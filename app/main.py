"""VPS Algorithmic Trading Control Center.

Dashboard monitoring akun & posisi MetaTrader 5 secara real-time, sepenuhnya
lewat websocket (data akun, live candle, dan panel admin).
"""
import asyncio
import json
import secrets
from contextlib import asynccontextmanager
from datetime import datetime
from pathlib import Path
from typing import Optional

import MetaTrader5 as mt5
from fastapi import FastAPI, Form, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse

from app import config, mt5_client, security
from app.config import logger
from app.ws_manager import manager

TEMPLATES_DIR = Path(__file__).parent / "templates"
DASHBOARD_HTML = (TEMPLATES_DIR / "dashboard.html").read_text(encoding="utf-8")
ADMIN_LOGIN_HTML = (TEMPLATES_DIR / "admin_login.html").read_text(encoding="utf-8")
ADMIN_HTML = (TEMPLATES_DIR / "admin.html").read_text(encoding="utf-8")


# ----------------------------------------------------------------------------
# Background broadcaster: snapshot akun + live candle -> semua client dashboard
# ----------------------------------------------------------------------------
async def _push_candle_updates():
    """Kelompokkan subscriber per (symbol,timeframe) unik supaya MT5 cuma di-query
    sekali per kombinasi walau banyak client subscribe ke kombinasi yang sama."""
    if not manager.candle_subs:
        return
    unique_combos = set(manager.candle_subs.values())
    for symbol, timeframe in unique_combos:
        try:
            update = await asyncio.to_thread(
                mt5_client.get_candles_sync, symbol, timeframe, mt5_client.CANDLE_UPDATE_PUSH_COUNT
            )
        except HTTPException:
            continue
        except Exception as e:
            logger.warning("Gagal ambil candle update %s %s: %s", symbol, timeframe, e)
            continue
        if not update.get("candles"):
            continue
        payload = {
            "type": "candle_update", "symbol": update["symbol"],
            "timeframe": update["timeframe"], "candles": update["candles"],
        }
        targets = [ws for ws, combo in manager.candle_subs.items() if combo == (symbol, timeframe)]
        for ws in targets:
            await manager.send_personal(ws, payload)


async def market_data_broadcaster():
    equity_curve: list[dict] = []

    while True:
        if not mt5_client.mt5_connected:
            backoff = min(2 ** mt5_client.reconnect_attempts, 30)
            await manager.broadcast({"type": "status", "connected": False})
            await asyncio.sleep(backoff)
            ok = await asyncio.to_thread(mt5_client.connect_sync)
            mt5_client.reconnect_attempts = 0 if ok else mt5_client.reconnect_attempts + 1
            continue

        try:
            snapshot = await asyncio.to_thread(mt5_client.fetch_snapshot_sync)

            equity_curve.append({
                "t": datetime.now().strftime("%H:%M:%S"),
                "equity": snapshot["account"]["equity"],
                "balance": snapshot["account"]["balance"],
            })
            if len(equity_curve) > config.EQUITY_CURVE_MAX_POINTS:
                equity_curve.pop(0)
            snapshot["equity_curve"] = equity_curve

            await manager.broadcast(snapshot)
            mt5_client.reconnect_attempts = 0

            await _push_candle_updates()
        except Exception as e:
            logger.exception("Gagal mengambil snapshot MT5: %s", e)
            mt5_client.mt5_connected = False

        await asyncio.sleep(config.REFRESH_RATE)


@asynccontextmanager
async def lifespan(app: FastAPI):
    await asyncio.to_thread(mt5_client.connect_sync)
    task = asyncio.create_task(market_data_broadcaster())
    logger.info("Dashboard siap. Memantau simbol: %s", ", ".join(config.SYMBOLS))
    yield
    task.cancel()
    mt5.shutdown()
    logger.info("MT5 shutdown, server berhenti.")


app = FastAPI(title="VPS Algorithmic Trading Control Center", lifespan=lifespan)


# ----------------------------------------------------------------------------
# Dashboard utama
# ----------------------------------------------------------------------------
@app.get("/", response_class=HTMLResponse)
async def get_dashboard():
    html = DASHBOARD_HTML.replace("{REFRESH_RATE}", str(config.REFRESH_RATE))
    html = html.replace("__DASHBOARD_SYMBOLS_JSON__", json.dumps(config.SYMBOLS))
    return HTMLResponse(
        content=html,
        headers={"Cache-Control": "no-store, no-cache, must-revalidate, max-age=0", "Pragma": "no-cache", "Expires": "0"},
    )


@app.get("/health")
async def health():
    market_status = mt5_client.check_market_status()
    return {
        "mt5_connected": mt5_client.mt5_connected,
        "clients": len(manager.active),
        "symbols": config.SYMBOLS,
        "market_open": market_status.get("is_open", False),
        "market_reason": market_status.get("reason", "Unknown"),
    }


@app.websocket("/ws/data")
async def websocket_endpoint(websocket: WebSocket):
    await manager.connect(websocket)
    try:
        while True:
            raw = await websocket.receive_text()
            try:
                msg = json.loads(raw)
            except (json.JSONDecodeError, TypeError):
                continue

            msg_type = msg.get("type")
            if msg_type == "subscribe_candles":
                symbol = str(msg.get("symbol") or (config.SYMBOLS[0] if config.SYMBOLS else "")).strip().upper()
                timeframe = str(msg.get("timeframe") or "M1").strip().upper()
                if not symbol:
                    continue
                manager.candle_subs[websocket] = (symbol, timeframe)
                # Kirim history awal LANGSUNG ke client ini saja (bukan broadcast),
                # supaya chart langsung terisi tanpa menunggu tick berikutnya.
                if mt5_client.mt5_connected:
                    try:
                        history = await asyncio.to_thread(
                            mt5_client.get_candles_sync, symbol, timeframe, mt5_client.CANDLE_HISTORY_PUSH_COUNT
                        )
                        await manager.send_personal(websocket, {
                            "type": "candle_history", "symbol": history["symbol"],
                            "timeframe": history["timeframe"], "candles": history["candles"],
                        })
                    except HTTPException as e:
                        await manager.send_personal(websocket, {"type": "candle_error", "detail": e.detail})
                    except Exception as e:
                        logger.warning("Gagal ambil candle history %s %s: %s", symbol, timeframe, e)
            elif msg_type == "unsubscribe_candles":
                manager.candle_subs.pop(websocket, None)
    except WebSocketDisconnect:
        manager.disconnect(websocket)


# ----------------------------------------------------------------------------
# Admin: login (HTTP, untuk set cookie) + panel (websocket penuh untuk data & aksi)
# ----------------------------------------------------------------------------
@app.get("/admin/login", response_class=HTMLResponse)
async def admin_login_page(error: Optional[str] = None):
    error_block = '<div class="error">Password salah. Silakan coba lagi.</div>' if error else ""
    return HTMLResponse(content=ADMIN_LOGIN_HTML.replace("__ERROR_BLOCK__", error_block))


@app.post("/admin/login")
async def admin_login_submit(password: str = Form(...)):
    if not config.ADMIN_PASSWORD or not secrets.compare_digest(password, config.ADMIN_PASSWORD):
        return RedirectResponse(url="/admin/login?error=1", status_code=303)

    token = security.make_token()
    resp = RedirectResponse(url="/admin", status_code=303)
    resp.set_cookie(
        key=config.ADMIN_COOKIE_NAME, value=token,
        max_age=int(config.ADMIN_SESSION_HOURS * 3600), httponly=True, samesite="lax",
    )
    return resp


@app.post("/admin/logout")
async def admin_logout():
    resp = JSONResponse(content={"ok": True})
    resp.delete_cookie(config.ADMIN_COOKIE_NAME)
    return resp


@app.get("/admin", response_class=HTMLResponse)
async def admin_page(request: Request):
    if not security.is_authed(request):
        return RedirectResponse(url="/admin/login", status_code=303)
    return HTMLResponse(content=ADMIN_HTML)


async def _admin_snapshot() -> dict:
    if not mt5_client.mt5_connected:
        return {
            "type": "snapshot", "connected": False,
            "pending_orders": [], "active_trades": [], "failed_orders": [], "bot_status": None, "bot_events": [],
        }
    pending_orders, active_trades, failed_orders, bot_status, bot_events = await asyncio.gather(
        asyncio.to_thread(mt5_client.get_pending_orders_sync),
        asyncio.to_thread(mt5_client.get_active_positions_sync),
        asyncio.to_thread(mt5_client.read_failed_orders_sync),
        asyncio.to_thread(mt5_client.read_bot_status_sync),
        asyncio.to_thread(mt5_client.read_bot_events_sync),
    )
    return {
        "type": "snapshot", "connected": True,
        "pending_orders": pending_orders, "active_trades": active_trades,
        "failed_orders": failed_orders, "bot_status": bot_status, "bot_events": bot_events,
    }


async def _admin_handle_action(msg: dict) -> dict:
    """Jalankan aksi admin (close position/close-all/ganti mode) dan kembalikan hasilnya
    dalam bentuk seragam {success, message} untuk dikirim balik lewat websocket."""
    action = msg.get("type")

    if action == "close_position":
        ticket = int(msg.get("ticket"))
        result = await asyncio.to_thread(mt5_client.close_position_by_ticket_sync, ticket)
        return {"success": result["success"], "message": result["message"]}

    if action in ("close_all", "close_all_profit", "close_all_loss"):
        mode = {"close_all": "all", "close_all_profit": "profit", "close_all_loss": "loss"}[action]
        results = await asyncio.to_thread(mt5_client.close_positions_bulk_sync, mode)
        ok = sum(1 for r in results if r["success"])
        label = {"all": "posisi", "profit": "posisi profit", "loss": "posisi loss"}[mode]
        return {"success": True, "message": f"Selesai: {ok}/{len(results)} {label} ditutup."}

    if action == "set_mode":
        mode = msg.get("mode")
        if mode not in mt5_client.VALID_TRADING_MODES:
            return {"success": False, "message": f"Mode tidak valid: {mode}"}
        result = await asyncio.to_thread(mt5_client.write_bot_command_sync, mode)
        return {"success": result["success"], "message": result["message"]}

    return {"success": False, "message": f"Aksi tidak dikenal: {action}"}


@app.websocket("/ws/admin")
async def admin_websocket(websocket: WebSocket):
    """Satu koneksi websocket untuk seluruh panel admin: push data berkala
    (menggantikan polling REST) sekaligus menerima perintah aksi (close
    position, close-all, ganti mode trading) dan membalas hasilnya."""
    if not security.is_ws_authed(websocket):
        await websocket.close(code=4401)
        return

    await websocket.accept()
    try:
        while True:
            try:
                raw = await asyncio.wait_for(websocket.receive_text(), timeout=config.REFRESH_RATE)
            except asyncio.TimeoutError:
                await manager.send_personal(websocket, await _admin_snapshot())
                continue

            try:
                msg = json.loads(raw)
            except (json.JSONDecodeError, TypeError):
                continue

            request_id = msg.get("request_id")
            result = await _admin_handle_action(msg)
            await manager.send_personal(websocket, {"type": "action_result", "request_id": request_id, **result})
            await manager.send_personal(websocket, await _admin_snapshot())
    except WebSocketDisconnect:
        pass


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host=config.HOST, port=config.PORT)

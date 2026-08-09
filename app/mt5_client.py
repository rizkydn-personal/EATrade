"""Semua interaksi dengan terminal MT5: koneksi, snapshot akun, candle,
order pending/aktif, eksekusi close position, dan file status/log EA."""
import json
import os
import time
from datetime import datetime, timedelta
from typing import Optional

import MetaTrader5 as mt5
from fastapi import HTTPException

from app import config
from app.config import logger

mt5_connected = False
reconnect_attempts = 0

_symbol_cache: dict[str, Optional[str]] = {}

_MT5_TIMEFRAMES = {
    "M1": mt5.TIMEFRAME_M1, "M5": mt5.TIMEFRAME_M5, "M15": mt5.TIMEFRAME_M15,
    "M30": mt5.TIMEFRAME_M30, "H1": mt5.TIMEFRAME_H1, "H4": mt5.TIMEFRAME_H4,
    "D1": mt5.TIMEFRAME_D1,
}
CANDLE_MAX_COUNT = 1000
CANDLE_DEFAULT_COUNT = 200
CANDLE_HISTORY_PUSH_COUNT = 300  # dikirim sekali saat client subscribe
CANDLE_UPDATE_PUSH_COUNT = 3     # dikirim tiap tick berikutnya

_PENDING_TYPE_NAMES = {
    getattr(mt5, "ORDER_TYPE_BUY_LIMIT", 2): "BUY LIMIT",
    getattr(mt5, "ORDER_TYPE_SELL_LIMIT", 3): "SELL LIMIT",
    getattr(mt5, "ORDER_TYPE_BUY_STOP", 4): "BUY STOP",
    getattr(mt5, "ORDER_TYPE_SELL_STOP", 5): "SELL STOP",
    getattr(mt5, "ORDER_TYPE_BUY_STOP_LIMIT", 6): "BUY STOP LIMIT",
    getattr(mt5, "ORDER_TYPE_SELL_STOP_LIMIT", 7): "SELL STOP LIMIT",
}

TRADE_RETCODE_INVALID_FILL = 10030

# Terjemahan retcode MT5 yang paling sering muncul (ENUM_TRADE_RETCODE).
_RETCODE_MESSAGES = {
    10004: "Requote - harga sudah berubah, coba lagi.",
    10006: "Order ditolak broker.",
    10013: "Request tidak valid.",
    10014: "Volume tidak valid untuk symbol ini.",
    10015: "Harga tidak valid.",
    10016: "SL/TP tidak valid.",
    10018: "Market sedang TUTUP untuk symbol ini - order tidak bisa diproses.",
    10019: "Saldo/margin tidak cukup.",
    10021: "Tidak ada harga (requote), coba lagi sebentar lagi.",
    10025: "Tidak ada perubahan pada request.",
    10026: "Autotrading dimatikan di server broker.",
    10027: "Autotrading dimatikan di terminal MT5 (klik tombol Algo Trading di MT5).",
    10030: "Filling mode ditolak broker untuk symbol ini (FOK, IOC, dan RETURN sudah dicoba).",
    10031: "Tidak ada koneksi ke server trading.",
    10033: "Jumlah order pending sudah mencapai limit broker.",
    10034: "Jumlah/volume order sudah mencapai limit broker.",
}

# Modul Python `MetaTrader5` tidak menyediakan konstanta SYMBOL_FILLING_FOK/IOC
# (hanya ada di enum MQL5) - filling_mode dibaca sebagai bitmask integer biasa:
# bit 0 (1) = FOK didukung, bit 1 (2) = IOC didukung.
_SYMBOL_FILLING_FOK_BIT = 1
_SYMBOL_FILLING_IOC_BIT = 2
_FILLING_FALLBACK_ORDER = [mt5.ORDER_FILLING_FOK, mt5.ORDER_FILLING_IOC, mt5.ORDER_FILLING_RETURN]
_FILLING_NAMES = {mt5.ORDER_FILLING_FOK: "FOK", mt5.ORDER_FILLING_IOC: "IOC", mt5.ORDER_FILLING_RETURN: "RETURN"}

VALID_TRADING_MODES = {"DEFAULT_RECOMMENDED", "H24_UNLIMITED"}


# ----------------------------------------------------------------------------
# Koneksi & status market
# ----------------------------------------------------------------------------
def connect_sync() -> bool:
    global mt5_connected
    if config.MT5_LOGIN and config.MT5_PASSWORD and config.MT5_SERVER:
        ok = mt5.initialize(login=int(config.MT5_LOGIN), password=config.MT5_PASSWORD, server=config.MT5_SERVER)
    else:
        ok = mt5.initialize()

    mt5_connected = bool(ok)
    if not ok:
        logger.error("Gagal konek ke MT5: %s", mt5.last_error())
    else:
        acc = mt5.account_info()
        logger.info("Terhubung ke MT5. Akun: %s | Server: %s", acc.login if acc else "?", acc.server if acc else "?")
    return mt5_connected


def _mt5_time_str(epoch_seconds: float) -> str:
    if config.MT5_SERVER_UTC_OFFSET_HOURS:
        dt = datetime.utcfromtimestamp(epoch_seconds) + timedelta(hours=config.MT5_SERVER_UTC_OFFSET_HOURS)
    else:
        dt = datetime.fromtimestamp(epoch_seconds)
    return dt.strftime("%Y-%m-%d %H:%M:%S")


def check_market_status() -> dict:
    now_utc = datetime.utcnow()
    weekday = now_utc.weekday()
    hour = now_utc.hour

    if weekday == 5:  # Sabtu
        next_open = (now_utc + timedelta(days=2)).replace(hour=0, minute=0, second=0, microsecond=0)
        return {
            "is_open": False, "status": "Market Closed", "reason": "Weekend - Saturday",
            "current_time": now_utc.strftime("%Y-%m-%d %H:%M:%S UTC"),
            "next_open": next_open.strftime("%Y-%m-%d %H:%M:%S UTC"), "next_close": "N/A (Weekend)",
            "day": "Saturday", "is_weekend": True,
        }

    if weekday == 6:  # Minggu
        if hour < 22:
            next_open = now_utc.replace(hour=22, minute=0, second=0, microsecond=0)
            return {
                "is_open": False, "status": "Market Closed", "reason": "Weekend - Sunday (pre-open)",
                "current_time": now_utc.strftime("%Y-%m-%d %H:%M:%S UTC"),
                "next_open": next_open.strftime("%Y-%m-%d %H:%M:%S UTC"), "next_close": "N/A (Weekend)",
                "day": "Sunday", "is_weekend": True,
            }
        return {
            "is_open": True, "status": "Market Open", "reason": "Sunday Session Open",
            "current_time": now_utc.strftime("%Y-%m-%d %H:%M:%S UTC"),
            "next_open": None, "next_close": None, "day": "Sunday", "is_weekend": False,
        }

    if weekday == 4 and hour >= 22:  # Jumat malam
        next_open = (now_utc + timedelta(days=3)).replace(hour=0, minute=0, second=0, microsecond=0)
        return {
            "is_open": False, "status": "Market Closed", "reason": "Friday Close",
            "current_time": now_utc.strftime("%Y-%m-%d %H:%M:%S UTC"),
            "next_open": next_open.strftime("%Y-%m-%d %H:%M:%S UTC"), "next_close": "N/A (Weekend)",
            "day": "Friday", "is_weekend": True,
        }

    if mt5_connected and config.SYMBOLS:
        try:
            tick = mt5.symbol_info_tick(config.SYMBOLS[0])
            if tick:
                tick_time = datetime.fromtimestamp(tick.time)
                time_diff = (now_utc - tick_time).total_seconds()
                is_open = time_diff <= 60
                return {
                    "is_open": is_open, "status": "Market Open" if is_open else "Market Closed",
                    "reason": f"Active Trading ({int(time_diff)}s since last tick)" if is_open else f"No Recent Ticks ({int(time_diff)}s ago)",
                    "current_time": now_utc.strftime("%Y-%m-%d %H:%M:%S UTC"),
                    "last_tick": tick_time.strftime("%Y-%m-%d %H:%M:%S UTC"),
                    "next_open": None if is_open else "N/A", "next_close": None if is_open else "N/A",
                    "day": now_utc.strftime("%A"), "is_weekend": False,
                }
        except Exception as e:
            logger.warning("Gagal cek tick MT5: %s", e)

    if 0 <= weekday <= 4:  # Senin-Jumat, fallback
        return {
            "is_open": True, "status": "Market Open", "reason": "Regular Trading Session",
            "current_time": now_utc.strftime("%Y-%m-%d %H:%M:%S UTC"),
            "next_open": None, "next_close": None, "day": now_utc.strftime("%A"), "is_weekend": False,
        }

    return {
        "is_open": False, "status": "Market Closed", "reason": "Unknown",
        "current_time": now_utc.strftime("%Y-%m-%d %H:%M:%S UTC"),
        "next_open": "N/A", "next_close": "N/A", "day": now_utc.strftime("%A"), "is_weekend": True,
    }


# ----------------------------------------------------------------------------
# Symbol & candle
# ----------------------------------------------------------------------------
def _resolve_symbol(base: str) -> Optional[str]:
    if base in _symbol_cache:
        return _symbol_cache[base]

    resolved = None
    if mt5.symbol_info(base) is not None:
        resolved = base
    else:
        all_symbols = mt5.symbols_get()
        if all_symbols:
            candidates = sorted(
                (s.name for s in all_symbols if base.upper() in s.name.upper()), key=len
            )
            if candidates:
                resolved = candidates[0]

    if resolved is None:
        logger.warning("Simbol '%s' tidak ditemukan di broker", base)
    elif not mt5.symbol_select(resolved, True):
        logger.warning("Gagal menambahkan '%s' ke Market Watch", resolved)

    _symbol_cache[base] = resolved
    return resolved


def get_candles_sync(symbol: str, timeframe: str, count: int) -> dict:
    """Ambil candle OHLC untuk 1 symbol+timeframe (dipanggil via asyncio.to_thread)."""
    tf_key = (timeframe or "M1").strip().upper()
    tf_const = _MT5_TIMEFRAMES.get(tf_key)
    if tf_const is None:
        raise HTTPException(status_code=400, detail=f"Timeframe tidak didukung: {timeframe}")

    resolved_sym = _resolve_symbol(symbol)
    if not resolved_sym:
        raise HTTPException(status_code=404, detail=f"Symbol tidak ditemukan di broker: {symbol}")

    safe_count = max(10, min(int(count or CANDLE_DEFAULT_COUNT), CANDLE_MAX_COUNT))
    rates = mt5.copy_rates_from_pos(resolved_sym, tf_const, 0, safe_count)
    if rates is None or len(rates) == 0:
        return {"symbol": resolved_sym, "timeframe": tf_key, "candles": []}

    candles = [
        {"time": int(r["time"]), "open": float(r["open"]), "high": float(r["high"]),
         "low": float(r["low"]), "close": float(r["close"]), "volume": int(r["tick_volume"])}
        for r in rates
    ]
    return {"symbol": resolved_sym, "timeframe": tf_key, "candles": candles}


# ----------------------------------------------------------------------------
# Snapshot akun (dashboard utama)
# ----------------------------------------------------------------------------
def fetch_snapshot_sync() -> dict:
    account = mt5.account_info()
    if account is None:
        raise RuntimeError(f"account_info() gagal: {mt5.last_error()}")

    watchlist = []
    for sym in config.SYMBOLS:
        resolved_sym = _resolve_symbol(sym)
        tick = mt5.symbol_info_tick(resolved_sym) if resolved_sym else None
        if tick:
            watchlist.append({
                "symbol": resolved_sym, "bid": tick.bid, "ask": tick.ask,
                "spread": round(tick.ask - tick.bid, 5), "time": tick.time,
            })
        else:
            watchlist.append({"symbol": sym, "bid": None, "ask": None, "spread": None, "time": None})

    positions = mt5.positions_get()
    active_trades = []
    total_floating = 0.0
    if positions:
        for p in positions:
            total_floating += p.profit
            active_trades.append({
                "ticket": p.ticket, "symbol": p.symbol,
                "type": "BUY" if p.type == mt5.POSITION_TYPE_BUY else "SELL",
                "volume": p.volume, "price_open": p.price_open, "price_current": p.price_current,
                "sl": p.sl, "tp": p.tp, "pnl": p.profit, "open_time": _mt5_time_str(p.time),
            })

    days_to_fetch = max(config.HISTORY_DAYS, 30)
    date_from = datetime.now() - timedelta(days=days_to_fetch)
    date_to = datetime.now() + timedelta(days=1)

    deals = mt5.history_deals_get(date_from, date_to)
    if deals is None or len(deals) == 0:
        deals = mt5.history_deals_get()

    # MT5 menampilkan "Type" di tab History berdasarkan arah deal ENTRY (pembukaan
    # posisi), bukan deal EXIT (penutupan): saat posisi BUY ditutup, deal exit-nya
    # justru bertipe SELL (dan sebaliknya). Mapping position_id -> tipe deal entry
    # supaya label BUY/SELL konsisten dengan history asli MT5.
    entry_type_by_position = {}
    if deals:
        for d in deals:
            if d.entry == mt5.DEAL_ENTRY_IN and d.type in (mt5.DEAL_TYPE_BUY, mt5.DEAL_TYPE_SELL):
                entry_type_by_position[d.position_id] = d.type

    def _resolve_trade_type(d):
        entry_type = entry_type_by_position.get(d.position_id)
        if entry_type is not None:
            return "BUY" if entry_type == mt5.DEAL_TYPE_BUY else "SELL"
        # Fallback kalau deal entry tidak ditemukan (mis. di luar range tanggal):
        # arah exit deal adalah kebalikan dari arah posisi aslinya.
        if d.type == mt5.DEAL_TYPE_BUY:
            return "SELL"
        if d.type == mt5.DEAL_TYPE_SELL:
            return "BUY"
        return f"TYPE_{d.type}"

    history_trades = []
    if deals:
        for d in deals:
            if d.entry in (mt5.DEAL_ENTRY_OUT, mt5.DEAL_ENTRY_OUT_BY, mt5.DEAL_ENTRY_INOUT):
                if d.type == mt5.DEAL_TYPE_BALANCE:
                    continue
                history_trades.append({
                    "ticket": d.ticket, "symbol": d.symbol, "type": _resolve_trade_type(d),
                    "volume": d.volume, "pnl": d.profit, "commission": d.commission, "swap": d.swap,
                    "comment": d.comment or "", "time": _mt5_time_str(d.time), "time_epoch": d.time,
                })

        if not history_trades:
            for d in deals:
                if d.type in (mt5.DEAL_TYPE_BUY, mt5.DEAL_TYPE_SELL):
                    trade_type = _resolve_trade_type(d) if d.entry != mt5.DEAL_ENTRY_IN else ("BUY" if d.type == mt5.DEAL_TYPE_BUY else "SELL")
                    history_trades.append({
                        "ticket": d.ticket, "symbol": d.symbol, "type": trade_type,
                        "volume": d.volume, "pnl": d.profit, "commission": d.commission, "swap": d.swap,
                        "comment": d.comment or "", "time": _mt5_time_str(d.time), "time_epoch": d.time,
                    })

    if history_trades:
        cutoff_epoch = (datetime.now() - timedelta(days=config.HISTORY_DAYS)).timestamp()
        history_trades = [t for t in history_trades if t.get("time_epoch", 0) >= cutoff_epoch]

    history_trades.sort(key=lambda t: t.get("time", ""), reverse=True)

    today_start = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
    today_trades = [t for t in history_trades if t.get("time_epoch", 0) >= today_start]

    wins = [t["pnl"] for t in today_trades if t["pnl"] > 0]
    losses = [t["pnl"] for t in today_trades if t["pnl"] < 0]
    total_closed = len(today_trades)
    win_rate = round((len(wins) / total_closed) * 100, 1) if total_closed else 0.0
    gross_profit = sum(wins)
    gross_loss = abs(sum(losses))
    profit_factor = round(gross_profit / gross_loss, 2) if gross_loss > 0 else (gross_profit if gross_profit > 0 else 0.0)
    best_trade = max(today_trades, key=lambda t: t["pnl"], default=None)
    worst_trade = min(today_trades, key=lambda t: t["pnl"], default=None)
    realized_pnl_today = sum(t["pnl"] + t.get("commission", 0) + t.get("swap", 0) for t in today_trades)

    return {
        "type": "snapshot",
        "bot_status": read_bot_status_sync(),
        "connected": True,
        "server_time": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "account": {
            "login": account.login, "server": account.server, "currency": account.currency,
            "balance": account.balance, "equity": account.equity, "margin": account.margin,
            "margin_free": account.margin_free, "margin_level": account.margin_level,
            "floating_pnl": total_floating,
        },
        "watchlist": watchlist,
        "active_trades": active_trades,
        "history_trades": history_trades,
        "stats": {
            "win_rate": win_rate, "profit_factor": profit_factor, "total_closed_today": total_closed,
            "realized_pnl_today": round(realized_pnl_today, 2), "best_trade": best_trade, "worst_trade": worst_trade,
        },
        "market_status": check_market_status(),
    }


# ----------------------------------------------------------------------------
# Admin: pending orders, posisi aktif, close position
# ----------------------------------------------------------------------------
def get_pending_orders_sync() -> list:
    orders = mt5.orders_get()
    result = []
    if orders:
        for o in orders:
            result.append({
                "ticket": o.ticket, "symbol": o.symbol,
                "type": _PENDING_TYPE_NAMES.get(o.type, f"TYPE_{o.type}"),
                "volume": o.volume_current, "price_open": o.price_open, "sl": o.sl, "tp": o.tp,
                "setup_time": _mt5_time_str(o.time_setup), "comment": o.comment or "",
            })
    result.sort(key=lambda x: x["setup_time"], reverse=True)
    return result


def get_active_positions_sync() -> list:
    positions = mt5.positions_get()
    result = []
    if positions:
        for p in positions:
            result.append({
                "ticket": p.ticket, "symbol": p.symbol,
                "type": "BUY" if p.type == mt5.POSITION_TYPE_BUY else "SELL",
                "volume": p.volume, "price_open": p.price_open, "price_current": p.price_current,
                "sl": p.sl, "tp": p.tp, "pnl": p.profit, "open_time": _mt5_time_str(p.time),
            })
    return result


def _get_preferred_filling_type(symbol: str) -> int:
    """Deteksi mode filling yang didukung symbol dari MT5, bukan hardcode IOC -
    broker sering hanya mendukung salah satu (FOK atau IOC)."""
    info = mt5.symbol_info(symbol)
    if info is None:
        return mt5.ORDER_FILLING_IOC
    filling_mode = info.filling_mode
    if filling_mode & _SYMBOL_FILLING_FOK_BIT:
        return mt5.ORDER_FILLING_FOK
    if filling_mode & _SYMBOL_FILLING_IOC_BIT:
        return mt5.ORDER_FILLING_IOC
    return mt5.ORDER_FILLING_RETURN


def _send_close_order_with_filling_retry(base_request: dict, symbol: str):
    """Kirim order close dengan filling mode yang paling cocok untuk symbol; kalau
    broker menolak dengan retcode invalid-fill, coba mode filling lain satu per satu."""
    preferred = _get_preferred_filling_type(symbol)
    order_to_try = [preferred] + [f for f in _FILLING_FALLBACK_ORDER if f != preferred]

    last_result = None
    for filling in order_to_try:
        request = dict(base_request, type_filling=filling)
        result = mt5.order_send(request)
        last_result = result

        logger.info(
            "Close %s ticket=%s filling=%s -> retcode=%s comment=%s",
            symbol, base_request.get("position"), _FILLING_NAMES.get(filling, filling),
            getattr(result, "retcode", None), getattr(result, "comment", None),
        )

        if result is not None and result.retcode == mt5.TRADE_RETCODE_DONE:
            return result
        if result is not None and result.retcode != TRADE_RETCODE_INVALID_FILL:
            return result  # gagal karena alasan lain, bukan soal filling mode
    return last_result


def close_position_by_ticket_sync(ticket: int) -> dict:
    positions = mt5.positions_get(ticket=ticket)
    if not positions:
        return {"ticket": ticket, "success": False, "message": "Posisi tidak ditemukan (mungkin sudah tertutup)."}

    p = positions[0]
    tick = mt5.symbol_info_tick(p.symbol)
    if tick is None:
        return {"ticket": ticket, "success": False, "message": f"Gagal ambil harga untuk {p.symbol}."}

    tick_age_seconds = int(time.time() - tick.time)
    market_likely_closed = tick_age_seconds > 90

    if p.type == mt5.POSITION_TYPE_BUY:
        order_type, price = mt5.ORDER_TYPE_SELL, tick.bid
    else:
        order_type, price = mt5.ORDER_TYPE_BUY, tick.ask

    base_request = {
        "action": mt5.TRADE_ACTION_DEAL, "position": p.ticket, "symbol": p.symbol,
        "volume": p.volume, "type": order_type, "price": price, "deviation": 20,
        "magic": 234000, "comment": "Admin manual close", "type_time": mt5.ORDER_TIME_GTC,
    }
    send_result = _send_close_order_with_filling_retry(base_request, p.symbol)
    if send_result is None:
        return {"ticket": ticket, "success": False, "message": f"order_send gagal: {mt5.last_error()}"}
    if send_result.retcode != mt5.TRADE_RETCODE_DONE:
        friendly = _RETCODE_MESSAGES.get(send_result.retcode, send_result.comment)
        message = f"[{send_result.retcode}] {friendly}"
        if market_likely_closed:
            message += f" (tick {p.symbol} terakhir {tick_age_seconds}s lalu - market kemungkinan tutup)"
        return {"ticket": ticket, "success": False, "message": message}
    return {"ticket": ticket, "success": True, "message": "Posisi berhasil ditutup."}


def close_positions_bulk_sync(mode: str) -> list:
    """mode: 'all' | 'profit' | 'loss'"""
    positions = mt5.positions_get()
    if not positions:
        return []
    targets = []
    for p in positions:
        if mode == "profit" and p.profit < 0:
            continue
        if mode == "loss" and p.profit >= 0:
            continue
        targets.append(p.ticket)
    return [close_position_by_ticket_sync(t) for t in targets]


# ----------------------------------------------------------------------------
# File status/log EA (ditulis oleh XAUUSD_scalper_M1.mq5 di folder Common\Files)
# ----------------------------------------------------------------------------
def _read_jsonlines_sync(path: str, max_rows: int, label: str) -> list:
    if not os.path.exists(path):
        return []
    rows = []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    except Exception as e:
        logger.warning("Gagal membaca %s: %s", label, e)
        return []
    rows.reverse()  # terbaru dulu
    return rows[:max_rows]


def read_failed_orders_sync() -> list:
    return _read_jsonlines_sync(config.FAILED_ORDERS_LOG_PATH, config.FAILED_ORDERS_MAX_ROWS, "log kegagalan order")


def read_bot_events_sync() -> list:
    return _read_jsonlines_sync(config.BOT_EVENTS_LOG_PATH, config.BOT_EVENTS_MAX_ROWS, "log event bot")


def read_bot_status_sync() -> Optional[dict]:
    """Baca snapshot status live EA (ditulis ulang tiap update, bukan JSON-lines)."""
    if not os.path.exists(config.BOT_STATUS_LOG_PATH):
        return None
    try:
        with open(config.BOT_STATUS_LOG_PATH, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        if not content:
            return None
        status = json.loads(content)
    except Exception as e:
        logger.warning("Gagal membaca file status bot: %s", e)
        return None

    # Tandai stale kalau EA tidak update file dalam BOT_STATUS_STALE_AFTER_SEC detik
    # (mis. EA di-remove dari chart / AutoTrading dimatikan / terminal crash).
    try:
        ts = datetime.strptime(status.get("timestamp", ""), "%Y.%m.%d %H:%M:%S")
        age_sec = (datetime.now() - ts).total_seconds()
        status["_age_seconds"] = round(age_sec)
        status["_stale"] = age_sec > config.BOT_STATUS_STALE_AFTER_SEC
    except Exception:
        status["_age_seconds"] = None
        status["_stale"] = False
    return status


def write_bot_command_sync(mode: str) -> dict:
    """Tulis perintah ganti mode trading ke file yang di-poll EA lewat OnTimer
    (InpCommandPollIntervalSec), jadi berlaku dalam beberapa detik tanpa perlu
    restart/re-attach EA. Format timestamp harus sama dengan
    TimeToString(..., TIME_DATE|TIME_SECONDS) di MQL5 ("%Y.%m.%d %H:%M:%S")."""
    if mode not in VALID_TRADING_MODES:
        return {"success": False, "message": f"Mode tidak dikenal: {mode}"}
    try:
        parent = os.path.dirname(config.BOT_COMMAND_LOG_PATH)
        if parent:
            os.makedirs(parent, exist_ok=True)
        payload = {
            "mode": mode,
            "issued_at": datetime.now().strftime("%Y.%m.%d %H:%M:%S"),
            "issued_by": "admin-dashboard",
        }
        with open(config.BOT_COMMAND_LOG_PATH, "w", encoding="utf-8") as f:
            json.dump(payload, f)
        logger.info("Perintah ganti mode trading dikirim ke EA: %s", mode)
        return {
            "success": True, "mode": mode,
            "message": f"Perintah ganti mode ke '{mode}' terkirim. EA akan menerapkannya dalam beberapa detik.",
        }
    except Exception as e:
        logger.warning("Gagal menulis perintah mode trading: %s", e)
        return {"success": False, "message": f"Gagal menulis perintah: {e}"}

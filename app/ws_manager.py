"""Manager koneksi websocket untuk dashboard utama (snapshot akun + live candle)."""
import json

from fastapi import WebSocket

from app.config import logger


class ConnectionManager:
    def __init__(self):
        self.active: list[WebSocket] = []
        # Subscription live-candle per koneksi: ws -> (symbol, timeframe). Candle
        # di-push lewat websocket yang sama dengan snapshot akun (bukan polling
        # REST berulang dari browser).
        self.candle_subs: dict[WebSocket, tuple[str, str]] = {}

    async def connect(self, ws: WebSocket):
        await ws.accept()
        self.active.append(ws)
        logger.info("Client baru terhubung. Total client: %d", len(self.active))

    def disconnect(self, ws: WebSocket):
        if ws in self.active:
            self.active.remove(ws)
            logger.info("Client terputus. Total client: %d", len(self.active))
        self.candle_subs.pop(ws, None)

    async def broadcast(self, message: dict):
        if not self.active:
            return
        payload = json.dumps(message, default=str)
        dead = []
        for ws in self.active:
            try:
                await ws.send_text(payload)
            except Exception:
                dead.append(ws)
        for ws in dead:
            self.disconnect(ws)

    async def send_personal(self, ws: WebSocket, message: dict):
        try:
            await ws.send_text(json.dumps(message, default=str))
        except Exception:
            self.disconnect(ws)


manager = ConnectionManager()

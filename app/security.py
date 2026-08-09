"""Autentikasi admin panel: token sesi HMAC disimpan di cookie httponly."""
import hashlib
import hmac
import time
from typing import Optional

from fastapi import HTTPException, Request, WebSocket

from app import config


def make_token() -> str:
    expiry = int(time.time()) + int(config.ADMIN_SESSION_HOURS * 3600)
    payload = str(expiry)
    sig = hmac.new(config.ADMIN_SECRET_KEY.encode(), payload.encode(), hashlib.sha256).hexdigest()
    return f"{payload}.{sig}"


def verify_token(token: Optional[str]) -> bool:
    if not token or "." not in token:
        return False
    payload, _, sig = token.partition(".")
    expected_sig = hmac.new(config.ADMIN_SECRET_KEY.encode(), payload.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(sig, expected_sig):
        return False
    try:
        return time.time() < int(payload)
    except ValueError:
        return False


def is_authed(request: Request) -> bool:
    return verify_token(request.cookies.get(config.ADMIN_COOKIE_NAME))


def is_ws_authed(websocket: WebSocket) -> bool:
    return verify_token(websocket.cookies.get(config.ADMIN_COOKIE_NAME))


def require_admin_api(request: Request):
    """Untuk route API (JSON) - balas 401 jika belum login."""
    if not is_authed(request):
        raise HTTPException(status_code=401, detail="Unauthorized")

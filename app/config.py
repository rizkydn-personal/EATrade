"""Konfigurasi aplikasi, dibaca dari environment variable / file .env."""
import logging
import os
import secrets

from dotenv import load_dotenv

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("trading-dashboard")


def _env_float(name: str, default: float) -> float:
    return float(os.getenv(name, default))


def _env_int(name: str, default: int) -> int:
    return int(os.getenv(name, default))


# --- Koneksi MT5 ---
MT5_LOGIN = os.getenv("MT5_LOGIN")
MT5_PASSWORD = os.getenv("MT5_PASSWORD")
MT5_SERVER = os.getenv("MT5_SERVER")

# --- Dashboard ---
SYMBOLS = [s.strip().upper() for s in os.getenv("SYMBOLS", "XAUUSD").split(",") if s.strip()]
REFRESH_RATE = _env_float("REFRESH_RATE_SECONDS", 1.0)
HISTORY_DAYS = _env_int("HISTORY_DAYS", 1)
MT5_SERVER_UTC_OFFSET_HOURS = _env_float("MT5_SERVER_UTC_OFFSET_HOURS", 0.0)
EQUITY_CURVE_MAX_POINTS = _env_int("EQUITY_CURVE_MAX_POINTS", 300)
HOST = os.getenv("HOST", "0.0.0.0")
PORT = _env_int("PORT", 8000)

# --- Admin panel ---
ADMIN_PASSWORD = os.getenv("ADMIN_PASSWORD", "")
ADMIN_SECRET_KEY = os.getenv("ADMIN_SECRET_KEY", "")
ADMIN_SESSION_HOURS = _env_float("ADMIN_SESSION_HOURS", 12.0)
ADMIN_COOKIE_NAME = "admin_session"

# --- File yang ditulis/dibaca EA (folder Common\Files milik terminal MT5) ---
FAILED_ORDERS_LOG_PATH = os.getenv("FAILED_ORDERS_LOG_PATH", "failed_orders.json")
FAILED_ORDERS_MAX_ROWS = _env_int("FAILED_ORDERS_MAX_ROWS", 200)
BOT_STATUS_LOG_PATH = os.getenv("BOT_STATUS_LOG_PATH", "range_breakout_m1_status.json")
BOT_EVENTS_LOG_PATH = os.getenv("BOT_EVENTS_LOG_PATH", "range_breakout_m1_events.json")
BOT_EVENTS_MAX_ROWS = _env_int("BOT_EVENTS_MAX_ROWS", 200)
BOT_STATUS_STALE_AFTER_SEC = _env_int("BOT_STATUS_STALE_AFTER_SEC", 30)
BOT_COMMAND_LOG_PATH = os.getenv("BOT_COMMAND_LOG_PATH", "bot_command.json")

if not ADMIN_PASSWORD:
    logger.warning(
        "ADMIN_PASSWORD belum diset di .env - halaman /admin tidak bisa login. "
        "Tambahkan ADMIN_PASSWORD=your_password_here ke file .env."
    )
if not ADMIN_SECRET_KEY:
    # Fallback acak: aman selama proses berjalan, tapi sesi hilang tiap restart.
    ADMIN_SECRET_KEY = secrets.token_hex(32)
    logger.warning(
        "ADMIN_SECRET_KEY belum diset di .env - memakai kunci acak sementara "
        "(sesi admin logout otomatis tiap restart server)."
    )

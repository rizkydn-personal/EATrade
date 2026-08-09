# Trading System Control Center

Dashboard monitoring & kontrol akun MetaTrader 5 secara real-time, dipasangkan
dengan Expert Advisor (EA) scalper `XAUUSD_scalper_M1.mq5`. Semua data akun,
posisi, dan candle mengalir lewat **WebSocket** (bukan polling REST berulang),
baik di dashboard utama maupun panel admin.

## Struktur project

```
├── app/
│   ├── main.py           # FastAPI app: routing, websocket, background broadcaster
│   ├── config.py         # Baca semua konfigurasi dari .env
│   ├── mt5_client.py     # Semua interaksi ke terminal MT5 (akun, order, candle)
│   ├── security.py       # Autentikasi admin (token sesi HMAC di cookie)
│   ├── ws_manager.py     # Connection manager untuk websocket dashboard utama
│   └── templates/
│       ├── dashboard.html    # Halaman utama (akun, chart, watchlist)
│       ├── admin.html        # Panel admin (pending order, posisi, close, ganti mode)
│       └── admin_login.html  # Form login admin
├── ea/
│   └── XAUUSD_scalper_M1.mq5 # Expert Advisor MT5 (scalper M1)
├── requirements.txt
├── .env.example
├── setup.bat / run.bat / install_service.bat   # Windows (VPS produksi)
└── setup.sh / run.sh                            # Linux/macOS (dev/testing saja)
```

## Cara kerja singkat

1. **EA** (`ea/XAUUSD_scalper_M1.mq5`) dipasang di chart MT5 (lihat bagian
   "Setup EA" di bawah). EA menulis status & event ke file JSON di folder
   `Common\Files` milik terminal MT5.
2. **Dashboard** (`app/`) berjalan sebagai proses terpisah di VPS yang sama,
   membaca data akun langsung lewat API `MetaTrader5` (python) dan membaca
   file status/event yang ditulis EA, lalu menyiarkannya ke browser lewat
   WebSocket.
3. **Panel admin** (`/admin`) memakai WebSocket yang sama untuk menerima data
   berkala DAN mengirim perintah (close posisi, close all, ganti mode
   trading EA) — semuanya di satu koneksi, tanpa polling REST.

## Requirement

- **Windows Server/VPS** dengan **terminal MT5** ter-install & bisa login ke
  akun broker. Paket Python `MetaTrader5` resmi hanya berfungsi di Windows
  karena membungkus API terminal MT5 Windows.
- **Python 3.10+**.

## Instalasi & auto setup (Windows VPS)

1. Salin folder project ini ke VPS.
2. Jalankan **`setup.bat`** (double-click atau lewat cmd). Script ini akan:
   - Membuat virtual environment `.venv`
   - Install semua dependency dari `requirements.txt`
   - Membuat file `.env` dari `.env.example` (kalau belum ada)
3. Edit file **`.env`**, minimal isi:
   - `MT5_LOGIN`, `MT5_PASSWORD`, `MT5_SERVER` — kosongkan kalau ingin
     memakai sesi terminal MT5 yang sudah login manual.
   - `ADMIN_PASSWORD` — wajib diisi, ini password untuk masuk ke `/admin`.
   - `SYMBOLS` — daftar simbol yang dipantau, pisahkan dengan koma
     (contoh: `XAUUSD,EURUSD`).
   - `BOT_STATUS_LOG_PATH`, `BOT_EVENTS_LOG_PATH`, `FAILED_ORDERS_LOG_PATH`,
     `BOT_COMMAND_LOG_PATH` — arahkan ke folder `Common\Files` terminal MT5
     (biasanya `C:\Users\<user>\AppData\Roaming\MetaQuotes\Terminal\Common\Files\`),
     supaya sama dengan lokasi yang dipakai EA (lihat input `InpEnableFileLogging`
     di EA).

## Auto running

Jalankan **`run.bat`** untuk start dashboard. Script ini otomatis restart
proses kalau crash (loop dengan delay 5 detik).

Untuk auto-start saat VPS reboot, ada dua opsi:

- **Windows Service (disarankan untuk produksi)**: download
  [NSSM](https://nssm.cc), taruh `nssm.exe` di folder project, lalu jalankan
  **`install_service.bat`** sebagai Administrator. Dashboard akan berjalan
  sebagai service Windows (`TradingDashboard`), auto-start saat boot, dan
  auto-restart kalau proses mati.
- **Task Scheduler**: buat task baru yang menjalankan `run.bat` saat sistem
  startup, run sebagai user yang sama dengan terminal MT5 (harus user yang
  sama supaya API `MetaTrader5` bisa attach ke terminal yang sedang login).

Setelah jalan, akses dashboard dari browser:

- Dashboard utama: `http://<ip-vps>:8000/`
- Panel admin: `http://<ip-vps>:8000/admin`

> Disarankan taruh di belakang reverse proxy (nginx/Caddy) dengan HTTPS kalau
> diakses dari luar VPS, karena login admin memakai cookie sesi biasa.

## Setup EA di MT5

1. Copy `ea/XAUUSD_scalper_M1.mq5` ke folder `MQL5/Experts/` terminal MT5,
   compile di MetaEditor.
2. Attach ke chart XAUUSD timeframe M1.
3. Pastikan **AlgoTrading** aktif (tombol di toolbar MT5) dan izin
   **Allow DLL imports** / **Allow file access** sesuai kebutuhan.
4. Set input `InpEnableFileLogging = true` dan pastikan path status/event/
   command yang ditulis EA sama dengan yang di-set di `.env` dashboard
   (default keduanya memakai folder `Common\Files`, jadi biasanya tidak perlu
   diubah).
5. `InpEnableRemoteControl = true` kalau ingin memakai tombol ganti mode
   trading (Default / 24 Jam Unlimited) dari panel admin.

Parameter risk (`InpRiskPercent`, `InpMaxDailyLossPercent`,
`InpMaxDailyProfitPercent`, `InpMaxOpenPositions`, dst) diatur langsung lewat
input EA di MT5 — dashboard hanya memonitor dan mengirim perintah ganti mode,
tidak mengubah parameter risk EA.

## Environment variable (`.env`)

| Variable | Default | Keterangan |
|---|---|---|
| `MT5_LOGIN` / `MT5_PASSWORD` / `MT5_SERVER` | kosong | Kosongkan untuk pakai sesi terminal yang sudah login manual |
| `SYMBOLS` | `XAUUSD` | Daftar simbol dipisah koma |
| `REFRESH_RATE_SECONDS` | `1` | Interval snapshot akun & push data admin |
| `HISTORY_DAYS` | `1` | Rentang history trade yang ditampilkan |
| `EQUITY_CURVE_MAX_POINTS` | `300` | Jumlah titik equity curve yang disimpan di memori |
| `HOST` / `PORT` | `0.0.0.0` / `8000` | Alamat bind server |
| `ADMIN_PASSWORD` | kosong (wajib diisi) | Password login `/admin` |
| `ADMIN_SECRET_KEY` | random tiap restart | Isi manual supaya sesi admin tidak logout tiap restart server |
| `ADMIN_SESSION_HOURS` | `12` | Lama sesi login admin |
| `FAILED_ORDERS_LOG_PATH` | `failed_orders.json` | File log kegagalan order dari EA |
| `BOT_STATUS_LOG_PATH` | `range_breakout_m1_status.json` | File status live EA |
| `BOT_EVENTS_LOG_PATH` | `range_breakout_m1_events.json` | File log event lifecycle EA |
| `BOT_COMMAND_LOG_PATH` | `bot_command.json` | File perintah ganti mode ke EA |
| `BOT_STATUS_STALE_AFTER_SEC` | `30` | Ambang EA dianggap "tidak merespons" |

## Endpoint

| Endpoint | Keterangan |
|---|---|
| `GET /` | Dashboard utama |
| `GET /health` | Health check JSON (status koneksi MT5, jumlah client) |
| `WS /ws/data` | Snapshot akun berkala + live candle (subscribe per symbol/timeframe) |
| `GET /admin/login`, `POST /admin/login` | Form & submit login admin |
| `POST /admin/logout` | Logout admin |
| `GET /admin` | Panel admin (butuh login) |
| `WS /ws/admin` | Data pending order/posisi/log EA berkala + kirim aksi (close, ganti mode) |

## Menjalankan di Linux (opsional, dev/testing saja)

Paket `MetaTrader5` resmi tidak berjalan di Linux/macOS karena membungkus API
terminal MT5 Windows. `setup.sh` / `run.sh` disediakan untuk testing
tampilan/behavior FastAPI di luar Windows — instalasi `MetaTrader5` di
`requirements.txt` kemungkinan besar akan gagal di Linux dan itu normal;
dashboard akan tetap bisa jalan tapi `mt5_connected` selalu `false`. Untuk
dashboard yang benar-benar terhubung ke akun trading, jalankan di VPS
Windows.

## Catatan keamanan

- Ganti `ADMIN_PASSWORD` dan set `ADMIN_SECRET_KEY` manual sebelum dipakai
  di produksi — jangan biarkan default kosong.
- Panel admin bisa menutup semua posisi dan mengubah mode trading EA; jangan
  expose port dashboard langsung ke internet tanpa proteksi tambahan
  (reverse proxy + HTTPS, firewall/IP allowlist, dsb).

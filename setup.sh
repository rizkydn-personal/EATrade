#!/usr/bin/env bash
# ============================================================================
# Auto setup untuk Linux/macOS - HANYA untuk development/testing frontend.
# Paket MetaTrader5 resmi hanya berjalan di Windows (membungkus terminal MT5
# Windows), jadi untuk dashboard yang benar-benar terhubung ke akun trading,
# pakai setup.bat di VPS Windows. Lihat README.md bagian "Menjalankan di
# Linux (opsional)" untuk detail.
# ============================================================================
set -e
cd "$(dirname "$0")"

echo "=== 1/3  Membuat virtual environment (.venv) ==="
if [ ! -d ".venv" ]; then
    python3 -m venv .venv
else
    echo ".venv sudah ada, dilewati."
fi

source .venv/bin/activate

echo "=== 2/3  Install dependency dari requirements.txt ==="
pip install --upgrade pip
pip install -r requirements.txt || echo "[WARN] Instalasi paket MetaTrader5 kemungkinan gagal di Linux - ini normal, lihat README.md."

echo "=== 3/3  Menyiapkan file .env ==="
if [ ! -f ".env" ]; then
    cp .env.example .env
    echo "File .env dibuat dari .env.example - SILAKAN EDIT ADMIN_PASSWORD dan MT5_LOGIN/PASSWORD/SERVER."
else
    echo ".env sudah ada, tidak ditimpa."
fi

echo
echo "Setup selesai. Jalankan ./run.sh untuk start dashboard."

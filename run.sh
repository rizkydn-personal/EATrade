#!/usr/bin/env bash
# ============================================================================
# Auto run - start dashboard dan otomatis restart kalau proses crash.
# ============================================================================
cd "$(dirname "$0")"

if [ ! -f ".venv/bin/activate" ]; then
    echo "[ERROR] .venv belum ada. Jalankan ./setup.sh terlebih dahulu."
    exit 1
fi

source .venv/bin/activate

while true; do
    echo "[$(date)] Starting dashboard..."
    python -m app.main
    echo "[$(date)] Dashboard berhenti/crash. Restart dalam 5 detik... (Ctrl+C untuk berhenti total)"
    sleep 5
done

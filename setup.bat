@echo off
REM ============================================================================
REM  Auto setup - VPS Algorithmic Trading Control Center
REM  Membuat virtual environment, install dependency, dan menyiapkan file .env.
REM  Jalankan sekali saja setelah clone/copy project ke VPS.
REM ============================================================================
setlocal enabledelayedexpansion
cd /d "%~dp0"

echo === 1/4  Mengecek Python ===
where python >nul 2>nul
if errorlevel 1 (
    echo [ERROR] Python tidak ditemukan di PATH. Install Python 3.10+ dari python.org lalu ulangi.
    pause
    exit /b 1
)

echo === 2/4  Membuat virtual environment (.venv) ===
if not exist ".venv" (
    python -m venv .venv
) else (
    echo .venv sudah ada, dilewati.
)

call ".venv\Scripts\activate.bat"

echo === 3/4  Install dependency dari requirements.txt ===
python -m pip install --upgrade pip
pip install -r requirements.txt

echo === 4/4  Menyiapkan file .env ===
if not exist ".env" (
    copy ".env.example" ".env" >nul
    echo File .env dibuat dari .env.example - SILAKAN EDIT ADMIN_PASSWORD dan MT5_LOGIN/PASSWORD/SERVER.
) else (
    echo .env sudah ada, tidak ditimpa.
)

echo.
echo ============================================================================
echo  Setup selesai.
echo  1. Edit file .env (isi MT5_LOGIN/PASSWORD/SERVER dan ADMIN_PASSWORD).
echo  2. Jalankan run.bat untuk start dashboard.
echo  3. (Opsional) Jalankan install_service.bat untuk auto-start saat VPS reboot.
echo ============================================================================
pause

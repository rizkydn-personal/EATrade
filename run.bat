@echo off
REM ============================================================================
REM  Auto run - VPS Algorithmic Trading Control Center
REM  Start dashboard dan otomatis restart kalau proses crash.
REM ============================================================================
cd /d "%~dp0"

if not exist ".venv\Scripts\activate.bat" (
    echo [ERROR] .venv belum ada. Jalankan setup.bat terlebih dahulu.
    pause
    exit /b 1
)

call ".venv\Scripts\activate.bat"

:loop
echo [%date% %time%] Starting dashboard...
python -m app.main
echo [%date% %time%] Dashboard berhenti/crash. Restart dalam 5 detik... (Ctrl+C untuk berhenti total)
timeout /t 5 >nul
goto loop

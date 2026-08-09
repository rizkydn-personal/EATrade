@echo off
REM ============================================================================
REM  (Opsional) Daftarkan dashboard sebagai Windows Service pakai NSSM, supaya
REM  otomatis start saat VPS reboot dan otomatis restart kalau proses mati.
REM  Download NSSM dari https://nssm.cc, taruh nssm.exe di folder project ini
REM  (atau pastikan nssm ada di PATH), lalu jalankan script ini as Administrator.
REM ============================================================================
setlocal
cd /d "%~dp0"
set SERVICE_NAME=TradingDashboard

where nssm >nul 2>nul
if errorlevel 1 (
    if not exist "nssm.exe" (
        echo [ERROR] nssm.exe tidak ditemukan. Download dari https://nssm.cc dan taruh di folder ini.
        pause
        exit /b 1
    )
    set NSSM=%~dp0nssm.exe
) else (
    set NSSM=nssm
)

echo Mendaftarkan service "%SERVICE_NAME%"...
%NSSM% install %SERVICE_NAME% "%~dp0.venv\Scripts\python.exe" "-m app.main"
%NSSM% set %SERVICE_NAME% AppDirectory "%~dp0"
%NSSM% set %SERVICE_NAME% AppStdout "%~dp0service.log"
%NSSM% set %SERVICE_NAME% AppStderr "%~dp0service.log"
%NSSM% set %SERVICE_NAME% Start SERVICE_AUTO_START
%NSSM% set %SERVICE_NAME% AppRestartDelay 5000

echo.
echo Service "%SERVICE_NAME%" terdaftar. Start sekarang dengan:
echo     nssm start %SERVICE_NAME%
echo Atau lewat Windows Services (services.msc).
pause

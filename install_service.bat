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

REM --- Hilangkan trailing backslash dari %~dp0 agar tidak merusak quoting NSSM ---
set "PROJECT_DIR=%~dp0"
if "%PROJECT_DIR:~-1%"=="\" set "PROJECT_DIR=%PROJECT_DIR:~0,-1%"

where nssm >nul 2>nul
if errorlevel 1 (
    if not exist "nssm.exe" (
        echo [ERROR] nssm.exe tidak ditemukan. Download dari https://nssm.cc dan taruh di folder ini.
        pause
        exit /b 1
    )
    set "NSSM=%PROJECT_DIR%\nssm.exe"
) else (
    set NSSM=nssm
)

echo Mendaftarkan service "%SERVICE_NAME%"...

REM Hapus dulu kalau sudah pernah terdaftar sebelumnya, biar bersih (opsional tapi aman)
%NSSM% status %SERVICE_NAME% >nul 2>nul
if not errorlevel 1 (
    echo Service "%SERVICE_NAME%" sudah ada, menghapus dulu sebelum daftar ulang...
    %NSSM% stop %SERVICE_NAME% >nul 2>nul
    %NSSM% remove %SERVICE_NAME% confirm >nul 2>nul
)

%NSSM% install %SERVICE_NAME% "%PROJECT_DIR%\.venv\Scripts\python.exe" "-m app.main"
%NSSM% set %SERVICE_NAME% AppDirectory "%PROJECT_DIR%"
%NSSM% set %SERVICE_NAME% AppStdout "%PROJECT_DIR%\service.log"
%NSSM% set %SERVICE_NAME% AppStderr "%PROJECT_DIR%\service.log"
%NSSM% set %SERVICE_NAME% Start SERVICE_AUTO_START
%NSSM% set %SERVICE_NAME% AppRestartDelay 5000

echo.
echo Verifikasi konfigurasi:
%NSSM% get %SERVICE_NAME% Application
%NSSM% get %SERVICE_NAME% AppDirectory

echo.
echo Service "%SERVICE_NAME%" terdaftar. Start sekarang dengan:
echo     nssm start %SERVICE_NAME%
echo Atau lewat Windows Services (services.msc).
pause

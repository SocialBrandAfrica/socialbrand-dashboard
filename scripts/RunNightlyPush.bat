@echo off
:: ============================================================
::  SocialBrand - Nightly Push
::  Scheduled at 20:00. If Push-SigmaToSupabase.ps1 is already
::  running, waits 60 minutes and tries once more (21:00).
::  Run on srsdelareyvilesvr. Safe to run daily after store close.
:: ============================================================

set SCRIPT=C:\socialbrand\Push-SigmaToSupabase.ps1
set LOGFILE=C:\socialbrand\nightly_push.log
set MAX_ATTEMPTS=2
set WAIT_MINUTES=60

echo.>> "%LOGFILE%"
echo ============================================================>> "%LOGFILE%"
echo Nightly push started: %date% %time%>> "%LOGFILE%"

set ATTEMPT=0

:TRY
set /a ATTEMPT+=1
echo Attempt %ATTEMPT% of %MAX_ATTEMPTS% at %time%>> "%LOGFILE%"

:: Check if Push-SigmaToSupabase.ps1 is already running
powershell.exe -NonInteractive -Command "exit (Get-Process powershell -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like '*Push-Sigma*' -or (Get-WmiObject Win32_Process -Filter \"ProcessId=$($_.Id)\" -ErrorAction SilentlyContinue).CommandLine -like '*Push-SigmaToSupabase*' }).Count"
if %errorlevel% GTR 0 (
    echo Already running. >> "%LOGFILE%"
    if %ATTEMPT% LSS %MAX_ATTEMPTS% (
        echo Waiting %WAIT_MINUTES% minutes before retry...>> "%LOGFILE%"
        echo Waiting %WAIT_MINUTES% minutes before retry...
        powershell.exe -NonInteractive -Command "Start-Sleep -Seconds %WAIT_MINUTES%*60"
        goto TRY
    ) else (
        echo Max attempts reached. Push skipped tonight.>> "%LOGFILE%"
        echo Max attempts reached. Push skipped tonight.
        goto END
    )
)

echo Running push...>> "%LOGFILE%"
powershell.exe -NonInteractive -ExecutionPolicy Bypass -File "%SCRIPT%" >> "%LOGFILE%" 2>&1
echo Push completed at %time% with exit code %errorlevel%>> "%LOGFILE%"

:END
echo ============================================================>> "%LOGFILE%"

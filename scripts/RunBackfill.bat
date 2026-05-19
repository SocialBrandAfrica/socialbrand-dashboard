@echo off
:: ============================================================
::  SocialBrand - ONE-TIME BACKFILL
::  Run this ONCE tonight after the store closes.
::  Wipes the wrong data and reloads everything from
::  the TAC zip files on the server.
::
::  Do NOT run this during trading hours.
::  Do NOT run this more than once.
::  After this, use RunNightlyPush.bat each evening.
:: ============================================================

echo.
echo ============================================================
echo   SocialBrand ONE-TIME BACKFILL
echo   %date%  %time%
echo   This will take several minutes.
echo ============================================================
echo.

powershell.exe -ExecutionPolicy Bypass -File "C:\socialbrand\Push-SigmaToSupabase.ps1" -Backfill -Force

echo.
echo ============================================================
echo   Done. Check output above for any errors.
echo   From now on use RunNightlyPush.bat each evening.
echo ============================================================
echo.
pause

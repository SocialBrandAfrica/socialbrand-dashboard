@echo off
:: ============================================================
::  SocialBrand - Nightly Push
::  Run this each evening after the store closes.
::  Reads tonight's TAC zip and updates the dashboard.
:: ============================================================

echo.
echo ============================================================
echo   SocialBrand Nightly Push
echo   %date%  %time%
echo ============================================================
echo.

powershell.exe -ExecutionPolicy Bypass -File "C:\socialbrand\Push-SigmaToSupabase.ps1"

echo.
echo ============================================================
echo   Done. Check output above for any errors.
echo ============================================================
echo.
pause

@echo off
:: ============================================================
::  SocialBrand - Sigma Folder Scanner
::  Run this on a store server to identify database files,
::  config files, and 3rd party software.
::  Output: C:\socialbrand\sigma_scan_report.txt
:: ============================================================

set REPORT=C:\socialbrand\sigma_scan_report.txt
if not exist C:\socialbrand mkdir C:\socialbrand
set SCAN_ROOT=S:\sigma

echo SocialBrand Sigma Scan > "%REPORT%"
echo Run date: %date% %time% >> "%REPORT%"
echo Server: %COMPUTERNAME% >> "%REPORT%"
echo Scanning: %SCAN_ROOT% >> "%REPORT%"
echo. >> "%REPORT%"

echo ============================================================ >> "%REPORT%"
echo DATABASE FILES (.mdb .db .sdf .fdb .mdf .dbf .sqlite .gdb) >> "%REPORT%"
echo ============================================================ >> "%REPORT%"
dir /s /b "%SCAN_ROOT%\*.mdb" "%SCAN_ROOT%\*.db" "%SCAN_ROOT%\*.sdf" "%SCAN_ROOT%\*.fdb" "%SCAN_ROOT%\*.mdf" "%SCAN_ROOT%\*.dbf" "%SCAN_ROOT%\*.sqlite" "%SCAN_ROOT%\*.gdb" 2>nul >> "%REPORT%"
echo. >> "%REPORT%"

echo ============================================================ >> "%REPORT%"
echo EXECUTABLES (.exe) - identifies 3rd party software >> "%REPORT%"
echo ============================================================ >> "%REPORT%"
dir /s /b "%SCAN_ROOT%\*.exe" 2>nul >> "%REPORT%"
echo. >> "%REPORT%"

echo ============================================================ >> "%REPORT%"
echo CONFIG FILES (.ini .cfg .config .xml .json) >> "%REPORT%"
echo ============================================================ >> "%REPORT%"
dir /s /b "%SCAN_ROOT%\*.ini" "%SCAN_ROOT%\*.cfg" "%SCAN_ROOT%\*.config" "%SCAN_ROOT%\*.xml" "%SCAN_ROOT%\*.json" 2>nul >> "%REPORT%"
echo. >> "%REPORT%"

echo ============================================================ >> "%REPORT%"
echo TOP-LEVEL FOLDER STRUCTURE >> "%REPORT%"
echo ============================================================ >> "%REPORT%"
dir /ad "%SCAN_ROOT%\" 2>nul >> "%REPORT%"
echo. >> "%REPORT%"

echo ============================================================ >> "%REPORT%"
echo COMMS FOLDER CONTENTS (where TAC zips live) >> "%REPORT%"
echo ============================================================ >> "%REPORT%"
dir /s "%SCAN_ROOT%\comms\" 2>nul >> "%REPORT%"
echo. >> "%REPORT%"

echo ============================================================ >> "%REPORT%"
echo WINDOWS SERVICES (Sigma or database related) >> "%REPORT%"
echo ============================================================ >> "%REPORT%"
sc query type= all state= all 2>nul | findstr /i "sigma sql firebird mysql postgres interbase" >> "%REPORT%"
echo. >> "%REPORT%"

echo ============================================================ >> "%REPORT%"
echo INSTALLED PROGRAMS (Sigma or database related) >> "%REPORT%"
echo ============================================================ >> "%REPORT%"
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall" /s 2>nul | findstr /i "DisplayName sigma sql firebird mysql catman" >> "%REPORT%"
reg query "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" /s 2>nul | findstr /i "DisplayName sigma sql firebird mysql catman" >> "%REPORT%"
echo. >> "%REPORT%"

echo Done!
echo.
echo Report saved to: %REPORT%
echo.
echo Please share C:\socialbrand\sigma_scan_report.txt with SocialBrand support.
pause

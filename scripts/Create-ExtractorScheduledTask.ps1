#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Creates (or replaces) the nightly sigma extractor delta task on this server.

.DESCRIPTION
    Registers a Windows Scheduled Task that runs Invoke-ExtractFromSigmaSQL.ps1
    in delta mode (no flags) every day at 18:40 SAST.

    Schedule: 18:40 -- BEFORE the 19:00 store close (Pieter ruling 2026-06-12:
    pre-EOD means before close; staff can start Sigma EOD any time after 19:00,
    and on 2026-06-11 the EOD lock held dw220sdb from ~20:01 to past 21:54 on
    4/5 stores -- the old 19:40 slot fired into that risk window). A delta run
    takes 5-10 min, so it ends ~18:50, clear of the close AND the EASYDB
    rebuild (~19:20). The last ~20 min of trading is recovered by the nightly
    sweep's 3-day delta overlap. sigma_ean_master read at 18:40 reflects the
    previous EASYDB rebuild; the post-rebuild sweep run refreshes it.

    Run this script once per server after the full-refresh has been verified
    (ROLLOUT-001 Gate 1-4). Run as Administrator.

.PARAMETER ScriptDir
    Folder where Invoke-ExtractFromSigmaSQL.ps1 lives.
    Defaults to C:\SocialBrand.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File ".\Create-ExtractorScheduledTask.ps1"
#>
param(
    [string]$ScriptDir = 'C:\SocialBrand'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# SB-CC-PUSH-HARDEN-001 (2026-07-14): must match Invoke-ExtractFromSigmaSQL.ps1's
# own $taskName exactly -- that script's self-heal logic re-registers under
# whatever name is hardcoded there if it ever finds the task missing/unhealthy.
# A mismatch here would bootstrap under one name while self-heal expects another.
$TaskName   = 'WindowsDataSync-SB_Daily'
$ScriptPath = Join-Path $ScriptDir 'Invoke-ExtractFromSigmaSQL.ps1'
$ExeArgs    = '-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File "' + $ScriptPath + '"'
# Absolute path to powershell.exe -- bare 'powershell.exe' fails on servers where
# System32\WindowsPowerShell is missing from the system PATH (observed on 80175
# and 21355: "The term 'powershell.exe' is not recognized"). The absolute path
# works regardless of PATH state.
$PsExePath  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

Write-Host "=== Create-ExtractorScheduledTask ===" -ForegroundColor Cyan
Write-Host "Server  : $env:COMPUTERNAME"
Write-Host "Script  : $ScriptPath"
Write-Host "Task    : $TaskName"
Write-Host "Trigger : daily 18:40"
Write-Host ""

if (-not (Test-Path $ScriptPath)) {
    Write-Error "Extractor not found at $ScriptPath -- deploy it first (push v3.19 runs tonight, or copy manually from GitHub raw)."
    exit 1
}

# Remove existing task if present (clean replace)
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Write-Host "Removing existing task '$TaskName'..." -ForegroundColor Yellow
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$trigger = New-ScheduledTaskTrigger -Daily -At '18:40'
$action  = New-ScheduledTaskAction -Execute $PsExePath -Argument $ExeArgs -WorkingDirectory $ScriptDir
# ExecutionTimeLimit 4h is ample: a delta run is 5-10 min and the dw220sdb retry
# is a short bounded ~10 min. (The 23:30 poll-to-cutoff was descoped 2026-06-17.)
$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Hours 4) `
    -StartWhenAvailable `
    -WakeToRun:$false

Register-ScheduledTask `
    -TaskName $TaskName `
    -Trigger  $trigger `
    -Action   $action `
    -Settings $settings `
    -RunLevel  Highest `
    -Force | Out-Null

Write-Host "Task registered." -ForegroundColor Green

# Verify
$task = Get-ScheduledTask -TaskName $TaskName
Write-Host "State   : $($task.State)"
Write-Host "Trigger : $($task.Triggers[0].StartBoundary)"
Write-Host ""
Write-Host "Run manually to verify:" -ForegroundColor Cyan
Write-Host "  Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "  -- or --"
Write-Host "  cd $ScriptDir"
Write-Host "  .\Invoke-ExtractFromSigmaSQL.ps1"

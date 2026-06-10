#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Creates (or replaces) the Sunday early-push scheduled task on this server.

.DESCRIPTION
    On Sundays the stores close earlier. TAC zip files (PRSSALE) are consistently
    ready by ~15:30 SAST (observed across 4 Sundays: 15:23, 15:28, 15:30, 15:34).
    Weekday zips are ready at ~19:20-19:40.

    This task fires every Sunday at 16:15 -- 45 minutes after the latest observed
    Sunday zip time -- so Sunday data hits the dashboard ~3.5 hours earlier than
    the weekday 20:00 push.

    The existing "SocialBrand Nightly Push" task (20:00 daily) still runs on Sunday
    and will log NO_NEW_DATA, which is correct and expected.

    Run as Administrator once on each server. Safe to re-run.

.PARAMETER ScriptDir
    Folder where Push-SigmaToSupabase.ps1 lives. Defaults to C:\SocialBrand.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File ".\Create-SundayPushTask.ps1"
#>
param(
    [string]$ScriptDir = 'C:\SocialBrand'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TaskName   = 'SocialBrand Sunday Push'
$ScriptPath = Join-Path $ScriptDir 'Push-SigmaToSupabase.ps1'
$ExeArgs    = '-WindowStyle Hidden -ExecutionPolicy Bypass -NonInteractive -File "' + $ScriptPath + '"'
# Absolute path to powershell.exe -- bare 'powershell.exe' fails on servers where
# System32\WindowsPowerShell is missing from the system PATH (observed on 80175
# and 21355).
$PsExePath  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

Write-Host "=== Create-SundayPushTask ===" -ForegroundColor Cyan
Write-Host "Server  : $env:COMPUTERNAME"
Write-Host "Script  : $ScriptPath"
Write-Host "Task    : $TaskName"
Write-Host "Trigger : every Sunday at 16:15"
Write-Host ""

if (-not (Test-Path $ScriptPath)) {
    Write-Error "Push script not found at $ScriptPath"
    exit 1
}

# Remove existing task if present (clean replace)
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Write-Host "Removing existing task '$TaskName'..." -ForegroundColor Yellow
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

# Weekly trigger: Sundays only at 16:15
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '16:15'
$action  = New-ScheduledTaskAction -Execute $PsExePath -Argument $ExeArgs -WorkingDirectory $ScriptDir
$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
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
Write-Host "Trigger : $($task.Triggers[0].StartBoundary) (weekly, Sunday)"
Write-Host ""
Write-Host "Why 16:15:" -ForegroundColor DarkGray
Write-Host "  Sunday TAC zips observed ready at 15:23 / 15:28 / 15:30 / 15:34 SAST." -ForegroundColor DarkGray
Write-Host "  16:15 gives a 45-min buffer. Weekday 20:00 task still runs (NO_NEW_DATA = correct)." -ForegroundColor DarkGray
Write-Host ""
Write-Host "Run today manually if needed:" -ForegroundColor Cyan
Write-Host "  cd $ScriptDir"
Write-Host "  .\Push-SigmaToSupabase.ps1"

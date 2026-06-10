#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Creates (or replaces) the nightly sigma extractor delta task on this server.

.DESCRIPTION
    Registers a Windows Scheduled Task that runs Invoke-ExtractFromSigmaSQL.ps1
    in delta mode (no flags) every night at 19:40 SAST.

    Schedule: 19:40 -- after EASYDB rebuild (~19:20, ~15 min) and before the
    nightly push at 20:00.  Delta runs are fast (minutes, not hours).

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

$TaskName   = 'SocialBrand-ExtractDelta'
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
Write-Host "Trigger : daily 19:40"
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

$trigger = New-ScheduledTaskTrigger -Daily -At '19:40'
$action  = New-ScheduledTaskAction -Execute $PsExePath -Argument $ExeArgs -WorkingDirectory $ScriptDir
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

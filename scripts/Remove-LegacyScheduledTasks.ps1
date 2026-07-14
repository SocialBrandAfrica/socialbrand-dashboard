#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Removes scheduled tasks left over from a retired legacy push mechanism,
    now that a newer data source is in place (retirement history in canon,
    2026-06-28).

.DESCRIPTION
    Removes these two tasks on this server:
        "SocialBrand Nightly Push"  -- Push-SigmaToSupabase.ps1 at 20:00 daily
        "SocialBrand Sunday Push"   -- Push-SigmaToSupabase.ps1 at 16:15 Sunday

    Also removes any other scheduled task whose action references Push-SigmaToSupabase.ps1
    (belt-and-suspenders in case the task was registered under a different name).

    Keeps:
        "WindowsDataSync-SB_Daily"  -- Invoke-ExtractFromSigmaSQL.ps1 at 18:40
        This is the sigma-native extractor; it must continue running every day.
        (Renamed from "SocialBrand-ExtractDelta" 2026-07-14, SB-CC-PUSH-HARDEN-001.)

    Safe to run multiple times. Reports what it found and removed.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File ".\Remove-LegacyScheduledTasks.ps1"
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$KeeperTask   = 'WindowsDataSync-SB_Daily'
$RemoveByName = @('SocialBrand Nightly Push', 'SocialBrand Sunday Push')

Write-Host ""
Write-Host "=== Remove-LegacyScheduledTasks ===" -ForegroundColor Cyan
Write-Host "Server : $env:COMPUTERNAME"
Write-Host "Date   : $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
Write-Host "Reason : retired legacy push mechanism, newer data source now in place"
Write-Host ""

$removed = 0
$skipped = 0

# --- Remove by known name ---
foreach ($name in $RemoveByName) {
    $t = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if ($t) {
        Write-Host "  [REMOVE] '$name'  (State: $($t.State))" -ForegroundColor Yellow
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
        Write-Host "           Removed." -ForegroundColor Green
        $removed++
    }
    else {
        Write-Host "  [SKIP]   '$name' not found on this server." -ForegroundColor DarkGray
        $skipped++
    }
}

# --- Belt-and-suspenders: any task referencing Push-SigmaToSupabase.ps1 ---
Write-Host ""
Write-Host "  Scanning all tasks for Push-SigmaToSupabase.ps1 references..."
$allTasks = Get-ScheduledTask -ErrorAction SilentlyContinue
foreach ($t in $allTasks) {
    if ($RemoveByName -contains $t.TaskName) { continue }   # already handled above
    if ($t.TaskName -eq $KeeperTask)         { continue }   # never touch the keeper
    $actions = $t.Actions | Where-Object { $_ -is [CimInstance] }
    foreach ($a in $actions) {
        $argStr = try { $a.Arguments } catch { '' }
        if ($argStr -match 'Push-SigmaToSupabase') {
            Write-Host "  [REMOVE] '$($t.TaskName)'  (matched Push-SigmaToSupabase.ps1 in args)" -ForegroundColor Yellow
            Unregister-ScheduledTask -TaskName $t.TaskName -Confirm:$false
            Write-Host "           Removed." -ForegroundColor Green
            $removed++
        }
    }
}

# --- Verify the keeper is present ---
Write-Host ""
$keeper = Get-ScheduledTask -TaskName $KeeperTask -ErrorAction SilentlyContinue
if ($keeper) {
    $trigger = try { $keeper.Triggers[0].StartBoundary } catch { 'unknown' }
    Write-Host "  [OK]  '$KeeperTask' is present.  State: $($keeper.State)  Trigger: $trigger" -ForegroundColor Green
}
else {
    Write-Host "  [WARN] '$KeeperTask' NOT FOUND on this server." -ForegroundColor Red
    Write-Host "         The sigma-native extractor will not run at 18:40." -ForegroundColor Red
    Write-Host "         Fix: run Invoke-ExtractFromSigmaSQL.ps1 once manually -- it self-registers the task." -ForegroundColor Yellow
}

# --- Summary ---
Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host "  Tasks removed : $removed"
Write-Host "  Not found     : $skipped"
Write-Host ""
Write-Host "  Push-SigmaToSupabase.ps1 is still at C:\socialbrand\ but will no longer run." -ForegroundColor DarkGray
Write-Host "  daily_snapshots table is retained in Supabase for historical reference." -ForegroundColor DarkGray
Write-Host ""

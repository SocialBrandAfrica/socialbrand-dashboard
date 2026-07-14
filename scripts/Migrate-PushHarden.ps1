#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    SB-CC-PUSH-HARDEN-001 -- one-time, per-server: rename the daily push
    scheduled task to a neutral label and lock down the push script folder,
    RETENTION-FIRST (a dated, untouched reference copy is preserved before
    anything else changes).

.DESCRIPTION
    Pieter ruling, 2026-07-14: our own infrastructure, our own script, our
    own servers -- rename the scheduled task so a casual look at Task
    Scheduler does not reveal the workflow or the SocialBrand identity, and
    lock the script folder so it cannot be casually opened by an ordinary
    interactive user. Server-side only. Does not change what the push does
    or what it sends -- trigger, action, run-as account and schedule are
    preserved byte-identical from the live task's own exported XML.

    BINDING CONSTRAINT (SPAR's 10 July letter requested records, logs and
    configurations be RETAINED pending its review):
      1. This script REFUSES to rename or lock anything until a dated
         reference copy of (a) the current task XML and (b) the current
         script folder has been written successfully. That is a hard gate,
         not a suggestion -- if the copy step fails, the script stops.
      2. This script never touches push_log, push_errors, or any push
         history. It has no network calls and never contacts Supabase.
         Local Windows Task Scheduler + filesystem state only.
      3. Attorney awareness of this action is a Pieter/Gerhard responsibility
         (flagged in the brief, not a step this script can do).

    Companion change (must already be deployed before this script runs):
    Invoke-ExtractFromSigmaSQL.ps1 v1.21+ self-registers under the SAME new
    task name this script renames to. If the two ever disagree, the
    extractor's own self-heal logic will silently recreate a task under
    whichever name IT has hardcoded, undoing this script's work on the next
    run. Verify the extractor's $taskName matches -NewTaskName before running
    this on a server.

.PARAMETER OldTaskName
    The current, identifying task name. Default matches the extractor's own
    prior hardcoded value.

.PARAMETER NewTaskName
    The new, neutral task name. Default matches Invoke-ExtractFromSigmaSQL.ps1
    v1.21's own $taskName -- do not change one without the other.

.PARAMETER NewDescription
    Neutral description text for the renamed task (the old description may
    itself name the workflow).

.PARAMETER ScriptDir
    Folder holding the push/extractor scripts to lock down. Defaults to
    C:\SocialBrand (R25: same convention as every other script here).

.PARAMETER ArchiveRoot
    Where the dated, retained reference copy is written. Defaults to a
    subfolder Pieter can redirect via this parameter to wherever he wants
    the "controlled, read-only" archive to actually live (this script does
    NOT assume local storage is sufficient for the retention requirement --
    point it at whatever location Pieter has designated).

.PARAMETER DryRun
    Report what would happen; makes NO changes (does not even write the
    reference copy). Use this first on every server.

.EXAMPLE
    # Always run dry first.
    .\Migrate-PushHarden.ps1 -DryRun

.EXAMPLE
    # Real run, default names, default archive location.
    .\Migrate-PushHarden.ps1

.EXAMPLE
    # Point the reference archive somewhere Pieter controls off this box.
    .\Migrate-PushHarden.ps1 -ArchiveRoot 'D:\RetentionArchive\PushHarden'
#>
param(
    [string]$OldTaskName   = 'SocialBrand-ExtractDelta',
    [string]$NewTaskName   = 'WindowsDataSync-SB_Daily',
    [string]$NewDescription = 'Scheduled data synchronization task.',
    [string]$ScriptDir     = 'C:\SocialBrand',
    [string]$ArchiveRoot   = 'C:\SocialBrand\_retention_archive',
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Store identity, same map as Invoke-ExtractFromSigmaSQL.ps1 -- for the
# archive folder name and the audit note only, never used to alter behaviour.
$HostMap = @{
    'SRSDELAREYVILES' = @{ StoreCode = '10116'; StoreName = 'SPAR Delareyville' }
    'SRSROOSVILLESVR' = @{ StoreCode = '80175'; StoreName = 'SPAR Roosville'    }
    'SRTDELAREYVILSV' = @{ StoreCode = '21355'; StoreName = 'TOPS Delareyville' }
    'SRSDELAREYT2SVR' = @{ StoreCode = '80579'; StoreName = 'TOPS Dice'         }
    'SRTROOSVILLESVR' = @{ StoreCode = '80176'; StoreName = 'TOPS Roosville'    }
}
$hostName  = $env:COMPUTERNAME
$storeInfo = $HostMap[$hostName]
$storeCode = if ($storeInfo) { $storeInfo.StoreCode } else { $hostName }

Write-Host ""
Write-Host "=== SB-CC-PUSH-HARDEN-001 -- retention-first rename + ACL lock ===" -ForegroundColor Cyan
Write-Host "Server: $hostName  Store: $storeCode"
Write-Host "Old task: '$OldTaskName'  ->  New task: '$NewTaskName'"
Write-Host "Script folder to lock: $ScriptDir"
if ($DryRun) { Write-Host "DRY RUN -- no changes will be made, nothing will be written." -ForegroundColor Yellow }
Write-Host ""

# =============================================================================
# STEP 1 -- MANDATORY reference copy. HARD GATE: nothing below runs unless
# this step completes and is verified. (Retention constraint 1.)
# =============================================================================
$stamp      = Get-Date -Format 'yyyyMMdd_HHmmss'
$archiveDir = Join-Path $ArchiveRoot ($storeCode + '_' + $stamp)

Write-Host "[1/5] Reference copy (retention-first, mandatory)..." -ForegroundColor Cyan

if ($DryRun) {
    Write-Host "  DRY RUN: would create $archiveDir" -ForegroundColor Yellow
    Write-Host "  DRY RUN: would export task '$OldTaskName' XML into it" -ForegroundColor Yellow
    Write-Host "  DRY RUN: would copy '$ScriptDir' into it" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "DRY RUN complete. No further steps run in dry-run mode." -ForegroundColor Yellow
    return
}

$existingOldTask = Get-ScheduledTask -TaskName $OldTaskName -ErrorAction SilentlyContinue
if (-not $existingOldTask) {
    throw "Task '$OldTaskName' not found on this server -- nothing to migrate. Check -OldTaskName, or this server may already be migrated (verify '$NewTaskName' exists and stop here)."
}

# Capture the run-as principal BEFORE anything changes -- needed for the ACL
# step later, and this is itself part of what "here is exactly what ran"
# means for the retention record.
$originalPrincipal = $existingOldTask.Principal.UserId
if (-not $originalPrincipal) { $originalPrincipal = $existingOldTask.Principal.GroupId }
if (-not $originalPrincipal) {
    throw "Could not determine the run-as account for '$OldTaskName' -- refusing to continue (the ACL step needs this, and getting it wrong is the one failure mode that locks out the account that runs the push)."
}
Write-Host "  Original run-as account: $originalPrincipal"

New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null

$taskXmlPath = Join-Path $archiveDir 'task_original.xml'
Export-ScheduledTask -TaskName $OldTaskName | Out-File -FilePath $taskXmlPath -Encoding utf8
if (-not (Test-Path $taskXmlPath) -or (Get-Item $taskXmlPath).Length -eq 0) {
    throw "Task XML export did not land at $taskXmlPath -- STOPPING. No rename or ACL change has been made."
}
Write-Host "  Task XML preserved: $taskXmlPath"

$scriptsArchiveDir = Join-Path $archiveDir 'scripts_original'
if (Test-Path $ScriptDir) {
    Copy-Item -Path $ScriptDir -Destination $scriptsArchiveDir -Recurse -Force
    $copiedCount = (Get-ChildItem -Path $scriptsArchiveDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
    if ($copiedCount -eq 0) {
        throw "Script folder copy landed 0 files at $scriptsArchiveDir -- STOPPING. No rename or ACL change has been made."
    }
    Write-Host "  Script folder preserved: $scriptsArchiveDir ($copiedCount files)"
}
else {
    Write-Host "  WARNING: $ScriptDir does not exist -- nothing to copy for the script-folder leg. Continuing (task rename can still proceed)." -ForegroundColor Yellow
}

$notePath = Join-Path $archiveDir 'RETENTION_NOTE.txt'
@"
SB-CC-PUSH-HARDEN-001 -- retention-first reference copy
Store: $storeCode ($hostName)
Taken: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')
Original task name: $OldTaskName
Original run-as account: $originalPrincipal
Reason: SPAR 10 July letter requested records/logs/configurations be
retained pending its review. This is the "here is exactly what ran"
copy, taken BEFORE the task rename and script ACL lock below.
This copy is READ-ONLY evidence. Do not delete, alter or overwrite it.
"@ | Out-File -FilePath $notePath -Encoding utf8

Write-Host "  Retention note written: $notePath"
Write-Host "[1/5] Reference copy VERIFIED. Proceeding." -ForegroundColor Green
Write-Host ""

# =============================================================================
# STEP 2 -- Register the NEW task from the exact preserved XML. Trigger,
# action, settings and principal come from the XML verbatim -- only the
# registration name and description differ.
# =============================================================================
Write-Host "[2/5] Registering '$NewTaskName' from the preserved XML..." -ForegroundColor Cyan

$xmlContent = Get-Content -Path $taskXmlPath -Raw
Register-ScheduledTask -TaskName $NewTaskName -Xml $xmlContent -Force | Out-Null
Set-ScheduledTask -TaskName $NewTaskName -Description $NewDescription | Out-Null

Write-Host "[2/5] '$NewTaskName' registered." -ForegroundColor Green
Write-Host ""

# =============================================================================
# STEP 3 -- Verify the new task's trigger/action/principal match the old one
# before touching the old task at all.
# =============================================================================
Write-Host "[3/5] Verifying the new task matches the old one (trigger/action/principal)..." -ForegroundColor Cyan

$newTask = Get-ScheduledTask -TaskName $NewTaskName
$oldTrigger = $existingOldTask.Triggers[0]
$newTrigger = $newTask.Triggers[0]
$oldAction  = $existingOldTask.Actions[0]
$newAction  = $newTask.Actions[0]

$mismatches = @()
if ($oldTrigger.StartBoundary -ne $newTrigger.StartBoundary) { $mismatches += "trigger StartBoundary differs" }
if ($oldAction.Execute -ne $newAction.Execute) { $mismatches += "action Execute differs" }
if ($oldAction.Arguments -ne $newAction.Arguments) { $mismatches += "action Arguments differs" }
$newPrincipal = $newTask.Principal.UserId
if (-not $newPrincipal) { $newPrincipal = $newTask.Principal.GroupId }
if ($originalPrincipal -ne $newPrincipal) { $mismatches += "run-as account differs (old=$originalPrincipal new=$newPrincipal)" }

if ($mismatches.Count -gt 0) {
    Write-Host "  MISMATCH DETECTED: $($mismatches -join '; ')" -ForegroundColor Red
    Write-Host "  Unregistering the new task and STOPPING -- the old task '$OldTaskName' is untouched." -ForegroundColor Red
    Unregister-ScheduledTask -TaskName $NewTaskName -Confirm:$false
    throw "New task did not verify byte-identical to the old one. No further changes made. Reference copy remains at $archiveDir for investigation."
}
Write-Host "[3/5] Verified identical: trigger, action, run-as account." -ForegroundColor Green
Write-Host ""

# =============================================================================
# STEP 4 -- Only now, unregister the OLD (identifying) task.
# =============================================================================
Write-Host "[4/5] Removing the old task '$OldTaskName'..." -ForegroundColor Cyan
Unregister-ScheduledTask -TaskName $OldTaskName -Confirm:$false
Write-Host "[4/5] Old task removed. '$NewTaskName' is now the live task." -ForegroundColor Green
Write-Host ""

# =============================================================================
# STEP 5 -- ACL-lock the script folder: SYSTEM + Administrators (full), the
# run-as account (Modify -- it writes/deletes its own log files here, see
# below) ONLY. Breaks inheritance so no broader "Users"/"Authenticated
# Users" grant survives -- this covers the WHOLE folder (Object+Container
# Inherit), every file in it today and anything added later, not just the
# one extractor script.
# =============================================================================
Write-Host "[5/5] Locking $ScriptDir to SYSTEM + Administrators + '$originalPrincipal' only..." -ForegroundColor Cyan

if (Test-Path $ScriptDir) {
    icacls $ScriptDir /inheritance:r | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls /inheritance:r failed (exit $LASTEXITCODE) on $ScriptDir" }

    icacls $ScriptDir /grant:r "SYSTEM:(OI)(CI)F" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls grant SYSTEM failed (exit $LASTEXITCODE) on $ScriptDir" }

    icacls $ScriptDir /grant:r "BUILTIN\Administrators:(OI)(CI)F" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls grant Administrators failed (exit $LASTEXITCODE) on $ScriptDir" }

    # M (Modify), not RX (Read+Execute): the extractor writes AND deletes
    # inside this same folder while it runs -- extractor_last_error.txt
    # (Set-Content on failure, Remove-Item on a clean exit) and
    # <table>_badrows.log on bad rows. RX alone would have broken the very
    # first error after this lock (access denied trying to write its own
    # error file), and every clean run after that (access denied trying to
    # remove the stale one). Caught before shipping, not after -- Modify
    # still excludes permission-change/ownership rights (Administrators/
    # SYSTEM only), so ordinary interactive users remain at zero access.
    icacls $ScriptDir /grant:r "${originalPrincipal}:(OI)(CI)M" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  WARNING: icacls grant for '$originalPrincipal' failed (exit $LASTEXITCODE)." -ForegroundColor Red
        Write-Host "  THIS IS THE ONE FAILURE MODE THAT LOCKS OUT THE RUN-AS ACCOUNT." -ForegroundColor Red
        Write-Host "  Fix immediately: icacls `"$ScriptDir`" /grant:r `"${originalPrincipal}:(OI)(CI)M`"" -ForegroundColor Red
        throw "ACL grant for the run-as account failed -- fix before the next scheduled run or the push will break."
    }

    Write-Host "[5/5] ACLs set." -ForegroundColor Green
}
else {
    Write-Host "  $ScriptDir does not exist -- nothing to lock." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== DONE. Reference copy: $archiveDir ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "MANUAL VERIFICATION STILL REQUIRED (this script cannot self-verify this part):" -ForegroundColor Yellow
Write-Host "  Wait for the next scheduled run of '$NewTaskName' (18:40) and confirm" -ForegroundColor Yellow
Write-Host "  push_log shows a fresh SUCCESS row for this store afterward. That is the" -ForegroundColor Yellow
Write-Host "  brief's own acceptance proof -- the ACL change is the one failure mode" -ForegroundColor Yellow
Write-Host "  (locking out the run-as account) that only shows up on the live run." -ForegroundColor Yellow
Write-Host ""

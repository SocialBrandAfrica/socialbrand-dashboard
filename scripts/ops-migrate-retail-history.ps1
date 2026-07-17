#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    SB-CC-PUSH-HARDEN-001 -- THE single per-server migration. Supersedes
    Migrate-PushHarden.ps1 and the three ops-* scripts (ops-unbrand-extract-task,
    ops-debrand-folder, ops-protect-push-folder), which are hard-blocked.

    Sequence (PM-approved, counsel-cleared 2026-07-14):
      preconditions -> retention export -> rename task -> move folder ->
      repoint task -> lock the FINAL folder with the ACTUAL run-as account ->
      STOP for human verification -> (separate -Finalize run) delete old.

.DESCRIPTION
    Why one script and not four: the three ops-* scripts each did one step
    correctly in isolation and broke each other in combination --

      1. SELF-HEAL RESURRECTION. Invoke-ExtractFromSigmaSQL.ps1 calls
         Register-ExtractDeltaTask at STARTUP on every full-chain run. It
         re-registers the task under whatever name is hardcoded in THAT
         deployed copy. Renaming the live task while an older extractor is
         deployed means the next 18:40 run recreates the old branded task --
         two tasks, double extraction nightly, brand back in Task Scheduler,
         silently, within 24 hours. THIS SCRIPT HARD-GATES ON THE DEPLOYED
         EXTRACTOR ALREADY CARRYING THE NEW NAME (precondition 4).

      2. ACL/MOVE ORDER DEADLOCK. Locking C:\SocialBrand then copying it to
         C:\RetailHistory loses the lock (Copy-Item does not carry the source
         ACL; the copy inherits from C:\ root, where Users can read). Copying
         first then locking C:\SocialBrand locks the stale fallback and leaves
         the live folder open. Either order fails. THIS SCRIPT LOCKS THE FINAL
         FOLDER, AFTER THE MOVE.

      3. ASSUMED PRINCIPAL. Granting only SYSTEM + Administrators assumes the
         task runs as an admin. The extractor's own v1.18 logic falls back to
         registering Limited/non-elevated when RunLevel Highest is denied --
         that fallback has fired before. If it did, an assumed-admin lock locks
         out the account that runs the feed and the store goes dark silently.
         THIS SCRIPT READS THE PRINCIPAL OFF THE LIVE TASK AND GRANTS IT
         EXPLICITLY (Modify, not Read+Execute -- the extractor writes
         extractor_last_error.txt / *_badrows.log into its own folder and
         deletes the error file on a clean exit).

    NOTHING IS DESTROYED BY THIS SCRIPT. It copies, never moves. The old task
    and old folder both survive until you run -Finalize, and -Finalize only
    runs after YOU have confirmed a real 18:40 feed landed in push_log.

    THE END STATE (Pieter's design, 2026-07-14):
      C:\RetailHistory  = the MACHINERY. Extractor, key, logs. ACL-locked to
                          SYSTEM + Administrators + the real run-as account.
                          Neutral name -- nothing here says what it is.
      C:\SocialBrand    = KEPT, as the genuine Sigma export folder. CSV/Excel
                          only. Load-bearing for nothing. Not locked -- an
                          export folder reveals nothing either way.
      The brand name ends up on the one folder where it means nothing, and
      every trace of how the platform actually works moves off under a
      neutral name. -Finalize therefore strips the MACHINERY out of
      C:\SocialBrand and LEAVES the folder and its exports intact -- it is
      NOT a folder delete. sb-key.txt (the Supabase service_role key) is on
      that strip list and is the most important item on it: the export folder
      is not ACL-locked, so a key left behind there would hand out full DB
      access and defeat this whole exercise.

.PARAMETER OldTaskName
    The branded task currently on the server.

.PARAMETER NewTaskName
    Pieter's ruling, 2026-07-14: 'Retail History'. Must match the deployed
    extractor's own hardcoded $taskName (v1.23+) or this script refuses.

.PARAMETER OldDir
    Current script folder. Default C:\SocialBrand.

.PARAMETER NewDir
    De-branded target. Default C:\RetailHistory.

.PARAMETER RetainDir
    Retention export target. Default C:\SB-retain (matches the record memo).

.PARAMETER Finalize
    SECOND run, after verification: deletes the old TASK, and strips the
    MACHINERY (extractor, sb-key.txt, logs) out of the old folder -- the
    folder itself and its CSV/Excel exports are KEPT (see THE END STATE
    above). Never removes a machinery file whose counterpart is missing from
    the new folder. Refuses unless the new task exists, points at the new
    folder, and has a real LastRunTime inside 26h.

.PARAMETER DryRun
    Reports every step, changes nothing, writes nothing.

.EXAMPLE
    # 1. Deploy Invoke-ExtractFromSigmaSQL.ps1 v1.23+ to C:\SocialBrand first.
    # 2. Dry run:
    .\ops-migrate-retail-history.ps1 -DryRun

.EXAMPLE
    # 3. Real run:
    .\ops-migrate-retail-history.ps1
    # 4. Let it feed one night. Confirm push_log has a fresh row for this store.
    # 5. Only then:
    .\ops-migrate-retail-history.ps1 -Finalize
#>
param(
    [string]$OldTaskName = 'SocialBrand-ExtractDelta',
    [string]$NewTaskName = 'Retail History',
    [string]$OldDir      = 'C:\SocialBrand',
    [string]$NewDir      = 'C:\RetailHistory',
    [string]$RetainDir   = 'C:\SB-retain',
    [switch]$Finalize,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$hostName = $env:COMPUTERNAME
$stamp    = Get-Date -Format 'yyyyMMdd_HHmmss'

Write-Host ""
Write-Host "=== SB-CC-PUSH-HARDEN-001 : Retail History migration ===" -ForegroundColor Cyan
Write-Host "Server : $hostName"
Write-Host "Task   : '$OldTaskName'  ->  '$NewTaskName'"
Write-Host "Folder : '$OldDir'  ->  '$NewDir'"
Write-Host "Retain : $RetainDir"
if ($DryRun)   { Write-Host "MODE   : DRY RUN -- nothing will be changed or written." -ForegroundColor Yellow }
if ($Finalize) { Write-Host "MODE   : FINALIZE -- deletes the OLD task and OLD folder." -ForegroundColor Yellow }
Write-Host ""

# =============================================================================
# HARD GUARD -- SPAR / Catman property is NEVER touched by this script.
# Pieter's standing instruction, 2026-07-14, verbatim: "you do not touch
# anything in S:\sigma\comms\Catman ever. that's not our files and those are
# not our property ever."
# PRSSALE.DAT / TAC*.zip live under S:\sigma\comms\Catman on the store server.
# This script operates ONLY on our own C:\ folders and our own tasks. The guard
# below is belt-and-braces: if any parameter is ever pointed at that path (by
# typo, by a future edit, by copy-paste), the script refuses to start.
# =============================================================================
function Assert-NotCatman {
    param([string]$Path, [string]$Label)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $p = $Path.ToLower()
    if ($p -like '*catman*' -or $p -like 's:*' -or $p -like '*\sigma\comms*') {
        throw "REFUSING TO RUN: -$Label resolves to '$Path', which touches SPAR/Catman property (S:\sigma\comms\Catman). That is not ours and is never touched by this tooling. Nothing has been changed."
    }
}
foreach ($pair in @(@{P=$OldDir;L='OldDir'}, @{P=$NewDir;L='NewDir'}, @{P=$RetainDir;L='RetainDir'})) {
    Assert-NotCatman -Path $pair.P -Label $pair.L
}
Write-Host "[guard] Catman/S: boundary check passed -- this script touches only our own C:\ paths." -ForegroundColor DarkGray

# =============================================================================
# FINALIZE PATH (second run, after human verification)
# =============================================================================
if ($Finalize) {
    $newTask = Get-ScheduledTask -TaskName $NewTaskName -ErrorAction SilentlyContinue
    if (-not $newTask) { throw "FINALIZE REFUSED: task '$NewTaskName' does not exist. Run the migration first." }

    $act = $newTask.Actions[0]
    $argStr = ''
    try { $argStr = [string]$act.Arguments } catch { $argStr = '' }
    if ($argStr -like "*$OldDir*") {
        throw "FINALIZE REFUSED: '$NewTaskName' still points at '$OldDir'. The repoint did not take -- fix that before deleting anything."
    }

    $info = Get-ScheduledTaskInfo -TaskName $NewTaskName -ErrorAction SilentlyContinue
    if (-not $info -or -not $info.LastRunTime -or $info.LastRunTime -lt (Get-Date).AddHours(-26)) {
        $lrt = if ($info -and $info.LastRunTime) { $info.LastRunTime.ToString('yyyy-MM-dd HH:mm') } else { 'never' }
        throw "FINALIZE REFUSED: '$NewTaskName' LastRunTime = $lrt. It has not completed a real scheduled run in the last 26h. Let it feed one night and confirm push_log first -- that is the whole point of the two-step."
    }

    Write-Host "[finalize] '$NewTaskName' last ran $($info.LastRunTime) and points at the new folder. Proceeding." -ForegroundColor Green
    Write-Host ""

    # -------------------------------------------------------------------------
    # Pieter's design, 2026-07-14: '$OldDir' SURVIVES as the genuine Sigma
    # export folder (CSV/Excel only, load-bearing for nothing). Only the
    # MACHINERY leaves it. So finalize is surgical -- an explicit named list,
    # never a recursive wipe. An earlier draft of this script did
    # `Remove-Item $OldDir -Recurse -Force` here, which would have destroyed
    # DIWAAIS.xls / DIWAAIS2.xls and every other real export in that folder.
    #
    # *** THE CREDENTIAL. *** sb-key.txt is the Supabase service_role key.
    # '$NewDir' is ACL-locked; '$OldDir' is NOT (it is just an export folder
    # now, readable by ordinary users). Leaving the key behind in an unlocked
    # folder would hand out full DB access and defeat the entire point of this
    # exercise. It is on the list below and it is the single most important
    # removal here.
    # -------------------------------------------------------------------------
    $MachineryFiles = @(
        'Invoke-ExtractFromSigmaSQL.ps1',
        'sb-key.txt',
        'Test-SupabaseConnection.ps1',
        'extractor_last_run.log',
        'extractor_last_err.log',
        'extractor_last_error.txt',
        'nightly_push.log'
    )
    $MachineryPatterns = @('*_badrows.log')

    if ($DryRun) {
        Write-Host "  DRY RUN: would delete task '$OldTaskName'" -ForegroundColor Yellow
        Write-Host "  DRY RUN: would remove MACHINERY ONLY from '$OldDir' (folder + exports KEPT):" -ForegroundColor Yellow
        foreach ($m in $MachineryFiles) {
            $p = Join-Path $OldDir $m
            if (Test-Path -LiteralPath $p) { Write-Host "           - $m" -ForegroundColor Yellow }
        }
        foreach ($pat in $MachineryPatterns) {
            Get-ChildItem -LiteralPath $OldDir -Filter $pat -File -ErrorAction SilentlyContinue |
                ForEach-Object { Write-Host "           - $($_.Name)" -ForegroundColor Yellow }
        }
        Write-Host "  DRY RUN: everything else in '$OldDir' would be left exactly as-is." -ForegroundColor Yellow
        return
    }

    # 1. Old task first -- nothing should be able to launch from $OldDir while
    #    we strip it.
    if (Get-ScheduledTask -TaskName $OldTaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $OldTaskName -Confirm:$false
        Write-Host "[finalize] Removed old task '$OldTaskName'." -ForegroundColor Green
    } else {
        Write-Host "[finalize] Old task '$OldTaskName' already gone." -ForegroundColor DarkGray
    }

    # 2. Machinery out of the export folder -- but NEVER remove a file whose
    #    counterpart did not land in the locked folder. Losing sb-key.txt with
    #    no surviving copy would take the store's feed down permanently.
    $removed = 0; $keptBack = 0
    $targets = @()
    foreach ($m in $MachineryFiles) {
        $p = Join-Path $OldDir $m
        if (Test-Path -LiteralPath $p) { $targets += (Get-Item -LiteralPath $p) }
    }
    foreach ($pat in $MachineryPatterns) {
        $targets += (Get-ChildItem -LiteralPath $OldDir -Filter $pat -File -ErrorAction SilentlyContinue)
    }

    foreach ($t in $targets) {
        $counterpart = Join-Path $NewDir $t.Name
        if (-not (Test-Path -LiteralPath $counterpart)) {
            Write-Host "  [KEPT] '$($t.Name)' -- no counterpart in '$NewDir'. NOT removed." -ForegroundColor Red
            $keptBack++
            continue
        }
        Remove-Item -LiteralPath $t.FullName -Force
        Write-Host "  [moved-out] $($t.Name)" -ForegroundColor Green
        $removed++
    }
    Write-Host "[finalize] Machinery removed from '$OldDir': $removed file(s). Kept back (no counterpart): $keptBack." -ForegroundColor Green

    # 3. Report what survives, and flag anything that still looks like code or
    #    a secret sitting in an UNLOCKED folder.
    Write-Host ""
    Write-Host "=== '$OldDir' now contains (export folder, NOT locked) ===" -ForegroundColor Cyan
    $survivors = Get-ChildItem -LiteralPath $OldDir -File -ErrorAction SilentlyContinue
    if (-not $survivors) {
        Write-Host "  (no files at root)" -ForegroundColor DarkGray
    } else {
        $survivors | Sort-Object Name |
            Select-Object Name, @{n='KB';e={[math]::Round($_.Length/1KB,1)}}, LastWriteTime |
            Format-Table -AutoSize | Out-String | Write-Host
    }
    $suspect = $survivors | Where-Object { $_.Extension -in @('.ps1','.bat','.cmd','.psm1') -or $_.Name -match '(?i)key|secret|token|password|cred' }
    if ($suspect) {
        Write-Host "  *** REVIEW THESE -- code or possible secrets left in an UNLOCKED folder: ***" -ForegroundColor Red
        $suspect | ForEach-Object { Write-Host "      $($_.Name)" -ForegroundColor Red }
        Write-Host "  This folder is meant to hold CSV/Excel exports only. Anything above either" -ForegroundColor Yellow
        Write-Host "  belongs in '$NewDir' (locked) or should be removed." -ForegroundColor Yellow
    } else {
        Write-Host "  [ok] No scripts or key-like files remain at the root of the export folder." -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "=== FINALIZE DONE ===" -ForegroundColor Cyan
    Write-Host "  Machinery : '$NewDir'   (locked: SYSTEM + Administrators + run-as)"
    Write-Host "  Exports   : '$OldDir'   (kept, CSV/Excel, load-bearing for nothing)"
    Write-Host "  Retained  : $RetainDir"
    if ($keptBack -gt 0) {
        Write-Host ""
        Write-Host "  WARNING: $keptBack machinery file(s) were KEPT because no copy exists in '$NewDir'." -ForegroundColor Red
        Write-Host "  Investigate before considering this server done." -ForegroundColor Red
    }
    return
}

# =============================================================================
# PRECONDITIONS -- all must pass before anything is touched.
# =============================================================================
Write-Host "[1/6] Preconditions..." -ForegroundColor Cyan

# 1. Old task exists
$oldTask = Get-ScheduledTask -TaskName $OldTaskName -ErrorAction SilentlyContinue
if (-not $oldTask) {
    throw "Task '$OldTaskName' not found on this server. Either it is already migrated (check for '$NewTaskName') or the name differs -- list with: Get-ScheduledTask | Select TaskName"
}

# 2. Old folder exists
if (-not (Test-Path -LiteralPath $OldDir)) { throw "'$OldDir' not found. Confirm the real script folder from the task's own action." }

# 3. New folder must not already exist (never clobber)
if (Test-Path -LiteralPath $NewDir) { throw "'$NewDir' already exists. Stop and inspect -- this script never overwrites an existing target." }

# 4. THE SELF-HEAL GATE. The DEPLOYED extractor must already hardcode the new
#    task name, or the rename undoes itself on the next 18:40 run.
$extractor = Join-Path $OldDir 'Invoke-ExtractFromSigmaSQL.ps1'
if (-not (Test-Path -LiteralPath $extractor)) {
    throw "Extractor not found at '$extractor'. Cannot verify the self-heal name -- refusing to rename a task whose script I cannot read."
}
$extractorText = Get-Content -LiteralPath $extractor -Raw
if ($extractorText -notmatch [regex]::Escape("`$taskName = '$NewTaskName'")) {
    throw @"
REFUSING TO RUN -- the deployed extractor does not carry the new task name.

  Expected to find:  `$taskName = '$NewTaskName'
  In:                $extractor

This is the single most important gate in this script. The extractor
re-registers its own scheduled task at startup on EVERY full-chain run, using
whatever name is hardcoded in it. If the live task is renamed while an older
extractor is still deployed, the next 18:40 run will recreate the OLD branded
task -- you get two tasks, a double extraction every night, and the brand back
in Task Scheduler, silently, within 24 hours.

FIX: deploy Invoke-ExtractFromSigmaSQL.ps1 v1.23 or later to '$OldDir' first,
then re-run this script. Nothing has been changed.
"@
}
Write-Host "  [ok] Deployed extractor carries `$taskName = '$NewTaskName' -- self-heal will REINFORCE the rename, not undo it." -ForegroundColor Green

# 5. Capture the ACTUAL run-as principal from the live task. Never assumed.
$principal = $null
try { $principal = [string]$oldTask.Principal.UserId } catch { $principal = $null }
if ([string]::IsNullOrWhiteSpace($principal)) {
    try { $principal = [string]$oldTask.Principal.GroupId } catch { $principal = $null }
}
if ([string]::IsNullOrWhiteSpace($principal)) {
    throw "Could not read the run-as account off '$OldTaskName'. Refusing to continue -- the folder lock needs it, and assuming it is the one mistake that darks a store."
}
$runLevel = 'unknown'
try { $runLevel = [string]$oldTask.Principal.RunLevel } catch { }
Write-Host "  [ok] Live run-as account: '$principal'  (RunLevel: $runLevel)" -ForegroundColor Green
Write-Host "       -- this exact account gets Modify on the final folder; nothing is assumed." -ForegroundColor DarkGray

if ($DryRun) {
    Write-Host ""
    Write-Host "  DRY RUN -- would now:" -ForegroundColor Yellow
    Write-Host "    2. export '$OldTaskName' XML + current ACLs -> $RetainDir" -ForegroundColor Yellow
    Write-Host "    3. create '$NewTaskName' from that exact XML, verify it matches" -ForegroundColor Yellow
    Write-Host "    4. COPY '$OldDir' -> '$NewDir' (original kept as fallback)" -ForegroundColor Yellow
    Write-Host "    5. repoint '$NewTaskName' action: '$OldDir' -> '$NewDir'" -ForegroundColor Yellow
    Write-Host "    6. lock '$NewDir' to SYSTEM + Administrators + '$principal' (Modify)" -ForegroundColor Yellow
    Write-Host "    then STOP for your verification. Old task + old folder untouched." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "DRY RUN complete. Nothing changed, nothing written." -ForegroundColor Yellow
    return
}

# =============================================================================
# 2. RETENTION EXPORT -- mandatory, verified, before any change.
# =============================================================================
Write-Host "[2/6] Retention export (before any change)..." -ForegroundColor Cyan
if (-not (Test-Path -LiteralPath $RetainDir)) { New-Item -ItemType Directory -Path $RetainDir -Force | Out-Null }

$xmlPath = Join-Path $RetainDir ("task_{0}_{1}_original.xml" -f ($OldTaskName -replace '[\\/:*?"<>|]', '_'), $stamp)
Export-ScheduledTask -TaskName $OldTaskName | Out-File -FilePath $xmlPath -Encoding utf8
if (-not (Test-Path -LiteralPath $xmlPath) -or (Get-Item -LiteralPath $xmlPath).Length -eq 0) {
    throw "Task XML export did not land at $xmlPath -- STOPPING. Nothing has been changed."
}
Write-Host "  [ok] Task definition preserved: $xmlPath" -ForegroundColor Green

$aclPath = Join-Path $RetainDir ("acl_{0}_before_{1}.txt" -f ($OldDir -replace '[\\/:*?"<>|]', '_'), $stamp)
icacls "$OldDir" | Out-File -FilePath $aclPath -Encoding utf8
Write-Host "  [ok] Current folder permissions recorded: $aclPath" -ForegroundColor Green

# =============================================================================
# 3. CREATE THE NEW TASK from the exact preserved XML.
# =============================================================================
Write-Host "[3/6] Creating '$NewTaskName' from the preserved definition..." -ForegroundColor Cyan
$xmlContent = Get-Content -LiteralPath $xmlPath -Raw

# BUG-LOG ENG-023 (2026-07-17, PM fix on a live-server halt): the description is
# set HERE, in the XML, before the task is registered. It was previously set with
# `Set-ScheduledTask -Description` AFTER registering -- that cmdlet has no
# -Description parameter, so the script died between step 3 and step 4 with the
# new task already registered and unpointed. Setting it in the XML is also the
# correct place on the merits: the exported XML carries the OLD task's own
# description, so registering the XML unaltered would have carried the old label
# straight into the new task and defeated the rename.
$newDescription = 'Scheduled data maintenance task.'
if ($xmlContent -match '(?s)<Description>.*?</Description>') {
    $xmlContent = $xmlContent -replace '(?s)<Description>.*?</Description>', "<Description>$newDescription</Description>"
    Write-Host "  [ok] Description replaced in the XML before registration." -ForegroundColor Green
} elseif ($xmlContent -match '<RegistrationInfo>') {
    $xmlContent = $xmlContent -replace '<RegistrationInfo>', "<RegistrationInfo><Description>$newDescription</Description>"
    Write-Host "  [ok] Description inserted into the XML before registration (original had none)." -ForegroundColor Green
} else {
    Write-Host "  [warn] No <RegistrationInfo> block found -- registering without a description override." -ForegroundColor Yellow
}

Register-ScheduledTask -TaskName $NewTaskName -Xml $xmlContent -Force | Out-Null

$newTask = Get-ScheduledTask -TaskName $NewTaskName -ErrorAction SilentlyContinue
if (-not $newTask) { throw "'$NewTaskName' did not register. Old task '$OldTaskName' is untouched." }

# verify it matches the original before we rely on it
$mismatch = @()
if ([string]$oldTask.Triggers[0].StartBoundary -ne [string]$newTask.Triggers[0].StartBoundary) { $mismatch += 'trigger' }
if ([string]$oldTask.Actions[0].Execute -ne [string]$newTask.Actions[0].Execute) { $mismatch += 'execute' }
if ([string]$oldTask.Actions[0].Arguments -ne [string]$newTask.Actions[0].Arguments) { $mismatch += 'arguments' }
if ($mismatch.Count -gt 0) {
    Unregister-ScheduledTask -TaskName $NewTaskName -Confirm:$false
    throw "New task did not match the original ($($mismatch -join ', ')). Rolled it back. '$OldTaskName' is untouched."
}
Write-Host "  [ok] '$NewTaskName' registered, verified identical (trigger/execute/arguments)." -ForegroundColor Green
Write-Host "       Old task '$OldTaskName' still present as fallback -- deleted only by -Finalize." -ForegroundColor DarkGray

# =============================================================================
# 4. COPY the folder (never move -- the original is the fallback).
# =============================================================================
Write-Host "[4/6] Copying '$OldDir' -> '$NewDir' (original kept)..." -ForegroundColor Cyan
Copy-Item -LiteralPath $OldDir -Destination $NewDir -Recurse -Force
$copied = (Get-ChildItem -LiteralPath $NewDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
if ($copied -eq 0) { throw "Copy landed 0 files at '$NewDir' -- STOPPING. Old task and folder untouched." }
Write-Host "  [ok] $copied file(s) copied. Original '$OldDir' intact as fallback." -ForegroundColor Green

# v1.23+ derives its own paths from `$PSScriptRoot, so there are no absolute
# path literals left to rewrite inside the copy. Verify that holds -- if an
# older extractor somehow got here, say so rather than silently shipping a
# copy that still reads from the old folder.
$copiedExtractor = Join-Path $NewDir 'Invoke-ExtractFromSigmaSQL.ps1'
if (Test-Path -LiteralPath $copiedExtractor) {
    $ct = Get-Content -LiteralPath $copiedExtractor -Raw
    if ($ct -match [regex]::Escape($OldDir)) {
        Write-Host "  [warn] The copied extractor still contains the literal '$OldDir'." -ForegroundColor Yellow
        Write-Host "         v1.23+ should carry none. Check it before -Finalize removes the old folder." -ForegroundColor Yellow
    } else {
        Write-Host "  [ok] Copied extractor carries no '$OldDir' literals (v1.23 `$BaseDir behaviour confirmed)." -ForegroundColor Green
    }
}

# =============================================================================
# 5. REPOINT the new task at the new folder.
# =============================================================================
Write-Host "[5/6] Repointing '$NewTaskName' to '$NewDir'..." -ForegroundColor Cyan
$act = $newTask.Actions[0]
$newArgs = ([string]$act.Arguments) -replace [regex]::Escape($OldDir), $NewDir
$newWork = $NewDir
try {
    if (-not [string]::IsNullOrWhiteSpace([string]$act.WorkingDirectory)) {
        $newWork = ([string]$act.WorkingDirectory) -replace [regex]::Escape($OldDir), $NewDir
    }
} catch { $newWork = $NewDir }

$repointed = New-ScheduledTaskAction -Execute ([string]$act.Execute) -Argument $newArgs -WorkingDirectory $newWork
Set-ScheduledTask -TaskName $NewTaskName -Action $repointed | Out-Null

$check = (Get-ScheduledTask -TaskName $NewTaskName).Actions[0]
if (([string]$check.Arguments) -like "*$OldDir*") {
    throw "Repoint did not take -- '$NewTaskName' still references '$OldDir'. Old task/folder untouched; investigate before proceeding."
}
Write-Host "  [ok] '$NewTaskName' now runs from '$NewDir'." -ForegroundColor Green

# =============================================================================
# 6. LOCK THE FINAL FOLDER -- with the ACTUAL principal, Modify rights.
# =============================================================================
Write-Host "[6/6] Locking '$NewDir' (SYSTEM + Administrators + '$principal')..." -ForegroundColor Cyan

icacls "$NewDir" /inheritance:r | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls /inheritance:r failed (exit $LASTEXITCODE) on '$NewDir'." }
icacls "$NewDir" /grant:r "SYSTEM:(OI)(CI)F" /T /C | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls grant SYSTEM failed (exit $LASTEXITCODE) on '$NewDir'." }
icacls "$NewDir" /grant:r "BUILTIN\Administrators:(OI)(CI)F" /T /C | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls grant Administrators failed (exit $LASTEXITCODE) on '$NewDir'." }

# The run-as account. SYSTEM/Administrators are already covered above; anything
# else must be granted explicitly or the feed dies the next time it runs.
$already = @('system','nt authority\system','s-1-5-18','builtin\administrators','administrators')
if ($already -notcontains $principal.ToLower()) {
    icacls "$NewDir" /grant:r "${principal}:(OI)(CI)M" /T /C | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "  *** ACL GRANT FOR THE RUN-AS ACCOUNT FAILED (exit $LASTEXITCODE) ***" -ForegroundColor Red
        Write-Host "  This is THE failure mode that darks a store. Fix it NOW:" -ForegroundColor Red
        Write-Host "      icacls `"$NewDir`" /grant:r `"${principal}:(OI)(CI)M`" /T /C" -ForegroundColor Yellow
        Write-Host "  Or restore open access immediately:" -ForegroundColor Yellow
        Write-Host "      icacls `"$NewDir`" /inheritance:e" -ForegroundColor Yellow
        throw "Could not grant '$principal' on '$NewDir'. The old task and old folder are BOTH still intact -- the feed will keep running from '$OldDir' tonight. Fix the grant, or just delete '$NewDir' and re-run."
    }
    Write-Host "  [ok] '$principal' granted Modify (it writes extractor_last_error.txt / *_badrows.log here)." -ForegroundColor Green
} else {
    Write-Host "  [ok] Run-as '$principal' is already covered by the SYSTEM/Administrators grant." -ForegroundColor Green
}

# =============================================================================
# STOP. Human verification gate.
# =============================================================================
Write-Host ""
Write-Host "=== MIGRATION DONE ON THIS SERVER -- NOTHING DELETED ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Current state:" -ForegroundColor White
Write-Host "  LIVE     : task '$NewTaskName' -> '$NewDir'  (locked)"
Write-Host "  FALLBACK : task '$OldTaskName' -> '$OldDir'  (untouched, still scheduled)"
Write-Host "  RETAINED : $RetainDir"
Write-Host ""
Write-Host "NOTE: both tasks are scheduled for 18:40 tonight. That is deliberate --" -ForegroundColor DarkGray
Write-Host "      the fallback proves the store still feeds if the new path has a problem." -ForegroundColor DarkGray
Write-Host "      The extractor is idempotent (upserts on natural keys), so a double run" -ForegroundColor DarkGray
Write-Host "      does not corrupt anything. -Finalize removes the duplicate." -ForegroundColor DarkGray
Write-Host ""
Write-Host "END STATE after -Finalize:" -ForegroundColor White
Write-Host "  '$NewDir'  = machinery (extractor, key, logs), locked."
Write-Host "  '$OldDir'  = KEPT as the Sigma export folder (CSV/Excel), machinery stripped out."
Write-Host "  -Finalize does NOT delete '$OldDir' -- it removes only named machinery files"
Write-Host "  (including sb-key.txt, which must not sit in an unlocked export folder)."
Write-Host ""
Write-Host "VERIFY BEFORE FINALIZING (do not skip):" -ForegroundColor Yellow
Write-Host "  1. Let it run tonight at 18:40 (or: schtasks /Run /TN `"$NewTaskName`")"
Write-Host "  2. Confirm push_log has a fresh row for this store"
Write-Host "  3. Task Scheduler > '$NewTaskName' > History shows Completed"
Write-Host ""
Write-Host "THEN, and only then:" -ForegroundColor Yellow
Write-Host "      .\ops-migrate-retail-history.ps1 -Finalize"
Write-Host ""
Write-Host "REVERT (if anything looks wrong): the old task and old folder are both" -ForegroundColor Yellow
Write-Host "still live and untouched. Just delete the new pair:" -ForegroundColor Yellow
Write-Host "      Unregister-ScheduledTask -TaskName `"$NewTaskName`" -Confirm:`$false"
Write-Host "      Remove-Item -LiteralPath `"$NewDir`" -Recurse -Force"
Write-Host ""

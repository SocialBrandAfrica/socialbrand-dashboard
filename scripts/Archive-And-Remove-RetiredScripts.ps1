#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    SB-CC-PUSH-HARDEN-001 follow-up -- Pieter ruling: retired scripts must not
    be on the servers. Archives an EXPLICIT, reviewed list of retired files to
    an OFF-SERVER location (hash-verified), then removes them from this
    server's C:\SocialBrand.

.DESCRIPTION
    Different risk profile from Migrate-PushHarden.ps1 (which renames a LIVE
    task and locks a folder -- everything stays recoverable in place).
    This script DELETES files from the server. Under an active records-
    retention request, a local "moved to a subfolder on the same box" archive
    (which is what the existing Cleanup-SocialBrandFolder.ps1 does for the
    discovery scripts) is not enough -- Pieter's own words: retired files
    must not be on the servers, at all, full stop. So this script:

      1. Refuses to run unless -ArchiveRoot resolves to a DIFFERENT drive
         than -ScriptDir (a best-effort check that you pointed it somewhere
         off this machine -- a mapped network drive, a UNC path, a portable
         drive). Override with -ConfirmSameDrive only if you deliberately
         want a same-drive archive for some reason -- discouraged.
      2. For each retired file: computes its hash, copies it to a dated
         archive folder, re-hashes the COPY, and only removes the original
         from C:\SocialBrand if the two hashes match exactly. Any mismatch
         aborts that file (original left in place) rather than risk deleting
         something that was not faithfully preserved.
      3. Writes a manifest (filename, original path, archive path, hash,
         timestamps) into the archive folder itself -- the "here is exactly
         what we removed and where the copy lives" record.
      4. Never touches push_log, push_errors, or any operational history.

    The retired-file list is EXPLICIT (not a pattern match) -- reviewed one
    by one before this script was written: each of these was confirmed to
    have zero live scheduled tasks, zero references from any still-running
    script, and its retirement already recorded in the platform's own
    history (Push-SigmaToSupabase.ps1's own nightly/Sunday tasks were
    removed from all 5 servers 2026-06-28; the Discover-SigmaTables*.ps1
    trio's one-off job -- confirming the sales-source table -- has been
    done and superseded by the live extractor for months; the three .bat
    launchers and Fix-ScheduledTasksHidden.ps1 exist only to run/patch
    those same retired scripts).

.PARAMETER ArchiveRoot
    MANDATORY, no default -- an off-server location you control (network
    share, UNC path, mapped/portable drive). This script will not silently
    default to somewhere still on this machine.

.PARAMETER ScriptDir
    Folder the retired files currently live in. Defaults to C:\SocialBrand.

.PARAMETER ConfirmSameDrive
    Override the off-server drive check. Only use this if you deliberately
    want the archive on the same physical machine (e.g. a genuinely separate
    disk that still happens to share a drive letter scheme) -- not
    recommended given the reason this script exists.

.PARAMETER DryRun
    Report what would happen; makes NO changes (no copy, no delete).

.EXAMPLE
    # Always run dry first.
    .\Archive-And-Remove-RetiredScripts.ps1 -ArchiveRoot 'D:\RetentionArchive\PushHarden' -DryRun

.EXAMPLE
    # Real run.
    .\Archive-And-Remove-RetiredScripts.ps1 -ArchiveRoot '\\fileserver\SocialBrand-Retention\10116'
#>
param(
    [Parameter(Mandatory)]
    [string]$ArchiveRoot,
    [string]$ScriptDir = 'C:\SocialBrand',
    [switch]$ConfirmSameDrive,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Explicit, reviewed list -- never a pattern match. Each entry confirmed
# retired (no live task, no live script reference) before this file was
# written; see the header for the review summary.
$RetiredFiles = @(
    'Push-SigmaToSupabase.ps1',
    'Create-SundayPushTask.ps1',
    'Discover-SigmaTables.ps1',
    'Discover-SigmaTables2.ps1',
    'Discover-SigmaTables3.ps1',
    'Fix-ScheduledTasksHidden.ps1',
    'RunNightlyPush.bat',
    'RunBackfill.bat',
    'RunDiscovery.bat',
    'RunDiscovery2.bat',
    'RunDiscovery3.bat'
)

$hostName  = $env:COMPUTERNAME
$stamp     = Get-Date -Format 'yyyyMMdd_HHmmss'
$thisArchive = Join-Path $ArchiveRoot ($hostName + '_' + $stamp)

Write-Host ""
Write-Host "=== Archive-And-Remove-RetiredScripts ===" -ForegroundColor Cyan
Write-Host "Server      : $hostName"
Write-Host "Script dir  : $ScriptDir"
Write-Host "Archive to  : $thisArchive"
Write-Host "Files known : $($RetiredFiles.Count)"
if ($DryRun) { Write-Host "DRY RUN -- no changes will be made." -ForegroundColor Yellow }
Write-Host ""

# ---- off-server sanity check ----
function Get-DriveRoot([string]$Path) {
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
        if ($full -match '^[A-Za-z]:\\') { return $full.Substring(0,2).ToUpper() }
        if ($full -match '^\\\\') { return ($full -split '\\')[2] }   # UNC server name
        return $full
    } catch { return $Path }
}
$scriptDrive  = Get-DriveRoot $ScriptDir
$archiveDrive = Get-DriveRoot $ArchiveRoot
if ($scriptDrive -eq $archiveDrive -and -not $ConfirmSameDrive) {
    throw "ArchiveRoot ('$ArchiveRoot') resolves to the SAME drive/host as ScriptDir ('$ScriptDir') -- this looks like it is still on THIS server, which is exactly what Pieter's ruling says not to do. Point -ArchiveRoot at a network share, UNC path, or portable drive, or pass -ConfirmSameDrive if this is deliberate."
}

if ($DryRun) {
    foreach ($f in $RetiredFiles) {
        $p = Join-Path $ScriptDir $f
        if (Test-Path -LiteralPath $p) {
            Write-Host "  DRY RUN: would archive + remove: $f" -ForegroundColor Yellow
        }
        else {
            Write-Host "  DRY RUN: not present, nothing to do: $f" -ForegroundColor DarkGray
        }
    }
    Write-Host ""
    Write-Host "DRY RUN complete. No changes made." -ForegroundColor Yellow
    return
}

New-Item -ItemType Directory -Path $thisArchive -Force | Out-Null

$manifest = @()
$archived = 0
$notFound = 0
$failed   = 0

foreach ($f in $RetiredFiles) {
    $srcPath = Join-Path $ScriptDir $f
    if (-not (Test-Path -LiteralPath $srcPath)) {
        Write-Host "  [SKIP] '$f' not found in $ScriptDir -- nothing to remove." -ForegroundColor DarkGray
        $notFound++
        continue
    }

    $srcHash = (Get-FileHash -LiteralPath $srcPath -Algorithm SHA256).Hash
    $dstPath = Join-Path $thisArchive $f
    Copy-Item -LiteralPath $srcPath -Destination $dstPath -Force

    if (-not (Test-Path -LiteralPath $dstPath)) {
        Write-Host "  [FAIL] '$f' -- archive copy did not land. Original left in place." -ForegroundColor Red
        $failed++
        continue
    }
    $dstHash = (Get-FileHash -LiteralPath $dstPath -Algorithm SHA256).Hash
    if ($srcHash -ne $dstHash) {
        Write-Host "  [FAIL] '$f' -- archive copy hash mismatch (src=$srcHash dst=$dstHash). Original left in place, archive copy left for inspection." -ForegroundColor Red
        $failed++
        continue
    }

    Remove-Item -LiteralPath $srcPath -Force
    Write-Host "  [OK] '$f' archived (SHA256 verified) and removed from $ScriptDir." -ForegroundColor Green
    $archived++

    $manifest += [pscustomobject]@{
        FileName      = $f
        OriginalPath  = $srcPath
        ArchivePath   = $dstPath
        SHA256        = $srcHash
        ArchivedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

$manifestPath = Join-Path $thisArchive 'REMOVAL_MANIFEST.csv'
$manifest | Export-Csv -Path $manifestPath -NoTypeInformation -Encoding UTF8

$notePath = Join-Path $thisArchive 'RETENTION_NOTE.txt'
@"
SB-CC-PUSH-HARDEN-001 follow-up -- retired scripts archived off-server, then removed
Server: $hostName
Taken: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')
Files archived: $archived   Not found: $notFound   Failed (left in place): $failed
Reason: Pieter ruling -- retired scripts must not be on the servers. SPAR's 10 July
letter requested records/logs/configurations be retained pending its review, so
each file was hash-verified in this archive BEFORE removal from the live server.
See REMOVAL_MANIFEST.csv in this folder for the per-file detail.
This copy is READ-ONLY evidence. Do not delete, alter or overwrite it.
"@ | Out-File -FilePath $notePath -Encoding utf8

Write-Host ""
Write-Host "=== DONE. Archived $archived, not-found $notFound, failed $failed. ===" -ForegroundColor Cyan
Write-Host "Manifest: $manifestPath"
Write-Host "Note    : $notePath"
if ($failed -gt 0) {
    Write-Host ""
    Write-Host "$failed file(s) FAILED to archive-verify and were left in place -- check output above." -ForegroundColor Red
}
Write-Host ""

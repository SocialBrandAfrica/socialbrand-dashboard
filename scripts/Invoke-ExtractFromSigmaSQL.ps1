#Requires -Version 5.1
<#
.SYNOPSIS
    Phase A Layer 1 extractor. Reads 12 Sigma SQL tables and upserts to Supabase.
.DESCRIPTION
    Fills the 12 Supabase tables defined in sigma_layer1_schema.sql from
    localhost\SIGMA (databases dw220sdb and EASYDB). Casts all float keys to
    bigint, trims all char fields, upserts on each natural key. Runs on the
    store server (Windows Authentication, no password).

    Delta mode (default): extracts only data at or after the watermark. The
    watermark is the max date already in Supabase for this store, less a 3-day
    overlap to catch late arrivals. Applies to sigma_sales and sigma_movements
    only; all reference tables are always fully refreshed.

    Full-refresh mode (-FullRefresh): extracts all history, year by year for
    the two large fact tables, in a single pass for everything else. Use this
    for the initial population of each table. Can take 30-60 minutes or more.

    EASYDB nightly rebuild runs at approximately 19:20. sigma_ean_master is
    skipped automatically if the clock falls inside the 19:00-19:30 window.
    Pass -SkipEan to suppress it entirely for a run.

    Reference: sigma_layer1_schema.sql v1.0, PM sign-off 2026-06-04.
    Architecture rules: NORTH_STAR.md / project_sigma_architecture.md.

.PARAMETER FullRefresh
    Extract all history from Sigma, not just the delta since the last run.
    Use for initial table population. Runs year by year for large fact tables.

.PARAMETER SkipEan
    Skip sigma_ean_master entirely for this run (e.g. running near 19:00-19:30).

.PARAMETER TableName
    Extract a single named table only. Useful for reruns or troubleshooting.
    Valid values: sales, movements, articles, lifecycle, orders, orderlines,
    suppliermaster, supplierlink, tradeterms, ean, departments, subdepts, soh_daily.

.EXAMPLE
    # Initial load -- full history, all tables
    powershell.exe -ExecutionPolicy Bypass -File ".\Invoke-ExtractFromSigmaSQL.ps1" -FullRefresh

    # Nightly delta run
    powershell.exe -ExecutionPolicy Bypass -File ".\Invoke-ExtractFromSigmaSQL.ps1"

    # Rerun a single table
    powershell.exe -ExecutionPolicy Bypass -File ".\Invoke-ExtractFromSigmaSQL.ps1" -TableName articles

.NOTES
    Version  : v1.4
    Date     : 2026-06-08
    Schema   : sigma_layer1_schema.sql v1.0
    Requires : C:\socialbrand\sb-key.txt (Supabase service_role key, first line)
               SQL Server client libraries (present on all Sigma store servers)

    v1.0 : Initial release. 12 tables, delta + full-refresh modes.
    v1.3 : UTF-8 POST body on all Supabase calls (PGRST102 fix).
    v1.4 : Invoke-SnapshotSohDaily added (l2_soh_daily, Layer 2 Gate 2 Option A).
    v1.5 : Invoke-ExtractPromotions + Invoke-ExtractPromotionArticles (DBAKTK/DBAKTP).
    v1.6 : ROW_NUMBER dedup for sigma_ean_master (fix PG-21000 duplicate-batch).
    v1.7 : Fix dREFNR float truncation -- CONVERT(varchar,CONVERT(bigint,ROUND(dREFNR,0)))
           instead of CAST(dREFNR AS BIGINT). barcode stored as text, not bigint.
    v1.8 : Write fatal error to C:\socialbrand\extractor_last_error.txt on exit 1 so
           push_log in Push-SigmaToSupabase v3.22+ captures the actual exception text
           instead of a bare "Exit code 1". Cleared at start of each run.
    v1.9 : Delete-before-insert for sigma_ean_master. Old truncated-barcode rows (from
           pre-v1.7 CAST bigint runs) persist alongside new full-length barcodes because
           the conflict key includes barcode -- different truncated vs full values never
           collide, so no row is ever overwritten. Fix: DELETE all store rows first, then
           INSERT fresh from EASYDB. Only runs if EASYDB read succeeds (safe guard).
           Also: script-scope trap added so CONFIG-section failures (unknown host,
           missing key file) write extractor_last_error.txt too -- previously only
           main-try failures were captured and startup crashes showed as a bare
           "Exit code 1" in push_log.
    v1.10: Per-table push_log rows (push_type='l1_table', one per table per run,
           SUCCESS with rows_pushed or FAILED with error). R22 / DASH-TRUTH-001
           P0.1: 80175 sigma_sales was dark for 2 days behind a green summary row.
           A green night with a dark table is now structurally impossible.
    v1.11: sigma_scan_refs extraction from dw220sdb.dbo.DBREFE -- Sigma's NATIVE
           scan-reference table (R25 source-of-record, PM ruling 2026-06-11).
           Sigma stores check-digit-stripped bodies natively; the GS1 check-digit
           computation (12->13 EAN, 11->12 UPC-A) is the approved decode, with
           per-row provenance (code_kind, decode_method). Includes dPACK (native
           pack-link home). IntellistoX/sigma_ean_master stays as derivative
           cross-check during transition. SB-CC-SOURCE-001.
    v1.12: EOD-collision guard. 2026-06-11 20:00 run: 4/5 stores failed with
           "Cannot open database dw220sdb requested by the login" -- Sigma EOD
           holds dw220sdb in a restricted state around 20:00 (same login worked
           at 19:40 and on 21355 at 20:03). Fix: Wait-ForSigmaDw probes the DB
           at startup and retries every 5 min (max 9 probes, ~40 min) until EOD
           releases it, instead of failing the whole chain on first contact.
    v1.14: Self-registering 18:40 pre-EOD task. The standalone
           Create-ExtractorScheduledTask.ps1 was never auto-deployed, so the
           SocialBrand-ExtractDelta task existed on 0/5 servers and the pre-EOD
           window never fired (push_log: zero 18:40 sigma_extractor rows ever).
           Fix: Register-ExtractDeltaTask runs at startup, BEFORE any SQL, so it
           lands even when dw220sdb is locked. Idempotent -- (re)registers only
           when the task is missing or its trigger is not 18:40. Rides the fresh
           nightly extractor deploy (Invoke-DeployExtractor, not version-gated),
           so it self-heals on all 5 servers from the next push. Full-chain runs
           only (skipped on -TableName single-table reruns). 18:40 is hardcoded
           here to match Create-ExtractorScheduledTask.ps1 -- flagged as
           per-store config under R25 / SOURCE-001 (must not fossilise).
    v1.13: Probe discriminator. 2026-06-11: the lock outlasted the full 45-min
           probe window on 4 stores (held 20:01 to past 21:54) and the bare
           "Cannot open database" text cannot distinguish an EOD lock from a
           broken login or a downed instance. On every failed probe the guard
           now asks master (always reachable when instance + Windows login are
           healthy) for dw220sdb's state_desc/user_access_desc from
           sys.databases and logs it: RESTRICTED_USER / SINGLE_USER / OFFLINE /
           RESTORING = EOD-style lock (waiting is right); ONLINE + MULTI_USER
           yet open fails = permission problem (waiting will not help); master
           unreachable = instance/login broken, not an EOD lock. The give-up
           error carries the last observed state so push_log names the cause.
#>
param(
    [switch]$FullRefresh,
    [switch]$SkipEan,
    [ValidateSet('sales','movements','articles','lifecycle','orders','orderlines',
                 'suppliermaster','supplierlink','tradeterms','ean','scanrefs','departments','subdepts',
                 'soh_daily','promotions','promotionarticles')]
    [string]$TableName = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Script-scope trap: catches terminating errors thrown OUTSIDE the main
# try/catch -- i.e. the CONFIG section below (unknown host, missing key file).
# Without this, such failures exit 1 with no error file and push_log shows a
# bare "Exit code 1" (the v1.8 mechanism only covers the main try block).
trap {
    try {
        Set-Content -Path 'C:\socialbrand\extractor_last_error.txt' -Value ("CONFIG/STARTUP: " + $_.ToString()) -Encoding UTF8 -Force
    }
    catch {}
    Write-Host "FATAL (startup): $_" -ForegroundColor Red
    exit 1
}

# =============================================================================
# CONFIG
# =============================================================================

$ScriptVersion  = 'v1.17'   # v1.17 (SB-CC-DICE-REPAIR-001, 2026-06-21): Self-healing dw220sdb user mapping repair. When Wait-ForSigmaDw detects ONLINE+MULTI_USER failure (permission problem, not EOD lock), attempts to restore the db_datareader mapping from a master connection before giving up. (v1.16: truthful status, bounded retry)
$ClientId       = 'socialbrand'

# Store identity -- auto-detected from hostname, same map as Push-SigmaToSupabase.ps1.
$HostMap = @{
    'SRSDELAREYVILES' = @{ StoreCode = '10116'; StoreName = 'SPAR Delareyville' }
    'SRSROOSVILLESVR' = @{ StoreCode = '80175'; StoreName = 'SPAR Roosville'    }
    'SRTDELAREYVILSV' = @{ StoreCode = '21355'; StoreName = 'TOPS Delareyville' }
    'SRSDELAREYT2SVR' = @{ StoreCode = '80579'; StoreName = 'TOPS Dice'         }
    'SRTROOSVILLESVR' = @{ StoreCode = '80176'; StoreName = 'TOPS Roosville'    }
}
$HostKey = $env:COMPUTERNAME.ToUpper()
if (-not $HostMap.ContainsKey($HostKey)) {
    throw "Unknown host '$HostKey'. Add it to HostMap in script config."
}
$StoreCode = $HostMap[$HostKey].StoreCode
$StoreName = $HostMap[$HostKey].StoreName

# SQL Server -- Windows Auth, no password.
$SigmaServer = 'localhost\SIGMA'
$DwDb        = 'dw220sdb'
$EasyDb      = 'EASYDB'

# Supabase -- service_role key loaded from local file. Never stored in script.
$SupabaseUrl = 'https://crklvhfwyxlisfcvqenc.supabase.co'
$KeyFile     = 'C:\socialbrand\sb-key.txt'
if (-not (Test-Path $KeyFile)) {
    throw "Supabase key file not found: $KeyFile. Create it with the service_role key on the first line."
}
$SupabaseKey = (Get-Content $KeyFile -Raw).Trim()

# Push tuning -- mirrors Push-SigmaToSupabase.ps1 values.
$BatchSize      = 500
$RetryMax       = 3
$RetryWaitSecs  = 10
$DeltaOverlapDays = 3    # Re-pull this many days before watermark to catch late arrivals.
$DefaultDeltaDays = 7    # Lookback if Supabase table is empty (no watermark).

# EASYDB extraction window guard -- nightly rebuild runs at ~19:20.
$EasyDbBlockHourStart = 19
$EasyDbBlockMinEnd    = 30

# =============================================================================
# TLS
# =============================================================================

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# =============================================================================
# SELF-REGISTERING PRE-EOD TASK (v1.14)
# =============================================================================

function Register-ExtractDeltaTask {
    # Ensures the SocialBrand-ExtractDelta scheduled task exists and fires at
    # 18:40 (before the 19:00 store close, clear of the ~20:00 dw220sdb lock).
    # Idempotent: registers only when the task is missing or its trigger is not
    # 18:40. Runs at extractor startup BEFORE any SQL, so it lands even when
    # dw220sdb is locked. Non-fatal -- a registration failure never blocks the
    # extract (it just retries next run). Self-heals all 5 servers via the fresh
    # nightly extractor deploy.
    #
    # 18:40 is hardcoded to match Create-ExtractorScheduledTask.ps1. Per Pieter
    # (R25 / SB-CC-SOURCE-001): pre-EOD time is per-store/per-day CONFIG, not
    # code -- this must move to config when SOURCE-001 lands. Flagged so it does
    # not fossilise as a hardcoding.
    $taskName = 'SocialBrand-ExtractDelta'
    $atTime   = '18:40'
    try {
        if (-not $PSCommandPath) {
            Write-Host "  [task] Script path unknown - skipping task registration." -ForegroundColor DarkGray
            return
        }
        $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existing) {
            # Already present with an 18:40 daily trigger -> leave it alone.
            $hasSlot = $false
            foreach ($t in $existing.Triggers) {
                if ($t.StartBoundary -and ($t.StartBoundary -match 'T18:40:00')) { $hasSlot = $true }
            }
            if ($hasSlot) {
                Write-Host "  [task] '$taskName' already registered for $atTime." -ForegroundColor DarkGray
                return
            }
            Write-Host "  [task] '$taskName' present but not at $atTime - re-registering." -ForegroundColor Yellow
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        }

        $psExe   = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $exeArgs = '-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File "' + $PSCommandPath + '"'
        $workDir = Split-Path $PSCommandPath
        $trigger = New-ScheduledTaskTrigger -Daily -At $atTime
        $action  = New-ScheduledTaskAction -Execute $psExe -Argument $exeArgs -WorkingDirectory $workDir
        # ExecutionTimeLimit 4h is ample: a delta run is 5-10 min and the dw220sdb
        # retry is a short bounded ~10 min. (The 23:30 poll-to-cutoff / long window
        # were descoped 2026-06-17 -- the lock is rare; a stale store shows on the
        # dashboard and a manual re-run lands it; no long-window task needed.)
        $settings = New-ScheduledTaskSettingsSet `
            -ExecutionTimeLimit (New-TimeSpan -Hours 4) `
            -StartWhenAvailable `
            -WakeToRun:$false

        Register-ScheduledTask `
            -TaskName $taskName `
            -Trigger  $trigger `
            -Action   $action `
            -Settings $settings `
            -RunLevel  Highest `
            -Force | Out-Null
        Write-Host "  [task] Registered '$taskName' -> daily $atTime." -ForegroundColor Green
    }
    catch {
        # Non-fatal: needs admin/highest rights; if the run context lacks them
        # this warns and retries next run. The extract continues regardless.
        Write-Warning "[task] Could not register '$taskName' (non-fatal): $_"
    }
}

# Full-chain runs only -- skip on single-table manual reruns (-TableName ...).
if ([string]::IsNullOrEmpty($TableName)) {
    Register-ExtractDeltaTask
}

# =============================================================================
# SQL HELPERS
# =============================================================================

function New-SqlConn {
    param([string]$Db)
    $cs   = "Server=$SigmaServer;Database=$Db;Integrated Security=True;Connection Timeout=30;"
    $conn = New-Object System.Data.SqlClient.SqlConnection($cs)
    $conn.Open()
    return $conn
}

function Get-DwStateDiag {
    # v1.13 probe discriminator. The dw220sdb open failed -- ask master WHY.
    # master is accessible whenever the instance and the Windows login are
    # healthy, so the answer splits the failure into named causes:
    #   state/user_access RESTRICTED_USER, SINGLE_USER, OFFLINE, RESTORING
    #     = EOD-style lock, waiting is correct
    #   ONLINE + MULTI_USER yet the open fails
    #     = permission/login-mapping problem, waiting will not help
    #   master itself unreachable
    #     = instance down or Windows login broken, NOT an EOD lock
    # Returns a one-line diagnosis. Never throws.
    try {
        $m = New-SqlConn -Db 'master'
        try {
            $cmd = New-Object System.Data.SqlClient.SqlCommand(
                "SELECT state_desc, user_access_desc FROM sys.databases WHERE name = '$DwDb'", $m)
            $r = $cmd.ExecuteReader()
            try {
                if ($r.Read()) {
                    return "$DwDb state=$($r.GetString(0)) user_access=$($r.GetString(1)) (instance+login OK)"
                }
                return "$DwDb NOT IN sys.databases -- detached or dropped during EOD? (instance+login OK)"
            }
            finally { $r.Close() }
        }
        finally { $m.Close() }
    }
    catch {
        return "master also unreachable ($($_.ToString().Trim())) -- instance down or Windows login broken, NOT an EOD lock"
    }
}

function Repair-DwAccess {
    # SB-CC-DICE-REPAIR-001 (2026-06-21): When dw220sdb is ONLINE+MULTI_USER but the
    # machine account's database user mapping is missing, attempt to restore it from a
    # master connection. Works if the Windows login has ALTER ANY DATABASE or sysadmin.
    # Fails gracefully if permissions are insufficient -- error is logged and we fall
    # through to the normal failure path. Never throws.
    param([string]$LoginName, [string]$UserName)
    Write-Host "[dw-repair] Attempting to restore dw220sdb user mapping for $LoginName ..." -ForegroundColor Yellow
    try {
        $m = New-SqlConn -Db 'master'
        try {
            # Ensure the server-level login exists
            $ensureLogin = @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$LoginName')
    CREATE LOGIN [$LoginName] FROM WINDOWS;
"@
            $cmd = New-Object System.Data.SqlClient.SqlCommand($ensureLogin, $m)
            $cmd.ExecuteNonQuery() | Out-Null

            # Restore the database user and db_datareader role in dw220sdb.
            # Uses sp_executesql to switch database context -- requires ALTER ANY DATABASE
            # or sysadmin at the server level.
            $repairSql = @"
EXEC sp_executesql N'
    USE [$DwDb];
    IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N''$UserName'')
        CREATE USER [$UserName] FOR LOGIN [$LoginName];
    IF IS_ROLEMEMBER(''db_datareader'', N''$UserName'') = 0
        EXEC sp_addrolemember ''db_datareader'', N''$UserName'';
';
"@
            $cmd2 = New-Object System.Data.SqlClient.SqlCommand($repairSql, $m)
            $cmd2.ExecuteNonQuery() | Out-Null
            Write-Host "[dw-repair] User mapping restored. Retrying dw220sdb connection..." -ForegroundColor Green
            return $true
        }
        finally { $m.Close() }
    }
    catch {
        Write-Host "[dw-repair] Repair failed (insufficient SQL Server privileges): $($_.ToString().Trim())" -ForegroundColor Yellow
        Write-Host "[dw-repair] Manual fix required: connect to localhost\SIGMA on SRSDELAREYT2SVR, run Scripts 1+2 from SB-CC-DICE-REPAIR-001." -ForegroundColor Yellow
        return $false
    }
}

function Wait-ForSigmaDw {
    # SB-CC-EXTRACT-002 (Pieter SIMPLIFIED 2026-06-17): bounded retry, not poll-to-cutoff.
    # SB-CC-DICE-REPAIR-001 (2026-06-21): on ONLINE+MULTI_USER failure (permission mapping
    # lost, not an EOD lock), attempt self-repair from master before giving up.
    $maxTries    = 3
    $gapSecs     = 300   # ~10 min total across the 3 tries
    $repairTried = $false

    # Derive Windows login + DB user name from the current machine identity.
    $loginName = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name  # e.g. SRSDELAREYT2\SRSDELAREYT2SVR$
    $userName  = $loginName.Split('\')[-1]                                         # e.g. SRSDELAREYT2SVR$

    for ($i = 1; $i -le $maxTries; $i++) {
        try {
            $conn = New-SqlConn -Db $DwDb
            $conn.Close()
            if ($i -gt 1) { Write-Host "[dw-probe] $DwDb reachable on try $i." -ForegroundColor Green }
            return
        }
        catch {
            $msg  = $_.ToString()
            $diag = Get-DwStateDiag

            # Detect ONLINE+MULTI_USER = permission/mapping problem, NOT an EOD lock.
            # On first encounter, attempt self-repair then retry immediately (don't wait).
            if ($diag -match 'ONLINE.*MULTI_USER' -and -not $repairTried) {
                $repairTried = $true
                $repaired = Repair-DwAccess -LoginName $loginName -UserName $userName
                if ($repaired) {
                    continue   # retry the connection immediately, no sleep
                }
                # Repair failed -- fall through to normal fail path below
            }

            if ($i -ge $maxTries) {
                throw "dw220sdb not reachable after $maxTries tries (~10 min) -- failing truthfully; the store will show STALE on the dashboard and a manual re-run will land it. Diagnosis: $diag | Last error: $msg"
            }
            Write-Host "[dw-probe] $DwDb not reachable (try $i/$maxTries). Diagnosis: $diag. Waiting $($gapSecs)s." -ForegroundColor Yellow
            Start-Sleep -Seconds $gapSecs
        }
    }
}

function Invoke-SqlTable {
    # Runs a query and returns a DataTable. Use for tables small enough to fit in memory.
    param(
        [System.Data.SqlClient.SqlConnection]$Conn,
        [string]$Sql,
        [int]$TimeoutSecs = 600
    )
    $cmd                = New-Object System.Data.SqlClient.SqlCommand($Sql, $Conn)
    $cmd.CommandTimeout = $TimeoutSecs
    $adapter            = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
    $dt                 = New-Object System.Data.DataTable
    $null               = $adapter.Fill($dt)
    return ,$dt
}

# New-SqlReader removed. Readers are created inside Push-Reader to prevent
# PowerShell pipeline enumeration from consuming the forward-only reader.

# =============================================================================
# SUPABASE HELPERS
# =============================================================================

function Get-Headers {
    return @{
        'apikey'        = $SupabaseKey
        'Authorization' = "Bearer $SupabaseKey"
        'Content-Type'  = 'application/json; charset=utf-8'
        'Prefer'        = 'resolution=merge-duplicates,return=minimal'
        'User-Agent'    = "SocialBrand-Extractor/$ScriptVersion PowerShell"
    }
}

# =============================================================================
# STORE EXTRACT CONFIG (SB-CC-EXTRACT-002) -- declarative timing, read at startup
# =============================================================================
function Get-StoreExtractConfig {
    # Reads this store's row from store_extract_config (declarative timing, R25).
    # Falls back to safe defaults if Supabase is unreachable or the row is missing
    # -- config never blocks the pull. Timing is DATA, not code: a new customer is
    # a new row, the runner is unchanged.
    $fallback = @{ ready_poll_minutes = 10; hard_cutoff = '23:30'; eod_window_start = '18:40'; source = 'fallback' }
    try {
        $hdrs = @{ 'apikey' = $SupabaseKey; 'Authorization' = "Bearer $SupabaseKey" }
        $url  = "$SupabaseUrl/rest/v1/store_extract_config" +
                "?select=ready_poll_minutes,hard_cutoff,eod_window_start" +
                "&store_code=eq.$StoreCode&client_id=eq.$ClientId&limit=1"
        $rows = Invoke-RestMethod -Uri $url -Method GET -Headers $hdrs -TimeoutSec 20
        if ($rows -and @($rows).Count -ge 1) {
            $r = @($rows)[0]
            return @{
                ready_poll_minutes = $r.ready_poll_minutes
                hard_cutoff        = $r.hard_cutoff
                eod_window_start   = $r.eod_window_start
                source             = 'store_extract_config'
            }
        }
        Write-Host "  [cfg] no store_extract_config row for $StoreCode -- fallback (poll 10m, cutoff 23:30)." -ForegroundColor Yellow
        return $fallback
    }
    catch {
        Write-Warning "[cfg] store_extract_config fetch failed ($_) -- fallback (poll 10m, cutoff 23:30)."
        return $fallback
    }
}

# Fetch once on full-chain runs -- informational log of the store's config row.
# (Wait-ForSigmaDw now uses a fixed bounded retry; the readiness poll was descoped 2026-06-17.)
$script:ExtractCfg = $null
if ([string]::IsNullOrEmpty($TableName)) {
    $script:ExtractCfg = Get-StoreExtractConfig
    Write-Host ("  [cfg] {0} ({1}): poll {2}m, hard_cutoff {3} (source: {4})." -f `
        $StoreName, $StoreCode, $script:ExtractCfg.ready_poll_minutes, $script:ExtractCfg.hard_cutoff, $script:ExtractCfg.source) -ForegroundColor Cyan
}

function Get-Watermark {
    # Returns the max value of $Column in $Table for this store, as a [datetime].
    # Returns $null on empty table or failure -- caller falls back to default lookback.
    param([string]$Table, [string]$Column)
    $url  = "$SupabaseUrl/rest/v1/$Table`?select=$Column&store_code=eq.$StoreCode&order=$Column.desc&limit=1"
    $hdrs = @{
        'apikey'        = $SupabaseKey
        'Authorization' = "Bearer $SupabaseKey"
        'User-Agent'    = "SocialBrand-Extractor/$ScriptVersion PowerShell"
    }
    try {
        $rows = Invoke-RestMethod -Uri $url -Method GET -Headers $hdrs -TimeoutSec 30
        if ($rows -and $rows.Count -gt 0 -and $null -ne $rows[0].$Column) {
            return [datetime]$rows[0].$Column
        }
    }
    catch {
        Write-Warning "  Watermark read failed for $Table.$Column -- using default $DefaultDeltaDays-day lookback. ($_)"
    }
    return $null
}

function Send-Batch {
    param([string]$Table, [string]$ConflictCols, [array]$Rows)
    $url     = "$SupabaseUrl/rest/v1/$Table`?on_conflict=$ConflictCols"
    $attempt = 0
    while ($attempt -lt $RetryMax) {
        try {
            $json  = ConvertTo-Json -InputObject @($Rows) -Depth 5 -Compress
            # Send as explicit UTF-8 bytes. PS 5.1 leaves chars like U+00A0 (NBSP)
            # raw in the JSON, and a string -Body is sent non-UTF-8, so the lone
            # 0xA0 byte is invalid UTF-8 -> PostgREST PGRST102. Bytes fix it for all
            # non-ASCII (accents, NBSP, degree, currency) with no data loss.
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            $null  = Invoke-RestMethod -Uri $url -Method POST -Headers (Get-Headers) -Body $bytes -TimeoutSec 90
            return $Rows.Count
        }
        catch {
            $attempt++
            $detail = ''
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $detail = ' | ' + $reader.ReadToEnd()
            }
            catch {}
            if ($attempt -lt $RetryMax) {
                Write-Warning "  Batch attempt $attempt/$RetryMax failed for $Table. Retrying in ${RetryWaitSecs}s. ($_$detail)"
                Start-Sleep -Seconds $RetryWaitSecs
            }
            else {
                Write-Warning "  Batch failed after $RetryMax retries for $Table. Falling back to row-by-row. ($_$detail)"
                $pushed = 0
                foreach ($row in $Rows) {
                    try {
                        $rj   = ConvertTo-Json -InputObject @($row) -Depth 5 -Compress
                        $rb   = [System.Text.Encoding]::UTF8.GetBytes($rj)
                        $null = Invoke-RestMethod -Uri $url -Method POST -Headers (Get-Headers) -Body $rb -TimeoutSec 60
                        $pushed++
                    }
                    catch {
                        Write-Warning "    Row error in $Table`: $_"
                        # DIAGNOSTIC (v1.2): dump the offending row so we can see the
                        # exact bad value -- JSON sent plus per-field character codes.
                        try {
                            $log = "C:\socialbrand\" + $Table + "_badrows.log"
                            Add-Content -Path $log -Value "=== bad row ==="
                            Add-Content -Path $log -Value $rj
                            foreach ($k in $row.Keys) {
                                $cv = $row[$k]
                                if ($cv -is [string]) {
                                    $codes = (($cv.ToCharArray()) | ForEach-Object { [int]$_ }) -join ' '
                                    Add-Content -Path $log -Value ("  " + $k + " codes: " + $codes)
                                }
                            }
                        }
                        catch {}
                    }
                }
                return $pushed
            }
        }
    }
    return 0
}

function Push-DataTable {
    # Maps a DataTable through $RowMapper and pushes in batches.
    param(
        [string]$Table,
        [string]$ConflictCols,
        [System.Data.DataTable]$Dt,
        [scriptblock]$RowMapper
    )
    $total  = $Dt.Rows.Count
    $batch  = [System.Collections.Generic.List[object]]::new()
    $pushed = 0
    foreach ($row in $Dt.Rows) {
        $mapped = & $RowMapper $row
        if ($null -ne $mapped) { $null = $batch.Add($mapped) }
        if ($batch.Count -ge $BatchSize) {
            $pushed += Send-Batch -Table $Table -ConflictCols $ConflictCols -Rows $batch.ToArray()
            $batch.Clear()
            Write-Host "    $pushed / $total..." -NoNewline
        }
    }
    if ($batch.Count -gt 0) {
        $pushed += Send-Batch -Table $Table -ConflictCols $ConflictCols -Rows $batch.ToArray()
    }
    return $pushed
}

function Push-Reader {
    # Creates a SqlDataReader internally and streams it through $RowMapper in batches.
    # The reader never leaves this function, so PowerShell cannot enumerate it.
    # Use for large tables (sigma_sales, sigma_movements).
    param(
        [string]$Table,
        [string]$ConflictCols,
        [System.Data.SqlClient.SqlConnection]$Conn,
        [string]$Sql,
        [scriptblock]$RowMapper,
        [int]$TimeoutSecs = 1800
    )
    $cmd                = New-Object System.Data.SqlClient.SqlCommand($Sql, $Conn)
    $cmd.CommandTimeout = $TimeoutSecs
    $reader             = $cmd.ExecuteReader()
    $batch  = [System.Collections.Generic.List[object]]::new()
    $pushed = 0
    $read   = 0
    try {
        while ($reader.Read()) {
            $read++
            $mapped = & $RowMapper $reader
            if ($null -ne $mapped) { $null = $batch.Add($mapped) }
            if ($batch.Count -ge $BatchSize) {
                $pushed += Send-Batch -Table $Table -ConflictCols $ConflictCols -Rows $batch.ToArray()
                $batch.Clear()
                if ($pushed % 50000 -eq 0 -and $pushed -gt 0) {
                    Write-Host "    $pushed rows pushed so far..."
                }
            }
        }
        if ($batch.Count -gt 0) {
            $pushed += Send-Batch -Table $Table -ConflictCols $ConflictCols -Rows $batch.ToArray()
        }
    }
    finally {
        $reader.Close()
    }
    return $pushed
}

# =============================================================================
# FIELD TYPE HELPERS
# All accept a DataRow column value or SqlDataReader ordinal value.
# Return $null for DBNull. Trim strings. Never throw -- return $null on failure.
# =============================================================================

function Safe-Text {
    param($v)
    if ($null -eq $v -or $v -is [System.DBNull]) { return $null }
    $s = $v.ToString()
    # Strip NUL and other control chars (0x00-0x1F, 0x7F). Sigma char() columns can
    # carry NUL padding / control bytes; ConvertTo-Json emits them as  etc.,
    # which PostgREST rejects (PGRST102 "Empty or invalid json"). One bad row poisons
    # the whole batch body, so the row-by-row fallback then drops the good rows too.
    $s = [regex]::Replace($s, '[\x00-\x1F\x7F-\x9F\uD800-\uDFFF]', ' ').Trim()
    if ($s -eq '') { return $null }
    return $s
}

function Safe-SmallInt {
    param($v)
    if ($null -eq $v -or $v -is [System.DBNull]) { return $null }
    try { return [int][decimal]$v } catch { return $null }
}

function Safe-Int {
    param($v)
    if ($null -eq $v -or $v -is [System.DBNull]) { return $null }
    try { return [int][decimal]$v } catch { return $null }
}

function Safe-BigInt {
    param($v)
    if ($null -eq $v -or $v -is [System.DBNull]) { return $null }
    try { return [long][decimal]$v } catch { return $null }
}

function Safe-Dec {
    param($v)
    if ($null -eq $v -or $v -is [System.DBNull]) { return $null }
    try { return [decimal]$v } catch { return $null }
}

function Safe-Bool {
    param($v)
    if ($null -eq $v -or $v -is [System.DBNull]) { return $null }
    try { return [bool]$v } catch { return $null }
}

function Safe-Date {
    # Returns yyyy-MM-dd string. Stores 1990-01-01 raw (Sigma sentinel -- Layer 2 maps to null).
    # Returns $null for DBNull or dates before year 100 (invalid SQL edge-case artifacts).
    param($v)
    if ($null -eq $v -or $v -is [System.DBNull]) { return $null }
    try {
        $d = [datetime]$v
        if ($d.Year -lt 100) { return $null }
        return $d.ToString('yyyy-MM-dd')
    }
    catch { return $null }
}

function Safe-Time {
    # Returns HH:mm:ss string. Handles SQL time (TimeSpan), datetime, and int (seconds).
    param($v)
    if ($null -eq $v -or $v -is [System.DBNull]) { return $null }
    try {
        if ($v -is [TimeSpan]) {
            return '{0:D2}:{1:D2}:{2:D2}' -f $v.Hours, $v.Minutes, $v.Seconds
        }
        if ($v -is [int] -or $v -is [long]) {
            $ts = [TimeSpan]::FromSeconds([long]$v)
            return '{0:D2}:{1:D2}:{2:D2}' -f $ts.Hours, $ts.Minutes, $ts.Seconds
        }
        return ([datetime]$v).ToString('HH:mm:ss')
    }
    catch { return $null }
}

# =============================================================================
# EXTRACTION FUNCTIONS
# =============================================================================

# --- 1. sigma_sales (dw220sdb.DBUmBA) ----------------------------------------
# Grain: cPerKz='T' AND cVorKz=1. Delta by sale_date. Full-refresh: year by year.

function Invoke-ExtractSales {
    Write-Host "`n[1/12] sigma_sales  (dw220sdb.DBUmBA, grain cPerKz=T cVorKz=1)"
    $conflict = 'client_id,store_code,period_kind,sale_date,cashier_nr,txn_kind,product_code'

    # Retention window: first day of current month minus 16 months.
    # Mirrors the RetentionCutoff formula in Push-SigmaToSupabase.ps1 exactly.
    $today    = Get-Date
    $fromDate = if ($FullRefresh) {
        (Get-Date -Year $today.Year -Month $today.Month -Day 1).AddMonths(-16).ToString('yyyy-MM-dd')
    }
    else {
        $wm = Get-Watermark -Table 'sigma_sales' -Column 'sale_date'
        if ($wm) { $wm.AddDays(-$DeltaOverlapDays).ToString('yyyy-MM-dd') }
        else     { $today.AddDays(-$DefaultDeltaDays).ToString('yyyy-MM-dd') }
    }
    $toDate = $today.ToString('yyyy-MM-dd')

    Write-Host "  Window: $fromDate .. $toDate"

    $sql = @"
SELECT
    dtDatum                       AS sale_date,
    CAST(dArtNr  AS BIGINT)       AS product_code,
    lPersNr                       AS cashier_nr,
    cPerKz                        AS period_kind,
    cVorKz                        AS txn_kind,
    dVKUmsatz                     AS sales_incl_vat,
    dMwStWert                     AS vat_value,
    dEKUmsatz                     AS cost_value,
    dMenge                        AS qty
FROM dw220sdb.dbo.DBUmBA WITH (NOLOCK)
WHERE cPerKz = 'T'
  AND cVorKz = 1
  AND dtDatum >= '$fromDate'
  AND dtDatum <= '$toDate'
"@
    $conn = New-SqlConn -Db $DwDb
    try {
        $pushed = Push-Reader -Table 'sigma_sales' -ConflictCols $conflict -Conn $conn -Sql $sql -RowMapper {
            param($r)
            [ordered]@{
                client_id      = $ClientId
                store_code     = $StoreCode
                sale_date      = Safe-Date     $r['sale_date']
                product_code   = Safe-BigInt   $r['product_code']
                cashier_nr     = Safe-Int      $r['cashier_nr']
                period_kind    = Safe-Text     $r['period_kind']
                txn_kind       = Safe-SmallInt $r['txn_kind']
                sales_incl_vat = Safe-Dec      $r['sales_incl_vat']
                vat_value      = Safe-Dec      $r['vat_value']
                cost_value     = Safe-Dec      $r['cost_value']
                qty            = Safe-Dec      $r['qty']
            }
        }
    }
    finally { $conn.Close() }

    Write-Host "  sigma_sales: $pushed rows pushed." -ForegroundColor Green
    return $pushed
}

# --- 2. sigma_movements (dw220sdb.DBBEBE) -------------------------------------
# All movement types stored raw. Delta by movement_date. Full-refresh: year by year.

function Invoke-ExtractMovements {
    Write-Host "`n[2/12] sigma_movements  (dw220sdb.DBBEBE)"
    $conflict = 'client_id,store_code,movement_id'

    # Same 16-month retention window as sigma_sales and the push script.
    $today    = Get-Date
    $fromDate = if ($FullRefresh) {
        (Get-Date -Year $today.Year -Month $today.Month -Day 1).AddMonths(-16).ToString('yyyy-MM-dd')
    }
    else {
        $wm = Get-Watermark -Table 'sigma_movements' -Column 'movement_date'
        if ($wm) { $wm.AddDays(-$DeltaOverlapDays).ToString('yyyy-MM-dd') }
        else     { $today.AddDays(-$DefaultDeltaDays).ToString('yyyy-MM-dd') }
    }
    $toDate = $today.ToString('yyyy-MM-dd')

    Write-Host "  Window: $fromDate .. $toDate"

    $sql = @"
SELECT
    CAST(lAZaehler_AUTOINC AS BIGINT) AS movement_id,
    CAST(dArtNr  AS BIGINT)           AS product_code,
    cTyp                              AS movement_type,
    cVorg                             AS movement_process,
    dtDatum                           AS movement_date,
    tiZeit                            AS movement_time,
    dMenge                            AS qty,
    dNBestand                         AS new_soh,
    sModul                            AS module,
    cAnmeldung                        AS user_name,
    CAST(dAuftrNr AS BIGINT)          AS order_nr,
    CAST(dWeNr    AS BIGINT)          AS grv_nr,
    CAST(dLftNr   AS BIGINT)          AS supplier_nr,
    dVKWert                           AS retail_value,
    dEKWert                           AS cost_value,
    cArtText                          AS article_text,
    cLftKText                         AS supplier_text,
    sLfsNr                            AS delivery_note
FROM dw220sdb.dbo.DBBEBE WITH (NOLOCK)
WHERE dtDatum >= '$fromDate'
  AND dtDatum <= '$toDate'
"@
    $conn = New-SqlConn -Db $DwDb
    try {
        $pushed = Push-Reader -Table 'sigma_movements' -ConflictCols $conflict -Conn $conn -Sql $sql -RowMapper {
            param($r)
            [ordered]@{
                client_id        = $ClientId
                store_code       = $StoreCode
                movement_id      = Safe-BigInt $r['movement_id']
                product_code     = Safe-BigInt $r['product_code']
                movement_type    = Safe-Text   $r['movement_type']
                movement_process = Safe-Text   $r['movement_process']
                movement_date    = Safe-Date   $r['movement_date']
                movement_time    = Safe-Time   $r['movement_time']
                qty              = Safe-Dec    $r['qty']
                new_soh          = Safe-Dec    $r['new_soh']
                module           = Safe-Text   $r['module']
                user_name        = Safe-Text   $r['user_name']
                order_nr         = Safe-BigInt $r['order_nr']
                grv_nr           = Safe-BigInt $r['grv_nr']
                supplier_nr      = Safe-BigInt $r['supplier_nr']
                retail_value     = Safe-Dec    $r['retail_value']
                cost_value       = Safe-Dec    $r['cost_value']
                article_text     = Safe-Text   $r['article_text']
                supplier_text    = Safe-Text   $r['supplier_text']
                delivery_note    = Safe-Text   $r['delivery_note']
            }
        }
    }
    finally { $conn.Close() }

    Write-Host "  sigma_movements: $pushed rows pushed." -ForegroundColor Green
    return $pushed
}

# --- 3. sigma_articles (dw220sdb.DBARTS) --------------------------------------
# Article master including delisted. Always full refresh (current state).

function Invoke-ExtractArticles {
    Write-Host "`n[3/12] sigma_articles  (dw220sdb.DBARTS)"
    $conflict = 'client_id,store_code,product_code'
    $sql = @"
SELECT
    CAST(dARTNR     AS BIGINT)  AS product_code,
    cGEFUE                      AS record_status,
    cBEZ                        AS description,
    cKURZBEZ                    AS short_description,
    siMWST                      AS vat_code,
    dVK                         AS sell_price_incl_vat,
    dNPRVK                      AS net_promo_price,
    siABT                       AS department_nr,
    lWgr                        AS merch_group_nr,
    cInhalt                     AS pack_content,
    cEINH                       AS unit,
    dGEWICHT                    AS weight,
    cHerkLand                   AS origin_country,
    cARTIKELART                 AS article_type,
    cPLU                        AS plu_flag,
    cWAG                        AS scale_flag,
    cBESTANDSFUE                AS record_stock_qty,
    dtDATNEU                    AS created_date,
    dtDATVK                     AS price_change_date
FROM dw220sdb.dbo.DBARTS WITH (NOLOCK)
"@
    $conn = New-SqlConn -Db $DwDb
    try {
        $dt = Invoke-SqlTable -Conn $conn -Sql $sql
        Write-Host "  $($dt.Rows.Count) rows read from Sigma..."
        $pushed = Push-DataTable -Table 'sigma_articles' -ConflictCols $conflict -Dt $dt -RowMapper {
            param($row)
            [ordered]@{
                client_id           = $ClientId
                store_code          = $StoreCode
                product_code        = Safe-BigInt  $row['product_code']
                record_status       = Safe-Text    $row['record_status']
                description         = Safe-Text    $row['description']
                short_description   = Safe-Text    $row['short_description']
                vat_code            = Safe-SmallInt $row['vat_code']
                sell_price_incl_vat = Safe-Dec     $row['sell_price_incl_vat']
                net_promo_price     = Safe-Dec     $row['net_promo_price']
                department_nr       = Safe-SmallInt $row['department_nr']
                merch_group_nr      = Safe-Int     $row['merch_group_nr']
                pack_content        = Safe-Text    $row['pack_content']
                unit                = Safe-Text    $row['unit']
                weight              = Safe-Dec     $row['weight']
                origin_country      = Safe-Text    $row['origin_country']
                article_type        = Safe-Text    $row['article_type']
                plu_flag            = Safe-Text    $row['plu_flag']
                scale_flag          = Safe-Text    $row['scale_flag']
                record_stock_qty    = Safe-SmallInt $row['record_stock_qty']
                created_date        = Safe-Date    $row['created_date']
                price_change_date   = Safe-Date    $row['price_change_date']
            }
        }
    }
    finally { $conn.Close() }
    Write-Host "  sigma_articles: $pushed rows pushed." -ForegroundColor Green
    return $pushed
}

# --- 4. sigma_lifecycle (dw220sdb.DBStAr) -------------------------------------
# Per-article SOH and lifecycle dates. Always full refresh (current state).
# Sentinel 1990-01-01 stored raw -- Layer 2 maps to null.

function Invoke-ExtractLifecycle {
    Write-Host "`n[4/12] sigma_lifecycle  (dw220sdb.DBStAr)"
    $conflict = 'client_id,store_code,product_code'
    $sql = @"
SELECT
    CAST(dArtNr AS BIGINT)  AS product_code,
    dBestand                AS soh,
    dStdBest                AS standard_stock,
    dLfdVerk                AS running_sales,
    dtErstVerkauf           AS first_sale_date,
    dtDatUms                AS last_sale_date,
    dtDatWE                 AS last_receipt_date,
    dtDatBest               AS last_order_date,
    dtDatInv                AS last_inv_date,
    dBestInv                AS last_inv_soh
FROM dw220sdb.dbo.DBStAr WITH (NOLOCK)
"@
    $conn = New-SqlConn -Db $DwDb
    try {
        $dt = Invoke-SqlTable -Conn $conn -Sql $sql
        Write-Host "  $($dt.Rows.Count) rows read from Sigma..."
        $pushed = Push-DataTable -Table 'sigma_lifecycle' -ConflictCols $conflict -Dt $dt -RowMapper {
            param($row)
            [ordered]@{
                client_id         = $ClientId
                store_code        = $StoreCode
                product_code      = Safe-BigInt $row['product_code']
                soh               = Safe-Dec   $row['soh']
                standard_stock    = Safe-Dec   $row['standard_stock']
                running_sales     = Safe-Dec   $row['running_sales']
                first_sale_date   = Safe-Date  $row['first_sale_date']
                last_sale_date    = Safe-Date  $row['last_sale_date']
                last_receipt_date = Safe-Date  $row['last_receipt_date']
                last_order_date   = Safe-Date  $row['last_order_date']
                last_inv_date     = Safe-Date  $row['last_inv_date']
                last_inv_soh      = Safe-Dec   $row['last_inv_soh']
            }
        }
    }
    finally { $conn.Close() }
    Write-Host "  sigma_lifecycle: $pushed rows pushed." -ForegroundColor Green
    return $pushed
}

# --- L2. l2_soh_daily (daily SOH snapshot -- Layer 2 Gate 2 Option A) ----------
# Snapshots today's SOH from DBStAr into l2_soh_daily before Invoke-ExtractLifecycle
# overwrites sigma_lifecycle. ON CONFLICT DO NOTHING -- idempotent per day.
# Approved: SB-CC-L2-001 v1.0 Gate 2 Option A (PM 2026-06-07).
# Prerequisites: l2_soh_daily table must exist (sql/create_l2_soh_daily.sql).

function Invoke-SnapshotSohDaily {
    Write-Host "`n[L2] l2_soh_daily snapshot  (DBStAr -> l2_soh_daily)"
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $sql = @"
SELECT
    CAST(dArtNr  AS BIGINT) AS product_code,
    dBestand                AS soh,
    dStdBest                AS standard_stock
FROM dw220sdb.dbo.DBStAr WITH (NOLOCK)
"@
    $conn = New-SqlConn -Db $DwDb
    try {
        $dt = Invoke-SqlTable -Conn $conn -Sql $sql
        Write-Host "  $($dt.Rows.Count) rows read from DBStAr..."
    }
    finally { $conn.Close() }

    $url = "$SupabaseUrl/rest/v1/l2_soh_daily" +
           "?on_conflict=client_id,store_code,product_code,snapshot_date"
    $hdrs = @{
        'apikey'        = $SupabaseKey
        'Authorization' = "Bearer $SupabaseKey"
        'Content-Type'  = 'application/json; charset=utf-8'
        'Prefer'        = 'resolution=ignore-duplicates,return=minimal'
        'User-Agent'    = "SocialBrand-Extractor/$ScriptVersion PowerShell"
    }
    $pushed = 0
    $batch  = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $dt.Rows) {
        $null = $batch.Add([ordered]@{
            client_id      = $ClientId
            store_code     = $StoreCode
            product_code   = Safe-BigInt $row['product_code']
            snapshot_date  = $today
            soh            = Safe-Dec   $row['soh']
            standard_stock = Safe-Dec   $row['standard_stock']
        })
        if ($batch.Count -ge $BatchSize) {
            $json  = ConvertTo-Json -InputObject $batch.ToArray() -Depth 5 -Compress
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            try { $null = Invoke-RestMethod -Uri $url -Method POST -Headers $hdrs -Body $bytes -TimeoutSec 90 }
            catch { Write-Warning "  l2_soh_daily batch error: $_" }
            $pushed += $batch.Count
            $batch.Clear()
            Write-Host "    $pushed / $($dt.Rows.Count)..." -NoNewline
        }
    }
    if ($batch.Count -gt 0) {
        $json  = ConvertTo-Json -InputObject $batch.ToArray() -Depth 5 -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        try { $null = Invoke-RestMethod -Uri $url -Method POST -Headers $hdrs -Body $bytes -TimeoutSec 90 }
        catch { Write-Warning "  l2_soh_daily final batch error: $_" }
        $pushed += $batch.Count
    }
    Write-Host ""
    Write-Host "  l2_soh_daily: $pushed rows snapshotted (ignore-duplicates)." -ForegroundColor Green
    return $pushed
}

# --- 5. sigma_orders (dw220sdb.DBAufK) ----------------------------------------
# Purchase order header. Full refresh each run (35k rows, changes on receipt/invoice).

function Invoke-ExtractOrders {
    Write-Host "`n[5/12] sigma_orders  (dw220sdb.DBAufK)"
    $conflict = 'client_id,store_code,order_nr'
    $sql = @"
SELECT
    CAST(dAuftrNr     AS BIGINT)  AS order_nr,
    CAST(lLiefNr      AS BIGINT)  AS supplier_nr,
    cVorArt                       AS order_type,
    cStatu1                       AS status_1,
    cStatu2                       AS status_2,
    dtDatDis                      AS order_date,
    dtDatEWe                      AS expected_grv_date,
    dtDatWe                       AS grv_date,
    dtDatRe                       AS invoice_date,
    dtFaelligkeit                 AS due_date,
    CAST(dWeNr        AS BIGINT)  AS grv_nr,
    cRechNr                       AS invoice_nr,
    dSumVk                        AS order_retail_total,
    dSumEk                        AS order_cost_total,
    dRechW                        AS invoice_value,
    dGutW                         AS credit_value,
    dSumMw                        AS vat_total,
    siAnzPos                      AS line_count,
    sNameSped                     AS carrier,
    sExtBelNr                     AS ext_doc_nr,
    cZentAufNr                    AS central_order_nr
FROM dw220sdb.dbo.DBAufK WITH (NOLOCK)
"@
    $conn = New-SqlConn -Db $DwDb
    try {
        $dt = Invoke-SqlTable -Conn $conn -Sql $sql
        Write-Host "  $($dt.Rows.Count) rows read from Sigma..."
        $pushed = Push-DataTable -Table 'sigma_orders' -ConflictCols $conflict -Dt $dt -RowMapper {
            param($row)
            [ordered]@{
                client_id            = $ClientId
                store_code           = $StoreCode
                order_nr             = Safe-BigInt  $row['order_nr']
                supplier_nr          = Safe-BigInt  $row['supplier_nr']
                order_type           = Safe-Text    $row['order_type']
                status_1             = Safe-Text    $row['status_1']
                status_2             = Safe-Text    $row['status_2']
                order_date           = Safe-Date    $row['order_date']
                expected_grv_date    = Safe-Date    $row['expected_grv_date']
                grv_date             = Safe-Date    $row['grv_date']
                invoice_date         = Safe-Date    $row['invoice_date']
                due_date             = Safe-Date    $row['due_date']
                grv_nr               = Safe-BigInt  $row['grv_nr']
                invoice_nr           = Safe-Text    $row['invoice_nr']
                order_retail_total   = Safe-Dec     $row['order_retail_total']
                order_cost_total     = Safe-Dec     $row['order_cost_total']
                invoice_value        = Safe-Dec     $row['invoice_value']
                credit_value         = Safe-Dec     $row['credit_value']
                vat_total            = Safe-Dec     $row['vat_total']
                line_count           = Safe-SmallInt $row['line_count']
                carrier              = Safe-Text    $row['carrier']
                ext_doc_nr           = Safe-Text    $row['ext_doc_nr']
                central_order_nr     = Safe-Text    $row['central_order_nr']
            }
        }
    }
    finally { $conn.Close() }
    Write-Host "  sigma_orders: $pushed rows pushed." -ForegroundColor Green
    return $pushed
}

# --- 6. sigma_order_lines (dw220sdb.DBAufP) ------------------------------------
# Purchase order lines. Full refresh each run (685k rows).

function Invoke-ExtractOrderLines {
    Write-Host "`n[6/12] sigma_order_lines  (dw220sdb.DBAufP)"
    $conflict = 'client_id,store_code,order_nr,line_seq,product_code,pack_size'
    $sql = @"
SELECT
    CAST(dAuftrNr AS BIGINT)  AS order_nr,
    lFolg                     AS line_seq,
    CAST(dArtNr   AS BIGINT)  AS product_code,
    siBEH                     AS pack_size,
    CAST(lLiefNr  AS BIGINT)  AS supplier_nr,
    cStatPos                  AS line_status,
    cBez                      AS description,
    siMwSt                    AS vat_code,
    dBeMg                     AS ordered_qty,
    dMgWe                     AS received_qty,
    dVK                       AS sell_price,
    dEK                       AS cost,
    dRechEKL                  AS invoiced_cost,
    dRechMenge                AS invoiced_qty,
    dRechPosSum               AS invoiced_line_total
FROM dw220sdb.dbo.DBAufP WITH (NOLOCK)
"@
    $conn = New-SqlConn -Db $DwDb
    try {
        $dt = Invoke-SqlTable -Conn $conn -Sql $sql -TimeoutSecs 600
        Write-Host "  $($dt.Rows.Count) rows read from Sigma..."
        $pushed = Push-DataTable -Table 'sigma_order_lines' -ConflictCols $conflict -Dt $dt -RowMapper {
            param($row)
            [ordered]@{
                client_id            = $ClientId
                store_code           = $StoreCode
                order_nr             = Safe-BigInt  $row['order_nr']
                line_seq             = Safe-Int     $row['line_seq']
                product_code         = Safe-BigInt  $row['product_code']
                pack_size            = Safe-SmallInt $row['pack_size']
                supplier_nr          = Safe-BigInt  $row['supplier_nr']
                line_status          = Safe-Text    $row['line_status']
                description          = Safe-Text    $row['description']
                vat_code             = Safe-SmallInt $row['vat_code']
                ordered_qty          = Safe-Dec     $row['ordered_qty']
                received_qty         = Safe-Dec     $row['received_qty']
                sell_price           = Safe-Dec     $row['sell_price']
                cost                 = Safe-Dec     $row['cost']
                invoiced_cost        = Safe-Dec     $row['invoiced_cost']
                invoiced_qty         = Safe-Dec     $row['invoiced_qty']
                invoiced_line_total  = Safe-Dec     $row['invoiced_line_total']
            }
        }
    }
    finally { $conn.Close() }
    Write-Host "  sigma_order_lines: $pushed rows pushed." -ForegroundColor Green
    return $pushed
}

# --- 7. sigma_supplier_master (dw220sdb.DBLFTS) --------------------------------
# Supplier master. Full refresh each run.

function Invoke-ExtractSupplierMaster {
    Write-Host "`n[7/12] sigma_supplier_master  (dw220sdb.DBLFTS)"
    $conflict = 'client_id,store_code,supplier_nr'
    $sql = @"
SELECT
    CAST(LFTNR          AS BIGINT)  AS supplier_nr,
    TYP                             AS supplier_type,
    lGruppe                         AS supplier_group,
    LNAME                           AS name,
    KURZ1                           AS short_name,
    KURZ2                           AS short_name_2,
    STATUS                          AS status,
    BBN                             AS bbn,
    CAST(ILN            AS BIGINT)  AS gln,
    KREDNR                          AS creditor_nr,
    BNAME                           AS order_contact_name,
    BORT                            AS order_city,
    BTELE                           AS order_phone,
    RNAME                           AS remit_name,
    cEMail                          AS email,
    SKONTO1                         AS settle_disc_1_pct,
    TAG1                            AS settle_disc_1_days,
    SKONTO2                         AS settle_disc_2_pct,
    TAG2                            AS settle_disc_2_days,
    KONDNR                          AS terms_nr,
    lBestellart                     AS order_method,
    DATAB                           AS valid_from,
    DATBIS                          AS valid_to,
    dtDatNeuAnlage                  AS created_date
FROM dw220sdb.dbo.DBLFTS WITH (NOLOCK)
"@
    $conn = New-SqlConn -Db $DwDb
    try {
        $dt = Invoke-SqlTable -Conn $conn -Sql $sql
        Write-Host "  $($dt.Rows.Count) rows read from Sigma..."
        $pushed = Push-DataTable -Table 'sigma_supplier_master' -ConflictCols $conflict -Dt $dt -RowMapper {
            param($row)
            [ordered]@{
                client_id            = $ClientId
                store_code           = $StoreCode
                supplier_nr          = Safe-BigInt  $row['supplier_nr']
                supplier_type        = Safe-Text    $row['supplier_type']
                supplier_group       = Safe-Int     $row['supplier_group']
                name                 = Safe-Text    $row['name']
                short_name           = Safe-Text    $row['short_name']
                short_name_2         = Safe-Text    $row['short_name_2']
                status               = Safe-Text    $row['status']
                bbn                  = Safe-Text    $row['bbn']
                gln                  = Safe-BigInt  $row['gln']
                creditor_nr          = Safe-Text    $row['creditor_nr']
                order_contact_name   = Safe-Text    $row['order_contact_name']
                order_city           = Safe-Text    $row['order_city']
                order_phone          = Safe-Text    $row['order_phone']
                remit_name           = Safe-Text    $row['remit_name']
                email                = Safe-Text    $row['email']
                settle_disc_1_pct    = Safe-Dec     $row['settle_disc_1_pct']
                settle_disc_1_days   = Safe-SmallInt $row['settle_disc_1_days']
                settle_disc_2_pct    = Safe-Dec     $row['settle_disc_2_pct']
                settle_disc_2_days   = Safe-SmallInt $row['settle_disc_2_days']
                terms_nr             = Safe-SmallInt $row['terms_nr']
                order_method         = Safe-Int     $row['order_method']
                valid_from           = Safe-Date    $row['valid_from']
                valid_to             = Safe-Date    $row['valid_to']
                created_date         = Safe-Date    $row['created_date']
            }
        }
    }
    finally { $conn.Close() }
    Write-Host "  sigma_supplier_master: $pushed rows pushed." -ForegroundColor Green
    return $pushed
}

# --- 8. sigma_supplier_link (dw220sdb.DBLFTB) ---------------------------------
# Article-supplier link. Pack size, list cost, origin. Full refresh each run.

function Invoke-ExtractSupplierLink {
    Write-Host "`n[8/12] sigma_supplier_link  (dw220sdb.DBLFTB)"
    $conflict = 'client_id,store_code,supplier_nr,product_code,pack_size'
    $sql = @"
SELECT
    CAST(lLIEFNR        AS BIGINT)  AS supplier_nr,
    CAST(dARTNR         AS BIGINT)  AS product_code,
    siBEH                           AS pack_size,
    dEKL                            AS list_cost,
    cSTATUS                         AS status,
    cArtNrL                         AS supplier_article_nr,
    cHerk                           AS origin_code,
    CAST(dEAN           AS BIGINT)  AS ean,
    ceantyp                         AS ean_type,
    dtDATEK                         AS cost_date,
    dtDATAB                         AS valid_from,
    dtDATBIS                        AS valid_to,
    dtLetztSAend                    AS last_change_date
FROM dw220sdb.dbo.DBLFTB WITH (NOLOCK)
"@
    $conn = New-SqlConn -Db $DwDb
    try {
        $dt = Invoke-SqlTable -Conn $conn -Sql $sql -TimeoutSecs 300
        Write-Host "  $($dt.Rows.Count) rows read from Sigma..."
        $pushed = Push-DataTable -Table 'sigma_supplier_link' -ConflictCols $conflict -Dt $dt -RowMapper {
            param($row)
            [ordered]@{
                client_id           = $ClientId
                store_code          = $StoreCode
                supplier_nr         = Safe-BigInt  $row['supplier_nr']
                product_code        = Safe-BigInt  $row['product_code']
                pack_size           = Safe-SmallInt $row['pack_size']
                list_cost           = Safe-Dec     $row['list_cost']
                status              = Safe-Text    $row['status']
                supplier_article_nr = Safe-Text    $row['supplier_article_nr']
                origin_code         = Safe-Text    $row['origin_code']
                ean                 = Safe-BigInt  $row['ean']
                ean_type            = Safe-Text    $row['ean_type']
                cost_date           = Safe-Date    $row['cost_date']
                valid_from          = Safe-Date    $row['valid_from']
                valid_to            = Safe-Date    $row['valid_to']
                last_change_date    = Safe-Date    $row['last_change_date']
            }
        }
    }
    finally { $conn.Close() }
    Write-Host "  sigma_supplier_link: $pushed rows pushed." -ForegroundColor Green
    return $pushed
}

# --- 9. sigma_trade_terms (dw220sdb.DBKOND) -----------------------------------
# Supplier trade terms and rebates. Full refresh each run.

function Invoke-ExtractTradeTerms {
    Write-Host "`n[9/12] sigma_trade_terms  (dw220sdb.DBKOND)"
    $conflict = 'client_id,store_code,term_id'
    $sql = @"
SELECT
    CAST(lAZaehler_AUTOINC AS BIGINT)  AS term_id,
    cKZKond                            AS condition_kind,
    CAST(lLiefnr           AS BIGINT)  AS supplier_nr,
    CAST(dArtnr            AS BIGINT)  AS product_code,
    lWgr                               AS merch_group_nr,
    siGruppe                           AS group_ref,
    cBez                               AS description,
    dRabatt                            AS discount,
    dMgAb                              AS min_qty,
    cBasis                             AS basis,
    cArt                               AS kind,
    siStufe                            AS tier,
    DatAb                              AS valid_from,
    DatBis                             AS valid_to
FROM dw220sdb.dbo.DBKOND WITH (NOLOCK)
"@
    $conn = New-SqlConn -Db $DwDb
    try {
        $dt = Invoke-SqlTable -Conn $conn -Sql $sql
        Write-Host "  $($dt.Rows.Count) rows read from Sigma..."
        $pushed = Push-DataTable -Table 'sigma_trade_terms' -ConflictCols $conflict -Dt $dt -RowMapper {
            param($row)
            [ordered]@{
                client_id      = $ClientId
                store_code     = $StoreCode
                term_id        = Safe-BigInt  $row['term_id']
                condition_kind = Safe-Text    $row['condition_kind']
                supplier_nr    = Safe-BigInt  $row['supplier_nr']
                product_code   = Safe-BigInt  $row['product_code']
                merch_group_nr = Safe-Int     $row['merch_group_nr']
                group_ref      = Safe-SmallInt $row['group_ref']
                description    = Safe-Text    $row['description']
                discount       = Safe-Dec     $row['discount']
                min_qty        = Safe-Dec     $row['min_qty']
                basis          = Safe-Text    $row['basis']
                kind           = Safe-Text    $row['kind']
                tier           = Safe-SmallInt $row['tier']
                valid_from     = Safe-Date    $row['valid_from']
                valid_to       = Safe-Date    $row['valid_to']
            }
        }
    }
    finally { $conn.Close() }
    Write-Host "  sigma_trade_terms: $pushed rows pushed." -ForegroundColor Green
    return $pushed
}

# --- 10. sigma_ean_master (EASYDB.IntelliAcc.IntellistoX_EAN_Master) ----------
# Barcode-to-article bridge. Only populated map on this estate.
# EASYDB drops and recreates this table nightly at ~19:20.
# Extraction is auto-skipped if the clock is inside 19:00-19:30.

function Invoke-ExtractEanMaster {
    Write-Host "`n[10/12] sigma_ean_master  (EASYDB.IntelliAcc.IntellistoX_EAN_Master)"

    # Time-window guard
    $now = Get-Date
    if ($now.Hour -eq $EasyDbBlockHourStart -and $now.Minute -lt $EasyDbBlockMinEnd) {
        Write-Warning "  SKIPPED -- clock is $($now.ToString('HH:mm')), inside the 19:00-19:30 EASYDB rebuild window. Run again after 19:30."
        return 0
    }
    if ($SkipEan) {
        Write-Warning "  SKIPPED -- -SkipEan flag was set."
        return 0
    }

    $conflict = 'client_id,store_code,barcode,product_code'
    # Dedup on (dREFNR, dARTNR): EASYDB stores multiple EAN-system rows per
    # barcode+product (EAN13 + ITF14 etc).  Sending both in the same 500-row
    # batch triggers "ON CONFLICT DO UPDATE command cannot affect row a second
    # time" (PG-21000).  ROW_NUMBER PARTITION BY (dREFNR,dARTNR) ORDER BY
    # Sorter ASC keeps the primary EAN designation (lowest Sorter) per pair.
    $sql = @"
WITH ranked AS (
    SELECT
        CONVERT(varchar(20), CONVERT(bigint, ROUND(dREFNR, 0))) AS barcode,
        CAST(dARTNR  AS BIGINT)  AS product_code,
        cSYSTEM                  AS ean_system,
        cTYP                     AS ean_type,
        dPrufZif                 AS check_digit,
        Orderable                AS orderable,
        Sorter                   AS sorter,
        ROW_NUMBER() OVER (
            PARTITION BY dREFNR, dARTNR
            ORDER BY Sorter ASC, dPrufZif ASC
        ) AS rn
    FROM IntelliAcc.IntellistoX_EAN_Master WITH (NOLOCK)
)
SELECT barcode, product_code, ean_system, ean_type,
       check_digit, orderable, sorter
FROM   ranked
WHERE  rn = 1
"@
    try {
        $conn = New-SqlConn -Db $EasyDb
    }
    catch {
        Write-Warning "  SKIPPED -- could not connect to EASYDB database. ($_)"
        return 0
    }
    try {
        $dt = Invoke-SqlTable -Conn $conn -Sql $sql
        Write-Host "  $($dt.Rows.Count) rows read from EASYDB..."

        # Delete all existing sigma_ean_master rows for this store before inserting.
        # Pre-v1.7 runs stored barcodes via CAST(dREFNR AS BIGINT), which truncates
        # 13-digit EAN-13 codes to 12 digits. The conflict key includes barcode, so
        # a truncated row (e.g. '600106068482') and its corrected row ('6001060684820')
        # are different keys -- upsert inserts the correct row but leaves the stale one.
        # Deleting first ensures the table reflects only the current EASYDB state.
        $delUrl  = "$SupabaseUrl/rest/v1/sigma_ean_master?store_code=eq.$StoreCode&client_id=eq.$ClientId"
        $delHdrs = @{
            'apikey'        = $SupabaseKey
            'Authorization' = "Bearer $SupabaseKey"
            'Prefer'        = 'return=minimal'
            'User-Agent'    = "SocialBrand-Extractor/$ScriptVersion PowerShell"
        }
        try {
            $null = Invoke-RestMethod -Uri $delUrl -Method DELETE -Headers $delHdrs -TimeoutSec 30
            Write-Host "  sigma_ean_master: cleared $StoreCode rows before full refresh." -ForegroundColor Yellow
        }
        catch {
            Write-Warning "  sigma_ean_master: pre-delete failed ($_) -- proceeding with upsert (stale rows may persist)."
        }

        $pushed = Push-DataTable -Table 'sigma_ean_master' -ConflictCols $conflict -Dt $dt -RowMapper {
            param($row)
            [ordered]@{
                client_id    = $ClientId
                store_code   = $StoreCode
                barcode      = Safe-Text    $row['barcode']
                product_code = Safe-BigInt  $row['product_code']
                ean_system   = Safe-Text    $row['ean_system']
                ean_type     = Safe-Text    $row['ean_type']
                check_digit  = Safe-SmallInt $row['check_digit']
                orderable    = Safe-Bool    $row['orderable']
                sorter       = Safe-Int     $row['sorter']
            }
        }
    }
    finally { $conn.Close() }
    Write-Host "  sigma_ean_master: $pushed rows pushed." -ForegroundColor Green
    return $pushed
}

# --- 10b. sigma_scan_refs (dw220sdb.DBREFE -- R25 NATIVE source-of-record) ----

function Get-Gs1CheckDigit {
    # GS1 check digit over a 12-digit body (EAN-13). For 11-digit UPC-A bodies
    # the same algorithm applies after left-padding to 12 with '0'.
    # Position weighting (1-indexed over the body): odd x1, even x3.
    param([string]$Body)
    $padded = $Body.PadLeft(12, '0')
    $sum = 0
    for ($i = 0; $i -lt 12; $i++) {
        $d = [int][string]$padded[$i]
        if ((($i + 1) % 2) -eq 0) { $sum += $d * 3 } else { $sum += $d }
    }
    return ((10 - ($sum % 10)) % 10)
}

function Invoke-ExtractScanRefs {
    # PM ruling 2026-06-11 18:50 (R25): dw220sdb.dbo.DBREFE is Sigma's NATIVE
    # scan-reference table -- the source-of-record for scan codes. Sigma stores
    # CHECK-DIGIT-STRIPPED bodies natively (12-digit EAN-13 bodies, 11-digit
    # UPC-A bodies, 6/7-digit PLUs); the full 13-digit code exists nowhere on
    # the server. The GS1 check-digit computation is the APPROVED decode, with
    # provenance stamped per row (code_kind + decode_method). Proof: 15,161 of
    # 15,182 TAC EAN-13s on 10116 exactly = len-12 body + computed check digit.
    # IntellistoX (sigma_ean_master) stays as derivative cross-check during
    # transition. Full refresh: delete store rows, then insert.
    Write-Host "`n[10b/16] sigma_scan_refs  (dw220sdb.DBREFE -- native scan references)"
    $conflict = 'client_id,store_code,scan_code,product_code'
    $sql = @"
WITH ranked AS (
    SELECT
        CONVERT(varchar(20), CONVERT(decimal(20,0), ROUND(dREFNR, 0))) AS scan_code,
        CONVERT(bigint, ROUND(dARTNR, 0)) AS product_code,
        cSYSTEM        AS system_flag,
        cTYP           AS type_flag,
        dPACK          AS pack_size,
        siMENGE        AS qty_flag,
        siGESPERRT     AS blocked_flag,
        cHerk          AS origin_flag,
        dtDATE         AS ref_date,
        dtDatumAnlage  AS created_date,
        dtLetztAend    AS last_changed,
        ROW_NUMBER() OVER (
            PARTITION BY dREFNR, dARTNR
            ORDER BY dtLetztAend DESC
        ) AS rn
    FROM dw220sdb.dbo.DBREFE WITH (NOLOCK)
)
SELECT scan_code, product_code, system_flag, type_flag, pack_size, qty_flag,
       blocked_flag, origin_flag, ref_date, created_date, last_changed
FROM   ranked
WHERE  rn = 1
"@
    $conn = New-SqlConn -Db $DwDb
    try {
        $dt = Invoke-SqlTable -Conn $conn -Sql $sql
        Write-Host "  $($dt.Rows.Count) rows read from DBREFE..."

        # Full refresh: clear this store's rows first (same rationale as
        # sigma_ean_master v1.9 -- scan_code is in the conflict key, so stale
        # codes would otherwise persist forever).
        $delUrl  = "$SupabaseUrl/rest/v1/sigma_scan_refs?store_code=eq.$StoreCode&client_id=eq.$ClientId"
        $delHdrs = @{
            'apikey'        = $SupabaseKey
            'Authorization' = "Bearer $SupabaseKey"
            'Prefer'        = 'return=minimal'
            'User-Agent'    = "SocialBrand-Extractor/$ScriptVersion PowerShell"
        }
        try {
            $null = Invoke-RestMethod -Uri $delUrl -Method DELETE -Headers $delHdrs -TimeoutSec 30
            Write-Host "  sigma_scan_refs: cleared $StoreCode rows before full refresh." -ForegroundColor Yellow
        }
        catch {
            Write-Warning "  sigma_scan_refs: pre-delete failed ($_) -- proceeding with upsert (stale rows may persist)."
        }

        $pushed = Push-DataTable -Table 'sigma_scan_refs' -ConflictCols $conflict -Dt $dt -RowMapper {
            param($row)
            $code   = Safe-Text $row['scan_code']
            $kind   = 'OTHER'
            $full   = $code
            $method = 'AS_IS'
            if ($code -and $code -match '^[0-9]+$') {
                if ($code.Length -eq 12) {
                    $kind = 'EAN13_BODY'; $full = $code + (Get-Gs1CheckDigit $code); $method = 'CHECK_DIGIT_APPENDED'
                }
                elseif ($code.Length -eq 11) {
                    $kind = 'UPCA_BODY';  $full = $code + (Get-Gs1CheckDigit $code); $method = 'CHECK_DIGIT_APPENDED'
                }
                elseif ($code.Length -eq 13) {
                    $kind = 'FULL13'
                }
                elseif ($code.Length -le 8) {
                    $kind = 'PLU'
                }
            }
            [ordered]@{
                client_id     = $ClientId
                store_code    = $StoreCode
                scan_code     = $code
                product_code  = Safe-BigInt $row['product_code']
                code_kind     = $kind
                barcode_full  = $full
                decode_method = $method
                system_flag   = Safe-Text $row['system_flag']
                type_flag     = Safe-Text $row['type_flag']
                pack_size     = Safe-Dec  $row['pack_size']
                qty_flag      = Safe-Dec  $row['qty_flag']
                blocked_flag  = Safe-Text $row['blocked_flag']
                origin_flag   = Safe-Text $row['origin_flag']
                ref_date      = Safe-Date $row['ref_date']
                created_date  = Safe-Date $row['created_date']
                last_changed  = Safe-Date $row['last_changed']
            }
        }
    }
    finally { $conn.Close() }
    Write-Host "  sigma_scan_refs: $pushed rows pushed." -ForegroundColor Green
    return $pushed
}

# --- 11. sigma_departments (dw220sdb.DBABTL) ----------------------------------

function Invoke-ExtractDepartments {
    Write-Host "`n[11/12] sigma_departments  (dw220sdb.DBABTL)"
    $conflict = 'client_id,store_code,department_nr'
    $sql = @"
SELECT
    ABTLNR   AS department_nr,
    ABTLBEZ  AS name,
    ABTLMWST AS vat_code,
    sKurz    AS short_code
FROM dw220sdb.dbo.DBABTL WITH (NOLOCK)
"@
    $conn = New-SqlConn -Db $DwDb
    try {
        $dt = Invoke-SqlTable -Conn $conn -Sql $sql
        Write-Host "  $($dt.Rows.Count) rows read from Sigma..."
        $pushed = Push-DataTable -Table 'sigma_departments' -ConflictCols $conflict -Dt $dt -RowMapper {
            param($row)
            [ordered]@{
                client_id     = $ClientId
                store_code    = $StoreCode
                department_nr = Safe-SmallInt $row['department_nr']
                name          = Safe-Text     $row['name']
                vat_code      = Safe-SmallInt $row['vat_code']
                short_code    = Safe-Text     $row['short_code']
            }
        }
    }
    finally { $conn.Close() }
    Write-Host "  sigma_departments: $pushed rows pushed." -ForegroundColor Green
    return $pushed
}

# --- 12. sigma_subdepts (dw220sdb.DBWGRP) -------------------------------------

function Invoke-ExtractSubdepts {
    Write-Host "`n[12/12] sigma_subdepts  (dw220sdb.DBWGRP)"
    $conflict = 'client_id,store_code,merch_group_nr'
    $sql = @"
SELECT
    lWgr       AS merch_group_nr,
    WGRBEZ     AS name,
    WGRZUGABT  AS parent_department_nr,
    WGRMWST    AS vat_code,
    sKurz      AS short_code,
    MINDSPAN   AS min_margin_pct
FROM dw220sdb.dbo.DBWGRP WITH (NOLOCK)
"@
    $conn = New-SqlConn -Db $DwDb
    try {
        $dt = Invoke-SqlTable -Conn $conn -Sql $sql
        Write-Host "  $($dt.Rows.Count) rows read from Sigma..."
        $pushed = Push-DataTable -Table 'sigma_subdepts' -ConflictCols $conflict -Dt $dt -RowMapper {
            param($row)
            [ordered]@{
                client_id             = $ClientId
                store_code            = $StoreCode
                merch_group_nr        = Safe-Int    $row['merch_group_nr']
                name                  = Safe-Text   $row['name']
                parent_department_nr  = Safe-SmallInt $row['parent_department_nr']
                vat_code              = Safe-SmallInt $row['vat_code']
                short_code            = Safe-Text   $row['short_code']
                min_margin_pct        = Safe-Dec    $row['min_margin_pct']
            }
        }
    }
    finally { $conn.Close() }
    Write-Host "  sigma_subdepts: $pushed rows pushed." -ForegroundColor Green
    return $pushed
}

# --- 13. sigma_promotions (dw220sdb.DBAKTK) -----------------------------------
# Promotion headers. Full refresh each run (small table, headers change).

function Invoke-ExtractPromotions {
    Write-Host "`n[13] sigma_promotions  (dw220sdb.DBAKTK)"
    $conflict = 'client_id,store_code,promo_nr'
    $sql = @"
SELECT
    CAST(lNummer     AS BIGINT)  AS promo_nr,
    dtStart                      AS start_date,
    dtEnde                       AS end_date,
    siArt                        AS promo_type,
    cText                        AS description,
    siKeineAend                  AS no_changes,
    cStatus                      AS status
FROM dw220sdb.dbo.DBAKTK WITH (NOLOCK)
"@
    $conn = New-SqlConn -Db $DwDb
    try {
        $dt = Invoke-SqlTable -Conn $conn -Sql $sql
        Write-Host "  $($dt.Rows.Count) rows read from Sigma..."
        $pushed = Push-DataTable -Table 'sigma_promotions' -ConflictCols $conflict -Dt $dt -RowMapper {
            param($row)
            [ordered]@{
                client_id   = $ClientId
                store_code  = $StoreCode
                promo_nr    = Safe-BigInt   $row['promo_nr']
                start_date  = Safe-Date     $row['start_date']
                end_date    = Safe-Date     $row['end_date']
                promo_type  = Safe-SmallInt $row['promo_type']
                description = Safe-Text     $row['description']
                no_changes  = Safe-SmallInt $row['no_changes']
                status      = Safe-Text     $row['status']
            }
        }
    }
    finally { $conn.Close() }
    Write-Host "  sigma_promotions: $pushed rows pushed." -ForegroundColor Green
    return $pushed
}

# --- 14. sigma_promotion_articles (dw220sdb.DBAKTP) ---------------------------
# Promotion lines. Full refresh each run.

function Invoke-ExtractPromotionArticles {
    Write-Host "`n[14] sigma_promotion_articles  (dw220sdb.DBAKTP)"
    $conflict = 'client_id,store_code,line_id'
    $sql = @"
SELECT
    CAST(lAZaehler   AS BIGINT)  AS line_id,
    CAST(lNummer     AS BIGINT)  AS promo_nr,
    CAST(dArtNr      AS BIGINT)  AS product_code,
    siKz                         AS indicator,
    dtDatum                      AS promo_date,
    dVkAlt                       AS old_price,
    dVkNeu                       AS new_price,
    dtStart                      AS start_date,
    dtEnde                       AS end_date,
    cStatus                      AS status,
    cEbene                       AS level,
    dEKListe                     AS list_cost,
    dPMg7Ta1                     AS promo_qty_d1,
    dPMg7Ta2                     AS promo_qty_d2,
    dPMg7Ta3                     AS promo_qty_d3,
    dPMg7Ta4                     AS promo_qty_d4,
    dPMg7Ta5                     AS promo_qty_d5,
    dPMg7Ta6                     AS promo_qty_d6,
    dPMg7Ta7                     AS promo_qty_d7,
    dPMg7Wo1                     AS promo_qty_w1,
    dPMg7Wo2                     AS promo_qty_w2,
    dPMg7Wo3                     AS promo_qty_w3,
    dPMg7Wo4                     AS promo_qty_w4,
    dPMg7Wo5                     AS promo_qty_w5,
    dPMg7Wo6                     AS promo_qty_w6,
    dMenge                       AS qty,
    dtVkLetzt                    AS last_sale_date,
    CAST(lFolgNr     AS BIGINT)  AS follow_nr,
    dBewert                      AS valuation,
    siMultiV                     AS multi_buy_type,
    dRabattDM                    AS discount_amount,
    dRabattProz                  AS discount_pct,
    dRabattDMAlt                 AS discount_amount_old,
    dRabattProzAlt               AS discount_pct_old,
    dVkAlt2                      AS old_price_2,
    dVkNeu2                      AS new_price_2,
    dEndBestand                  AS end_stock,
    siRabVar                     AS discount_variant,
    CAST(lMultiGr    AS BIGINT)  AS multi_buy_group,
    siMultiMg                    AS multi_buy_min_qty,
    CAST(lMMGr       AS BIGINT)  AS multi_group_ref
FROM dw220sdb.dbo.DBAKTP WITH (NOLOCK)
"@
    $conn = New-SqlConn -Db $DwDb
    try {
        $dt = Invoke-SqlTable -Conn $conn -Sql $sql -TimeoutSecs 300
        Write-Host "  $($dt.Rows.Count) rows read from Sigma..."
        $pushed = Push-DataTable -Table 'sigma_promotion_articles' -ConflictCols $conflict -Dt $dt -RowMapper {
            param($row)
            [ordered]@{
                client_id           = $ClientId
                store_code          = $StoreCode
                line_id             = Safe-BigInt   $row['line_id']
                promo_nr            = Safe-BigInt   $row['promo_nr']
                product_code        = Safe-BigInt   $row['product_code']
                indicator           = Safe-SmallInt $row['indicator']
                promo_date          = Safe-Date     $row['promo_date']
                old_price           = Safe-Dec      $row['old_price']
                new_price           = Safe-Dec      $row['new_price']
                start_date          = Safe-Date     $row['start_date']
                end_date            = Safe-Date     $row['end_date']
                status              = Safe-Text     $row['status']
                level               = Safe-Text     $row['level']
                list_cost           = Safe-Dec      $row['list_cost']
                promo_qty_d1        = Safe-Dec      $row['promo_qty_d1']
                promo_qty_d2        = Safe-Dec      $row['promo_qty_d2']
                promo_qty_d3        = Safe-Dec      $row['promo_qty_d3']
                promo_qty_d4        = Safe-Dec      $row['promo_qty_d4']
                promo_qty_d5        = Safe-Dec      $row['promo_qty_d5']
                promo_qty_d6        = Safe-Dec      $row['promo_qty_d6']
                promo_qty_d7        = Safe-Dec      $row['promo_qty_d7']
                promo_qty_w1        = Safe-Dec      $row['promo_qty_w1']
                promo_qty_w2        = Safe-Dec      $row['promo_qty_w2']
                promo_qty_w3        = Safe-Dec      $row['promo_qty_w3']
                promo_qty_w4        = Safe-Dec      $row['promo_qty_w4']
                promo_qty_w5        = Safe-Dec      $row['promo_qty_w5']
                promo_qty_w6        = Safe-Dec      $row['promo_qty_w6']
                qty                 = Safe-Dec      $row['qty']
                last_sale_date      = Safe-Date     $row['last_sale_date']
                follow_nr           = Safe-BigInt   $row['follow_nr']
                valuation           = Safe-Dec      $row['valuation']
                multi_buy_type      = Safe-SmallInt $row['multi_buy_type']
                discount_amount     = Safe-Dec      $row['discount_amount']
                discount_pct        = Safe-Dec      $row['discount_pct']
                discount_amount_old = Safe-Dec      $row['discount_amount_old']
                discount_pct_old    = Safe-Dec      $row['discount_pct_old']
                old_price_2         = Safe-Dec      $row['old_price_2']
                new_price_2         = Safe-Dec      $row['new_price_2']
                end_stock           = Safe-Dec      $row['end_stock']
                discount_variant    = Safe-SmallInt $row['discount_variant']
                multi_buy_group     = Safe-BigInt   $row['multi_buy_group']
                multi_buy_min_qty   = Safe-SmallInt $row['multi_buy_min_qty']
                multi_group_ref     = Safe-BigInt   $row['multi_group_ref']
            }
        }
    }
    finally { $conn.Close() }
    Write-Host "  sigma_promotion_articles: $pushed rows pushed." -ForegroundColor Green
    return $pushed
}

# =============================================================================
# MAIN
# =============================================================================

$startTime = Get-Date
# Clear any stale error file from the previous run so the push script does not
# read stale diagnostics if this run succeeds or fails for a different reason.
try { Remove-Item 'C:\socialbrand\extractor_last_error.txt' -Force -ErrorAction SilentlyContinue } catch {}

Write-Host "=================================================="
Write-Host " Sigma Layer 1 Extractor  $ScriptVersion"
Write-Host " Store  : $StoreName ($StoreCode)"
Write-Host " Mode   : $(if ($FullRefresh) { 'FULL REFRESH' } else { 'DELTA' })"
Write-Host " Table  : $(if ($TableName) { $TableName } else { 'all 14' })"
Write-Host " Started: $($startTime.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "=================================================="

$totals = @{}

$runAll  = ($TableName -eq '')
$run     = { param($name) $runAll -or $TableName -eq $name }

# v1.10: per-table push_log row (push_type='l1_table') for every table this run
# touches. R22 / SB-CC-DASH-TRUTH-001 P0.1: a green night with a dark table must
# be structurally impossible -- 80175 sigma_sales was dark for 2 days while the
# nightly summary row looked green. Non-fatal: a failed log write never fails
# the extraction.
function Send-TableLog {
    param([string]$Table, [string]$Status, [int]$Rows, [datetime]$StartTime, [string]$ErrorMsg)
    try {
        $rec = [ordered]@{
            store_code       = $StoreCode
            push_type        = 'l1_table'
            table_name       = $Table
            status           = $Status
            script_version   = $ScriptVersion
            rows_pushed      = $Rows
            duration_seconds = [int]((Get-Date) - $StartTime).TotalSeconds
            started_at       = $StartTime.ToString('o')
            completed_at     = (Get-Date -Format 'o')
        }
        if ($ErrorMsg) { $rec['error_message'] = $ErrorMsg.Substring(0, [Math]::Min(490, $ErrorMsg.Length)) }
        $json  = ConvertTo-Json -InputObject $rec -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $hdrs  = @{
            'apikey'        = $SupabaseKey
            'Authorization' = "Bearer $SupabaseKey"
            'Content-Type'  = 'application/json; charset=utf-8'
            'Prefer'        = 'return=minimal'
            'User-Agent'    = "SocialBrand-Extractor/$ScriptVersion PowerShell"
        }
        $null = Invoke-RestMethod -Uri "$SupabaseUrl/rest/v1/push_log" -Method POST -Headers $hdrs -Body $bytes -TimeoutSec 15
    }
    catch {
        Write-Warning "  push_log l1_table row failed (non-fatal): $_"
    }
}

function Invoke-LoggedStep {
    param([string]$Name, [string]$Table, [scriptblock]$Step)
    if (-not ($runAll -or $TableName -eq $Name)) { return }
    $t0 = Get-Date
    try {
        $rows = & $Step
        $totals[$Table] = $rows
        Send-TableLog -Table $Table -Status 'SUCCESS' -Rows ([int]$rows) -StartTime $t0
    }
    catch {
        Send-TableLog -Table $Table -Status 'FAILED' -Rows 0 -StartTime $t0 -ErrorMsg $_.ToString()
        throw
    }
}

try {
    # v1.12: probe dw220sdb before the chain. Every table except sigma_ean_master
    # (EASYDB-sourced) reads dw220sdb; if Sigma EOD still holds it, wait for the
    # release instead of dying at the first connection (2026-06-11: 4/5 stores
    # failed at 20:01-20:12 on a login that worked at 19:40).
    if ($TableName -ne 'ean') { Wait-ForSigmaDw }

    Invoke-LoggedStep 'sales'             'sigma_sales'              { Invoke-ExtractSales }
    Invoke-LoggedStep 'movements'         'sigma_movements'          { Invoke-ExtractMovements }
    Invoke-LoggedStep 'articles'          'sigma_articles'           { Invoke-ExtractArticles }
    Invoke-LoggedStep 'soh_daily'         'l2_soh_daily'             { Invoke-SnapshotSohDaily }
    Invoke-LoggedStep 'lifecycle'         'sigma_lifecycle'          { Invoke-ExtractLifecycle }
    Invoke-LoggedStep 'orders'            'sigma_orders'             { Invoke-ExtractOrders }
    Invoke-LoggedStep 'orderlines'        'sigma_order_lines'        { Invoke-ExtractOrderLines }
    Invoke-LoggedStep 'suppliermaster'    'sigma_supplier_master'    { Invoke-ExtractSupplierMaster }
    Invoke-LoggedStep 'supplierlink'      'sigma_supplier_link'      { Invoke-ExtractSupplierLink }
    Invoke-LoggedStep 'tradeterms'        'sigma_trade_terms'        { Invoke-ExtractTradeTerms }
    Invoke-LoggedStep 'ean'               'sigma_ean_master'         { Invoke-ExtractEanMaster }
    Invoke-LoggedStep 'scanrefs'          'sigma_scan_refs'          { Invoke-ExtractScanRefs }
    Invoke-LoggedStep 'departments'       'sigma_departments'        { Invoke-ExtractDepartments }
    Invoke-LoggedStep 'subdepts'          'sigma_subdepts'           { Invoke-ExtractSubdepts }
    Invoke-LoggedStep 'promotions'        'sigma_promotions'         { Invoke-ExtractPromotions }
    Invoke-LoggedStep 'promotionarticles' 'sigma_promotion_articles' { Invoke-ExtractPromotionArticles }
}
catch {
    $fatalMsg = $_.ToString()
    Write-Host "`nERROR during extract: $fatalMsg" -ForegroundColor Red

    # SB-CC-EXTRACT-002 v1.1 req 1 -- TRUTHFUL RUN STATUS.
    # A mid-run dw220sdb lock can trip a LATE, non-EOD table (scanrefs / promotions
    # / departments etc.) AFTER the end-of-day FACT tables already landed. That is
    # NOT a failed end-of-day -- but the old code exit-1'd on it, stamping the whole
    # run FAILED. That lying status blinded monitoring (~13 false-FAILED runs in the
    # 7 days to 06-17 while every store was actually current), so a genuinely dark
    # store was indistinguishable from the nightly noise.
    # The run is a GENUINE failure only if an EOD FACT table did not land:
    #   sigma_sales / sigma_movements / l2_soh_daily.
    # A non-fact table that tripped is already logged FAILED per-table
    # (Send-TableLog) and the next run (catch-up poll / nightly) re-pulls it on
    # delta. Alerts key on fact-table DATA FRESHNESS (req 2), never on this code.
    # R28: general beha
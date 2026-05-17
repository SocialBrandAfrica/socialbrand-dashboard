#Requires -Version 5.1
<#
.SYNOPSIS
    Nightly push from Sigma SQL Server to Supabase - SocialBrand Pulse.
.DESCRIPTION
    Phase 1: daily_aggregates (DBAUms) and stock_snapshots (PLU_s).
    Runs on the store server using Windows Auth against localhost\SIGMA.
    Scheduled via Task Scheduler at 02:00 every night after Sigma day-end close.
.PARAMETER Mode
    nightly  - daily_aggregates + stock_snapshots (default)
    intraday - reserved for Phase 2 (transactions)
.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File "S:\SocialBrand\Push-SigmaToSupabase.ps1" -Mode nightly
#>
param(
    [ValidateSet('nightly', 'intraday')]
    [string]$Mode = 'nightly',
    [switch]$Backfill
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =============================================================================
# CONFIG - uncomment the block for this server, leave the rest commented
# =============================================================================

$ScriptVersion  = 'v1.0'
$ClientName     = 'SocialBrand'    # looked up at startup - do not change

# Store identity - one line active per server deployment
# ---------------------------------------------------------------
$StoreCode = '10116'  # SPAR Delareyville  - srsdelareyvilesvr
# $StoreCode = '80175'  # SPAR Roosville    - srsroosvillesvr
# $StoreCode = '21355'  # TOPS Delareyville - srtdelareyvilsvr
# $StoreCode = '80579'  # TOPS Dice         - srsdelareyt2svr
# $StoreCode = '80176'  # TOPS Roosville    - srtroosvillesvr
# ---------------------------------------------------------------

# SQL Server - Windows Auth, no password needed
$SigmaServer   = 'localhost\SIGMA'
$NposDb        = 'npos'
$DwDb          = 'DW220sDB'

# siMktNr = 1 on every store server (each runs an isolated Sigma instance).
# Store identity comes from $StoreCode above, not from siMktNr.
$SigmaMktNr    = 1

# Supabase - service_role key only. Never logged, never in queries.
$SupabaseUrl   = 'https://crklvhfwyxlisfcvqenc.supabase.co'
$SupabaseKey   = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImNya2x2aGZ3eXhsaXNmY3ZxZW5jIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3ODQxNTAxNSwiZXhwIjoyMDkzOTkxMDE1fQ.krsIfIwVEkCdl3BJnUJYb04A1f2mKJu1n8wsTi04dG0'

# Push tuning
$BatchSize     = 500
$DefaultDays   = 7                 # look-back window when no prior success exists
$RetryMax      = 3
$RetryWaitSecs = 10

# =============================================================================
# TLS
# =============================================================================

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# =============================================================================
# HELPERS
# =============================================================================

function Get-ClientId {
    # Fetch the UUID for this client from the clients table at startup.
    $url  = "$SupabaseUrl/rest/v1/clients?select=*&limit=1"
    $hdrs = @{ 'apikey' = $SupabaseKey; 'Authorization' = "Bearer $SupabaseKey" }
    $rows = Invoke-RestMethod -Uri $url -Method GET -Headers $hdrs
    if (-not $rows -or $rows.Count -eq 0) {
        throw "Client '$ClientName' not found in Supabase clients table."
    }
    $row = $rows[0]
    # Try common primary key column names
    if ($row.PSObject.Properties['client_id']) { return $row.client_id }
    if ($row.PSObject.Properties['id'])        { return $row.id }
    throw "Could not find primary key column on clients table. Columns: $($row.PSObject.Properties.Name -join ', ')"
}

function Get-Headers {
    return @{
        'apikey'        = $SupabaseKey
        'Authorization' = "Bearer $SupabaseKey"
        'Content-Type'  = 'application/json'
        'Prefer'        = 'resolution=merge-duplicates,return=minimal'
    }
}

function Get-ReturnHeaders {
    return @{
        'apikey'        = $SupabaseKey
        'Authorization' = "Bearer $SupabaseKey"
        'Content-Type'  = 'application/json'
        'Prefer'        = 'return=representation'
    }
}

function New-SqlConn {
    param([string]$Database)
    $cs   = "Server=$SigmaServer;Database=$Database;Integrated Security=True;Connection Timeout=30;"
    $conn = New-Object System.Data.SqlClient.SqlConnection($cs)
    $conn.Open()
    return $conn
}

function Invoke-Sql {
    param(
        [System.Data.SqlClient.SqlConnection]$Conn,
        [string]$Sql,
        [hashtable]$Params = @{}
    )
    $cmd                = New-Object System.Data.SqlClient.SqlCommand($Sql, $Conn)
    $cmd.CommandTimeout = 180
    foreach ($k in $Params.Keys) {
        $null = $cmd.Parameters.AddWithValue($k, $Params[$k])
    }
    $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
    $dt      = New-Object System.Data.DataTable
    $null    = $adapter.Fill($dt)
    return ,$dt
}

function Get-EAN {
    # EAN priority: (1) d_intnr if it is a 13-digit GS1 barcode,
    # (2) PLU_EAN.EAN_nr if supplied, (3) synthetic store+PLU fallback.
    param(
        [string]$Plu,
        [string]$Intnr = '',
        [string]$EanNr = ''
    )
    if ($Intnr -match '^\d{13}$') { return $Intnr }
    if ($EanNr -ne '')            { return $EanNr  }
    return $StoreCode.PadLeft(5, '0') + $Plu.PadLeft(8, '0')
}

function Get-GpPct {
    param([double]$SellIncVat, [double]$CostExVat)
    $sellExVat = $SellIncVat / 1.15
    if ($sellExVat -le 0) { return 0.0 }
    return [Math]::Round(($sellExVat - $CostExVat) / $sellExVat * 100, 2)
}

function Get-Watermark {
    param([string]$TableName)
    $url = "$SupabaseUrl/rest/v1/push_log" +
           "?select=completed_at" +
           "&store_code=eq.$StoreCode" +
           "&table_name=eq.$TableName" +
           "&status=eq.SUCCESS" +
           "&order=completed_at.desc" +
           "&limit=1"
    $hdrs = @{ 'apikey' = $SupabaseKey; 'Authorization' = "Bearer $SupabaseKey" }
    try {
        $rows = Invoke-RestMethod -Uri $url -Method GET -Headers $hdrs
        if ($rows -and $rows.Count -gt 0 -and $rows[0].completed_at) {
            return [datetime]$rows[0].completed_at
        }
    }
    catch {
        Write-Warning "Watermark read failed for $TableName - defaulting to last $DefaultDays days. ($_)"
    }
    return (Get-Date).AddDays(-$DefaultDays)
}

function Clear-StuckRuns {
    # Mark any RUNNING entries older than 30 minutes as FAILED before starting a new run.
    # Prevents push_log filling with orphaned rows from crashed or interrupted runs.
    $cutoff = (Get-Date).AddMinutes(-30).ToString('o')
    $url    = "$SupabaseUrl/rest/v1/push_log" +
              "?store_code=eq.$StoreCode" +
              "&status=eq.RUNNING" +
              "&started_at=lt.$cutoff"
    $hdrs   = @{ 'apikey' = $SupabaseKey; 'Authorization' = "Bearer $SupabaseKey" }
    try {
        $stuck = Invoke-RestMethod -Uri ($url + '&select=push_id,table_name') -Method GET -Headers $hdrs
        if ($stuck -and $stuck.Count -gt 0) {
            Write-Warning "Found $($stuck.Count) stuck RUNNING entry/entries - marking FAILED before starting."
            $body = [ordered]@{
                status        = 'FAILED'
                completed_at  = (Get-Date -Format 'o')
                error_message = 'Marked FAILED by new run startup - previous run did not complete cleanly.'
            } | ConvertTo-Json
            Invoke-RestMethod -Uri $url -Method PATCH -Headers (Get-Headers) -Body $body | Out-Null
        }
    }
    catch {
        Write-Warning "Could not clear stuck runs: $_"
    }
}

function Start-PushLog {
    param([string]$TableName)
    $body = [ordered]@{
        store_code     = $StoreCode
        client_id      = $ClientId
        table_name     = $TableName
        push_type      = $Mode
        status         = 'RUNNING'
        started_at     = (Get-Date -Format 'o')
        script_version = $ScriptVersion
    } | ConvertTo-Json
    $result = Invoke-RestMethod -Uri "$SupabaseUrl/rest/v1/push_log" -Method POST -Headers (Get-ReturnHeaders) -Body $body
    return $result[0].push_id
}

function Complete-PushLog {
    param([object]$LogId, [string]$Status, [int]$RowsPushed = 0, [int]$RowsFailed = 0, [string]$Msg = '')
    $body = [ordered]@{
        status       = $Status
        completed_at = (Get-Date -Format 'o')
        rows_pushed  = $RowsPushed
        rows_failed  = $RowsFailed
    }
    if ($Msg) { $body['error_message'] = $Msg }
    $json = $body | ConvertTo-Json
    Invoke-RestMethod -Uri "$SupabaseUrl/rest/v1/push_log?push_id=eq.$LogId" -Method PATCH -Headers (Get-Headers) -Body $json | Out-Null
}

function Write-PushError {
    param([object]$LogId, [string]$TableName, [string]$Message, [string]$Payload = '')
    $body = [ordered]@{
        push_id       = $LogId
        store_code    = $StoreCode
        table_name    = $TableName
        error_message = $Message
        row_data      = $Payload.Substring(0, [Math]::Min(2000, $Payload.Length))
    } | ConvertTo-Json
    try {
        Invoke-RestMethod -Uri "$SupabaseUrl/rest/v1/push_errors" -Method POST -Headers (Get-Headers) -Body $body | Out-Null
    }
    catch {
        Write-Warning "push_errors write failed: $_"
    }
}

function Send-Batch {
    # POST one batch (up to $BatchSize rows) to a Supabase table.
    # Returns count of rows successfully pushed.
    param(
        [string]$TableName,
        [string]$ConflictCols,
        [array]$Rows,
        [object]$LogId
    )
    $url  = "$SupabaseUrl/rest/v1/$TableName`?on_conflict=$ConflictCols"
    $json = ConvertTo-Json -InputObject @($Rows) -Depth 5 -Compress

    # Try the whole batch first
    $attempt = 0
    while ($attempt -lt $RetryMax) {
        try {
            Invoke-RestMethod -Uri $url -Method POST -Headers (Get-Headers) -Body $json | Out-Null
            return $Rows.Count
        }
        catch {
            $attempt++
            $detail = ''
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $detail = ' | ' + $reader.ReadToEnd()
            } catch {}
            if ($attempt -lt $RetryMax) {
                Write-Warning "Batch attempt $attempt/$RetryMax failed for $TableName - retrying in ${RetryWaitSecs}s. ($_$detail)"
                Start-Sleep -Seconds $RetryWaitSecs
            } else {
                Write-Warning "Batch failed after $RetryMax retries: $_$detail"
            }
        }
    }

    # Batch failed after all retries - fall back to row-by-row to isolate bad rows
    Write-Warning "Batch failed after $RetryMax retries. Falling back to row-by-row for $($Rows.Count) rows."
    $pushed = 0
    foreach ($row in $Rows) {
        $rowJson = ConvertTo-Json -InputObject @($row) -Depth 5 -Compress
        try {
            Invoke-RestMethod -Uri $url -Method POST -Headers (Get-Headers) -Body $rowJson | Out-Null
            $pushed++
        }
        catch {
            Write-PushError -LogId $LogId -TableName $TableName -Message $_.ToString() -Payload $rowJson
        }
    }
    return $pushed
}

# =============================================================================
# PUSH: daily_aggregates  <-  DW220sDB.dbo.DBAUms
# =============================================================================

function Push-DailyAggregates {
    Write-Host "`n[daily_aggregates] Starting push..." -ForegroundColor Cyan
    $logId = $null

    try {
        $logId     = Start-PushLog -TableName 'daily_aggregates'
        $watermark = if ($Backfill) { [datetime]'2026-03-01' } else { Get-Watermark -TableName 'daily_aggregates' }
        Write-Host "  Watermark: $watermark  |  siMktNr filter: $SigmaMktNr"

        $sql = @"
SELECT
    u.dtDatum                                                                        AS agg_date,
    CAST(CAST(u.dArtNr AS BIGINT) AS VARCHAR(20))                                   AS plu_code,
    '$StoreCode' + RIGHT('00000000' + CAST(CAST(u.dArtNr AS BIGINT) AS VARCHAR), 8) AS ean,
    LTRIM(RTRIM(a.cBEZ))                                                            AS description,
    CAST(g.WGRZUGABT AS VARCHAR(20))                                                AS dept_code,
    LTRIM(RTRIM(ab.ABTLBEZ))                                                       AS dept_name,
    CAST(a.lWgr AS VARCHAR(20))                                                     AS sub_dept_code,
    LTRIM(RTRIM(g.WGRBEZ))                                                          AS sub_dept_name,
    SUM(u.dUmsVK)                                                                   AS sales_inc_vat,
    SUM(u.dUmsVK - u.dMwStAus)                                                      AS sales_ex_vat,
    SUM(u.dUmsEK)                                                                   AS cost_of_sales,
    SUM(u.dUmsVK - u.dMwStAus - u.dUmsEK)                                          AS gp_amount,
    SUM(u.dMenge)                                                                   AS qty_sold
FROM $DwDb.dbo.DBAUms u
LEFT JOIN $DwDb.dbo.DBARTS a
    ON u.dArtNr = a.dARTNR
LEFT JOIN $DwDb.dbo.DBWGRP g
    ON a.lWgr = g.lWgr
LEFT JOIN $DwDb.dbo.DBABTL ab
    ON g.WGRZUGABT = ab.ABTLNR
WHERE u.siMktNr  = @sigmaMktNr
  AND u.dtDatum >= @watermark
GROUP BY
    u.dtDatum,
    u.dArtNr,
    a.cBEZ,
    a.lWgr,
    g.WGRZUGABT,
    g.WGRBEZ,
    ab.ABTLBEZ
ORDER BY u.dtDatum, u.dArtNr
"@
        $conn = New-SqlConn -Database $DwDb
        $dt   = Invoke-Sql -Conn $conn -Sql $sql -Params @{
            watermark  = $watermark.Date
            sigmaMktNr = $SigmaMktNr
        }
        $conn.Dispose()

        Write-Host "  Rows from Sigma: $($dt.Rows.Count)"

        $pushed = 0
        $batch  = [System.Collections.Generic.List[hashtable]]::new()

        foreach ($row in $dt.Rows) {
            $sellEx  = [Math]::Round([double]$row['sales_ex_vat'], 2)
            $gpAmt   = [Math]::Round([double]$row['gp_amount'], 2)
            $gpPct   = if ($sellEx -gt 0) { [Math]::Round($gpAmt / $sellEx * 100, 2) } else { 0.0 }

            $record  = [ordered]@{
                client_id     = $ClientId
                store_code    = $StoreCode
                agg_date      = ([datetime]$row['agg_date']).ToString('yyyy-MM-dd')
                ean           = [string]$row['ean']
                plu_code      = [string]$row['plu_code']
                description   = if ($row['description']   -is [DBNull]) { $null } else { [string]$row['description']   }
                dept_code     = if ($row['dept_code']      -is [DBNull]) { $null } else { [string]$row['dept_code']     }
                dept_name     = if ($row['dept_name']      -is [DBNull]) { $null } else { [string]$row['dept_name']     }
                sub_dept_code = if ($row['sub_dept_code']  -is [DBNull]) { $null } else { [string]$row['sub_dept_code'] }
                sub_dept_name = if ($row['sub_dept_name']  -is [DBNull]) { $null } else { [string]$row['sub_dept_name'] }
                qty_sold      = [Math]::Round([double]$row['qty_sold'], 3)
                sales_inc_vat = [Math]::Round([double]$row['sales_inc_vat'], 2)
                cost_of_sales = [Math]::Round([double]$row['cost_of_sales'], 2)
                sales_ex_vat  = $sellEx
                gp_amount     = $gpAmt
                gp_pct        = $gpPct
            }
            $batch.Add($record)

            if ($batch.Count -ge $BatchSize) {
                $pushed += Send-Batch -TableName 'daily_aggregates' -ConflictCols 'client_id,store_code,agg_date,ean' -Rows $batch.ToArray() -LogId $logId
                $batch.Clear()
                Write-Host "  Pushed $pushed rows so far..."
            }
        }
        if ($batch.Count -gt 0) {
            $pushed += Send-Batch -TableName 'daily_aggregates' -ConflictCols 'client_id,store_code,agg_date,ean' -Rows $batch.ToArray() -LogId $logId
        }

        Complete-PushLog -LogId $logId -Status 'SUCCESS' -RowsPushed $pushed
        Write-Host "  [daily_aggregates] Done. $pushed rows pushed." -ForegroundColor Green
    }
    catch {
        $msg = $_.ToString()
        try {
            $stream = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $msg   += ' | ' + $reader.ReadToEnd()
        } catch {}
        Write-Host "  [daily_aggregates] FAILED: $msg" -ForegroundColor Red
        if ($logId) {
            try { Complete-PushLog -LogId $logId -Status 'FAILED' -Msg $msg } catch {}
        }
    }
}

# =============================================================================
# PUSH: departments + sub_departments  <-  npos.dbo.Dgrp_d / npos.dbo.Wgr_d
# These are tiny reference tables (~30 rows each). Upserted every nightly run.
# client_id is included so they work in a multi-tenant schema.
# =============================================================================

function Push-RefTables {
    Write-Host "`n[ref_tables] Starting push (departments + sub_departments)..." -ForegroundColor Cyan

    try {
        $conn = New-SqlConn -Database $NposDb

        # -- departments (DBABTL) -----------------------------------------------
        $sqlDept = @"
SELECT
    CAST(ABTLNR AS VARCHAR(20))  AS dept_code,
    LTRIM(RTRIM(ABTLBEZ))        AS dept_name
FROM $DwDb.dbo.DBABTL
WHERE ABTLBEZ IS NOT NULL
"@
        $dtDept = Invoke-Sql -Conn $conn -Sql $sqlDept
        Write-Host "  departments rows from Sigma: $($dtDept.Rows.Count)"

        $deptBatch = @()
        foreach ($row in $dtDept.Rows) {
            $deptBatch += [ordered]@{
                client_id  = $ClientId
                store_code = $StoreCode
                dept_code  = [string]$row['dept_code']
                dept_name  = [string]$row['dept_name']
            }
        }
        if ($deptBatch.Count -gt 0) {
            $url  = "$SupabaseUrl/rest/v1/departments?on_conflict=client_id,store_code,dept_code"
            $json = ConvertTo-Json -InputObject @($deptBatch) -Depth 3 -Compress
            Invoke-RestMethod -Uri $url -Method POST -Headers (Get-Headers) -Body $json | Out-Null
            Write-Host "  departments upserted: $($deptBatch.Count)" -ForegroundColor Green
        }

        # -- sub_departments (DBWGRP) -------------------------------------------
        $sqlSub = @"
SELECT
    CAST(lWgr        AS VARCHAR(20)) AS sub_dept_code,
    LTRIM(RTRIM(WGRBEZ))             AS sub_dept_name,
    CAST(WGRZUGABT   AS VARCHAR(20)) AS dept_code
FROM $DwDb.dbo.DBWGRP
WHERE WGRBEZ IS NOT NULL
"@
        $dtSub = Invoke-Sql -Conn $conn -Sql $sqlSub
        Write-Host "  sub_departments rows from Sigma: $($dtSub.Rows.Count)"

        $subBatch = @()
        foreach ($row in $dtSub.Rows) {
            $subBatch += [ordered]@{
                client_id     = $ClientId
                store_code    = $StoreCode
                sub_dept_code = [string]$row['sub_dept_code']
                sub_dept_name = [string]$row['sub_dept_name']
                dept_code     = if ($row['dept_code'] -is [DBNull]) { $null } else { [string]$row['dept_code'] }
            }
        }
        if ($subBatch.Count -gt 0) {
            $url  = "$SupabaseUrl/rest/v1/sub_departments?on_conflict=client_id,store_code,sub_dept_code"
            $json = ConvertTo-Json -InputObject @($subBatch) -Depth 3 -Compress
            Invoke-RestMethod -Uri $url -Method POST -Headers (Get-Headers) -Body $json | Out-Null
            Write-Host "  sub_departments upserted: $($subBatch.Count)" -ForegroundColor Green
        }

        $conn.Dispose()
        Write-Host "  [ref_tables] Done." -ForegroundColor Green
    }
    catch {
        Write-Host "  [ref_tables] FAILED: $_" -ForegroundColor Red
    }
}

# =============================================================================
# PUSH: stock_snapshots  <-  npos.dbo.PLU_s
# =============================================================================

function Push-StockSnapshots {
    Write-Host "`n[stock_snapshots] Starting push..." -ForegroundColor Cyan
    $logId = $null

    try {
        $logId       = Start-PushLog -TableName 'stock_snapshots'
        $snapshotAt  = (Get-Date).ToString('o')

        # Full snapshot every run - no watermark filter.
        # PLU_s holds current SOH and is maintained live on all stores (SPAR and TOPS).
        # F5 - PLU_s has no reserved_qty; push 0. available_qty = s_stock.
        $sql = @"
SELECT
    PLU_nr,
    CAST(s_stock AS FLOAT) AS soh
FROM $NposDb.dbo.PLU_s
WHERE s_stock IS NOT NULL
"@
        $conn = New-SqlConn -Database $NposDb
        $dt   = Invoke-Sql -Conn $conn -Sql $sql
        $conn.Dispose()

        Write-Host "  Rows from Sigma: $($dt.Rows.Count)"

        $pushed = 0
        $batch  = [System.Collections.Generic.List[hashtable]]::new()

        foreach ($row in $dt.Rows) {
            $plu    = [string]$row['PLU_nr']
            $ean    = Get-EAN -Plu $plu
            $soh    = [Math]::Round([double]$row['soh'], 3)

            $record = [ordered]@{
                client_id    = $ClientId
                store_code   = $StoreCode
                snapshot_at  = $snapshotAt
                ean          = $ean
                plu_code     = $plu
                soh          = $soh
                reserved_qty = 0
                available_qty = $soh
            }
            $batch.Add($record)

            if ($batch.Count -ge $BatchSize) {
                $pushed += Send-Batch -TableName 'stock_snapshots' -ConflictCols 'client_id,store_code,snapshot_at,ean' -Rows $batch.ToArray() -LogId $logId
                $batch.Clear()
                Write-Host "  Pushed $pushed rows so far..."
            }
        }
        if ($batch.Count -gt 0) {
            $pushed += Send-Batch -TableName 'stock_snapshots' -ConflictCols 'client_id,store_code,snapshot_at,ean' -Rows $batch.ToArray() -LogId $logId
        }

        Complete-PushLog -LogId $logId -Status 'SUCCESS' -RowsPushed $pushed
        Write-Host "  [stock_snapshots] Done. $pushed rows pushed." -ForegroundColor Green
    }
    catch {
        $msg = $_.ToString()
        try {
            $stream = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $msg   += ' | ' + $reader.ReadToEnd()
        } catch {}
        Write-Host "  [stock_snapshots] FAILED: $msg" -ForegroundColor Red
        if ($logId) {
            try { Complete-PushLog -LogId $logId -Status 'FAILED' -Msg $msg } catch {}
        }
    }
}

# =============================================================================
# MAIN
# =============================================================================

Write-Host "=== SocialBrand Push Script $ScriptVersion - Mode: $Mode - Store: $StoreCode ===" -ForegroundColor White
Write-Host "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

$ClientId = Get-ClientId
Write-Host "Client UUID: $ClientId"

Clear-StuckRuns

switch ($Mode) {
    'nightly' {
        Push-RefTables
        Push-DailyAggregates
        Push-StockSnapshots
    }
    'intraday' {
        Write-Host "Intraday mode not yet implemented (Phase 2)." -ForegroundColor Yellow
        exit 0
    }
}

Write-Host "`nCompleted: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White

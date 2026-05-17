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
    [string]$Mode = 'nightly'
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
    # F1 - EAN synthesis. If PLU is all-numeric and shorter than 8 chars, build a
    # synthetic barcode: store_code padded to 5 + PLU padded to 8.
    param([string]$Plu)
    if ($Plu -match '^\d+$' -and $Plu.Length -lt 8) {
        return $StoreCode.PadLeft(5, '0') + $Plu.PadLeft(8, '0')
    }
    return $Plu
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
        $watermark = Get-Watermark -TableName 'daily_aggregates'
        Write-Host "  Watermark: $watermark  |  siMktNr filter: $SigmaMktNr"

        # F6 - DBAUms has no dept/sub_dept; join to npos.PLU_d -> npos.Wgr_d
        # F7 - filter by siMktNr (Sigma internal market number, not the store code)
        # dArtNr is float - cast via BIGINT to strip the decimal safely
        # Group by date + product to collapse multiple siKz rows (sales, returns, etc.)
        # into one aggregate row per product per day.
        $sql = @"
SELECT
    u.dtDatum,
    CAST(CAST(u.dArtNr AS BIGINT) AS VARCHAR(20)) AS plu_code_raw,
    SUM(CAST(u.dMenge   AS FLOAT))                AS qty_sold,
    SUM(CAST(u.dUmsVK   AS FLOAT))                AS sales_inc_vat,
    SUM(CAST(u.dUmsEK   AS FLOAT))                AS cost_of_sales,
    SUM(CAST(u.dMwStAus AS FLOAT))                AS vat_amount,
    MAX(CAST(p.wgr_id   AS VARCHAR(20)))          AS sub_dept_code,
    MAX(CAST(w.hptgrp   AS VARCHAR(20)))          AS dept_code
FROM $DwDb.dbo.DBAUms u
LEFT JOIN $NposDb.dbo.PLU_d p
    ON CAST(CAST(u.dArtNr AS BIGINT) AS VARCHAR(20)) = p.PLU_nr
LEFT JOIN $NposDb.dbo.Wgr_d w
    ON p.wgr_id = w.wgr_id
WHERE u.dtDatum >= @watermark
  AND u.siMktNr  = @sigmaMktNr
GROUP BY u.dtDatum, u.dArtNr
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
            $plu     = $row['plu_code_raw']
            $ean     = Get-EAN -Plu $plu

            $sellInc = [double]$row['sales_inc_vat']
            $cost    = [double]$row['cost_of_sales']
            $vatOut  = [double]$row['vat_amount']
            $sellEx  = [Math]::Round($sellInc - $vatOut, 2)
            $gpAmt   = [Math]::Round($sellEx - $cost, 2)
            $gpPct   = Get-GpPct -SellIncVat $sellInc -CostExVat $cost

            $record  = [ordered]@{
                client_id     = $ClientId
                store_code    = $StoreCode
                agg_date      = ([datetime]$row['dtDatum']).ToString('yyyy-MM-dd')
                ean           = $ean
                plu_code      = $plu
                dept_code     = if ($row['dept_code']     -is [DBNull]) { $null } else { $row['dept_code'] }
                sub_dept_code = if ($row['sub_dept_code'] -is [DBNull]) { $null } else { $row['sub_dept_code'] }
                qty_sold      = [Math]::Round([double]$row['qty_sold'], 3)
                sales_inc_vat = [Math]::Round($sellInc, 2)
                cost_of_sales = [Math]::Round($cost, 2)
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
        Push-DailyAggregates
        Push-StockSnapshots
    }
    'intraday' {
        Write-Host "Intraday mode not yet implemented (Phase 2)." -ForegroundColor Yellow
        exit 0
    }
}

Write-Host "`nCompleted: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White

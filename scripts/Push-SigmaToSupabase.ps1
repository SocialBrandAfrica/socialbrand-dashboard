#Requires -Version 5.1
<#
.SYNOPSIS
    Nightly push from Sigma SQL Server to Supabase — SocialBrand Pulse.
.DESCRIPTION
    Phase 1: daily_aggregates (DBAUms) and stock_snapshots (PLU_s).
    Runs on the store server using Windows Auth against localhost\SIGMA.
    Scheduled via Task Scheduler at 02:00 every night after Sigma day-end close.
.PARAMETER Mode
    nightly  — daily_aggregates + stock_snapshots (default)
    intraday — reserved for Phase 2 (transactions)
.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File "C:\SocialBrand\Push-SigmaToSupabase.ps1" -Mode nightly
#>
param(
    [ValidateSet('nightly', 'intraday')]
    [string]$Mode = 'nightly'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =============================================================================
# CONFIG — edit before deploying to a store server
# =============================================================================

$ScriptVersion = 'v1.0'
$StoreCode     = '10116'           # 5-digit code for SPAR Delareyville
$ClientId      = 1                 # clients.id in Supabase (SocialBrand = 1)

# SQL Server — Windows Auth, no password needed
$SigmaServer   = 'localhost\SIGMA'
$NposDb        = 'npos'
$DwDb          = 'DW220sDB'

# F7 — siMktNr is Sigma's internal market number, NOT the 5-digit store code.
# Confirmed 2026-05-17: siMktNr = 1 on all store servers. No per-store mapping needed.
$SigmaMktNr    = 1

# Supabase — service_role key only. Never logged, never in queries.
$SupabaseUrl   = 'https://crklvhfwyxlisfcvqenc.supabase.co'
$SupabaseKey   = 'REPLACE_WITH_SERVICE_ROLE_KEY'

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
    $cmd             = New-Object System.Data.SqlClient.SqlCommand($Sql, $Conn)
    $cmd.CommandTimeout = 180
    foreach ($k in $Params.Keys) {
        $cmd.Parameters.AddWithValue($k, $Params[$k]) | Out-Null
    }
    $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
    $dt      = New-Object System.Data.DataTable
    $adapter.Fill($dt) | Out-Null
    return $dt
}

function Get-EAN {
    # F1 — EAN synthesis. If PLU is all-numeric and shorter than 8 chars, build a
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
        Write-Warning "Watermark read failed for $TableName — defaulting to last $DefaultDays days. ($_)"
    }
    return (Get-Date).AddDays(-$DefaultDays)
}

function Start-PushLog {
    param([string]$TableName)
    $body = [ordered]@{
        store_code     = $StoreCode
        client_id      = $ClientId
        table_name     = $TableName
        status         = 'RUNNING'
        started_at     = (Get-Date -Format 'o')
        script_version = $ScriptVersion
    } | ConvertTo-Json
    $result = Invoke-RestMethod -Uri "$SupabaseUrl/rest/v1/push_log" -Method POST -Headers (Get-ReturnHeaders) -Body $body
    return $result[0].id
}

function Complete-PushLog {
    param([object]$LogId, [string]$Status, [int]$RowsPushed = 0, [string]$Msg = '')
    $body = [ordered]@{
        status       = $Status
        completed_at = (Get-Date -Format 'o')
        rows_pushed  = $RowsPushed
    }
    if ($Msg) { $body['error_message'] = $Msg }
    $json = $body | ConvertTo-Json
    Invoke-RestMethod -Uri "$SupabaseUrl/rest/v1/push_log?id=eq.$LogId" -Method PATCH -Headers (Get-Headers) -Body $json | Out-Null
}

function Write-PushError {
    param([object]$LogId, [string]$TableName, [string]$Message, [string]$Payload = '')
    $body = [ordered]@{
        store_code    = $StoreCode
        client_id     = $ClientId
        table_name    = $TableName
        push_log_id   = $LogId
        error_message = $Message
        payload       = $Payload.Substring(0, [Math]::Min(2000, $Payload.Length))
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
            if ($attempt -lt $RetryMax) {
                Write-Warning "Batch attempt $attempt/$RetryMax failed for $TableName — retrying in ${RetryWaitSecs}s. ($_)"
                Start-Sleep -Seconds $RetryWaitSecs
            }
        }
    }

    # Batch failed after all retries — fall back to row-by-row to isolate bad rows
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
# PUSH: daily_aggregates  ←  DW220sDB.dbo.DBAUms
# =============================================================================

function Push-DailyAggregates {
    Write-Host "`n[daily_aggregates] Starting push..." -ForegroundColor Cyan
    $logId = $null

    try {
        $logId    = Start-PushLog -TableName 'daily_aggregates'
        $watermark = Get-Watermark -TableName 'daily_aggregates'
        Write-Host "  Watermark: $watermark  |  siMktNr filter: $SigmaMktNr"

        # F6 — DBAUms has no dept/sub_dept; join to npos.PLU_d → npos.Wgr_d
        # F7 — filter by siMktNr (Sigma internal market number, not the store code)
        # dArtNr is float — cast via BIGINT to strip the decimal safely
        $sql = @"
SELECT
    u.dtDatum,
    CAST(CAST(u.dArtNr AS BIGINT) AS VARCHAR(20)) AS plu_code_raw,
    CAST(u.dMenge    AS FLOAT)                    AS qty_sold,
    CAST(u.dUmsVK    AS FLOAT)                    AS sales_inc_vat,
    CAST(u.dUmsEK    AS FLOAT)                    AS cost_of_sales,
    CAST(u.dMwStAus  AS FLOAT)                    AS vat_amount,
    CAST(p.wgr_id    AS VARCHAR(20))              AS sub_dept_code,
    CAST(w.hptgrp    AS VARCHAR(20))              AS dept_code
FROM $DwDb.dbo.DBAUms u
LEFT JOIN $NposDb.dbo.PLU_d p
    ON CAST(CAST(u.dArtNr AS BIGINT) AS VARCHAR(20)) = p.PLU_nr
LEFT JOIN $NposDb.dbo.Wgr_d w
    ON p.wgr_id = w.wgr_id
WHERE u.dtDatum  >= @watermark
  AND u.siMktNr   = @sigmaMktNr
ORDER BY u.dtDatum, u.dArtNr
"@
        $conn = New-SqlConn -Database $DwDb
        $dt   = Invoke-Sql -Conn $conn -Sql $sql -Params @{
            watermark   = $watermark.Date
            sigmaMktNr  = $SigmaMktNr
        }
        $conn.Dispose()

        Write-Host "  Rows from Sigma: $($dt.Rows.Count)"

        $pushed = 0
        $today  = (Get-Date).ToString('yyyy-MM-dd')
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
                client_id      = $ClientId
                store_code     = $StoreCode
                agg_date       = ([datetime]$row['dtDatum']).ToString('yyyy-MM-dd')
                ean            = $ean
                plu_code       = $plu
                dept_code      = if ($row['dept_code']     -is [DBNull]) { $null } else { $row['dept_code'] }
                sub_dept_code  = if ($row['sub_dept_code'] -is [DBNull]) { $null } else { $row['sub_dept_code'] }
                qty_sold       = [Math]::Round([double]$row['qty_sold'], 3)
                sales_inc_vat  = [Math]::Round($sellInc, 2)
                cost_of_sales  = [Math]::Round($cost, 2)
                sales_ex_vat   = $sellEx
                gp_amount      = $gpAmt
                gp_pct         = $gpPct
            }
            $batch.Add($record)

            if ($batch.Count -ge $BatchSize) {
                $pushed += Send-Batch -TableName 'daily_aggregates' -ConflictCols 'client_id,store_code,agg_date,plu_code' -Rows $batch.ToArray() -LogId $logId
                $batch.Clear()
                Write-Host "  Pushed $pushed rows..." -NoNewline; Write-Host "`r" -NoNewline
            }
        }
        if ($batch.Count -gt 0) {
            $pushed += Send-Batch -TableName 'daily_aggregates' -ConflictCols 'client_id,store_code,agg_date,plu_code' -Rows $batch.ToArray() -LogId $logId
        }

        Complete-PushLog -LogId $logId -Status 'SUCCESS' -RowsPushed $pushed
        Write-Host "  [daily_aggregates] Done. $pushed rows pushed." -ForegroundColor Green
    }
    catch {
        $msg = $_.ToString()
        Write-Host "  [daily_aggregates] FAILED: $msg" -ForegroundColor Red
        if ($logId) {
            try { Complete-PushLog -LogId $logId -Status 'FAILED' -Msg $msg } catch {}
        }
    }
}

# =============================================================================
# PUSH: stock_snapshots  ←  npos.dbo.PLU_s
# =============================================================================

function Push-StockSnapshots {
    Write-Host "`n[stock_snapshots] Starting push..." -ForegroundColor Cyan
    $logId = $null

    try {
        $logId       = Start-PushLog -TableName 'stock_snapshots'
        $snapshotDate = (Get-Date).ToString('yyyy-MM-dd')

        # Full snapshot every run — no watermark filter.
        # PLU_s holds current SOH only; it is fully replaced each nightly close.
        # F5 — PLU_s has no reserved_qty; push 0. available_qty = s_stock.
        # NOTE: PLU_s is SPAR-only. TOPS store servers return 0 rows — do not deploy
        #       this function on TOPS servers until an alternative stock table is found.
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
                client_id     = $ClientId
                store_code    = $StoreCode
                snapshot_date = $snapshotDate
                ean           = $ean
                plu_code      = $plu
                soh           = $soh
                reserved_qty  = 0
                available_qty = $soh
            }
            $batch.Add($record)

            if ($batch.Count -ge $BatchSize) {
                $pushed += Send-Batch -TableName 'stock_snapshots' -ConflictCols 'client_id,store_code,snapshot_date,plu_code' -Rows $batch.ToArray() -LogId $logId
                $batch.Clear()
                Write-Host "  Pushed $pushed rows..." -NoNewline; Write-Host "`r" -NoNewline
            }
        }
        if ($batch.Count -gt 0) {
            $pushed += Send-Batch -TableName 'stock_snapshots' -ConflictCols 'client_id,store_code,snapshot_date,plu_code' -Rows $batch.ToArray() -LogId $logId
        }

        Complete-PushLog -LogId $logId -Status 'SUCCESS' -RowsPushed $pushed
        Write-Host "  [stock_snapshots] Done. $pushed rows pushed." -ForegroundColor Green
    }
    catch {
        $msg = $_.ToString()
        Write-Host "  [stock_snapshots] FAILED: $msg" -ForegroundColor Red
        if ($logId) {
            try { Complete-PushLog -LogId $logId -Status 'FAILED' -Msg $msg } catch {}
        }
    }
}

# =============================================================================
# MAIN
# =============================================================================

Write-Host "=== SocialBrand Push Script $ScriptVersion — Mode: $Mode — Store: $StoreCode ===" -ForegroundColor White
Write-Host "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

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

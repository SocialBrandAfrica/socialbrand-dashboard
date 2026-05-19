#Requires -Version 5.1
<#
.SYNOPSIS
    Nightly push from Sigma TAC zip (PRSSALE.DAT) to Supabase - SocialBrand Pulse.
.DESCRIPTION
    Reads PRSSALE.DAT from S:\sigma\comms\Catman\TAC*.zip.
    Pushes daily_aggregates (from PRSSALE) and stock_snapshots (from dewas_PLU_s).
    DBAUms is retired as a sales source. PRSSALE.DAT covers 100% of sales.
.PARAMETER Mode
    nightly  - daily_aggregates + stock_snapshots (default)
    intraday - reserved for Phase 2 (transactions)
.PARAMETER Backfill
    Process all TAC*.zip files in TacZipDir instead of only the latest.
.PARAMETER Force
    Combined with -Backfill: overwrite dates that already exist in daily_aggregates.
.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File "C:\SocialBrand\Push-SigmaToSupabase.ps1"
    powershell.exe -ExecutionPolicy Bypass -File "C:\SocialBrand\Push-SigmaToSupabase.ps1" -Backfill
    powershell.exe -ExecutionPolicy Bypass -File "C:\SocialBrand\Push-SigmaToSupabase.ps1" -Backfill -Force
#>
param(
    [ValidateSet('nightly', 'intraday')]
    [string]$Mode = 'nightly',
    [switch]$Backfill,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =============================================================================
# CONFIG
# =============================================================================

$ScriptVersion = 'v2.0'
$ClientName    = 'SocialBrand'

# Store identity - auto-detected from hostname. Same script deploys to all servers.
# ---------------------------------------------------------------
$hostMap = @{
    'SRSDELAREYVILESVR' = @{ StoreCode = '10116'; StoreName = 'SPAR_Delareyville' }
    'SRSROOSVILLESVR'   = @{ StoreCode = '80175'; StoreName = 'SPAR_Roosville'    }
    'SRTDELAREYVILSV'   = @{ StoreCode = '21355'; StoreName = 'TOPS_Delareyville' }
    'SRSDELAREYT2SVR'   = @{ StoreCode = '80579'; StoreName = 'TOPS_Dice'         }
    'SRTROOSVILLESVR'   = @{ StoreCode = '80176'; StoreName = 'TOPS_Roosville'    }
}
$hostKey = $env:COMPUTERNAME.ToUpper()
if (-not $hostMap.ContainsKey($hostKey)) {
    throw "Unknown host '$hostKey' - add it to hostMap in script config."
}
$StoreCode = $hostMap[$hostKey].StoreCode
$StoreName = $hostMap[$hostKey].StoreName
Write-Host "Store: $StoreName ($StoreCode) on $hostKey"
# ---------------------------------------------------------------

# TAC zip location and temp extraction root
$TacZipDir    = 'S:\sigma\comms\Catman'
$TempBase     = "$env:TEMP\SBPush"
$BackfillFrom = [datetime]'2025-01-01'   # skip zips older than this date

# SQL Server - Windows Auth, no password needed
$SigmaServer = 'localhost\SIGMA'
$NposDb      = 'npos'
$DwDb        = 'DW220sDB'

# Supabase - service_role key only. Never logged, never in queries.
$SupabaseUrl = 'https://crklvhfwyxlisfcvqenc.supabase.co'
$SupabaseKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImNya2x2aGZ3eXhsaXNmY3ZxZW5jIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3ODQxNTAxNSwiZXhwIjoyMDkzOTkxMDE1fQ.krsIfIwVEkCdl3BJnUJYb04A1f2mKJu1n8wsTi04dG0'

# Push tuning
$BatchSize     = 500
$DefaultDays   = 7
$RetryMax      = 3
$RetryWaitSecs = 10

# =============================================================================
# TLS
# =============================================================================

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# =============================================================================
# CORE HELPERS
# =============================================================================

function Get-ClientId {
    $url  = "$SupabaseUrl/rest/v1/clients?select=*&limit=1"
    $hdrs = @{ 'apikey' = $SupabaseKey; 'Authorization' = "Bearer $SupabaseKey" }
    $rows = Invoke-RestMethod -Uri $url -Method GET -Headers $hdrs
    if (-not $rows -or $rows.Count -eq 0) {
        throw "Client not found in Supabase clients table."
    }
    $row = $rows[0]
    if ($row.PSObject.Properties['client_id']) { return $row.client_id }
    if ($row.PSObject.Properties['id'])        { return $row.id }
    throw "Could not find primary key on clients table. Columns: $($row.PSObject.Properties.Name -join ', ')"
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
            $null = Invoke-RestMethod -Uri $url -Method PATCH -Headers (Get-Headers) -Body $body
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
        push_type      = if ($Backfill) { 'backfill' } else { $Mode }
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
    $null = Invoke-RestMethod -Uri "$SupabaseUrl/rest/v1/push_log?push_id=eq.$LogId" -Method PATCH -Headers (Get-Headers) -Body $json
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
        $null = Invoke-RestMethod -Uri "$SupabaseUrl/rest/v1/push_errors" -Method POST -Headers (Get-Headers) -Body $body
    }
    catch {
        Write-Warning "push_errors write failed: $_"
    }
}

function Send-Batch {
    param(
        [string]$TableName,
        [string]$ConflictCols,
        [array]$Rows,
        [object]$LogId
    )
    $url  = "$SupabaseUrl/rest/v1/$TableName`?on_conflict=$ConflictCols"
    $json = ConvertTo-Json -InputObject @($Rows) -Depth 5 -Compress

    $attempt = 0
    while ($attempt -lt $RetryMax) {
        try {
            $null = Invoke-RestMethod -Uri $url -Method POST -Headers (Get-Headers) -Body $json
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

    Write-Warning "Falling back to row-by-row for $($Rows.Count) rows in $TableName."
    $pushed = 0
    foreach ($row in $Rows) {
        $rowJson = ConvertTo-Json -InputObject @($row) -Depth 5 -Compress
        try {
            $null = Invoke-RestMethod -Uri $url -Method POST -Headers (Get-Headers) -Body $rowJson
            $pushed++
        }
        catch {
            Write-PushError -LogId $LogId -TableName $TableName -Message $_.ToString() -Payload $rowJson
        }
    }
    return $pushed
}

# =============================================================================
# PRSSALE PARSING
# =============================================================================

function Parse-NumericField {
    # Strip leading + and whitespace. Negative values keep their sign.
    param([string]$Val)
    $clean = $Val.Trim().TrimStart('+')
    if ([string]::IsNullOrWhiteSpace($clean)) { return 0.0 }
    return [double]$clean
}

function Convert-SigmaDate {
    # DD/MM/YYYY -> YYYY-MM-DD
    param([string]$Val)
    $p = $Val.Trim() -split '/'
    return "$($p[2])-$($p[1])-$($p[0])"
}

function Invoke-MergeFields {
    # Reconstructs a 34-element field array from a P row that has more than
    # 34 comma-separated tokens due to commas embedded in description,
    # dept_name, or sub_dept_name. Returns [string[]] of exactly 34 elements,
    # or $null if the row cannot be reliably reconstructed.
    #
    # Three fixed-format anchors drive the reconstruction (all non-variable):
    #   Status   (field 26) - the keyword 'Active', 'Locked', or 'Delete'
    #   subdept  (field 23) - exactly 9 digits, zero-padded
    #   dept     (field 21) - exactly 6 digits, zero-padded
    #
    # The 7 trailing fields (27-33) after Status contain dates and reserved
    # values - none are expected to contain commas.
    param([string[]]$Raw)

    $n = $Raw.Count

    # Step 1: find Status by scanning forward from its nominal index (26).
    # internal_ref (field 25) is always immediately before Status and contains
    # only digits, so the Status keyword is a reliable target.
    $statusIdx = -1
    $scanCeil  = $n - 7   # at least 7 trailing fields must follow Status
    for ($i = 26; $i -lt $scanCeil; $i++) {
        $v = $Raw[$i].Trim()
        if ($v -eq 'Active' -or $v -eq 'Locked' -or $v -eq 'Delete') {
            $statusIdx = $i
            break
        }
    }
    if ($statusIdx -lt 0) { return $null }

    # Step 2: find sub_dept_code (field 23, exactly 9 digits) by scanning
    # backward from statusIdx - 2 (skipping internal_ref at statusIdx - 1).
    $subDeptCodeIdx = -1
    $floor1         = [Math]::Max(22, $statusIdx - 30)
    for ($i = ($statusIdx - 2); $i -ge $floor1; $i--) {
        if ($Raw[$i].Trim() -match '^\d{9}$') {
            $subDeptCodeIdx = $i
            break
        }
    }
    if ($subDeptCodeIdx -lt 0) { return $null }

    # Step 3: find dept_code (field 21, exactly 6 digits) by scanning backward
    # from one position before sub_dept_code.
    $deptCodeIdx = -1
    $floor2      = [Math]::Max(20, $subDeptCodeIdx - 30)
    for ($i = ($subDeptCodeIdx - 1); $i -ge $floor2; $i--) {
        if ($Raw[$i].Trim() -match '^\d{6}$') {
            $deptCodeIdx = $i
            break
        }
    }
    if ($deptCodeIdx -lt 0) { return $null }

    # Fields 4-20 (17 fixed-format numeric tokens) sit immediately before
    # dept_code: raw[deptCodeIdx-17 .. deptCodeIdx-1].
    # Description (field 3) is everything from raw[3] to raw[deptCodeIdx-18].
    $descEnd = $deptCodeIdx - 18
    if ($descEnd -lt 3) { return $null }

    $out = [string[]]::new(34)

    $out[0] = $Raw[0]   # record type (P)
    $out[1] = $Raw[1]   # file date (DD/MM/YYYY)
    $out[2] = $Raw[2]   # EAN

    # Description: join all tokens from index 3 to descEnd
    $out[3] = ($Raw[3..$descEnd] -join ',')

    # Fields 4-20: 17 fixed-format numerics just before dept_code
    for ($i = 4; $i -le 20; $i++) {
        $out[$i] = $Raw[$deptCodeIdx - 21 + $i]
    }

    $out[21] = $Raw[$deptCodeIdx]

    # Dept name: all tokens between dept_code and sub_dept_code
    $deptNameEnd = $subDeptCodeIdx - 1
    $out[22] = if ($deptCodeIdx + 1 -le $deptNameEnd) {
                   ($Raw[($deptCodeIdx + 1)..$deptNameEnd] -join ',')
               } else { '' }

    $out[23] = $Raw[$subDeptCodeIdx]

    # Sub-dept name: all tokens between sub_dept_code and internal_ref
    $subNameEnd = $statusIdx - 2
    $out[24] = if ($subDeptCodeIdx + 1 -le $subNameEnd) {
                   ($Raw[($subDeptCodeIdx + 1)..$subNameEnd] -join ',')
               } else { '' }

    $out[25] = $Raw[$statusIdx - 1]   # internal_ref (15-digit plu_code)
    $out[26] = $Raw[$statusIdx]       # Status

    for ($i = 27; $i -le 33; $i++) {
        $out[$i] = $Raw[$statusIdx + ($i - 26)]
    }

    return ,$out
}

function Invoke-TacExtract {
    # Extracts a TAC*.zip, locates PRSSALE.dat inside TEMPDIR\, reads the
    # sale date from field[1] of the first P row (DD/MM/YYYY), renames the
    # file to the standard pattern PRSSALE_<StoreName>_<YYYYMMDD>.dat, and
    # returns a PSCustomObject:
    #   FilePath - full path to the renamed PRSSALE file
    #   AggDate  - ISO date YYYY-MM-DD parsed from the file header
    #   TempDir  - extraction root (caller must clean up in a finally block)
    param([string]$ZipPath)

    $zipName = [System.IO.Path]::GetFileNameWithoutExtension($ZipPath)
    $tempDir = Join-Path $TempBase $zipName

    if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $tempDir -Force

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $tempDir)

    $prssalePath = Join-Path $tempDir 'TEMPDIR\PRSSALE.dat'
    if (-not (Test-Path $prssalePath)) {
        $found = Get-ChildItem -Path $tempDir -Recurse -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -ieq 'PRSSALE.dat' } |
                 Select-Object -First 1
        if (-not $found) { throw "PRSSALE.dat not found inside $ZipPath" }
        $prssalePath = $found.FullName
    }

    $enc     = [System.Text.Encoding]::GetEncoding('iso-8859-1')
    $lines   = [System.IO.File]::ReadAllLines($prssalePath, $enc)
    $dateRaw = $null
    foreach ($ln in $lines) {
        if ($ln.StartsWith('P,')) {
            $dateRaw = ($ln -split ',')[1].Trim()
            break
        }
    }
    if (-not $dateRaw) { throw "No P row found in PRSSALE.dat extracted from $ZipPath" }

    $p        = $dateRaw -split '/'
    $yyyymmdd = "$($p[2])$($p[1])$($p[0])"
    $isoDate  = "$($p[2])-$($p[1])-$($p[0])"

    $newName = "PRSSALE_${StoreName}_${yyyymmdd}.dat"
    $newPath = Join-Path (Split-Path $prssalePath -Parent) $newName
    Move-Item -Path $prssalePath -Destination $newPath -Force

    return [PSCustomObject]@{
        FilePath = $newPath
        AggDate  = $isoDate
        TempDir  = $tempDir
    }
}

function Test-DateExists {
    # Returns $true if daily_aggregates already has rows for this store + date.
    param([string]$AggDate)
    $url  = "$SupabaseUrl/rest/v1/daily_aggregates" +
            "?select=agg_date" +
            "&client_id=eq.$ClientId" +
            "&store_code=eq.$StoreCode" +
            "&agg_date=eq.$AggDate" +
            "&limit=1"
    $hdrs = @{ 'apikey' = $SupabaseKey; 'Authorization' = "Bearer $SupabaseKey" }
    $rows = Invoke-RestMethod -Uri $url -Method GET -Headers $hdrs
    return ($rows -and $rows.Count -gt 0)
}

function Invoke-ParsePrssale {
    # Parses a renamed PRSSALE file (ISO-8859-1 encoding, 34 fields per P row).
    # Filters: today_qty != 0 AND Status != 'Delete'.
    # EAN comes from field[2] directly - no synthesis required.
    # sales_ex_vat = sales_inc_vat / (1 + vat_rate / 100).
    # gp_amount    = sales_ex_vat - cost_of_sales.
    # gp_pct is NOT stored in daily_aggregates (computed in the view layer).
    # Returns List[hashtable] ready to POST to daily_aggregates.
    param([string]$FilePath)

    $enc     = [System.Text.Encoding]::GetEncoding('iso-8859-1')
    $lines   = [System.IO.File]::ReadAllLines($FilePath, $enc)
    $records = [System.Collections.Generic.List[hashtable]]::new()
    $skipped = 0

    foreach ($line in $lines) {
        if (-not $line.StartsWith('P,')) { continue }

        $raw    = $line -split ','
        $fields = if ($raw.Count -eq 34) {
                      $raw
                  } else {
                      Invoke-MergeFields -Raw $raw
                  }

        if ($null -eq $fields) {
            # Silently skip rows that are clearly zero-qty (e.g. Sigma 'Item Not Found'
            # placeholders). Only warn when the row might carry real sales data.
            $likelyZeroQty = ($raw.Count -gt 8) -and ((Parse-NumericField $raw[8]) -eq 0)
            if (-not $likelyZeroQty) {
                $skipped++
                Write-Warning "Unparseable P row (token count $($raw.Count)) skipped: $($line.Substring(0, [Math]::Min(100, $line.Length)))"
            }
            continue
        }

        $status = $fields[26].Trim()
        if ($status -eq 'Delete') { continue }

        $todayQty = Parse-NumericField $fields[8]
        if ($todayQty -eq 0) { continue }

        $vatRate     = Parse-NumericField $fields[7]
        $salesIncVat = Parse-NumericField $fields[10]
        $costOfSales = Parse-NumericField $fields[9]

        $divisor    = 1 + ($vatRate / 100)
        $salesExVat = if ($divisor -gt 0) {
                          [Math]::Round($salesIncVat / $divisor, 2)
                      } else { $salesIncVat }
        $gpAmount   = [Math]::Round($salesExVat - $costOfSales, 2)

        $record = [ordered]@{
            client_id     = $ClientId
            store_code    = $StoreCode
            agg_date      = Convert-SigmaDate $fields[1]
            ean           = $fields[2].Trim()
            plu_code      = $fields[25].Trim()
            description   = $fields[3].Trim()
            dept_code     = $fields[21].Trim()
            dept_name     = $fields[22].Trim()
            sub_dept_code = $fields[23].Trim()
            sub_dept_name = $fields[24].Trim()
            qty_sold      = [Math]::Round($todayQty, 3)
            sales_inc_vat = [Math]::Round($salesIncVat, 2)
            sales_ex_vat  = $salesExVat
            cost_of_sales = [Math]::Round($costOfSales, 2)
            gp_amount     = $gpAmount
        }
        $records.Add($record)
    }

    if ($skipped -gt 0) { Write-Warning "Skipped $skipped unparseable rows in $FilePath" }
    return ,$records
}

# =============================================================================
# PUSH: departments + sub_departments  <-  DW220sDB reference tables
# Full upsert on every nightly run (~30 rows each, rarely changes).
# =============================================================================

function Push-RefTables {
    Write-Host "`n[ref_tables] Starting push (departments + sub_departments)..." -ForegroundColor Cyan
    try {
        $conn = New-SqlConn -Database $NposDb

        $sqlDept = @"
SELECT
    CAST(ABTLNR AS VARCHAR(20))  AS dept_code,
    LTRIM(RTRIM(ABTLBEZ))        AS dept_name
FROM $DwDb.dbo.DBABTL
WHERE ABTLBEZ IS NOT NULL
"@
        $dtDept = Invoke-Sql -Conn $conn -Sql $sqlDept
        Write-Host "  departments rows: $($dtDept.Rows.Count)"

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
            $null = Invoke-RestMethod -Uri $url -Method POST -Headers (Get-Headers) -Body $json
            Write-Host "  departments upserted: $($deptBatch.Count)" -ForegroundColor Green
        }

        $sqlSub = @"
SELECT
    CAST(lWgr        AS VARCHAR(20)) AS sub_dept_code,
    LTRIM(RTRIM(WGRBEZ))             AS sub_dept_name,
    CAST(WGRZUGABT   AS VARCHAR(20)) AS dept_code
FROM $DwDb.dbo.DBWGRP
WHERE WGRBEZ IS NOT NULL
"@
        $dtSub = Invoke-Sql -Conn $conn -Sql $sqlSub
        Write-Host "  sub_departments rows: $($dtSub.Rows.Count)"

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
            $null = Invoke-RestMethod -Uri $url -Method POST -Headers (Get-Headers) -Body $json
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
# PUSH: daily_aggregates  <-  PRSSALE.DAT  (nightly - latest TAC zip only)
# =============================================================================

function Push-DailyAggregatesNightly {
    Write-Host "`n[daily_aggregates] Starting nightly push from PRSSALE.DAT..." -ForegroundColor Cyan
    $logId   = $null
    $tempDir = $null

    try {
        $logId = Start-PushLog -TableName 'daily_aggregates'

        $zips = @(Get-ChildItem -Path $TacZipDir -Filter 'TAC*.zip' -ErrorAction Stop |
                  Sort-Object LastWriteTime -Descending)
        if ($zips.Count -eq 0) { throw "No TAC*.zip files found in $TacZipDir" }

        $latest = $zips[0]
        Write-Host "  ZIP: $($latest.Name)  (modified $($latest.LastWriteTime))"

        $extracted = Invoke-TacExtract -ZipPath $latest.FullName
        $tempDir   = $extracted.TempDir
        Write-Host "  File date: $($extracted.AggDate)"

        $records = Invoke-ParsePrssale -FilePath $extracted.FilePath
        Write-Host "  Rows after filter (qty != 0, not Delete): $($records.Count)"

        $pushed = 0
        $batch  = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($rec in $records) {
            $batch.Add($rec)
            if ($batch.Count -ge $BatchSize) {
                $pushed += Send-Batch -TableName 'daily_aggregates' `
                                      -ConflictCols 'client_id,store_code,agg_date,ean' `
                                      -Rows $batch.ToArray() -LogId $logId
                $batch.Clear()
                Write-Host "  Pushed $pushed rows so far..."
            }
        }
        if ($batch.Count -gt 0) {
            $pushed += Send-Batch -TableName 'daily_aggregates' `
                                  -ConflictCols 'client_id,store_code,agg_date,ean' `
                                  -Rows $batch.ToArray() -LogId $logId
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
        if ($logId) { try { Complete-PushLog -LogId $logId -Status 'FAILED' -Msg $msg } catch {} }
    }
    finally {
        if ($tempDir -and (Test-Path $tempDir)) {
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# =============================================================================
# PUSH: daily_aggregates  <-  all TAC*.zip files  (backfill mode)
# =============================================================================

function Push-DailyAggregatesBackfill {
    Write-Host "`n[daily_aggregates] Backfill mode - processing all TAC*.zip files..." -ForegroundColor Cyan

    $zips = @(Get-ChildItem -Path $TacZipDir -Filter 'TAC*.zip' -ErrorAction Stop |
              Sort-Object LastWriteTime)
    if ($zips.Count -eq 0) {
        Write-Host "  No TAC*.zip files found in $TacZipDir" -ForegroundColor Yellow
        return
    }
    Write-Host "  Found $($zips.Count) zip file(s). Processing oldest-first."

    $totalPushed  = 0
    $totalSkipped = 0

    foreach ($zip in $zips) {
        $logId   = $null
        $tempDir = $null

        try {
            Write-Host "`n  ZIP: $($zip.Name)"
            $logId = Start-PushLog -TableName 'daily_aggregates'

            $extracted = Invoke-TacExtract -ZipPath $zip.FullName
            $tempDir   = $extracted.TempDir
            $aggDate   = $extracted.AggDate
            Write-Host "  Date: $aggDate"

            if ([datetime]$aggDate -lt $BackfillFrom) {
                Write-Host "  SKIP - $aggDate is before BackfillFrom $($BackfillFrom.ToString('yyyy-MM-dd'))." -ForegroundColor DarkGray
                Complete-PushLog -LogId $logId -Status 'SUCCESS' -RowsPushed 0 `
                    -Msg "Skipped - before BackfillFrom threshold"
                $totalSkipped++
                continue
            }

            if (-not $Force -and (Test-DateExists -AggDate $aggDate)) {
                Write-Host "  SKIP - $aggDate already in daily_aggregates. Use -Force to overwrite." -ForegroundColor Yellow
                Complete-PushLog -LogId $logId -Status 'SUCCESS' -RowsPushed 0 `
                    -Msg "Skipped - $aggDate already loaded for store $StoreCode"
                $totalSkipped++
                continue
            }

            $records = Invoke-ParsePrssale -FilePath $extracted.FilePath
            Write-Host "  Rows after filter: $($records.Count)"

            $pushed = 0
            $batch  = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($rec in $records) {
                $batch.Add($rec)
                if ($batch.Count -ge $BatchSize) {
                    $pushed += Send-Batch -TableName 'daily_aggregates' `
                                          -ConflictCols 'client_id,store_code,agg_date,ean' `
                                          -Rows $batch.ToArray() -LogId $logId
                    $batch.Clear()
                }
            }
            if ($batch.Count -gt 0) {
                $pushed += Send-Batch -TableName 'daily_aggregates' `
                                      -ConflictCols 'client_id,store_code,agg_date,ean' `
                                      -Rows $batch.ToArray() -LogId $logId
            }

            Complete-PushLog -LogId $logId -Status 'SUCCESS' -RowsPushed $pushed
            Write-Host "  Pushed $pushed rows for $aggDate." -ForegroundColor Green
            $totalPushed += $pushed
        }
        catch {
            $msg = $_.ToString()
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $msg   += ' | ' + $reader.ReadToEnd()
            } catch {}
            Write-Host "  FAILED ($($zip.Name)): $msg" -ForegroundColor Red
            if ($logId) { try { Complete-PushLog -LogId $logId -Status 'FAILED' -Msg $msg } catch {} }
        }
        finally {
            if ($tempDir -and (Test-Path $tempDir)) {
                Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Write-Host ("`n[daily_aggregates] Backfill complete. " +
                "$totalPushed rows pushed. $totalSkipped dates skipped.") -ForegroundColor Green
}

# =============================================================================
# PUSH: stock_snapshots  <-  npos.dbo.dewas_PLU_s
# Source changed from PLU_s (wipes at EOD, 0 rows during trading hours) to
# dewas_PLU_s (persistent ~78k rows, confirmed columns 2026-05-18).
# PLU_nr is the 13-digit barcode - used as ean directly, no synthesis needed.
# Conflict key: (client_id, store_code, ean) - one row per EAN per store,
# updated on each push (snapshot_at records when SOH was last refreshed).
# =============================================================================

function Push-StockSnapshots {
    Write-Host "`n[stock_snapshots] Starting push from dewas_PLU_s..." -ForegroundColor Cyan
    $logId = $null

    try {
        $logId      = Start-PushLog -TableName 'stock_snapshots'
        $snapshotAt = (Get-Date).ToString('o')

        $sql = @"
SELECT PLU_nr, CAST(SUM(s_stock) AS FLOAT) AS soh
FROM $NposDb.dbo.dewas_PLU_s
WHERE s_stock IS NOT NULL
GROUP BY PLU_nr
"@
        $conn = New-SqlConn -Database $NposDb
        $dt   = Invoke-Sql -Conn $conn -Sql $sql
        $conn.Dispose()

        Write-Host "  Rows from dewas_PLU_s: $($dt.Rows.Count)"

        $pushed = 0
        $batch  = [System.Collections.Generic.List[hashtable]]::new()

        foreach ($row in $dt.Rows) {
            $ean = [string]$row['PLU_nr']
            $soh = [Math]::Round([double]$row['soh'], 3)

            $record = [ordered]@{
                client_id     = $ClientId
                store_code    = $StoreCode
                snapshot_at   = $snapshotAt
                ean           = $ean
                plu_code      = $ean
                soh           = $soh
                reserved_qty  = 0
                available_qty = $soh
            }
            $batch.Add($record)

            if ($batch.Count -ge $BatchSize) {
                $pushed += Send-Batch -TableName 'stock_snapshots' `
                                      -ConflictCols 'client_id,store_code,snapshot_at,ean' `
                                      -Rows $batch.ToArray() -LogId $logId
                $batch.Clear()
                Write-Host "  Pushed $pushed rows so far..."
            }
        }
        if ($batch.Count -gt 0) {
            $pushed += Send-Batch -TableName 'stock_snapshots' `
                                  -ConflictCols 'client_id,store_code,snapshot_at,ean' `
                                  -Rows $batch.ToArray() -LogId $logId
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
        if ($logId) { try { Complete-PushLog -LogId $logId -Status 'FAILED' -Msg $msg } catch {} }
    }
}

# =============================================================================
# MAIN
# =============================================================================

Write-Host "=== SocialBrand Push $ScriptVersion - Store: $StoreCode ($StoreName) - Mode: $Mode ===" -ForegroundColor White
Write-Host "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
if ($Backfill) {
    $forceLabel = if ($Force) { ' + Force' } else { '' }
    Write-Host "Backfill mode ON$forceLabel" -ForegroundColor Yellow
}

$ClientId = Get-ClientId
Write-Host "Client UUID: $ClientId"

Clear-StuckRuns

$null = New-Item -ItemType Directory -Path $TempBase -Force

switch ($Mode) {
    'nightly' {
        Push-RefTables
        if ($Backfill) {
            Push-DailyAggregatesBackfill
        } else {
            Push-DailyAggregatesNightly
        }
        Push-StockSnapshots
    }
    'intraday' {
        Write-Host "Intraday mode not yet implemented (Phase 2)." -ForegroundColor Yellow
        exit 0
    }
}

Write-Host "`nCompleted: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White

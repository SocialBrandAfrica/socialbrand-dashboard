#Requires -Version 5.1
<#
.SYNOPSIS
    Nightly push from Sigma TAC zip (PRSSALE.DAT) to Supabase daily_snapshots.
.DESCRIPTION
    Reads PRSSALE.DAT from S:\sigma\comms\Catman\TAC*.zip.
    Pushes daily_snapshots (all 27 columns, full catalog including zero-sale rows).
    Also pushes stock_snapshots (from dewas_PLU_s) and ref tables.
    daily_aggregates is retired - this script no longer writes to it.
.PARAMETER Mode
    nightly  - daily_snapshots + stock_snapshots + ref tables (default)
    intraday - reserved for Phase 2 (transactions)
.PARAMETER Backfill
    Process all TAC*.zip files in TacZipDir instead of only the latest.
.PARAMETER Force
    Combined with -Backfill: overwrite dates already in daily_snapshots.
.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File "C:\SocialBrand\Push-SigmaToSupabase.ps1"
    powershell.exe -ExecutionPolicy Bypass -File "C:\SocialBrand\Push-SigmaToSupabase.ps1" -Backfill
    powershell.exe -ExecutionPolicy Bypass -File "C:\SocialBrand\Push-SigmaToSupabase.ps1" -Backfill -Force
#>
param(
    [ValidateSet('nightly', 'intraday')]
    [string]$Mode = 'nightly',
    [switch]$Backfill,
    [switch]$Force,
    [datetime]$BackfillFrom = [datetime]'2025-01-01'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =============================================================================
# CONFIG
# =============================================================================

$ScriptVersion = 'v3.0'
$ClientName    = 'SocialBrand'

# Store identity - auto-detected from hostname. Same script deploys to all servers.
# StoreName uses spaces to match prssale_parser_v2.py STORE_MAP output.
$hostMap = @{
    'SRSDELAREYVILES'   = @{ StoreCode = '10116'; StoreName = 'SPAR Delareyville' }
    'SRSROOSVILLESVR'   = @{ StoreCode = '80175'; StoreName = 'SPAR Roosville'    }
    'SRTDELAREYVILSV'   = @{ StoreCode = '21355'; StoreName = 'TOPS Delareyville' }
    'SRSDELAREYT2SVR'   = @{ StoreCode = '80579'; StoreName = 'TOPS Dice'         }
    'SRTROOSVILLESVR'   = @{ StoreCode = '80176'; StoreName = 'TOPS Roosville'    }
}
$hostKey = $env:COMPUTERNAME.ToUpper()
if (-not $hostMap.ContainsKey($hostKey)) {
    throw "Unknown host '$hostKey' - add it to hostMap in script config."
}
$StoreCode = $hostMap[$hostKey].StoreCode
$StoreName = $hostMap[$hostKey].StoreName
Write-Host "Store: $StoreName ($StoreCode) on $hostKey"

# TAC zip location and temp extraction root
$TacZipDir = 'S:\sigma\comms\Catman'
$TempBase  = "$env:TEMP\SBPush"

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

# Placeholder sentinel used by Sigma for products with no sales history
$PlaceholderDate = '01/01/1990'

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
    try { return [double]$clean } catch { return 0.0 }
}

function Convert-SigmaDate {
    # DD/MM/YYYY or DD-MM-YYYY -> YYYY-MM-DD
    # KI-002 fix: normalise hyphens to slashes before splitting.
    # Some TAC archives on TOPS Roosville (and possibly other TOPS stores)
    # encode dates as DD-MM-YYYY. The Replace ensures consistent parsing.
    param([string]$Raw)
    $s = $Raw.Trim().Replace('-', '/')
    $parts = $s.Split('/')
    if ($parts.Count -lt 3 -or [string]::IsNullOrWhiteSpace($parts[2])) { return $null }
    return "$($parts[2])-$($parts[1])-$($parts[0])"
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
    $statusIdx = -1
    $scanCeil  = $n - 7
    for ($i = 26; $i -lt $scanCeil; $i++) {
        $v = $Raw[$i].Trim()
        if ($v -eq 'Active' -or $v -eq 'Locked' -or $v -eq 'Delete') {
            $statusIdx = $i
            break
        }
    }
    if ($statusIdx -lt 0) { return $null }

    # Step 2: find sub_dept_code (field 23, exactly 9 digits).
    $subDeptCodeIdx = -1
    $floor1         = [Math]::Max(22, $statusIdx - 30)
    for ($i = ($statusIdx - 2); $i -ge $floor1; $i--) {
        if ($Raw[$i].Trim() -match '^\d{9}$') {
            $subDeptCodeIdx = $i
            break
        }
    }
    if ($subDeptCodeIdx -lt 0) { return $null }

    # Step 3: find dept_code (field 21, exactly 6 digits).
    $deptCodeIdx = -1
    $floor2      = [Math]::Max(20, $subDeptCodeIdx - 30)
    for ($i = ($subDeptCodeIdx - 1); $i -ge $floor2; $i--) {
        if ($Raw[$i].Trim() -match '^\d{6}$') {
            $deptCodeIdx = $i
            break
        }
    }
    if ($deptCodeIdx -lt 0) { return $null }

    $descEnd = $deptCodeIdx - 18
    if ($descEnd -lt 3) { return $null }

    $out = [string[]]::new(34)

    $out[0] = $Raw[0]   # record type (P)
    $out[1] = $Raw[1]   # file date (DD/MM/YYYY or DD-MM-YYYY)
    $out[2] = $Raw[2]   # EAN

    $out[3] = ($Raw[3..$descEnd] -join ',')

    for ($i = 4; $i -le 20; $i++) {
        $out[$i] = $Raw[$deptCodeIdx - 21 + $i]
    }

    $out[21] = $Raw[$deptCodeIdx]

    $deptNameEnd = $subDeptCodeIdx - 1
    $out[22] = if ($deptCodeIdx + 1 -le $deptNameEnd) {
                   ($Raw[($deptCodeIdx + 1)..$deptNameEnd] -join ',')
               } else { '' }

    $out[23] = $Raw[$subDeptCodeIdx]

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
    # Extracts a TAC*.zip, locates PRSSALE.dat, reads the sale date from
    # field[1] of the first P row, applies KI-002 hyphen normalisation,
    # renames the file, and returns FilePath, AggDate (ISO), TempDir.
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

    # KI-002: normalise DD-MM-YYYY to DD/MM/YYYY before splitting
    $dateNorm = $dateRaw.Replace('-', '/')
    $p        = $dateNorm -split '/'
    $yyyymmdd = "$($p[2])$($p[1])$($p[0])"
    $isoDate  = "$($p[2])-$($p[1])-$($p[0])"

    $storeTag = $StoreName.Replace(' ', '_')
    $newName  = "PRSSALE_${storeTag}_${yyyymmdd}.dat"
    $newPath  = Join-Path (Split-Path $prssalePath -Parent) $newName
    Move-Item -Path $prssalePath -Destination $newPath -Force

    return [PSCustomObject]@{
        FilePath = $newPath
        AggDate  = $isoDate
        TempDir  = $tempDir
    }
}

function Test-DateExists {
    # Returns $true if daily_snapshots already has rows for this store + date.
    param([string]$SnapDate)
    $url  = "$SupabaseUrl/rest/v1/daily_snapshots" +
            "?select=snapshot_date" +
            "&store_code=eq.$StoreCode" +
            "&snapshot_date=eq.$SnapDate" +
            "&limit=1"
    $hdrs = @{ 'apikey' = $SupabaseKey; 'Authorization' = "Bearer $SupabaseKey" }
    try {
        $rows = Invoke-RestMethod -Uri $url -Method GET -Headers $hdrs
        return ($rows -and $rows.Count -gt 0)
    }
    catch { return $false }
}

function Invoke-ParsePrssaleForSnapshots {
    # Parses PRSSALE.dat and maps all 27 daily_snapshots columns.
    # Inclusion rules (same as prssale_parser_v2.py):
    #   - Status == 'Delete'                                         -> EXCLUDE
    #   - last_sales_date == 01/01/1990 AND soh == 0 AND period_qty == 0 -> EXCLUDE (pure placeholder)
    #   - last_sales_date == 01/01/1990 AND (soh > 0 OR period_qty > 0) -> INCLUDE, is_placeholder = true
    #   - All other rows including today_qty == 0                    -> INCLUDE, is_placeholder = false
    # EAN synthesis: PLU codes shorter than 8 digits get a synthetic 13-digit EAN
    #   (store_code zero-padded to 5 digits) + (PLU zero-padded to 8 digits).
    param([string]$FilePath, [string]$SnapDate)

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
            $skipped++
            Write-Warning "Unparseable P row ($($raw.Count) tokens) skipped: $($line.Substring(0, [Math]::Min(120, $line.Length)))"
            continue
        }

        $status = $fields[26].Trim()

        $lastDateRaw = $fields[28].Trim()
        # KI-002: normalise hyphen dates in last_sales_date_raw before comparison
        $lastDateNorm = $lastDateRaw.Replace('-', '/')

        $periodQty = Parse-NumericField $fields[11]
        $soh       = Parse-NumericField $fields[20]

        $isPlaceholder = ($lastDateNorm -eq $PlaceholderDate)
        if ($isPlaceholder -and $soh -eq 0 -and $periodQty -eq 0) { continue }

        # Convert last_sales_date to ISO. NULL if placeholder date or pre-2000 or invalid.
        $lastDateIso = $null
        if (-not $isPlaceholder) {
            $converted = Convert-SigmaDate $lastDateNorm
            if ($converted -and $converted.Length -ge 4) {
                $yr = 0
                if ([int]::TryParse($converted.Substring(0, 4), [ref]$yr) -and $yr -ge 2000) {
                    $lastDateIso = $converted
                }
            }
        }

        # EAN synthesis: PLU codes (< 8 digits, all numeric) get a synthetic 13-digit EAN
        # to ensure global uniqueness across stores. Format: store_code(5) + PLU(8).
        $rawEan = $fields[2].Trim()
        $ean = if ($rawEan -match '^\d+$' -and $rawEan.Length -lt 8) {
                   $StoreCode.PadLeft(5, '0') + $rawEan.PadLeft(8, '0')
               } else {
                   $rawEan
               }

        # file_date: normalise hyphen format to slash format for consistency
        $fileDate = $fields[1].Trim().Replace('-', '/')

        # unit_cost: use period cost/qty when available; fall back to 80% of ex-VAT sell price
        $periodCost = Parse-NumericField $fields[12]
        $sellPrice  = Parse-NumericField $fields[6]
        $vatPct     = Parse-NumericField $fields[7]

        $unitCost = if ($periodQty -ne 0) {
                        [Math]::Round($periodCost / [Math]::Abs($periodQty), 4)
                    } elseif ($sellPrice -gt 0) {
                        $divisor = 1 + ($vatPct / 100)
                        $exVat   = if ($divisor -gt 0) { $sellPrice / $divisor } else { $sellPrice }
                        [Math]::Round($exVat * 0.80, 4)
                    } else {
                        0.0
                    }

        $record = [ordered]@{
            store_code          = $StoreCode
            store_name          = $StoreName
            file_date           = $fileDate
            snapshot_date       = $SnapDate
            ean                 = $ean
            description         = $fields[3].Trim()
            size                = $fields[4].Trim()
            unit                = $fields[5].Trim()
            sell_price          = [Math]::Round($sellPrice, 4)
            vat_pct             = [Math]::Round($vatPct, 4)
            today_qty           = [Math]::Round((Parse-NumericField $fields[8]), 3)
            today_cost          = [Math]::Round((Parse-NumericField $fields[9]), 2)
            today_sales         = [Math]::Round((Parse-NumericField $fields[10]), 2)
            period_qty          = [Math]::Round($periodQty, 3)
            period_cost         = [Math]::Round($periodCost, 2)
            period_sales        = [Math]::Round((Parse-NumericField $fields[13]), 2)
            soh                 = [Math]::Round($soh, 3)
            dept_code           = $fields[21].Trim()
            dept_name           = $fields[22].Trim()
            sub_dept_code       = $fields[23].Trim()
            sub_dept_name       = $fields[24].Trim()
            internal_ref        = $fields[25].Trim()
            status              = $status
            promo               = $fields[27].Trim()
            last_sales_date_raw = $lastDateRaw
            last_sales_date_iso = $lastDateIso
            unit_cost           = $unitCost
            is_placeholder      = $isPlaceholder
        }
        $records.Add($record)
    }

    if ($skipped -gt 0) { Write-Warning "Skipped $skipped unparseable rows in $FilePath" }
    return ,$records
}

# =============================================================================
# PUSH: departments + sub_departments  <-  DW220sDB reference tables
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
# PUSH: daily_snapshots  <-  PRSSALE.DAT  (nightly - latest TAC zip only)
# All 27 columns. Full catalog including zero-sale rows. No zero-sale filter.
# Conflict key: store_code, snapshot_date, ean.
# =============================================================================

function Push-DailySnapshotsNightly {
    Write-Host "`n[daily_snapshots] Starting nightly push from PRSSALE.DAT..." -ForegroundColor Cyan
    $logId   = $null
    $tempDir = $null

    try {
        $logId = Start-PushLog -TableName 'daily_snapshots'

        $zips = @(Get-ChildItem -Path $TacZipDir -Filter 'TAC*.zip' -ErrorAction Stop |
                  Sort-Object LastWriteTime -Descending)
        if ($zips.Count -eq 0) { throw "No TAC*.zip files found in $TacZipDir" }

        $latest = $zips[0]
        Write-Host "  ZIP: $($latest.Name)  (modified $($latest.LastWriteTime))"

        $extracted = Invoke-TacExtract -ZipPath $latest.FullName
        $tempDir   = $extracted.TempDir
        $snapDate  = $extracted.AggDate
        Write-Host "  Snapshot date: $snapDate"

        $records = Invoke-ParsePrssaleForSnapshots -FilePath $extracted.FilePath -SnapDate $snapDate
        Write-Host "  Rows to push (full catalog, excl Delete + pure placeholders): $($records.Count)"

        $pushed = 0
        $batch  = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($rec in $records) {
            $batch.Add($rec)
            if ($batch.Count -ge $BatchSize) {
                $pushed += Send-Batch -TableName 'daily_snapshots' `
                                      -ConflictCols 'store_code,snapshot_date,ean' `
                                      -Rows $batch.ToArray() -LogId $logId
                $batch.Clear()
                Write-Host "  Pushed $pushed rows so far..."
            }
        }
        if ($batch.Count -gt 0) {
            $pushed += Send-Batch -TableName 'daily_snapshots' `
                                  -ConflictCols 'store_code,snapshot_date,ean' `
                                  -Rows $batch.ToArray() -LogId $logId
        }

        Complete-PushLog -LogId $logId -Status 'SUCCESS' -RowsPushed $pushed
        Write-Host "  [daily_snapshots] Done. $pushed rows pushed." -ForegroundColor Green
    }
    catch {
        $msg = $_.ToString()
        try {
            $stream = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $msg   += ' | ' + $reader.ReadToEnd()
        } catch {}
        Write-Host "  [daily_snapshots] FAILED: $msg" -ForegroundColor Red
        if ($logId) { try { Complete-PushLog -LogId $logId -Status 'FAILED' -Msg $msg } catch {} }
    }
    finally {
        if ($tempDir -and (Test-Path $tempDir)) {
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# =============================================================================
# PUSH: daily_snapshots  <-  all TAC*.zip files  (backfill mode)
# =============================================================================

function Push-DailySnapshotsBackfill {
    Write-Host "`n[daily_snapshots] Backfill mode - processing all TAC*.zip files..." -ForegroundColor Cyan

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
            $logId = Start-PushLog -TableName 'daily_snapshots'

            $extracted = Invoke-TacExtract -ZipPath $zip.FullName
            $tempDir   = $extracted.TempDir
            $snapDate  = $extracted.AggDate
            Write-Host "  Date: $snapDate"

            if ([datetime]$snapDate -lt $BackfillFrom) {
                Write-Host "  SKIP - $snapDate is before BackfillFrom $($BackfillFrom.ToString('yyyy-MM-dd'))." -ForegroundColor DarkGray
                Complete-PushLog -LogId $logId -Status 'SUCCESS' -RowsPushed 0 `
                    -Msg "Skipped - before BackfillFrom threshold"
                $totalSkipped++
                continue
            }

            if (-not $Force -and (Test-DateExists -SnapDate $snapDate)) {
                Write-Host "  SKIP - $snapDate already in daily_snapshots. Use -Force to overwrite." -ForegroundColor Yellow
                Complete-PushLog -LogId $logId -Status 'SUCCESS' -RowsPushed 0 `
                    -Msg "Skipped - $snapDate already loaded for store $StoreCode"
                $totalSkipped++
                continue
            }

            $records = Invoke-ParsePrssaleForSnapshots -FilePath $extracted.FilePath -SnapDate $snapDate
            Write-Host "  Rows to push: $($records.Count)"

            $pushed = 0
            $batch  = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($rec in $records) {
                $batch.Add($rec)
                if ($batch.Count -ge $BatchSize) {
                    $pushed += Send-Batch -TableName 'daily_snapshots' `
                                          -ConflictCols 'store_code,snapshot_date,ean' `
                                          -Rows $batch.ToArray() -LogId $logId
                    $batch.Clear()
                }
            }
            if ($batch.Count -gt 0) {
                $pushed += Send-Batch -TableName 'daily_snapshots' `
                                      -ConflictCols 'store_code,snapshot_date,ean' `
                                      -Rows $batch.ToArray() -LogId $logId
            }

            Complete-PushLog -LogId $logId -Status 'SUCCESS' -RowsPushed $pushed
            Write-Host "  Pushed $pushed rows for $snapDate." -ForegroundColor Green
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

    Write-Host ("`n[daily_snapshots] Backfill complete. " +
                "$totalPushed rows pushed. $totalSkipped dates skipped.") -ForegroundColor Green
}

# =============================================================================
# PUSH: stock_snapshots  <-  npos.dbo.dewas_PLU_s
# Retained for intraday SOH readings. Not used by the dashboard.
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
# REFRESH: mv_kpi_by_date materialized view
# =============================================================================

function Invoke-RefreshKpiView {
    Write-Host "`n[kpi_view] Refreshing mv_kpi_by_date..." -ForegroundColor Cyan
    $url  = "$SupabaseUrl/rest/v1/rpc/refresh_kpi_view"
    $hdrs = @{
        'apikey'        = $SupabaseKey
        'Authorization' = "Bearer $SupabaseKey"
        'Content-Type'  = 'application/json'
    }
    try {
        $null = Invoke-RestMethod -Uri $url -Method POST -Headers $hdrs -Body '{}'
        Write-Host "  Dashboard view refreshed - Pulse is live." -ForegroundColor Green
    }
    catch {
        Write-Warning "View refresh failed: $_"
        Write-Warning "Run manually in Supabase SQL Editor: REFRESH MATERIALIZED VIEW mv_kpi_by_date;"
    }
}

# =============================================================================
# UPSERT: product_search_index
# One row per EAN; stores[] array accumulates across all store servers.
# Runs after daily_snapshots push so the index reflects the latest catalog.
# =============================================================================

function Invoke-UpsertSearchIndex {
    Write-Host "`n[search_index] Updating product_search_index for store $StoreCode..." -ForegroundColor Cyan
    $url  = "$SupabaseUrl/rest/v1/rpc/upsert_search_index"
    $hdrs = @{
        'apikey'        = $SupabaseKey
        'Authorization' = "Bearer $SupabaseKey"
        'Content-Type'  = 'application/json'
    }
    $body = '{"p_store_code":"' + $StoreCode + '"}'
    try {
        $null = Invoke-RestMethod -Uri $url -Method POST -Headers $hdrs -Body $body
        Write-Host "  Search index updated for store $StoreCode." -ForegroundColor Green
    }
    catch {
        Write-Warning "Search index upsert failed: $_"
        Write-Warning "Run manually: SELECT upsert_search_index('$StoreCode');"
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
            Push-DailySnapshotsBackfill
        } else {
            Push-DailySnapshotsNightly
        }
        Push-StockSnapshots
        Invoke-RefreshKpiView
        Invoke-UpsertSearchIndex
    }
    'intraday' {
        Write-Host "Intraday mode not yet implemented (Phase 2)." -ForegroundColor Yellow
        exit 0
    }
}

Write-Host "`nCompleted: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White

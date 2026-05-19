#Requires -Version 5.1
# Discover-SigmaTables3.ps1
# Validates DBUmBA as the correct sales source.
# Run ON the store server AFTER end-of-day (DW220sDB tables only update at EOD).
# Output saved to C:\socialbrand\sigma_discovery3.txt

$Server  = 'localhost\SIGMA'
$OutDir  = 'C:\socialbrand'
$OutFile = "$OutDir\sigma_discovery3.txt"
$Lines   = [System.Collections.Generic.List[string]]::new()

if (-not (Test-Path $OutDir)) { $null = New-Item -ItemType Directory -Path $OutDir -Force }

function Log { param([string]$s) $Lines.Add($s); Write-Host $s }

Log "Sigma Discovery Pass 3 - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Log "Server: $Server"
Log "Target: confirm DBUmBA covers ~2038 SKUs on 2026-05-10 with total sales ~R191245"
Log ""

function Run-Query {
    param([string]$Db, [string]$Sql)
    $conn = New-Object System.Data.SqlClient.SqlConnection(
        "Server=$Server;Database=$Db;Integrated Security=True;Connection Timeout=10;")
    $conn.Open()
    $cmd = $conn.CreateCommand()
    $cmd.CommandText    = $Sql
    $cmd.CommandTimeout = 60
    $da  = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
    $dt  = New-Object System.Data.DataTable
    $null = $da.Fill($dt)
    $conn.Close()
    return ,$dt
}

# --- 1. DBUmBA breakdown by cPerKz on May 10 ---
Log "=== DBUmBA: breakdown by cPerKz on 2026-05-10 ==="
Log "(cPerKz is the period key - likely D=daily, W=weekly, M=monthly per SKU)"
try {
    $dt = Run-Query -Db 'DW220sDB' -Sql @"
SELECT
    cPerKz,
    COUNT(*)             AS rows,
    COUNT(DISTINCT CAST(CAST(dArtNr AS BIGINT) AS VARCHAR(20))) AS unique_skus,
    SUM(dVKUmsatz)       AS total_sales_incl_vat,
    SUM(dEKUmsatz)       AS total_cost,
    SUM(dMenge)          AS total_qty
FROM DW220sDB.dbo.DBUmBA WITH (NOLOCK)
WHERE dtDatum = '2026-05-10'
  AND siMktNr = 1
GROUP BY cPerKz
ORDER BY cPerKz
"@
    foreach ($r in $dt.Rows) {
        Log "  cPerKz='$($r.cPerKz)'  rows=$($r.rows)  unique_skus=$($r.unique_skus)  total_sales=$([math]::Round($r.total_sales_incl_vat,2))  total_cost=$([math]::Round($r.total_cost,2))  total_qty=$([math]::Round($r.total_qty,2))"
    }
} catch { Log "  ERROR: $_" }

Log ""

# --- 2. DBUmBA: all siMktNr values present ---
Log "=== DBUmBA: siMktNr values in table ==="
try {
    $dt = Run-Query -Db 'DW220sDB' -Sql @"
SELECT siMktNr, COUNT(*) AS rows, MIN(dtDatum) AS min_date, MAX(dtDatum) AS max_date
FROM DW220sDB.dbo.DBUmBA WITH (NOLOCK)
GROUP BY siMktNr
ORDER BY siMktNr
"@
    foreach ($r in $dt.Rows) {
        Log "  siMktNr=$($r.siMktNr)  rows=$($r.rows)  dates=$($r.min_date) to $($r.max_date)"
    }
} catch { Log "  ERROR: $_" }

Log ""

# --- 3. DBUmBA: all cVorKz values (+ = sale, - = return?) ---
Log "=== DBUmBA: cVorKz values on 2026-05-10 (+ sale / - return) ==="
try {
    $dt = Run-Query -Db 'DW220sDB' -Sql @"
SELECT cVorKz, COUNT(*) AS rows, SUM(dVKUmsatz) AS total_sales
FROM DW220sDB.dbo.DBUmBA WITH (NOLOCK)
WHERE dtDatum = '2026-05-10' AND siMktNr = 1
GROUP BY cVorKz
ORDER BY cVorKz
"@
    foreach ($r in $dt.Rows) {
        Log "  cVorKz='$($r.cVorKz)'  rows=$($r.rows)  total_sales=$([math]::Round($r.total_sales,2))"
    }
} catch { Log "  ERROR: $_" }

Log ""

# --- 4. DBAUms vs DBUmBA side-by-side on May 10 (daily cPerKz only) ---
Log "=== Side-by-side comparison on 2026-05-10 ==="
Log "  PRSSALE reference:  unique_skus=2038  total_sales=191245"
try {
    $dba = Run-Query -Db 'DW220sDB' -Sql @"
SELECT COUNT(DISTINCT CAST(CAST(dArtNr AS BIGINT) AS VARCHAR(20))) AS unique_skus,
       SUM(dUmsVK) AS total_sales, SUM(dMenge) AS total_qty
FROM DW220sDB.dbo.DBAUms WITH (NOLOCK)
WHERE dtDatum = '2026-05-10' AND siMktNr = 1
"@
    $r = $dba.Rows[0]
    Log "  DBAUms (all siKz):  unique_skus=$($r.unique_skus)  total_sales=$([math]::Round($r.total_sales,2))  total_qty=$([math]::Round($r.total_qty,2))"
} catch { Log "  DBAUms ERROR: $_" }

try {
    $dbu = Run-Query -Db 'DW220sDB' -Sql @"
SELECT COUNT(DISTINCT CAST(CAST(dArtNr AS BIGINT) AS VARCHAR(20))) AS unique_skus,
       SUM(dVKUmsatz) AS total_sales, SUM(dMenge) AS total_qty
FROM DW220sDB.dbo.DBUmBA WITH (NOLOCK)
WHERE dtDatum = '2026-05-10' AND siMktNr = 1 AND cPerKz = 'D'
"@
    $r = $dbu.Rows[0]
    Log "  DBUmBA (cPerKz=D):  unique_skus=$($r.unique_skus)  total_sales=$([math]::Round($r.total_sales,2))  total_qty=$([math]::Round($r.total_qty,2))"
} catch { Log "  DBUmBA ERROR: $_" }

Log ""

# --- 5. Sample 10 rows from DBUmBA to see if dArtNr joins to DBARTS ---
Log "=== DBUmBA: 10 sample rows for 2026-05-10 with article description ==="
try {
    $dt = Run-Query -Db 'DW220sDB' -Sql @"
SELECT TOP 10
    b.cPerKz,
    CAST(CAST(b.dArtNr AS BIGINT) AS VARCHAR(20)) AS art_nr,
    LTRIM(RTRIM(a.cBEZ))  AS description,
    b.dVKUmsatz           AS sales_incl_vat,
    b.dEKUmsatz           AS cost,
    b.dMenge              AS qty
FROM DW220sDB.dbo.DBUmBA b WITH (NOLOCK)
LEFT JOIN DW220sDB.dbo.DBARTS a ON b.dArtNr = a.dARTNR
WHERE b.dtDatum = '2026-05-10'
  AND b.siMktNr = 1
  AND b.cPerKz  = 'D'
ORDER BY b.dVKUmsatz DESC
"@
    foreach ($r in $dt.Rows) {
        Log "  [$($r.cPerKz)] $($r.art_nr)  $($r.description)  sales=$($r.sales_incl_vat)  qty=$($r.qty)"
    }
} catch { Log "  ERROR: $_" }

Log ""
Log "Done: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

$Lines | Set-Content -Path $OutFile -Encoding UTF8
Write-Host ""
Write-Host "Saved to: $OutFile" -ForegroundColor Green
Read-Host "Press Enter to close"

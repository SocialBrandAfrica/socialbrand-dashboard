#Requires -Version 5.1
# Discover-LiveVsEOD.ps1
# Run ON the store server DURING TRADING HOURS.
# Captures live vs EOD table state so we know what is safe to read
# during the day and what only appears after close.
# Output saved to C:\socialbrand\sigma_live_vs_eod.txt

$Server  = 'localhost\SIGMA'
$OutDir  = 'C:\socialbrand'
$OutFile = "$OutDir\sigma_live_vs_eod.txt"
$Today   = (Get-Date).ToString('yyyy-MM-dd')
$Lines   = [System.Collections.Generic.List[string]]::new()

if (-not (Test-Path $OutDir)) { $null = New-Item -ItemType Directory -Path $OutDir -Force }

function Log { param([string]$s) $Lines.Add($s); Write-Host $s }

Log "Live-vs-EOD Snapshot - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Log "Server: $Server"
Log "Today: $Today"
Log ""

function Run-Query {
    param([string]$Db, [string]$Sql)
    $conn = New-Object System.Data.SqlClient.SqlConnection(
        "Server=$Server;Database=$Db;Integrated Security=True;Connection Timeout=10;")
    $conn.Open()
    $cmd = $conn.CreateCommand()
    $cmd.CommandText    = $Sql
    $cmd.CommandTimeout = 30
    $da  = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
    $dt  = New-Object System.Data.DataTable
    $null = $da.Fill($dt)
    $conn.Close()
    return ,$dt
}

# --- 1. TAC zip files in Catman folder ---
Log "=== TAC zip files in S:\sigma\comms\Catman ==="
try {
    $zips = Get-ChildItem -Path 'S:\sigma\comms\Catman' -Filter 'TAC*.zip' -ErrorAction Stop |
            Sort-Object LastWriteTime -Descending
    if ($zips.Count -eq 0) {
        Log "  (none found)"
    } else {
        foreach ($z in $zips) {
            Log "  $($z.Name)  size=$([math]::Round($z.Length/1KB,1))KB  modified=$($z.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
        }
    }
} catch {
    Log "  ERROR reading Catman folder: $_"
}

Log ""

# --- 2. DW220sDB tables - do they have rows for TODAY? ---
Log "=== DW220sDB tables: rows for today ($Today) ==="
Log "(If 0, these tables only update at EOD)"

$dwChecks = @(
    @{Tbl='DBAUms';  DateCol='dtDatum'},
    @{Tbl='DBUmBA';  DateCol='dtDatum'},
    @{Tbl='DBUmWg';  DateCol='dtDatum'},
    @{Tbl='DBUmAb';  DateCol='dtDatum'}
)
foreach ($c in $dwChecks) {
    try {
        $dt = Run-Query -Db 'DW220sDB' -Sql "SELECT COUNT(*) AS n FROM DW220sDB.dbo.$($c.Tbl) WITH (NOLOCK) WHERE CAST($($c.DateCol) AS DATE) = '$Today'"
        $n = $dt.Rows[0].n
        $flag = if ($n -gt 0) { '  <-- UPDATES LIVE DURING TRADING' } else { '  (EOD only)' }
        Log "  $($c.Tbl): $n rows for today$flag"
    } catch { Log "  $($c.Tbl): ERROR - $_" }
}

Log ""

# --- 3. npos live transaction tables ---
Log "=== npos live tables: transactions so far today ==="

try {
    $dt = Run-Query -Db 'npos' -Sql "SELECT COUNT(*) AS n FROM npos.dbo.T_h1 WITH (NOLOCK) WHERE CAST(Sale_date AS DATE) = '$Today'"
    Log "  T_h1 (transaction headers today): $($dt.Rows[0].n) transactions so far"
} catch { Log "  T_h1: ERROR - $_" }

try {
    $dt = Run-Query -Db 'npos' -Sql "SELECT COUNT(*) AS n FROM npos.dbo.T_l1 WITH (NOLOCK)"
    Log "  T_l1 (transaction lines total): $($dt.Rows[0].n) rows (no date col - live rolling buffer)"
} catch { Log "  T_l1: ERROR - $_" }

Log ""

# --- 4. PLU_s vs dewas_PLU_s ---
Log "=== SOH tables: live vs EOD snapshot ==="

try {
    $dt = Run-Query -Db 'npos' -Sql "SELECT COUNT(*) AS n, SUM(CAST(s_stock AS FLOAT)) AS total_soh FROM npos.dbo.PLU_s WITH (NOLOCK)"
    $r = $dt.Rows[0]
    Log "  PLU_s (live):        rows=$($r.n)  total_soh=$([math]::Round([double]$r.total_soh, 0))"
} catch { Log "  PLU_s: ERROR - $_" }

try {
    $dt = Run-Query -Db 'npos' -Sql "SELECT COUNT(*) AS n, SUM(CAST(s_stock AS FLOAT)) AS total_soh FROM npos.dbo.dewas_PLU_s WITH (NOLOCK)"
    $r = $dt.Rows[0]
    Log "  dewas_PLU_s (EOD snapshot): rows=$($r.n)  total_soh=$([math]::Round([double]$r.total_soh, 0))"
} catch { Log "  dewas_PLU_s: ERROR - $_" }

Log ""

# --- 5. dewas_T_bu today vs T_bu today ---
Log "=== Booking tables: live vs EOD snapshot ==="

try {
    $dt = Run-Query -Db 'npos' -Sql "SELECT COUNT(*) AS n FROM npos.dbo.T_bu WITH (NOLOCK) WHERE CAST(datum AS DATE) = '$Today'"
    Log "  T_bu (live today): $($dt.Rows[0].n) rows"
} catch { Log "  T_bu: ERROR - $_" }

try {
    $dt = Run-Query -Db 'npos' -Sql "SELECT COUNT(*) AS n FROM npos.dbo.dewas_T_bu WITH (NOLOCK) WHERE CAST(datum AS DATE) = '$Today'"
    Log "  dewas_T_bu (EOD snapshot today): $($dt.Rows[0].n) rows"
} catch { Log "  dewas_T_bu: ERROR - $_" }

Log ""
Log "Done: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Log "Run this again after EOD close and compare the numbers."

$Lines | Set-Content -Path $OutFile -Encoding UTF8
Write-Host ""
Write-Host "Saved to: $OutFile" -ForegroundColor Green
Read-Host "Press Enter to close"

#Requires -Version 5.1
# Discover-SigmaTables.ps1
# Run ON the store server. Output saved to C:\socialbrand\sigma_discovery.txt

$Server  = 'localhost\SIGMA'
$OutDir  = 'C:\socialbrand'
$OutFile = "$OutDir\sigma_discovery.txt"
$Lines   = [System.Collections.Generic.List[string]]::new()

if (-not (Test-Path $OutDir)) { $null = New-Item -ItemType Directory -Path $OutDir -Force }

function Log { param([string]$s) $Lines.Add($s); Write-Host $s }

Log "Sigma Discovery - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Log "Server: $Server"
Log ""

# --- test connection first ---
try {
    $testConn = New-Object System.Data.SqlClient.SqlConnection(
        "Server=$Server;Database=master;Integrated Security=True;Connection Timeout=10;")
    $testConn.Open()
    $testConn.Close()
    Log "Connection: OK"
} catch {
    Log "CONNECTION FAILED: $_"
    Log "Make sure you are running this ON the store server, not from your PC."
    $Lines | Set-Content -Path $OutFile -Encoding UTF8
    Write-Host ""
    Write-Host "Saved to: $OutFile" -ForegroundColor Yellow
    Read-Host "Press Enter to close"
    exit 1
}

function Run-Query {
    param([string]$Db, [string]$Sql)
    $conn = New-Object System.Data.SqlClient.SqlConnection(
        "Server=$Server;Database=$Db;Integrated Security=True;Connection Timeout=10;")
    $conn.Open()
    $cmd = $conn.CreateCommand()
    $cmd.CommandText   = $Sql
    $cmd.CommandTimeout = 60
    $da  = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
    $dt  = New-Object System.Data.DataTable
    $null = $da.Fill($dt)
    $conn.Close()
    return ,$dt
}

# --- list all tables in npos ---
Log "=== npos tables ==="
try {
    $dt = Run-Query -Db 'npos' -Sql "SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE='BASE TABLE' ORDER BY TABLE_NAME"
    foreach ($r in $dt.Rows) { Log "  $($r.TABLE_NAME)" }
} catch { Log "ERROR: $_" }

Log ""

# --- list all tables in DW220sDB ---
Log "=== DW220sDB tables ==="
try {
    $dt = Run-Query -Db 'DW220sDB' -Sql "SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE='BASE TABLE' ORDER BY TABLE_NAME"
    foreach ($r in $dt.Rows) { Log "  $($r.TABLE_NAME)" }
} catch { Log "ERROR: $_" }

Log ""

# --- check specific candidate tables ---
$checks = @(
    @{Db='npos';     Tbl='Transakt'},
    @{Db='npos';     Tbl='TransaktPos'},
    @{Db='npos';     Tbl='PLU_t'},
    @{Db='npos';     Tbl='PLU_v'},
    @{Db='npos';     Tbl='PLU_h'},
    @{Db='npos';     Tbl='Kassabon'},
    @{Db='npos';     Tbl='KassabonRegel'},
    @{Db='DW220sDB'; Tbl='DBAUms'},
    @{Db='DW220sDB'; Tbl='DBNUms'},
    @{Db='DW220sDB'; Tbl='DBUmsGes'}
)

Log "=== Candidate table details ==="
foreach ($c in $checks) {
    $db  = $c.Db
    $tbl = $c.Tbl
    try {
        $exists = Run-Query -Db $db -Sql "SELECT COUNT(*) AS n FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME='$tbl' AND TABLE_TYPE='BASE TABLE'"
        if ($exists.Rows[0].n -eq 0) { continue }

        Log ""
        Log "TABLE: $db.dbo.$tbl"

        # columns
        $cols = Run-Query -Db $db -Sql "SELECT COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='$tbl' ORDER BY ORDINAL_POSITION"
        $colStr = ($cols.Rows | ForEach-Object { "$($_.COLUMN_NAME)($($_.DATA_TYPE))" }) -join ', '
        Log "  Columns: $colStr"

        # row count
        $cnt = Run-Query -Db $db -Sql "SELECT COUNT(*) AS n FROM dbo.$tbl WITH (NOLOCK)"
        Log "  Total rows: $($cnt.Rows[0].n)"

        # date range + May 10 count using first date column
        $datCol = $cols.Rows | Where-Object { $_.DATA_TYPE -in @('date','datetime','smalldatetime') } | Select-Object -First 1
        if ($datCol) {
            $dc  = $datCol.COLUMN_NAME
            $rng = Run-Query -Db $db -Sql "SELECT MIN(CAST($dc AS DATE)) AS mn, MAX(CAST($dc AS DATE)) AS mx FROM dbo.$tbl WITH (NOLOCK)"
            Log "  Date range ($dc): $($rng.Rows[0].mn) to $($rng.Rows[0].mx)"
            $m10 = Run-Query -Db $db -Sql "SELECT COUNT(*) AS n FROM dbo.$tbl WITH (NOLOCK) WHERE CAST($dc AS DATE)='2026-05-10'"
            Log "  Rows on 2026-05-10: $($m10.Rows[0].n)"
        }
    } catch {
        Log "  $db.$tbl - ERROR: $_"
    }
}

# --- stored procs mentioning PRSSALE or Transakt ---
Log ""
Log "=== Stored procs mentioning PRSSALE or Transakt (npos) ==="
try {
    $sp = Run-Query -Db 'npos' -Sql @"
SELECT ROUTINE_NAME FROM INFORMATION_SCHEMA.ROUTINES
WHERE ROUTINE_TYPE='PROCEDURE'
  AND (ROUTINE_DEFINITION LIKE '%PRSSALE%' OR ROUTINE_DEFINITION LIKE '%Transakt%')
ORDER BY ROUTINE_NAME
"@
    if ($sp.Rows.Count -eq 0) { Log "  (none found)" }
    else { foreach ($r in $sp.Rows) { Log "  $($r.ROUTINE_NAME)" } }
} catch { Log "  ERROR: $_" }

Log ""
Log "Done: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

$Lines | Set-Content -Path $OutFile -Encoding UTF8
Write-Host ""
Write-Host "Saved to: $OutFile" -ForegroundColor Green
Read-Host "Press Enter to close"

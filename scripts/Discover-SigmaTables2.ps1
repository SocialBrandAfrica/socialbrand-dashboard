#Requires -Version 5.1
# Discover-SigmaTables2.ps1
# Second pass - checks candidates missed in first run.
# Run ON the store server. Output saved to C:\socialbrand\sigma_discovery2.txt

$Server  = 'localhost\SIGMA'
$OutDir  = 'C:\socialbrand'
$OutFile = "$OutDir\sigma_discovery2.txt"
$Lines   = [System.Collections.Generic.List[string]]::new()

if (-not (Test-Path $OutDir)) { $null = New-Item -ItemType Directory -Path $OutDir -Force }

function Log { param([string]$s) $Lines.Add($s); Write-Host $s }

Log "Sigma Discovery Pass 2 - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Log "Server: $Server"
Log "Target: find table with ~2038 rows on 2026-05-10 (matching PRSSALE product count)"
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

$checks = @(
    # dewas_ persistent tables in npos (most promising - dewas_PLU_s is the persistent SOH table)
    @{Db='npos';     Tbl='dewas_T_bu'},
    @{Db='npos';     Tbl='dewas_T_pay'},
    @{Db='npos';     Tbl='dewas_T_txt'},
    @{Db='npos';     Tbl='dewas_Wgr_m'},
    # live transaction tables in npos
    @{Db='npos';     Tbl='T_bu'},
    @{Db='npos';     Tbl='T_l1'},
    @{Db='npos';     Tbl='T_l2'},
    @{Db='npos';     Tbl='T_h1'},
    @{Db='npos';     Tbl='T_h2'},
    @{Db='npos';     Tbl='T_tot'},
    @{Db='npos';     Tbl='Dgrp_tot'},
    @{Db='npos';     Tbl='Wgr_m'},
    @{Db='npos';     Tbl='Ssal_h'},
    # DW220sDB detail/alternative turnover tables
    @{Db='DW220sDB'; Tbl='DBEUms'},
    @{Db='DW220sDB'; Tbl='DBNVEK'},
    @{Db='DW220sDB'; Tbl='DBNVEP'},
    @{Db='DW220sDB'; Tbl='DBUmsa'},
    @{Db='DW220sDB'; Tbl='DBUmWg'},
    @{Db='DW220sDB'; Tbl='DBUmAb'},
    @{Db='DW220sDB'; Tbl='DBUmAK'},
    @{Db='DW220sDB'; Tbl='DBUmBA'},
    @{Db='DW220sDB'; Tbl='DBUmRg'}
)

foreach ($c in $checks) {
    $db  = $c.Db
    $tbl = $c.Tbl
    try {
        $exists = Run-Query -Db $db -Sql "SELECT COUNT(*) AS n FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME='$tbl' AND TABLE_TYPE='BASE TABLE'"
        if ($exists.Rows[0].n -eq 0) {
            Log "$db.dbo.$tbl - NOT FOUND"
            continue
        }

        Log ""
        Log "TABLE: $db.dbo.$tbl"

        $cols = Run-Query -Db $db -Sql "SELECT COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='$tbl' ORDER BY ORDINAL_POSITION"
        $colStr = ($cols.Rows | ForEach-Object { "$($_.COLUMN_NAME)($($_.DATA_TYPE))" }) -join ', '
        Log "  Columns: $colStr"

        $cnt = Run-Query -Db $db -Sql "SELECT COUNT(*) AS n FROM dbo.$tbl WITH (NOLOCK)"
        Log "  Total rows: $($cnt.Rows[0].n)"

        $datCol = $cols.Rows | Where-Object { $_.DATA_TYPE -in @('date','datetime','smalldatetime') } | Select-Object -First 1
        if ($datCol) {
            $dc  = $datCol.COLUMN_NAME
            $rng = Run-Query -Db $db -Sql "SELECT MIN(CAST($dc AS DATE)) AS mn, MAX(CAST($dc AS DATE)) AS mx FROM dbo.$tbl WITH (NOLOCK)"
            Log "  Date range ($dc): $($rng.Rows[0].mn) to $($rng.Rows[0].mx)"
            $m10 = Run-Query -Db $db -Sql "SELECT COUNT(*) AS n FROM dbo.$tbl WITH (NOLOCK) WHERE CAST($dc AS DATE)='2026-05-10'"
            Log "  Rows on 2026-05-10: $($m10.Rows[0].n)"
        } else {
            Log "  (no date column found - check columns above)"
        }
    } catch {
        Log "  $db.$tbl - ERROR: $_"
    }
}

Log ""
Log "Done: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

$Lines | Set-Content -Path $OutFile -Encoding UTF8
Write-Host ""
Write-Host "Saved to: $OutFile" -ForegroundColor Green
Read-Host "Press Enter to close"

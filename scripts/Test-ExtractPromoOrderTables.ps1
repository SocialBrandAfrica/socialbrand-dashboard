<#
Test-ExtractPromoOrderTables.ps1
SB-CC-BLOOM-031 A1 / SB-AUD-PROMO-001 section 8.5 item 2. Written 2026-09-21 by CC. TEST ONLY.

WHAT IT DOES
Mirrors six Sigma tables into the platform, EVERY column (THE MIRROR RULE, SIGMA-SERVER-SCHEMA-MAP v1.7):
  DBAdik  promotion order headers   -> sigma_raw_dbadik
  DBAdip  promotion order lines     -> sigma_raw_dbadip
  DBAdit  promotion order texts     -> sigma_raw_dbadit
  DBAufK  order headers             -> sigma_raw_dbaufk
  DBAufP  order lines               -> sigma_raw_dbaufp
  IntelliAcc.IntellistoX_Promo_Info_Master (current promotions, snapshot) -> sigma_raw_intellistox_promo
Window: promotions ending, and orders placed, dated or received, in the last -Quarters quarters (default 6).

SAFE
Reads Sigma with READ UNCOMMITTED (no locks, Sigma is never blocked). Writes only to the six sigma_raw_*
tables and one push_log row per table (push_type raw_mirror_test). Does NOT touch the nightly extractor,
its task (Retail History) or any table the dashboard reads. Re-running is safe: rows upsert on Sigma's key.

HOW TO RUN (on the store server, in the extractor's folder, the one holding sb-key.txt)
  1. Copy this file into that folder (for example C:\RetailHistory).
  2. Open PowerShell there and run the dry run first. It reads and counts, and pushes nothing:
       powershell -ExecutionPolicy Bypass -File .\Test-ExtractPromoOrderTables.ps1 -DryRun
  3. If every table says COLUMNS OK, run it for real:
       powershell -ExecutionPolicy Bypass -File .\Test-ExtractPromoOrderTables.ps1
  4. Send CC the file raw_mirror_test_<store>_<date>.log that it writes in the same folder.
  Optional: -Only DBAdik,DBAdip to run some tables only. -Quarters 6 to change the window.
#>
param(
    [switch]$DryRun,
    [int]$Quarters = 6,
    [string[]]$Only = @(),
    [string]$KeyFile = ''
)
$ErrorActionPreference = 'Stop'
$ScriptVersion = 'raw-mirror-test-v0.1'
$ClientId      = 'socialbrand'
$BatchSize     = 500
$RetryMax      = 3
$RetryWaitSecs = 10
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

$BaseDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($BaseDir)) { $BaseDir = (Get-Location).Path }

$HostMap = @{
    'SRSDELAREYVILES' = '10116'
    'SRSROOSVILLESVR' = '80175'
    'SRTDELAREYVILSV' = '21355'
    'SRSDELAREYT2SVR' = '80579'
    'SRTROOSVILLESVR' = '80176'
}
$HostKey = $env:COMPUTERNAME.ToUpper()
if (-not $HostMap.ContainsKey($HostKey)) { throw "Unknown host '$HostKey'." }
$StoreCode   = $HostMap[$HostKey]
$CaptureDate = (Get-Date).ToString('yyyy-MM-dd')
$LogFile     = Join-Path $BaseDir ("raw_mirror_test_" + $StoreCode + "_" + (Get-Date).ToString('yyyy-MM-dd_HHmm') + ".log")

function Write-Log {
    param([string]$Msg)
    $line = (Get-Date).ToString('HH:mm:ss') + '  ' + $Msg
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

$SupabaseUrl = 'https://crklvhfwyxlisfcvqenc.supabase.co'
if ([string]::IsNullOrWhiteSpace($KeyFile)) {
    foreach ($cand in @((Join-Path $BaseDir 'sb-key.txt'), 'C:\RetailHistory\sb-key.txt', 'C:\socialbrand\sb-key.txt')) {
        if (Test-Path $cand) { $KeyFile = $cand; break }
    }
}
if ([string]::IsNullOrWhiteSpace($KeyFile) -or -not (Test-Path $KeyFile)) {
    throw "sb-key.txt not found. Put this script in the extractor folder or pass -KeyFile."
}
$SupabaseKey = (Get-Content $KeyFile -Raw).Trim()

function Get-Headers {
    return @{
        'apikey'        = $SupabaseKey
        'Authorization' = "Bearer $SupabaseKey"
        'Content-Type'  = 'application/json; charset=utf-8'
        'Prefer'        = 'resolution=merge-duplicates,return=minimal'
        'User-Agent'    = "RetailHistory-RawMirrorTest/$ScriptVersion PowerShell"
    }
}

function Send-Batch {
    param([string]$Table, [string]$ConflictCols, [array]$Rows)
    $url     = "$SupabaseUrl/rest/v1/$Table`?on_conflict=$ConflictCols"
    $attempt = 0
    while ($attempt -lt $RetryMax) {
        try {
            $json  = ConvertTo-Json -InputObject @($Rows) -Depth 5 -Compress
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            $null  = Invoke-RestMethod -Uri $url -Method POST -Headers (Get-Headers) -Body $bytes -TimeoutSec 120
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
            Write-Log ("  batch attempt $attempt/$RetryMax failed for $Table : " + $_.ToString() + $detail)
            if ($attempt -lt $RetryMax) { Start-Sleep -Seconds $RetryWaitSecs }
        }
    }
    return 0
}

function Send-PushLog {
    param([string]$Table, [datetime]$Started, [long]$Pushed, [long]$Failed, [long]$Expected, [string]$Status, [string]$Err)
    try {
        # ENG-214 (2026-09-23): push_log.client_id is UUID (the legacy Phase-1 type), not text.
        # Posting 'socialbrand' into it fails 22P02 and the catch below swallowed it, so the real
        # 21-09 run at 80175 wrote ZERO raw_mirror_test rows while the data landed correctly. The
        # nightly extractor's Send-TableLog omits the column for the same reason. Do not re-add it.
        $body = [ordered]@{
            store_code       = $StoreCode
            push_type        = 'raw_mirror_test'
            table_name       = $Table
            started_at       = $Started.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            completed_at     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            rows_pushed      = $Pushed
            rows_failed      = $Failed
            rows_expected    = $Expected
            status           = $Status
            error_message    = $Err
            script_version   = $ScriptVersion
            snapshot_date    = $CaptureDate
            duration_seconds = [int]((Get-Date) - $Started).TotalSeconds
        }
        $h = Get-Headers
        $h['Prefer'] = 'return=minimal'
        $bytes = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $body -Compress))
        $null = Invoke-RestMethod -Uri "$SupabaseUrl/rest/v1/push_log" -Method POST -Headers $h -Body $bytes -TimeoutSec 60
    }
    catch { Write-Log ("  push_log write failed: " + $_.ToString()) }
}

function Convert-Value {
    # Every column as Sigma holds it. Text: control characters stripped and trailing padding trimmed,
    # the same cleaning the nightly extractor applies (Safe-Text), empty becomes null.
    param($v, [string]$SqlType)
    if ($null -eq $v -or $v -is [System.DBNull]) { return $null }
    if ($v -is [string]) {
        $s = [regex]::Replace($v, '[\x00-\x1F\x7F-\x9F\uD800-\uDFFF]', ' ').Trim()
        if ($s -eq '') { return $null }
        return $s
    }
    if ($v -is [datetime]) {
        if ($v.Year -lt 100) { return $null }
        if ($SqlType -eq 'date') { return $v.ToString('yyyy-MM-dd') }
        return $v.ToString('yyyy-MM-ddTHH:mm:ss.fff')
    }
    if ($v -is [TimeSpan]) { return ('{0:D2}:{1:D2}:{2:D2}' -f $v.Hours, $v.Minutes, $v.Seconds) }
    if ($v -is [bool]) { return $v }
    if ($v -is [double] -or $v -is [single]) {
        if ([double]::IsNaN([double]$v) -or [double]::IsInfinity([double]$v)) { return $null }
        return [double]$v
    }
    return $v
}

function ConvertTo-PgName {
    param([string]$n)
    $n = $n.Replace('%', '_pct')
    $n = [regex]::Replace($n, '[^A-Za-z0-9_]', '_')
    return $n.ToLower()
}

$Specs = @(
    @{ Sigma = 'DBAdik'; PgTable = 'sigma_raw_dbadik'; Db = 'dw220sdb'; Snapshot = $false;
       Conflict = 'client_id,store_code,simktnr,laktnr';
       Sql = 'SELECT k.* FROM dbo.DBAdik k WHERE k.dtDatbis >= @from';
       Expected = @('siMktNr', 'lAktNr', 'cAktart', 'dtDatvon', 'dtDatbis', 'dtDatfall', 'cHinw', 'siBearb', 'cBezKdkz1', 'cBezKdkz2', 'cBezKdkz3', 'cBezKdkz4', 'cBezKdkz5', 'cBezKdkz6', 'cBezKdkz7', 'cBezKdkz8', 'cBezKdkz9', 'cBezKdkz10', 'cKdnBez', 'dtErstLief', 'siGrpWechsel', 'cVorArt', 'cHerk', 'sZentAktNr', 'siFolgeNr', 'siZentVersion', 'sBemerkung') },
    @{ Sigma = 'DBAdip'; PgTable = 'sigma_raw_dbadip'; Db = 'dw220sdb'; Snapshot = $false;
       Conflict = 'client_id,store_code,simarkt,laktnr,dartnr,llftnr,sibeh';
       Sql = 'SELECT p.* FROM dbo.DBAdip p JOIN dbo.DBAdik k ON k.siMktNr = p.siMarkt AND k.lAktNr = p.lAktnr WHERE k.dtDatbis >= @from';
       Expected = @('siMarkt', 'lAktnr', 'dArtnr', 'lLftnr', 'cLftartnr', 'siBeh', 'dVkakt', 'dEkakt', 'cDispoArt', 'cZusttxt', 'dGvorbe', 'siKzmae', 'dBemg1', 'dBemg2', 'dBemg3', 'dBemg4', 'dBemg5', 'dBemg6', 'dBemg7', 'dBemg8', 'dBemg9', 'dBemg10', 'dBemg11', 'dBemg12', 'dBemg13', 'dBemg14', 'dBemg15', 'dBemg16', 'dBemg17', 'dBemg18', 'dBemg19', 'dBemg20', 'dtLieftag1', 'dtLieftag2', 'dtLieftag3', 'dtLieftag4', 'dtLieftag5', 'dtLieftag6', 'dtLieftag7', 'dtLieftag8', 'dtLieftag9', 'dtLieftag10', 'dtLieftag11', 'dtLieftag12', 'dtLieftag13', 'dtLieftag14', 'dtLieftag15', 'dtLieftag16', 'dtLieftag17', 'dtLieftag18', 'dtLieftag19', 'dtLieftag20', 'dVknorm', 'dMenge', 'cKennz', 'cKdkz1', 'cKdkz2', 'cKdkz3', 'cKdkz4', 'cKdkz5', 'cKdkz6', 'cKdkz7', 'cKdkz8', 'cKdkz9', 'cKdkz10', 'lFolgNr', 'dRefNr', 'lAbteilung', 'lWgrp', 'cBez', 'sSortFeld', 'sSortBez', 'cHerk', 'cKzVera', 'dPrevBeMg1', 'dPrevBeMg2', 'dPrevBeMg3', 'dPrevBeMg4', 'dPrevBeMg5', 'dPrevBeMg6', 'dPrevBeMg7', 'dPrevBeMg8', 'dPrevBeMg9', 'dPrevBeMg10', 'dPrevBeMg11', 'dPrevBeMg12', 'dPrevBeMg13', 'dPrevBeMg14', 'dPrevBeMg15', 'dPrevBeMg16', 'dPrevBeMg17', 'dPrevBeMg18', 'dPrevBeMg19', 'dPrevBeMg20', 'dPrevMenge', 'dZentRzptNr', 'dMngPalette', 'dZuschuss', 'cofferid') },
    @{ Sigma = 'DBAdit'; PgTable = 'sigma_raw_dbadit'; Db = 'dw220sdb'; Snapshot = $false;
       Conflict = 'client_id,store_code,simarkt,laktnr,dartnr,llftnr,sibeh,sityp,sizeile';
       Sql = 'SELECT t.* FROM dbo.DBAdit t JOIN dbo.DBAdik k ON k.siMktNr = t.siMarkt AND k.lAktNr = t.lAktNr WHERE k.dtDatbis >= @from';
       Expected = @('siMarkt', 'lAktNr', 'dArtNr', 'lLftNr', 'siBeh', 'siZeile', 'lZentPosNr', 'sText', 'siTyp') },
    @{ Sigma = 'DBAufK'; PgTable = 'sigma_raw_dbaufk'; Db = 'dw220sdb'; Snapshot = $false;
       Conflict = 'client_id,store_code,simktnr,dauftrnr';
       Sql = 'SELECT a.* FROM dbo.DBAufK a WHERE (a.dtDatDis >= @from OR a.dtDatEWe >= @from OR a.dtDatWe >= @from)';
       Expected = @('siMktNr', 'dAuftrNr', 'lLiefNr', 'cVorArt', 'cStatu1', 'cStatu2', 'dtDatDis', 'dtDatEWe', 'dtDatWe', 'dtDatRe', 'dWeNr', 'cRechNr', 'dSumVk', 'dSumEk', 'dSumVkP', 'dSumEkP', 'dGutW', 'dRechW', 'cRabKz1', 'dRab1', 'cRabKz2', 'dRab2', 'cZusTxt', 'lAktNr', 'cSondVa', 'cUMarkt', 'siAnzPos', 'dtDatPr', 'dtDatKond', 'cAktKz', 'cSpez', 'dSumMw', 'siWaehrung', 'siKPfand', 'cWEInfo', 'tmZeitWE', 'sNameSped', 'siAnzBEH', 'siAnzKg', 'siAnzPal', 'lAnzArt', 'sExtBelNr', 'sBediener', 'cZentAufNr', 'cBeleNr', 'dWeNrWe', 'siPosLautLiefer', 'cSortBer', 'siHOStorno', 'dBarcodeNr', 'siWEProtGedruckt', 'dMESSAufnr', 'lVertreter', 'siBestGesendet', 'lFibuNummer', 'dtBearbBis', 'siVorbestellung', 'dtBestellbarAb', 'siInvers', 'siRegRetGedruckt', 'sRefNr', 'dtFaelligkeit', 'cgutschriftnr', 'siStatus', 'dVerknRech', 'dReklamKolli', 'sikopfpara', 'siTranspRechnen', 'siZollStRechnen', 'siAbgleichOhneTK', 'dKurs', 'siSpeichNeueEKs') },
    @{ Sigma = 'DBAufP'; PgTable = 'sigma_raw_dbaufp'; Db = 'dw220sdb'; Snapshot = $false;
       Conflict = 'client_id,store_code,simktnr,dauftrnr,lfolg,dartnr,sibeh';
       Sql = 'SELECT p.* FROM dbo.DBAufP p JOIN dbo.DBAufK a ON a.siMktNr = p.siMktNr AND a.dAuftrNr = p.dAuftrNr WHERE (a.dtDatDis >= @from OR a.dtDatEWe >= @from OR a.dtDatWe >= @from)';
       Expected = @('siMktNr', 'dAuftrNr', 'lANrBest', 'dArtNr', 'cStatPos', 'cKzVera', 'dBeMg', 'siBEH', 'cKzPos1', 'dWeMg1', 'cKzPos2', 'dWeMg2', 'cKzPos3', 'dWeMg3', 'cKzPos4', 'dWeMg4', 'dVK', 'dEK', 'dEKN', 'dEKWeR', 'dEKWeAb', 'dEKWeNN', 'dMgWe', 'lFolg', 'cRabKz1', 'dRab1', 'cRabKz2', 'dRab2', 'cSpez', 'dNMgWe', 'cAktKz', 'lAktNr', 'cBez', 'siKzBez', 'cRueckSt', 'cNVENr', 'dAbwPfMg', 'lLiefNr', 'cEingabeMg1', 'cEingabeMg2', 'cEingabeMg3', 'cEingabeMg4', 'cFunkMDE', 'dArtNrHo', 'dwemgze', 'siNachLief', 'siBestVorMod', 'cDiffGrund', 'siNAenderbar', 'siTeilAufNr', 'dEKPf', 'dEKVorher', 'lLiefRechPos', 'dRechEKL', 'dRechEKoK', 'dRechMenge', 'dRechPosSum', 'siStatus', 'drechekwer', 'drechekwenn', 'dreklwert', 'sipospara', 'dRechRab', 'siMwSt', 'ckzstueck', 'dvkalt', 'dekwennextra', 'dtdatmhd', 'dtranspauf', 'dzollstauf', 'siMitTK', 'dEKWeNNFremd', 'dreklwertohneextra', 'lLoadList', 'caktek') },
    @{ Sigma = 'IntellistoX_Promo_Info_Master'; PgTable = 'sigma_raw_intellistox_promo'; Db = 'EASYDB'; Snapshot = $true;
       Conflict = 'client_id,store_code,capture_date,uid';
       Sql = 'SELECT x.* FROM IntelliAcc.IntellistoX_Promo_Info_Master x';
       Expected = @('UID', 'ProductCode', 'PromoSupplier', 'PromoNumber', 'NationalNumber', 'FromDate', 'ToDate', 'Active', 'cEBENE', 'NormalPrice', 'NormalVAT', 'NormalPackCost', 'NormalPackSize', 'NormalGP', 'NormalGP%', 'PromoPrice', 'PromoVAT', 'PromoPackCost', 'PromoPackSize', 'CostDiff%', 'PromoGP', 'PromoGP%', 'dtLieftag1', 'dtLieftag2', 'cBez', 'cKdkz6', 'dAktMengeWo1', 'dAktMengeWo1Datum', 'dAktMengeWo2', 'dAktMengeWo2Datum', 'dAktMengeWo3', 'dAktMengeWo3Datum', 'dAktMengeWo4', 'dAktMengeWo4Datum', 'dAktMengeWo5', 'dAktMengeWo5Datum', 'dAktMengeWo6', 'dAktMengeWo6Datum') }
)

$Prefix = "SET NOCOUNT ON; SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED; DECLARE @from date = DATEADD(quarter, -$Quarters, CAST(GETDATE() AS date)); "

Write-Log ("Raw mirror test " + $ScriptVersion + " on " + $HostKey + " (store " + $StoreCode + "), window " + $Quarters + " quarters" + $(if ($DryRun) { ", DRY RUN (nothing pushed)" } else { "" }))
$summary = @()

foreach ($spec in $Specs) {
    if ($Only.Count -gt 0 -and -not ($Only -contains $spec.Sigma)) { continue }
    $started = Get-Date
    Write-Log ("== " + $spec.Sigma + " -> " + $spec.PgTable)
    if ($spec.Db -eq 'EASYDB') {
        $h = (Get-Date).Hour; $m = (Get-Date).Minute
        if (($h -eq 19 -and $m -lt 45) -or ($h -eq 18 -and $m -ge 55)) {
            Write-Log "  SKIPPED: EASYDB rebuilds around 19:20. Run again after 19:45."
            $summary += ($spec.Sigma + ': SKIPPED (EASYDB rebuild window)')
            continue
        }
    }
    $conn = New-Object System.Data.SqlClient.SqlConnection("Server=localhost\SIGMA;Database=$($spec.Db);Integrated Security=True;Connection Timeout=30;")
    $read = 0; $pushed = 0; $status = 'SUCCESS'; $err = $null
    try {
        $conn.Open()
        $cmd = New-Object System.Data.SqlClient.SqlCommand(($Prefix + $spec.Sql), $conn)
        $cmd.CommandTimeout = 1200
        $rdr = $cmd.ExecuteReader()
        try {
            $n = $rdr.FieldCount
            $names = @(); $pgNames = @(); $types = @()
            for ($i = 0; $i -lt $n; $i++) {
                $names   += $rdr.GetName($i)
                $pgNames += (ConvertTo-PgName $rdr.GetName($i))
                $types   += $rdr.GetDataTypeName($i).ToLower()
            }
            $missing = @($spec.Expected | Where-Object { -not ($names -contains $_) })
            $extra   = @($names | Where-Object { -not ($spec.Expected -contains $_) })
            if ($missing.Count -gt 0 -or $extra.Count -gt 0) {
                $status = 'SCHEMA_DIFF'
                $err = "columns differ from the June crawl. missing: " + ($missing -join ',') + " | extra: " + ($extra -join ',')
                Write-Log ("  " + $err)
                Write-Log "  NOT PUSHED. Send CC this log: the mirror table needs these columns first."
            }
            else {
                Write-Log ("  COLUMNS OK (" + $n + " of " + $spec.Expected.Count + ")")
                $nowIso = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                $batch = [System.Collections.Generic.List[object]]::new()
                while ($rdr.Read()) {
                    $read++
                    if ($DryRun) { continue }
                    $row = [ordered]@{ client_id = $ClientId; store_code = $StoreCode }
                    if ($spec.Snapshot) { $row['capture_date'] = $CaptureDate }
                    for ($i = 0; $i -lt $n; $i++) { $row[$pgNames[$i]] = Convert-Value $rdr.GetValue($i) $types[$i] }
                    $row['extracted_at'] = $nowIso
                    $null = $batch.Add($row)
                    if ($batch.Count -ge $BatchSize) {
                        $pushed += Send-Batch -Table $spec.PgTable -ConflictCols $spec.Conflict -Rows $batch.ToArray()
                        $batch.Clear()
                        if (($read % 10000) -eq 0) { Write-Log ("  " + $pushed + " pushed of " + $read + " read...") }
                    }
                }
                if (-not $DryRun -and $batch.Count -gt 0) {
                    $pushed += Send-Batch -Table $spec.PgTable -ConflictCols $spec.Conflict -Rows $batch.ToArray()
                }
                if ($DryRun) { Write-Log ("  DRY RUN: " + $read + " rows read, nothing pushed") }
                else {
                    if ($pushed -ne $read) { $status = 'PARTIAL' }
                    Write-Log ("  " + $status + ": " + $pushed + " pushed of " + $read + " read")
                }
            }
        }
        finally { $rdr.Close() }
    }
    catch {
        $status = 'FAILED'; $err = $_.ToString()
        Write-Log ("  FAILED: " + $err)
    }
    finally { $conn.Close() }
    $secs = [int]((Get-Date) - $started).TotalSeconds
    $summary += ($spec.Sigma + ': ' + $status + ', read ' + $read + ', pushed ' + $pushed + ', ' + $secs + 's')
    if (-not $DryRun) { Send-PushLog -Table $spec.PgTable -Started $started -Pushed $pushed -Failed ($read - $pushed) -Expected $read -Status $status -Err $err }
}

Write-Log "== SUMMARY"
foreach ($s in $summary) { Write-Log ("  " + $s) }
Write-Log ("Log file: " + $LogFile)

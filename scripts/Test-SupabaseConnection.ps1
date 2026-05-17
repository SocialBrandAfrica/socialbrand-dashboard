#Requires -Version 5.1
# Test-SupabaseConnection.ps1 — run on store server before the first push to confirm HTTPS is open.

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

$SupabaseUrl = 'https://crklvhfwyxlisfcvqenc.supabase.co'

try {
    $response = Invoke-WebRequest -Uri "$SupabaseUrl/rest/v1/" -Method GET -UseBasicParsing -TimeoutSec 15
    Write-Host "SUCCESS — HTTP $($response.StatusCode) from $SupabaseUrl" -ForegroundColor Green
}
catch {
    Write-Host "FAILED — $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Check: outbound port 443 must be open. Sigma GRD uses this port — if GRD works, this should too." -ForegroundColor Yellow
    exit 1
}

#Requires -Version 5.1
# Test-SupabaseConnection.ps1 - run on store server before the first push to confirm HTTPS is open.

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

$SupabaseUrl = 'https://crklvhfwyxlisfcvqenc.supabase.co'

try {
    $response = Invoke-WebRequest -Uri "$SupabaseUrl/rest/v1/" -Method GET -UseBasicParsing -TimeoutSec 15
    Write-Host "SUCCESS - HTTP $($response.StatusCode) from $SupabaseUrl" -ForegroundColor Green
}
catch {
    # 401 Unauthorized = Supabase received the request but requires an API key.
    # This means port 443 is open and the network path is clear - treat as SUCCESS.
    if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 401) {
        Write-Host "SUCCESS - Port 443 is open. Supabase responded with 401 (no API key sent, expected)." -ForegroundColor Green
    }
    else {
        Write-Host "FAILED - $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Check: outbound port 443 must be open. Sigma GRD uses this port - if GRD works, this should too." -ForegroundColor Yellow
        exit 1
    }
}

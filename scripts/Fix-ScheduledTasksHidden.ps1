#Requires -Version 5.1
<#
.SYNOPSIS
    Fixes SocialBrand scheduled tasks so PowerShell runs hidden (no desktop window).
.DESCRIPTION
    Updates both "SocialBrand Nightly Push" and "SocialBrand Nightly Push Retry"
    to use -WindowStyle Hidden. Run once on each store server.
    Safe to run multiple times.
#>

$taskNames = @("SocialBrand Nightly Push", "SocialBrand Nightly Push Retry")
$arg = '-WindowStyle Hidden -ExecutionPolicy Bypass -NonInteractive -File "C:\SocialBrand\Push-SigmaToSupabase.ps1"'

foreach ($name in $taskNames) {
    $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        Write-Host "SKIP: Task not found: $name"
        continue
    }
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arg
    Set-ScheduledTask -TaskName $name -Action $action | Out-Null
    Write-Host "OK: $name updated to -WindowStyle Hidden"
}

Write-Host ""
Write-Host "Verify:"
foreach ($name in $taskNames) {
    $t = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if ($t) {
        Write-Host "  $name -> $($t.Actions[0].Arguments)"
    }
}

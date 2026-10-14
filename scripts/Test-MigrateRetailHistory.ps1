#Requires -Version 5.1
<#
.SYNOPSIS
    ENG-023 / ENG-026 regression test for ops-migrate-retail-history.ps1. DEV BOX ONLY, read-only.
    Never run on a store server. It does NOT dot-source the migration script: it pulls the three
    helper functions out by AST and evaluates only those definitions, so no migration code can run.
#>
$ErrorActionPreference = 'Stop'
$here      = Split-Path -Parent $PSCommandPath
$migration = Join-Path $here 'ops-migrate-retail-history.ps1'
$extractor = Join-Path $here 'Invoke-ExtractFromSigmaSQL.ps1'
$fail = 0; $pass = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++; Write-Host "  PASS  $name" -ForegroundColor Green }
    else     { $script:fail++; Write-Host "  FAIL  $name  $detail" -ForegroundColor Red }
}

# Load the three helpers by AST (never dot-source the migration script).
$text = Get-Content -LiteralPath $migration -Raw
$tk = $null; $er = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tk, [ref]$er)
Check 'migration script parses' ($er.Count -eq 0)
$want = 'Get-CodeText','Test-ScriptNamedParameters','ConvertTo-RenamedTaskXml'
$defs = @($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $want -contains $n.Name}, $true))
Check 'all three helper functions found' ($defs.Count -eq 3) "found $($defs.Count)"
foreach ($d in $defs) { Invoke-Expression $d.Extent.Text }

# (a) fixture: a wrong parameter name is caught, independent of git history
$fx = @(Test-ScriptNamedParameters -ScriptText 'Set-ScheduledTask -TaskName x -Description y')
Check '(a) fixture Set-ScheduledTask -Description gives exactly 1 BAD_PARAM' ($fx.Count -eq 1 -and $fx[0].Kind -eq 'BAD_PARAM') "got $($fx.Count)"
# (b) the migration script itself binds
$self = @(Test-ScriptNamedParameters -ScriptText $text)
Check '(b) migration script: 0 findings' ($self.Count -eq 0) (($self | Out-String))
# (f) location independence
Push-Location HKLM:\
try { $hk = @(Test-ScriptNamedParameters -ScriptText $text) } finally { Pop-Location }
Check '(f) 0 findings when run from HKLM:\' ($hk.Count -eq 0) "got $($hk.Count)"
# (g) the pre-fix revision still produces the ENG-023 finding
$pre = (& git -C $here show 'a335a8f^:scripts/ops-migrate-retail-history.ps1') -join "`n"
$prf = @(Test-ScriptNamedParameters -ScriptText $pre)
Check '(g) pre-fix revision a335a8f^: 1 finding' ($prf.Count -eq 1) "got $($prf.Count)"

# (c) the extractor: code has no old-folder literal and does carry the new task name
$ect  = Get-Content -LiteralPath $extractor -Raw
$code = Get-CodeText -Text $ect
Check '(c) extractor whole-file text DOES match the old path (the ENG-026 false positive)' ($ect -match [regex]::Escape('C:\SocialBrand'))
Check '(c) extractor code-only text does NOT match the old path' ($code -notmatch [regex]::Escape('C:\SocialBrand'))
Check "(c) extractor code-only text still matches the task-name gate" ($code -match [regex]::Escape("`$taskName = 'Retail History'"))
# (d) synthetic controls
$s1 = "# `$taskName = 'Retail History'`n`$taskName = 'SocialBrand-ExtractDelta'`n"
Check '(d1) name only in a comment fails the code-only gate' ((Get-CodeText -Text $s1) -notmatch [regex]::Escape("`$taskName = 'Retail History'"))
Check '(d1) ...and the old whole-text gate would have passed it' ($s1 -match [regex]::Escape("`$taskName = 'Retail History'"))
$s2 = "`$d = 'C:\socialbrand\x'`n"
Check '(d2) a real literal in code is flagged' ((Get-CodeText -Text $s2) -match [regex]::Escape('C:\SocialBrand'))
$s3 = "<#`nold C:\SocialBrand`n#>`n`$BaseDir = `$PSScriptRoot  # was C:\SocialBrand`n"
Check '(d3) literal only in block and trailing comments is not flagged' ((Get-CodeText -Text $s3) -notmatch [regex]::Escape('C:\SocialBrand'))
# (e) XML rewrite over every locally registered task
$n = 0; $bad = 0
foreach ($tsk in @(Get-ScheduledTask)) {
    try {
        $x = Export-ScheduledTask -TaskName $tsk.TaskName -TaskPath $tsk.TaskPath | Out-String
        $o = ConvertTo-RenamedTaskXml -Xml $x -Description 'Scheduled data maintenance task.'
        if (([xml]$o).GetElementsByTagName('Description').Count -ne 1) { $bad++ }
        $n++
    } catch { $bad++; $n++ }
}
Check "(e) description rewrite on $n local task definitions: 0 failures" ($bad -eq 0 -and $n -gt 0) "bad=$bad of $n"
$esc = ConvertTo-RenamedTaskXml -Xml '<Task><RegistrationInfo><Description>x</Description></RegistrationInfo></Task>' -Description 'a $1 $$ & < " b'
Check '(e) special characters round-trip' (([xml]$esc).Task.RegistrationInfo.Description -eq 'a $1 $$ & < " b')

Write-Host ""
Write-Host "$pass passed, $fail failed" -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
if ($fail) { exit 1 }
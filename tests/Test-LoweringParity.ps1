<#
.SYNOPSIS
    Differential test: each fixture method run interpreted by PowerShell and lowered by PSC must agree.
.DESCRIPTION
    ConstructProbe covers enums, switch, ternary, if as a value, chained assignment, narrow integers, member-chain
    compound assignment and loops. KeywordProbe covers keywords declared by [Keyword()] methods. CustomObjectProbe
    covers [pscustomobject] literals through SMA's PSObject, including the object escaping to PowerShell.
    Each fixture runs in a child pwsh so the interpreted classes and the lowered types never share a session.
    Known divergences are listed by name; a known divergence that disappears is reported, so the list stays true.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$compilerPath = Join-Path $repoRoot 'Export-LoweredAssembly.ps1'
$outDir = Join-Path $repoRoot 'build/lowering-parity'
$null = New-Item -ItemType Directory -Force -Path $outDir
. (Join-Path $PSScriptRoot 'ChildPwsh.ps1')

# Interpreted: $o.PSObject is a separate wrapper object. Lowered: the object itself. Open, recorded in ROADMAP.md.
$knownDivergences = @{ 'CustomObjectProbe.PSObjectIsSelf' = 'lowered .PSObject is the object itself, not PowerShell''s wrapper' }

$failures = [Collections.Generic.List[string]]::new()
$compared = 0
foreach ($fixture in 'ConstructProbe', 'KeywordProbe', 'CustomObjectProbe') {
    $source = Join-Path $PSScriptRoot "fixtures/$fixture.ps1"
    $assembly = Join-Path $outDir "$fixture.dll"
    $null = & $compilerPath -Mode Compile -SourcePath $source -ClassName $fixture -OutputPath $assembly
    $child = Get-ChildPwshCommand
    $report = & $child[0] -NoProfile -NonInteractive -Command {
        param($source, $assembly, $fixture)
        $ErrorActionPreference = 'Stop'
        $lowered = [Reflection.Assembly]::LoadFile($assembly).GetType($fixture, $true)
        . $source
        $interpreted = $fixture -as [type]
        foreach ($method in $interpreted.GetMethods([Reflection.BindingFlags]'Public,Static,DeclaredOnly') | Where-Object { -not $_.IsSpecialName -and $_.GetParameters().Count -eq 0 -and $_.ReturnType -ne [object] }) {
            $expected = $method.Invoke($null, @())
            try { $actual = $lowered.GetMethod($method.Name).Invoke($null, @()); $error2 = $null } catch { $actual = $null; $error2 = $_.Exception.InnerException.Message }
            [pscustomobject]@{ Name = $method.Name; Expected = "$expected"; Actual = "$actual"; Error = $error2 }
        }
        # An object returned to PowerShell must behave as PowerShell's own, after Add-Member too.
        $escape = $interpreted.GetMethod('Escapes')
        if ($escape) {
            $inspect = {
                param($o)
                $o | Add-Member Extra 9
                ($o.PSObject.Properties.Name -join ',') + '|' + ($o -is [pscustomobject]) + '|' + $o.PSObject.BaseObject.GetType().FullName + '|' + ($o | ConvertTo-Json -Compress) + '|' + "$o" + '|' + ($o.PSObject.TypeNames -join ',')
            }
            [pscustomobject]@{ Name = 'Escapes'; Expected = (& $inspect ($escape.Invoke($null, @()))); Actual = (& $inspect ($lowered.GetMethod('Escapes').Invoke($null, @()))); Error = $null }
        }
    } -args $source, $assembly, $fixture
    foreach ($row in $report) {
        $compared++
        $key = "$fixture.$($row.Name)"
        $same = $null -eq $row.Error -and $row.Expected -ceq $row.Actual
        if ($knownDivergences.ContainsKey($key)) {
            if ($same) { $failures.Add("${key}: listed as a known divergence but now agrees; update the list") }
            else { Write-Host "  KNOWN $key ($($knownDivergences[$key])): interpreted '$($row.Expected)', lowered '$($row.Actual)'" }
            continue
        }
        if ($row.Error) { $failures.Add("${key}: lowered threw '$($row.Error)'") }
        elseif (-not $same) { $failures.Add("${key}: interpreted '$($row.Expected)', lowered '$($row.Actual)'") }
    }
}

$failures | ForEach-Object { Write-Host "  FAIL $_" }
[pscustomobject]@{ Suite = 'LoweringParity'; Compared = $compared; Known = $knownDivergences.Count; Failures = $failures.Count; Status = if ($failures.Count) { 'FAIL' } else { 'PASS' } }
if ($failures.Count) { exit 1 }

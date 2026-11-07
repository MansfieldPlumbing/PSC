<#
.SYNOPSIS
    A Pwsh script designed to amortize.
.DESCRIPTION
    Self-contained compiler. Compile emits an assembly (or, with -Native, an executable);
    Expression returns live AST and expression objects in the calling process;
    Inspect reads assembly metadata; Capability reports the admitted contract;
    Link reads COFF objects and libraries and resolves their symbols into a
    native image. No module import or external implementation source is required.
    Called with no arguments, it returns its own API (Mode Api), read from this file's AST.
.PARAMETER Mode
    Compile (the default when compile inputs are given), Api (the default with no arguments), Expression,
    Inspect, Capability, Link or PowerShell (the pinned PowerShell build, downloaded and verified on first use);
    or, from SMA's own parser over PowerShell projects: Describe (one project as live objects: units, edges,
    coverage, absence, changes), Lint, Profile (every project's functions and methods), Report (on a historical
    profile) or Verify (the description's structural fixture).
.PARAMETER ArchivePath
    PowerShell: an already-downloaded release archive, verified the same way as a download.
.PARAMETER Native
    Compile: produce a native executable at OutputPath. The lowered assembly is compiled to machine code by the
    pinned ILC and linked by PSC's own COFF linker with the pinned Native AOT runtime; requires EntryPoint.
.PARAMETER ProjectPath
    Describe: the project folder to describe. Call with & to keep the returned live objects.
.PARAMETER LintFiles
    Lint: files to check; without it, every PowerShell file of every project beside this script's folder.
.PARAMETER ProfilePath
    Report: a historical profile (CLIXML) to report on.
.PARAMETER LinkInput
    Link: COFF object (.obj) and library (.lib) paths, in command-line order.
.PARAMETER LibraryDirectory
    Link: directories searched, in order, for libraries named by default-library directives.
.PARAMETER DefaultLibrary
    Link: libraries added as if named by a default-library directive.
.PARAMETER NoDefaultLibrary
    Link: default libraries to ignore; '*' ignores every default-library directive.
.PARAMETER ResolveOnly
    Link: resolve symbols and report members, imports and unresolved symbols without writing an image.
.PARAMETER EntrySymbol
    Link: the image's entry point symbol; it is a reference like any other.
.PARAMETER LinkMerge
    Link: output-section merges, each From=To, applied after the linker's own and before the objects' directives.
.PARAMETER Subsystem
    Link: Console (default) or Windows.
.PARAMETER StackReserve
    Link: stack reserve size in bytes.
.PARAMETER SourcePath
    Source file containing typed PowerShell classes.
.PARAMETER SourceAst
    Retained ScriptBlockAst to compile directly, as an alternative to SourcePath.
.PARAMETER ClassNames
    Optional explicit set of classes to emit from the source, including ClassName.
.PARAMETER StaticData
    Typed primitive, string or array values keyed by Class.Field. Emits static initialization IL;
    does not generate PowerShell source or preserve mutable runtime fields.
.PARAMETER ClassName
    Class whose exported methods are reported; defaults to the first class.
.PARAMETER MethodNames
    Optional method selection for ClassName.
.PARAMETER OutputPath
    Destination assembly path; filename determines the assembly name.
.PARAMETER EntryPoint
    Optional static entry point returning int or void, with no parameters or
    one string[] parameter. Writes a runtime configuration beside output.
.PARAMETER Deterministic
    Produces deterministic bytes and MVID. Enabled by default.
.PARAMETER MethodAst
    FunctionMemberAst to lower in Expression mode. Accepts pipeline input.
.PARAMETER AssemblyPath
    Assembly to inspect in Inspect mode.
.PARAMETER Help
    Displays full script help without compiling.
.EXAMPLE
    & ./Invoke-PSC.ps1
.EXAMPLE
    & ./Invoke-PSC.ps1 -SourcePath ./tests/fixtures/Slice1Fixture.ps1 -ClassName Slice1Fixture -OutputPath ./build/Example.dll -Deterministic
.EXAMPLE
    & ./Invoke-PSC.ps1 -Mode Expression -MethodAst $method
.EXAMPLE
    & ./Invoke-PSC.ps1 -Mode Inspect -AssemblyPath ./build/Example.dll
.EXAMPLE
    & ./Invoke-PSC.ps1 -Mode Capability
.EXAMPLE
    $pwsh = & ./Invoke-PSC.ps1 -Mode PowerShell
#>
[CmdletBinding()]
param(
    [ValidateSet('Compile', 'Api', 'Expression', 'Inspect', 'Capability', 'Link', 'PowerShell', 'Describe', 'Lint', 'Profile', 'Report', 'Verify', 'Readme', 'Investigate')]
    [string] $Mode = 'Compile',
    [string] $ArchivePath,
    [string] $ProjectPath,
    [string[]] $LintFiles,
    [string[]] $InvestigatePath,
    [string] $ProfilePath,
    [string] $SourcePath,
    [System.Management.Automation.Language.ScriptBlockAst] $SourceAst,
    [Collections.IDictionary] $StaticData,
    [string] $ClassName,
    [string[]] $ClassNames,
    [string[]] $MethodNames,
    [string] $OutputPath,
    [string] $EntryPoint,
    # Compile: produce a native executable at OutputPath (lowered, then ILC, then PSC's linker). Needs EntryPoint.
    [switch] $Native,
    [switch] $Deterministic = $true,
    [Parameter(ValueFromPipeline)]
    [System.Management.Automation.Language.FunctionMemberAst] $MethodAst,
    [string] $AssemblyPath,
    [string[]] $LinkInput,
    [string[]] $LibraryDirectory,
    [string[]] $DefaultLibrary,
    [string[]] $NoDefaultLibrary,
    [switch] $ResolveOnly,
    [string] $EntrySymbol,
    [string[]] $LinkMerge,
    [ValidateSet('Console', 'Windows')]
    [string] $Subsystem = 'Console',
    [long] $StackReserve = 0x100000,
    [switch] $Help
)

begin {
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================================
# SMA DESCRIPTION, LINT AND PROFILE
# Projects described as live objects from SMA's own parser.
# ============================================================================

# The projects beside this script's folder.
$ProjectsRoot = Split-Path -Parent $PSScriptRoot
$ThirdPartyRemotes = 'microsoft/directml', 'microsoft/edit', 'ggml-org/llama.cpp'
$WriteCommands = 'Set-Content','Add-Content','Out-File','New-Item','Remove-Item','Copy-Item','Move-Item','Rename-Item','Export-Clixml','Export-Csv','Clear-Content','Set-Item'
$NetworkCommands = 'Invoke-WebRequest','Invoke-RestMethod','Start-BitsTransfer','New-PSSession','Enter-PSSession'
$ProcessCommands = 'Start-Process','Stop-Process','Invoke-Command','Start-Job'
$DynamicCommands = 'Add-Type','Invoke-Expression','iex'

function Get-ProjectRemote([string] $path) {
    $url = git -C $path remote get-url origin 2>$null
    if (-not $url) { return $null }
    $uri = $null
    if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri)) { return $url.ToLowerInvariant() }
    $name = $uri.AbsolutePath.Trim('/')
    if ($name.EndsWith('.git', [StringComparison]::OrdinalIgnoreCase)) { $name = $name.Substring(0, $name.Length - 4) }
    $name.ToLowerInvariant()
}

function Get-Projects {
    foreach ($d in Get-ChildItem -LiteralPath $ProjectsRoot -Directory -Force) {
        if ($d.Name.StartsWith('.')) { continue }
        if (Test-Path -LiteralPath (Join-Path $d.FullName '.git')) {
            $remote = Get-ProjectRemote $d.FullName
            if ($remote -and $ThirdPartyRemotes -contains $remote) { continue }
            if (-not $remote) { $remote = '(local) ' + $d.Name.ToLowerInvariant() }
            $files = @(git -C $d.FullName ls-files --cached --others --exclude-standard -- '*.ps1' '*.psm1' 2>$null | Sort-Object -Unique)
        } else {
            # Project folders outside git: enumerate the file system, leaving out copied upstream references.
            $remote = '(local) ' + $d.Name.ToLowerInvariant()
            $files = @(Get-ChildItem -LiteralPath $d.FullName -Recurse -File -Include *.ps1, *.psm1 -ErrorAction SilentlyContinue |
                Where-Object { -not $_.FullName.Contains('\reference\') -and -not $_.FullName.Contains('\.git\') -and -not $_.FullName.Contains('\node_modules\') } |
                ForEach-Object { $_.FullName.Substring($d.FullName.Length + 1) })
        }
        if ($files.Count) { [pscustomobject]@{ Project = $d.Name; Path = $d.FullName; Remote = $remote; Files = $files } }
    }
}

function Test-DriveRooted([string] $value) {
    if ($value.Length -lt 4 -or $value.Length -gt 259) { return $false }
    try { if (-not [IO.Path]::IsPathFullyQualified($value)) { return $false }; $root = [IO.Path]::GetPathRoot($value) } catch { return $false }
    $root.Length -eq 3 -and [char]::IsLetter($root[0]) -and $root[1] -eq ':'
}

function Get-UnitProfile($project, [string] $file, $node) {
    if ($node -is [System.Management.Automation.Language.FunctionMemberAst]) {
        $name = $node.Parent.Name + '.' + $node.Name; $kind = 'method'; $parameters = @($node.Parameters.Name.VariablePath.UserPath); $help = $null
    } else {
        $name = $node.Name.Replace('global:', '').Replace('script:', ''); $kind = 'function'
        $parameters = @($node.Parameters.Name.VariablePath.UserPath + $node.Body.ParamBlock.Parameters.Name.VariablePath.UserPath | Where-Object { $_ }); $help = $node.GetHelpContent()
    }
    $calls = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $effects = [Collections.Generic.HashSet[string]]::new()
    foreach ($command in $node.Body.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $commandName = $command.GetCommandName()
        if ($commandName) { $null = $calls.Add($commandName.Replace('global:', '').Replace('script:', '')) }
        elseif ($command.InvocationOperator -ne 'Unknown') { $null = $effects.Add('process') }
    }
    $types = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($t in $node.Body.FindAll({ $args[0] -is [System.Management.Automation.Language.TypeExpressionAst] -or $args[0] -is [System.Management.Automation.Language.TypeConstraintAst] }, $true)) { $null = $types.Add($t.TypeName.FullName) }
    foreach ($c in $calls) {
        if ($WriteCommands -contains $c) { $null = $effects.Add('file-write') }
        if ($NetworkCommands -contains $c) { $null = $effects.Add('network') }
        if ($ProcessCommands -contains $c) { $null = $effects.Add('process') }
        if ($DynamicCommands -contains $c) { $null = $effects.Add('dynamic-code') }
    }
    foreach ($m in $node.Body.FindAll({ $args[0] -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $args[0].Static }, $true)) {
        $typeName = $m.Expression.TypeName.FullName; $member = $m.Member.Extent.Text
        $fileType = $typeName -in 'IO.File','System.IO.File','IO.Directory','System.IO.Directory'
        if ($fileType -and ($member.StartsWith('Write') -or $member.StartsWith('Append') -or $member -in 'Delete','Move','Copy','CreateDirectory','Create','Replace')) { $null = $effects.Add('file-write') }
        if ($typeName -in 'scriptblock','System.Management.Automation.ScriptBlock' -and $member -eq 'Create') { $null = $effects.Add('dynamic-code') }
        if ($typeName -in 'Diagnostics.Process','System.Diagnostics.Process') { $null = $effects.Add('process') }
    }
    foreach ($t in $types) { if ($t.StartsWith('Net.Http') -or $t.StartsWith('System.Net.Http') -or $t.StartsWith('Net.Sockets') -or $t.StartsWith('System.Net.Sockets') -or $t -in 'Net.WebClient','System.Net.WebClient') { $null = $effects.Add('network') } }
    $rooted = @($node.Body.FindAll({ $args[0] -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | Where-Object { Test-DriveRooted $_.Value } | ForEach-Object Value | Sort-Object -Unique)
    # Calls the command graph cannot see: instance member invocations ($kernels.Tokenize(...)) and names handed to
    # reflection (GetMethod('Tokenize')). Both are resolved later against units of the same project, as nominations.
    $memberCalls = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $reflected = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($m in $node.Body.FindAll({ $args[0] -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
        if ($m.Member -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { continue }
        $memberName = $m.Member.Value
        if (-not $m.Static) { $null = $memberCalls.Add($memberName) }
        if ($memberName -in 'GetMethod', 'GetProperty', 'GetField', 'GetMember' -and $m.Arguments.Count -and $m.Arguments[0] -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $null = $reflected.Add($m.Arguments[0].Value) }
    }
    # Statement structure: each statement of at least 12 nodes as a preorder of node kinds and operators, with every
    # name and literal value removed. Equal hashes in different units are shared structure, whatever the spelling.
    $subtrees = [Collections.Generic.HashSet[string]]::new()
    foreach ($statement in $node.Body.FindAll({ $args[0] -is [System.Management.Automation.Language.StatementAst] -and $args[0] -isnot [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0] -isnot [System.Management.Automation.Language.TypeDefinitionAst] }, $true)) {
        $kinds = [Collections.Generic.List[string]]::new()
        foreach ($n in $statement.FindAll({ $true }, $true)) {
            $nodeKind = $n.GetType().Name
            if ($n -is [System.Management.Automation.Language.BinaryExpressionAst]) { $nodeKind += ':' + $n.Operator }
            elseif ($n -is [System.Management.Automation.Language.UnaryExpressionAst]) { $nodeKind += ':' + $n.TokenKind }
            elseif ($n -is [System.Management.Automation.Language.AssignmentStatementAst]) { $nodeKind += ':' + $n.Operator }
            $kinds.Add($nodeKind)
        }
        if ($kinds.Count -ge 12) { $null = $subtrees.Add([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($kinds -join ' '))).Substring(0, 16)) }
    }
    $tokens = $errors = $null; $null = [System.Management.Automation.Language.Parser]::ParseInput($node.Extent.Text, [ref]$tokens, [ref]$errors)
    $shape = ($tokens | Where-Object { $_.Kind -notin 'NewLine','Comment','EndOfInput' } | ForEach-Object { if ($_.Kind -eq 'Variable') { 'v' } else { $_.Kind.ToString() + ':' + $_.Text } }) -join ' '
    [pscustomobject]@{
        Project = $project.Project; Remote = $project.Remote; File = $file; Name = $name; Kind = $kind; Line = $node.Extent.StartLineNumber
        Lines = $node.Extent.EndLineNumber - $node.Extent.StartLineNumber + 1; Parameters = $parameters; Calls = @($calls); Types = @($types)
        Effects = @($effects); RootedPaths = $rooted; Synopsis = $(if ($help) { $help.Synopsis } else { $null })
        Shape = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($shape))).Substring(0, 16)
        MemberCalls = @($memberCalls); ReflectedNames = @($reflected); Subtrees = @($subtrees)
    }
}

function Invoke-SmaProfile {
    param()
    $builtin = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($c in Get-Command -CommandType Cmdlet, Function, Alias -ErrorAction SilentlyContinue) { $null = $builtin.Add($c.Name) }
    $projects = @(Get-Projects)
    $units = [Collections.Generic.List[object]]::new()
    foreach ($project in $projects) {
        foreach ($rel in $project.Files) {
            $path = Join-Path $project.Path $rel; if (-not (Test-Path -LiteralPath $path)) { continue }
            $tokens = $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
            foreach ($node in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionMemberAst] -or ($args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Parent -isnot [System.Management.Automation.Language.FunctionMemberAst]) }, $true)) {
                $units.Add((Get-UnitProfile $project $rel $node))
            }
        }
    }
    $byProject = @{}; foreach ($u in $units) { $k = $u.Project + '|' + $u.Name; if (-not $byProject.ContainsKey($k)) { $byProject[$k] = $u } }
    $byName = $units | Group-Object Name -AsHashTable -AsString
    # Class methods by project and short name, the targets of member invocations and reflected names.
    $methods = @{}
    foreach ($u in $units | Where-Object Kind -eq 'method') { $k = $u.Project + '|' + $u.Name.Split('.')[-1]; if (-not $methods.ContainsKey($k)) { $methods[$k] = [Collections.Generic.List[object]]::new() }; $methods[$k].Add($u) }
    $incoming = @{}
    $addIncoming = { param($target, [string] $via, $source) $key = $target.Project + '|' + $target.Name + '|' + $target.Line; if (-not $incoming.ContainsKey($key)) { $incoming[$key] = [Collections.Generic.List[string]]::new() }; $incoming[$key].Add($via + ':' + $source.Name) }
    foreach ($u in $units) {
        $internal = [Collections.Generic.List[object]]::new(); $elsewhere = [Collections.Generic.List[string]]::new(); $unresolved = [Collections.Generic.List[string]]::new()
        foreach ($c in $u.Calls) {
            if ($byProject.ContainsKey($u.Project + '|' + $c)) { $internal.Add($byProject[$u.Project + '|' + $c]); & $addIncoming $byProject[$u.Project + '|' + $c] 'command' $u }
            elseif ($byName.ContainsKey($c)) { $elsewhere.Add($c + ' <- ' + ((@($byName[$c].Project | Sort-Object -Unique)) -join ',')) }
            elseif (-not $builtin.Contains($c)) { $unresolved.Add($c) }
        }
        # Member and reflection edges are nominations by name within the project; they are kept apart from command calls.
        $nominated = [Collections.Generic.List[string]]::new()
        foreach ($pair in @(@($u.MemberCalls, 'member'), @($u.ReflectedNames, 'reflection'))) {
            foreach ($n in $pair[0]) {
                $k = $u.Project + '|' + $n
                if ($methods.ContainsKey($k)) { foreach ($t in $methods[$k]) { if ($t -ne $u) { $nominated.Add($pair[1] + ':' + $t.Name); & $addIncoming $t $pair[1] $u } } }
                elseif ($pair[1] -eq 'reflection' -and $byProject.ContainsKey($k)) { $nominated.Add('reflection:' + $n); & $addIncoming $byProject[$k] 'reflection' $u }
            }
        }
        $u | Add-Member Internal $internal; $u | Add-Member NameMatchedElsewhere @($elsewhere); $u | Add-Member Unresolved @($unresolved); $u | Add-Member Nominated @($nominated)
    }
    foreach ($u in $units) { $key = $u.Project + '|' + $u.Name + '|' + $u.Line; $u | Add-Member Incoming @($(if ($incoming.ContainsKey($key)) { $incoming[$key] } else { @() })) }
    $memo = @{}
    $testPure = {
        param($u, $seen)
        $key = $u.Project + '|' + $u.Name + '|' + $u.Line
        if ($memo.ContainsKey($key)) { return $memo[$key] }
        if ($seen.Contains($key)) { return $true }
        $null = $seen.Add($key)
        $ok = $u.Effects.Count -eq 0 -and $u.RootedPaths.Count -eq 0 -and $u.NameMatchedElsewhere.Count -eq 0 -and $u.Unresolved.Count -eq 0
        if ($ok) { foreach ($d in $u.Internal) { if (-not (& $testPure $d $seen)) { $ok = $false; break } } }
        $memo[$key] = $ok; $ok
    }
    foreach ($u in $units) { $u | Add-Member PureClosure (& $testPure $u ([Collections.Generic.HashSet[string]]::new())) }
    @($units | Select-Object Project, Remote, File, Name, Kind, Line, Lines, Parameters, Calls, Types, Effects, RootedPaths, Synopsis, Shape, @{ n = 'Internal'; e = { @($_.Internal.Name) } }, NameMatchedElsewhere, Unresolved, PureClosure, MemberCalls, ReflectedNames, Subtrees, Nominated, Incoming)
}

function Get-SmaUnits($profiled) {
    # One unit per function, and one per class with its methods rolled up.
    foreach ($f in $profiled | Where-Object Kind -eq 'function') { $f | Select-Object *, @{ n = 'Pure'; e = { $_.PureClosure } } }
    foreach ($g in $profiled | Where-Object Kind -eq 'method' | Group-Object Project, File, { $_.Name.Split('.')[0] }) {
        $m = $g.Group
        [pscustomobject]@{ Project = $m[0].Project; Remote = $m[0].Remote; File = $m[0].File; Name = $m[0].Name.Split('.')[0]; Kind = 'class'
            Line = ($m.Line | Measure-Object -Minimum).Minimum; Lines = ($m.Lines | Measure-Object -Sum).Sum
            Calls = @($m.Calls | Sort-Object -Unique); Types = @($m.Types | Sort-Object -Unique); Effects = @($m.Effects | Sort-Object -Unique)
            RootedPaths = @($m.RootedPaths | Sort-Object -Unique); NameMatchedElsewhere = @($m.NameMatchedElsewhere | Sort-Object -Unique)
            Unresolved = @($m.Unresolved | Sort-Object -Unique); Shape = (($m | Sort-Object Name).Shape -join ''); Pure = -not ($m | Where-Object { -not $_.PureClosure })
            Subtrees = @($m.Subtrees | Sort-Object -Unique); Nominated = @($m.Nominated | Sort-Object -Unique)
            Incoming = @($m.Incoming | Where-Object { $_ -and $_.Split(':', 2)[1] -notlike ($m[0].Name.Split('.')[0] + '.*') } | Sort-Object -Unique) }
    }
}

# Units that only checks can reach. Roots are units nothing else calls (entry points and script-level dispatch
# targets). A check is a unit named Test-*, Verify-*, Assert-*, or *Judge*. A unit reachable from a check root and
# from no other root works only inside its own proofs: green checks, unreachable from the product.
function Get-SmaCheckOnly($profiled) {
    $byKey = @{}
    foreach ($u in $profiled) { $k = $u.Project + '|' + $u.Name; if (-not $byKey.ContainsKey($k)) { $byKey[$k] = [Collections.Generic.List[object]]::new() }; $byKey[$k].Add($u) }
    $edges = @{}
    foreach ($u in $profiled) {
        $targets = [Collections.Generic.List[object]]::new()
        foreach ($n in $u.Internal) { if ($byKey.ContainsKey($u.Project + '|' + $n)) { $targets.AddRange($byKey[$u.Project + '|' + $n]) } }
        foreach ($n in $u.Nominated) { $name = $n.Split(':', 2)[1]; if ($byKey.ContainsKey($u.Project + '|' + $name)) { $targets.AddRange($byKey[$u.Project + '|' + $name]) } }
        $edges[$u] = $targets
    }
    $isCheck = { param($u) $short = $u.Name.Split('.')[-1]; $short -match '^(Test|Verify|Assert)-' -or $short -match '(?i)judge' -or $u.File -match '(?i)(^|[\\/])(tests?|.*judges?)[\\/.]' }
    $reach = { param([object[]] $roots) $seen = [Collections.Generic.HashSet[object]]::new(); $stack = [Collections.Generic.Stack[object]]::new(); foreach ($r in $roots) { if ($seen.Add($r)) { $stack.Push($r) } }
        while ($stack.Count) { $x = $stack.Pop(); foreach ($t in $edges[$x]) { if ($seen.Add($t)) { $stack.Push($t) } } }; , $seen }
    $roots = @($profiled | Where-Object { -not $_.Incoming.Count })
    $fromChecks = & $reach @($roots | Where-Object { & $isCheck $_ })
    $fromProduct = & $reach @($roots | Where-Object { -not (& $isCheck $_) })
    foreach ($u in $fromChecks) {
        if ($fromProduct.Contains($u) -or (& $isCheck $u)) { continue }
        $callers = @($profiled | Where-Object { $edges[$_] -contains $u } | ForEach-Object Name | Sort-Object -Unique)
        [pscustomobject]@{ Project = $u.Project; File = $u.File; Line = $u.Line; Name = $u.Name; Lines = $u.Lines; CalledBy = $callers; Status = 'UnverifiedNomination'; ExecutionCoverage = 'Unknown' }
    }
}

function Get-SmaReport {
    param($units, $profiled)
    '=== projects'
    $units | Group-Object Project | Sort-Object Count -Descending | ForEach-Object { '{0,-28} {1,5} units  {2,4} pure  {3}' -f $_.Name, $_.Count, @($_.Group | Where-Object Pure).Count, $_.Group[0].Remote }
    '=== copies of one remote: identical, diverged, not in every copy'
    foreach ($r in $units | Group-Object Remote | Where-Object { @($_.Group.Project | Sort-Object -Unique).Count -gt 1 }) {
        $copies = @($r.Group.Project | Sort-Object -Unique); $map = @{}
        foreach ($c in $copies) { $map[$c] = @{}; foreach ($u in $r.Group | Where-Object Project -eq $c) { $map[$c][$u.Kind + ':' + $u.Name] = $u.Shape } }
        $same = 0; $diff = 0; $one = 0
        foreach ($n in @($map.Values | ForEach-Object { $_.Keys } | Sort-Object -Unique)) {
            $present = @($copies | Where-Object { $map[$_].ContainsKey($n) })
            if ($present.Count -lt $copies.Count) { $one++ } elseif (@($present | ForEach-Object { $map[$_][$n] } | Sort-Object -Unique).Count -eq 1) { $same++ } else { $diff++ }
        }
        '{0,-34} {1}: identical {2}, diverged {3}, not in every copy {4}' -f $r.Name, ($copies -join ' / '), $same, $diff, $one
    }
    $primary = @{}; foreach ($r in $units | Group-Object Remote) { $primary[$r.Name] = ($r.Group | Group-Object Project | Sort-Object Count -Descending | Select-Object -First 1).Name }
    $distinct = @($units | Where-Object { $primary[$_.Remote] -eq $_.Project })
    '=== distinct work (largest copy of each remote)'
    '{0} units: {1} functions, {2} classes; pure closures {3}' -f $distinct.Count, @($distinct | Where-Object Kind -eq 'function').Count, @($distinct | Where-Object Kind -eq 'class').Count, @($distinct | Where-Object Pure).Count
    'effects: ' + (($distinct | ForEach-Object { $_.Effects } | Group-Object | Sort-Object Count -Descending | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join '  ')
    '=== identical structure in more than one remote (at least 5 lines)'
    $distinct | Where-Object { $_.Lines -ge 5 } | Group-Object Shape | Where-Object { @($_.Group.Remote | Sort-Object -Unique).Count -gt 1 } | Sort-Object { $_.Group[0].Lines } -Descending | ForEach-Object { '{0,4} lines  {1}' -f $_.Group[0].Lines, (($_.Group | ForEach-Object { "$($_.Project):$($_.Name)" }) -join ' = ') }
    '=== same name, different structure, in more than one remote'
    $distinct | Group-Object Kind, Name | Where-Object { @($_.Group.Remote | Sort-Object -Unique).Count -gt 1 -and @($_.Group.Shape | Sort-Object -Unique).Count -gt 1 } | Sort-Object Count -Descending | ForEach-Object { '{0,-40} {1}' -f $_.Group[0].Name, (($_.Group | ForEach-Object Project | Sort-Object -Unique) -join ', ') }
    '=== dynamic code'
    $distinct | Where-Object { $_.Effects -contains 'dynamic-code' } | Sort-Object Project, File, Line | ForEach-Object { '  {0}:{1}:{2} {3}' -f $_.Project, $_.File, $_.Line, $_.Name }
    '=== drive-rooted path literals'
    $distinct | Where-Object { $_.RootedPaths.Count } | Sort-Object Project, File, Line | ForEach-Object { '  {0}:{1}:{2} {3}  {4}' -f $_.Project, $_.File, $_.Line, $_.Name, ($_.RootedPaths -join ' | ') }
    '=== calls matched by name to another project (nominated, not established)'
    $distinct | ForEach-Object { $u = $_; $u.NameMatchedElsewhere | ForEach-Object { "$($u.Project) -> " + $_ } } | Group-Object | Sort-Object Count -Descending | ForEach-Object { '  {0,4}  {1}' -f $_.Count, $_.Name }
    '=== reached only through members or reflection (invisible to the command graph)'
    $distinct | Where-Object { $_.Incoming.Count -and -not ($_.Incoming | Where-Object { $_ -like 'command:*' }) } | Sort-Object Project, File, Line | ForEach-Object { '  {0}:{1}:{2} {3}  <- {4}' -f $_.Project, $_.File, $_.Line, $_.Name, (($_.Incoming | ForEach-Object { $_ } | Select-Object -First 4) -join ' | ') }
    '=== no incoming edge from any unit (entry points, script-level dispatch, or unused), by project'
    $distinct | Where-Object { -not $_.Incoming.Count } | Group-Object Project | Sort-Object Count -Descending | ForEach-Object { '  {0,-28} {1,5} of {2}' -f $_.Name, $_.Count, @($distinct | Where-Object Project -eq $_.Name).Count }
    '=== experimental check-root nominations; script dispatch, dynamic binding and product reachability are not established'
    if ($profiled) { Get-SmaCheckOnly $profiled | Sort-Object Project, File, Line | ForEach-Object { '  {0}:{1}:{2} {3} ({4} lines)  <- {5}' -f $_.Project, $_.File, $_.Line, $_.Name, $_.Lines, (($_.CalledBy | Select-Object -First 4) -join ', ') } }
    '=== statement structure shared by different units (12+ nodes, names and literals removed), widest first'
    $owners = @{}
    foreach ($u in $distinct) { foreach ($s in $u.Subtrees) { if (-not $owners.ContainsKey($s)) { $owners[$s] = [Collections.Generic.List[object]]::new() }; $owners[$s].Add($u) } }
    $owners.GetEnumerator() | Where-Object { @($_.Value | ForEach-Object { $_.Project + '|' + $_.Name } | Sort-Object -Unique).Count -gt 2 } | Sort-Object { @($_.Value).Count } -Descending | Select-Object -First 60 | ForEach-Object {
        $names = @($_.Value | ForEach-Object { $_.Project + ':' + $_.Name } | Sort-Object -Unique)
        '  {0} x{1,-4} {2}{3}' -f $_.Key, $names.Count, (($names | Select-Object -First 6) -join ' = '), $(if ($names.Count -gt 6) { ' ...' } else { '' }) }
}

# Lint: defects PowerShell's own rules make easy to write and hard to see, found from the parser.
#   CaseSpelledTwoWays  a variable or function name written with different casing (one name to PowerShell).
#   VariableClobbered   a variable assigned at a function's top level and again inside a loop (loops share the
#                       function's scope), then read at top level after that loop.
#   MethodSyntaxCall    a command called as name(a, b): one array argument, not two.
#   CommaBindsFirst     an arithmetic, comparison or format operator with a bare comma list as an operand:
#                       the comma binds first, so the operator receives an array.
#   CaselessSymbol      a case-insensitive comparison against a literal containing letters, in a file that also
#                       uses case-sensitive operators, so case matters to its author there.
function Get-SmaLint {
    param([string] $file)
    $tokens = $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
    $finding = { param([string] $rule, $node, [string] $detail) [pscustomobject]@{ File = $file; Line = $node.Extent.StartLineNumber; Rule = $rule; Detail = $detail } }
    $variables = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true))
    foreach ($group in $variables | Where-Object { -not $_.VariablePath.IsDriveQualified } | Group-Object { $_.VariablePath.UserPath.ToLowerInvariant() }) {
        $spellings = @($group.Group | ForEach-Object { $_.VariablePath.UserPath } | Sort-Object -Unique -CaseSensitive)
        if ($spellings.Count -gt 1) { & $finding 'CaseSpelledTwoWays' $group.Group[0] ('$' + ($spellings -join ' $')) }
    }
    # In a class method, a local whose name equals a property's name in any casing is the property to PowerShell:
    # assigning it is a parse error, and reading it is easy to confuse. Every such name is a finding.
    foreach ($type in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.TypeDefinitionAst] }, $true)) {
        $properties = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($member in $type.Members) { if ($member -is [System.Management.Automation.Language.PropertyMemberAst]) { $null = $properties.Add($member.Name) } }
        foreach ($method in $type.Members | Where-Object { $_ -is [System.Management.Automation.Language.FunctionMemberAst] }) {
            # A parameter with a property's name is the ordinary constructor idiom ($this.Name = $Name). The defects are
            # assigning a local with a property's name (PowerShell rejects it) and reading one that is neither a
            # parameter nor assigned in the method, where $this.<Name> was meant.
            $parameterNames = [Collections.Generic.HashSet[string]]::new([string[]]@($method.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }), [StringComparer]::OrdinalIgnoreCase)
            $assigned = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($assignment in $method.Body.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) { $left = $assignment.Left; while ($left -is [System.Management.Automation.Language.ConvertExpressionAst]) { $left = $left.Child }; if ($left -is [System.Management.Automation.Language.VariableExpressionAst]) { $null = $assigned.Add($left.VariablePath.UserPath) } }
            foreach ($variable in $method.Body.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] -and -not $args[0].VariablePath.IsDriveQualified }, $true)) {
                $variableName = $variable.VariablePath.UserPath
                if ($variableName -eq 'this' -or -not $properties.Contains($variableName) -or $parameterNames.Contains($variableName)) { continue }
                $how = if ($assigned.Contains($variableName)) { 'assigned as a local' } else { 'read but never assigned or passed in; $this.' + $variableName + ' was probably meant' }
                & $finding 'LocalShadowsProperty' $variable ("`$$variableName in $($type.Name).$($method.Name) shares property $($type.Name).$variableName's name and is $how"); break
            }
        }
    }
    # A script's parameters share one case-insensitive namespace with every variable in the file.
    $scriptParameters = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    foreach ($parameter in $scriptParameters) {
        $others = @($variables | Where-Object { $_.VariablePath.UserPath -ieq $parameter -and $_.VariablePath.UserPath -cne $parameter })
        if ($others.Count) { & $finding 'CaseSpelledTwoWays' $others[0] "script parameter `$$parameter also written `$$($others[0].VariablePath.UserPath)" }
    }
    $definitions = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
    $commands = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true))
    $defined = @{}; foreach ($d in $definitions) { $defined[$d.Name.ToLowerInvariant()] = $d.Name }
    foreach ($group in @($commands | Where-Object { $_.GetCommandName() -and $defined.ContainsKey($_.GetCommandName().ToLowerInvariant()) }) | Group-Object { $_.GetCommandName().ToLowerInvariant() }) {
        $spellings = @(@($group.Group | ForEach-Object { $_.GetCommandName() }) + $defined[$group.Name] | Sort-Object -Unique -CaseSensitive)
        if ($spellings.Count -gt 1) { & $finding 'CaseSpelledTwoWays' $group.Group[0] ($spellings -join ' ') }
    }
    $isLoop = { param($a) $a -is [System.Management.Automation.Language.LoopStatementAst] }
    foreach ($fn in $definitions) {
        $body = $fn.Body
        $loopOf = { param($n) $found = $null; $p = $n.Parent; while ($null -ne $p -and $p -ne $body) { if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst] -or $p -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { return 'nested' }; if (& $isLoop $p) { $found = $p }; $p = $p.Parent }; $found }
        $assigned = @{}
        foreach ($a in $body.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
            # Only a direct rebinding counts ($x = ..., [T] $x = ...); $x[i] = ... and $x.P = ... change the object, not the variable.
            $left = $a.Left; while ($left -is [System.Management.Automation.Language.ConvertExpressionAst]) { $left = $left.Child }
            foreach ($target in @($left) | Where-Object { $_ -is [System.Management.Automation.Language.VariableExpressionAst] }) {
                $name = $target.VariablePath.UserPath.ToLowerInvariant(); $loop = & $loopOf $a
                if ($loop -eq 'nested') { continue }
                # An accumulator ($t += x, $t = $t + x) carries its own value forward; that is not a clobber.
                if ($null -ne $loop -and ($a.Operator -ne 'Equals' -or @($a.Right.FindAll({ param($x) $x -is [System.Management.Automation.Language.VariableExpressionAst] -and $x.VariablePath.UserPath -ieq $name }, $true)).Count)) { continue }
                if (-not $assigned.ContainsKey($name)) { $assigned[$name] = [Collections.Generic.List[object]]::new() }
                $assigned[$name].Add([pscustomobject]@{ Node = $a; Loop = $loop; Offset = $a.Extent.StartOffset })
            }
        }
        foreach ($loopNode in $body.FindAll({ $args[0] -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) {
            if ((& $loopOf $loopNode) -eq 'nested') { continue }
            $name = $loopNode.Variable.VariablePath.UserPath.ToLowerInvariant()
            if (-not $assigned.ContainsKey($name)) { $assigned[$name] = [Collections.Generic.List[object]]::new() }
            $assigned[$name].Add([pscustomobject]@{ Node = $loopNode; Loop = $loopNode; Offset = $loopNode.Extent.StartOffset })
        }
        foreach ($name in $assigned.Keys) {
            $top = @($assigned[$name] | Where-Object { $null -eq $_.Loop }); $inner = @($assigned[$name] | Where-Object { $null -ne $_.Loop })
            if (-not $top.Count -or -not $inner.Count) { continue }
            $firstTop = ($top | Measure-Object Offset -Minimum).Minimum
            foreach ($i in $inner) {
                if ($i.Offset -lt $firstTop) { continue }
                # A scanner fills a default when a condition holds (an if or switch between the write and its loop).
                # A clobber overwrites unconditionally on every pass.
                $guard = $i.Node.Parent; $guarded = $false
                while ($null -ne $guard -and $guard -ne $i.Loop) { if ($guard -is [System.Management.Automation.Language.IfStatementAst] -or $guard -is [System.Management.Automation.Language.SwitchStatementAst] -or $guard -is [System.Management.Automation.Language.TryStatementAst]) { $guarded = $true; break }; $guard = $guard.Parent }
                if ($guarded) { continue }
                # Searches and refinements read the outer value inside the loop before replacing it. A clobber is a
                # loop temporary: inside the loop the name is written before it is ever read.
                $inLoop = @($i.Loop.FindAll({ param($x) $x -is [System.Management.Automation.Language.VariableExpressionAst] -and $x.VariablePath.UserPath -ieq $name }, $true) | Sort-Object { $_.Extent.StartOffset })
                if ($i.Loop -is [System.Management.Automation.Language.ForEachStatementAst] -and $i.Loop.Variable.VariablePath.UserPath -ieq $name) { $inLoop = @($inLoop | Where-Object { $_ -ne $i.Loop.Variable }) }
                $firstUse = $inLoop | Select-Object -First 1
                if ($null -ne $firstUse -and -not ($firstUse.Parent -is [System.Management.Automation.Language.AssignmentStatementAst] -and $firstUse.Parent.Left -eq $firstUse) -and -not ($i.Loop -is [System.Management.Automation.Language.ForEachStatementAst] -and $i.Loop.Variable.VariablePath.UserPath -ieq $name)) { continue }
                $after = $i.Loop.Extent.EndOffset
                $reads = @($body.FindAll({ param($x) $x -is [System.Management.Automation.Language.VariableExpressionAst] -and $x.VariablePath.UserPath -ieq $name -and $x.Extent.StartOffset -gt $after -and $x.Parent -isnot [System.Management.Automation.Language.AssignmentStatementAst] }, $true) | Where-Object { $null -eq (& $loopOf $_) })
                $reassigned = @($top | Where-Object { $_.Offset -gt $after -and $_.Offset -lt $(if ($reads.Count) { $reads[0].Extent.StartOffset } else { 0 }) })
                if ($reads.Count -and -not $reassigned.Count) { & $finding 'VariableClobbered' $i.Node ("`$$name in $($fn.Name): set at top level, reassigned in the loop at line $($i.Loop.Extent.StartLineNumber), read after it at line $($reads[0].Extent.StartLineNumber)"); break }
            }
        }
    }
    # A forced reimport inside a function reruns the module body on every call and resets its script-scope state.
    foreach ($c in $commands | Where-Object { $_.GetCommandName() -eq 'Import-Module' }) {
        $forced = @($c.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and 'Force'.StartsWith($_.ParameterName, [StringComparison]::OrdinalIgnoreCase) })
        $owner = $c.Parent; while ($null -ne $owner -and $owner -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $owner = $owner.Parent }
        if ($forced.Count -and $null -ne $owner) {
            $callCount = @($commands | Where-Object { $_.GetCommandName() -eq $owner.Name }).Count
            & $finding 'ForcedReimport' $c ("in $($owner.Name), called from $callCount place(s): " + $c.Extent.Text)
        }
    }
    foreach ($c in $commands) {
        $name = $c.GetCommandName(); if (-not $name -or $c.CommandElements.Count -lt 2) { continue }
        $second = $c.CommandElements[1]
        if ($second -is [System.Management.Automation.Language.ParenExpressionAst] -and $second.Extent.StartOffset -eq $c.CommandElements[0].Extent.EndOffset -and $null -ne $second.Pipeline.Find({ $args[0] -is [System.Management.Automation.Language.ArrayLiteralAst] }, $true)) { & $finding 'MethodSyntaxCall' $c $c.Extent.Text.Split("`n")[0] }
    }
    foreach ($b in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.BinaryExpressionAst] }, $true)) {
        if ($b.Operator -in 'Comma') { continue }
        foreach ($side in $b.Left, $b.Right) {
            if ($side -is [System.Management.Automation.Language.ArrayLiteralAst] -and $side.Elements.Count -gt 1 -and $b.Operator -notin 'Format', 'Join', 'Iin', 'Cin', 'Inotin', 'Cnotin', 'Icontains', 'Ccontains', 'Inotcontains', 'Cnotcontains', 'Ireplace', 'Creplace') { & $finding 'CommaBindsFirst' $b $b.Extent.Text.Split("`n")[0] }
        }
    }
    # Literals that exist in this file in more than one casing ('A' and 'a'): case distinguishes them here.
    $literals = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $x.Parent -isnot [System.Management.Automation.Language.MemberExpressionAst] -and $x.Parent -isnot [System.Management.Automation.Language.CommandAst] }, $true))
    $cased = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($group in $literals | Where-Object { $_.Value -cmatch '\p{L}' } | Group-Object { $_.Value.ToLowerInvariant() }) {
        if (@($group.Group.Value | Sort-Object -Unique -CaseSensitive).Count -gt 1) { $null = $cased.Add($group.Name) }
    }
    if ($cased.Count) {
        foreach ($b in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.BinaryExpressionAst] -and $x.Operator -in 'Ieq', 'Ine', 'Ilike', 'Inotlike', 'Iin', 'Inotin', 'Icontains', 'Inotcontains', 'Imatch', 'Inotmatch', 'Ireplace', 'Isplit' }, $true)) {
            $operands = @(foreach ($side in $b.Left, $b.Right) { if ($side -is [System.Management.Automation.Language.ArrayLiteralAst]) { $side.Elements } else { $side } })
            $hits = @($operands | Where-Object { $_ -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $cased.Contains($_.Value) } | ForEach-Object Value)
            if ($hits.Count) { & $finding 'CaselessSymbol' $b ("'" + ($hits -join "','") + "' exists here in another casing: " + $b.Extent.Text.Split("`n")[0]) }
        }
    }
}

# Describe: one project as live objects, built only from its parsed source. Every fact carries where it was read
# (file and line). Code held in string literals is parsed and described too, marked Embedded: it is cruft by the AST
# rule, and it is still part of what the project does. String literals that are not PowerShell are listed as Foreign.
class SmaUnit {
    [string] $Identity; [string] $Scope; [string] $BodyScope
    [string] $Name; [string] $Kind; [string] $File; [int] $Line; [int] $Lines; [string] $Class
    [bool] $Embedded; [string[]] $Parameters; [string] $Synopsis
    [object] $Ast
    [string] ToString() { return "$($this.Name) ($($this.File):$($this.Line))" }
}
class SmaEdge {
    [string] $FromIdentity; [string] $ToIdentity; [string] $Scope
    [string] $Resolution = 'Unresolved'; [string] $Reason
    [object] $Ast
    [string] $From; [string] $To; [string] $Kind; [string] $File; [int] $Line
    [string] ToString() { return "$($this.From) -$($this.Kind)-> $($this.To) ($($this.File):$($this.Line))" }
}
class SmaSource {
    [string] $Identity; [string] $File; [string] $Sha256; [string] $Provenance
    [string] $ParentIdentity; [object] $Container; [object] $Ast; [object[]] $ParseErrors
    [string] $Boundary; [bool] $Embedded
}
class SmaCoverage {
    [string] $Root; [string] $Scope; [int] $Sources; [int] $ParseFailures; [int] $UnresolvedEdges
    [int] $UnexaminedLiterals; [bool] $DeclarationsComplete; [bool] $ExecutionComplete
    [string[]] $Limitations
}
class SmaAbsence {
    [string] $Pattern; [string] $Scope; [string] $Status
    [object[]] $Matches; [SmaCoverage] $Coverage
}
class SmaChange {
    [string] $File; [string] $Before; [string] $After; [string] $Kind
}
class SmaProject {
    [string] $Root; [string] $Commit; [datetime] $DescribedUtc
    [Collections.Generic.List[SmaUnit]] $Units
    [Collections.Generic.List[SmaEdge]] $Edges
    SmaProject() { $this.Units = [Collections.Generic.List[SmaUnit]]::new(); $this.Edges = [Collections.Generic.List[SmaEdge]]::new() }
    [Collections.Generic.List[object]] $EntryCalls = [Collections.Generic.List[object]]::new()
    [Collections.Generic.List[object]] $Embedded = [Collections.Generic.List[object]]::new()
    [Collections.Generic.List[object]] $Foreign = [Collections.Generic.List[object]]::new()
    [Collections.Generic.List[object]] $Lint = [Collections.Generic.List[object]]::new()
    [Collections.Generic.List[object]] $Parameters = [Collections.Generic.List[object]]::new()
    [Collections.Generic.List[object]] $Variables = [Collections.Generic.List[object]]::new()
    [string[]] $Files
    [string[]] $Operations = @('Describe','Find','Callers','Callees','Path','Coverage','Absent','Changes')
    [Collections.Generic.List[SmaSource]] $Sources = [Collections.Generic.List[SmaSource]]::new()
    [Collections.Generic.List[object]] $Symbols = [Collections.Generic.List[object]]::new()
    [Collections.Generic.List[object]] $TypeReferences = [Collections.Generic.List[object]]::new()
    [Collections.Generic.List[object]] $Relationships = [Collections.Generic.List[object]]::new()
    [Collections.Generic.List[object]] $Diagnostics = [Collections.Generic.List[object]]::new()
    [Collections.Generic.List[object]] $Observations = [Collections.Generic.List[object]]::new()
    [Collections.Generic.Dictionary[System.Management.Automation.Language.Ast,SmaUnit]] $NodeOwners = [Collections.Generic.Dictionary[System.Management.Automation.Language.Ast,SmaUnit]]::new()
    [SmaProject] Describe() { return $this }
    [SmaCoverage] Coverage() { return $this.Coverage('Execution') }
    [SmaCoverage] Coverage([string] $Scope) {
        if ($Scope -notin 'Declarations','Execution') { throw 'Scope must be Declarations or Execution.' }
        $failures = @($this.Sources | Where-Object { $_.ParseErrors.Count }).Count
        $unresolved = @($this.Edges | Where-Object Resolution -ne 'Bound').Count
        return [SmaCoverage]@{ Root = $this.Root; Scope = $Scope; Sources = $this.Sources.Count; ParseFailures = $failures
            UnresolvedEdges = $unresolved; UnexaminedLiterals = $this.Foreign.Count
            DeclarationsComplete = ($failures -eq 0 -and $this.Foreign.Count -eq 0); ExecutionComplete = $false
            Limitations = @('Local nonignored PowerShell files only; imported and external source is not recursively admitted.',
                'Static lexical binding only; runtime function replacement, aliases, module exports and dynamic dispatch require observations.',
                'Large multiline literals without an established PowerShell consumer remain unclassified.',
                'Experimental lint findings are hypotheses, not proof of runtime failure.') }
    }
    [SmaChange[]] Changes() {
        $changes = [Collections.Generic.List[SmaChange]]::new()
        foreach ($source in $this.Sources | Where-Object { -not $_.Embedded }) {
            $path = Join-Path $this.Root $source.File
            $after = if ([IO.File]::Exists($path)) { (Get-FileHash -LiteralPath $path).Hash } else { '' }
            if ($after -cne $source.Sha256) { $changes.Add([SmaChange]@{ File = $source.File; Before = $source.Sha256; After = $after; Kind = $(if ($after) { 'Modified' } else { 'Missing' }) }) }
        }
        foreach ($relative in Get-SmaSourceFiles $this.Root) {
            if ($relative -notin $this.Files) { $changes.Add([SmaChange]@{ File = $relative; After = (Get-FileHash -LiteralPath (Join-Path $this.Root $relative)).Hash; Kind = 'Added' }) }
        }
        return $changes.ToArray()
    }
    # Units whose name matches a pattern (regular expression over unit names, which are data, not code).
    [SmaUnit[]] Find([string] $Pattern) { return @($this.Units | Where-Object { $_.Name -match $Pattern }) }
    [SmaEdge[]] Callers([string] $name) { return @($this.Edges | Where-Object { $_.To -ieq $name -or $_.To -like "*.$name" }) }
    [SmaEdge[]] Callees([string] $name) { return @($this.Edges | Where-Object { $_.From -ieq $name }) }
    # A shortest call path from one unit to another over every edge kind, or nothing when none exists.
    [string[]] Path([string] $From, [string] $To) {
        $starts=@($this.Units | Where-Object { $_.Identity -ceq $From -or $_.Name -ieq $From })
        $ends=@($this.Units | Where-Object { $_.Identity -ceq $To -or $_.Name -ieq $To })
        if($starts.Count -gt 1 -or $ends.Count -gt 1){throw 'Ambiguous symbol: supply its scope-qualified unit Identity.'}
        if($starts.Count -eq 0 -or $ends.Count -eq 0){return @()}
        $startIdentity=$starts[0].Identity;$endIdentity=$ends[0].Identity
        $labels=@{};foreach($unit in $this.Units){$labels[$unit.Identity]=$unit.Name}
        $previous = @{}; $queue = [Collections.Generic.Queue[string]]::new(); $queue.Enqueue($startIdentity); $previous[$startIdentity] = $null
        $next = @{}; foreach ($e in $this.Edges | Where-Object Resolution -eq 'Bound') { $k = $e.FromIdentity; if (-not $next.ContainsKey($k)) { $next[$k] = [Collections.Generic.List[string]]::new() }; $next[$k].Add($e.ToIdentity) }
        while ($queue.Count) {
            $n = $queue.Dequeue(); if ($n -ceq $endIdentity) { $path = [Collections.Generic.List[string]]::new(); $c = $n; while ($null -ne $c) { $path.Insert(0, $labels[$c]); $c = $previous[$c] }; return $path.ToArray() }
            foreach ($m in @($next[$n])) { if ($null -ne $m -and -not $previous.ContainsKey($m)) { $previous[$m] = $n; $queue.Enqueue($m) } }
        }
        return @()
    }
    # Evidence of absence: every unit name, command, type and member searched, with how many of each were searched.
    [object] Absent([string] $Pattern) { return $this.Absent($Pattern, 'Execution') }
    [SmaAbsence] Absent([string] $Pattern, [string] $Scope) {
        # Absence is claimed only when nothing matches anywhere the parser can see: unit names, call targets, script
        # and function parameters, environment and script variables, and the holders and contents of string literals
        # that are source (embedded PowerShell, templates, foreign languages).
        $matchedUnits = @($this.Units | Where-Object { $_.Name -match $Pattern })
        $matchedEdges = @($this.Edges | Where-Object { $_.To -match $Pattern })
        $matchedParameters = @($this.Parameters | Where-Object { $_.Name -match $Pattern })
        $matchedVariables = @($this.Variables | Where-Object { $_.Name -match $Pattern })
        $matchedLiterals = @(@($this.Embedded) + @($this.Foreign) | Where-Object { $_.HeldBy -match $Pattern -or $_.Text -match $Pattern })
        $coverage = $this.Coverage($Scope)
        $matches = @(if ($Scope -eq 'Declarations') { $matchedUnits } else { @($matchedUnits) + @($matchedEdges) + @($matchedParameters) + @($matchedVariables) + @($matchedLiterals) })
        $status = if ($matches.Count) { 'Found' } elseif ($Scope -eq 'Declarations' -and $coverage.DeclarationsComplete) { 'NotFoundWithinScope' } else { 'Unknown' }
        return [SmaAbsence]@{ Pattern = $Pattern; Scope = $Scope; Status = $status; Matches = @($matches); Coverage = $coverage }
    }
}

function Get-SmaLexicalScope($node, [string] $sourceIdentity) {
    $cursor = $node.Parent
    while ($null -ne $cursor) {
        if ($cursor -is [System.Management.Automation.Language.ScriptBlockAst]) { return $sourceIdentity + ':' + $cursor.Extent.StartOffset }
        # Inline function/method parameters precede the body node in the AST, but belong to its lexical scope.
        if ($cursor -is [System.Management.Automation.Language.FunctionDefinitionAst] -or $cursor -is [System.Management.Automation.Language.FunctionMemberAst]) { return $sourceIdentity + ':' + $cursor.Body.Extent.StartOffset }
        $cursor = $cursor.Parent
    }
    return $sourceIdentity + ':0'
}

function Get-SmaOwner($node, $project, [string] $sourceIdentity) {
    $cursor = $node.Parent
    while ($null -ne $cursor) {
        if ($project.NodeOwners.ContainsKey($cursor)) { return $project.NodeOwners[$cursor] }
        $cursor = $cursor.Parent
    }
    return $project.Units | Where-Object Identity -eq ($sourceIdentity + ':script') | Select-Object -First 1
}

function Add-SmaDescribedSource($project, [string] $relative, $ast, [bool] $embedded, [int] $lineOffset, [string] $sourceIdentity) {
    $scriptName=if($embedded){'<embedded-script>'+$sourceIdentity}else{'<script>'+$relative}
    $scriptUnit = [SmaUnit]@{ Identity = $sourceIdentity + ':script'; Name = $scriptName; Kind = 'script'; File = $relative
        Line = 1 + $lineOffset; Lines = $ast.Extent.EndLineNumber; Ast = $ast; Embedded = $embedded
        Scope = $sourceIdentity + ':0'; BodyScope = $sourceIdentity + ':' + $ast.Extent.StartOffset }
    $project.Units.Add($scriptUnit)
    $project.NodeOwners[$ast] = $scriptUnit
    foreach ($node in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -or $args[0] -is [System.Management.Automation.Language.TypeDefinitionAst] }, $true)) {
        $className = ''; $kind = 'function'; $name = $node.Name; $bodyScope = ''
        if ($node -is [System.Management.Automation.Language.TypeDefinitionAst]) { $kind = 'class' }
        elseif ($node.Parent -is [System.Management.Automation.Language.FunctionMemberAst]) { $className = $node.Parent.Parent.Name; $kind = 'method'; $name = $className + '.' + $name }
        if ($kind -ne 'class') { $bodyScope = $sourceIdentity + ':' + $node.Body.Extent.StartOffset }
        $unit = [SmaUnit]@{ Identity = $sourceIdentity + ':' + $node.Extent.StartOffset + ':' + $kind; Name = $name; Kind = $kind; Class = $className
            File = $relative; Line = $node.Extent.StartLineNumber + $lineOffset; Lines = $node.Extent.EndLineNumber - $node.Extent.StartLineNumber + 1
            Ast = $node; Embedded = $embedded; Scope = (Get-SmaLexicalScope $node $sourceIdentity); BodyScope = $bodyScope }
        $project.Units.Add($unit)
        $project.NodeOwners[$node] = $unit
    }
    foreach ($node in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }, $true)) {
        $unit=[SmaUnit]@{ Identity=$sourceIdentity+':'+$node.Extent.StartOffset+':closure'; Name='<closure>'+$relative+':'+$node.Extent.StartOffset
            Kind='closure'; File=$relative; Line=$node.Extent.StartLineNumber+$lineOffset; Lines=$node.Extent.EndLineNumber-$node.Extent.StartLineNumber+1
            Ast=$node; Embedded=$embedded; Scope=(Get-SmaLexicalScope $node $sourceIdentity); BodyScope=$sourceIdentity+':'+$node.ScriptBlock.Extent.StartOffset }
        $project.Units.Add($unit);$project.NodeOwners[$node]=$unit
        $project.Relationships.Add([pscustomobject]@{Kind='ScriptBlockValue';Identity=$unit.Identity;Container=$node.Parent;Ast=$node;Resolution='Invocation requires a consumer or runtime observation'})
    }
    # An authored ScriptMethod is a closure attached by a command, not a CLR class method. Record the
    # attachment separately: a matching member spelling never establishes which object receives a call.
    foreach($command in $ast.FindAll({$args[0] -is [System.Management.Automation.Language.CommandAst]},$true)){
        if($command.GetCommandName() -ine 'Add-Member'){continue}
        $arguments=@{}; $elements=$command.CommandElements
        for($i=1;$i -lt $elements.Count;$i++){
            if($elements[$i] -isnot [System.Management.Automation.Language.CommandParameterAst]){continue}
            $parameter=$elements[$i]; $value=$parameter.Argument
            if($null -eq $value -and $i+1 -lt $elements.Count -and $elements[$i+1] -isnot [System.Management.Automation.Language.CommandParameterAst]){$i++;$value=$elements[$i]}
            $arguments[$parameter.ParameterName]=$value
        }
        $memberType=$arguments['MemberType'];$memberName=$arguments['Name'];$body=$arguments['Value']
        if($memberType -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -or $memberType.Value -ine 'ScriptMethod' -or
            $memberName -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -or $body -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst]){continue}
        $receiver=$arguments['InputObject']
        if($null -eq $receiver -and $command.Parent -is [System.Management.Automation.Language.PipelineAst]){
            $pipeline=$command.Parent; $index=[Array]::IndexOf($pipeline.PipelineElements,$command)
            if($index -gt 0){$receiver=$pipeline.PipelineElements[$index-1]}
        }
        $project.Relationships.Add([pscustomobject]@{Kind='ScriptMethodDefinition';Name=$memberName.Value;ValueIdentity=$project.NodeOwners[$body].Identity
            ReceiverAst=$receiver;Ast=$command;File=$relative;Line=$command.Extent.StartLineNumber+$lineOffset
            Resolution='Authored attachment; command resolution, receiver identity and later invocation require binding or observation'})
    }
    foreach($assignment in $ast.FindAll({$args[0] -is [System.Management.Automation.Language.AssignmentStatementAst]},$true)){
        if($assignment.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]){continue}
        $table=$assignment.Right.Find({$args[0] -is [System.Management.Automation.Language.HashtableAst]},$false)
        if($null -eq $table){continue}
        foreach($pair in $table.KeyValuePairs){
            $value=$pair.Item2.Find({$args[0] -is [System.Management.Automation.Language.ScriptBlockExpressionAst]},$false)
            if($value -and $pair.Item1 -is [System.Management.Automation.Language.StringConstantExpressionAst]){
                $project.Relationships.Add([pscustomobject]@{Kind='DispatchTableEntry';Table=$assignment.Left.VariablePath.UserPath;Key=$pair.Item1.Value
                    ValueIdentity=$project.NodeOwners[$value].Identity;Ast=$pair.Item2;File=$relative;Line=$pair.Item1.Extent.StartLineNumber+$lineOffset;Resolution='Declared mapping; selector and invocation remain separate facts'})
            }
        }
    }
    foreach ($node in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ParameterAst] -or $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] -or $args[0] -is [System.Management.Automation.Language.TypeExpressionAst] -or $args[0] -is [System.Management.Automation.Language.TypeConstraintAst] }, $true)) {
        $scope = Get-SmaLexicalScope $node $sourceIdentity
        $record = [pscustomobject]@{ Name = ''; Kind = $node.GetType().Name; Scope = $scope; File = $relative; Line = $node.Extent.StartLineNumber + $lineOffset; Ast = $node; Type = '' }
        if ($node -is [System.Management.Automation.Language.ParameterAst]) {
            $record.Name = $node.Name.VariablePath.UserPath; $record.Type = $node.StaticType.FullName
            $project.Parameters.Add($record); $project.Symbols.Add($record)
        } elseif ($node -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $record.Name = $node.VariablePath.UserPath
            if ($node.Parent -is [System.Management.Automation.Language.ConvertExpressionAst]) { $record.Type = $node.Parent.Type.TypeName.FullName }
            $project.Variables.Add($record); $project.Symbols.Add($record)
        } else { $record.Name = $node.TypeName.FullName; $project.TypeReferences.Add($record) }
    }
    foreach ($node in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] -or $args[0] -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -or $args[0] -is [System.Management.Automation.Language.UsingStatementAst] }, $true)) {
        $owner = Get-SmaOwner $node $project $sourceIdentity
        $edge = [SmaEdge]@{ From = $owner.Name; FromIdentity = $owner.Identity; Scope = (Get-SmaLexicalScope $node $sourceIdentity)
            File = $relative; Line = $node.Extent.StartLineNumber + $lineOffset; Ast = $node; Reason = 'Target requires binding or runtime observation.' }
        if ($node -is [System.Management.Automation.Language.CommandAst]) {
            $edge.Kind = 'command'; $edge.To = $node.GetCommandName()
            if (-not $edge.To) { $edge.To = $node.CommandElements[0].Extent.Text; $edge.Kind = 'dynamic-command' }
            if ($node.InvocationOperator -eq 'Dot') { $edge.Kind = 'dot-source' }
            if ($edge.To -in 'Import-Module','Add-Type','Invoke-Expression') { $edge.Kind = 'import-or-evaluation' }
            if ($owner.Kind -eq 'script') { $project.EntryCalls.Add($edge) }
        } elseif ($node -is [System.Management.Automation.Language.UsingStatementAst]) {
            $edge.Kind = 'using'; $edge.To = $node.Name.Value
        } else {
            $memberName = if ($node.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $node.Member.Value } else { $node.Member.Extent.Text }
            $edge.To = $memberName; $edge.Kind = 'member'
            if ($node.Static -and $node.Expression -is [System.Management.Automation.Language.TypeExpressionAst]) {
                $edge.To = $node.Expression.TypeName.FullName + '.' + $memberName; $edge.Kind = 'static'
            } elseif ($node.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and $node.Expression.VariablePath.UserPath -ieq 'this' -and $owner.Class) {
                $edge.To = $owner.Class + '.' + $memberName; $edge.Kind = 'this-member'
            }
            if ($memberName -in 'GetMethod','GetProperty','GetField','GetMember','GetType','CreateDelegate') {
                $edge.Kind = 'reflection'; $edge.Reason = 'Reflection receiver and overload are not established.'
                if($node.Arguments.Count -and $node.Arguments[0] -is [System.Management.Automation.Language.StringConstantExpressionAst]){$edge.To=$node.Arguments[0].Value}
            }
            if ($memberName -in 'Invoke','DynamicInvoke') { $edge.Kind = 'delegate-or-reflection'; $edge.Reason = 'Callable value is not established.' }
        }
        $project.Edges.Add($edge)
    }
}

function Resolve-SmaEdges($project) {
    $functions = @{}; $methods = @{}
    foreach ($unit in $project.Units) {
        if ($unit.Kind -eq 'function') { $index = $functions; $key = $unit.Scope + '|' + $unit.Name }
        elseif ($unit.Kind -eq 'method') { $index = $methods; $key = $unit.File + '|' + $unit.Name }
        else { continue }
        if (-not $index.ContainsKey($key)) { $index[$key] = [Collections.Generic.List[SmaUnit]]::new() }
        $index[$key].Add($unit)
    }
    # Never turn a short member spelling into a class method edge. Only explicit local static/this receivers bind here.
    foreach ($edge in $project.Edges) {
        $candidates = @()
        if ($edge.Kind -eq 'command') {
            $cursor = $edge.Ast.Parent
            while ($cursor) {
                if ($cursor -is [System.Management.Automation.Language.ScriptBlockAst]) {
                    # Scope identities already include the secondary source identity.
                    $prefix = $edge.Scope.Substring(0, $edge.Scope.LastIndexOf(':'))
                    $scope = $prefix + ':' + $cursor.Extent.StartOffset
                    $key = $scope + '|' + $edge.To
                    $candidates = @(if ($functions.ContainsKey($key)) { $functions[$key] })
                    if ($candidates.Count) { break }
                }
                $cursor = $cursor.Parent
            }
        } elseif ($edge.Kind -in 'static','this-member') {
            $key = $edge.File + '|' + $edge.To
            $candidates = @(if ($methods.ContainsKey($key)) { $methods[$key] })
        }
        if ($candidates.Count -eq 1) { $edge.ToIdentity = $candidates[0].Identity; $edge.To = $candidates[0].Name; $edge.Resolution = 'Bound'; $edge.Reason = 'Unique declaration in lexical scope; static relationship, not an execution observation.' }
        elseif ($candidates.Count -gt 1) { $edge.Reason = 'Multiple declarations or overloads; binding not established.' }
    }
    foreach ($group in $project.Units | Where-Object Kind -in 'function','class' | Group-Object Scope,Name) {
        if ($group.Count -gt 1) { $project.Diagnostics.Add([pscustomobject]@{ Rule = 'DuplicateDeclaration'; File = $group.Group[0].File; Line = $group.Group[0].Line; Nodes = $group.Group; Detail = 'Case-insensitive declarations share a lexical scope.' }) }
    }
    foreach ($group in $project.Symbols | Group-Object Scope,{ $_.Name.ToLowerInvariant() }) {
        $spellings = @($group.Group.Name | Sort-Object -Unique -CaseSensitive)
        if ($spellings.Count -gt 1) { $project.Diagnostics.Add([pscustomobject]@{ Rule = 'CaseFoldSymbol'; File = $group.Group[0].File; Line = $group.Group[0].Line; Nodes = $group.Group; Detail = 'One PowerShell variable has multiple authored casings: ' + ($spellings -join ', ') }) }
        $types = @($group.Group.Type | Where-Object { $_ -and $_ -ne 'System.Object' } | Sort-Object -Unique)
        if ($types.Count -gt 1) { $project.Diagnostics.Add([pscustomobject]@{ Rule='MultipleVariableTypes'; File=$group.Group[0].File; Line=$group.Group[0].Line; Nodes=$group.Group; Detail='One lexical variable has multiple declared types; inspect conversions: '+($types -join ', ') }) }
    }
}

function Get-SmaSourceFiles([string] $root) {
    if ([IO.Directory]::Exists((Join-Path $root '.git'))) {
        git -C $root ls-files --cached --others --exclude-standard -- '*.ps1' '*.psm1' 2>$null | Sort-Object -Unique
    } else {
        # SMA hosts retained third-party sources and evidence. Its own authored project is the root script.
        Get-ChildItem -LiteralPath $root -File | Where-Object Extension -in '.ps1','.psm1' | ForEach-Object Name
    }
}

function Get-SmaEncodedSourceOrigins($Ast, [string]$SourceIdentity) {
    $assignments=@($Ast.FindAll({$args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and $args[0].Left -is [System.Management.Automation.Language.VariableExpressionAst]},$true))
    $unwrap={param($node)
        while($true){
            if($node -is [System.Management.Automation.Language.CommandExpressionAst]){$node=$node.Expression;continue}
            if($node -is [System.Management.Automation.Language.PipelineAst] -and $node.PipelineElements.Count -eq 1 -and $node.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]){$node=$node.PipelineElements[0].Expression;continue}
            if($node -is [System.Management.Automation.Language.ParenExpressionAst]){$node=$node.Pipeline;continue}
            return $node
        }
    }
    $resolve={param($variable,[int]$before)
        if($variable -isnot [System.Management.Automation.Language.VariableExpressionAst]){return $null}
        $scope=Get-SmaLexicalScope $variable $SourceIdentity
        $matches=@($assignments | Where-Object { $_.Left.VariablePath.UserPath -ieq $variable.VariablePath.UserPath -and $_.Extent.EndOffset -le $before -and (Get-SmaLexicalScope $_.Left $SourceIdentity) -eq $scope })
        # Require one preceding write in a sequential block enclosing its use. A sibling conditional write does not qualify.
        if($matches.Count -ne 1){return $null}
        $cursor=$variable.Parent;$enclosing=$false
        while($cursor){if([object]::ReferenceEquals($matches[0].Parent,$cursor)){$enclosing=$true;break};$cursor=$cursor.Parent}
        if(-not $enclosing){return $null}
        return & $unwrap $matches[0].Right
    }
    foreach($command in $Ast.FindAll({$args[0] -is [System.Management.Automation.Language.CommandAst]},$true)){
        if($command.GetCommandName() -notin 'powershell','powershell.exe','pwsh','pwsh.exe'){continue}
        for($i=1;$i -lt $command.CommandElements.Count;$i++){
            $parameter=$command.CommandElements[$i]
            if($parameter -isnot [System.Management.Automation.Language.CommandParameterAst] -or $parameter.ParameterName -ine 'EncodedCommand'){continue}
            $argument=$parameter.Argument
            if($null -eq $argument -and $i+1 -lt $command.CommandElements.Count){$argument=$command.CommandElements[$i+1]}
            $encoding=& $resolve $argument $command.Extent.StartOffset
            if($encoding -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst] -or -not $encoding.Static -or $encoding.Expression -isnot [System.Management.Automation.Language.TypeExpressionAst] -or $encoding.Expression.TypeName.GetReflectionType() -ne [Convert] -or $encoding.Member.Value -ine 'ToBase64String' -or $encoding.Arguments.Count -ne 1){continue}
            $getBytes=$encoding.Arguments[0]
            if($getBytes -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst] -or $getBytes.Member.Value -ine 'GetBytes' -or $getBytes.Arguments.Count -ne 1){continue}
            $unicode=$getBytes.Expression
            if($unicode -isnot [System.Management.Automation.Language.MemberExpressionAst] -or -not $unicode.Static -or $unicode.Expression -isnot [System.Management.Automation.Language.TypeExpressionAst] -or $unicode.Expression.TypeName.GetReflectionType() -ne [Text.Encoding] -or $unicode.Member.Value -ine 'Unicode'){continue}
            $literal=& $resolve $getBytes.Arguments[0] $encoding.Extent.StartOffset
            if($literal -is [System.Management.Automation.Language.StringConstantExpressionAst]){
                [pscustomobject]@{Literal=$literal;Consumer=$command;Transform='UTF-16LE then Base64';Target=$command.GetCommandName();Boundary='PowerShellEncodedCommandSource'}
            }
        }
    }
}
function Get-SmaDescription {
    param([string] $root)
    $root = [IO.Path]::GetFullPath($root)
    $project = [SmaProject]::new(); $project.Root = $root; $project.DescribedUtc = [DateTime]::UtcNow
    if ([IO.Directory]::Exists((Join-Path $root '.git'))) { $project.Commit = (git -C $root rev-parse HEAD 2>$null) }
    # Tracked and untracked-but-not-ignored PowerShell files: a working directory's whole source.
    $project.Files = @(Get-SmaSourceFiles $root)
    foreach ($relative in $project.Files) {
        $path = Join-Path $root $relative; $tokens = $errors = $null
        if(-not [IO.File]::Exists($path)){
            $project.Sources.Add([SmaSource]@{Identity=$relative+':missing';File=$relative;Boundary='MissingFile';ParseErrors=@('Tracked source is missing.');Provenance=$project.Commit})
            $project.Diagnostics.Add([pscustomobject]@{Rule='MissingSource';File=$relative;Line=0;Detail='Tracked source is missing; relevant scope is incomplete.'})
            continue
        }
        try {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
            $hash = (Get-FileHash -LiteralPath $path).Hash
        } catch {
            $project.Sources.Add([SmaSource]@{Identity=$relative+':unreadable';File=$relative;Boundary='UnreadableSource';ParseErrors=@($_);Provenance=$project.Commit})
            $project.Diagnostics.Add([pscustomobject]@{Rule='UnreadableSource';File=$relative;Line=0;Detail=$_.Exception.Message;Error=$_})
            continue
        }
        $identity = $relative + ':' + $hash
        $project.Sources.Add([SmaSource]@{ Identity = $identity; File = $relative; Sha256 = $hash; Provenance = $project.Commit
            Ast = $ast; ParseErrors = @($errors); Boundary = 'PowerShellFile' })
        foreach ($errorRecord in $errors) { $project.Diagnostics.Add([pscustomobject]@{ Rule = 'ParseFailure'; File = $relative; Line = $errorRecord.Extent.StartLineNumber; Column = $errorRecord.Extent.StartColumnNumber; Detail = $errorRecord.Message; Ast = $errorRecord.Extent }) }
        Add-SmaDescribedSource $project $relative $ast $false 0 $identity
        $encodedOrigins=@(Get-SmaEncodedSourceOrigins $ast $identity)
        foreach($origin in $encodedOrigins){$project.Relationships.Add([pscustomobject]@{Kind='ExecutableSourceBoundary';File=$relative;Line=$origin.Literal.Extent.StartLineNumber;Source=$origin.Literal;Consumer=$origin.Consumer;Transform=$origin.Transform;Target=$origin.Target;Resolution='Structurally established source construction; execution not observed'})}
        # String literals long enough to be source: parse each; PowerShell with definitions is Embedded, the rest Foreign.
        $literals=@($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $args[0].Value.Length -ge 400 -and $args[0].Value.Contains("`n") }, $true))
        foreach($origin in $encodedOrigins){if(-not @($literals | Where-Object {[object]::ReferenceEquals($_,$origin.Literal)}).Count){$literals+= $origin.Literal}}
        foreach ($literal in $literals) {
            $innerTokens = $innerErrors = $null
            $inner = [System.Management.Automation.Language.Parser]::ParseInput($literal.Value, [ref]$innerTokens, [ref]$innerErrors)
            $definitions = @($inner.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -or $args[0] -is [System.Management.Automation.Language.TypeDefinitionAst] }, $true)).Count
            $holder = $literal.Parent; while ($null -ne $holder -and $holder -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $holder = $holder.Parent }
            $record = [pscustomobject]@{ File = $relative; Line = $literal.Extent.StartLineNumber; EndLine = $literal.Extent.EndLineNumber; Characters = $literal.Value.Length; Text = $literal.Value
                HeldBy = $(if ($holder) { $holder.Name } else { '<script>' }); Definitions = $definitions; ParseErrors = $innerErrors.Count
                Ast = $inner; Container = $literal; Boundary = 'UnclassifiedMultilineLiteral'
                UnresolvedTypes = @($innerErrors | Where-Object ErrorId -eq 'TypeNotFound' | ForEach-Object { $_.Extent.Text.Trim('[', ']') } | Sort-Object -Unique) }
            $nonTypeErrors = @($innerErrors | Where-Object ErrorId -ne 'TypeNotFound').Count
            $encoded=@($encodedOrigins | Where-Object {[object]::ReferenceEquals($_.Literal,$literal)})
            if (($definitions -gt 0 -and $nonTypeErrors -eq 0) -or $encoded.Count) {
                $record.Boundary = if($encoded.Count){'PowerShellEncodedCommandSource'}else{'PowerShellSyntaxCandidate'}
                $project.Embedded.Add($record)
                $innerHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($literal.Value)))
                $innerIdentity = $identity + ':literal:' + $literal.Extent.StartOffset
                $project.Sources.Add([SmaSource]@{ Identity = $innerIdentity; File = $relative; Sha256 = $innerHash; Ast = $inner
                    ParseErrors = @($innerErrors); Embedded = $true; Container = $literal; ParentIdentity = $identity; Boundary = $record.Boundary })
                $offset=$literal.Extent.StartLineNumber-1
                if($literal.StringConstantType -in 'SingleQuotedHereString','DoubleQuotedHereString'){$offset++}
                Add-SmaDescribedSource $project $relative $inner $true $offset $innerIdentity
            } else { $project.Foreign.Add($record) }
        }
        try { foreach ($finding in @(Get-SmaLint $path)) { $finding.File = $relative; $project.Lint.Add($finding) } }
        catch { $project.Diagnostics.Add([pscustomobject]@{ Rule='LintFailure'; File=$relative; Line=0; Detail=$_.Exception.Message; Error=$_ }) }
    }
    Resolve-SmaEdges $project
    $project
}

function Compare-SmaRuntimeGraph($Before, $After) {
    $leftToRight = [Collections.Generic.Dictionary[object,object]]::new([Collections.Generic.ReferenceEqualityComparer]::Instance)
    $rightToLeft = [Collections.Generic.Dictionary[object,object]]::new([Collections.Generic.ReferenceEqualityComparer]::Instance)
    $differences = [Collections.Generic.List[string]]::new()
    $compare = {
        param($left, $right, [string] $path)
        if ($null -eq $left -or $null -eq $right) { if (-not [object]::ReferenceEquals($left,$right)) { $differences.Add($path + ': null mismatch') }; return }
        $leftType = $left.GetType(); $rightType = $right.GetType()
        if ($leftType.Name -cne $rightType.Name) { $differences.Add($path + ': type mismatch'); return }
        if ($leftType.IsPrimitive -or $left -is [string] -or $left -is [decimal] -or $leftType.IsEnum) {
            if (-not $left.Equals($right)) { $differences.Add($path + ': value mismatch') }; return
        }
        if (-not $leftType.IsValueType) {
            if ($leftToRight.ContainsKey($left)) { if (-not [object]::ReferenceEquals($leftToRight.get_Item($left),$right)) { $differences.Add($path + ': shared reference changed') }; return }
            if ($rightToLeft.ContainsKey($right)) { $differences.Add($path + ': distinct references merged'); return }
            $leftToRight.Add($left,$right); $rightToLeft.Add($right,$left)
        }
        if ($left -is [Collections.IEnumerable]) {
            $leftItems = @($left); $rightItems = @($right)
            if ($leftItems.Count -ne $rightItems.Count) { $differences.Add($path + ': collection length changed'); return }
            for ($i=0; $i -lt $leftItems.Count; $i++) { & $compare $leftItems[$i] $rightItems[$i] ($path + '[' + $i + ']') }
            return
        }
        $fields = $leftType.GetFields([Reflection.BindingFlags]'Instance,Public')
        foreach ($field in $fields) {
            $otherField = $rightType.GetField($field.Name)
            if ($null -eq $otherField) { $differences.Add($path + ': missing field ' + $field.Name); continue }
            & $compare ($field.GetValue($left)) ($otherField.GetValue($right)) ($path + '.' + $field.Name)
        }
        if (-not $fields.Count) {
            foreach ($property in $leftType.GetProperties([Reflection.BindingFlags]'Instance,Public') | Where-Object { $_.CanRead -and -not $_.GetIndexParameters().Count }) {
                $otherProperty = $rightType.GetProperty($property.Name)
                if ($null -eq $otherProperty) { $differences.Add($path + ': missing property ' + $property.Name); continue }
                & $compare ($property.GetValue($left)) ($otherProperty.GetValue($right)) ($path + '.' + $property.Name)
            }
        }
    }
    & $compare $Before $After '$'
    [pscustomobject]@{ PSTypeName='Sma.RuntimeGraphComparison'; Equal=($differences.Count -eq 0); ReferencePairs=$leftToRight.Count; Differences=$differences.ToArray() }
}

function Invoke-SmaObservedOperation($Project, [string] $Name, [scriptblock] $Operation, [object[]] $Arguments=@()) {
    $watch=[Diagnostics.Stopwatch]::StartNew()
    try {
        $result=& $Operation @Arguments
        $Project.Observations.Add([pscustomobject]@{ Name=$Name; Ast=$Operation.Ast; StartedUtc=[DateTime]::UtcNow-$watch.Elapsed
            WallMilliseconds=$watch.Elapsed.TotalMilliseconds; Succeeded=$true; Result=$result; Error=$null; Boundary='Explicit invocation only; no filesystem enforcement.' })
        return $result
    } catch {
        $Project.Observations.Add([pscustomobject]@{ Name=$Name; Ast=$Operation.Ast; WallMilliseconds=$watch.Elapsed.TotalMilliseconds
            Succeeded=$false; Result=$null; Error=$_; Boundary='Explicit invocation only; no filesystem enforcement.' })
        throw
    }
}

function Test-SmaDescription {
    param()
    # The fixture is an independent Git repository that exists only for this check; its evidence is the live
    # description returned with each result.
    $directory = Join-Path ([IO.Path]::GetTempPath()) ('PSC-Verify-' + [guid]::NewGuid().ToString('N'))
    $null = [IO.Directory]::CreateDirectory($directory)
    try {
    git init --quiet $directory
    if($LASTEXITCODE){throw 'Could not create an independent Git fixture.'}
    $fixture = @'
class Unrelated { [void] Add([int] $value) {} }
function Entry { $list = [Collections.Generic.List[int]]::new(); $list.Add(1); $target.GetMethod('Ghost').Invoke($null,@()); & $dispatch; Local }
function Local { $Value = 1; $value += 2 }
function Duplicate { 'first' }
function DUPLICATE { 'second' }
function Outer { function Local { 'nested' }; Local }
$unused = { Never }
function Never { 'unused closure target' }
function Types { [int]$slot=1; [string]$SLOT='other' }
function ParameterScope([int]$Token) { $token += 1 }
function OtherParameterScope([string]$TOKEN) { $TOKEN }
$firstObject | Add-Member -MemberType ScriptMethod -Name Evaluate -Value { FirstMethodTarget }
Add-Member -InputObject $secondObject -MemberType ScriptMethod -Name Evaluate -Value { SecondMethodTarget }
$thirdObject | Add-Member -MemberType ScriptMethod -Name $unknownName -Value { UnknownMethodTarget }
$fourthObject | Add-Member -MemberType NoteProperty -Name Evaluate -Value 7
$firstObject.Evaluate(); $secondObject.Evaluate(); $unrelatedObject.Evaluate()
$payloadForFixture = 'Write-Output "inert parser fixture"'
$transportForFixture = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($payloadForFixture))
powershell.exe -EncodedCommand $transportForFixture
if ($flag) { $conditionalPayload = 'Write-Output "conditional parser fixture"' }
$conditionalTransport = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($conditionalPayload))
powershell.exe -EncodedCommand $conditionalTransport
Entry
'@
    [IO.File]::WriteAllText((Join-Path $directory 'untracked.ps1'), $fixture)
    $project = Get-SmaDescription $directory
    $checks = [ordered]@{
        DuplicateDeclarations = @($project.Diagnostics | Where-Object Rule -eq 'DuplicateDeclaration').Count -eq 1
        CaseFoldSymbols = @($project.Diagnostics | Where-Object Rule -eq 'CaseFoldSymbol').Count -ge 1
        ScriptDispatch = $project.Path('<script>untracked.ps1','Entry').Count -eq 2
        NoInventedMemberEdge = $project.Path('Entry','Unrelated.Add').Count -eq 0
        ReflectionUnresolved = @($project.Edges | Where-Object { $_.Kind -eq 'reflection' -and $_.Resolution -ne 'Unresolved' }).Count -eq 0
        DynamicUnresolved = @($project.Edges | Where-Object { $_.Kind -eq 'dynamic-command' -and $_.Resolution -eq 'Unresolved' }).Count -eq 1
        AbsenceLimited = $project.Absent('UnexaminedTarget','Execution').Status -eq 'Unknown'
        DeclarationAbsence = $project.Absent('Ghost','Declarations').Status -eq 'NotFoundWithinScope'
        LiveAstRetained = $project.Sources[0].Ast -is [System.Management.Automation.Language.ScriptBlockAst]
        LocalSourceIncluded = $project.Files -contains 'untracked.ps1'
        ClosureNotExecutedByContainment = $project.Path('<script>untracked.ps1','Never').Count -eq 0
        LexicalBinding = @($project.Edges | Where-Object { $_.From -eq 'Outer' -and $_.To -eq 'Local' -and $_.Resolution -eq 'Bound' -and $_.ToIdentity -eq @($project.Units | Where-Object { $_.Name -eq 'Local' -and $_.Scope -eq @($project.Units | Where-Object Name -eq 'Outer')[0].BodyScope })[0].Identity }).Count -eq 1
        VariableTypeConflicts = @($project.Diagnostics | Where-Object Rule -eq 'MultipleVariableTypes').Count -ge 1
        EncodedSourceEstablishedStructurally = @($project.Relationships | Where-Object Kind -eq 'ExecutableSourceBoundary').Count -eq 1
        ShortExecutableInputRetained = @($project.Sources | Where-Object Boundary -eq 'PowerShellEncodedCommandSource').Count -eq 1
        InlineParameterScope = @($project.Diagnostics | Where-Object { $_.Rule -eq 'CaseFoldSymbol' -and $_.Nodes[0].Scope -eq @($project.Units | Where-Object Name -eq 'ParameterScope')[0].BodyScope }).Count -eq 1
        IndependentParameterScopes = @($project.Diagnostics | Where-Object { $_.Rule -eq 'MultipleVariableTypes' -and @($_.Nodes | Where-Object Name -ieq 'Token').Count }).Count -eq 0
        ScriptMethodAttachments = @($project.Relationships | Where-Object Kind -eq 'ScriptMethodDefinition').Count -eq 2
        ScriptMethodReceiversRetained = @($project.Relationships | Where-Object { $_.Kind -eq 'ScriptMethodDefinition' -and $null -ne $_.ReceiverAst -and $_.ValueIdentity }).Count -eq 2
        ScriptMethodCallsRemainUnresolved = @($project.Edges | Where-Object { $_.To -eq 'Evaluate' -and $_.Resolution -eq 'Unresolved' }).Count -eq 3
    }
    [IO.File]::AppendAllText((Join-Path $directory 'untracked.ps1'), "`n# source revision")
    $checks.SourceInvalidation = $project.Changes().Count -eq 1
    [IO.File]::WriteAllText((Join-Path $directory 'broken.ps1'),'function Broken { 1 + }')
    $broken=Get-SmaDescription $directory
    $checks.ParsePositions = @($broken.Diagnostics | Where-Object { $_.Rule -eq 'ParseFailure' -and $_.Line -eq 1 -and $_.Column -gt 0 }).Count -gt 0
    $checks.ParseFailureLimitsAbsence = $broken.Absent('UnseenDeclaration','Declarations').Status -eq 'Unknown'
    $shared=[int[]]@(4,5);$copy=[int[]]@(4,5)
    $checks.GraphSharedReferences = (Compare-SmaRuntimeGraph ([object[]]@($shared,$shared)) ([object[]]@($copy,$copy))).Equal
    $checks.GraphSplitReferencesRejected = -not (Compare-SmaRuntimeGraph ([object[]]@($shared,$shared)) ([object[]]@([int[]]@(4,5),[int[]]@(4,5)))).Equal
    foreach ($key in $checks.Keys) {
        [pscustomobject]@{ Test = $key; Passed = [bool]$checks[$key]; Evidence = $project }
    }
    if ($checks.Values -contains $false) { throw 'SMA independent structural fixture failed.' }
    }
    finally {
        # The only removal target is the exact directory created above.
        if ([IO.Path]::GetFullPath($directory).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $directory -Recurse -Force
        }
    }
}


# Validate the invocation before parsing source or constructing an assembly. With no arguments the script
# describes its own API (the process block), so there is nothing to validate.
if (-not $Help -and $PSBoundParameters.Count) {
    switch ($Mode) {
        'Compile' {
            if ([string]::IsNullOrEmpty($SourcePath) -and $null -eq $SourceAst) { throw 'Compile requires -SourcePath or -SourceAst.' }
            if ([string]::IsNullOrEmpty($OutputPath)) { throw 'Compile requires -OutputPath.' }
        }
        'Inspect' {
            if ([string]::IsNullOrEmpty($AssemblyPath)) { throw 'Inspect requires -AssemblyPath.' }
        }
        'Link' {
            if ($null -eq $LinkInput -or $LinkInput.Count -eq 0) { throw 'Link requires -LinkInput.' }
            if (-not $ResolveOnly -and [string]::IsNullOrEmpty($OutputPath)) { throw 'Link requires -OutputPath unless -ResolveOnly.' }
        }
    }
}

# Class name -> mirror type for the classes being compiled together; set by
# Export-LoweredAssembly for the duration of one compilation.
$script:LoweringClassTypes = @{}

# Keyword name -> its declaring method, for one compilation.
$script:LoweringKeywords = @{}

# A class in the source deriving from System.Attribute is a marker for other members, not code to compile.
function Test-AttributeClass([System.Management.Automation.Language.TypeDefinitionAst] $Class) {
    $Class.BaseTypes.Count -eq 1 -and (Resolve-AstType $Class.BaseTypes[0].TypeName) -eq [Attribute]
}

# The source declares its own keywords: a static method marked [Keyword()], where Keyword is an attribute
# class in the same source. The method's name is the keyword; its first parameter, a [string], receives the
# statement's name; its further typed parameters are the statement's properties. A keyword with properties
# takes a property table, 'register A { Bits = 8 }'; one without takes a script body, 'lower A { ... }'.
function Get-LoweringKeywords {
    param([System.Management.Automation.Language.Ast] $Root)
    $markers = @($Root.FindAll({ param($n) $n -is [System.Management.Automation.Language.TypeDefinitionAst] -and $n.IsClass -and $n.Name -eq 'Keyword' }, $true) | Where-Object { Test-AttributeClass $_ })
    if ($markers.Count -eq 0) { return }
    $marked = $Root.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionMemberAst] -and
        @($n.Attributes | Where-Object { $_ -is [System.Management.Automation.Language.AttributeAst] -and $_.TypeName.Name -eq 'Keyword' }).Count -gt 0
    }, $true)
    foreach ($method in $marked) {
        $parameters = @($method.Parameters)
        $first = if ($parameters.Count) { $parameters[0].Attributes | Where-Object { $_ -is [System.Management.Automation.Language.TypeConstraintAst] } | Select-Object -First 1 }
        if (-not $method.IsStatic -or -not $first -or (Resolve-AstType $first.TypeName) -ne [string]) {
            throw "[{0}:{1}] Keyword method '{2}' must be static and take the statement's name as its first parameter, a [string]." -f $method.Extent.StartLineNumber, $method.Extent.StartColumnNumber, $method.Name
        }
        [pscustomobject]@{ Name = $method.Name; Class = $method.Parent.Name; Method = $method; Properties = @($parameters | Select-Object -Skip 1) }
    }
}

# Teaches SMA's own parser the keywords (DynamicKeyword), so the source parses to typed
# DynamicKeywordStatementAst nodes. The caller pops the keywords after parsing.
function Enter-LoweringKeywords([object[]] $Definitions) {
    [System.Management.Automation.Language.DynamicKeyword]::Push()
    foreach ($definition in $Definitions) {
        $keyword = [System.Management.Automation.Language.DynamicKeyword]::new()
        $keyword.Keyword = $definition.Name
        $keyword.NameMode = [System.Management.Automation.Language.DynamicKeywordNameMode]::NameRequired
        $keyword.BodyMode = if ($definition.Properties.Count) { [System.Management.Automation.Language.DynamicKeywordBodyMode]::Hashtable } else { [System.Management.Automation.Language.DynamicKeywordBodyMode]::ScriptBlock }
        foreach ($parameter in $definition.Properties) {
            $constraint = $parameter.Attributes | Where-Object { $_ -is [System.Management.Automation.Language.TypeConstraintAst] } | Select-Object -First 1
            $property = [System.Management.Automation.Language.DynamicKeywordProperty]::new()
            $property.Name = $parameter.Name.VariablePath.UserPath
            $property.TypeConstraint = $constraint.TypeName.FullName
            $keyword.Properties.Add($property.Name, $property)
        }
        [System.Management.Automation.Language.DynamicKeyword]::AddKeyword($keyword)
    }
}

function Resolve-AstType {
    <#
    .SYNOPSIS
        Resolves an AST TypeName or string into a concrete CLR Type.
    #>
    param(
        [Parameter(Mandatory)]
        $TypeName
    )

    if ($TypeName -is [Type]) {
        return $TypeName
    }

    # Classes compiled together resolve to their mirror types first, so a
    # same-named PowerShell class loaded in this session is never chosen.
    if ($TypeName -is [System.Management.Automation.Language.TypeName] -or $TypeName -is [string]) {
        $simple = if ($TypeName -is [string]) { $TypeName.Trim().Trim('[', ']') } else { $TypeName.FullName }
        if ($script:LoweringClassTypes -and $script:LoweringClassTypes.ContainsKey($simple)) {
            return $script:LoweringClassTypes[$simple]
        }
    }

    # Generic and array names resolve structurally, so their arguments can be
    # classes compiled together: [System.Collections.Generic.List[ConsoleCell]].
    if ($TypeName -is [System.Management.Automation.Language.GenericTypeName]) {
        $arguments = [Type[]]@($TypeName.GenericArguments | ForEach-Object { Resolve-AstType $_ })
        $definitionName = '{0}`{1}' -f $TypeName.TypeName.FullName, $arguments.Count
        $definition = Resolve-AstType $definitionName
        return $definition.MakeGenericType($arguments)
    }
    if ($TypeName -is [System.Management.Automation.Language.ArrayTypeName]) {
        $element = Resolve-AstType $TypeName.ElementType
        return $(if ($TypeName.Rank -eq 1) { $element.MakeArrayType() } else { $element.MakeArrayType($TypeName.Rank) })
    }

    if ($TypeName -is [System.Management.Automation.Language.ITypeName]) {
        $reflectionType = $TypeName.GetReflectionType()
        if ($null -ne $reflectionType) {
            return $reflectionType
        }
        $nameString = $TypeName.FullName
    }
    elseif ($TypeName -is [string]) {
        $nameString = $TypeName
    }
    else {
        throw "Cannot resolve type from unexpected object of type '$($TypeName.GetType().FullName)'."
    }

    $trimmed = $nameString.Trim()
    if ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']') -and -not $trimmed.EndsWith('[]')) {
        $trimmed = $trimmed.Substring(1, $trimmed.Length - 2).Trim()
    }

    if ($trimmed.EndsWith('[]')) {
        $elemName = $trimmed.Substring(0, $trimmed.Length - 2).Trim()
        $elemType = Resolve-AstType $elemName
        return $elemType.MakeArrayType()
    }

    # Common primitive aliases
    switch ($trimmed.ToLowerInvariant()) {
        'void'    { return [void] }
        'int'     { return [int] }
        'int32'   { return [int] }
        'long'    { return [long] }
        'int64'   { return [long] }
        'short'   { return [short] }
        'int16'   { return [short] }
        'byte'    { return [byte] }
        'sbyte'   { return [sbyte] }
        'uint'    { return [uint] }
        'uint32'  { return [uint] }
        'ulong'   { return [ulong] }
        'uint64'  { return [ulong] }
        'ushort'  { return [ushort] }
        'uint16'  { return [ushort] }
        'float'   { return [single] }
        'single'  { return [single] }
        'double'  { return [double] }
        'bool'    { return [bool] }
        'boolean' { return [bool] }
        'char'    { return [char] }
        'string'  { return [string] }
        'object'  { return [object] }
    }

    $clrType = [Type]::GetType($nameString, $false, $true)
    if ($null -ne $clrType) {
        return $clrType
    }

    # Search loaded assemblies
    foreach ($asm in [AppDomain]::CurrentDomain.GetAssemblies()) {
        $found = $asm.GetType($nameString, $false, $true)
        if ($null -ne $found) {
            return $found
        }
    }

    # PowerShell also resolves abbreviated System namespaces, including open generic definitions.
    if (-not $nameString.StartsWith('System.', [StringComparison]::OrdinalIgnoreCase)) {
        foreach ($asm in [AppDomain]::CurrentDomain.GetAssemblies()) {
            $found = $asm.GetType('System.' + $nameString, $false, $true)
            if ($null -ne $found) { return $found }
        }
    }

    throw "Type '$nameString' could not be resolved to a loaded CLR Type."
}

function Test-AstAdmitted {
    <#
    .SYNOPSIS
        Validates that a PowerShell AST node is within the admitted typed subset.
    .DESCRIPTION
        Rejects pipelines, commands, dynamic resolution, closures, ambient state,
        and unsupported expressions fail-closed with source extent diagnostics.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.Ast] $Ast
    )

    $violations = [System.Collections.Generic.List[pscustomobject]]::new()

    # A lowered unit consists of its compiled classes, not the surrounding
    # PowerShell host script. String throws intentionally lose SMA identity;
    # catches in that unit must not depend on SMA exception inspection.
    $unit = $Ast
    while ($unit.Parent) { $unit = $unit.Parent }
    foreach ($typeAst in $unit.FindAll({ param($n) $n -is [System.Management.Automation.Language.TypeDefinitionAst] }, $true)) {
        foreach ($catchAst in $typeAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true)) {
            foreach ($catchType in $catchAst.CatchTypes) {
                $resolved = Resolve-AstType $catchType.TypeName
                if ($resolved.Assembly.GetName().Name -eq 'System.Management.Automation' -and [Exception].IsAssignableFrom($resolved)) {
                    throw "[$($catchType.Extent.File):$($catchType.Extent.StartLineNumber)] ClrOnly catch cannot filter on an SMA exception type."
                }
            }
            foreach ($read in $catchAst.Body.FindAll({ param($n)
                ($n -is [System.Management.Automation.Language.MemberExpressionAst] -and $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Member.Value -eq 'ErrorRecord') -or
                ($n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -in '_', 'PSItem', 'Error', 'ErrorRecord')
            }, $true)) {
                $target = $read
                if ($target.Parent -is [System.Management.Automation.Language.ConvertExpressionAst]) { $target = $target.Parent }
                if ($target.Parent -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $target.Parent.Operator -eq [System.Management.Automation.Language.TokenKind]::Equals -and
                    [object]::ReferenceEquals($target.Parent.Left, $target)) { continue }
                throw "[$($read.Extent.File):$($read.Extent.StartLineNumber)] ClrOnly catch cannot read ErrorRecord, `$_, `$PSItem or `$Error."
            }
        }
    }

    # Disallowed AST node types in compiled methods
    $disallowed = $Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -or
        ($node -is [System.Management.Automation.Language.PipelineAst] -and $node.PipelineElements.Count -gt 1) -or
        ($node -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -and
            $node.Parent -isnot [System.Management.Automation.Language.DynamicKeywordStatementAst] -and
            -not ($node.Parent -is [System.Management.Automation.Language.SwitchStatementAst] -and
                @($node.Parent.Clauses | Where-Object { [object]::ReferenceEquals($_.Item1, $node) }).Count -eq 1)) -or
        $node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
    }, $true)

    foreach ($bad in $disallowed) {
        $reason = switch ($bad.GetType().Name) {
            'CommandAst' { "Commands and cmdlets are not allowed in compiled methods." }
            'CommandExpressionAst' { "Command expressions are not allowed in compiled methods." }
            'PipelineAst' { "Multi-element pipelines are not allowed in compiled methods." }
            'ScriptBlockExpressionAst' { "Nested script blocks or lambdas are not allowed in compiled methods." }
            'ExpandableStringExpressionAst' { "Expandable double-quoted strings are not allowed; use string concatenation or single-quoted literals." }
            default { "Unsupported AST node '$($bad.GetType().Name)'." }
        }

        $violations.Add([pscustomobject]@{
            File   = $bad.Extent.File
            Line   = $bad.Extent.StartLineNumber
            Column = $bad.Extent.StartColumnNumber
            Text   = $bad.Extent.Text
            Reason = $reason
        })
    }

    if ($violations.Count -gt 0) {
        $msg = ($violations | ForEach-Object {
            "[{0}:{1}] {2} (near '{3}')" -f $_.Line, $_.Column, $_.Reason, $_.Text
        }) -join "`n"
        throw "AST admission failed:`n$msg"
    }

    return
}

$script:NativeImportTypes = [Type[]]@([int], [uint], [long], [ulong], [short], [ushort], [byte], [sbyte], [single], [double], [IntPtr], [UIntPtr])

function Get-AttributeArgumentValue([System.Management.Automation.Language.ExpressionAst] $Argument) {
    # Constants, $true/$false, and static members such as [StringMarshalling]::Utf16.
    if ($Argument -is [System.Management.Automation.Language.MemberExpressionAst] -and $Argument.Static -and
        $Argument.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and
        $Argument.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        $type = Resolve-AstType $Argument.Expression.TypeName
        $field = $type.GetField($Argument.Member.Value, [Reflection.BindingFlags]'Public,Static')
        if ($field) { return $field.GetValue($null) }
        throw "[{0}:{1}] '{2}' is not a static field." -f $Argument.Extent.StartLineNumber, $Argument.Extent.StartColumnNumber, $Argument.Extent.Text
    }
    $Argument.SafeGetValue()
}

function Get-NativeImport {
    <#
    .SYNOPSIS
        Describes a method marked [System.Runtime.InteropServices.LibraryImport],
        or returns nothing for an ordinary method.
    .DESCRIPTION
        A native import is a static method whose body is a single throw, so it
        stays valid PowerShell and fails plainly if run interpreted. Its
        parameters and return are blittable (integers, floating point,
        IntPtr, UIntPtr), and [string] parameters need StringMarshalling Utf8
        or Utf16. SetLastError = $true keeps errno (or the Win32 last error)
        for [Runtime.InteropServices.Marshal]::GetLastPInvokeError().
    #>
    param([Parameter(Mandatory)][System.Management.Automation.Language.FunctionMemberAst] $Function)

    $attribute = $Function.Attributes | Where-Object {
        $_ -is [System.Management.Automation.Language.AttributeAst] -and
        $_.TypeName.FullName -in 'System.Runtime.InteropServices.LibraryImport', 'System.Runtime.InteropServices.LibraryImportAttribute', 'LibraryImport', 'LibraryImportAttribute'
    } | Select-Object -First 1
    if (-not $attribute) { return }

    $where = { param($Message) "[{0}:{1}] Native import '{2}': {3}" -f $Function.Extent.StartLineNumber, $Function.Extent.StartColumnNumber, $Function.Name, $Message }
    if (-not $Function.IsStatic) { throw (& $where 'must be static.') }
    if ($attribute.PositionalArguments.Count -ne 1) { throw (& $where 'needs the library name as its one positional argument.') }
    $statements = @($Function.Body.EndBlock.Statements)
    if ($statements.Count -ne 1 -or $statements[0] -isnot [System.Management.Automation.Language.ThrowStatementAst]) {
        throw (& $where 'its body must be a single throw statement.')
    }

    $import = [ordered]@{
        Library           = [string](Get-AttributeArgumentValue $attribute.PositionalArguments[0])
        EntryPoint        = $Function.Name
        StringMarshalling = [System.Runtime.InteropServices.StringMarshalling]::Custom
        SetLastError      = $false
    }
    $stringMarshallingSet = $false
    foreach ($named in $attribute.NamedArguments) {
        if ($named.ArgumentName -notin 'EntryPoint', 'StringMarshalling', 'SetLastError') {
            throw (& $where "argument '$($named.ArgumentName)' is not supported.")
        }
        $value = if ($named.ExpressionOmitted) { $true } else { Get-AttributeArgumentValue $named.Argument }
        switch ($named.ArgumentName) {
            'EntryPoint'        { $import.EntryPoint = [string]$value }
            'StringMarshalling' { $import.StringMarshalling = [System.Runtime.InteropServices.StringMarshalling]$value; $stringMarshallingSet = $true }
            'SetLastError'      { $import.SetLastError = [bool]$value }
        }
    }

    $return = if ($Function.ReturnType) { Resolve-AstType $Function.ReturnType.TypeName } else { [void] }
    if ($return -ne [void] -and $return -notin $script:NativeImportTypes) { throw (& $where "return type '$($return.FullName)' is not blittable.") }
    $parameterTypes = Get-ParameterTypes $Function
    foreach ($type in $parameterTypes) {
        if ($type -eq [string]) {
            if (-not $stringMarshallingSet -or $import.StringMarshalling -notin 'Utf8', 'Utf16') {
                throw (& $where '[string] parameters need StringMarshalling Utf8 or Utf16.')
            }
            continue
        }
        if ($type -notin $script:NativeImportTypes) { throw (& $where "parameter type '$($type.FullName)' is not blittable.") }
    }
    [pscustomobject]$import
}

function Add-NativeImportMethod {
    # A P/Invoke method on a TypeBuilder: the platform-default calling convention,
    # [string] parameters marshalled as the import's StringMarshalling says.
    # DefinePInvokeMethod cannot set SetLastError; on the persisted builder the
    # DllImport pseudo-attribute replaces the import data with every field
    # (System.Reflection.Emit MethodBuilderImpl.SetCustomAttributeCore,
    # runtime ab19415702aa8139d5369e47c73edb47343c34ad). The mirror's imports
    # are only call targets during lowering, so they never carry it.
    param([Reflection.Emit.TypeBuilder] $TypeBuilder, [string] $Name, $Import, [Type] $ReturnType, [Type[]] $ParameterTypes, [string[]] $ParameterNames, [switch] $Persisted)
    $charSet = if ($Import.StringMarshalling -eq 'Utf16') { [Runtime.InteropServices.CharSet]::Unicode } else { [Runtime.InteropServices.CharSet]::Ansi }
    $method = $TypeBuilder.DefinePInvokeMethod($Name, $Import.Library, $Import.EntryPoint,
        [Reflection.MethodAttributes]'Public,Static,HideBySig,PinvokeImpl', [Reflection.CallingConventions]::Standard,
        $ReturnType, $ParameterTypes, [Runtime.InteropServices.CallingConvention]::Winapi, $charSet)
    $method.SetImplementationFlags([Reflection.MethodImplAttributes]::PreserveSig)
    if ($Persisted -and $Import.SetLastError) {
        $dllImport = [Runtime.InteropServices.DllImportAttribute]
        $fields = [Reflection.FieldInfo[]]@('EntryPoint', 'CharSet', 'CallingConvention', 'SetLastError', 'PreserveSig' | ForEach-Object { $dllImport.GetField($_) })
        $values = [object[]]@($Import.EntryPoint, $charSet, [Runtime.InteropServices.CallingConvention]::Winapi, $true, $true)
        $method.SetCustomAttribute([Reflection.Emit.CustomAttributeBuilder]::new($dllImport.GetConstructor([Type[]]@([string])), [object[]]@($Import.Library), $fields, $values))
    }
    $marshalAs = [Runtime.InteropServices.MarshalAsAttribute].GetConstructor([Type[]]@([Runtime.InteropServices.UnmanagedType]))
    for ($i = 0; $i -lt $ParameterTypes.Length; $i++) {
        $parameter = $method.DefineParameter($i + 1, [Reflection.ParameterAttributes]::None, $ParameterNames[$i])
        if ($ParameterTypes[$i] -eq [string] -and $Import.StringMarshalling -eq 'Utf8') {
            $parameter.SetCustomAttribute([Reflection.Emit.CustomAttributeBuilder]::new($marshalAs, [object[]]@([Runtime.InteropServices.UnmanagedType]::LPUTF8Str)))
        }
    }
    $method
}

# Native expressions retain typed plans for the existing IL emitter.
# No runtime helper or implementation dependency is emitted.
$script:NativeExpressions = [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()

function Get-NativeMethodContract {
    param([System.Management.Automation.Language.FunctionMemberAst] $Function)
    $attrs = @($Function.Attributes | Where-Object {
        $_ -is [System.Management.Automation.Language.AttributeAst] -and
        $_.TypeName.FullName -match '(^|\.)(UnmanagedCallersOnly|UnmanagedCallConv)(Attribute)?$'
    })
    if (-not $attrs.Count) { return }
    $where = '[{0}:{1}] Native method ''{2}'': ' -f $Function.Extent.StartLineNumber, $Function.Extent.StartColumnNumber, $Function.Name
    if ($attrs.Count -ne 1) { throw ($where + 'exactly one native contract is allowed.') }
    $a = $attrs[0]
    if ($a.TypeName.FullName -notin 'UnmanagedCallersOnly','UnmanagedCallersOnlyAttribute','System.Runtime.InteropServices.UnmanagedCallersOnly','System.Runtime.InteropServices.UnmanagedCallersOnlyAttribute',
        'UnmanagedCallConv','UnmanagedCallConvAttribute','System.Runtime.InteropServices.UnmanagedCallConv','System.Runtime.InteropServices.UnmanagedCallConvAttribute') {
        throw ($where + 'native contract must name the CoreLib interop attribute.')
    }
    $kind = if ($a.TypeName.FullName -match 'UnmanagedCallersOnly') { 'Callback' } else { 'Calli' }
    if (-not $Function.IsStatic -or $Function.IsConstructor) { throw ($where + 'must be a static method.') }
    if (Get-NativeImport $Function) { throw ($where + 'cannot also be a library import.') }
    if ($a.PositionalArguments.Count -or $a.NamedArguments.Count -ne 1 -or $a.NamedArguments[0].ArgumentName -cne 'CallConvs') {
        throw ($where + 'requires exactly one explicit CallConvs type (Cdecl or Stdcall).')
    }
    $types = @($a.NamedArguments[0].Argument.FindAll({param($n) $n -is [System.Management.Automation.Language.TypeExpressionAst]},$true))
    $text = $a.NamedArguments[0].Argument.Extent.Text
    if ($types.Count -ne 1 -or $text -notmatch '^\[[\w.]+\]$') { throw ($where + 'CallConvs must be one literal convention type.') }
    $convType = Resolve-AstType $types[0].TypeName
    $conv = if ($convType -eq [Runtime.CompilerServices.CallConvCdecl]) { [Runtime.InteropServices.CallingConvention]::Cdecl }
            elseif ($convType -eq [Runtime.CompilerServices.CallConvStdcall]) { [Runtime.InteropServices.CallingConvention]::StdCall }
            else { throw ($where + 'only Cdecl and Stdcall are supported.') }
    $return = if ($Function.ReturnType) { Resolve-AstType $Function.ReturnType.TypeName } else { [void] }
    $parameters = Get-ParameterTypes $Function
    if ($return -ne [void] -and $return -notin $script:NativeImportTypes) { throw ($where + 'return type must be a blittable scalar.') }
    foreach ($t in $parameters) {
        if ($t -notin $script:NativeImportTypes) { throw ($where + 'parameters must be blittable scalars; bool, char, references and byrefs are not supported.') }
    }
    if ($kind -eq 'Calli') {
        if ($parameters.Count -lt 1 -or $parameters[0] -ne [IntPtr]) { throw ($where + 'first parameter must be IntPtr (native pointer width).') }
        $statements = @($Function.Body.EndBlock.Statements)
        if ($statements.Count -ne 1 -or $statements[0] -isnot [System.Management.Automation.Language.ThrowStatementAst]) { throw ($where + 'indirect-call stub body must be a single throw statement.') }
    }
    [pscustomobject]@{Kind=$kind; Convention=$conv; ConventionType=$convType; ReturnType=$return; ParameterTypes=$parameters}
}

function Set-NativeCallbackAttribute {
    param([Reflection.Emit.MethodBuilder]$Builder,$Contract)
    if ($Contract -and $Contract.Kind -eq 'Callback') {
        $type=[Runtime.InteropServices.UnmanagedCallersOnlyAttribute]
        $Builder.SetCustomAttribute([Reflection.Emit.CustomAttributeBuilder]::new($type.GetConstructor([Type[]]@()), [object[]]@(),
            [Reflection.FieldInfo[]]@($type.GetField('CallConvs')), [object[]]@(,[Type[]]@($Contract.ConventionType))))
    }
}

function Convert-NativeAddressExpression {
    param([System.Management.Automation.Language.InvokeMemberExpressionAst]$Node)
    # Exact form: [LocalClass].GetMethod('UniqueCallback').MethodHandle.GetFunctionPointer().
    if ($Node.Static -or $Node.Member.Extent.Text -cne 'GetFunctionPointer' -or $Node.Arguments) { return }
    $handle=$Node.Expression
    if ($handle -isnot [System.Management.Automation.Language.MemberExpressionAst] -or $handle.Static -or $handle.Member.Extent.Text -cne 'MethodHandle') { return }
    $lookup=$handle.Expression
    if ($lookup -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst] -or $lookup.Static -or
        $lookup.Member.Extent.Text -cne 'GetMethod' -or $lookup.Expression -isnot [System.Management.Automation.Language.TypeExpressionAst] -or
        $lookup.Arguments.Count -ne 1 -or $lookup.Arguments[0] -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { return }
    $where='[{0}:{1}] Function pointer: ' -f $Node.Extent.StartLineNumber,$Node.Extent.StartColumnNumber
    $type=Resolve-AstType $lookup.Expression.TypeName
    if ($type -notin $script:LoweringClassTypes.Values) { throw ($where+'target must be a class in this compilation.') }
    $methods=@($type.GetMethods([Reflection.BindingFlags]'Public,Static,Instance,DeclaredOnly') | Where-Object Name -CEQ $lookup.Arguments[0].Value)
    if ($methods.Count -ne 1 -or -not $methods[0].IsDefined([Runtime.InteropServices.UnmanagedCallersOnlyAttribute],$false)) { throw ($where+'target must be one unambiguous UnmanagedCallersOnly method.') }
    $method=$methods[0]
    if ($Mode -eq 'Expression') { throw ($where+'native address acquisition requires Compile mode.') }
    if ($script:IlMap.Members.Count -and -not $script:IlMap.Members.ContainsKey($method)) { throw ($where+'callback target was omitted from this compilation.') }
    $constant=[Linq.Expressions.Expression]::Constant($method,[Reflection.MethodInfo])
    $expr=[Linq.Expressions.Expression]::Call([Linq.Expressions.Expression]::Property($constant,'MethodHandle'),[RuntimeMethodHandle].GetMethod('GetFunctionPointer',[Type[]]@()))
    $script:NativeExpressions.Add($expr,[pscustomobject]@{Kind='Address';Method=$method})
    $expr
}

function Get-ClassModel {
    <#
    .SYNOPSIS
        Describes the classes compiled together: properties, constructors and methods.
    #>
    param([Parameter(Mandatory)][System.Management.Automation.Language.TypeDefinitionAst[]] $ClassAsts)

    foreach ($class in $ClassAsts) {
        $properties = @($class.Members | Where-Object { $_ -is [System.Management.Automation.Language.PropertyMemberAst] })
        $functions = @($class.Members | Where-Object { $_ -is [System.Management.Automation.Language.FunctionMemberAst] })
        foreach ($p in $properties) {
            if (-not $p.PropertyType) {
                throw "[{0}:{1}] Property `${2} of class {3} needs a type." -f $p.Extent.StartLineNumber, $p.Extent.StartColumnNumber, $p.Name, $class.Name
            }
        }
        foreach ($f in $functions) { $null = Get-NativeMethodContract $f }
        if ($class.BaseTypes.Count) {
            throw "[{0}:{1}] Class {2} derives from another type; only classes deriving from System.Object are supported." -f `
                $class.Extent.StartLineNumber, $class.Extent.StartColumnNumber, $class.Name
        }
        [pscustomobject]@{
            Name         = $class.Name
            Ast          = $class
            Properties   = $properties
            Constructors  = @($functions | Where-Object IsConstructor)
            Methods       = @($functions | Where-Object { -not $_.IsConstructor -and -not (Get-NativeImport -Function $_) })
            NativeImports = @($functions | Where-Object { -not $_.IsConstructor } | ForEach-Object {
                $import = Get-NativeImport -Function $_
                if ($import) { [pscustomobject]@{ Ast = $_; Import = $import } }
            })
        }
    }
}

function Get-ParameterTypes([System.Management.Automation.Language.FunctionMemberAst] $Function) {
    , [Type[]]@($Function.Parameters | ForEach-Object {
        $tc = $_.Attributes | Where-Object { $_ -is [System.Management.Automation.Language.TypeConstraintAst] } | Select-Object -First 1
        if (-not $tc) {
            throw "[{0}:{1}] Parameter `${2} needs a type." -f $_.Extent.StartLineNumber, $_.Extent.StartColumnNumber, $_.Name.VariablePath.UserPath
        }
        Resolve-AstType $tc.TypeName
    })
}

function New-ClassMirror {
    <#
    .SYNOPSIS
        Defines every class's shape as a real runtime type in a collectible
        in-memory assembly, so method bodies can be lowered against it.
    .DESCRIPTION
        Expression factories validate members by reflection, which classes
        still being emitted cannot answer. The mirror has the same fields,
        constructors and method signatures; its bodies only throw. The emitter
        maps each mirror member to the output assembly's member.
        Registers the mirror types for Resolve-AstType.
    #>
    param([Parameter(Mandatory)][object[]] $Model, [System.Management.Automation.Language.TypeDefinitionAst[]] $Enums = @())

    $name = [Reflection.AssemblyName]::new("PSLoweringMirror$([Guid]::NewGuid().ToString('N'))")
    $assembly = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly($name, [Reflection.Emit.AssemblyBuilderAccess]::RunAndCollect)
    $module = $assembly.DefineDynamicModule($name.Name)
    $notSupported = [NotSupportedException].GetConstructor([Type[]]@())
    $objectCtor = [object].GetConstructor([Type[]]@())

    # Enums declared in the source are real enums here, before any class names them.
    foreach ($enumAst in $Enums) {
        $enumBuilder = $module.DefineEnum($enumAst.Name, [Reflection.TypeAttributes]::Public, (Get-EnumUnderlyingType $enumAst))
        foreach ($literal in (Get-EnumLiterals $enumAst)) { $null = $enumBuilder.DefineLiteral($literal.Name, $literal.Value) }
        $script:LoweringClassTypes[$enumAst.Name] = $enumBuilder.CreateType()
    }

    $builders = [ordered]@{}
    foreach ($c in $Model) {
        $builders[$c.Name] = $module.DefineType($c.Name, [Reflection.TypeAttributes]'Public,Class')
        $script:LoweringClassTypes[$c.Name] = $builders[$c.Name]
    }

    function Write-ThrowBody([Reflection.Emit.ILGenerator] $IL) {
        $IL.Emit([Reflection.Emit.OpCodes]::Newobj, $notSupported)
        $IL.Emit([Reflection.Emit.OpCodes]::Throw)
    }

    foreach ($c in $Model) {
        $tb = $builders[$c.Name]
        foreach ($p in $c.Properties) {
            $attributes = [Reflection.FieldAttributes]::Public
            if ($p.IsStatic) { $attributes = $attributes -bor [Reflection.FieldAttributes]::Static }
            $null = $tb.DefineField($p.Name, (Resolve-AstType $p.PropertyType.TypeName), $attributes)
        }
        $constructors = @($null)
        if ($c.Constructors.Count) { $constructors = @($c.Constructors) }
        foreach ($ctorAst in $constructors) {
            [Type[]]$constructorParameterTypes = @()
            if ($ctorAst) { $constructorParameterTypes = Get-ParameterTypes $ctorAst }
            $cb = $tb.DefineConstructor([Reflection.MethodAttributes]'Public,HideBySig,SpecialName,RTSpecialName',
                [Reflection.CallingConventions]::Standard, $constructorParameterTypes)
            $il = $cb.GetILGenerator()
            $il.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
            $il.Emit([Reflection.Emit.OpCodes]::Call, $objectCtor)
            Write-ThrowBody $il
        }
        foreach ($n in $c.NativeImports) {
            $return = if ($n.Ast.ReturnType) { Resolve-AstType $n.Ast.ReturnType.TypeName } else { [void] }
            $names = [string[]]@($n.Ast.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
            $null = Add-NativeImportMethod -TypeBuilder $tb -Name $n.Ast.Name -Import $n.Import -ReturnType $return -ParameterTypes (Get-ParameterTypes $n.Ast) -ParameterNames $names
        }
        foreach ($m in $c.Methods) {
            $attributes = [Reflection.MethodAttributes]'Public,HideBySig'
            $attributes = $attributes -bor $(if ($m.IsStatic) { [Reflection.MethodAttributes]::Static } else { [Reflection.MethodAttributes]::Virtual })
            $return = if ($m.ReturnType) { Resolve-AstType $m.ReturnType.TypeName } else { [void] }
            $mb = $tb.DefineMethod($m.Name, $attributes, $return, (Get-ParameterTypes $m))
            Set-NativeCallbackAttribute -Builder $mb -Contract (Get-NativeMethodContract $m)
            Write-ThrowBody $mb.GetILGenerator()
        }
    }

    foreach ($c in $Model) {
        $script:LoweringClassTypes[$c.Name] = $builders[$c.Name].CreateType()
    }
    $types = [ordered]@{}
    foreach ($enumAst in $Enums) { $types[$enumAst.Name] = $script:LoweringClassTypes[$enumAst.Name] }
    foreach ($c in $Model) { $types[$c.Name] = $script:LoweringClassTypes[$c.Name] }
    $types
}

# An enum's underlying type: its declared base, or Int32.
function Get-EnumUnderlyingType([System.Management.Automation.Language.TypeDefinitionAst] $EnumAst) {
    if ($EnumAst.BaseTypes.Count) { return Resolve-AstType $EnumAst.BaseTypes[0].TypeName }
    [int]
}

# An enum's members and values, numbered as PowerShell numbers them: a member without a value is the previous one plus one.
function Get-EnumLiterals([System.Management.Automation.Language.TypeDefinitionAst] $EnumAst) {
    $underlying = Get-EnumUnderlyingType $EnumAst
    [long] $next = 0
    foreach ($member in $EnumAst.Members) {
        $value = if ($member.InitialValue) { [long]$member.InitialValue.SafeGetValue() } else { $next }
        $next = $value + 1
        [pscustomobject]@{ Name = $member.Name; Value = [Convert]::ChangeType($value, $underlying) }
    }
}

$script:ClassMirrorCache = [System.Runtime.CompilerServices.ConditionalWeakTable[object, hashtable]]::new()

function Use-ClassMirror {
    <#
    .SYNOPSIS
        Makes the classes of the source an AST belongs to resolvable: builds
        their mirror once per parsed source and registers it for Resolve-AstType.
    #>
    param([Parameter(Mandatory)][System.Management.Automation.Language.Ast] $Ast)
    $root = $Ast
    while ($root.Parent) { $root = $root.Parent }
    $types = Get-ClassMirrorType -Root $root
    $semanticsRoot = Get-PscSemanticsClass
    while ($semanticsRoot.Parent) { $semanticsRoot = $semanticsRoot.Parent }
    if ($root -ne $semanticsRoot -and -not $types.ContainsKey('PowerShellSemantics')) {
        $types = $types + (Get-ClassMirrorType -Root $semanticsRoot)
    }
    $script:LoweringClassTypes = @{} + $types
}

# The mirror types of the classes and enums under one root, built once per root.
function Get-ClassMirrorType {
    param([Parameter(Mandatory)][System.Management.Automation.Language.ScriptBlockAst] $Root)
    $types = $null
    if (-not $script:ClassMirrorCache.TryGetValue($Root, [ref]$types)) {
        $classes = @($Root.FindAll({ param($n) $n -is [System.Management.Automation.Language.TypeDefinitionAst] -and $n.IsClass }, $true) | Where-Object { -not (Test-AttributeClass $_) })
        $enums = @($Root.FindAll({ param($n) $n -is [System.Management.Automation.Language.TypeDefinitionAst] -and $n.IsEnum }, $true))
        $script:LoweringClassTypes = @{}
        $mirror = New-ClassMirror -Model @(Get-ClassModel -ClassAsts $classes) -Enums $enums
        $types = @{}
        foreach ($name in $mirror.Keys) { $types[$name] = $mirror[$name] }
        $script:ClassMirrorCache.Add($Root, $types)
    }
    $types
}

# PowerShellSemantics' definition, read once from this script's AST and copied into a root of its own, so its methods
# lower like any class's and every compile can include it. It has no constructor, so its copy is faithful (SMA's Copy()
# of a constructor loses its implicit base call's node type).
function Get-PscSemanticsClass {
    if ($null -eq $script:PscSemanticsAst) {
        $tokens = $null; $errors = $null
        $own = [System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$tokens, [ref]$errors)
        $definition = $own.Find({ param($n) $n -is [System.Management.Automation.Language.TypeDefinitionAst] -and $n.Name -eq 'PowerShellSemantics' }, $true)
        $block = [System.Management.Automation.Language.StatementBlockAst]::new($definition.Extent, [System.Management.Automation.Language.StatementAst[]]@($definition.Copy()), [System.Management.Automation.Language.TrapStatementAst[]]@())
        $root = [System.Management.Automation.Language.ScriptBlockAst]::new($definition.Extent, $null, $block, $false)
        $script:PscSemanticsAst = $root.Find({ param($n) $n -is [System.Management.Automation.Language.TypeDefinitionAst] }, $true)
    }
    $script:PscSemanticsAst
}

$script:ExpressionNewMethod = [Linq.Expressions.Expression].GetMethod(
    'New',
    [Type[]]@([Reflection.ConstructorInfo], [System.Collections.Generic.IEnumerable[Linq.Expressions.Expression]])
)

# PowerShell's numeric semantics, expressed with CLR operations only. The
# PowerShell parity check (tests/parity/PowerShellParity.ps1) checks
# every rule here against PowerShell itself.
$script:IntegralTypes = [Type[]]@([int], [long], [short], [sbyte], [byte], [ushort], [uint], [ulong])
$script:FloatingTypes = [Type[]]@([double], [single])

function ConvertTo-PowerShellType {
    <#
    .SYNOPSIS
        Converts an expression to a type the way a PowerShell typed assignment,
        cast, argument or return does.
    .DESCRIPTION
        Floating to integral rounds half to even and throws OverflowException
        when out of range or NaN (System.Convert, as PowerShell's numeric
        conversion does). Integral narrowing throws on overflow. A reference
        (an [object], a [string]) converts to a number or [char] through
        System.Convert with the invariant culture: boxed numbers, $null,
        $true/$false and plain numeric text match PowerShell; text PowerShell
        reads but Convert does not ('0x10', '1e3', '5.5') throws instead of
        producing a different value. A reference to [bool] stays an unboxing
        conversion, because PowerShell's [bool]'false' is $true and
        Convert.ToBoolean's is not. Other conversions are plain CLR conversions.
    #>
    param(
        [Parameter(Mandatory)][Linq.Expressions.Expression] $Expression,
        [Parameter(Mandatory)][Type] $Type
    )
    $from = $Expression.Type
    if ($from -eq $Type) { return $Expression }
    if ($Type -eq [void]) { return [Linq.Expressions.Expression]::Block($Expression, [Linq.Expressions.Expression]::Empty()) }
    if ($from -in $script:IntegralTypes -and $Type -eq [char]) {
        # PowerShell's integral-to-Char cast checks the UTF-16 code-unit range.
        # A plain conv.u2 would silently truncate negative or oversized values.
        $convert = [Convert].GetMethod('ToChar', [Type[]]@($from))
        return [Linq.Expressions.Expression]::Call($convert, $Expression)
    }
    if ($from -in $script:FloatingTypes -and $Type -in $script:IntegralTypes) {
        $convert = [Convert].GetMethod("To$($Type.Name)", [Type[]]@($from))
        return [Linq.Expressions.Expression]::Call($convert, $Expression)
    }
    if ($from -in $script:IntegralTypes -and $Type -in $script:IntegralTypes) {
        return [Linq.Expressions.Expression]::ConvertChecked($Expression, $Type)
    }
    if (-not $from.IsValueType -and ($Type -in $script:IntegralTypes -or $Type -in $script:FloatingTypes -or $Type -eq [char])) {
        $convert = [Convert].GetMethod("To$($Type.Name)", [Type[]]@([object], [IFormatProvider]))
        $culture = [Linq.Expressions.Expression]::Property($null, [Globalization.CultureInfo].GetProperty('InvariantCulture'))
        $boxed = if ($from -eq [object]) { $Expression } else { [Linq.Expressions.Expression]::Convert($Expression, [object]) }
        return [Linq.Expressions.Expression]::Call($convert, $boxed, $culture)
    }
    [Linq.Expressions.Expression]::Convert($Expression, $Type)
}

function New-PowerShellStringComparison {
    <#
    .SYNOPSIS
        Compares two strings as PowerShell's comparison operators do: through
        the invariant culture's CompareInfo, ignoring case unless the operator
        is case-sensitive (SMA LanguagePrimitives.Equals and Compare).
    #>
    param(
        [Parameter(Mandatory)][Linq.Expressions.Expression] $Left,
        [Parameter(Mandatory)][Linq.Expressions.Expression] $Right,
        [Parameter(Mandatory)][bool] $CaseSensitive
    )
    $culture = [Linq.Expressions.Expression]::Property($null, [Globalization.CultureInfo].GetProperty('InvariantCulture'))
    $compareInfo = [Linq.Expressions.Expression]::Property($culture, 'CompareInfo')
    $compare = [Globalization.CompareInfo].GetMethod('Compare', [Type[]]@([string], [string], [Globalization.CompareOptions]))
    $options = if ($CaseSensitive) { [Globalization.CompareOptions]::None } else { [Globalization.CompareOptions]::IgnoreCase }
    [Linq.Expressions.Expression]::Call($compareInfo, $compare, $Left, $Right,
        [Linq.Expressions.Expression]::Constant($options, [Globalization.CompareOptions]))
}

function New-PowerShellArithmetic {
    <#
    .SYNOPSIS
        Integral +, -, * fail on overflow where PowerShell would leave the
        type (in a typed method PowerShell then fails converting back).
        Integral / divides as Double, as PowerShell does, after failing on a
        zero divisor. Floating arithmetic is plain IEEE 754.
    #>
    param(
        [Parameter(Mandatory)][string] $Operator,
        [Parameter(Mandatory)][Linq.Expressions.Expression] $Left,
        [Parameter(Mandatory)][Linq.Expressions.Expression] $Right
    )
    if ($Left.Type -eq [string]) {
        if ($Operator -ne 'Plus') { throw "Operator '$Operator' is not defined for strings." }
        $concat = [string].GetMethod('Concat', [Type[]]@([string], [string]))
        return [Linq.Expressions.Expression]::Call($concat, $Left, $Right)
    }
    $integral = $Left.Type -in $script:IntegralTypes
    switch ($Operator) {
        'Plus'     { if ($integral) { return [Linq.Expressions.Expression]::AddChecked($Left, $Right) }; return [Linq.Expressions.Expression]::Add($Left, $Right) }
        'Minus'    { if ($integral) { return [Linq.Expressions.Expression]::SubtractChecked($Left, $Right) }; return [Linq.Expressions.Expression]::Subtract($Left, $Right) }
        'Multiply' { if ($integral) { return [Linq.Expressions.Expression]::MultiplyChecked($Left, $Right) }; return [Linq.Expressions.Expression]::Multiply($Left, $Right) }
        'Rem'      { return [Linq.Expressions.Expression]::Modulo($Left, $Right) }
        'Divide' {
            if (-not $integral) { return [Linq.Expressions.Expression]::Divide($Left, $Right) }
            $zero = [Linq.Expressions.Expression]::Constant([Convert]::ChangeType(0, $Right.Type), $Right.Type)
            $throw = [Linq.Expressions.Expression]::Throw(
                $script:ExpressionNewMethod.Invoke($null, [object[]]@([DivideByZeroException].GetConstructor([Type[]]@()), [Linq.Expressions.Expression[]]@())), [double])
            $quotient = [Linq.Expressions.Expression]::Divide(
                [Linq.Expressions.Expression]::Convert($Left, [double]),
                [Linq.Expressions.Expression]::Convert($Right, [double]))
            return [Linq.Expressions.Expression]::Condition(
                [Linq.Expressions.Expression]::Equal($Right, $zero), $throw, $quotient)
        }
    }
}

# [int]($a / $b), or a typed target taking one, where $a and $b are Int32 or UInt32 (narrower integers widen to Int32).
# PowerShell divides them as Double and rounds the quotient half to even into the integral type. Double holds every
# such quotient and every half exactly, so the same value comes from integer arithmetic: the truncated quotient and
# the remainder in Int64, stepped away from zero when twice the remainder passes the divisor, or equals it with an
# odd quotient. No floating point and no call; a zero divisor throws DivideByZeroException as PowerShell does.
# $null when the node is not such a quotient, and the Double path applies.
function ConvertTo-IntegralQuotient {
    param(
        [Parameter(Mandatory)][System.Management.Automation.Language.Ast] $Node,
        [Parameter(Mandatory)][Type] $Type,
        [Parameter(Mandatory)][hashtable] $Scope
    )
    if ($Type -notin $script:IntegralTypes) { return $null }
    $inner = $Node
    while ($true) {
        if ($inner -is [System.Management.Automation.Language.ParenExpressionAst]) { $inner = $inner.Pipeline; continue }
        if ($inner -is [System.Management.Automation.Language.PipelineAst] -and $inner.PipelineElements.Count -eq 1 -and
            $inner.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) { $inner = $inner.PipelineElements[0].Expression; continue }
        break
    }
    if ($inner -isnot [System.Management.Automation.Language.BinaryExpressionAst] -or $inner.Operator -ne 'Divide') { return $null }
    $bound = $script:PscEnvironment.Get('NumericOperands').Bind([PscOperatorKind]::Arithmetic,
        (Convert-AstExpression -Node $inner.Left -Scope $Scope), (Convert-AstExpression -Node $inner.Right -Scope $Scope))
    if ($null -eq $bound -or $bound.Left.Type -notin [int], [uint32]) { return $null }
    $semantics = $script:LoweringClassTypes['PowerShellSemantics']
    if ($null -eq $semantics) { throw 'PowerShellSemantics is not part of this compile; Export-LoweredAssembly composes it into every one.' }
    $rounded = [Linq.Expressions.Expression]::Call($semantics.GetMethod('RoundedQuotient'),
        [Linq.Expressions.Expression]::Convert($bound.Left, [long]), [Linq.Expressions.Expression]::Convert($bound.Right, [long]))
    ConvertTo-PowerShellType -Expression $rounded -Type $Type
}

# A copy of a using statement. SMA's UsingStatementAst.Copy() reuses its Name child for a statement without an alias
# (using namespace System.IO), so it always throws there; the public constructor builds the copy from a copied Name.
function Copy-UsingStatement {
    param([Parameter(Mandatory)][System.Management.Automation.Language.UsingStatementAst] $Using)
    if ($null -eq $Using.Alias -and $null -eq $Using.ModuleSpecification -and $null -ne $Using.Name) {
        return [System.Management.Automation.Language.UsingStatementAst]::new($Using.Extent, $Using.UsingStatementKind, $Using.Name.Copy())
    }
    $Using.Copy()
}


function Get-AstArrayElements($node) {
    if ($node -is [System.Management.Automation.Language.ArrayLiteralAst]) {
        return @($node.Elements)
    }
    if ($node -is [System.Management.Automation.Language.ArrayExpressionAst]) {
        if ($node.SubExpression -and $node.SubExpression.Statements.Count -gt 0) {
            $first = $node.SubExpression.Statements[0]
            if ($first -is [System.Management.Automation.Language.PipelineAst] -and
                $first.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst] -and
                $first.PipelineElements[0].Expression -is [System.Management.Automation.Language.ArrayLiteralAst]) {
                return @($first.PipelineElements[0].Expression.Elements)
            }
            if ($first -is [System.Management.Automation.Language.PipelineAst] -and
                $first.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) {
                return @($first.PipelineElements[0].Expression)
            }
        }
    }
    return @($node)
}

function New-PowerShellArrayIndex {
    <#
    .SYNOPSIS
        Array element access with PowerShell's index rule: a negative index
        counts from the end ($a[-1] is the last element). Returns the setup
        expressions and the element access; the array and index are evaluated
        once.
    #>
    param(
        [Parameter(Mandatory)][Linq.Expressions.Expression] $Array,
        [Parameter(Mandatory)][Linq.Expressions.Expression] $Index,
        [Parameter(Mandatory)][hashtable] $Scope
    )
    $setup = [System.Collections.Generic.List[Linq.Expressions.Expression]]::new()
    if ($Index.Type -ne [int]) { $Index = ConvertTo-PowerShellType -Expression $Index -Type ([int]) }
    # A list (any type with an Int32 indexer and a Count) follows the same rule as an array: PowerShell counts a
    # negative index from the end of an IList too.
    $indexer = if ($Array.Type.IsArray) { $null } else { Get-IntIndexer $Array.Type }
    $access = { param($target, $at) if ($indexer) { [Linq.Expressions.Expression]::MakeIndex($target, $indexer, [Linq.Expressions.Expression[]]@($at)) } else { [Linq.Expressions.Expression]::ArrayAccess($target, $at) } }
    if ($Index -is [Linq.Expressions.ConstantExpression] -and [int]$Index.Value -ge 0) {
        return [pscustomobject]@{ Setup = $setup; Access = (& $access $Array $Index) }
    }
    $id = $Scope.DeclaredLocals.Count
    if ($Array -isnot [Linq.Expressions.ParameterExpression]) {
        $arrayTemp = [Linq.Expressions.Expression]::Variable($Array.Type, "indexArray$id")
        $Scope.DeclaredLocals.Add($arrayTemp)
        $setup.Add([Linq.Expressions.Expression]::Assign($arrayTemp, $Array))
        $Array = $arrayTemp
    }
    if ($Index -isnot [Linq.Expressions.ParameterExpression]) {
        $indexTemp = [Linq.Expressions.Expression]::Variable([int], "indexValue$id")
        $Scope.DeclaredLocals.Add($indexTemp)
        $setup.Add([Linq.Expressions.Expression]::Assign($indexTemp, $Index))
        $Index = $indexTemp
    }
    $length = if ($indexer) { [Linq.Expressions.Expression]::Property($Array, 'Count') } else { [Linq.Expressions.Expression]::ArrayLength($Array) }
    $adjusted = [Linq.Expressions.Expression]::Condition(
        [Linq.Expressions.Expression]::LessThan($Index, [Linq.Expressions.Expression]::Constant(0)),
        [Linq.Expressions.Expression]::Add($Index, $length),
        $Index)
    [pscustomobject]@{ Setup = $setup; Access = (& $access $Array $adjusted) }
}

# A type's default indexer (Item) taking one key that the index converts to: exact type first, then any
# integer-to-integer match. $null when the type has none.
function Get-KeyIndexer([Type] $Type, [Type] $IndexType) {
    $candidates = @($Type.GetProperties() | Where-Object { $_.Name -eq 'Item' -and $_.GetIndexParameters().Count -eq 1 })
    foreach ($property in $candidates) { if ($property.GetIndexParameters()[0].ParameterType.IsAssignableFrom($IndexType)) { return $property } }
    foreach ($property in $candidates) {
        $parameterType = $property.GetIndexParameters()[0].ParameterType
        if ($parameterType -in $script:IntegralTypes -and $IndexType -in $script:IntegralTypes) { return $property }
    }
    $null
}

function Get-IntIndexer([Type] $Type) {
    # The default indexer taking one Int32, on a type that also exposes an Int32 Count (List[T], IList[T]).
    $count = $Type.GetProperty('Count', [Type[]]@())
    if ($null -eq $count -or $count.PropertyType -ne [int]) { return $null }
    foreach ($property in $Type.GetProperties()) {
        $parameters = $property.GetIndexParameters()
        if ($property.Name -eq 'Item' -and $parameters.Count -eq 1 -and $parameters[0].ParameterType -eq [int]) { return $property }
    }
    $null
}

function Convert-AstExpressionAs {
    param(
        [Parameter(Mandatory)][System.Management.Automation.Language.Ast] $Node,
        [Parameter(Mandatory)][Type] $Type,
        [Parameter(Mandatory)][hashtable] $Scope
    )
    $inner = $Node
    while ($inner -is [System.Management.Automation.Language.PipelineAst] -and $inner.PipelineElements.Count -eq 1 -and
           $inner.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) {
        $inner = $inner.PipelineElements[0].Expression
    }
    if ($Type.IsArray -and ($inner -is [System.Management.Automation.Language.ArrayExpressionAst] -or
                            $inner -is [System.Management.Automation.Language.ArrayLiteralAst])) {
        $elementType = $Type.GetElementType()
        $items = [System.Collections.Generic.List[Linq.Expressions.Expression]]::new()
        foreach ($element in Get-AstArrayElements $inner) {
            $items.Add((Convert-AstExpressionAs -Node $element -Type $elementType -Scope $Scope))
        }
        return [Linq.Expressions.Expression]::NewArrayInit($elementType, [Linq.Expressions.Expression[]]$items.ToArray())
    }
    $quotient = ConvertTo-IntegralQuotient -Node $Node -Type $Type -Scope $Scope
    if ($null -ne $quotient) { return $quotient }
    $value = Convert-AstExpression -Node $Node -Scope $Scope
    if ($value.Type -eq $Type) { return $value }
    if ($value -is [Linq.Expressions.ConstantExpression] -and $null -eq $value.Value -and -not $Type.IsValueType) {
        return [Linq.Expressions.Expression]::Constant($null, $Type)
    }
    ConvertTo-PowerShellType -Expression $value -Type $Type
}

# A PowerShell custom object is an SMA PSObject over PSCustomObject whose members are note properties in the
# order they were written. Compiled code builds and uses it through SMA's own PSObject API, so its Extended Type
# System behaviour (ordering, type identity, formatting, later Add-Member) is PowerShell's, not an imitation.
function New-PowerShellCustomObject {
    param([Parameter(Mandatory)][System.Management.Automation.Language.HashtableAst] $Table, [Parameter(Mandatory)][hashtable] $Scope)
    $object = [Linq.Expressions.Expression]::Variable([System.Management.Automation.PSObject], "customObject$($Scope.DeclaredLocals.Count)")
    $Scope.DeclaredLocals.Add($object)
    $parts = [System.Collections.Generic.List[Linq.Expressions.Expression]]::new()
    $parts.Add([Linq.Expressions.Expression]::Assign($object, $script:ExpressionNewMethod.Invoke($null, @([System.Management.Automation.PSObject].GetConstructor([Type[]]@()), [Linq.Expressions.Expression[]]@()))))
    $noteConstructor = [System.Management.Automation.PSNoteProperty].GetConstructor([Type[]]@([string], [object]))
    $properties = [Linq.Expressions.Expression]::Property($object, 'Properties')
    $add = $properties.Type.GetMethod('Add', [Type[]]@([System.Management.Automation.PSPropertyInfo]))
    foreach ($pair in $Table.KeyValuePairs) {
        $value = Convert-AstExpression -Node $pair.Item2 -Scope $Scope
        if ($value.Type -ne [object]) { $value = [Linq.Expressions.Expression]::Convert($value, [object]) }
        $note = $script:ExpressionNewMethod.Invoke($null, @($noteConstructor, [Linq.Expressions.Expression[]]@([Linq.Expressions.Expression]::Constant([string]$pair.Item1.SafeGetValue()), $value)))
        $parts.Add([Linq.Expressions.Expression]::Call($properties, $add, [Linq.Expressions.Expression]$note))
    }
    $parts.Add($object)
    [Linq.Expressions.Expression]::Block([System.Management.Automation.PSObject], [Linq.Expressions.Expression[]]$parts.ToArray())
}

# True when an expression is the intrinsic .PSObject member: PowerShell's view of the wrapper as an ordinary object.
function Test-PSObjectView([System.Management.Automation.Language.Ast] $Node) {
    $Node -is [System.Management.Automation.Language.MemberExpressionAst] -and
    $Node -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst] -and -not $Node.Static -and
    $Node.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $Node.Member.Value -eq 'PSObject'
}

# The note property of a PSObject by name: the PSPropertyInfo, or $null when it has none.
function Get-PowerShellNoteProperty([Linq.Expressions.Expression] $Target, [string] $Name) {
    $properties = [Linq.Expressions.Expression]::Property($Target, 'Properties')
    [Linq.Expressions.Expression]::Call($properties, $properties.Type.GetMethod('get_Item', [Type[]]@([string])), [Linq.Expressions.Expression]::Constant($Name))
}

# $object.Name on a PSObject: the property's value, or $null when it has none (PowerShell outside strict mode).
function New-PowerShellNotePropertyRead {
    param([Linq.Expressions.Expression] $Target, [string] $Name, [hashtable] $Scope)
    $property = [Linq.Expressions.Expression]::Variable([System.Management.Automation.PSPropertyInfo], "noteProperty$($Scope.DeclaredLocals.Count)")
    $Scope.DeclaredLocals.Add($property)
    [Linq.Expressions.Expression]::Block([object], [Linq.Expressions.Expression[]]@(
        [Linq.Expressions.Expression]::Assign($property, (Get-PowerShellNoteProperty $Target $Name)),
        [Linq.Expressions.Expression]::Condition(
            [Linq.Expressions.Expression]::Equal($property, [Linq.Expressions.Expression]::Constant($null, [System.Management.Automation.PSPropertyInfo])),
            [Linq.Expressions.Expression]::Constant($null, [object]),
            [Linq.Expressions.Expression]::Property($property, 'Value'))))
}

function New-MemberAccess {
    # $target.Name or [Type]::Name as a field or property expression.
    param([Linq.Expressions.Expression] $Target, [Type] $Type, [string] $Name, [System.Management.Automation.Language.Ast] $Node)
    $member = Resolve-MatchingMember -TargetType $Type -MemberName $Name -IsStatic:($null -eq $Target)
    if ($member -is [Reflection.PropertyInfo]) { return [Linq.Expressions.Expression]::Property($Target, $member) }
    [Linq.Expressions.Expression]::Field($Target, $member)
}

function Read-PowerShellClass {
    <#
    .SYNOPSIS
        Parses PowerShell source code and validates the target class definition.
    #>
    param(
        [Parameter(Mandatory)][string] $Source,
        [Parameter()][string] $ClassName,
        [Parameter()][string] $SourceFile = ''
    )

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $Source,
        $SourceFile,
        [ref]$tokens,
        [ref]$errors
    )

    # Keywords the source declares are taught to SMA's parser, and the source is parsed again with them.
    $keywords = @(Get-LoweringKeywords $ast)
    if ($keywords.Count) {
        Enter-LoweringKeywords $keywords
        try { $ast = [System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tokens, [ref]$errors) }
        finally { [System.Management.Automation.Language.DynamicKeyword]::Pop() }
    }

    if ($errors -and $errors.Count -gt 0) {
        $messages = ($errors | ForEach-Object { $_.Message }) -join "`n"
        throw "PowerShell syntax parse error:`n$messages"
    }

    $classes = @($ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.TypeDefinitionAst] -and $n.IsClass
    }, $true) | Where-Object { -not (Test-AttributeClass $_) })

    if ($classes.Count -eq 0) {
        throw 'No class definition found in source.'
    }

    $targetClass = if ($ClassName) {
        $matched = @($classes | Where-Object Name -eq $ClassName)
        if ($matched.Count -ne 1) {
            throw "Expected exactly one class named '$ClassName', found $($matched.Count)."
        }
        $matched[0]
    }
    else {
        $classes[0]
    }

    [pscustomobject]@{
        Ast      = $ast
        ClassAst = $targetClass
    }
}

function Add-GenericInference([Type] $Pattern, [Type] $Actual, [hashtable] $Bindings) {
    # Structural inference only: do not guess a common type for conflicting
    # occurrences of T or infer a type parameter solely from a return type.
    if ($Pattern.IsGenericParameter) {
        if ($Bindings.ContainsKey($Pattern)) { return $Bindings[$Pattern] -eq $Actual }
        $Bindings[$Pattern] = $Actual
        return $true
    }
    if ($Pattern.IsArray) {
        if (-not $Actual.IsArray -or $Pattern.GetArrayRank() -ne $Actual.GetArrayRank() -or $Pattern.IsSZArray -ne $Actual.IsSZArray) { return $false }
        return Add-GenericInference $Pattern.GetElementType() $Actual.GetElementType() $Bindings
    }
    if ($Pattern.IsGenericType) {
        if (-not $Actual.IsGenericType -or $Pattern.GetGenericTypeDefinition() -ne $Actual.GetGenericTypeDefinition()) { return $false }
        $patterns = $Pattern.GetGenericArguments()
        $actuals = $Actual.GetGenericArguments()
        for ($i = 0; $i -lt $patterns.Length; $i++) {
            if (-not (Add-GenericInference $patterns[$i] $actuals[$i] $Bindings)) { return $false }
        }
        return $true
    }
    return $Pattern.IsAssignableFrom($Actual)
}

function Resolve-MatchingMethod {
    param(
        [Parameter(Mandatory)][Type] $TargetType,
        [Parameter(Mandatory)][string] $MethodName,
        [Parameter(Mandatory)][AllowEmptyCollection()][Type[]] $ArgumentTypes,
        [switch] $IsStatic,
        [System.Management.Automation.Language.IScriptExtent] $SourceExtent
    )

    $flags = [Reflection.BindingFlags]'Public'
    if ($IsStatic) {
        $flags = $flags -bor [Reflection.BindingFlags]::Static
    } else {
        $flags = $flags -bor [Reflection.BindingFlags]::Instance
    }

    # 1. Exact match
    $exact = $TargetType.GetMethod($MethodName, $flags, $null, $ArgumentTypes, $null)
    if ($null -ne $exact -and -not $exact.ContainsGenericParameters) { return $exact }

    # 2. Compatible match
    $all = @($TargetType.GetMethods($flags) | Where-Object {
        $_.Name -eq $MethodName -and $_.GetParameters().Length -eq $ArgumentTypes.Length
    })

    foreach ($candidate in $all) {
        if ($candidate.ContainsGenericParameters) { continue }
        $params = $candidate.GetParameters()
        $match = $true
        for ($i = 0; $i -lt $params.Length; $i++) {
            if (-not $params[$i].ParameterType.IsAssignableFrom($ArgumentTypes[$i])) {
                $match = $false
                break
            }
        }
        if ($match) { return $candidate }
    }

    # 3. The one overload reachable by PowerShell's argument conversion; the call site converts each argument with
    # ConvertTo-PowerShellType. A number converts to any numeric parameter (checked, floating rounded to even), and an
    # [object] argument, whose type PowerShell only learns when the call runs, converts to the parameter's type then.
    # An open generic definition is never callable as it stands; step 4 closes it or rejects it.
    $numeric = [Type[]]@($script:IntegralTypes + $script:FloatingTypes)
    $reachable = @($all | Where-Object {
        if ($_.ContainsGenericParameters) { return $false }
        $params = $_.GetParameters()
        for ($i = 0; $i -lt $params.Length; $i++) {
            $wanted = $params[$i].ParameterType
            $given = $ArgumentTypes[$i]
            if (-not $wanted.IsAssignableFrom($given) -and -not ($wanted -in $numeric -and $given -in $numeric) -and $given -ne [object]) { return $false }
        }
        $true
    })
    if ($reachable.Count -eq 1) { return $reachable[0] }

    $failure = "Could not resolve method '$MethodName' with argument types ($($ArgumentTypes -join ', ')) on '$($TargetType.FullName)'."
    # 4. Static generic method definitions, closed by structural inference from the argument types. The
    # non-generic binder above and its diagnostics are unchanged; this runs only when it found nothing.
    $genericCandidates = @($all | Where-Object { $IsStatic -and $_.IsGenericMethodDefinition })
    if ($genericCandidates.Count -eq 0) { throw $failure }
    $tried = [Collections.Generic.List[string]]::new()
    $applicable = [Collections.Generic.List[object]]::new()
    foreach ($candidate in $genericCandidates) {
        $bindings = @{}
        $parameters = $candidate.GetParameters()
        $inferred = $true
        for ($i = 0; $i -lt $parameters.Length; $i++) {
            if (-not (Add-GenericInference $parameters[$i].ParameterType $ArgumentTypes[$i] $bindings)) { $inferred = $false; break }
        }
        $typeArguments = [Type[]]@($candidate.GetGenericArguments() | ForEach-Object { $bindings[$_] })
        if (-not $inferred -or $typeArguments -contains $null) {
            $tried.Add("${candidate}: conflicting or uninferred type parameters")
            continue
        }
        try { $closed = $candidate.MakeGenericMethod($typeArguments) }
        catch [ArgumentException] { $tried.Add("${candidate}: inferred arguments violate generic constraints"); continue }
        $closedParameters = $closed.GetParameters()
        $matchesArguments = $true
        $isExact = $true
        for ($i = 0; $i -lt $closedParameters.Length; $i++) {
            if (-not $closedParameters[$i].ParameterType.IsAssignableFrom($ArgumentTypes[$i])) { $matchesArguments = $false; break }
            if ($closedParameters[$i].ParameterType -ne $ArgumentTypes[$i]) { $isExact = $false }
        }
        if ($matchesArguments) { $applicable.Add([pscustomobject]@{ Method = $closed; Exact = $isExact }) }
        $tried.Add("${candidate}: closed as $closed")
    }
    $best = @($applicable | Where-Object Exact)
    if ($best.Count -eq 0) { $best = @($applicable) }
    if ($best.Count -eq 1) { return $best[0].Method }
    if ($best.Count -gt 1) { $failure = "Ambiguous generic method '$MethodName' on '$($TargetType.FullName)'." }
    if ($SourceExtent) { $failure = '[{0}:{1}] {2}' -f $SourceExtent.StartLineNumber, $SourceExtent.StartColumnNumber, $failure }
    throw ($failure + ' Candidates tried: ' + ($tried -join '; '))
}

function Resolve-MatchingConstructor {
    param(
        [Parameter(Mandatory)][Type] $TargetType,
        [Parameter(Mandatory)][AllowEmptyCollection()][Type[]] $ArgumentTypes
    )

    # 1. Exact match
    $exact = $TargetType.GetConstructor($ArgumentTypes)
    if ($null -ne $exact) { return $exact }

    # 2. Compatible match
    $all = @($TargetType.GetConstructors() | Where-Object {
        $_.GetParameters().Length -eq $ArgumentTypes.Length
    })

    foreach ($candidate in $all) {
        $params = $candidate.GetParameters()
        $match = $true
        for ($i = 0; $i -lt $params.Length; $i++) {
            if (-not $params[$i].ParameterType.IsAssignableFrom($ArgumentTypes[$i])) {
                $match = $false
                break
            }
        }
        if ($match) { return $candidate }
    }

    throw "Could not resolve constructor with argument types ($($ArgumentTypes -join ', ')) on '$($TargetType.FullName)'."
}

function Resolve-MatchingMember {
    param(
        [Parameter(Mandatory)][Type] $TargetType,
        [Parameter(Mandatory)][string] $MemberName,
        [switch] $IsStatic
    )

    $flags = [Reflection.BindingFlags]'Public'
    if ($IsStatic) {
        $flags = $flags -bor [Reflection.BindingFlags]::Static
    } else {
        $flags = $flags -bor [Reflection.BindingFlags]::Instance
    }

    $prop = $TargetType.GetProperty($MemberName, $flags)
    if ($null -ne $prop) { return $prop }

    $field = $TargetType.GetField($MemberName, $flags)
    if ($null -ne $field) { return $field }

    throw "Could not resolve property or field '$MemberName' on '$($TargetType.FullName)'."
}

# Integer promotion as C# defines it (binary numeric promotion): types narrower than Int32 meet in
# Int32; same signedness meets in the wider type; mixed signedness meets in the narrowest signed type
# that holds both (Int32 with UInt32 is Int64). A signed type with UInt64 has no common integer type
# and is rejected. Returns $null when no rule applies.
# PowerShell's semantics as typed methods, written once here and lowered by PSC into every assembly it compiles;
# lowering calls them wherever a construct needs them, in any program. Each runs the same interpreted by SMA.
class PowerShellSemantics {
    # [int]($dividend / $divisor) for Int32 and UInt32 operands: PowerShell divides as Double and rounds half to even.
    # Double holds every such quotient and half exactly, so the integer quotient, stepped away from zero when twice the
    # remainder passes the divisor or equals it with an odd quotient, is the same value. A zero divisor throws.
    static [long] RoundedQuotient([long] $dividend, [long] $divisor) {
        [long] $quotient = [Math]::DivRem($dividend, $divisor).Item1
        [long] $remainder = $dividend - $quotient * $divisor
        [long] $excess = 2 * [Math]::Abs($remainder) - [Math]::Abs($divisor)
        if ($excess -gt 0 -or ($excess -eq 0 -and ($quotient -band 1) -ne 0)) {
            if (($dividend -lt 0) -ne ($divisor -lt 0)) { return $quotient - 1 }
            return $quotient + 1
        }
        return $quotient
    }
}

# A lowering decision PSC asks its environment for at the moment it lowers. The newest binding for a target wins and
# keeps the binding it replaced, so how PSC came to lower a construct stays in the runspace with it.
class PscBinding {
    [string] $Target
    [string] $Reason
    [PscBinding] $Previous
}

# The bindings in force, by target, and every binding set, in order. The API object Invoke-PSC.ps1 returns holds the
# environment, so it lives as long as the caller keeps that object; a binding set through it is the next one used.
class PscEnvironment {
    [Collections.Generic.Dictionary[string, PscBinding]] $Current = [Collections.Generic.Dictionary[string, PscBinding]]::new([StringComparer]::Ordinal)
    [Collections.Generic.List[PscBinding]] $History = [Collections.Generic.List[PscBinding]]::new()

    [PscBinding] Set([PscBinding] $binding) {
        [PscBinding] $replaced = $null
        if ($this.Current.TryGetValue($binding.Target, [ref] $replaced)) { $binding.Previous = $replaced }
        $this.Current[$binding.Target] = $binding
        $this.History.Add($binding)
        return $binding
    }

    [PscBinding] Get([string] $target) {
        [PscBinding] $binding = $null
        if (-not $this.Current.TryGetValue($target, [ref] $binding)) { throw [InvalidOperationException]::new("No binding for '$target' in this environment.") }
        return $binding
    }
}

# What an operator does with its operands, which decides the type they are bound to.
enum PscOperatorKind { Arithmetic; Comparison; Bitwise; Conditional }

# Two operands converted to the type an operator works in.
class PscBoundOperands {
    [Linq.Expressions.Expression] $Left
    [Linq.Expressions.Expression] $Right
}

# Binds the operands of a binary operator. Returns $null when it does not apply to their types.
class PscOperandBinding : PscBinding {
    [PscBoundOperands] Bind([PscOperatorKind] $kind, [Linq.Expressions.Expression] $left, [Linq.Expressions.Expression] $right) {
        throw [NotImplementedException]::new($this.GetType().FullName + ' does not bind operands.')
    }
}

# PowerShell's numeric operand binding, measured on SMA (PowerShell 7.7.0-preview.5), not C#'s:
# - Arithmetic and comparison work in the higher-ranked operand type: Int32 < UInt32 < Int64 < UInt64 < Double <
#   Decimal, with narrower integers ranked as Int32 and Single as Double. [uint32]5 + [int]2 is UInt32 and
#   [uint64]5 + [long]2 is UInt64, where C# gives Int64 and refuses.
# - Comparison of a Decimal with a Single or Double is done in Double ([decimal]0 -lt [single]NaN is False).
# - Comparison of a signed integer with an unsigned one of higher rank is exact in Int64 (UInt32) or Decimal (UInt64).
# - Bitwise operators work in the higher-ranked integer type, the signed operand's bits kept ([int]-1 -band [uint32]1
#   is UInt32 1).
# - Conditional arms: PowerShell converts neither, but a lowered expression has one type, so they take the arithmetic one.
# Where SMA's result type depends on the value, nothing is chosen here and the binding does not apply: arithmetic on a
# signed integer and an unsigned one of higher rank ([uint32]1 + [int]-2 is Int64, [uint32]5 + [int]2 is UInt32), and
# bitwise operators with a Single, Double or Decimal operand (UInt64, or Int64 when negative). The program states the
# type it means there, as PSNES does.
class PowerShellNumericOperands : PscOperandBinding {
    static [Type[]] $Ranks = @([int], [uint32], [long], [uint64], [double], [decimal])

    PowerShellNumericOperands() {
        $this.Target = 'NumericOperands'
        $this.Reason = "PowerShell's operand conversions, measured on SMA"
    }

    static [int] Rank([Type] $type) {
        if ($type -in [sbyte], [byte], [int16], [uint16], [int]) { return 0 }
        if ($type -eq [uint32]) { return 1 }
        if ($type -eq [long]) { return 2 }
        if ($type -eq [uint64]) { return 3 }
        if ($type -in [single], [double]) { return 4 }
        if ($type -eq [decimal]) { return 5 }
        return -1
    }

    static [Linq.Expressions.Expression] As([Linq.Expressions.Expression] $operand, [Type] $type) {
        if ($operand.Type -eq $type) { return $operand }
        return [Linq.Expressions.Expression]::Convert($operand, $type)
    }

    [PscBoundOperands] Bind([PscOperatorKind] $kind, [Linq.Expressions.Expression] $left, [Linq.Expressions.Expression] $right) {
        [int] $leftRank = [PowerShellNumericOperands]::Rank($left.Type)
        [int] $rightRank = [PowerShellNumericOperands]::Rank($right.Type)
        if ($leftRank -lt 0 -or $rightRank -lt 0) { return $null }
        if ($kind -eq [PscOperatorKind]::Bitwise -and [Math]::Max($leftRank, $rightRank) -ge 4) { return $null }
        [int] $top = [Math]::Max($leftRank, $rightRank)
        [Type] $common = [PowerShellNumericOperands]::Ranks[$top]
        if ($kind -ne [PscOperatorKind]::Bitwise -and $top -in 1, 3) {
            [Type] $other = if ($leftRank -eq $top) { $right.Type } else { $left.Type }
            if ($other -in [sbyte], [int16], [int], [long]) {
                if ($kind -ne [PscOperatorKind]::Comparison) { return $null }
                $common = if ($top -eq 1) { [long] } else { [decimal] }
            }
        }
        if ($kind -eq [PscOperatorKind]::Comparison -and $top -eq 5 -and [Math]::Min($leftRank, $rightRank) -eq 4) { $common = [double] }
        return [PscBoundOperands]@{ Left = [PowerShellNumericOperands]::As($left, $common); Right = [PowerShellNumericOperands]::As($right, $common) }
    }
}

$script:PscEnvironment = [PscEnvironment]::new()
[void] $script:PscEnvironment.Set([PowerShellNumericOperands]::new())
# PowerShellSemantics' definition from this script's AST, read on the first compile.
$script:PscSemanticsAst = $null

function Convert-AstExpression {
    <#
    .SYNOPSIS
        Converts an individual AST expression node into a typed LINQ Expression.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.Ast] $Node,

        [Parameter(Mandatory)]
        [hashtable] $Scope
    )

    # The concrete worker consumer needs a literal ThreadStart delegate type.
    if ($Node -is [System.Management.Automation.Language.TypeExpressionAst]) {
        $type = Resolve-AstType $Node.TypeName
        if ($type -eq [Threading.ThreadStart]) { return [Linq.Expressions.Expression]::Constant($type,[Type]) }
        throw ('[{0}:{1}] Only the ThreadStart type literal is admitted as a value.' -f $Node.Extent.StartLineNumber,$Node.Extent.StartColumnNumber)
    }
    # 1. Constant literals
    if ($Node -is [System.Management.Automation.Language.ConstantExpressionAst]) {
        $val = $Node.Value
        $type = if ($null -eq $val) { [object] } else { $val.GetType() }
        return [Linq.Expressions.Expression]::Constant($val, $type)
    }

    # 2. String constant expressions
    if ($Node -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        return [Linq.Expressions.Expression]::Constant($Node.Value, [string])
    }

    # 3. Variable references ($true, $false, $null, parameters, locals)
    if ($Node -is [System.Management.Automation.Language.VariableExpressionAst]) {
        $varName = $Node.VariablePath.UserPath
        switch ($varName.ToLowerInvariant()) {
            'true'  { return [Linq.Expressions.Expression]::Constant($true, [bool]) }
            'false' { return [Linq.Expressions.Expression]::Constant($false, [bool]) }
            'null'  { return [Linq.Expressions.Expression]::Constant($null, [object]) }
        }

        if ($varName -eq 'this') {
            if (-not $Scope.This) {
                throw "[{0}:{1}] `$this is not available in a static method." -f $Node.Extent.StartLineNumber, $Node.Extent.StartColumnNumber
            }
            return $Scope.This
        }
        if (($varName -in '_', 'PSItem') -and $Scope.ContainsKey('SwitchItem')) {
            return $Scope.SwitchItem
        }
        if ($Scope.Parameters.ContainsKey($varName)) {
            return $Scope.Parameters[$varName]
        }
        if ($Scope.Locals.ContainsKey($varName)) {
            return $Scope.Locals[$varName]
        }

        throw "[{0}:{1}] Unresolved variable `$$varName." -f $Node.Extent.StartLineNumber, $Node.Extent.StartColumnNumber
    }

    # 4. CommandExpressionAst wrapper
    if ($Node -is [System.Management.Automation.Language.CommandExpressionAst]) {
        return Convert-AstExpression -Node $Node.Expression -Scope $Scope
    }

    # 5. Pipeline wrapper around single expression (e.g. statement in pipeline)
    if ($Node -is [System.Management.Automation.Language.PipelineAst]) {
        if ($Node.PipelineElements.Count -eq 1 -and
            $Node.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) {
            return Convert-AstExpression -Node $Node.PipelineElements[0].Expression -Scope $Scope
        }
    }

    # An assignment used as a value ($a = $b = $c) is the value stored.
    if ($Node -is [System.Management.Automation.Language.AssignmentStatementAst]) {
        return Convert-AstStatement -Statement $Node -Scope $Scope
    }

    # if as a value: $x = if ($c) { $a } elseif ($d) { $b } else { $e }, each branch one expression.
    if ($Node -is [System.Management.Automation.Language.IfStatementAst]) {
        $branchValue = {
            param($block)
            if ($block.Statements.Count -ne 1) {
                throw "[{0}:{1}] Each branch of an if used as a value must be one expression." -f $block.Extent.StartLineNumber, $block.Extent.StartColumnNumber
            }
            Convert-AstExpression -Node $block.Statements[0] -Scope $Scope
        }
        if (-not $Node.ElseClause) {
            throw "[{0}:{1}] An if used as a value needs an else branch." -f $Node.Extent.StartLineNumber, $Node.Extent.StartColumnNumber
        }
        $result = & $branchValue $Node.ElseClause
        $clauses = @($Node.Clauses)
        for ($i = $clauses.Count - 1; $i -ge 0; $i--) {
            $test = Convert-AstExpression -Node $clauses[$i].Item1 -Scope $Scope
            $whenTrue = & $branchValue $clauses[$i].Item2
            $widened = $script:PscEnvironment.Get('NumericOperands').Bind([PscOperatorKind]::Conditional, $whenTrue, $result)
            if ($widened) { $whenTrue = $widened.Left; $result = $widened.Right }
            if ($whenTrue.Type -ne $result.Type) {
                throw "[{0}:{1}] Branches of an if used as a value require identical types, got '{2}' and '{3}'." -f $Node.Extent.StartLineNumber, $Node.Extent.StartColumnNumber, $whenTrue.Type.FullName, $result.Type.FullName
            }
            $result = [Linq.Expressions.Expression]::Condition($test, $whenTrue, $result)
        }
        return $result
    }

    # Ternary: $test ? $a : $b. An integer test is true when nonzero, as in PowerShell.
    if ($Node -is [System.Management.Automation.Language.TernaryExpressionAst]) {
        $test = Convert-AstExpression -Node $Node.Condition -Scope $Scope
        if ($test.Type -in $script:IntegralTypes) { $test = [Linq.Expressions.Expression]::NotEqual($test, [Linq.Expressions.Expression]::Constant([Convert]::ChangeType(0, $test.Type), $test.Type)) }
        if ($test.Type -ne [bool]) {
            throw "[{0}:{1}] A ternary test must be [bool] or an integer, got '{2}'." -f $Node.Extent.StartLineNumber, $Node.Extent.StartColumnNumber, $test.Type.FullName
        }
        $whenTrue = Convert-AstExpression -Node $Node.IfTrue -Scope $Scope
        $whenFalse = Convert-AstExpression -Node $Node.IfFalse -Scope $Scope
        $widened = $script:PscEnvironment.Get('NumericOperands').Bind([PscOperatorKind]::Conditional, $whenTrue, $whenFalse)
        if ($widened) { $whenTrue = $widened.Left; $whenFalse = $widened.Right }
        if ($whenTrue.Type -ne $whenFalse.Type) {
            throw "[{0}:{1}] Ternary arms require identical types, got '{2}' and '{3}'." -f $Node.Extent.StartLineNumber, $Node.Extent.StartColumnNumber, $whenTrue.Type.FullName, $whenFalse.Type.FullName
        }
        return [Linq.Expressions.Expression]::Condition($test, $whenTrue, $whenFalse)
    }

    # $a, $b, $c with no type stated: an object[], as PowerShell builds it. A stated type lowers through the cast or the
    # typed target instead.
    if ($Node -is [System.Management.Automation.Language.ArrayLiteralAst]) {
        $items = [System.Collections.Generic.List[Linq.Expressions.Expression]]::new()
        foreach ($element in $Node.Elements) { $items.Add([Linq.Expressions.Expression]::Convert((Convert-AstExpression -Node $element -Scope $Scope), [object])) }
        return [Linq.Expressions.Expression]::NewArrayInit([object], [Linq.Expressions.Expression[]]$items.ToArray())
    }

    # 5. Paren expressions: ( $expr )
    if ($Node -is [System.Management.Automation.Language.ParenExpressionAst]) {
        return Convert-AstExpression -Node $Node.Pipeline -Scope $Scope
    }



    # 6. Type casts: [int]$x or [int[]]@(...)
    if ($Node -is [System.Management.Automation.Language.ConvertExpressionAst]) {
        $targetType = Resolve-AstType $Node.Type.TypeName
        # [pscustomobject]@{ ... }: a PowerShell custom object, built through SMA's PSObject.
        if ($targetType -eq [System.Management.Automation.PSObject] -and $Node.Child -is [System.Management.Automation.Language.HashtableAst]) {
            return New-PowerShellCustomObject -Table $Node.Child -Scope $Scope
        }
        if ($targetType.IsArray) {
            $childNode = $Node.Child
            if ($childNode -is [System.Management.Automation.Language.ArrayExpressionAst] -or
                $childNode -is [System.Management.Automation.Language.ArrayLiteralAst]) {
                $elements = Get-AstArrayElements $childNode
                $elemType = $targetType.GetElementType()
                $elemExprList = [System.Collections.Generic.List[Linq.Expressions.Expression]]::new()
                foreach ($el in $elements) {
                    $itemExpr = Convert-AstExpression -Node $el -Scope $Scope
                    if ($itemExpr.Type -ne $elemType) {
                        $itemExpr = (ConvertTo-PowerShellType -Expression $itemExpr -Type ($elemType))
                    }
                    $elemExprList.Add($itemExpr)
                }
                return [Linq.Expressions.Expression]::NewArrayInit($elemType, [Linq.Expressions.Expression[]]$elemExprList.ToArray())
            }
        }
        $quotient = ConvertTo-IntegralQuotient -Node $Node.Child -Type $targetType -Scope $Scope
        if ($null -ne $quotient) { return $quotient }
        $child = Convert-AstExpression -Node $Node.Child -Scope $Scope
        return (ConvertTo-PowerShellType -Expression $child -Type ($targetType))
    }

    # 7. Unary arithmetic expressions: -$x, ++$x, --$x, $x++, $x--
    if ($Node -is [System.Management.Automation.Language.UnaryExpressionAst]) {
        if ($Node.TokenKind -in 'PostfixPlusPlus', 'PrefixPlusPlus', 'PostfixMinusMinus', 'PrefixMinusMinus') {
            $target = Convert-AstExpression -Node $Node.Child -Scope $Scope
            $one = [Linq.Expressions.Expression]::Constant(1, [int])
            $operand = $target
            $widened = $script:PscEnvironment.Get('NumericOperands').Bind([PscOperatorKind]::Arithmetic, $target, $one)
            if ($widened) { $operand = $widened.Left; $one = $widened.Right } else { $one = [Linq.Expressions.Expression]::Constant([Convert]::ChangeType(1, $target.Type), $target.Type) }
            $operator = if ($Node.TokenKind -in 'PostfixPlusPlus', 'PrefixPlusPlus') { 'Plus' } else { 'Minus' }
            return [Linq.Expressions.Expression]::Assign($target, (ConvertTo-PowerShellType -Expression (New-PowerShellArithmetic -Operator $operator -Left $operand -Right $one) -Type $target.Type))
        }

        $operand = Convert-AstExpression -Node $Node.Child -Scope $Scope
        switch ($Node.TokenKind) {
            'Minus'   {
                if ($operand.Type -in $script:IntegralTypes) { return [Linq.Expressions.Expression]::NegateChecked($operand) }
                return [Linq.Expressions.Expression]::Negate($operand)
            }
            'Plus'    { return $operand }
            'Not'     { return [Linq.Expressions.Expression]::Not($operand) }
            'Bnot'    {
                if ($operand.Type -notin $script:IntegralTypes) {
                    throw "[{0}:{1}] -bnot requires an integral operand, got '{2}'." -f $Node.Extent.StartLineNumber, $Node.Extent.StartColumnNumber, $operand.Type.FullName
                }
                return [Linq.Expressions.Expression]::Not($operand)
            }
            'Exclaim' { return [Linq.Expressions.Expression]::Not($operand) }
            default {
                throw "[{0}:{1}] Unsupported unary operator '{2}'." -f `
                    $Node.Extent.StartLineNumber, $Node.Extent.StartColumnNumber, $Node.TokenKind
            }
        }
    }

    # 8. Binary arithmetic and comparison expressions
    if ($Node -is [System.Management.Automation.Language.BinaryExpressionAst]) {
        $left = Convert-AstExpression -Node $Node.Left -Scope $Scope
        if ($Node.Operator -in 'Iin', 'Inotin', 'Cin', 'Cnotin') {
            $right = Convert-AstExpressionAs -Node $Node.Right -Type ([string[]]) -Scope $Scope
            if ($left.Type -ne [string]) {
                throw "[$($Node.Extent.StartLineNumber):$($Node.Extent.StartColumnNumber)] Membership requires a string value and string[] collection."
            }
            $et = [Linq.Expressions.Expression]
            $id = $Scope.DeclaredLocals.Count
            $value = $et::Variable([string], "membershipValue$id")
            $array = $et::Variable([string[]], "membershipArray$id")
            $index = $et::Variable([int], "membershipIndex$id")
            $found = $et::Variable([bool], "membershipFound$id")
            foreach ($local in @($value, $array, $index, $found)) { $Scope.DeclaredLocals.Add($local) }
            $done = $et::Label("membershipDone$id")
            $compare = New-PowerShellStringComparison -Left ($et::ArrayIndex($array, $index)) -Right $value -CaseSensitive ([string]$Node.Operator).StartsWith('C', [StringComparison]::Ordinal)
            $loop = $et::Loop($et::IfThenElse($et::LessThan($index, $et::ArrayLength($array)),
                $et::Block($et::IfThen($et::Equal($compare, $et::Constant(0)),
                    $et::Block($et::Assign($found, $et::Constant($true)), $et::Break($done))),
                    $et::Assign($index, $et::Add($index, $et::Constant(1))), $et::Empty()),
                $et::Break($done)), $done)
            $result = if ($Node.Operator -in 'Inotin', 'Cnotin') { $et::Not($found) } else { $found }
            return $et::Block($et::Assign($value, $left), $et::Assign($array, $right),
                $et::Assign($index, $et::Constant(0)), $et::Assign($found, $et::Constant($false)),
                $et::IfThen($et::NotEqual($array, $et::Constant($null, [string[]])), $loop), $result)
        }
        $right = Convert-AstExpression -Node $Node.Right -Scope $Scope

        if ($Node.Operator -in 'Shl', 'Shr') {
            # The shift count is an Int32 in PowerShell and the CLR. A narrower left operand keeps its own type in
            # PowerShell ([byte] -shl 8 loses the high bits), so it shifts as an Int32 and truncates back.
            if ($right.Type -in $script:IntegralTypes -and $right.Type -ne [int]) { $right = ConvertTo-PowerShellType -Expression $right -Type ([int]) }
            if ($left.Type -in [sbyte], [byte], [short], [ushort]) {
                $narrow = $left.Type
                $wide = [Linq.Expressions.Expression]::Convert($left, [int])
                $shifted = if ($Node.Operator -eq 'Shl') { [Linq.Expressions.Expression]::LeftShift($wide, $right) } else { [Linq.Expressions.Expression]::RightShift($wide, $right) }
                return [Linq.Expressions.Expression]::Convert($shifted, $narrow)
            }
            if ($left.Type -notin $script:IntegralTypes -or $right.Type -ne [int]) {
                throw "[{0}:{1}] -{2} requires an integral left operand and an [int] shift count, got '{3}' and '{4}'." -f `
                    $Node.Extent.StartLineNumber, $Node.Extent.StartColumnNumber, $Node.Operator.ToString().ToLowerInvariant(), $left.Type.FullName, $right.Type.FullName
            }
            if ($Node.Operator -eq 'Shl') { return [Linq.Expressions.Expression]::LeftShift($left, $right) }
            return [Linq.Expressions.Expression]::RightShift($left, $right)
        }

        # $null compared with a reference is a null of that reference's type.
        if ($Node.Operator -in 'Ieq', 'Ine', 'Ceq', 'Cne') {
            if ($left -is [Linq.Expressions.ConstantExpression] -and $null -eq $left.Value -and -not $right.Type.IsValueType) { $left = [Linq.Expressions.Expression]::Constant($null, $right.Type) }
            if ($right -is [Linq.Expressions.ConstantExpression] -and $null -eq $right.Value -and -not $left.Type.IsValueType) { $right = [Linq.Expressions.Expression]::Constant($null, $left.Type) }
        }
        if ($Node.Operator -notin 'And', 'Or') {
            # Narrow integers have no CLR arithmetic of their own, even when both sides match.
            $kind = if ($Node.Operator -in 'Band', 'Bor', 'Bxor') { [PscOperatorKind]::Bitwise }
                elseif ($Node.Operator -in 'Plus', 'Minus', 'Multiply', 'Divide', 'Rem') { [PscOperatorKind]::Arithmetic }
                else { [PscOperatorKind]::Comparison }
            $widened = $script:PscEnvironment.Get('NumericOperands').Bind($kind, $left, $right)
            if ($widened) { $left = $widened.Left; $right = $widened.Right }
        }
        if ($left.Type -ne $right.Type) {
            throw "[{0}:{1}] Binary operator '{2}' requires identical operand types, got '{3}' and '{4}'." -f `
                $Node.Extent.StartLineNumber, $Node.Extent.StartColumnNumber, $Node.Operator, $left.Type.FullName, $right.Type.FullName
        }

        if ($left.Type -eq [string] -and $Node.Operator -match '^[IC](eq|ne|lt|le|gt|ge)$') {
            $compared = New-PowerShellStringComparison -Left $left -Right $right -CaseSensitive ([string]$Node.Operator).StartsWith('C', [StringComparison]::Ordinal)
            $zero = [Linq.Expressions.Expression]::Constant(0)
            switch -Regex ($Node.Operator) {
                'eq$' { return [Linq.Expressions.Expression]::Equal($compared, $zero) }
                'ne$' { return [Linq.Expressions.Expression]::NotEqual($compared, $zero) }
                'lt$' { return [Linq.Expressions.Expression]::LessThan($compared, $zero) }
                'le$' { return [Linq.Expressions.Expression]::LessThanOrEqual($compared, $zero) }
                'gt$' { return [Linq.Expressions.Expression]::GreaterThan($compared, $zero) }
                'ge$' { return [Linq.Expressions.Expression]::GreaterThanOrEqual($compared, $zero) }
            }
        }

        switch ($Node.Operator) {
            { $_ -in 'Plus', 'Minus', 'Multiply', 'Divide', 'Rem' } { return New-PowerShellArithmetic -Operator $Node.Operator -Left $left -Right $right }
            { $_ -in 'Band', 'Bor', 'Bxor' } {
                if ($left.Type -notin $script:IntegralTypes) {
                    throw "[{0}:{1}] -{2} requires integral operands, got '{3}'." -f $Node.Extent.StartLineNumber, $Node.Extent.StartColumnNumber, $Node.Operator.ToString().ToLowerInvariant(), $left.Type.FullName
                }
                switch ($Node.Operator) {
                    'Band' { return [Linq.Expressions.Expression]::And($left, $right) }
                    'Bor'  { return [Linq.Expressions.Expression]::Or($left, $right) }
                    'Bxor' { return [Linq.Expressions.Expression]::ExclusiveOr($left, $right) }
                }
            }
            { $_ -in 'Ieq', 'Ceq' } { return [Linq.Expressions.Expression]::Equal($left, $right) }
            { $_ -in 'Ine', 'Cne' } { return [Linq.Expressions.Expression]::NotEqual($left, $right) }
            { $_ -in 'Ilt', 'Clt' } { return [Linq.Expressions.Expression]::LessThan($left, $right) }
            { $_ -in 'Ile', 'Cle' } { return [Linq.Expressions.Expression]::LessThanOrEqual($left, $right) }
            { $_ -in 'Igt', 'Cgt' } { return [Linq.Expressions.Expression]::GreaterThan($left, $right) }
            { $_ -in 'Ige', 'Cge' } { return [Linq.Expressions.Expression]::GreaterThanOrEqual($left, $right) }
            'And'      { return [Linq.Expressions.Expression]::AndAlso($left, $right) }
            'Or'       { return [Linq.Expressions.Expression]::OrElse($left, $right) }
            default {
                throw "[{0}:{1}] Unsupported binary operator '{2}'." -f `
                    $Node.Extent.StartLineNumber, $Node.Extent.StartColumnNumber, $Node.Operator
            }
        }
    }

    # 9. Array index read: $arr[$i]
    if ($Node -is [System.Management.Automation.Language.IndexExpressionAst]) {
        $targetExpr = Convert-AstExpression -Node $Node.Target -Scope $Scope
        $idxExpr = Convert-AstExpression -Node $Node.Index -Scope $Scope
        $isList = -not $targetExpr.Type.IsArray -and $null -ne (Get-IntIndexer $targetExpr.Type)
        if (($targetExpr.Type.IsArray -and $targetExpr.Type.GetArrayRank() -eq 1) -or $isList) {
            $element = New-PowerShellArrayIndex -Array $targetExpr -Index $idxExpr -Scope $Scope
            $read = if ($isList) { $element.Access } else { [Linq.Expressions.Expression]::ArrayIndex($element.Access.Object, $element.Access.Arguments[0]) }
            if ($element.Setup.Count -eq 0) { return $read }
            $element.Setup.Add($read)
            return [Linq.Expressions.Expression]::Block($read.Type, [Linq.Expressions.Expression[]]$element.Setup.ToArray())
        }
        # Any other type indexes through its default indexer (Item), by key: a dictionary, a member collection.
        $keyed = Get-KeyIndexer $targetExpr.Type $idxExpr.Type
        if ($keyed) {
            $key = ConvertTo-PowerShellType -Expression $idxExpr -Type $keyed.GetIndexParameters()[0].ParameterType
            return [Linq.Expressions.Expression]::MakeIndex($targetExpr, $keyed, [Linq.Expressions.Expression[]]@($key))
        }
        throw "[{0}:{1}] Indexing into non-array type '{2}' is not supported." -f `
            $Node.Extent.StartLineNumber, $Node.Extent.StartColumnNumber, $targetExpr.Type.FullName
    }

    # 10. Invoke Member Expression: [T]::Method(...) or $inst.Method(...) or [T]::new(...)
    if ($Node -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
        $address = Convert-NativeAddressExpression $Node
        if ($address) { return $address }
        $memberName = if ($Node.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            $Node.Member.Value
        } else {
            $Node.Member.Extent.Text
        }

        # Convert arguments
        $argExprs = [System.Collections.Generic.List[Linq.Expressions.Expression]]::new()
        if ($Node.Arguments) {
            foreach ($arg in $Node.Arguments) {
                $argExprs.Add((Convert-AstExpression -Node $arg -Scope $Scope))
            }
        }
        $argTypes = [Type[]]@($argExprs | ForEach-Object { $_.Type })

        if ($Node.Static) {
            $targetType = if ($Node.Expression -is [System.Management.Automation.Language.TypeExpressionAst]) {
                Resolve-AstType $Node.Expression.TypeName
            } else {
                Resolve-AstType $Node.Expression.Extent.Text
            }

            # Array allocation: [T[]]::new(count)
            if ($targetType.IsArray -and $memberName -eq 'new') {
                if ($argExprs.Count -ne 1) {
                    throw "[{0}:{1}] Array constructor requires exactly 1 length argument." -f `
                        $Node.Extent.StartLineNumber, $Node.Extent.StartColumnNumber
                }
                $lenExpr = $argExprs[0]
                if ($lenExpr.Type -ne [int]) {
                    $lenExpr = (ConvertTo-PowerShellType -Expression $lenExpr -Type ([int]))
                }
                return [Linq.Expressions.Expression]::NewArrayBounds($targetType.GetElementType(), $lenExpr)
            }

            # Object constructor: [T]::new(...)
            if ($memberName -eq 'new') {
                $ctor = Resolve-MatchingConstructor -TargetType $targetType -ArgumentTypes $argTypes
                $params = $ctor.GetParameters()
                for ($i = 0; $i -lt $params.Length; $i++) {
                    if ($argExprs[$i].Type -ne $params[$i].ParameterType) {
                        $argExprs[$i] = (ConvertTo-PowerShellType -Expression $argExprs[$i] -Type ($params[$i].ParameterType))
                    }
                }
                return $script:ExpressionNewMethod.Invoke($null, @($ctor, [Linq.Expressions.Expression[]]$argExprs.ToArray()))
            }

            # Static method call: [T]::Method(...)
            $method = Resolve-MatchingMethod -TargetType $targetType -MethodName $memberName -ArgumentTypes $argTypes -IsStatic -SourceExtent $Node.Extent
            if ($method.IsDefined([Runtime.InteropServices.UnmanagedCallersOnlyAttribute],$false)) {
                throw ('[{0}:{1}] UnmanagedCallersOnly method cannot be called from managed code.' -f $Node.Extent.StartLineNumber,$Node.Extent.StartColumnNumber)
            }
            $params = $method.GetParameters()
            for ($i = 0; $i -lt $params.Length; $i++) {
                if ($argExprs[$i].Type -ne $params[$i].ParameterType) {
                    $argExprs[$i] = (ConvertTo-PowerShellType -Expression $argExprs[$i] -Type ($params[$i].ParameterType))
                }
            }
            return [Linq.Expressions.Expression]::Call($method, [Linq.Expressions.Expression[]]$argExprs.ToArray())
        }
        else {
            # Instance method call: $inst.Method(...)
            $targetExpr = Convert-AstExpression -Node $Node.Expression -Scope $Scope
            # On a PowerShell object, PowerShell calls methods on the base object: a custom object's base is
            # PSCustomObject, so GetType() reports PSCustomObject and ToString() returns an empty string.
            # Through .PSObject, the methods are the PSObject class's own.
            if ($targetExpr.Type -eq [System.Management.Automation.PSObject] -and -not (Test-PSObjectView $Node.Expression)) {
                $targetExpr = [Linq.Expressions.Expression]::Property($targetExpr, 'BaseObject')
            }
            $method = Resolve-MatchingMethod -TargetType $targetExpr.Type -MethodName $memberName -ArgumentTypes $argTypes
            if ($method.IsDefined([Runtime.InteropServices.UnmanagedCallersOnlyAttribute],$false)) {
                throw ('[{0}:{1}] UnmanagedCallersOnly method cannot be called from managed code.' -f $Node.Extent.StartLineNumber,$Node.Extent.StartColumnNumber)
            }
            $params = $method.GetParameters()
            for ($i = 0; $i -lt $params.Length; $i++) {
                if ($argExprs[$i].Type -ne $params[$i].ParameterType) {
                    $argExprs[$i] = (ConvertTo-PowerShellType -Expression $argExprs[$i] -Type ($params[$i].ParameterType))
                }
            }
            return [Linq.Expressions.Expression]::Call($targetExpr, $method, [Linq.Expressions.Expression[]]$argExprs.ToArray())
        }
    }

    # 11. Member expression: $arr.Length, $inst.Prop, [T]::Prop
    if ($Node -is [System.Management.Automation.Language.MemberExpressionAst] -and
        $Node -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
        $memberName = if ($Node.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            $Node.Member.Value
        } else {
            $Node.Member.Extent.Text
        }

        if ($Node.Static) {
            $targetType = if ($Node.Expression -is [System.Management.Automation.Language.TypeExpressionAst]) {
                Resolve-AstType $Node.Expression.TypeName
            } else {
                Resolve-AstType $Node.Expression.Extent.Text
            }
            # An enum member is a constant of the enum type; literal fields have no storage to load.
            if ($targetType.IsEnum) { return [Linq.Expressions.Expression]::Constant([Enum]::Parse($targetType, $memberName, $true), $targetType) }
            return New-MemberAccess -Target $null -Type $targetType -Name $memberName -Node $Node
        }
        else {
            $targetExpr = Convert-AstExpression -Node $Node.Expression -Scope $Scope
            if ($targetExpr.Type.IsArray -and $memberName -eq 'Length') {
                return [Linq.Expressions.Expression]::ArrayLength($targetExpr)
            }
            # On a PowerShell object, a member name is one of its properties. Through .PSObject, PowerShell
            # shows the wrapper itself as an ordinary object, so $o.PSObject.Name is the PSObject class's member.
            if ($targetExpr.Type -eq [System.Management.Automation.PSObject]) {
                if ($memberName -eq 'PSObject') { return $targetExpr }
                if (Test-PSObjectView $Node.Expression) { return New-MemberAccess -Target $targetExpr -Type $targetExpr.Type -Name $memberName -Node $Node }
                return New-PowerShellNotePropertyRead -Target $targetExpr -Name $memberName -Scope $Scope
            }
            return New-MemberAccess -Target $targetExpr -Type $targetExpr.Type -Name $memberName -Node $Node
        }
    }

    throw "[{0}:{1}] Unsupported AST expression '{2}' ({3})." -f `
        $Node.Extent.StartLineNumber, $Node.Extent.StartColumnNumber, $Node.Extent.Text, $Node.GetType().Name
}

function New-PredicateTruth {
    param([Linq.Expressions.Expression] $Value)
    $et = [Linq.Expressions.Expression]
    if ($Value.Type -eq [bool]) { return $Value }
    if ($Value.Type -eq [string]) {
        return $et::Not($et::Call([string].GetMethod('IsNullOrEmpty', [type[]]@([string])), $Value))
    }
    if ($Value.Type -in ($script:IntegralTypes + @([single], [double], [decimal]))) {
        return $et::NotEqual($Value, $et::Default($Value.Type))
    }
    if ($Value.Type.IsArray -and $Value.Type.GetArrayRank() -eq 1) {
        $item = $et::ArrayIndex($Value, $et::Constant(0))
        # PowerShell treats a nested singleton list by the nested list's
        # count, rather than recursively testing its first element.
        $one = if ($item.Type.IsArray) {
            $et::AndAlso($et::NotEqual($item, $et::Constant($null, $item.Type)),
                $et::GreaterThan($et::ArrayLength($item), $et::Constant(0)))
        } else { New-PredicateTruth $item }
        return $et::AndAlso($et::NotEqual($Value, $et::Constant($null, $Value.Type)),
            $et::AndAlso($et::GreaterThan($et::ArrayLength($Value), $et::Constant(0)),
                $et::OrElse($et::GreaterThan($et::ArrayLength($Value), $et::Constant(1)), $one)))
    }
    if ($Value -is [Linq.Expressions.ConstantExpression] -and $null -eq $Value.Value) {
        return $et::Constant($false)
    }
    throw "Predicate truthiness requires a statically typed Boolean, string, number or one-dimensional array; got '$($Value.Type.FullName)'."
}

function Convert-PredicateSwitch {
    param([System.Management.Automation.Language.SwitchStatementAst] $Statement, [hashtable] $Scope)
    $et = [Linq.Expressions.Expression]
    $flags = [int]$Statement.Flags
    $caseSensitive = [int][System.Management.Automation.Language.SwitchFlags]::CaseSensitive
    if ($flags -band (-bnot $caseSensitive)) {
        throw "[$($Statement.Extent.StartLineNumber):$($Statement.Extent.StartColumnNumber)] Predicate switch admits exact matching only."
    }
    $inputValue = Convert-AstExpression -Node $Statement.Condition -Scope $Scope
    if ($inputValue.Type -ne [string] -and $inputValue.Type -ne [string[]]) {
        throw "[$($Statement.Extent.StartLineNumber):$($Statement.Extent.StartColumnNumber)] Predicate switch input must be string or string[]."
    }
    $id = $Scope.DeclaredLocals.Count
    $values = $et::Variable([string[]], "switchValues$id")
    $item = $et::Variable([string], "switchItem$id")
    $index = $et::Variable([int], "switchIndex$id")
    $matched = $et::Variable([bool], "switchMatched$id")
    foreach ($local in @($values, $item, $index, $matched)) { $Scope.DeclaredLocals.Add($local) }
    $breakLabel = $et::Label("switchBreak$id")
    $continueLabel = $et::Label("switchContinue$id")
    $hadItem = $Scope.ContainsKey('SwitchItem')
    $oldItem = if ($hadItem) { $Scope.SwitchItem } else { $null }
    $Scope.SwitchItem = $item
    $Scope.Loops.Push(@{ Break = $breakLabel; Continue = $continueLabel })
    $chain = [Collections.Generic.List[Linq.Expressions.Expression]]::new()
    $chain.Add($et::Assign($item, $et::ArrayIndex($values, $index)))
    $chain.Add($et::Assign($matched, $et::Constant($false)))
    try {
        foreach ($clause in $Statement.Clauses) {
            if ($clause.Item1 -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
                $predicate = $clause.Item1.ScriptBlock
                if ($predicate.ParamBlock -or $predicate.BeginBlock -or $predicate.ProcessBlock -or
                    -not $predicate.EndBlock -or $predicate.EndBlock.Statements.Count -ne 1 -or
                    $predicate.EndBlock.Statements[0] -isnot [System.Management.Automation.Language.PipelineAst]) {
                    throw "[$($predicate.Extent.StartLineNumber):$($predicate.Extent.StartColumnNumber)] Predicate must contain one typed expression."
                }
                if ($predicate.Find({ param($n) $n -is [System.Management.Automation.Language.UnaryExpressionAst] -and
                    $n.TokenKind -in 'PostfixPlusPlus','PrefixPlusPlus','PostfixMinusMinus','PrefixMinusMinus' }, $true)) {
                    throw "[$($predicate.Extent.StartLineNumber):$($predicate.Extent.StartColumnNumber)] Predicate local variable mutation is not admitted."
                }
                $value = Convert-AstExpression -Node $predicate.EndBlock.Statements[0] -Scope $Scope
                # Capture the expression once before testing its truthiness.
                $result = $et::Variable($value.Type, "switchPredicate$($Scope.DeclaredLocals.Count)")
                $Scope.DeclaredLocals.Add($result)
                $condition = $et::Block($et::Assign($result, $value), (New-PredicateTruth $result))
            } else {
                $constant = Convert-AstExpression -Node $clause.Item1 -Scope $Scope
                if ($constant.Type -ne [string]) { throw 'Mixed predicate switch clauses must be string constants.' }
                # Switch exact matching treats null as the empty string.
                $text = $et::Condition($et::Equal($item, $et::Constant($null, [string])), $et::Constant(''), $item)
                $comparison = New-PowerShellStringComparison -Left $text -Right $constant -CaseSensitive ([bool]($flags -band $caseSensitive))
                $condition = $et::Equal($comparison, $et::Constant(0))
            }
            $body = Convert-AstStatement -Statement $clause.Item2 -Scope $Scope
            $chain.Add($et::IfThen($condition, $et::Block(
                $et::Assign($matched, $et::Constant($true)), $body, $et::Empty())))
        }
        if ($Statement.Default) {
            $chain.Add($et::IfThen($et::Not($matched), (Convert-AstStatement -Statement $Statement.Default -Scope $Scope)))
        }
    } finally {
        $null = $Scope.Loops.Pop()
        if ($hadItem) { $Scope.SwitchItem = $oldItem } else { $Scope.Remove('SwitchItem') }
    }
    $chain.Add($et::Label($continueLabel))
    $chain.Add($et::Assign($index, $et::Add($index, $et::Constant(1))))
    $chain.Add($et::Empty())
    $loop = $et::Loop($et::IfThenElse($et::LessThan($index, $et::ArrayLength($values)),
        $et::Block([Linq.Expressions.Expression[]]$chain.ToArray()), $et::Break($breakLabel)), $breakLabel)
    $arrayValue = if ($inputValue.Type -eq [string]) { $et::NewArrayInit([string], [Linq.Expressions.Expression[]]@($inputValue)) } else { $inputValue }
    return $et::Block($et::Assign($values, $arrayValue),
        $et::IfThen($et::Equal($values, $et::Constant($null, [string[]])),
            $et::Block($et::Assign($values, $et::NewArrayInit([string], [Linq.Expressions.Expression[]]@($et::Constant($null, [string])))), $et::Empty())),
        $et::Assign($index, $et::Constant(0)), $loop, $et::Empty())
}

function Convert-AstStatement {
    <#
    .SYNOPSIS
        Converts an individual AST statement into a typed LINQ Expression.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.Ast] $Statement,

        [Parameter(Mandatory)]
        [hashtable] $Scope
    )

    # A predicate switch is an ordered chain, with a lexically bound current
    # string. No delegate or nested lambda is emitted for its predicates.
    if ($Statement -is [System.Management.Automation.Language.SwitchStatementAst] -and
        @($Statement.Clauses | Where-Object { $_.Item1 -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }).Count -gt 0) {
        return Convert-PredicateSwitch -Statement $Statement -Scope $Scope
    }

    # 1. Assignment statement: $x = <expr>, [int]$x = <expr>, or $arr[$i] = <expr>
    if ($Statement -is [System.Management.Automation.Language.AssignmentStatementAst]) {
        $leftNode = $Statement.Left

        if ($Statement.Operator -ne [System.Management.Automation.Language.TokenKind]::Equals) {
            $compound = @{ PlusEquals = 'Plus'; MinusEquals = 'Minus'; MultiplyEquals = 'Multiply'; DivideEquals = 'Divide'; RemainderEquals = 'Rem' }[[string]$Statement.Operator]
            if (-not $compound) {
                throw "[{0}:{1}] Unsupported assignment operator '{2}'." -f $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber, $Statement.Operator
            }
            if ($leftNode -is [System.Management.Automation.Language.IndexExpressionAst]) {
                # The array and index are evaluated once, then the element is read,
                # combined and stored back.
                $arrayExpr = Convert-AstExpression -Node $leftNode.Target -Scope $Scope
                if (-not ($arrayExpr.Type.IsArray -and $arrayExpr.Type.GetArrayRank() -eq 1) -and $null -eq (Get-IntIndexer $arrayExpr.Type)) {
                    throw "[{0}:{1}] Compound assignment into non-array type '{2}' is not supported." -f $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber, $arrayExpr.Type.FullName
                }
                $element = New-PowerShellArrayIndex -Array $arrayExpr -Index (Convert-AstExpression -Node $leftNode.Index -Scope $Scope) -Scope $Scope
                $right = Convert-AstExpression -Node $Statement.Right -Scope $Scope
                $operandLeft = $element.Access
                $widened = $script:PscEnvironment.Get('NumericOperands').Bind([PscOperatorKind]::Arithmetic, $operandLeft, $right)
                if ($widened) { $operandLeft = $widened.Left; $right = $widened.Right }
                if ($right.Type -ne $operandLeft.Type) {
                    throw "[{0}:{1}] Compound assignment '{2}' requires identical operand types, got '{3}' and '{4}'." -f `
                        $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber, $Statement.Operator, $element.Access.Type.FullName, $right.Type.FullName
                }
                $combined = New-PowerShellArithmetic -Operator $compound -Left $operandLeft -Right $right
                $element.Setup.Add([Linq.Expressions.Expression]::Assign($element.Access, (ConvertTo-PowerShellType -Expression $combined -Type $element.Access.Type)))
                $element.Setup.Add([Linq.Expressions.Expression]::Empty())
                return [Linq.Expressions.Expression]::Block([Linq.Expressions.Expression[]]$element.Setup.ToArray())
            }
            # The target is read and then written, so it must be a variable or a chain of field reads off a
            # variable or type: reading it twice has no effect to repeat.
            $chain = $leftNode
            while ($chain -is [System.Management.Automation.Language.MemberExpressionAst] -and
                   $chain -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst] -and -not $chain.Static) { $chain = $chain.Expression }
            $plain = $chain -is [System.Management.Automation.Language.VariableExpressionAst] -or
                     ($chain -is [System.Management.Automation.Language.MemberExpressionAst] -and $chain -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $chain.Static)
            if (-not $plain) {
                throw "[{0}:{1}] Compound assignment '{2}' is supported only on a variable or a chain of members of a variable or type." -f $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber, $Statement.Operator
            }
            $target = Convert-AstExpression -Node $leftNode -Scope $Scope
            $right = Convert-AstExpression -Node $Statement.Right -Scope $Scope
            $operandLeft = $target
            $widened = $script:PscEnvironment.Get('NumericOperands').Bind([PscOperatorKind]::Arithmetic, $operandLeft, $right)
            if ($widened) { $operandLeft = $widened.Left; $right = $widened.Right }
            if ($right.Type -ne $operandLeft.Type) {
                throw "[{0}:{1}] Compound assignment '{2}' requires identical operand types, got '{3}' and '{4}'." -f `
                    $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber, $Statement.Operator, $target.Type.FullName, $right.Type.FullName
            }
            $value = New-PowerShellArithmetic -Operator $compound -Left $operandLeft -Right $right
            return [Linq.Expressions.Expression]::Assign($target, (ConvertTo-PowerShellType -Expression $value -Type $target.Type))
        }

        # Array element assignment: $arr[$i] = <expr>
        if ($leftNode -is [System.Management.Automation.Language.IndexExpressionAst]) {
            $targetExpr = Convert-AstExpression -Node $leftNode.Target -Scope $Scope
            $idxExpr = Convert-AstExpression -Node $leftNode.Index -Scope $Scope
            $indexer = if ($targetExpr.Type.IsArray) { $null } else { Get-IntIndexer $targetExpr.Type }
            if (-not $targetExpr.Type.IsArray -and $null -eq $indexer) {
                throw "[{0}:{1}] Cannot assign into non-array type '{2}'." -f `
                    $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber, $targetExpr.Type.FullName
            }
            $elemType = if ($indexer) { $indexer.PropertyType } else { $targetExpr.Type.GetElementType() }
            $element = New-PowerShellArrayIndex -Array $targetExpr -Index $idxExpr -Scope $Scope
            $valExpr = Convert-AstExpressionAs -Node $Statement.Right -Type $elemType -Scope $Scope
            $store = [Linq.Expressions.Expression]::Assign($element.Access, $valExpr)
            if ($element.Setup.Count -eq 0) { return $store }
            $element.Setup.Add($store)
            $element.Setup.Add([Linq.Expressions.Expression]::Empty())
            return [Linq.Expressions.Expression]::Block([Linq.Expressions.Expression[]]$element.Setup.ToArray())
        }

        if ($leftNode -is [System.Management.Automation.Language.MemberExpressionAst] -and
            $leftNode -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst] -and -not $leftNode.Static) {
            # The owner is converted once. On a PowerShell object, $object.Name = value sets that note property.
            $owner = Convert-AstExpression -Node $leftNode.Expression -Scope $Scope
            $name = if ($leftNode.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $leftNode.Member.Value } else { $leftNode.Member.Extent.Text }
            if ($owner.Type -eq [System.Management.Automation.PSObject]) {
                $value = Convert-AstExpression -Node $Statement.Right -Scope $Scope
                if ($value.Type -ne [object]) { $value = [Linq.Expressions.Expression]::Convert($value, [object]) }
                return [Linq.Expressions.Expression]::Assign([Linq.Expressions.Expression]::Property((Get-PowerShellNoteProperty $owner $name), 'Value'), $value)
            }
            $memberTarget = New-MemberAccess -Target $owner -Type $owner.Type -Name $name -Node $leftNode
            if ($memberTarget.Member -is [Reflection.PropertyInfo] -and -not $memberTarget.Member.CanWrite) {
                throw "[{0}:{1}] Property '{2}' is read-only." -f $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber, $memberTarget.Member.Name
            }
            return [Linq.Expressions.Expression]::Assign($memberTarget, (Convert-AstExpressionAs -Node $Statement.Right -Type $memberTarget.Type -Scope $Scope))
        }
        if ($leftNode -is [System.Management.Automation.Language.MemberExpressionAst] -and
            $leftNode -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
            $memberTarget = Convert-AstExpression -Node $leftNode -Scope $Scope
            if ($memberTarget -isnot [Linq.Expressions.MemberExpression]) {
                throw "[{0}:{1}] Cannot assign to '{2}'." -f $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber, $leftNode.Extent.Text
            }
            if ($memberTarget.Member -is [Reflection.PropertyInfo] -and -not $memberTarget.Member.CanWrite) {
                throw "[{0}:{1}] Property '{2}' is read-only." -f $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber, $memberTarget.Member.Name
            }
            $valueForMember = Convert-AstExpressionAs -Node $Statement.Right -Type $memberTarget.Type -Scope $Scope
            return [Linq.Expressions.Expression]::Assign($memberTarget, $valueForMember)
        }

        $varName = $null
        $explicitType = $null

        if ($leftNode -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $varName = $leftNode.VariablePath.UserPath
        }
        elseif ($leftNode -is [System.Management.Automation.Language.ConvertExpressionAst] -and
                $leftNode.Child -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $explicitType = Resolve-AstType $leftNode.Type.TypeName
            $varName = $leftNode.Child.VariablePath.UserPath
        }
        else {
            throw "[{0}:{1}] Unsupported assignment target '{2}'." -f `
                $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber, $leftNode.Extent.Text
        }

        if (($varName -in '_', 'PSItem') -and $Scope.ContainsKey('SwitchItem')) {
            $value = Convert-AstExpressionAs -Node $Statement.Right -Type $Scope.SwitchItem.Type -Scope $Scope
            return [Linq.Expressions.Expression]::Assign($Scope.SwitchItem, $value)
        }

        $knownType = if ($explicitType) { $explicitType }
                     elseif ($Scope.Parameters.ContainsKey($varName)) { $Scope.Parameters[$varName].Type }
                     elseif ($Scope.Locals.ContainsKey($varName)) { $Scope.Locals[$varName].Type }
                     else { $null }
        $valExpr = if ($knownType) { Convert-AstExpressionAs -Node $Statement.Right -Type $knownType -Scope $Scope }
                   else { Convert-AstExpression -Node $Statement.Right -Scope $Scope }

        if ($explicitType -and $valExpr.Type -ne $explicitType) {
            $valExpr = (ConvertTo-PowerShellType -Expression $valExpr -Type ($explicitType))
        }

        $targetVar = $null
        if ($Scope.Parameters.ContainsKey($varName)) {
            $targetVar = $Scope.Parameters[$varName]
        }
        elseif ($Scope.Locals.ContainsKey($varName)) {
            $targetVar = $Scope.Locals[$varName]
        }
        else {
            $localType = if ($explicitType) { $explicitType } else { $valExpr.Type }
            $targetVar = [Linq.Expressions.Expression]::Variable($localType, $varName)
            $Scope.Locals[$varName] = $targetVar
            $Scope.DeclaredLocals.Add($targetVar)
        }

        if ($valExpr.Type -ne $targetVar.Type) {
            $valExpr = (ConvertTo-PowerShellType -Expression $valExpr -Type ($targetVar.Type))
        }

        return [Linq.Expressions.Expression]::Assign($targetVar, $valExpr)
    }

    # 2. Return statement
    if ($Statement -is [System.Management.Automation.Language.ReturnStatementAst]) {
        if ($null -eq $Statement.Pipeline) {
            # Void return
            if ($Scope.ReturnType -ne [void]) {
                throw "[{0}:{1}] Empty return statement in non-void method." -f `
                    $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber
            }
            return [Linq.Expressions.Expression]::Return($Scope.ReturnTarget)
        }

        $retVal = Convert-AstExpressionAs -Node $Statement.Pipeline -Type $Scope.ReturnType -Scope $Scope

        return [Linq.Expressions.Expression]::Return($Scope.ReturnTarget, $retVal)
    }

    # 3. Statement block: { stmt1; stmt2 }
    if ($Statement -is [System.Management.Automation.Language.StatementBlockAst]) {
        $stmtList = [System.Collections.Generic.List[Linq.Expressions.Expression]]::new()
        foreach ($s in $Statement.Statements) {
            $stmtList.Add((Convert-AstStatement -Statement $s -Scope $Scope))
        }
        $stmtList.Add([Linq.Expressions.Expression]::Empty())
        return [Linq.Expressions.Expression]::Block($stmtList)
    }

    # 4. If statement: if ($c) { $t } elseif ($c2) { $t2 } else { $e }
    if ($Statement -is [System.Management.Automation.Language.IfStatementAst]) {
        $elseExpr = if ($Statement.ElseClause) {
            Convert-AstStatement -Statement $Statement.ElseClause -Scope $Scope
        } else {
            [Linq.Expressions.Expression]::Empty()
        }

        $clauses = @($Statement.Clauses)
        for ($i = $clauses.Count - 1; $i -ge 0; $i--) {
            $cond = Convert-AstExpression -Node $clauses[$i].Item1 -Scope $Scope
            $then = Convert-AstStatement -Statement $clauses[$i].Item2 -Scope $Scope
            $elseExpr = [Linq.Expressions.Expression]::IfThenElse($cond, $then, $elseExpr)
        }

        return $elseExpr
    }

    # 5. For statement: for ($i = 0; $i -lt $n; $i++) { ... }
    if ($Statement -is [System.Management.Automation.Language.ForStatementAst]) {
        $blockStmts = [System.Collections.Generic.List[Linq.Expressions.Expression]]::new()

        if ($Statement.Initializer) {
            $blockStmts.Add((Convert-AstStatement -Statement $Statement.Initializer -Scope $Scope))
        }

        $breakLabel = [Linq.Expressions.Expression]::Label('forBreak')
        $continueLabel = [Linq.Expressions.Expression]::Label('forContinue')

        $condExpr = if ($Statement.Condition) {
            Convert-AstExpression -Node $Statement.Condition -Scope $Scope
        } else {
            [Linq.Expressions.Expression]::Constant($true, [bool])
        }

        $Scope.Loops.Push(@{ Break = $breakLabel; Continue = $continueLabel })
        try { $bodyExpr = Convert-AstStatement -Statement $Statement.Body -Scope $Scope }
        finally { $null = $Scope.Loops.Pop() }

        $iterExpr = if ($Statement.Iterator) {
            Convert-AstStatement -Statement $Statement.Iterator -Scope $Scope
        } else {
            [Linq.Expressions.Expression]::Empty()
        }

        $loopBody = [Linq.Expressions.Expression]::Block(
            $bodyExpr,
            [Linq.Expressions.Expression]::Label($continueLabel),
            $iterExpr,
            [Linq.Expressions.Expression]::Empty()
        )

        $loopExpr = [Linq.Expressions.Expression]::Loop(
            [Linq.Expressions.Expression]::IfThenElse(
                $condExpr,
                $loopBody,
                [Linq.Expressions.Expression]::Break($breakLabel)
            ),
            $breakLabel
        )

        $blockStmts.Add($loopExpr)
        $blockStmts.Add([Linq.Expressions.Expression]::Empty())
        return [Linq.Expressions.Expression]::Block($blockStmts)
    }

    # 6. While statement: while ($cond) { ... }
    if ($Statement -is [System.Management.Automation.Language.WhileStatementAst]) {
        $breakLabel = [Linq.Expressions.Expression]::Label('whileBreak')
        $continueLabel = [Linq.Expressions.Expression]::Label('whileContinue')

        $condExpr = Convert-AstExpression -Node $Statement.Condition -Scope $Scope
        $Scope.Loops.Push(@{ Break = $breakLabel; Continue = $continueLabel })
        try { $bodyExpr = Convert-AstStatement -Statement $Statement.Body -Scope $Scope }
        finally { $null = $Scope.Loops.Pop() }

        $loopBody = [Linq.Expressions.Expression]::Block(
            $bodyExpr,
            [Linq.Expressions.Expression]::Empty()
        )

        return [Linq.Expressions.Expression]::Loop(
            [Linq.Expressions.Expression]::IfThenElse(
                $condExpr,
                $loopBody,
                [Linq.Expressions.Expression]::Break($breakLabel)
            ),
            $breakLabel,
            $continueLabel
        )
    }

    # 7. Throw statement: throw <expr>
    if ($Statement -is [System.Management.Automation.Language.ThrowStatementAst]) {
        if ($Statement.Pipeline) {
            $exExpr = Convert-AstExpression -Node $Statement.Pipeline -Scope $Scope
            # ClrOnly string-throw contract: preserve the supplied message in
            # InvalidOperationException. SMA RuntimeException identity is not
            # preserved. The admission pass rejects SMA-dependent catches.
            if ($exExpr.Type -eq [string]) {
                $ctor = [InvalidOperationException].GetConstructor([type[]]@([string]))
                $exception = $script:ExpressionNewMethod.Invoke($null, [object[]]@($ctor, [Linq.Expressions.Expression[]]@($exExpr)))
                return [Linq.Expressions.Expression]::Throw($exception, [void])
            }
            # Explicit CoreLib exception construction retains the previously
            # admitted structured-exception contract (Slice8Fixture). This
            # does not admit exception variables or ErrorRecord operands.
            $operand = $Statement.Pipeline
            while ($operand -is [System.Management.Automation.Language.PipelineAst] -or
                   $operand -is [System.Management.Automation.Language.CommandExpressionAst] -or
                   $operand -is [System.Management.Automation.Language.ParenExpressionAst]) {
                if ($operand -is [System.Management.Automation.Language.PipelineAst]) { $operand = $operand.PipelineElements[0] }
                elseif ($operand -is [System.Management.Automation.Language.CommandExpressionAst]) { $operand = $operand.Expression }
                else { $operand = $operand.Pipeline }
            }
            if ($operand -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst] -or
                -not $operand.Static -or $operand.Member.Value -ne 'new' -or
                -not [Exception].IsAssignableFrom($exExpr.Type) -or $exExpr.Type.Assembly -ne [object].Assembly) {
                throw "[$($Statement.Extent.File):$($Statement.Extent.StartLineNumber)] Non-string throw operand requires a separate admission decision."
            }
            return [Linq.Expressions.Expression]::Throw($exExpr, [void])
        } else {
            throw "[$($Statement.Extent.File):$($Statement.Extent.StartLineNumber)] Rethrow requires a separate admission decision."
        }
    }

    # 8. Try / Catch / Finally statement
    if ($Statement -is [System.Management.Automation.Language.TryStatementAst]) {
        $tryBody = Convert-AstStatement -Statement $Statement.Body -Scope $Scope

        $catchBlocks = [System.Collections.Generic.List[Linq.Expressions.CatchBlock]]::new()
        if ($Statement.CatchClauses) {
            foreach ($cc in $Statement.CatchClauses) {
                $catchType = [System.Exception]
                if ($cc.CatchTypes -and $cc.CatchTypes.Count -gt 0) {
                    $catchType = Resolve-AstType $cc.CatchTypes[0].TypeName
                }
                $catchBody = Convert-AstStatement -Statement $cc.Body -Scope $Scope
                $catchBlocks.Add([Linq.Expressions.Expression]::Catch($catchType, $catchBody))
            }
        }

        $finallyBody = if ($Statement.Finally) {
            Convert-AstStatement -Statement $Statement.Finally -Scope $Scope
        } else {
            $null
        }

        if ($finallyBody) {
            return [Linq.Expressions.Expression]::TryCatchFinally(
                $tryBody,
                $finallyBody,
                [Linq.Expressions.CatchBlock[]]$catchBlocks.ToArray()
            )
        }
        else {
            return [Linq.Expressions.Expression]::TryCatch(
                $tryBody,
                [Linq.Expressions.CatchBlock[]]$catchBlocks.ToArray()
            )
        }
    }

    # 9. Pipeline statement (single expression evaluated as statement)
    if ($Statement -is [System.Management.Automation.Language.PipelineAst]) {
        return Convert-AstExpression -Node $Statement -Scope $Scope
    }

    # 10. foreach ($item in $array) { ... } over a typed one-dimensional array,
    # lowered as an indexed loop. As in PowerShell, a $null array iterates zero
    # times, and the loop variable keeps its last value afterwards.
    if ($Statement -is [System.Management.Automation.Language.ForEachStatementAst]) {
        if ($Statement.Flags -ne [System.Management.Automation.Language.ForEachFlags]::None) {
            throw "[{0}:{1}] foreach -parallel is not supported." -f $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber
        }
        $collection = Convert-AstExpression -Node $Statement.Condition -Scope $Scope
        if (-not $collection.Type.IsArray -or $collection.Type.GetArrayRank() -ne 1) {
            throw "[{0}:{1}] foreach requires a typed one-dimensional array, got '{2}'." -f `
                $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber, $collection.Type.FullName
        }
        $elementType = $collection.Type.GetElementType()
        $varName = $Statement.Variable.VariablePath.UserPath
        $item = if ($Scope.Parameters.ContainsKey($varName)) { $Scope.Parameters[$varName] }
                elseif ($Scope.Locals.ContainsKey($varName)) { $Scope.Locals[$varName] }
                else {
                    $declared = [Linq.Expressions.Expression]::Variable($elementType, $varName)
                    $Scope.Locals[$varName] = $declared
                    $Scope.DeclaredLocals.Add($declared)
                    $declared
                }
        $id = $Scope.DeclaredLocals.Count
        $array = [Linq.Expressions.Expression]::Variable($collection.Type, "foreachArray$id")
        $index = [Linq.Expressions.Expression]::Variable([int], "foreachIndex$id")
        $Scope.DeclaredLocals.Add($array)
        $Scope.DeclaredLocals.Add($index)
        $breakLabel = [Linq.Expressions.Expression]::Label("foreachBreak$id")
        $continueLabel = [Linq.Expressions.Expression]::Label("foreachContinue$id")

        $Scope.Loops.Push(@{ Break = $breakLabel; Continue = $continueLabel })
        try { $bodyExpr = Convert-AstStatement -Statement $Statement.Body -Scope $Scope }
        finally { $null = $Scope.Loops.Pop() }

        $current = (ConvertTo-PowerShellType -Expression ([Linq.Expressions.Expression]::ArrayIndex($array, $index)) -Type $item.Type)
        $loopBody = [Linq.Expressions.Expression]::Block(
            [Linq.Expressions.Expression]::Assign($item, $current),
            $bodyExpr,
            [Linq.Expressions.Expression]::Label($continueLabel),
            [Linq.Expressions.Expression]::Assign($index, [Linq.Expressions.Expression]::Add($index, [Linq.Expressions.Expression]::Constant(1))),
            [Linq.Expressions.Expression]::Empty())
        $loop = [Linq.Expressions.Expression]::Loop(
            [Linq.Expressions.Expression]::IfThenElse(
                [Linq.Expressions.Expression]::LessThan($index, [Linq.Expressions.Expression]::ArrayLength($array)),
                $loopBody,
                [Linq.Expressions.Expression]::Break($breakLabel)),
            $breakLabel)
        return [Linq.Expressions.Expression]::Block(
            [Linq.Expressions.Expression]::Assign($array, $collection),
            [Linq.Expressions.Expression]::Assign($index, [Linq.Expressions.Expression]::Constant(0)),
            [Linq.Expressions.Expression]::IfThen(
                [Linq.Expressions.Expression]::NotEqual($array, [Linq.Expressions.Expression]::Constant($null, $collection.Type)),
                $loop),
            [Linq.Expressions.Expression]::Empty())
    }

    # 11. break and continue leave or restart the innermost loop.
    if ($Statement -is [System.Management.Automation.Language.BreakStatementAst] -or
        $Statement -is [System.Management.Automation.Language.ContinueStatementAst]) {
        $keyword = if ($Statement -is [System.Management.Automation.Language.BreakStatementAst]) { 'break' } else { 'continue' }
        if ($Statement.Label) {
            throw "[{0}:{1}] Labeled {2} is not supported." -f $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber, $keyword
        }
        if ($Scope.Loops.Count -eq 0) {
            throw "[{0}:{1}] {2} outside a loop is not supported." -f $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber, $keyword
        }
        $loopLabels = $Scope.Loops.Peek()
        if ($keyword -eq 'break') { return [Linq.Expressions.Expression]::Break($loopLabels.Break) }
        return [Linq.Expressions.Expression]::Continue($loopLabels.Continue)
    }

    # A keyword statement, 'keyword Name { ... }', lowers to a call of the method that declares the keyword
    # (see Get-LoweringKeywords) with the name and the properties in parameter order; a script body then runs inline.
    if ($Statement -is [System.Management.Automation.Language.DynamicKeywordStatementAst]) {
        $elements = $Statement.CommandElements
        $keywordName = $elements[0].Value
        if (-not $script:LoweringKeywords.ContainsKey($keywordName)) {
            throw "[{0}:{1}] Keyword '{2}' is not declared by a [Keyword()] method in this source." -f $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber, $keywordName
        }
        $definition = $script:LoweringKeywords[$keywordName]
        if ($elements.Count -ne 3 -or $elements[1] -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
            throw "[{0}:{1}] Keyword '{2}' needs a literal name and a body." -f $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber, $keywordName
        }
        $body = $elements[2]
        $arguments = [System.Collections.Generic.List[Linq.Expressions.Expression]]::new()
        $arguments.Add([Linq.Expressions.Expression]::Constant($elements[1].Value, [string]))
        if ($body -is [System.Management.Automation.Language.HashtableAst]) {
            $values = @{}
            foreach ($pair in $body.KeyValuePairs) { $values[[string]$pair.Item1.SafeGetValue()] = $pair.Item2 }
            $declared = @($definition.Properties | ForEach-Object { $_.Name.VariablePath.UserPath })
            foreach ($key in $values.Keys) {
                if ($key -notin $declared) { throw "[{0}:{1}] Keyword '{2}' has no property '{3}'." -f $body.Extent.StartLineNumber, $body.Extent.StartColumnNumber, $keywordName, $key }
            }
            foreach ($parameter in $definition.Properties) {
                $propertyName = $parameter.Name.VariablePath.UserPath
                if (-not $values.ContainsKey($propertyName)) { throw "[{0}:{1}] Keyword '{2}' needs property '{3}'." -f $body.Extent.StartLineNumber, $body.Extent.StartColumnNumber, $keywordName, $propertyName }
                $constraint = $parameter.Attributes | Where-Object { $_ -is [System.Management.Automation.Language.TypeConstraintAst] } | Select-Object -First 1
                $arguments.Add((Convert-AstExpressionAs -Node $values[$propertyName] -Type (Resolve-AstType $constraint.TypeName) -Scope $Scope))
            }
        }
        $parts = [System.Collections.Generic.List[Linq.Expressions.Expression]]::new()
        $method = Resolve-MatchingMethod -TargetType $script:LoweringClassTypes[$definition.Class] -MethodName $definition.Name -ArgumentTypes ([Type[]]@($arguments | ForEach-Object Type)) -IsStatic
        $parts.Add([Linq.Expressions.Expression]::Call($method, [Linq.Expressions.Expression[]]$arguments.ToArray()))
        if ($body -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
            foreach ($inner in $body.ScriptBlock.EndBlock.Statements) { $parts.Add((Convert-AstStatement -Statement $inner -Scope $Scope)) }
        }
        $parts.Add([Linq.Expressions.Expression]::Empty())
        return [Linq.Expressions.Expression]::Block([Linq.Expressions.Expression[]]$parts.ToArray())
    }

    # 12. switch over an integer or enum value with constant clauses. As in PowerShell, every matching
    # clause runs in order, break or continue leaves the switch, and default runs when nothing matched.
    if ($Statement -is [System.Management.Automation.Language.SwitchStatementAst]) {
        if ($Statement.Flags -ne [System.Management.Automation.Language.SwitchFlags]::None) {
            throw "[{0}:{1}] switch options are not supported." -f $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber
        }
        $subject = Convert-AstExpression -Node $Statement.Condition -Scope $Scope
        if ($subject.Type -notin $script:IntegralTypes -and -not $subject.Type.IsEnum) {
            throw "[{0}:{1}] switch requires an integer or enum value, got '{2}'." -f $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber, $subject.Type.FullName
        }
        $id = $Scope.DeclaredLocals.Count
        $value = [Linq.Expressions.Expression]::Variable($subject.Type, "switchValue$id")
        $matched = [Linq.Expressions.Expression]::Variable([bool], "switchMatched$id")
        $Scope.DeclaredLocals.Add($value)
        $Scope.DeclaredLocals.Add($matched)
        $endLabel = [Linq.Expressions.Expression]::Label("switchEnd$id")
        $parts = [System.Collections.Generic.List[Linq.Expressions.Expression]]::new()
        $parts.Add([Linq.Expressions.Expression]::Assign($value, $subject))
        $parts.Add([Linq.Expressions.Expression]::Assign($matched, [Linq.Expressions.Expression]::Constant($false)))
        $Scope.Loops.Push(@{ Break = $endLabel; Continue = $endLabel })
        try {
            foreach ($clause in $Statement.Clauses) {
                $left = [Linq.Expressions.Expression]$value
                $right = Convert-AstExpression -Node $clause.Item1 -Scope $Scope
                if ($left.Type.IsEnum -and $right.Type -ne $left.Type) { $left = [Linq.Expressions.Expression]::Convert($left, [Enum]::GetUnderlyingType($left.Type)) }
                if ($right.Type.IsEnum -and $right.Type -ne $left.Type) { $right = [Linq.Expressions.Expression]::Convert($right, [Enum]::GetUnderlyingType($right.Type)) }
                $widened = $script:PscEnvironment.Get('NumericOperands').Bind([PscOperatorKind]::Comparison, $left, $right)
                if ($widened) { $left = $widened.Left; $right = $widened.Right }
                if ($left.Type -ne $right.Type) {
                    throw "[{0}:{1}] switch clause type '{2}' does not match the value's type '{3}'." -f $clause.Item1.Extent.StartLineNumber, $clause.Item1.Extent.StartColumnNumber, $right.Type.FullName, $value.Type.FullName
                }
                $body = Convert-AstStatement -Statement $clause.Item2 -Scope $Scope
                $parts.Add([Linq.Expressions.Expression]::IfThen([Linq.Expressions.Expression]::Equal($left, $right),
                    [Linq.Expressions.Expression]::Block([Linq.Expressions.Expression]::Assign($matched, [Linq.Expressions.Expression]::Constant($true)), $body, [Linq.Expressions.Expression]::Empty())))
            }
            if ($Statement.Default) {
                $parts.Add([Linq.Expressions.Expression]::IfThen([Linq.Expressions.Expression]::Not($matched), (Convert-AstStatement -Statement $Statement.Default -Scope $Scope)))
            }
        }
        finally { $null = $Scope.Loops.Pop() }
        $parts.Add([Linq.Expressions.Expression]::Label($endLabel))
        return [Linq.Expressions.Expression]::Block([Linq.Expressions.Expression[]]$parts.ToArray())
    }

    throw "[{0}:{1}] Unsupported AST statement '{2}' ({3})." -f `
        $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber, $Statement.Extent.Text, $Statement.GetType().Name
}

function Convert-MethodAstToLambda {
    <#
    .SYNOPSIS
        Lowers a method or constructor of a PowerShell class into a LambdaExpression.
    .DESCRIPTION
        Types are resolved against the mirror of every class in the method's
        source, so the method may use those classes and their members. An
        instance method or constructor takes the instance as its first lambda
        parameter, named 'this', which the emitter maps to argument 0. A
        constructor first runs -Initializers, the instance properties' initial
        values, as PowerShell does before the constructor body.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.FunctionMemberAst] $MethodAst,

        [Parameter()]
        [System.Management.Automation.Language.PropertyMemberAst[]] $Initializers = @()
    )

    Use-ClassMirror -Ast $MethodAst
    Test-AstAdmitted -Ast $MethodAst

    $classType = $script:LoweringClassTypes[$MethodAst.Parent.Name]
    $retType = if ($MethodAst.IsConstructor) { [void] }
               elseif ($MethodAst.ReturnType) { Resolve-AstType $MethodAst.ReturnType.TypeName }
               else { [void] }

    $paramExprList = [System.Collections.Generic.List[Linq.Expressions.ParameterExpression]]::new()
    $paramMap = @{}
    foreach ($p in $MethodAst.Parameters) {
        $tc = $p.Attributes | Where-Object { $_ -is [System.Management.Automation.Language.TypeConstraintAst] } | Select-Object -First 1
        $pType = if ($tc) { Resolve-AstType $tc.TypeName } else { [object] }
        $pName = $p.Name.VariablePath.UserPath
        $pExpr = [Linq.Expressions.Expression]::Parameter($pType, $pName)
        $paramExprList.Add($pExpr)
        $paramMap[$pName] = $pExpr
    }

    $native = Get-NativeMethodContract $MethodAst
    if ($native -and $native.Kind -eq 'Calli') {
        if ($Mode -eq 'Expression') { throw ('[{0}:{1}] Native indirect-call stubs require Compile mode.' -f $MethodAst.Extent.StartLineNumber,$MethodAst.Extent.StartColumnNumber) }
        $method = $classType.GetMethod($MethodAst.Name,[Type[]]$native.ParameterTypes)
        $call = [Linq.Expressions.Expression]::Call($method,[Linq.Expressions.Expression[]]$paramExprList.ToArray())
        $script:NativeExpressions.Add($call,$native)
        return [pscustomobject]@{Name=$MethodAst.Name; Lambda=[Linq.Expressions.Expression]::Lambda($call,$paramExprList.ToArray()); IsStatic=$true; HasThis=$false; ReturnType=$retType; ParameterTypes=$native.ParameterTypes}
    }

    $thisParam = if ($MethodAst.IsStatic) { $null } else { [Linq.Expressions.Expression]::Parameter($classType, 'this') }
    New-LoweredBody -Name $MethodAst.Name -ReturnType $retType -This $thisParam -Parameters $paramExprList -ParameterMap $paramMap `
        -Initializers $Initializers -Statements @($(if ($MethodAst.Body -and $MethodAst.Body.EndBlock) { $MethodAst.Body.EndBlock.Statements })) `
        -IsStatic ([bool]$MethodAst.IsStatic) -IsConstructor ([bool]$MethodAst.IsConstructor)
}

function Convert-InitializersToLambda {
    <#
    .SYNOPSIS
        Lowers property initial values on their own: the static initializer
        (-Static) or the implicit constructor of a class that declares none.
    #>
    param(
        [Parameter(Mandatory)][System.Management.Automation.Language.TypeDefinitionAst] $ClassAst,
        [Parameter()][System.Management.Automation.Language.PropertyMemberAst[]] $Initializers = @(),
        [switch] $Static
    )
    Use-ClassMirror -Ast $ClassAst
    $classType = $script:LoweringClassTypes[$ClassAst.Name]
    $thisParam = if ($Static) { $null } else { [Linq.Expressions.Expression]::Parameter($classType, 'this') }
    New-LoweredBody -Name $(if ($Static) { '.cctor' } else { '.ctor' }) -ReturnType ([void]) -This $thisParam `
        -Parameters ([System.Collections.Generic.List[Linq.Expressions.ParameterExpression]]::new()) -ParameterMap @{} `
        -Initializers $Initializers -Statements @() -IsStatic ([bool]$Static) -IsConstructor $true
}

function New-LoweredBody {
    param(
        [string] $Name, [Type] $ReturnType, $This,
        [System.Collections.Generic.List[Linq.Expressions.ParameterExpression]] $Parameters, [hashtable] $ParameterMap,
        [System.Management.Automation.Language.PropertyMemberAst[]] $Initializers, [object[]] $Statements,
        [bool] $IsStatic, [bool] $IsConstructor
    )

    $returnTarget = [Linq.Expressions.Expression]::Label($ReturnType, 'returnTarget')
    $declaredLocals = [System.Collections.Generic.List[Linq.Expressions.ParameterExpression]]::new()
    $scope = @{
        ReturnType     = $ReturnType
        ReturnTarget   = $returnTarget
        Parameters     = $ParameterMap
        Locals         = @{}
        DeclaredLocals = $declaredLocals
        Loops          = [System.Collections.Generic.Stack[object]]::new()
        This           = $This
    }

    $body = [System.Collections.Generic.List[Linq.Expressions.Expression]]::new()
    foreach ($p in $Initializers) {
        if (-not $p.InitialValue) { continue }
        $classType = $script:LoweringClassTypes[$p.Parent.Name]
        $field = $classType.GetField($p.Name, [Reflection.BindingFlags]'Public,Static,Instance')
        $value = Convert-AstExpressionAs -Node $p.InitialValue -Type $field.FieldType -Scope $scope
        $target = if ($field.IsStatic) { $null } else { $This }
        $body.Add([Linq.Expressions.Expression]::Assign([Linq.Expressions.Expression]::Field($target, $field), $value))
    }
    foreach ($stmt in $Statements) {
        if ($null -eq $stmt) { continue }
        # The parser opens every constructor with an implicit base() call; the
        # emitter calls System.Object's constructor, the only base supported.
        if ($stmt -is [System.Management.Automation.Language.CommandExpressionAst] -and
            $stmt.Expression -is [System.Management.Automation.Language.BaseCtorInvokeMemberExpressionAst]) {
            if ($stmt.Expression.Arguments -and @($stmt.Expression.Arguments).Count) {
                throw "[{0}:{1}] A base constructor call with arguments is not supported." -f $stmt.Extent.StartLineNumber, $stmt.Extent.StartColumnNumber
            }
            continue
        }
        $body.Add((Convert-AstStatement -Statement $stmt -Scope $scope))
    }
    $defaultVal = if ($ReturnType -eq [void]) { [Linq.Expressions.Expression]::Empty() } else { [Linq.Expressions.Expression]::Default($ReturnType) }
    $body.Add([Linq.Expressions.Expression]::Label($returnTarget, $defaultVal))

    $bodyBlock = [Linq.Expressions.Expression]::Block($ReturnType,
        [Linq.Expressions.ParameterExpression[]]$declaredLocals.ToArray(),
        [Linq.Expressions.Expression[]]$body.ToArray())
    $lambdaParameters = [System.Collections.Generic.List[Linq.Expressions.ParameterExpression]]::new()
    if ($This) { $lambdaParameters.Add($This) }
    foreach ($p in $Parameters) { $lambdaParameters.Add($p) }
    $lambda = [Linq.Expressions.Expression]::Lambda($bodyBlock, $Name, [Linq.Expressions.ParameterExpression[]]$lambdaParameters.ToArray())

    [pscustomobject]@{
        Name           = $Name
        IsStatic       = $IsStatic
        IsConstructor  = $IsConstructor
        HasThis        = [bool]$This
        ReturnType     = $ReturnType
        ParameterTypes = [Type[]]@($Parameters | ForEach-Object { $_.Type })
        ParameterNames = [string[]]@($Parameters | ForEach-Object { $_.Name })
        Lambda         = $lambda
    }
}

function Set-DeterministicMvid {
    <#
    .SYNOPSIS
        Applies a deterministic Module Version ID (MVID) and zeroes PE timestamp.
    .DESCRIPTION
        Clears the PE header TimeDateStamp, locates the MVID in the metadata heap,
        computes SHA-256 over the blanked assembly bytes, formats the first 16 bytes
        as an RFC 4122 v4 variant 1 GUID, and writes it back into the binary.
    #>
    param(
        [Parameter(Mandatory)]
        [byte[]] $Assembly
    )

    if ($Assembly.Length -lt 0x40) {
        throw 'The byte array is too short to be a valid PE file.'
    }

    # COFF header: e_lfanew at 0x3C, then PE signature 'PE\0\0' (0x00004550),
    # then Machine (2 bytes), NumberOfSections (2 bytes), TimeDateStamp (4 bytes).
    $peOffset = [BitConverter]::ToInt32($Assembly, 0x3C)
    if ($peOffset -lt 0 -or $peOffset -ge ($Assembly.Length - 12)) {
        throw 'Invalid e_lfanew PE header offset.'
    }

    if ([BitConverter]::ToUInt32($Assembly, $peOffset) -ne 0x00004550) {
        throw 'The assembly does not carry a valid PE signature where its DOS header points.'
    }

    $timestampOffset = $peOffset + 8
    $result = [byte[]]$Assembly.Clone()
    for ($i = 0; $i -lt 4; $i++) {
        $result[$timestampOffset + $i] = 0
    }

    $stream = [System.IO.MemoryStream]::new($result, $false)
    $peReader = [System.Reflection.PortableExecutable.PEReader]::new($stream)
    try {
        $reader = [System.Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($peReader)
        $current = $reader.GetGuid($reader.GetModuleDefinition().Mvid).ToByteArray()
    }
    finally {
        $peReader.Dispose()
        $stream.Dispose()
    }

    # Locate the exact 16-byte MVID occurrence in the binary
    $matches = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i -le ($result.Length - 16); $i++) {
        if ($result[$i] -ne $current[0]) { continue }
        $same = $true
        for ($j = 1; $j -lt 16; $j++) {
            if ($result[$i + $j] -ne $current[$j]) {
                $same = $false
                break
            }
        }
        if ($same) {
            $matches.Add($i)
        }
    }

    if ($matches.Count -ne 1) {
        throw "The module version id appears $($matches.Count) times in the assembly; exactly one occurrence is required."
    }
    $offset = $matches[0]

    # Blank the 16 MVID bytes for hashing
    $blanked = [byte[]]$result.Clone()
    for ($j = 0; $j -lt 16; $j++) {
        $blanked[$offset + $j] = 0
    }

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha256.ComputeHash($blanked)
    }
    finally {
        $sha256.Dispose()
    }

    $mvid = [byte[]]::new(16)
    [System.Array]::Copy($digest, 0, $mvid, 0, 16)
    # Format as RFC 4122 v4 variant 1 GUID
    $mvid[7] = [byte](($mvid[7] -band 0x0F) -bor 0x40)
    $mvid[8] = [byte](($mvid[8] -band 0x3F) -bor 0x80)

    [System.Array]::Copy($mvid, 0, $result, $offset, 16)
    return ,$result
}

function New-PersistedAssemblySession {
    <#
    .SYNOPSIS
        Creates a new PersistedAssemblyBuilder session.
    #>
    param(
        [Parameter(Mandatory)][string] $AssemblyName,
        [Parameter()][Reflection.Assembly] $CoreAssembly = [object].Assembly
    )

    $an = [Reflection.AssemblyName]::new($AssemblyName)
    $builder = [Reflection.Emit.PersistedAssemblyBuilder]::new($an, $CoreAssembly)
    $module = $builder.DefineDynamicModule("$AssemblyName.dll")

    [pscustomobject]@{
        AssemblyName = $AssemblyName
        Builder      = $builder
        Module       = $module
        Types        = [System.Collections.Generic.Dictionary[string, Reflection.Emit.TypeBuilder]]::new()
    }
}

function Save-PersistedAssemblySession {
    <#
    .SYNOPSIS
        Saves the PersistedAssemblyBuilder session to the specified output path.
    .DESCRIPTION
        Creates types, serializes to a MemoryStream, applies deterministic MVID
        if requested, and writes atomically to disk using a temporary file.
    #>
    param(
        [Parameter(Mandatory)]
        [psobject] $Session,

        [Parameter(Mandatory)]
        [string] $OutputPath,

        [switch] $Deterministic = $true,

        # A static method to mark as the entry point. The image is then an
        # executable rather than a library; without it the bytes are exactly
        # what PersistedAssemblyBuilder.Save writes.
        [Parameter()][Reflection.Emit.MethodBuilder] $EntryPoint
    )

    $fullOut = if ([IO.Path]::IsPathFullyQualified($OutputPath)) {
        [IO.Path]::GetFullPath($OutputPath)
    }
    else {
        [IO.Path]::GetFullPath((Join-Path (Get-Location) $OutputPath))
    }

    $outDir = [IO.Path]::GetDirectoryName($fullOut)
    if ($outDir -and -not [IO.Directory]::Exists($outDir)) {
        [IO.Directory]::CreateDirectory($outDir) | Out-Null
    }

    # Ensure all defined types are created
    foreach ($tb in $Session.Types.Values) {
        if (-not $tb.IsCreated()) {
            $null = $tb.CreateType()
        }
    }

    if ($EntryPoint) {
        # PersistedAssemblyBuilder.Save always writes a library with no entry
        # point (WritePEImage, runtime ab194157). An executable is the same
        # metadata serialized by ManagedPEBuilder with an executable header
        # and the entry method's handle, which exists once metadata is built.
        $ilStream = $null
        $fieldData = $null
        $metadata = $Session.Builder.GenerateMetadata([ref]$ilStream, [ref]$fieldData)
        if ($EntryPoint.MetadataToken -eq 0) {
            throw "Entry point '$($EntryPoint.Name)' has no metadata token after metadata generation."
        }
        $entryHandle = [Reflection.Metadata.Ecma335.MetadataTokens]::MethodDefinitionHandle($EntryPoint.MetadataToken -band 0x00FFFFFF)
        $peBuilder = [Reflection.PortableExecutable.ManagedPEBuilder]::new(
            [Reflection.PortableExecutable.PEHeaderBuilder]::CreateExecutableHeader(),
            [Reflection.Metadata.Ecma335.MetadataRootBuilder]::new($metadata),
            $ilStream, $fieldData, $null, $null, $null, 0, $entryHandle)
        $peBlob = [Reflection.Metadata.BlobBuilder]::new()
        $null = $peBuilder.Serialize($peBlob)
        $bytes = $peBlob.ToArray()
    }
    else {
        $ms = [IO.MemoryStream]::new()
        try {
            $Session.Builder.Save($ms)
            $bytes = $ms.ToArray()
        }
        finally {
            $ms.Dispose()
        }
    }

    if ($Deterministic) {
        $bytes = Set-DeterministicMvid -Assembly $bytes
    }

    # Atomic file write to avoid partial artifacts on failure
    $tempFile = [IO.Path]::Combine($outDir, [IO.Path]::GetRandomFileName() + '.tmp')
    try {
        [IO.File]::WriteAllBytes($tempFile, $bytes)
        [IO.File]::Move($tempFile, $fullOut, $true)
    }
    finally {
        if ([IO.File]::Exists($tempFile)) {
            [IO.File]::Delete($tempFile)
        }
    }

    # An executable runs on the shared framework it was compiled against: the
    # runtime configuration names that framework and its exact version.
    $runtimeConfigPath = $null
    if ($EntryPoint) {
        $runtimeVersion = ([object].Assembly.GetCustomAttributes([Reflection.AssemblyInformationalVersionAttribute], $false)[0].InformationalVersion -split '\+')[0]
        $runtimeConfigPath = [IO.Path]::ChangeExtension($fullOut, '.runtimeconfig.json')
        $runtimeConfig = [ordered]@{
            runtimeOptions = [ordered]@{
                tfm       = "net$([Environment]::Version.Major).$([Environment]::Version.Minor)"
                framework = [ordered]@{ name = 'Microsoft.NETCore.App'; version = $runtimeVersion }
            }
        }
        [IO.File]::WriteAllText($runtimeConfigPath, ($runtimeConfig | ConvertTo-Json -Depth 4))
    }

    $sha256 = [Security.Cryptography.SHA256]::HashData($bytes)
    $hexHash = [BitConverter]::ToString($sha256).Replace('-', '')

    [pscustomobject]@{
        OutputPath   = $fullOut
        Length       = $bytes.Length
        SHA256       = $hexHash
        Deterministic = [bool]$Deterministic
        EntryPoint    = if ($EntryPoint) { $EntryPoint.Name } else { $null }
        RuntimeConfig = $runtimeConfigPath
    }
}

# Mirror member -> output member for the classes being compiled together, set
# by Export-LoweredAssembly for one compilation. Empty: operands pass through.
$script:IlMap = @{ Types = @{}; Members = @{} }

function Get-IlType([Type] $Type) {
    if ($null -eq $Type) { return $null }
    if ($script:IlMap.Types.ContainsKey($Type)) { return $script:IlMap.Types[$Type] }
    if ($Type.IsArray) {
        $element = Get-IlType $Type.GetElementType()
        if ($element -ne $Type.GetElementType()) { return $(if ($Type.GetArrayRank() -eq 1) { $element.MakeArrayType() } else { $element.MakeArrayType($Type.GetArrayRank()) }) }
        return $Type
    }
    if ($Type.IsConstructedGenericType) {
        $arguments = [Type[]]@($Type.GetGenericArguments() | ForEach-Object { Get-IlType $_ })
        $changed = $false
        $original = $Type.GetGenericArguments()
        for ($i = 0; $i -lt $arguments.Length; $i++) { if ($arguments[$i] -ne $original[$i]) { $changed = $true } }
        if ($changed) { return $Type.GetGenericTypeDefinition().MakeGenericType($arguments) }
    }
    if ($Type.Assembly.GetName().Name -like 'PSLoweringMirror*') { throw "Type '$($Type.Name)' has no compiled counterpart." }
    $Type
}

function Get-IlMember([Reflection.MemberInfo] $Member) {
    if ($script:IlMap.Members.ContainsKey($Member)) { return $script:IlMap.Members[$Member] }
    if ($script:IlMap.ContainsKey('ImplicitConstructors') -and $script:IlMap.ImplicitConstructors.ContainsKey($Member)) {
        # Reflection.Emit normally adds this constructor when the type is completed. Materialize it only when
        # an authored call needs its token; untouched historical outputs retain their original metadata order.
        $builder = $script:IlMap.ImplicitConstructors[$Member].DefineDefaultConstructor([Reflection.MethodAttributes]::Public)
        $script:IlMap.Members[$Member] = $builder
        $null = $script:IlMap.ImplicitConstructors.Remove($Member)
        return $builder
    }
    if ($Member.DeclaringType -and $Member.DeclaringType.Assembly.GetName().Name -like 'PSLoweringMirror*') {
        throw "'$($Member.DeclaringType.Name).$($Member.Name)' is used but not compiled; was it left out with -MethodNames?"
    }
    $declaring = $Member.DeclaringType
    if ($Member -is [Reflection.MethodInfo] -and $Member.IsConstructedGenericMethod -and -not $declaring.IsConstructedGenericType) {
        $originalArguments = $Member.GetGenericArguments()
        $mappedArguments = [Type[]]@($originalArguments | ForEach-Object { Get-IlType $_ })
        for ($i = 0; $i -lt $originalArguments.Length; $i++) {
            if ($originalArguments[$i] -ne $mappedArguments[$i]) {
                return $Member.GetGenericMethodDefinition().MakeGenericMethod($mappedArguments)
            }
        }
    }
    if ($declaring -and $declaring.IsConstructedGenericType) {
        $mapped = Get-IlType $declaring
        if ($mapped -ne $declaring) {
            if ($Member -is [Reflection.MethodInfo] -and $Member.IsGenericMethod) {
                throw "Generic method '$($Member.Name)' on '$($declaring.Name)' over a compiled class is not supported."
            }
            # A member of a constructed type shares its definition's metadata token.
            $definition = $declaring.GetGenericTypeDefinition().GetMembers([Reflection.BindingFlags]'Public,NonPublic,Instance,Static') |
                Where-Object { $_.MetadataToken -eq $Member.MetadataToken -and $_.Module -eq $Member.Module } | Select-Object -First 1
            if (-not $definition) { throw "No definition found for '$($Member.Name)' on '$($declaring.Name)'." }
            if ($Member -is [Reflection.ConstructorInfo]) { return [Reflection.Emit.TypeBuilder]::GetConstructor($mapped, $definition) }
            if ($Member -is [Reflection.MethodInfo]) { return [Reflection.Emit.TypeBuilder]::GetMethod($mapped, $definition) }
            if ($Member -is [Reflection.FieldInfo]) { return [Reflection.Emit.TypeBuilder]::GetField($mapped, $definition) }
        }
    }
    $Member
}

# A call's receiver: a reference is loaded; a value type is addressed in its own storage (local, argument,
# field, array element), so mutations reach it, or else copied once to a temporary.
function Write-IlReceiver {
    param([Reflection.Emit.ILGenerator] $IL, [Linq.Expressions.Expression] $Expr, [hashtable] $Context)
    if (-not $Expr.Type.IsValueType) {
        Write-IlExpression -IL $IL -Expr $Expr -Context $Context
        return
    }
    if ($Expr -is [Linq.Expressions.ParameterExpression]) {
        if ($Context.Locals.ContainsKey($Expr)) {
            $IL.Emit([Reflection.Emit.OpCodes]::Ldloca, $Context.Locals[$Expr])
            return
        }
        if ($Context.Parameters.ContainsKey($Expr)) {
            $IL.Emit([Reflection.Emit.OpCodes]::Ldarga, [int16]$Context.Parameters[$Expr])
            return
        }
        throw "No storage for value-type receiver '$($Expr.Name)'."
    }
    if ($Expr -is [Linq.Expressions.MemberExpression] -and $Expr.Member -is [Reflection.FieldInfo] -and
        -not $Expr.Member.IsInitOnly -and -not $Expr.Member.IsLiteral) {
        if ($Expr.Expression) {
            Write-IlReceiver -IL $IL -Expr $Expr.Expression -Context $Context
            $IL.Emit([Reflection.Emit.OpCodes]::Ldflda, (Get-IlMember $Expr.Member))
        } else {
            $IL.Emit([Reflection.Emit.OpCodes]::Ldsflda, (Get-IlMember $Expr.Member))
        }
        return
    }
    if ($Expr -is [Linq.Expressions.BinaryExpression] -and $Expr.NodeType -eq [Linq.Expressions.ExpressionType]::ArrayIndex) {
        Write-IlExpression -IL $IL -Expr $Expr.Left -Context $Context
        Write-IlExpression -IL $IL -Expr $Expr.Right -Context $Context
        $IL.Emit([Reflection.Emit.OpCodes]::Ldelema, (Get-IlType $Expr.Type))
        return
    }
    if ($Expr -is [Linq.Expressions.IndexExpression] -and $null -eq $Expr.Indexer -and $Expr.Object.Type.IsArray -and $Expr.Arguments.Count -eq 1) {
        Write-IlExpression -IL $IL -Expr $Expr.Object -Context $Context
        Write-IlExpression -IL $IL -Expr $Expr.Arguments[0] -Context $Context
        $IL.Emit([Reflection.Emit.OpCodes]::Ldelema, (Get-IlType $Expr.Type))
        return
    }
    if ($Expr -is [Linq.Expressions.BlockExpression]) {
        # Array normalization can wrap a storage location in a setup block.
        foreach ($variable in $Expr.Variables) {
            if (-not $Context.Locals.ContainsKey($variable)) { $Context.Locals[$variable] = $IL.DeclareLocal((Get-IlType $variable.Type)) }
        }
        for ($i = 0; $i -lt $Expr.Expressions.Count - 1; $i++) {
            Write-IlDiscarded -IL $IL -Expr $Expr.Expressions[$i] -Context $Context
        }
        Write-IlReceiver -IL $IL -Expr $Expr.Expressions[$Expr.Expressions.Count - 1] -Context $Context
        return
    }
    # Computed values, properties and readonly fields have no writable storage.
    # Evaluate exactly once and call on a defensive temporary.
    $temporary = $IL.DeclareLocal((Get-IlType $Expr.Type))
    Write-IlExpression -IL $IL -Expr $Expr -Context $Context
    Write-IlLocalStore -IL $IL -Loc $temporary
    $IL.Emit([Reflection.Emit.OpCodes]::Ldloca, $temporary)
}

function Write-IlInstanceCall([Reflection.Emit.ILGenerator] $IL, [Reflection.MethodInfo] $Method, [Type] $ReceiverType) {
    if ($ReceiverType -and $ReceiverType.IsValueType -and ($Method.IsVirtual -or -not $Method.DeclaringType.IsValueType)) {
        $IL.Emit([Reflection.Emit.OpCodes]::Constrained, (Get-IlType $ReceiverType))
        $IL.Emit([Reflection.Emit.OpCodes]::Callvirt, (Get-IlMember $Method))
    } elseif ($Method.IsVirtual -and -not $Method.DeclaringType.IsValueType) {
        $IL.Emit([Reflection.Emit.OpCodes]::Callvirt, (Get-IlMember $Method))
    } else {
        $IL.Emit([Reflection.Emit.OpCodes]::Call, (Get-IlMember $Method))
    }
}

function Write-IlArgumentLoad([Reflection.Emit.ILGenerator]$IL, [int]$Index) {
    switch ($Index) {
        0 { $IL.Emit([Reflection.Emit.OpCodes]::Ldarg_0); return }
        1 { $IL.Emit([Reflection.Emit.OpCodes]::Ldarg_1); return }
        2 { $IL.Emit([Reflection.Emit.OpCodes]::Ldarg_2); return }
        3 { $IL.Emit([Reflection.Emit.OpCodes]::Ldarg_3); return }
    }
    if ($Index -le 255) {
        $IL.Emit([Reflection.Emit.OpCodes]::Ldarg_S, [byte]$Index)
    } else {
        $IL.Emit([Reflection.Emit.OpCodes]::Ldarg, [int16]$Index)
    }
}

function Write-IlArgumentStore([Reflection.Emit.ILGenerator]$IL, [int]$Index) {
    if ($Index -le 255) {
        $IL.Emit([Reflection.Emit.OpCodes]::Starg_S, [byte]$Index)
    } else {
        $IL.Emit([Reflection.Emit.OpCodes]::Starg, [int16]$Index)
    }
}

function Write-IlLocalLoad([Reflection.Emit.ILGenerator]$IL, [Reflection.Emit.LocalBuilder]$Loc) {
    $idx = $Loc.LocalIndex
    switch ($idx) {
        0 { $IL.Emit([Reflection.Emit.OpCodes]::Ldloc_0); return }
        1 { $IL.Emit([Reflection.Emit.OpCodes]::Ldloc_1); return }
        2 { $IL.Emit([Reflection.Emit.OpCodes]::Ldloc_2); return }
        3 { $IL.Emit([Reflection.Emit.OpCodes]::Ldloc_3); return }
    }
    if ($idx -le 255) {
        $IL.Emit([Reflection.Emit.OpCodes]::Ldloc_S, $Loc)
    } else {
        $IL.Emit([Reflection.Emit.OpCodes]::Ldloc, $Loc)
    }
}

function Write-IlLocalStore([Reflection.Emit.ILGenerator]$IL, [Reflection.Emit.LocalBuilder]$Loc) {
    $idx = $Loc.LocalIndex
    switch ($idx) {
        0 { $IL.Emit([Reflection.Emit.OpCodes]::Stloc_0); return }
        1 { $IL.Emit([Reflection.Emit.OpCodes]::Stloc_1); return }
        2 { $IL.Emit([Reflection.Emit.OpCodes]::Stloc_2); return }
        3 { $IL.Emit([Reflection.Emit.OpCodes]::Stloc_3); return }
    }
    if ($idx -le 255) {
        $IL.Emit([Reflection.Emit.OpCodes]::Stloc_S, $Loc)
    } else {
        $IL.Emit([Reflection.Emit.OpCodes]::Stloc, $Loc)
    }
}

function Write-IlArrayLoad([Reflection.Emit.ILGenerator]$IL, [Type]$ElementType) {
    if ($ElementType -eq [int]) { $IL.Emit([Reflection.Emit.OpCodes]::Ldelem_I4); return }
    if ($ElementType -eq [single]) { $IL.Emit([Reflection.Emit.OpCodes]::Ldelem_R4); return }
    if ($ElementType -eq [double]) { $IL.Emit([Reflection.Emit.OpCodes]::Ldelem_R8); return }
    if ($ElementType -eq [byte]) { $IL.Emit([Reflection.Emit.OpCodes]::Ldelem_U1); return }
    if ($ElementType -eq [sbyte]) { $IL.Emit([Reflection.Emit.OpCodes]::Ldelem_I1); return }
    if ($ElementType -eq [short]) { $IL.Emit([Reflection.Emit.OpCodes]::Ldelem_I2); return }
    if ($ElementType -eq [ushort]) { $IL.Emit([Reflection.Emit.OpCodes]::Ldelem_U2); return }
    if ($ElementType -eq [long]) { $IL.Emit([Reflection.Emit.OpCodes]::Ldelem_I8); return }
    if ($ElementType -eq [bool]) { $IL.Emit([Reflection.Emit.OpCodes]::Ldelem_I1); return }
    if (-not $ElementType.IsValueType) { $IL.Emit([Reflection.Emit.OpCodes]::Ldelem_Ref); return }
    $IL.Emit([Reflection.Emit.OpCodes]::Ldelem, (Get-IlType $ElementType))
}

function Write-IlArrayStore([Reflection.Emit.ILGenerator]$IL, [Type]$ElementType) {
    if ($ElementType -eq [int]) { $IL.Emit([Reflection.Emit.OpCodes]::Stelem_I4); return }
    if ($ElementType -eq [single]) { $IL.Emit([Reflection.Emit.OpCodes]::Stelem_R4); return }
    if ($ElementType -eq [double]) { $IL.Emit([Reflection.Emit.OpCodes]::Stelem_R8); return }
    if ($ElementType -eq [byte]) { $IL.Emit([Reflection.Emit.OpCodes]::Stelem_I1); return }
    if ($ElementType -eq [sbyte]) { $IL.Emit([Reflection.Emit.OpCodes]::Stelem_I1); return }
    if ($ElementType -eq [short]) { $IL.Emit([Reflection.Emit.OpCodes]::Stelem_I2); return }
    if ($ElementType -eq [ushort]) { $IL.Emit([Reflection.Emit.OpCodes]::Stelem_I2); return }
    if ($ElementType -eq [long]) { $IL.Emit([Reflection.Emit.OpCodes]::Stelem_I8); return }
    if ($ElementType -eq [bool]) { $IL.Emit([Reflection.Emit.OpCodes]::Stelem_I1); return }
    if (-not $ElementType.IsValueType) { $IL.Emit([Reflection.Emit.OpCodes]::Stelem_Ref); return }
    $IL.Emit([Reflection.Emit.OpCodes]::Stelem, (Get-IlType $ElementType))
}

function Write-IlConstant {
    param(
        [Parameter(Mandatory)][Reflection.Emit.ILGenerator] $IL,
        [Parameter(Mandatory)][Linq.Expressions.ConstantExpression] $Expr
    )

    $val = $Expr.Value
    if ($null -eq $val) {
        $IL.Emit([Reflection.Emit.OpCodes]::Ldnull)
        return
    }

    if ($val -is [Type] -and $val -eq [Threading.ThreadStart]) {
        $IL.Emit([Reflection.Emit.OpCodes]::Ldtoken,$val)
        $IL.Emit([Reflection.Emit.OpCodes]::Call,[Type].GetMethod('GetTypeFromHandle',[Type[]]@([RuntimeTypeHandle])))
        return
    }
    if ($val -is [int]) {
        switch ($val) {
            -1 { $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4_M1); return }
            0  { $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0); return }
            1  { $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1); return }
            2  { $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4_2); return }
            3  { $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4_3); return }
            4  { $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4_4); return }
            5  { $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4_5); return }
            6  { $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4_6); return }
            7  { $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4_7); return }
            8  { $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4_8); return }
        }
        if ($val -ge -128 -and $val -le 127) {
            $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4_S, [sbyte]$val)
        }
        else {
            $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4, [int]$val)
        }
        return
    }

    if ($val -is [enum]) {
        $underlying = [Enum]::GetUnderlyingType($val.GetType())
        Write-IlConstant -IL $IL -Expr ([Linq.Expressions.Expression]::Constant([Convert]::ChangeType($val, $underlying), $underlying))
        return
    }

    if ($val -is [bool]) {
        if ($val) {
            $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1)
        }
        else {
            $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
        }
        return
    }

    if ($val -is [string]) {
        $IL.Emit([Reflection.Emit.OpCodes]::Ldstr, [string]$val)
        return
    }

    if ($val -is [double]) {
        $IL.Emit([Reflection.Emit.OpCodes]::Ldc_R8, [double]$val)
        return
    }

    if ($val -is [single]) {
        $IL.Emit([Reflection.Emit.OpCodes]::Ldc_R4, [single]$val)
        return
    }

    if ($val -is [long]) {
        $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I8, [long]$val)
        return
    }

    throw "Unsupported constant type '$($val.GetType().FullName)'."
}

function Write-IlConversion {
    param(
        [Parameter(Mandatory)][Reflection.Emit.ILGenerator] $IL,
        [Parameter(Mandatory)][Type] $FromType,
        [Parameter(Mandatory)][Type] $ToType,
        [switch] $Checked
    )

    if ($FromType -eq $ToType) { return }

    # Boxing and unboxing come first: a numeric opcode applied to a reference
    # converts the reference's bits, not the value it holds.
    if ($FromType.IsValueType -and -not $ToType.IsValueType) {
        $IL.Emit([Reflection.Emit.OpCodes]::Box, (Get-IlType $FromType))
        if ($ToType -ne [object]) { $IL.Emit([Reflection.Emit.OpCodes]::Castclass, (Get-IlType $ToType)) }
        return
    }
    if (-not $FromType.IsValueType -and $ToType.IsValueType) {
        $IL.Emit([Reflection.Emit.OpCodes]::Unbox_Any, (Get-IlType $ToType))
        return
    }
    if (-not $FromType.IsValueType -and -not $ToType.IsValueType) {
        $IL.Emit([Reflection.Emit.OpCodes]::Castclass, (Get-IlType $ToType))
        return
    }
    $numeric = { param([Type] $T) $T.IsPrimitive -or $T.IsEnum }
    if (-not (& $numeric $FromType) -or -not (& $numeric $ToType)) {
        throw "Unsupported conversion from '$($FromType.FullName)' to '$($ToType.FullName)'."
    }

    # Char is an unsigned 16-bit integer: [char]10 is U+000A, and [char]70000 throws as it does in PowerShell.
    if ($Checked -and $ToType.IsPrimitive -and $ToType -notin [double], [single], [bool]) {
        $un = if ($FromType -in [byte], [ushort], [uint], [ulong], [char]) { '_Un' } else { '' }
        $suffix = @{ [int] = 'I4'; [long] = 'I8'; [short] = 'I2'; [sbyte] = 'I1'; [byte] = 'U1'; [ushort] = 'U2'; [uint] = 'U4'; [ulong] = 'U8'; [char] = 'U2' }[$ToType]
        if ($suffix) {
            $IL.Emit([Reflection.Emit.OpCodes].GetField("Conv_Ovf_$suffix$un").GetValue($null))
            return
        }
    }
    if ($ToType -in [double], [single] -and $FromType -in [uint], [ulong]) {
        $IL.Emit([Reflection.Emit.OpCodes]::Conv_R_Un)
    }

    if ($ToType -eq [int])    { $IL.Emit([Reflection.Emit.OpCodes]::Conv_I4); return }
    if ($ToType -eq [long])   { $IL.Emit([Reflection.Emit.OpCodes]::Conv_I8); return }
    if ($ToType -eq [double]) { $IL.Emit([Reflection.Emit.OpCodes]::Conv_R8); return }
    if ($ToType -eq [single]) { $IL.Emit([Reflection.Emit.OpCodes]::Conv_R4); return }
    if ($ToType -eq [short])  { $IL.Emit([Reflection.Emit.OpCodes]::Conv_I2); return }
    if ($ToType -eq [byte])   { $IL.Emit([Reflection.Emit.OpCodes]::Conv_U1); return }
    if ($ToType -eq [sbyte])  { $IL.Emit([Reflection.Emit.OpCodes]::Conv_I1); return }
    if ($ToType -eq [uint])   { $IL.Emit([Reflection.Emit.OpCodes]::Conv_U4); return }
    if ($ToType -eq [ulong])  { $IL.Emit([Reflection.Emit.OpCodes]::Conv_U8); return }
    if ($ToType -eq [ushort]) { $IL.Emit([Reflection.Emit.OpCodes]::Conv_U2); return }
    if ($ToType -eq [char])   { $IL.Emit([Reflection.Emit.OpCodes]::Conv_U2); return }

    throw "Unsupported conversion from '$($FromType.FullName)' to '$($ToType.FullName)'."
}


# Every expression leaves its value on the stack. Where a consumer does not want that value (a statement in a
# block, a void branch, a loop or try body), it emits the expression through this, which drops the value.
function Write-IlDiscarded {
    param(
        [Parameter(Mandatory)][Reflection.Emit.ILGenerator] $IL,
        [Parameter(Mandatory)][Linq.Expressions.Expression] $Expr,
        [Parameter(Mandatory)][hashtable] $Context
    )
    # A discarded assignment stores without keeping its value: no dup, temporary or pop.
    if ($Expr.NodeType -eq [Linq.Expressions.ExpressionType]::Assign) {
        Write-IlAssign -IL $IL -Expr $Expr -Context $Context -Discard
        return
    }
    Write-IlExpression -IL $IL -Expr $Expr -Context $Context
    if ($Expr.Type -ne [void]) { $IL.Emit([Reflection.Emit.OpCodes]::Pop) }
}

function Write-IlAssign {
    <#
    .SYNOPSIS
        Emits an assignment. By default its value, the value stored, is left on the stack; a store that
        consumes the stack keeps it in a temporary. With -Discard nothing is left and no copy is made.
    #>
    param(
        [Parameter(Mandatory)][Reflection.Emit.ILGenerator] $IL,
        [Parameter(Mandatory)][Linq.Expressions.BinaryExpression] $Expr,
        [Parameter(Mandatory)][hashtable] $Context,
        [switch] $Discard
    )
    $left = $Expr.Left
    if ($left -is [Linq.Expressions.ParameterExpression]) {
        Write-IlExpression -IL $IL -Expr $Expr.Right -Context $Context
        if (-not $Discard) { $IL.Emit([Reflection.Emit.OpCodes]::Dup) }
        if ($Context.Locals.ContainsKey($left)) { Write-IlLocalStore -IL $IL -Loc $Context.Locals[$left]; return }
        if ($Context.Parameters.ContainsKey($left)) { Write-IlArgumentStore -IL $IL -Index $Context.Parameters[$left]; return }
        throw "No storage for assignment target '$($left.Name)'."
    }
    if ($left -is [Linq.Expressions.MemberExpression] -and $left.Member -is [Reflection.FieldInfo] -and $left.Member.IsStatic) {
        Write-IlExpression -IL $IL -Expr $Expr.Right -Context $Context
        if (-not $Discard) { $IL.Emit([Reflection.Emit.OpCodes]::Dup) }
        $IL.Emit([Reflection.Emit.OpCodes]::Stsfld, (Get-IlMember $left.Member))
        return
    }
    # The remaining targets consume a receiver (and an index) beneath the value.
    if ($left -is [Linq.Expressions.IndexExpression]) {
        if ($null -ne $left.Indexer) { Write-IlReceiver -IL $IL -Expr $left.Object -Context $Context }
        else { Write-IlExpression -IL $IL -Expr $left.Object -Context $Context }
        Write-IlExpression -IL $IL -Expr $left.Arguments[0] -Context $Context
    } elseif ($left -is [Linq.Expressions.MemberExpression]) {
        if ($left.Expression) { Write-IlReceiver -IL $IL -Expr $left.Expression -Context $Context }
    } else {
        throw "Assignment to unsupported target expression '$($left.GetType().FullName)'."
    }
    $value = $null
    if ($Discard) { Write-IlExpression -IL $IL -Expr $Expr.Right -Context $Context }
    else { $value = Write-IlStoredValue -IL $IL -Expr $Expr.Right -Context $Context }
    if ($left -is [Linq.Expressions.IndexExpression] -and $null -ne $left.Indexer) {
        Write-IlInstanceCall -IL $IL -Method $left.Indexer.GetSetMethod() -ReceiverType $left.Object.Type
    } elseif ($left -is [Linq.Expressions.IndexExpression]) {
        Write-IlArrayStore -IL $IL -ElementType $left.Type
    } elseif ($left.Member -is [Reflection.FieldInfo]) {
        $IL.Emit([Reflection.Emit.OpCodes]::Stfld, (Get-IlMember $left.Member))
    } else {
        $receiverType = if ($left.Expression) { $left.Expression.Type } else { $null }
        Write-IlInstanceCall -IL $IL -Method $left.Member.GetSetMethod() -ReceiverType $receiverType
    }
    if (-not $Discard) { Write-IlLocalLoad -IL $IL -Loc $value }
}

# Emits a value about to be stored by an instruction that consumes it, keeping a copy in a temporary of its
# type (one per type, as nothing is emitted between the store and the reload). Returns that temporary.
function Write-IlStoredValue {
    param(
        [Parameter(Mandatory)][Reflection.Emit.ILGenerator] $IL,
        [Parameter(Mandatory)][Linq.Expressions.Expression] $Expr,
        [Parameter(Mandatory)][hashtable] $Context
    )
    if (-not $Context.ContainsKey('StoredValues')) { $Context.StoredValues = @{} }
    $type = Get-IlType $Expr.Type
    if (-not $Context.StoredValues.ContainsKey($type)) { $Context.StoredValues[$type] = $IL.DeclareLocal($type) }
    $temporary = $Context.StoredValues[$type]
    Write-IlExpression -IL $IL -Expr $Expr -Context $Context
    $IL.Emit([Reflection.Emit.OpCodes]::Dup)
    Write-IlLocalStore -IL $IL -Loc $temporary
    $temporary
}

function Write-IlExpression {
    param(
        [Parameter(Mandatory)][Reflection.Emit.ILGenerator] $IL,
        [Parameter(Mandatory)][Linq.Expressions.Expression] $Expr,
        [Parameter(Mandatory)][hashtable] $Context
    )

    $native = $null
    if ($script:NativeExpressions.TryGetValue($Expr,[ref]$native)) {
        if ($native.Kind -eq 'Address') {
            $IL.Emit([Reflection.Emit.OpCodes]::Ldftn,(Get-IlMember $native.Method))
            return
        }
        # Reject null before entering native code. These are typed parameters,
        # so loading the pointer twice has no observable side effects.
        $valid=$IL.DefineLabel()
        Write-IlExpression -IL $IL -Expr $Expr.Arguments[0] -Context $Context
        $IL.Emit([Reflection.Emit.OpCodes]::Brtrue,$valid)
        $IL.Emit([Reflection.Emit.OpCodes]::Ldstr,'functionPointer')
        $IL.Emit([Reflection.Emit.OpCodes]::Newobj,[ArgumentNullException].GetConstructor([Type[]]@([string])))
        $IL.Emit([Reflection.Emit.OpCodes]::Throw)
        $IL.MarkLabel($valid)
        for ($i=1;$i -lt $Expr.Arguments.Count;$i++) { Write-IlExpression -IL $IL -Expr $Expr.Arguments[$i] -Context $Context }
        Write-IlExpression -IL $IL -Expr $Expr.Arguments[0] -Context $Context
        $signature=[Type[]]@($native.ParameterTypes | Select-Object -Skip 1)
        $IL.EmitCalli([Reflection.Emit.OpCodes]::Calli,[Runtime.InteropServices.CallingConvention]$native.Convention,[Type]$native.ReturnType,$signature)
        return
    }

    # 1. Constant
    if ($Expr -is [Linq.Expressions.ConstantExpression]) {
        Write-IlConstant -IL $IL -Expr $Expr
        return
    }

    # 2. Parameter / Local read
    if ($Expr -is [Linq.Expressions.ParameterExpression]) {
        if ($Context.Locals.ContainsKey($Expr)) {
            Write-IlLocalLoad -IL $IL -Loc $Context.Locals[$Expr]
            return
        }
        if ($Context.Parameters.ContainsKey($Expr)) {
            Write-IlArgumentLoad -IL $IL -Index $Context.Parameters[$Expr]
            return
        }
        throw "Variable '$($Expr.Name)' was neither in parameters nor locals."
    }

    # 3. Block
    if ($Expr -is [Linq.Expressions.BlockExpression]) {
        # Declare local variables
        foreach ($var in $Expr.Variables) {
            if (-not $Context.Locals.ContainsKey($var)) {
                $loc = $IL.DeclareLocal((Get-IlType $var.Type))
                $Context.Locals[$var] = $loc
            }
        }

        # Every expression but the last is evaluated for its effect; so is the last when the block is void.
        $count = $Expr.Expressions.Count
        for ($i = 0; $i -lt $count; $i++) {
            $child = $Expr.Expressions[$i]
            if ($i -eq $count - 1 -and $Expr.Type -ne [void]) { Write-IlExpression -IL $IL -Expr $child -Context $Context }
            else { Write-IlDiscarded -IL $IL -Expr $child -Context $Context }
        }
        return
    }

    # 4. Goto / Return
    if ($Expr -is [Linq.Expressions.GotoExpression]) {
        if ($Expr.Value) {
            Write-IlExpression -IL $IL -Expr $Expr.Value -Context $Context
            if ($Context.ReturnLocal -and $Expr.Target.Name -eq 'returnTarget') {
                Write-IlLocalStore -IL $IL -Loc $Context.ReturnLocal
            }
        }

        $target = $Expr.Target
        if (-not $Context.Labels.ContainsKey($target)) {
            $Context.Labels[$target] = $IL.DefineLabel()
        }
        $label = $Context.Labels[$target]
        if ($Context.ExceptionDepth -gt 0) {
            $IL.Emit([Reflection.Emit.OpCodes]::Leave, $label)
        } else {
            $IL.Emit([Reflection.Emit.OpCodes]::Br, $label)
        }
        return
    }

    # 5. Label
    if ($Expr -is [Linq.Expressions.LabelExpression]) {
        $target = $Expr.Target
        if (-not $Context.Labels.ContainsKey($target)) {
            $Context.Labels[$target] = $IL.DefineLabel()
        }
        $label = $Context.Labels[$target]
        $IL.MarkLabel($label)

        if ($Expr.Target.Name -eq 'returnTarget') {
            if ($Context.ReturnLocal) {
                Write-IlLocalLoad -IL $IL -Loc $Context.ReturnLocal
            }
            return
        }

        if ($Expr.DefaultValue) {
            Write-IlExpression -IL $IL -Expr $Expr.DefaultValue -Context $Context
        }
        return
    }

    # 6. Default / Empty
    if ($Expr -is [Linq.Expressions.DefaultExpression]) {
        if ($Expr.Type -eq [void]) { return }
        if ($Expr.Type -eq [int] -or $Expr.Type -eq [bool] -or $Expr.Type -eq [short] -or $Expr.Type -eq [byte]) {
            $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0); return
        }
        if ($Expr.Type -eq [long]) { $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I8, [long]0); return }
        if ($Expr.Type -eq [double]) { $IL.Emit([Reflection.Emit.OpCodes]::Ldc_R8, [double]0.0); return }
        if (-not $Expr.Type.IsValueType) { $IL.Emit([Reflection.Emit.OpCodes]::Ldnull); return }
        throw "Unsupported default value type '$($Expr.Type.FullName)'."
    }

    # 7. Unary Convert
    if ($Expr -is [Linq.Expressions.UnaryExpression] -and $Expr.NodeType -in [Linq.Expressions.ExpressionType]::Convert, [Linq.Expressions.ExpressionType]::ConvertChecked) {
        Write-IlExpression -IL $IL -Expr $Expr.Operand -Context $Context
        Write-IlConversion -IL $IL -FromType $Expr.Operand.Type -ToType $Expr.Type -Checked:($Expr.NodeType -eq [Linq.Expressions.ExpressionType]::ConvertChecked)
        return
    }

    # Checked negation: 0 - x with overflow checking, as CIL has no checked neg.
    if ($Expr -is [Linq.Expressions.UnaryExpression] -and $Expr.NodeType -eq [Linq.Expressions.ExpressionType]::NegateChecked) {
        Write-IlConstant -IL $IL -Expr ([Linq.Expressions.Expression]::Constant([Convert]::ChangeType(0, $Expr.Type), $Expr.Type))
        Write-IlExpression -IL $IL -Expr $Expr.Operand -Context $Context
        $IL.Emit([Reflection.Emit.OpCodes]::Sub_Ovf)
        return
    }

    # 8. Unary Negate
    if ($Expr -is [Linq.Expressions.UnaryExpression] -and $Expr.NodeType -eq [Linq.Expressions.ExpressionType]::Negate) {
        Write-IlExpression -IL $IL -Expr $Expr.Operand -Context $Context
        $IL.Emit([Reflection.Emit.OpCodes]::Neg)
        return
    }

    # 9. Unary Not
    if ($Expr -is [Linq.Expressions.UnaryExpression] -and $Expr.NodeType -eq [Linq.Expressions.ExpressionType]::Not) {
        Write-IlExpression -IL $IL -Expr $Expr.Operand -Context $Context
        if ($Expr.Operand.Type -eq [bool]) {
            $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
            $IL.Emit([Reflection.Emit.OpCodes]::Ceq)
        }
        else {
            $IL.Emit([Reflection.Emit.OpCodes]::Not)
        }
        return
    }

    # 9.1 Unary ArrayLength
    if ($Expr -is [Linq.Expressions.UnaryExpression] -and $Expr.NodeType -eq [Linq.Expressions.ExpressionType]::ArrayLength) {
        Write-IlExpression -IL $IL -Expr $Expr.Operand -Context $Context
        $IL.Emit([Reflection.Emit.OpCodes]::Ldlen)
        $IL.Emit([Reflection.Emit.OpCodes]::Conv_I4)
        return
    }

    # 9.15 Unary Throw / Rethrow
    if ($Expr -is [Linq.Expressions.UnaryExpression] -and $Expr.NodeType -eq [Linq.Expressions.ExpressionType]::Throw) {
        if ($Expr.Operand) {
            Write-IlExpression -IL $IL -Expr $Expr.Operand -Context $Context
            $IL.Emit([Reflection.Emit.OpCodes]::Throw)
        } else {
            $IL.Emit([Reflection.Emit.OpCodes]::Rethrow)
        }
        return
    }

    # 9.2 NewArray (Bounds or Init)
    if ($Expr -is [Linq.Expressions.NewArrayExpression]) {
        if ($Expr.NodeType -eq [Linq.Expressions.ExpressionType]::NewArrayBounds) {
            Write-IlExpression -IL $IL -Expr $Expr.Expressions[0] -Context $Context
            $IL.Emit([Reflection.Emit.OpCodes]::Newarr, (Get-IlType $Expr.Type.GetElementType()))
            return
        }
        if ($Expr.NodeType -eq [Linq.Expressions.ExpressionType]::NewArrayInit) {
            $elemType = $Expr.Type.GetElementType()
            $count = $Expr.Expressions.Count
            Write-IlConstant -IL $IL -Expr ([Linq.Expressions.Expression]::Constant($count, [int]))
            $IL.Emit([Reflection.Emit.OpCodes]::Newarr, (Get-IlType $elemType))
            for ($i = 0; $i -lt $count; $i++) {
                $IL.Emit([Reflection.Emit.OpCodes]::Dup)
                Write-IlConstant -IL $IL -Expr ([Linq.Expressions.Expression]::Constant($i, [int]))
                Write-IlExpression -IL $IL -Expr $Expr.Expressions[$i] -Context $Context
                Write-IlArrayStore -IL $IL -ElementType $elemType
            }
            return
        }
    }

    # 9.3 New object instantiation (NewExpression)
    if ($Expr -is [Linq.Expressions.NewExpression]) {
        foreach ($arg in $Expr.Arguments) {
            Write-IlExpression -IL $IL -Expr $arg -Context $Context
        }
        $IL.Emit([Reflection.Emit.OpCodes]::Newobj, (Get-IlMember $Expr.Constructor))
        return
    }

    # 9.4 Method call (MethodCallExpression)
    if ($Expr -is [Linq.Expressions.MethodCallExpression]) {
        if ($Expr.Object) {
            Write-IlReceiver -IL $IL -Expr $Expr.Object -Context $Context
        }
        foreach ($arg in $Expr.Arguments) {
            Write-IlExpression -IL $IL -Expr $arg -Context $Context
        }
        $receiverType = if ($Expr.Object) { $Expr.Object.Type } else { $null }
        Write-IlInstanceCall -IL $IL -Method $Expr.Method -ReceiverType $receiverType
        return
    }

    # 9.3 List element read through an indexer property (List[T].Item)
    if ($Expr -is [Linq.Expressions.IndexExpression] -and $null -ne $Expr.Indexer -and $Expr.Arguments.Count -eq 1) {
        Write-IlReceiver -IL $IL -Expr $Expr.Object -Context $Context
        Write-IlExpression -IL $IL -Expr $Expr.Arguments[0] -Context $Context
        Write-IlInstanceCall -IL $IL -Method $Expr.Indexer.GetGetMethod() -ReceiverType $Expr.Object.Type
        return
    }

    # 9.4 Array element read through an IndexExpression (one-dimensional array)
    if ($Expr -is [Linq.Expressions.IndexExpression] -and $null -eq $Expr.Indexer -and $Expr.Object.Type.IsArray -and $Expr.Arguments.Count -eq 1) {
        Write-IlExpression -IL $IL -Expr $Expr.Object -Context $Context
        Write-IlExpression -IL $IL -Expr $Expr.Arguments[0] -Context $Context
        Write-IlArrayLoad -IL $IL -ElementType $Expr.Type
        return
    }

    # 9.5 Member access - Property or Field (MemberExpression)
    if ($Expr -is [Linq.Expressions.MemberExpression]) {
        if ($Expr.Member -is [Reflection.PropertyInfo]) {
            $getter = $Expr.Member.GetGetMethod()
            if ($Expr.Expression) {
                Write-IlReceiver -IL $IL -Expr $Expr.Expression -Context $Context
            }
            $receiverType = if ($Expr.Expression) { $Expr.Expression.Type } else { $null }
            Write-IlInstanceCall -IL $IL -Method $getter -ReceiverType $receiverType
            return
        }
        if ($Expr.Member -is [Reflection.FieldInfo]) {
            # A literal (const or enum member) has no storage to load; its
            # value is the constant, as in LambdaCompiler.EmitMemberExpression.
            if ($Expr.Member.IsLiteral) {
                $literalType = if ($Expr.Member.FieldType.IsEnum) { $Expr.Member.FieldType.GetEnumUnderlyingType() } else { $Expr.Member.FieldType }
                Write-IlConstant -IL $IL -Expr ([Linq.Expressions.Expression]::Constant($Expr.Member.GetRawConstantValue(), $literalType))
                return
            }
            if ($Expr.Expression) {
                Write-IlReceiver -IL $IL -Expr $Expr.Expression -Context $Context
                $IL.Emit([Reflection.Emit.OpCodes]::Ldfld, (Get-IlMember $Expr.Member))
            } else {
                $IL.Emit([Reflection.Emit.OpCodes]::Ldsfld, (Get-IlMember $Expr.Member))
            }
            return
        }
        throw "Unsupported member access on '$($Expr.Member.GetType().FullName)'."
    }

    # 9.6 Try / Catch / Finally (TryExpression)
    if ($Expr -is [Linq.Expressions.TryExpression]) {
        $lblEnd = $IL.BeginExceptionBlock()
        $Context.ExceptionDepth++

        # A try used as a statement evaluates its bodies for effect; a finally body always is.
        if ($Expr.Type -eq [void]) { Write-IlDiscarded -IL $IL -Expr $Expr.Body -Context $Context }
        else { Write-IlExpression -IL $IL -Expr $Expr.Body -Context $Context }

        foreach ($cb in $Expr.Handlers) {
            $IL.BeginCatchBlock((Get-IlType $cb.Test))
            if ($cb.Variable) {
                if (-not $Context.Locals.ContainsKey($cb.Variable)) {
                    $loc = $IL.DeclareLocal((Get-IlType $cb.Variable.Type))
                    $Context.Locals[$cb.Variable] = $loc
                }
                Write-IlLocalStore -IL $IL -Loc $Context.Locals[$cb.Variable]
            } else {
                $IL.Emit([Reflection.Emit.OpCodes]::Pop)
            }
            if ($Expr.Type -eq [void]) { Write-IlDiscarded -IL $IL -Expr $cb.Body -Context $Context }
            else { Write-IlExpression -IL $IL -Expr $cb.Body -Context $Context }
        }

        if ($Expr.Finally) {
            $IL.BeginFinallyBlock()
            Write-IlDiscarded -IL $IL -Expr $Expr.Finally -Context $Context
        }

        $IL.EndExceptionBlock()
        $Context.ExceptionDepth--
        return
    }

    # 10. Conditional Expression (if/else or ternary)
    if ($Expr -is [Linq.Expressions.ConditionalExpression]) {
        Write-IlExpression -IL $IL -Expr $Expr.Test -Context $Context
        $lblFalse = $IL.DefineLabel()
        $lblEnd = $IL.DefineLabel()

        $IL.Emit([Reflection.Emit.OpCodes]::Brfalse, $lblFalse)
        # A void conditional (an if statement) evaluates its branches for effect.
        if ($Expr.Type -eq [void]) { Write-IlDiscarded -IL $IL -Expr $Expr.IfTrue -Context $Context }
        else { Write-IlExpression -IL $IL -Expr $Expr.IfTrue -Context $Context }

        $hasFalseBranch = ($Expr.IfFalse -and $Expr.IfFalse.NodeType -ne [Linq.Expressions.ExpressionType]::Default -and $Expr.IfFalse.Type -ne [void]) -or
                          ($Expr.IfFalse -and $Expr.IfFalse.NodeType -ne [Linq.Expressions.ExpressionType]::Default)

        if ($hasFalseBranch) {
            $IL.Emit([Reflection.Emit.OpCodes]::Br, $lblEnd)
            $IL.MarkLabel($lblFalse)
            if ($Expr.Type -eq [void]) { Write-IlDiscarded -IL $IL -Expr $Expr.IfFalse -Context $Context }
            else { Write-IlExpression -IL $IL -Expr $Expr.IfFalse -Context $Context }
            $IL.MarkLabel($lblEnd)
        }
        else {
            $IL.MarkLabel($lblFalse)
        }
        return
    }

    # 11. Loop Expression
    if ($Expr -is [Linq.Expressions.LoopExpression]) {
        $lblHead = $IL.DefineLabel()
        $lblBreak = if ($Expr.BreakLabel) {
            if (-not $Context.Labels.ContainsKey($Expr.BreakLabel)) {
                $Context.Labels[$Expr.BreakLabel] = $IL.DefineLabel()
            }
            $Context.Labels[$Expr.BreakLabel]
        } else { $IL.DefineLabel() }

        $lblContinue = if ($Expr.ContinueLabel) {
            if (-not $Context.Labels.ContainsKey($Expr.ContinueLabel)) {
                $Context.Labels[$Expr.ContinueLabel] = $IL.DefineLabel()
            }
            $Context.Labels[$Expr.ContinueLabel]
        } else { $lblHead }

        $IL.MarkLabel($lblHead)
        # The continue label is the loop head, as in LambdaCompiler.EmitLoopExpression.
        if ($Expr.ContinueLabel) { $IL.MarkLabel($lblContinue) }
        Write-IlDiscarded -IL $IL -Expr $Expr.Body -Context $Context
        $IL.Emit([Reflection.Emit.OpCodes]::Br, $lblHead)
        $IL.MarkLabel($lblBreak)
        return
    }

    # 12. Binary Expressions (Arithmetic, Assignment, Logic, Comparisons, Index)
    if ($Expr -is [Linq.Expressions.BinaryExpression]) {
        # An assignment is an expression whose value is the value stored, as in PowerShell and LINQ.
        if ($Expr.NodeType -eq [Linq.Expressions.ExpressionType]::Assign) {
            Write-IlAssign -IL $IL -Expr $Expr -Context $Context
            return
        }

        # Array Index Read
        if ($Expr.NodeType -eq [Linq.Expressions.ExpressionType]::ArrayIndex) {
            Write-IlExpression -IL $IL -Expr $Expr.Left -Context $Context
            Write-IlExpression -IL $IL -Expr $Expr.Right -Context $Context
            Write-IlArrayLoad -IL $IL -ElementType $Expr.Type
            return
        }

        # Short-circuit logical AndAlso
        if ($Expr.NodeType -eq [Linq.Expressions.ExpressionType]::AndAlso) {
            Write-IlExpression -IL $IL -Expr $Expr.Left -Context $Context
            $lbl = $IL.DefineLabel()
            $IL.Emit([Reflection.Emit.OpCodes]::Dup)
            $IL.Emit([Reflection.Emit.OpCodes]::Brfalse, $lbl)
            $IL.Emit([Reflection.Emit.OpCodes]::Pop)
            Write-IlExpression -IL $IL -Expr $Expr.Right -Context $Context
            $IL.MarkLabel($lbl)
            return
        }

        # Short-circuit logical OrElse
        if ($Expr.NodeType -eq [Linq.Expressions.ExpressionType]::OrElse) {
            Write-IlExpression -IL $IL -Expr $Expr.Left -Context $Context
            $lbl = $IL.DefineLabel()
            $IL.Emit([Reflection.Emit.OpCodes]::Dup)
            $IL.Emit([Reflection.Emit.OpCodes]::Brtrue, $lbl)
            $IL.Emit([Reflection.Emit.OpCodes]::Pop)
            Write-IlExpression -IL $IL -Expr $Expr.Right -Context $Context
            $IL.MarkLabel($lbl)
            return
        }

        # Binary operations (Arithmetic and Comparisons)
        Write-IlExpression -IL $IL -Expr $Expr.Left -Context $Context
        Write-IlExpression -IL $IL -Expr $Expr.Right -Context $Context

        if ($Expr.Method) {
            $IL.Emit([Reflection.Emit.OpCodes]::Call, (Get-IlMember $Expr.Method))
            return
        }

        $isFloat = ($Expr.Left.Type -eq [double] -or $Expr.Left.Type -eq [single])
        # Unsigned operands need the _Un forms; for floats, the _Un compare
        # forms are the ones that treat NaN as unordered.
        $isUnsigned = $Expr.Left.Type -in [byte], [ushort], [uint], [ulong]

        switch ($Expr.NodeType) {
            'Add'      { $IL.Emit([Reflection.Emit.OpCodes]::Add); return }
            'Subtract' { $IL.Emit([Reflection.Emit.OpCodes]::Sub); return }
            'Multiply' { $IL.Emit([Reflection.Emit.OpCodes]::Mul); return }
            'AddChecked'      { $IL.Emit($(if ($isUnsigned) { [Reflection.Emit.OpCodes]::Add_Ovf_Un } else { [Reflection.Emit.OpCodes]::Add_Ovf })); return }
            'SubtractChecked' { $IL.Emit($(if ($isUnsigned) { [Reflection.Emit.OpCodes]::Sub_Ovf_Un } else { [Reflection.Emit.OpCodes]::Sub_Ovf })); return }
            'MultiplyChecked' { $IL.Emit($(if ($isUnsigned) { [Reflection.Emit.OpCodes]::Mul_Ovf_Un } else { [Reflection.Emit.OpCodes]::Mul_Ovf })); return }
            'Divide'   { $IL.Emit($(if ($isUnsigned) { [Reflection.Emit.OpCodes]::Div_Un } else { [Reflection.Emit.OpCodes]::Div })); return }
            'And'         { $IL.Emit([Reflection.Emit.OpCodes]::And); return }
            'Or'          { $IL.Emit([Reflection.Emit.OpCodes]::Or); return }
            'ExclusiveOr' { $IL.Emit([Reflection.Emit.OpCodes]::Xor); return }
            'LeftShift'   { $IL.Emit([Reflection.Emit.OpCodes]::Shl); return }
            'RightShift'  { $IL.Emit($(if ($isUnsigned) { [Reflection.Emit.OpCodes]::Shr_Un } else { [Reflection.Emit.OpCodes]::Shr })); return }
            'Modulo'   { $IL.Emit($(if ($isUnsigned) { [Reflection.Emit.OpCodes]::Rem_Un } else { [Reflection.Emit.OpCodes]::Rem })); return }
            'Equal'    { $IL.Emit([Reflection.Emit.OpCodes]::Ceq); return }
            'NotEqual' {
                $IL.Emit([Reflection.Emit.OpCodes]::Ceq)
                $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
                $IL.Emit([Reflection.Emit.OpCodes]::Ceq)
                return
            }
            'LessThan' { $IL.Emit($(if ($isUnsigned) { [Reflection.Emit.OpCodes]::Clt_Un } else { [Reflection.Emit.OpCodes]::Clt })); return }
            'GreaterThan' { $IL.Emit($(if ($isUnsigned) { [Reflection.Emit.OpCodes]::Cgt_Un } else { [Reflection.Emit.OpCodes]::Cgt })); return }
            'LessThanOrEqual' {
                if ($isFloat -or $isUnsigned) {
                    $IL.Emit([Reflection.Emit.OpCodes]::Cgt_Un)
                } else {
                    $IL.Emit([Reflection.Emit.OpCodes]::Cgt)
                }
                $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
                $IL.Emit([Reflection.Emit.OpCodes]::Ceq)
                return
            }
            'GreaterThanOrEqual' {
                if ($isFloat -or $isUnsigned) {
                    $IL.Emit([Reflection.Emit.OpCodes]::Clt_Un)
                } else {
                    $IL.Emit([Reflection.Emit.OpCodes]::Clt)
                }
                $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
                $IL.Emit([Reflection.Emit.OpCodes]::Ceq)
                return
            }
        }
    }

    throw "Emitter encountered unhandled expression node type '$($Expr.GetType().FullName)' ($($Expr.NodeType))."
}

function Write-IlMethodBody {
    <#
    .SYNOPSIS
        Emits MSIL into a MethodBuilder from a validated LambdaExpression.
    #>
    param(
        [Parameter(Mandatory)][Linq.Expressions.LambdaExpression] $Lambda,
        # A MethodBuilder or ConstructorBuilder.
        [Parameter(Mandatory)][object] $MethodBuilder,
        [switch] $IsStatic,
        # The lambda's first parameter is the instance ('this', argument 0).
        [switch] $HasThis,
        # Call System.Object's constructor first, as an instance constructor must.
        [switch] $BaseConstructor
    )

    $il = $MethodBuilder.GetILGenerator()
    if ($BaseConstructor) {
        $il.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
        $il.Emit([Reflection.Emit.OpCodes]::Call, [object].GetConstructor([Type[]]@()))
    }

    $paramMap = @{}
    $offset = if ($IsStatic -or $HasThis) { 0 } else { 1 }

    for ($i = 0; $i -lt $Lambda.Parameters.Count; $i++) {
        $p = $Lambda.Parameters[$i]
        $paramMap[$p] = ($i + $offset)
    }

    $retLocal = if ($Lambda.ReturnType -ne [void]) {
        $il.DeclareLocal((Get-IlType $Lambda.ReturnType))
    } else {
        $null
    }

    $context = @{
        IsStatic    = [bool]$IsStatic
        Parameters  = $paramMap
        Locals      = @{}
        Labels      = @{}
        ReturnType     = $Lambda.ReturnType
        ReturnLocal    = $retLocal
        ExceptionDepth = 0
    }

    Write-IlExpression -IL $il -Expr $Lambda.Body -Context $context

    # Final method return
    $il.Emit([Reflection.Emit.OpCodes]::Ret)
}

function Get-PinnedPowerShell {
    <#
    .SYNOPSIS
        Returns pwsh.exe of the pinned PowerShell build, downloading it into build/cache on first use.
    .DESCRIPTION
        PSC is verified on PowerShell 7.7.0-preview.5 (.NET 11) only. The archive is checked against the SHA-256
        GitHub publishes for the release asset before it is extracted.
    #>
    [CmdletBinding()]
    param([string] $ArchivePath)
    $version = '7.7.0-preview.5'
    $asset = "PowerShell-$version-win-x64.zip"
    $sha256 = 'BA727D1890F7DBCBA05286BC0E61FC9F168DE9BA2A1003C4934BCE8E38BBFD1B'
    $cache = Join-Path $PSScriptRoot "build/cache/pwsh/$version"
    $pwsh = Join-Path $cache 'pwsh.exe'
    if (Test-Path -LiteralPath $pwsh) { return $pwsh }
    $null = New-Item -ItemType Directory -Force -Path $cache
    $zip = if ($ArchivePath) { [IO.Path]::GetFullPath($ArchivePath) } else { Join-Path $PSScriptRoot "build/cache/pwsh/$asset" }
    if (-not $ArchivePath -and -not (Test-Path -LiteralPath $zip)) {
        Invoke-WebRequest -Uri "https://github.com/PowerShell/PowerShell/releases/download/v$version/$asset" -OutFile $zip
    }
    $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    if ($actual -ne $sha256) {
        if (-not $ArchivePath) { Remove-Item -LiteralPath $zip }
        throw "$asset SHA-256 $actual does not match the pinned $sha256."
    }
    Expand-Archive -LiteralPath $zip -DestinationPath $cache
    if (-not (Test-Path -LiteralPath $pwsh)) { throw "pwsh.exe missing from $asset." }
    $pwsh
}

# The API's records. A property marked hidden is kept on the object and left out of its default presentation:
# console display and the README show exactly the properties that are not hidden.
class PscParameter {
    [string] $Name
    [type] $Type
    [object] $Default
    [object[]] $AllowedValues
    [bool] $Pipeline
    hidden [System.Management.Automation.Language.ParameterAst] $Ast
    [string] ToString() { return $this.Name }
}

class PscOperation {
    [string] $Mode
    [PscParameter[]] $Parameters
    [string[]] $Calls
    hidden [System.Management.Automation.Language.FunctionDefinitionAst[]] $Definitions
}

class PscApi {
    [string] $Synopsis
    [string] $Script
    [string] $SourceSha512
    [string] $DefaultMode
    [PscOperation[]] $Modes
    [PscParameter[]] $Parameters
    [PscMeasure[]] $Measures
    [string[]] $Functions
    [string[]] $Classes
    [PscEnvironment] $Environment
    hidden [System.Management.Automation.Language.ScriptBlockAst] $Ast

    # Sets a binding in this API's environment; the newest binding for its target wins.
    [PscBinding] SetBinding([PscBinding] $binding) { return $this.Environment.Set($binding) }
}

function Get-PscApi {
    [CmdletBinding()]
    [OutputType([PscApi])]
    param()
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'This script has parse errors; its API cannot be described.' }
    $scriptParameters = [System.Collections.Generic.Dictionary[string, System.Management.Automation.Language.ParameterAst]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($parameter in $ast.ParamBlock.Parameters) { $scriptParameters[$parameter.Name.VariablePath.UserPath] = $parameter }
    $functions = [System.Collections.Generic.Dictionary[string, System.Management.Automation.Language.FunctionDefinitionAst]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($function in $ast.BeginBlock.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Parent -isnot [System.Management.Automation.Language.FunctionMemberAst] }, $false)) {
        $functions[$function.Name] = $function
    }
    $switch = $ast.ProcessBlock.Find({ param($node) $node -is [System.Management.Automation.Language.SwitchStatementAst] }, $false)
    $operations = [System.Collections.Generic.List[PscOperation]]::new()
    foreach ($clause in $switch.Clauses) {
        $body = $clause.Item2
        $used = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($variable in $body.FindAll({ param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
            $name = $variable.VariablePath.UserPath
            if ($scriptParameters.ContainsKey($name) -and $name -ne 'Mode') { $null = $used.Add($name) }
        }
        $calls = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($command in $body.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $name = $command.GetCommandName()
            if (-not $name -or -not $functions.ContainsKey($name)) { continue }
            $null = $calls.Add($name)
            $splatted = @($command.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and $_.Splatted }).Count
            if (-not $splatted) { continue }
            $target = $functions[$name]
            $targetParameters = if ($target.Body.ParamBlock) { $target.Body.ParamBlock.Parameters } else { $target.Parameters }
            foreach ($parameter in @($targetParameters)) {
                $parameterName = $parameter.Name.VariablePath.UserPath
                if ($scriptParameters.ContainsKey($parameterName) -and $parameterName -ne 'Mode') { $null = $used.Add($parameterName) }
            }
        }
        $operation = [PscOperation]::new()
        $operation.Mode = $clause.Item1.SafeGetValue()
        $operation.Parameters = [PscParameter[]]@(foreach ($name in $used) { Get-PscApiParameter $scriptParameters[$name] })
        $operation.Calls = [string[]]@($calls)
        $operation.Definitions = [System.Management.Automation.Language.FunctionDefinitionAst[]]@(foreach ($name in $calls) { $functions[$name] })
        $operations.Add($operation)
    }
    $help = $ast.GetHelpContent()
    $api = [PscApi]::new()
    $api.Synopsis = if ($help) { $help.Synopsis.Trim() } else { $null }
    $api.Script = $PSCommandPath
    $api.SourceSha512 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA512).Hash
    $api.DefaultMode = $scriptParameters['Mode'].DefaultValue.SafeGetValue()
    $api.Modes = $operations.ToArray()
    $api.Parameters = [PscParameter[]]@(foreach ($parameter in $ast.ParamBlock.Parameters) { Get-PscApiParameter $parameter })
    $api.Measures = [PscSource]::new($PSCommandPath).Measures
    $api.Functions = [string[]]@($functions.Keys)
    $api.Classes = [string[]]@($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.TypeDefinitionAst] }, $true) | ForEach-Object Name)
    $api.Environment = $script:PscEnvironment
    $api.Ast = $ast
    $api
}

function Get-PscApiParameter {
    [CmdletBinding()]
    [OutputType([PscParameter])]
    param([Parameter(Mandatory)][System.Management.Automation.Language.ParameterAst] $Parameter)
    $allowed = [System.Collections.Generic.List[object]]::new()
    $pipeline = $false
    foreach ($attribute in $Parameter.Attributes) {
        if ($attribute -isnot [System.Management.Automation.Language.AttributeAst]) { continue }
        $attributeType = $attribute.TypeName.GetReflectionAttributeType()
        if ($attributeType -eq [System.Management.Automation.ValidateSetAttribute]) {
            foreach ($argument in $attribute.PositionalArguments) { $allowed.Add($argument.SafeGetValue()) }
        }
        if ($attributeType -eq [System.Management.Automation.ParameterAttribute]) {
            foreach ($argument in $attribute.NamedArguments) { if ($argument.ArgumentName -eq 'ValueFromPipeline') { $pipeline = $true } }
        }
    }
    $described = [PscParameter]::new()
    $described.Name = $Parameter.Name.VariablePath.UserPath
    $described.Type = $Parameter.StaticType
    $described.Default = if ($Parameter.DefaultValue) { $Parameter.DefaultValue.SafeGetValue() } else { $null }
    $described.AllowedValues = $allowed.ToArray()
    $described.Pipeline = $pipeline
    $described.Ast = $Parameter
    $described
}

# The properties a type presents: its public properties that are not hidden, in declaration order.
function Get-PscPresentedProperty {
    [CmdletBinding()]
    [OutputType([System.Reflection.PropertyInfo])]
    param([Parameter(Mandatory)][type] $Type)
    foreach ($property in $Type.GetProperties()) {
        if (-not $property.IsDefined([System.Management.Automation.HiddenAttribute], $false)) { $property }
    }
}

# One Markdown table cell: each element's ToString, joined; cell and row delimiters escaped.
function ConvertTo-PscMarkdownCell {
    [CmdletBinding()]
    [OutputType([string])]
    param([object] $Value)
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($Value)) { if ($null -ne $item) { $parts.Add($item.ToString()) } }
    [string]::Join(', ', $parts).Replace('|', '\|').ReplaceLineEndings(' ')
}

# The Markdown lines of a table of objects of one type, one column per presented property.
function ConvertTo-PscMarkdownTable {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Reflection.PropertyInfo[]] $Columns, [object[]] $Rows)
    '| ' + [string]::Join(' | ', [string[]]@($Columns | ForEach-Object Name)) + ' |'
    '|' + [string]::Join('|', [string[]]@(foreach ($column in $Columns) { '---' })) + '|'
    foreach ($row in @($Rows)) {
        '| ' + [string]::Join(' | ', [string[]]@(foreach ($column in $Columns) { ConvertTo-PscMarkdownCell $column.GetValue($row) })) + ' |'
    }
}

# The README's lines: the API object's presented scalar properties as one table, then each presented sequence
# property under its own name, as a table when its elements are PSC records and as a list otherwise.
function ConvertTo-PscReadme {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][PscApi] $Api)
    '# PSC'
    ''
    $presented = @(Get-PscPresentedProperty -Type ([PscApi]))
    ConvertTo-PscMarkdownTable -Columns @($presented | Where-Object { -not $_.PropertyType.IsArray }) -Rows @($Api)
    foreach ($property in $presented | Where-Object { $_.PropertyType.IsArray }) {
        ''
        '## ' + $property.Name
        ''
        $element = $property.PropertyType.GetElementType()
        $value = $property.GetValue($Api)
        if ($element.Assembly -eq [PscApi].Assembly) { ConvertTo-PscMarkdownTable -Columns @(Get-PscPresentedProperty -Type $element) -Rows $value }
        else { ConvertTo-PscMarkdownCell $value }
    }
}

function Get-LoweringCapability {
    <#
    .SYNOPSIS
        Reports compiler capabilities, runtime versions, and supported contracts.
    #>
    [CmdletBinding()]
    param()

    [pscustomobject]@{
        Compiler                = 'PSC'
        SourcePath              = $PSCommandPath
        SourceSha256            = (Get-FileHash -LiteralPath $PSCommandPath).Hash
        CompileInputs           = @('SourcePath','SourceAst','ClassNames','StaticData')
        Product                 = 'Dev.MansfieldPlumbing.PowerShell.Lowering'
        PowerShellVersion       = $PSVersionTable.PSVersion.ToString()
        RuntimeVersion          = [Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
        PersistedAssemblyBuilder = $null -ne ([Type]::GetType('System.Reflection.Emit.PersistedAssemblyBuilder, System.Reflection.Emit'))
        EmitterEngine           = 'PowerShell.IlEmitter'
        SupportedModes          = @('ClrOnly')
        SemanticContract        = 'Typed PowerShell semantics: checked integral arithmetic, Double integral division, round-half-to-even integral conversion, invariant-culture string comparison, IEEE 754 floats, exact reflected member binding'
        DependencyContract      = 'Zero runtime SMA dependencies for ClrOnly output'
    }
}

function ConvertTo-TypedExpression {
    <#
    .SYNOPSIS
        Lowers a PowerShell class method AST into a validated System.Linq.Expressions.LambdaExpression.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [System.Management.Automation.Language.FunctionMemberAst] $MethodAst
    )

    Convert-MethodAstToLambda -MethodAst $MethodAst
}

function ConvertTo-StaticDataExpression {
    param($Value, [Type] $Type)
    if ($Type -in [IntPtr],[UIntPtr]) { throw 'Native addresses are not durable static data.' }
    if ($null -eq $Value) {
        if ($Type.IsValueType) { throw "Null is not valid for static data of type $Type." }
        return [Linq.Expressions.Expression]::Constant($null, $Type)
    }
    if ($Type.IsArray -and $Type.GetArrayRank() -eq 1) {
        if ($Value -isnot [Array]) { throw "Static data requires an array of $($Type.GetElementType())." }
        $items = [Collections.Generic.List[Linq.Expressions.Expression]]::new()
        foreach ($item in $Value) { $items.Add((ConvertTo-StaticDataExpression $item $Type.GetElementType())) }
        return [Linq.Expressions.Expression]::NewArrayInit($Type.GetElementType(), $items)
    }
    if ($Type -ne [string] -and -not $Type.IsPrimitive) { throw "Static data supports primitive values, strings and their arrays, not $Type." }
    if ($Value.GetType() -ne $Type) { throw "Static data type mismatch: expected $Type, received $($Value.GetType())." }
    return [Linq.Expressions.Expression]::Constant($Value, $Type)
}

function Export-LoweredAssembly {
    <#
    .SYNOPSIS
        Compiles the classes of a typed PowerShell source file into a managed assembly.
    .DESCRIPTION
        Every class in the file is compiled into one assembly, so classes may
        use each other's types, fields, constructors and methods. Properties
        become public fields; their initial values run in the static
        initializer (static properties) or before each constructor body.
        -ClassName names the class whose methods are reported and which holds
        the -EntryPoint; it defaults to the first class.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string] $SourcePath,
        [Parameter()][System.Management.Automation.Language.ScriptBlockAst] $SourceAst,
        [Parameter()][Collections.IDictionary] $StaticData,
        [Parameter()][string] $ClassName,
        [Parameter()][string[]] $ClassNames,
        # Emit only these methods of -ClassName. A body that uses an omitted
        # method fails with an error naming it.
        [Parameter()][string[]] $MethodNames,
        [Parameter(Mandatory)][string] $OutputPath,
        [switch] $Deterministic = $true,

        # Name of a static method to make the program's entry point. It must
        # return [int] or [void] and take no parameters or one [string[]].
        # The output is then an executable with a runtime configuration
        # beside it, runnable with `dotnet <OutputPath>`.
        [Parameter()][string] $EntryPoint
    )

    if ($null -ne $SourceAst) {
        if ($SourcePath) { throw 'Supply SourcePath or SourceAst, not both.' }
        $classes = @($SourceAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.TypeDefinitionAst] -and $n.IsClass }, $true))
        $target = @(if ($ClassName) { $classes | Where-Object Name -eq $ClassName } else { $classes | Select-Object -First 1 })
        if ($target.Count -ne 1) { throw 'SourceAst must contain exactly one target class.' }
        # The caller may compose class copies from independently parsed sources. Extent.Text is provenance,
        # not a serialization of that composed tree. Get-ClassModel and body admission validate the live nodes.
        $parsed = [pscustomobject]@{ Ast = $SourceAst; ClassAst = $target[0] }
    } else {
    $fullSourcePath = if ([IO.Path]::IsPathFullyQualified($SourcePath)) {
        [IO.Path]::GetFullPath($SourcePath)
    }
    else {
        [IO.Path]::GetFullPath((Join-Path (Get-Location) $SourcePath))
    }
    if (-not [IO.File]::Exists($fullSourcePath)) {
        throw "Source file not found: '$fullSourcePath'."
    }

    $source = [IO.File]::ReadAllText($fullSourcePath)
    $parsed = Read-PowerShellClass -Source $source -ClassName $ClassName -SourceFile $fullSourcePath
    }
    $targetClass = $parsed.ClassAst
    $classAsts = @($parsed.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TypeDefinitionAst] -and $n.IsClass }, $true) | Where-Object { -not (Test-AttributeClass $_) })
    # PSC's semantic helpers are lowered with every program.
    if ('PowerShellSemantics' -notin @($classAsts.Name)) { $classAsts += Get-PscSemanticsClass }
    $script:LoweringKeywords = @{}
    foreach ($definition in @(Get-LoweringKeywords $parsed.Ast)) { $script:LoweringKeywords[$definition.Name] = $definition }
    if ($ClassNames) {
        $selected = @(@($ClassNames) + 'PowerShellSemantics' | Sort-Object -Unique)
        $classAsts = @($classAsts | Where-Object Name -in $selected)
        if ($classAsts.Count -ne $selected.Count -or $targetClass.Name -notin $ClassNames) { throw 'ClassNames must identify existing classes and include ClassName.' }
    }
    $model = @(Get-ClassModel -ClassAsts $classAsts)
    Use-ClassMirror -Ast $parsed.Ast
    $mirror = @{} + $script:LoweringClassTypes
    $dataFields = @{}
    if ($null -eq $StaticData) { $StaticData = @{} }
    foreach ($key in $StaticData.Keys) {
        $parts = ([string]$key).Split('.')
        if ($parts.Count -ne 2 -or $parts[0] -notin @($model.Name)) { throw "Unknown or unselected static data field '$key'." }
        $field = $mirror[$parts[0]].GetField($parts[1], [Reflection.BindingFlags]'Public,Static,DeclaredOnly')
        if ($null -eq $field) { throw "Unknown static data field '$key'." }
        $dataFields[$key] = [pscustomobject]@{ Field = $field; Expression = (ConvertTo-StaticDataExpression $StaticData[$key] $field.FieldType) }
    }

    $assemblyName = [IO.Path]::GetFileNameWithoutExtension($OutputPath)
    $session = New-PersistedAssemblySession -AssemblyName $assemblyName
    $declared = [Reflection.BindingFlags]'Public,Static,Instance,DeclaredOnly'
    $script:IlMap = @{ Types = @{}; Members = @{}; ImplicitConstructors = @{} }
    try {
        # 1. Output types, so every signature can name any of them. Enums are complete once their literals exist.
        foreach ($enumAst in @($parsed.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TypeDefinitionAst] -and $n.IsEnum }, $true))) {
            $enumBuilder = $session.Module.DefineEnum($enumAst.Name, [Reflection.TypeAttributes]::Public, (Get-EnumUnderlyingType $enumAst))
            foreach ($literal in (Get-EnumLiterals $enumAst)) { $null = $enumBuilder.DefineLiteral($literal.Name, $literal.Value) }
            $null = $enumBuilder.CreateType()
            $script:IlMap.Types[$mirror[$enumAst.Name]] = $enumBuilder
        }
        foreach ($c in $model) {
            $tb = $session.Module.DefineType($c.Name, [Reflection.TypeAttributes]'Public,Class')
            $session.Types[$c.Name] = $tb
            $script:IlMap.Types[$mirror[$c.Name]] = $tb
        }

        # 2. Fields, constructors and methods, in source order.
        $plans = foreach ($c in $model) {
            $tb = $session.Types[$c.Name]
            $mirrorType = $mirror[$c.Name]
            foreach ($p in $c.Properties) {
                $mf = $mirrorType.GetField($p.Name, $declared)
                $script:IlMap.Members[$mf] = $tb.DefineField($mf.Name, (Get-IlType $mf.FieldType), $mf.Attributes)
            }
            $ctorPlans = @(foreach ($ctorAst in $c.Constructors) {
                [Type[]]$types = @()
                if ($ctorAst) { $types = Get-ParameterTypes $ctorAst }
                $mc = $mirrorType.GetConstructor($declared, $null, $types, $null)
                $cb = $tb.DefineConstructor($mc.Attributes, [Reflection.CallingConventions]::Standard, [Type[]]@($types | ForEach-Object { Get-IlType $_ }))
                if ($ctorAst) {
                    for ($i = 0; $i -lt $ctorAst.Parameters.Count; $i++) { $null = $cb.DefineParameter($i + 1, [Reflection.ParameterAttributes]::None, $ctorAst.Parameters[$i].Name.VariablePath.UserPath) }
                }
                $script:IlMap.Members[$mc] = $cb
                [pscustomobject]@{ Ast = $ctorAst; Builder = $cb }
            })
            foreach ($n in $c.NativeImports) {
                $types = Get-ParameterTypes $n.Ast
                $mm = $mirrorType.GetMethod($n.Ast.Name, $declared, $null, $types, $null)
                $names = [string[]]@($n.Ast.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
                $script:IlMap.Members[$mm] = Add-NativeImportMethod -TypeBuilder $tb -Name $mm.Name -Import $n.Import `
                    -ReturnType (Get-IlType $mm.ReturnType) -ParameterTypes ([Type[]]@($types | ForEach-Object { Get-IlType $_ })) -ParameterNames $names -Persisted
            }
            $methods = @($c.Methods)
            if ($MethodNames -and $c.Name -eq $targetClass.Name) { $methods = @($methods | Where-Object { $_.Name -in $MethodNames }) }
            $methodPlans = foreach ($m in $methods) {
                $types = Get-ParameterTypes $m
                $mm = $mirrorType.GetMethod($m.Name, $declared, $null, $types, $null)
                $mb = $tb.DefineMethod($mm.Name, $mm.Attributes, (Get-IlType $mm.ReturnType), [Type[]]@($types | ForEach-Object { Get-IlType $_ }))
                for ($i = 0; $i -lt $m.Parameters.Count; $i++) { $null = $mb.DefineParameter($i + 1, [Reflection.ParameterAttributes]::None, $m.Parameters[$i].Name.VariablePath.UserPath) }
                Set-NativeCallbackAttribute -Builder $mb -Contract (Get-NativeMethodContract $m)
                $script:IlMap.Members[$mm] = $mb
                [pscustomobject]@{ Ast = $m; Builder = $mb }
            }
            if (-not $c.Constructors.Count) {
                $mc = $mirrorType.GetConstructor($declared, $null, [Type[]]@(), $null)
                if (@($c.Properties | Where-Object { -not $_.IsStatic -and $_.InitialValue }).Count) {
                    $cb = $tb.DefineConstructor($mc.Attributes, [Reflection.CallingConventions]::Standard, [Type[]]@())
                    $script:IlMap.Members[$mc] = $cb
                    $ctorPlans += [pscustomobject]@{ Ast = $null; Builder = $cb }
                } else { $script:IlMap.ImplicitConstructors[$mc] = $tb }
            }
            [pscustomobject]@{ Class = $c; Constructors = @($ctorPlans); Methods = @($methodPlans) }
        }

        # 3. Bodies.
        $emittedMethods = [System.Collections.Generic.List[string]]::new()
        $entryBuilder = $null
        foreach ($plan in $plans) {
            $c = $plan.Class
            $staticInits = @($c.Properties | Where-Object { $_.IsStatic -and $_.InitialValue })
            $instanceInits = @($c.Properties | Where-Object { -not $_.IsStatic -and $_.InitialValue })
            $fieldInputs = @($dataFields.Values | Where-Object { $_.Field.DeclaringType -eq $mirror[$c.Name] })
            if ($staticInits.Count -or $fieldInputs.Count) {
                $lowered = Convert-InitializersToLambda -ClassAst $c.Ast -Initializers $staticInits -Static
                $initializer = $lowered.Lambda
                if ($fieldInputs.Count) {
                $body = [Collections.Generic.List[Linq.Expressions.Expression]]::new()
                $body.Add($lowered.Lambda.Body)
                foreach ($inputField in $fieldInputs) { $body.Add([Linq.Expressions.Expression]::Assign([Linq.Expressions.Expression]::Field($null, $inputField.Field), $inputField.Expression)) }
                $body.Add([Linq.Expressions.Expression]::Empty())
                $initializer = [Linq.Expressions.Expression]::Lambda([Linq.Expressions.Expression]::Block($body), [Linq.Expressions.ParameterExpression[]]@())
                }
                Write-IlMethodBody -Lambda $initializer -MethodBuilder $session.Types[$c.Name].DefineTypeInitializer() -IsStatic
            }
            foreach ($ctor in $plan.Constructors) {
                $lowered = if ($ctor.Ast) { Convert-MethodAstToLambda -MethodAst $ctor.Ast -Initializers $instanceInits }
                           else { Convert-InitializersToLambda -ClassAst $c.Ast -Initializers $instanceInits }
                Write-IlMethodBody -Lambda $lowered.Lambda -MethodBuilder $ctor.Builder -HasThis -BaseConstructor
            }
            foreach ($method in $plan.Methods) {
                $lowered = Convert-MethodAstToLambda -MethodAst $method.Ast
                Write-IlMethodBody -Lambda $lowered.Lambda -MethodBuilder $method.Builder -IsStatic:$lowered.IsStatic -HasThis:$lowered.HasThis
                if ($c.Name -eq $targetClass.Name) {
                    $emittedMethods.Add($lowered.Name)
                    if ($EntryPoint -and $lowered.Name -ceq $EntryPoint) {
                        # ECMA-335 II.15.4.1.2: a static method returning int32 or void,
                        # taking no parameters or one string[].
                        $types = @($lowered.ParameterTypes)
                        $validReturn = $lowered.ReturnType -in [int], [void]
                        $validParams = $types.Count -eq 0 -or ($types.Count -eq 1 -and $types[0] -eq [string[]])
                        $entryNative = Get-NativeMethodContract $method.Ast
                        if ($entryNative -and $entryNative.Kind -eq 'Callback') { throw ('[{0}:{1}] UnmanagedCallersOnly cannot be an entry point.' -f $method.Ast.Extent.StartLineNumber,$method.Ast.Extent.StartColumnNumber) }
                        if (-not $lowered.IsStatic -or -not $validReturn -or -not $validParams) {
                            throw "[{0}:{1}] Entry point '{2}' must be static, return [int] or [void], and take no parameters or one [string[]]." -f `
                                $method.Ast.Extent.StartLineNumber, $method.Ast.Extent.StartColumnNumber, $EntryPoint
                        }
                        $entryBuilder = $method.Builder
                    }
                }
            }
        }
        if ($emittedMethods.Count -eq 0 -and $MethodNames) {
            throw "No matching methods found in class '$($targetClass.Name)' to export."
        }
        if ($EntryPoint -and -not $entryBuilder) {
            throw "Entry point '$EntryPoint' is not an exported method of class '$($targetClass.Name)'."
        }

        # 4. Save.
        $saveResult = Save-PersistedAssemblySession -Session $session -OutputPath $OutputPath -Deterministic:$Deterministic -EntryPoint $entryBuilder
    }
    finally {
        $script:IlMap = @{ Types = @{}; Members = @{} }
        $script:LoweringKeywords = @{}
    }

    [pscustomobject]@{
        OutputPath     = $saveResult.OutputPath
        Length         = $saveResult.Length
        SHA256         = $saveResult.SHA256
        ClassName      = $targetClass.Name
        Classes        = [string[]]@($model | ForEach-Object Name)
        EmittedMethods = $emittedMethods.ToArray()
        Deterministic  = $saveResult.Deterministic
        EntryPoint     = $saveResult.EntryPoint
        RuntimeConfig  = $saveResult.RuntimeConfig
    }
}

# Native AOT: the lowered assembly compiled to machine code by ILC (Microsoft's IL compiler, PSC's backend) and
# linked by PSC's own COFF linker. No MSBuild and no .NET SDK: every input is pinned under tools and verified by hash.

# Pinned tool folders already verified against their manifests in this process.
$script:VerifiedPins = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

# Pinned Native AOT toolchain folders under PSC's NativeAOT folder, found by enumerating it for the newest version of each.
function Get-NativeToolset {
    $tools = Join-Path $PSScriptRoot 'NativeAOT'
    $find = { param([string] $prefix) $found = @(Get-ChildItem -LiteralPath $tools -Directory -Filter ($prefix + '*') | Sort-Object Name); if (-not $found.Count) { throw "Pinned tool '$prefix*' is missing under $tools." }; $found[-1].FullName }
    $toolset = [pscustomobject]@{
        Compiler = & $find 'ilc-1'
        Build = & $find 'ilc-build-'
        Runtime = & $find 'nativeaot-win-x64-'
        Msvc = & $find 'msvc-'
        Sdk = & $find 'windows-sdk-lib-'
    }
    foreach ($folder in $toolset.Compiler, $toolset.Build, $toolset.Runtime, $toolset.Sdk) {
        if ($script:VerifiedPins.Contains($folder)) { continue }
        $manifest = Join-Path $folder 'pin.sha256.csv'
        if (-not [IO.File]::Exists($manifest)) { throw "Pinned tool $folder has no hash manifest." }
        foreach ($entry in Import-Csv -LiteralPath $manifest) {
            $path = Join-Path $folder $entry.Path
            if (-not [IO.File]::Exists($path) -or (Get-FileHash -LiteralPath $path).Hash -cne $entry.Sha256) { throw "Pinned tool file failed verification: $path" }
        }
        $null = $script:VerifiedPins.Add($folder)
    }
    $toolset
}

# ILC's settings for a Windows x64 executable. The feature switches are those the .NET SDK's ILCompiler targets pass
# for PublishAot with InvariantGlobalization and UseSystemResourceKeys (observed from a reference publish); each is
# both a compile-time feature and a runtime knob, as the SDK passes them.
$script:NativeFeatureSwitches = [ordered]@{
    'Microsoft.Extensions.DependencyInjection.VerifyOpenGenericServiceTrimmability' = $true
    'System.ComponentModel.DefaultValueAttribute.IsSupported' = $false
    'System.ComponentModel.Design.IDesignerHost.IsSupported' = $false
    'System.ComponentModel.TypeConverter.EnableUnsafeBinaryFormatterInDesigntimeLicenseContextSerialization' = $false
    'System.ComponentModel.TypeDescriptor.IsComObjectDescriptorSupported' = $false
    'System.Data.DataSet.XmlSerializationIsSupported' = $false
    'System.Diagnostics.Tracing.EventSource.IsSupported' = $false
    'System.Globalization.Invariant' = $true
    'System.Globalization.PredefinedCulturesOnly' = $true
    'System.Linq.Enumerable.IsSizeOptimized' = $true
    'System.Net.SocketsHttpHandler.Http3Support' = $false
    'System.Reflection.Metadata.MetadataUpdater.IsSupported' = $false
    'System.Resources.ResourceManager.AllowCustomResourceTypes' = $false
    'System.Resources.UseSystemResourceKeys' = $true
    'System.Runtime.CompilerServices.RuntimeFeature.IsDynamicCodeSupported' = $false
    'System.Runtime.InteropServices.BuiltInComInterop.IsSupported' = $false
    'System.Runtime.InteropServices.EnableConsumingManagedCodeFromNativeHosting' = $false
    'System.Runtime.InteropServices.EnableCppCLIHostActivation' = $false
    'System.Runtime.InteropServices.Marshalling.EnableGeneratedComInterfaceComImportInterop' = $false
    'System.Runtime.Serialization.EnableUnsafeBinaryFormatterSerialization' = $false
    'System.StartupHookProvider.IsSupported' = $false
    'System.Text.Encoding.EnableUnsafeUTF7Encoding' = $false
    'System.Text.Json.JsonSerializer.IsReflectionEnabledByDefault' = $false
    'System.Threading.Thread.EnableAutoreleasePool' = $false
    'System.Threading.ThreadPool.UseWindowsThreadPool' = $true
    'System.Linq.Expressions.CanEmitObjectArrayDelegate' = $false
}

function Export-NativeImage {
    param(
        [Parameter(Mandatory)][string] $AssemblyPath,
        [Parameter(Mandatory)][string] $OutputPath,
        [ValidateSet('Console', 'Windows')][string] $Subsystem = 'Console'
    )
    $toolset = Get-NativeToolset
    $managed = Join-Path $toolset.Runtime 'runtimes\win-x64\lib\net11.0'
    $native = Join-Path $toolset.Runtime 'runtimes\win-x64\native'
    $object = [IO.Path]::ChangeExtension($OutputPath, '.obj')
    $response = [IO.Path]::ChangeExtension($OutputPath, '.ilc.rsp')

    # 1. ILC: the lowered assembly to one native object.
    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.Add($AssemblyPath)
    $arguments.Add('-o:' + $object)
    foreach ($reference in Get-ChildItem -LiteralPath $managed, $native -File -Filter *.dll | Sort-Object FullName) { $arguments.Add('-r:' + $reference.FullName) }
    foreach ($option in '--targetos:win', '--targetarch:x64', '-O',
        '--export-dynamic-symbol:DotNetRuntimeDebugHeader,DATA', '--export-dynamic-symbol:DotNetRuntimeContractDescriptor,DATA',
        '--initassembly:System.Private.CoreLib', '--initassembly:System.Private.StackTraceMetadata', '--initassembly:System.Private.TypeLoader', '--initassembly:System.Private.Reflection.Execution',
        '--directpinvoke:System.Globalization.Native', '--directpinvoke:System.IO.Compression.Native',
        ('--directpinvokelist:' + (Join-Path $toolset.Build 'build\WindowsAPIs.txt')),
        '--stacktracedata:frames', '--scanreflection', '--methodbodyfolding:generic', '--singlewarn', '--resilient',
        '--generateunmanagedentrypoints:System.Private.CoreLib,HIDDEN', '--feature:System.Diagnostics.Debugger.IsSupported=false', '--runtimeknob:RUNTIME_IDENTIFIER=win-x64') {
        $arguments.Add($option)
    }
    foreach ($switch in $script:NativeFeatureSwitches.Keys) {
        $value = $script:NativeFeatureSwitches[$switch].ToString().ToLowerInvariant()
        $arguments.Add("--feature:$switch=$value"); $arguments.Add("--runtimeknob:$switch=$value")
    }
    [IO.File]::WriteAllLines($response, $arguments)
    $compiler = Join-Path $toolset.Compiler 'tools\ilc.exe'
    $output = & $compiler "@$response" 2>&1
    if ($LASTEXITCODE -ne 0) { throw ("ILC failed ($LASTEXITCODE):`n" + ($output -join "`n")) }

    # 2. PSC's COFF linker: the object, the Native AOT runtime, and the Windows import libraries.
    $inputs = [System.Collections.Generic.List[string]]::new()
    $inputs.Add($object)
    foreach ($name in 'bootstrapper.obj', 'Runtime.WorkstationGC.lib', 'eventpipe-disabled.lib', 'Runtime.VxsortDisabled.lib', 'standalonegc-disabled.lib', 'aotminipal.lib',
        'zlibstatic.lib', 'brotlicommon.lib', 'brotlienc.lib', 'brotlidec.lib', 'zstd_static.lib', 'System.Globalization.Native.Aot.lib', 'System.IO.Compression.Native.Aot.lib') { $inputs.Add((Join-Path $native $name)) }
    foreach ($name in 'advapi32.lib', 'bcrypt.lib', 'crypt32.lib', 'iphlpapi.lib', 'kernel32.lib', 'mswsock.lib', 'ncrypt.lib', 'normaliz.lib', 'ntdll.lib',
        'ole32.lib', 'oleaut32.lib', 'secur32.lib', 'Synchronization.lib', 'user32.lib', 'version.lib', 'ws2_32.lib') { $inputs.Add((Join-Path $toolset.Sdk "um\x64\$name")) }
    $libraries = @((Join-Path $toolset.Msvc 'lib\x64'), (Join-Path $toolset.Sdk 'ucrt\x64'), (Join-Path $toolset.Sdk 'um\x64'))
    $resolution = Resolve-CoffLink -Inputs $inputs.ToArray() -LibraryDirectories $libraries -DefaultLibraries @('ucrt.lib') -IgnoredDefaultLibraries @('libucrt.lib') -Entry 'wmainCRTStartup'
    if ($resolution.Unresolved.Count) { throw ("Native link: unresolved external symbols:`n" + ($resolution.Unresolved -join "`n")) }
    $image = Write-CoffImage -Resolution $resolution -Path ([IO.Path]::GetFullPath($OutputPath)) -Merges @('.managedcode=.text', 'hydrated=.bss') -Subsystem $(if ($Subsystem -eq 'Windows') { 2 } else { 3 }) -StackReserve 1572864
    [pscustomobject]@{ OutputPath = [IO.Path]::GetFullPath($OutputPath); Object = $object; ObjectLength = (Get-Item -LiteralPath $object).Length; ImageLength = (Get-Item -LiteralPath $OutputPath).Length; Image = $image }
}

function Test-LoweredAssembly {
    <#
    .SYNOPSIS
        Inspects an emitted assembly, validates zero SMA dependencies, and generates a receipt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $AssemblyPath
    )

    $fullPath = [IO.Path]::GetFullPath($AssemblyPath)
    if (-not [IO.File]::Exists($fullPath)) {
        throw "Assembly file not found: '$fullPath'."
    }

    $bytes = [IO.File]::ReadAllBytes($fullPath)
    $sha256 = [BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($bytes)).Replace('-', '')

    $stream = [IO.MemoryStream]::new($bytes, $false)
    $peReader = [Reflection.PortableExecutable.PEReader]::new($stream)
    try {
        $meta = [Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($peReader)
        $mvid = $meta.GetGuid($meta.GetModuleDefinition().Mvid).ToString()

        $assemblyRefs = [System.Collections.Generic.List[string]]::new()
        foreach ($handle in $meta.AssemblyReferences) {
            $ref = $meta.GetAssemblyReference($handle)
            $refName = $meta.GetString($ref.Name)
            $assemblyRefs.Add($refName)
        }
    }
    finally {
        $peReader.Dispose()
        $stream.Dispose()
    }

    $smaReferenced = $assemblyRefs -contains 'System.Management.Automation'

    [pscustomobject]@{
        AssemblyPath       = $fullPath
        Length             = $bytes.Length
        SHA256             = $sha256
        MVID               = $mvid
        AssemblyReferences = $assemblyRefs.ToArray()
        SmaReferenced      = $smaReferenced
        ClrOnlyAdmitted    = (-not $smaReferenced)
    }
}

# ---------------------------------------------------------------------------------------------------------------
# Native linking. COFF objects (regular and /bigobj), short import objects and .lib archives are read as typed
# records; symbols are resolved the way the platform linker resolves them: explicit inputs first, then libraries in
# the order they are named or found, repeating until nothing new is pulled in. Reference: Microsoft PE/COFF
# specification (pinned under the shared root as references\pe-coff-spec-*).
# ---------------------------------------------------------------------------------------------------------------

function Read-CoffName([byte[]] $Bytes, [int] $Offset, [int] $Length) {
    $end = $Offset
    while ($end -lt $Offset + $Length -and $end -lt $Bytes.Length -and $Bytes[$end] -ne 0) { $end++ }
    [Text.Encoding]::UTF8.GetString($Bytes, $Offset, $end - $Offset)
}

function Read-CoffStringAt([byte[]] $Bytes, [int] $Offset) {
    $end = $Offset
    while ($end -lt $Bytes.Length -and $Bytes[$end] -ne 0) { $end++ }
    [Text.Encoding]::UTF8.GetString($Bytes, $Offset, $end - $Offset)
}

function Split-CoffDirectives([string] $Text) {
    # Whitespace-separated options; a double-quoted run keeps its spaces and loses its quotes.
    $tokens = [Collections.Generic.List[string]]::new()
    $current = [Text.StringBuilder]::new(); $quoted = $false
    foreach ($character in $Text.ToCharArray()) {
        if ($character -eq [char]'"') { $quoted = -not $quoted; continue }
        if (-not $quoted -and [char]::IsWhiteSpace($character)) {
            if ($current.Length) { $tokens.Add($current.ToString()); $null = $current.Clear() }
            continue
        }
        $null = $current.Append($character)
    }
    if ($current.Length) { $tokens.Add($current.ToString()) }
    foreach ($token in $tokens) {
        if ($token.Length -lt 2 -or ($token[0] -ne [char]'/' -and $token[0] -ne [char]'-')) { continue }
        $colon = $token.IndexOf([char]':')
        if ($colon -lt 0) { [pscustomobject]@{ Option = $token.Substring(1).ToUpperInvariant(); Value = '' } }
        else { [pscustomobject]@{ Option = $token.Substring(1, $colon - 1).ToUpperInvariant(); Value = $token.Substring($colon + 1) } }
    }
}

function Read-CoffImportObject([byte[]] $Bytes, [string] $Origin) {
    # IMPORT_OBJECT_HEADER: Sig1 0, Sig2 0xFFFF, Version 0, Machine, TimeDateStamp, SizeOfData, Ordinal/Hint, Type.
    $typeBits = [BitConverter]::ToUInt16($Bytes, 18)
    $symbol = Read-CoffStringAt $Bytes 20
    $dll = Read-CoffStringAt $Bytes (20 + [Text.Encoding]::UTF8.GetByteCount($symbol) + 1)
    $kind = @('Code', 'Data', 'Const', 'Unknown')[$typeBits -band 3]
    $nameType = ($typeBits -shr 2) -band 7
    $importName = $symbol
    if ($nameType -ge 2) { $importName = $importName.TrimStart([char]'?', [char]'@', [char]'_') }
    if ($nameType -eq 3) { $at = $importName.IndexOf([char]'@'); if ($at -ge 0) { $importName = $importName.Substring(0, $at) } }
    $defined = [Collections.Generic.List[string]]::new(); $defined.Add('__imp_' + $symbol); if ($kind -eq 'Code') { $defined.Add($symbol) }
    [pscustomobject]@{
        Kind = 'Import'; Origin = $Origin; Machine = [BitConverter]::ToUInt16($Bytes, 6); Symbol = $symbol; Dll = $dll
        ImportKind = $kind; NameType = $nameType; ImportName = $importName; OrdinalOrHint = [BitConverter]::ToUInt16($Bytes, 16)
        ByOrdinal = ($nameType -eq 0); Defines = $defined.ToArray()
    }
}

function Read-CoffObject([byte[]] $Bytes, [string] $Origin) {
    if ($Bytes.Length -ge 20 -and [BitConverter]::ToUInt16($Bytes, 0) -eq 0 -and [BitConverter]::ToUInt16($Bytes, 2) -eq 0xFFFF) {
        $version = [BitConverter]::ToUInt16($Bytes, 4)
        if ($version -eq 0) { return Read-CoffImportObject $Bytes $Origin }
        $class = [guid]::new([byte[]]$Bytes[12..27])
        if ($class -ne [guid]'d1baa1c7-baee-4ba9-af20-faf66aa4dcb8') { throw "$Origin`: unsupported anonymous object (version $version, class $class)." }
        $big = $true; $machine = [BitConverter]::ToUInt16($Bytes, 6)
        $sectionCount = [int][BitConverter]::ToUInt32($Bytes, 44); $symbolTable = [int][BitConverter]::ToUInt32($Bytes, 48); $symbolCount = [int][BitConverter]::ToUInt32($Bytes, 52)
        $sectionTable = 56; $recordSize = 20
    } else {
        $big = $false; $machine = [BitConverter]::ToUInt16($Bytes, 0)
        $sectionCount = [int][BitConverter]::ToUInt16($Bytes, 2); $symbolTable = [int][BitConverter]::ToUInt32($Bytes, 8); $symbolCount = [int][BitConverter]::ToUInt32($Bytes, 12)
        $sectionTable = 20 + [BitConverter]::ToUInt16($Bytes, 16); $recordSize = 18
    }
    $stringTable = $symbolTable + $symbolCount * $recordSize
    $sections = [Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $sectionCount; $i++) {
        $h = $sectionTable + 40 * $i
        $name = Read-CoffName $Bytes $h 8
        if ($name.StartsWith('/') -and $symbolTable -gt 0) { $name = Read-CoffStringAt $Bytes ($stringTable + [int]::Parse($name.Substring(1))) }
        $characteristics = [BitConverter]::ToUInt32($Bytes, $h + 36)
        $relocationCount = [int][BitConverter]::ToUInt16($Bytes, $h + 32); $relocations = [int][BitConverter]::ToUInt32($Bytes, $h + 24)
        if (($characteristics -band 0x01000000) -ne 0 -and $relocationCount -eq 0xFFFF) { $relocationCount = [int][BitConverter]::ToUInt32($Bytes, $relocations) - 1; $relocations += 10 }
        $sections.Add([pscustomobject]@{
            Number = $i + 1; Name = $name; Characteristics = $characteristics
            RawSize = [int][BitConverter]::ToUInt32($Bytes, $h + 16); RawOffset = [int][BitConverter]::ToUInt32($Bytes, $h + 20)
            RelocationOffset = $relocations; RelocationCount = $relocationCount
        })
    }
    $symbols = [object[]]::new($symbolCount)
    for ($i = 0; $i -lt $symbolCount; $i++) {
        $at = $symbolTable + $i * $recordSize
        $name = if ([BitConverter]::ToUInt32($Bytes, $at) -eq 0) { Read-CoffStringAt $Bytes ($stringTable + [int][BitConverter]::ToUInt32($Bytes, $at + 4)) } else { Read-CoffName $Bytes $at 8 }
        $section = if ($big) { [BitConverter]::ToInt32($Bytes, $at + 12) } else { [int][BitConverter]::ToInt16($Bytes, $at + 12) }
        $typeAt = if ($big) { $at + 16 } else { $at + 14 }
        $auxCount = [int]$Bytes[$typeAt + 3]
        $symbols[$i] = [pscustomobject]@{
            Index = $i; Name = $name; Value = [BitConverter]::ToUInt32($Bytes, $at + 8); Section = $section
            Type = [BitConverter]::ToUInt16($Bytes, $typeAt); StorageClass = [int]$Bytes[$typeAt + 2]; AuxCount = $auxCount; AuxOffset = $at + $recordSize
        }
        $i += $auxCount
    }
    $directives = @(foreach ($s in $sections) {
        if ($s.Name -eq '.drectve' -and $s.RawSize -gt 0) {
            $text = [Text.Encoding]::UTF8.GetString($Bytes, $s.RawOffset, $s.RawSize)
            if ($text.Length -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
            Split-CoffDirectives $text
        }
    })
    [pscustomobject]@{
        Kind = 'Object'; Origin = $Origin; Bytes = $Bytes; Machine = $machine; BigObject = $big; RecordSize = $recordSize
        Sections = $sections.ToArray(); Symbols = $symbols; Directives = $directives
    }
}

function Read-CoffArchive([string] $Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 8 -or [Text.Encoding]::ASCII.GetString($bytes, 0, 8) -ne "!<arch>`n") { throw "$Path is not a COFF archive." }
    $members = [Collections.Generic.List[object]]::new(); $index = $null; $first = $null; $longNames = $null
    $at = 8; $linkerMembers = 0
    while ($at + 60 -le $bytes.Length) {
        $name = [Text.Encoding]::ASCII.GetString($bytes, $at, 16).TrimEnd()
        $size = [int]::Parse([Text.Encoding]::ASCII.GetString($bytes, $at + 48, 10).Trim())
        $data = $at + 60
        if ($name -eq '/') { $linkerMembers++; if ($linkerMembers -eq 1) { $first = @{ Offset = $data; Size = $size } } else { $index = @{ Offset = $data; Size = $size } } }
        elseif ($name -eq '//') { $longNames = @{ Offset = $data; Size = $size } }
        else { $members.Add([pscustomobject]@{ HeaderOffset = $at; Name = $name; DataOffset = $data; Size = $size }) }
        $at = $data + $size; if (($at % 2) -ne 0) { $at++ }
    }
    $symbolToMember = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
    if ($null -ne $index) {
        # Second linker member: little-endian member offsets, then symbol count, 1-based member indices, names.
        $p = $index.Offset; $memberCount = [int][BitConverter]::ToUInt32($bytes, $p); $p += 4
        $offsets = [int[]]::new($memberCount); for ($i = 0; $i -lt $memberCount; $i++) { $offsets[$i] = [int][BitConverter]::ToUInt32($bytes, $p); $p += 4 }
        $symbolCount = [int][BitConverter]::ToUInt32($bytes, $p); $p += 4
        $indices = [int[]]::new($symbolCount); for ($i = 0; $i -lt $symbolCount; $i++) { $indices[$i] = [int][BitConverter]::ToUInt16($bytes, $p); $p += 2 }
        for ($i = 0; $i -lt $symbolCount; $i++) { $symbol = Read-CoffStringAt $bytes $p; $p += [Text.Encoding]::UTF8.GetByteCount($symbol) + 1; if (-not $symbolToMember.ContainsKey($symbol)) { $symbolToMember[$symbol] = $offsets[$indices[$i] - 1] } }
    } elseif ($null -ne $first) {
        # First linker member only: big-endian count and offsets, then names.
        $p = $first.Offset; $count = [int](([uint32]$bytes[$p] -shl 24) -bor ([uint32]$bytes[$p + 1] -shl 16) -bor ([uint32]$bytes[$p + 2] -shl 8) -bor [uint32]$bytes[$p + 3]); $p += 4
        $offsets = [int[]]::new($count); for ($i = 0; $i -lt $count; $i++) { $offsets[$i] = [int](([uint32]$bytes[$p] -shl 24) -bor ([uint32]$bytes[$p + 1] -shl 16) -bor ([uint32]$bytes[$p + 2] -shl 8) -bor [uint32]$bytes[$p + 3]); $p += 4 }
        for ($i = 0; $i -lt $count; $i++) { $symbol = Read-CoffStringAt $bytes $p; $p += [Text.Encoding]::UTF8.GetByteCount($symbol) + 1; if (-not $symbolToMember.ContainsKey($symbol)) { $symbolToMember[$symbol] = $offsets[$i] } }
    }
    $byHeader = @{}; foreach ($m in $members) { $byHeader[$m.HeaderOffset] = $m }
    [pscustomobject]@{ Kind = 'Archive'; Path = $Path; Bytes = $bytes; Members = $members.ToArray(); MemberAt = $byHeader; SymbolIndex = $symbolToMember; LongNames = $longNames }
}

function Get-CoffArchiveMember($Archive, [int] $HeaderOffset) {
    $member = $Archive.MemberAt[$HeaderOffset]
    if ($null -eq $member) { throw "$($Archive.Path): no member at offset $HeaderOffset." }
    $name = $member.Name
    if ($name.StartsWith('/') -and $null -ne $Archive.LongNames) { $name = Read-CoffStringAt $Archive.Bytes ($Archive.LongNames.Offset + [int]::Parse($name.Substring(1))) }
    $name = $name.TrimEnd([char]'/')
    $data = [byte[]]::new($member.Size); [Array]::Copy($Archive.Bytes, $member.DataOffset, $data, 0, $member.Size)
    Read-CoffObject $data ((Split-Path -Leaf $Archive.Path) + '(' + $name + ')')
}

function Find-CoffLibrary([string] $Name, [string[]] $Directories) {
    $file = if ([IO.Path]::HasExtension($Name)) { $Name } else { $Name + '.lib' }
    if ([IO.Path]::IsPathRooted($file) -and [IO.File]::Exists($file)) { return [IO.Path]::GetFullPath($file) }
    foreach ($directory in $Directories) { $candidate = Join-Path $directory $file; if ([IO.File]::Exists($candidate)) { return [IO.Path]::GetFullPath($candidate) } }
    $null
}

function Resolve-CoffLink {
    param([string[]] $Inputs, [string[]] $LibraryDirectories = @(), [string[]] $DefaultLibraries = @(), [string[]] $IgnoredDefaultLibraries = @(), [string] $Entry)
    $ignoreAll = $IgnoredDefaultLibraries -contains '*'
    $ignored = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $IgnoredDefaultLibraries) { if ($name -ne '*') { $null = $ignored.Add([IO.Path]::GetFileNameWithoutExtension($name)) } }
    $defined = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $definedSymbol = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $referenced = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $weakDefault = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $alternate = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $libraries = [Collections.Generic.List[object]]::new(); $libraryPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $loaded = [Collections.Generic.List[object]]::new(); $loadedMembers = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $missingLibraries = [Collections.Generic.List[string]]::new()

    $addLibrary = {
        param([string] $name, [bool] $fromDirective)
        $stem = [IO.Path]::GetFileNameWithoutExtension($name)
        if ($fromDirective -and ($ignoreAll -or $ignored.Contains($stem))) { return }
        $path = Find-CoffLibrary $name $LibraryDirectories
        if ($null -eq $path) { if (-not $missingLibraries.Contains($name)) { $missingLibraries.Add($name) }; return }
        if ($libraryPaths.Add($path)) { $libraries.Add((Read-CoffArchive $path)) }
    }
    $addObject = {
        param($object)
        $loaded.Add($object)
        if ($object.Kind -eq 'Import') {
            foreach ($name in $object.Defines) { if (-not $defined.ContainsKey($name)) { $defined[$name] = $object } }
            return
        }
        foreach ($directive in $object.Directives) {
            switch ($directive.Option) {
                'DEFAULTLIB' { & $addLibrary $directive.Value $true }
                'ALTERNATENAME' { $eq = $directive.Value.IndexOf([char]'='); if ($eq -gt 0) { $from = $directive.Value.Substring(0, $eq); if (-not $alternate.ContainsKey($from)) { $alternate[$from] = $directive.Value.Substring($eq + 1) } } }
                'INCLUDE' { $null = $referenced.Add($directive.Value) }
            }
        }
        foreach ($symbol in $object.Symbols) {
            if ($null -eq $symbol -or ($symbol.StorageClass -ne 2 -and $symbol.StorageClass -ne 105)) { continue }
            if ($symbol.StorageClass -eq 105) {
                $tag = [int][BitConverter]::ToUInt32($object.Bytes, $symbol.AuxOffset)
                $weakDefault[$symbol.Name] = $object.Symbols[$tag].Name
                $null = $referenced.Add($symbol.Name)
                continue
            }
            if ($symbol.Section -ne 0 -or $symbol.Value -ne 0) { if (-not $defined.ContainsKey($symbol.Name)) { $defined[$symbol.Name] = $object; $definedSymbol[$symbol.Name] = $symbol } }
            else { $null = $referenced.Add($symbol.Name) }
        }
    }
    $isResolved = { param([string] $name) $defined.ContainsKey($name) -or ($alternate.ContainsKey($name) -and $defined.ContainsKey($alternate[$name])) }
    # Symbols the linker itself defines while writing the image (PE/COFF: image base; load-configuration tables).
    $linkerDefined = [pscustomobject]@{ Kind = 'Linker'; Origin = '(linker)' }
    foreach ($name in '__ImageBase', '__guard_flags', '__guard_fids_table', '__guard_fids_count', '__guard_iat_table', '__guard_iat_count',
        '__guard_longjmp_table', '__guard_longjmp_count', '__guard_eh_cont_table', '__guard_eh_cont_count', '__dynamic_value_reloc_table', '__enclave_config', '__volatile_metadata') {
        $defined[$name] = $linkerDefined
    }
    if ($Entry) { $null = $referenced.Add($Entry) }

    foreach ($inputPath in $Inputs) {
        $full = [IO.Path]::GetFullPath($inputPath)
        if ($full.EndsWith('.lib', [StringComparison]::OrdinalIgnoreCase)) { if ($libraryPaths.Add($full)) { $libraries.Add((Read-CoffArchive $full)) } }
        else { & $addObject (Read-CoffObject ([IO.File]::ReadAllBytes($full)) (Split-Path -Leaf $full)) }
    }
    foreach ($name in $DefaultLibraries) { & $addLibrary $name $false }

    # Pull archive members until a full pass over the libraries adds nothing.
    do {
        $pulled = $false
        for ($l = 0; $l -lt $libraries.Count; $l++) {
            $library = $libraries[$l]
            foreach ($name in @($referenced)) {
                if (& $isResolved $name) { continue }
                foreach ($candidate in @($name, $(if ($alternate.ContainsKey($name)) { $alternate[$name] } else { $null }))) {
                    if ($null -eq $candidate -or -not $library.SymbolIndex.ContainsKey($candidate)) { continue }
                    $key = $library.Path + '|' + $library.SymbolIndex[$candidate]
                    if ($loadedMembers.Add($key)) { & $addObject (Get-CoffArchiveMember $library $library.SymbolIndex[$candidate]); $pulled = $true }
                    break
                }
            }
        }
    } while ($pulled)

    $open = @(foreach ($name in $referenced) {
        if (& $isResolved $name) { continue }
        if ($weakDefault.ContainsKey($name) -and (& $isResolved $weakDefault[$name])) { continue }
        $name
    })
    $unresolved = @($open | Sort-Object -Unique)
    $imports = @($loaded | Where-Object { $_.Kind -eq 'Import' } | Where-Object { $referenced.Contains('__imp_' + $_.Symbol) -or $referenced.Contains($_.Symbol) })
    [pscustomobject]@{
        Objects = @($loaded | Where-Object { $_.Kind -eq 'Object' } | ForEach-Object { $_.Origin })
        Libraries = @($libraries | ForEach-Object { $_.Path })
        MissingLibraries = $missingLibraries.ToArray()
        Imports = @($imports | Sort-Object Dll, ImportName | ForEach-Object { [pscustomobject]@{ Dll = $_.Dll; Name = $_.ImportName; Symbol = $_.Symbol; Kind = $_.ImportKind; ByOrdinal = $_.ByOrdinal; Hint = $_.OrdinalOrHint } })
        Unresolved = $unresolved
        Loaded = $loaded.ToArray()
        Defined = $defined; DefinedSymbol = $definedSymbol; Alternate = $alternate; WeakDefault = $weakDefault; Entry = $Entry
    }
}

function Get-CoffSectionDefinitions($Object) {
    # Per section number: the section-definition auxiliary record (COMDAT selection, associated section) and, for a
    # COMDAT, its leader: the first symbol after the section symbol that names the same section (PE/COFF 5.5.6).
    $definitions = [object[]]::new($Object.Sections.Count + 1)
    $symbols = $Object.Symbols
    for ($i = 0; $i -lt $symbols.Count; $i++) {
        $symbol = $symbols[$i]
        if ($null -eq $symbol -or $symbol.Section -le 0 -or $symbol.Section -gt $Object.Sections.Count) { continue }
        $entry = $definitions[$symbol.Section]
        if ($null -eq $entry) {
            if ($symbol.StorageClass -eq 3 -and $symbol.Value -eq 0 -and $symbol.AuxCount -gt 0) {
                $at = $symbol.AuxOffset
                $number = [int][BitConverter]::ToUInt16($Object.Bytes, $at + 12) -bor ([int][BitConverter]::ToUInt16($Object.Bytes, $at + 16) -shl 16)
                $definitions[$symbol.Section] = [pscustomobject]@{ Selection = [int]$Object.Bytes[$at + 14]; Associated = $number; Leader = $null }
            }
            continue
        }
        if ($null -eq $entry.Leader -and $entry.Selection -ne 0 -and $entry.Selection -ne 5) { $entry.Leader = $symbol }
    }
    $definitions
}

function Write-CoffImage {
    # Writes a PE32+ image from a resolution: keeps the sections link.exe keeps (/OPT:REF over COMDATs), lays out
    # output sections by name before '$' with the suffix as the sort key, builds the import table and jump thunks,
    # applies AMD64 relocations, sorts the function table and writes base relocations. Reference: PE/COFF
    # specification sections 3, 4, 5 and 6.
    param($Resolution, [string] $Path, [string[]] $Merges = @(), [int] $Subsystem = 3, [long] $StackReserve = 0x100000)
    $imageBase = [long]0x140000000
    $fileAlignment = 0x200; $sectionAlignment = 0x1000
    $alignUp = { param([long] $value, [long] $alignment) [long]([Math]::Ceiling($value / $alignment) * $alignment) }
    $objects = @($Resolution.Loaded | Where-Object { $_.Kind -eq 'Object' })
    $id = 0; foreach ($o in $Resolution.Loaded) { $o | Add-Member -NotePropertyName Id -NotePropertyValue $id -Force; $id++ }
    $errors = [Collections.Generic.List[string]]::new()

    # Output-section names: link.exe's own merges, then the objects' directives, then the command line's.
    $mergeMap = @{ '.xdata' = '.rdata'; '.00cfg' = '.rdata'; '.idata' = '.rdata'; '.didat' = '.rdata'; '.edata' = '.rdata'; '.bss' = '.data'; '.tls' = '.data' }
    $mergeValues = [Collections.Generic.List[string]]::new()
    foreach ($o in $objects) { foreach ($d in $o.Directives) { if ($d.Option -eq 'MERGE') { $mergeValues.Add($d.Value) } } }
    foreach ($m in $Merges) { $mergeValues.Add($m) }
    foreach ($m in $mergeValues) { $eq = $m.IndexOf([char]'='); if ($eq -gt 0) { $mergeMap[$m.Substring(0, $eq)] = $m.Substring($eq + 1) } }
    $outputOf = { param([string] $group) $name = $group; for ($k = 0; $k -lt 16 -and $mergeMap.ContainsKey($name); $k++) { $name = $mergeMap[$name] }; $name }
    # Sections the linker consumes rather than places (debug records, guard and volatile-access tables, checksums).
    $consumed = [Collections.Generic.HashSet[string]]::new([string[]]@('.drectve', '.debug', '.gfids', '.giats', '.gljmp', '.gehcont', '.gssep', '.gsspr', '.chks64', '.voltbl'), [StringComparer]::Ordinal)

    # 1. Contributions: one per kept input section.
    $contributions = [object[]]::new($Resolution.Loaded.Count)
    $all = [Collections.Generic.List[object]]::new(); $sequence = 0
    foreach ($o in $objects) {
        $definitions = Get-CoffSectionDefinitions $o
        $list = [object[]]::new($o.Sections.Count + 1)
        foreach ($section in $o.Sections) {
            $ch = [long]$section.Characteristics
            $dollar = $section.Name.IndexOf([char]'$'); $group = if ($dollar -ge 0) { $section.Name.Substring(0, $dollar) } else { $section.Name }
            if (($ch -band 0xA00) -ne 0 -or $consumed.Contains($group)) { continue }
            if ($group -eq '.idata') { $errors.Add("$($o.Origin): long-format import section $($section.Name) is not supported."); continue }
            $definition = $definitions[$section.Number]
            $comdat = ($ch -band 0x1000) -ne 0
            if ($comdat -and $null -ne $definition -and $definition.Selection -ne 5 -and $null -ne $definition.Leader -and $definition.Leader.StorageClass -eq 2) {
                $winner = $Resolution.Defined[$definition.Leader.Name]
                if ($null -eq $winner -or $winner.Kind -ne 'Object' -or $winner.Id -ne $o.Id) { continue }
            }
            $alignBits = [int](($ch -shr 20) -band 0xF)
            $list[$section.Number] = [pscustomobject]@{
                Sequence = $sequence++; Object = $o; Section = $section; Name = $section.Name; Group = $group; Output = (& $outputOf $group)
                Comdat = $comdat; Associated = $(if ($comdat -and $null -ne $definition -and $definition.Selection -eq 5) { $definition.Associated } else { 0 })
                Code = ($ch -band 0x20) -ne 0; Uninitialized = ($ch -band 0x80) -ne 0; Characteristics = $ch
                Size = [long]$section.RawSize; Align = $(if ($alignBits -gt 0) { 1 -shl ($alignBits - 1) } else { 16 })
                Live = $false; Rva = [long]-1; Children = [Collections.Generic.List[object]]::new(); Synthetic = $null
            }
        }
        foreach ($c in $list) {
            if ($null -eq $c -or $c.Associated -eq 0) { continue }
            $parent = $list[$c.Associated]
            if ($null -eq $parent) { $list[$c.Section.Number] = $null } else { $parent.Children.Add($c) }
        }
        foreach ($c in $list) { if ($null -ne $c) { $all.Add($c) } }
        $contributions[$o.Id] = $list
    }

    # 2. Symbol targets: a kept contribution and offset, an absolute value, an import slot or thunk, a common block.
    $nameTargets = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $symbolTargets = [object[]]::new($Resolution.Loaded.Count)
    $resolveName = {
        param([string] $name)
        if ($nameTargets.ContainsKey($name)) { return $nameTargets[$name] }
        $n = $name
        if (-not $Resolution.Defined.ContainsKey($n) -and $Resolution.Alternate.ContainsKey($n)) { $n = $Resolution.Alternate[$n] }
        $t = $null
        if ($Resolution.Defined.ContainsKey($n)) {
            $d = $Resolution.Defined[$n]
            switch ($d.Kind) {
                'Linker' { $t = if ($n -eq '__ImageBase') { [pscustomobject]@{ K = 'Base' } } else { [pscustomobject]@{ K = 'Absolute'; V = [long]$(if ($n -eq '__guard_flags') { 0x100 } else { 0 }) } } }
                'Import' { $t = [pscustomobject]@{ K = $(if ($n.StartsWith('__imp_')) { 'Slot' } else { 'Thunk' }); Import = $d } }
                'Object' {
                    $s = $Resolution.DefinedSymbol[$n]
                    if ($s.Section -gt 0) { $t = [pscustomobject]@{ K = 'Section'; C = $contributions[$d.Id][$s.Section]; Offset = [long]$s.Value; Name = $n } }
                    elseif ($s.Section -eq -1) { $t = [pscustomobject]@{ K = 'Absolute'; V = [long]$s.Value } }
                    else { $t = [pscustomobject]@{ K = 'Common'; Name = $n; Size = [long]$s.Value } }
                }
            }
        }
        $nameTargets[$name] = $t
        $t
    }
    $symbolTarget = {
        param($o, [int] $index)
        $cache = $symbolTargets[$o.Id]; if ($null -eq $cache) { $cache = [object[]]::new($o.Symbols.Count); $symbolTargets[$o.Id] = $cache }
        if ($null -ne $cache[$index]) { return $cache[$index] }
        $s = $o.Symbols[$index]; $t = $null
        if ($s.StorageClass -eq 105) {
            $t = & $resolveName $s.Name
            if ($null -eq $t) { $t = & $symbolTarget $o ([int][BitConverter]::ToUInt32($o.Bytes, $s.AuxOffset)) }
        } elseif ($s.StorageClass -eq 2) { $t = & $resolveName $s.Name }
        elseif ($s.Section -gt 0) { $t = [pscustomobject]@{ K = 'Section'; C = $contributions[$o.Id][$s.Section]; Offset = [long]$s.Value; Name = $s.Name } }
        elseif ($s.Section -eq -1) { $t = [pscustomobject]@{ K = 'Absolute'; V = [long]$s.Value } }
        if ($null -eq $t) { $t = [pscustomobject]@{ K = 'Unresolved'; Name = $s.Name } }
        $cache[$index] = $t
        $t
    }

    # 3. Reachability (/OPT:REF): non-COMDAT sections, the entry point, the TLS and load-configuration records and
    # /INCLUDE names are roots; a live section makes its relocation targets and its associated sections live.
    $usedImports = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $usedThunks = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $usedCommon = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $work = [Collections.Generic.Stack[object]]::new()
    $markTarget = {
        param($t, [string] $where)
        switch ($t.K) {
            'Section' { if ($null -eq $t.C) { $errors.Add("$where references $($t.Name) in a discarded section.") } elseif (-not $t.C.Live) { $t.C.Live = $true; $work.Push($t.C) } }
            'Slot' { $usedImports[$t.Import.Symbol] = $t.Import }
            'Thunk' { $usedImports[$t.Import.Symbol] = $t.Import; $usedThunks[$t.Import.Symbol] = $t.Import }
            'Common' { if (-not $usedCommon.ContainsKey($t.Name)) { $usedCommon[$t.Name] = $t } }
            'Unresolved' { $errors.Add("$where references unresolved $($t.Name).") }
        }
    }
    foreach ($c in $all) { if (-not $c.Comdat) { $c.Live = $true; $work.Push($c) } }
    $rootNames = [Collections.Generic.List[string]]::new()
    if ($Resolution.Entry) { $rootNames.Add($Resolution.Entry) }
    foreach ($name in '_tls_used', '_load_config_used') { if ($Resolution.Defined.ContainsKey($name)) { $rootNames.Add($name) } }
    foreach ($o in $objects) { foreach ($d in $o.Directives) { if ($d.Option -eq 'INCLUDE') { $rootNames.Add($d.Value) } } }
    foreach ($name in $rootNames) {
        $t = & $resolveName $name
        if ($null -eq $t) { $errors.Add("root $name is unresolved.") } else { & $markTarget $t '(root)' }
    }
    while ($work.Count) {
        $c = $work.Pop(); $o = $c.Object; $bytes = $o.Bytes
        for ($i = 0; $i -lt $c.Section.RelocationCount; $i++) {
            $at = $c.Section.RelocationOffset + 10 * $i
            $t = & $symbolTarget $o ([int][BitConverter]::ToUInt32($bytes, $at + 4))
            & $markTarget $t "$($o.Origin)($($c.Name))"
        }
        foreach ($child in $c.Children) { if (-not $child.Live) { $child.Live = $true; $work.Push($child) } }
    }
    if ($errors.Count) { throw ("Link failed:`n" + (($errors | Select-Object -First 40) -join "`n")) }

    # 4. Synthetic contributions: jump thunks, the import address table and the rest of the import data, common
    # blocks and the debug directory that carries the extended DLL characteristics.
    $byDll = [ordered]@{}
    foreach ($import in @($usedImports.Values | Sort-Object { $_.Dll.ToLowerInvariant() }, ImportName)) {
        $key = $import.Dll.ToLowerInvariant(); if (-not $byDll.Contains($key)) { $byDll[$key] = [Collections.Generic.List[object]]::new() }
        $byDll[$key].Add($import)
    }
    $newSynthetic = {
        param([string] $kind, [string] $output, [long] $size, [int] $align, [bool] $code, [bool] $uninitialized)
        $c = [pscustomobject]@{
            Sequence = $all.Count; Object = $null; Section = $null; Name = $output; Group = $output; Output = $output
            Comdat = $false; Associated = 0; Code = $code; Uninitialized = $uninitialized; Characteristics = [long]0
            Size = $size; Align = $align; Live = $true; Rva = [long]-1; Children = $null; Synthetic = $kind
        }
        $all.Add($c); $c
    }
    $slotOffset = @{}; $iatSize = [long]0
    foreach ($key in $byDll.Keys) { foreach ($import in $byDll[$key]) { $slotOffset[$import.Symbol] = $iatSize; $iatSize += 8 }; $iatSize += 8 }
    $iat = & $newSynthetic 'ImportAddressTable' '.rdata' $iatSize 8 $false $false
    $iat.Sequence = -1   # first in .rdata, as link.exe places it
    $thunkOffset = @{}; $n = 0; foreach ($symbol in @($usedThunks.Keys | Sort-Object)) { $thunkOffset[$symbol] = [long]8 * $n; $n++ }
    $thunks = if ($n) { & $newSynthetic 'Thunks' '.text' ([long]8 * $n) 16 $true $false } else { $null }
    $descriptorSize = [long]20 * ($byDll.Count + 1)
    $lookupAt = & $alignUp $descriptorSize 8
    $hintAt = @{}; $p = $lookupAt + $iatSize
    foreach ($key in $byDll.Keys) { foreach ($import in $byDll[$key]) { if (-not $import.ByOrdinal) { $hintAt[$import.Symbol] = $p; $p += & $alignUp (2 + [Text.Encoding]::ASCII.GetByteCount($import.ImportName) + 1) 2 } } }
    $dllNameAt = @{}; foreach ($key in $byDll.Keys) { $dllNameAt[$key] = $p; $p += [Text.Encoding]::ASCII.GetByteCount($byDll[$key][0].Dll) + 1 }
    $importData = & $newSynthetic 'ImportData' '.rdata' $p 8 $false $false
    $debug = & $newSynthetic 'Debug' '.rdata' 32 4 $false $false
    $commonContribution = @{}
    foreach ($entry in @($usedCommon.Values | Sort-Object Name)) {
        $align = 1; while ($align -lt $entry.Size -and $align -lt 16) { $align *= 2 }
        $commonContribution[$entry.Name] = & $newSynthetic 'Common' '.data' $entry.Size $align $false $true
    }

    # 5. Layout: output sections in link.exe's order; within one, initialized before uninitialized, then by input
    # group (first appearance), full section name (ordinal), and input order.
    $live = @($all | Where-Object { $_.Live })
    $groupOrder = @{}; foreach ($c in $live) { if (-not $groupOrder.ContainsKey($c.Group)) { $groupOrder[$c.Group] = $groupOrder.Count } }
    $outputNames = [Collections.Generic.List[string]]::new()
    foreach ($name in '.text', '.rdata', '.data', '.pdata') { if (@($live | Where-Object { $_.Output -eq $name }).Count) { $outputNames.Add($name) } }
    foreach ($c in $live) { if (-not $outputNames.Contains($c.Output)) { $outputNames.Add($c.Output) } }
    $known = @{ '.text' = 0x60000020; '.rdata' = 0x40000040; '.data' = [int]-1073741760; '.pdata' = 0x40000040 }   # .data: 0xC0000040
    $outputs = [Collections.Generic.List[object]]::new()
    $rva = [long]$sectionAlignment
    foreach ($name in $outputNames) {
        $memberList = [Collections.Generic.List[object]]::new(); foreach ($c in $live) { if ($c.Output -eq $name) { $memberList.Add($c) } }
        $memberList.Sort([Comparison[object]] {
            param($a, $b)
            $r = $a.Uninitialized.CompareTo($b.Uninitialized); if ($r) { return $r }
            # The TLS template leads its output section; the import address table leads .rdata.
            $ga = if ($a.Group -eq '.tls') { -2 } elseif ($a.Sequence -lt 0) { -1 } else { $groupOrder[$a.Group] }
            $gb = if ($b.Group -eq '.tls') { -2 } elseif ($b.Sequence -lt 0) { -1 } else { $groupOrder[$b.Group] }
            $r = $ga.CompareTo($gb); if ($r) { return $r }
            $r = [string]::CompareOrdinal($a.Name, $b.Name); if ($r) { return $r }
            $a.Sequence.CompareTo($b.Sequence)
        })
        $members = $memberList.ToArray()
        $offset = [long]0; $initializedEnd = [long]0; $code = $false; $flags = [long]0
        foreach ($c in $members) {
            $offset = & $alignUp $offset $c.Align
            $c.Rva = $rva + $offset; $offset += $c.Size
            if (-not $c.Uninitialized) { $initializedEnd = $offset }
            if ($c.Code) { $code = $true }
            $flags = $flags -bor $c.Characteristics
        }
        $characteristics = if ($known.ContainsKey($name)) { [int]$known[$name] } else {
            $f = $flags -band 0xFE0000E0; if ($initializedEnd -gt 0) { $f = $f -band (-bnot 0x80) }; [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$f), 0)
        }
        $outputs.Add([pscustomobject]@{ Name = $name; Rva = $rva; VirtualSize = $offset; InitializedSize = $initializedEnd; Code = $code; Characteristics = $characteristics; Members = $members; Data = $null; FileOffset = [long]0; RawSize = [long]0 })
        $rva = & $alignUp ($rva + [Math]::Max($offset, 1)) $sectionAlignment
    }
    $outputIndex = @{}; for ($i = 0; $i -lt $outputs.Count; $i++) { $outputIndex[$outputs[$i].Name] = $i }
    $outputOfRva = { param([long] $r) foreach ($s in $outputs) { if ($r -ge $s.Rva -and $r -lt $s.Rva + [Math]::Max($s.VirtualSize, 1)) { return $s } }; $null }
    $targetRva = {
        param($t)
        switch ($t.K) {
            'Section' { return $t.C.Rva + $t.Offset }
            'Slot' { return $iat.Rva + $slotOffset[$t.Import.Symbol] }
            'Thunk' { return $thunks.Rva + $thunkOffset[$t.Import.Symbol] }
            'Common' { return $commonContribution[$t.Name].Rva }
            'Base' { return [long]0 }
        }
        throw "no address for target kind $($t.K)."
    }

    # 6. Section contents and relocations.
    foreach ($s in $outputs) {
        $s.Data = [byte[]]::new($s.InitializedSize)
        if ($s.Code) { [Array]::Fill($s.Data, [byte]0xCC) }
        foreach ($c in $s.Members) { if ($null -ne $c.Section -and -not $c.Uninitialized -and $c.Size -gt 0) { [Array]::Copy($c.Object.Bytes, $c.Section.RawOffset, $s.Data, $c.Rva - $s.Rva, $c.Size) } }
    }
    $baseRelocations = [Collections.Generic.List[long]]::new()
    $tlsStart = [long]-1
    foreach ($c in $live) { if ($c.Group -eq '.tls' -and ($tlsStart -lt 0 -or $c.Rva -lt $tlsStart)) { $tlsStart = $c.Rva } }
    foreach ($s in $outputs) {
        $data = $s.Data
        foreach ($c in $s.Members) {
            if ($null -eq $c.Section) { continue }
            $o = $c.Object; $bytes = $o.Bytes
            for ($i = 0; $i -lt $c.Section.RelocationCount; $i++) {
                $at = $c.Section.RelocationOffset + 10 * $i
                $offset = [long][BitConverter]::ToUInt32($bytes, $at)
                $type = [int][BitConverter]::ToUInt16($bytes, $at + 8)
                if ($type -eq 0) { continue }
                $t = & $symbolTarget $o ([int][BitConverter]::ToUInt32($bytes, $at + 4))
                $place = $c.Rva + $offset; $here = [int]($place - $s.Rva)
                $absolute = $t.K -eq 'Absolute'
                $targetAddress = if ($absolute) { $t.V } else { & $targetRva $t }
                switch ($type) {
                    1 { # ADDR64
                        $value = [BitConverter]::ToInt64($data, $here) + $(if ($absolute) { $targetAddress } else { $imageBase + $targetAddress })
                        [BitConverter]::GetBytes([long]$value).CopyTo($data, $here)
                        if (-not $absolute) { $baseRelocations.Add($place) }
                    }
                    3 { # ADDR32NB
                        $value = [long][BitConverter]::ToInt32($data, $here) + $targetAddress
                        if ($value -lt 0 -or $value -gt [uint32]::MaxValue) { throw "$($o.Origin)($($c.Name)): ADDR32NB out of range." }
                        [Array]::Copy([BitConverter]::GetBytes([long]$value), 0, $data, $here, 4)
                    }
                    { $_ -ge 4 -and $_ -le 9 } { # REL32 .. REL32_5
                        if ($absolute) { throw "$($o.Origin)($($c.Name)): relative relocation to an absolute symbol." }
                        $value = [long][BitConverter]::ToInt32($data, $here) + $targetAddress - ($place + 4 + ($type - 4))
                        if ($value -lt [int]::MinValue -or $value -gt [int]::MaxValue) { throw "$($o.Origin)($($c.Name)): REL32 out of range." }
                        [BitConverter]::GetBytes([int]$value).CopyTo($data, $here)
                    }
                    10 { # SECTION
                        $owner = & $outputOfRva $targetAddress
                        [BitConverter]::GetBytes([uint16]($outputIndex[$owner.Name] + 1)).CopyTo($data, $here)
                    }
                    11 { # SECREL: from the TLS template's start for thread-local data, else from the output section's
                        $origin = if ($t.K -eq 'Section' -and $t.C.Group -eq '.tls') { $tlsStart } else { (& $outputOfRva $targetAddress).Rva }
                        $value = [long][BitConverter]::ToInt32($data, $here) + $targetAddress - $origin
                        [Array]::Copy([BitConverter]::GetBytes([long]$value), 0, $data, $here, 4)
                    }
                    default { throw "$($o.Origin)($($c.Name)): AMD64 relocation type $type is not supported." }
                }
            }
        }
    }

    # 7. Synthetic contents: import directory, lookup and address tables, hint/name entries, DLL names; thunks.
    $rdata = $outputs[$outputIndex['.rdata']]
    $iatHere = [int]($iat.Rva - $rdata.Rva); $dataHere = [int]($importData.Rva - $rdata.Rva)
    $slot = 0; $d = 0
    foreach ($key in $byDll.Keys) {
        $descriptor = $dataHere + 20 * $d
        [BitConverter]::GetBytes([uint32]($importData.Rva + $lookupAt + 8 * $slot)).CopyTo($rdata.Data, $descriptor)          # OriginalFirstThunk
        [BitConverter]::GetBytes([uint32]($importData.Rva + $dllNameAt[$key])).CopyTo($rdata.Data, $descriptor + 12)          # Name
        [BitConverter]::GetBytes([uint32]($iat.Rva + 8 * $slot)).CopyTo($rdata.Data, $descriptor + 16)                        # FirstThunk
        [Text.Encoding]::ASCII.GetBytes($byDll[$key][0].Dll).CopyTo($rdata.Data, $dataHere + [int]$dllNameAt[$key])
        foreach ($import in $byDll[$key]) {
            $entry = if ($import.ByOrdinal) { [long]::MinValue -bor [long]$import.OrdinalOrHint } else {
                $h = $dataHere + [int]$hintAt[$import.Symbol]
                [BitConverter]::GetBytes([uint16]$import.OrdinalOrHint).CopyTo($rdata.Data, $h)
                [Text.Encoding]::ASCII.GetBytes($import.ImportName).CopyTo($rdata.Data, $h + 2)
                [long]($importData.Rva + $hintAt[$import.Symbol])
            }
            [BitConverter]::GetBytes([long]$entry).CopyTo($rdata.Data, $dataHere + [int]$lookupAt + 8 * $slot)
            [BitConverter]::GetBytes([long]$entry).CopyTo($rdata.Data, $iatHere + 8 * $slot)
            $slot++
        }
        $slot++; $d++
    }
    if ($null -ne $thunks) {
        $text = $outputs[$outputIndex['.text']]
        foreach ($symbol in $thunkOffset.Keys) {
            $at = [int]($thunks.Rva + $thunkOffset[$symbol] - $text.Rva)
            $text.Data[$at] = 0xFF; $text.Data[$at + 1] = 0x25
            [BitConverter]::GetBytes([int](($iat.Rva + $slotOffset[$symbol]) - ($thunks.Rva + $thunkOffset[$symbol] + 6))).CopyTo($text.Data, $at + 2)
        }
    }

    # 8. Function table sorted by begin address (the unwinder binary-searches it).
    $exceptionRva = [long]0; $exceptionSize = [long]0
    if ($outputIndex.ContainsKey('.pdata')) {
        $pdata = $outputs[$outputIndex['.pdata']]
        $count = [int]($pdata.InitializedSize / 12)
        $entries = [Collections.Generic.List[object]]::new()
        for ($i = 0; $i -lt $count; $i++) { $b = [byte[]]::new(12); [Array]::Copy($pdata.Data, 12 * $i, $b, 0, 12); $entries.Add($b) }
        $i = 0; foreach ($b in @($entries | Sort-Object { [BitConverter]::ToUInt32($_, 0) })) { [Array]::Copy($b, 0, $pdata.Data, 12 * $i, 12); $i++ }
        $exceptionRva = $pdata.Rva; $exceptionSize = 12 * $count
    }

    # 9. Base relocations: one block per 4 KiB page, DIR64 entries, padded to 4 bytes.
    $relocStream = [IO.MemoryStream]::new(); $relocWriter = [IO.BinaryWriter]::new($relocStream)
    $sorted = @($baseRelocations | Sort-Object -Unique)
    $k = 0
    while ($k -lt $sorted.Count) {
        $page = $sorted[$k] -band (-bnot [long]0xFFF); $start = $k
        while ($k -lt $sorted.Count -and ($sorted[$k] -band (-bnot [long]0xFFF)) -eq $page) { $k++ }
        $entryCount = $k - $start; $padded = $entryCount + ($entryCount % 2)
        $relocWriter.Write([uint32]$page); $relocWriter.Write([uint32](8 + 2 * $padded))
        for ($j = $start; $j -lt $k; $j++) { $relocWriter.Write([uint16]((10 -shl 12) -bor ($sorted[$j] -band 0xFFF))) }
        if ($padded -ne $entryCount) { $relocWriter.Write([uint16]0) }
    }
    $relocWriter.Flush()
    if ($relocStream.Length) {
        $outputs.Add([pscustomobject]@{ Name = '.reloc'; Rva = $rva; VirtualSize = $relocStream.Length; InitializedSize = $relocStream.Length; Code = $false; Characteristics = 0x42000040; Members = @(); Data = $relocStream.ToArray(); FileOffset = [long]0; RawSize = [long]0 })
        $rva = & $alignUp ($rva + $relocStream.Length) $sectionAlignment
    }

    # 10. File layout, debug directory, headers.
    $headerSize = & $alignUp (0x40 + 4 + 20 + 240 + 40 * $outputs.Count) $fileAlignment
    $fileOffset = $headerSize
    foreach ($s in $outputs) { $s.RawSize = & $alignUp $s.InitializedSize $fileAlignment; $s.FileOffset = $(if ($s.RawSize) { $fileOffset } else { 0 }); $fileOffset += $s.RawSize }
    $debugHere = [int]($debug.Rva - $rdata.Rva)
    $debugFile = $rdata.FileOffset + $debugHere
    [BitConverter]::GetBytes([uint32]20).CopyTo($rdata.Data, $debugHere + 12)                 # IMAGE_DEBUG_TYPE_EX_DLLCHARACTERISTICS
    [BitConverter]::GetBytes([uint32]4).CopyTo($rdata.Data, $debugHere + 16)
    [BitConverter]::GetBytes([uint32]($debug.Rva + 28)).CopyTo($rdata.Data, $debugHere + 20)
    [BitConverter]::GetBytes([uint32]($debugFile + 28)).CopyTo($rdata.Data, $debugHere + 24)
    [BitConverter]::GetBytes([uint32]1).CopyTo($rdata.Data, $debugHere + 28)                  # CET compatible

    $entryTarget = & $resolveName $Resolution.Entry
    $directoryOf = { param([string] $name) if ($Resolution.Defined.ContainsKey($name)) { & $targetRva (& $resolveName $name) } else { [long]0 } }
    $tlsRva = & $directoryOf '_tls_used'
    $loadConfigRva = & $directoryOf '_load_config_used'
    $loadConfigSize = [long]0
    if ($loadConfigRva) { $owner = & $outputOfRva $loadConfigRva; $loadConfigSize = [BitConverter]::ToUInt32($owner.Data, [int]($loadConfigRva - $owner.Rva)) }
    $reloc = if ($outputIndex.Count -lt $outputs.Count) { $outputs[$outputs.Count - 1] } else { $null }
    $directories = @(
        @(0, 0), @(($importData.Rva), $descriptorSize), @(0, 0), @($exceptionRva, $exceptionSize), @(0, 0),
        @($(if ($reloc) { $reloc.Rva } else { 0 }), $(if ($reloc) { $reloc.VirtualSize } else { 0 })),
        @($debug.Rva, 28), @(0, 0), @(0, 0), @($tlsRva, $(if ($tlsRva) { 0x28 } else { 0 })), @($loadConfigRva, $loadConfigSize),
        @(0, 0), @($iat.Rva, $iatSize), @(0, 0), @(0, 0), @(0, 0))
    $codeSize = [long]0; $dataSize = [long]0
    foreach ($s in $outputs) { if ($s.Code) { $codeSize += $s.RawSize } else { $dataSize += $s.RawSize } }

    $stream = [IO.MemoryStream]::new(); $w = [IO.BinaryWriter]::new($stream)
    $w.Write([uint16]0x5A4D); $w.Write([byte[]]::new(0x3A)); $w.Write([uint32]0x40)        # MZ, e_lfanew
    $w.Write([uint32]0x4550)                                                               # PE\0\0
    $w.Write([uint16]0x8664); $w.Write([uint16]$outputs.Count); $w.Write([uint32]0); $w.Write([uint32]0); $w.Write([uint32]0)
    $w.Write([uint16]240); $w.Write([uint16]0x22)                                         # executable, large address aware
    $w.Write([uint16]0x20B); $w.Write([byte]14); $w.Write([byte]0)
    $w.Write([uint32]$codeSize); $w.Write([uint32]$dataSize); $w.Write([uint32]0)
    $w.Write([uint32](& $targetRva $entryTarget)); $w.Write([uint32]$outputs[0].Rva)
    $w.Write([uint64]$imageBase); $w.Write([uint32]$sectionAlignment); $w.Write([uint32]$fileAlignment)
    $w.Write([uint16]6); $w.Write([uint16]0); $w.Write([uint16]0); $w.Write([uint16]0); $w.Write([uint16]6); $w.Write([uint16]0)
    $w.Write([uint32]0); $w.Write([uint32]$rva); $w.Write([uint32]$headerSize); $w.Write([uint32]0)
    $w.Write([uint16]$Subsystem); $w.Write([uint16]0x8160)                               # high entropy VA, dynamic base, NX, terminal server aware
    $w.Write([uint64]$StackReserve); $w.Write([uint64]0x1000); $w.Write([uint64]0x100000); $w.Write([uint64]0x1000)
    $w.Write([uint32]0); $w.Write([uint32]16)
    foreach ($pair in $directories) { $w.Write([uint32]$pair[0]); $w.Write([uint32]$pair[1]) }
    foreach ($s in $outputs) {
        $nameBytes = [byte[]]::new(8); [Text.Encoding]::ASCII.GetBytes($s.Name).CopyTo($nameBytes, 0); $w.Write($nameBytes)
        $w.Write([uint32]$s.VirtualSize); $w.Write([uint32]$s.Rva); $w.Write([uint32]$s.RawSize); $w.Write([uint32]$s.FileOffset)
        $w.Write([uint32]0); $w.Write([uint32]0); $w.Write([uint16]0); $w.Write([uint16]0); $w.Write([int]$s.Characteristics)
    }
    $w.Write([byte[]]::new($headerSize - $stream.Length))
    foreach ($s in $outputs) { if ($s.RawSize) { $w.Write($s.Data); $w.Write([byte[]]::new($s.RawSize - $s.Data.Length)) } }
    $w.Flush()
    [IO.File]::WriteAllBytes($Path, $stream.ToArray())
    [pscustomobject]@{
        Path = $Path; Size = $stream.Length; Sections = @($outputs | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Rva = $_.Rva; VirtualSize = $_.VirtualSize; RawSize = $_.RawSize } })
        Imports = @($usedImports.Values | ForEach-Object { [pscustomobject]@{ Dll = $_.Dll; Name = $_.ImportName; ByOrdinal = $_.ByOrdinal; Hint = $_.OrdinalOrHint } })
        Kept = $live.Count; Discarded = ($all.Count - $live.Count); BaseRelocations = $sorted.Count
    }
}

# ============================================================================
# MEASURES
# Terms are NIST SP 800-55v1's: measurement is "the process of obtaining quantitative values using quantitative
# methods"; measures are "quantifiable and objective values that result from measurement"; a metric is a measure
# held to a set target. PSC sets no targets. Each measurement method is a class deriving from PscMeasurementMethod;
# its Locate method is the method of measurement, and the measure is the number of extents it returns.
# ============================================================================

class PscMeasure {
    [string] $Entity
    [type] $Method
    [int] $Value
    hidden [System.Management.Automation.Language.IScriptExtent[]] $Locations
}

class PscSource {
    [string] $Path
    [string] $Sha512
    [System.Management.Automation.Language.ScriptBlockAst] $Ast
    [System.Management.Automation.Language.Token[]] $Tokens
    [System.Management.Automation.Language.ParseError[]] $ParseErrors
    [PscMeasure[]] $Measures

    PscSource([string] $path) {
        $this.Path = $path
        $this.Sha512 = (Get-FileHash -LiteralPath $path -Algorithm SHA512).Hash
        $parsedTokens = $null; $parsedErrors = $null
        $this.Ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$parsedTokens, [ref]$parsedErrors)
        $this.Tokens = $parsedTokens
        $this.ParseErrors = $parsedErrors
        $found = [System.Collections.Generic.List[PscMeasure]]::new()
        foreach ($method in [PscMeasurementMethod]::All()) { $found.Add($method.Measure($this)) }
        $this.Measures = $found.ToArray()
    }
}

class PscMeasurementMethod {
    static hidden [System.Collections.Generic.Dictionary[string, type]] $Cmdlets = [System.Collections.Generic.Dictionary[string, type]]::new([StringComparer]::OrdinalIgnoreCase)

    [System.Collections.Generic.List[System.Management.Automation.Language.IScriptExtent]] Locate([PscSource] $source) { throw [System.NotImplementedException]::new($this.GetType().Name) }

    [PscMeasure] Measure([PscSource] $source) {
        $found = $this.Locate($source)
        $measure = [PscMeasure]::new()
        $measure.Entity = $source.Path
        $measure.Method = $this.GetType()
        $measure.Value = $found.Count
        $measure.Locations = $found.ToArray()
        return $measure
    }

    static [PscMeasurementMethod[]] All() {
        $methods = [System.Collections.Generic.List[PscMeasurementMethod]]::new()
        foreach ($type in [PscMeasurementMethod].Assembly.GetTypes()) {
            if ($type.IsSubclassOf([PscMeasurementMethod])) { $methods.Add([PscMeasurementMethod][Activator]::CreateInstance($type)) }
        }
        return $methods.ToArray()
    }

    static [System.Collections.Generic.List[System.Management.Automation.Language.IScriptExtent]] Nodes([PscSource] $source, [type] $nodeType) {
        $found = [System.Collections.Generic.List[System.Management.Automation.Language.IScriptExtent]]::new()
        foreach ($node in $source.Ast.FindAll({ param($n) $nodeType.IsInstanceOfType($n) }, $true)) { $found.Add($node.Extent) }
        return $found
    }

    # The cmdlet type a command name resolves to in this session, through aliases; $null for anything else.
    static [type] ResolveCmdlet([string] $name) {
        $type = $null
        if ([PscMeasurementMethod]::Cmdlets.TryGetValue($name, [ref]$type)) { return $type }
        $info = Get-Command -Name $name -ErrorAction Ignore | Select-Object -First 1
        if ($info -is [System.Management.Automation.AliasInfo]) { $info = $info.ResolvedCommand }
        if ($info -is [System.Management.Automation.CmdletInfo]) { $type = $info.ImplementingType }
        [PscMeasurementMethod]::Cmdlets[$name] = $type
        return $type
    }

    static [System.Collections.Generic.List[System.Management.Automation.Language.CommandAst]] Commands([PscSource] $source, [type] $cmdletType) {
        $found = [System.Collections.Generic.List[System.Management.Automation.Language.CommandAst]]::new()
        foreach ($command in $source.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $name = $command.GetCommandName()
            if ($name -and [PscMeasurementMethod]::ResolveCmdlet($name) -eq $cmdletType) { $found.Add($command) }
        }
        return $found
    }

    # Commands whose first element is not a name SMA can read, by the kind of node it is.
    static [System.Collections.Generic.List[System.Management.Automation.Language.IScriptExtent]] CommandsNamedBy([PscSource] $source, [type] $elementType, [type[]] $excluded) {
        $found = [System.Collections.Generic.List[System.Management.Automation.Language.IScriptExtent]]::new()
        foreach ($command in $source.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $first = $command.CommandElements[0]
            if ($first -is [System.Management.Automation.Language.StringConstantExpressionAst] -or -not $elementType.IsInstanceOfType($first)) { continue }
            $skip = $false
            foreach ($type in $excluded) { if ($type.IsInstanceOfType($first)) { $skip = $true } }
            if (-not $skip) { $found.Add($command.Extent) }
        }
        return $found
    }
}

class AddTypeCommands : PscMeasurementMethod {
    [System.Collections.Generic.List[System.Management.Automation.Language.IScriptExtent]] Locate([PscSource] $source) {
        $found = [System.Collections.Generic.List[System.Management.Automation.Language.IScriptExtent]]::new()
        foreach ($command in [PscMeasurementMethod]::Commands($source, [Microsoft.PowerShell.Commands.AddTypeCommand])) { $found.Add($command.Extent) }
        return $found
    }
}

# Add-Type commands that SMA's static binder binds to TypeDefinition or MemberDefinition: source text compiled at run time.
class AddTypeSourceText : PscMeasurementMethod {
    [System.Collections.Generic.List[System.Management.Automation.Language.IScriptExtent]] Locate([PscSource] $source) {
        $found = [System.Collections.Generic.List[System.Management.Automation.Language.IScriptExtent]]::new()
        foreach ($command in [PscMeasurementMethod]::Commands($source, [Microsoft.PowerShell.Commands.AddTypeCommand])) {
            $bound = [System.Management.Automation.Language.StaticParameterBinder]::BindCommand($command, $true).BoundParameters
            if ($bound.ContainsKey('TypeDefinition') -or $bound.ContainsKey('MemberDefinition')) { $found.Add($command.Extent) }
        }
        return $found
    }
}

class InvokeExpressionCommands : PscMeasurementMethod {
    [System.Collections.Generic.List[System.Management.Automation.Language.IScriptExtent]] Locate([PscSource] $source) {
        $found = [System.Collections.Generic.List[System.Management.Automation.Language.IScriptExtent]]::new()
        foreach ($command in [PscMeasurementMethod]::Commands($source, [Microsoft.PowerShell.Commands.InvokeExpressionCommand])) { $found.Add($command.Extent) }
        return $found
    }
}

# [scriptblock]::Create(...): script text turned into a script block at run time.
class ScriptBlockCreateCalls : PscMeasurementMethod {
    [System.Collections.Generic.List[System.Management.Automation.Language.IScriptExtent]] Locate([PscSource] $source) {
        $found = [System.Collections.Generic.List[System.Management.Automation.Language.IScriptExtent]]::new()
        foreach ($call in $source.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Static }, $true)) {
            if ($call.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and $call.Expression.TypeName.GetReflectionType() -eq [scriptblock] -and
                $call.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $call.Member.Value -eq 'Create') { $found.Add($call.Extent) }
        }
        return $found
    }
}

class HereStrings : PscMeasurementMethod {
    [System.Collections.Generic.List[System.Management.Automation.Language.IScriptExtent]] Locate([PscSource] $source) {
        $found = [System.Collections.Generic.List[System.Management.Automation.Language.IScriptExtent]]::new()
        foreach ($token in $source.Tokens) {
            if ($token.Kind -eq [System.Management.Automation.Language.TokenKind]::HereStringLiteral -or $token.Kind -eq [System.Management.Automation.Language.TokenKind]::HereStringExpandable) { $found.Add($token.Extent) }
        }
        return $found
    }
}

class ScriptBlockExpressions : PscMeasurementMethod {
    [System.Collections.Generic.List[System.Management.Automation.Language.IScriptExtent]] Locate([PscSource] $source) { return [PscMeasurementMethod]::Nodes($source, [System.Management.Automation.Language.ScriptBlockExpressionAst]) }
}

class CommandsNamedByVariable : PscMeasurementMethod {
    [System.Collections.Generic.List[System.Management.Automation.Language.IScriptExtent]] Locate([PscSource] $source) { return [PscMeasurementMethod]::CommandsNamedBy($source, [System.Management.Automation.Language.VariableExpressionAst], [type[]]@()) }
}

class ScriptBlockLiteralsInvoked : PscMeasurementMethod {
    [System.Collections.Generic.List[System.Management.Automation.Language.IScriptExtent]] Locate([PscSource] $source) { return [PscMeasurementMethod]::CommandsNamedBy($source, [System.Management.Automation.Language.ScriptBlockExpressionAst], [type[]]@()) }
}

class CommandsNamedByOtherExpression : PscMeasurementMethod {
    [System.Collections.Generic.List[System.Management.Automation.Language.IScriptExtent]] Locate([PscSource] $source) {
        return [PscMeasurementMethod]::CommandsNamedBy($source, [System.Management.Automation.Language.ExpressionAst], [type[]]@([System.Management.Automation.Language.VariableExpressionAst], [System.Management.Automation.Language.ScriptBlockExpressionAst]))
    }
}

# Calls naming a System.Type member whose first parameter is a name (GetMethod, GetProperty, GetType, InvokeMember, ...)
# with a text constant as that argument. The member set is read from System.Type itself.
class MemberLookupsByText : PscMeasurementMethod {
    [System.Collections.Generic.List[System.Management.Automation.Language.IScriptExtent]] Locate([PscSource] $source) {
        $lookups = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($member in [type].GetMethods()) {
            $parameters = $member.GetParameters()
            if ($parameters.Length -gt 0 -and $parameters[0].ParameterType -eq [string] -and $parameters[0].Name -in 'name', 'typeName') { $null = $lookups.Add($member.Name) }
        }
        $found = [System.Collections.Generic.List[System.Management.Automation.Language.IScriptExtent]]::new()
        foreach ($call in $source.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
            if ($call.Member -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -or -not $lookups.Contains($call.Member.Value)) { continue }
            if ($null -eq $call.Arguments -or $call.Arguments.Count -eq 0) { continue }
            if ($call.Arguments[0] -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $found.Add($call.Extent) }
        }
        return $found
    }
}

class HashtableLiterals : PscMeasurementMethod {
    [System.Collections.Generic.List[System.Management.Automation.Language.IScriptExtent]] Locate([PscSource] $source) { return [PscMeasurementMethod]::Nodes($source, [System.Management.Automation.Language.HashtableAst]) }
}

# Hashtable literals with only constant keys that are not converted to a type ([T]@{...}) and not assigned to a variable
# that is splatted: records whose field names are text.
class HashtableRecords : PscMeasurementMethod {
    [System.Collections.Generic.List[System.Management.Automation.Language.IScriptExtent]] Locate([PscSource] $source) {
        $splatted = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($variable in $source.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.Splatted }, $true)) { $null = $splatted.Add($variable.VariablePath.UserPath) }
        $found = [System.Collections.Generic.List[System.Management.Automation.Language.IScriptExtent]]::new()
        foreach ($table in $source.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)) {
            if ($table.Parent -is [System.Management.Automation.Language.ConvertExpressionAst]) { continue }
            $statement = $table.Parent.Parent
            if ($statement -is [System.Management.Automation.Language.AssignmentStatementAst] -and $statement.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $splatted.Contains($statement.Left.VariablePath.UserPath)) { continue }
            $constant = $true
            foreach ($pair in $table.KeyValuePairs) { if ($pair.Item1 -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { $constant = $false } }
            if ($constant) { $found.Add($table.Extent) }
        }
        return $found
    }
}

class QuotedTextConstants : PscMeasurementMethod {
    [System.Collections.Generic.List[System.Management.Automation.Language.IScriptExtent]] Locate([PscSource] $source) {
        $found = [System.Collections.Generic.List[System.Management.Automation.Language.IScriptExtent]]::new()
        foreach ($node in $source.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)) {
            if ($node.StringConstantType -ne [System.Management.Automation.Language.StringConstantType]::BareWord) { $found.Add($node.Extent) }
        }
        return $found
    }
}

class ExpandableTexts : PscMeasurementMethod {
    [System.Collections.Generic.List[System.Management.Automation.Language.IScriptExtent]] Locate([PscSource] $source) { return [PscMeasurementMethod]::Nodes($source, [System.Management.Automation.Language.ExpandableStringExpressionAst]) }
}

# -match, -notmatch, -replace and -split in every casing, binary and unary, and [regex] type uses.
class RegexUses : PscMeasurementMethod {
    [System.Collections.Generic.List[System.Management.Automation.Language.IScriptExtent]] Locate([PscSource] $source) {
        $kinds = [System.Management.Automation.Language.TokenKind[]]@('Imatch', 'Cmatch', 'Inotmatch', 'Cnotmatch', 'Ireplace', 'Creplace', 'Isplit', 'Csplit')
        $found = [System.Collections.Generic.List[System.Management.Automation.Language.IScriptExtent]]::new()
        foreach ($node in $source.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.BinaryExpressionAst] -or $n -is [System.Management.Automation.Language.UnaryExpressionAst] }, $true)) {
            $kind = if ($node -is [System.Management.Automation.Language.BinaryExpressionAst]) { $node.Operator } else { $node.TokenKind }
            if ($kind -in $kinds) { $found.Add($node.Extent) }
        }
        foreach ($node in $source.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TypeExpressionAst] -or $n -is [System.Management.Automation.Language.TypeConstraintAst] }, $true)) {
            if ($node.TypeName.GetReflectionType() -eq [regex]) { $found.Add($node.Extent) }
        }
        return $found
    }
}

# ============================================================================
# DERIVED CHECKS
# Every throw in a script, read from SMA's AST: the condition guarding it, the relation that condition tests, and
# where each compared value comes from, established by following the value back through its assignments. A value
# whose origin SMA cannot establish is Unresolved, at its location.
# ============================================================================

enum PscGuard {
    Unguarded
    Then
    Else
}

enum PscPredicateKind {
    Comparison
    Negation
    Conjunction
    Disjunction
    Truth
}

enum PscOperandOrigin {
    Literal
    ReflectedInvocation
    PscInvocation
    MethodCall
    StaticMember
    Computed
    ProcessExitCode
    Command
    DynamicCommand
    Variable
    Unresolved
}

class PscOperand {
    [PscOperandOrigin] $Origin
    hidden [System.Management.Automation.Language.Ast] $Ast
    hidden [System.Management.Automation.Language.Ast] $Source
    [string] ToString() { return $this.Origin.ToString() + ': ' + $this.Ast.Extent.Text.ReplaceLineEndings(' ') }
}

# A condition as SMA parsed it: a tree whose inner nodes are -not, -and and -or (operands in evaluation order, so
# short-circuiting is preserved) and whose leaves are comparisons or the truth of a single value.
class PscPredicate {
    [PscPredicateKind] $Kind
    [System.Management.Automation.Language.TokenKind] $Operator
    [PscOperand] $Left
    [PscOperand] $Right
    [PscPredicate[]] $Operands
    hidden [System.Management.Automation.Language.Ast] $Ast
    [string] ToString() { return $this.Ast.Extent.Text.ReplaceLineEndings(' ') }

    # The leaves in evaluation order.
    [PscPredicate[]] Leaves() {
        $found = [System.Collections.Generic.List[PscPredicate]]::new()
        if ($this.Kind -eq [PscPredicateKind]::Comparison -or $this.Kind -eq [PscPredicateKind]::Truth) { $found.Add($this) }
        else { foreach ($operand in $this.Operands) { $found.AddRange($operand.Leaves()) } }
        return $found.ToArray()
    }
}

class PscDerivedCheck {
    [string] $Path
    [int] $Line
    [PscGuard] $Guard
    [PscPredicate] $Predicate
    hidden [System.Management.Automation.Language.ThrowStatementAst] $Throw
}

# The expression a pipeline, parenthesis, command expression or conversion wraps, when it wraps exactly one.
function Get-PscInnerExpression {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.Ast])]
    param([Parameter(Mandatory)][System.Management.Automation.Language.Ast] $Ast)
    $node = $Ast
    while ($true) {
        if ($node -is [System.Management.Automation.Language.ParenExpressionAst]) { $node = $node.Pipeline; continue }
        if ($node -is [System.Management.Automation.Language.ArrayExpressionAst] -and $node.SubExpression.Statements.Count -eq 1) { $node = $node.SubExpression.Statements[0]; continue }
        # A pipeline's value is what its last element produces.
        if ($node -is [System.Management.Automation.Language.PipelineAst]) { $node = $node.PipelineElements[$node.PipelineElements.Count - 1]; continue }
        if ($node -is [System.Management.Automation.Language.CommandExpressionAst]) { $node = $node.Expression; continue }
        if ($node -is [System.Management.Automation.Language.ConvertExpressionAst]) { $node = $node.Child; continue }
        return $node
    }
}

# The last assignment to a variable before an offset, within a scope's AST.
function Find-PscAssignment {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.AssignmentStatementAst])]
    param(
        [Parameter(Mandatory)][System.Management.Automation.Language.Ast] $Scope,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][int] $Before
    )
    $last = $null
    foreach ($assignment in $Scope.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        if ($assignment.Extent.EndOffset -gt $Before) { continue }
        $left = Get-PscInnerExpression $assignment.Left
        if ($left -isnot [System.Management.Automation.Language.VariableExpressionAst] -or -not $left.VariablePath.UserPath.Equals($Name, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($null -eq $last -or $assignment.Extent.StartOffset -gt $last.Extent.StartOffset) { $last = $assignment }
    }
    $last
}

function Get-PscOperand {
    [CmdletBinding()]
    [OutputType([PscOperand])]
    param(
        [Parameter(Mandatory)][System.Management.Automation.Language.Ast] $Ast,
        [Parameter(Mandatory)][System.Management.Automation.Language.Ast] $Scope,
        [int] $Depth = 0
    )
    $operand = [PscOperand]::new()
    $operand.Ast = $Ast
    $operand.Source = $Ast
    $operand.Origin = [PscOperandOrigin]::Unresolved
    $node = Get-PscInnerExpression $Ast
    if ($Depth -gt 16) { return $operand }
    if ($node -is [System.Management.Automation.Language.ConstantExpressionAst] -or $node -is [System.Management.Automation.Language.TypeExpressionAst]) { $operand.Origin = [PscOperandOrigin]::Literal; return $operand }
    if ($node -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
        $isReflectedInvoke = $node.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $node.Member.Value -eq 'Invoke'
        $operand.Origin = if ($isReflectedInvoke) { [PscOperandOrigin]::ReflectedInvocation } else { [PscOperandOrigin]::MethodCall }
        return $operand
    }
    if ($node -is [System.Management.Automation.Language.MemberExpressionAst] -and $node.Static) { $operand.Origin = [PscOperandOrigin]::StaticMember; return $operand }
    if ($node -is [System.Management.Automation.Language.IndexExpressionAst]) {
        $inner = Get-PscOperand -Ast $node.Target -Scope $Scope -Depth ($Depth + 1)
        $operand.Origin = $inner.Origin; $operand.Source = $inner.Source; return $operand
    }
    if ($node -is [System.Management.Automation.Language.BinaryExpressionAst] -or $node -is [System.Management.Automation.Language.UnaryExpressionAst]) { $operand.Origin = [PscOperandOrigin]::Computed; return $operand }
    if ($node -is [System.Management.Automation.Language.MemberExpressionAst]) {
        $inner = Get-PscOperand -Ast $node.Expression -Scope $Scope -Depth ($Depth + 1)
        $operand.Origin = $inner.Origin; $operand.Source = $inner.Source; return $operand
    }
    if ($node -is [System.Management.Automation.Language.VariableExpressionAst]) {
        if ($node.VariablePath.UserPath.Equals('LASTEXITCODE', [StringComparison]::OrdinalIgnoreCase)) { $operand.Origin = [PscOperandOrigin]::ProcessExitCode; return $operand }
        $assignment = Find-PscAssignment -Scope $Scope -Name $node.VariablePath.UserPath -Before $node.Extent.StartOffset
        if ($null -eq $assignment) { $operand.Origin = [PscOperandOrigin]::Variable; return $operand }
        $inner = Get-PscOperand -Ast $assignment.Right -Scope $Scope -Depth ($Depth + 1)
        $operand.Origin = $inner.Origin; $operand.Source = $assignment; return $operand
    }
    if ($node -is [System.Management.Automation.Language.CommandAst]) {
        $first = $node.CommandElements[0]
        if ($first -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $operand.Origin = [PscOperandOrigin]::Command; return $operand }
        if ($first -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $assignment = Find-PscAssignment -Scope $Scope -Name $first.VariablePath.UserPath -Before $node.Extent.StartOffset
            if ($null -ne $assignment) {
                $target = Get-PscInnerExpression $assignment.Right
                if ($target -is [System.Management.Automation.Language.CommandAst]) {
                    $last = $target.CommandElements[$target.CommandElements.Count - 1]
                    if ($last -is [System.Management.Automation.Language.StringConstantExpressionAst] -and [IO.Path]::GetFileName($last.Value).Equals([IO.Path]::GetFileName($PSCommandPath), [StringComparison]::OrdinalIgnoreCase)) {
                        $operand.Origin = [PscOperandOrigin]::PscInvocation; $operand.Source = $assignment; return $operand
                    }
                }
            }
        }
        # Any other command whose name is a value computed at run time.
        $operand.Origin = [PscOperandOrigin]::DynamicCommand
        return $operand
    }
    $operand
}

function Get-PscPredicate {
    [CmdletBinding()]
    [OutputType([PscPredicate])]
    param(
        [Parameter(Mandatory)][System.Management.Automation.Language.Ast] $Ast,
        [Parameter(Mandatory)][System.Management.Automation.Language.Ast] $Scope
    )
    $node = Get-PscInnerExpression $Ast
    $predicate = [PscPredicate]::new()
    $predicate.Ast = $node
    if ($node -is [System.Management.Automation.Language.BinaryExpressionAst] -and $node.Operator -in [System.Management.Automation.Language.TokenKind]::And, [System.Management.Automation.Language.TokenKind]::Or) {
        $predicate.Kind = if ($node.Operator -eq [System.Management.Automation.Language.TokenKind]::And) { [PscPredicateKind]::Conjunction } else { [PscPredicateKind]::Disjunction }
        $predicate.Operator = $node.Operator
        $predicate.Operands = [PscPredicate[]]@((Get-PscPredicate -Ast $node.Left -Scope $Scope), (Get-PscPredicate -Ast $node.Right -Scope $Scope))
        return $predicate
    }
    if ($node -is [System.Management.Automation.Language.UnaryExpressionAst] -and $node.TokenKind -in [System.Management.Automation.Language.TokenKind]::Not, [System.Management.Automation.Language.TokenKind]::Exclaim) {
        $predicate.Kind = [PscPredicateKind]::Negation
        $predicate.Operator = $node.TokenKind
        $predicate.Operands = [PscPredicate[]]@(Get-PscPredicate -Ast $node.Child -Scope $Scope)
        return $predicate
    }
    if ($node -is [System.Management.Automation.Language.BinaryExpressionAst]) {
        $predicate.Kind = [PscPredicateKind]::Comparison
        $predicate.Operator = $node.Operator
        $predicate.Left = Get-PscOperand -Ast $node.Left -Scope $Scope
        $predicate.Right = Get-PscOperand -Ast $node.Right -Scope $Scope
        return $predicate
    }
    $predicate.Kind = [PscPredicateKind]::Truth
    $predicate.Left = Get-PscOperand -Ast $node -Scope $Scope
    $predicate
}

function Get-PscDerivedCheck {
    [CmdletBinding()]
    [OutputType([PscDerivedCheck])]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][System.Management.Automation.Language.ScriptBlockAst] $Ast
    )
    $ast = $Ast
    foreach ($throw in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ThrowStatementAst] }, $true)) {
        $check = [PscDerivedCheck]::new()
        $check.Path = $Path
        $check.Line = $throw.Extent.StartLineNumber
        $check.Throw = $throw
        $check.Guard = [PscGuard]::Unguarded
        $scope = $throw.Parent
        while ($scope -isnot [System.Management.Automation.Language.ScriptBlockAst]) { $scope = $scope.Parent }
        $parent = $throw.Parent
        while ($null -ne $parent -and $parent -ne $scope) {
            if ($parent -is [System.Management.Automation.Language.IfStatementAst]) {
                $condition = $null
                foreach ($clause in $parent.Clauses) {
                    if ($throw.Extent.StartOffset -ge $clause.Item2.Extent.StartOffset -and $throw.Extent.EndOffset -le $clause.Item2.Extent.EndOffset) { $condition = $clause.Item1 }
                }
                if ($null -ne $condition) { $check.Guard = [PscGuard]::Then }
                else { $check.Guard = [PscGuard]::Else; $condition = $parent.Clauses[$parent.Clauses.Count - 1].Item1 }
                $check.Predicate = Get-PscPredicate -Ast $condition -Scope $scope
                break
            }
            $parent = $parent.Parent
        }
        $check
    }
}

# The file a path expression names, folded from SMA's AST: text constants, $PSScriptRoot, variables followed to their
# assignments, Join-Path with two positional values, and Split-Path -Parent. $null when the expression does not fold.
function Resolve-PscPathExpression {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][System.Management.Automation.Language.Ast] $Ast,
        [Parameter(Mandatory)][System.Management.Automation.Language.Ast] $Scope,
        [Parameter(Mandatory)][string] $Directory,
        [int] $Depth = 0
    )
    if ($Depth -gt 16) { return $null }
    $node = Get-PscInnerExpression $Ast
    if ($node -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return $node.Value }
    if ($node -is [System.Management.Automation.Language.VariableExpressionAst]) {
        if ($node.VariablePath.UserPath.Equals('PSScriptRoot', [StringComparison]::OrdinalIgnoreCase)) { return $Directory }
        $assignment = Find-PscAssignment -Scope $Scope -Name $node.VariablePath.UserPath -Before $node.Extent.StartOffset
        if ($null -eq $assignment) { return $null }
        return Resolve-PscPathExpression -Ast $assignment.Right -Scope $Scope -Directory $Directory -Depth ($Depth + 1)
    }
    if ($node -isnot [System.Management.Automation.Language.CommandAst]) { return $null }
    $binding = [System.Management.Automation.Language.StaticParameterBinder]::BindCommand($node, $true)
    $command = $node.GetCommandName()
    if ($command -eq 'Join-Path' -and $binding.BoundParameters.ContainsKey('Path') -and $binding.BoundParameters.ContainsKey('ChildPath')) {
        $parent = Resolve-PscPathExpression -Ast $binding.BoundParameters['Path'].Value -Scope $Scope -Directory $Directory -Depth ($Depth + 1)
        $child = Resolve-PscPathExpression -Ast $binding.BoundParameters['ChildPath'].Value -Scope $Scope -Directory $Directory -Depth ($Depth + 1)
        if ($null -eq $parent -or $null -eq $child) { return $null }
        return [IO.Path]::GetFullPath([IO.Path]::Combine($parent, $child))
    }
    if ($command -eq 'Split-Path' -and $binding.BoundParameters.ContainsKey('Parent') -and $binding.BoundParameters.ContainsKey('Path')) {
        $inner = Resolve-PscPathExpression -Ast $binding.BoundParameters['Path'].Value -Scope $Scope -Directory $Directory -Depth ($Depth + 1)
        if ($null -eq $inner) { return $null }
        return [IO.Path]::GetDirectoryName($inner)
    }
    $null
}

# ============================================================================
# INVESTIGATION
# A target is examined by every instrument that applies to it. Each instrument is a class deriving from
# PscInstrument, found by type, and may require other instruments' results on the same target. An instrument that
# throws is recorded as an observation (its ErrorRecord) and blocks only the instruments that require it; everything
# else still runs. Instruments add observations as they make them, so a later failure cannot erase earlier evidence.
# References an instrument finds become new targets. Each target is examined once.
# ============================================================================

# An instrument that could not run because an instrument it requires failed on the same target.
class PscBlocked {
    [type] $Instrument
    [type] $Requires
}

class PscObservation {
    [string] $Target
    [type] $Instrument
    [object] $Value
}

class PscInvestigation {
    [System.Collections.Generic.List[string]] $Targets = [System.Collections.Generic.List[string]]::new()
    [System.Collections.Generic.List[PscObservation]] $Observations = [System.Collections.Generic.List[PscObservation]]::new()
    hidden [System.Collections.Generic.Queue[string]] $Pending = [System.Collections.Generic.Queue[string]]::new()
    hidden [System.Collections.Generic.HashSet[string]] $Seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    [void] AddTarget([string] $path) {
        $full = [IO.Path]::GetFullPath($path)
        if ($this.Seen.Add($full)) { $this.Pending.Enqueue($full); $this.Targets.Add($full) }
    }

    [void] Observe([string] $target, [type] $instrument, [object] $value) {
        $observation = [PscObservation]::new()
        $observation.Target = $target
        $observation.Instrument = $instrument
        $observation.Value = $value
        $this.Observations.Add($observation)
    }

    # The values an instrument observed on a target.
    [object[]] Find([string] $target, [type] $instrument) {
        $found = [System.Collections.Generic.List[object]]::new()
        foreach ($observation in $this.Observations) {
            if ($observation.Instrument -eq $instrument -and $observation.Target.Equals($target, [StringComparison]::OrdinalIgnoreCase)) { $found.Add($observation.Value) }
        }
        return $found.ToArray()
    }
}

class PscInstrument {
    # The instruments whose results this one needs on the same target.
    [type[]] Requires() { return [type[]]@() }
    [bool] AppliesTo([string] $target) { throw [System.NotImplementedException]::new($this.GetType().Name) }
    [void] Examine([PscInvestigation] $investigation, [string] $target) { throw [System.NotImplementedException]::new($this.GetType().Name) }

    static [PscInstrument[]] All() {
        $instruments = [System.Collections.Generic.List[PscInstrument]]::new()
        foreach ($type in [PscInstrument].Assembly.GetTypes()) {
            if ($type.IsSubclassOf([PscInstrument])) { $instruments.Add([PscInstrument][Activator]::CreateInstance($type)) }
        }
        return $instruments.ToArray()
    }

    static [PscSource] Source([PscInvestigation] $investigation, [string] $target) {
        return [PscSource]@($investigation.Find($target, [ParseInstrument]))[0]
    }
}

# SMA's parse of a PowerShell file: the PscSource, then each parse error as its own observation.
class ParseInstrument : PscInstrument {
    [bool] AppliesTo([string] $target) { return [IO.Path]::GetExtension($target) -in '.ps1', '.psm1' }
    [void] Examine([PscInvestigation] $investigation, [string] $target) {
        $source = [PscSource]::new($target)
        $investigation.Observe($target, [ParseInstrument], $source)
        foreach ($parseError in $source.ParseErrors) { $investigation.Observe($target, [ParseErrorInstrument], $parseError) }
    }
}

# Holds the parse errors ParseInstrument observes; it examines nothing itself.
class ParseErrorInstrument : PscInstrument {
    [bool] AppliesTo([string] $target) { return $false }
}

class MeasureInstrument : PscInstrument {
    [type[]] Requires() { return [type[]]@([ParseInstrument]) }
    [bool] AppliesTo([string] $target) { return [IO.Path]::GetExtension($target) -in '.ps1', '.psm1' }
    [void] Examine([PscInvestigation] $investigation, [string] $target) {
        foreach ($measure in [PscInstrument]::Source($investigation, $target).Measures) { $investigation.Observe($target, [MeasureInstrument], $measure) }
    }
}

class DerivedCheckInstrument : PscInstrument {
    [type[]] Requires() { return [type[]]@([ParseInstrument]) }
    [bool] AppliesTo([string] $target) { return [IO.Path]::GetExtension($target) -in '.ps1', '.psm1' }
    [void] Examine([PscInvestigation] $investigation, [string] $target) {
        foreach ($check in Get-PscDerivedCheck -Path $target -Ast ([PscInstrument]::Source($investigation, $target).Ast)) { $investigation.Observe($target, [DerivedCheckInstrument], $check) }
    }
}

# Files a source names through path expressions that fold (dot-sourced scripts, Join-Path from $PSScriptRoot): each
# existing file is observed and becomes a target.
class ReferenceInstrument : PscInstrument {
    [type[]] Requires() { return [type[]]@([ParseInstrument]) }
    [bool] AppliesTo([string] $target) { return [IO.Path]::GetExtension($target) -in '.ps1', '.psm1' }
    [void] Examine([PscInvestigation] $investigation, [string] $target) {
        $ast = [PscInstrument]::Source($investigation, $target).Ast
        $directory = [IO.Path]::GetDirectoryName($target)
        $named = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($command in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $candidates = if ($command.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot) { @($command.CommandElements[0]) } elseif ($command.GetCommandName() -eq 'Join-Path') { @($command) } else { @() }
            foreach ($candidate in $candidates) {
                $scope = $candidate.Parent
                while ($scope -isnot [System.Management.Automation.Language.ScriptBlockAst]) { $scope = $scope.Parent }
                $path = Resolve-PscPathExpression -Ast $candidate -Scope $scope -Directory $directory
                if ($null -ne $path -and [IO.File]::Exists($path) -and $named.Add($path)) {
                    $investigation.Observe($target, [ReferenceInstrument], [IO.FileInfo]::new($path))
                    $investigation.AddTarget($path)
                }
            }
        }
    }
}

function Invoke-PscInvestigation {
    [CmdletBinding()]
    [OutputType([PscInvestigation])]
    param([Parameter(Mandatory)][string[]] $Path)
    $investigation = [PscInvestigation]::new()
    foreach ($item in $Path) {
        if ([IO.Directory]::Exists($item)) { foreach ($file in Get-ChildItem -LiteralPath $item -Recurse -File -Include *.ps1, *.psm1) { $investigation.AddTarget($file.FullName) } }
        else { $investigation.AddTarget($item) }
    }
    $instruments = [PscInstrument]::All()
    while ($investigation.Pending.Count) {
        $target = $investigation.Pending.Dequeue()
        $outcome = [System.Collections.Generic.Dictionary[type, bool]]::new()
        $remaining = [System.Collections.Generic.List[PscInstrument]]::new()
        foreach ($instrument in $instruments) { if ($instrument.AppliesTo($target)) { $remaining.Add($instrument) } }
        $progress = $true
        while ($remaining.Count -and $progress) {
            $progress = $false
            foreach ($instrument in $remaining.ToArray()) {
                $requirements = $instrument.Requires()
                $failed = @($requirements | Where-Object { $outcome.ContainsKey($_) -and -not $outcome[$_] })
                if ($failed.Count) {
                    $blocked = [PscBlocked]::new(); $blocked.Instrument = $instrument.GetType(); $blocked.Requires = $failed[0]
                    $investigation.Observe($target, [PscBlocked], $blocked)
                    $outcome[$instrument.GetType()] = $false; $null = $remaining.Remove($instrument); $progress = $true
                    continue
                }
                if (@($requirements | Where-Object { -not $outcome.ContainsKey($_) }).Count) { continue }
                try { $instrument.Examine($investigation, $target); $outcome[$instrument.GetType()] = $true }
                catch { $investigation.Observe($target, $instrument.GetType(), $_); $outcome[$instrument.GetType()] = $false }
                $null = $remaining.Remove($instrument); $progress = $true
            }
        }
        foreach ($instrument in $remaining) {
            $blocked = [PscBlocked]::new(); $blocked.Instrument = $instrument.GetType()
            $investigation.Observe($target, [PscBlocked], $blocked)
        }
    }
    $investigation
}

# ============================================================================
# DIFFERENTIAL COMPARISON
# Primitives: lower a source's classes; define the same classes interpreted by SMA; derive argument values from
# parameter types; invoke a method into an outcome; compare two outcomes. The Lower, Interpret and Compare instruments
# compose them over any target that declares classes. SMA running the source is the reference implementation.
# ============================================================================

class PscOutcome {
    [object] $Value
    [System.Exception] $Exception
    [double] $Milliseconds
    [bool] $Finished = $true
    [string] ToString() {
        if (-not $this.Finished) { return 'unfinished' }
        if ($null -ne $this.Exception) { return $this.Exception.GetType().Name + ': ' + $this.Exception.Message }
        if ($null -eq $this.Value) { return '$null' }
        if ($this.Value -is [Array]) { return '@(' + [string]::Join(', ', [string[]]@(foreach ($item in $this.Value) { [string]$item })) + ')' }
        return $this.Value.ToString()
    }
}

enum PscRelation {
    Equal
    Different
    BothThrew
    OnlyLoweredThrew
    OnlyInterpretedThrew
    NotCompared
}

class PscComparison {
    [string] $Class
    [string] $Method
    [object[]] $Arguments
    [PscOutcome] $Lowered
    [PscOutcome] $Interpreted
    [PscRelation] $Relation
}

# A method Compare did not execute, and the node in its body (or its class's constructors and initializers) that
# could act outside the computation: a command, or a call PSC cannot establish as free of effects.
class PscNotExecuted {
    [string] $Class
    [string] $Method
    [System.Management.Automation.Language.IScriptExtent] $Cause
}

# The first node in a body that could act outside its own computation, or $null. Allowed: operators, conversions,
# member and element access, calls to the same class (checked in turn), and static calls on System types that only
# compute: Math, MathF, Convert, BitConverter, Array, Buffer, String, Char, the numeric primitives.
function Find-PscEffect {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.Ast])]
    param(
        [Parameter(Mandatory)][System.Management.Automation.Language.Ast] $Body,
        [Parameter(Mandatory)][System.Management.Automation.Language.TypeDefinitionAst] $Class,
        [System.Collections.Generic.HashSet[System.Management.Automation.Language.Ast]] $Visited = [System.Collections.Generic.HashSet[System.Management.Automation.Language.Ast]]::new()
    )
    if (-not $Visited.Add($Body)) { return $null }
    $computing = [type[]]@([Math], [MathF], [Convert], [BitConverter], [Array], [Buffer], [string], [char], [int], [long], [short], [sbyte], [byte], [uint16], [uint32], [uint64], [double], [float], [decimal], [bool])
    foreach ($node in $Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -or $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
        if ($node -is [System.Management.Automation.Language.CommandAst]) { return $node }
        $target = Get-PscInnerExpression $node.Expression
        if ($node.Static) {
            if ($target -is [System.Management.Automation.Language.TypeExpressionAst] -and $target.TypeName.GetReflectionType() -in $computing) { continue }
            if ($target -is [System.Management.Automation.Language.TypeExpressionAst] -and $target.TypeName.Name -eq $Class.Name -and $node.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                foreach ($member in $Class.Members) {
                    if ($member -is [System.Management.Automation.Language.FunctionMemberAst] -and $member.Name -eq $node.Member.Value) {
                        $inner = Find-PscEffect -Body $member.Body -Class $Class -Visited $Visited
                        if ($null -ne $inner) { return $inner }
                    }
                }
                continue
            }
            return $node
        }
        if ($target -is [System.Management.Automation.Language.VariableExpressionAst] -and $target.VariablePath.UserPath -eq 'this' -and $node.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            foreach ($member in $Class.Members) {
                if ($member -is [System.Management.Automation.Language.FunctionMemberAst] -and $member.Name -eq $node.Member.Value) {
                    $inner = Find-PscEffect -Body $member.Body -Class $Class -Visited $Visited
                    if ($null -ne $inner) { return $inner }
                }
            }
            continue
        }
        return $node
    }
    $null
}

# Boundary values of a type: its extremes, zero and its neighbours, and for floating point NaN, infinities and -0.
function Get-PscTypeValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][type] $Type)
    if ($Type.IsArray) {
        $element = $Type.GetElementType()
        $values = @(Get-PscTypeValue -Type $element | Select-Object -First 3)
        $empty = [Array]::CreateInstance($element, 0)
        $all = [Array]::CreateInstance($element, $values.Count)
        for ($i = 0; $i -lt $values.Count; $i++) { $all.SetValue($values[$i], $i) }
        , $empty
        , $all
        return
    }
    if ($Type.IsEnum) { foreach ($value in [Enum]::GetValues($Type)) { $value }; return }
    if ($Type -eq [int]) { [int]::MinValue, [int]-1, [int]0, [int]1, [int]2, [int]7, [int]70000, [int]::MaxValue; return }
    if ($Type -eq [long]) { [long]::MinValue, [long]-1, [long]0, [long]1, [long]7, [long]::MaxValue; return }
    if ($Type -eq [short]) { [short]::MinValue, [short]-1, [short]0, [short]1, [short]::MaxValue; return }
    if ($Type -eq [sbyte]) { [sbyte]::MinValue, [sbyte]-1, [sbyte]0, [sbyte]1, [sbyte]::MaxValue; return }
    if ($Type -eq [byte]) { [byte]0, [byte]1, [byte]7, [byte]::MaxValue; return }
    if ($Type -eq [uint16]) { [uint16]0, [uint16]1, [uint16]::MaxValue; return }
    if ($Type -eq [uint32]) { [uint32]0, [uint32]1, [uint32]::MaxValue; return }
    if ($Type -eq [uint64]) { [uint64]0, [uint64]1, [uint64]::MaxValue; return }
    if ($Type -eq [double]) { 0.0, -0.0, 1.0, -1.0, 0.5, 2.5, [double]::NaN, [double]::PositiveInfinity, [double]::NegativeInfinity, [double]::MaxValue, [double]::Epsilon; return }
    if ($Type -eq [float]) { [float]0, [float]-0.0, [float]1, [float]-1, [float]0.5, [float]2.5, [float]::NaN, [float]::PositiveInfinity, [float]::NegativeInfinity, [float]::MaxValue; return }
    if ($Type -eq [decimal]) { [decimal]0, [decimal]1, [decimal]-1, [decimal]0.5; return }
    if ($Type -eq [bool]) { $true, $false; return }
    if ($Type -eq [char]) { [char]'a', [char]'A', [char]'0', [char]0; return }
    if ($Type -eq [string]) { '', 'a', 'A', 'PowerShell', 'ß', ' '; return }
}

# Every combination of each parameter type's values, in order, up to a limit. Nothing when a type has no values.
function Get-PscArgumentSet {
    [CmdletBinding()]
    param([type[]] $Types, [int] $Limit = 64)
    $lists = [System.Collections.Generic.List[object[]]]::new()
    foreach ($type in @($Types)) {
        $values = [System.Collections.Generic.List[object]]::new()
        foreach ($value in Get-PscTypeValue -Type $type) { $values.Add($value) }
        if ($values.Count -eq 0) { return }
        $lists.Add($values.ToArray())
    }
    $indexes = [int[]]::new($lists.Count)
    $produced = 0
    while ($produced -lt $Limit) {
        $arguments = [object[]]::new($lists.Count)
        for ($i = 0; $i -lt $lists.Count; $i++) { $arguments[$i] = $lists[$i][$indexes[$i]] }
        , $arguments
        $produced++
        $position = $lists.Count - 1
        while ($position -ge 0) {
            $indexes[$position]++
            if ($indexes[$position] -lt $lists[$position].Length) { break }
            $indexes[$position] = 0
            $position--
        }
        if ($position -lt 0) { return }
    }
}

# Invokes a method into an outcome: its value, or the exception it threw unwrapped from the reflection layers. Array
# arguments are copied so a method that mutates them cannot change another invocation's input. With a time limit the
# call runs as a compiled delegate on a pool thread; an unfinished call is recorded as unfinished.
function Invoke-PscMethod {
    [CmdletBinding()]
    [OutputType([PscOutcome])]
    param(
        [Parameter(Mandatory)][System.Reflection.MethodInfo] $Method,
        [object] $Instance,
        [object[]] $Arguments,
        [int] $TimeLimitMilliseconds = 0
    )
    $copies = [object[]]::new(@($Arguments).Count)
    for ($i = 0; $i -lt $copies.Length; $i++) { $copies[$i] = if ($Arguments[$i] -is [Array]) { $Arguments[$i].Clone() } else { $Arguments[$i] } }
    $outcome = [PscOutcome]::new()
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        if ($TimeLimitMilliseconds -gt 0) {
            $call = [System.Linq.Expressions.Expression]::Call(
                [System.Linq.Expressions.Expression]::Constant($Method, [System.Reflection.MethodBase]),
                [System.Reflection.MethodBase].GetMethod('Invoke', [type[]]@([object], [object[]])),
                [System.Linq.Expressions.Expression]::Constant($Instance, [object]),
                [System.Linq.Expressions.Expression]::Constant($copies, [object[]]))
            $task = [System.Threading.Tasks.Task[object]]::Run([System.Linq.Expressions.Expression]::Lambda([Func[object]], $call).Compile())
            if (-not $task.Wait($TimeLimitMilliseconds)) { $outcome.Finished = $false }
            else { $outcome.Value = $task.Result }
        }
        else { $outcome.Value = $Method.Invoke($Instance, $copies) }
    }
    catch {
        $exception = $_.Exception
        while (($exception -is [System.Management.Automation.MethodInvocationException] -or $exception -is [System.Reflection.TargetInvocationException] -or $exception -is [System.AggregateException]) -and $null -ne $exception.InnerException) { $exception = $exception.InnerException }
        $outcome.Exception = $exception
    }
    $outcome.Milliseconds = $clock.Elapsed.TotalMilliseconds
    $outcome
}

# Whether two values are the same: arrays element by element, floating point by bits (NaN equals NaN; -0 differs from 0),
# instances of the lowered and interpreted forms of one class by their public instance fields and properties.
function Test-PscSameValue {
    [CmdletBinding()]
    [OutputType([bool])]
    param([object] $First, [object] $Second)
    if ($null -eq $First -or $null -eq $Second) { return ($null -eq $First -and $null -eq $Second) }
    if ($First -is [Array] -and $Second -is [Array]) {
        if ($First.Length -ne $Second.Length) { return $false }
        for ($i = 0; $i -lt $First.Length; $i++) { if (-not (Test-PscSameValue $First[$i] $Second[$i])) { return $false } }
        return $true
    }
    if ($First -is [double] -and $Second -is [double]) { return [BitConverter]::DoubleToInt64Bits($First) -eq [BitConverter]::DoubleToInt64Bits($Second) }
    if ($First -is [float] -and $Second -is [float]) { return [BitConverter]::SingleToInt32Bits($First) -eq [BitConverter]::SingleToInt32Bits($Second) }
    if ($First.GetType().IsPrimitive -or $First -is [string] -or $First -is [decimal] -or $First.GetType().IsEnum) {
        return $First.GetType() -eq $Second.GetType() -and $First.Equals($Second)
    }
    $firstMembers = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($field in $First.GetType().GetFields([System.Reflection.BindingFlags]'Public,Instance')) { $firstMembers[$field.Name] = $field.GetValue($First) }
    foreach ($property in $First.GetType().GetProperties([System.Reflection.BindingFlags]'Public,Instance')) { if ($property.GetIndexParameters().Length -eq 0) { $firstMembers[$property.Name] = $property.GetValue($First) } }
    $secondMembers = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($field in $Second.GetType().GetFields([System.Reflection.BindingFlags]'Public,Instance')) { $secondMembers[$field.Name] = $field.GetValue($Second) }
    foreach ($property in $Second.GetType().GetProperties([System.Reflection.BindingFlags]'Public,Instance')) { if ($property.GetIndexParameters().Length -eq 0) { $secondMembers[$property.Name] = $property.GetValue($Second) } }
    if ($firstMembers.Count -ne $secondMembers.Count) { return $false }
    foreach ($name in $firstMembers.Keys) {
        if (-not $secondMembers.ContainsKey($name) -or -not (Test-PscSameValue $firstMembers[$name] $secondMembers[$name])) { return $false }
    }
    $true
}

function Compare-PscOutcome {
    [CmdletBinding()]
    [OutputType([PscRelation])]
    param([Parameter(Mandatory)][PscOutcome] $Lowered, [Parameter(Mandatory)][PscOutcome] $Interpreted)
    $loweredThrew = $null -ne $Lowered.Exception
    $interpretedThrew = $null -ne $Interpreted.Exception
    if ($loweredThrew -and $interpretedThrew) { return [PscRelation]::BothThrew }
    if ($loweredThrew) { return [PscRelation]::OnlyLoweredThrew }
    if ($interpretedThrew) { return [PscRelation]::OnlyInterpretedThrew }
    if (Test-PscSameValue $Lowered.Value $Interpreted.Value) { return [PscRelation]::Equal }
    [PscRelation]::Different
}

# One evaluation of an operator in SMA, as written and with an operand binding's type written into each operand.
# Relation compares type and value; SameNumber says whether the two results are equal numbers whatever their types.
class PscBindingEvaluation {
    [System.Management.Automation.Language.TokenKind] $Operator
    [type] $Left
    [type] $Right
    [type] $Bound
    [object[]] $Arguments
    [PscOutcome] $Reference
    [PscOutcome] $Mutated
    [PscRelation] $Relation
    [bool] $SameNumber
}

# Checks an operand binding against SMA by mutating SMA's own AST: for each operator and pair of operand types, SMA
# evaluates [L]$a op [R]$b and [B]([L]$a) op [B]([R]$b), B being the type the binding chose, on each pair of
# boundary values. Every evaluation is returned; one whose Relation is not Equal is where the binding departs.
function Compare-PscOperandBinding {
    [CmdletBinding()]
    [OutputType([PscBindingEvaluation])]
    param(
        [Parameter(Mandatory)][PscOperandBinding] $Binding,
        [System.Management.Automation.Language.TokenKind[]] $Operator = @('Plus', 'Minus', 'Multiply', 'Divide', 'Rem', 'Band', 'Bor', 'Bxor', 'Ieq', 'Ilt'),
        [type[]] $Type = @([sbyte], [byte], [int16], [uint16], [int], [uint32], [long], [uint64], [single], [double], [decimal])
    )
    $position = [System.Management.Automation.Language.ScriptPosition]::new('Compare-PscOperandBinding', 1, 1, '')
    $extent = [System.Management.Automation.Language.ScriptExtent]::new($position, $position)
    $a = [System.Management.Automation.Language.VariableExpressionAst]::new($extent, 'a', $false)
    $b = [System.Management.Automation.Language.VariableExpressionAst]::new($extent, 'b', $false)
    $parameters = [System.Management.Automation.Language.ParameterAst[]]@(
        [System.Management.Automation.Language.ParameterAst]::new($extent, $a.Copy(), [System.Management.Automation.Language.AttributeBaseAst[]]@(), $null),
        [System.Management.Automation.Language.ParameterAst]::new($extent, $b.Copy(), [System.Management.Automation.Language.AttributeBaseAst[]]@(), $null))
    foreach ($token in $Operator) {
        $kind = if ($token -in 'Band', 'Bor', 'Bxor') { [PscOperatorKind]::Bitwise }
            elseif ($token -in 'Plus', 'Minus', 'Multiply', 'Divide', 'Rem') { [PscOperatorKind]::Arithmetic }
            else { [PscOperatorKind]::Comparison }
        foreach ($leftType in $Type) {
            foreach ($rightType in $Type) {
                $bound = $Binding.Bind($kind, [Linq.Expressions.Expression]::Parameter($leftType), [Linq.Expressions.Expression]::Parameter($rightType))
                if ($null -eq $bound) { continue }
                $left = [System.Management.Automation.Language.ConvertExpressionAst]::new($extent, [System.Management.Automation.Language.TypeConstraintAst]::new($extent, [System.Management.Automation.Language.ReflectionTypeName]::new($leftType)), $a.Copy())
                $right = [System.Management.Automation.Language.ConvertExpressionAst]::new($extent, [System.Management.Automation.Language.TypeConstraintAst]::new($extent, [System.Management.Automation.Language.ReflectionTypeName]::new($rightType)), $b.Copy())
                $boundLeft = [System.Management.Automation.Language.ConvertExpressionAst]::new($extent, [System.Management.Automation.Language.TypeConstraintAst]::new($extent, [System.Management.Automation.Language.ReflectionTypeName]::new($bound.Left.Type)), $left.Copy())
                $boundRight = [System.Management.Automation.Language.ConvertExpressionAst]::new($extent, [System.Management.Automation.Language.TypeConstraintAst]::new($extent, [System.Management.Automation.Language.ReflectionTypeName]::new($bound.Right.Type)), $right.Copy())
                $evaluators = foreach ($expression in [System.Management.Automation.Language.BinaryExpressionAst]::new($extent, $left, $token, $right, $extent),
                                                      [System.Management.Automation.Language.BinaryExpressionAst]::new($extent, $boundLeft, $token, $boundRight, $extent)) {
                    $statement = [System.Management.Automation.Language.PipelineAst]::new($extent, [System.Management.Automation.Language.CommandExpressionAst]::new($extent, $expression, $null))
                    $body = [System.Management.Automation.Language.StatementBlockAst]::new($extent, [System.Management.Automation.Language.StatementAst[]]@($statement), $null)
                    $paramBlock = [System.Management.Automation.Language.ParamBlockAst]::new($extent, [System.Management.Automation.Language.AttributeAst[]]@(), [System.Management.Automation.Language.ParameterAst[]]@($parameters | ForEach-Object { $_.Copy() }))
                    [System.Management.Automation.Language.ScriptBlockAst]::new($extent, $paramBlock, $body, $false).GetScriptBlock()
                }
                foreach ($arguments in Get-PscArgumentSet -Types $leftType, $rightType -Limit 1024) {
                    $outcomes = foreach ($evaluator in $evaluators) {
                        $outcome = [PscOutcome]::new()
                        try { $outcome.Value = $evaluator.InvokeReturnAsIs($arguments[0], $arguments[1]) }
                        catch { $outcome.Exception = $_.Exception.GetBaseException() }
                        $outcome
                    }
                    $sameNumber = $null -eq $outcomes[0].Exception -and $null -eq $outcomes[1].Exception -and
                        [System.Management.Automation.LanguagePrimitives]::Equals($outcomes[0].Value, $outcomes[1].Value) -and
                        [System.Management.Automation.LanguagePrimitives]::Equals($outcomes[1].Value, $outcomes[0].Value)
                    [PscBindingEvaluation]@{
                        Operator = $token; Left = $leftType; Right = $rightType; Bound = $bound.Left.Type; Arguments = $arguments
                        Reference = $outcomes[0]; Mutated = $outcomes[1]
                        Relation = Compare-PscOutcome -Lowered $outcomes[1] -Interpreted $outcomes[0]
                        SameNumber = $sameNumber
                    }
                }
            }
        }
    }
}

# The source's classes and enums defined by SMA, interpreted: a new script block holding copies of the source's type
# definitions only (no other statement runs), invoked, with each runtime type read from its definition.
function ConvertTo-PscInterpretedType {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Management.Automation.Language.ScriptBlockAst] $Ast)
    $definitions = [System.Collections.Generic.List[System.Management.Automation.Language.StatementAst]]::new()
    foreach ($definition in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TypeDefinitionAst] }, $false)) { $definitions.Add($definition.Copy()) }
    $usings = [System.Collections.Generic.List[System.Management.Automation.Language.UsingStatementAst]]::new()
    foreach ($using in $Ast.UsingStatements) { $usings.Add((Copy-UsingStatement $using)) }
    $block = [System.Management.Automation.Language.StatementBlockAst]::new($Ast.Extent, $definitions, [System.Management.Automation.Language.TrapStatementAst[]]@())
    $script = [System.Management.Automation.Language.ScriptBlockAst]::new($Ast.Extent, $usings, $null, $block, $false, $false)
    $null = & $script.GetScriptBlock()
    $typeProperty = [System.Management.Automation.Language.TypeDefinitionAst].GetProperty('Type', [System.Reflection.BindingFlags]'NonPublic,Instance')
    $types = [System.Collections.Generic.Dictionary[string, type]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($definition in $definitions) { $types[$definition.Name] = $typeProperty.GetValue($definition) }
    , $types
}

# A source's classes, lowered by PSC and loaded from the assembly's bytes. Lowering stops at a class's first refusal;
# the refusal is recorded, the class it occurs in is set aside, and the remaining classes are lowered again, until what
# remains lowers or nothing remains. Every class's first refusal is observed, and every class that lowers is lowered.
class LowerInstrument : PscInstrument {
    [type[]] Requires() { return [type[]]@([ParseInstrument]) }
    [bool] AppliesTo([string] $target) { return [IO.Path]::GetExtension($target) -in '.ps1', '.psm1' }
    [void] Examine([PscInvestigation] $investigation, [string] $target) {
        $source = [PscInstrument]::Source($investigation, $target)
        $classes = @($source.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TypeDefinitionAst] -and $n.IsClass }, $false) | Where-Object { -not (Test-AttributeClass $_) })
        if ($classes.Count -eq 0) { return }
        $directory = [IO.Path]::Combine([IO.Path]::GetDirectoryName($PSCommandPath), 'build', 'investigation', $source.Sha512.Substring(0, 16))
        $null = [IO.Directory]::CreateDirectory($directory)
        $output = [IO.Path]::Combine($directory, [IO.Path]::GetFileNameWithoutExtension($target) + '.dll')
        $candidates = [System.Collections.Generic.List[System.Management.Automation.Language.TypeDefinitionAst]]::new()
        foreach ($class in $classes) { $candidates.Add($class) }
        while ($candidates.Count) {
            try {
                $null = Export-LoweredAssembly -SourceAst $source.Ast -ClassName $candidates[0].Name -ClassNames ([string[]]@($candidates | ForEach-Object Name)) -OutputPath $output -Deterministic
                $investigation.Observe($target, [LowerInstrument], [System.Reflection.Assembly]::Load([IO.File]::ReadAllBytes($output)))
                return
            }
            catch {
                $investigation.Observe($target, [LowerInstrument], $_)
                # The refusal's source position exists only in its message text; see the typed-refusal measure.
                $position = [regex]::Match($_.Exception.Message, '^\[(\d+):(\d+)\]')
                if (-not $position.Success) { return }
                $line = [int]$position.Groups[1].Value
                $refused = @($candidates | Where-Object { $line -ge $_.Extent.StartLineNumber -and $line -le $_.Extent.EndLineNumber })
                if ($refused.Count -eq 0) { return }
                $null = $candidates.Remove($refused[0])
            }
        }
    }
}

# The same classes defined by SMA, interpreted: the reference implementation.
class InterpretInstrument : PscInstrument {
    [type[]] Requires() { return [type[]]@([LowerInstrument]) }
    [bool] AppliesTo([string] $target) { return [IO.Path]::GetExtension($target) -in '.ps1', '.psm1' }
    [void] Examine([PscInvestigation] $investigation, [string] $target) {
        if (@($investigation.Find($target, [LowerInstrument]) | Where-Object { $_ -is [System.Reflection.Assembly] }).Count -eq 0) { return }
        $source = [PscInstrument]::Source($investigation, $target)
        $investigation.Observe($target, [InterpretInstrument], (ConvertTo-PscInterpretedType -Ast $source.Ast))
    }
}

# Every method of every class, lowered and interpreted, on arguments derived from its parameter types. A lowered call
# that does not finish within the time limit, or takes long enough that the interpreted call would not, leaves the
# interpreted call unmade and the comparison NotCompared.
class CompareInstrument : PscInstrument {
    [type[]] Requires() { return [type[]]@([LowerInstrument], [InterpretInstrument]) }
    [bool] AppliesTo([string] $target) { return [IO.Path]::GetExtension($target) -in '.ps1', '.psm1' }
    [void] Examine([PscInvestigation] $investigation, [string] $target) {
        $assemblies = @($investigation.Find($target, [LowerInstrument]) | Where-Object { $_ -is [System.Reflection.Assembly] })
        $interpretedSets = @($investigation.Find($target, [InterpretInstrument]))
        if ($assemblies.Count -eq 0 -or $interpretedSets.Count -eq 0) { return }
        $assembly = [System.Reflection.Assembly]$assemblies[0]
        $interpreted = $interpretedSets[0]
        $source = [PscInstrument]::Source($investigation, $target)
        $flags = [System.Reflection.BindingFlags]'Public,Static,Instance,DeclaredOnly'
        foreach ($class in $source.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TypeDefinitionAst] -and $n.IsClass }, $false)) {
            $loweredType = $assembly.GetType($class.Name)
            if ($null -eq $loweredType -or -not $interpreted.ContainsKey($class.Name)) { continue }
            $interpretedType = $interpreted[$class.Name]
            foreach ($member in $class.Members) {
                if ($member -isnot [System.Management.Automation.Language.FunctionMemberAst] -or $member.IsConstructor) { continue }
                $loweredMethod = @($loweredType.GetMethods($flags) | Where-Object { $_.Name -eq $member.Name -and $_.GetParameters().Length -eq $member.Parameters.Count })[0]
                $interpretedMethod = @($interpretedType.GetMethods($flags) | Where-Object { $_.Name -eq $member.Name -and $_.GetParameters().Length -eq $member.Parameters.Count })[0]
                if ($null -eq $loweredMethod -or $null -eq $interpretedMethod) { continue }
                $cause = Find-PscEffect -Body $member.Body -Class $class
                if ($null -eq $cause -and -not $loweredMethod.IsStatic) {
                    foreach ($other in $class.Members) {
                        if ($null -ne $cause) { break }
                        if ($other -is [System.Management.Automation.Language.FunctionMemberAst] -and $other.IsConstructor) { $cause = Find-PscEffect -Body $other.Body -Class $class }
                        elseif ($other -is [System.Management.Automation.Language.PropertyMemberAst] -and -not $other.IsStatic -and $null -ne $other.InitialValue) { $cause = Find-PscEffect -Body $other.InitialValue -Class $class }
                    }
                }
                if ($null -ne $cause) {
                    $unexecuted = [PscNotExecuted]::new(); $unexecuted.Class = $class.Name; $unexecuted.Method = $member.Name; $unexecuted.Cause = $cause.Extent
                    $investigation.Observe($target, [CompareInstrument], $unexecuted)
                    continue
                }
                $loweredInstance = $null; $interpretedInstance = $null
                if (-not $loweredMethod.IsStatic) {
                    try { $loweredInstance = [Activator]::CreateInstance($loweredType); $interpretedInstance = [Activator]::CreateInstance($interpretedType) }
                    catch { $investigation.Observe($target, [CompareInstrument], $_); continue }
                }
                $parameterTypes = [type[]]@($loweredMethod.GetParameters() | ForEach-Object ParameterType)
                $sets = @(Get-PscArgumentSet -Types $parameterTypes)
                if ($parameterTypes.Length -eq 0) { $sets = @(, [object[]]@()) }
                foreach ($arguments in $sets) {
                    $comparison = [PscComparison]::new()
                    $comparison.Class = $class.Name
                    $comparison.Method = $member.Name
                    $comparison.Arguments = $arguments
                    $comparison.Lowered = Invoke-PscMethod -Method $loweredMethod -Instance $loweredInstance -Arguments $arguments -TimeLimitMilliseconds 2000
                    if (-not $comparison.Lowered.Finished -or $comparison.Lowered.Milliseconds -gt 50) { $comparison.Relation = [PscRelation]::NotCompared }
                    else {
                        $comparison.Interpreted = Invoke-PscMethod -Method $interpretedMethod -Instance $interpretedInstance -Arguments $arguments
                        $comparison.Relation = Compare-PscOutcome -Lowered $comparison.Lowered -Interpreted $comparison.Interpreted
                    }
                    $investigation.Observe($target, [CompareInstrument], $comparison)
                }
            }
        }
    }
}

}

process {
    if ($Help) {
        Get-Help -Name $PSCommandPath -Full
        return
    }
    # With no arguments, the script describes itself instead of compiling nothing.
    if ($PSBoundParameters.Count -eq 0) { return Get-PscApi }
    switch ($Mode) {
        'Api' { Get-PscApi }
        'PowerShell' { Get-PinnedPowerShell -ArchivePath $ArchivePath }
        'Compile' {
            $compileParameters = @{}
            foreach ($name in 'SourcePath', 'SourceAst', 'StaticData', 'ClassName', 'ClassNames', 'MethodNames', 'OutputPath', 'EntryPoint', 'Deterministic') {
                if ($PSBoundParameters.ContainsKey($name)) { $compileParameters[$name] = $PSBoundParameters[$name] }
            }
            if (-not $Native) { return Export-LoweredAssembly @compileParameters }
            if (-not $EntryPoint) { throw 'A native executable needs -EntryPoint.' }
            # The lowered assembly sits beside the executable, named for it; ILC and the linker take it from there.
            $compileParameters['OutputPath'] = [IO.Path]::ChangeExtension([IO.Path]::GetFullPath($OutputPath), '.dll')
            $lowered = Export-LoweredAssembly @compileParameters
            $image = Export-NativeImage -AssemblyPath $lowered.OutputPath -OutputPath $OutputPath -Subsystem $Subsystem
            [pscustomobject]@{ Assembly = $lowered; Native = $image }
        }
        'Expression' {
            if ($null -eq $MethodAst) { throw 'Expression requires -MethodAst.' }
            ConvertTo-TypedExpression -MethodAst $MethodAst
        }
        'Inspect' { Test-LoweredAssembly -AssemblyPath $AssemblyPath }
        'Capability' { Get-LoweringCapability }
        'Describe' { Get-SmaDescription $(if ($ProjectPath) { $ProjectPath } else { $PSScriptRoot }) }
        'Lint' {
            $targets = if ($LintFiles) { $LintFiles } else { foreach ($project in Get-Projects) { foreach ($relative in $project.Files) { Join-Path $project.Path $relative } } }
            $findings = @(foreach ($file in $targets) { if (Test-Path -LiteralPath $file) { Get-SmaLint ([IO.Path]::GetFullPath($file)) } })
            $findings | Group-Object Rule | Sort-Object Count -Descending | ForEach-Object { '{0,-20} {1,5}' -f $_.Name, $_.Count }
            $findings | Sort-Object Rule, File, Line | ForEach-Object { '{0,-20} {1}:{2}  {3}' -f $_.Rule, $_.File, $_.Line, $_.Detail }
        }
        'Profile' { Invoke-SmaProfile }
        'Report' {
            if (-not $ProfilePath) { throw 'Report requires a historical -ProfilePath.' }
            $profiled = Import-Clixml -LiteralPath $ProfilePath
            Get-SmaReport @(Get-SmaUnits $profiled) $profiled
        }
        'Verify' { Test-SmaDescription }
        'Investigate' {
            if (-not $InvestigatePath) { throw 'Investigate requires -InvestigatePath.' }
            Invoke-PscInvestigation -Path $InvestigatePath
        }
        'Readme' {
            $readme = Join-Path $PSScriptRoot 'README.md'
            [IO.File]::WriteAllLines($readme, [string[]]@(ConvertTo-PscReadme -Api (Get-PscApi)), [Text.UTF8Encoding]::new($false))
            Get-Item -LiteralPath $readme
        }
        'Link' {
            $resolution = Resolve-CoffLink -Inputs $LinkInput -LibraryDirectories @($LibraryDirectory | Where-Object { $_ }) -DefaultLibraries @($DefaultLibrary | Where-Object { $_ }) -IgnoredDefaultLibraries @($NoDefaultLibrary | Where-Object { $_ }) -Entry $EntrySymbol
            if ($ResolveOnly) { return $resolution }
            if ($resolution.Unresolved.Count) { throw ("Link: unresolved external symbols:`n" + ($resolution.Unresolved -join "`n")) }
            Write-CoffImage -Resolution $resolution -Path ([IO.Path]::GetFullPath($OutputPath)) -Merges @($LinkMerge | Where-Object { $_ }) -Subsystem $(if ($Subsystem -eq 'Windows') { 2 } else { 3 }) -StackReserve $StackReserve
        }
    }
}

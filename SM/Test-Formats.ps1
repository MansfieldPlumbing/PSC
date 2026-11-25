#requires -Version 7.7
[CmdletBinding()]
param([string] $Compiler = (Join-Path (Split-Path -Parent $PSScriptRoot) 'PSC.ps1'))
$ErrorActionPreference = 'Stop'
$Compiler = [IO.Path]::GetFullPath($Compiler)
$pwsh = (Get-Process -Id $PID).Path
$work = Join-Path ([IO.Path]::GetTempPath()) ('psc-sm-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)

function Assert-Pass([bool] $Condition, [string] $Description) {
    if (!$Condition) { throw $Description }
    [Console]::WriteLine('PASS ' + $Description)
}
function Invoke-Entry([Reflection.Assembly] $Assembly, [string[]] $Arguments) {
    $previous = [Console]::Out
    $capture = [IO.StringWriter]::new([Globalization.CultureInfo]::CurrentCulture)
    try {
        [Console]::SetOut($capture)
        [void]$Assembly.EntryPoint.Invoke($null, [object[]]@(,$Arguments))
        return $capture.ToString().TrimEnd("`r", "`n")
    } finally { [Console]::SetOut($previous); $capture.Dispose() }
}
# Test-only native call adapter. The production code and image are emitted by PSC.
function New-NativeOracleDelegate {
    $ab = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly([Reflection.AssemblyName]::new('SmTestNativeDelegate'), [Reflection.Emit.AssemblyBuilderAccess]::Run)
    $tb = $ab.DefineDynamicModule('Oracle').DefineType('SmTestNativeDelegate', [Reflection.TypeAttributes]'Public,Sealed', [MulticastDelegate])
    $ctor = $tb.DefineConstructor([Reflection.MethodAttributes]'Public,HideBySig,RTSpecialName', [Reflection.CallingConventions]::Standard, [type[]]@([object], [IntPtr]))
    $ctor.SetImplementationFlags([Reflection.MethodImplAttributes]::Runtime)
    $invoke = $tb.DefineMethod('Invoke', [Reflection.MethodAttributes]'Public,HideBySig,NewSlot,Virtual', [double], [type[]]@([double]))
    $invoke.SetImplementationFlags([Reflection.MethodImplAttributes]::Runtime)
    return $tb.CreateType()
}
try {
    $script = Join-Path $PSScriptRoot 'Calibration.sm1'
    $contractSource = Join-Path $PSScriptRoot 'Calibration.srm1'
    $clientSource = Join-Path $PSScriptRoot 'CalibrationClient.sm1'
    $appliance = Join-Path $PSScriptRoot 'Calibration.sexe'
    $runtime = Join-Path $work 'runtime'
    $expected = ([double]41.25).ToString([Globalization.CultureInfo]::CurrentCulture)
    $portable = & $pwsh -NoProfile -File $script -Value 10
    Assert-Pass ($LASTEXITCODE -eq 0 -and $portable -ceq $expected) 'portable .sm1 executes directly in stock Pwsh'
    $unbootstrapped = & $pwsh -NoProfile -File $clientSource 2>&1
    Assert-Pass ($LASTEXITCODE -ne 0 -and ($unbootstrapped | Out-String).Contains('ScriptTypeRole')) 'PSC-dependent .sm1 fails without its declared runtime types'

    # Explicit paths, before any runtime load: the query gate accepts each format.
    foreach ($entry in @(@($script, 'SmCalibrationProvider'), @($contractSource, 'SmCalibrationContract'), @($appliance, 'SmApplianceKernel'))) {
        $q = & $Compiler -Mode Query -QueryPath $entry[0] -QueryKind Declaration -QueryName $entry[1] -QueryTake 1
        try {
            Assert-Pass ($q.Coverage().ArtifactsOpened -eq 0) "lazy query opens no $([IO.Path]::GetExtension($entry[0])) at creation"
            $hits = $q.Pull(1)
            Assert-Pass ($hits.Length -eq 1 -and $hits[0].Name -ceq $entry[1] -and $hits[0].ArtifactSha256 -ceq (Get-FileHash -LiteralPath $entry[0]).Hash -and !$hits[0].ParseIncomplete) "structural witness for $([IO.Path]::GetExtension($entry[0]))"
        } finally { $q.Dispose() }
    }
    $q = & $Compiler -Mode Query -QueryPath $PSScriptRoot -QueryKind Declaration -QueryName SmApplianceKernel
    try { $hits = $q.Pull(64); Assert-Pass ($hits.Length -eq 1 -and $q.Coverage().Exhausted) 'directory query discovers .sexe without filename rewriting' } finally { $q.Dispose() }

    # All runtime dependencies are built from the same authoritative PSC.ps1.
    & $Compiler -Mode BuildRuntime -RuntimeDirectory $runtime -ContractPaths $contractSource | Out-Null
    Assert-Pass ([IO.Directory]::GetFiles($runtime, '*.dll').Length -eq 7) 'clean seven-faculty runtime with .srm1 contract input'
    Assert-Pass (@([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -in 'Vom', 'ScriptType', 'InquiryPrimitives' }).Count -eq 0) 'runtime build does not contaminate coordinator identities'
    $providerPath = Join-Path $work 'Provider.dll'
    $portablePath = Join-Path $work 'Portable.dll'
    $clientPath = Join-Path $work 'Client.dll'
    $applicationPath = Join-Path $work 'Application.dll'
    $compactPath = Join-Path $work 'Compact.dll'
    & $Compiler -SourcePath $script -DeclarationsOnly -ClassName SmCalibrationProvider -OutputPath $providerPath | Out-Null
    & $Compiler -SourcePath $script -Program -OutputPath $portablePath | Out-Null
    & $Compiler -SourcePath $appliance -Program -OutputPath $applicationPath | Out-Null
    & $Compiler -SourcePath $appliance -Program -FixedParameters @{ Presentation = 'Compact' } -OutputPath $compactPath | Out-Null
    $portableAssembly = [Reflection.Assembly]::LoadFrom($portablePath)
    Assert-Pass ((Invoke-Entry $portableAssembly @('-Value', '10')) -ceq $portable) 'compiled portable .sm1 agrees with unmodified Pwsh'
    $application = [Reflection.Assembly]::LoadFrom($applicationPath)
    $compact = [Reflection.Assembly]::LoadFrom($compactPath)
    Assert-Pass ((Invoke-Entry $application @('-Value', '10')) -ceq $expected) 'one-file .sexe default application entry point'
    Assert-Pass ((Invoke-Entry $application @('-Value', '10', '-Presentation', 'Detailed')) -ceq ('Calibrated value:' + [Environment]::NewLine + $expected)) 'one-file .sexe alternative application behavior'
    Assert-Pass ((Invoke-Entry $compact @('-Value', '10')) -ceq $expected) 'specialized .sexe retains behavior of selected mode'
    $rejected = $false
    try { $null = Invoke-Entry $compact @('-Value', '10', '-Presentation', 'Detailed') } catch { $rejected = $_.Exception.GetBaseException().Message.Contains('Presentation') }
    Assert-Pass $rejected 'fixed appliance parameter cannot be overridden at execution'

    foreach ($name in 'Vom', 'InquiryPrimitives', 'ScriptType') { [void][Reflection.Assembly]::LoadFrom((Join-Path $runtime ($name + '.dll'))) }
    & $Compiler -SourcePath $clientSource -DeclarationsOnly -ClassName SmCalibrationClient -OutputPath $clientPath | Out-Null
    $client = [Reflection.Assembly]::LoadFrom($clientPath).GetType('SmCalibrationClient', $true)
    $providerType = [Reflection.Assembly]::LoadFrom($providerPath).GetType('SmCalibrationProvider', $true)
    $provider = [Activator]::CreateInstance($providerType)
    $descriptor = [ScriptTypeCatalog]::Find('SmCalibrationContract')
    $member = $descriptor.FindResolved('Apply', [type[]]@([double]))
    Assert-Pass ($null -ne $member -and $member.Required -and $member.ResultTypeIdentity -ceq [double].AssemblyQualifiedName) '.srm1 produces a typed required contract operation'
    Assert-Pass ($null -eq [ScriptTypeCatalog].Assembly.GetType('SmCalibrationContract') -and $null -eq [ScriptTypeCatalog].Assembly.GetType('SmCalibrationUse')) '.srm1 catalog retains semantic descriptors rather than executable contract classes'
    $space = [Vom]::new()
    $owner = $space.Register(0, [object]::new(), [object], $null)
    try {
        $realization = [ScriptTypeRealization]::new()
        $realization.ContractHandle = $space.Register($owner, $descriptor, [ScriptTypeContract], $null)
        $realization.ReceiverHandle = $space.Register($owner, $provider, [object], $null)
        $thunk = $providerType.GetMethod('ApplyThunk').CreateDelegate([Func[object,object[],object]])
        $realization.Calls = [ScriptTypeCall[]]@([ScriptTypeCall]::new($member, [type[]]@([double]), $thunk))
        $handle = $space.Register($owner, $realization, [ScriptTypeRealization], $null)
        [void]$space.Rebind($owner, 'calibration', 0, $handle)
        $role = [ScriptTypeRole]::new($space, $owner, 'calibration')
        $measure = $client.GetMethod('Measure')
        foreach ($value in [double[]]@(-10, 0, 2.5, 10, 127.125)) {
            $reference = $providerType.GetMethod('Apply').Invoke($provider, [object[]]@($value))
            Assert-Pass ($measure.Invoke($null, [object[]]@($role, $value)) -eq $reference) "bootstrapped .sm1 resolves .srm1 contract and invokes provider ($value)"
        }
        [void]$space.Revoke($handle)
        $denied = $false
        try { [void]$measure.Invoke($null, [object[]]@($role, [double]10)) } catch { $denied = $true }
        Assert-Pass $denied 'withdrawn role denies the same compiled SM client'
    } finally { [void]$space.Revoke($owner) }
    Assert-Pass ('System.Management.Automation' -notin $client.Assembly.GetReferencedAssemblies().Name -and 'System.Management.Automation' -notin [ScriptTypeCatalog].Assembly.GetReferencedAssemblies().Name) 'PSC-dependent SM client and catalog have no SMA reference'

    if ($IsLinux -and [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -eq [Runtime.InteropServices.Architecture]::X64) {
        $library = Join-Path $work 'ApplianceKernel.so'
        & $Compiler -Mode NativeCil -AssemblyPath $applicationPath -ClassName SmApplianceKernel -MethodNames Apply -RuntimeDirectory $runtime -OutputPath $library | Out-Null
        $native = [Runtime.InteropServices.NativeLibrary]::Load($library)
        try {
            $invoke = [Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer([Runtime.InteropServices.NativeLibrary]::GetExport($native, 'Apply'), (New-NativeOracleDelegate))
            $method = $application.GetType('SmApplianceKernel', $true).GetMethod('Apply')
            foreach ($value in [double[]]@(-10, 0, 2.5, 10, 127.125)) {
                $reference = [double]$method.Invoke($null, [object[]]@($value))
                $actual = [double]$invoke.DynamicInvoke([object[]]@($value))
                Assert-Pass ([BitConverter]::DoubleToInt64Bits($actual) -eq [BitConverter]::DoubleToInt64Bits($reference)) "native .sexe kernel agrees with managed realization ($value)"
            }
        } finally { [Runtime.InteropServices.NativeLibrary]::Free($native) }
    } else { [Console]::WriteLine('SKIP direct-native kernel execution requires Linux x64') }
} finally { [IO.Directory]::Delete($work, $true) }

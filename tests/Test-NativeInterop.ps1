param([string]$DataAssemblyPath, [string]$ExpectedDataText, [string]$ExpectedDataHash)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($DataAssemblyPath) {
    if((Get-FileHash -LiteralPath $DataAssemblyPath).Hash -cne $ExpectedDataHash) { throw 'Fresh typed-data assembly identity changed.' }
    $assembly=[Reflection.Assembly]::LoadFile($DataAssemblyPath)
    $dataType=$assembly.GetType('NativeInteropFixture',$true)
    if($dataType.GetMethod('ReadData').Invoke($null,@()) -cne $ExpectedDataText -or $dataType.GetMethod('DataAt').Invoke($null,@(-1)) -ne -3 -or $assembly.GetTypes().Length -ne 1) { throw 'Fresh typed-data reconstruction failed.' }
    'FRESH_TYPED_DATA=PASS'
    return
}
if(-not $IsWindows -or [IntPtr]::Size -ne 8) { throw 'Native ABI gates require Windows x64.' }
$root=Split-Path $PSScriptRoot -Parent
$compiler=Join-Path $root 'Export-LoweredAssembly.ps1'
$dir=Join-Path $root 'build/native-interop'
$null=New-Item -ItemType Directory -Force $dir
$fixture=Join-Path $PSScriptRoot 'native-fixtures/NativeInteropFixture.ps1'
$dll=Join-Path $dir 'NativeInteropFixture.dll'
$null=& $compiler -SourcePath $fixture -OutputPath $dll -EntryPoint Main
$type=[Reflection.Assembly]::LoadFile($dll).GetType('NativeInteropFixture',$true)
. (Join-Path $PSScriptRoot 'NativeMetadata.ps1')
. (Join-Path $PSScriptRoot 'LegacyMetadata.ps1')
Test-NativeMetadata $type
foreach($reference in (Read-LegacyAssembly $dll).References) {
    if($reference.Name -cne 'System.Private.CoreLib') { throw 'Native output contains an external assembly reference.' }
}
function Check($ObservedValue,$ExpectedValue,[string]$GateName) { if(-not [object]::Equals($ObservedValue,$ExpectedValue)) { throw "Native ABI gate failed: $GateName" } }

# Independent CLR answers cover value receivers on computed values, arguments,
# static storage and local copies. These checks precede the external host gate.
$guidText='48eba18e-f8c9-4687-bf11-0a74c9f96a8f'
Check ([Convert]::ToHexString($type.GetMethod('GuidBytes').Invoke($null,@($guidText)))) ([Convert]::ToHexString([Guid]::new($guidText).ToByteArray())) 'computed struct receiver'
Check ($type.GetMethod('NumberText').Invoke($null,@(1234))) '000004D2' 'value argument receiver'
Check ($type.GetMethod('DateTicks').Invoke($null,@())) ([long]123456) 'struct property receiver'
Check ($type.GetMethod('ValueTypeName').Invoke($null,@(7))) 'System.Int32' 'constrained Object method'
Check ($type.GetMethod('MutateStaticValue').Invoke($null,@())) 1 'mutable static struct receiver'
Check ($type.GetMethod('MutateLocalValue').Invoke($null,@())) 2 'mutable local struct receiver'
Check ($type.GetField('Spinner').GetValue($null).Count) 1 'local mutation preserves copied source'
Check ($type.GetMethod('WriteStructField').Invoke($null,@())) 123 'field assignment through a struct receiver'
Check ($type.GetMethod('MakeInstance').Invoke($null,@()).GetType()) $type 'implicit constructor'
Check ($type.Assembly.GetType('DefaultInitializerFixture',$true).GetMethod('Read').Invoke($null,@())) 7 'implicit constructor runs instance initializers'
Check ($type.GetMethod('ListWork').Invoke($null,@())) 18 'list index read write and compound assignment'
foreach($value in 0,10,65535) { Check ($type.GetMethod('Character').Invoke($null,@($value))) ([char]$value) 'integer to char' }
foreach($value in -1,65536,70000) {
    $rejected=$false
    try { $null=$type.GetMethod('Character').Invoke($null,@($value)) } catch { $rejected=$true }
    if(-not $rejected) { throw "Out-of-range char conversion admitted: $value" }
}
$tokens=$null;$errors=$null
$sourceAst=[Management.Automation.Language.Parser]::ParseFile($fixture,[ref]$tokens,[ref]$errors)
if($errors.Count) { throw 'Native fixture has parse failures.' }
$dataDll=Join-Path $dir 'NativeTypedData.dll'
$textData="quote ' and newline`nΩ"
$null=& $compiler -SourceAst $sourceAst -ClassName NativeInteropFixture -ClassNames @('NativeInteropFixture') -StaticData @{'NativeInteropFixture.DataText'=$textData;'NativeInteropFixture.DataNumbers'=[int[]]@(7,19,-3)} -OutputPath $dataDll
$dataAssembly=[Reflection.Assembly]::LoadFile($dataDll)
$dataType=$dataAssembly.GetType('NativeInteropFixture',$true)
Check ($dataType.GetMethod('ReadData').Invoke($null,@())) $textData 'typed string data without source substitution'
Check ($dataType.GetMethod('DataAt').Invoke($null,@(1))) 19 'typed array data'
Check ($dataAssembly.GetTypes().Length) 1 'explicit class selection'
$dataType.GetField('DataText').SetValue($null,'resident mutation must not become durable data')
$start=[Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
$start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
foreach($argument in @('-NoProfile','-File',$PSCommandPath,'-DataAssemblyPath',$dataDll,'-ExpectedDataText',$textData,'-ExpectedDataHash',(Get-FileHash -LiteralPath $dataDll).Hash)) { $start.ArgumentList.Add($argument) }
$process=[Diagnostics.Process]::Start($start)
$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync();$process.WaitForExit()
if($process.ExitCode -ne 0 -or -not $stdout.Result.Contains('FRESH_TYPED_DATA=PASS')) { throw ('Fresh typed-data verification failed: '+$stdout.Result+$stderr.Result) }
foreach($invalidData in @(@{'NativeInteropFixture.Unknown'='x'},@{'NativeInteropFixture.DataText'=1},@{'NativeInteropFixture.DataPointer'=[IntPtr]::Zero},@{'UnselectedNativeFixture.Data'=7})) {
    $invalidPath=Join-Path $dir ([guid]::NewGuid().ToString('N')+'.dll')
    $rejected=$false
    try { $null=& $compiler -SourceAst $sourceAst -ClassName NativeInteropFixture -ClassNames @('NativeInteropFixture') -StaticData $invalidData -OutputPath $invalidPath } catch { $rejected=$true }
    if(-not $rejected -or (Test-Path -LiteralPath $invalidPath)) { throw 'Invalid static data emitted an assembly.' }
}
Write-Host 'AST input, typed data, class selection, value receivers, implicit constructors, list indexing and char boundaries: PASS.'

# Independent unmanaged ABI oracle: public Reflection.Emit defines delegate
# metadata, not compiler expressions or compiler IL. NativeLibrary supplies
# OS/CRT exports. No C# source compilation, third-party binary or device.
function New-AbiDelegate([string]$OracleName,[Type]$Return,[Type[]]$Parameters,[Runtime.InteropServices.CallingConvention]$Convention) {
    $a=[Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly([Reflection.AssemblyName]::new($OracleName),[Reflection.Emit.AssemblyBuilderAccess]::RunAndCollect)
    $t=$a.DefineDynamicModule($OracleName).DefineType($OracleName,[Reflection.TypeAttributes]'Public,Sealed',[MulticastDelegate])
    $t.DefineConstructor([Reflection.MethodAttributes]'Public,HideBySig,SpecialName,RTSpecialName',[Reflection.CallingConventions]::Standard,[Type[]]@([object],[IntPtr])).SetImplementationFlags([Reflection.MethodImplAttributes]'Runtime,Managed')
    $t.DefineMethod('Invoke',[Reflection.MethodAttributes]'Public,HideBySig,NewSlot,Virtual',$Return,$Parameters).SetImplementationFlags([Reflection.MethodImplAttributes]'Runtime,Managed')
    $attr=[Runtime.InteropServices.UnmanagedFunctionPointerAttribute]
    $t.SetCustomAttribute([Reflection.Emit.CustomAttributeBuilder]::new($attr.GetConstructor([Type[]]@([Runtime.InteropServices.CallingConvention])),[object[]]@($Convention)))
    $t.CreateType()
}
$kernel=[Runtime.InteropServices.NativeLibrary]::Load('kernel32.dll')
$crt=[Runtime.InteropServices.NativeLibrary]::Load('ucrtbase.dll')
$data=[Runtime.InteropServices.Marshal]::AllocHGlobal(20)
try {
    $pidPointer=[Runtime.InteropServices.NativeLibrary]::GetExport($kernel,'GetCurrentProcessId')
    $pidDelegate=New-AbiDelegate 'PidOracle' ([uint]) ([Type[]]@()) ([Runtime.InteropServices.CallingConvention]::StdCall)
    $oracle=[Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer($pidPointer,$pidDelegate)
    Check ($type.GetMethod('ProcessId').Invoke($null,@($pidPointer))) ($oracle.DynamicInvoke()) 'stdcall OS export'
    Check ($oracle.DynamicInvoke()) ([uint][Environment]::ProcessId) 'OS process identity'
    $attribute=$type.GetMethod('Comparator').GetCustomAttributes([Runtime.InteropServices.UnmanagedCallersOnlyAttribute],$false)
    Check $attribute.Count 1 'callback attribute'
    Check $attribute[0].CallConvs[0] ([Runtime.CompilerServices.CallConvCdecl]) 'callback convention'
    $pointer=$type.GetMethod('ComparatorAddress').Invoke($null,@())
    if($pointer -eq [IntPtr]::Zero) { throw 'ldftn produced null.' }
    $compareType=New-AbiDelegate 'ComparatorOracle' ([int]) ([Type[]]@([IntPtr],[IntPtr])) ([Runtime.InteropServices.CallingConvention]::Cdecl)
    $compare=[Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer($pointer,$compareType)
    $mixedPointer=$type.GetMethod('MixedAddress').Invoke($null,@())
    $mixedType=New-AbiDelegate 'MixedOracle' ([double]) ([Type[]]@([long],[single],[double],[long])) ([Runtime.InteropServices.CallingConvention]::Cdecl)
    $mixed=[Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer($mixedPointer,$mixedType)
    $mixedArgs=@([long]5000000000,[single]1.25,[double]2.5,[long]7)
    Check ($type.GetMethod('CallMixed').Invoke($null,(@($mixedPointer)+$mixedArgs))) ($mixed.DynamicInvoke($mixedArgs)) 'mixed scalar signature'
    Check ($mixed.DynamicInvoke($mixedArgs)) ([double]5000000010.75) 'mixed scalar independent answer'
    $echoPointer=$type.GetMethod('EchoAddress').Invoke($null,@())
    $wide=[IntPtr]::new([long]4294967297)
    Check ($type.GetMethod('CallEcho').Invoke($null,@($echoPointer,$wide))) $wide '64-bit pointer argument and result'
    $writePointer=$type.GetMethod('WriteAddress').Invoke($null,@())
    $null=$type.GetMethod('CallWrite').Invoke($null,@($writePointer,$data,[long]5000000000))
    Check ([Runtime.InteropServices.Marshal]::ReadInt64($data)) ([long]5000000000) 'void callback and 64-bit scalar'
    # Callback body parity against the actual PowerShell method on the same memory.
    . $fixture
    $sourceType='NativeInteropFixture' -as [Type]
    foreach($pair in @(@(-9,17),@(17,-9),@(17,17),@([int]::MinValue,[int]::MaxValue))) {
        [Runtime.InteropServices.Marshal]::WriteInt32($data,0,$pair[0])
        [Runtime.InteropServices.Marshal]::WriteInt32($data,4,$pair[1])
        $right=[IntPtr]::Add($data,4)
        $expected=$sourceType.GetMethod('CompareValues').Invoke($null,@($data,$right))
        Check ($compare.DynamicInvoke(@($data,$right))) $expected 'independent callback ABI and PowerShell parity'
        Check ($type.GetMethod('Compare').Invoke($null,@($pointer,$data,$right))) $expected 'typed calli roundtrip'
    }
    $values=[int[]]@(7,-3,7,[int]::MinValue,0)
    [Runtime.InteropServices.Marshal]::Copy($values,0,$data,$values.Length)
    $sort=[Runtime.InteropServices.NativeLibrary]::GetExport($crt,'qsort')
    $null=$type.GetMethod('Sort').Invoke($null,@($sort,$data,[UIntPtr]::new([uint]5),[UIntPtr]::new([uint]4),$pointer))
    [Array]::Sort($values)
    for($i=0;$i -lt 5;$i++) { Check ([Runtime.InteropServices.Marshal]::ReadInt32($data,$i*4)) $values[$i] 'native qsort reverse callback' }
    $nullRejected=$false
    try { $null=$type.GetMethod('ProcessId').Invoke($null,@([IntPtr]::Zero)) } catch { $nullRejected=$_.Exception.InnerException -is [ArgumentNullException] }
    if(-not $nullRejected) { throw 'Null native pointer was not rejected.' }
}
finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($data); [Runtime.InteropServices.NativeLibrary]::Free($crt); [Runtime.InteropServices.NativeLibrary]::Free($kernel) }

# Ordinary managed instance delegates run both synchronously (PowerShell parity)
# and on a CLR-created thread with no runspace.
$workerPath=Join-Path $PSScriptRoot 'native-fixtures/ThreadDelegateFixture.ps1'
$workerDll=Join-Path $dir 'ThreadDelegateFixture.dll'
$null=& $compiler -SourcePath $workerPath -OutputPath $workerDll -EntryPoint Main
$workerType=[Reflection.Assembly]::LoadFile($workerDll).GetType('ThreadDelegateFixture',$true)
. $workerPath
$sourceWorker='ThreadDelegateFixture' -as [Type]
foreach($t in @($sourceWorker,$workerType)) {
    $w=[Activator]::CreateInstance($t)
    $delegate=$t.GetMethod('Worker').Invoke($w,@())
    Check ($delegate.GetType()) ([Threading.ThreadStart]) 'typed managed delegate'
    $delegate.Invoke()
    Check ($w.Result) 42 'instance delegate parity'
}
$w=[Activator]::CreateInstance($workerType)
$null=$workerType.GetMethod('StartAndJoin').Invoke($w,@())
Check ($w.Result) 42 'CLR worker thread'

# Fresh dotnet hosts independently assert absence of SMA and exercise native IL.
foreach($program in @($dll,$workerDll)) {
    $output=& dotnet exec $program 2>&1
    if($LASTEXITCODE -ne 0) { throw "Zero-SMA native host failed ($LASTEXITCODE): $output" }
}

$cdecl='[System.Runtime.InteropServices.UnmanagedCallConv(CallConvs=[System.Runtime.CompilerServices.CallConvCdecl])]'
$callback='[System.Runtime.InteropServices.UnmanagedCallersOnly(CallConvs=[System.Runtime.CompilerServices.CallConvCdecl])]'
$cases=[ordered]@{
    PointerWidth="$cdecl static [int] M([long]`$p) { throw [NotSupportedException]::new() }"
    Instance="$callback [int] M([int]`$x) { return `$x }"
    Reference="$callback static [int] M([string]`$x) { return 0 }"
    Boolean="$callback static [bool] M() { return `$true }"
    Char="$callback static [int] M([char]`$x) { return 0 }"
    Array="$callback static [int] M([int[]]`$x) { return 0 }"
    Byref="$callback static [int] M([ref]`$x) { return 0 }"
    MissingConvention='[System.Runtime.InteropServices.UnmanagedCallersOnly()] static [int] M() { return 0 }'
    UnsupportedConvention='[System.Runtime.InteropServices.UnmanagedCallersOnly(CallConvs=[System.Runtime.CompilerServices.CallConvFastcall])] static [int] M() { return 0 }'
    Body="$cdecl static [int] M([IntPtr]`$p) { return 0 }"
    ManagedCall="$callback static [int] M() { return 0 } static [int] N() { return [RejectManagedCall]::M() }"
    OrdinaryAddress="static [int] M() { return 0 } static [IntPtr] N() { return [RejectOrdinaryAddress].GetMethod('M').MethodHandle.GetFunctionPointer() }"
    MixedContracts="$callback $cdecl static [int] M([IntPtr]`$p) { throw [NotSupportedException]::new() }"
    CalliReference="$cdecl static [int] M([IntPtr]`$p, [string]`$s) { throw [NotSupportedException]::new() }"
    CalliBoolean="$cdecl static [int] M([IntPtr]`$p, [bool]`$b) { throw [NotSupportedException]::new() }"
}
foreach($name in $cases.Keys) {
    $source=Join-Path $dir "Reject$name.ps1"
    $out=Join-Path $dir "Reject$name.dll"
    Set-Content $source "class Reject$name { $($cases[$name]) }"
    if(Test-Path $out) { Remove-Item -LiteralPath $out }
    $message=$null
    try { $null=& $compiler -SourcePath $source -OutputPath $out } catch { $message=$_.Exception.Message }
    if($null -eq $message -or $message -notmatch '\[\d+:\d+\]' -or (Test-Path $out)) { throw "Native rejection gate failed: $name ($message)" }
}
foreach($gate in 'EntryPoint','OmittedCallback') {
    $out=Join-Path $dir "Reject$gate.dll"
    if(Test-Path $out) { Remove-Item -LiteralPath $out }
    $compileArguments=@{SourcePath=$fixture;OutputPath=$out}
    if($gate -eq 'EntryPoint') {
        $source=Join-Path $dir 'RejectEntryPoint.ps1'
        Set-Content $source "class RejectEntryPoint { $callback static [int] Main() { return 0 } }"
        $compileArguments.SourcePath=$source
        $compileArguments.EntryPoint='Main'
    }
    else { $compileArguments.MethodNames=@('ComparatorAddress') }
    $message=$null
    try { $null=& $compiler @compileArguments } catch { $message=$_.Exception.Message }
    if($null -eq $message -or $message -notmatch '\[\d+:\d+\]' -or (Test-Path $out)) { throw "Native rejection gate failed: $gate ($message)" }
}
$ast=[Management.Automation.Language.Parser]::ParseFile($fixture,[ref]$null,[ref]$null)
foreach($name in 'ProcessId','ComparatorAddress') {
    $method=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionMemberAst] -and $n.Name -ceq $name},$true)
    $message=$null
    try { $null=& $compiler -Mode Expression -MethodAst $method } catch { $message=$_.Exception.Message }
    if($null -eq $message -or $message -notmatch '\[\d+:\d+\].*Compile mode') { throw "Native Expression mode boundary failed: $name" }
}
Write-Host "Native interop: ABI, reverse callback, parity, worker, zero-SMA hosts and $($cases.Count) negative gates passed."

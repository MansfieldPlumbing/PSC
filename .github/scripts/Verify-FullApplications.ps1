[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Psc,
    [Parameter(Mandatory)][string]$Psnes,
    [Parameter(Mandatory)][string]$Notepad,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$null = [IO.Directory]::CreateDirectory($OutputDirectory)
if ([Environment]::Version.Major -ne 11) { throw "Need .NET 11; found $([Environment]::Version)." }

# First verify the source emulator. Never treat the compilation itself as execution parity.
$runner = [Environment]::ProcessPath
$report = @(& $runner -NoProfile -NonInteractive -File $Psnes -Conformance)
if ($LASTEXITCODE -ne 0) { throw "Interpreted PSNES conformance exited $LASTEXITCODE." }
$passed = @($report | Where-Object { $_ -match '\sPASS\s*$' }).Count
if ($passed -ne 18) { throw "PSNES conformance $passed/18." }
"PSNES interpreted tests: 18/18 PASS"

# Compile the actual production PSNES program, not the historical seven-class core.
# Fix the Conformance switch so test-runner commands are not entry-point dependencies.
$psnesPath = Join-Path $OutputDirectory 'PSNES.dll'
$null = & $Psc -Mode Compile -Program -SourcePath $Psnes -FixedParameters @{ Conformance = $false } -OutputPath $psnesPath
if (-not (Test-Path -LiteralPath $psnesPath)) { throw 'PSNES full managed build produced no assembly.' }
$a = [Reflection.Assembly]::LoadFrom($psnesPath)
$names = @($a.GetTypes() | ForEach-Object Name)
foreach ($name in 'Rom','Ppu','Memory','OpInfo','Cpu6502','Nes','PsnesBench','Win32','NesWindow','PSNES') {
    if ($name -notin $names) { throw "PSNES full assembly omitted $name." }
}
if ($a.EntryPoint.Name -ne 'Main') { throw 'PSNES missing program entry point.' }
if (@($a.GetTypes()).Count -lt 15) { throw 'PSNES full assembly lost authored or generated types.' }
"PSNES referenced assemblies: $(@($a.GetReferencedAssemblies() | ForEach-Object Name) -join ', ')"

# Deterministic NROM program: INC $0000; JMP $8000. The 20-frame RAM checksum
# is nonzero, checking actual CPU writes rather than mere idle-frame execution.
[string]$rom = [IO.Path]::GetFullPath((Join-Path $OutputDirectory 'fixture.nes'))
[byte[]]$image = [byte[]]::new(16 + 16384)
$image[0]=0x4e; $image[1]=0x45; $image[2]=0x53; $image[3]=0x1a; $image[4]=1
for ([int]$i=16; $i -lt $image.Length; $i++) { $image[$i]=0xea }
[byte[]]$loop = @(0xee,0,0,0x4c,0,0x80)
[Array]::Copy($loop, 0, $image, 16, 6)
for ([int]$i=$image.Length-6; $i -lt $image.Length; $i+=2) { $image[$i]=0; $image[$i+1]=0x80 }
[IO.File]::WriteAllBytes($rom,$image)
$nesType=$a.GetType('Nes',$true)
$nes=[Activator]::CreateInstance($nesType)
$romInstance=$nesType.GetField('Rom').GetValue($nes)
if (-not $romInstance.GetType().GetMethod('Load').Invoke($romInstance,[object[]]@([string]$rom))) { throw 'Fixture rejected by compiled PSNES.' }
$null=$nesType.GetMethod('PowerOn').Invoke($nes,[object[]]@())
$run=$nesType.GetMethod('RunFrame')
for ([int]$frame=0; $frame -lt 20; $frame++) { $null=$run.Invoke($nes,[object[]]@()) }
$memory=$nesType.GetField('Memory').GetValue($nes)
[byte[]]$ram=$memory.GetType().GetField('Ram').GetValue($memory)
[ulong]$actual=$a.GetType('PsnesBench').GetMethod('Checksum').Invoke($null,[object[]]@(,$ram))
[ulong]$expected=[ulong]::Parse('2000000000000004',[Globalization.NumberStyles]::HexNumber)
if ($actual -ne $expected) { throw ('PSNES checksum {0:X16}, expected {1:X16}' -f $actual,$expected) }
"PSNES full managed: PASS, 20 frames, checksum $('{0:X16}' -f $actual)"

# Notepad is likewise compiled from its production entry point, including all
# application classes. Verification and browser-design tasks are not part of the
# executable's reachability graph. The ICO lives beside Notepad.ps1.
$notepadPath = Join-Path $OutputDirectory 'Notepad.dll'
$fixed = @{
    VerifyModel=$false; VerifyGraphics=$false; VerifyWindow=$false; Compare=$false;
    VerifyNativeFeatures=$false; CatalogIcons=$false; ExtractTypeScript=$false;
    BuildTypeScript=$false; BuildDesign=$false; SkipBrowser=$true; DiagnosticPath=''
}
$null = & $Psc -Mode Compile -Program -SourcePath $Notepad -FixedParameters $fixed -OutputPath $notepadPath
if (-not (Test-Path -LiteralPath $notepadPath)) { throw 'Notepad full managed build produced no assembly.' }
$b=[Reflection.Assembly]::LoadFrom($notepadPath)
$types=@($b.GetTypes())
if ($types.Count -lt 54) { throw "Notepad emitted $($types.Count) CLR types, expected at least 54." }
if ($b.EntryPoint.Name -ne 'Main') { throw 'Notepad missing Main entry.' }
"Notepad referenced assemblies: $(@($b.GetReferencedAssemblies() | ForEach-Object Name) -join ', ')"
$t=$b.GetType('NotepadDocument',$true)
$d=[Activator]::CreateInstance($t,[object[]]@('abcd'))
$get=$t.GetMethod('GetText',[Type[]]@([int],[int]))
$insert=$t.GetMethod('Insert',[Type[]]@([int],[string]))
$delete=$t.GetMethod('Delete',[Type[]]@([int],[int]))
$undo=$t.GetMethod('Undo',[Type[]]@())
$redo=$t.GetMethod('Redo',[Type[]]@())
$null=$insert.Invoke($d,[object[]]@(2,'XY'))
if ($get.Invoke($d,[object[]]@(0,6)) -cne 'abXYcd') { throw 'Notepad insert mismatch.' }
$null=$undo.Invoke($d,[object[]]@())
if ($get.Invoke($d,[object[]]@(0,4)) -cne 'abcd') { throw 'Notepad undo mismatch.' }
$null=$redo.Invoke($d,[object[]]@())
if ($get.Invoke($d,[object[]]@(0,6)) -cne 'abXYcd') { throw 'Notepad redo mismatch.' }
$null=$delete.Invoke($d,[object[]]@(1,3))
if ($get.Invoke($d,[object[]]@(0,3)) -cne 'acd') { throw 'Notepad delete mismatch.' }
"Notepad full managed: PASS, $($types.Count) types, document insert/undo/redo/delete"
"All full managed application conformance gates PASS."

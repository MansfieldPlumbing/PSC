# Roadmap

Measured 2026-11-08 on branch `condense-into-invoke-psc` (PSC `5238476`), Notepad branch
`psc-typed-model`, pwsh `515a49a`, kokoro-hexagon `6d88079`. Line and node counts are from SMA's AST through
`$api.ReadSource`; source measures are PSC's own (`PscMeasure`). Counts that group code by purpose are grouped by
function name and line range, and are approximate.

## 1. Notepad (ships first)

The app is to become `Invoke-Notepad.ps1`, compiled by `Invoke-PSC.ps1` to a NativeAOT `Notepad.exe`; a glue
script fetches both and the NuGet inputs, records the SHA-512 of each, compiles, runs the checks, and keeps a record
of inputs and measurements.

### State

| Measure | Value |
|---|---|
| Notepad.ps1 | 14,152 lines, 727,618 bytes, 75,193 AST nodes (before the model change) |
| Framework code in it | 10,600 lines; `Invoke-Design` alone 9,835 |
| Comparison and test tooling in it | 1,991 lines |
| Model, window, graphics | typed classes on `psc-typed-model`: `NotepadModel` and its records, `NotepadWindow` (Win32 imports, an `[UnmanagedCallersOnly]` window procedure), `NotepadGraphics` (Direct2D, DirectWrite and WIC through COM pointer stubs) |
| Interpreted runs | through PSC: `Invoke-PSC.ps1 -Mode Run -SourcePath Notepad.ps1 -RunParameters @{...}` fills the native stubs and callbacks just in time; run directly under pwsh, the first native call throws |
| Members lowering | 223 of 274 (native stubs included), every member of the classes; 25 of 89 before the model change |
| Interface state | `$ui` is `[NotepadUi]`; its colour picker, modal and dropdown are `NotepadColorPicker`, `NotepadModal` (`NotepadModalButton`) and `NotepadDropdown` (`NotepadOption`) |
| `-VerifyModel`, `-VerifyGraphics` | pass through PSC Run |
| 3-second UI run diagnostics | 24 of 24 entries equal to `main` except `ScrollX` `0` → `0.0` (one literal corrected in `Paint-Editor`); with the entrance animation on, the entrance completes |

### To a native Notepad.exe

1. Model, window and graphics as typed classes: done. Services module (78 lines) remains a `New-Module` object.
2. PSC lowering gaps remaining: `$MyInvocation` (the dot-source guards of the folded scripts); multi-element
   pipelines and cmdlets; nested script blocks; overload resolution with `[object]` arguments; `DateTime` minus
   `Nullable[DateTime]`; a parameter default that is not a constant.
   Closed: `foreach` over any value; indexing a string; optional parameters; `.Count` on an array; `[string]`
   and string `+` as PowerShell formats them; `@( )`, `$( )`, `@{ }`, statements as values; `-f`; text read by a
   type's `Parse`; `[ref]` arguments; closest overload; array conversion; `-match` family; rethrow; `$_.Exception`
   in a catch; throw of an exception value; `$null =`; expandable strings; conditions by static type; `Nullable`
   equality; `$null`/`$true`/`$false` defaults; `$MyInvocation.InvocationName`; a hashtable literal converted to a
   class; a number to `[bool]`; `$null` to `[string]` is `''` at every typed site.
   Known differences, lowered against SMA: an index past the end throws (SMA gives `$null`); Int32, Int64 and
   unsigned overflow throws (SMA moves to `Double`); exact integral division is `Double` (SMA keeps the integral
   type); a mixed signed and unsigned operation whose signed operand is not a non-negative constant is refused (SMA's
   type depends on the value); a `$null` passed by reflection into a `[string]` parameter stays `$null` (SMA gives
   `''`).
3. `-VerifyWindow` launches Notepad.ps1 directly and is to launch through PSC Run.
4. Notepad corrections, semantics preserved and checked by Notepad's own runs:
   - identities held in strings (`$ui.Hover`, `Pressed`, `Focus`, `Menu`, `Submenu`, `Nodes` keyed by string) to
     typed identities;
   - `$Event` untyped; 22 `$ui` slots untyped or written with two types (`EditorOrigin` `Double[]` and `Int32[]`);
   - `$settings` as a typed key table (8 accesses by run-time key; passed to `Invoke-Model`, `New-Module`, a
     `[hashtable]` parameter);
   - cmdlets on app paths (`Join-Path`, `Test-Path`, `Split-Path`, `Get-Content`, `Set-Content`).
5. Remove the in-app comparison page, its megaphone button, and the person button (it duplicates the gear).
6. One copy button: the selection when there is one, else the document; copy as file stays opt-in.
7. Move the comparison tooling and `-VerifyWindow` out of Notepad into PSC (section 2).
8. Glue script.
9. Measure which files PSC's linker reads from the 706 MB `msvc-*` folder; MSVC libraries have no NuGet package.

### Observed defects

- Status bar showed `Unix (LF)` for a new document; the model creates `Windows (CRLF)`.
- Caption buttons drawn twice (a stale frame under the current one), once.
- Title bar and caption buttons do not follow the edge during a live resize (frame loop shares the thread with the
  modal size loop).
- `WM_NCHITTEST` never returns `HTMAXBUTTON`, so Snap Layouts cannot appear.
- Type sizes, icon weights and the status bar differ from stock Windows Notepad.
- `Open-Modal`'s `[bool]$Input` parameter is shadowed by PowerShell's automatic `$input`: under SMA it is always
  `$true`, so every modal draws an input box and takes `dialog-input` focus. A lowered build would read the
  parameter's real value. Renaming the parameter changes the interpreted behaviour; not done.

### Features

Animation type setting (slide, fade, rise, none, turnstile); kinetic scrolling; tab reorder and tear-off; minimap;
virtual-file copy through reverse COM (`IDataObject` with `CFSTR_FILEDESCRIPTORW` / `CFSTR_FILECONTENTS`); an
integrated console (ConPTY to the installed pwsh, or SMA hosted on CoreCLR); an installer built on the same framework.

## 2. PSC capabilities to build

| Capability | Source |
|---|---|
| Framework parts selected by a typed `[Flags()]` enum on Compile; a part used without its flag is refused | Notepad, QuickPS |
| Composition layer (3D transforms, independent animation) | QuickPS `src\Composition.Windows.ps1` |
| Window capture | QuickPS `src\WindowCapture.Windows.ps1`, `src\Capture.Windows.ps1` |
| Window instruments: live-resize anchoring, minimum size, Snap Layouts hit test, maximize to work area, restore, minimize, Win+arrow snapping, backdrop | Notepad `Invoke-Window.Verify` |
| Comparison instruments: capture a reference app (UI Automation tree, region images, window attributes), drive it, compare as measurements; intended differences recorded as such | Notepad comparison tooling |
| Timing measurements: cold start to first frame, working set, frame time typing and resizing | none yet |
| Design system as types | Notepad `Invoke-Design` (9,835 lines of transcribed HTML/CSS) |
| Fluent controls: buttons, inputs, dropdowns, modals, tooltips, colour picker, four-corner gradient editor | Notepad app code |

## 3. To acquire from pwsh

`setup.ps1`: 9,448 lines, 222 functions, 77,993 AST nodes.

| Component | Lines | Functions (examples) | Into PSC as |
|---|---|---|---|
| Expression-tree kit, managed host generation | ~1,330 | `New-Clr*`, `Write-MicrosoftLambdaToMethodBuilder`, `Add-PersistedMethod`, `New-ManagedHostAssemblyBytes` | the host written as PowerShell classes, lowered by PSC |
| Machine code: Thumb-2, AArch64, x64, ARM32, with ABI tests | ~1,290 | `New-A64*`, `New-T32Step`, `New-X64Instruction`, `Test-*CallAbi`, `New-PslNativeLibrary*` | native back end |
| Android resources, binary manifest, validation | ~1,035 | `New-ResourceTable`, `New-BinaryAxmlManifest`, `Test-BinaryAxml` | Android target |
| ELF writer and reader | ~945 | `New-ElfCodeLibrary`, `New-ElfPayloadLibrary`, `Read-ElfImage` | object formats, beside COFF |
| Native host library | ~800 | `New-NativeHostLibrary` (527) | Android target |
| Text interface | ~770 | `Get-CanvasCells`, `Render-Canvas`, `Start-PipelineWorker` | UI framework |
| Acquisition | ~660 | `Get-GitObject` (smart HTTP), `Get-VerifiedPackageBytes`, `Assert-PackageIdentity`, `Get-FileSha512` | acquisition, shared with the glue script |
| APK: ZIP, deflate, CRC-32, signing | ~580 | `New-ApkArchive`, `New-SignedApk`, `Get-ApkContentDigest` | Android target |
| Assembly store | ~520 | `New-AssemblyStoreBytes`, `Test-AssemblyStoreBytes` | Android target |
| DEX writer | ~490 | `New-JavaPeerDex`, `ConvertTo-DexImage` | Android target |
| PE: ReadyToRun to IL-only, MVID, inspection | ~375 | `ConvertTo-IlOnlyImage`, `Set-DeterministicMvid` | PE tools (PSC already has `Set-DeterministicMvid`) |
| Steps, write plan, approval, help | ~480 | `Resolve-StepOrder`, `Resolve-WritePlan` | stays in `setup.ps1` |

Other pwsh sources: `modules\Console.psm1` (939 lines), `modules\AndroidCanvas.psm1` (1,042), `scripts\adb.ps1`
(1,535; adb client), `scripts\usbaoa.ps1` (474; USB accessory), `scripts\CellCanvas.ps1` (827),
`tools\Get-AssemblyClosure.ps1` (589), `scripts\commands\Parsers\*`.

## 4. To acquire from kokoro-hexagon

Source outside `build\` and `data\`: 109 scripts, 39,386 lines.

| Component | Where | Into PSC as |
|---|---|---|
| Hexagon instruction encoder, packets, emission | `Invoke-HexagonDevelopment.ps1` (`HexagonEncoder`, `Group-HexagonPackets`, `ConvertTo-HexagonAssembly`) | native back end, beside AArch64 and x64 |
| Kernel builders over expression trees | `tools\Kokoro.CaptureKernels.psm1` (`Get-Conv1dKernel`, `Get-MatrixApplyKernel`, ...) | kernels written as PowerShell, lowered by PSC |
| Numeric primitives: STFT and inverse, LSTM, attention, layer norm, convolution, quantization | `tools\Invoke-KokoroPrecomputedDecoder.ps1` | numeric library |
| Audio measurement: spectrogram, pitch, comparison, PNG and line plots | `tools\Kokoro.AudioMeasurement.psm1` | instruments for audio apps |
| PyTorch checkpoint reader | `src\runspace\Torch.Checkpoint.psm1` | data readers |
| Android audio, DSP queue layout, native binding | `src\runspace\Audio.AAudio.psm1`, `DspQueue.Layout.psm1`, `Native.Binding.psm1` | Android target |
| Device sessions over adb, resident jobs | `tools\Kokoro.Evaluator.psm1`, `Get-Adb` | one adb client, with pwsh `scripts\adb.ps1` |
| English phonemizer | `phonemizer\Invoke-EnglishPhonemizer.ps1` (4,220 lines, 34 classes) | stays an app; its build path uses PSC |

Not acquired: the Student (`student\Invoke-Student.ps1`, 5,582 lines) and anything shaped like stock Kokoro.

## 5. Triage

### kokoro-hexagon

- 109 source scripts against one script per project.
- `ScriptBlock.Create`: 12 (`src\jobs\Kokoro.Albert16Run.ps1` 10, `Invoke-HexagonDevelopment.ps1` 2).
- `Add-Type`: 1 (`student\Invoke-Student.ps1`).
- Hashtables used as records: 6,719 of 7,739 hashtable literals.
- Member lookups by text: 220. Commands named by a variable: 3,876; by another expression: 240. Regex uses: 157.
- Functions defined in more than one file: 10 names (`Get-Even` in 8 files).
- `build\` holds copies of other repositories: pwsh at `7398372` (including its `setup.ps1`) and PSC's earlier
  compiler (`Export-LoweredAssembly.ps1`, PSLowering), plus retained driver scripts of 5 to 7 MB.
- Terms: `Get-KokoroRatchetCase`, `Test-KokoroRatchet`, `Update-KokoroRatchet`, `Write-EnglishBuildReceipt`.
- Uncommitted changes in the working tree (`AGENTS.md` deleted; four files modified), not made in this session.

### pwsh

- 31 scripts against one script per project; `scripts\probes\canvas\Jni.ps1` and `scripts\probes\jni\Jni.ps1`
  are 376 lines each, defined twice.
- Functions defined in more than one file: 34 names.
- `ScriptBlock.Create`: 3. `Add-Type`: 1 (`setup.ps1`).
- Pinned, hash-verified addresses, where the direction is to record and compare, rolling forward.
- Terms: "receipt" in the README and `docs\receipt-*`.

### PSC

- Investigation: the third PSNES lowering pass throws `NullReferenceException` inside `-Mode Investigate` and not
  in a plain process.
- Refusals are positioned text, not records carrying the AST node.
- `Invoke-PSC.ps1` parses under `pwsh -NoProfile` only after `Import-Module Microsoft.PowerShell.Utility`.
- Classes PSC defines cannot be named by a caller after the script returns.
- `Add-PscFoldedScript` edits source text by offset; `PscAstRebuild` is the structural replacement.
- Type inference for records reaches SMA's internal `AstTypeInference` by reflection.
- Lowering refuses a class deriving from another class (adb.ps1 and PSC itself).
- `[string]` conversion of a `[bool]` is not lowered.
- `-join` with a typed array (`[double[]]`) on the left is refused.
- A parameter named `$Input` is not modelled: SMA's automatic `$input` overrides it inside the function; lowering
  reads the parameter. Admission should refuse or model it.
- A run-time `$null` of static type `[string]` (from a .NET call) assigned to a typed `[string]` stays `$null`
  lowered; SMA gives `''` (read from the lowering, not yet measured).
- SMA defect: `Copy()` of a `BaseCtorInvokeMemberExpressionAst` yields an `InvokeMemberExpressionAst`.

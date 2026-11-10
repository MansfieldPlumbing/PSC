# Roadmap

Measured 2026-11-08 on branch `condense-into-invoke-psc` (PSC `5238476`), Notepad branch
`psc-typed-model`, pwsh `515a49a`, kokoro-hexagon `6d88079`. Line and node counts are from SMA's AST through
`$api.ReadSource`; source measures are PSC's own (`PscMeasure`). Counts that group code by purpose are grouped by
function name and line range, and are approximate.

## 1. Notepad (ships first)

The app is to become `Invoke-Notepad.ps1`, compiled by `Invoke-PSC.ps1` to a NativeAOT `Notepad.exe`; a glue
script fetches both and the NuGet inputs, records the SHA-512 of each, compiles, runs the checks, and keeps a record
of inputs and measurements.

Order, set by Scott: a native Notepad.exe first (compile a script: item 8; the remaining refusals: items 2, 4, 9
and 10); the reusable Fluent framework (item 14) after it.

### State

| Measure | Value |
|---|---|
| Notepad.ps1 | 14,152 lines, 727,618 bytes, 75,193 AST nodes (before the model change) |
| Framework code in it | 10,600 lines; `Invoke-Design` alone 9,835 |
| Comparison and test tooling in it | 1,991 lines |
| Model, window, graphics | typed classes on `psc-typed-model`: `NotepadModel` and its records, `NotepadWindow` (Win32 imports, an `[UnmanagedCallersOnly]` window procedure), `NotepadGraphics` (Direct2D, DirectWrite and WIC through COM pointer stubs) |
| Interpreted runs | through PSC: `Invoke-PSC.ps1 -Mode Run -SourcePath Notepad.ps1 -RunParameters @{...}` fills the native stubs and callbacks just in time; run directly under pwsh, the first native call throws |
| Members lowering | 239 of 275 (native stubs included), every member of the classes; 25 of 89 before the model change |
| Interface state | `$ui` is `[NotepadUi]`; its colour picker, modal and dropdown are `NotepadColorPicker`, `NotepadModal` (`NotepadModalButton`) and `NotepadDropdown` (`NotepadOption`); hit-test nodes are `NotepadHitNode` (their `Data` is still `[object]`); settings are `NotepadSettings` (typed properties, `Get`/`Set` by run-time name); the palette is a `Dictionary[string,string]`; window events reach `Handle-Event` and `Key-Input` as `NotepadWindowEvent` |
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
   class; a number to `[bool]`; `$null` to `[string]` is `''` at every typed site; a number `-in` a list of numeric
   constants; `+` and `-` with a numeric `Nullable` when its `$null` and its value give one result type; `++` and
   `--` on a numeric `Nullable`; a call to a script function that writes exactly one value of one type is that
   type; a key a generic dictionary lacks reads `$null` when its value type holds `$null`.
   Refused because SMA's result type depends on the value: `+`/`-` with a `Nullable` whose `$null` and value give
   different types (`Nullable[double] + int` is `Int32` when `$null`); `*`, `/`, `%` with a `Nullable`.
   Known differences, lowered against SMA: an index past the end throws (SMA gives `$null`); Int32, Int64 and
   unsigned overflow throws (SMA moves to `Double`); exact integral division is `Double` (SMA keeps the integral
   type); a mixed signed and unsigned operation whose signed operand is not a non-negative constant is refused (SMA's
   type depends on the value); a `$null` passed by reflection into a `[string]` parameter stays `$null` (SMA gives
   `''`); a key a generic dictionary with a non-nullable value type lacks throws (SMA gives `$null`).
3. `-VerifyWindow` launches Notepad.ps1 directly and is to launch through PSC Run.
4. Notepad corrections, semantics preserved and checked by Notepad's own runs (the 3-second run's `Generation`
   counts frames and varies with timing: 9 in one of four runs where the others gave 7):
   - a command's data (`NotepadHitNode.Data`, `Command`'s `$Data`) as typed records: text, a tab or palette index,
     a dropdown, a modal button, a setting choice;
   - identities held in strings (`$ui.Hover`, `Pressed`, `Focus`, `Menu`, `Submenu`, `Nodes` keyed by string) to
     typed identities;
   - `$ui` slots still untyped (`OpacityTrack`, `TextCache`, `IconCatalog`, `Expanded`) and `@( )` arrays used as
     tuples (menu entries, find buttons, colour roles);
   - cmdlets on app paths (`Join-Path`, `Test-Path`, `Split-Path`, `Get-Content`, `Set-Content`).
5. In-app comparison page, megaphone and person buttons: removed. The copy and writing-tools buttons moved right
   into the space.
6. One copy button: the selection when there is one, else the document; copy as file stays opt-in.
7. Comparison: `Invoke-NotepadComparison` (`-Compare`) and `-VerifyWindow` stay in Notepad as they are. PSC gains
   general primitives in their place, usable for any app it builds: UI Automation queries of a running window,
   window and frame captures, pixel and geometry measurement, input replay, and comparison of the same against a
   reference app. They serve the planned ports of HTML/TypeScript/JavaScript apps and the Photos, Paint and
   Terminal counterparts as much as Notepad.
8. Compile a script, not only classes. Notepad's 28 classes compile together into one assembly (58,368 bytes,
   2026-11-09). What remains, in order:
   - The function class: Compile already folds the script's functions into one class (`Notepad`) when
     `-ClassNames` lists it, but `-ClassName` must name a class written in the source, and the functions must
     lower (36 refused today).
   - The entry point: the script's top-level statements as `Main(string[])`, its `param()` block bound from the
     command line as PowerShell binds a script's parameters (named, positional, switches, `ValidateSet`), script
     variables as the function class's static fields.
   - Development-only code (the Verify functions, `Invoke-NotepadComparison`, `-Compare`, `-DiagnosticPath`)
     out of the native build. Proposed: the build fixes those switches to their defaults as compile-time
     constants, the branches they guard are pruned, and functions no longer reachable from the entry point are
     not compiled. Scott to decide.
   - `Invoke-Design`'s `data { }` section: a data section admits only literals, so it lowers as the hashtables and
     arrays it builds (static data today takes only numbers, strings and their arrays).
   PSC's Compile mode takes classes; a script's function class, its script
   variables and its top-level statements (the entry point) are lowered member by member by Investigate but not
   yet emitted into an assembly. Development-only code (`Invoke-NotepadComparison`, the Verify functions) is to be
   left out of the native build.
9. No JSON in the app. NativeAOT cannot load an assembly or generate code at run time (Microsoft's Native AOT
   limitations), so settings cannot live in a managed assembly the app rewrites. Defaults (the default settings, the
   palette, the design's declarations) are compiled into the exe as static data: the lowering of `Invoke-Design`'s
   `data { }` section. Settings are `config.ini` beside the program: every setting listed, the changed ones as
   `key=value` and the rest commented out as `;key=value`, so only changes take effect and new defaults reach
   untouched settings; `[Colors]` and `[AnsiColors]` sections entry by entry. A missing file is all defaults. The
   session (open tabs) is `session.bin` in the user's application data (`BinaryWriter`/`BinaryReader`). Done in
   Notepad; JSON remains only in the development diagnostics dump, which stays until the UI Automation primitives
   (item 7) read the running app instead, and is left out of the native build. PSC is to lower `$PSScriptRoot` to
   `AppContext.BaseDirectory`, the program's directory.
10. Cmdlets in app code lower to .NET (`Join-Path`, `Test-Path`, `Get-Content`, `Set-Content`, `New-Item`,
    `Start-Sleep`, `Where-Object`, `ForEach-Object`, `Select-Object -First`), bound by SMA's `StaticParameterBinder`,
    each checked against SMA. SMA itself cannot be in a NativeAOT image (it depends on reflection).
11. Reverse COM: interfaces implemented by the app as vtables of `[UnmanagedCallersOnly]` function pointers (NativeAOT
    has no built-in COM). `IDropTarget` with `RegisterDragDrop` for dropping files (UTF-8, UTF-16) onto the window
    and its tabs; `IDataObject` for virtual-file copy (`CFSTR_FILEDESCRIPTORW`/`CFSTR_FILECONTENTS`) and tab tear-off.
    OLE needs `OleInitialize` on the window's single-threaded apartment.
12. Glue script, and an installer. A per-user install (under the user's `AppData\Local\Programs`) keeps
    `config.ini` beside the exe writable; under Program Files it is not. The installer puts the files in place and
    registers the program as a handler for `.txt` and `.md`; the choices are Notepad's own.
13. First run, in the manner of Windows' out-of-box experience: on its first launch Notepad asks one thing, once
    (recorded in `config.ini`): whether it should open `.txt` and `.md`. It is opt-in; a yes opens Windows 11's
    Default apps settings page, where the user confirms, since an app cannot set the default itself, as Scott
    observed. Whether the page can open on Notepad's own entry through an `ms-settings:defaultapps` query is to be
    checked. Everything else is left to Settings, with defaults of a solid backdrop and a fade-in entrance, as stock
    Notepad has.
13. Measure which files PSC's linker reads from the 706 MB `msvc-*` folder; MSVC libraries have no NuGet package.

14. The Fluent layer as a framework other apps reuse (a download manager over .NET, the Photos, Paint and Terminal
    counterparts, Android). Today its parts live in Notepad.ps1 and read Notepad's script state: the controls
    (`Button`, `InputBox`, `Select-Control`, `Toggle-Control`, menus, the modal, the colour picker, the four-corner
    gradient), hit testing (`NotepadHitNode`), theming (the palette from the design's CSS), the window
    (`NotepadWindow`) and drawing (`NotepadGraphics`). To be reused they become typed classes that take what they
    draw on, the theme and the input state as arguments instead of reading `$ui`, `$settings`, `$graphics` and
    `$palette`; drawing and windowing sit behind contracts that Direct2D and Win32 implement on Windows and another
    backend implements on Android. Decided by Scott: the framework lives in PSC and is compiled into an app that
    asks for it, under a flag. It is PowerShell classes in Invoke-PSC.ps1; SMA must see them as it sees the app's
    own (in a Run, defined before the app runs; in a Compile, its class definitions join the app's source before
    lowering), so an app written against them parses, runs interpreted and compiles alike. The framework is general:
    nothing in it names Notepad. Scott also intends simulacra of Material and Metro, so the core (layout, hit
    testing, input, animation, drawing and windowing contracts) belongs to no design language; Fluent, Material and
    Metro are design languages over it (their controls' look, metrics, motion and theme). First piece: theming (the palette and colour lookup), hit testing (the node and its
    collections) and `Button`, each a framework class taking its surface, theme and input state as arguments;
    Notepad then uses them, checked by its own runs (model, graphics, diagnostics equal). The other controls, the
    window and drawing follow. Order, set by Scott: after a native Notepad.exe.
15. Acrylic in an unfocused window. DWM's system backdrops (`DWMWA_SYSTEMBACKDROP_TYPE`, which Notepad uses) fall
    back to a solid colour when the window is inactive. Windows Terminal keeps acrylic unfocused
    (`compatibility.enableUnfocusedAcrylic`): its terminal background is a XAML `AcrylicBrush`, `HostBackdrop`
    while focused and `Backdrop` while unfocused (microsoft/terminal PR #15923); its tab row still loses acrylic
    (issue #19544, reopened April 2026). Notepad has no XAML. Its candidates, to be measured before choosing: a
    Windows.UI.Composition visual tree on the window (`ICompositorDesktopInterop`, a backdrop brush and a blur
    effect: the mechanism XAML's brush is built on), or the undocumented `SetWindowCompositionAttribute` accent.

### Observed defects

- Status bar showed `Unix (LF)` for a new document; the model creates `Windows (CRLF)`.
- Caption buttons drawn twice (a stale frame under the current one), once.
- Title bar and caption buttons do not follow the edge during a live resize (frame loop shares the thread with the
  modal size loop).
- `WM_NCHITTEST` never returns `HTMAXBUTTON`, so Snap Layouts cannot appear.
- Type sizes, icon weights and the status bar differ from stock Windows Notepad.

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

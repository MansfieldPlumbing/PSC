# PSC

PSC is a single-file compiler and semantic development environment for typed PowerShell/SM source. It emits deterministic managed assemblies without an SMA runtime dependency for admitted code, links native Windows PE images, and directly emits verified x64 ELF leaf libraries. No SDK or project file is needed for managed compilation.

**Start here:** PowerShell 7.7 / .NET 11, Git, and `PSC.ps1`. `Invoke-PSC.ps1` is the legacy entry point.

```powershell
$api = & ./PSC.ps1                       # Describe PSC, without compiling
$api.Describe('Compile').Parameters       # Live command contract
$dev = $api.OpenDevelopment('./psc-tree') # Project the canonical source
& ./PSC.ps1 -SourcePath ./psc-tree/SM/Calibration.sexe -Program -OutputPath ./Calibration.dll
```

`Calibration.dll` is a managed program, not a native executable. The embedded SM fixture exercises its entry point. `-Native` adds the existing Windows NativeAOT/COFF pipeline; `NativeCil` is the separate, currently leaf-only native path.

## Source formats

| Extension | Role | Analogue | Intent |
|---|---|---|---|
| .sm1 | Script | .ps1 | Independent executable source |
| .srm1 | Script Resource Module | .psm1 | Reusable behavior, contracts, types and resources |
| .sexe | Script Executable | .exe | One-shot executable appliance before realization |

The extension describes intent, not executable eligibility. PSC is the realization authority; stock `pwsh` execution is not a requirement. Direct SMA-free one-shot launch through PSC is a target, not an implemented feature. `Run` currently executes through SMA as a reference path.

## Find, inspect, edit, conform

The canonical source is `PSC.ps1`. The worktree is a disposable, ordered AST projection, including embedded SM sources and tests. Do not maintain a competing source tree.

| Tool | Responsibility |
|---|---|
| `git grep -n -F -- 'ConvertTo-PscIr' PSC.ps1` | Literal text in tracked source |
| `rg -n -F -- 'Apply' ./psc-tree` | Literal text in the projected worktree |
| `$api.Find('ConvertTo-PscIr')` | Named AST declarations |
| `$api.Search('PersistedAssemblyBuilder')` | AST declaration extents containing literal text |
| `git log -p -- PSC.ps1` | Committed history |

```powershell
$q = $api.Find('ConvertTo-PscIr')
try { $q.Pull(10); $q.Coverage() } finally { $q.Dispose() }
$api.Describe('Guard').DispatchExtent.Text
$api.Guide()
```

Query returns typed witnesses with source identity, owner, extent and coverage. Pull in windows of 1..256; dispose cursors. Literal containment includes comments and strings inside a declaration, not proof of binding. Use `$dev.Find('Apply')` or `$dev.Search('literal')` to include projected resources; canonical queries do not parse embedded source strings. `OpenQuery` supports explicit paths, owner, kind and limit, including non-loading CIL inspection for binary queries.

A read-only query witness can become an edit witness only through exact source/extent validation (`$doc.Resolve($hit)`). A document's own `Find` returns revision-bound editable witnesses directly. Example, using a behavior-preserving numeric-literal edit in the projected calibration resource:

```powershell
$doc = $dev.OpenDocument('SM/Calibration.sm1')
$hit = $doc.Find('Declaration','Apply','SmCalibrationProvider',1)[0]
$doc.Replace($hit, $hit.Target.Extent.Text.Replace('4.0 + 1.25','4.0 + 1.250'))
$doc.Undo()
$doc.Redo()
$doc.Save()
$dev.Changes()
$dev.Affected()
$dev.Collate('./PSC.next.ps1')
$receipt = $dev.Conform($true)
$receipt.Stages | Select-Object Name,State,ExitCode
```

External edits to projected files are also supported. Start with a clean Git baseline and a new or matching projection. Collate needs a fresh candidate destination and rejects missing/untracked units and changed declaration boundaries. Additions, deletions and renames still require explicit canonical edits. Affected reports declared faculty dependencies, not exhaustive semantic or test coverage. No tests are omitted based on Affected.

Conform runs the protected Guard against committed source, the candidate API, projection and embedded regressions. `true` selects development scope and skips historical Windows verification (`Complete = False`); `false` requests the full suite and requires its native toolchain. Review the receipt before explicitly promoting the candidate. Use `git diff -- PSC.ps1`, commit the reviewed change, verify HEAD, then open a fresh projection. Never silently change protected checkers. See [AGENTS.md](AGENTS.md) for engineering requirements.

## Compiler and runtime

- **Managed:** SMA AST and typed expression lowering, deterministic IL emission, static graph/data realization, reachability and fixed-parameter specialization.
- **Native:** pinned Windows NativeAOT compiler plus PSC COFF linker; direct CIL-to-IR-to-x64 ELF leaf emission and decoded-byte ABI checks. The direct backend does not yet replace ILC for general programs.
- **Faculties:** `Vom` (Virtual Object Model), `InquiryPrimitives`, `ScriptType`, `PrimitiveConversion`, `ObjectDispatch`, `NativeEncoding`, `ElfEncoding`. Build with `-Mode BuildRuntime`. Structural contracts can be erased at build time or retained as typed descriptors with revocable role bindings.
- **Evidence:** differential tests, structural lint, Guard, non-loading binary queries and coverage. An observed call is not a universal binding proof; an ABI check is not a proof of arithmetic equivalence.

## Trust and security

PSC authoring requires a trusted PowerShell session with the required language capabilities. It uses reflection, metadata readers, assembly emission and native interop openly. Do not bypass AMSI, Defender, App Control or execution policies. Follow local signing and deployment policy. Only compile or execute trusted source; conformance runs candidate code and is not a sandbox. Use trusted assemblies for CIL import/compilation and trusted data for `FixedParametersPath` and `ProfilePath`. Query is the non-loading metadata inquiry path for supported binaries. Determinism and SHA-256 identify artifacts; they do not establish publisher trust or safety.

Microsoft guidance: [script injection](https://learn.microsoft.com/en-us/powershell/scripting/security/preventing-script-injection), [PowerShell security](https://learn.microsoft.com/en-us/powershell/scripting/security/security-features), [unsafe deserialization](https://learn.microsoft.com/en-us/dotnet/standard/serialization/binaryformatter-security-guide).

## Live reference

```powershell
$api.AssertSurface()
$api.Modes
$api.Parameters
$api.Measures
$api.Functions
$api.Classes
$api | Get-Member
& ./PSC.ps1 -Mode Capability
```

The API is derived from the running script, so mode names and parameter evidence do not depend on a previous session's notes. Use `Describe(mode)` for dispatcher extents and associated definitions. CLI inventory below is generated; source hash, local paths, runtime and measurement values are available from the live API rather than frozen into the README. Regenerate with `& ./PSC.ps1 -Mode Readme`.

<details>
<summary>CLI modes, parameters and dispatcher calls</summary>

| Mode | Parameters | Calls |
|---|---|---|
| Api |  | Get-PscApi |
| Edit | SourcePath |  |
| UnCollate | SourcePath, TreeDirectory | New-PscSourceTree |
| Collate | OutputPath, TreeDirectory | Write-PscSourceTree |
| Status | SourcePath, TreeDirectory | Read-PscSourceTree |
| Diff | SourcePath, TreeDirectory | Compare-PscSourceTree |
| BuildFaculty | ContractInputsPath, ContractPaths, ContractReferences, Faculty, RuntimeDirectory | Build-PscFaculty, Read-PscContractInputs |
| BuildRuntime | ContractPaths, ContractReferences, RuntimeDirectory | Build-PscRuntime |
| Query | QueryKind, QueryLiteral, QueryName, QueryOwner, QueryOwnerHandle, QueryPath, QuerySpace, QueryTake |  |
| PowerShell | ArchivePath | Get-PinnedPowerShell |
| Compile | ClassName, ClassNames, DeclarationsOnly, Deterministic, EntryPoint, FixedParameters, FixedParametersPath, LeasedStructuralContracts, MethodNames, Native, OutputPath, Program, SourceAst, SourcePath, StaticData, StructuralBindings, StructuralThunks, Subsystem | ConvertTo-PscLeasedStructuralSource, ConvertTo-PscStructuralSource, Export-LoweredAssembly, Export-NativeImage, New-PscStructuralThunkSource, Read-PowerShellSource |
| Expression | MethodAst | ConvertTo-TypedExpression |
| AnalyzeCilIr | AssemblyPath, ClassName, MethodNames | Import-PscCilAssembly |
| VerifyNativeLeaf | AssemblyPath, NativeBorrowedCell, NativeFloatArguments, NativeFrameBytes, NativeIntegerArguments, NativeReturnKind, RuntimeDirectory | Test-PscX64LeafAbi |
| NativeCil | AssemblyPath, ClassName, Deterministic, MethodNames, NativeBorrowedCell, OutputPath | Import-PscCilAssembly |
| ImportCilIr | AssemblyPath, ClassName, Deterministic, MethodNames, OutputPath | Import-PscCilAssembly |
| ImportCil | AssemblyPath, ClassName, Deterministic, MethodNames, OutputPath | Import-PscCilAssembly |
| Inspect | AssemblyPath, ClassName, MethodNames | Test-LoweredAssembly |
| Capability |  | Get-LoweringCapability |
| Graph | ProjectPath | Get-SmaGraph |
| Lint | LintEdit, LintFiles, LintObjects | Edit-SmaLintFinding, Get-Projects, Get-SmaLint |
| Guard | AgainstPath, CheckerHash, LintFiles | Test-PscCandidateGuard, Test-SmaGuard |
| Profile |  | Invoke-SmaProfile |
| Report | ProfilePath | Get-SmaReport, Get-SmaUnits |
| Verify |  | Test-SmaGraph |
| Conform | AgainstPath, CheckerHash, DevelopmentOnly, SourcePath | Invoke-PscConformance |
| Consolidate | OutputPath, SourcePath | ConvertTo-PscSingleScript |
| Investigate | InvestigatePath | Invoke-PscInvestigation |
| Records | SourceAst | Get-PscRecord |
| Run | RunParameters, SourceAst, SourcePath | Invoke-PscRun |
| Readme |  | ConvertTo-PscReadme, Get-PscApi |
| Link | DefaultLibrary, EntrySymbol, LibraryDirectory, LinkInput, LinkMerge, NoDefaultLibrary, OutputPath, ResolveOnly, StackReserve, Subsystem | Resolve-CoffLink, Write-CoffImage |

</details>

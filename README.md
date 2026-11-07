# PSC

PSC compiles typed PowerShell classes to .NET assemblies and to Windows x64
Native AOT executables. The compiler is one PowerShell script, `Invoke-PSC.ps1`.

## How PSC lowers

1. SMA's parser parses the source. Statement keywords the source declares are
   registered with the parser first (see [Compiled language](#compiled-language)).
2. The classes to compile become a class model, and mirror types are defined so
   member and type references resolve before IL exists.
3. Each method's AST is lowered to a typed LINQ expression tree. Constructs
   outside the compiled language are rejected here, with their source position.
4. PSC's IL emitter writes each expression tree as a method body into a
   `PersistedAssemblyBuilder` assembly, which is saved deterministically.
5. With `-Native`, ILC compiles that assembly to one COFF object, and PSC's COFF
   linker links it with the Native AOT runtime and the Windows import libraries
   into a PE32+ executable.

Compiled output references no `System.Management.Automation` type. Its assembly
references are `System.Private.CoreLib` and the BCL assemblies the source calls.

The same pipeline serves three uses:

- **Helpers**: individual typed methods (kernels, contracts, conversions)
  compiled to an assembly that a PowerShell process loads and calls through
  reflection or delegates.
- **Hot loops**: methods that run per frame or per sample, compiled to IL so the
  loop runs as JIT-compiled code instead of in the PowerShell interpreter, or
  compiled into a native executable.
- **Appliances**: a whole PowerShell script whose classes and static entry
  method form a program, compiled with `-Native -EntryPoint <method>` to a
  Native AOT executable. The executable contains the Native AOT runtime and the
  program's code. Its import table names only Windows system DLLs and the
  Universal C Runtime API sets (`api-ms-win-crt-*`); it imports no .NET host or
  PowerShell library.

Not yet complete: a single-file JIT executable. `-EntryPoint` without `-Native`
writes an assembly and its `runtimeconfig.json`, which run with
`dotnet exec <name>.dll`.

## Invocation

`& ./Invoke-PSC.ps1` with no arguments returns a `PSC.Api` object read from the
script's own AST: each mode, the script parameters that mode's operation reads
(including parameters bound through a splatted call), their types, defaults,
allowed values and help, and the functions each mode calls. `-Mode Api` returns
the same object. `-Help` returns the comment-based help.

| Mode | Returns |
|---|---|
| `Compile` | The compilation record. Inputs: `SourcePath` or `SourceAst`, `ClassName`, `ClassNames`, `MethodNames`, `StaticData`, `OutputPath`, `EntryPoint`, `Deterministic`. With `-Native` and `EntryPoint`: the lowered assembly's record and the native image's record. |
| `Expression` | The typed expression of one method, with a live `Lambda`. Input: `MethodAst`, also from the pipeline. |
| `Inspect` | The metadata of a compiled assembly. Input: `AssemblyPath`. |
| `Capability` | Compiler identity and source SHA-256, PowerShell and runtime versions, and the semantic and dependency contracts. |
| `Link` | COFF symbol resolution and, unless `-ResolveOnly`, a PE32+ image. Inputs: `LinkInput`, `LibraryDirectory`, `DefaultLibrary`, `NoDefaultLibrary`, `EntrySymbol`, `LinkMerge`, `Subsystem`, `StackReserve`, `OutputPath`. |
| `PowerShell` | The path of PowerShell 7.7.0-preview.5 `pwsh.exe` beneath `build/cache`. The release archive is downloaded on first use (or read from `ArchivePath`) and checked against its published SHA-256 before extraction. |
| `Describe` | One PowerShell project as live objects from SMA's parser: units, edges, coverage, absence and changes. Input: `ProjectPath`. |
| `Lint`, `Profile`, `Report`, `Verify` | Findings over PowerShell files (by default every project beside this repository's folder), a profile of every project's functions and methods, a report on a stored profile (`ProfilePath`), and the description's structural fixture. |

`Compile` is the default mode whenever arguments are given.

## Compiled language

Every class in the source is compiled into one assembly; `ClassNames` selects
a subset. Supported:

- typed properties as public fields, with initial values (static properties in
  the type initializer, instance properties before each constructor body);
  constructors with typed parameters; static and instance methods with typed
  parameters and returns, including `[void]`; `$this`
- typed locals, assignment as an expression, compound assignment, `++` and `--`
  on variables, fields, properties and array elements
- arithmetic, comparison and Boolean operators on operands of one type, string
  concatenation with `+`, `-band`, `-bor`, `-bxor`, `-bnot`, `-shl`, `-shr`
- string membership tests over typed string arrays
- `if`/`elseif`/`else`, `while`, `for`, `foreach` over a typed one-dimensional
  array, `break`, `continue`, early `return`
- `switch` over an integer or enum value with constant clauses, and `switch`
  whose clauses are script-block predicates over the current value
- typed arrays: creation, literals typed by their target, negative indexes from
  the end, element assignment, `Length`
- indexing through a .NET default indexer: integer-indexed collections and keyed
  collections
- calls to .NET static and instance methods, properties, fields, constants and
  constructors, bound by signature, including static generic methods whose type
  arguments are inferred structurally from the argument types
- value-type receivers addressed in their own storage (local, argument, field,
  array element), so calls and stores on a struct reach the struct
- `throw` of a string, of a constructed CoreLib exception, `try`/`catch`/`finally`
- native imports: a static method marked
  `[System.Runtime.InteropServices.LibraryImport('library', EntryPoint = 'name')]`
  whose body is a single `throw` compiles to a P/Invoke method; indirect calls
  through unmanaged function pointers and native callbacks are described in
  [the native interop contract](docs/native-interop.md)
- statement keywords declared by the source: a static method marked
  `[Keyword()]`, where `Keyword` is an attribute class in the same source, is
  registered with SMA's parser as a `DynamicKeyword` before the source is parsed
- typed primitive, string and array values supplied through `StaticData` as
  static initialization

Rejected before any assembly is written, with line, column and reason:
commands and pipelines; script blocks outside `switch` predicates and keyword
bodies; `do`; `switch` with options or over a string subject with constant
clauses; labeled `break` and `continue`; `break` or `continue` outside a loop;
`foreach` over anything but a typed one-dimensional array; operators on mixed
operand types; classes deriving from anything but `System.Object`; untyped
properties and parameters; base constructor calls with arguments; rethrow;
throwing a variable, an `ErrorRecord` or a non-string literal; catch blocks that
depend on `RuntimeException`, `$_` or `$Error`; uninferable or conflicting
generic type arguments. Nothing falls back to running the PowerShell source.

## Semantics

- Integral `+`, `-`, `*`, `++`, `--` and negation are checked and throw
  `OverflowException`. PowerShell widens the intermediate result and then fails
  converting it back to the declared type, so both throw, with different
  exception types.
- Integral `/` divides as `Double`: `7/2` is `3.5`, and `4` when returned as
  `[int]`. Division by zero throws.
- Floating-point to integral conversion rounds half to even and throws when out
  of range or NaN. Integral narrowing, including integral to `[char]`, throws on
  overflow.
- String `-eq`, `-ne`, `-lt`, `-le`, `-gt` and `-ge` compare with the invariant
  culture, ignoring case unless the operator is case-sensitive (`-ceq` and so on).
- `throw` of a string throws `InvalidOperationException` with that message.
  PowerShell throws `RuntimeException`.

Known differences from interpreted PowerShell:

- An integral expression that overflows but is never stored in or returned as a
  typed value throws in compiled code; PowerShell continues with a `Double`.
- Reading a missing key through a keyed indexer throws `KeyNotFoundException`;
  PowerShell returns `$null`.

## Native executables

`Compile -Native -EntryPoint <method>` lowers the classes to an assembly beside
the executable, compiles it to one COFF object with ILC, and links that object
with the Native AOT runtime and the Windows import libraries in PSC's own COFF
linker. It writes `<name>.dll`, `<name>.runtimeconfig.json`, `<name>.ilc.rsp`,
`<name>.obj` and `<name>.exe`. The image's entry symbol is `wmainCRTStartup`;
`ucrt.lib` is its default library; its stack reserve is 1.5 MiB; `Subsystem` is
`Console` or `Windows`.

The toolchain is read from `NativeAOT/`, which Git ignores, taking the newest
folder of each kind:

| Folder | Contents | Hash manifest |
|---|---|---|
| `ilc-11.0.0-preview.6.26359.118` | ILC | `pin.sha256.csv`, verified on use |
| `ilc-build-11.0.0-preview.6.26359.118` | ILC build files | `pin.sha256.csv`, verified on use |
| `nativeaot-win-x64-11.0.0-preview.6.26359.118` | Native AOT runtime | `pin.sha256.csv`, verified on use |
| `windows-sdk-lib-10.0.26100.0` | Windows SDK import libraries | `pin.sha256.csv`, verified on use |
| `msvc-14.51.36223` | MSVC libraries | none; not verified |

The lowered assembly is compiled against the runtime PowerShell is running on;
ILC and the Native AOT runtime are 11.0.0-preview.6.

## Verification

`tests/Test-ConsolidatedRunner.ps1` runs 23 suites, each in its own process:

| Suite | Verifies |
|---|---|
| `tests/Test-OneParameterPersistence.ps1`, `tests/Test-TwoParameterPersistence.ps1`, `probes/Test-SmaCompilation.ps1` | the expression trees SMA's own compiler produces, as a comparison baseline |
| `tests/Test-Slice1.ps1` | signatures and constants; a copied compiler in an unrelated directory; deterministic output; `Compile`, `Expression`, `Inspect`, `Capability` |
| `tests/Test-Slice2.ps1` … `tests/Test-Slice8.ps1` | parameters, locals and arithmetic; IEEE 754 and Boolean logic; control flow; typed arrays; reflected calls and constructors; structured exceptions |
| `tests/Test-Slice9.ps1` | a range-checked index contract over every input 1–510 and the `Int32` extremes |
| `tests/parity/LambdaCompilerParity.ps1` | the same expression trees compiled by `LambdaCompiler` give the same results |
| `tests/Test-ZeroSmaHost.ps1` | output loads and runs in a process without SMA; its only reference is `System.Private.CoreLib` |
| `tests/parity/PowerShellParity.ps1` | each fixture method run as PowerShell and as IL on the same inputs |
| `tests/consumers/Test-PwshAdmission.ps1` | output passes an external persisted-method admission check, pinned by commit and SHA-256 |
| `tests/Test-DotnetHost.ps1` | a program compiled with `-EntryPoint Main` runs under `dotnet exec` with no PowerShell assembly loaded |
| `tests/Test-Rejections.ps1` | each rejected construct is refused with its diagnostic and no output |
| `tests/Test-NativeImports.ps1` | native imports call the native function with the declared marshalling |
| `tests/Test-ConversionBoundary.ps1` | conversion semantics at type boundaries |
| `tests/Test-SingleFileArchitecture.ps1` | one implementation script, no loaders, and every mode run from a copy in a fresh process |
| `tests/Test-NativeInterop.ps1` | unmanaged function pointers and native callbacks, with signature metadata checks |
| `tests/Test-PortableSimd.ps1` | static generic call inference and struct receivers, compared bitwise with PowerShell |
| `tests/Test-LegacyReproduction.ps1` | 52 historical outputs rebuilt byte-identical (SHA-256, MVID, assembly references) to the [`218f54e` baseline](tests/baseline/README.md), 13 exact diagnostics, and two negative controls that must fail |

Measured at `ee73e9c` on PowerShell 7.7.0-preview.5 / .NET 11.0.0-rc.1.26425.128
(Windows x64, 2026-11-07): 23 of 23 suites passed; PowerShell parity 300 calls
with 0 divergences; LambdaCompiler parity 19 methods; rejections 15 cases;
portable SIMD 96 comparisons; reproduction 52 outputs and 13 diagnostics.

The suites run on that PowerShell and runtime only: `-Mode PowerShell` provides
the PowerShell, and the dotnet-host suites need the standalone runtime
11.0.0-rc.1.26425.128 on `PATH`. The repository has no CI workflow.

Not covered by any suite: `-Native`, `Link`, `Describe`, `Lint`, `Profile`,
`Report`, `Api` and `PowerShell`. `tests/Test-LoweringParity.ps1`, which runs
fixture methods interpreted and lowered in a child process, is not in the runner.

## Repository layout

- `Invoke-PSC.ps1`: the compiler.
- `NativeAOT/`: the pinned Native AOT toolchain (ignored).
- `tests/`: suites, fixtures, parity checks and the runner.
- `tests/baseline/`: the frozen `218f54e` outputs and diagnostics.
- `docs/`: the native interop contract.
- `experiments/`: the earlier approach, which persists the expression trees
  SMA's own compiler produces; its output depends on SMA at run time.
- `probes/`: runtime observation.
- `build/`: generated output and the pinned PowerShell and runtime (ignored).

## License

[MIT](LICENSE)

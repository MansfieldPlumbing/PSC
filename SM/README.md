# SM — Semantics Management (exploratory)

These are experiments within PSC, not a separate compiler, package system or grammar. PSC.ps1 remains the authoritative production source. The `1` suffix identifies the source-format generation, not the execution backend.

## Why three source formats?

| Format | Role under investigation | Concrete experiment |
| --- | --- | --- |
| `.sm1` | Executable semantics, with independently declared runtime requirements | `Calibration.sm1` runs in stock Pwsh and compiles through PSC; `CalibrationClient.sm1` needs the compiled ScriptType faculty and its VOM-published role. |
| `.srm1` | Script Resource Module: semantic declarations, reusable contracts, resources and potentially executable faculties | `Calibration.srm1` is consumed by PSC's existing contract authoring path. Its required operation becomes a typed descriptor in ScriptType.dll, without emitting or executing the contract's placeholder class. |
| `.sexe` | Self-contained application translation unit, with entry parameters and realization policy | `Calibration.sexe` builds as a parameterized program; fixing Presentation specializes its entry interface. A scalar kernel from the same source can also be acquired and emitted as a native shared library. |

The file role does not establish parser compatibility or runtime independence. Both `.sm1` examples use existing SMA grammar. One runs without additional types; the other requires PSC-built types, not a new parser. A compiled client and catalog do not reference SMA. The runtime assemblies are still managed assemblies.

An SRM contract is a declaration of an operation, not an implementation of it: a provider compiled from `.sm1` supplies the behavior, and VOM controls the lifetime of its realization. The fixture explicitly publishes the role; there is no automatic module loader or import syntax. The two source types do not need a nominal inheritance relationship. The resource and provider can therefore be acquired independently.

A `.sexe` is source, not a PE/ELF image. The fixture produces managed application images using `-Program`, plus an import-free Linux x64 native leaf using `NativeCil`. It does not claim a standalone PSC-native application or that a native compiler DLL already exists. The existing NativeAOT executable target remains available separately.

## Reproduce

PowerShell 7.7 / .NET 11:

```powershell
pwsh -NoProfile -File ./SM/Test-Formats.ps1
```

The test builds seven runtime faculties in a new temporary directory, materializes the SRM contract, compares the portable script and its compiled entry point, exercises a published and revoked role, tests application specialization, and checks native kernel results on Linux x64. It cleans temporary outputs on exit. Other targets skip native loader execution rather than reporting parity without execution.

`PSC.ps1 -Mode Query` admits `.sm1`, `.srm1` and `.sexe` as source candidates using the existing parser and extent witnesses. This is intentionally an inquiry change only; legacy Graph, Lint and Investigate discovery policies remain unchanged. There is no automatic inference of compilation mode from the extension and no extension-based semantic restriction yet.

## Development criteria

Extend a format when it exposes a semantic requirement not represented by the current compiler: resource identity and composition, explicit bootstrap requirements, or application realization and specialization. Do not duplicate the compiler to implement those roles. Prefer executable comparisons, including absent-capability and withdrawal cases, over new grammar or naming alone.

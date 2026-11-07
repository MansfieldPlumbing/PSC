# PSC

| Synopsis | Script | SourceSha512 | DefaultMode |
|---|---|---|---|
| A Pwsh script designed to amortize. | C:\dev\psc\Invoke-PSC.ps1 | 5AA4F907BD4AFA4F186FDE8681DA68756A832C0FFD4121FBBCC40CABE6A7D8A4CAA8C406B2D30D20F047434B60DD18B3B4DF1893A54336F011102800AA39A573 | Compile |

## Modes

| Mode | Parameters | Calls |
|---|---|---|
| Api |  | Get-PscApi |
| PowerShell | ArchivePath | Get-PinnedPowerShell |
| Compile | ClassName, ClassNames, Deterministic, EntryPoint, MethodNames, Native, OutputPath, SourceAst, SourcePath, StaticData, Subsystem | Export-LoweredAssembly, Export-NativeImage |
| Expression | MethodAst | ConvertTo-TypedExpression |
| Inspect | AssemblyPath | Test-LoweredAssembly |
| Capability |  | Get-LoweringCapability |
| Describe | ProjectPath | Get-SmaDescription |
| Lint | LintFiles | Get-Projects, Get-SmaLint |
| Profile |  | Invoke-SmaProfile |
| Report | ProfilePath | Get-SmaReport, Get-SmaUnits |
| Verify |  | Test-SmaDescription |
| Investigate | InvestigatePath | Invoke-PscInvestigation |
| Readme |  | ConvertTo-PscReadme, Get-PscApi |
| Link | DefaultLibrary, EntrySymbol, LibraryDirectory, LinkInput, LinkMerge, NoDefaultLibrary, OutputPath, ResolveOnly, StackReserve, Subsystem | Resolve-CoffLink, Write-CoffImage |

## Parameters

| Name | Type | Default | AllowedValues | Pipeline |
|---|---|---|---|---|
| Mode | System.String | Compile | Compile, Api, Expression, Inspect, Capability, Link, PowerShell, Describe, Lint, Profile, Report, Verify, Readme, Investigate | False |
| ArchivePath | System.String |  |  | False |
| ProjectPath | System.String |  |  | False |
| LintFiles | System.String[] |  |  | False |
| InvestigatePath | System.String[] |  |  | False |
| ProfilePath | System.String |  |  | False |
| SourcePath | System.String |  |  | False |
| SourceAst | System.Management.Automation.Language.ScriptBlockAst |  |  | False |
| StaticData | System.Collections.IDictionary |  |  | False |
| ClassName | System.String |  |  | False |
| ClassNames | System.String[] |  |  | False |
| MethodNames | System.String[] |  |  | False |
| OutputPath | System.String |  |  | False |
| EntryPoint | System.String |  |  | False |
| Native | System.Management.Automation.SwitchParameter |  |  | False |
| Deterministic | System.Management.Automation.SwitchParameter | True |  | False |
| MethodAst | System.Management.Automation.Language.FunctionMemberAst |  |  | True |
| AssemblyPath | System.String |  |  | False |
| LinkInput | System.String[] |  |  | False |
| LibraryDirectory | System.String[] |  |  | False |
| DefaultLibrary | System.String[] |  |  | False |
| NoDefaultLibrary | System.String[] |  |  | False |
| ResolveOnly | System.Management.Automation.SwitchParameter |  |  | False |
| EntrySymbol | System.String |  |  | False |
| LinkMerge | System.String[] |  |  | False |
| Subsystem | System.String | Console | Console, Windows | False |
| StackReserve | System.Int64 | 1048576 |  | False |
| Help | System.Management.Automation.SwitchParameter |  |  | False |

## Measures

| Entity | Method | Value |
|---|---|---|
| C:\dev\psc\Invoke-PSC.ps1 | AddTypeCommands | 0 |
| C:\dev\psc\Invoke-PSC.ps1 | AddTypeSourceText | 0 |
| C:\dev\psc\Invoke-PSC.ps1 | InvokeExpressionCommands | 0 |
| C:\dev\psc\Invoke-PSC.ps1 | ScriptBlockCreateCalls | 0 |
| C:\dev\psc\Invoke-PSC.ps1 | HereStrings | 1 |
| C:\dev\psc\Invoke-PSC.ps1 | ScriptBlockExpressions | 282 |
| C:\dev\psc\Invoke-PSC.ps1 | CommandsNamedByVariable | 92 |
| C:\dev\psc\Invoke-PSC.ps1 | ScriptBlockLiteralsInvoked | 0 |
| C:\dev\psc\Invoke-PSC.ps1 | CommandsNamedByOtherExpression | 1 |
| C:\dev\psc\Invoke-PSC.ps1 | MemberLookupsByText | 16 |
| C:\dev\psc\Invoke-PSC.ps1 | HashtableLiterals | 175 |
| C:\dev\psc\Invoke-PSC.ps1 | HashtableRecords | 69 |
| C:\dev\psc\Invoke-PSC.ps1 | QuotedTextConstants | 1276 |
| C:\dev\psc\Invoke-PSC.ps1 | ExpandableTexts | 120 |
| C:\dev\psc\Invoke-PSC.ps1 | RegexUses | 17 |

## Functions

Get-ProjectRemote, Get-Projects, Test-DriveRooted, Get-UnitProfile, Invoke-SmaProfile, Get-SmaUnits, Get-SmaCheckOnly, Get-SmaReport, Get-SmaLint, Get-SmaLexicalScope, Get-SmaOwner, Add-SmaDescribedSource, Resolve-SmaEdges, Get-SmaSourceFiles, Get-SmaEncodedSourceOrigins, Get-SmaDescription, Compare-SmaRuntimeGraph, Invoke-SmaObservedOperation, Test-SmaDescription, Test-AttributeClass, Get-LoweringKeywords, Enter-LoweringKeywords, Resolve-AstType, Test-AstAdmitted, Get-AttributeArgumentValue, Get-NativeImport, Add-NativeImportMethod, Get-NativeMethodContract, Set-NativeCallbackAttribute, Convert-NativeAddressExpression, Get-ClassModel, Get-ParameterTypes, New-ClassMirror, Get-EnumUnderlyingType, Get-EnumLiterals, Use-ClassMirror, ConvertTo-PowerShellType, New-PowerShellStringComparison, New-PowerShellArithmetic, Get-AstArrayElements, New-PowerShellArrayIndex, Get-KeyIndexer, Get-IntIndexer, Convert-AstExpressionAs, New-PowerShellCustomObject, Test-PSObjectView, Get-PowerShellNoteProperty, New-PowerShellNotePropertyRead, New-MemberAccess, Read-PowerShellClass, Add-GenericInference, Resolve-MatchingMethod, Resolve-MatchingConstructor, Resolve-MatchingMember, ConvertTo-CommonIntegralOperands, Convert-AstExpression, New-PredicateTruth, Convert-PredicateSwitch, Convert-AstStatement, Convert-MethodAstToLambda, Convert-InitializersToLambda, New-LoweredBody, Set-DeterministicMvid, New-PersistedAssemblySession, Save-PersistedAssemblySession, Get-IlType, Get-IlMember, Write-IlReceiver, Write-IlInstanceCall, Write-IlArgumentLoad, Write-IlArgumentStore, Write-IlLocalLoad, Write-IlLocalStore, Write-IlArrayLoad, Write-IlArrayStore, Write-IlConstant, Write-IlConversion, Write-IlDiscarded, Write-IlAssign, Write-IlStoredValue, Write-IlExpression, Write-IlMethodBody, Get-PinnedPowerShell, Get-PscApi, Get-PscApiParameter, Get-PscPresentedProperty, ConvertTo-PscMarkdownCell, ConvertTo-PscMarkdownTable, ConvertTo-PscReadme, Get-LoweringCapability, ConvertTo-TypedExpression, ConvertTo-StaticDataExpression, Export-LoweredAssembly, Get-NativeToolset, Export-NativeImage, Test-LoweredAssembly, Read-CoffName, Read-CoffStringAt, Split-CoffDirectives, Read-CoffImportObject, Read-CoffObject, Read-CoffArchive, Get-CoffArchiveMember, Find-CoffLibrary, Resolve-CoffLink, Get-CoffSectionDefinitions, Write-CoffImage, Get-PscInnerExpression, Find-PscAssignment, Get-PscOperand, Get-PscPredicate, Get-PscDerivedCheck, Resolve-PscPathExpression, Invoke-PscInvestigation, Find-PscEffect, Get-PscTypeValue, Get-PscArgumentSet, Invoke-PscMethod, Test-PscSameValue, Compare-PscOutcome, ConvertTo-PscInterpretedType

## Classes

SmaUnit, SmaEdge, SmaSource, SmaCoverage, SmaAbsence, SmaChange, SmaProject, PscParameter, PscOperation, PscApi, PscMeasure, PscSource, PscMeasurementMethod, AddTypeCommands, AddTypeSourceText, InvokeExpressionCommands, ScriptBlockCreateCalls, HereStrings, ScriptBlockExpressions, CommandsNamedByVariable, ScriptBlockLiteralsInvoked, CommandsNamedByOtherExpression, MemberLookupsByText, HashtableLiterals, HashtableRecords, QuotedTextConstants, ExpandableTexts, RegexUses, PscGuard, PscPredicateKind, PscOperandOrigin, PscOperand, PscPredicate, PscDerivedCheck, PscBlocked, PscObservation, PscInvestigation, PscInstrument, ParseInstrument, ParseErrorInstrument, MeasureInstrument, DerivedCheckInstrument, ReferenceInstrument, PscOutcome, PscRelation, PscComparison, PscNotExecuted, LowerInstrument, InterpretInstrument, CompareInstrument

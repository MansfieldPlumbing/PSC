# PSC

| Synopsis | Script | SourceSha512 | DefaultMode |
|---|---|---|---|
| A Pwsh script designed to amortize. | C:\dev\psc\Invoke-PSC.ps1 | 07E5F5B1F0E028E5B21ED52D86FEDD4999BB59F385B81CFC9815ECA7B413991D29A8961A521855AA4414A2A971FFA31DE90EFC91BF93C6D32CBCCB3019A90B88 | Compile |

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
| C:\dev\psc\Invoke-PSC.ps1 | ScriptBlockExpressions | 276 |
| C:\dev\psc\Invoke-PSC.ps1 | CommandsNamedByVariable | 92 |
| C:\dev\psc\Invoke-PSC.ps1 | ScriptBlockLiteralsInvoked | 0 |
| C:\dev\psc\Invoke-PSC.ps1 | CommandsNamedByOtherExpression | 0 |
| C:\dev\psc\Invoke-PSC.ps1 | MemberLookupsByText | 14 |
| C:\dev\psc\Invoke-PSC.ps1 | HashtableLiterals | 175 |
| C:\dev\psc\Invoke-PSC.ps1 | HashtableRecords | 69 |
| C:\dev\psc\Invoke-PSC.ps1 | QuotedTextConstants | 1243 |
| C:\dev\psc\Invoke-PSC.ps1 | ExpandableTexts | 120 |
| C:\dev\psc\Invoke-PSC.ps1 | RegexUses | 17 |

## Functions

Get-ProjectRemote, Get-Projects, Test-DriveRooted, Get-UnitProfile, Invoke-SmaProfile, Get-SmaUnits, Get-SmaCheckOnly, Get-SmaReport, Get-SmaLint, Get-SmaLexicalScope, Get-SmaOwner, Add-SmaDescribedSource, Resolve-SmaEdges, Get-SmaSourceFiles, Get-SmaEncodedSourceOrigins, Get-SmaDescription, Compare-SmaRuntimeGraph, Invoke-SmaObservedOperation, Test-SmaDescription, Test-AttributeClass, Get-LoweringKeywords, Enter-LoweringKeywords, Resolve-AstType, Test-AstAdmitted, Get-AttributeArgumentValue, Get-NativeImport, Add-NativeImportMethod, Get-NativeMethodContract, Set-NativeCallbackAttribute, Convert-NativeAddressExpression, Get-ClassModel, Get-ParameterTypes, New-ClassMirror, Get-EnumUnderlyingType, Get-EnumLiterals, Use-ClassMirror, ConvertTo-PowerShellType, New-PowerShellStringComparison, New-PowerShellArithmetic, Get-AstArrayElements, New-PowerShellArrayIndex, Get-KeyIndexer, Get-IntIndexer, Convert-AstExpressionAs, New-PowerShellCustomObject, Test-PSObjectView, Get-PowerShellNoteProperty, New-PowerShellNotePropertyRead, New-MemberAccess, Read-PowerShellClass, Add-GenericInference, Resolve-MatchingMethod, Resolve-MatchingConstructor, Resolve-MatchingMember, ConvertTo-CommonIntegralOperands, Convert-AstExpression, New-PredicateTruth, Convert-PredicateSwitch, Convert-AstStatement, Convert-MethodAstToLambda, Convert-InitializersToLambda, New-LoweredBody, Set-DeterministicMvid, New-PersistedAssemblySession, Save-PersistedAssemblySession, Get-IlType, Get-IlMember, Write-IlReceiver, Write-IlInstanceCall, Write-IlArgumentLoad, Write-IlArgumentStore, Write-IlLocalLoad, Write-IlLocalStore, Write-IlArrayLoad, Write-IlArrayStore, Write-IlConstant, Write-IlConversion, Write-IlDiscarded, Write-IlAssign, Write-IlStoredValue, Write-IlExpression, Write-IlMethodBody, Get-PinnedPowerShell, Get-PscApi, Get-PscApiParameter, Get-PscPresentedProperty, ConvertTo-PscMarkdownCell, ConvertTo-PscMarkdownTable, ConvertTo-PscReadme, Get-LoweringCapability, ConvertTo-TypedExpression, ConvertTo-StaticDataExpression, Export-LoweredAssembly, Get-NativeToolset, Export-NativeImage, Test-LoweredAssembly, Read-CoffName, Read-CoffStringAt, Split-CoffDirectives, Read-CoffImportObject, Read-CoffObject, Read-CoffArchive, Get-CoffArchiveMember, Find-CoffLibrary, Resolve-CoffLink, Get-CoffSectionDefinitions, Write-CoffImage, Get-PscInnerExpression, Find-PscAssignment, Get-PscOperand, Get-PscPredicate, Get-PscDerivedCheck, Resolve-PscPathExpression, Invoke-PscInvestigation

## Classes

SmaUnit, SmaEdge, SmaSource, SmaCoverage, SmaAbsence, SmaChange, SmaProject, PscParameter, PscOperation, PscApi, PscMeasure, PscSource, PscMeasurementMethod, AddTypeCommands, AddTypeSourceText, InvokeExpressionCommands, ScriptBlockCreateCalls, HereStrings, ScriptBlockExpressions, CommandsNamedByVariable, ScriptBlockLiteralsInvoked, CommandsNamedByOtherExpression, MemberLookupsByText, HashtableLiterals, HashtableRecords, QuotedTextConstants, ExpandableTexts, RegexUses, PscGuard, PscPredicateKind, PscOperandOrigin, PscOperand, PscPredicate, PscDerivedCheck, PscBlocked, PscObservation, PscInvestigation, PscInstrument, ParseInstrument, ParseErrorInstrument, MeasureInstrument, DerivedCheckInstrument, ReferenceInstrument

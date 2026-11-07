# PSC

| Synopsis | Script | SourceSha512 | DefaultMode | Environment |
|---|---|---|---|---|
| A Pwsh script designed to amortize. | C:\dev\psc\Invoke-PSC.ps1 | B6C3DF0978EA98A0DF22AAA67D385ED3BEF9DC320BFB3EBA733119EBAD90BA37647C4BC39804341BE7894656D272280CA35047E576D28E124BD85436078C46FF | Compile | PscEnvironment |

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
| Consolidate | OutputPath, SourcePath | ConvertTo-PscSingleScript |
| Investigate | InvestigatePath | Invoke-PscInvestigation |
| Records | SourceAst | Get-PscRecord |
| Readme |  | ConvertTo-PscReadme, Get-PscApi |
| Link | DefaultLibrary, EntrySymbol, LibraryDirectory, LinkInput, LinkMerge, NoDefaultLibrary, OutputPath, ResolveOnly, StackReserve, Subsystem | Resolve-CoffLink, Write-CoffImage |

## Parameters

| Name | Type | Default | AllowedValues | Pipeline |
|---|---|---|---|---|
| Mode | System.String | Compile | Compile, Api, Expression, Inspect, Capability, Link, PowerShell, Describe, Lint, Profile, Report, Verify, Readme, Investigate, Consolidate, Records | False |
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
| C:\dev\psc\Invoke-PSC.ps1 | ScriptBlockExpressions | 325 |
| C:\dev\psc\Invoke-PSC.ps1 | CommandsNamedByVariable | 96 |
| C:\dev\psc\Invoke-PSC.ps1 | ScriptBlockLiteralsInvoked | 0 |
| C:\dev\psc\Invoke-PSC.ps1 | CommandsNamedByOtherExpression | 2 |
| C:\dev\psc\Invoke-PSC.ps1 | MemberLookupsByText | 23 |
| C:\dev\psc\Invoke-PSC.ps1 | HashtableLiterals | 195 |
| C:\dev\psc\Invoke-PSC.ps1 | HashtableRecords | 75 |
| C:\dev\psc\Invoke-PSC.ps1 | QuotedTextConstants | 1432 |
| C:\dev\psc\Invoke-PSC.ps1 | ExpandableTexts | 124 |
| C:\dev\psc\Invoke-PSC.ps1 | NamespaceUsings | 0 |
| C:\dev\psc\Invoke-PSC.ps1 | RegexUses | 18 |

## Functions

Get-ProjectRemote, Get-Projects, Test-DriveRooted, Get-UnitProfile, Invoke-SmaProfile, Get-SmaUnits, Get-SmaCheckOnly, Get-SmaReport, Get-SmaLint, Get-SmaLexicalScope, Get-SmaOwner, Add-SmaDescribedSource, Resolve-SmaEdges, Get-SmaSourceFiles, Get-SmaEncodedSourceOrigins, Get-SmaDescription, Compare-SmaRuntimeGraph, Invoke-SmaObservedOperation, Test-SmaDescription, Test-AttributeClass, Get-LoweringKeywords, Enter-LoweringKeywords, Resolve-AstType, Test-AstAdmitted, Get-AttributeArgumentValue, Get-NativeImport, Add-NativeImportMethod, Get-NativeMethodContract, Set-NativeCallbackAttribute, Convert-NativeAddressExpression, Get-ClassModel, Get-ParameterType, Get-ParameterTypes, New-ClassMirror, Get-EnumUnderlyingType, Get-EnumLiterals, Use-ClassMirror, Get-ClassMirrorType, Get-PscSemanticsMethod, Add-PscSemanticsToSession, Get-ScriptFunctionClass, New-OutputBlock, Test-PscWrittenWhole, New-OutputWrite, New-ScriptFunctionCall, Get-VariableName, Get-SmaVariableName, Get-PscInferredType, Get-PscRecord, ConvertTo-PscRecordSource, Get-ScriptVariable, Get-ScriptField, Test-ScriptFunctionMember, Find-ScriptFunction, Get-PscSemanticsClass, ConvertTo-PowerShellType, New-PowerShellStringComparison, New-PowerShellArithmetic, ConvertTo-IntegralQuotient, New-TypedArrayLiteral, New-PowerShellArrayIndex, Get-KeyIndexer, Get-IntIndexer, Convert-AstExpressionAs, New-PowerShellCustomObject, Test-PSObjectView, Get-PowerShellNoteProperty, New-PowerShellNotePropertyRead, Test-PscDynamicMemberTarget, Test-PscStrictMode, New-MemberAccess, Read-PowerShellClass, Add-GenericInference, Resolve-MatchingMethod, Resolve-MatchingConstructor, Resolve-MatchingMember, Convert-AstExpression, New-PredicateTruth, Convert-PredicateSwitch, Convert-AstStatement, Convert-MethodAstToLambda, Convert-InitializersToLambda, New-LoweredBody, Set-DeterministicMvid, New-PersistedAssemblySession, Save-PersistedAssemblySession, Get-IlType, Get-IlMember, Write-IlReceiver, Write-IlInstanceCall, Write-IlArgumentLoad, Write-IlArgumentStore, Write-IlLocalLoad, Write-IlLocalStore, Write-IlArrayLoad, Write-IlArrayStore, Write-IlConstant, Write-IlConversion, Write-IlDiscarded, Write-IlAssign, Write-IlStoredValue, Write-IlExpression, Write-IlMethodBody, Get-PinnedPowerShell, Get-PscApi, Get-PscApiParameter, Get-PscPresentedProperty, ConvertTo-PscMarkdownCell, ConvertTo-PscMarkdownTable, ConvertTo-PscReadme, Get-LoweringCapability, ConvertTo-TypedExpression, ConvertTo-StaticDataExpression, Export-LoweredAssembly, Get-NativeToolset, Export-NativeImage, Test-LoweredAssembly, Read-CoffName, Read-CoffStringAt, Split-CoffDirectives, Read-CoffImportObject, Read-CoffObject, Read-CoffArchive, Get-CoffArchiveMember, Find-CoffLibrary, Resolve-CoffLink, Get-CoffSectionDefinitions, Write-CoffImage, Get-PscInnerExpression, Find-PscAssignment, Get-PscOperand, Get-PscPredicate, Get-PscDerivedCheck, Resolve-PscPathExpression, Invoke-PscInvestigation, Find-PscEffect, Compare-PscOperandBinding, ConvertTo-PscSingleScript, Get-PscFixedPath, Get-PscFixedVariable, Resolve-PscScriptInvocation, Get-PscScriptDifference, Add-PscFoldedScript

## Classes

SmaUnit, SmaEdge, SmaSource, SmaCoverage, SmaAbsence, SmaChange, SmaProject, PscDifferential, PowerShellSemantics, PscBinding, PscEnvironment, PscOperatorKind, PscBoundOperands, PscOperandBinding, PowerShellNumericOperands, PscParameter, PscOperation, PscAstRebuild, PscOperatorRebinding, PscRecordSlot, PscRecord, PscRecordRewrite, PscApi, PscMeasure, PscSource, PscMeasurementMethod, AddTypeCommands, AddTypeSourceText, InvokeExpressionCommands, ScriptBlockCreateCalls, HereStrings, ScriptBlockExpressions, CommandsNamedByVariable, ScriptBlockLiteralsInvoked, CommandsNamedByOtherExpression, MemberLookupsByText, HashtableLiterals, HashtableRecords, QuotedTextConstants, ExpandableTexts, NamespaceUsings, RegexUses, PscGuard, PscPredicateKind, PscOperandOrigin, PscOperand, PscPredicate, PscCondition, PscDerivedCheck, PscBlocked, PscObservation, PscInvestigation, PscInstrument, ParseInstrument, ParseErrorInstrument, MeasureInstrument, DerivedCheckInstrument, ReferenceInstrument, PscOutcome, PscRelation, PscComparison, PscNotExecuted, PscBindingEvaluation, PscIncludedScript, PscConsolidation, PscConsolidationState, PscMemberLowering, MemberLoweringInstrument, LowerInstrument, InterpretInstrument, CompareInstrument

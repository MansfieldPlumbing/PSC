# PSC

The Treachery of Images. Magritte painted a pipe and wrote beneath it "Ceci n'est pas une pipe": the picture is not the pipe. PSC works by the same distinction. A handle is not what it identifies, #FF8000 is not the colour, a script's text is not its meaning, and a measurement is a picture of what happened, not what happened.

| Synopsis | Script | SourceSha512 | DefaultMode | Environment |
|---|---|---|---|---|
| A Pwsh script designed to amortize. | C:\Dev\PSC\Invoke-PSC.ps1 | CEF736ED670ACF2B9CC3C85D87D9C428E7EC579D8666E970E856947D32A22354503DFF775D60A334FB63649433EBADF41126782872A00AF56837E55979C5F21D | Compile | PscEnvironment |

## Modes

| Mode | Parameters | Calls |
|---|---|---|
| Api |  | Get-PscApi |
| PowerShell | ArchivePath | Get-PinnedPowerShell |
| Compile | ClassName, ClassNames, Deterministic, EntryPoint, FixedParameters, FixedParametersPath, MethodNames, Native, OutputPath, Program, SourceAst, SourcePath, StaticData, Subsystem | Export-LoweredAssembly, Export-NativeImage, Read-PowerShellSource |
| Expression | MethodAst | ConvertTo-TypedExpression |
| Inspect | AssemblyPath, ClassName, MethodNames | Test-LoweredAssembly |
| Capability |  | Get-LoweringCapability |
| Graph | ProjectPath | Get-SmaGraph |
| Lint | LintEdit, LintFiles | Edit-SmaLintFinding, Get-Projects, Get-SmaLint |
| Guard | CheckerHash, LintFiles | Test-SmaGuard |
| Profile |  | Invoke-SmaProfile |
| Report | ProfilePath | Get-SmaReport, Get-SmaUnits |
| Verify |  | Test-SmaGraph |
| Consolidate | OutputPath, SourcePath | ConvertTo-PscSingleScript |
| Investigate | InvestigatePath | Invoke-PscInvestigation |
| Records | SourceAst | Get-PscRecord |
| Run | RunParameters, SourceAst, SourcePath | Invoke-PscRun |
| Readme |  | ConvertTo-PscReadme, Get-PscApi |
| Link | DefaultLibrary, EntrySymbol, LibraryDirectory, LinkInput, LinkMerge, NoDefaultLibrary, OutputPath, ResolveOnly, StackReserve, Subsystem | Resolve-CoffLink, Write-CoffImage |

## Parameters

| Name | Type | Default | AllowedValues | Pipeline |
|---|---|---|---|---|
| Mode | System.String | Compile | Compile, Api, Expression, Inspect, Capability, Link, PowerShell, Graph, Lint, Guard, Profile, Report, Verify, Readme, Investigate, Consolidate, Records, Run | False |
| RunParameters | System.Collections.Hashtable | System.Collections.Hashtable |  | False |
| BindingEnvironment | System.Object |  |  | False |
| ArchivePath | System.String |  |  | False |
| ProjectPath | System.String |  |  | False |
| LintFiles | System.String[] |  |  | False |
| LintEdit | System.Management.Automation.SwitchParameter |  |  | False |
| CheckerHash | System.String |  |  | False |
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
| Program | System.Management.Automation.SwitchParameter |  |  | False |
| FixedParameters | System.Collections.Hashtable |  |  | False |
| FixedParametersPath | System.String |  |  | False |
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
| C:\Dev\PSC\Invoke-PSC.ps1 | AddTypeCommands | 0 |
| C:\Dev\PSC\Invoke-PSC.ps1 | AddTypeSourceText | 0 |
| C:\Dev\PSC\Invoke-PSC.ps1 | InvokeExpressionCommands | 0 |
| C:\Dev\PSC\Invoke-PSC.ps1 | ScriptBlockCreateCalls | 0 |
| C:\Dev\PSC\Invoke-PSC.ps1 | HereStrings | 1 |
| C:\Dev\PSC\Invoke-PSC.ps1 | ScriptBlockExpressions | 415 |
| C:\Dev\PSC\Invoke-PSC.ps1 | CommandsNamedByVariable | 135 |
| C:\Dev\PSC\Invoke-PSC.ps1 | ScriptBlockLiteralsInvoked | 0 |
| C:\Dev\PSC\Invoke-PSC.ps1 | CommandsNamedByOtherExpression | 5 |
| C:\Dev\PSC\Invoke-PSC.ps1 | MemberLookupsByText | 64 |
| C:\Dev\PSC\Invoke-PSC.ps1 | HashtableLiterals | 224 |
| C:\Dev\PSC\Invoke-PSC.ps1 | HashtableRecords | 80 |
| C:\Dev\PSC\Invoke-PSC.ps1 | QuotedTextConstants | 1559 |
| C:\Dev\PSC\Invoke-PSC.ps1 | ExpandableTexts | 152 |
| C:\Dev\PSC\Invoke-PSC.ps1 | NamespaceUsings | 0 |
| C:\Dev\PSC\Invoke-PSC.ps1 | RegexUses | 19 |

## Functions

Get-ProjectRemote, Get-Projects, Test-DriveRooted, Get-UnitProfile, Invoke-SmaProfile, Get-SmaUnits, Get-SmaCheckOnly, Get-SmaReport, Get-SmaLint, Edit-SmaLintFinding, Get-SmaChecker, Test-SmaGuard, Get-SmaLexicalScope, Get-SmaOwner, Add-SmaGraphSource, Resolve-SmaEdges, Get-SmaSourceFiles, Get-SmaEncodedSourceOrigins, Get-SmaGraph, Compare-SmaRuntimeGraph, Invoke-SmaObservedOperation, Test-SmaGraph, Test-AttributeClass, Get-ProgramIcon, Set-ProgramEntryAttributes, New-PscEntryFixtureAst, Get-PscPeResourceBytes, Get-PscPeResource, Test-PscProgramMetadata, Test-PscInlineMethod, Assert-PscInlineOverrides, Test-PscTypedArrayAssignment, Test-PscInline, Get-LoweringKeywords, Enter-LoweringKeywords, Resolve-AstType, Test-AstAdmitted, Get-AttributeArgumentValue, Get-NativeImport, Add-NativeImportMethod, Get-NativeMethodContract, Set-NativeCallbackAttribute, Convert-NativeAddressExpression, Get-ClassModel, Get-ParameterType, Get-ParameterTypes, New-ClassMirror, Get-EnumUnderlyingType, Get-EnumLiterals, Use-ClassMirror, Get-ClassMirrorType, Get-PscSemanticsMethod, Add-PscSemanticsToSession, Get-ScriptFunctionClass, New-OutputBlock, Test-PscWrittenWhole, New-OutputWrite, Measure-PscOutputStatement, Measure-PscOutputPaths, Get-PscFunctionOutputType, New-ScriptFunctionCall, Get-VariableName, Get-SmaVariableName, Get-PscInferredType, Get-PscRecord, Invoke-PscRun, ConvertTo-PscRecordSource, Get-PscInferredTypeName, Get-ScriptVariable, Get-ScriptField, Test-ScriptFunctionMember, Find-ScriptFunction, Get-PscSemanticsClass, ConvertTo-PowerShellType, New-PowerShellStringComparison, New-PscOrderingComparison, New-PowerShellArithmetic, ConvertTo-IntegralQuotient, New-TypedArrayLiteral, New-PowerShellArrayIndex, Get-KeyIndexer, Get-IntIndexer, Convert-AstExpressionAs, New-PowerShellTableObject, New-PowerShellCustomObject, Test-PSObjectView, Get-PowerShellNoteProperty, New-PowerShellNotePropertyRead, Test-PscDynamicMemberTarget, Test-PscStrictMode, New-MemberAccess, Read-PowerShellSource, Read-PowerShellClass, Add-GenericInference, Resolve-MatchingMethod, Resolve-MatchingConstructor, Add-PscDefaultArguments, Resolve-MatchingMember, Convert-AstExpression, New-PredicateTruth, Convert-PredicateSwitch, Convert-AstStatement, Convert-MethodAstToLambda, Convert-InitializersToLambda, New-LoweredBody, Set-DeterministicMvid, New-PersistedAssemblySession, Save-PersistedAssemblySession, Get-IlType, Get-IlMember, Write-IlReceiver, Write-IlInstanceCall, Write-IlArgumentLoad, Write-IlArgumentStore, Write-IlLocalLoad, Write-IlLocalStore, Write-IlArrayLoad, Write-IlArrayStore, Write-IlConstant, Write-IlConversion, Write-IlDiscarded, Write-IlAssign, Write-IlStoredValue, Write-IlExpression, Write-IlFieldDataArray, Write-IlMethodBody, Get-PinnedPowerShell, Get-PscApi, Get-PscApiParameter, Get-PscPresentedProperty, ConvertTo-PscMarkdownCell, ConvertTo-PscMarkdownTable, ConvertTo-PscReadme, Get-LoweringCapability, ConvertTo-TypedExpression, Get-PscStaticInstance, Complete-PscStaticGraph, Get-PscStaticGraphPrologue, ConvertTo-StaticDataExpression, Get-RequiredClassMethods, Export-LoweredAssembly, Get-NativeToolset, Get-AssemblyReferenceName, Get-NativeReferenceClosure, Export-NativeImage, Test-LoweredAssembly, Read-CoffName, Read-CoffStringAt, Split-CoffDirectives, Read-CoffImportObject, Read-CoffObject, Read-CoffArchive, Get-CoffArchiveMember, Find-CoffLibrary, Resolve-CoffLink, Get-CoffSectionDefinitions, Write-CoffImage, Get-PscInnerExpression, Find-PscAssignment, Get-PscOperand, Get-PscPredicate, Get-PscDerivedCheck, Resolve-PscPathExpression, Invoke-PscInvestigation, Find-PscEffect, Compare-PscOperandBinding, ConvertTo-PscSingleScript, Get-PscFixedPath, Get-PscFixedVariable, Resolve-PscScriptInvocation, Get-PscScriptDifference, Add-PscFoldedScript

## Classes

PscChecker, SmaLintEdit, SmaLintFinding, SmaLintEditedFile, SmaLintRebinding, SmaLintEnumSource, SmaLintEnumFit, SmaLintConversion, PscGuardVerdict, SmaUnit, SmaEdge, SmaSource, SmaCoverage, SmaAbsence, SmaChange, SmaProject, PscInline, SingleThreadedApartment, ApplicationIcon, PscIconImage, PscResourceType, PscIcon, PscEntryFixture, PscPeResource, PscProgramMetadataVerdict, PscTableElement, PscTableAssignment, PscTypedArrayVerdict, PscInlineLoop, PscInlineOverride, PscDifferential, PowerShellSemantics, PscBindingTarget, PscMutationState, PscBinding, PscCharacterLiteral, PscMutation, PscEnvironment, PscOperatorKind, PscBoundOperands, PscOperandBinding, PowerShellNumericOperands, PscParameter, PscOperation, PscAstRebuild, PscNativeEntry, PscNativeCalls, PscNativeStubFill, PscOperatorRebinding, PscRecordSlot, PscRecord, PscFixedParameters, PscReachability, PscRecordRewrite, PscApi, PscFieldData, PscStaticGraph, PscMethodClosure, PscLoweringSource, PscStaticDataField, PscMemberPlan, PscClassPlan, PscSemanticsPlan, PscLoweredAssembly, PscMethodInspection, PscAssemblyInspection, PscCoffDirective, PscCoffInput, PscCoffLinkerDefined, PscCoffImport, PscCoffSection, PscCoffSymbol, PscCoffObject, PscCoffSpan, PscCoffArchiveMember, PscCoffArchive, PscCoffResolvedImport, PscCoffResolution, PscCoffSectionDefinition, PscCoffContribution, PscCoffTargetKind, PscCoffTarget, PscCoffOutputSection, PscCoffImageSection, PscCoffImageImport, PscCoffImage, PscMeasure, PscSource, PscMeasurementMethod, AddTypeCommands, AddTypeSourceText, InvokeExpressionCommands, ScriptBlockCreateCalls, HereStrings, ScriptBlockExpressions, CommandsNamedByVariable, ScriptBlockLiteralsInvoked, CommandsNamedByOtherExpression, MemberLookupsByText, HashtableLiterals, HashtableRecords, QuotedTextConstants, ExpandableTexts, NamespaceUsings, RegexUses, PscGuard, PscPredicateKind, PscOperandOrigin, PscOperand, PscPredicate, PscCondition, PscDerivedCheck, PscBlocked, PscObservation, PscInvestigation, PscInstrument, ParseInstrument, ParseErrorInstrument, MeasureInstrument, DerivedCheckInstrument, ReferenceInstrument, PscOutcome, PscRelation, PscComparison, PscNotExecuted, PscBindingEvaluation, PscIncludedScript, PscConsolidation, PscConsolidationState, PscMemberLowering, MemberLoweringInstrument, LowerInstrument, InterpretInstrument, CompareInstrument

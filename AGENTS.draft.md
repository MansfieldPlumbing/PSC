# PSC agent standard — DRAFT for Scott

Draft written at Scott's request on 2026-11-09. Nothing here is in force until Scott moves it into `AGENTS.md`.
Each line is taken from something Scott said or from what the code does; lines marked (open) are his to decide.

## What PSC is

- PSC is `Invoke-PSC.ps1`: one script, upstream of every PowerShell repository Scott owns. Work on it is paid for once
  and used everywhere. It may grow to megabytes; every addition must make it stronger for all users, not for one program.
- Agents work through its API (`-Mode ...`, `PscApi`). No scratch scripts, no side files, no second tool that does part
  of PSC's job. If the API cannot do what the work needs, the API grows.
- NativeAOT is one output. A single-file JIT conversion, the Hexagon kernel compilers and the rest of what pwsh does
  are others. Nothing in PSC may assume one output.
- Code is the record. Docs and READMEs may be stale; read the script, by its AST.

## PowerShell is not bash

- PowerShell source here is typed, structured program text that SMA parses, binds and reasons about. If SMA is blind
  to something, it is not correct.
- No text pipelines over code, no regex on code, no source held in strings, no code assembled from text, no
  `Invoke-Expression`, no `Add-Type`, no C# in any form, no C# semantics passed off as PowerShell idiom.
- Semantics follow the target ISA, stated in types the program declares. Not C#'s conversions, and not SMA's dynamic
  conversions added as special cases.

## No strings in place of structure

A string literal at the point of use is a defect unless it is text a person reads.

- A name from a fixed set is an enum member (`[TokenKind]::Plus`, never `'Plus'`). A string compared with an enum
  silently never matches when misspelled: lint rule `EnumNameUnknown` found five such comparisons in PSC.
- A record's fields are class properties, not hashtable keys or string-keyed lookups (`.Get('NumericOperands')` is one).
- A reference to a member, type or method is a typed reference, not its name.
- Text that is data (a message, a label, a unit, a measure) is a named, typed value declared once on the class that
  owns it, and used by that name.
- (open) A hashtable is not a record, a dispatch table or a type map. Scott has said it should be a vtable or a
  typetable: a typed table whose keys are members or types SMA can see. Its exact shape is his to state.
- (open) `[pscustomobject]`: Scott intends to limit it. Until he says how, new records are classes.

## Change the environment, not the compiler's cases

- When a construct does not lower, do not add a rule that recognizes that one shape. Find the layer that owns the
  decision (parser, binder, operand binding, type system) and give the environment a binding that makes the decision
  for every program: `PscEnvironment.Set`, a `PscBinding` subclass, `PscApi.BindOperators`, a `[Keyword()]` method
  registered as a `DynamicKeyword`.
- A binding is set just in time, is typed, keeps the binding it replaced, and is visible to SMA.
- New grammar is taught to SMA's parser before parsing. Source text is never rewritten; there is no second parser.
- Bulk edits to source are made from the AST and checked by SMA before they are written
  (`-Mode Lint -LintEdit` is the pattern: findings carry edits; a file is written only if it parses with no errors).

## Programs compiled by PSC

- Application code names no platform. Fluent is a cross-platform UI framework (Windows and Android; Material and
  Metro simulacra; a cell renderer); it does not mimic Win32.
- A refusal from PSC is fixed in the layer that owns it: the program if the program is untyped or ambiguous, PSC's
  environment if PowerShell semantics are missing. Never by a workaround in either.

## Conduct

- Do what Scott asks. Only Scott makes rules. Report what breaks them; fix only when asked.
- Say what is proven, what is measured and what is unknown. A lowering change is verified by running the affected
  program's investigation before and after and comparing members lowered and refusals.
- Do not commit, push or delete what you did not create unless Scott asks.
- The checker is the functions marked `[PscChecker()]` in `Invoke-PSC.ps1`. Run `-Mode Guard -LintFiles <file>` on
  every PowerShell file you change, and leave it passing. Do not change, remove, unmark, weaken or route around a
  checker function, and do not change code so that a rule stops seeing a defect. Only Scott changes the checker; he
  keeps its hash (`CheckerHash`) outside the machine.

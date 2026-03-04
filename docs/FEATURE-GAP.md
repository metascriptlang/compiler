# Feature Gap: MetaScript vs Nim

Comprehensive tracking of Nim compiler features not yet in MetaScript self-hosted compiler.
Goal: 100% pipeline parity with `~/projects/nim/compiler/`.

## Status Legend

- **DONE** — Implemented and tested
- **NOW** — Can implement now, no blockers
- **BLOCKED** — Needs prerequisite work first
- **DEFERRED** — Needs new language feature or major design work
- **N/A** — Not applicable to MetaScript's language design

---

## Phase 1: Parse + Module Loading

| Feature | Nim Source | Status | Notes |
|---------|-----------|--------|-------|
| ~~Recursive descent + Pratt parser~~ | ~~parser.nim (2,612 lines)~~ | ~~DONE~~ | ~~37 NodeKinds, 80+ TokenKinds~~ |
| ~~Module graph + topo sort~~ | ~~modulegraphs.nim, modules.nim~~ | ~~DONE~~ | ~~src/module/ (graph, resolver, loader)~~ |
| ~~Cycle detection~~ | ~~importer.nim~~ | ~~DONE~~ | ~~State machine (Loading re-encounter)~~ |
| ~~Significant whitespace~~ | ~~lexer.nim indent tracking~~ | ~~N/A~~ | ~~MetaScript uses braces~~ |
| Custom numeric literals | `123'CustomType` | DEFERRED | Not in MetaScript syntax yet |
| Unicode operators | `∘`, `×`, `★` as operators | DEFERRED | Not in MetaScript syntax yet |
| ~~Source filters~~ | ~~syntaxes.nim (145 lines)~~ | ~~N/A~~ | ~~MetaScript has no source filter concept~~ |
| Generalized string literals | `sql"SELECT ..."` | DEFERRED | Tagged template syntax possible alternative |

---

## Phase 2: Type Checking

| Feature | Nim Source | Status | Notes |
|---------|-----------|--------|-------|
| ~~3-pass type checking~~ | ~~sem.nim + 15 files (~24K lines)~~ | ~~DONE~~ | ~~collect → resolve → check~~ |
| ~~Forward references~~ | ~~Implicit via 3-pass~~ | ~~DONE~~ | ~~No workarounds needed~~ |
| ~~Overload resolution~~ | ~~sigmatch.nim (3,254 lines)~~ | ~~DONE~~ | ~~scoreCandidate in compat.ms~~ |
| ~~Generic instantiation~~ | ~~seminst.nim (483 lines)~~ | ~~DONE~~ | ~~Monomorphize module~~ |
| ~~UFCS / extension methods~~ | ~~semexprs.nim dot rewrite~~ | ~~DONE~~ | ~~ExtensionRegistry + extensionMethodLower~~ |
| ~~Cross-module type propagation~~ | ~~strTableAdds + importer.nim~~ | ~~DONE~~ | ~~ExportRegistry in context.ms~~ |
| ~~**Effect system** (`func`, `@pure`, `@raises`)~~ | ~~sempass2.nim (1,800 lines)~~ | ~~**DONE**~~ | ~~`@pure` decorator + purity violation checker~~ |
| ~~**Nil safety** (`not nil` annotations)~~ | ~~nilcheck.nim (1,387 lines)~~ | ~~**DONE**~~ | ~~Guard clause narrowing, logical AND narrowing, assertion narrowing~~ |
| **Borrow checking** (view types) | varpartitions.nim (1,019 lines) | **BLOCKED** | Needs CFG (Gap 5) + Span\<T\> type |
| Concepts / type classes | concepts.nim (607 lines) | DEFERRED | Not in MetaScript type system yet |
| Multi-methods | cgmeth.nim (308 lines) | DEFERRED | Not in MetaScript — uses extension methods instead |
| Method dispatch / VTables | vtables.nim (166 lines) | DEFERRED | Needs multi-methods first |
| Converter procs | implicit type conversion | DEFERRED | `converter` keyword parsed but not checked |
| Template instantiation | semtempl.nim (928 lines) | DEFERRED | MetaScript has `@comptime` (planned) |
| Macro system | VM-based macro expansion | DEFERRED | Hermes VM integration planned |

---

## Phase 3: Transforms

| Feature | Nim Source | Status | Notes |
|---------|-----------|--------|-------|
| ~~Lambda lifting~~ | ~~lambdalifting.nim (1,031 lines)~~ | ~~DONE~~ | ~~lambdaLifting.ms (482 lines)~~ |
| ~~Closure iterator → state machine~~ | ~~closureiters.nim (1,529 lines)~~ | ~~DONE~~ | ~~generatorLower.ms (512 lines)~~ |
| ~~Destructor lifting (6 hooks)~~ | ~~liftdestructors.nim (1,359 lines)~~ | ~~DONE~~ | ~~destructorLifting.ms (636 lines)~~ |
| ~~Constant folding~~ | ~~transf.nim getConstExpr~~ | ~~DONE~~ | ~~constantFolding.ms~~ |
| ~~Defer → try/finally~~ | ~~transf.nim liftDefer~~ | ~~DONE~~ | ~~deferLower.ms~~ |
| ~~For loop lowering~~ | ~~transf.nim transformFor~~ | ~~DONE~~ | ~~forLoopLower.ms + forOfLower.ms~~ |
| ~~Match/case lowering~~ | ~~transf.nim transformCase~~ | ~~DONE~~ | ~~matchLower.ms~~ |
| ~~Destructuring~~ | ~~lowerings.nim lowerTupleUnpacking~~ | ~~DONE~~ | ~~destructuringLower.ms~~ |
| ~~Extension method rewrite~~ | ~~semcall.nim UFCS~~ | ~~DONE~~ | ~~extensionMethodLower.ms~~ |
| ~~Dead code elimination~~ | ~~ic/dce.nim~~ | ~~DONE~~ | ~~dce.ms (2-tier)~~ |
| ~~**String case hash dispatch**~~ | ~~ccgstmts.nim genStringCase~~ | ~~**DONE**~~ | ~~DJB2 hash + SwitchStmt for >8 string arms~~ |
| HLO / term rewriting | hlo.nim (105 lines) | DEFERRED | User-defined rewrite rules need macro system |
| Proc inlining | inliner.nim (122 lines) | DEFERRED | `@inline` decorator parsed but not implemented |
| Spawn / parallel | spawn.nim (445 lines) | DEFERRED | Threading model not designed yet |
| ~~Lift locals~~ | ~~liftlocals.nim (76 lines)~~ | ~~N/A~~ | ~~Niche `.liftLocals` pragma, no MetaScript equivalent~~ |

---

## Phase 4: Analyzer (DRC Injection)

| Feature | Nim Source | Status | Notes |
|---------|-----------|--------|-------|
| ~~Destructor call injection~~ | ~~injectdestructors.nim (1,382 lines)~~ | ~~DONE~~ | ~~analyzer/ (6 files, ~2500 lines)~~ |
| ~~Scope-based cleanup (LIFO)~~ | ~~injectdestructors.nim~~ | ~~DONE~~ | ~~scope.ms + inject.ms~~ |
| ~~Move optimization (last-read)~~ | ~~injectdestructors.nim~~ | ~~DONE~~ | ~~lastRead.ms (conservative forward scan)~~ |
| ~~Post-optimizer (wasMoved+destroy elision)~~ | ~~optimizer.nim (298 lines)~~ | ~~DONE~~ | ~~optimize.ms~~ |
| ~~**CFG-based data flow analysis**~~ | ~~dfa.nim (491 lines)~~ | ~~**DONE**~~ | ~~Termination analysis — return/throw/break skip outer scope checks~~ |
| ~~**Sink parameter inference**~~ | ~~sinkparameter_inference.nim (69 lines)~~ | ~~**DONE**~~ | ~~Auto-detect consumed params, skip cleanup~~ |
| **Cursor / borrow inference** | varpartitions.nim (1,019 lines) | **BLOCKED** | Needs CFG first; enables Span\<T\> |
| Isolation check (thread safety) | isolation_check.nim (232 lines) | DEFERRED | Needs threading model |

---

## Phase 5: C Codegen

| Feature | Nim Source | Status | Notes |
|---------|-----------|--------|-------|
| ~~Section-based output (16 sections)~~ | ~~cgendata.nim~~ | ~~DONE~~ | ~~10 sections (sufficient for current feature set)~~ |
| ~~Two-phase init (DatInit + Init)~~ | ~~cgen.nim genInitCode/genDatInitCode~~ | ~~DONE~~ | ~~Module-qualified init names~~ |
| ~~Type emission + forward decls~~ | ~~ccgtypes.nim (2,074 lines)~~ | ~~DONE~~ | ~~types.ms with TypeCache~~ |
| ~~Expression emission~~ | ~~ccgexprs.nim (4,066 lines)~~ | ~~DONE~~ | ~~expressions.ms~~ |
| ~~Statement emission~~ | ~~ccgstmts.nim (1,961 lines)~~ | ~~DONE~~ | ~~statements.ms~~ |
| ~~Call generation~~ | ~~ccgcalls.nim (895 lines)~~ | ~~DONE~~ | ~~In expressions.ms genCallExpr~~ |
| ~~Closure calls~~ | ~~ccgcalls.nim genClosureCall~~ | ~~DONE~~ | ~~`(callee).fn(callee.env, args)`~~ |
| ~~Multi-module build~~ | ~~cgen.nim genModule~~ | ~~DONE~~ | ~~Unity build with #include assembly~~ |
| ~~@runtime / @builtin lowering~~ | ~~TMagic in ccgexprs.nim~~ | ~~DONE~~ | ~~emitRuntimeCall in expressions.ms~~ |
| ~~String concat chain fusion~~ | ~~ccgexprs.nim genStrConcat~~ | ~~DONE~~ | ~~ms_string_concat_many~~ |
| ~~Array bounds checking~~ | ~~ccgexprs.nim genArrayElem~~ | ~~DONE~~ | ~~GCC statement expressions~~ |
| ~~Empty string fast path~~ | ~~ccgexprs.nim genStrEquals~~ | ~~DONE~~ | ~~`(s.len == 0)`~~ |
| ~~Array index write~~ | ~~ccgexprs.nim genArrayElem~~ | ~~DONE~~ | ~~`arr.p->data[i] = v`~~ |
| ~~**NRVO** (named return value optimization)~~ | ~~cgen.nim allPathsAsgnResult~~ | ~~**DONE**~~ | ~~Out-param signature for struct-returning functions~~ |
| ~~**Enum toString**~~ | ~~enumtostr.nim (112 lines)~~ | ~~**DONE**~~ | ~~Auto-generated switch-based toString per enum~~ |
| ~~3 exception strategies (goto/C++/setjmp)~~ | ~~ccgstmts.nim~~ | ~~DONE (2/3)~~ | ~~Goto-based (default) + setjmp (fallback)~~ |
| ~~**Goto-based exceptions**~~ | ~~ccgstmts.nim genTryGoto~~ | ~~**DONE**~~ | ~~Label-based goto with ms_nimErr_ flag~~ |
| RTTI V2 (ARC/ORC) | ccgtypes.nim genTypeInfoV2 | DEFERRED | Minimal RTTI currently |
| ~~C++ dual target~~ | ~~Throughout cgen~~ | ~~N/A~~ | ~~MetaScript targets C only~~ |
| ~~Hot code reloading~~ | ~~Throughout cgen (HCR)~~ | ~~N/A~~ | ~~Not in scope~~ |
| ~~GC traversal procs~~ | ~~ccgtrav.nim (232 lines)~~ | ~~N/A~~ | ~~ARC/DRC only, no tracing GC~~ |
| ~~Default value expansion~~ | ~~expanddefaults.nim (131 lines)~~ | ~~DONE~~ | ~~Zero-init in codegen~~ |

---

## Summary: Implementable Gaps — ALL DONE

All 8 gaps that could be filled without new language features have been implemented:

| # | Gap | Status | Phase | Impl. Details |
|---|-----|--------|-------|---------------|
| ~~1~~ | ~~Enum toString~~ | ~~DONE~~ | ~~Codegen~~ | ~~`genEnumToString()` in declarations.ms~~ |
| ~~2~~ | ~~String case hash dispatch~~ | ~~DONE~~ | ~~Transform~~ | ~~DJB2 hash + SwitchStmt in matchLower.ms~~ |
| ~~3~~ | ~~Effect system (@pure)~~ | ~~DONE~~ | ~~Checker~~ | ~~`checkPurityViolations()` in checkPass.ms~~ |
| ~~4~~ | ~~Enhanced null safety~~ | ~~DONE~~ | ~~Checker~~ | ~~Guard clause + AND narrowing in checkPass.ms~~ |
| ~~5~~ | ~~CFG-based last-read~~ | ~~DONE~~ | ~~Analyzer~~ | ~~Termination analysis in lastRead.ms~~ |
| ~~6~~ | ~~Sink parameter inference~~ | ~~DONE~~ | ~~Analyzer~~ | ~~`isParamSinkCandidate()` in inject.ms~~ |
| ~~7~~ | ~~NRVO~~ | ~~DONE~~ | ~~Codegen~~ | ~~Out-param signature in declarations.ms~~ |
| ~~8~~ | ~~Goto-based exceptions~~ | ~~DONE~~ | ~~Codegen~~ | ~~Label-based goto in statements.ms~~ |

**Pipeline parity achieved for all implementable gaps.**

## Codegen-Level String/Array Parity

| # | Gap | Status | Details |
|---|-----|--------|---------|
| ~~9~~ | ~~COW string mutation guard~~ | ~~DONE~~ | ~~`ms_prepare_str_mutation(&s)` before `ms_string_set_char` in expressions.ms~~ |
| ~~10~~ | ~~Fused string append~~ | ~~DONE~~ | ~~`s += rhs` → `ms_string_append(&s, rhs)` in inject.ms (skip save/concat/destroy)~~ |
| 11 | Swap builtin | DEFERRED | Needs generic `T` support in std/core.ms |
| 12 | Slice/openArray | BLOCKED | Needs `Span<T>` type |

## Summary: DEFERRED (needs new language features)

| Gap | Nim Source | Blocker |
|-----|-----------|---------|
| Fixed-size arrays `T[N]` | `array[N, T]` (system.nim) | NOW | TypeKind.SizedArray + stack codegen infrastructure DONE. Parser needs T[N] syntax. |
| Span\<T\> (non-owning view) | `openArray[T]` (system.nim) | IN-PROGRESS | TypeKind.Span + codegen infrastructure DONE. Needs openArray calling convention. |
| Concepts / type classes | concepts.nim | Type system design |
| Multi-methods + VTables | cgmeth.nim + vtables.nim | Language feature |
| Template/macro system | semtempl.nim + VM | Hermes VM integration |
| Converter procs | implicit conversions | Language feature |
| Proc inlining | inliner.nim | @inline implementation |
| Spawn / parallel | spawn.nim | Threading model |
| Borrow/cursor inference | varpartitions.nim | Needs CFG + Span\<T\> |
| Isolation check | isolation_check.nim | Needs threading |
| Custom numeric literals | lexer.nim | Syntax extension |
| Unicode operators | lexer.nim | Syntax extension |
| RTTI V2 | ccgtypes.nim | Runtime design |

## Summary: NOT APPLICABLE

| Gap | Why |
|-----|-----|
| ~~Significant whitespace~~ | ~~MetaScript uses braces~~ |
| ~~Source filters~~ | ~~No equivalent concept~~ |
| ~~Lift locals pragma~~ | ~~Niche feature~~ |
| ~~C++ target~~ | ~~C only~~ |
| ~~Hot code reloading~~ | ~~Not in scope~~ |
| ~~GC traversal~~ | ~~ARC/DRC only~~ |

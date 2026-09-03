\# NIM-REF — MetaScript ↔ Nim Reference Mapping



> \*\*Canonical answer to "are we diverging from the reference here, and why?"\*\*

> This is an architecture/design guideline, not a task tracker. When a subsystem's

> design feels uncertain — \*should we do what Nim does?\* — the answer is here, with

> the concrete reason. If it isn't here, add it rather than guessing.



The standard reference is the Nim compiler (`\~/projects/nim/compiler/`). MetaScript's

self-hosted compiler is grounded in it, especially for DRC (`injectdestructors.nim`),

transforms (`transf.nim`), and lifecycle hooks (`liftdestructors.nim`).



\## 0. The parity principle



\*\*Parity means SAME COMPILER BEHAVIOUR — correct type-checking, transforms, codegen,

memory management — NOT identical internal representation.\*\* Two implementations can

reach the same C output by different internal routes. A divergence is legitimate when

it produces the same observable result; it is a bug when it produces a different one.



Every divergence below is one of:

\- \*\*SAME\*\* — we do what Nim does (the default; not listed unless worth confirming).

\- \*\*DIVERGE-INTENTIONAL\*\* — different mechanism, same result, with a concrete reason.

\- \*\*DIVERGE-INCOMPLETE\*\* — we intended to reach Nim's coverage but a piece is unwritten

&#x20; (a latent gap, not a design choice). These are the ones that bite.



\*\*How closely to track Nim, by subsystem (the anti-flip heuristic).\*\* When a new "should we

match Nim here?" question arises: track Nim \*\*most strictly where getting it wrong is a silent

miscompile\*\* — DRC / ownership / lifecycle-hooks (`inject.ms`, `destructorLifting.ms`), where a

divergence = UAF/leak; read Nim's source line-by-line and match the algorithm. Track it \*\*loosely

where the concern is structural/representational\*\* — AST shape, checker pass layout, type

representation, C-file layout — where MS's own design is cleaner for our goals (multi-backend,

TS-surface) and reaches the same observable behaviour. Frontend (parser/checker) is the freest;

the \*\*transform → mono → DRC-analyzer middle is where the reference genuinely lives\*\* (near-mirror

of `transf.nim` / `injectdestructors.nim` / `liftdestructors.nim`); backend follows `cgen.nim`

except the shared-header layout. Rule: the more a change touches memory ownership, the closer to

Nim it must stay.



\---



\## 1. Mapping table (by subsystem)



| Subsystem | Nim | MetaScript | Verdict | Why |

|---|---|---|---|---|

| \*\*AST shape\*\* | generic `sons: seq\[PNode]` + index constants (`namePos=0`…) | named-field discriminated union (`FunctionDeclData.fnReturnType`) | DIVERGE-INTENTIONAL | self-documenting + type-safe; cost = adding a field touches all construction sites. We accept it. |

| \*\*Type annotations\*\* | parser builds type-AST nodes; sem resolves on demand | stored as \*\*strings\*\* (`"Node\[]"`), `resolveAnnotation` parses them in Pass 2 | DIVERGE-INTENTIONAL | simpler; same resolved Type at the end. New type syntax needs a `resolveAnnotation` update. |

| \*\*Checker structure\*\* | semantic analysis is largely \*\*single-pass, on-demand\*\* (`sem.nim`/`semexprs`/`semstmts` recurse into a symbol's dependencies lazily as they're referenced) | explicit \*\*3-pass\*\*: `collectPass` (gather all declarations) → `resolvePass` (parse type annotations, enrich symbols) → `checkPass`/`checkExprPass` (infer + validate bodies) | DIVERGE-INTENTIONAL | eager, ordered passes resolve forward references and mutual recursion cleanly without Nim's lazy on-demand machinery — collect every decl first, so a body checked in Pass 3 sees all symbols regardless of source order. Same end result (all symbols resolved, all bodies checked). Same eager-vs-lazy philosophy as Import resolution below. Cross-module resolution via `ExportRegistry`. TRAP FIXED 2026-07-19: `resolveVariable` early-returned on ANNOTATED vars, deferring their type to Pass-3 source-order body checking — a fn body ABOVE a module-level `let` saw Unknown and miscompiled SILENTLY (extension-method lowering missed → raw `->push` on msRefArray in C; no checker diagnostic). That broke this row's own order-independence guarantee. Annotated module vars now bind their type in Pass 2 (mirrors resolveExtern; Shaping machinery covers forward aliases). Repro pair: fn-before-decl vs decl-before-fn (m6a/m6b). |

| \*\*Object construction — missing fields\*\* | `collectMissingFields` (semobjconstr.nim:160-173): a field with no assignment is default-initialized; it is an ERROR only when `needsFullInit`, `sfRequiresInit in flags`, or `r.sym.typ.requiresInit` | same rule; MS's `requiresInit` set is exactly \*\*function-typed fields\*\* — checked in `checkExprPass.ms` next to the excess-property check. Value/nullable/array fields keep default-init | SAME | 2026-07-28. MS previously had NO check at all: a missing field zero-inits, so an unimplemented interface method was a NULL function pointer → SIGSEGV with no diagnostic (Neon's `terminalHost` missing `setStyle`; 8-line repro exits 139). A function type has no valid zero — that IS Nim's `requiresInit` condition — so rejecting it is parity, not a TS-style tightening. Opt out by declaring the field `((…) => T) \\| null` and handling the null. Measured blast radius before enabling: 167 missing-field sites across the recompiler + Neon, \*\*none\*\* function-typed → 0 fallout. Guard `src/test/fixedbugs/bug058.ms` (3 tests, incl. two that pin default-init for value/nullable fields). \*\*DECIDED 2026-08-13 (surface DIVERGE-INTENTIONAL layered on the SAME verdict):\*\* `?` now desugars to `(T) | null` — `optionalizeTypeString` (`utils/string.ms`, `=>`-aware top-level-null scan, idempotent on an existing `\\| null`) applied at the 3 sites that used to discard the token: interface field + class property (`parser/statements/declaration.ms`), anon object-type field (`resolvePass.ms`). The requiresInit algorithm is UNTOUCHED — a desugared optional fn field routes through the same `T \\| null` door a hand-written union takes; `?` never reaches the checker. Fail-loud edges: `?` on a struct (value type) field and `?` on a class method are parse errors. NOT adopted, unchanged: the full-TS required-fields rule; postfix `T?` (still consume-and-skip, separate arc); bare-read-without-narrow still compiles (row 76's flow-narrowing scope note — reading an un-narrowed value-type optional yields the Maybe carrier, pre-existing behavior verified identical with hand-written `\\| null` on the pre-fix binary). Measured: suite 3453/3453, corpus parity 455/0 + SAN 108/0 (earlier 26 "fails" were concurrent-corpus-run cache trample — two `run.ms` sharing `out/\*/.cache`; solo rerun 0 fail), neon 292/292, guards ALL GREEN, gen-1/gen-2 self-host. Guards: corpus `015-optionalFieldNull` (proven RED on the pre-fix binary: "field 'cb' must be initialized"), 3 parser pins in `declaration.ms`. Latent pre-existing sibling found en route (own ticket): arrow literal assigned to a `fn-returning-`\\|`-null` field miscompiles C (`\*\_\_result = x` into `Maybe\_p10` — contextual return coercion misses the Maybe wrap; rows 82/85 family). |

| \*\*Tail-call optimization\*\* | none in the compiler — no TCO pass exists (grep of the reference compiler = 0 hits); the C backend relies on the C compiler's sibling-call optimization at `-O2`+, and the JS backend emits a plain recursive call | `transform/lowering/tailCallLower.ms` rewrites self-recursion into `while (1)` + loop-carried locals + `continue` at the AST level, for \*\*both\*\* backends | DIVERGE-INTENTIONAL | Measured 2026-08-14: MS at `-O0` runs 50M self-recursive frames in 0.17 s / RSS 2.2 MB; the reference in debug mode dies at call 2000, and in release with ARC + a `string` param it \*\*segfaults (rc=139)\*\* at depth 2M — the destructor injected after the call blocks the sibling-call optimization, which is exactly the case a systems language cares about. Doing it in the transform (before the analyzer injects DRC) makes O(1) stack independent of opt level, and is the only way to get it on JS at all — no JS engine but JSC ever shipped ES6 proper tail calls. Covers \*\*self\*\*-recursion only; mutual recursion still depends on the C compiler. |

| \*\*Assignment to a parameter\*\* | \*\*forbidden\*\* — `Error: 's' cannot be assigned to`; consequently `injectdestructors` models params as borrowed (`injectdestructors.nim:215` — `skParam and not isSinkType` → copy, never own) and never destroys them | allowed (TS compatibility); `transform/lowering/paramReassignLower.ms` (C only) redirects every assigned param through an owned shadow local before the analyzer runs | DIVERGE-INTENTIONAL (language rule) / was DIVERGE-INCOMPLETE (analyzer) | We adopted the borrowed-param model but not the rule that makes it sound, so an owned value stored into a param slot was never destroyed — a leak in EVERY function that assigns a param, not only tail-recursive ones. Measured 2026-08-14: 5M calls of `s = s + "x"` on a `string` param = 82 MB RSS; the same logic hand-written over a local = 2.2 MB. The fix normalizes to `let local = param`, which is the shape the reference forces a programmer to write, so the already-proven local sink/destroy path applies and no new ownership rule enters the analyzer. Shadow locals are named `\_\_prs\_N` / `\_\_tcp\_N`, \*\*not\*\* `$…`: `analyzer/inject.ms:1691,1971` treat any `$`-prefixed local initialized from an identifier as a cursor (borrow, never destroyed), which silently reproduced the original leak. |

| \*\*Import resolution\*\* | lazy on-demand lookup in module interface tables | eager copy of imported symbols into scope (`collectImport`) | DIVERGE-INTENTIONAL | simpler, sufficient at our scale; same resolvability during checking. |

| \*\*C output layout\*\* | per-module self-contained `.c` (re-emits needed types) → incremental | single shared `msProto.h` (topo-sorted) + per-module `.c` `#include`s it | DIVERGE-INTENTIONAL | simpler, no duplicate type defs; trade-off = lose incremental compile (any type change rebuilds header). Acceptable at our scale. |

| \*\*Expression-with-statements\*\* | `nkStmtListExpr` — a statement-list that is also an expression (value = last child); lets the analyzer hoist a temp \*\*in place\*\* at any expression position | \*\*no such node\*\* (FINAL — see §3 ⛔). Instead: the analyzer captures fresh owned values via the consolidated `ensureDestructionIfNeeded` in `processNode` (§3 Status), and conditional-eval positions are lowered expr→statement in \*\*Phase-3 transforms\*\* (`conditionalExprLower` ternary→if, `resultDesugar` try→stmts, `rvalueLower` receiver→temp, `callHoist` short-circuit/ternary/loop→control-flow); `match`-expr/`try` already lower via temp-hoist (`matchLower.ms:47-56`) | DIVERGE-INTENTIONAL (committed) | \*\*Two questions, do not conflate (§3 ⛔): Q1 node = NO (the node is the inline wrapper; the substance is temp + `s.final` destroy, which MS's hoist reproduces identically — `ensureDestruction` injectdestructors.nim:526; all 3 backends flatten an inline stmt-expr regardless → zero codegen benefit). Q2 algorithm = YES, \*\*DONE 2026-06-05\*\* — the once-eval capture is consolidated in `processNode` (Nim's central `p()` shape) and fires for all 5 fresh-owned producers; the call-arg gap that caused the Photon leak is closed + native-gated, see §3 "Status — CLOSED").\*\* |

| \*\*DRC scope cleanup\*\* | destroy for EVERY owned local goes into `s.final` at decl (`pVarTopLevel`, injectdestructors.nim:582) and is NEVER removed; a move emits only an inline reset at the occurrence (`destructiveMoveVar`, via `nkStmtListExpr`); destroy-on-zeroed is a runtime no-op — path-sensitivity lives 100% at runtime | SAME model (unified 2026-07-15): unconditional destroys in `generateCleanup`; moves blit + zero via `destructiveMoveVar` §3-hoisted to preStmts; `msWasMoved(p)=((p)=NULL)` + NULL-guarded `msDecref` make skipped-path destroys no-ops | SAME + two traps | \*\*Trap 1: injection must NEVER elide a destroy at compile time.\*\* The pre-unify per-scope `wasMoved` set was path-INSENSITIVE → any non-dominating move (sink in a no-else `if`, `return x` vs `return y`) leaked the not-taken path (engine bug #B, \~375/game). The ONLY legal compile-time elision is the path-aware POST-pass `optimize.ms` — an MS extra; Nim relies on the runtime no-op alone. \*\*Trap 2: §3 hoisting of the zero is NOT order-neutral.\*\* Nim's zero sits inline at the occurrence; MS pre-hoists it, so any EARLIER same-statement read of the moved var (call args, Ptr-field borrows — `sgGetSignatureContext`, `createSymbolTable`) must be captured in evaluation order first: `stmtBorrowReads` + `retroHoistStmtReads` (inject.ms) rewrite those reads to borrow temps. The invariant is EXACTLY "reads that remain INLINE in the statement body": reads absorbed into earlier preStmts by mid-statement branch lowering execute BEFORE the zero and must be DISCARDED (rewriting them = $pborrow use-before-assign garbage), while the enclosing statement's list must SURVIVE the nested lowering (save/restore in `processBranchAssign` + the assignment-ternary arm; clearing it = missed capture, NULL read). Probe shapes: `{cur: g as Ptr<S>, flag: c?1:2, all:\[g]}`, `flag: c?k:peek(g)`. Single-use DRC temps consumed by an enclosing expression ($cond from ternary lowering) must ALSO route through `destructiveMoveVar`, not rely on cleanup skips. \*\*This trap is the sanctioned reopening condition for §3 Q1: three shapes of this class are closed by the one invariant above; if a FOURTH shape appears that the invariant does not cover, stop patching and re-litigate the stmt-expr decision (§3) instead.\*\* |

| \*\*DRC universal walk\*\* | `p(n, c, s, mode)` recurses EVERY position (vardecl init, assign RHS, call args, \*\*conditions\*\*, literals); `ensureDestruction` captures fresh temps anywhere | the analyzer captures \*\*every fresh-owned producer\*\* (Call/Object/Array/New/Closure) via ONE consolidated `ensureDestructionIfNeeded` call in `processNode` after dispatch, reaching every position the mode-carrying walk reaches; `callHoist` retains only the conditional-eval lowering (short-circuit/ternary/loop) | SAME (functionally) — \*\*CLOSED 2026-06-05\*\* | was DIVERGE-INCOMPLETE: the per-statement `callHoist` enumeration left \*\*call-argument\*\* uncovered (the Photon leak, 2026-06-01). Now the once-eval capture is consolidated in `processNode` (Nim's central `p()` shape) and fires for all 5 fresh-owned producers — the Photon object-literal leak + its 4 siblings (array/new/closure/call-result as a stored call-arg) are fixed and native-gated (leak-callarg-\*, leak-arraylit-callarg, leak-new-callarg, leak-closure-callarg, paralock-nested). Materialization stays hoist-to-temp (not Nim's inline `nkStmtListExpr`); same result. A narrow compile-time \*\*fail-loud\*\* (inject.ms) fires if an env-bearing closure-pair reaches DRC without a nodeType. See §3. |

| \*\*Capture of call returns\*\* | `ensureDestruction` driven with ownership info | every RC return is made \*\*owned for the caller at the return site\*\* (`needsReturnIncref` increfs Ref, String/Array deep-copied), so capturing+destroying any call return — even a "borrow accessor" — is balanced | SAME (no fresh-vs-borrow wall) | verified native: borrow-accessor capture stays flat, container intact. The only capture constraint is POSITION (don't hoist out of a short-circuit), not type. See §3. |

| \*\*Param passing\*\* | ALL objects by-pointer unconditionally | track mutation via `mutatedParams`; unmutated struct params get `const T\*` | DIVERGE-INTENTIONAL | better optimization — proves immutability. |

| \*\*`console.log` debug\*\* | requires `$`/toString; error if missing | JSON debug fallback via stringify | DIVERGE-INTENTIONAL | TS convention — always shows something. |

| \*\*Lambda lifting: array params\*\* | copies value to env; forbids capturing `var` params (`illegalCapture`) | stores `Ptr<T>` in shared env for ccgIntroducedPtr params | DIVERGE-INTENTIONAL | MS arrays are reference types (JS semantics); closure + caller must share. Nim's `seq` is value-type so copy is correct there. |

| \*\*Lambda lifting: ancestor captures (nested-closure shared vars)\*\* | a captured var lives in EXACTLY ONE env — the frame that declares it; inner procs read it by walking the `up`-chain (`accessViaEnvParam` loops `env.up.up…` until the field is found, lambdalifting.nim:529). `up` is an owning ref that keeps the parent frame alive. | FIXED 2026-07-21 (`lambdaLifting.ms`, up-chain, single-file). `setupSharedEnv` no longer copies an ancestor capture into each intermediate shared env; it SKIPS the field, wires `$up = \_envP` (the enclosing env the closure-pair already carries), and records a compile-time ancestor-env chain (`sharedEnvChainNames/Types`). `rewriteNode`/`chainWalkAccess` walk that chain — N `$up` hops — to reach the one storage slot; `rewriteOuterRef` walks it too (from the named env var) for an ancestor ref at the closure's own scope. `$up` is an owning `Ref<parentEnv>` (Nim's owning `up`): the chain supplies each hop's type at compile time, and the ref keeps the parent frame alive. | was DIVERGE-UNINTENTIONAL → SAME (up-chain access + owning `$up`) — \*\*but the LOOP path had no parity until 2026-08-07\*\*, see addendum | \*\*Bug D (nested-closure write-loss).\*\* The old "copy-cascade" duplicated the captured VALUE into every intermediate env, so a nested closure's write hit the copy, never the slot (repro `let c=0; run(()=>{ const inner=()=>{c=c+1}; inner() }); // c stayed 0`). Copy was UNDOCUMENTED → unintentional; return to Nim's up-walk (which MS already had as `chainWalkAccess`, 1-hop → now N-hop). Verified: repro `c=1`, neon `dispose.test` 4/4 (was FAIL), battery 3323/14 = known-flake set only, 0 closure-area regressions. \*\*Lifetime — owning `$up` (commit `584b2da`).\*\* Typed `Ref<parentEnv>` → DRC increfs on wire, ORC decrefs on env destroy, so an escaping closure keeps its ancestor frame alive. Acyclic + short chain → no cycle, no destroy-recursion. Confirmed empirically: a 2-level escaping counter factory SIGTRAPs (\~8 iters) with a non-owning `$up`, but is clean (bad=0, final=101 over 100 iters + heap churn) once owning. Surfaced with it: `rewriteOuterRef` also needed the chain-walk — an ancestor ref at the closure's OWN scope (`return c`) was miscompiling to `\_envN->c` for the skipped field. Two commits: `1d1f710` (up-chain access) + `584b2da` (outer-ref chain-walk + owning `$up`). Not "option A vs B": A (Ptr-promotion via `EnvPromotedPtr`) was a self-invented second mechanism duplicating `chainWalkAccess`; rejected per `/trace-nim` (follow Nim, don't invent a peer divergence). \*\*ADDENDUM 2026-08-07 — the loop path never had this parity (bug D survived inside loops).\*\* The SAME verdict above was only ever measured for non-loop closures: at a LOOP site the closure pair carries a per-closure snapshot env, and `setupSharedEnv` still cast `\_envP` to the enclosing shared env → out-of-bounds `$up` (8B env read as 16B), plus `insideLoop` leaked into closure bodies forcing INNER closures onto the snapshot path (a private copy = bug D's write-loss one level down), plus the captured cell lived per-call. Fixed by deciding env-kind BEFORE the body walk: `createSnapshotPairEnv` builds the pair env pre-walk from the full capture set, `setupSharedEnv` wires `$up` against its real type, `walkLiftBody` resets `insideLoop` per frame. The ancestor-capture mechanism stays SAME (one storage slot, up-chain walk); ONE scoped divergence is now DOCUMENTED-INTENTIONAL: \*\*Nim has no per-iteration binding\*\* — at a loop site MS snapshots the full capture set into the pair env at closure creation (JS `let`-per-iteration approximation, consistent with the pre-existing direct-capture snapshot), and chain walks terminate at the pair env because its fields are complete. Guard: `fixedbugs/bug092`. |

| \*\*Generic return inference\*\* | `inheritBindings` — contextual fills GAPS only; arg-bindings win | when both arg + contextual bind T, prefer the SUPERTYPE if arg is assignable to it | DIVERGE-INTENTIONAL | TS contextual-typing parity; needed for int32/number widening (`let x: Result<number,string> = ok(int32\_var)`). |

| \*\*`unknown` top type — repr + conversions\*\* | no runtime top type in Nim; the model is `pointer`: typeRel tyPointer accepts ONLY nil/ptr/proc/cstring implicitly, value types REJECTED (sigmatch.nim:1602-1620); nilable pointers use nil-as-sentinel, only value types get a wrapper (options.nim:90-99 SomePointer split); `pointer` is RC-inert | `unknown` = `void\*` (getTypeDesc:713). FIXED 2026-07-20, 6-file set, all gates baseline-green. THREE independent unintentional divergences found under one symptom: (1) \*\*kind overload\*\* — TypeKind.Unknown was BOTH the pending-inference sentinel ("inference pending, allow", compat.ms:119) and user `unknown`; blanket gates in fitNode/checkCallExpr (5c32d00) existed to protect pending and silently swallowed user-unknown conversions too. Split: annotation `"unknown"` now mints a FRESH type stamped TypeFlag.UserUnknown (bit 23) in resolvePass; `"any"` was left pointing at the permissive singleton — \*\*CLOSED 2026-07-30: `any` is now a REJECTED annotation and `undefined` resolves to `null` with a migration warning\*\* (see the row below; `unknown` is the sole user-facing top type). (2) \*\*repr split violation\*\* — isMaybeWrappable classified Unknown value-shaped (via isPrimitiveKind) so `unknown\\|null` built a Maybe struct while `Ref\\|null` collapsed to bare pointer; Unknown moved to the pointer branch (its own options.nim citation demanded it), unwrapRefNullUnion + isPointerType gained Unknown arms → `unknown\\|null` collapses to bare `void\*`, null IS the sentinel, wrap/unwrap machinery unreachable by construction. (3) \*\*RC classification\*\* — classify's Union arm sent collapsed-unknown into the Ref branch (msDecrefCyclic on raw void\* = SEGV, probe u1); now noRcInfo beside Ptr (pointer is RC-inert, may hold foreign handles). Follow-ons fixed by (2): shimCallArg no longer takes `\&(arg)` (param and arg both pointer-typed now); value-shaped×unknown flows DIAGNOSED at fitNode/call-args/casts when UserUnknown (no void\* repr for string/struct/closure — Nim typeRel parity), pending stays lenient. (Cast site extended 2026-07-23 to peel the nilable-union form `unknown\\|null` — it had inspected only bare `unknown`; see the Value-type Maybe unwrap row.) | was DIVERGE-UNINTENTIONAL (×3) → SAME (Nim pointer model) | d1.patch (prior HANDOFF) carved a Maybe\&lt;unknown\&gt; wrap INTO the wrong repr — superseded and reverted. Verified: probe u1 all-paths green (C shows bare void\* params, `ref == MS\_NIL`, cast-out member reads); neon render host 274/274 + hostOps 274/274 (first-ever green), element/renderToString unchanged; battery 3326/7 = known-fail set exactly; native 120/0; engine 332/333; play30 ORC acc=6844, no leak dump. OPEN siblings (separate rows/arcs, unmasked not caused): nested-fn capture drops outer-var C decls (`cur`/`pool`/`h`, reconcile tests); generic-instantiation scope losses (`CompState\_Clean`/`makeRowInto`/`T` — flow/region); value→`unknown\[]` element-position diagnostic hole (counter push macro path bypasses checkCallExpr); Phase-C builder swallows per-TU cc failure then links (undefined-symbol noise masks the real clang error — collect loop after dispatchCompileJobs lacks the @compile-path exit(1) mirror, compile.ms \~596). SAGA COMPLETION 2026-07-20 (post-commit followups, installed msc RESYNCED to gen-2): (1) value-shape rule MOVED from the cast site to MATERIALIZATION sites (fitNode/call-args peel through TypeAssertion chains) — the `{...} as unknown as NodeData` idiom is type-level (unwrapAsUnknown collapse) and must not error; explicit cast chains reinterpret pointer-SIZED scalars per Nim isCastable (semexprs.nim:320, dstSize>=srcSize/integral; ARC forbids integral<-string) — int64/bool/char/enum legal `(void\*)(x)`, fat values still diagnosed; small-struct reinterpret (Nim-legal, size<=8) UNIMPLEMENTED, no consumer. (2) isPointerType(Unknown) must be FLAG-GATED (UserUnknown only): kind-based made PENDING-typed scalar exprs (test-mode instrumented) 'pointers' -> shimCallArg deref'd int32 args = the types.ms:1805 gen-1 miscompile + the gen-2 Maybe\_p6 resurrection; with the gate, gen-1===gen-2 fixed point (battery 3326/7 both, u2 interface-closure probe green both). (3) R4 build-path abort landed (moduleCompileFailed exit(1) before link, solana-exempt, mirrors the test path). BOOTSTRAP RULE: any checker-RULE change must rebuild via msc-it3 (gen-0) first — a same-rules binary rejects the tree's own idioms mid-migration. DEPLOY TRAP: cp over an existing Mach-O SIGKILLs (signature cache) — rm first + codesign -s -. \*\*SUPERSEDED by the kind split (landed 2026-08-06; docs/UNKNOWN-BUG.md retired):\*\* the flag model above was the interim fix — `TypeFlag.UserUnknown` is DELETED and each meaning owns a kind, exactly Nim's model (tyPointer/tyInferred/tyError/tyNone): `Unknown` = user top type (void\\\* repr, fresh per call), `Inferred` = pending inference (the sole `isUnresolvedType`/compat-leniency kind), `Error` = recovery + cancelled checks, `None` = no-type node kinds, deliberate raw pointers = `Ptr<void>`; the legacy `Pending` kind is UNCONSTRUCTIBLE (`pendingType()` deleted — the compiler itself proves the migration), and `getTypeDesc` answers any sentinel kind with Nim's else-branch internal error (`gateFlaglessUnknown`, armed after the pending-at-emission population measured EMPTY: battery + Neon sweep + self-build). The bug generator this killed: three readers (emission / checker conversion gate / arg shim) answered "is a flagless Unknown a pointer?" differently, so dropping the flag = memory corruption with no diagnostic (bug076 was the fourth child of this root). Standing rule: a NEW meaning gets a NEW TypeKind — never a flag, never a shared singleton. Canonical semantics map: the sentinel-kind comment at `unknownType` (src/checker/types.ms). Guards: `handoff/{unknownKindReaders,noneKindNoType,b3InferredKind,b4ErrorRecovery}.ms`, `fixedbugs/bug069\\|bug076\\|bug084\\|bug085`. |

| \*\*Container element ops for `unknown` (seq\[pointer])\*\* | container hooks lifted PER ELEMENT TYPE: tySequence → useSeqOrStrOp/fillSeqOp inlines the element's op (liftdestructors.nim:1015/603); tyPointer → defaultOp = inert (:978) — a seq of pointers touches NO elements on destroy/copy; entry/exit symmetry holds by construction | ONE runtime msRefArray family with HARDCODED element ops (Destroy/Splice decref, array.c:547/646; "the array owns its elements — push moves in"); entry side is compile-time classify. UserUnknown elements: classify says noRcInfo → push/store/Map-get emit NO rc transfer, but runtime exits still decref = net −1 per array death → premature free → UAF (neon reconcile slab poison, freelist next `0xffffffff00000000`). FIXED 2026-07-20: classifyArray UserUnknown arm (peels `unknown\\|null`) → inert hook set; box-site destroyFn → msNumberArrayDestroy — the Actor-exemption shape (same reason: elements the array must not own). PLUS pre-existing roulette healed: inert msRefArray cells now get their OWN weak TypeInfo `msPtrArrayRefCell` — the shared `msRefArrayRefCellTypeInfo` was first-ensure-wins per module + last-DatInit-wins across modules, so mixing counted+inert element families in one program scrambled the destroyer (Actor arrays lived on this mine; px A/B showed typed arrays silently going free-only = leak) | was DIVERGE-UNINTENTIONAL → SAME (Nim seq\[pointer] via kind-selected hooks) | Entry-side repair (sinkClassify §4, the Ptr\&lt;T\&gt; precedent) is UNSOUND here: unknown may hold an int-cast non-heap scalar (isCastable) — no rc header to incref; the CONTAINER side must go inert, exactly Nim's tyPointer defaultOp. LATENT (accepted; phase 2 = dedicated msPtrArray kind): `.splice` on `unknown\[]` still routes to counted msRefArraySplice/Splice3 (decref/incref raw void\*) — no current consumer (neon render + std Map audited; Map is open-addressing, never splices); Actor arrays share this hole. Gates: standalone reconcile port probe green; neon reconcile 2/2 + reconArrow 2/2 (first pass ever) + render suite at baseline; unit 3326/7 known-set; native 120/0; engine 332/333; play30 ORC acc=6844 0 leaks; gen-1≡gen-2 fixed point. |

| \*\*Monomorphization\*\* | post-sem instantiation pass | eliminated separate pass — mono at checker site (Nim parity, collect.ms 890→55 lines) | SAME (cleaner) | name-indexed DCE; same monomorphized output. |

| \*\*Extern (importc) decls never get generated bodies\*\* | cgen skips body emission for imported procs — importc is a binding, not a definition | `genFunctionDecl` keyed extern ONLY on `sym.ImportC`; `methodToFunction` lifts `static extern log(...) from "msPrintln"` into a FunctionDecl carrying `fnFlags="extern"`+`nativeName` but NO resolvedSym → when the name-indexed DCE fallback (reachability.ms MemberExpr, no resolvedSym on FIELD accesses) marked it alive BY NAME, codegen emitted an empty-body `static void log(msRefArray\*)` colliding with libm `log(double)`. Repro: any interface field or captured local named `log`. | was DIVERGE-INCOMPLETE → SAME (fixed 2026-07-31, 2bc5693) | `isExternFn`/`hasNativeName` in `genFunctionDecl` now also read the node's own `fnFlags`/`nativeName`; same guard mirrored in `genMethodAsFunction` (defensive — unreached post-lift). The name-fallback over-marking itself is within the name-indexed DCE divergence (this row's neighbour) and stays: harmless once externs can't be defined. Pinned by `fixedbugs/bug072ExternMethodLiftedEmit.ms` (proven RED on pre-fix binary). |

| \*\*Lowered decls always carry their symbol\*\* | transf-introduced temps/locals always reference a PSym; cgen assigns unique loc names per-sym (fillLocalName parity) | `lowerMatchExprInVar` rebuilt `const x = match(...)` as `let x; if-chain x = arm` WITHOUT the original resolvedSym, and `emitResult` assigned via bare `makeIdent(name)` — genVarDecl left the sym-less decl un-hoisted (raw C name) while the bare refs resolved through `lookupLocalName`'s last-wins name map into a SAME-NAMED sibling `let`'s hoisted slot (`kw\_1\_`): first sink destroyed an uninitialized slot (sgFormatHover SIGABRT) or double-destroyed the sibling's value. Bisect blamed an innocent runtime commit — uninit-read symptom flips on unrelated binary-layout changes. | was DIVERGE-INCOMPLETE → SAME (fixed 2026-07-31) | `letDecl.resolvedSym = stmt.resolvedSym` + `assignSym` threaded through `buildIfChain`/`wrapArmBody`/`moveInto`/`emitResult` so assign-mode LHS uses `makeIdentResolved` (nested-hoist path passes its `resultSym` too). Corpus `240/241/242-matchShadow\*` (241 proven red, exit=133 all native lanes) + `fixedbugs/bug073MatchShadowedLetSlot.ms`. |

| \*\*DRC convention\*\* | alloc at `rc=1` (sole owner); `nimDecRefIsLast` true at `rc==1` | alloc at `rc=0` (sole owner); `msDecRefIsLast` true at `rc==0` | DIVERGE-INTENTIONAL | \*\*offset by 1\*\* — both correct, do not confuse when porting RC patterns. Nim callee-increfs ref returns; MS callee returns rc=0 and caller takes ownership. |

| \*\*UTF-16 `.length` walk + append flag compose (string runtime)\*\* | `runeLen` (stdlib unicode) is an OUT-OF-LINE branchy skip-walk (`elif` chain advancing by 1/2/3/4 bytes), called per use, no cache of any kind; `add` appends in the caller's TU | `.length` = UTF-16 code units (TS parity) with a 2-bit cached ASCII answer in the payload cap word (CHECKED bit 61 / ASCII bit 60): O(1) on known-ASCII, else `msStringLengthWalk` — a noinline \*\*stride-1 byte-classification count\*\* (`count += (c\&0xC0)!=0x80; count += c>=0xF0`), NOT the reference's skip-walk; appenders compose the cached answer in BOTH directions (2026-08-16: non-ASCII src ⇒ CHECKED+nonASCII for any dest state — kills the IsAscii re-scan after every append); `msStringAppend`/`msStringAppendChar` are static-inline fast paths in `string.h` (cap-check + memcpy + zero-or-one flag store), slow paths (`\*Slow`) in `string.c`; `msStringPrepareAdd` stays the sole gateway for C-side byte writers (socket.h) and still retracts | walk shape = DIVERGE-INTENTIONAL; flag cache = DIVERGE-INTENTIONAL (TS `.length` needs it, the reference has no equivalent surface); inline append = SAME in structure | Measured 2026-08-16 (twin probes, MIN of interleaved rounds): the reference's skip-walk SHAPE compiled under MS's `--danger` LTO pipeline gets if-converted to csel — the pointer advance then depends on each byte load, serializing at \~8 cycles/char = 6.5x slower (0.52s vs 0.08s over 400MB of 2-byte chars); proven standalone (csel-forced twin 0.57s vs branchy 0.081s) and `noinline` does NOT escape it (the LTO backend csels the out-of-line body too — measured, do not retry that fix). The stride-1 count has NO data-dependent advance — nothing to serialize, NEON-vectorizes, 0.10s = 1.25x of the reference, and is immune to branch-mispredict on mixed ASCII/non-ASCII data where the branchy walk degrades. Answers are identical on valid UTF-8/WTF-8 (each lead byte counts once, lead ≥0xF0 adds the surrogate twin); pinned by corpus `105-utf16Parity` (byte-matched against a Node oracle). Compose-negative kills the double-walk: ASCII-prefix probe 0.11s→0.05s. Residual gap: append+`.length` compound loop = 1.46x (0.41 vs 0.28 over 200M iters) — attributed by asm to `\&s` escaping into the slow-path call (msString stays memory-resident, store-to-load round-trip per iteration) + `.length`'s flag verification vs the reference's direct `len` field read; closing it needs codegen-side register caching across statements — separate arc, do NOT chase it in the runtime. A char-COUNT cache stays BANNED (no harmless-stale direction, ≥6 hand-built payload sites — see the litconst decision 2026-08-16). |

| \*\*Exception RC (catch consume + async carry)\*\* | `genTryGoto` (`ccgstmts.nim:1443`) emits `popCurrentException()` (`currException = currException.up`, `=copy` destroys the old = the single free) after EVERY handler, bare or named; named `as e` = `getCurrentException()` \*\*incref\*\* + `eqdestroy(e)` — a balanced pair layered on top, not the primary free. Closure iterators bind `:curExc` via \*\*`nkFastAsgn`\*\* (NO incref, `closureiters.nim:1233`). The currException stack (`.up` chain) preserves an outer exception across a nested/re-raise handler. | Single-slot `msCurrException` (NO `.up` stack). The single ref is consumed exactly once per handler: \*\*bare `catch {}`\*\* → `msDiscardCurrentException()` (decref+null = single-slot popCurrentException); \*\*named catch-var\*\* → borrow bind + analyzer `msDecref(e)` at handler scope-end (fuses eqdestroy+pop into one decref, so `msClearException` stays null-only); \*\*async\*\* → the `$curExc` env field, typed as the exception type so it is DRC-owned \*\*even when the handler ignores the var\*\*, acquired by \*\*MOVE\*\* (matches `nkFastAsgn` — no incref), freed once by the env destructor. `genTryCatchStmt` (`statements.ms`), `buildExcRouting` + `$curExc` decl typing (`generatorLower.ms`/`asyncBridge.ms`), `msDiscardCurrentException` (`system.c`). | consume-once = \*\*SAME\*\* (adapted to single-slot); no-`.up`-stack = \*\*DIVERGE-INTENTIONAL\*\* | Single-slot reaches the same observable result — exactly one free per caught Error, zero incref — the invariant the anti-flip heuristic (§0) demands we track strictly. \*\*Pre-fix bug (leak on EVERY catch):\*\* `msClearException` was pointer-only (nulled `msCurrException`, never decref'd), so it dropped the sole ref with no owner to reclaim it — bare/empty catch (no owning binding), and async (`$curExc` increfed a phantom 2nd owner, or degraded to `void\*` when the catch var was unused → no destructor hook) all leaked. Guards: `catchReleasesException`, `awaitThrowInTryRoutes` (`GUARD-BALANCE Error`), both proven red on the pre-fix binary. \*\*Catch-body-throw / async rethrow — FIXED 2026-07-27 (was mis-filed under the `.up` gap):\*\* propagating a throw OUT of an async catch body needs no `.up` chain — it broke on two dropped pieces of the raise protocol. (1) `buildExcRouting`'s terminal re-raised `$excCaught` AFTER the unconditional `$curExc = move($excCaught)` nulled it → `msFutureFail(fut, NULL)` → awaiter saw a synthesized `"noproc"`; Nim re-raises \*\*`:curExc`\*\* — the slot just stored — (`closureiters.nim:1251` `nkRaiseStmt(newCurExcAccess())`); fixed by re-raising a typed `$curExc`. (2) The ThrowStmt arm of `analyzer/inject.ms` set `needsTry` but never walked the raise argument — Nim's `pRaiseStmt` treats it as a \*\*sink\*\* (`injectdestructors.nim:786` `p(n\[0], sinkArg)`; non-movable source → `tmp = copy; raise tmp`, `:773`). The un-sunk rethrow (`throw e` → `$curExc` env-field alias) left two owners of one ref: the routing store's self-assign `msDecref` freed it early and the env destructor freed it again — ledger-proven `DOUBLE-DESTROY of Error` pre-fix. Fixed by `processThrow`: owned-local ident → Consumed walk (move); member/element RC source → incref-copy temp (the `pRaiseStmt:773` shape, mirroring `emitReturnWithIncref`); strings untouched (`msThrow` copies — MS sugar outside Nim's ref domain). Guard `asyncRethrowPropagates` proven RED both channels pre-fix (`noproc` exit=1; single-shot `DOUBLE-DESTROY` exit=134 — a looped body balances the ledger by slab reuse even while corrupting, so the guard keeps a single-shot section) → GREEN drc+orc, ledger 27/27. \*\*Still `.up`-relevant (deferred):\*\* only `finally`-during-exception semantics (`finally-across-suspend` slice decides whether to port `pushCurrentException`/`popCurrentException` + `:finallyPath`). |

| \*\*Sink parameters\*\* | explicit `proc f(x: sink T)`; inference exists (`sinkparameter\_inference.nim`) but `optSinkInference` is NOT in DefaultOptions — OFF by default; when on, `checkForSink` mutates the param SYMBOL type in place (sempass2, before injectdestructors) so caller `sinkArg` AND callee final-scope destroy (injectdestructors.nim:1359-68) read ONE marker | NO sink params (2026-07-16, `ea38c2a`): always-on `ownershipInference.ms` REMOVED — it wrapped only the fn-type view while callee cleanup gated on never-set `SymbolFlag.Sink`, so callers moved/copied +1 in and no one destroyed (engine residual \~14 leaks/game, probe sinkprobe2 5,996) | SAME as Nim DEFAULT | re-adding sink params requires the Nim single-marker shape: one in-place type mutation read by BOTH sides, plus uniform sinkArg materialization for ALL kinds (msString call-temps and cursor-ident args crashed 3 gate attempts at callee-destroy: gen-2 double-free in path.ms join/normalize, parser UAF); partial patches /tmp/trace-b2. COROLLARY FIXED 2026-07-17: processNew still passed ctor args as `Consumed` (leftover from the sink era) while ctor callees copy like every borrow-param callee → +1 orphan per `new T(freshOrOwnedArg)` (probes: 399,998 leaks/200K iters both directions); `new T(x)` lowers to `T\_init(this,x)` = plain call ⇒ args are Normal, same as processCall. Fix exposed a second latent bug: DRC temps hoisted to module top level (`$tmp\_N`, per-module tempCounter, symbol has no modulePath) emitted as non-static C globals → duplicate symbols at link; fix = `static` prefix in genTopLevelVar for moduleless symbols (user globals always carry modulePath → module-mangled). |

| \*\*Per-type sink ops\*\* | `=sink`/`=copy`/`=destroy` lifted per type (`liftdestructors`) | per-type hooks lifted by `destructorLifting.ms`, inlined save→assign→incref→destroy at each site | SAME (mechanism differs) | both valid; a per-type `=sink` makes destroy-then-store atomic, an inline pattern with a defensive incref accidentally implements `=copy` — watch this when touching `moveOrCopy` (the 2026-05 leak). |

| \*\*Non-owning link (`{.cursor.}`)\*\* | `{.cursor.}` pragma — field/local opts out of RC; std/lists uses it on `prev`/`tail`; compiler may prove cursor-safety later | \*\*`Cursor<T>` type — SHIPPED\*\* (3df714e..a4fe5f6 + the 2026-08-20 migration): the 11 compiler-internal link sites (`CToken.next`/`origin`, `Scope.parent`, `SymbolTable.current`, 2 checkPass params) now use it; nilable via the allowsNil arm; guard `cursorFieldBreaksCycle`. `Ptr<T>` + arena-own remains for FFI/unmanaged memory only — see §5 | DIVERGE-INTENTIONAL (type, not pragma — §5 Q1) | MS `Ptr<T>` is already more ergonomic than Nim `ptr` (transparent access, no `\[]` deref), so the "cursor exists because ptr is cumbersome" pressure is weaker here. What we give up vs cursor: compiler-provable safety on those links. Acceptable for compiler-internal code; the user-facing version is the §5 backlog. |

| \*\*Cross-module proc/ctor prototype\*\* | `genProcNoForward` (`cgen.nim:1526-1546`): `genProcPrototype(m,prc)` emits a forward proto in EVERY using module + `genProcAux(q,prc)` emits the definition ONCE in the owner module `q=findPendingModule`, deduped via `m.declaredProtos` / `q.declaredThings` | regular calls: `ensureCrossModuleProto` (`forward.ms:101`) at the call site; mono'd-class \*\*ctors\*\*: a dedicated `\_init` proto emitter in the NewExpr handler (`expressions.ms`) — `void <Class>\_init(<Class>\* this, getTypeDesc(params))` matching the lifted `\_init` FunctionDecl, deduped via `g.declaredProcs` — plus the def routed to the class's owner module (`classNode.resolvedSym = classSym`, `instantiate.ms`) | SAME (Nim parity) | \*\*Do NOT regress to the old hack.\*\* Ctor protos USED to appear only as a side-effect of the per-module drain DUPLICATING the synthetic ctor ClassDecl into every consumer's program (so `genConstructor` re-ran per TU). When the drain was consolidated to a single owner-routed pass, the duplication vanished and exposed that NewExpr never emitted its own proto → 15× `<Class>\_\_T\_init undeclared`. Fix = match Nim: proto at call-site + def at owner. Ctors need a DEDICATED emitter (not `ensureCrossModuleProto`) because the lifted `\_init` has no `Symbol`/`fnType` in the export registry and uses raw `getTypeDesc` params — the definition comes from the lifted `\_init` FunctionDecl (full `shouldIndirectParam`), and NewExpr's caller promotion mirrors it; `genConstructor` itself never ran anymore and was deleted 2026-08-13 (proven: emit-C of ctor + mono-generic probes contains zero `\_new`). |

| \*\*ORC cyclic vs plain ref ops\*\* | `liftdestructors.nim:725` — under gcOrc a ref uses CYCLIC ops unless provably acyclic (`canFormAcycle`); `nimDecRefIsLastCyclicDyn` runs `rememberCycle(isDestroy=true)` = unregister-from-rootset BEFORE the destructor (orc.nim:506-516); invariant: an object mid-destruction is NEVER a registered root | classify.ms Ref/union-Ref arms → `msDecrefCyclic`/`msIncrefCyclic` (2026-07-17 fix; was hardcoded plain `msDecref` — half-wired vs destructorLifting's field hooks which already chose cyclic, → mid-destroy roots traced by the msOrcEndTeardown deferred collect = the nondeterministic msTrace UAF) | SAME | TWO traps: (1) RESOLVED 2026-07-17 — union copy hook now ports Nim's case-object `=copy` (fillBodyObjT, liftdestructors.nim:261-308): blob = \*dest snapshot, whole-object zero (`\*dest = null` → memset; per-variant wasMoved dispatch is NOT enough — field copy ops release old dest bits, foreign-variant garbage on unswitched memory), tag+field copy, `<T>Destroy(\&blob)` LAST (destroy-first frees src reachable through dest's old branch — Nim's `result = result.sons\[0]` note); self-assign guard already existed at hook top. genCopyRef msIncrefCyclic arm re-added via runtime macro `msRefCopyCyclic` (system.h): incref new → assign → decref old AFTER assign = Nim attachedAsgn isCyclic order (a collect during old's destroy must never trace a dest still holding the dying ref). REMNANT RESOLVED 2026-07-18: genCopyRef unary arm reordered to Nim non-cyclic attachedAsgn order (incref-new(src) → decref-old(dest) → assign; liftdestructors.nim:776-779 + the bug #15753 barrier comment) for all 5 map pairs (msIncref/msAtomicIncref/msClosureCopy/msClosureIncref/msMapIncref); msIncRef verified NULL-guarded (drc.h:197) so no genIf(y) wrapper needed. Verified gen-1 clean-lineage (emission-side fix): emit-C order flipped in std hooks, unit 3312/14, native 120/0/0/0, engine 332/333, play30 ORC acc=6844 + 0 leaks. Probe note: source-level rc==1 alias could NOT be routed into the hook (analyzer blits cursor-alias field assigns raw, no hook call) — the unsafe order was only reachable via containing hooks/element paths, hence latent. (a) RESOLVED 2026-07-19: guard was HiddenAddr(param) for ALL binary hooks — class hooks (params Ref, no ident auto-deref) emitted `\&(dest) == \&(src)` = param-slot compare, always false; value/union hooks accidentally correct because Var<T> idents auto-deref to `(\*dest)` and codegen collapses `\&(\*dest)`→`dest`. Fix (generateHook): class→ident compare, value→keep HiddenAddr. TRAP: naive ident-compare breaks value hooks (`(\*dest) == (\*src)` struct-compare = invalid C) — the auto-deref asymmetry is the whole story. (b) RESOLVED 2026-07-19: root = `isDrcLifecycleName` blanket `ms\*`→false treated `msAnon\_<hash>` hooks as runtime fns → isDeclAlive DCE'd the DEFS (decls + calls survived; Destroy/Trace lived only via TypeInfo initializer refs; msTuple\_ hit the identical landmine, same one-line rescue in forward.ms). Verified gen-1 (msc-refops3): anon hook defs 6/6 emitted, guards `dest == src` all shapes, unit 3312/14, native 120/0/0/0, engine 332/333, play30 ORC acc=6844 + 0 leaks. (c) RESOLVED 2026-07-19 — (d') LANDED on live tree, battery green: unit 3318/14 of 3332 (+3 classify tests: owned-anon / flagged-defer / hash-copy-defer), native 120/0/0/0, engine 332/333, play30 ORC acc=6844 + 0 leaks; probes anoncopy 42-9-1, leakloop2 hs=42 (was 9 = corruption), uafref/holderonly 42. FINAL MECHANISM: classifyObject (1) defers inline union-variant payloads — TypeFlag.DuVariant (bit 22) stamped in createUnion (stampInlineDuVariants; substituteType forwards the bit through struct rebuilds) — AND structurally-equal copies of them via the structural-hash registry (DuVariantRegistry in checker/types, NameSet-shaped; classify's isDuVariantHashName lazily hashes registrants via anonTypeName = copy-immune identity, the MS-native ItemId under the intentional per-module type worlds); (2) OWNS every other anon struct (msAnon Named RcInfo) so the central moveOrCopy machinery copies/destroys them. Coordinated generation fixes: scanForAnonStructTypes gained a nameless-struct arm (defs for analyzer-owned anon types were never GENERATED — the deeper layer of the (b) DCE landmine) + ensureDrcProto emits an opaque `typedef struct X X;` before msAnon protos (consumer TUs lack the full typedef block; identical redeclaration is legal C11). NEW BUG PINNED en route (finding #6): a method call on a MODULE-LEVEL array emits `->push` on msRefArray = invalid C (moduleless-sym family) — module state must be NameSet-shaped (struct + free-fn API taking it as param). HANG POSTMORTEM: session 2b/2c "build hangs" were PHANTOM — sample() pinned Phase C sequential fork()-per-cc on a bloated post-check heap (\_malloc\_fork\_parent/\_xzm\_foreach\_lock zone walks, minutes per fork × 280 modules; heap size = ORC-timing lottery) → every single-run bisect that day was noise; cure = parallel/posix\_spawn Phase C builder (msc-it3 lineage) COPIED INTO the worktree (std resolves BINARY-adjacent — an out-of-tree builder compiles against the wrong std). STILL OPEN: `\_uwN\_` ctor-arg temp leak class (DU-deferred temps keep today's balance), finding #4 ctor-result double-decref (pre-existing, holderonly repro), fitnode-adopt-proposal.patch parked. Original trace (historical): `let mine: S = h.s` raw-blits (no copy, no scope destroy) while field-stores release old values → ASan UAF + silent corruption (leakloop2: pre-fix prints hs=9 — slab recycle overwrote h's field — post-fix hs=42). ROOT = classifyObject bails on `typeName === ""` before checking HasAsgn (flag IS propagated) → anon-struct locals unmanaged → VarDecl never reaches the central moveOrCopy machinery (healthy, Nim-parity, just starved). Nim invariant violated: hasDestructor is STRUCTURAL (injectdestructors.nim:68), never name-gated; ops keyed by type identity (attachedOps\[ItemId]→PSym, modulegraphs.nim:78,355 — drift impossible by construction). Candidate fix (classify anon arm via anonTypeName + ensureDrcProto msAnon exemption) PROVES the semantics (probes green: init wasMoved+Copy, scope Destroy, hs=42) but collides with THREE DU-machinery sites that all use anon structs as representation currency WITHOUT type identity: (1) cross-TU protos referencing never-typedef'd msAnon C types (fixed by exemption), (2) union-fitted literal captures whose C storage is the <Union>\_vN carrier (checker stamps live on syms/wrap sites — invisible to classify; interim-gated), (3) `node.data as Variant` narrowing cursors whose codegen POINTER-decl flips to value when rcInfo goes None→Named (cc break — the stop point, NOT gated). INTENTIONAL-GAP NOTES: (i) name-keyed ops vs Nim ItemId→sym = intentional representation divergence (structural typing has no canonical ItemId); invariant holds only where naming is a single shared oracle (tupleTypeName precedent). (ii) DU structural types (payloads/carriers/narrowings) have NO identity outside DU codegen — INTERIM gap; close via design "(d)": give DU-structural types identity at creation (checker/DU layer) so classify/lifter/codegen agree — also closes the `\_uwN\_` leak class. Trap for (d): vN hooks take WHOLE-UNION pointers (payload temps tagless) — naming payload types `<Union>\_vN` collides signatures. WIP: .session-artifacts/refops/f3-wip.patch (f3 hunks = classify anon arm, forward isGeneratedMsAnonHook + gate, inject 2 interim gates) + probes anoncopy/leakloop2/holderonly. (d')-IMPLEMENTATION MAP (2026-07-19 session 2b, f3-wip2.patch — design finalized, battery pending): identity vehicle = TypeFlag.DuVariant bit 22 stamped in createUnion on nameless struct children (typeExtra is NOT free — Union: discriminant type, Struct: BASE CLASS via pickAllocExpr; TypeFlag bits 8-15 = overloaded minArity/SizedArray byte — high bits only) + substituteType must forward the bit (struct-rebuild drops typeFlags). PROVEN LIMIT: object-identity stamping loses to PER-MODULE TYPE COPIES (eager-import worlds + struct aliases are nameless (`type X = {…}` keeps typeName="") + exploratory literal types — DBG: {expr} stamped ×6 canonical copies, analyzer still met a 7th fresh one). FINAL DESIGN: structural-hash registry — anonTypeName(hash) is the copy-immune identity (all 7 hash equal); record at stamp, classify defers on isDuVariantHash(anonTypeName(t)); requires moving the anonTypeName cluster codegen→checker (import cycle; audit anonFieldKey deps) + keeps tupleTypeName's name-as-identity precedent. UPSTREAM: the per-module copies are themselves the Import-resolution row's intentional divergence (eager symbol copies; Nim has ONE ModuleGraph type world, which is what makes itemId possible) — the hash registry is the MS-native itemId under that constraint, NOT a workaround to fix later. fitNode gained a contextual-identity-adoption arm (nameless-literal adopts canonical expected struct — TS parity, keep pending battery). TOOLING TRAP: installed msc v0.2.24 HANGS (>20min, clean cache) compiling the edited tree (loop inlined in createUnion = deterministic trigger; helper-extraction + still hangs on later variants) while gen-1-of-HEAD (msc-refops3) builds it in \~3min — build this work with HEAD-lineage compilers only. Emission traps hit while porting: hook param idents auto-deref (explicit HiddenDeref → `(\*(\*dest))` C error); whole-var union assign masks the hook (borrow-temp + sink), live-dest UCopy only via containing hooks/field/element paths. \_uwN\_ ctor-arg temp leak class CLOSED 2026-07-19 (with finding #4, one gate: processObjectLiteral isRefConstr now includes ANON structs so owned literals SINK their fields — field.ms 200K→0 leaks, slab-off clean). (2) the fix is EMISSION-side: gen-1 binaries (built by pre-fix gen-0) still crash on heavy builds — validate and deploy from gen-2+. |

| \*\*canFormAcycle — which types get cyclic ops\*\* | `canFormAcycleAux` (`types.nim:408-461`) drives the "provably acyclic" branch that the row above references. It answers "can a reference cycle pass THROUGH cells of this type" by walking from `orig` and returning true ONLY on a \*\*back-edge\*\*: `withRef and sameBackendType(t, orig)` (a ref hop that returns to the origin type). Closures are cyclic unconditionally (`tyProc ccClosure`, :451). Cursor fields are skipped (`sfCursor`, :393-395) — they don't own the ref. \*\*NON-FINAL objects are cyclic UNCONDITIONALLY\*\* (`tfFinal notin t.flags → result = true`, :436-438): open-world inheritance means a subclass may introduce a back-edge the base can't see. `cyclicType` (`liftdestructors.nim:695-699`) wraps it for the ref-op choice; the flag lands in TypeInfo (`ccgtypes.nim:1738`, `flags or 1`). | \*\*`src/transform/cycles.ms` `canFormAcycle(t, cyclicCache, acyclicCache)`\*\* (NEW 2026-07-20) — faithful port. Back-edge identity = the resolved type NAME (`typeName` \\| `anonTypeName` \\| `mangleMonoName`) = the MS-native ItemId under the per-module type-copy divergence (Import-resolution row; same "naming is the single shared oracle" basis as tupleTypeName/DuVariant). Marker is a FRESH NameSet per query (intermediate results depend on `orig` and must NOT be memoized); only the entry-level answer is cached, in caller-owned `cyclicCache`/`acyclicCache` (TransformContext for classify, LiftCtx for the lifter). Closure→true, Ptr/unknown→false, Ref→recurse pointee, null pointee→conservatively true. | was \*\*DIVERGE-UNINTENTIONAL → SAME\*\* | \*\*The pre-port oracle was the WRONG FUNCTION, not a missing case.\*\* `isCyclicType` (destructorLifting.ms) answered "does this type transitively CONTAIN a ref" (`Ref \\| Function => true` unconditionally) ≈ Nim's `containsTyRef`, NOT `canFormAcycle`; `classify.ms` didn't ask at all — it HARDCODED `msDecrefCyclic`/`msIncrefCyclic` for every Ref/union-Ref local. Row-above verdict "SAME" covered op-order + registration wiring, and was only safe because BOTH sides over-approximated to cyclic — so the divergence was latent (over-conservative = wasted rootset registrations + collector pressure, never unsafe). \*\*UNIFICATION (the load-bearing part):\*\* classify's Ref/union-Ref arms AND the lifter's `isCyclicType` now call the ONE `canFormAcycle` oracle. This retires the split-oracle that caused the 2026-07-17 mid-destroy UAF (classify plain-decref vs field-hooks cyclic → cell registered by fields, destroyed by a plain local-decref, traced mid-teardown). Invariant: \*\*one oracle, two consumers, per-type answer identical by construction\*\* — never let classify and destructorLifting compute cyclicity independently again. Two latent oracle holes fixed in passing (both toward Nim): GenericInstance-containing-ref fell into the old catch-all `false` (missed), and refOp's `trace` arm emitted `msOrcTraceRef` for acyclic pointees (Nim gates trace on cyclic, `liftdestructors.nim:782-791`). \*\*⚠️ LANDMINE — `class extends` (LANG-STRUCT Phase 2.8, NOT STARTED): the port DELIBERATELY OMITS Nim's non-final rule (:436-438).\*\* Today MS has no C backend for inheritance, so every struct is effectively final and "back-edge only" is complete + correct. \*\*The moment `class Child extends Base` gains a C backend, this oracle becomes UNSOUND for polymorphic refs:\*\* a `Ref<Base>` whose runtime object is a `Child` that holds a `Ref<Base>` field forms a cycle the structural walk over `Base`'s fields cannot see (the back-edge lives in the subclass). `canFormAcycle` will return acyclic → plain `msDecref` → the cycle leaks (and, if the cell IS reachable from a genuine cycle elsewhere, the missing TypeInfo `isCyclic` flag makes it un-collectable → silent leak, NOT a crash). REQUIRED at that milestone, pick one and record the choice HERE: \*\*CHOSEN 2026-08-13 — option (A), Nim-faithful.\*\* `OpenClass` (TypeFlag bit 23, `std/meta/node.ms`) stamped on the PARENT struct in `resolveClass` (`resolvePass.ms`); `cfaAux` Struct arm returns true when set (`cycles.ms`), independent of the typeExtra field walk (both apply). Bit 23 survives struct rebuild (`copyTypeForSubst` forwards all flags except Substituting; `createGenericInstance` forwards base typeFlags) — the row-69 DuVariant precedent. Single oracle: `classify.ms` + `destructorLifting.ms` both read the same `canFormAcycle`. Verified: CChild→CBase cycle now collects under orc (alloc==destroy=40000), was 100% leak; DirectCycle self-cycle is the paired control (collects pre- and post-fix → ORC sanity, distinguishes oracle-blind from ORC-broken); drc leak is by-design (Nim ARC). Guard `src/test/guard/openClassCycleCollects.ms` (new `GUARD-BALANCE-ORC` directive, drc not asserted), proven red on the pre-fix binary. Battery 171/3448, guard suite ALL GREEN. Option (B) whole-program subclass walk rejected (MS invention, not Nim-faithful). Branch `h13-p5-open-class-acyclic`. | (A) port Nim's rule verbatim — any non-final (subclassable, non-`isPureObject`) object type ⇒ cyclic unconditionally, needs an `isFinal`/`tfFinal` equivalent on MS struct types (a "has subclasses / is open" bit set by the checker); or (B) a closed-world whole-program subclass walk that unions each base's cyclicity with all its subclasses' (only viable because MS is whole-program, no separate compilation — but must run AFTER all `extends` are collected, and `classify`+`destructorLifting` must read the SAME resolved answer or the split-oracle UAF returns). Do NOT ship `extends` codegen without closing this. Second, smaller trap for that milestone: `typeExtra` on a Struct already carries the base-class ref (LANG-STRUCT.md:361) — the port walks `typeExtra` as a child, which is correct for FIELD inheritance but is NOT the non-final back-edge check; they are independent, need both. \*\*Verification (2026-07-20, /tmp/canf gen-2 clean-lineage, workspace-only ORC counter in drc.c — NOT backported):\*\* perf regs→0 on the engine game sims (Card/Skill/Mutation/GameState are genuinely acyclic): bench 10M refs 4.13→1.54s (−63%, regs 10,000,000→0), play300 \~5.6→1.63s (−71%, regs 85,640→0), play30 unchanged (already sub-threshold); correctness identical (acc 6844/68731). Safety: memory-safety probes green (leakloop2 hs=42 corruption-sentinel, anoncopy/uafref/holderonly 42, 0 leaks; uafclo build-fail is pre-existing under msc0 too); native tier 120/0 BOTH GC modes incl. `raiser-cycle-collect` still `collects=58` (genuine cycles STILL registered + collected — the oracle discriminates, it doesn't disable ORC); classify + lifter unit green (3 hook-count pins updated to Nim-correct: interface `{items:number\[]}` 6→5 hooks, no trace on acyclic pointee — plus 2 new pins locking the cyclic side: self-ref `interface Node{next:Node\\|null}` KEEPS trace); gen-1→gen-4 bootstrap, semantic fixpoint (0 string diff across generations, \~2000B ambient nondeterminism only). |

| \*\*Generic instance ownership\*\* | `setOwner(result, fn)` (`seminst.nim:404`) — a generic proc instance is owned by the \*\*defining\*\* module (via `fn`): def emitted there, users get a forward proto. Private deps are `N\_LIB\_PRIVATE` = `\_\_attribute\_\_((visibility("hidden")))` (`nimbase.h:192`), still resolvable across TUs. \[special case `seminst.nim:402`: `sfGlobal` + `symbolFiles` → owned by the \*\*consumer\*\* module] | instance `modulePath = sym.modulePath` (defining module; MS-only fallback to `ctx.modulePath` when the template carries no module); the drain routes each instance into its owner module's program before codegen (`compile.ms`) so its body is emitted in that TU, beside the module-private `static` helpers it calls | SAME (default case) | reverts the earlier `modulePath=""` divergence: a module-less instance landed in an arbitrary TU and called a helper emitted `static` in another TU → `undefined symbol` at link (proved in a 2-module repro: `\_helper…` unresolved). MS emits private fns `static` (stricter than Nim's `hidden`) so co-location is \*\*required\*\*, not optional. Same owner-routed drain as the ctor row above. Nim's incremental-global special case (`seminst.nim:402`) is N/A — MS has no `symbolFiles`. |

| \*\*Enum member repr \& generic-instantiation survival\*\* | enum field access `E.M` sem-resolves to an `nkSym` bound to the real `skEnumField` symbol owned by the enum type — a normal in-scope symbol. Generic instantiation copies the body (`copyTree`, `seminst.nim:461`) and `freshGenSyms` (`seminst.nim:100-118`) re-creates ONLY `sfGenSym` locals; the enum-field `nkSym` is non-gensym → passes through the `else` recursion \*\*by reference\*\*, never re-resolved by name. | checker REWRITES `E.M` (MemberExpr) → mangled `Identifier "E\_M"` whose name is \*\*deliberately never bound in any scope\*\* (`checkExprPass.ms:4025-4065`); the SOLE resolution path is the inline `resolvedSym` (`SymbolKind.EnumMember`), which the Identifier re-check honors (`checkExprPass.ms:383-385`). Generic instantiation clones the (already-rewritten) body via `monoCloneNode`, then `clearCheckerState` + re-checks against concrete types. | DIVERGE-INTENTIONAL (the rewrite) \*\*+ hard invariant\*\* | The rewrite is KEPT because codegen never special-cases enum MemberExpr — the mangled name IS the C identifier (a real, wanted codegen simplification). \*\*COST/INVARIANT: because that name is out-of-scope by construction, `resolvedSym` is the only way to resolve it, so EVERY clone / state-clear / re-check site MUST preserve an `EnumMember` resolvedSym\*\* or the re-check fails `Undefined variable 'E\_M'`. Three sites enforce it: `copyNodeMeta` (`clone.ms` — hoisted to apply in BOTH Mono \& Check modes), `clearCheckerState` (`instantiate.ms`), and `checkExprPass` honors it. FIXED 2026-07-20: the Mono-clone branch + `clearCheckerState` blanket-stripped resolvedSym → instantiating any class/fn whose body reads a \*\*cross-module\*\* enum member (Neon `Signal<T>.set` reading `CompState.Clean`) failed `Undefined variable 'CompState\_Clean'` at the instantiation site (7 Neon files). This is the "generic-instantiation scope loss" flagged in the `unknown` top-type row. Nim never hits it — it carries the resolved symbol by reference (`freshGenSyms`) rather than a name that must be re-looked-up. The full Nim-parity alternative (bind `E.M` to a real in-scope enum-field symbol instead of an out-of-scope mangled name) is deliberately NOT taken: it would push enum-member handling into every codegen backend. |

| \*\*CT eval / macro expansion\*\* | ONE project-global VM on the ModuleGraph (`graph.vm`); vmgen lazily compiles each routine to bytecode ONCE per symbol (`procToCodePos`, vmgen.nim:2416-2455) from `transformBody` output held on the SEPARATE `transformedBodyImpl` field — the sem'd AST stays canonical for all consumers; `evalConstExprAux` (vm.nim:2434) transforms only the expression being evaluated; macro args are the caller's REAL nodes (aliased, `setupMacroParam` vm.nim:2500-2510), macro result is not cloned but fully re-semmed in the caller's context (`semAfterMacroCall`) and the call node replaced wholesale. Safety rests on 4 invariants, not purity (`liftCapturedVars` DOES mutate in place): once-only flags (nfSem/nfTransf) + separate output field + boundary copies (`getImpl` → copyTree, macrocache copyTree, tyStatic args) + partial nfSem write-barrier in VM structural mutators | Raiser = standalone mini-pipeline (check + refineTypes + `transformForRaiser`, all destructive in place) over a synthetic Program built per `@comptime` block / macro invocation; needed decls are injected into that Program, and every injected decl is \*\*CLONED\*\* via `cloneNodeForCheck` (comptime.ms — collectors walk the REAL nodes for resolvedSym/type chains, cloning happens only at the push). Macro path injects only body-reachable helper fns, never the module's decls. No caching yet: every invocation re-checks/re-compiles its whole synthetic Program (macro args are baked in as const-decl statements) | DIVERGE-INTENTIONAL (standalone-Program VM is a consequence of the eager 3-pass checker + Raiser doubling as a backend) \*\*+ one hard invariant\*\* | \*\*Real module nodes must NEVER enter the inner pipeline.\*\* By-ref injection was a silent miscompile (2026-07: sibling fns' string-concats folded to `"<object>"` in place, identifiers emitted unmangled in C — probes: any module containing one `@comptime` block corrupted; VM values themselves were always correct). Per §0 anti-flip heuristic, CT-eval sits in the track-Nim-strictly class (wrong = silent miscompile), NOT the frontend-free class. Known upgrade path = Nim-parity per-symbol bytecode cache (separate cached program from per-call args → registers), which removes injection and the per-invocation recompile cost; until then, clone-at-inject IS the invariant enforcement. Regression gate: src/test/lang/comptime.ms "isolation:" tests. |

| \*\*Raiser local slots (CT-eval codegen)\*\* | `genVarSection` (vmgen.nim:1984, local branch) calls `setSlot` (:1550 → `getFreeRegister(…, slotFixedLet/slotFixedVar, start=1)`) so every declared local owns a DEDICATED register, then generates the initializer INTO it (`gen(c, a\[2], s.position.TRegister)`). Aliasing a variable's own register is reachable ONLY from the no-destination path: `genRdVar` (:1746, local branch) takes `dest = s.position` when `dest < 0`, else `genAsgn(c, dest, n, requiresCopy)`. `regInfo\[].kind` (slotFixedLet/slotFixedVar vs slotSomeTemp) is what keeps fixed slots out of temp reuse and drives `requiresCopy`. | `compileVariableDecl` (codegen/raiser/statements.ms) adopted `compileExpr`'s returned register as the new local's slot; for an Identifier initializer that register IS the source local's slot (`resolveLocal`, codegen/raiser/expressions.ms Identifier arm), so two locals shared one register and writing the new name wrote the old one. FIXED 2026-08-13: the `locals` table IS the fixed-slot registry (no parallel kind array — representation divergence, Q1), `regIsFixedLocal` answers Nim's `regInfo\[].kind < slotSomeTemp` question against it, and a `Move` copies out when the initializer resolved to a live local's slot. Temps are still adopted directly: owned by no name, which is the property Nim buys with a dedicated slot. | was \*\*DIVERGE-UNINTENTIONAL → SAME\*\* | \*\*Silent miscompile, comptime only, every type.\*\* Found 2026-08-13 from downstream wreckage in the spacetime SDK: a macro wrote `let base = ty; if (ty === "opt:string") base = "string";` — the store to `base` clobbered `ty`, so the NEXT test of `ty` went false and the macro emitted a plain reader instead of the Option ternary, while the schema half of the SAME expansion still carried `"opt:string"`. Net effect: the emitted descriptor declared the reducer arg as a Sum while the dispatch decoded a bare string — two halves of one macro disagreeing, no diagnostic anywhere. Isolation matrix (the load-bearing evidence): `const`/`let`, plain assign and assign-under-`if`, `string`, \*\*`int32`\*\* and \*\*`boolean`\*\* ALL corrupt at comptime, while the identical source through the C backend is correct — so this was never a string/refcount bug, it was variable binding. Params, `for-of` bindings and array-element stores were already correct (each `allocReg`s its own). Runtime prerequisite was ALREADY satisfied and unused: the VM's Move arm does `copyValueInto` under the comment "Copy to avoid aliasing between registers" (raiser/vm.ms) — the generator simply never emitted Move for a declaration. Guard: `src/test/lang/comptime.ms` "a declared local owns its register, never aliases its initializer" (string / int32 / boolean / self-concat), \*\*proven RED on the pre-fix binary\*\* (`AssertionError: LOCAL\_SLOT === keep/changed\\|7/9\\|true/false\\|base/base!`) and green after. Verified: full suite 171 files / 3461 tests green, gen-2 self-build byte-identical in size and reproducing the fix, spacetime module rebuilt with descriptor + 4/4 runtime probes green. |



| \*\*Generic method cross-module monomorphization\*\* | Nim has no "method" category — `c.set(42)` on a generic `Cell<T>` is a generic proc call whose body is globally reachable via the ModuleGraph (`getBody(graph, fn)`); `seminst`/`generateInstance` instantiates the concrete body at every call site regardless of which module uses it. One global body, mono'd per type-arg everywhere. | per-module symbol worlds → a generic body (`declNode`) must be EXPLICITLY carried across the module boundary via `ExportRegistry` so the importing module can clone+substitute it (`tryInstantiateGenericCallee`). `buildExportInfo` (`context.ms`) is the single export chokepoint; import side (`collectPass`) copies `exportInfo.declNode` gate-free. | was \*\*DIVERGE-UNINTENTIONAL → SAME\*\* (parity with MS's own cross-module mono machinery) | Free functions, constructors, static generic methods, and extension methods were all wired to carry `declNode` cross-module — but INSTANCE methods of a generic class were DROPPED: the export gate tested `methodIsStatic \&\& isGenericFn(method-own-flags)`, yet an instance method's genericity comes from the enclosing class `<T>` (seen through the `this` receiver), not the method's own flags. Result: importing module emitted the mono'd struct (`Cell\_\_int32`) but bound `c.set()`/`c.get()` to the erased defining-module methods (`Cell\_set(Cell\_\_unknown\*, void\*)`) → C type mismatch (`void\*` vs `int32`/`double`). FIXED 2026-07-21: both gates (primary + overload, `context.ms`) replaced with `methodCarriesMonoBody(symType) = hasGenericParams(symType)` — carry the body whenever the signature still mentions an unresolved generic param (own `<T>` OR class `<T>` via `this`). Repro: generic `Cell<T>` in one module, `makeCell<int32>` + direct `c.set(42)`/`c.get()` in another (Neon `counter.test` `assigning to void\*`). NOT shielded by the "deliberately NOT monomorphized" note (that covers only Map/Set entry `key: T→void\*`, borrow-only). Sibling of the enum-member row above + the `unknown`-top-type row's "generic-instantiation scope losses". The full Nim model (one global body) is N/A — MS's per-module worlds are the intentional Import-resolution divergence; this restores the invariant within that architecture. |

| \*\*Container element assignability + enforcement site\*\* | Nim `typeRel` keeps `seq`/`array`/`ptr` elements \*\*INVARIANT\*\* (`sigmatch.nim:1502-1516`: element `typeRel < isGeneric` ⇒ `isNone`; only covariant ref/ptr under `nimEnableCovariance` or empty-seq relax). Enforcement is CENTRAL in `fitNode` (`sem.nim:99` → `indexTypesMatch` → `typeMismatch`); every assignment site funnels through it, so no site can forget the relation. | `isAssignable` (compat.ms) is the relation; container element-repr invariance added at \*\*compat.ms:48\*\* (`sameElementRepr` — numeric elements must share C repr, `number`≡`float64`). Enforcement now CENTRAL in `fitNode` (checkExprPass.ms) scoped to the memory-safety class via \*\*`isReinterpretUnsafe`\*\* (peels Ref/Array/Span/Ptr/SizedArray in lockstep; true only on a numeric element-repr mismatch). | was \*\*DIVERGE-UNINTENTIONAL → SAME\*\* (Nim container invariance + central fitNode enforcement), \*\*SCOPED\*\* | \*\*Root:\*\* MS split Nim's single relation into `isAssignable` (bool) + a coerce-only `fitNode` that emitted errors ONLY for the Unknown family — the relation-failure→`typeMismatch` half was lifted OUT of fitNode and scattered per-site as `isAssignable`+`addError`. Arg-path had it; \*\*var-decl / field / array-elem / return / ternary did NOT\*\* → `const dst: number\[] = int32arr` emitted a raw `(msNumberArray\*)(int32\_tArray\*)` cast with no per-element conversion → reading `dst\[i]` as an 8-byte double from a 4-byte-stride buffer = \*\*ASan heap-buffer-overflow READ\*\* (repro executed 2026-07-21). Fix restores Nim's "fitNode enforces the relation" so ALL sites are covered by one check. \*\*SCOPE (why not full parity yet):\*\* flipping fitNode to reject \*every\* `!isAssignable` surfaced \*\*127 false-positives\*\* in self-test, ALL from `isAssignable` being an incomplete stand-in for Nim `typeRel`, NOT real bugs: 43× same-name type ≢ itself (`CToken`/`Scope` — the \*\*per-module type-identity\*\* divergence; this Import-resolution row + the DuVariant/itemId saga in the ORC row), 9× missing conversion coverage (`int32→int64`, enum→int32, `number→float64`), \~54× nullable-union→non-null (flow-narrowing not integrated at fitNode). So enforcement is scoped to `isReinterpretUnsafe`. \*\*RE-TRACED 2026-07-21 (`/trace-nim`) — the scope is TERMINAL, not a deferred arc.\*\* Re-measuring under general `!isAssignable` at HEAD 785065a gave 328 false-positives; tracing each bucket against Nim source + this doc shows dropping the scope would VIOLATE documented intentional divergences, so it must not be done: (1) \*\*\~75 nullable `T\\|null→T` / `null→T` = DIVERGE-INTENTIONAL\*\* (this doc's "Nullable-ref struct field hooks" §, lines \~198-205: MS's TS-style non-null `T` vs `T\\|null` union is a \*feature Nim lacks\*; option "collapse to a plain nilable ref like Nim" was EXPLICITLY REJECTED). Rejecting `T\\|null→T` = implementing TS flow-narrowing = a NEW feature, not a return-to-Nim; C is a same-repr `T\*` copy, no hazard. (2) \*\*43 `Ref<T>→Ptr<T>` (`CToken`/`Scope` linked-list next-ptr) = DIVERGE-INTENTIONAL\*\* (row 63 `Ptr<T>`+arena-own cursor pattern, "Ref→Ptr cast" probe-verified). Emitted C confirmed `((\*head).next = tok)` = `Tok\*`→`Tok\*` same-repr pointer copy, no OOB (NOT the earlier "per-module identity" story — it's an intentional cursor coercion; both sides same nominal element). \*\*OBSOLETE 2026-08-20: those link sites migrated to `Cursor<T>` (§5), whose fit rides the `skipModifier` peel — the bucket is empty now, which unblocks tightening the remaining Ref↔Ptr interchange arm (compat.ms:356) to FFI-explicit (`as Ptr<T>`), the PTRPROBE step.\*\* (3) \*\*9 scalar/enum conversions\*\* (`int32→int64` isIntConv, enum→int32, `number≡float64`) = the ONLY genuine `isAssignable`<`typeRel` gaps, and BENIGN under the scope — scalar widening emits a REAL conversion via `isNarrowingIntConv`/`needsStdConv`, never a raw container cast. (4) \*\*200× `int32→string` at one site = a SEPARATE latent bug\*\* (`fillDefaults` pairs a `this`-method's default-arg value against the wrong formal — `indexOf(…, start:int64=0)`'s `0` checked vs the prior `sub:string` param); orthogonal to `typeRel`, masked today by the permissive fitNode, own ticket. \*\*Conclusion: the memory-safety class (container element-repr) is the correct SCOPE for central fitNode enforcement; the remaining `isAssignable`≠`typeRel` deltas are either intentional divergences to respect or a benign scalar-conv nicety.\*\* \*\*Verified 2026-07-21\*\* (worktree, gen-1 of HEAD 1d1f710): self-build 283/0; self-test \*\*3332 passed / 5 failed\*\* — all 5 baseline (path.ms UNC-join, literals/expressions float-format, lsp `elapsed<200` timing; each reproduced under installed msc); \*\*0 container false-positives\*\*; `oob.ms` rejected at compile (no binary → OOB impossible); scalar `int32→number` widening + `number\[]`/`float64\[]` still accepted (row 56 preserved). Tests: `src/test/handoff/typeCoercion.ms` (isReinterpretUnsafe/isAssignable unit) + `src/test/handoff/arrayElementRepr.ms` (all sites). |

| \*\*Structural type-dedup keys — function signature\*\* | Type identity is structural everywhere: `hashType` (`sighashes.nim:227` `of tyProc`) folds each param name+type + return + callConv into the type hash used for mangling/caching; `sameInstantiation` (`seminst.nim:78`) compares generic type-args via `sameType`, which for `tyProc` compares params+return. Two nullable/generic wrappers over differently-signed procs are DISTINCT types. | Three checker/codegen dedup keyers collapsed EVERY function to a constant: `maybeCacheKey` (`checker/types.ms`) `"p"+kindOrdinal`, checker `typeKey` (`checker/types.ms:1421`) `kind.toString()`, codegen `anonFieldKey` (`codegen/c/types.ms:63`) `"fn"`. So `(()=>number)\\|null` and `((v:number)=>void)\\|null` both keyed `Maybe\_p22` → the 2nd field inherited the 1st's arity-0 signature → checker `cell.setter(n)` "expected at most 0, got 1" + C fn-ptr cast to `(void)`. Same collapse hit tuple names (`tupleTypeName` via `typeKey`) and anon-struct/DU-variant names (`anonTypeName` via `anonFieldKey`). | was \*\*DIVERGE-UNINTENTIONAL → SAME\*\* | Our OWN codegen `typeKey` (`codegen/c/types.ms:196`) already keyed functions structurally (`func(params):ret`) — the checker keyers + `anonFieldKey` were the outliers, so there was no intentional reason. FIXED 2026-07-21: structural fn key (params+return) in `maybeCacheKey` + checker `typeKey` + `anonFieldKey`. Only ever SPLITS previously-colliding keys, never merges (safe by construction); `tupleTypeName`/`anonTypeName` are single-source (no checker↔codegen desync). Repro: `neon/probe/r1\_arity\_min.ms` (two nullable-closure fields, different arity — single field or non-nullable PASSES; two different-arity nullable fields COLLIDE). Verified: distinct `Maybe\_fn\_fnnumber11`/`Maybe\_fn\_fnnumbervoid15`, setter cast now arity-1; battery 3323/14 = known-flake set exactly. \*\*Sibling FIXED 2026-07-21 (`registry.ms` `e771cb9`):\*\* `monoTypeKey` (`monomorphize/registry.ms:39`) `Function => "function"` + anon `Union => "union"` — the SAME collapse at the generic-instantiation dedup level (`mangleMonoName` → the mono symbol identity read by the CHECKER `instantiate.ms:440/544`, which returns the cached symbol on a name hit → 2nd instantiation reuses the 1st's body). Made structural (params+return for fn; members for anon union), mirroring Nim `sameInstantiation` (`seminst.nim:78`, compares type-args via `sameType`). \*\*Empirical return-to-Nim proof:\*\* (a) fn-collapse was BENIGN — `Holder<()=>number>` vs `Holder<(x:number)=>void>` fused to `Holder\_\_function` with `v: msClosure` yet RAN CORRECT (`a()=42`, `b(7)` both right) because `msClosure` is a uniform repr and call-arity is applied at the call SITE from the local's static type, not the erased field; (b) union-collapse was a REAL miscompile — `Box<number|string>` vs `Box<boolean|number>` fused to `Box\_\_union` → C `assigning to msUnion\_1y4f43o from incompatible msUnion\_gddi8r` (non-uniform payload layouts, no uniformity to save it). Structural key splits both (`Holder\_\_fn\_...`, `Box\_\_union\_number\_string`); benign fn case still runs correct; battery 3323/14 = known-flake exactly. Exposes one SEPARATE pre-existing bug underneath (union ctor-param proto/def indirection: `\_init(…, msUnion\* v)` def vs `msUnion v` proto — present pre-fix). \*\*One deliberate residual (measured 2026-08-12):\*\* Nim folds `callConv` into `hashType`; MS keys functions on params+return ONLY, and that is correct here rather than a gap — Nim has TWO representations to tell apart (proc pointer vs closure pair) while MS has one (`msClosure`, chosen off `TypeKind.Function` alone). Verified by grep + emit: `.callConv` has ZERO readers in both `typeKey`s, `sameTypeInner` and `monoTypeKey`, `struct Iterator { msClosure next; }` is emitted either way, and flipping the flag on the iterator's `next` field changed the emitted C by 0 lines. callConv's only consumers are call dispatch (row 715) and the function→closure auto-wrap at `checkExprPass.ms:2379`. |

| \*\*Integer literal representation\*\* | `nkIntLit` carries `intVal: BiggestInt`, a separate node kind from `nkFloatLit`/`floatVal` — an integer literal never passes through a float. | ONE `NumberLiteral` kind discriminated by `isFloat`, whose data held only `value: number` (float64). Every literal past 2^53 was rounded in the PARSER, so both backends inherited the loss; near the int64 bounds the double→int64 conversion saturated and flipped sign silently. | was \*\*DIVERGE-UNINTENTIONAL → SAME\*\* | FIXED 2026-08-04: `NumberLiteralData` gained `intVal: int64`, authoritative when `!isFloat` (`std/meta/node.ms`), filled from the literal TEXT by `parseIntegerLiteral` and emitted via `int64ToDecimal` on both backends. Keeping the single node kind is deliberate — the `isFloat` discriminant plays Nim's node-kind role, and `BigIntLiteralData` already holds the text for values wider than int64. Three follow-on double round-trips had to go with it: the global-initializer format path, unary-minus constant folding, and binary constant folding (which now DECLINES to fold operands a double cannot hold rather than baking in a wrong constant). Guards: corpus `013-int64Fidelity` + `src/test/{c,js}/int64Literal.ms`. |

| \*\*JS `int64` runtime representation (BigInt gate)\*\* | `optJsBigInt64` (`options.nim:112`; switch `--jsbigint64:on\\|off`, `commands.nim:1172`) sits in \*\*`DefaultGlobalOptions`\*\* (`options.nim:512-513`) = \*\*ON by default\*\*, and it gates BOTH halves as ONE unit: representation — typed-array name is `BigInt64Array`/`BigUint64Array` under the flag and `""` otherwise (`jsgen.nim:1948-1958`), default init `"0n"` vs `"0"` (`jsgen.nim:1981-1984`) — AND every operator, which wraps its result in `BigInt.asIntN(64, …)`/`asUintN(64, …)` and coerces the other operand with `BigInt($2)` (`jsgen.nim:584-818`). The non-typed array fallback fills each slot with the ELEMENT's default, recursively (`createVar(p, e, false)`, `jsgen.nim:2005-2013`) — never `null`. | `jsBigInt64` on `JSGenerator` (`codegen/js/emit.ms`), \*\*default `false`\*\*, read by `jsTypedArrayName` + `jsDefaultValue` (`codegen/js/statements.ms`). The operator half is UNWRITTEN, so the gate stays off and `int64` is an IEEE double everywhere on this backend. | \*\*DIVERGE-INCOMPLETE\*\* — the off-state is a legal reference state, but the reference DEFAULT (on) is not reached | Pre-fix MS carried the ON-state \*representation\* with \*\*no flag and no operators\*\* — a combination the reference cannot emit: `let a: int64;` → `0n` and `let a: int64\[4];` → `new BigInt64Array(4)`, while every literal and operator stayed a Number, so the FIRST arithmetic op on such a local threw `TypeError: Cannot mix BigInt and other types` at runtime (JS backend only; `013-int64Fidelity`'s `@skip-js` hid it, and `512-jsonInt64`'s `@xfail(js)` reason mis-blamed `parser.ms`'s `parseInt` — that call is only where the loss becomes visible). FIXED 2026-08-10 by gating both representation sites. The same fix had to close a second, undocumented divergence in the same function: the array fallback hardcoded `null` instead of the element default, which the new off-state would otherwise have turned `int64\[4]` into an array of `null`. \*\*Stage B\*\* = port the operator table, flip the default ON, then drop `@xfail(js)`/`@skip-js` from `512`/`013`; audit the JS helpers that take int64 first (`msIntToStringRadix`, hashing, Map keys — the reference keeps two stdlib implementations behind this flag). Guards: corpus `014-int64DefaultInit` (proven RED pre-fix — crash; now byte-identical across c/orc/danger/js) + 3 emit pins in `src/test/js/int64Literal.ms`. Sibling of the \*\*Integer literal representation\*\* row above: that one fixed the front end and named this backend half as pending. |

| \*\*Type IDENTITY vs assignability (control-flow merge)\*\* | Two SEPARATE relations. Identity = `sameType`/`sameTypeAux` (`types.nim:1033/1224`); assignability = `typeRel` (`sigmatch.nim`). `sameTypeAux` compares by KIND then per-kind structure: anonymous aggregates field-by-field incl. field NAMES (`sameTuple`, `types.nim:1099`), named objects nominally by id (`ifFastObjectTypeCheckFailed`), value-carrying types by value (`tyRange` → `sameValue`), transparent wrappers by inner type (`tyVar`/`tyLent`/`tySink`/`tyVarargs` → `sameChildrenAux`), generic params by `sym.position` under `ExactGenericParams`, and EVERY arm additionally requires `sameFlags(a, b)`. | MS has one relation, `typeRelation` (`checker/compat.ms`), whose `Exact` was used AS identity by the flow-merge dedup (`checker/flow.ms` `getTypeAtBranchLabel`). Its Struct arm compared `typeName` only and its catch-all arm returned `Exact` for ANY same-kind pair — so the two anonymous variants of a match-type DU (`{kind,a}` vs `{kind,b}`), two literal types (`true`/`false`, `"a"`/`"b"`), two unions, two function types, and every wrapper pair all reported "same type". | was \*\*DIVERGE-UNINTENTIONAL → SAME\*\* (identity is structural; assignability left as-is) | \*\*Root:\*\* `Exact` lied, so the BranchLabel join collapsed its two antecedents to the head one — the TRUE edge — and a narrowing leaked past the sub-expression that created it (`const c = e.ok \&\& …;` narrowed `e` for the REST OF THE FUNCTION). Unsound narrowing, not DU-specific. FIXED 2026-07-28 (`383bb1c`, corrected by `e628ea9`): a dedicated `sameType` relation now lives beside `typeRelation` — nominal types by name, anonymous aggregates by field names + field types + `typeFlags` (repr: value-struct ≢ ref-interface), literals by value, Union/Tuple/Varargs/Conditional by children, Function by params+return, wrappers (Array/Span/Ref/Ptr/Borrow/Var/Sink/Lent) by inner type, GenericParam by name, everything else "same kind ⇒ same". Self-referential types (`Node`, `Scope`) make the walk cyclic, so it carries the reference's recursion budget and assumes "same" once spent. `getTypeAtBranchLabel` dedups with `sameType`; `typeRelation` is left exactly as it was. \*\*The first attempt tightened `typeRelation`'s `Exact` in place and had to be reverted: that relation ALSO scores overload candidates (`scoreCandidatePriority` / `scoreCandidateWithSkip` in checkExprPass.ms + context.ms — a consumer set missed because a grep for `typeRelation(`/`scoreCandidate(` does not match those names), so a stricter `Exact`/`None` changed candidate selection and produced a null-deref SIGSEGV in `checkCallExpr` on macro `Node` params, plus a 3x self-test slowdown. The lesson is the reference's own split: identity and assignability are two relations, not one relation with a strict tier.\*\* \*\*Sibling in the same commit (must ship together):\*\* once the merge correctly keeps both variants it rebuilds the union, and a bare `createUnion` residual DROPS the discriminant metadata the disc-read contract needs (`resolvePass.ms:1433`) → codegen emits `.kind` against a variant struct instead of routing `\_tag` → hard C error "no member named 'kind'". Both merge sites now go through `joinNarrowedTypes` → `unionPreservingDiscriminant`. \*\*Blast radius:\*\* `sameType` has exactly one consumer (the merge dedup); `typeRelation` and `isAssignable` are untouched, so overload scoring and every assignability site keep their previous behaviour. Gates: macroNodeBogusField guard back to 2/2 diagnostics, discrim.ms 299/299 drc+orc, identity units 453, compiler suite 3342/3342 (36s — the shared-relation attempt had inflated it to 135s), gen-2≡gen-3 emitted-C fixpoint 0/284. Tests PROVEN RED pre-fix: `src/test/lang/discrim.ms` flow-merge section (4 enum-disc shapes fail to build), `src/test/handoff/typeIdentityExact.ms` (13 identity units), nim-guard `src/test/guard/flowMergeDiscIdentity.ms`. \*\*KNOWN REMAINING (separate arc, do not assume closed):\*\* `sameType` compares named types by NAME STRING, not symbol id — same-name types from different modules still count as identical (the per-module type-identity area of the container-assignability row); GenericParam compares by name, not position (inert here — a merge always narrows one reference); the cyclic-type budget answers "same" when spent, which is the conservative direction for a merge (it can only merge, never split). `typeRelation`'s `Exact` remains assignability-grade and still reports any same-kind pair as exact — do NOT reuse it as identity; use `sameType`. |

| \*\*Module check reuse (1 parse / 1 sem per build)\*\* | Each module is imported+sem'd exactly ONCE per compile (`passes.nim` — `importModule` early-returns for already-processed modules; results live on the ModuleGraph); nothing re-parses or re-sems an import. | `checkModuleGraph` already registered each module's program+ctx (`registerModuleProgram`), but `cmdBuildC`/`cmdTest` phase A1 re-parsed and re-checked the entry tree anyway — TWO full checks per build. A1 now looks up `lookupModuleProgram`/`lookupModuleCtx` instead (`src/compiler/compile.ms`, cmdBuildC ~1098 + cmdTest ~1545). The discarded re-check was not just slow: memoized instantiation attaches cross-module generic instances to the graph-check programs, so the thrown-away second check emitted modules WITHOUT them (std/core/struct.ms 518 vs 15707 emitted lines) — nondeterministic undefined symbols on clean-cache builds, long masked by warm .o caches. | SAME (toward the reference's 1-parse/1-sem) | Measured on the self-host tree (Windows, zig cc): build 303.4s→18.8s (16×; checker phases ~29×), test 282s→33-42s. Baseline binary rebuilt from a clean HEAD worktree to rule out contamination; suite 174 files / 3510 tests ×4 green with the reuse binary; self-build fixpoint chains verified (mscC4→mscD, mscJ2→mscK1). |

| \*\*Flow-type query memoization (per-query shared-flow cache)\*\* | No analog: Nim has no control-flow type narrowing — a variable's type never changes along control flow. | Flow-narrowing is the documented TS-leaning divergence (container-assignability row); `getFlowTypeOfReference`/`getTypeAtFlowNode` port the TS checker's per-query shared-flow cache (TS 5.6.2 checker.ts:28391-28402 stake, :28467-28472 commit; binder.ts:1352-1361 `setFlowNodeReferenced` → `FlowFlags.Shared` on 2nd antecedent reference). The port had the checker-side cache (`state.sharedFlows`, flow.ms) but the binder side was NEVER ported — `FlowFlags.Shared` is only ever read, never set, so the cache was dead code and every query re-walked BOTH antecedents at every label: sequential narrowing-if chains cost 2\^N per query (a 50-statement `if (t !== null && t.kind === X)` chain never finished; `callResolve.ms` alone burned 125-143s of a 137s body-check on self-host). FIXED 2026-08-31: `getTypeAtFlowNode` memoizes multi-antecedent BranchLabel results per query through the same sharedFlows list. | DIVERGE-INTENTIONAL vs the TS implementation (the feature itself already diverges from Nim by design): the memo is claimed at QUERY time on real merges instead of a binder-set Shared flag on all shared nodes; LoopLabels keep their `findLoopInfo` re-entry guard; `isDefinitelyNonNullAt` walks its own path, untouched. | Soundness: `getTypeAtFlowNode` is pure per (state, node) and FlowState is created fresh per query, so the first result per label is final within the query; the one theoretical hazard — a BranchLabel inside a loop body visited across accumulating back-edge unions — is bounded by the loop-label re-entry guard returning "union so far". Verified: 11/11 narrowing battery (seq / loop+reassign / loop+continue / nested / switch / merge / else-if / &&-\\|\| / double-continue + 2 must-fail cases) byte-identical against the clean-HEAD baseline binary; suite 3510 ×4; nb25 probe 270s→2.5s, nb50 >600s→1.9s; TS 5.6.2 source read directly (checker.ts + binder.ts), not from memory. Narrower perf coverage than TS (condition nodes with 2 consumers are not cached) — extend the memo if such a pattern ever shows up hot. |

| \*\*Maybe identity survival across type substitution\*\* | generic instantiation copies a type via `copyType` (`semtypinst.nim:394`) then PRESERVES its identity flags — `handleGenericInvocation` `result.flags = header.flags` (`:451`) + `result.flags + newbody.flags - tfInstClearedFlags` (`:489`). Substituting type-vars NEVER rebuilds a type through a ctor that recomputes flags from scratch, so an instantiated `Option\[T]`→`Option\[int]` keeps its kind + identity flags. | `substituteStruct` (`checker/types.ms:1701`) rebuilt a substituted Maybe via the generic `createStruct` ctor, which DROPPED `IsMaybe` (recomputed only structural flags like HasAsgn/DuVariant from children) and copied the stale un-substituted `typeName` (`Maybe\_fn\_fnTT…`). Downstream `isMaybeType`→false → `operatorLower` folded `f !== null` to constant-true (guard VANISHED) + `nullableLower` never unwrapped → `f(x)` called a struct (C "not a function"). | was \*\*DIVERGE-UNINTENTIONAL → SAME\*\* | The \*\*Union\*\* case already re-canonicalized through `createMaybeType`; the \*\*Struct\*\* case was the lone outlier that lost identity. FIXED 2026-07-22 (`ba6b365`): route Maybe rebuilds through `createMaybeType(substituted inner)` — the canonical ctor re-stamps `IsMaybe` + derives the correct substituted name + cache-dedups identity (the MS analog of Nim's `copyType` + `result.flags = header.flags`). Falsifier: mono'd `createMemo\_\_int32`/`apply\_\_int32` body went `{ return f(x); }` (struct-call) → `if (f.present) { … f.value.fn … }` (guarded unwrap). Guard: `src/test/guard/maybeIdentitySubst.ms` (proven RED on the pre-fix binary — build fails "`Maybe\_fn\_fnTTboolean15` is not a function", the stale-name symptom carrying the raw `T`). Sibling of the Structural type-dedup + container-assignability rows above. |

| \*\*Call-site Maybe-coercion uses the INSTANTIATED formal\*\* | `implicitConv` (`sigmatch.nim:2179`): when `containsGenericType(f)` (`:2182`) the conversion node's type is `getInstantiatedType(c, arg, m, f)` (`:2184` → resolves `f` through `m.bindings`, `:2172`) — NEVER the raw generic formal; only a concrete `f` uses `f` directly (`:2188`). | direct generic calls run the arg-coercion loop (`checkExprPass.ms`) BEFORE instantiation (the method path instantiates first — asymmetry), so the Maybe-wrap stamped the RAW formal `Maybe<(T,T)=>boolean>` → C `msClosure` vs `Maybe\_fn\_fnTT…` struct mismatch. | was \*\*DIVERGE-INCOMPLETE → SAME\*\* | The deferred reconciliation in `tryInstantiateGenericCallee` (self-cited "mirrors `sigmatch.nim:2395` `paramTypesMatchAux`") existed but only re-coerced `NullLiteral` args = a partial port of `implicitConv`. FIXED 2026-07-22 (`f1061e0`): (a) the coercion loop DEFERS generic-containing Maybe formals — `findFirstGenericParamName(f) !== ""` = `containsGenericType(f)` analog; (b) reconciliation re-coerces ALL Maybe-coercible args with the SUBSTITUTED formal — `applySubstitutions(formal)` = `getInstantiatedType` analog. \*\*SCOPE:\*\* proven for memo's shape (optional `equals = null`, T bound from `fn: () => T`'s return + untyped arrow params); the general "arrow → REQUIRED generic `Maybe<fn>` param" is still blocked by siblings (arrow not closure-lowered → `int 0`; binding-order binds T from a later arg; explicit-targ arrow degeneration — all pinned in neon `probe/nullfn\_\*`). |

| \*\*Lambda lifting: uniform child traversal\*\* | `detectCapturedVars`/`liftCapturedVars` walk the full tree via a default that recurses EVERY son — `else: for i in 0..<n.len: … n\[i]` (`lambdalifting.nim:511-515`). No node kind is skipped, so an arrow nested in a call held by ANY wrapper (member access, ternary, index, cast) is still discovered + lifted. | `walkLift` (`transform/lowering/lambdaLifting.ms`) had an ad-hoc arm list (Call/Binary/Unary/Object/Array) with a NO-OP `\_ => {}` default → MemberExpr/ArrayAccess/ConditionalExpr/TypeAssertion were never descended, so `g(x => …).toString()` (a call behind a member access) left its inline arrow unlifted → codegen `0 /\* unlowered ArrowFunction \*/` → C `msClosure` ← `int`. A variable-bound arrow escaped (VariableDecl WAS handled). | was \*\*DIVERGE-UNINTENTIONAL → SAME\*\* | FIXED 2026-07-22: default arm now `mapChildren(node, child => walkOrLift(child, state))` — MS's canonical mutating child-walker, the analog of Nim's `for i in 0..<n.len`; walkOrLift lifts arrows + routes statement children back through their own arms; leaves no-op. Proven: baseline emits `unlowered` for member-chain/ternary/index/as-cast, fixed emits a real `(msClosure){.fn=…,.env=NULL}`; battery 3323/14 = known-flake set only. Guard `src/test/guard/inlineArrowMemberLift.ms` (RED pre-fix = 3 unlowered, GREEN post-fix). \*\*This is the general-case blocker behind neon `probe/nullfn\_generic\_arg\_notlowered` — NOT a Maybe/generic issue\*\* (a bare non-nullable non-generic `g(arrow).m()` fails identically); the two Maybe-wrap rows above were a red herring for this sibling. |

| \*\*Statement-expansion walk: uniform child traversal\*\* | Nim `transf.transform` funnels through `transformSons` (recurse ALL sons) + descends nested procs via `transformBody` (`transf.nim:127`); tuple-unpacking (`nkVarTuple`) is NEVER left unlowered because codegen itself lowers it (`genVarTuple`→`lowerTupleUnpacking`, `ccgstmts.nim:103`). | `walkExpandBlocksHooked` (`transform/walker.ms`) — the shared statement-list-expansion walker for 9 desugar/lowering passes (destructuringLower, spread, forOf, switch, match, await, conditional, callHoist, arrayMethodInline) — had a NO-OP `\_ => {}` default → never descended into fn bodies in EXPRESSION position (`VariableDecl.init`, `ExprStmt`, `ReturnStmt`, call args). So `const \[a,b] = f()` inside `const g = () => {…}` / a capturing arrow / a call-arg arrow survived `destructuringLower` (pass 8, 12 passes before lambdaLifting@20) → codegen `/\* unsupported stmt: DestructuringDecl \*/` → C `use of undeclared identifier`. MS codegen has NO nkVarTuple-style fallback (unlike Nim `genVarTuple`), so the early walk MUST be complete. Independent of lifting (a non-lifted `const g=()=>{const \[a,b]=pair()}` fails identically). | was \*\*DIVERGE-INCOMPLETE → SAME\*\* | FIXED 2026-07-24: default arm now `mapChildren(node, child => { walkExpandBlocksHooked(child, …); return child; })` — the direct sibling of row 76's walkLift fix, MS's analog of Nim's `for i in 0..<n.len`. Proven: emit-C `unsupported stmt` 1→0; neon probes `r1\_undeclared\_s`/`r1\_arity\_min` RED (undeclared s/g) → 274/274; battery \*\*3321/16 = known-flake set EXACTLY\*\* (byte-identical fail diff, zero regression — NB true machine baseline is 3321/16, NOT 3330/7). Guard `src/test/guard/destructureInArrowLower.ms` (RED pre-fix = undeclared a/b in all 3 arrow positions, GREEN drc+orc post-fix). \*\*Follow-up (defense-in-depth, separate item):\*\* give codegen an nkVarTuple-style `DestructuringDecl` fallback so lowering never depends on a single pass. |

| \*\*Contextual arrow param/return typing peels Maybe\*\* | No Nim analog (Nim lambdas carry typed params; TS-style contextual param typing is MS-only) — the authority is MS's OWN bare-`fn` formal path, which types an untyped arrow's params from the expected function type. | `checkAnonymousFunction` (`checker/checkExprPass.ms`) gated BOTH the contextual param-type source (`ctxParamTypes = expectedType.typeChildren`) and the Bug-G contextual return-type fallback on `expectedType.kind === TypeKind.Function`. A `fn \\| null` formal is a \*\*Maybe struct\*\* (`IsMaybe`, inner in `typeReturn`), not `Function` — so both gates missed it → untyped arrow params fell to `unknownType()` → C `void\*`. Body `a !== 0.0` → `void\* != double`. | was \*\*DIVERGE-INCOMPLETE → SAME\*\* (parity with MS's own bare-`fn` contextual path) | FIXED 2026-07-22: peel a Maybe (`isMaybeType` → `typeReturn`) into `fnExpected` before both gates. Only SURFACES as a C error when the body forces the concrete type (compare a param to a `double` literal) — `a === b` alone stays `void\*==void\*` and compiles wrongly-typed, which is why the four-cell localization (non-generic/generic × nullable/non-nullable) needed body-forcing probes. Sibling of the "Call-site Maybe-coercion uses the INSTANTIATED formal" row (75) and its SCOPE note ("general arrow → generic `Maybe<fn>` param still blocked"): row 76 fixed the LIFT layer of `probe/nullfn\_generic\_arg\_notlowered`, this fixes the PARAM-TYPE layer underneath it → probe now builds + runs `true`. Guard `src/test/guard/maybeArrowParamContext.ms` (RED pre-fix = `void \*/double` on non-generic + generic nullable-fn arrows, GREEN post-fix). Battery 3330/7 = known-flake set exactly. |

| \*\*Expression-body arrow implicit return skips fitNode\*\* | Nim has no expr-body lambda; the authority is Nim's rule that sem inserts conversions (`nkHiddenStdConv`) at EVERY value-meets-formal position, plus MS's own fitNode invariant ("every fit position shares the one wrap — no position can forget it") and the ReturnStmt path (`checkPass.ms:1230`). | `checkAnonymousFunction` (checkExprPass.ms:5821) checked an expression body via `checkExpr(body, explicitReturnType)` — a contextual HINT, not a coercion — so no wrap node was synthesized; lambdaLifting later normalized `=> x` to `{ return x }` with the raw expr → codegen `\*\_\_result = x;` into `Maybe\_pN` = clang error. Block-body arrows were green (ReturnStmt → fitNode → synthMaybeWrap). | was \*\*DIVERGE-INCOMPLETE → SAME\*\* | FIXED 2026-08-12: `checkArrowExpr` reseats a non-block `arrowBody` through `fitNode` against the checked closure's `typeReturn` (awaited-unwrapped for async arrows, mirroring `checkPass.ms:1210`). Boundary matrix (5 probes): named-fn + block-body arrow GREEN, expr-body RED across field / typed-const / explicit `: int32 \\| null` annotation — annotation alone did NOT save it, pinning the miss to the expr-body path, not type sourcing. Fix empirically closes the sibling shapes: `=> null` (void\* into Maybe carrier) and `=> namedFn` into a closure-returning slot (fn-ptr into msClosure — fitNode's closure auto-wrap arm was equally unreachable); variant→union expr-body was ALREADY green (fitted elsewhere), so the class is exactly "coercions that only fitNode performs". Guard `src/test/fixedbugs/bug105ArrowExprBodyFit.ms` (9 tests incl. ternary body, call-arg position, block-body neighbour; proven RED pre-fix). Gates: suite 3453/3453 on gen-0 AND gen-1 (fixpoint on the compiler-code state), corpus parity 455/0/6xfail + SAN ledger 108/0/1xfail (isolated worktree — first main-tree run false-redded 26 from a peer session sharing out/); JS unaffected (Maybe de-materialized there). Third sibling of the rows 82/85 contextual-arrow family. \*\*Residuals measured 2026-08-13, both PRE-EXISTING (probed red on the pre-fix binary too, separate arcs):\*\* (1) an ASYNC arrow against a concrete contextual `Promise<T>` slot is broken in ALL body forms — block body dies at the checker ("Return type mismatch in '<arrow>': expected Promise, got int32") because `checkAnonymousFunction`'s synthesized symbol never carries SymbolFlag.Async so checkReturnStmt's awaited-unwrap gate (checkPass.ms:1210) can't fire; expr body reaches async lowering un-boxed (raw int32 / post-fix Maybe struct returned where `msFuture\*` expected). The checkArrowExpr fit already unwraps Awaitable for async arrows, so it points the right way once the async family is fixed — PARALOCK territory. (2) `=> match (x) { … }` is a PARSE error ("expected expression") — match-expr is not in the arrow-body grammar; workaround is a block body with `return match`. |

| \*\*Overload call sites bind the winner symbol per backend\*\* | Overload resolution happens once in sem and is WRITTEN INTO the AST — `semcall.nim:847/886` `result\[0] = newSymNode(finalCallee)`; cgen/jsgen just emit the callee sym, so no backend can disagree with the checker by construction. | MS keeps the callee identifier's resolvedSym = PRIMARY and stamps the winner slot on the CallExpr (`cd.resolvedOverloadIdx`, checkExprPass.ms:4201) so check-time preserves the winner view for LSP — an intentional representation divergence. But only the C backend consumed the stamp (TAG\_CALL\_OVERLOAD arm + sig→impl redirect); the JS backend emitted the callee identifier → `mangledFunctionName(primary, name, primary.overloadIdx)` → EVERY js call site called `\_u0` regardless of the winner. Runtime symptom far from cause: `childOf(box)` ran the string body → `Cannot read properties of undefined` deep in std. | was \*\*DIVERGE-INCOMPLETE → SAME\*\* (winner binding uniform across backends; the stamp representation stays, intentionally) | FIXED 2026-08-13: winner selection (raw slot → sym, plus body-less-sig→impl redirect) extracted to `resolveOverloadWinner` (`codegen/c/names.ms`), consumed by BOTH backends — C's TAG\_CALL\_OVERLOAD arm and a new js `emitCallExpr` overload arm (Identifier callee + `sym.overloads` non-empty → emit `jsSymbolName(winnerSym)`; the winner's own `overloadIdx` matches its def name by construction; native-pattern is checked on the WINNER). Guard: corpus `715-overloadDispatch` (3-way overload + churn loop; proven RED on the pre-fix binary = node crash; now c↔orc↔js↔danger identical). Gates: suite 3462/3462, self-host fixpoint 0/295, corpus parity 465/0/6xfail, SAN+ledger 110/0/1xfail, nim-guard ALL GREEN. \*\*Adjacent defects measured en route, NOT fixed (separate arcs):\*\* (1) method overloads broken on BOTH targets at the DEFINITION side — C mangles both class methods to the same `\_u0` ("conflicting types" at cc), js clobbers the prototype slot (last def wins → `a=NaN`); (2) namespace-import call `ns.f(box)` never overload-resolves in the CHECKER ("got Box, expected string" — primary only; fails loud on both targets); (3) a fn-REFERENCE to an overloaded name (`const g = childOf`) binds the primary on both backends symmetrically (pre-existing, coherent). Union-param narrowing (`x as Box` out of `string\\|Box`) is the complementary OPEN defect of the type-directed-dispatch pair — separate arc. |

| \*\*Monomorph annotation roundtrip: parenthesize compound type literals\*\* | Nim substitutes generic type-params on PType NODES (`semtypinst.replaceTypeVarsT`), never on strings — no surface-syntax precedence hazard; `seq\[T]` with `T=proc` stays `seq\[proc]` structurally. | MS monomorphizes string annotations textually: `substituteTypeStrings`/`substAnnotationAll` (`checker/instantiate.ms`) call `monoSubstAnnotation(ann, pname, monoConcreteTypeName(t))` then re-`resolveAnnotation`. `monoConcreteTypeName` (`monomorphize/clone.ms:321`) emitted a Function as the BARE literal `() => number`; substituted into a `U\[]` LOCAL-var annotation it yielded `() => number\[]`, which re-parses as `() => (number\[])` — a FUNCTION returning number\[], not `(() => number)\[]` an Array. So `const x: U\[]` (U=fn) collapsed to `function` → "Return type mismatch: expected Array, got function". Return/param `U\[]` use Type-object `substituteType` (Array branch correct) — only the STRING-annotation local-var path broke. `U=number` (`number\[]`) has no precedence hazard, so only function/compound element types collapsed. | was \*\*DIVERGE-UNINTENTIONAL → SAME\*\* | FIXED 2026-07-25: parenthesize the Function literal in `monoConcreteTypeName` → `(() => number)`, unambiguous under a trailing `\[]`/`?`. Parens are transparent to `resolveAnnotation` (same reconstructed Type → same downstream mangling) and mirror the precedent already set for anon unions (`clone.ms:285-289`) + tuples (bracketed). Battery \*\*3330/7 = known-flake set exactly\*\* (touches every generic instantiation; zero regression). Neon `probe/ufn\_array` RED→runs; `array.test` advances past the inference error to its next distinct sub-bugs (closure-array `.slice`, createRoot void-callback). Guard `src/test/guard/genericFnArrayAnnot.ms` (RED pre-fix = "expected Array, got function", GREEN post-fix). \*\*Latent siblings still bare (same class, not yet Neon-blocking):\*\* anon Union `A | B` + Conditional `A extends B ? C : D` literals are also unparenthesized → `U\[]` with U=union/conditional collapses identically. |

| \*\*Try/finally handler presence is structural\*\* | `genTryGoto` (`ccgstmts.nim:1444-1447`) decides handler presence by NODE KIND — `fin = if t\[^1].kind == nkFinally` and `hasExcept = t\[1].kind == nkExceptBranch`. Never a nil-pointer test, never "is the body empty". A try with no except branch runs its finally and keeps propagating; only a real except branch assigns `nimErr\_ = NIM\_FALSE`. `genTryGoto` ends with `raiseExit(p)` (`:808`) = `if (nimErr\_) goto LA<enclosing>\_ / BeforeRet\_`. The finally body runs under `oldNimErrFin<lab>\_ = nimErr\_; nimErr\_ = false; <body>; nimErr\_ = oldNimErrFin<lab>\_` so its own raise-checks don't misfire while an error is in flight. | MS had NO structural marker: `TryCatchStmtData` carried only `catchBody`, and "no catch clause" was encoded as a placeholder VALUE — an empty BlockStmt (parser) or a NullLiteral (`analyzer/inject.ms` DRC scope-cleanup try/finally, `deferLower`). `genTryCatchStmt` inferred `hasCatch = d.catchBody !== null`, so EVERY try/finally — including the DRC cleanup scaffold wrapped around ordinary functions — emitted a bare-catch handler that did `msErr = MS\_FALSE; msDiscardCurrentException();` and SWALLOWED the propagating exception. The JS backend had the identical defect (`if (d.catchBody !== null)` → emitted `catch {}`). Two further gaps: no trailing `raiseExit`, and no `oldNimErrFin` save/restore (DRC's per-destroy `if (msErr) goto BeforeRet\_` guards misfired on entry). In a TAIL-RECURSIVE function (body wrapped in `while (1)`) the swallow fell to the loop end and re-entered the function → \*\*infinite re-throw\*\*, one fresh `msMakeError` per iteration (neon `renderToString` hung unboundedly; `msc` itself only sat in `\_\_wait4` on the child). | was \*\*DIVERGE-UNINTENTIONAL → SAME\*\* | Introduced by `2974c6c`, which widened a partially-structural predicate to a pointer test while fixing a real bug (an empty `catch {}` MUST still swallow). Inference cannot separate "empty handler" from "no handler" — and a NullLiteral placeholder sitting in a STATEMENT slot gets wrapped in a block by `transform/walker.ms`'s statement-expansion walk, so sniffing the placeholder is a symptom patch. FIXED 2026-07-25 by making presence STRUCTURAL, the MS analog of Nim's distinct node kinds: `hasCatchClause: boolean` added to `TryCatchStmtData` \*\*and\*\* the inline `NodeData` arm (`std/meta/node.ms:364,586` — both declare the shape); two constructors replace inference — `makeTryFinally` (false) vs `makeTryCatch` (true) — used at parser (3 sites, explicit), `analyzer/inject.ms` (2), `deferLower`; `clone.ms` carries the field; BOTH backends read `d.hasCatchClause`. Plus the trailing `if (msErr) { <raiseExit> }` after the finally (`errorTargets` already popped → targets the enclosing handler) and `\_\_oldErr\_<lab>` save/restore = Nim's `oldNimErrFin`. \*\*Third gap, found by AUDIT (pre-existing, NOT from `2974c6c`):\*\* `errorTargets` was popped right after the try body, so a `throw` inside a CATCH body jumped straight to the enclosing handler and SKIPPED that try's own finally. Nim keeps the entry alive across the except branches (`p.nestedTryStmts\[^1].label = nextExcept`) and places `LA<nextExcept>\_:` immediately after each branch body, so a raise inside a handler falls into the finally first; `discard pop` happens only AFTER the branches. Fixed with an `\_\_aftercatch\_<lab>` target pushed around the catch body. Guard `src/test/guard/tryFinallyPropagates.ms` covers 7 shapes and gives a 3-way RED/GREEN discrimination: pre-`2974c6c` binary = `swallow:RED` + `catchthrow-finally:RED` (and propagate/drcscope/tailrec OK — independent confirmation that `2974c6c` is what broke those three); structural-fix-without-`\_\_aftercatch` = `catchthrow-finally:RED` only; complete fix = all 7 ok. Respects row 61's DIVERGE-INTENTIONAL single-slot model: row 61's "bare `catch {}`" means a REAL empty handler (still discards), which is now distinct from absence. Verified: battery \*\*3330/7 = known-flake set exactly\*\*; neon 10 pass, `renderToString` 4s (was unbounded); guard `src/test/guard/tryFinallyPropagates.ms` proven RED (`propagate:RED`) on the pre-fix binary → GREEN. |



| \*\*Assert failure exits via raise; the framework is the catch site\*\* | Nim `assert` (`lib/std/assertions.nim`) expands `assertImpl` → `failedAssertImpl` → `raiseAssert` `{.noinline, noreturn.}`, which RAISES `AssertionDefect`. The exit is the exception mechanism, so it is \*\*return-type agnostic\*\* and behaves identically at any lambda nesting depth; and assert's own doc states the contract for the other half — \*"This exception is only supposed to be caught by unit testing frameworks"\* — i.e. the FRAMEWORK is the catch site, not the assert. | `genAssertStmt` (`codegen/c/statements.ms`) emitted `msTestCheckFail(msg, \_\_FILE\_\_, \_\_LINE\_\_); return;` on the test arm (the non-test arm's `abort()` was already agnostic). Two defects: (a) a bare `return;` is ILL-FORMED C in a non-void function, so an assert inside ANY non-void arrow — `(v: number): number => { assert …; return v\*2; }`, \*\*zero generics\*\* — failed to compile (`-Wreturn-mismatch`); (b) where it did compile it returned from the innermost LAMBDA, not the test. Independently, `ms\_test\_main` (`runtime/core/test.h`) called `e->fn()` and read only `\_\_ms\_test\_failed`, never `msErr` — so ANY uncaught exception escaping a test body was reported ✓ PASS (silent false-green). | was \*\*DIVERGE-UNINTENTIONAL → SAME\*\* | FIXED 2026-07-25. Assert emits `msErr = MS\_TRUE` + `emitPendingErrorGoto(p)` — the conditional twin of `emitErrorGoto`, resolving the same `errorTargets`/`BeforeRet\_` destination `genThrowStmt` uses and setting `beforeRetNeeded` so the epilogue's zero-value return exists. The test boundary consumes it: `if (msErr) { \_\_ms\_test\_failed = 1; msDiscardCurrentException(); }` — exactly row 61's bare-catch consume-once (decref+null), so no leak and no double free. \*\*No exception OBJECT is minted:\*\* `msTestCheckFail` already owns the message (`strncpy` into its own static buffer), and `msCurrException` is deliberately left untouched so an assert failing inside a catch body cannot orphan the exception being handled. The dispatcher TU needed `#include "runtime/core/system.h"` (`codegen/c/test.ms`) — it included only `test.h`, where `msErr` is undeclared. Guards: `src/test/guard/assertInNonVoidArrow.ms` (6 shapes; RED pre-fix = 4 compile errors, GREEN post-fix) and `src/test/guard/testBoundaryReportsEscape.ms` + `fixtures/escapingThrow.test.ms` — the latter must assert a \*failing\* outcome, which a passing test file cannot state about itself, so it \*\*spawns the compiler under test\*\* (`execFile(cwd() + "/msc", \["test", fixture])`) and asserts the child exits exactly `1` (`ms\_test\_main`'s "some test failed" code; `0` = swallowed escape, anything else = `./msc` missing/unrunnable, which must not read as a pass). Proven RED against pre-fix codegen AND pre-fix `test.h` together. Its own exit code is polluted by the known `std/fs/path.ms` flake that `std/process` drags into the closure — read the guard's own `✓ / ×` line. Verified: battery \*\*3330/7\*\* = known-flake set exactly, ZERO regression; `uncaught exception escaped` count \*\*0\*\* across all 3337 battery tests (no test was exploiting the hole, so the fix cost nothing); neon 10/5 → \*\*11/4\*\* (`region` green — this was its sole blocker). Failure reporting (message, power-assert diagram, file:line) unchanged. \*\*Framing corrected:\*\* the Neon tracker filed this as "void-callback inference" (T=unknown → `void\*`); a concretely-typed non-generic arrow fails identically, so inference was never the root. |



| \*\*Value-type Maybe unwrap operators (`as T` / `?? d` / postfix `!`)\*\* | No Nim analog — Nim `Option\[T]` unwraps via `get`/`isSome` procs, not TS operators. Authority is MS's OWN working extraction: flow-narrow (`if (v !== null) use(v)`) on an \*\*identifier\*\* → `nullableLower` rule 1 rewrites `v` → `v.value` (identifier is a C lvalue). | For a value type T, `T \\| null` is the Maybe carrier `{ value, present }`. The three TS unwraps all SKIPPED rule 1's extraction and leaked the carrier into arithmetic ("operand of type `Maybe\_pN` where arithmetic type is required"): (a) `x as T` is a \*\*TypeAssertion\*\* node, not an Identifier — rule 1 only matched Identifier/MemberExpr; (b) `x ?? y` — `inferBinaryOp` typed the result as the LEFT (carrier) type, not the payload; (c) `x!` — the parser had \*\*no postfix `!`\*\* (only prefix logical-not + `!=`/`!==`, three distinct lexer tokens). | was \*\*DIVERGE-INCOMPLETE → SAME\*\* (parity with MS's own flow-narrow extraction; the operators are TS-surface, but the underlying `.value` read is MS's existing mechanism) | FIXED 2026-07-23: (a) \*\*rule 1c\*\* in `nullableLower` — a `TypeAssertion` whose `asExpr` is Maybe and whose `nodeType` is a non-Maybe payload rewrites to `asExpr.value` (same shape as rule 1, TypeAssertion arm); (b) `inferBinaryOp` `"??"` returns `leftType.typeReturn` when `isMaybeType(leftType)`; (c) parser postfix arm consumes `TokenKind.Bang` → `TypeAssertion` with \*\*sentinel `asType = "!"`\*\* (zero AST-struct churn — `"!"` is not a valid type annotation; the checker intercepts the sentinel before `resolveAnnotation`, sets `nodeType = unwrap(operand)`, and rule 1c reads `.value`). Guard `src/test/guard/maybeValueUnwrap.ms` (RED pre-fix: `as`/`??` leak the carrier, `!` fails to parse; GREEN post-fix). Battery \*\*3330/7\*\* = known-flake set exactly. \*\*Motivated by\*\* the `Map.get(): V → V \\| null` flip (std-lib Optional return — DIVERGE-INTENTIONAL vs Nim `Table.getOrDefault`, matching TS/Rust/Swift; `Option\[T]` is model-compatible per row 57's pointer model + this file's Nullable-ref §): value-type map values (`Map<HostNode, number>`) need these unwraps at call sites. \*\*FIXED 2026-07-23 — codegen borrow + checker diagnostic (prior `.value`/materialize story was empirically FALSE):\*\* `const a = <call: unknown\\|null> as unknown` emits `void\*\* a; a = \&(call()); use(\*a)` → clang "cannot take the address of an rvalue". Traced by emit-C (`msc-test`, `/tmp/borrowvar.ms` A-E isolation): NO `.value` is produced and `materializeMaybeReads` never runs on it (it touches only Identifier/Member/ArrayAccess whose \*declared\* type `isMaybeType`; a call rvalue with a pointer-collapsed `unknown\\|null` is neither). Rule 1c also skips it (`isMaybeType(unknown\\|null)` is FALSE — §57 collapses it to bare `void\*`). The `void\*\*`/`\&` borrow comes from \*\*`isUnionNarrowing` (codegen/c/statements.ms:262)\*\* which gates the VarDecl storage-borrow arm (`${cType}\* v; v = \&(init); indirectLocals.push`) at :354. It tests only `asExpr.nodeType.kind === TypeKind.Union` — TRUE for a pointer-collapsed nullable too. Isolation: fA `m.get() as H` borrows; fB `m.get()` (no cast) = value; fD `gu() as H` (gu→plain `unknown`, not `\\|null`) = value; fE `m.get() as string` = Maybe `.value` (value-shaped, handled by rule 1c earlier). So the borrow fires \*\*only\*\* for a nilable-\*\*pointer\*\* union routed through the tagged-union storage-borrow. \*\*Invariant:\*\* union storage-borrow (`\&union`, reinterpret as variant) is valid ONLY for a genuine tagged union (discriminant + inline variant storage, Nim case-object); a nilable pointer (`{Ref\\|Ptr\\|Unknown, Null}`, §57 / options.nim SomePointer split) collapses to a bare pointer — null is the sentinel, no tag, nothing to borrow (Nim never reinterprets a nilable ref). \*\*Verdict: DIVERGE-UNINTENTIONAL\*\* — §57 already established the collapse (`unwrapRefNullUnion`, isPointerType Unknown arm); the codegen gate simply didn't consult it. \*\*Fix:\*\* `isUnionNarrowing` returns false when `unwrapRefNullUnion(srcType) !== null` (2-line: import + guard). Verified precise: genuine DU tests (`src/test/handoff/unionNarrow\*.ms`, 4-variant `DocData`) have `unwrapRefNullUnion → null`, untouched. Runtime prereq: none (value path emits `void\* a = call()`, RC-inert per §57 noRcInfo). Repro `/tmp/unkas.ms`; hits only Neon `reconcile.test.ms` pool setup (`Map<string, HostNode=unknown>`). \*\*SECOND FIX (checker, DIVERGE-INCOMPLETE), found while proving fail-loud:\*\* the cast-site value-shape diagnostic (`checkExprPass.ms:1389`, "cannot cast unknown to value type") inspected only bare `unknown` (`srcType.kind === Unknown`), NOT the nilable-union form `{unknown,null}` (kind === Union) — so `unknown\\|null as <fat value>` slipped past the checker to a cryptic clang "address of rvalue" instead of the clean diagnostic bare `unknown` gets. Fix: peel `unwrapRefNullUnion(srcType)` before the check — mirrors the peel already present at the call-arg sites (`:1951`, `:2858`); the cast site was the only one missed. \*\*Verified (both fixes):\*\* emit-C flip `void\*\*→void\*` (A–E isolation); `unkas` build+run prints `ok` (clang error gone); `unknown\\|null as fat-value` now diagnosed at checker, bare-unknown still diagnosed, `unknown\\|null as Ref` no over-fire; genuine-DU emit-C `msc-b ≡ msc-test` byte-identical; battery \*\*3332/5\*\* (flake-only, 0 regression); guards proven RED→GREEN — `nilableUnknownAsCast.ms` (runtime) + `nilableUnknownCastError.ms` (3/3, checker negative). Nim `options.nim` SomePointer split read this session. Committed `8c69ffa..dd80ebc` (Map flip / operators / codegen guard / checker peel / guards); docs uncommitted per rule. \*\*ADDENDUM 2026-08-14:\*\* postfix `!` now ALSO narrows a nilable-pointer union (`Ref\\|Null`) via an `unwrapRefNullUnion` arm in the sentinel handler (checkExprPass.ms) — type-level only: the carrier is already a bare pointer (§57 collapse) so codegen is unchanged (verified no `.value` read, C+JS). The `T\\|null→T` leniency hides it at every ASSIGNABILITY site — member access, overload scoring and generic inference all measured GREEN pre-fix (r7/r8/r9) — but NOT at a \*\*join\*\*: a surviving null member makes `cond ? t! : "s"` (and `\[t!, "s"]`) a 3-member `{Ref, String, Null}` union that codegen cannot fill (`assigning to 'msUnion\_\*' from incompatible type 'Tok \*'` / `from 'msString'`). Guard `src/test/guard/bangRefNullUnion.ms` PROVEN RED on a binary with ONLY this hunk reverted — branch-join, union-hook and try-join fixes all still in, so the red isolates this narrowing — GREEN on C and JS. The red only became REACHABLE once the branch join (row above) and the try/catch join started producing `Ref\\|Null` from inference; before them the shape could not be written. |

| \*\*Generic instance identity is module-qualified at EVERY gate\*\* | The instantiation cache is keyed on the generic symbol's `itemId` — a `(module, item)` pair, not a name: `addToGenericProcCache` (`semdata.nim:619`) does `procInstCache.mgetOrPut(s.itemId, @\[])`, read back by `procInstCacheItems` (`modulegraphs.nim:348`); `genericCacheGet` (`seminst.nim:89`) then discriminates within that bucket via `sameInstantiation` (`seminst.nim:78`, compares concreteTypes with `sameType`). The instance is owned by the defining module (`setOwner(result, fn)`, `seminst.nim:404`) and its BODY is emitted once in that module, deduped through `q.declaredThings` in `genProcNoForward` (`cgen.nim:1526-1546`) — again symbol identity, never a name string. Two same-named generics in different modules cannot collide by construction. | MS mangles instances to an MS-level name (`mangleMonoName` → `takeWitness\_\_Color`) that carries NO module, then used that bare name as the key at \*\*two\*\* independent gates: (1) `addPendingInstance` (`checker/instantiate.ms`) `\_pendingNames.has(fd.fnName)` — the queue drained into per-module programs; (2) `\_emittedInstances` (`codegen/c/declarations.ms`) `isInstanceEmitted(d.fnName)` — the cross-TU "emit the body once" gate. Both sat under machinery that IS module-qualified: the drain routes by `resolvedSym.modulePath` (row above) and the emitted C symbol is `mangledFunctionName(sym, …)` = `takeWitness\_\_Color\_\_<module>`. | was \*\*DIVERGE-UNINTENTIONAL\*\* (×2) \*\*→ SAME\*\* | \*\*The dedup scope was narrower than the emission scope\*\*, so two modules each declaring a \*module-private\* generic with the same name and the same type args (ordinary module scoping — neither exported, and TS allows it) lost the second one. Gate 1 dropped the decl node silently → `call to undeclared function`; fixing only gate 1 moved the failure to gate 2, which emitted a prototype but skipped the body → `undefined symbol` at link. Both are clean type-checks followed by a toolchain error, with no diagnostic. FIXED 2026-07-28: gate 1 keys on `resolvedSym.modulePath ‖ name` (the same identity the drain routes by); gate 2 keys on the already-module-qualified C `name` (computed one screen earlier at `declarations.ms:150`), which makes the key identical to the symbol the linker resolves — by construction it can never drop a definition that is still referenced, while still deduping the genuine case this gate exists for (a consumer TU re-emitting an instance it doesn't own). \*\*Invariant: a generic-instance dedup key must be at least as specific as the C symbol it guards.\*\* Sibling of the structural-key row (`monoTypeKey` collapsing `Function`/`Union` to a constant) — same bug class, different axis: that one lost the TYPE args, this one lost the MODULE. Real-world pair: `fixedbugs/bug007.ms` + `bug008.ms` (both `takeWitness<T>` + `enum Color`), which is why `fixedbugs/index.ms` was red while `bug008.ms` alone passed. Guard `src/test/fixedbugs/bug059MonoPendingDedupModuleBlind.ms` + `bug059helper.ms` — reproduces standalone (the file imports its helper), PROVEN RED on the pre-fix binary at both gates in turn. The generic-CLASS path was probed with the same shape (two modules, same-named `class Boxy<T>`, different bodies) and is CLEAN — its ctor gate already keys on the emitted `ctorName`. Gates: guard GREEN, 4 shape-probes green, battery \*\*3346/3346\*\*, gen-2 self-apply green, G1-gate 8→7 files. |



| \*\*Bare value-type `T \\| null` in a payload position — lower vs diagnose is per-position\*\* | No Nim analog: Nim's `Option\[T]` is unwrapped by `get`/`isSome` procs, never by operators, and `pointer`-shaped nilables use nil as the sentinel (`options.nim:90-99` SomePointer split, this file's `unknown` row). The MECHANISM reference is MS's own per-type `Eq` lifting (`liftdestructors` analog — `ensureEq`/`fieldEqExpr` in destructorLifting.ms), which already generates field-wise equality including `msStringEquals` for string fields. The SEMANTICS reference is tsc, per TSGAP's dual-reference rule. | For a value type T, `T \\| null` is the carrier struct `{ value, present }`. Every EXPLICIT unwrap already worked (`!`, `??`, `if (v !== null)` — the "Value-type Maybe unwrap operators" row). The BARE form was unguarded in two positions and reached codegen as a struct: `v === 1` emitted a raw C `==` on the carrier (operatorLower's `isValueObject` gate excludes Maybe at line 74, so the comparison fell through every branch), and `f(3, 7)` on a `fn \\| null` passed checkCallExpr undiagnosed (it only validates arity under `TypeKind.Function`). Reference-typed `Box \\| null` is immune by construction — it collapses to a bare pointer, so no carrier exists. | was \*\*DIVERGE-INCOMPLETE\*\* (×2) \*\*→ SAME\*\* (tsc semantics, MS's own Eq-lifting mechanism) | \*\*The two positions want OPPOSITE answers, which is why one "cluster" needed two fixes.\*\* tsc types `v === 1` on `number \\| undefined` as LEGAL — comparison between overlapping types, false when absent — so it must LOWER. tsc REJECTS an invocation of a possibly-undefined callee (ts2722) so that must ERROR. (Arithmetic, the third position, was ALREADY diagnosed — ts18048 parity, `checkExprPass.ms` \~723; a probe matrix initially misread that \*wanted\* error as a third defect.) FIXED 2026-07-28: (a) `operatorLower` routes carrier equality through the generated per-carrier `Eq`, wrapping a bare payload operand into a carrier first — \*\*not\*\* an inline `v.present \&\& v.value === o`, because the carrier side may be a call (`m\["k"] === 1`) and the inline form would evaluate it TWICE; the Eq call takes each operand once by construction. Wrapping also gets absent-vs-ZERO right, which a payload-only compare silently does not (an absent carrier zero-inits its payload, so `null === 0` would report true). Carrier Eq is generated from the \*\*Type\*\* via a new `pendingCarrierEqs` channel because `ensureEq` resolves its argument by NAME through the symbol table (`destructorLifting.ms:1472`) and a synthesized carrier has no symbol — the same "synthesized types have no name to look up" shape as the mono-instance rows. (b) `checkCallExpr` rejects a Maybe-typed callee before the Function branch. Guard `src/test/fixedbugs/bug061MaybeCarrierBarePosition.ms` (9 tests: absent-vs-payload, absent-vs-zero, absent-vs-absent, `!==` negation, string payload, single-evaluation, the call diagnostic, and the unwrapped call still legal) — PROVEN RED pre-fix. Closes `bug010` + `bug047` of the G1-gate. \*\*Still open, deliberately (TSGAP G6):\*\* the REFERENCE sibling — `const b: Box \\| null; b.n` — is accepted silently with no diagnostic and no guard (tsc ts18047). It emits valid C (a plain pointer deref) so it segfaults at runtime rather than failing to build, which is exactly why it never appeared in the G1-gate list. |

| \*\*No `any`; `undefined` is a warned alias of `null`\*\* | Nim has no `any`: the top type is `pointer` (RC-inert, accepts only nil/ptr/proc/cstring implicitly — the `unknown` row above), and there is no undefined-vs-nil split at all — one absent value, `nil`. So the reference offers no analog to erase `any` to; a "trust me, read a field off it" type cannot exist on a C target that has no dynamic member lookup. | `resolvePass` mapped the annotation `"any"` onto `unknownType()` — the checker's INTERNAL pending-inference sentinel — and `"undefined"` had no mapping at all, falling through the exempted unresolved-name path to the same singleton. Both therefore inherited every leniency gate that exists to serve inference (`compat.ms:263/661/893` allow-all on `TypeKind.Unknown`) and bypassed the UserUnknown diagnostics entirely — so `undefined` silently became an opaque pointer instead of the null alias LANG.md already documented. | was \*\*DIVERGE-UNINTENTIONAL → SAME\*\* (`any` rejected; `undefined` aliased to null, TS-compat) | \*\*The permissiveness was never designed — it was borrowed identity.\*\* git shows `"any" => unknownType()` arriving inside a grab-bag commit (`507df8b`, "std/http solidify … many minor bug fixes"), not a type-system commit; a later hard-error pass for unresolved names (`4a3d12f`) then had to EXEMPT `any`/`undefined` to keep building, layering a second cover over the hole. An earlier revision of the `unknown` row described this as "TS parity + escape hatch" — that was post-hoc narration, corrected here. FIXED 2026-07-30, and the two names get DIFFERENT verdicts on purpose: `any` is a hard error carrying the alternative (`'any' is not a MetaScript type - use 'unknown' with an explicit cast`) because nothing can implement it, while `undefined` resolves to `nullType()` and emits a migration WARNING (`'undefined' is an alias of 'null' - prefer 'null'`) — \*\*kept legal for TypeScript backward-compatibility\*\*, since pasted TS code uses `T | undefined` for exactly what MS spells `T | null`, and it behaves identically (the union takes the ordinary null path: Maybe-carrier for value types, bare pointer for refs). Both names left the `emitUnresolvedTypeRef` exemption list (dead entries once each has a real arm). \*\*The internal singleton is untouched\*\*: pending inference, generic inference and the Raiser/comptime path keep using `unknownType()` exactly as before — only the two SPELLINGS that let user code name it are gone. Metaprogramming is unaffected by construction: its dynamism rides `Node` + the `NodeData` union + `as XxxData` casts, and a census found ZERO `: any` in `std/`, `std/meta/`, the comptime tests, or any downstream consumer (neon / lightcube / photon). Census of real users at the time of the fix: 2 test files (both in the G1-gate list — `checker3pass/stress/deepNesting`, `handoff/classMemberElseIf`, each closed by typing the code properly: `Node` + `forEachChild`, `CheckerContext`) and 2 compiler sites (`methodToFunction.ms` `any\[]` → `Type\[]`; `package/org.ms` `headers: any` → `HttpHeaders`). `"any"`/`"undefined"` also dropped out of the primitive-name list in `transform/native/pointerParam.ms`. Guard `src/test/fixedbugs/bug069AnyUndefinedAnnotation.ms` (7 tests: `any` rejected bare and as `any\[]`, `undefined` warns yet compiles, the warning is emitted once per annotation (not once per pass), `string \\| undefined` free of errors, `unknown` still legal, `null as unknown as T` still legal). \*\*Guard-authoring trap hit here:\*\* `errorCount` in `handoff/helpers.ms` returns `ctx.errors.length` — the whole diagnostics list, warnings INCLUDED — so asserting `errorCount === 0` on the `undefined` cases went red on the guard's own expected warning; `strictErrorCount` is the severity-filtered one, and `warningCount` includes the PRELUDE's own warnings so the once-per-annotation check has to be a delta against the same program spelled with `null`. One more mechanical trap, paid for in a wasted round: `resolveAnnotation` is reached once per checker pass and the passes report DIFFERENT columns for the same annotation (declaration start vs the annotation itself), so a position-keyed dedupe does nothing — `warnOncePerLine` keys on (line, message), accepting that two `undefined` annotations sharing a line collapse to one hint. `addWarning` itself is deliberately left un-deduped (global behaviour, out of scope). Gates: suite \*\*3364/3364\*\* drc AND orc, gen-2 self-apply green + gen-2 reproduces the diagnostic, G1-gate 4 → \*\*2 files\*\*. Note the `unknown` row's own rule stays in force and is the reason `x as string` on an `unknown` is STILL an error (no void\* repr for a fat value) — that is wanted behaviour, not collateral. |



| \*\*String mutability contract\*\* | `string` is a MUTABLE value type: `s\[i]=c`, `s.add`, `setLen` — incl. `setLen(0)` buffer-reuse (strs\_v2.nim source comment: "pattern 's.setLen 0' is common for avoiding allocations") and `var string` out-params. Safety comes from the ENGINE, not the surface: NimStringV2 has NO refcount — assignment is an eager deep copy (`nimAsgnStrV2`, dest-capacity reuse) so every string is uniquely owned and in-place mutation is structurally safe. The surface's price: the `prepareMutation` trap (system.nim:3112 — literal-COW + `addr` mutation crashes without it), the JS backend must copy every string/seq assignment (jsgen etySeq/nimCopy), and JS std collections can never bind native Map/Set (tables.nim is 100% portable, zero importjs; native JS collections are FFI-only with `cstring` keys — jsheaders.nim). | `string` is OBSERVABLY IMMUTABLE at the surface on ALL backends; the C ENGINE stays the unchanged NimStringV2 clone (msString eager-copy + literal-COW + `stringOpLower` `s=s+x`→`msStringAppend` in-place; runtime mutation tier `msStringSetChar/SetLength/SetSlice` stays INTERNAL, for lowerings only). The checker rejects the mutation surface fail-loud, pointing at the buffer tier (`uint8\[]` + `asBytes`/`asString` zero-copy bridges, bug063-066) — the typed home for Nim's `setLen(0)`/`s\[i]=` idioms. Landed 2026-08-01 (STRING-CONTRACT §6 P1-P3): JS `string` = native JS string (TS-named surface UTF-16-native by the index-space contract; byte tier = cached hand-rolled WTF-8 encode — TextEncoder mangles lone surrogates), `cstring ≡ string` on JS, and JS Map/Set/HashMap/HashSet = native binds with `get(): V \\| null`. Raiser untouched (VM string ops already functional-only: ConcatStr/StrLen). | DIVERGE-INTENTIONAL | Decided 2026-08-01 after tracing the reference's root reason for mutability and probing MS. C loses NOTHING: in-place append already flows through the functional surface (measured linear, user≈0 at 100k appends); assignment is already eager-copy parity (39µs per 131KB assign = memcpy); ASan-clean alias probe; and the mutation surface never worked (`s\[i]=` died at clang — emit passed msString by value into `msStringSetChar(msString\*,…)` — and no std mutate API exists, so no user code depends on it). TS-surface rule applies: a visible un-TS surface loses; Nim remains the internal-mechanism reference. Full design, per-Nim-path alternative table, and migration plan (P0 contract lock-in → P1 js native string → P2 native collections → P3 cleanup) live in \*\*docs/STRING-CONTRACT.md\*\*. \*\*ADDENDUM 2026-08-15 — the immutable-surface/mutable-engine seam has a live defect, see STRING-CONTRACT §3 (C).\*\* The UTF-16 TS tier is funded by an is-ASCII cache in the payload `cap` bits that exists in NEITHER reference: Nim needs none (its `len` IS the byte count), and the JS engines fix the representation at CONSTRUCTION rather than recomputing on read. MS computes it lazily ON READ and writes it back into a payload the engine mutates in place, so (a) a read path writes — a thread race, and the reason literals could not be `.rodata` — and (b) `msStringPrepareAdd` clears the bits only when it reallocs, so an append that fits in spare capacity leaves a stale flag and `.length` over-reports (measured: `"ab"+"c"+"d"` then `+"é"` gives 6, must be 5; a realloc-forcing variant and a fresh `"héllo"` both answer correctly in the same run). Agreed fix, unimplemented: make the flag a WRITE-side contract — set at construction, compose on concat/append (`ASCII(a++b) = ASCII(a) ∧ ASCII(b)`), clear in the mandatory mutation gateways (`prepareAdd`/`prepareMutation` — the same cut-point Nim already uses for literal COW), reads pure. Then a missed site degrades to "slow", never "silently wrong", and the pure-read rule is what the freestanding profile requires anyway. Landed in the same session (correctness on every target, not just freestanding): string literals are now `static const` in `.rodata` with the ASCII answer BAKED into `cap` at emit time — which is what `runtime/core/string.h:74-77` always claimed — and the 128-entry single-char table is const-initialized, retiring its init guard and constructor. Do NOT hunt for the UTF-16 tier in Nim: its reference is the JS engines; its normative spec is LANG.md §0. |

| \*\*Program entry / `main`\*\* | no special name — entry is the main module's top-level statements; `system.quit(code)` terminates | same: entry = top-level code, run in `\_\_Init000` dependency order; `MsMain`/`MsPreMainInner`/`MsMainInner`/`msProgramResult` are a name-for-name port of `NimMain`/`PreMain`/`NimMainInner`/`nim\_program\_result` (cgen.nim:1665-1862); `process.exit(code)` is a Node-shaped surface over the same libc `exit` | SAME (2026-08-16) | the auto-call of an \*unreferenced\* `main` was OURS — absent from both Nim and TS — and its heuristic silently disabled itself the moment `main` was mentioned anywhere (`const g = main;`), so a program could go inert with no diagnostic. Removed; every entry now calls its own `main()`. A module that is BOTH a CLI entry and a test target uses `when (!testBuild)` (condsyms port). No entry-module predicate, deliberately (decided 2026-08-17): nothing imports an entry module, and a test build's entry is still the entry — build kind is the discriminator, not module position |

| \*\*Macro returning multiple statements (splice)\*\* | a macro's returned `nkStmtList` stays NESTED at statement position — `semStmtList` (semstmts.nim:2941-3001) walks sons transparently for noreturn detection but never flattens them into the enclosing list; declarations inside do not escape to module scope | `SpliceMany` at statement position FLATTENS: `spliceStmtMany` (checkPass.ms) collects each element (collectVariable/collectFunction + `SymbolFlag.Global` — the re-collect, since collectPass walked the original list before the macro ran), checks and hoists the prefix via `pendingHoisted`/`drainHoisted`, and replaces the ExprStmt with the last element in place | DIVERGE-INTENTIONAL (2026-08-18) | the flatten is what `@stdbModule` needs — sibling top-level DECLARATIONS (`@emit` blob, registration call, dispatcher) that Nim expresses with templates-in-stmtlist but MS cannot, because MS macros return one node and MS has no untyped AST tier. Nim's nesting rule exists for templates, not for a node-returning macro system; porting it would leave multi-decl emission impossible. Verified: corpus 724 (`a+b=3`), multidecl 2868/2868 incl. the flipped positive test, gate 174/3479. Known residual (pre-existing, NOT this change): a macro PARAM referenced in a returned node's fields is dropped by the VM serialize step — upstream bug #6, see spacetime/docs/ROADMAP.md |

| \*\*How a `Span`/openArray argument's `(data, len)` pair is built\*\* | `openArrayLoc` (ccgcalls.nim:260-353) materializes the argument ONCE into a location — `var a = initLocExpr(p, if n.kind == nkHiddenStdConv: n\[1] else: n)` (:279) — and every later read repeats that LOCATION'S NAME, never the expression: the payload is `cIfExpr(dataFieldAccessor(p, ra), dataField(p, ra), NimNil)` (:318/324/343, the empty/nil guard) and the length is `lenExpr(p, a)` = `dotField(rdLoc(a), "len")` (cgen.nim:477-483). A fixed-size array takes neither: `rdLoc(a)` plus a STATIC `lengthOrd` (:327-331), no guard, because its buffer is inline and never nil. `genArg` routes every `tyOpenArray`/`tyVarargs` formal through this one proc (:380-382) | `spanLower` (Array/String→Span arms) and `spanParamExpand` (Case 2, the path call arguments actually take) built the pair from the argument's AST NODE, referencing it 2-3× (`.length > 0`, `.data`, `.length`). A later pass then hoisted EACH occurrence into its OWN temp | was \*\*DIVERGE-UNINTENTIONAL → SAME\*\* | \*\*Root:\*\* repeating a location name is idempotent; repeating an expression is not. `probe(vary())` emitted `dollartmp\_5\_ = vary(); dollartmp\_6\_ = vary(); probe((\*dollartmp\_5\_).p->data, (\*dollartmp\_6\_).len)` — the callee got one object's POINTER with another object's LENGTH. Measured 2026-08-20 on a HEAD-matched gen-1 with a clean cache: a `vary()` returning a 1-byte buffer on call 1 and an 8-byte one on call 2 gave `callee len=8 first=11`, i.e. a licensed 7-byte OOB read (the earlier write-up called this "runs 2-3 times, non-deterministic" and understated it). The lvalue-only guard shipped 2026-08-18 was a workaround for the same root, and it left the empty-array-from-a-call case crashing on a NULL payload. C only — the JS lane measured `calls=1` (both passes are `!jsBackend`). \*\*FIXED 2026-08-20\*\* by following Nim: `materializeSpanSources` (spanLower.ms) binds any non-location source to a temp before the pair is built, at the two entries that reach a Span formal (a declared `HiddenStdConv`, and a Span PARAMETER position on a CallExpr), so the reads below always repeat an identifier; `spanParamExpand` grew the `tyArray` arm (SizedArray → inline buffer + static length, no guard). Hoisting uses `walkExpandBlocks` + `freshTempSym` (the callHoist shape — flat peer statements, not a BlockStmt) and is restricted to statements whose expression runs exactly once (`VariableDecl`/`ExprStmt`/`ReturnStmt`, skipped when `containsConditionalEval`), because a ternary arm or `\&\&` RHS would change how often the source runs — Nim has no such restriction only because its codegen emits into the branch's own statement stream. The lvalue restriction is now dead weight, kept as a safety net for sources the hoist declines. \*\*Consequence:\*\* an array LITERAL at a Span argument works for the first time (it becomes a stack `T\[N]` temp), closing the codegen half of upstream #7(b). CLOSED 2026-08-23 (`86b2bb8`): the checker peels Span alongside Array/SizedArray for literal element inference. NOT Nim parity — `nim c -r` refuses `openArray\[uint8] ← \[7,8,9]`; this keeps MS's own TS-style literal inference consistent (same family as `T|null`). Also unrelated and then-broken: a function RETURNING `Span<T>` built from an array (`msSpan\_uint8\_t` ← `msUint8Array\*`) — closed by design 2026-08-28: Span return is a checker error (see the Span-return row). Guard PROVEN RED pre-fix: corpus `725-spanArgSingleEval` (the pre-fix binary fails to compile it at the literal; the single-eval half is independently red — `len=8 first=11` vs `len=1 first=11`). Gates on the fixed binary: suite \*\*174 files / 3493 tests\*\*, corpus \*\*570 pass / 1 fail / 6 xfail / 0 xpass\*\* where the single fail is `507-fsBasics \[orc]` build-killed under load and re-runs green (`4 pass · 0 fail`) on BOTH binaries, `725` parity `c↔orc↔danger↔js identical`, 60 guards identical to the pre-fix binary (the two actor guards that tripped in a 60-build batch pass individually at 352/352 and 292/292), gen-2 self-host builds and runs the guard green. \*\*SUPERSEDED 2026-08-23 (`7ea2049`): the convention itself was the deeper bug.\*\* `spanParamExpand` rewrote signatures module-locally, so the defining and importing TUs emitted two C signatures for one symbol (`(uint8\_t\*, int64\_t)` vs `(msSpan\_uint8\_t\*)`) — a cross-module span call passed garbage (corpus `726-spanCrossModuleAbi`, proven RED rc=255 pre-fix). The fix keeps the reference's PRINCIPLE (convention derived from the TYPE, identically in every TU) but not its ABI: non-extern functions keep `Span` end-to-end on codegen's pre-existing type-derived by-pointer convention (`ccgIntroducedPtr`, types.ms); only EXTERN functions keep the flat `(data,len)` FFI expansion (runtime C is written against it, e.g. `msOsCpus`). `wrapSpanArgs` (spanLower) wraps non-span call args at Span formals in `HiddenStdConv` so one lowering path builds the span value; the conv arm peels `Ref` around the source type. Closure Span params work now (lambdas are lifted before the pass runs). Newly surfaced, pre-existing, then-open: decl-site `const s: Span<T> = arr` gets NO conversion node from the checker (raw C assign — never worked; CLOSED 2026-08-25), and Span RETURN (banned by design 2026-08-28, `aa23ebb`). Gates: suite 174/3506, corpus 571/0/6 + 726 four-lane parity, guards ALL GREEN, gen-2 self-host, spacetime reader-as-Span 325/310/326/330 + conformance 12 vectors. \*\*REPLACED 2026-08-23 (session 2): `materializeSpanSources` deleted; the single-eval moved to the ANALYZER, where Nim actually does it.\*\* Probed the mechanism's fate: it WAS load-bearing (deleting it alone → 725 red, `pair=8:11 evaluations=2`), but its two self-limits left two real miscompiles at HEAD, measured: a span-source call in an if-CONDITION (`if (rec(vary()))` → `8:11 calls=2`; `unconditionalExprOf` returns null for IfStmt) and an unconditional span source in a statement merely CONTAINING a ternary elsewhere (`pair(vary()) + (flag ? "-t" : "-f")` → `8:11 calls=2`; the `containsConditionalEval` skip discards the whole statement). while/for-header conds were already safe via callHoist's `expandWhile` (hoists ANY fresh RC call — no conditional-eval precheck, unlike `expandIf`). Twin-probe Nim (`--gc:arc`, emitted C): `colontmpD\_ = vary\_\_(); pairOf\_\_((colontmpD\_).p ? (colontmpD\_.p->data) : NIM\_NIL, colontmpD\_.len)` — the once-evaluation of an owned rvalue source is INJECTDESTRUCTORS' `:tmpD` temp, in the if-condition case too; `openArrayLoc` only repeats that location's name, and the nil guard is a C-level `?:` invisible to any statement lowering. The earlier row text blamed codegen's statement stream — wrong half: for RC sources the statement-level materialization is a phase-4 job, and moving ours to codegen would have orphaned the temp from DRC cleanup. MS parity now: (1) `ensureDestructionIfNeeded` (inject.ms) memoizes captures per statement on node IDENTITY (`capturedNodes`/`capturedSyms` in DrcContext, cleared per `processStmtList` iteration) — a transform-shared fresh-producer node lands in ONE `$tmp` instead of one temp per reference; (2) the empty-array guard moved BELOW the AST: the Array→Span arm emits `msArrDataOr0(src.p)` (array.h: `((p\_) ? (p\_)->data : NULL)`) for ALL sources, replacing the lvalue-only AST ternary. An AST-level guard-for-everyone was tried and REGRESSED (calls=2 everywhere): `lowerConditionalExpr` splits the ternary across statements, defeating the per-statement memo — the guard must not exist at the AST layer. Net −126 lines. Probe matrix on the fixed gen-1 (11 shapes): stmt/if-cond/mixed-ternary/nested/return/struct-field/ref-arr-member/struct-mixed all `1:11 calls=1`; while-cond \& for-header correctly `1:11;8:22; calls=2` (per-iteration re-eval). Gates: suite 174/3506 on gen-1 AND gen-2 self-host; corpus parity 576/0/6 (725+726 `c↔orc↔danger↔js identical`) + SAN/DRC-ledger 133/0/1; guards ALL GREEN; spacetime 325/310/326/330 + conformance 12 vectors. Validated on a clean-HEAD /tmp tree (`sf\_c1\_455917275`) — the live tree could not self-build at the time (another session's `preprocess.ms` WIP needs a newer compiler), so the combined build with that WIP is UNVERIFIED. Both since closed: decl-site Span coercion (2026-08-25), Span RETURN — banned by design 2026-08-28 (`aa23ebb`, Span-return row). |



\### Local (non-module-scope) declarations — collectPass/checkStmt (DIVERGE-NARROWED; local decls work since 2026-08-15, shadowing still rejected)



\*\*Nim\*\* enters every declaration's symbol into the CURRENT scope at its point of semantic analysis —

`typeDefLeftSidePass` (semstmts.nim:1444) → `addInterfaceDecl` → `addInterfaceDeclAt(c,

c.currentScope, sym)` (lookups.nim:435); there is no "collect only top-level" concept, and local

types work (verified by running Nim: local `type` in a proc, including shadowing a module-level

name, resolves innermost like TS). \*\*MS\*\* collects declarations in a top-level-only pass

(`collectTopLevel` walks `programStmts` only) and the check-side misses were SILENT: `checkClassDecl`

did `lookupSymbol → if null return` (so a shadowing local class silently bound the OUTER symbol —

measured wrong answers, C `1` vs JS `undefined` vs TS/Nim `2`), the grouped

Interface/Struct/Enum/TypeAlias/Extern arm was `=> {}`, and a local `extern function` (parsed as

FunctionDecl with "extern" in fnFlags) fell into the nested-fn rewrite and lifted a bodyless

closure → link error. The Nim analog of the missing behavior is the loud `internalError`

fallthrough. \*\*2026-08-14, Stage 1:\*\* `rejectLocalDecl` in checkStmt (checkPass.ms) — a located

error for all 8 decl kinds when `table.current.scopeKind` is not Module/Global. Guard

`src/test/fixedbugs/bug106LocalDeclRejected.ms` proven RED→GREEN; battery 3474/3474. `when`-block

module-level decls are unaffected (flattened before collect, measured). \*\*2026-08-15, Stage 2:\*\*

all 8 kinds (type alias, interface, struct, enum, class, extern, actor, macro) are admitted in a

non-module scope by reusing the module-level `collect\*`/`resolve\*` pair at the point of semantic

analysis — `defineSymbol` targets `table.current`, which is exactly Nim's `addDeclAt(c,

c.currentScope, sym)` — and lifting the decl node onto `programStmts`, because every transform and

both backends discover types by walking module-level statements. The lift goes to the FRONT: C

claims TypeInfo ownership when the declaration is emitted (`declaredThings`, genClassDecl), so a

decl landing after its use site emitted `extern msTypeInfo <T>TypeInfo` with no definition —

caught by the local-actor case, where destructorLifting also declines TypeInfo because

`isClassOrInterface` covers Class/Interface only. \*\*Residual divergence:\*\* a local name is admitted

only when it is free module-wide (`claimLocalTypeName`); SHADOWING stays rejected, where Nim

resolves innermost. C keys both the emitted struct and its include guard on the bare name

(`genObjectType`: `mangle(typeName)` + `#ifndef <name>\_DEFINED`), so a shadow or a sibling-scope

duplicate would silently collapse into whichever definition emitted first. Closing it needs

mangling keyed on symbol identity the way Nim's `getTypeName` + sigHash does (ccgtypes.nim:150) —

same arc as the generic-instance identity row; the JS collision (nested class emitted raw under the

SAME module-only mangled name as its top-level shadow) is the standing proof.



\### Test-block local declarations — collectPass (DIVERGE-INCOMPLETE, low-priority)



`collectPass` recurses a test block only for `function` declarations (which hoist, and which

codegen lifts to a top-level C function — `checkBlock` block-scopes them but that alone does not

make them codegen-emittable). Block-local `const`/`let` are left to `checkBlock`'s own scope —

they don't hoist (TS temporal dead zone), and collecting them to module scope made sibling blocks

reusing a name collide (`Duplicate symbol 'r'`; broke the self-host binary on std/serialize/json

while the suite stayed green — guard `fixedbugs/bug048`). \*\*Residual gap:\*\* two sibling test blocks

with a same-named local `function` still collide as module-scope overloads → wrong resolution / C

dup. Fully-TS-correct fix = mangle each test block's lifted functions per-block (mirror

`lambdaLifting`'s per-block env naming `test${counter}`). Rare (needs duplicate local-function

names across sibling blocks); deferred.



\### Test-block DRC injection — inject.ms dispatch (DIVERGE-INCOMPLETE, fix known, left OFF)



`test { }` block bodies \*\*never get DRC scope-cleanup\*\* → owned heap locals in a test leak (every

test with heap locals, PASS or FAIL path). Empirical proof (emit-C, `msc test f.ms --gc=drc

\--emit=c`): a test with `const big = concat(a,b)` (heap string) emits `\_\_ms\_test\_0` with `big\_1\_`

allocated + used but \*\*no `msStringDecref(big\_1\_)` before the closing brace\*\*.



\*\*Nim\*\* wires `injectDestructorCalls` INTO cgen for every proc body (`cgen.nim:1301-1302`) and every

module-level stmt (`cgen.nim:2464-2480`), flag `sfInjectDestructors` set uniformly

(`sempass2.nim:144`); an unhandled node kind is a LOUD `internalError` (`injectdestructors.nim:1099`),

never silent. Structurally impossible for a codegen-reaching body to escape injection. `unittest.test`

is a template → expands to ordinary proc code → gets injection like anything else.



\*\*MetaScript\*\* DRC injection is a SEPARATE pre-codegen pass `injectProgram` (`inject.ms`) that

dispatches per statement kind (`inject.ms:1370` match): `FunctionDecl → processFuncDecl` (:1374),

`ClassDecl → processClass` (:1385), \*\*no `TestDecl` arm\*\* → falls to the silent `\_ => stmt` (:1388)

passthrough. But codegen `genTestDeclNode` (`codegen/c/test.ms`) DOES emit the body as

`static void \_\_ms\_test\_N(){ body }`. So the test body reaches C but skips DRC. Made `test` a

first-class `TestDecl` and forgot to wire it into the separate DRC pass; MS's `\_ => stmt` silent

fallthrough (vs Nim's `internalError`) let it slip with no diagnostic.



\*\*Verdict: DIVERGE-INCOMPLETE (unintentional).\*\* The Nim-faithful state is the fix (inject test bodies

like every other body) PLUS a loud fallthrough. Leaving it off is itself a divergence — a controlled,

scoped, logged one.



\*\*Fix is known and mechanically correct (verified, NOT landed):\*\* add `NodeKind.TestDecl =>

processTestDecl(...)` routing `d.testBody` through `processFuncBodyWithParams(testBody, null, testName,

\[], …)` (ownerSym/funcNodeType null OK — 0 params, gets processStmtList + generateCleanup). Emit-C with

that build (`msc-g1`) confirms `msStringDecref(big\_1\_)` now appears at scope exit.



\*\*Why it is left OFF (the blocker):\*\* enabling DRC on \~3300 test bodies \*\*breaks the full suite\*\* —

it wakes latent aliasing bugs in the CODE-UNDER-TEST. Mechanism: many test bodies read SHARED/module-

global state into a local (e.g. parser `parseParams` puts the same Node pointers in its owned return

AND global `\_lastDefaults` without incref). The new cleanup frees the shared payload → corruption.

Dormant before because a test body was never cleaned + tests were authored for the retired JS runner (JS

GC). Nim never hits this: Nim seqs are VALUE types (copied on return), so destroying a local that came

from a global is safe; MS arrays are REFERENCE types (`msRefArray` shared payload), so destroying an

array-local aliased to a global corrupts it. Fixing it = the A-arc: land the dispatch, then hunt every

exposed aliasing bug across the suite (unknown count) — high effort/risk. NOT done.



\*\*Decision (2026-07-21): leave OFF, this row IS the record.\*\* The leak is TEST-ONLY and benign —

confined to the test process at teardown (OS reclaims), and native leak-checking uses `programs/`

main-fns, not `test{}` bodies. The shipped compiler and its leak guarantees are unaffected; the

divergence is scoped to `test{}`. If a future need for leak-checking INSIDE test blocks arises, that

is the trigger to open the A-arc. (Standalone-subset pass/fail counts are red herrings — some files

fail/crash standalone under BOTH pre-fix and fixed `msc` due to order/global-state artifacts; only

FULL-suite pre-fix vs full-suite fix is clean signal.)



\---



\## 2. GenericInstance / generic-struct DRC — mostly CLOSED (was a safety gap)



\### Per-type lifecycle hooks for a GenericInstance — DONE (Nim parity)



\*\*Nim\*\* (`injectdestructors.nim:265`): strips `tyGenericInst` to the concrete `tyObject`,

classifies by its fields, lifts hooks with the \*\*mangled\*\* C name (`SetEntry\_\_stringDestroy`).



\*\*MetaScript\*\* (`classify.ms:188-217`, the GenericInstance arm): an RC-bearing instance

(`hasAsgnFlag` on the wrapper or on the instantiated `t.typeReturn` body) returns

`RcKind.Named` with `mangleMonoName(t.typeName, t.typeChildren)` → `SetEntry\_\_stringDestroy/

Copy/Sink`. Hooks are lifted from the concrete (substituted) fields by `destructorLifting.ms`

(GI scan \~1784 via `unwrapGenericInstance`). \*\*This is Nim parity.\*\* (Earlier revisions of this

doc claimed the arm returned `noRcInfo` — stale; it has mangled per-instance since.)



\### Bare-`Struct` generic collapse (the IteratorResult class of bug) — CLOSED for IteratorResult



A generic struct created in transform/checker as a \*\*bare `Struct`\*\* named after its base

(not a `GenericInstance`) collapses every instantiation into one C struct; when modules bake

different concrete field types into it, the layouts diverge under one C name — a latent \*\*ABI

hazard\*\*. This bit `IteratorResult<T>`: `{ void\* value }` in one TU vs `{ msString value }` in

another (masked only because it is consumed-immediately).



\*\*Fix\*\* (Nim full-mono parity): `createIteratorResult` (`types.ms`) builds the result as

`createGenericInstance(IteratorResult{value:T,done}, \[yieldType])`, so each yield-type mangles

to a distinct, consistently-laid-out `IteratorResult\_\_string` via the GI codegen arm

(`codegen/c/types.ms:716`). Both `createIterator` and `generatorLower.buildIterResultType`

route through it; the bare `IteratorResult` template now only appears for genuinely-generic

`T` (stays `void\*`, consistent, single TU). `==` on the GI result is never instantiated

(`isValueObject` requires `TypeKind.Struct`, and no source compares two iterator results) —

matches Nim's "lift only what's used" / `tyGenericParam → discard`.



\### Still open (future, low-priority)

\- A \*\*user-defined\*\* generic struct VALUE with owned RC fields stored/aliased long-term

&#x20; (not borrow-only): classify mangling handles its hooks, but `\&`-of-array-element after

&#x20; `nativeLower` (`s.data\[i]` is a macro) still needs a temp hoist. No current API exposes this;

&#x20; driven later by the array→`Vec<T>` migration. Files: `classify.ms`, `destructorLifting.ms`.

\- Collection entry structs (`HashSetEntry`/`MapEntry`) intentionally keep `key: T → void\*`

&#x20; (consistent layout, borrow-only, live `HashSetEntryEq` compares `hcode`) — not collapsed, no

&#x20; hazard, deliberately NOT monomorphized.



\### Nullable-ref struct field hooks (`t: T | null`) — the "almost-misfixed" latent gap (2026-07-10)



\*\*Symptom.\*\* A value `struct` with a \*\*nullable reference field\*\* (`t: Ref<T> | null` /

`t: Ptr<T> | null`) silently \*\*drops that field on every struct copy\*\* and \*\*never decrefs it

on destroy\*\*. First surfaced via `SpawnSlotEntry.innerType: Type | null` in `awaitLower.ms`

round-tripping through `HashMap<string, SpawnSlotEntry>`: `await h` on a stored spawn handle

emitted no `msUnboxDouble` (the `innerType` read back null) → `void\*` assigned to `double` →

compile error. Repro is backend-narrow (C + `--gc=drc`/`--gc=orc` only; JS + `--gc=none` copy

the struct whole, so they are fine).



\*\*The four wrong turns it invites — do NOT take them (each was entertained and disproven):\*\*

1\. ❌ \*"native-only memory UB / Heisenbug"\* — it is \*\*deterministic\*\*; a probe read the field

&#x20;  null while the source local was still alive (no free happened).

2\. ❌ \*"synthetic node lacks type info"\* — the fused path (`await spawn(...)`) unboxes correctly,

&#x20;  proving `nodeType`/`awaitedType` resolution is fine.

3\. ❌ \*"tagged-union payload lost"\* (tempting given recent union-codegen commits) — the C struct

&#x20;  is `struct Entry { double a; Ty\* t; }`; `t` is a \*\*plain pointer\*\*, not a tagged union.

4\. ❌ \*"make MS like Nim — collapse the `T | null` union into a plain nilable ref"\* — this would

&#x20;  \*\*delete non-nullable references\*\* (MS's TS-style null-safety). See below.



\*\*Why `T | null` is a union at all — it is TS-compat, verified, KEEP it.\*\* MS models nullability

the TypeScript way: a `Union` type with `null` (`TypeKind.Null`) as a member — 1:1 with TS

`T | null`. Nim has no such thing (every `ref` is intrinsically nilable), so Nim never hits a

"union arm" for a nullable ref. The union representation is \*load-bearing\*: it is exactly what

gives MS \*\*non-null `Ty` vs nullable `Ty | null`\*\* (a feature Nim lacks). `resolvePass.ms:291-326`

(verified): `T | null` where `T` is a \*\*value struct\*\* → wrapped in `Maybe<T>` (no in-band null

sentinel); `Ref<T> | null` / `Ptr<T> | null` → \*\*stays `Union(Ref/Ptr, Null)`\*\*, C-lowered to a

bare `T\*` + `MS\_NIL`. So the ref/ptr nullable \*\*reaches DRC as a raw `Union`\*\* — value-struct

nullable becomes a named `Maybe` and is handled elsewhere. That split is why only ref/ptr fields

are hit.



\*\*Root cause (real).\*\* `destructorLifting.ms` `fillBody` `TypeKind.Union` arm handles

string-like, named, and primitive-only unions but has \*\*no case for an anonymous nullable-ref

union\*\* → it emits nothing → the field is omitted from `Copy`/`Destroy`/`WasMoved`. Meanwhile

`classify.ms` (the Union arm, `unwrapRefNullUnion` → `RcKind.Ref`) \*\*does\*\* classify it as a

managed Ref. \*\*The two paths disagree\*\* — flag-propagation + `classify` mark the field managed

(so the struct gets hooks at all), but the hook \*body\* skips it. Ironic corollary: a struct that

is "managed but its hook drops a field" is \*\*worse\*\* than an unmanaged one (unmanaged → whole-struct

memcpy copies the pointer correctly).



\*\*Fix direction (Nim-verified, learn the BEHAVIOUR not the STRUCTURE).\*\* Nim's `fillBody`

`of tyRef` (liftdestructors.nim:981) → `atomicRefOp` (incref/decref, nil-safe). MS's own

`TypeKind.Ref` arm already does the equivalent (`refOp`). So the `TypeKind.Union` arm must, for a

nullable-ref inner, route to the \*\*same `refOp`\*\* — mirroring `classify.ms:239-246` exactly

(`unwrapRefNullUnion`; `Ptr`-inner or actor → `defaultOp` plain-copy/no-decref; else `refOp`). This

is "learn Nim's DRC behaviour (nullable ref ⇒ ref-op), keep MS's TS type-model (the union)".



\*\*The standing rule (paste when this returns).\*\* `fillBody`'s `TypeKind.Union` arm and

`classify.ms`'s `TypeKind.Union` arm \*\*must stay in lockstep\*\* — every union shape one treats as

managed, the other must emit hooks for. A nullable-ref field is a \*\*ref\*\* for DRC purposes (Nim

`tyRef` = MS `Ref<T> | null`), \*not\* a tagged union and \*not\* a reason to touch the type model.

Broader lesson (the transferable Nim insight): MS's TS-union representation for nullable-ref reaches

\*\*many `TypeKind.Union` dispatch sites\*\* (classify, fillBody, codegen…), each of which must remember

`unwrapRefNullUnion`; Nim structurally cannot forget because it has one `tyRef` arm. Audit the other

`TypeKind.Union` dispatch sites for the same omission; longer-term consider a single chokepoint.



\*\*Status: CLOSED (2026-07-10).\*\* `fillBody` `TypeKind.Union` arm now unwraps the nullable-ref union

(`unwrapRefNullUnion`) → `refOp` (incref/decref), mirroring `classify.ms:239-246`; `Ptr`/actor inner →

`defaultOp` (plain-copy bits, no decref). Guards: `fixedbugs/bug044` (nullable-ref struct field survives

HashMap \*\*and\*\* array round-trip, green drc+orc) + `paralockNested` (the spawn-await origin, 20k iter,

exit-0 drc+orc) + self-host binary builds clean under both drc and orc (no cross-module cascade / no

over-decref of borrow-typed `Ref<T>|null` fields).



\---



\## 3. DRC cleanup: where MS and Nim genuinely differ (the recurring-confusion zone)



\### ⛔ FINAL DECISION (committed 2026-06-04) — stop reopening this



The recurring question \*"do we need Nim's `nkStmtListExpr`?"\* keeps causing wavering because it

\*\*conflates two orthogonal questions\*\*. Separate them permanently. Both answers are grounded in

`\~/projects/nim/compiler/injectdestructors.nim` (read, not pattern-matched):



> \*\*The ONE sanctioned reopening condition (added 2026-07-15, from the DRC-unify work):\*\*

> hoisting is not order-neutral — a pre-hoisted `wasMoved` zero can reorder against

> same-statement earlier reads (§1 row "DRC scope cleanup", Trap 2). Three shapes of that

> class are closed by one invariant (`stmtBorrowReads`/`retroHoistStmtReads`: capture reads

> that remain inline; discard branch-lowered ones; save/restore across mid-statement

> lowering). \*\*If a fourth shape appears that this invariant cannot express, that is the

> signal to re-litigate Q1 here — reopen the stmt-expr decision rather than stacking a

> second re-sequencing mechanism.\*\*



\*\*Q1 — REPRESENTATION (the node `nkStmtListExpr`): NO. Final. Do not add it.\*\*

`ensureDestruction` (injectdestructors.nim:526-538) is `(let tmp = sink(arg); s.final.add destroy(tmp); tmp)`.

The \*\*substance\*\* is \*temp + scope-exit destroy\*; `nkStmtListExpr` is only the \*\*inline wrapper\*\* that

lets the temp sit mid-expression. MS's \*hoist-to-preceding-statement\* (`const $t = arg;` + register

scope-destroy) produces the \*\*identical temp, identical scope-destroy, identical sequence point\*\* for any

unconditionally-evaluated position, and lowers conditionally-evaluated positions to control flow exactly

as Nim does (`handleNestedTempl` at p():804 recurses if/case/while

branches carrying `mode`). ⚠ \*\*Citation corrected 2026-08-10, and it is not a footnote.\*\* `and`/`or`

are NOT lowered in `transf` — `transf.nim` never mentions `mAnd`/`mOr`; the lowering lives in cgen

(`genAndOr` ccgexprs.nim:1349, dispatched at :2857), i.e. the SAME pass that materialises the node

(`genStmtListExprImpl` :3219 dumps every child but the last into the CURRENT `cpsStmts`). That

co-location is the whole reason Nim never has to ask \*"is this position conditionally evaluated?"\*:

by the time a stmt-expr's prefix is emitted, `genAndOr` has already written the branch jump, so the

prefix lands inside the branch by construction. The transferable rule is about ORDER, not

representation — \*\*materialisation must come after conditional lowering.\*\* MS satisfies it today

because hoisting runs in the Phase-4 analyzer, after Phase-3 `callHoist`/`conditionalExprLower`; a

pass that materialised during CHECK would not, and that gap is a Q1 question, not a patch. All

three backends must flatten an inline stmt-expr regardless — C via GNU

`({…})`, JS via IIFE, Raiser (register VM) via instruction flattening — so the node adds \*\*zero codegen

benefit and relocates the hoist into 3 backends\*\*. MS already lowers every value-bearing construct this

way (`match`-expr `matchLower.ms:47-56` → `let $matchres; if-chain assigns it; use $matchres`; ternary;

`try`). \*\*The node is redundant, not impossible. Stop reopening it.\*\*



\*\*Addendum 2026-08-11 — the "materialised during CHECK" case is REAL, and it cost a placement bug.\*\*

The paragraph above names a hypothetical ("a pass that materialised during CHECK would not \[satisfy

the order rule]"). One such pass exists: the \*\*expression-position macro hoist\*\* (`SpliceMany`,

`unwrapSpliceManyAtExpr` in `checkExprPass.ms`). It cannot move to Phase 4 — the prefix DECLARES the

symbols the value element must resolve, so materialisation has to happen while checking. It therefore

carries two compensations for what the Phase-4 position gives the other hoists for free: (1) the

conditional-eval refusal (`ctx.condEvalDepth`, a loud diagnostic instead of correct placement — the

order rule cannot be satisfied at check time, so the cases it would break are rejected outright);

(2) an owner-bound insertion point, which was \*\*missing and is the bug fixed here\*\*.



`pendingHoisted` was a flat queue drained by "the nearest enclosing statement-list walk", where

\*nearest\* was resolved by WALK ORDER. Checking a macro's value element descends into any statement

list nested inside it — an arrow argument's body — before control returns to the list holding the

call site, so that nested list's `drainHoisted` took the prefix. The hoisted decl landed INSIDE the

value's own arrow: for a run-once `static` slot that means the slot initialises \*after\* the call that

reads it (empty/NULL at mount), i.e. silent wrong behaviour, not a build error. \*\*Neither the unit

guard nor the corpus could see it\*\* — both used a bare `Identifier` as the value element, which has

no nested statement list for the prefix to land in.



\*\*Verdict: DIVERGE-UNINTENTIONAL → SAME.\*\* Nim has no analog because `nkStmtListExpr` makes ownership

structural (`semexprs.nim:3481` `newTreeIT(nkStmtListExpr, …, hoistedParams, result)`) — with the

prefix inside the node there is no queue and no insertion point to get wrong. Since Q1 (above) keeps

that node out on purpose, the authority is MS's OWN hoist-to-preceding-statement mechanism, which

already had the property: `callHoist` / `resultDesugar` / `matchLower` splice through

`walkExpandBlocks`, where each statement list drives the expansion of \*\*its own\*\* list — no global

queue, nothing for a nested list to take. SpliceMany was the one hoist that did not.



\*\*Fix:\*\* ownership is fixed when the entry is QUEUED, not when it is taken. `pendingHoisted` becomes a

stack: each statement-list walk (`checkBlock`, `checkProgramBody`) takes a high-water mark on entry

and `drainHoisted(…, from)` splices only what was queued above it. A nested list entered while

checking the value sees an empty slice and cannot take the call site's prefix. No allocation per

block, no new mechanism — the same "correct by construction" property Nim gets from the node and

`walkExpandBlocks` gets from per-list splicing.



\*\*Isolation (one axis at a time, all four probes read from emitted C + run):\*\* block in the PREFIX

only → guard lands in the user function, PASS (the prefix is `callCheckStmt`'d \*before\* it is queued,

so it can never take itself); block in the VALUE only → guard lands in `dollarfn\_…(int32\_t w)`, the

wire arrow → crash. That pair is the trigger boundary. \*\*Gates:\*\* corpus `704-macroExprHoist` grew a

third site of the value-block shape, PROVEN RED pre-fix (`FAIL builds=2 wbuilds=1 notes=2 wired=W1` —

only the FIRST read is wrong, the signature of a slot filled one call too late) → 5 pass incl.

c↔orc↔js↔danger parity; suite \*\*3437/3437 on drc AND orc\*\*; Neon sweep 16/18 with the 2 reds

(`style`, `voidHost`) \*\*byte-identical pre/post\*\* (19 and 23 `msString` C errors either way — a

pre-existing string-equality lowering gap in `yoga/src/enums.ms`, unrelated); the motivating consumer

(neon `direct()` template hoist) went from 19.00 to \*\*3.016 host-ops/mount on BOTH the C and JS

lanes\*\*, matching the hand-hoisted cell exactly. Self-host emitted-C fixpoint \*\*0/294\*\* (gen-1 built

gen-2, gen-2 built gen-3, every emitted `.c` byte-identical between the two generations) and corpus

`704` still PASSes when run by the gen-3 binary, so the fix survives being compiled by itself.



\*\*Adjacent, MEASURED and deliberately NOT fixed:\*\* a macro at expression position inside an

EXPRESSION-bodied arrow (`() => memo()`) has no statement list of its own, so its prefix is owned by

the enclosing list. Probed (`p3ExprArrow`): the value is always correct — this is NOT the failure

mode above — but the prefix is EAGER. A module-level `const f = () => memo()` has already run its

initializer before `f` is ever called (`builds=1` with zero calls), and an arrow declared inside a

function keeps one module-scope slot across separate calls of that function (`twice()` returns

`T2/T2` twice, `builds` stays 2). For a run-once `static` slot that is harmless: same value, computed

earlier, one build per site even if the arrow never runs. It is nonetheless an UNGUARDED instance of

the invariant `condEvalDepth` exists to protect — an expression-bodied arrow is a may-not-execute

position, and no diagnostic fires — so a macro emitting a side-effecting non-`static` prefix there

would run it unconditionally. Extending the refusal to lambda bodies is NOT proposed here: a

BLOCK-bodied arrow (neon's `<For>`) owns its own statement list and keeps the prefix inside, so it is

unaffected, but whether any existing expression-bodied call site would be broken by such a refusal

was not surveyed.



\*\*Reason ranking for Q1 (re-litigate on the wrong reason = the waver returns):\*\*

1\. \*\*DECISIVE — multi-backend with no portable inline form.\*\* The node has no portable

&#x20;  statement-expression on JS (none — needs IIFE) or Raiser (register VM — none). Even Nim

&#x20;  itself does \*\*not\*\* keep it inline: its cgen flattens it (`ccgexprs.nim:3241 genStmtListExpr`

&#x20;  emits the leading stmts + materialises the last expr into a temp), and Nim avoids GNU `({…})`

&#x20;  for portable C. So \*everyone\* hoists — the only question is \*\*where\*\*: Nim hoists late, per-cgen;

&#x20;  MS hoists once, in the analyzer, and every backend downstream receives flat statements.

&#x20;  \*\*MetaScript is a committed multi-backend compiler (C/JS/Raiser today, more deliberately coming —

&#x20;  WASM, LLVM IR, Erlang, Move, BPF, embedded).\*\* The node would tax every \*new\* backend with its own

&#x20;  flatten pass; hoist-once compounds in our favour with each backend added. This reason alone settles it.

2\. \*\*SECONDARY — named-field-AST category-hybrid.\*\* A node that is both a statement-list and a

&#x20;  value-bearing expression fights the discriminated-union design (each variant has exactly its fields).

&#x20;  Real, but aesthetic; would not decide it alone.

3\. \*\*NOT decisive — TS-surface has no statement-expression.\*\* This only means the \*parser\* never

&#x20;  produces the node, i.e. it would be \*\*internal-only\*\* — which is perfectly addable (`HiddenDeref`/

&#x20;  `HiddenStdConv`/`HiddenAddr` are all parser-never-made internal nodes). \*\*Do NOT cite TS-compat as

&#x20;  the reason\*\* — if reason 1 were false, TS-compat alone would not stop us. It is a red herring for

&#x20;  this decision.



\*\*Q2 — TRAVERSAL (the algorithm `p(n, mode)` universal walk): YES. Follow Nim.\*\*

Nim's `p()` (injectdestructors.nim:803) recurses \*\*EVERY\*\* position carrying `mode`, and applies

`ensureDestruction` \*\*uniformly\*\* wherever a fresh owned value lands in a non-consumed position — including

call arguments: `nkObjConstr` in `normal` mode → `ensureDestruction` (line 889); call \*\*result\*\* in

`normal` mode → `ensureDestruction` (line 935-939); sink-param arg → `sinkArg` consume/move (line 918).

MS's `callHoist` was \*\*N handlers keyed by enclosing statement kind\*\* → enumeration → structurally

incomplete → \*\*call-argument was silently uncovered (the Photon WS broadcast leak, 2026-06-01)\*\*.

\*\*CLOSED 2026-06-05\*\*: the once-eval capture was consolidated into ONE call in `processNode` (Nim's

central `p()` shape), firing for all 5 fresh-owned producers (Call/Object/Array/New/Closure) — `callHoist`

now retains only the conditional-eval lowerings. See the Status block below.



\*\*Mantra (paste this when the question returns):\*\* \*Adopt Nim's algorithm (universal mode-recursion +

`ensureDestruction` everywhere); reject Nim's node (`nkStmtListExpr`). Materialisation = hoist-to-preceding-

statement — provably equivalent (same temp + same `s.final` destroy), backend-portable (C/JS/Raiser).\*



\*\*Addendum 2026-08-10 — macro-emitted statements at an expression position (`SpliceMany`). This did NOT

reopen Q1.\*\* A macro may return `NodeKind.SpliceMany` whose LAST element is the value replacing the call

site, the earlier ones statements to run first. That IS stmt-expr semantics, and it is admissible only

because the node is consumed DURING macro expansion in the checker (`unwrapSpliceManyAtExpr`,

checkExprPass): the prefix is checked in the CURRENT scope — the reference's own order, `semStmtList`

semstmts.nim:2941 sems children in order and types the list as its last child, which is why the value can

see what the prefix declares — and is then hoisted into the enclosing statement list by the drain in

`checkBlock`/`checkProgramBody`. Transform, analyzer and codegen never see a `SpliceMany` in an

expression, so the ban stands and no backend gained a flatten pass.



Two rules follow from materialising during CHECK instead of in cgen, and both are deliberate:

an EMPTY `SpliceMany` at an expression position is an error (no last element = no value), and a macro at a

conditionally-evaluated position (`\&\&`/`||` RHS, ternary arm, loop condition — `ctx.condEvalDepth`) is

REFUSED. Hoisting would lift the prefix out of the guard that decides whether it runs at all. The

reference never needs that refusal because it materialises in cgen, \*after\* `genAndOr` has emitted the

branch jump — the prefix lands inside the branch by construction. Refusing declines a position; it is not

a second re-sequencing mechanism, so the §3 warning above does not apply to it. Statement position is

unchanged (every element splices; empty is legal). Nim's `discardCheck` on non-last elements is

deliberately NOT ported — MetaScript follows TypeScript, where discarding a call's value is legal.

Guards: `fixedbugs/bug103`, `corpus/704-macroExprHoist` (RC-typed slot, parity across c/orc/danger/js).

\*\*If a macro is ever genuinely needed at a conditionally-evaluated position, THAT is the moment to

re-litigate Q1\*\* — the faithful fix is to keep the node until Phase-3 and flatten it next to `callHoist`,

once conditionals are already control flow. Never hoist out of the guard.



\*\*Corollary — the call-arg leak is NOT a representation gap.\*\* It is the missing universal-walk +

`ensureDestruction`-on-fresh-constructor-in-normal-arg (Nim line 889). It is closed by the \*\*walker\*\*,

\*\*never\*\* by the node. Adding `nkStmtListExpr` would not fix it.



\---



This is the area that keeps causing re-investigation. The full picture, grounded:



\*\*Nim's model.\*\* `p()` is a universal recursive processor in the analyzer

(`injectdestructors`). It walks EVERY position. Wherever a fresh owned value appears,

`ensureDestruction` wraps it in `nkStmtListExpr` — `(let tmp = expr; <register destroy in

s.final>; tmp)` — keeping the value \*\*inline\*\* while deferring the destroy to scope exit.

Because the temp stays inline, this works even mid-expression: inside a `\&\&`, inside a

loop condition, inside a call argument. One mechanism, all positions.



\*\*MS's model.\*\* MS has no `nkStmtListExpr` (named-field AST choice). Its equivalent is to

\*\*hoist the temp to a preceding statement\*\* — either in a Phase-3 transform

(`conditionalExprLower`, `resultDesugar`, `rvalueLower`, `callHoist`) or analyzer-side via

`addPre` (`processConditional`). The analyzer then sees a clean `const $t = call()` and

cleans it via the normal SINK-on-VariableDecl path.



\*\*Where this is EQUIVALENT to Nim (no node needed):\*\* any position evaluated \*\*once,

unconditionally\*\* — vardecl init, return, assignment RHS, plain call args, a \*simple\*

`if` condition. For these, hoisting `$t` to the preceding statement is functionally

identical to Nim's `nkStmtListExpr`. `processConditional` proves the analyzer already does

this. \*\*MS can follow Nim's strategy here without Nim's node.\*\*



\*\*Where a plain preceding hoist is wrong — and how MS handles it (option (a), shipped):\*\*

\- \*\*Short-circuit operands\*\* (`a \&\& f().ok`, `||`): `f()` must run \*only if `a`\*. A preceding

&#x20; hoist evaluates eagerly → breaks short-circuit. MS lowers to a \*\*flag + nested-if\*\*

&#x20; (`let $flag=false; if(a){const $t=f(); $flag=$t.ok;}` then test `$flag`) — exactly what

&#x20; Nim's `and`/`or` magic does (`if a: b else: false`). `lowerShortCircuit` in `callHoist.ms`.

\- \*\*Ternary branch\*\* (`c ? f().ok : g().ok`): each branch runs only on its path. MS lowers to

&#x20; a \*\*result temp + if/else\*\* (`let $r; if(c){const $t=f(); $r=$t.ok;} else {…}`), one scope

&#x20; per branch. `lowerTernary`.

\- \*\*Loop conditions\*\* (`while (f().ok)`): re-evaluate + destroy each iteration. MS lowers to

&#x20; \*\*while-true + break\*\* (`while(true){const $t=f(); if(!$t.ok) break; BODY}`); `continue`

&#x20; re-runs the top-of-body hoist. `expandWhile`.

\- \*\*`else if (f().ok)`\*\*: the else-if is the `.alternate`, never a statement-list entry, so

&#x20; it's wrapped in a block so the walker reaches it (cascades down the chain).



All of these are option (a) — \*\*lower-to-statement in Phase-3, no `nkStmtListExpr` needed\*\* —

and are SHIPPED + native-gated. Option (b) (a value-bearing stmt-expr node) was never needed.



\*\*Fresh-vs-borrow is NOT a wall (verified — an earlier assumption, now disproven).\*\* It was

once believed that capturing a "borrow accessor" return (`current(state)` → a pointer into

`state.tokens`) and destroying it would over-free. It does NOT: MS makes every RC return

\*\*owned for the caller at the return SITE\*\* — `needsReturnIncref` increfs Ref returns,

String/Array returns are deep-copied (passCopyToSink). So `const $t = current(state)`

receives a genuinely-owned value; destroying `$t` at scope exit is balanced and leaves the

container intact. Proven natively: capturing String/Ref borrow-accessor returns in a 3M-iter

loop stays flat (2 MB) with the source array intact. \*\*So position, not type, is the only real

constraint\*\* — the consolidated capture (`ensureDestructionIfNeeded` in `processNode`, §3 Status)

handles every owned type (String/Array/Ref/Closure/Function/Result); the only gate is POSITION

(Consumed/SinkArg own it upstream → skip; conditional-eval positions are lowered to control flow by

`callHoist` first). The historical note: an early all-owned-types `callHoist` self-hosted cleanly,

which is what disproved the fresh-vs-borrow wall.



\*\*Status — CLOSED ⛔ (2026-06-05).\*\* Both the once-eval capture and the per-producer coverage are

unified: `ensureDestructionIfNeeded` is called from ONE place — `processNode`, after its dispatch

`match`, in Normal mode — so every fresh-owned producer the mode-carrying walk reaches is captured.

The producer processors (`processCall`/`processObjectLiteral`/`processArrayLiteral`/`processNew`)

are dumb (process children, return the node); the capture decision lives in the dispatcher (Nim's

central `p()` shape). `callHoist.ms` retains ONLY the conditional-eval lowerings — short-circuit →

flag + nested-if, ternary → result temp + if/else, loop-cond → while-true + break, else-if →

block-wrap (Nim lowers `and`/`or` the same way in its frontend) — each with its permanent native

guard (leak-call-in-cond/loop-cond/short-circuit/elseif-cond/ternary-cond/vardecl-sc, all green

drc+orc, 278MB→2MB each).



\*\*The whack-a-mole that drove this (now closed).\*\* Before consolidation, `callHoist` was handlers

keyed by enclosing statement kind; a position no handler enumerated was silently uncovered. 2026-06-01:

a fresh object literal passed as a stored call argument leaked — the \*\*real Photon WS broadcast leak\*\*

(\~960 B/msg; `processFrame` → `decisionDeliver({kind, data, closeCode})`, 387MB @ 2M). Coverage

probing then found the SAME shape in 4 sibling producers — array literal, `new T()`, \*\*closures\*\*, and

the call-result itself — all stored as call args. All five are now captured uniformly by the

consolidated `processNode` walk + native-gated: leak-callarg-object, leak-callarg-escape (multi-alias

over-free discriminator), leak-arraylit-callarg (RC elements, over-free guard), leak-new-callarg,

leak-closure-callarg; paralock-nested guards the concurrency-closure over-free. The `(c ? f() : g()).ok`

residual is covered by the conditional-eval lowering; nested object literals are covered (outer

captured, inner sinks as a field).



\*\*Closure was the hard one (3-part fix, emit-C traced).\*\* A lifted closure-pair (an NF\_CLOSURE

ObjectLiteral) carried no `nodeType`, so the analyzer bailed on null → 247MB leak. Fix: (1)

`lambdaLifting` sets the closure-pair's `nodeType`; (2) `classify.ms` `Function → needsCleanup=true`

so it is captured + `msClosureDestroy`'d (`msClosureDestroy` is null-env-safe, so bare-fn pairs no-op);

(3) `processObjectLiteral` keeps NF\_CLOSURE pairs `isRefConstr` so the env field stays a COPY (incref)

— else `nodeType=Function` flips the env field to a borrow and the pair's destroy double-frees the env

against lambda-lifting's own env-var lifecycle (the over-free a naive 1-line classify flip causes;

caught by paralock-nested + leak-closure-callarg). A narrow compile-time \*\*fail-loud\*\* (`inject.ms`,

console — `checkerCtx.errors` does NOT print from Phase 4, the abandoned `errFailedMove` precedent

proves it) fires if an env-bearing closure-pair ever reaches DRC without a `nodeType`; verified to fire

on the simulated bug and 0× on a clean build (the \~800 benign null-type fresh producers per build are

void/synthetic calls + bare-fn pairs, so a blanket check would be cry-wolf noise — the loud check is

narrowed to the leak signature).



\*\*Materialization stays hoist-to-temp, not Nim's inline `nkStmtListExpr`\*\* (§1 ⛔): the named-field AST

\+ C/JS/Raiser all lacking a portable statement-expression make hoist-to-preceding-statement the

correct, backend-portable choice; same result as Nim's inline capture. The PARALOCK exclusions still

hold — awaitables/`Promise` (spawn/async/actor-CALL results, their own consume-once lifecycle) and

actor SEND/CALL message arguments (the mailbox takes ownership) are not captured here.



\*\*Array-literal of RC elements (`\[f(), g()]`, `\[s, s]`) — a runtime, not analyzer, fix.\*\* The

analyzer was already Nim-correct here: `processArrayLiteral` processes each element in SinkArg

mode → copies aliased occurrences, moves last-read ones → `\_mscc2\_\[i]` arrives independently

owned, assuming the array builder \*\*moves\*\* them in. But `runtime/core/array.c

msStringArrayFromArr` \*\*deep-copied\*\* every element (defensive against `\[s,s]`) → a redundant

2nd buffer + orphaned the analyzer's owned element → leak (177MB native tier). Fix: make

`msStringArrayFromArr` \*\*move\*\* (`arr.p->data\[i] = src\[i]`, drop the copy) — matching

`msGenericArrayPush` (ref/object arrays, which already moved and never leaked) and Nim's seq

sink. The anti-double-free rationale was obsolete (analyzer copies the aliased occurrence

upstream). Only caller is `nativeLower` (string\[]→FromArr) → all elements analyzer-prepared →

move safe. Guard: array-literal-strings, green drc+orc.



\*\*Bug-D warning.\*\* Do NOT "fix" this by re-driving the analyzer's capture from a binding-RHS

expression position in Normal mode. That violates the mode invariant: `ensureDestructionIfNeeded`

fires only in Normal mode, but a binding RHS must stay \*\*Consumed\*\* so the declared var

(moveOrCopy `MOC\_IS\_DECL` sink) is sole owner — driving it Normal creates two owners →

double-destroy. Verified to crash native self-host.



\---



\## 4. Recursive auto-destroy on owning self-ref chains (the CToken class of bug)



\*\*The problem class.\*\* A lifted destroy hook for a type with an \*\*owning self-referential

field\*\* (`interface Tok { next: Tok }`) recurses per node: `destroy(tok)` →

`decref(tok.next)` → rc hits 0 → `destroy(next)` → … Stack depth = \*\*chain length\*\*. A

linear chain of thousands (the cparse prelude token list) overflows the stack; a shallow

tree (the compiler's own AST `Node`/`children`) is fine. The compiler cannot statically

tell them apart — so this is a \*\*warning\*\*, never an error.



\*\*Reference landscape (read from source, 2026-06-10):\*\*

\- \*\*Nim\*\*: same recursion (no auto-iterate in `liftdestructors`). Mitigation = `{.cursor.}`

&#x20; on the back/aux links; note their own std/lists keeps `next` owning, so deep-list destroy

&#x20; still recurses in Nim — cursor alone is not the full fix.

\- \*\*Rust\*\*: same (`Drop` on `Box` chains overflows); idiomatic fix = manual iterative

&#x20; `Drop` or \*\*arena + indices\*\*.

\- \*\*Swift\*\*: `weak` (auto-nil) / `unowned` (checked trap) / `unowned(unsafe)` (raw).

\- \*\*Zig\*\*: no destructors — intrusive nodes, arena owns, free is a flat loop. The problem

&#x20; cannot exist by construction.

\- \*\*Universal naming rule\*\*: every major language reserves the "weak" family name for the

&#x20; \*\*checked/auto-null\*\* variant (Swift weak, Rust `Weak`, C# `WeakReference`, C++

&#x20; `weak\_ptr`, JS `WeakRef` — 5/5). Never name a raw non-owning marker "weak".



\*\*The MS answer (committed): owner + non-RC links, NOT auto-iterate.\*\*

The arena owns the nodes; the links are non-owning. Note that arena ownership ALONE does

not fix it — each node still holds rc on its successor via `next`, and the last strong

drop recurses the whole chain. The links themselves must be non-RC:



```ms

interface Tok {

&#x20;   value: string;

&#x20;   next: Ptr<Tok>;      // non-owning link — destroy hook skips it

}

// lexer context owns: tokens: Tok\[]  → destroy = flat loop over the array

```



`Ptr<T>` in field position works end-to-end (probe 2026-06-10: 200k-node chain,

`as Ptr<T>` cast from Ref, transparent member access, `null as unknown as Ptr<T>`,

destroy hook emits no traversal — flat RSS, no overflow). Applied to cparse

(`CToken.next`/`origin` → `Ptr<CToken>`, per-session token arenas in

`TokenizeResult.arena`/`PreprocessResult.arena`; nested `#include`/`##`-paste arenas

fold into the session arena).



\*\*Detection (Phase 2)\*\*: `resolvePass` warns on a direct owning self-ref field

(`field: T` inside `T`, interface + class), pointing at this pattern. Warning, not

error (tree-vs-list is a runtime property). Ptr-typed links stay silent.



\*\*The DRC boundary rule this pattern forced (`sinkClassify`, inject.ms).\*\* Every

ownership-materialization gate used to classify by the SOURCE expression type —

`Ptr ⇒ noRcInfo ⇒ no copy` — while owning destinations (Ref-element array destroy

`msRefArrayDestroy`, Ref returns, Ref fields) decref what they hold. A Ptr-sourced

value entering an owning slot therefore arrived as a raw borrow and was over-freed

(net −1 per pass-through; surfaced as heap corruption in cparse's `copyLine`

`return \[head.next, tok]` and `copyTokenList`'s `return sentinel.next`).

`sinkClassify` closes it: at sink/return materialization points only

(`passCopyToSink`, `processMember`/`processArrayAccess`/`processIdentifier` SinkArg,

`needsReturnIncref`), a `Ptr<T>` whose pointee classifies as a counted Ref

reclassifies as that pointee → copy (incref). A Ptr var is NEVER moved into an

owning slot — it holds a borrow, there is no rc share to transfer. Ptr to non-Ref

pointees (malloc/FFI memory, no rc header) is untouched. Verified: minimal-trigger

matrix (`#if`/function-macro/`defined()`) + full `future.h` through the standalone

cparse driver, clean under guard-malloc.



\*\*Gate caveat (hard-won):\*\* analyzer changes invalidate BOTH build caches — always

`rm -rf out \~/.metascript/cache/objects` before rebuilding, or stale objects mix old

and new RC conventions in one binary and produce both false-green and false-red.



\## 5. `Cursor<T>` — the non-owning link marker



Nim carries TWO separate things here and so do we, but the shapes differ:



| concept | Nim | MS |

|---|---|---|

| raw / untraced memory (FFI, `alloc`, hardware) | \*\*type\*\* `ptr T` (`manual.md:2034` "untraced references … are \*unsafe\*") | \*\*type\*\* `Ptr<T>` |

| non-owning link to a \*managed\* object | \*\*pragma\*\* `{.cursor.}` on a `ref`-typed field/var (`pragmas.nim:982` → `sfCursor`) | \*\*type\*\* `Cursor<T>` |



\*\*Why a type and not an annotation (Q1 divergence, deliberate).\*\* Nim hangs the flag on the

field's \*symbol\*; MS interface fields are parallel string arrays (`InterfaceDeclData.

interfaceFields` / `interfaceFieldTypes`) with no per-field node or symbol to carry a bit.

A type-position marker is the only encoding that covers `interface` and `class` alike. The

ALGORITHM follows Nim exactly (§3 Q2); only the carrier differs.



\*\*Semantics (identical to `{.cursor.}`):\*\* the slot does not participate in reference

counting — no incref on store, no decref of the old value, no destroy/trace recursion

through it. Access is transparent: `Cursor<T>` peels in `skipModifier` /

`peelToStructOrUnion`, so reads, member access, and passing to a `T` parameter need no

cast. Codegen emits the same C pointer as a plain `T` field.



\*\*It is NOT safer at runtime than `Ptr<T>`.\*\* Nim's own doc is blunt: \*"this is not C++'s

weak\_ptr … it is a raw pointer without runtime checks"\* (`destructors.md:645`). A cursor

can dangle. What it buys is (a) the type stays a reference so no implicit ref→ptr

conversion is needed anywhere, (b) intent is separable from FFI pointers, (c) a future

prover/inference has something to key on (`destructors.md:664`; MS already infers cursors

for locals in `src/analyzer/cursors.ms`).



\*\*Nil-ability (allowsNil, 2026-08-20).\*\* Bare `null` is a member of `Cursor<T>`'s value

set — end-of-chain IS a cursor state. Nim needs no rule here because `{.cursor.}` doesn't

change the type and refs are nilable (`allowsNil`, `sigmatch.nim:730`; `lists.nim` writes

`nil` into cursor fields with zero casts). MS refs are TS-strict non-nullable, so Cursor

gets an explicit pre-peel arm in `isAssignableInner` (compat.ms) — pre-peel because

`skipModifier` peels Cursor and would turn the question into `null→Ref` (= false). `Ptr`

and `Ref` stay TS-strict (`T | null` opt-in; pins at compat.ms "null rejected by bare

ptr"/"null still rejected by bare ref"). Regression: `fixedbugs/bug111CursorNullFit.ms`.

Same session closed the assignment door this exposed: BinaryExpr `"="` never consulted

the relation for a Null RHS (`h.p = null` on a plain ref field compiled silently), while

the object-literal path did — Nim has ONE door (`semAsgn` → `fitNode` → `typeRel`,

`semexprs.nim:2026`). Enforcement added scoped to Null RHS (no flow-narrowing dependency,

so row 80's TERMINAL scope stays closed). Measured on the tree: exactly 16 violations,

all "de-facto nullable slot declared bare" (`Node.nodeType/typeExpr/typeExprs/

paramLocations`, `ReturnStmtData.argument`, one codegen local) → those decls now carry

`| null`; the arg-path fallout (125 errors) was closed by widening 38 callee params that

already null-guarded their own first line, plus `!` at phase-invariant sites.



\*\*Shipped users (2026-08-20).\*\* The 11 compiler-internal link sites migrated off `Ptr<T>`:

`CToken.next`/`origin` (token/tokenize/preprocess ×7), `Scope.parent`,

`SymbolTable.current`, 2 `checkPass.ms` params (×4). Construction sites write bare

`next: null` — the `null as unknown as Ptr<T>` idiom is gone from these files. Emitted C

verified from the gate build cache: every `.next` store is a bare pointer assignment

(`(\*cur\_1\_).next = c\_1\_;`), grep for `msIncref`/`msDecref` touching `next` = empty.

The branch-join also learned Cursor: `isPointerKindJoinPair`/`joinedPointerMember`

(checkExprPass.ms) treat `{Ptr, Cursor}` as the non-owning class and keep the Ref side —

without it the committed ternary `tok.kind === Eof ? tok : tok.next` (preprocess.ms:130)

re-triggered the Ref|Ptr union-carrier class as Ref|Cursor

(`assigning to 'void \*' from incompatible type 'msUnion\_\*'`).



\### When to use which



\- \*\*`Cursor<T>`\*\* — a field or slot that points at another \*managed\* object it does not

&#x20; own: `next`/`prev` links, a parent back-pointer, a back-edge that would otherwise form

&#x20; an RC cycle. The owner must outlive the cursor (typically an arena/array holding every

&#x20; node). This is the tier for user-facing code.

\- \*\*`Ptr<T>`\*\* — memory MS does not manage: `Ptr<void>` from `cimport` (`void\*`), malloc'd

&#x20; buffers, `extern` handles, boxed closure returns, `$up` env. No rc header exists to skip,

&#x20; so `Cursor` would be meaningless.

\- \*\*Neither\*\* — the default. An owning `T` field is right unless the link closes a cycle or

&#x20; the chain is long enough for recursive destroy to overflow the stack (§4).



\### Where the algorithm lives



\- `destructorLifting.ms` `fillBody` — a `Cursor` field falls to `\_ => defaultOp(...)`, the

&#x20; 1:1 port of `liftdestructors.nim:166` (`sfCursor` ⇒ `defaultOp`, not `fillBody`): destroy

&#x20; and trace emit nothing, copy/sink emit a plain assignment.

\- `classify.ms` — `TypeKind.Ptr | TypeKind.Cursor => noRcInfo()`.

\- `inject.ms` — `sinkClassify` (a cursor entering an OWNING slot still increfs, same rule as

&#x20; `Ptr`), and the MemberExpr arm of assignment: `lhsIsNonOwning` suppresses the RHS-derived

&#x20; RcInfo fallback. That fallback is the load-bearing one — without it the slot silently goes

&#x20; back to owning; guard `cursorFieldBreaksCycle` pins it (proven red: `alloc=10000

&#x20; destroy=0`).



\## 6. How to verify any DRC/Nim-parity change



The old JS harness is GONE —

do not use it. The test infra is MetaScript itself, compiled and run by `msc`:



```

msc test src/index.ms            # unit/test-block tier

msc run src/test/corpus/run.ms   # corpus tier: builds every @maxrss program under

&#x20;                                # --gc=drc AND --gc=orc, asserts exit-0 (no over-free)

&#x20;                                # + peak-RSS cap (no leak) + stdout (correctness);

&#x20;                                # parity programs additionally byte-compare C vs JS.

MSCORPUS\_SAN=1 msc run src/test/corpus/run.ms   # same corpus under ASan + DRC ledger

&#x20;                                # Both runners test ./msc when present (MSC=<path> overrides).

```



DRC over-free / ORC faults only show on the \*\*native binary\*\* — gate every DRC-area change

with the native tier. Plus: build the native self-host compiler

(`msc build src/index.ms --gc=drc --danger --cc=clang`, likewise `--gc=orc`) and have it

compile real input — the 1st-generation native `msc` is the meaningful self-host gate.

Stale caches poison DRC verdicts (§4 caveat): `rm -rf out/debug/.cache` (and

`\~/.metascript/cache/objects`) before trusting a green OR a red.



\*\*2nd-gen self-compile DRC SEGV — FIXED 2026-06-26 (completion queue now owns the future).\*\*

gen-2 (the native `msc` recompiling the compiler) previously SIGSEGV'd on `--gc=drc` while

`--gc=orc` worked. Root cause (ASAN, slab-off): a \*\*future-callback use-after-free\*\* — the

MPSC completion queue (`dispatchFull.c msCompletionQueuePush`/`msCompletionQueueDrain`) held

a \*\*raw `replyFuture` pointer with no ref\*\*. A `spawn()`ed future can finish (worker sets

`finished` \*before\* pushing its completion msg) and be freed by its owner (the `for (const f

of futures) waitFor(f)` array, scope-exit) before the drain pops the msg — leaving a stale

pointer that `msFutureFireCallbacks` dereferences (the freed block reused by a codegen

`#line` string, `emitLineDir`). ORC survived it (cycle collector deferred the free past the

drain); DRC frees eagerly → UAF. \*\*Fix (root, not band-aid): the completion queue owns a ref

while a msg is in flight\*\* — `msIncRef(fut)` on push, `msFutureDrcDestroy(fut)` after fire.

Non-atomic incref is race-free here: array push/access are move/borrow (no concurrent rc

touch), and the MPSC push/pop barrier orders the worker incref before the dispatcher decref —

same shape as `msSpawn`'s existing env-incref. Verified: gen-2-drc builds clean ×4, `test-native`

94/0 (drc+orc, incl. paralock/await/actor/discarded-future). \*\*POSIX only — the Windows IOCP

path (`#ifdef \_WIN32`) has the same latent raw-pointer bug; mirror the incref/decref there

when a Windows native gate exists.\*\* When in doubt, use the \*\*twin MS/Nim emit-C comparison\*\* (write the same pattern

in both, emit C with `--passC="-O0"`, diff the hot loop) — it out-performs reading

`inject.ms` for any RC-accounting question.

| \*\*Hash mixing is unsigned arithmetic\*\* | Every mixing step in `lib/pure/hashes.nim` is `uint64` — `hashWangYi1` uses `'u64` constants and `hiXorLo(a, b: uint64): uint64` (with `hiXorLoFallback64` splitting into 32-bit halves), casting to the signed `Hash` only at the very end (:100-178). Unsigned wrap is defined behaviour, so no overflow pragma is needed anywhere. | `std/core/struct.ms hashNumber` and the C `msPtrHash` BOTH multiplied a 32-bit-masked value by Knuth's 2654435761 in \*\*signed int64\*\*. `(2^32-1) \* 2654435761 = 1.14e19` exceeds `INT64\_MAX` (9.22e18) → undefined behaviour. `msc test` defaults to \*\*zig cc\*\* (`cc.ms:141` auto-detect prefers it), whose debug UB checks trap it: `thread N panic: signed integer overflow`. In the C copy the operand came from an ASLR'd pointer, so it fired on \~1 run in 3 and read as a flaky test for weeks (neon `reconcile`/`reconcileHard`). Under `--danger`/release it would instead be SILENT UB. | was \*\*DIVERGE-UNINTENTIONAL → SAME\*\* | FIXED 2026-07-27: mix in `uint64`, cast at the end. Masked results are bit-identical for every input that did not trap. \*\*DRY:\*\* the C side no longer mixes at all — `msPtrHash` became `msPtrFold` (fold only) and `hash(this u: unknown)` routes through `hashNumber`, so exactly ONE Knuth site exists; having two is what let one be fixed while the other stayed wrong. Guard: inline tests in `std/core/struct.ms` pin the 32-bit boundary values AND assert `a.hash() === hashNumber(msPtrFold(a))` so a reintroduced second mixer drifts visibly — these run \*\*in the battery\*\* (163 files/3340). Bounded audit of the whole class (`masked value × multiplier ≥ 2^31`): djb2 `×33` and FNV-1a `×16777619` both stay under INT64\_MAX; the Knuth constant was the only one that overflowed. |

| \*\*`unknown` keys are BORROWED — containers keyed by them own nothing\*\* | `pointer` is the untraced top type; ARC/ORC emit no `=destroy`/`=copy` for it, so `Table\[pointer, V]` holds a raw address whose lifetime belongs to its creator. `options.nim:90-99` SomePointer splits exactly here. | `hash(this u: unknown)` (added so the render layer could key on reference identity) makes `Map<unknown, V>` usable, but the key is `void\*` and RC-inert per row 57, so \*\*the map does not keep the key alive\*\*. Measured: a key whose only owner left scope reads back as whatever reused the memory (probe: `v=7` before churn, `v=1000` after). Neon leans on this everywhere — `type HostNode = unknown`, and `reconcileArrays` builds a `Map<HostNode, number>` index. | \*\*DIVERGE-INTENTIONAL\*\* (consequence of row 57; Nim behaves identically for `pointer`) | Correct-by-design — host nodes are foreign handles owned by the platform tree, which is row 57's stated rationale ("may hold foreign handles"). But it is load-bearing and \*\*invisible in the type\*\*: nothing warns that a `Map<unknown,V>` cache outliving its keys silently dangles. Guard `src/test/guard/unknownKeyIsBorrowed.ms` pins the SAFE half (an independently-owned key survives storage + heavy churn; the map must never finalize a handle it does not own) and deliberately does NOT assert what a dropped key reads back as — that value is UB and pinning it would enshrine it. RED there means `unknown` stopped being RC-inert → re-trace row 57 before changing anything. |



\## JS backend name mangling (added 2026-07-30, /trace-nim session)



| Mechanism | Nim | MS | Verdict | Notes |

|---|---|---|---|---|

| \*\*JS emitted-name uniqueness in the flat bundle scope\*\* | `mangleName` (jsgen.nim:228-281): every symbol's JS name carries its identity — `\_<sym.id>` for data, `\_\_<uniqueModuleName>\_u<itemId.item>` for procs (mangleutils.nim:51-59); cached on `s.loc.snippet` at first touch, ALL references read the cache (`genSym` jsgen.nim:1660-1716) so decl/ref agree by construction; bare names ONLY for exportc/importjs/compilerproc (pre-seeded snippet, pragmas.nim:156-178); whole program = ONE flat scope, no IIFEs (`wholeCode` jsgen.nim:3176-3190) | was: NOTHING — `safeJsName(d.name)` bare everywhere, flat concat, silent last-wins on duplicate private helpers (repro /tmp/jsdup: JS a=2 b=2 vs C a=1 b=2). NOW: `jsSymbolName` (codegen/js/expressions.ms) reuses the C backend's `mangledFunctionName`/`mangledGlobalName` (names.ms — already the Nim-shaped `name\_\_module\_u<ovIdx>` scheme) for non-exported module-level Function + Global-flagged Variable syms; bare iff sym null / nativeName / `SymbolFlag.Exported` / `SymbolFlag.Imported` (new flag, stamped at importSymFromRegistry + createSymFromExport) | was \*\*DIVERGE-INCOMPLETE → SAME (stage A)\*\* | MS maps Nim's exportc class onto `export` (the @emit raw-text ABI calls exported std runtime names bare — must stay bare). Stage B residue: exported-name collisions across modules (Nim: exportc uniqueness = user responsibility; MS should add a checker diagnostic), enum-member flat constants, synthesized no-resolvedSym identifiers. Trap for porters: do NOT stamp `Exported` on imported syms — checkPass:1988 builds export registries from that flag → every import silently re-exported; that's why `Imported` is a separate flag. \*\*2026-08-09 addendum (the `(this)` SyntaxError):\*\* Nim's `reservedWords` gate inside `mangleName` (jsgen.nim:229-243) includes `"this"` — Nim can NEVER emit a reserved word as a binding. MS's `JS\_RESERVED` (`"$"+name`) deliberately EXCLUDES `"this"` because MS emits ES classes (Nim emits none) and class-method bodies need bare `this`; the method→function lifts (monomorphised generics, ctor `\_init`) inherited the exclusion and emitted `function f(this)` = load-time SyntaxError, killing every generic-using JS bundle. Resolution stays DIVERGE-INTENTIONAL on the class-emission axis, SAME on the invariant: receiver bindings emit `$this` via `gen.thisName` emit-context state (declarations.ms `emitFunctionDeclInner` + expressions.ms `emitIdentifier`) — context-sensitive because the method body NODE is shared between class emission and the lift (`methodToFunctionDecl` reuses `md.methodBody`), so a Nim-style symbol-cached rename at the lowering would corrupt the class path. Guard: js/basic "generic class method lift renames the receiver binding" (proven red). Same session closed a harness hole: test/helpers.ms `emitJSTwoPhase` never drained `drainPendingInstances()` — in-process JS bundles called mono decls that were never emitted (CLI's distribution block, compile.ms:778-799, now ported). |





\## Converter routine kind (design locked 2026-07-30 — not yet implemented)



| Mechanism | Nim | MS | Verdict | Notes |

|---|---|---|---|---|

| \*\*Implicit conversion at type boundaries (`converter`)\*\* | Distinct routine kind (`skConverter`); body is a RUNTIME proc; applied during sigmatch scoring (`convMatches` candidate comparison; converter list walked at sigmatch.nim:2297, arg wrapped via `implicitConv` sigmatch.nim:2179); applies only where the converter symbol is in scope; single application, no chains | `converter name(p: Node): Target` — same standalone routine kind, but the body runs in the MACRO ENGINE at compile time, the source type is restricted to compile-time-only (`Node`), and application happens ONLY at settled expected-type positions (return / resolved call arg / annotated decl) — never inside overload scoring | \*\*DIVERGE-INTENTIONAL\*\* | Mirror constraints, not preference: Nim's source domain is runtime values (body must run at runtime); MS's source domain is AST (exists only at compile time). Scoring exclusion is deliberate — macro expansion inside sigmatch would be reentrant (expand → check → match → expand). Safety invariant Nim lacks: an MS converter source cannot exist at runtime, so every applicable site is a compile ERROR today — a converter can only turn errors into code, never change the meaning of live code (the `converter toBool(x: int)` footgun is unrepresentable). Runtime-source converters deliberately unsupported. First user: JSX boundary lowering (LANG-JSX.md). Spec: LANG.md "Converter Declarations"; plan: JSX-ROADMAP Phase 9. Target matching follows Nim since 2026-08-09 (bug101): declaring module resolves the return annotation, the resolved Type rides the export/prelude pipeline, boundary falls back to a sameType walk when the display-name fast-path misses — dest-side identity mirrors `typeRel in {isEqual}` (userConvMatch, sigmatch.nim:2316). |





\## Closure args at call sites (2026-07-30, bug-B /trace-nim session — fix in /tmp/wt-fnrepr worktree)



| Mechanism | Nim | MS | Verdict | Notes |

|---|---|---|---|---|

| \*\*Relation-checking function-typed call args\*\* | `paramTypesMatch` checks EVERY arg; `typeRel of tyProc` (sigmatch.nim:791+) runs `procParamTypeRel` on every param AND the return with `minRel` — conversions never apply inside proc types, so `proc(): int` where `proc(): float` is expected = isNone, and lambdas (semInferredLambda) are typed FROM the formal then still relation-checked | was: arg loop SKIPPED any arg or param of kind Function (checkExprPass.ms:2992 carve-out for contextually-typed lambdas — swallowed every closure: fn-vs-string, fn-vs-fn wrong return, int32-vs-number repr all silent; the last one = silent ABI garbage since the C call site casts `.fn` to the DECLARED signature). NOW (staged): closure VALUES (identifier/call-result) checked via isFunctionAssignable + repr gate (`fnSlotReprMismatch`: nullable-union peel then fieldReprMismatch then capped isReinterpretUnsafe); literal lambdas + generic-containing formals still skipped | was \*\*DIVERGE-UNINTENTIONAL → SAME (staged)\*\* | Full parity (check lambdas post-inference too, drop the generic-formal skip) = own arc; the skip zone is exactly the ec38c20 false-positive family. Repr gate mirrors the sameElementRepr precedent (row 72's scoped class) — Function was the MISSED kind in that arc. ⚠ Trap: `findFirstGenericParamName` has NO cycle guard — calling it per-arg on macro-context types (`(n: Node) => Node`, Node cyclic) = silent stack-overflow SIGSEGV; use depth-capped `hasGenericParams`. ⚠ compileToCWithStd (test harness) leaves generic `() => T` returns unsubstituted — guards for the generic-source variant can't red/green through the harness (bug006-divergence family). Guard bug070 red-proof is TREE-toggle (checker-as-library). |

| \*\*Lambda return type: annotation must survive resolution\*\* | ONE path for lambdas and declared procs — `nkLambdaKinds → semProcAux` (`semexprs.nim:3525`) → `semParamList` (`semstmts.nim:2477`) → `semProcTypeNode` (`semtypes.nim:1560`). The return type is gated on the ANNOTATION EXISTING (`if n\[0].kind != nkEmpty: r = semTypeNode(...)`), never on what it resolved to; the closest analog to a top-typed annotation, `auto`/`tyAnything`, is explicitly KEPT (`copyType` + `tfRetType`, `semtypes.nim:1593`), not discarded. No annotation ⇒ `r` stays nil ⇒ void: Nim does NOT infer a lambda's return type from its body. | `checkAnonymousFunction` (`checker/checkExprPass.ms`) gated the annotation on `explicitReturnType.kind !== TypeKind.Unknown`, so an arrow/function-expression annotated `: unknown` (or an alias of it) had its RESOLVED, `UserUnknown`-stamped type thrown away and fell through to the flagless pending singleton `unknownType()`. Declared functions kept the stamp — so the same annotation meant different things depending on how the function was spelled. | was \*\*DIVERGE-INCOMPLETE → SAME\*\* (Nim's presence-gate; the `unknown` row 58's flag model) | \*\*Consequence was silent memory corruption, not a type error.\*\* `isPointerType` is flag-gated on `UserUnknown` (row 58 item 2, `codegen/c/types.ms:346`), so a flagless return type is "not a pointer" → `shimCallArg` (`codegen/c/expressions.ms:281`, `paramIsPtr \&\& !argIsPtr`) took `\&local` and passed `void\*\*` into a closure param declared `void\*` → every field read offset-shifted; crash or garbage depending on the callee's layout. Row 58's fix covered the DECLARATION path only; this is the lambda hole in the same arc, and a sibling of row 83 (also `checkAnonymousFunction`, also "the arrow path lacks what declarations have"). \*\*Fix = delete the kind test\*\* (`if (explicitReturnType !== null)`) — Nim's presence gate exactly; safe because the contextual "Source 2" assignment already guards `kind !== Unknown`, so a `kind === Unknown` explicitReturnType can only have come from a real annotation. \*\*The inferred-return site in the same function is MS-NATIVE with no Nim analog\*\* (Nim has no body-inference for lambdas) — there the guard becomes `inferredRet.kind !== TypeKind.Unknown \\|\\| isUserUnknown(inferredRet)`, which is still a \*presence\* test (real type vs the pending sentinel), authority = MS's own declaration path + TS (tsc keeps `: unknown` and infers `unknown` from a body that returns it). Guard `src/test/fixedbugs/bug076ClosureUnknownReturnRepr.ms` (6 cells: declared-fn control, explicit `unknown`, alias-of-unknown, inferred, function-expression, double-read) — \*\*PROVEN RED\*\* under a HEAD-matched pristine binary: 5/6 fail with a read-back field value of `2.65e-313` (the pointer bits reinterpreted as a double), control green. \*\*Assert on a read-back VALUE, never a length\*\* — the first version of this repro asserted `kids.length === 1`, which stays 1 even when the wrong pointer was pushed (a false green that cost a full isolation round). Gates: battery 3393/3393; `src/test/index.ms` red on exactly `bug006` + `lang/syntax.ms` = pristine differential; Neon sweep 17/17 incl. the tree-vs-direct emission differential this unblocked; DRC and ORC both reproduced pre-fix. |

| \*\*Implicit conversion is injected at EVERY fit position\*\* | `fitNode` (`sem.nim:99`) is the single funnel: `indexTypesMatch` → `paramTypesMatch` → `implicitConv` inserts `nkHiddenSubConv`/`nkHiddenStdConv` on the argument node itself (`sigmatch.nim`). Because var-init, assignment, return, ternary and every call argument all reach it, no position can silently skip a representation change — the conversion is a property of the FIT, not of the syntactic context. | `widenVariantToUnion` (checkExprPass.ms) built the `HiddenSubConv` correctly but had exactly ONE caller: the overload sig→impl reconcile loop (shipped with bug082, which only ever exercised that path). `fitNode` itself had no Union arm, and neither the direct-call argument loop nor `inferGenericReturn` wrapped — so a variant VALUE flowing into a union slot reached codegen unconverted at 5 of 6 positions. | was \*\*DIVERGE-INCOMPLETE → SAME\*\* | A union slot and a variant have different C layouts (tag + payload vs bare struct), so an unconverted variant is not a type error the backend can catch: `const s: Shape = c` / `return c` / `Result.ok(c)` emitted `assigning to 'Shape' from 'Circle \*'` (hard error), while a plain call argument passed the bare pointer with only a \*\*clang warning\*\* — a silent layout pun at runtime, the worst cell in the matrix. Structural DUs were therefore only usable through `match`, which lowers on its own path. FIXED 2026-08-09: the wrap now happens in `fitNode` (covering var init, assign, return, ternary, literal fields), in the direct-call argument loop beside the existing `needsStdConv` insertion, and in `inferGenericReturn` AFTER bindings settle — the last one is required because `Result.ok(x)` is not an ordinary generic call: `resultDesugar` rewrites it to an object literal in transform, so the only moment its argument can be fitted is while the checker infers the call. Guard against the nilable family at the chokepoint (`unwrapRefNullUnion(formal) !== null` ⇒ no wrap): `T \\| null` collapses to a bare pointer and takes no tag (row 90's lesson, learned there the hard way). Pins: `fixedbugs/bug099DuVariantUnionFit.ms` (6 positions, proven red = 14 C errors on the pre-fix binary) + `corpus/253-duVariantWiden` (parity incl. js). \*\*Residual, deliberately out of scope and fail-loud:\*\* a union whose variants share no LITERAL discriminator (`kind: string` instead of `kind: "circle"`) still fails — hooks are never lifted for it (`\_ShapeDestroy` undefined at link, the interim gap named in the ORC row) and a literal initializer refuses the slot because `variantIndexInUnion` compares field types exactly (`StringLiteral` ≠ `String`, "refuse rather than guess"). Both shapes failed to build before this fix too. |

| \*\*A deref is a LOCATION: ownership transfers out of it by copy\*\* | `p()` (`injectdestructors.nim`) groups the location expressions — `nkDerefExpr`/`nkHiddenDeref` alongside `nkDotExpr`, `nkBracketExpr`, `nkCheckedFieldExpr` — and in `sinkArg` mode routes them through `passCopyToSink`, never through `destructiveMoveVar`. Rationale is ownership, not syntax: the pointee belongs to whoever owns the cell, so a sink may take a COPY of the bytes but must not zero the source or claim the cell. | `moveOrCopy` already encoded the rule on the assignment side — `MemberExpr \\| ArrayAccess \\| HiddenDeref => genCopy` ("field/element access → always copy") — and `processMember`/`processArrayAccess` re-derived it on the expression side. `processHiddenWrapper` did NOT: it forwarded the incoming mode straight through the deref, so a `SinkArg`/`Consumed` context reached the pointer identity underneath and `destructiveMoveVar` moved the POINTER. | was \*\*DIVERGE-INCOMPLETE → SAME\*\* | Latent until something could sink a deref: the variant→union widen above created exactly that shape (the union stores the variant by value, so its operand is `HiddenDeref(ref)`). Result was `msPtrWasMoved(t)` followed by the scope's `msDecref(t)` — a decref of a pointer that had just been zeroed, i.e. a \*\*no-op\*\*, so every widened cell leaked: ledger `Tag alloc=25004 destroy=2` on a 25k-iteration corpus program. FIXED 2026-08-09: `processHiddenWrapper` gives `HiddenDeref` (NOT `HiddenAddr`, which stays transparent — it is an address-of for var/out params, no ownership question) the same treatment as its siblings: operand processed in `Normal` mode, then `passCopyToSink` when the context is `SinkArg`/`Consumed` and the pointee type needs cleanup. Emission goes from a pointer move to `TagCopy(\&$borrow, \&(\*t))` + blit into the slot, leaving the ref owned by its own scope. \*\*Methodology warning, the expensive part of this row:\*\* the leaking version passed the inline suite (3435 ×2 GC modes), the whole parity corpus (425), the guard tier, an ASan + slab-off run over the same 100k-allocation churn, AND printed correct output. macOS ships no LSan, so ASan is blind to leaks here — \*\*only the DRC ledger (`MSCORPUS\_SAN=1`) reported it\*\*. Any change that introduces a new value-copy path out of a heap ref must treat the SAN lane as a required gate, not a backstop. Gates after the fix: suite 3435 ×2, corpus 425/0/6, SAN 102/0/1, guards green, self-host fixpoint 0/293. |





\## `{.global.}` / `sfGlobal` — per-site storage class (2026-08-10, /trace-nim session — SHIPPED for `static const`/`static let`, `static var` rejected)



| Mechanism | Nim | MS | Verdict | Notes |

|---|---|---|---|---|

| \*\*`sfGlobal` — the flag itself\*\* | `sfGlobal` (`astdef.nim:48`, "symbol is at global scope") is set from TWO sources: automatically for any variable whose owner is a module (`semstmts.nim:1117/1131/1161/1175`, all four guarded `if getCurrOwner(c).kind == skModule`), and by hand via the `{.global.}` pragma on a variable declared INSIDE a proc. One flag, position-independent, read by every consumer. | `SymbolFlag.Global = 32` (`checker/symbol.ms:23`) — set for own-module top-level `VariableDecl` (`collectPass.ms`) and for imported Variable syms (`importSymFromRegistry`; both set-sites are listed in the comment at `codegen/c/names.ms:245-246`). Read by six consumers: `names.ms:247` (`isModuleGlobalVar` → `mangledGlobalName`, module-qualified C name), `lambdaLifting.ms:404/1094` + `lambdaLiftingDetect.ms:168` (globals are NOT captured into a closure env), `alias.ms:69` + `inject.ms:1494` (DRC skips globals), `checkPass.ms:1545`. | \*\*SAME\*\* for the module-level case; \*\*DIVERGE-INCOMPLETE\*\* for the proc-local case | `SymbolFlag.Global` \*\*IS\*\* `sfGlobal` — the correspondence was simply never written down, and the flag's own comment reads only "module-level variable", which describes the only way the flag is currently SET rather than what it MEANS. A 2026-08-10 session read that comment and concluded "MS has nothing carrying `{.global.}` semantics"; that is half wrong — the flag and all six consumers are already Nim-shaped, and the only missing piece is a way to STAMP it on a decl that is not lexically at module scope. Whoever extends this must reuse this flag, not add a second one. |

| \*\*`{.global.}` is a storage class, NOT an initialization discipline\*\* | `genSingleVar` (`ccgstmts.nim:365`): `if sfGlobal in v.flags` → `assignGlobalVar` puts the STORAGE at file scope. The INITIALIZER is a separate decision: `potentialValueInit` (`ccgstmts.nim:319-325`) emits a static C initializer only when `isDeepConstExpr(value)` \*\*and\*\* `p.withinLoop == 0` \*\*and\*\* `not containsGarbageCollectedRef(v.typ)`; otherwise the rope is empty and `ccgstmts.nim:462-467` runs `loadInto(targetProc, …)` — the assignment lands in the CURRENT PROC and therefore \*\*re-runs on every call\*\*. Run-once in Nim is `once` (`system.nim:2859`) = `var alreadyExecuted {.global.} = false` + an `if`: the guard is hand-composed ON TOP of the storage class, never implied by it. | n/a (not implemented) | \*\*Trap — measured, do not re-derive\*\* | Nim 2.2.2, `--gc:arc`, macOS arm64, proc called 3×: `var t {.global.} = createTmpl()` → \*\*builds=3\*\* (ids 1,2,3); `let t {.global.} = createTmpl()` → \*\*builds=3 as well\*\* (Nim's single-assignment spelling does NOT imply run-once); `once: cached = createTmpl()` → \*\*builds=1\*\*. Emitted C for the first: storage `t\_\_g\_u87;` at file scope with no initializer, assignment `t\_\_g\_u87 = T1\_;` INSIDE `component\_\_g\_u85()`. Consequence: \*\*porting `{.global.}` alone to obtain a per-site singleton does not work\*\* — any cache/memo/template object is a GC ref with a non-const initializer, so it takes the `loadInto` path by construction. |

| \*\*MS EXTENSION — `const` + global storage implies run-once\*\* | Nim's `const` is compile-time-only, so Nim has no spelling meaning "runtime single-assignment binding"; its nearest, `let`, is measured above re-running under `{.global.}`. Nim therefore requires `{.global.}` + `once` to be composed BY HAND (`system.nim:2859`). | MS has `const` = runtime single-assignment. Decision 2026-08-10: a proc-scope `const` carrying the global storage class initializes \*\*exactly once\*\*, while `let` with the same storage class keeps Nim's `{.global.}` semantics (storage moved, initializer per call). Equivalent to Nim's `{.global.}` + `once`, composed automatically for the `const` spelling only. | \*\*DIVERGE-INTENTIONAL (MS extension)\*\* | \*\*Reason:\*\* re-running the initializer of a binding spelled `const` contradicts what `const` asserts; Nim only escapes that contradiction because it has no runtime `const`. \*\*Purpose:\*\* give macros a per-site singleton WITHOUT reaching the Program node — a capability Nim's macro API also lacks (`lib/core/macros.nim`, 223 `proc`, \*\*zero\*\* case-insensitive matches for "global"), which is exactly why `{.global.}` exists there. Keeping the decl lexically at its site means the question "which module does the hoisted decl land in?" never arises. First consumer: Neon `direct()` lifting `createTemplate(builder)` out of the per-instance path (`neon/src/render/template.ms` builds one Template per `direct()` evaluation; benchmark cell C 19.00 → target \~3.02 ops/mount, i.e. parity with the build-once cell B). \*\*Implementation must take the lazy/guard shape, NOT an eager hoist into module init\*\* — a proc-local initializer may legally read params/locals, which do not exist at module-init time. \*\*Spelling LOCKED 2026-08-10:\*\* `static const` / `static let` / `static var` as a statement inside a function or method body — a modifier, not a pragma. Chosen over a `{.global.}`-style pragma because it is precisely C's static-local semantics (static storage duration, one initialization) and reads the same way to both C and TS eyes; inside a method BODY it cannot be confused with a static class member, which is declared in the class body. `SymbolFlag.Static = 1024` already means "static class member or static linkage" — the keyword is shared, the flag is NOT: this storage class stamps `SymbolFlag.Global` (row 1). \*\*Collision is a solved problem — copy Nim:\*\* two methods each declaring `static const x` must not share a C symbol, and Nim mangles by unique symbol ID rather than source name (`t\_\_g\_u87` = name + module + `u87`), so `mangledGlobalName` (`names.ms`) needs a symbol-ID suffix for the proc-local case; module-level globals keep the by-name form (one namespace, no ambiguity). \*\*Param-read LOCKED 2026-08-10 — fail-loud:\*\* a `static const` initializer that reads a parameter or an enclosing local is a \*\*checker error\*\*, not first-call-wins. First-call-wins would silently bind the singleton to whichever caller arrived first, which is unobservable at the call site and undebuggable in a macro-generated decl. Rejecting is also the reversible direction — it can be relaxed to first-call-wins later, never tightened once shipped. Costs the first consumer nothing: Neon's `builder` arrow is capture-free by construction (`direct.ms` splits the static skeleton from the capturing `wire`, Solid-style). |

| \*\*Scope cleanup must ROUTE a global's destroy, not queue it with the locals\*\* | `pVarTopLevel` (`injectdestructors.nim:570-582`) decides per DECLARATION which list a destroy joins: `sfCursor`/`sfThread` get none, `sfGlobal` goes to `c.graph.globalDestructors` (program exit), everything else to `s.final` (scope exit, drained by `processScope`). The global arm is a peer of the cursor arm, in the same `if`. | `registerVar` (`analyzer/scope.ms`) is the port and had the cursor arm (`isCursor` → registered but never cleaned) but \*\*not the global arm\*\*: every owned local went to `varsToCleanup` unconditionally, drained by `generateCleanup` (`inject.ms:1216`). MS read `SymbolFlag.Global` in exactly two places (`inject.ms:1494`, `alias.ms:69`) and \*\*both are about moves\*\* ("never move globals"), never about destruction. | was \*\*DIVERGE-INCOMPLETE → SAME\*\* (fixed 2026-08-10) | Latent until a declaration inside a function body could carry `Global` — `static` is the first construct that produces one, which is why row 50 could claim "SAME model" for years without being caught. Symptom on `--gc=drc` with an RC-typed slot: `s = MS\_NIL` re-zeroed per call, initializer detached from the decl (so the run-once guard could not be emitted at all), `msStringDecref(s)` at scope exit \*\*and\*\* in `\_\_finally` — i.e. the singleton was freed after the first call. An `int32` slot passed throughout (no cleanup needed), so \*\*the guard test must use an RC type or it proves nothing\*\* — the first version of `bug102` missed the bug for exactly this reason. Fix mirrors Nim's shape: decline to register when the symbol is `Global`. MS never destroys module globals at all (see the `nodeCache` survivor note — the reference does not destroy an imported module's globals either), so "do not register" IS the MS-consistent form of "route away from `s.final`". Verified: `once` returns the same value across 3 calls on drc, orc and js with one initializer run (`builds=3` for 1 once-call + 2 per-call), suite 3437 ×2 GC modes. |

| \*\*Lowered `var` decls lose their symbol\*\* | transf-introduced decls always reference a PSym; `{.global.}` is orthogonal to any hoisting. | `varHoist` (`transform/lowering/varHoist.ms`) rewrites `var x = init` into a hoisted `let x = null` built by NAME (`collectDeclNames` returns a `NameSet` of strings) plus a bare `makeAssign(makeIdent(name), init)` — neither carries `resolvedSym`, so `genVarDecl` falls to its "no resolvedSym" arm: raw C name, no type (`void\* n = MS\_NIL; (n = 0);` for `var n = 0`). | \*\*DIVERGE-INCOMPLETE — open, `static var` rejected meanwhile\*\* | Same class as row 62 (`lowerMatchExprInVar`), and `makeIdentResolved` (`transform/util.ms:142`) already exists as the fix vehicle. \*\*This is NOT the storage class's bug\*\*: plain `var n = 0` with no `static` emits the identical symbol-less shape today. It only became visible because reads of a `static` slot resolve through `mangledGlobalName` while the decl kept the raw name → `use of undeclared identifier`. `static var` is therefore a \*\*fail-loud checker error\*\* (`checkStaticStorageDecl`) pointing at `static let`. Fixing `var` properly needs one semantic decision first, which is why it was not bundled: `var x` declared in two sibling blocks yields two checker symbols but ONE hoisted decl, so attaching a symbol forces a choice that name-merging currently hides — precisely the last-wins name-map trap row 62 documents. Scope note: `var` has \*\*zero\*\* declarations in `src/`, `std/` and the test tree, so nothing in-tree exercises it. |



\## Implicit stringification (added 2026-08-10, /trace-nim session)



| Mechanism | Nim | MS | Verdict | Notes |

|---|---|---|---|---|

| \*\*Phase at which an implicit stringify call is inserted\*\* | Inserted during SEMANTIC ANALYSIS, so it is produced BY overload resolution and carries the winning symbol: `echo x` matches `varargs\[typed, $]` and sigmatch forwards the argument through the converter (`localConvMatch`, `sigmatch.nim:2596`; `implicitConv`, `:2179`). Nim has no backend pass that plants a call and leaves it to be bound later. | `stringConcatFlatten` (`transform/coercion/stringConcatFlatten.ms:164-172`, a POST-checker, C-only pass — `transform/index.ms:96`) planted a bare `x.toString()` MemberExpr. Its own comment claimed "builtinLower/extensionMethodLower resolve later", but both key off `NodeFlag.ExtCall`/`resolvedSym` set BY THE CHECKER, which this node never met: `extensionMethodLower.ms:23` returns immediately. C codegen printed the leftover as a struct member call → clang `no member named 'toString' in 'struct A'`. Primitives escaped (builtinLower binds them by TYPE) and hand-written `a.toString()` escaped (the checker bound it), so only compiler-INSERTED stringification of a user type was broken. On JS the pass never runs at all, so the operand reached the backend as a raw `+` and JS's own coercion answered — correct by luck for a class METHOD, silently `\[object Object]` for an extension-declared `toString`. | was \*\*DIVERGE-UNINTENTIONAL → SAME\*\* | Both passes carry a `// Follows reference \*.zig` header — they were ported from the pre-self-hosted Zig pipeline, where they were backend lowerings, and the position came along with them. No NIM-REF row ever justified the phase. FIXED 2026-08-10 (`350b644`): `synthStringify` (`checker/checkExprPass.ms`) plants the call at the `+`/`+=` site, next to the existing `wrapInConv` CString precedent, and CHECKS it — accepting only a trial that is diagnostic-free, string-returning, and bound to a symbol with a real `declNode` (the universal `.toString()` fallback mints a declaration-less symbol, which is exactly the shape that used to reach codegen). Anything else keeps the builtin path byte-for-byte. `stringConcatFlatten` needed no edit: a resolved operand is already a string leaf. Template literals ride the same `+` path; `+=` is covered by the same hook. Guard `src/test/guard/stringifyProtocolResolved.ms` (13 cells; proven RED = 13 clang errors pre-fix), corpus `714-stringifyProtocol` (C/JS parity). Gates: battery 3437/3437, guard suite ALL GREEN drc+orc, Neon 18/18, 12-cell C≡JS matrix. \*\*Deliberately NOT taken in this step:\*\* primitives still coerce in the post-checker pass. Nim-complete alignment (move them too, delete `coerceToString`) is a much larger blast radius with no bug attached — a separate arc. \*\*Adjacent holes this trace measured but did not touch:\*\* `String(x)` is the same planted-call shape in `typeCoercion.ms` and is ALSO C-only (on JS `String` is an undefined variable, even for `String(42)`); a type whose `toString` has the wrong shape, or none at all, still reaches clang or the JSON debug fallback (which prints `null` for populated fields); `extends` is independently broken on both backends. |

| \*\*Type of an argument a lowering synthesizes\*\* | The formal parameter's type is authority: `implicitConv`/`fitNode` build every inserted argument from `f` (the formal) — `sigmatch.nim:2179` — so representation and ownership of a planted argument are identical to a written one. No Nim pass invents a type for a node it hands to a callee. | `debugLower` (`transform/native/debugLower.ms`) lowers `console.log(structInstance)` to `stringify(jsonObject(keys, values))` and hand-built BOTH argument types, three of them wrong: (a) `values` as `createArray(createPtr(voidType()))` — a raw-pointer element array where the callee declares `JsonValue\[]` (`Ref<JsonValueData>`), so reference semantics were lost and `stringify` walked garbage → `panic: member access within misaligned address … JsonValueData` on EVERY named struct, at `std/serialize/json/stringify.ms:15`; (b) `keys` as a BARE `createArray(stringType())` where the callee declares `Ref<Array>`, so it was passed as `\&stackTemp` and destroyed twice (object destroy + scope cleanup); (c) the synthesized field `MemberExpr` carried NO nodeType, so C codegen emitted `.` for a `Ref` field → clang "member reference type 'Inner \*' is a pointer". | was \*\*DIVERGE-UNINTENTIONAL → SAME\*\* | FIXED 2026-08-10 (`7d81d66`, deployed v0.2.44): all three read their type from the `jsonObject` symbol the pass ALREADY resolves via `resolveDbgIdent` — no new mechanism, the pass simply stops guessing. Measured before: `console.log(new Bare(7))` panicked (misaligned address DIFFERENT each run = uninitialised read) and `${b}` printed `{"v":null}`; after: `Bare { v: 7, s: "hi" }` and `{"v":7,"s":"hi"}`, with the DRC ledger balanced (JsonValueData 22/22, per-class 6/6, 4/4, 1/1). Bisect note: the panic reproduces on every binary 0.2.33→0.2.43, and `c59795a^` (the commit that turned this line from `pendingType()` into `Ptr<void>`) is ALSO red — the sentinel sweep changed the SHAPE of the bug, not its origin; trees older than \~2026-07 cannot be built by a current `msc` (bootstrap wall), so the first bad commit was not pinned and the mechanism was proven by fix-and-measure instead. Guard `src/test/guard/debugDumpOwnership.ms` (proven RED = build failure pre-fix; GUARD-BALANCE on 4 types). \*\*Same root family as the "Implicit stringification" row above\*\* — a post-checker pass reinventing what the checker already knows. The structural cure for BOTH is to lower at check time (synthesize + `checkExpr`, the pattern the four protocols use), which would also delete the C-only `String(x)` pass and the 19 remaining hand-set `nodeType`s here; filed, not done. Known gap left: `console.log(\[1,2,3])` prints `<object>` (array dump needs a runtime element walk — a new mechanism, deliberately not invented), and the JS lane still dumps the MANGLED class name. |

| \*\*Which call gets the closure calling convention\*\* | `genAsgnCall` (`ccgcalls.nim:883-893`) tests the callee's TYPE first and unconditionally: `if ri\[0].typ.skipTypes({tyGenericInst, tyAlias, tySink, tyOwned}).callConv == ccClosure: genClosureCall(...)`. Only the LATER arms look at `ri\[0].kind == nkSym` (infix, named-param). One site, on the fully lowered tree, no syntactic gate — a named proc carries `ccNimCall`, a closure carries `ccClosure`, and the type is authority because sem guarantees it. | The decision was split across FOUR shape-gated sites: `checkExprPass.ms:2956` (callee `kind === Identifier`, gated on callConv), `closureCallMarker.ms` (`kind === MemberExpr`, then a second branch for `kind === ArrayAccess`, both gated on nodeType alone and force-stamping CcClosure), and `lambdaLifting.ms:1520` (callee `kind === ObjectLiteral`, for lifted IIFEs). Any callee shape without its own branch stayed `isDirectCall = true` and C codegen emitted `expr(args)` on an `msClosure` struct. | was \*\*DIVERGE-UNINTENTIONAL → SAME\*\* | Symptom: `make(1)(2)` — invoking a closure a call returned — failed with clang `called object type 'msClosure' is not a function or function pointer`, while `const b = make(1); b(2)` compiled. The checker sees the callee as a CallExpr (no branch); by the time the marker runs, `rvalueLower` has hoisted it to a temp Identifier, which the marker deliberately ignored ("checker owns Identifiers"). Neither pass owned the post-hoist node — the two halves of the decision look at DIFFERENT AST stages. Same hole for a ternary callee (`(c ? f : g)(y)` → `$tern`); the ArrayAccess branch was itself an earlier symptom-patch for the same gap, and its own comment already stated the Nim rule ("dispatch by callee TYPE, not syntactic shape") without implementing it. FIXED 2026-08-11: one predicate in the marker (which runs LAST in the native pipeline, the position matching `genAsgnCall`), the ArrayAccess + MemberExpr branches deleted, codegen untouched (it only ever read `isDirectCall`; `callConv` has \*\*zero\*\* readers in `codegen/c/`). \*\*The first cut shipped an interim oracle; the literal rule landed once the producer stopped lying.\*\* Porting `callConv == CcClosure` straight across BROKE the self-host, because `createIterator` (`checker/types.ms:345`) built the `next` field with `createFunction` (CcDefault) while `generatorLower` stored an actual closure into it — the type lied at the point of creation, and the deleted MemberExpr branch had been silently compensating by force-stamping CcClosure on the way past. An interim predicate ("does this callee NAME a function") stood in until that was traced. Root-caused and CLOSED 2026-08-12: `createIterator` now uses `createClosureType`, so the predicate is Nim's one-liner verbatim and the interim oracle is gone. \*\*Divergence CLOSED 2026-08-12\*\* (`0bc1e2f` checker, `b0c9557` transform): the predicate is `calleeFunctionType(callee).callConv === CcClosure` and nothing else; the MemberExpr and ArrayAccess branches are deleted. Three findings from the audit, each measured rather than reasoned. (1) \*\*`lambdaLifting`'s IIFE patch canNOT go\*\* — deleting it re-breaks `((s) => s+1)(4)` (C emits `(msClosure){...}(4)`), because the lifted ObjectLiteral closure-pair carries no callConv-bearing type; retiring it means making `tryLiftClosure` stamp the pair, a separate task. (2) \*\*Nim's `skipTypes({tyGenericInst, tyAlias, tySink, tyOwned})` is deliberately not ported\*\* — that set is empty here: aliases and generic instances are resolved before this pass and `copyTypeForSubst` carries callConv through substitution (probed green: generic identity, generic relay, interface field, array-of-alias), and `createSink(` has no call site at all. (3) \*\*One producer still lies and it is harmless\*\*: `asyncBridge.ms:454` typed `$stepper` CcDefault; it is only ever an ARGUMENT to `msAsyncStart`/`msFutureAddCallback`, never a callee. Flipped to `createClosureType` as hygiene in `26f3cb0` — emitted C for an async probe diffs \*\*0 lines\*\* before/after, confirming callConv is invisible to representation. Guards, all proven RED against pre-fix source: corpus `305-closureCallChain` (7 callee shapes incl. CallExpr, ternary, ArrayAccess, MemberExpr, relayed-through-param, env-less, loop churn — 9 clang errors pre-fix, 3 C lanes fail while JS passes), `fixedbugs/bug104` (same shapes in the test tier, 4 errors pre-fix), and `handoff/closureCall` (pins the emitted dispatch: `.fn)(` occurs 0 times pre-fix, where the emission is a raw `dollartmp\_1\_(2)`; note `.fn = ` alone proves nothing since CONSTRUCTING a closure emits it too). The handoff file replaced an `assert true` placeholder that had been counting as coverage since the bug017 era. Gates: suite 3440 ×2 GC modes, corpus 455/0/6, self-host fixpoint 0/294 emitted-C diff at clean HEAD. \*\*Methodology warning:\*\* the first control run compared two binaries that were BOTH broken (a parallel session's WIP in the shared tree produced the identical error set), which read as "pre-existing, not mine" — it was mine. Only a clean worktree at HEAD, patched with the single file, separated them. When a shared tree is dirty, a control built from that tree proves nothing. |

| \*\*Branch-type join — pointer-kind pair (`joinBranchTypes`)\*\* | `commonType` (sem.nim:138) is the branch-join relation ("array constructors, if expressions"); for `{tyRef, tyPtr}` with DIFFERING kinds it does `return x` — NEVER a union; the not-taken branch is left to later conversion/fitNode (which in Nim errors, since Nim has no ptr↔ref coercion) | `joinBranchTypes`/`canonicalizeBranchJoin` dedup treats a `Ref<T>`/`Ptr<T>` pair over the SAME pointee as ONE member via `isPointerKindJoinPair`, and keeps the OWNING member (`joinedPointerMember`: the `Ref`, whatever the branch order); `fitJoinedBranch` then coerces the other branch through the INTENTIONAL Ref↔Ptr cursor coercion (rows §4 cursor / container-assignability re-trace) | SAME (2026-08-14), ownership rule + pointee identity added 2026-08-15 | Pre-fix the join minted a tagged union for `cond ? tok : tok.next` over a `next: Ptr<CToken>` cursor field → `msUnion\_\*` returned as `Tok\*` / pushed into `CToken\[]` = hard C error (preprocess.ms `copyLine`, the shape that forced the if-form workaround). `sameType(Ref,Ptr)=false` is CORRECT (identity row) — the bug was the join lacking commonType's pointer-kind rule, NOT sameType recursion (initial suspicion disproven by JOINDBG instrumentation: members were `27:Ref(18:CToken)` vs `28:Ptr(27:Ref(18:CToken))`). Guard `src/test/guard/ptrRefBranchJoin.ms` proven RED on the pre-fix binary (msUnion C error); acceptance = copyLine ternary RESTORED (workaround deleted). Verified: combined-tree suite 3464/3464, self-host 296 clean, minimal repro green C+JS. \*\*AMENDED 2026-08-15 — "first branch wins" was a misread of `return x` and shipped a UAF.\*\* In Nim `return x` is not an accepted join: a mismatched `{tyRef, tyPtr}` pair yields a type the later fit REJECTS, so Nim never has to choose an owner. MS accepts the pair (the cursor coercion), so the join type is what the analyzer reads to decide ownership — picking the `Ptr` when it happens to be the first branch turns a freshly allocated sibling branch into a borrow: nothing owns it, scope exit destroys it, the return increfs freed memory. Measured on the pre-fix binary: `useBorrow ? borrowed : fresh(i)` = ASan heap-use-after-free WRITE in `msIncRef` (drc.h:226, rc=134) and wrong values (acc=2000000 vs 1001000); the same program with the branches SWAPPED is clean under both. Order was the entire signal, which is why the original guard (Ref-first, `tok.kind === 0 ? tok : tok.next`) stayed green. Two changes: `isPointerKindJoinPair` now also requires a Struct/Union pointee shared by both sides (`peelToStructOrUnion` + `sameType`; `Ptr<Tok>` is really `Ptr<Ref<Struct Tok>>`, so the peel is mandatory) — a mismatched pointee falls through to the union path and fails loud in C rather than silently retyping; and the dedup REPLACES a stored `Ptr` member with an incoming `Ref` instead of dropping it. Guard `src/test/guard/ptrFirstRefJoinOwnership.ms` proven RED (rc=1, both drc and orc) on the pre-fix binary, GREEN after. Note for guard authors: it signals through the \*\*exit code\*\*, not `throw` — an uncaught throw on the C backend exits 0 with no output, so the runner cannot see it. Gates: suite 3481/3481, guard suite ALL GREEN, corpus parity 494/0/6 xfail, corpus SAN 116/0/1 xfail, fixpoint gen2≡gen3 0/299 emitted .c. |

| \*\*Named primitive-union hooks (`type SN = int32 \\| string`)\*\* | case-object branches are lifted per BRANCH: `fillBodyObjT` (liftdestructors.nim:254) → `fillBodyObjTImpl` (:230) → `fillBodyObj` (:160), whose `nkRecCase` arm (:174) emits an `nkCaseStmt` on the discriminator and recurses into every branch; the `nkSym` arm then dispatches `fillBody(c, f.typ, …)` per field and a `tyString` payload takes the string op (:1032). A branch whose payload is a scalar/string is still a branch and still gets its op. (liftdestructors.nim read 2026-08-14; the earlier draft of this row asserted the parallel without reading it.) | classify.ms:296 names RC hooks for any named union with HasAsgn (`SNDestroy`/`SNCopy`/...), but destructorLifting refused to generate them: `typeNeedsHooks` probed each variant for FIELDS (a primitive variant has none) and `isTaggedUnion` required a variant peeling to Struct — both false for `int32 \\| string`, which codegen still emits as `struct SN { \_tag; union { int32 v0; msString v1; } }`. `scanForAnonStructTypes` also had no Union arm, so `ensureHooks("SN")` was never called at all (measured: 0 of 4145 ensureHooks entries). Only the ANONYMOUS form worked, via fillBody's inline `primitiveUnionOp`. | was \*\*DIVERGE-INCOMPLETE → SAME\*\* | FIXED 2026-08-14. Three edits, all `destructorLifting.ms`: (1) scan walk gains a Union arm gated exactly like classify (`typeName !== "" \&\& hasAsgnFlag`, minus `isAllStringLiteralUnion` (msString-backed, no `\_tag`) and minus `unwrapRefNullUnion` (pointer-collapsed)); (2) `typeNeedsHooks` Union arm admits `isPrimitiveOnlyUnion \&\& primitiveUnionStringIdx >= 0`; (3) `generateHook`'s Union branch routes primitive-only unions to the existing `primitiveUnionOp` instead of `generateUnionArms` — `buildVariantDispatch` requires `peelToStruct(variant)`, so a primitive union produced an EMPTY body (links, then leaks the msString). Emitted body verified: `if (self->\_tag == 1) msStringDecref(self->v1)`. Guard `src/test/guard/unionAliasPrimitiveHooks.ms`, PROVEN RED (`undefined symbol: \_SNDestroy`) on the pre-fix binary for all three shapes — local from a call, struct field, call argument — GREEN on C and JS. \*\*Micro-divergence accepted:\*\* `generateUnionArms` resets `\_tag = -1` after a `wasMoved` dispatch, the primitive path does not (parity with the pre-existing ANONYMOUS inline path it reuses). Safe because `msStringWasMoved` NULLs the slot and destroy is both tag-guarded and NULL-guarded; revisit if a primitive union ever carries a payload whose destroy is not NULL-guarded. \*\*Sibling hole left open (separate arc):\*\* an ANONYMOUS `int32 \\| string` LOCAL gets `noRcInfo` from classify (Union arm requires `typeName !== ""`), so its msString variant is never decref'd — links fine, leaks silently. |

| \*\*TryExpr catch join (`try f() catch v`)\*\* | `commonType` (sem.nim:138) gives an if/case/try expression the common type of its branches; a branch of a different type is reconciled there, not silently dropped. | `checkTryExpr` (checkExprPass.ms) type-checked `catchVal` and then THREW THE TYPE AWAY, always returning the Result's ok type. `try divide(1,0) catch null` typed as `int32`; the desugar's ternary (`resultDesugar.ms` `hoistTryExpr`) stamped the null branch with the value type, so the error path silently yielded \*\*0\*\*. | was \*\*DIVERGE-INCOMPLETE → SAME\*\*, \*\*SCOPED\*\* | FIXED 2026-08-14. Checker: `checkTryExpr` joins `\[okType, catchType]` through `joinBranchTypes` and re-fits the catch branch with `fitJoinedBranch`; never-typed catches (`catch panic()`) contribute nothing, so they keep `okType` by construction. Desugar: the ok branch of the synthesized ternary is wrapped with `makeTypedObjectLiteral(\["value","present"], …)` when the join is a Maybe carrier — the transform-side wrap already used by `operatorLower.ms:109`, since the checker's `synthMaybeWrap` cannot reach a `$result.value` node that does not exist until transform. \*\*SCOPE:\*\* the join is accepted only when it is a NULLABLE WIDENING of the ok type (`sameType`, `Maybe<okT>`, or `unwrapRefNullUnion === okT`); a genuinely different catch type (`catch "s"` on `Result<int32,\_>`) keeps today's loud C diagnostic instead of a half-lowered tagged union — turning a compile error into a miscompile would be the worse trade. The non-Result `try await … catch` path is untouched (its hoisted temp is typed by the await, not the join). Guard `src/test/guard/tryCatchJoin.ms`, PROVEN RED pre-fix on the value-type arm, GREEN on C and JS. |

| \*\*Type of an unresolved comptime identifier\*\* | The VM consumes a fully sem'd AST; a missing type is an internal error, never recoverable: `genVarSection` (vmgen.nim:1984) does `assert s.typ != nil` and assignment does `assert le.typ != nil`. Nim has NO name-based type inference anywhere — a value's type comes from the type system or the compile fails. | `refineTypes` (transform/typeRefine.ms), the comptime synthetic-Program refiner, ended its identifier lookup (resolvedSym → scope → registry) in `desperationHeuristic(name)`: the identifier's SPELLING mapped to a type — `elem`/`node`/`expr`/`stmt`/`left`/`right`/`arg`/`body`/`child`/`member`/`stmts`/`dec`/`tryExpr` → Node, `\*Type`/`\*type`/`ot`/`st` → Type, `\*Sym`/`sym`/`symbol` → Symbol, `tok`/`token` → Token. A comptime string local named `elem` used in an ASSIGNMENT (`out = out + elem`; single-assignment concat kept its type) became a Node; string-concat then lowered through `buildStructToString` → `wrapFieldAsJson` ⇄ `buildNestedJsonObject` recursing on the self-referential Node struct (`nodeTypeAst`) → compiler SIGSEGV, exit 139. The dangerous class is the spelling that DOESN'T crash: a wrong guessed type that lowers cleanly is a silent miscompile keyed to variable naming. | was \*\*DIVERGE-UNINTENTIONAL → SAME\*\* | FIXED 2026-08-14: `desperationHeuristic` deleted (function + sole call site, typeRefine.ms; -27 lines, no replacement — identifiers the 3-tier lookup misses stay null, which every consumer already handles). Load-bearing measurement first (probe = unconditional `return null`, suite on the probe binary): unit 3463/3463, comptime 355/355, corpus 479/0/6, gen-2 fixpoint green — ONE guard red, `macroChildIndexTraversal` (`Unknown host function: msNodeChildCount`), i.e. the heuristic propped up exactly one hole, the std/meta extern→CallHost route; that hole was closed independently by the concurrent hostTable/wire session the same day, after which the deletion is load-free (fresh probe: guard green, 3474/3474). Nim's assert model is NOT adopted at this layer: null types legitimately flow through this best-effort refiner (the all-green deletion proves it), so a hard error awaits a type-complete comptime pipeline — filed, not done. \*\*Sibling hardcode deleted in the same pass:\*\* `recoverKnownField` (same file) was the other half of the guessing — a hand-maintained mirror of the `Node`/`Symbol`/`Type`/`Token` field tables, consulted when `typeNames` was not populated. It keyed on the OBJECT's real type name rather than an identifier's spelling, so it was a milder class, but it had ALREADY drifted from `std/meta/node.ms`: `Node.flags`/`Symbol.symFlags`/`Type.typeFlags` answered `number` where the schema says `int32` (the f64-on-JS trap), `Symbol.overloads` answered `msRefArray` where the schema says `Symbol\[]`, and `Type.typeReturn`/`typeExtra` dropped the `| null`. Measured dead by the same probe method (unconditional early return): unit 3481/3481, comptime 355/355, corpus 494/0/6, the three macro guards green — identical to leaving it in. Deleted rather than corrected: a duplicated schema that no lane can distinguish from its own absence is a liability with no upside. Guard `src/test/guard/comptimeLocalNameNoHeuristic.ms` (macro locals named `elem`/`node`/`expr`/`fooType` through the assignment shape), PROVEN RED on the pre-fix binary (`msc.pre-swap-bak`, exit 139) and GREEN on the fix. Left open, independent hardening: `wrapFieldAsJson` ⇄ `buildNestedJsonObject` (transform/native/debugLower.ms) still have no cycle/depth guard, so ANY self-referential struct reaching struct-to-string recurses forever — reachable by design (std/meta warns on three such fields every build); a legitimately Node-typed macro local hitting string-concat reproduces the same SIGSEGV today. |

| \*\*Termination of a synthesized struct dump\*\* | Nim's `$`/`repr` for a cyclic graph is bounded by the RUNTIME walker, not by a compile-time expansion: `repr` (`system/repr.nim`) carries a `TAddrToName` visited set so a self-referential ref prints as a back-reference instead of recursing, and `mm:arc/orc` `=$`/trace hooks are generated ONCE per type with the recursive edge going through a POINTER, never through inlined structure. No Nim pass expands a type's fields into the AST, so "how deep do I inline" is a question Nim's design never asks. | `debugLower` expands the dump STRUCTURALLY at compile time: `console.log(x)` becomes `stringify(jsonObject(keys, vals))`, and `buildNestedJsonObject` emits one `wrapFieldAsJson` per field, which for a struct-typed field calls `buildNestedJsonObject` again (`transform/native/debugLower.ms`). The pair carried no visited set and no depth cap, so a type reachable from itself expanded forever: `class Chain { next: Chain }` killed the COMPILER with a stack overflow (exit 139, no diagnostic, no source location — the overflow destroys the frame chain, so lldb cannot unwind it and the macOS .ips report is the only readable evidence). | was \*\*DIVERGE-UNINTENTIONAL → SAME\*\* | \*\*Reachable by design, not by accident:\*\* `std/meta/node.ms` warns about three owning self-referential fields (`Node.nodeTypeAst`, `Node.typeExpr`, `FlowNode.antecedent`) on EVERY build — any macro local legitimately typed `Node` that meets string-concat reproduces it. Found 2026-08-14 as the crash MECHANISM behind the name-based comptime typing bug (row above): the wrong guessed type was `Node`, and it was this unbounded pair that turned a wrong type into a segfault. Deleting the heuristic removed one road in; this row closes the hole itself. FIXED 2026-08-14, \*\*SUPERSEDED 2026-08-15\*\* (that patch was a symptom fix — see the SUPERSEDED paragraph at the end of this cell): `wrapFieldAsJson`/`buildNestedJsonObject` threaded the type-name path currently being expanded (`structIsExpanding`/`withStructName`); a field whose struct type was already on that path lowered to `jsonNull`. Path-scoped, not global — sibling fields of the same type still expand, only a genuine cycle is cut. Depth cap of 16 rides along for the case a visited-set cannot answer (an ANONYMOUS struct has no type name); the cap alone would be wrong in the other direction, since a wide type would still expand exponentially before reaching it. Guard `src/test/guard/selfRefStructDebugDump.ms` — direct self-reference plus mutual `Ping ⇄ Pong` — \*\*PROVEN RED (exit 139) on the pre-fix binary\*\*, green on C and JS. Gates: unit 3474/3474, comptime 355/355, corpus 494 pass / 0 fail / 6 xfail, guard suite green, gen-2 self-build. \*\*Methodology note (cost 2 hours):\*\* the first control was run against a build of a COPY tree in which two unrelated in-flight files had been reverted to HEAD, and it "proved" the guard broke `msc test` — the same dirty-tree trap the closure-call row records. A true A/B (same copy tree, only `debugLower.ms` differing) showed BOTH binaries failing, i.e. the guard was innocent. \*\*Separate pre-existing hole found while writing the guard, NOT fixed here:\*\* dumping a reference-type field that is NULL dereferences it and dies at runtime (exit 255); reproducible with no cycle anywhere (`class Outer { inner: Inner }`, `inner` left null), identical on pre-fix binaries. `wrapFieldAsJson` needs a null test before the nested expansion, which is a codegen-shape change with its own blast radius. \*\*SUPERSEDED 2026-08-15 — the 2026-08-14 patch was wrong and is deleted.\*\* Path-scoped cutting cannot tell a cycle from ordinary depth: a plain three-node chain `a→b→c` printed `Chain { label: "a", next: null }`, because `Chain` was already on the expansion path at the second field. The guard passed while the compiler lied about the data — strictly worse than the exit-139 it replaced (a loud crash traded for a silent wrong answer, the exact trade this document exists to prevent). Root cause of the whole family: the dump was expanded STRUCTURALLY in the AST, so "how deep" had to be answered at compile time. Nim never answers it — `repr\_v2.nim:138` is ONE generic `repr\[T: tuple\\|object]` per type (`isNamed` only changes formatting, so named and anonymous share the path) and `repr\_v2.nim:152-154` opens the ref overload with `if isNil(x): return "nil"`; the recursive edge is a CALL, so depth follows the DATA at runtime. Adopted verbatim: `ensureDumpFn`/`callDumpFn` (`transform/native/debugLower.ms`) emit one `<Type>\_msDbgJson` per canonical type, memoized by name, nil-checked in the first statement, with struct-typed fields lowering to a call instead of an inlined expansion; `lowerBuiltins` (`builtinLower.ms`) appends the collected `FunctionDecl`s to `programStmts` after the walk. `structIsExpanding`/`withStructName`/`debugJsonMaxDepth` are deleted — no visited set, no depth cap, nothing to tune. The null-deref hole recorded above closes for free: the nil-check IS the base case, so `Outer { inner: null }` prints `{"tag":"t","inner":null}` instead of exiting 255. TRAP en route (cost one build cycle): the generated function was given `SymbolFlag.GeneratedOp` by analogy with `destructorLifting`'s hooks, but to `codegen/c/declarations.ms:177` that flag means "DRC lifecycle hook", which SKIPS the `ProcHeaders` prototype and delegates to `ensureDrcProto` — which only knows real hooks. The body was emitted with no declaration, so any type whose dump calls ANOTHER type's dump failed the C compile (`call to undeclared function 'Outer\_msDbgJson'`); pure self-recursion survived, which is why the first repro looked green. The flag's other consumer (`analyzer/inject.ms:1606`) is unreachable here regardless: `lowerNativeAccess` runs on the already-analyzed program. Guard `selfRefStructDebugDump.ms` rewritten to assert DEPTH rather than mere termination (`a→b→c` must print all three labels, `Ping ⇄ Pong` must print the far side, a null field must print `null`) — \*\*PROVEN RED on a compiler carrying every other change but this one\*\*: `GUARD RED: chain dump truncated before depth 2: {"label":"a","next":null}`, exit 1. Gates: unit 3447/3481 with the failing set BYTE-IDENTICAL to a control build of the same tree with only these two files reverted (the 34 failures belong to concurrent in-flight work), comptime 354/355 (same single pre-existing failure on the control), corpus 499 pass / 0 fail / 6 xfail, guard suite ALL GREEN under drc AND orc, gen-2 self-build green and smoke-tested. |

| \*\*Unhandled exception at program exit\*\* | `nimTestErrorFlag` (`system/excpt.nim:481`, goto-exceptions mode) is emitted by cgen at the end of the generated main body (`cgen.nim:2200-2201`: `prcBody.addCallStmt(cgsymValue(m, "nimTestErrorFlag"))`). Its body is `if nimInErrorMode and currException != nil: reportUnhandledError(currException); currException = nil; rawQuit(1)`, and its doc comment states the contract — it must run before `currException` is destroyed, and at the end of EVERY thread, "to ensure no error is swallowed". | `msThrow` (`runtime/core/system.c:61`) sets `msCurrException` + `msErr` and returns — the same error-flag propagation model — but nothing ever tested the flag at the top. An uncaught throw unwound out of `main` and the process exited \*\*0 with an empty stderr\*\*: `function main(): void { console.log("before"); throw "BOOM"; }` printed `before` and reported success. | was \*\*DIVERGE-UNINTENTIONAL → SAME\*\* | Found 2026-08-15 while strengthening the struct-dump guard in the row above. The blast radius is why it matters: `throw "GUARD RED: …"` is the assertion idiom of the nim-guard suite and `run.sh` grades a probe on its EXIT CODE, so \*\*24 of 54 guards had `throw` as their only red signal and not one of them could fail\*\* — the safety net was inert, and any CI reading exit codes inherited the same blindness. FIXED 2026-08-15: `msTestErrorFlag` (`runtime/core/system.c`) prints `Error: unhandled exception: <msg>` to stderr and `exit(1)`; `genProjectDispatcher` (`codegen/c/index.ms`) calls it inside `MsMain` between `MsMainInner()` and `msOrcCollect()`, matching Nim's placement at the end of the main body. Two details are load-bearing: (1) the message must be read through `msError\*`, NOT the declared `msException\*` — every writer of `msCurrException` stores an `msError\*` (`msMakeError`, `msFutureRaiseFrom`, `abort.h`) and the two structs have different layouts, so the declared type yields garbage; (2) the dispatcher included `runtime/core/system.h` only for async mains, so the call was an implicit declaration — made unconditional, which is a no-op under `--os=bare`/`solana` because `manual.h` is force-included (`compile.ms:405-409`) and shares system.h's `SYSTEM\_H` guard. Bare gets `static inline void msTestErrorFlag(void) { if (msErr) \_\_builtin\_trap(); }` — bare's `msThrow` discards the message, so there is nothing to print. Verified: uncaught → exit 1 with the message; caught `try/catch` → unchanged exit 0; guard suite 54/54 under drc AND orc, i.e. re-arming 24 inert guards surfaced no hidden regression; corpus 499/0/6, i.e. no program was silently finishing with a pending error; unit failing set byte-identical to the control; gen-2 self-build green and itself exits 1 on an uncaught throw. NOT done: no stack trace (Nim's `reportUnhandledErrorAux` prints one when `hasSomeStackTrace`), no exception type name in the message (MS has a single `Error` shape today), and non-main threads are unguarded — Nim's contract requires the call at the end of every thread. |



\## JS integer arithmetic and conversions (2026-08-15, /trace-nim session — MEASURED; conversions shipped, arithmetic not)



Full measurement matrix, emission tables, benchmark method and the phase plan live in

\[JS-NUMERIC.md](JS-NUMERIC.md). This section records only the MS↔Nim relation. Every claim

below was produced by compiling and running both compilers (Nim 2.2.2, Node v24.1.0,

macOS arm64), never by reading a pass.



| Mechanism | Nim | MS | Verdict | Notes |

|---|---|---|---|---|

| \*\*Operator surface: which spelling means integer division\*\* | TWO operators. `div`/`mod` are procs carrying magic `DivI`/`ModI`, declared once per width (`arithmetics.nim:96-125`); `/` on two ints returns \*\*float\*\* (`proc \\`/\\`\*(x, y: int): float`, `system.nim:1338`); `/=` is declared for `float64` and `\[T: float\\|float32]` only (`arithmetics.nim:342/346`) — \*\*integers have no `/=` at all\*\*. The author picks the semantics at the keyboard, overload resolution binds the magic, and codegen receives an already-disambiguated operation. | ONE operator. `/` means integer division when both operands are integer-typed, float division otherwise; the decision is made by `inferBinaryOp` (`checkExprPass.ms:2008`), whose `"\*" \\| "/" \\| "%" \\| "\*\*"` arm returns `widenIntegers(l, r)` for two integers. `/=` exists for every numeric type. | \*\*DIVERGE-INTENTIONAL\*\* (forced by the TS-compatible surface) | This row is the ROOT of every other row in this section, so do not "fix" it. MS took TypeScript's surface (`7 / 2` is spelled the same for ints and floats) with C's semantics (it \*means\* truncating division for ints). Nim never needs type-directed integer emission on JS because the operator already says which one it is; TypeScript never needs it because there is only one meaning. MS merged the two, so \*\*every integer arithmetic site on the JS backend must be emitted from static type information\*\* — a permanent, deliberate cost of the language design, not an implementation shortfall. Corollary: `/=` on integers has NO Nim analog to copy; MS is on its own there (measured scope: 5 occurrences across `src/` + `std/`, every one a bare identifier on the left). \*\*Resolved 2026-08-19\*\*: a left side that can be re-read (identifier, field chain, index over identifiers/literals, any of those behind `HiddenDeref`/`HiddenAddr`) is rewritten; anything else is a compile error naming the position, because emitting the raw compound form would silently disagree with C. Nim reaches the same place from the other side — it simply has no integer `/=` to get wrong. |

| \*\*Integer division emission on JS\*\* | `arithAux` (`jsgen.nim:626-692`). Non-BigInt path: overflow-checks ON → `divInt($1,$2)`, OFF → `Math.trunc($1 / $2)`; `mModI` likewise. `divInt` is a real emitted JS function (`jssys.nim:473`) whose body is `if (b == 0) raiseDivByZero(); if (b == -1 \&\& a == 2147483647) raiseOverflow(); return Math.trunc(a / b);` — \*\*the checked path also ends in `Math.trunc`\*\*, so there is no bare-`/` option anywhere on the Number path. Conversion layer then adds its own narrowing. Measured emission, `-d:danger`: `int8/int16/int32` → `Math.trunc(a/b) \\| 0`; `uint8` → `(a/b) \& 0xff`; `uint32` → `(a/b) >>> 0`; `int64` → `a / b` (BigInt — `optJsBigInt64` is in `DefaultGlobalOptions`, and int64 locals really do emit as `7n`); `uint64` → `BigInt.asUintN(64, a / b)`. | Emitted a bare `/`. Measured before the fix: `int32 7 / 2` = \*\*`3.5`\*\* on JS vs `3` on C; `-7 / 2` = `-3.5` vs `-3`; `uint32 7 / 2` = `3.5` vs `3`. \*\*SHIPPED 2026-08-15\*\* as `lowerIntArithJS` (`src/transform/coercion/intArithJS.ms`); gate `016-jsIntegerModel.ms` went 13 ok/6 BAD → 18 ok/1 BAD, C unchanged 19/19, the remainder being unsigned wrap. | \*\*DIVERGE-INTENTIONAL\*\* (one truncating operation where Nim emits two) | Planned MS emission collapses Nim's two operations into one: `(a / b) \\| 0` for signed ≤32, because `x\\|0` and `Math.trunc(x)\\|0` are both ToInt32 and therefore identical. Nim needs two only because the `Math.trunc` arrives from the magic layer and the `\\| 0` from the conversion layer, independently and unaware of each other. `Math.trunc` is still required for `int64` in Number mode (`\\| 0` would destroy the range) and for the BigInt rows. \*\*Performance is not a consideration here and should not be re-litigated:\*\* measured over 15 interleaved rounds (MIN), `Math.trunc`, `\\| 0`, `\~\~`, `>>> 0` and \*a guarded helper call\* all land within 4% of each other, while the untruncated `a / b` is \*\*1.49x slower\*\* — it accumulates doubles. Truncating correctly is the fast path. |

| \*\*`Math.trunc` on `%`\*\* | `mModI` wraps it: `Math.trunc($1 % $2)` (`jsgen.nim:692`). | Plan: emit nothing. | \*\*DIVERGE-INTENTIONAL\*\* | Measured: `int32 7 % 2` = `1` and `-7 % 2` = `-1`, identical on C and JS \*\*today\*\*, because `%` of two integer-valued Numbers is already integral — Nim's wrap is a no-op on this path. \*\*The condition was met 2026-08-15\*\*: float→int conversion now truncates at the boundary (row below), so an integer-typed slot really holds an integer and `%` is correct by construction rather than by luck. Emitting nothing is now a decision, and `src/test/js/intArith.ms` asserts the absence — without that test this row would silently become drift the first time someone "fixed" `%` by copying Nim. |

| \*\*int32 multiplication wrap\*\* | `(a \* b) \\| 0` under `-d:danger` (verified via the additive form, `int8 100 + 100` → `(a+b) \\| 0` → `200`). | Plan: `Math.imul(a, b)`. | \*\*DIVERGE-INTENTIONAL — MS stricter than Nim\*\* | The product of two int32 values can exceed 2^53, so the double is already wrong before `\\| 0` observes it; Nim accepts that loss in its unchecked mode. `Math.imul` is an exact 32-bit multiply and needs no helper. This is one of the few places where following Nim would be \*less\* correct than the C backend MS must match. \*\*Not measured: `Math.imul` performance\*\* — assumed cheap, untested. |

| \*\*float → unsigned conversion — a REFERENCE BUG, do not port\*\* | `genConv` (`jsgen.nim:2612`) gates the unsigned trimmer on the SOURCE being an integer: `if toUint and (fromInt or fromUint): r.res = "($1 $2)" % \[r.res, trimmer]`. A float source fails that test and then misses every subsequent arm, landing in `else: discard`, whose own comment reads `# TODO: What types must we handle here?`. Measured consequence: `uint8(3.9)` emits \*\*no conversion at all\*\*, and the unsigned `$` helper then evaluates `BigInt(3.9)` → `RangeError: The number 3.9 cannot be converted to a BigInt because it is not an integer`. The same program on Nim's own C backend prints `3`. | Plan: the mask alone — `(f) \& 0xff`, `(f) \& 0xffff`, `(f) >>> 0`. | \*\*DIVERGE-INTENTIONAL (fixing a reference defect)\*\* | Measured in Node: `3.9 \& 0xff` = `3`, `3.9 >>> 0` = `3` — `\&` and `>>>` perform ToInt32/ToUint32 first, so they truncate a float on their own. The correct repair of `genConv` is therefore to \*\*delete the `(fromInt or fromUint)` gate\*\*, not to add a `Math.trunc` in front; MS should emit ONE operation, not two. `Math.trunc` remains \*\*mandatory\*\* on the three BigInt-target rows (`BigInt(3.9)` throws; `BigInt(Math.trunc(3.9))` = `3n`). This is the one place in this section where copying the reference verbatim would import a live runtime crash. |

| \*\*Where a conversion is attached\*\* | `fitNode` (`sem.nim:99`) is the single funnel — `implicitConv` inserts `nkHiddenStdConv` on the argument node at EVERY fit position, so var-init, assignment, return, ternary and call arguments are all covered by construction; `genConv` merely spells the node. | `as` is a \*\*no-op on the JS backend\*\*, and the checker additionally accepts four implicit float→int paths. All five measured, C vs JS: explicit `f as int32` `3` / \*\*`3.9`\*\*; declaration `const x: int32 = f` `3` / \*\*`3.9`\*\*; parameter `3` / \*\*`3.9`\*\*; return `3` / \*\*`3.9`\*\*; assignment `3` / \*\*`3.9`\*\*. Every target width behaves alike (`3.9 as int8\\|int16\\|int32\\|int64\\|uint8\\|uint32` → `3` on C, `3.9` on JS). | was \*\*DIVERGE-INCOMPLETE → SAME\*\* (placement diverges deliberately, see below) | Highest-damage item in the whole matrix: the static type says integer and the runtime value is a fraction, which then contaminates everything downstream — including making the `%` row above conditional. \*\*Corrected 2026-08-15 after measuring — MS already has Nim's whole conversion architecture, and the earlier draft of this cell misread it twice.\*\* `fitNode` (`checkExprPass.ms:2582`) IS Nim's `fitNode`: one funnel, wrapping in `NodeKind.HiddenStdConv` on `isNarrowingIntConv` (float64 rank 10 > int32 rank 5), called from nine positions — decl init, return, assignment, ternary branches, object fields, array elements, arrow body, default params, plus call arguments through a separate test. Explicit `as` stays a `TypeAssertion`. The gap is purely on the consuming side: `jsgen.ms:87` emits only `hd.convExpr` and `emitTypeAssertion` (`codegen/js/expressions.ms:480`) is labelled `// no-op in JS`, so both node kinds are DISCARDED. \*\*Placement diverges from Nim deliberately: Nim spells conversions in codegen (`genConv`) because it has no transform tier for this; MS does have one and already uses it for C\*\* — `src/transform/native/rangeCheckInject.ms` rewrites both node kinds to `msCheckRange\*` calls (measured: all three of decl / `as` / call-arg emit `msCheckRangeI32(f, -2147483648, 2147483647)`, while JS emits a bare `f`). The JS fix is that pass's mirror, gated by the `jsBackend` flag that `transformProgram` (`src/transform/index.ms:89`) already threads through four JS-only passes; every JS spelling is an ordinary BinaryExpr/CallExpr, so no codegen file changes. Copying Nim's placement here would contradict both `CLAUDE.md`'s thin-codegen rule and this repo's own C-side precedent — the reference is authority for BEHAVIOUR, the in-tree design for STRUCTURE. \*\*SHIPPED 2026-08-15\*\* as `lowerIntConvJS` (`src/transform/coercion/intConvJS.ms`), 2 lines of wiring in `transformProgram` and no codegen change, exactly as planned. One placement constraint was discovered by measurement and is now pinned by a test: the pass must run AFTER `resolveRuntimeIdents`, because the prelude declares its own `class Math` and binding the synthesized `Math.trunc` receiver to it routes the call through the JS naming oracle, which mangles it to a module global. Measured on `016-jsIntegerModel.ms`: JS 3 ok/16 BAD → 13 ok/6 BAD, all ten `conv\*` rows flipped, C unchanged at 19/19; the six still red are division and wrap, which are the next two phases. |

| \*\*uint32 wrap and the bitwise family\*\* | Both backends agree, in BOTH modes — unsigned wrap is defined, so no check layer exists for it. Measured C and JS identical: `0-1` = 4294967295, `max+1` = 0, `1 shl 31` = 2147483648, `and/or/xor/not` = 4294967295 / 2147483649 / 4294967294 / 4294967295, `shr` = 1073741824. Emitted JS: `(a OP b) >>> 0` for `+ - << and or xor`, `\~(a) >>> 0`, and — the trick worth copying — \*\*`a >>> b` for `shr`, substituting the OPERATOR\*\*, because no trailing mask can undo an arithmetic shift of the int32 view. | Emitted a bare operator at every one of those, so all ten measured cases read back negative or unbounded on JS. \*\*SHIPPED 2026-08-15\*\* in `lowerIntArithJS`: same table as the reference, with `>>` substituted the same way. \*\*uint8/uint16 excluded on purpose\*\* — MS follows C's integer promotion (`uint8 200+100` = \*\*300\*\* on both backends), where the reference masks to 44 because its `+` over `uint8` returns `uint8`. Copying that mask would have introduced a bug. | \*\*SAME\*\* (uint32); \*\*DIVERGE-INTENTIONAL\*\* (uint8/uint16, forced by the promotion rule MS inherits from C) | Gate `016-jsIntegerModel.ms`, 19 → 28 cases, proven red at 18 ok / 10 BAD, now 28/28 `all-ok` on both lanes with the `@xfail(js)` removed. |

| \*\*uint32 multiplication — a REFERENCE BUG, do not port\*\* | `arithAux` emits `(a \* b) >>> 0`. A double multiply of two uint32 operands reaches 2^64, and the low bits are gone before the mask runs. Measured against \*\*its own C backend\*\*: `4294967295²` is `1` on C and \*\*`0`\*\* on JS; `3000000007 × 700000003` is `3906153237` on C and \*\*`3906153216`\*\* on JS. | `Math.imul(a, b) >>> 0`. `Math.imul` is an exact 32-bit multiply and answers signed, so the width mask still follows. | \*\*DIVERGE-INTENTIONAL (fixing a reference defect)\*\* | Second measured defect of this kind in the same subsystem, after `genConv` above — both are the same failure mode: a narrowing step that assumes its input already fits. Cheap to get right, and the C backend is the oracle that makes it visible. |

| \*\*Signed overflow — why MS does NOT copy the unconditional `\\| 0`\*\* | Two independent layers that compose: narrowing is emitted ALWAYS, in both modes (`((a + b)) \\| 0`), while the overflow CHECK is a helper wrapping the raw op only when checks are on (`((addInt(a, b)) \\| 0)`, `jssys.nim:452` = `var result = a + b; checkOverflowInt(result); return result;`). Checked mode raises before `\\| 0` ever sees an out-of-range value; danger mode lets `\\| 0` do the wrap. One spelling serves both. Its C backend genuinely wraps under `-d:danger` (measured: -2147483648 / 0 / -2147483648 — consistent), which is what makes the unconditional narrowing correct there. | \*\*Nothing emitted, deliberately.\*\* MS's C backend does not wrap: debug \*\*traps\*\* (measured, rc=255 with a source location) and danger is inconsistent UB — `int32 max+1` = 2147483648 (not wrapped) while `65536\*65536` = 0 (wrapped). | \*\*DIVERGE-INTENTIONAL (deferred to the check tier)\*\* | The reference's design is right and MS should adopt it — but only after the C side has a defined answer to match. Emitting `\\| 0` today would mean JS produces a defined wrap where C produces undefined behaviour, i.e. inventing a specification rather than porting one. \*\*MS's C-danger inconsistency is a real defect and needs its own issue\*\*; the language question ("does MS define signed overflow as wrapping?") has to be answered before either backend can be called correct here. |

| \*\*Range checks on conversion\*\* | `genRangeChck` (`jsgen.nim`) emits `BigInt.asUintN(size, …)`-based narrowing when `optRangeCheck` is on. | MS's \*\*C\*\* backend range-checks conversions: measured `300.9 as int8` → `Error: value 300 not in range -128 .. 127` (rc=1); `1e20 as int32` → trap `outside the range of representable values of type 'long long'`; `NaN as int32` → trap `nan is outside the range`. The JS backend does none of it (`300.9`, `1e20`, `NaN` pass through unchanged). | \*\*DIVERGE-INCOMPLETE (deferred deliberately)\*\* | This is a FOURTH class of C-debug check, alongside signed overflow, division-by-zero and shift overflow — all four were measured trapping with a source location. It belongs to the \*check obligation\*, not the \*value obligation\*: where C-debug refuses to produce a number, there is no number for JS to match, so these cases are excluded from the parity gate and the guards are scheduled last. Note also that Nim narrows all signed widths only to 32 bits (`int8(300.9)` → `300`, not `44`); MS follows, because the value C would produce there is a trap rather than a wrapped number. |



\## Tail-call lowering — MS is ahead of the reference (2026-08-16 session, guards 633-638)



Nim has NO tail-call pass: `grep -rln "tailcall|musttail|sibling" \~/projects/nim/compiler/` is empty. Nim survives deep self-recursion only via clang -O2 sibling-call optimisation on its C backend (measured: segfaults under ORC with a string param) and has nothing on JS. `tailCallLower.ms` is therefore MS-original; the reference supplies structural models, not an implementation to diff against.



Shipped, each with a corpus guard proven red on a pre-fix compiler (`src/test/corpus/programs/`):



| Shape | Guard | Note |

|---|---|---|

| `if/return` + DRC param-leak interaction | 632/633 | pre-existing |

| return-position ternary | 634 | `statementizeTailPositions` calls the now-exported `lowerTernaryInReturn` (conditionalExprLower.ms:183) — reuse, not copy |

| `\&\&`/`\\|\\|` in return | 635 | temp via `freshTempSym`; fires only when the RHS holds a tail call |

| match-expr in return | 636 | real root cause was the traversal family below, not matchLower |

| method self-call on FINAL classes | 637 | gated on `TypeFlag.OpenClass` = inverse of Nim `tfFinal` (`semstmts.nim:1675` `excl(body, tfFinal)`); the open-class half has NO automated assertion — the C backend lacks dynamic dispatch (pre-existing) |

| nested-loop return semantics; bare-block/braceless-if lowered | 638 | value-pinned: a rewrite that binds the inner loop yields 53 where 56 is correct; stayed green when the labeled-wrapper lowering landed (row below) |

| tail call inside while / do-while IS lowered | 640 | labeled wrapper (`\_\_tcl`) + labeled continue, 5M/1M deep; red 3/4 on the pre-change compiler (\[danger] survives via clang sibling-call — the Nim-release physics), green 5/5 full parity after |

| self-recursive routine bound to a const | 641 | needed a checker fix first (row below); arrow expr-body, arrow block-body, function-expr, and a function-local binding, 5M deep each |



Traversal family (rows 86/87) CLOSED inside this pass: `transformStmt` and `hasTailCall` were two independent hand-rolled arm lists with swallowing defaults — the family bit three times. Both now share one `tailOpaque` predicate (While/DoWhile/For\*/TryCatch/Defer + `isFuncBoundary`) and default-RECURSE all children (`mapChildren`/`forEachChild`) — Nim's `transformSons` polarity (`transf.nim` defaults to recursion in \~10 arms). A new structured stmt kind is covered automatically; a new loop-like kind must be added to `tailOpaque`, and 638 catches the miscompile if it is not.



typeFlags clobber (DIVERGE-UNINTENTIONAL, fixed at the proven site): `resolvePass.ms:1815` did `typeFlags = IsStruct`, erasing the `OpenClass` bit stamped at :1877. Nim treats a type's flags as a set — 15 `incl`/`excl` sites in semstmts, 63 in semtypes, and the single wholesale assign (`semstmts.nim:1933`) copies from another type, never resets to a constant. Fixed as `|=`; full suite green. Measured severity: no ORC leak from the wiped bit (1M cross-class cycles, peak RSS 2.47 vs 2.49 MB) because `cycles.ms` reads the field-path Type object, not `ClassDecl.nodeType`. RESIDUE: `resolvePass.ms:1417` (interface) and `:2014` (actor) still reset-to-constant; nothing stamps out-of-band bits on those today, left unchanged on purpose — apply `|=` there if that ever changes.



Self-recursive routine bound to a const — SHIPPED 2026-08-16, and the tail-call half was the smaller one. Traced from a repro matrix: `const f = (n: int64, acc: int64): int64 => … f(…)` failed to COMPILE on C (`called object type 'msClosure' is not a function or function pointer` — the row-756 dispatch), ran on JS, and a function-local binding failed even earlier with `Undefined variable`. The boundary: it worked only with an explicit type annotation on the const. Cause: `checkVariableDecl` (`checkPass.ms`) pre-registered the self-reference ONLY when a declared type existed, so without one the symbol carried `Inferred` while its own body was checked, `callConv` was not yet `CcClosure`, and the closure-call marker never fired. Nim never needs an external annotation: `semProcAux` (`semstmts.nim:2464-2479`) does `pushOwner` → `semParamList` → `s.typ = newProcType` and only then analyses the body — the signature comes from the routine itself, and the comment there ("push noalias flag at first to prevent unwanted recursive calls") shows recursion is exactly what the ordering is for. Verdict \*\*DIVERGE-INCOMPLETE\*\*; fix = derive the symbol type from the routine's own signature (`signatureTypeOf`, complete param + return annotations required, matching Nim's need for a declared return type on a recursive routine), and stamp it onto the hoisted module-scope symbol when that symbol is still `Inferred` — module-scope hoisting is why `lookupLocal` finds one there and not in a function body. With that, `lowerBoundRoutine` in tailCallLower treats a const-bound Arrow/FunctionExpr like a FunctionDecl; an expression-bodied arrow is wrapped as `return <expr>` first, and the rewrite is kept only when it actually produced the labeled wrapper, so non-recursive arrows are untouched. Guard 641; suite 3492 green.



Non-goals, decided: mutual recursion; virtual/open-class method calls; calls inside try (row 92 — `while(1)` wrapper re-throw hazard, now enforced structurally by `tailOpaque`); nested-loop returns — SHIPPED 2026-08-16 (initially deferred; the trace showed the cost was small and reversed the call). Nim's mechanism for this exact problem is `transformLoopBody` (`transf.nim:275`) — a continue-bearing loop body is wrapped in a labeled `nkBlockStmt` and `continue` is rewritten to `break <label>` (`:1153`). The MS port turned out even smaller than traced: the label infrastructure was already dormant in-tree (`BreakStmtData.breakLabel` and `ContinueStmtData.continueLabel` with complete JS labeled emit, plus `CBlock.label` — unused TBlock parity). The whole feature: one `whileLabel` field on `WhileStmtData` (3 literal sites), a JS label prefix in `emitWhileStmt`, C `goto <label>` in `genContinueStmt` + trailing `<label>: ;` in `genWhileStmt`, and tailCallLower labeling its wrapper `\_\_tcl` and emitting labeled continues; `tailOpaque` now denies only TryCatch/Defer/fn-boundary. Guards: 640 (while + do-while, 5M/1M deep, value-pinned), 638 keeps pinning the binding semantics; suite 3492 green. Toolchain trap recorded in memory: `msc` resolves `std/` from the binary's install root, so the `std/meta/node.ms` edit requires a fake bootstrap root symlinking the edited tree. RESIDUE: `statementizeTailPositions` keeps its own arm list — safe polarity, a missed shape merely stays un-optimised, never miscompiles.



\## Assignment in value position — DEBT; verdict DIVERGE-UNINTENTIONAL (Stage 1 shipped 2026-08-17)



\*\*Nim:\*\* assignment is a statement production, never an operator — `parseExprStmt` (`parser.nim:1581-1587`), grammar `exprStmt = … / simpleExpr '=' optInd (expr …)`, plus one explicit "special case: allow assignments" at `:695`; `tkEquals` has NO entry in the precedence machinery. Nim spells statements-then-value as `nkStmtListExpr`, the Q1 representation MS deliberately lacks (§3).



\*\*Ours (before):\*\* the parser has carried `TokenKind.Assign` as a full binary operator since the FIRST parser commit (`ba945a1`, header "JS-aligned precedence" — prec 5, right-assoc; chained `a = b = c` documented at `src/parser/expressions/precedence.ms:50` and pinned by the parse-only test `src/parser/expressions/core.ms:720`). The checker arrived later (`061b1bc`) and `inferBinaryOp` (`checkExprPass.ms:2050`) never had an arm for `=`, so every assignment VALUE fell to `\_ => inferredType()` — the internal pending-inference sentinel. Same borrowed identity as the `any` row above: it passes every leniency gate that exists to serve inference, so the value was never type-checked and codegen received no type. Sibling `UpdateExpr` (`x++`) does get a real type (`checkExprPass.ms:950`), which is what makes the missing arm an oversight rather than a design.



\*\*Measured symptoms\*\* (HEAD, `--gc=drc` AND `--gc=orc`, BOTH backends): `return l = "y" + l` → C `\[\[\[\[]` vs JS `\[yab]`; `a = b = "x"` → C loses the inner store (`a=x b=`); `(n = 5).toString()` on \*\*int32\*\* → `<object>` on BOTH backends; `while ((l = f()) !== "")` → C `invalid operands ('msString','msString')`, node prints `NaN`; `const r: int32 = (s = "x")` → NO checker error, clang catches it; `const r = (l = "y" + l)` → `internal: unresolved type (kind=47) reached codegen`. Emitted C shows the store landing in a borrow temp (dead store), the value `msStringDecref`'d before `return` (use-after-free), and `.length` never lowered to `msStringLength`.



\*\*Stage 1 (shipped):\*\* assignment operators type as `voidType()`, and an assignment BinaryExpr outside statement position is a checker error naming the split form. Statement position reuses the existing `ctx.stmtPosExpr` marker (`context.ms:994`, already read by the macro `SpliceMany` rules); `checkForStmt` now marks `forInit`/`forUpdate` too — 732 for-update sites depend on that. Guard `src/test/fixedbugs/bug109AssignmentIsStatement.ms` (7 tests), PROVEN RED without the fix (5 of 7 fail, file count 1→2, test failures 11→16). Blast radius measured BEFORE changing anything: \*\*0 real usages\*\* across src/std/examples/test (line-based + multiline greps, for-init, arrow bodies — the only hits are comments and that parse-only test); `makeAssign` (`transform/util.ms:343`) is the single construction chokepoint and all 50 internal synthesis sites wrap it in `makeExprStmt`. Gate 173 files / 3469 tests green; full corpus 536 pass / 3 fail / 6 xfail, where the 3 are `013-int64Fidelity` c/orc/danger failing identically on the pre-change binaries (`signed integer overflow: 9223372036854775800 + 8` in `parseIntegerLiteral`, `src/utils/string.ms:151` — a separate pre-existing bug; the older note that 013 "no longer reproduces" is stale).



\*\*Stage 2 (DEBT, not started):\*\* the true return to Nim is to move assignment out of the expression grammar into a statement production (`AssignStmt`), drop `Assign` from `isBinaryOperator`/`getPrecedence`/`isRightAssociative`, migrate the \~40 `operator === "="` consumers, and update the parse-only test. Cost is concentrated by the `makeAssign` chokepoint; the expensive part is `analyzer/inject.ms`, where moveOrCopy reads assignment nodes — memory-management code, so it needs the full gate + gen-2 + corpus on a quiet tree.



\*\*If the TS idiom is ever wanted\*\* (`while ((m = re.exec(s)) !== null)` is valid TS; MS's std has no `RegExp`/`exec` today, so demand is hypothetical): unlike `any` it IS implementable, so it belongs to the `undefined` class of TS-compat divergences, not the `any` class. Doing it properly needs THREE things, not two — a real type for the assignment value, statementization in value position (the `conditionalExprLower`/`updateExprLower` family), AND flow-narrowing through the assignment; without narrowing the idiom yields "may be null" inside the loop, which is a half-feature. At that point the diagnostic disappears entirely and this row flips to DIVERGE-INTENTIONAL with that rationale.



\## ORC collector state is per-thread (2026-08-19, /trace-nim session — SHIPPED)



| Mechanism | Nim | MS | Verdict | Notes |

|---|---|---|---|---|

| \*\*Cycle-collector state lives in the thread, not the process\*\* | Every piece of ORC state is a threadvar: `roots {.threadvar.}: CellSeq\[Cell]` (`lib/system/orc.nim:144`), `rootsThreshold {.threadvar.}` (:317), `freedCyclicObjects {.threadvar.}` (:379). A collection only ever walks the roots its own thread registered. The new thread-safe collector keeps the same partition — `yrc.nim`'s header: "Candidate roots are THREAD-LOCAL (gLocalRoots) … the common path from 'suspicious dec' to 'freed' never crosses a thread" — so NO reference collector shares a root set across threads, single- or multi-threaded. | `runtime/drc.c` defined all of it as plain globals: `msRoots` (:172), `msRootsThreshold` (:173), `msOrcTeardownDepth` (:174, an MS-only extension with no Nim analogue), `msFreedCyclicObjects` (:178). Any thread reaching `msOrcEndTeardown` (`drc.h:373`) could start a full collection over ANOTHER thread's roots — and `msOrcTeardownDepth` being shared also let one thread's `+= 1 / -= 1` cancel the UAF guard the other thread was relying on. | was \*\*DIVERGE-UNINTENTIONAL → SAME\*\* (fixed 2026-08-19) | The whole Bacon trial-deletion algorithm was ported faithfully \*\*including Nim's own Bug #22927 fix\*\* (`drc.c:389-391` is `orc.nim:363-365` line for line) — only `{.threadvar.}` was dropped, and NIM-REF had no row claiming a reason. \*\*Blast radius: it silently invalidated every corpus measurement.\*\* A pool worker running `compileCFile` (`compile.ms:600`) destroys a `Result<void, ProcessError>` at scope exit → `msOrcEndTeardown` → `msOrcCollect` → `collectCyclesBacon` → `\_NodeDestroy` on the MAIN thread's AST. Symptom: "build failed" with an empty log, \~10 per corpus run, plus a completing-run RSS of \*\*1.84 GB before vs 7.2 MB after\*\* (worse than `--gc=drc`'s 1.23 GB, because the worker's re-entrancy guard zeroes `roots.len` and main's cycles are then never reclaimed). Repro is a 45-line `.ms`: main churns cycles while four spawned workers allocate and drop a ref-typed local. Both halves are necessary — worker allocates nothing → 0/24 fail; main builds no cycles → 0/24 fail (`msOrcCollect` returns at `drc.c:409` on an empty root set); together → 13/24. A/B interleaved under identical load: pre-fix 7/16 crash, post-fix 0/16; at the compiler level (debug+ORC msc, 128 cc jobs per build) 1/12 vs 0/12. Gates after the fix: unit 174 files / 3493 tests, nim-guard ALL GREEN (drc+orc+js), corpus \*\*555 pass / 0 fail / 7 xfail\*\* (the run that produced the crash logs was 328/13). \*\*Deliberately NOT done:\*\* nothing was invented beyond the threadvar parity — in particular no owner-thread tag in `msRefHeader`. `msRememberCycle` (`drc.h:322`) unregisters by `rootIdx`, which is meaningless on another thread, so a cell registered on thread A and last-decref'd on thread B would corrupt B's root list; Nim has the identical shape and answers it by not sharing refs across threads. MS reaches the same place by construction rather than by rule: `msSpawnSlotSubmit` (`promise/thread.h:230`) takes no env ref and the worker never decrefs it, and the non-fused path routes env release back to the dispatcher via `msCompletionQueuePushEnvRelease`. \*\*Measured, not inferred\*\* (2026-08-19): `msUnregisterCycle` was instrumented to count calls whose `rootIdx` does not address this thread's own root set. On the compiler's own workload — a cold 128-cc-job build, the exact shape that produced the original crash — the counters are `reg=886325 unreg=65849 foreign=0`, byte-identical across 3 sequential and 4 concurrent runs: the unregister path runs 66k times and never once on a foreign thread. The concurrency corpus (402/403/405/406/409/410/411 and native actorCycleStress) reports `reg=0` — those types are acyclic, so they cannot reach the path at all, which is also why a spawn-closure probe capturing a ref stays green on BOTH runtimes and proves nothing. If a future path does hand a worker the last reference to a registered cell, this is the row to revisit, and `yrc.nim`'s orphan-list spill is the reference answer. Guard: `src/test/guard/orcThreadLocalRoots.ms`, \*\*proven red 10/10\*\* on the pre-fix runtime (all aborts) and green 10/10 after; its `Solo` control isolates "ORC collects at all" from "ORC collects per-thread". |



\## Integer literal spelling in emitted C (2026-08-20, /trace-nim session — SHIPPED)



| Mechanism | Nim | MS | Verdict | Notes |

|---|---|---|---|---|

| \*\*How an integer constant is spelled in the generated C\*\* | `genLiteral` (`ccgexprs.nim:23-45`) dispatches on the TARGET type: `tyInt64` → `addInt64Literal` (always `IL64(x)` = `x##LL`, `nimbase.h:146`), `tyUInt64` → `addUint64Literal` (`$i \& "ULL"`), everything else → `addIntLiteral` (`cbuilderbase.nim:88-95`), which spells plain digits inside the int32 range, decomposes `low(int32)` as `(-2147483647 -1)`, suffixes `IL64` above it, and decomposes `low(int64)` as `(IL64(-9223372036854775807) - IL64(1))`. Nim's own comment at the int32 arm — `# Nim has the same bug for the same reasons :-)` — names the reason: a MIN literal cannot be written directly, so it is built by arithmetic. | `formatCNumberLit` (`codegen/c/literals.ms`) emitted `int64ToDecimal(intVal)` for every integer regardless of target. Measured: `int64` min → bare `-9223372036854775808`, `int64` max/mid → digits with \*\*no suffix\*\*, `uint64` max → \*\*`-1`\*\*, `uint64` 1e19 → \*\*`-8446744073709551616`\*\*. `formatCInt64`/`formatCUint64` already existed with the right shape and \*\*no caller\*\* — a port that was written and never wired. | was \*\*DIVERGE-UNINTENTIONAL → SAME\*\* (fixed 2026-08-20) | \*\*The severity was mis-assessed twice before it was measured properly, and the correction is the point of this row.\*\* A bare `-9223372036854775808` looks harmless because in an ASSIGNMENT the implementation-defined conversion lands on the right value — measured correct on clang and zig cc, no warnings, which is what an early draft of this row wrongly recorded as "latent, conformance-only". It is not. `9223372036854775808` has no type in C's signed candidate list, so it becomes `unsigned long long`; in a COMPARISON the usual arithmetic conversions then promote the other operand to unsigned and the result flips silently. This was proven the expensive way: the fix's own guard `if (v > -9223372036854775808)` compiled to exactly that and returned false for every input, so the new formatter emitted the INT64\_MIN decomposition for \*all\* values, and the unit tests caught it. Nim never writes that literal either — it writes `low(int64)`; MS now uses a named `int64MinValue` const for the same reason (initialiser position is an assignment, which is the safe one). \*\*Deliberately NOT ported:\*\* Nim's `else` arm wraps small widths in a cast (`addCast(getTypeDesc(...))`, `ccgexprs.nim:45`) → `((NI32)42)`. No measured defect argues for it, MS's emitted C is cast-light by house style, and §3 Q1 puts representation on the intentional-divergence side; revisit if a target ever needs the width pinned at the literal. Gates: unit 174 files / 3504 tests, nim-guard ALL GREEN (drc+orc+js), \*\*gen-2 self-build green and gen-2 re-runs the suite 3504/3504\*\* (the emitter changed every integer constant in the compiler's own C, so a fixed point is the load-bearing gate here), corpus 555 pass / 0 fail / 7 xfail. Companion fix in the same arc: the out-of-range diagnostic printed the literal through a float64 (`cannot convert 9223372036854776000 to int32` for a source `9223372036854775807`); it now prints `outOfRangeText`/`intVal`, which is also what TypeScript does. |

| \*\*Member read on a value whose static type was lost\*\* \*(not a Nim row — an MS defect found en route, CLOSED)\* | n/a | `getDynamicField` is a real MS protocol (`obj.foo` → `obj.getDynamicField("foo")`, `src/test/c/protocols.ms:4`). When the checker loses a value's static type it falls into that protocol \*\*silently\*\*. Reproduced inside `formatCNumberLit`: `ty.kind === TypeKind.Uint64` compiled correctly on one line and, two lines later — after an intervening `if (…) return formatCNumber(d.value, ty);` — compiled to `getDynamicField(ty, "kind")` returning a `JsonValueData\*` compared against an enum constant (always false) plus a bogus `msDecrefCyclic` on a struct. Same expression, same function, same parameter. | \*\*CLOSED 2026-08-21 — root-caused in `checker/flow.ms` narrowType, fixed; guard `fixedbugs/bug112AliasedCondDeMorgan.ms` proven red\*\* | Blast radius measured, and it is small TODAY: a scan of every emitted `.c` in a full compiler build found `getDynamicField` calls only in genuine JSON code (`std/core/json`, `std/serialize/json/accessors`, corpus 505/506/512); the single hit in `checker/checkExprPass.ms` is the protocol's NAME as a string literal, not a call. So no live miscompile is shipping — but the failure mode is the worst kind (no diagnostic, wrong answer) and the trigger is an ordinary shape. Root-caused 2026-08-21 with a 14-variant isolation matrix on a standalone repro: the missing ingredient was the ALIASED condition — `const b = ty !== null \&\& ty.kind === K.X;` consumed by a branch that exits. narrowType's `\&\&`-false and `||`-true legs (checker/flow.ms) shortcut "one side didn't narrow" by returning the OTHER side — the intersection shortcut applied to a union — so on the fall-through path `Ty | null` collapsed to `null`, and every later member read fell into the protocol even under a fresh `ty !== null` guard (the reference narrowTypeByBinaryExpression builds the union with no shortcut; the fix is union absorption: either side unnarrowed → original type). Class vs struct only selects the failure MODE: the pointer repr fails silently, the same shape with a by-value struct dies loudly in clang (`struct` compared to `void \*`) — which is why the earlier small-struct repro, which also lacked the alias, showed nothing on any backend. Gates on the fixed compiler: 16/16 repro variants (drc+orc), unit 174 files/3504, nim-guard ALL GREEN, gen-2 self-build + suite, corpus 555/0/7 — and bug112 is the ONLY delta in the `src/test/index.ms` aggregate's fail set between the buggy and fixed binaries. Residuals deliberately NOT closed here: (1) member access on a `null`-typed receiver should ERROR, not synthesize `getDynamicField` — the synthesis gate in checkExprPass matched an extension against a null-typed object (this is the defense-in-depth against the NEXT narrowing bug); (2) the JS backend emits no enum decls for the minimal repro file (`ReferenceError: Kind\_Uint64 is not defined`) — independent bug, reproduces without the narrowing defect; (3) the `src/test/index.ms` aggregate lane (fixedbugs + test/c + lang) carries \~13 pre-existing red files and is outside the routine gate, so bug112 fires only when that lane runs. Workaround in the shipped code is ordering-only (compute the guards before the early return), and it is pinned by two unit tests in `literals.ms` so a reordering cannot silently reintroduce it. |



\## Module/symbol DCE — init pruning + hook aliveness (2026-08-23, /trace-nim session — tier 1 SHIPPED `ee6be7d..6067de5`, tier 2 PLANNED)



Measured context for the whole section: hello-world (`console.log("hi")`) went 32 → 19 modules, 1,906,296 → 1,758,408 B (−7.8%); self-host 300 → 292 modules. Gates on the shipped tier: suite 3506/3506, guard 130/130 identical to a clean-HEAD control, self-host fixpoint 0/293 `.c`, corpus SAN 133 pass / 1 fail (the 1 = pre-existing `015-optionalFieldNull`, red on control too). Corpus parity lane was green on the pre-port base and was NOT rerun at the ported base.



| Mechanism | Nim | MS | Verdict | Notes |

|---|---|---|---|---|

| \*\*Module init registration skips empty inits\*\* | `registerModuleToMain` (`cgen.nim` \~2259): the dispatcher's forward-decl + call for `DatInit`/`Init` are emitted only `if m.s\[cfsDatInitProc].buf.len > 0` / `cfsInitProc`; `registerReusedModuleToMain` carries the presence bits through the compilation cache ("the init/datInit presence comes from the artifact's meta head") | `genModuleInitFns` records `\_emptyDatInits`/`\_emptyInits`; `genProjectDispatcher` skips decl + call for members (`src/codegen/c/index.ms`, commit `6067de5`) | SAME | We did NOT port the reuse-metadata half and don't need to: a cache-reused module missing from the empty-sets still has its (possibly empty) init really defined in its cached `.c`, so the dispatcher's extra call links and runs as a no-op — the miss direction is conservative-safe. |

| \*\*Data init is static, not code\*\* | data → `DatInit` vs code → `Init` split; consts and constant aggregates are emitted as braced static C initializers via `genConstDefinition` (`ccgexprs.nim:3489`) / `genBracedInit` (:4198), producing no runtime init code; standalone targets additionally guard TLS/stack-bottom init calls with `targetOS != osStandalone` | `varDeclNeedsRuntimeInit` (`src/checker/reachability.ms`) stops rooting a module for initializers that produce no `Init000` code (number/bool/null literals, `\*TypeInfo` names, string literals) and `genGlobalVar` folds string-literal globals to a static pool ref (`src/codegen/c/declarations.ms`, commits `737a740` + `847747e`) — the two guards must stay in lock-step (two-gate) | SAME (direction) | \*\*Tier-3 extension stage-1 (object literals) COMMITTED `a64f759`+`bab5f83`; stage-2a (empty arrays) COMMITTED `51097d5..0823902` 2026-08-27:\*\* `isBakeableAggregateConst` (`reachability.ms`, shared predicate = the two-gate in one function) + `genBakedConstCell` (`declarations.ms`): a const object-literal whose fields are all scalar/string literals or null-env closure pairs bakes to `static struct { msRefHeader h; T b; }` with `rc = 1<<30` (immortal — `msDecRefIsLast` is count==0, `drc.h:238`, hot path untouched; cell never enters `msAlloc` so the DRC ledger never sees it — probe-verified), fields emitted by REUSING `genExpr` per field with a buffers-must-stay-empty guard so anything non-constant falls back to `Init000` (a two-gate mismatch degrades to lost optimization, never wrongness); dead const in an alive module emits nothing (Nim's lazy const emission for free). Q1 representation constraint: MS `const` is TS const (runtime initializers legal) — only the comptime-evaluable subset bakes; Nim's "const must be comptime" is NOT adoptable. Measured: hello 18→10 modules / 94,880→53,896 B danger-clang (Nim 2.2.2 danger = 72 KB — MS now smaller); self-host 300→294 modules; full matrix green (fixpoint 0/293 byte-identical, suite 3507, guards ALL incl. helloEmitClean, corpus 596/0/6x + SAN 137/0/1x, ORC/ledger-ASan/JS churn probes). \*\*Stage-2a (measured 2026-08-27):\*\* EMPTY const array literals bake to `static struct { msRefHeader h; msXxxArray b; } = { {1<<30,-1,\&CellTypeInfo,0}, {0,NULL} }` — runtime already grows from `p==NULL` (`msArrayPrepareAdd`; `MS\_ARRAY\_EMPTY` `array.h:203`); the per-element destroyFn/cellName derivation is now the shared `refArrayDestroyFn`/`refArrayCellName` (`expressions.ms`, extracted from the `msBoxRefArray` intercept — single source, do not re-inline). TRAP: `nativeLower` wraps top-level `\[]` in `msBoxRefArray(lit)` BEFORE `computeAliveSet`, so the predicate peels that call (`bakeableEmptyArrayLiteral`). Consequence: killing the last guaranteed ledger alloc exposed the SAN runner's implicit "≥1 LEDGER line proves instrumentation" contract → `drc.c` now always prints `LEDGER TOTAL` (constructor-registered atexit) and the runner exempts TOTAL from the balance rule (it sums excused destroy==0/slack imbalances); 17 dead `@ledger-slack(msRefArrayRefCell): 1` removed, 711 slack 6→5. hello 53,896→53,112 B, dispatch = own Init000 only; the 9 remaining hello modules are typedef/prototype-only TUs (0 fn defs, 0 data — ≈0 bytes; roster pruning belongs to the row-914 unification). \*\*NOT done:\*\* non-empty arrays (static element buffer + push/realloc = UB — blocked by design, not effort), nested aggregates, bare fn-identifier fields (rejected on purpose: a raw fn pointer in an msClosure field is a C type error). |

| \*\*DCE mechanism: on-demand emission vs precomputed alive set\*\* | emission IS the DCE: `genSym` on first use routes to `genProc` (`cgen.nim:1166` → `:1813`, public demand entry `requestProcDef` `:1828`); an unreferenced proc is simply never generated; no filter pass exists | alive set computed in the checker but AFTER transform+analyzer — `computeAliveSet` runs on `transformedPrograms` (`compile.ms:1222`, re-measured 2026-08-25); module skip (`aliveSetHasModule`, `compile.ms:1262`/`:1332`) saves codegen + clang only; codegen filters symbols via `isDeclAlive` (`src/codegen/c/declarations.ms:45`) | DIVERGE-INTENTIONAL | CORRECTED 2026-08-25: this cell previously justified the divergence by "module skip saves transform/analyzer work" — measured FALSE (see MS column; the skip's coverage equals Nim's emission laziness). The real reasons: (1) TS alignment — treeshaking (Rollup/esbuild) IS precompute-reachability-then-filter; on this axis the TS ecosystem and MS agree and Nim is the outlier, so per the house rule (no conflict → follow Nim; conflict → TS wins) the filter model stands; (2) per-module codegen-cache soundness — a module's emitted C is a pure function of its own post-transform AST, so cache hits legally skip codegen; demand-driven emission makes module A's output depend on module B's demands, which is why Nim re-runs whole-program codegen every build, caches only at the C-compiler level, and needs the owner-routing/`myModuleOpenForCodegen` machinery (`ccgtypes.nim:2046-2090`); (3) codegen stays thin/dumb per the project's hard rule; (4) `computeAliveSet` lives in the checker — backend-neutral by position, but NOT yet consumed by `src/codegen/js/` (grep 2026-08-25: zero hits) — a treeshaking gap to close, not a design choice. The cost is TWO predicates (reachability roots, `isDeclAlive`) that must agree; the mitigation is the fail-loud assert in the tier-2 plan below. Reopening condition: if a fourth predicate-drift bug appears after phase C's assert ships, re-litigate the architecture instead of patching. |

| \*\*Hook aliveness: reference edges, never names\*\* | no hook is ever a root and NO name-based aliveness exists anywhere. Hooks are synthesized at USE sites — `createTypeBoundOps` from `sempass2.nim:132` (\~15 sem positions: var sections :667, exprs :1218, seq/array ctor :1289, params :1315, returns :1470, raise :1480, case :1509), `injectdestructors.nim:246`, `lambdalifting.nim:241-253` — deduped via sighash `canonTypes` + `tfCheckedForDestructor` (`liftdestructors.nim:1458`). They are EMITTED only through real reference edges: an injected call, or TypeInfo emission — `genHook` (`ccgtypes.nim:1823`) calls `genProc(m, theProc)` and embeds the symbol; `isTrivialProc` leaves the slot NULL instead of emitting an empty hook. `=trace` is synthesized only under orc/yrc — source comment: "saves code size". | (updated 2026-08-25, phase C shipped) name-based exemptions DROPPED: `=`/`\_\_` prefixes, `isDrcLifecycleName`, and the generic-instance `\_\_` redirect are gone from both Root 2 and `isDeclAlive`; hooks live via real edges (alloc-site TypeInfo with `typeReturn`-first Ref peel, mono names via `mangleMonoName`, union variant hooks at every Union-typed walk node, actor-origin decl → hook marks). Two DOCUMENTED carve-outs remain, both codegen-demand-coupled (the demand is synthesized inside codegen with no AST edge): (1) the arraySeqHook family (`\*ArrayDestroy/Copy/Sink/WasMoved`, excluding the three exact runtime names) — emitted + walked, dead ones stripped free by the linker (static + `-ffunction-sections`); (2) `$`-prefixed DRC env hooks — emitted (except `$lifted\_`/`$fn\_`, aliveSet-gated) and now WALKED so their callees get edges. The actor TypeInfo emitter bypasses the `genGlobalVar` gate (separate emitter) — small debt, folds into the TypeInfo-unification arc. | DIVERGE-INCOMPLETE | \*\*Return-to-Nim plan (3 phases, each gated; A+B+C ALL DONE 2026-08-25, uncommitted in \~/worktrees/dce-fix2 — the old /tmp worktree was eaten by the macOS /tmp cleaner):\*\* \*\*A)\*\* add the two real edge kinds to the alive walk — inject-site→hook and TypeInfo→hook — while KEEPING both exemptions; the C emit must stay byte-identical (fixpoint-style diff is the phase gate). DONE: `markTypeInfoEdge` (`reachability.ms:266`) covers ObjectLiteral/NewExpr; the inject-site→hook edge pre-existed (inject uses `makeIdent`, caught by walkBody's Identifier fallback); gate: self-host 293/293 `.c` byte-identical, hello 20/20 + 19 modules kept. \*\*B)\*\* instrument: list every decl alive ONLY via exemption and classify each one (genuinely dead = the win; alive-through-an-edge-we-missed = a bug caught before any behavior change — this is where indirect references via function pointers/closures/dispatch tables surface). DONE: hello 1613 exemption-only decls → NOREF 1056 / ZOMBIE-REF 514 / TYPEINFO-REF 43 / ALIVE-REF 0; self-host 3107 → 2539 / 276 / 292 / 0. ALIVE-REF=0 on both = no missing call-graph edge kind. Fired branches: drc 1568+2615, `$` 45+471, dunder 0, eq/generic 0. Data: /tmp/audit-8128/. \*\*C)\*\* (design settled 2026-08-25) FIRST gate TypeInfo emission on the alive set — `isDeclAlive` filters only FunctionDecl today, so TypeInfo globals + `\_\_DatInit000` assignments emit unconditionally; flipping exemptions without the gate = 43 undefined symbols in hello (the phase-B TYPEINFO-REF count). The assert is INVERTED from the original plan: `genGlobalVar` records gated-out TypeInfos (`typeInfoSkipped:` key), and `ensureTypeInfoDef` hitting a demanded-but-skipped TypeInfo = build error ("missing edge in markTypeInfoEdge"). Rationale: the originally planned direction (hook referenced by TypeInfo must be alive) is already loud — a dead hook is a link error; the SILENT hole is `ensureTypeInfoDef`'s 2-field fallback (name+destroyFn, no traceFn/isCyclic — `types.ms:626` vs `genTypeInfoVar`'s 4 fields, `declarations.ms:736`), invisible under drc (`msOrcTraceRef` is a no-op, `drc.h:399`) and a leak under orc. THEN drop both exemptions — predicate drift becomes a build error, not a link error or a silent leak. SHIPPED + measured 2026-08-25: hello 32 → 18 modules, 1,908,192 → 878,136 B (−54%); self-host fixpoint 0/295 `.c` byte-identical (measure gen1→gen2 back-to-back — a corpus lane in between contaminates the shared `out/release/.cache` and fabricates diffs); suite 3506/3506; guard A/B identical 130/130 plus the new `helloEmitClean` runner check (nm on the linked binary — 0 websocket/crypto symbols; proven-red on a pre-phase-C compiler: 26 hits; grepping the emitted `.c` does NOT work — `#include` paths of dead-module imports false-positive); corpus parity 567 pass / 0 fail, SAN 132 / 0. The assert fired on real missing edges 6 times during bring-up (DU payload, mono `\_init`, GI hooks, `$Env` callees, actor hooks, union projection copies) — each fixed by adding an edge, never by re-widening an exemption. Full matrix on C: suite + guard A/B + fixpoint + corpus parity + SAN ledger (this area has precedent for leaks that hide from everything but the SAN ledger) + a permanent guard that hello's emitted C contains no websocket/crypto symbol. Runtime prerequisite for porting `isTrivialProc`→NULL: the runtime accepts `destroyFn = NULL` (recorded in prior sessions; MUST be re-verified empirically at phase-A start). VERIFIED 2026-08-23: MS DOES synthesize trace hooks under `--gc=drc` (probe: cyclic type → `LinkNodeTrace` emitted + traceFn assigned; self-host carries 292 trace fns) while Nim doesn't — a deferred size lever. Runtime `destroyFn = NULL` prerequisite also verified (static: `drc.h:68-74` guard, all dispatch via `MS\_DESTROY\_DISPATCH`; plus live probe — codegen already emits `destroyFn = NULL` for RC-field-free types, runs green). |

| \*\*TypeInfo emission: one demand-driven emitter, static data, identity keys\*\* | single entry `genTypeInfoV2` (`ccgtypes.nim:2046`): demand at use site, dedup + identity via `hashType` sighash (never by name), owner-routed definition with extern elsewhere; `genTypeInfoV2Impl` (`:1959`) emits a static braced initializer (`.destructor`/`.traceImpl` embedded via `genHook` `:1823`, trivial hook → NULL slot) — zero runtime init code | TWO emitters: `genTypeInfoVar` (`declarations.ms:736`, from destructorLifting's VariableDecl — 4 fields name/isCyclic/traceFn/destroyFn) and `ensureTypeInfoDef` (`types.ms:626`, on-demand at alloc sites — only name+destroyFn, silently emitted when the first path didn't run); both write runtime assignments into `\_\_DatInit000`; keyed by the `\*TypeInfo` NAME suffix — a TS-legal `const MyCustomTypeInfo` bypasses mangling (`declarations.ms:633` records the hazard) | DIVERGE-INCOMPLETE | \*\*Committed destination (settled 2026-08-25): follow Nim on all three counts\*\* — one demand-driven emitter at alloc sites, weak static braced initializer (kills the DatInit lines and any module-rooting they cause), keying by type identity. Bundle with the tier-3 `genBracedInit` port above: same emission surface, gate once. The phase-C `typeInfoSkipped` assert is scaffolding this destination deletes — with one emitter there is no silent fallback, and a dead hook referenced by a weak initializer is a loud link error by construction. |

| \*\*Runtime-internal deps must not ride optional modules' `@compile`\*\* \*(MS lesson, no direct Nim row — Nim's `cgsym`/compilerproc machinery requests runtime symbols on demand)\* | n/a | `pool.c:233` (always linked) calls `msIoEngineWake`, but that symbol was only compiled via `@compile` in `std/net/index.cms:9` — module DCE killing `std/net` produced an undefined symbol at link. Fixed by adding `runtime/io/engineSelect.c` to `rtFiles` (`src/compiler/compile.ms`, commit `ee6be7d`); dedupe is safe via `\_compiledOFiles`. | — | Audit rule for tier 2 phase-A recon: grep runtime C for symbols whose only compile path is an MS module's `@compile`; every such pair is a link failure waiting for DCE to get better. |

| \*\*Method dispatch (dynamic)\*\* | `cgmeth.nim`: methods bucketed (`methodDef`/`sameMethodBucket`), one dispatcher per bucket with `of`-test if-chain most-derived-first (`genIfDispatcher`, `sortBucket`/`inheritanceDiff`), call sites rewritten to the dispatcher (`methodCall`), dispatchers generated once the whole graph is known (`generateIfMethodDispatchers`) | same algorithm, MS-native representation: registry populated in collectPass (whole-program by pass ordering; dedupe by name+modulePath+location mirroring `registerExtension`), dispatcher emitted per-TU as `static msDisp\_<lifted>` into GlobalVars at the identifier-callee interception (`ensureMethodDispatcher`, codegen/c/expressions.ms) — sound because C emission is whole-program-fresh every build; RTTI = `msTypeInfo.base` chain + `msIsInstance` (runtime/drc.h) populated via destructorLifting `base` key → `genTypeInfoVar`; reachability edges: child TypeInfo ⇒ base TypeInfo (`markTypeInfoEdge`) and reachable base method ⇒ every override + its class TypeInfo (`markAndWalk`); `instanceof` lowers to `msIsInstance` on C; checker resolves inherited methods through the base chain (`findFirstMatchingExt`/`filterExtsByReceiverType` nearest-level walk via `classBaseStruct`) | \*\*SAME (algorithm) / DIVERGE-INTENTIONAL (placement)\*\* — per-TU static dispatcher at codegen vs Nim's pre-codegen dispatcher procs; per-module symbol worlds + incremental module caching make a single owning-module dispatcher unsafe here | 2026-08-26. Was DIVERGE-INCOMPLETE: C had NO dispatch (call bound to the receiver's STATIC type) while JS prototype-dispatched — one program, two meanings, silent; inherited methods were invisible to the checker (`d.foo()` with `foo` on Base errored "Property does not exist" — methods live in the extension registry, NOT `<Class>\_<method>` symbol-table entries; that lookup misses even own methods); `instanceof` on classes died at C codegen (`reached codegen unresolved`). Guard: corpus `732-dynamicDispatch` (c↔orc↔danger↔js parity: dispatch via base-typed var, 3-level, `this`-call in base method, inherited method, instanceof; proven RED on pre-fix binary — refuses to compile). Gates: suite 174/3507, nim-guard ALL GREEN, corpus 599/0/7, gen-2 fixed point (msc-dd2 dispatch tests green), drc+orc, JS parity byte-identical. Scope cuts declared: method extraction (`const f = b.step`) = separate this-binding arc; multi-methods not adopted (Nim default off); overloaded method names keep direct calls (conservative, no silent wrong dispatch — bucket disabled). Residuals (own tickets): override-signature compatibility rule (Nim `sameMethodBucket` Invalid arm) not yet enforced; `super.method()` untested (super ctor only today); collect runs twice per class (re-parse AST) — dedupe absorbs it, root cause unowned. \*\*Audited 2026-08-27\*\* (probes `$TMPDIR/opencode/audit\_5527`, post-commit re-verify vs cgmeth): no invented mechanism; every piece maps to a cgmeth analog or a documented adaptation. Precision fixes to this row's claims: (a) the overload bail in `dispatchOverridesFor` is name-GLOBAL (fires before the `dispDepthBelow` hierarchy filter), not per-bucket — but both trigger states fail LOUD earlier: same-class overload dies at C codegen (lifted `\_u0` redefinition), same-name classes in two modules die at link (`duplicate symbol \_D\_init` — ctor init not module-mangled, pre-existing global class-name uniqueness); no silent path exists today, re-scope the bail if either collision ever compiles. (b) cross-module dispatch + `instanceof` verified correct — owner module defines TypeInfo, consumers `extern` → `msIsInstance` pointer identity holds across TUs. (c) sig-mismatch "override" (`B.foo(int32)` vs `A.foo()`) = loud C arity error at the dispatcher call (`too few arguments, expected 2, have 1`) — the sameMethodBucket Invalid-arm residual is diagnostics-quality, not correctness. (d) fallback `ensureTypeInfoDef` emits no `base`; no user-code trigger found (owner path always runs for classes, `typeInfoSkipped` assert is loud) — folds into row 914's one-emitter destination: `base` must ride the braced initializer. |



\## for-of loop variable mutability (2026-08-28, /trace-nim session — SHIPPED)



| Mechanism | Nim | MS | Verdict | Notes |

|---|---|---|---|---|

| \*\*Writes through the for-of binding\*\* | for-vars are `skForVar` (`semstmts.nim:1085`); `isAssignable` puts them in the `{skParam, skLet, skForVar}` arm → `arAddressableConst` (`parampatterns.nim:238`) — the binding's location is never an assignable lvalue, so BOTH rebind and interior writes are "cannot assign". Mutation is spelled through `mitems`/`mpairs` (var iterators yield `var T`). | `checkForOfStmt` (checkPass.ms) bans INTERIOR mutation through the binding when the element type is a value aggregate, reusing the value-param rooster verbatim (`isValueAggregateParam` + `scanForMutation(interiorOnly)` from paramMutationAnalysis.ms — same invariant, same file, newly exported). Ref elements (`T\[]`) stay writable: the per-iteration copy is a pointer, writes alias identically on C and JS (probed). Rebind (`p = …`) stays legal. | \*\*SAME\*\* (interior ban rides Nim's arAddressableConst invariant) / \*\*DIVERGE-INTENTIONAL\*\* (rebind legal — TS surface; a rebind is a fresh per-iteration local with zero collection effect on BOTH backends, probed 2026-08-28) | Trigger evidence: `for (const p of vecOfStruct) p.x = 9` → C copy swallows (fieldVec=1,3), JS aliases (9,9) — silent C↔JS parity fork, same disease the value-param ban killed. Guard `forOfLoopVarMutationCheck` (4 shapes: Vec<struct>, struct\[], Vec<Vec>, tuple elem; proven RED on pre-fix msc — 0 errors), corpus `736-forOfLoopVarLegal` (landed as 735, renumbered `ac98d02` after a cross-session number collision) pins the legal surface (rebind, ref-elem writes) green C+JS. SHARED HOLE with the param rule, not widened here: mutating METHOD calls through the binding (`p.push(9)`) are invisible to `scanForMutation` on both rules — Nim catches those via the var-param binding (`x.add 1` needs `var seq`), we have no receiver-mutability marker; own ticket — CLOSED 2026-08-28 (`edb3f50`, mutator row below). Destructured for-of patterns (`for (const \[a,b] of …)`) not covered — bindings are locals of copies, same residual family. |



\## Vec<T> vs T\[] container-kind distinctness (2026-08-28, /trace-nim session — SHIPPED)



| Mechanism | Nim | MS | Verdict | Notes |

|---|---|---|---|---|

| \*\*Implicit relation between the value seq and the ref array\*\* | `typeRel` (sigmatch.nim) relates `tySequence` and `tyRef` as different KINDS — no arm relates them in either direction; `seq` ↔ `ref`/heap-box conversion is always explicit in source. | `Vec<T>` = bare `Array`, `T\[]`/`Array<T>` = `Ref(Array)` (pinned by resolvePass.ms's own representation tests, lines \~2066-2098). Two leaks made them implicitly interchangeable: (a) the `Ref<T> → T` auto-deref arm in `isAssignable` (compat.ms — documented purpose: self-referential FIELD promotion, interfaces) peeled `Ref(Array)` into bare-`Array` slots → `T\[]`→`Vec` assigns and param calls passed the checker; (b) fitNode's central enforcement is scoped to the memory-safety class `isReinterpretUnsafe` (row 80), which bailed on `source.kind !== target.kind` before ever seeing the pair → `Vec`→`T\[]` assigns passed. On C both assign directions emitted invalid C (clang "assigning to 'int32\_tArray' from incompatible type" — toolchain error shown to the user); `T\[]`→`Vec` param calls RAN via an ABI pun (ref-box pointer coincidentally matches the by-pointer value-aggregate param convention); JS ran everything (one array repr) → silent value/ref semantics fork. Fix: auto-deref arm refuses `Ref(Array)`→`Array` (one line); `isReinterpretUnsafe` gains the `Array`↔`Ref(Array)` pair both directions before the kind-equality bail; `arrayDisplay`/`typeDisplayName` render bare `Array` as `Vec<T>` vs `Ref(Array)` as `T\[]` (pre-fix diagnostics read "got Array, expected Array"). | was \*\*DIVERGE-UNINTENTIONAL → SAME\*\* (no implicit relation between container kinds; explicit conversion only) | Blast radius measured before fixing: in-tree ≈ 0 — corpus+suite C-green proved no reliance (C died on every cross path); std is 594 `T\[]` vs 13 `Vec<>` annotations with zero cross-assign. `Vec`→`T\[]` param calls were ALREADY rejected (kind mismatch in the arg path — the half that never had the peel). Legal surface preserved and probed: `T\[]`→`Span` and `Vec`→`Span` coercions (the Ref peel feeding the Span arm still runs — target Span, not Array), contextual literals (`const r: int32\[] = \[1,2]` types as Ref(Array) via refArrayWrap, `const v: Vec<int32> = \[...]` adopts bare Array — neither touches the banned pairs), interface auto-deref (inner Struct, untouched). Guard `vecRefArrayDistinct` (3 GUARD-CHECK-FAIL pins, proven RED on pre-fix msc: 0/3 substrings — pre-fix failures were clang-stage or silent), corpus `737-vecRefArraySpanLegal` pins the legal surface. NOT built: an explicit conversion API (`.toVec()` / `.toRefArray()`) — nothing in-tree needs it; add when a user hits the new error with a genuine need. |



\## Span as a function return type (2026-08-28, split-and-conquer run — SHIPPED)



| Mechanism | Nim | MS | Verdict | Notes |

|---|---|---|---|---|

| \*\*Borrowed view escaping via return\*\* | `typeAllowed` rejects `tyOpenArray` outside parameter position — `proc f(): openArray\[int]` is "invalid type ... for result" unless experimental view types are on. One rule, applied wherever a signature is formed. | No `typeAllowed` chokepoint exists; return annotations resolve at 5 scattered sites (fn `resolvePass:\~1190`, methods ×2 `\~1763/\~1979`, fn-type annotations `\~80`, closures `checkPass signatureTypeOf`) plus the inferred-return assignment in `checkFunctionDecl`. Fix: `resolveReturnAnnotation` wraps `resolveAnnotation`, bans top-level `TypeKind.Span` with "cannot return Span<T>: a Span borrows memory owned by its source; return the owning container (Vec<T> or T\[]) instead"; all 5 sites switched, inferred path checked (`function f(s: Span<T>) { return s; }`). | \*\*SAME\*\* (no view escapes a frame through a return type) | Pre-fix behavior was a raw clang error leaking to the user (`function view(a: int32\[]): Span<int32>` died at C compile; spacetime CLAUDE.md had it as "a function RETURNING Span stays broken"). Blast radius 0: no `): Span<` declaration existed in src/std/test. Guard `spanReturnBan` (5 pins incl. inferred + fn-type annotation shapes, proven RED 0/5 on pre-fix msc). Fn-type annotations report the error twice — pre-existing double-resolve (unknown-type errors report 4× on the same shape); not widened here. Residual: generic instantiation `id<T>` with T=Span returning T is not caught at the instantiation site.



\## Mutating array methods through value bindings (2026-08-28, split-and-conquer run — SHIPPED)



| Mechanism | Nim | MS | Verdict | Notes |

|---|---|---|---|---|

| \*\*`v.push(x)` where v is a value param / for-of binding\*\* | `seq.add` takes `var seq\[T]`; a non-var param or `skForVar` binding is `arAddressableConst` in `parampatterns.isAssignable` → "cannot be passed to a var parameter". The receiver-mutability rule IS the var-formal rule. | `scanForMutation`/`findMutationLocation` only saw assignment/update/HiddenAddr writes — `bump(v: Vec<int32>) { v.push(9) }` passed the checker and MUTATED THE CALLER on BOTH backends (value params pass by pointer with a read-only contract; probed pre-fix: a=\[1,2] → bump → a.length==3 on C and JS). Fix: CallExpr arm in both walkers — callee MemberExpr whose object roots at the scanned name, property in the builtin mutator list (push/pop/shift/unshift/splice/reverse/sort/fill/copyWithin/append/setLength/setSlice/stripInPlace/setLen), receiver nodeType `Array`/`SizedArray` (Ref(Array)=`T\[]` receivers stay legal — aliasing is their contract, pinned by corpus 736/738). Gated `interiorOnly` so the `mutatedParams` bits scan (unknown consumers) is untouched. Existing ①/for-of error messages fire unchanged. | \*\*SAME\*\* (receiver mutability rides the same invariant as Nim's var-formal check) | The mutator list already existed in `varpartitions.ms:isMutatingMethod` — but importing it pulled varpartitions INTO the build graph for the first time and it no longer compiles (5 stale errors: HiddenAddrData/isReadonly exports gone) — \*\*varpartitions.ms is dead code\*\* (zero import statements; its 3 in-tree mentions are comments) — DELETED `009ab83`, build + suite 3510×2 unchanged. (Correction: arrayMethodInline is ALIVE — transform/desugar/, imported + called + \~10 live suite tests; the earlier “dead” note meant only that its `.map` lowering never fires because the checker rejects `.map` first.) Predicate duplicated locally in paramMutationAnalysis instead of reviving the dead module. Guard `arrayMutatorValueBinding` (3 pins: param push, param sort, loop-var push via Vec<Vec>; proven RED 0/3). Corpus `738-arrayMutatorLegal` pins the legal surface (local Vec push, `T\[]` param push visible to caller, `T\[]` elem push in for-of) green C+JS. Residual (unchanged): user-defined struct methods mutating `this` have no marker; destructured for-of bindings.



\## ref/out param write-back on the JS backend (2026-08-28, split-and-conquer run — SHIPPED)



| Mechanism | Nim | MS | Verdict | Notes |

|---|---|---|---|---|

| \*\*`var T` params with no address-of on JS\*\* | jsgen represents an address as an `etyBaseIndex` PAIR (container, index): var params take two slots, `genAddr` builds (obj, field)/(arr, idx) pairs, `genDeref` reads `c\[k]`, locals with their address taken are allocated as single-cell boxes. | New js-only AST pass `jsVarParamLower` (transform/lowering, gated `jsBackend` in transformProgram — precedent: paramReassignLower is C-only). Same representation, one-arg packaging: a Var arg becomes `\[container, key]`; addr-taken locals box as `let x = \[init]` with reads rewritten `x\[0]`; addr-taken params re-box via prologue `p = \[p]`; callee reads/writes `v\[0]\[v\[1]]`; forwarding a Var param passes the pair through raw. jsgen unchanged — OutExpr reaching it still emits `/\* unsupported \*/` fail-loud. | \*\*SAME\*\* (Nim's base+index scheme; two slots vs one two-element literal is packaging) | Corpus `733-refOutParams` runs on the js lane for the first time (@skip-js removed) — all 8 checks (out int/struct/string, bare ref, out rw, member lvalue, elem lvalue, ref forwarding) print `ref-out-params done` identically to C, and the lane diff now guards it. Three traps burned into the pass, all found empirically: (1) synthetic identifiers must carry `nodeType = null` when they denote the CELL — a struct-typed synthetic ident gets wrapped in `msValCopy\_S` by the js valueCopy layer (callee then mutates the copy's cell) and a string-typed one turns `s\[0]` into `charAt(s,0)`; (2) the parser binds `out` INSIDE postfix — `out b.val` is `MemberExpr(OutExpr(b), val)`, so unwrap must run on the container, not only the arg top; (3) `mapChildren` hands NULL children to visitors — the pass segfaulted the compiler on every js build until sc/rw got null guards. |






| Mechanism | Nim | MS | Verdict | Notes |
|---|---|---|---|---|
| **Dot access whose object is not a type** | `builtinFieldAccess` gates type-field reads on `isTypeExpr(n.sons[0])` (`semexprs.nim:1608`) → `tryReadingTypeField`; a `skProc` name can never carry fields. Namespacing comes from MODULES (`math.floor`), and `T(x)` in call position is a CONVERSION, not a call — the `of skType:` arm of the callee switch dispatches to `semConv` (`semexprs.nim:3519-3527`). So in Nim one identifier is never both callable and a member namespace. | The static-extension machinery (`this typeof X`, flag `sext:X`, `parser/util.ms:220`) already keys the receiver by NAME: `ExtensionMethod.receiverTypeName` is a string, `isReceiverMatch` compares strings for `ext.isStatic`, and `checkMemberExpr`'s alias fallback resolves via `d.object.resolvedSym.name` — the clause `Buffer.alloc()` needs, since `type Buffer = string` makes `typeNameOf(objType)` return "string". Only the ENTRY predicate was kind-based (`symbolKind ∈ {Class, Actor, TypeAlias, Interface, Struct}`), which is why a name declared as `extern function String<T>(val: T)` could be called but could never carry `String.fromCharCode`. Fix: one shared `isTypeLevelAccess(ctx, obj)` (callResolve.ms) replaces the two inline kind lists at `checkCallExpr` ~800 and `checkMemberExpr` ~2707 — they asked the same question with lists that had already drifted (`Struct` present in one, absent in the other; unified to the union, inert in-tree since no static-extension receiver is a struct). The namespace arm is an ALLOWLIST of `SymbolKind.Function`, not a blocklist: kinds that bind a value (Variable, Parameter) never qualify, so a local shadowing the name wins — the first cut excluded only Parameter and silently accepted `const String = 5; String.fromCharCode(1)` (proven red on the pre-fix binary, now `Property 'fromCharCode' does not exist on type 'int32'`). Cost is off the hot path by construction: the kind checks short-circuit first and the registry is consulted only for Function-kind objects, and `ExtensionRegistry` carries a `staticReceivers: string[]` distinct-name cache maintained in `registerExtension` (the sole `methods.push` site) — 5 entries instead of a 348-entry scan per member access. Lowering is untouched — `extensionMethodLower` keys off `NodeFlag.ExtStatic`, never on symbol kind. | **DIVERGE-INTENTIONAL** (TS surface: `BigIntConstructor` declares a call signature, `NumberConstructor`/`StringConstructor` declare call + construct — the JS primitive-wrapper globals are callable AND namespaces; Nim has no such shape and does not want one) | Closed set of names this buys: `String`, `Number`, `Boolean`, `BigInt`, `Symbol`, `Object`, `Array` — everything else in std (`Buffer`, `JSON`, `Promise`, `Map`, `Set`) is a namespace only and was already served by the kind-based gate. Soundness is name-keyed, NOT kind-keyed on purpose: adding `SymbolKind.Function` to the gate list would make `propType = inferredType()` for every `f.foo` on a closure and SWALLOW real errors — probed, `f.nope(1)` and `helper.missing(1)` still report `Property … does not exist on type 'function'` after the change. `SymbolKind.Parameter` excluded so a local cannot shadow a namespace name. Two sibling gates deliberately NOT widened: `callResolve:1355` is LSP symbol-kind mapping for an explicit type argument, `callResolve:2943` only fires when `resolvedObjType.kind === String` which a function symbol's type never is. std now declares both surfaces: `BigInt(v)`+`asIntN`/`asUintN` (index.cms via `from "msBigInt*"`, index.jms via `globalThis.BigInt`), `String(val)` moved into index.jms too (it was C-only — `String(42)` did not exist on the js target before this) + `fromCharCode` (C delegates to `msStringFromCodePoint` after a 16-bit mask, which matches JS across the whole code-unit range including lone surrogates — the runtime is WTF-8, pinned by the existing json test `fromCodePoint(55296)` → `\ud800`). `String.fromCodePoint` deliberately NOT added: the free function `fromCodePoint` has 5 live callers in std/serialize/json and converting it would break them. Verified C == JS == node on both families; corpus `744-namespaceCallSurface`. |



| Mechanism | Nim | MS | Verdict | Notes |
|---|---|---|---|---|
| **tyVar use → deref node** | every sem'd expression typed `tyVar/tyLent` is wrapped in `nkHiddenDeref` at the expression boundary (`semexprs.nim:62/132` semOperand/semExprWithType, `:1159` callee); `takeImplicitAddr` re-wraps `nkHiddenAddr` where var-ness is needed. injectdestructors therefore sees a LOCATION at every store through a var param and `moveOrCopy` applies `=sink`/`=copy`. **cgen does NOT add a second indirection for tyVar** (verified 2026-08-30): `ccgIntroducedPtr` (ccgutils.nim:79) handles only tyObject/tyTuple and falls to `else: result = false`, so `lfIndirect` is never set for a var param; its `*` comes from the TYPE (`mapType` ccgtypes.nim:259 `tyPtr,tyVar,tyLent,tyRef`→ctPtr, star at :1009). One pointer, one deref source. | WAS: the pointerParam pass was removed ("handled at codegen time") keeping only the cgen half (`indirectParams` + `(*name)` + `&arg` shim) — the analyzer saw a bare Var-typed identifier at assignment dests, `classifyType` has no Var arm → needsCleanup=false → raw assign: `(*s)=tmp; msStringDecref(tmp)` = ASan heap-UAF on every heap store through `out`/`ref` (corpus 741 pins it; DRC ledger BALANCES — destroy count right, schedule wrong — only the ASan lane catches it). NOW: `transform/native/varParamDeref.ms` (last in transformForNative, C-only; js keeps jsVarParamLower) wraps Var-param ident value-uses in HiddenDeref (raw in OutExpr operands + args bound to a Var formal); `inject.ms` processAssignment gained a HiddenDeref dest arm → `moveOrCopy` MOC_IS_FIELD; `genHiddenDeref` collapses `HiddenDeref(indirect-param ident)` to the ident's own `(*name)` (symmetric to the existing HiddenAddr collapse). Emitted C for `s = "w-"+n` through `out s`: `msStringSink((*s), $callRes); msStringWasMoved($callRes)`. | was DIVERGE-UNINTENTIONAL → now SAME (algorithm; transform-vs-sem placement is the eager-pass representation choice, same class as HiddenStdConv) | Stage A measured 2026-08-29: suite 3510, fixpoint 0/297, guards ALL GREEN, corpus parity 664/1 (015 pre-existing) + SAN 151/0. **Stage B shipped 2026-09-02** (worktree `/tmp/wt-stageB-l3v6`, base 57dc854; NOT yet re-verified on 7ac0cac — that HEAD is red from an unrelated in-flight change that consumes `TypeKind.BigInt`/`execFileCapture` before declaring them). The full alignment this row prescribed, as landed: (1) `ccgIntroducedPtr(Var)` early-returns **false** BEFORE `skipModifier` — dispatch on the kind like Nim's `else: false`; an early exit AFTER skipModifier would let struct-size promotion see through Var (big-struct hooks would stay indirect → `(*(*p))`). (2) The stage-A `genHiddenDeref` collapse is DELETED — with no Var params indirect, a HiddenDeref is always a real deref. (3) `shouldIndirectParam` early-exits false for Var — the struct-mutation branch (out params are mutated by definition) saw through `skipModifier` and re-indirected them. (4) `destructorLifting` builds deref'd accessors (`hookParamDeref` = `makeHiddenDeref∘makeIdent`) for every VALUE use of a hook param — `x1/x2`, union `_tag`/blob/variant bases, `emitTagCopy`, tuple hooks — the port of `liftdestructors.nim:1340` (`if firstParamType.kind == tyVar: newDeref`); FORWARDING args (variant-helper dispatch, user-hook dispatch) stay raw idents, stamped `nodeType=Var` so `varParamDeref` recognizes them — EXCEPT the trace callback (param 1, `Ptr<void>`): stamping it made the arg shim emit `&(callback)`, corrupting the ORC trace worklist (invalid free in `msCellSeqGrow`, deterministic abort in `NodeDataTrace` under any test file with ≥7 tests — root-caused by C-emit diff: only `std/meta/node.ms` differed, 220 lines of `&(callback)`). (5) Self-assign guards compare bare idents now (both Ref and Var hooks) — the old HiddenAddr relied on the `&(*p)` collapse that (2) removed. (6) `varParamDeref` gained `takeImplicitAddr` (the sem-time `nkHiddenAddr` port, placed in the eager pass): non-forwarding args of Var formals are wrapped in HiddenAddr at the transform; forwarding = Identifier whose `resolvedSym.symbolType` is Var, or (bootstrap bridge for synthetic idents) null sym AND null nodeType — checker-typed user idents always carry nodeType. (7) `isPointerInC` += `Var` (checker B1) and the member-access HiddenDeref it inserts is typed by ONE peel anchored on the SYMBOL's declared type — the object's nodeType differs between read sites (checker pre-peels Var) and write sites (still Var), and the old `derefNode.nodeType = resolvedObjType` (fully peeled) mis-typed `(*p)` for `Var<Ref<T>>` as `T` while it emits `T*`. (8) Member `.`/`->` selection re-derives pointer-ness from the HiddenDeref's own nodeType instead of forcing dot when the object was wrapped. **Measured after stage B**: 7-probe matrix × drc/orc + ASan all green (baseline: struct-field/interface-field checker errors, interface-read C member-ref error, struct-read C passing error, interface-whole SEGV); suite 174 files / 3510 tests rc=0; fixpoint gen8→gen9 **0/284** `.c` differ (the 403 cache diffs are `.o.cfp` compiler fingerprints — binary-hash noise, not semantic); guard suite ALL GREEN incl. 741 both lanes; corpus parity 672 pass / 1 fail (015, pre-existing) / 5 xfail; corpus SAN 152 pass / 0 fail / 1 xfail. Emit-preserving where already correct: `st_whole`/hook bodies byte-identical to pre-stage-B; `scalar` gains a `msStringDecref` scope-destroy at end of main (pre-stage-B the out-arg string LEAKED — the analyzer only sees the location through the HiddenDeref). BOOTSTRAP TRAP: the change cannot ship as one generation — gen-N compiled by a half-paired gen-(N-1) carries `&(self)`/`&(callback)` forwarding calls and crashes its own runtime hooks before it can compile anything; the working sequence was S1 (transform new + codegen old, guards still HiddenAddr) → B1 (runs, emit ≡ HEAD) → B2 (full source, hooks emitted by B1) → … → B7, with the callback-stamp fix costing two extra generations (B6 inherits B5's bad stamp in its own binary, B7 is clean). Residual, load-sensitive and NOT this change: `405-arcLockerSharedCounter` (pool-help + ticket lock) deadlocks under SAN when the machine is saturated — proven pre-existing by C-emit identical to HEAD in three build configurations (plain/SAN, installed-std/worktree-std) and 16/16 standalone passes; full SAN lane completes in ~5 min on an idle machine with BOTH old and new compilers. |
| **Implicit T → Maybe<T> coercion node shape** | `implicitConv` (sigmatch.nim:2232) wraps EVERY implicit arg coercion in a conv NODE (`nkHiddenStdConv`/`nkHiddenSubConv`); the representation is materialized downstream | `synthMaybeWrap` (checker/fit.ms:286) materializes the carrier `{ value, present }` ObjectLiteral (nodeType=Maybe, NodeFlag.Sem) directly at the CHECKER layer; the null branch retypes in place | DIVERGE-UNINTENTIONAL — minimal step applied 2026-09-02, full alignment OPEN | The carrier shape broke the macro-wire source-form invariant (bug107): `stripMacroArgWrappers` only knew Hidden* KINDS, so a fitted arg crossed the wire frozen → re-check re-wrapped it (C clang `_lit.value = <struct>`; JS SILENT wrong value) or mismatched its anon type (loud). Minimal return-to-Nim step: the wire unwraps the carrier by TYPE (`isMaybeType` — a user cannot stamp IsMaybe on a literal), `compiler/meta/bridge.ms`; corpus pin `751-macroArgMaybeFit.ms` red pre-fix both lanes. Full alignment = synthMaybeWrap emits HiddenStdConv + transform layer (optionalCoercion/nullableLower) materializes; that arc should also close row 46's "own ticket" sibling (arrow literal → `fn \| null` field miscompile — same carrier family). Found by neon variants (reactive selector through JSX). |



| Mechanism | Nim | MS | Verdict | Notes |
|---|---|---|---|---|
| **Subtype relation under a nullable carrier** | no direct analog — Nim has no anonymous unions, so there is no `Option[A]` → `Option[A or B]` question; the closest shape is `implicitConv` wrapping a subtype conversion in `nkHiddenSubConv` (sigmatch.nim:2232) and letting cgen materialize the target layout | MS had the BARE half only: `A` → `A \| B` converted through `widenVariantToUnion` (fit.ms) → `HiddenSubConv` + slot stamped in `flags >> 16`, emitted as `((U){._tag=vi, .vN=x})`. Under a Maybe carrier both sides are Struct, so `isAssignableInner`'s same-kind arm sent them to `isObjectAssignable`, which compares two different payload types and refuses — "memory layout differs", with a suggestion (`asMaybe_p34_… extension`) no user can act on. Fix mirrors the bare arm one level down: `maybePayloadWidenSlot` (types.ms) answers the slot ONCE for both the relation (compat.isAssignableInner, placed BEFORE the same-kind arm) and the conversion (fit.widenMaybePayload → same HiddenSubConv + stamp), and the C emitter rebuilds the carrier `{.value=(U){._tag=vi,.vN=t.value}, .present=t.present}` off a temp | **DIVERGE-UNINTENTIONAL vs TS** (no Nim reference; TS makes `string \| null` a subtype of `number \| string \| null`, and MS already agreed for the bare pair — one arm of the same subtyping was simply missing) | The slot lookup lives in ONE function on purpose: a relation that accepts a widening the emitter cannot tag is a silent reinterpret, and the two sites are 2 files apart. `primitiveMemberIndexInUnion`/`variantIndexInUnion` moved fit.ms → types.ms for that (compat.ms cannot import fit.ms — fit imports compat). Call ARGS never reach fitNode (callResolve.ms owns that site, same reason synthMaybeWrap is duplicated there), so the conversion is applied at both sites. Absent carrier takes a zeroed union rather than injecting a garbage payload — refcounting would otherwise get a tagged slot to free. Union → wider union is refused (no single slot to stamp). Corpus `752-maybePayloadWiden.ms` (heap string, so RC sees a real payload), red pre-fix on both lanes. Found by neon `styleToCss`: 21 errors passing `string \| null` / `number \| null` fields to one `StyleValue` emitter. |


## Windows dispatch parity + bootstrap/env paths (2026-08-31, Windows-native session - SHIPPED)

| Mechanism | Nim | MS | Verdict | Notes |
|---|---|---|---|---|
| **I/O poll goes non-blocking when work already completed this tick** | `adjustTimeout` (`lib/pure/asyncdispatch.nim:289-299`) returns `0` when `p.callbacks.len != 0` - comment: "Do not let an expired timeout overtake completion callbacks which are already pending". The selector poll (POSIX `runOnce`, :1423) receives that 0. | `msAdjustTimeout` (`runtime/promise/dispatchFull.c`) already had the callbacks clause (SAME), and the POSIX selector poll additionally passes `didWork ? 0 : adj` (:652) - `didWork` widens the signal to the actor-poll hook (Step 1b), which completes futures the way Nim's callbacks deque does. The Windows IOCP branch had NO such clause: `GetQueuedCompletionStatusEx` always received the full `adj` (5 ms -> ~15.6 ms at default timer resolution), so a poll-style `msWaitFor` paid the whole timeout AFTER its future resolved in Step 1b. FIXED 2026-08-31: `waitMs = didWork ? 0 : (adj >= 0 ? adj : 500)` - one line, POSIX-parity. | **SAME** (Nim's adjustTimeout principle); the `didWork` signal itself is a narrow DIVERGE-INTENTIONAL (Nim has no actor mailbox hook; MS-POSIX had already chosen this widening) | Measured: a 100k-iteration actor-CALL loop went from ~26 min (looked like a deadlock; the "Windows actor hang" of the 2026-08-30/31 campaign) to **0.15 s**; 20k loop 316 s -> 0.08 s. Corpus 40-lane 39/39 (409 all three lanes green, was cell-timeout), 72-lane 40/40. Root-cause trail: stderr-buffering red herring, mini-debugger BP on `NtRemoveIoCompletionEx` proved the timeout was always the correct -50000, a memory-ring + watchdog probe proved the loop never stalled - every symptom was a 15.6 ms-per-iteration perf collapse, not a deadlock. Residual known-perf-gap (NOT a correctness issue): interleaved CALL+await-spawn loops still cost ~0.3 ms/iteration from Windows worker-wake churn (submit signals an idle worker, the caller's help-first almost always wins the dequeue, the worker wakes/steal-scans/sleeps on a core); POSIX hides this behind cheap futex wakes. Deferred optimization. |
| **Bootstrap fixed-point check** | `koch boot` (`koch.nim:354-414`): build repeatedly, each iteration with the previous generation binary; `sameFileContent(output, i.thVersion)` -> "executables are equal: SUCCESS!", early return. The not-equal warning is `when not defined(windows)` - **Nim itself skips the binary-identity gate on Windows** (PE timestamps make it unreproducible). | gen2->gen3: same repeated-build procedure (seed gen2 -> gen3 -> gen4...). On Windows, per Nim's own gating, the check runs on **emitted C** rather than binary bytes. | **SAME** procedure | Full suite through gen3: 174 files / 3510 tests green (one pre-existing Windows-only red closed en route - see the CRLF row below). |
| **Home/config dir + temp dir resolution** | `getHomeDir` (`lib/std/private/osappdirs.nim:25-26`): Windows -> `USERPROFILE`, POSIX -> `HOME`. `getTempDir` (:132-134): Windows `getEnvImpl(["TMP","TEMP","USERPROFILE"])`, POSIX `["TMPDIR","TEMP","TMP","TEMPDIR"]`. | `cacheRoot()`/`credentialsPath()` (`src/compiler/package/`) were HOME-only - empty on Windows (5 of 6 HOME readers already had the fallback; these two were the outliers). Fixed to HOME->USERPROFILE. Package tests wrote to hardcoded `/tmp` - now an env-based `TMP->TEMP->TMPDIR->"/tmp"` helper (NOT `std/os.tmpDir()`: importing it drags `runtime/os.h`'s @compile into test TUs). | **SAME** in spirit; MS is one notch wider than Nim (honors `HOME` on Windows if the user set it - Git-bash workflows), and the temp order unions Nim's two platform lists | `msc test` of the package files went from fail (empty cache root, unwritable `/tmp`) to 921/921 + 388/388. |
| **CRLF in source-scanning tests** | n/a (Nim's lexer accepts CR-LF as a line ending by spec) | `src/ast/childTableGuard.ms`'s local `trim` cut only space/tab/newline - on a CRLF Windows checkout every extracted field name kept a `\r\n\t` prefix, `tableMentions` never matched, and all 6 child tables "failed" spuriously (the field printed as invisible `\r\n\ttypExprMembers`). One `\r` added to both trim loops. | MS defect, **CLOSED** (no Nim analogue needed) | Proven by decoding the failing field's bytes (`13 10 9 116 121 112...`). Guard file now green 349/349 on CRLF checkouts; unchanged on LF. |
| **Bootstrap cache hygiene (the gen-4 stale-`.o` trap)** | `koch boot` keys `smartNimcache` per mode but Nim's fingerprint includes the module's source hash + flags; a changed compiler with unchanged inputs still recompiles because the bootstrap iterations run from a fresh-enough cache. | MS's `fullCompileCmd(ccOption, mode, flags)` compile-cache key does NOT include the compiler binary identity nor the emitted-C content hash. Proven 2026-08-31: gen-3 produced gen-4 twice - once against a warm cache (linking pre-existing `.o` compiled from an OLDER emission) and once after wiping `.o` - and only the wiped build behaved correctly (`shellUnquote` arg-quoting probe: `-DX=<v>` vs `-DX="<v>"`; the warm-cache binary could not even build `runtime/crypto/tls.c`). Two consequences: (a) a self-host chain MUST wipe `.o` (or key fp on emission content) between generations; (b) two msc processes sharing `out/{debug,release}/.cache` (e.g. parallel sessions on one machine) cross-contaminate generations. | **DIVERGE-GAP (cache key)** — fixpoint procedure documented, key fix pending | Fixpoint achieved after wiping: gen3-emission vs gen4c-emission = 300/300 modules byte-identical; the single delta (usage.ms `VERSION` 0.2.50 to 0.2.51) traces to a concurrent session's working-tree bump, not to codegen. gen5 (built by gen4c, wiped cache) passes the TLS build that stale gen-4 could not. Candidate fix (separate task): fold a content hash of the emitted `.c` into the `.o` cache key so a new compiler generation can never link an old emission's objects. |

## Symbol identity: declaration chain vs multimap scope (2026-09-03, prelude `Map.set` red - SHIPPED `bacbdab6`)

| Mechanism | Nim | MS | Verdict | Notes |
|---|---|---|---|---|
| **Scope storage for an overloaded name** | The scope is a MULTIMAP. `addOverloadableSymAt` (`lookups.nim:438-449`) calls `scope.addSym(fn)` for every declaration and only checks redefinition when the kind is NOT in `OverloadableSyms`; several symbols therefore sit under one name. Readers walk all of them with `initIdentIter`/`nextIdentIter` (`astalgo.nim:537-561`) - `initCandidateSymbols` (`semcall.nim:40`) and `searchForProcAux` (`procfind.nim`) both go through that iterator. There is no primary symbol and no overload list. | The scope is `Map<name, Symbol>` with FIRST-INSERTION-WINS (`addSymbolToScope`, `symbol.ms:178`); a second declaration of the name attaches to the winner via `existing.overloads.push(sym)` (`defineSymbol`, `symbol.ms:206`). This is the TypeScript model - one Symbol owning many declarations, one type carrying many call signatures - not a lossy port of the multimap. | **DIVERGE-INTENTIONAL** (TypeScript identity) | Kept deliberately, and not only on taste: the cross-module wire format is ALREADY chain-shaped - an exported symbol is one primary plus the parallel arrays `overloadTypes[] / overloadExtReceiverTypes[] / overloadDeclNodes[]` (`collectPass.ms:745-772`) - so moving the scope to a multimap would force a rewrite of the ExportRegistry, import propagation, monomorphize and LSP symbol recording for zero semantic gain. **Load-bearing consequence: any operation defined on "a symbol" is defined on its ENTIRE chain.** Nim needs no such rule because it has no chain. The next operation of this shape (a future `ensureChecked`, a serializer, a visitor) must drain the chain the same way. |
| **When a declaration acquires its type** | EAGER, driven by the declaration NODE. `semProcAux` (`semstmts.nim:2432`) works on the proc-def node: `semIdentDef` mints the symbol for THIS declaration (:2458), `semParamList` types it on the spot (:2493 - comment: "This is often the entirety of their semantic analysis"), and only afterwards is it added to the scope (:2554-2558). No lookup by name is ever involved. This is legal because Nim requires declare-before-use, with forward declarations reconciled by `searchForProc`. | DEMAND-DRIVEN, driven by NAME. `ensureShaped` (`resolvePass.ms:869`) types a symbol when a consumer first needs it; `resolveDeclarations` drives it by name. Forced by the language, not chosen: MS permits use-before-declaration (TypeScript ordering), so a signature may reference a type declared further down and cannot be typed eagerly at its own declaration site. Under the chain model, shaping BY NAME is the CORRECT spelling - the name is the symbol, the chain is its declarations. | **DIVERGE-INTENTIONAL** (falls out of TypeScript ordering freedom plus the chain model) | Neither a defect nor a gap: it is the only mechanism compatible with the two decisions above. A "shape by `node.resolvedSym` instead of by name" variant was evaluated and REJECTED - it restates no invariant, and `collectPass.ms` stamps `resolvedSym` at only 4 sites (:147/:246/:283/:454), so it would need a by-name fallback regardless. |
| **Invariant: every candidate entering overload scoring already carries a type** | Free of charge. `initCandidate` reads `callee.typ` directly (`sigmatch.nim:251`) because eager sem guarantees the type exists before any call site can see the symbol. | Must be actively maintained. `resolveOverloadCall` builds `[sym, ...sym.overloads]` and reads `cs.symbolType` raw, shaping nothing per candidate (`callResolve.ms:2001-2004`); extension matching reads `getExtFnType(ext)` inside `isReceiverMatch` and rejects on `kind !== Function` (`context.ms:645`). A Hollow member of the chain is therefore scored against `noneType` - silently, as a non-match. | **SAME** invariant, different mechanism | The invariant used to be maintained at the ENTRY POINT ("shape this name") but not over the STRUCTURE ("a symbol is its whole chain"), and the two disagree precisely when the chain grows AFTER the entry point has run. Observed red: the prelude gives 15 modules one shared scope, so `std/core/buffer` won the primary for `set` and `std/core/struct`'s `set@214`/`set@571` landed on an already-Shaped primary, hit the `ensureShaped` early-return (`resolvePass.ms:870`) and stayed Hollow - producing 4 silent `Property 'set' does not exist on type 'Map'` errors inside `buildPreludeContext`. Fix `bacbdab6`: `drainOverloads` (`resolvePass.ms:926`) is now called from BOTH the early-return (:880) and the normal exit (:921) - shaping a symbol means shaping its chain. The very same invariant was already hand-written once at `checkPass.ms:2294-2296`, which is evidence it is a law of the system that had merely been stated in the wrong place. |
| **Extension symbols that live outside any scope** | n/a - every routine symbol lives in a scope table. | Closed enumeration (verified 2026-09-03): only 8 sites mint a NEW symbol into the extension registry, all in `collectPass.ms` (:250, :462, :770, :808, :820, :915, :991, :1004). Every other `registerExtension` call - `checkPass.ms:2419/2454/2535`, `preludePack.ms:1168`, `orchestrator.ms:129` - re-registers an ExtensionMethod that already exists and reuses its `sym`; `src/monomorphize/` calls it nowhere. Of the 8, exactly ONE (:250, the local-declaration path) contributes an untyped symbol, and that symbol is always in the scope chain. The others are minted already-typed from the ExportRegistry, and the two that belong to no scope at all (`autoPropagateModuleExtensions`, :991/:1004) are stamped `SymbolState.Shaped` explicitly (:989/:1001). | **MS-ONLY** (no Nim analogue), invariant holds | Hence the guarantee **"no registry symbol is both outside the chain and untyped"**, and hence a proposed patch to `ensureShaped` each extension candidate before `isReceiverMatch` was REJECTED: it closes a hole that does not exist, at the price of work on a hot matching path plus error-ordering risk. Two traps worth knowing when reading this code: (a) `createExtMethod` (`context.ms:399`) NULLS the `fnType` argument whenever `sym` is non-null, so the type passed at a registration site is decorative - only `sym.symbolType` is ever read, through `getExtFnType` (`context.ms:528`); (b) `preludePack` SERIALIZES symbol state, so an invariant violation present when the pack is written is baked into every subsequent load - the chain must be complete BEFORE the pack is emitted. |

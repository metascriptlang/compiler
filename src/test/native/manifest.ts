// Native-execution test manifest.
//
// Each case is a real .ms program under programs/ that gets compiled to a
// NATIVE binary and run under both --gc=drc and --gc=orc. The runner
// (bun/test-native.ts) asserts exit 0 (no over-free/crash) and peak RSS under
// maxRssMb (no leak).
//
// To add a case: drop a self-contained program in programs/, add an entry
// here. Pick maxRssMb generously above the program's honest steady-state — the
// bound exists to catch UNBOUNDED growth (a leak doubles RSS into hundreds of
// MB), not to police a few MB of jitter.
//
// xfail: list the gc modes a case is CURRENTLY EXPECTED TO FAIL under (an open
// bug). The runner reports XFAIL (not a suite failure) and flags XPASS when it
// starts passing — that's the signal to flip the entry off once fixed.

export interface NativeCase {
	name: string;
	file: string;
	maxRssMb: number;
	// If set, the program's stdout must contain this marker — catches
	// correctness bugs that exit 0 with low RSS (wrong output, not a leak/crash).
	expectStdout?: string;
	// If set, the program must exit with this code (default 0). Lets a case assert
	// a deliberate fail-loud path (e.g. msMapFatal's exit 2) instead of a clean run.
	expectExit?: number;
	xfail?: ("drc" | "orc")[];
	note?: string;
}

export const CASES: NativeCase[] = [
	{
		name: "clean-loop",
		file: "cleanLoop.ms",
		maxRssMb: 30,
		expectStdout: "clean-loop acc=",
		note: "Real program: 3M-iteration string/array work that must stay flat. The always-green control — if this leaks, the harness or a core RC path regressed.",
	},
	{
		name: "closure-array",
		file: "closureArray.ms",
		maxRssMb: 30,
		expectStdout: "closure-array acc=",
		note: "bug033 native repro: array of closures freed at scope exit. Was a misaligned-access crash; runs through C DRC here (test-ms ran it on Bun and never touched the crash path).",
	},
	{
		name: "ref-array-share",
		file: "refArrayShare.ms",
		maxRssMb: 30,
		expectStdout: "ref-array acc=13500000",
		note: "Ref<Array<T>> reference semantics (Phase 3 array migration): share-on-assign, mutate-through (direct/param/closure capture), length/index, string-element arrays. Refcounted box via msAllocTyped + per-element-type cell TypeInfo. Flat RSS proves the box frees its payload + the cell once.",
	},
	{
		name: "ref-array-struct-elem",
		file: "refArrayStructElem.ms",
		maxRssMb: 30,
		expectStdout: "ref-array-struct-elem done",
		note: "Reference-array T[] of value-struct + generic-instance elements with owned heap fields: the boxed cell's destroyFn must run the per-type <Name>ArrayDestroy walker (per-element decref), not a free-only buffer wipe. destructorLifting's comprehensive walk now registers array element hooks for expression-position arrays too, so the walker is emitted. Regression for the ~617MB leak the prior number[]/string[]/interface-element tests missed.",
	},
	{
		name: "paralock-nested",
		file: "paralockNested.ms",
		maxRssMb: 80,
		expectStdout: "paralock-nested check=",
		note: "PARALOCK guard: spawn + actor + async crossed, 20k-iteration massive interleave on the shared worker pool. Standing answer to 'did my change break PARALOCK seamlessly?'. The final marker only prints if the actor tag round-trips. Higher RSS bound — concurrency runtime has a larger steady-state baseline (pool threads + mailboxes).",
	},
	{
		name: "actor-heapstr",
		file: "actorHeapStr.ms",
		maxRssMb: 30,
		expectStdout: "PASS:actor-heapstr",
		note: "FIXED (analyzer inject.ms: msMsgComplete* added to the sink-position list). A heap string returned from an actor CALL read back corrupted: the dispatch builds `const _result = getter(); msMsgComplete<T>(replyFut, _result);` and msMsgComplete* ESCAPES the value into the reply future (read later cross-thread by the awaiter). The analyzer hardcoded only msFutureCompleteT as a sink position, so the actor-reply completion value arg was treated as a non-consuming borrow: it passed _result raw AND destroyed _result at dispatch scope-exit → the future pointed at a freed buffer → UAF (emit-C: `msMsgCompleteString(fut, _result); ... msStringDecref(_result);`). Marking msMsgComplete*'s value arg (index 1) DrcMode.Consumed — the exact mechanism msFutureCompleteT already uses — makes the analyzer give the future its OWN owned value (copied into an escaping sink temp for the finally-protected local) and keep _result for its own cleanup (emit-C: `msStringCopy(&borrow, _result); msMsgCompleteString(fut, borrow); ... msStringDecref(_result);`). Same boundary-by-copy convention as actor args (msMsgSetString/msStringNew) and struct returns (msSinkBoxStruct memcpy+memset). Pony shares val cross-actor via ORCA refcount; MS copies sole-owner data across instead. Root proven by A/B emit-C probe: without the fix → raw pass + decref → `FAIL tag=[garbage]`; with the fix → copy-to-sink + decref → PASS.",
	},
	{
		name: "leak-call-in-cond",
		file: "leakCallInCond.ms",
		maxRssMb: 40,
		expectStdout: "leak-call-in-cond hits=",
		note: "FIXED by the Phase-3 call-hoist pass (transform/lowering/callHoist.ms): a fresh Result-returning call used only for a non-RC read (`const has = provide(p).ok`) is hoisted to `const $t = provide(p); const has = $t.ok` so the analyzer destroys $t at scope exit. Permanent regression guard — was 278MB leaking, now flat.",
	},
	{
		name: "leak-loop-cond",
		file: "leakLoopCond.ms",
		maxRssMb: 40,
		expectStdout: "leak-loop-cond i=",
		note: "FIXED by callHoist b3a: a fresh RC call in a LOOP condition (`while (provide(i).ok)`) re-evaluates every iteration, so a preceding hoist would be wrong. Lowered to `while (true) { const $t = provide(i); if (!($t.ok)) break; BODY }` so the per-iteration Result is destroyed at each iteration's scope exit. Permanent regression guard — was 339MB leaking, now flat.",
	},
	{
		name: "leak-short-circuit",
		file: "leakShortCircuit.ms",
		maxRssMb: 40,
		expectStdout: "leak-short-circuit hits=",
		note: "FIXED by callHoist b3b: a fresh RC call in a SHORT-CIRCUIT operand (`if (a && provide(i).ok)`) runs only when `a` holds, so it can't be hoisted eagerly. Lowered to a flag + nested-if (what Nim does for `and`/`or`) so the fresh Result is captured + destroyed only on the branch that reaches it. Permanent regression guard — was 339MB leaking, now flat.",
	},
	{
		name: "leak-elseif-cond",
		file: "leakElseIfCond.ms",
		maxRssMb: 40,
		expectStdout: "leak-elseif-cond hits=",
		note: "FIXED by callHoist (b3 audit): a fresh RC call in an `else if` condition (`else if (provide(i).ok)`) leaked — an else-if is the `.alternate` of its parent IfStmt, never a statement-list entry, so expandStmt never reached its condition. Fix wraps a fresh-cond else-if in a block so the walker descends and lowers it (cascading down the chain). Permanent regression guard — was 277MB leaking, now flat.",
	},
	{
		name: "leak-ternary-cond",
		file: "leakTernaryCond.ms",
		maxRssMb: 40,
		expectStdout: "leak-ternary-cond hits=",
		note: "FIXED by callHoist lowerTernary: a fresh RC call in a ternary BRANCH (`c ? provide(i).ok : false`) is evaluated only when that branch runs, so it can't be hoisted eagerly. Lowered to a result temp + if/else (each branch its own scope). Permanent regression guard — was 277MB leaking, now flat.",
	},
	{
		name: "leak-vardecl-sc",
		file: "leakVardeclSc.ms",
		maxRssMb: 40,
		expectStdout: "leak-vardecl-sc hits=",
		note: "FIXED by callHoist: a fresh RC call in a short-circuit operand of a VARDECL initializer (`const x = a && provide(i).ok`) leaked — the vardecl path used to skip conditional-eval initializers. Fix routes vardecl/assign initializers through lowerBoolCond (same flag/nested-if as if-cond). Permanent regression guard — was 277MB leaking, now flat.",
	},
	{
		name: "array-literal-strings",
		file: "arrayLiteralStrings.ms",
		maxRssMb: 40,
		expectStdout: "array-literal-strings acc=",
		note: "FIXED in runtime/core/array.c: msStringArrayFromArr deep-copied each element, allocating a redundant 2nd buffer and orphaning the analyzer's already-owned element (the analyzer copies aliased + moves last-read upstream, then assumes FromArr moves). Changed FromArr to MOVE (take the handle as-is), mirroring msGenericArrayPush (ref arrays) and Nim's sink. Permanent regression guard — was 177MB leaking, now flat.",
	},
	{
		name: "leak-callarg-object",
		file: "leakCallArgObject.ms",
		maxRssMb: 40,
		expectStdout: "leak-callarg-object acc=",
		note: "FIXED by the analyzer (inject.ms processObjectLiteral self-capture in Normal mode = Nim p()+ensureDestruction, injectdestructors.nim:889). A fresh interface object literal passed inline as a non-sink call argument, stored by the callee, leaked (value stuck at rc=1: callee increfs a fresh rc=0 value, caller never owned/destroyed it). processObjectLiteral processed the literal's FIELDS but never ensureDestruction'd the literal ITSELF; now it does in Normal mode (Consumed/SinkArg positions — binding RHS, sink param, ref field, return — skip it, so no double-free). The Phase-3 callHoist hoist could NOT fix this (never reached call args; crashed escape-heavy code) — this needed the Phase-4 analyzer. Was 431MB @ 2M, now flat ~2MB drc+orc. Paired with leak-callarg-escape (the multi-alias escape discriminator). See docs/NIM-REF.md §3.",
	},
	{
		name: "leak-callarg-escape",
		file: "leakCallArgEscape.ms",
		maxRssMb: 40,
		expectStdout: "leak-callarg-escape acc=",
		note: "FIXED with leak-callarg-object (inject.ms processObjectLiteral self-capture). Escape-heavy variant: a fresh interface object literal passed inline as a call arg is stored by the callee into a returned Box, then pushed into a persistent hub.subs list drained every 8 iters — so the value OUTLIVES the statement that created it (the multi-alias broadcast shape the Phase-3 callHoist hoist crashed on with over-free/SIGSEGV). This case is the PERMANENT discriminator proving the Phase-4 fix is over-free-SAFE on escaping values: the push-incref keeps the value alive until drain frees it, so the caller's scope-exit destroy of the captured temp is one balanced decref — NOT a premature free. Was 370MB @ 2M, now flat ~2MB drc+orc. If this ever SIGSEGVs, a fix made the literal capture too eager (destroying a value still aliased downstream).",
	},
	{
		name: "leak-arraylit-callarg",
		file: "leakArrayLitCallArg.ms",
		maxRssMb: 40,
		expectStdout: "leak-arraylit-callarg acc=",
		note: "FIXED by inject.ms processArrayLiteral (the ArrayLiteral sibling of leak-callarg-object). A fresh array literal passed inline as a non-sink call arg the callee stores leaked the array SHELL (rc=0 stuck) — MS arrays are reference types (heap), so a fresh array literal is an owned heap value, unlike Nim's value-type bracket (which is why it was wrongly skipped at first; 124MB @ 2M, found by post-fix coverage probing). RC string ELEMENTS also make it an over-free guard: the fix sinks elements into the array (owned) AND captures the shell in Normal mode, so the shell's destroy is balanced — a shell-only fix would over-free the borrowed elements (SIGSEGV). Discriminates correct-fix (flat) from no-fix (LEAK) and naive-shell-only (SIGSEGV). Now flat ~2MB drc+orc. Nim 889 adapted.",
	},
	{
		name: "leak-new-callarg",
		file: "leakNewCallArg.ms",
		maxRssMb: 40,
		expectStdout: "leak-new-callarg acc=",
		note: "FIXED by inject.ms processNew (the NewExpr sibling of leak-callarg-object). A fresh `new T(...)` passed inline as a non-sink call arg the callee stores leaked (rc=0 stuck) — processNew captured the constructor ARGS but never the `new` RESULT. Was 124MB @ 2M (found by post-fix coverage probing). processNew now ensureDestructions the result in Normal mode (mirrors processObjectLiteral; the ctor owns the object's fields so destroy is balanced). Now flat ~2MB drc+orc. Nim 889.",
	},
	{
		name: "leak-closure-callarg",
		file: "leakClosureCallArg.ms",
		maxRssMb: 40,
		expectStdout: "leak-closure-callarg acc=",
		note: "FIXED (the 5th fresh-owned producer). A closure capturing a local (heap env) passed inline as a non-sink call arg the callee stores leaked the captured env (247MB @ 2M, found by coverage probing). Root, traced by emit-C: the lifted closure-pair (an NF_CLOSURE ObjectLiteral) carried no nodeType, so ensureDestructionIfNeeded bailed on null and never captured it. The 3-part fix: (1) lambdaLifting sets the closure-pair's nodeType (originalNodeType) so the analyzer can classify it; (2) classify.ms TypeKind.Function → needsCleanup=true so it captures + destroys; (3) processObjectLiteral keeps NF_CLOSURE pairs isRefConstr so the env field stays a COPY (incref) — without this, setting nodeType=Function flips the env field to a borrow (no incref) and the pair's msClosureDestroy double-frees the env against the env-var's own lifecycle (the over-free a naive 1-line flip caused, caught here + by paralock-nested). Now flat ~2MB drc+orc; paralock-nested (concurrency closures) green; self-host (heavy closure use) exit 0.",
	},
	{
		name: "leak-ref-member-read",
		file: "leakRefMemberRead.ms",
		maxRssMb: 40,
		expectStdout: "leak-ref-member-read done",
		note: "FIXED by the analyzer HiddenDeref capture fix (inject.ms processNode HiddenDeref|HiddenAddr recursion). A fresh interface (heap Ref) returned and only a non-RC field read, with the call otherwise discarded, leaks ~555MB pre-fix: the member object lowers to HiddenDeref(call), and processNode's hand-written dispatch had no wrapper case (`_ => node`) so the walk stopped before the fresh call → ensureDestruction never captured it. A bare member-access ExprStmt is NOT covered by callHoist (not an assignment/vardecl/if/while), so ONLY the analyzer fix makes it flat. The Result-shaped leak-call-in-cond guard missed this class (Result uses sret, not a HiddenDeref pointer). Permanent regression guard — was 555MB leaking, now flat.",
	},
	{
		name: "leak-discarded-future",
		file: "leakDiscardedFuture.ms",
		maxRssMb: 40,
		expectStdout: "leak-discarded-future done",
		note: "Guards the FLAG-SCOPE of the analyzer's awaitable skip (inject.ms skipAwaitableCapture). A discarded fire-and-forget async future is owned by the caller and must be captured+destroyed by the ordinary discarded-call path; the awaitable skip is scoped to non-RC binding/condition walks ONLY, so it must NOT suppress this. If the skip regresses to global (skip every future in ensureDestructionIfNeeded), each discarded future leaks ~188B/iter (was 94MB at 500k during the global-guard misstep, now flat). Complements paralock-nested, which guards the opposite side (awaited stepper futures must NOT be re-captured).",
	},
	{
		name: "leak-async-await-loop",
		file: "leakAsyncAwaitLoop.ms",
		maxRssMb: 40,
		expectStdout: "leak-async-await-loop r=",
		note: "FIXED in C codegen (genWhileStmt/genDoWhileStmt): loops never called pushBlock(p, true), so genBreak/genContinue found no isLoop block and emitted a bare break/continue that SKIPPED pending finally — leaking every DRC temp whose cleanup lived in a finally between the jump and the loop boundary, AND violating the try/finally contract (finally didn't run on break/continue). Root cause of the Photon WS broadcast leak: the async stepper's fast-path `if (finished) continue` skipped the per-iteration temp decref. Was the general bug; manifested here as ~32 B/iter (2M → 64MB), now flat ~2MB. Restores Nim parity (ccgstmts startBlockWith + isLoop=true). Permanent regression guard.",
	},
	{
		name: "leak-map-drop",
		file: "leakMapDrop.ms",
		maxRssMb: 40,
		expectStdout: "leak-map-drop acc=",
		note: "FIXED by destructorLifting shouldEmitTypeInfo for mono'd heap classes: a Map<K,V> dropped at scope exit did not free its entries — the mono Map__string_string never ran emitFullTypeInfo (only processDecl does, and a mono has no declaration) so TypeInfo.destroyFn stayed NULL and msDecref skipped the recursive entry free. The mono gate excludes `$`-prefixed synthetic env structs (forcing their TypeInfo in a consumer module breaks the self-host binary compile — they aren't forward-declared there). Nim parity: liftdestructors wires the destructor slot per-instantiation. Was 477MB @ 50k×50 fill+drop, now flat ~2MB drc+orc. Caught NOTHING in test-ms/probes; only the full self-host binary build exposed the cross-module compile cascade — this guard pairs with that build as the gate.",
	},
	{
		name: "hashset-enlarge-keep",
		file: "hashSetEnlargeKeep.ms",
		maxRssMb: 40,
		expectStdout: "hashset-enlarge-keep ok n=5000",
		note: "FIXED in std/core/struct.ms hashSetEnlarge: the rehash loop wrote through the LOCAL `newData` after `s.data = newData` — under the C backend's value-array field-assign (deep copy) the rehash filled a dead local and every enlarge silently EMPTIED the live table. Correctness guard, not a leak guard: the marker only prints if all 5000 keys survive every enlarge and size is honest. Bun runs JS reference arrays where the alias forms, so test-ms is structurally blind to this family. Nim parity: tables.nim enlarge swaps then writes through t.data[j].",
	},
	{
		name: "leak-hashmap-enlarge",
		file: "leakHashMapEnlarge.ms",
		maxRssMb: 40,
		expectStdout: "leak-hashmap-enlarge acc=",
		note: "FIXED by classifyArray reading the instantiated body's hasAsgn + mono-TypeInfo wiring. hashMapEnlarge swaps the slot array (const old = m.data; m.data = newData; migrate), orphaning the old HashMapEntry__K_V[]. classifyArray decided RC from the abstract base (Entry<K,V>, K/V unbound → hasAsgn false) not the instantiated body (Entry__string → true), so the array of a mono'd generic struct misclassified non-RC → no per-element destroy on field-reassign; AND the mono HashMap__K_V TypeInfo.destroyFn was NULL (see leak-map-drop) so dropping never recursed. Nim parity: tfHasAsgn set per-instantiation. Was 574MB @ 50k×50 fill(+enlarge)+drop, now flat ~2MB drc+orc.",
	},
	{
		name: "ref-array-self-consume",
		file: "refArraySelfConsume.ms",
		maxRssMb: 30,
		expectStdout: "ref-array-self-consume n=",
		note: "FIXED in inject.ms processAssignment + scope.ms (varMovedInContext/clearMoveInContext). `x = f([..., x])` — a borrowed value sunk into an array literal in the RHS while the holder is reassigned (matchLower's armBody = makeBlock([setMatched, armBody]) shape). The analyzer cleared the pending wasMoved yet still ran save-assign-destroy → double-free / UAF (ASAN-confirmed in buildSwitchDispatch; the self-host gen-2 crashed on it). Fix skips destroy-old (MOC_IS_DECL) + clears the stale move when the LHS var is consumed INSIDE this RHS, gated by a movedBeforeRhs snapshot so a prior conditional move (e.g. `return x` in a sibling branch — the findProjectRoot regression) is not mistaken for consumption. Nim parity: injectdestructors eqwasMoved-then-eqsink no-op. Invisible to test-ms (Bun JS-GC); only the native binary + ASAN exposed it.",
	},
	{
		name: "ref-array-nested-vec",
		file: "refArrayNestedVec.ms",
		maxRssMb: 30,
		expectStdout: "ref-array-nested-vec done",
		note: "FIXED (Array->Ref migration tail): nested value array Vec<T>[] — a reference array whose elements are VALUE arrays — leaked because the box cell's destroyFn fell to the free-only msNumberArrayDestroy fallback (no per-element recursion into each inner array). 3 coordinated fixes: (1) checker arrayElementNeedsCleanup Array→true so the box-site selects arrCType+\"Destroy\" (the per-type msXxxArrayArrayDestroy walker); (2) the C type name comes from a SINGLE source — arrayCTypeName (codegen/c/types.ms) — that both genArrayType (codegen) and destructorLifting registerSeqElement (transform) route through, so the walker name can never drift from the box-site reference for ANY element kind (string/number/struct/enum/tuple); proven zero-divergence vs the legacy inline rule across the full self-host; (3) codegen forward.ms isDrcLifecycleName treats a base ending \"ArrayArray\" as a generated hook (emit body + forward proto) — the ms-prefixed nested name no longer collides with the runtime single-level helpers (msArray/msNumberArray/…). Walker body loops calling the inner destroyer (fillBody recurses), matching the reference seq[seq[T]] per-type destructor chain (twin-probe verified). Covers string/number/struct/enum/tuple inner. Was 7.5GB @ 200k for Vec<string>[], now flat ~2.6MB drc+orc. Invisible to test-ms (Bun JS-GC); the leak path is the C RefCell TypeInfo.destroyFn.",
	},
	{
		name: "actor-churn-heapstate",
		file: "actorChurnHeapState.ms",
		maxRssMb: 40,
		expectStdout: "actor-churn-heapstate done",
		note: "FIXED: actor create+stop churn leaked a->state (and its heap string) on every teardown. The actor handle is DRC-exempt (classify.ms: actors are runtime-managed), the spawn-time msIncRef exists only so the cycle detector sees rc>0, and the with-ctor `new` path passed null objType to ensureTypeInfoDef so the state type's TypeInfo.destroyFn was never wired (HeavyDestroy existed but unreferenced). Two coordinated fixes: (1) codegen expressions.ms NewExpr with-ctor branch passes the inner struct type (symmetry with the no-ctor branch) so ensureTypeInfoDef wires destroyFn; (2) runtime msActorDestroyWithReason frees a->state via that destroyFn after onTerminate (Pony: actor heap dies with the actor) — unconditional since the exempt handle and cycle-detector incref mean the actor is the sole owner. Was 1.07GB @ 200k (heap-string state), now ~8MB drc+orc. Invisible to test-ms (Bun JS-GC) — only the native binary runs msActorDestroyWithReason; no prior native case churned actor create+destroy.",
	},
	{
		name: "actor-churn-noctor",
		file: "actorChurnNoCtorState.ms",
		maxRssMb: 40,
		expectStdout: "actor-churn-noctor done",
		note: "FIXED (companion to actor-churn-heapstate): the NO-constructor actor teardown path is a distinct codegen branch (Ref-with-field-defaults, expressions.ms ~983) from the with-ctor one. State has a heap number[] field; the no-ctor branch already passed innerType so destroyFn is wired, and runtime msActorDestroyWithReason frees the state — without it the array leaked per teardown. Pins the no-ctor branch against drift.",
	},
	{
		name: "tuple-array-leak",
		file: "tupleArrayLeak.ms",
		maxRssMb: 40,
		expectStdout: "tuple-array done",
		note: "FIXED (Array->Ref residual): `[T,U][]` leaked each tuple's heap fields. Two coordinated fixes: (1) checker arrayElementNeedsCleanup adds a Tuple case (recurse children) so the ref-array box selects the per-type msTuple_<hash>ArrayDestroy walker instead of the free-only msNumberArrayDestroy; (2) codegen forward.ms isDrcLifecycleName recognizes the generated msTuple_<hash>Array walker as a DRC hook — without it DCE removed the walker (its ms prefix was misread as a runtime-provided family), leaving an undefined symbol. Was 386MB @ 100k, now ~2.4MB drc+orc. Invisible to test-ms (Bun JS-GC).",
	},
	{
		name: "map-tuple-value-leak",
		file: "mapTupleValueLeak.ms",
		maxRssMb: 40,
		expectStdout: "map-tuple-value done acc=0",
		note: "FIXED (tuple not a first-class value type): `Map<int32, [string,string]>` leaked BOTH the incoming and the overwritten tuple's strings on every `m.set` of an existing key. Tuples had no named DRC hooks (only inline expansion in destructorLifting.fillBody), so the analyzer's moveOrCopy at `m.entries[i].value = value` found classify.ms returning empty-named hooks and emitted MS_NIL where the value-STRUCT path emits PairCopy/PairDestroy — the new value was never copied into the slot and the old value was never freed (twin struct-value probe stayed flat at 2.3MB). Three coordinated fixes make tuples first-class (reference parity: of tyTuple == of tyObject): (1) monomorphize monoTypeKey + monoConcreteTypeName add Tuple cases so a mono'd container value `[A,B]` roundtrips through resolveAnnotation back to a Tuple instead of erasing to `unknown`; (2) destructorLifting ensureTupleHooks generates msTuple_<hash>{Destroy,Copy,Sink,WasMoved} over positional fields (named via tupleTypeName — the SAME function codegen uses, so names can't drift) and classify.ms Tuple arm returns Named(tupleTypeName); (3) codegen forward.ms ensureDrcProto emits the cross-module forward proto for msTuple_ hooks (the ms prefix otherwise skipped them). Was 504MB @ 200k, now ~2.3MB drc+orc. Invisible to test-ms (Bun JS-GC).",
	},
	{
		name: "struct-tuple-field-leak",
		file: "structTupleFieldLeak.ms",
		maxRssMb: 40,
		expectStdout: "struct-tuple-field done acc=0",
		note: "FIXED (companion to map-tuple-value-leak): a heap interface/struct with a tuple field hit two tuple-not-first-class holes at once — (1) BUILD FAIL: the auto-generated HolderEq compared the `pair` field with C `===` on a struct value (`invalid operands to binary expression 'msTuple_lta21p'`) because destructorLifting fieldEqExpr had no Tuple case; now routes to the generated msTuple_<hash>Eq via ensureTupleEq (sharing the operatorLower pending-ops dedup key); (2) LEAK: without named tuple hooks the field's heap strings leaked per drop. Both fixed by the first-class tuple work. Builds + flat ~2.2MB drc+orc. Invisible to test-ms (Bun JS-GC never runs the C == hook or the lifecycle frees).",
	},
	{
		name: "ref-field-sink-leak",
		file: "refFieldSinkLeak.ms",
		maxRssMb: 40,
		expectStdout: "ref-field-sink done acc=0",
		note: "FIXED (audit of the tuple work surfaced a pre-existing core-DRC leak): a value type (struct OR tuple) holding a Ref-typed field — a post-migration `Ref<Array>`, or an interface/class — leaked the PRIOR field value on every reassignment-sink. destructorLifting refOp's `sink` arm raw-assigned `dest.field = src.field` with NO decref of the old ref: the only per-field sink that violated the =sink-owns-old convention that stringOp (msStringDecref+assign) and arrayOp (guarded msArrayDestroy+assign) already honored. Fix mirrors Nim atomicRefOp attachedSink (liftdestructors.nim:762, acyclic branch): decref dest (guarded against self-sink), then assign. Nim's cyclic write-barrier ordering (assign-first) is provably unneeded here — our ORC defers cycle collection (runtime/drc.h: periodic 3-phase), so msDecrefCyclic does no synchronous trial-deletion that bug #15753 guards against. Was 119MB @ 50k (struct string[]) / 135MB (tuple-of-array), now ~2.3MB drc+orc; ASAN clean both modes. Invisible to test-ms (Bun JS-GC). NOTE: triggered only by value-type reassignment of a ref field (uncommon), which is why it survived self-host — caught here by a loop that reassigns.",
	},
	{
		name: "string-self-append",
		file: "stringSelfAppend.ms",
		maxRssMb: 30,
		expectStdout: "string-self-append r=128 s=63 t=81",
		note: "CORRECTNESS ANCHOR for the string self-append heap-use-after-free (the UAF is only deterministic under ASAN+slab-off, which the native runner doesn't use — slab masks it — so this pins the output lengths; the UAF was verified clean separately under `--cc=clang -DMS_SLAB_MAX=0 -fsanitize=address` drc+orc). stringOpLower rewrites self-first concat (`s = s + ...`) to in-place msStringAppend(&s, ...); when a later operand also aliases s (`s=s+s`, `s=s+sep+s`, `s=s+s+s`) msStringPrepareAdd's realloc freed the buffer the aliased operand still pointed at → UAF in the memcpy. Fix: msStringAppend reads preserved bytes from dest's grown buffer when src aliases dest (std::string self-append safety); msStringAppendArr snapshots the original payload once when ANY element aliases dest, so a mid-element realloc can't dangle a later self-operand. Nim sidesteps the whole class by never lowering concat-to-self in place (strs_v2 appendString is not self-safe, but `&` always builds fresh). Found by ASAN during the tuple-leak audit (big()'s `r=r+r` builder); pre-existing, unrelated to tuples/DRC.",
	},
	{
		name: "actor-shared-actor-field",
		file: "actorSharedActorField.ms",
		maxRssMb: 40,
		expectStdout: "actor-shared-actor-field done",
		note: "FIXED (UAF caught by audit of the actor-state-free fix): an actor whose state holds OTHER actor handles (plain Ref / array element / nullable union) double-freed the shared actor on teardown. Actors are DRC-exempt (classify.ms: SymbolKind.Actor -> noRcInfo), spawn never increfs the handle, so a generated destroy/copy hook touching the field underflowed the shared actor's rc; once the actor-state-free fix wired the with-ctor destroyFn, the orphaned hook ran and double-freed. Root cause: destructorLifting had no actor exemption while classify.ms did. Fixes mirror classify.ms: destructorLifting skips RC ops on actor-typed Ref fields (fillBody) and actor-element arrays (arrayOp), and codegen picks the free-only msNumberArrayDestroy for an actor-element ref-array box (no per-element decref). Pre-fix: ASAN heap-use-after-free / malloc abort under --gc=drc+orc. Invisible to test-ms (Bun JS-GC).",
	},
	{
		name: "jsx-lex-native",
		file: "jsxLexNative.ms",
		maxRssMb: 30,
		expectStdout: "jsx-lex-native acc=800000",
		note: "JSX lexer (src/lexer/jsx.ms) leak guard under the C runtime: lex() 200k× on a JSX string covering every mode — apostrophe text, attribute, expr container, nested + self-close. The lexer allocates per call (byteSlice for text/idents, jsxStack push/pop, token array) and frees per call, so RSS is flat ~2.5MB drc+orc. acc=800000 is the deterministic JSX-token count (4 × 200000 % 1e6); a regressed token stream — e.g. the `'` in \"Don't\" choking the scanner into an unterminated string — changes it. test-ms runs the lexer on Bun and never frees the emitted C strings, so it is blind to this path.",
	},
	{
		name: "jsx-parse-native",
		file: "jsxParseNative.ms",
		maxRssMb: 40,
		expectStdout: "jsx-parse-native acc=5000",
		note: "JSX parser (src/parser/expressions/jsx.ms) CRASH + CORRECTNESS guard: lex()+parseExpression() 5000× building a 3-child JSXElement (text + expr container + nested element), asserting the AST shape under the C runtime — catches over-free / UAF in JSX node construction (jsxChildren / jsxAttrs arrays, Result/try temporaries, nested nodes) that exits 0 on the Bun transpiler. NOT a leak guard: parseExpression accumulates per call regardless of JSX (A/B-proven — a plain `a + b * c` expr leaks the same ~2.7KB/iter; the parser frees per-compilation memory at process exit, not per call), so iterations are capped at 5000 (~14MB baseline) and the 40MB bound rides it while still catching a large JSX-specific leak on top. jsxLexNative is the leak guard.",
	},
	{
		name: "jsx-macro-native",
		file: "jsxMacroNative.ms",
		maxRssMb: 30,
		expectStdout: "jsx-macro-native PASS",
		note: "End-to-end JSX → macro → native (the closed cycle, Phases 3+4+7). A user `macro jsx(node)` consumes JSX `Node` values the parser produced and the checker typed compile-time-only, reads the serialized `jsxTag`, and emits a StringLiteral. The macro expands while THIS program compiles to native, so the build exercises parse → check → macro-expand → codegen; the marker prints only if every tag form — element, member (`Foo.Bar`), namespace (`svg:rect`), and a tag with attributes + expr container + nested children — round-tripped through the macro. ~2MB drc+orc. Proves JSX is usable end-to-end, not just parseable. (Macro array-field access, e.g. `node.jsxChildren.length`, is a separate macro-VM gap — returns -1 — so the toy macro reads the scalar tag only.)",
	},
	{
		name: "map-mutation-guard-ok",
		file: "mapMutationGuardOk.ms",
		maxRssMb: 30,
		expectStdout: "map-guard-ok sum=280 sum2=288 set=4 hmk=6 hs=4",
		note: "Positive half of the Map/Set concurrent-access guard (#188, Go writing-flag model). Exercises all four containers + a single-threaded mutate-during-iterate (value-update of each key while ranging m.toItems()). That must NOT fire — Go allows single-threaded mutation during range (the `writing` flag is set only for the duration of one op and clears before the iterator resumes), so this pins that the guard does not over-fire on legitimate sequential code. Invisible to test-ms (the guard's msMapFatal/exit only runs in the native binary).",
	},
	{
		name: "map-mutation-guard-fatal",
		file: "mapMutationGuardFatal.ms",
		maxRssMb: 30,
		expectStdout: "map-guard-fatal armed",
		expectExit: 2,
		note: "Negative half of the Map/Set concurrent-access guard (#188). After a clean set, forces the `writing` flag true (simulating a concurrent writer mid-mutation) then reads — get() detects writing and calls msMapFatal, which prints `fatal error: concurrent map read and map write` and exit(2) UNRECOVERABLE (Go fatal model: a detected race may already have corrupted memory, so it must not be a catchable throw). expectExit:2 asserts the fail-loud actually fired (the 'armed' marker prints before it; SHOULD-NOT-REACH never does). Locks the guard in CI so a future refactor can't silently disable it.",
	},
	{
		name: "arc-shared-box",
		file: "arcSharedBox.ms",
		maxRssMb: 40,
		expectStdout: "arc-shared-box total=112000",
		note: "Arc<T> atomic-refcount shared box — the first per-type atomic-rc path in the compiler. 4000 rounds × 4 spawn tasks each take an OWNING reference to one shared Arc<Payload> (return a → atomic incref) and drop the awaited result (atomic decref): concurrent owning rc traffic that a non-atomic refcount corrupts under contention (the reason Rust needs Arc<Mutex<T>>; MS's plain Ref rc is non-atomic, racing the check-then-decrement TOCTOU). createArc tags a Ref with TypeFlag.IsAtomic; classify.ms emits msAtomicIncref/Decref; new Arc(v) lowers to msBoxArc → msAllocArc cell at rc=MS_RC_INCREMENT (Rust convention — msAtomicDecRefIsLast frees when fetch_sub sees old==INC, so the box must NOT start at the rc=0 sole-owner of the non-atomic path). The cell reuses a weak-linkage Arc TypeInfo (ensureArcCellTypeInfo) whose destroyFn is the pointee's destructor — weak so a lifted-closure module can box without the owning-module gating that left PayloadTypeInfo undefined. Flat RSS proves box+pointee free once; total=112000 (4000×4×7) proves the value round-trips. ASAN-clean drc+orc separately (no UAF/double-free under contention); the atomic primitive proven by an 8-thread pthread+TSAN probe. Invisible to test-ms — Bun never runs the atomic C rc.",
	},
	{
		name: "arc-locker-shared-counter",
		file: "arcLockerSharedCounter.ms",
		maxRssMb: 30,
		expectStdout: "arc-locker total=12000",
		note: "Arc<struct{lock}> shared across spawn — the shipped shared-mutable-state pattern. Arc keeps the heap cell alive race-free (atomic rc); the bare Locker ticket lock serializes the read-modify-write. 3000 rounds × 4 spawn tasks hammer one shared Arc<Shared>; the counter lives in the lock's own slot, mutated ONLY inside withLock. total=12000 (3000×4) proves the ticket lock serializes race-free; flat RSS proves box+lock free once; clean under drc+orc. Replaces the dropped typed inline Mutex<T> (std/core/sync) — a redundant composition: Locker (exclusion) + Arc (cross-thread liveness) + struct (typed data) are orthogonal and compose without a dedicated lock-owns-data primitive, which MS can't make safe anyway (no field privacy / borrow checker to enforce no-unlocked-access). The sizeof-T-monomorphizes fix it was built on stays (general fix with its own regression). Invisible to test-ms — Bun never runs the C ticket lock.",
	},
	{
		name: "macro-node-fields",
		file: "macroNodeFields.ms",
		maxRssMb: 30,
		expectStdout: "macro-node-fields PASS",
		note: "Locks addKindFields (expand.ms) ↔ bridge.ms nodeToValue parity: a macro reading an ARRAY field of a NodeKind addKindFields didn't serialize used to abort at expansion with 'array handle out of bounds: 0' (e.g. MatchExpr.matchCases). Brought addKindFields to full parity (54 missing kinds added: MatchExpr/MatchCase, all For/Switch/Try/Do stmts, New/Await/Yield/Spread/TryExpr, Class/Interface/Enum/Method/Property/Ctor/Struct/Actor/Import/Export/Macro decls, patterns, etc.). The macros here read matchCases.length, matchCases[0].caseBody.kind, and casePatterns.length — building this program natively re-runs them at compile time, so a regression re-breaks the BUILD (macro abort), not just this assert. Invisible to compileToC tests (isolated module graph can't resolve std/meta).",
	},
	{
		name: "jsxdom-native",
		file: "jsxDomNative.ms",
		maxRssMb: 30,
		expectStdout: "jsxdom-native PASS",
		note: "End-to-end proof of the jsxDom reference macro (std/meta/jsxDom.ms): JSX → DomNode tree → render string. A macro rewrites <div id=app><h1>Hi</h1><p>x</p></div> into el()/txt()/attr() runtime calls at compile time; nested <h1>/<p> recurse via RE-EXPANSION (the macro emits jsxDom(child), the expander re-walks it — macro helper fns can't navigate/build Node values, only the macro body's return position is special-typed, so recursion can't be a helper). The marker prints only if render() is byte-exact, so this guards the whole JSX→macro→codegen path natively. Proves JSX is usable end-to-end, not just parseable.",
	},
];

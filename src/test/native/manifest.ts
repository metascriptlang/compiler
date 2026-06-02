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
		xfail: ["drc", "orc"],
		note: "OPEN BUG (found by this tier, pre-existing at HEAD): a HEAP-concatenated string set on an actor field reads back corrupted via CALL (a literal round-trips). The std/http multi-WS broadcast string path. CORRECTNESS bug — exits 0, no leak/crash — so it is caught by expectStdout, the reason this tier now asserts output. Drop xfail when actor heap-string transfer is fixed.",
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
		xfail: ["drc", "orc"],
		note: "OPEN BUG — and the transform-hoist approach to fixing it is UNSOUND on real code (negative result, 2026-06-01). A fresh interface object literal passed inline as a call argument, stored by the callee, leaks (value stuck at rc=1). Hoisting it to `const $t = {...}` (TypeKind.Ref — interfaces are heap) fixes THIS minimal probe but CRASHES real escape-heavy code (Photon WS broadcast: over-free/SIGSEGV) — the hoisted temp's scope-exit destroy races with a live alias the analyzer can't track once the value flows through actor messages / a broadcast subscriber list / async resume (callHoist runs post-actor/await lowering, inside the state-machine where the temp's scope ≠ the value's true lifetime). Excluding Ref makes it crash-safe but then it doesn't hoist (no fix). So the leak needs an ANALYZER-level fix (Phase 4 ownership of the fresh call argument), NOT a Phase-3 hoist. Was 387MB @ 2M. See docs/NIM-REF.md §3.",
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
];

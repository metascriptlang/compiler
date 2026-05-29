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
		name: "array-literal-strings",
		file: "arrayLiteralStrings.ms",
		maxRssMb: 40,
		xfail: ["drc", "orc"],
		note: "OPEN BUG (found by this tier on first run): array literal of string elements built in a hot loop grows RSS unbounded — the array-literal RC elements aren't cleaned at scope exit. Drop the xfail when fixed.",
	},
];

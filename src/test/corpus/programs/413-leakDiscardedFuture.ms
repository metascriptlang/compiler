// @maxrss: 40
// @stdout: leak-discarded-future done
// @serial
// @skip-js: migrated from native/ — JS-lane audit pending
// note: Guards the FLAG-SCOPE of the analyzer's awaitable skip (inject.ms skipAwaitableCapture). A discarded fire-and-forget async future is owned by the caller and must be captured+destroyed by the ordinary discarded-call path; the awaitable skip is scoped to non-RC binding/condition walks ONLY, so it must NOT suppress this. If the skip regresses to global (skip every future in ensureDestructionIfNeeded), each discarded future leaks ~188B/iter (was 94MB at 500k during the global-guard misstep, now flat). Complements paralock-nested, which guards the opposite side (awaited stepper futures must NOT be re-captured).

// Guards the flag-scoping of the analyzer's awaitable skip (inject.ms skipAwaitableCapture).
//
// A DISCARDED fire-and-forget async call's future is genuinely owned by the caller and MUST be
// captured + destroyed at scope exit (the ordinary discarded-call path). The awaitable skip is
// scoped (skipAwaitableCapture, set ONLY while walking a non-RC binding/condition initializer)
// precisely so it does NOT suppress this capture. If the skip ever regresses to global (skipping
// every future in ensureDestructionIfNeeded), each discarded future leaks (~188 B/iter). This
// pins that distinction: discarded future = captured; awaited stepper future = skipped (paralock).

async function work(i: number): Promise<number> { return i * 2; }

function main(): void {
	for (let i = 0; i < 500000; i = i + 1) {
		work(i);
	}
	console.log(`leak-discarded-future done`);
}
main();

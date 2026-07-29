// @ledger-slack(msRefArrayRefCell): 1
// @maxrss: 30
// @stdout: ref-array-self-consume n=
// @skip-js: migrated from native/ — JS-lane audit pending
// note: FIXED in inject.ms processAssignment + scope.ms (varMovedInContext/clearMoveInContext). `x = f([..., x])` — a borrowed value sunk into an array literal in the RHS while the holder is reassigned (matchLower's armBody = makeBlock([setMatched, armBody]) shape). The analyzer cleared the pending wasMoved yet still ran save-assign-destroy → double-free / UAF (ASAN-confirmed in buildSwitchDispatch; the self-host gen-2 crashed on it). Fix skips destroy-old (MOC_IS_DECL) + clears the stale move when the LHS var is consumed INSIDE this RHS, gated by a movedBeforeRhs snapshot so a prior conditional move (e.g. `return x` in a sibling branch — the findProjectRoot regression) is not mistaken for consumption. Nim parity: injectdestructors eqwasMoved-then-eqsink no-op. Only the native binary + ASAN exposed it.

// REGRESSION (ROOT-A DRC): `x = f([..., x])` — a borrowed value sunk into an array literal in
// the RHS while the holding variable is reassigned in the same statement (matchLower's
// `armBody = makeBlock([setMatched, armBody])` shape). The analyzer cleared the pending wasMoved
// yet still ran save-assign-destroy → double-free / use-after-free. Only the native binary runs
// DRC. Fixed in inject.ms processAssignment (consumedInRhs + the movedBeforeRhs gate)
// + scope.ms varMovedInContext/clearMoveInContext. Must run clean (exit 0, flat RSS) under
// both --gc=drc and --gc=orc.

interface Item { tag: number; }

function wrapBlock(items: Item[]): Item { return items[1]; }

function lower(): Item[] {
	const groups: Item[][] = [];
	const g0: Item[] = [];
	g0.push({ tag: 1 });
	g0.push({ tag: 2 });
	groups.push(g0);
	const result: Item[] = [];
	let gi = 0;
	while (gi < groups.length) {
		const bodies = groups[gi];
		let ai = 0;
		while (ai < bodies.length) {
			let armBody = bodies[ai];
			const marker: Item = { tag: 99 };
			armBody = wrapBlock([marker, armBody]);
			result.push(armBody);
			ai = ai + 1;
		}
		gi = gi + 1;
	}
	return result;
}

function main(): void {
	let n = 0;
	let m = 0;
	while (m < 500000) {
		const r = lower();
		n = n + r.length;
		m = m + 1;
	}
	console.log(`ref-array-self-consume n=${n}`);
}
main();

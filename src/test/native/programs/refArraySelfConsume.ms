// REGRESSION (ROOT-A DRC): `x = f([..., x])` — a borrowed value sunk into an array literal in
// the RHS while the holding variable is reassigned in the same statement (matchLower's
// `armBody = makeBlock([setMatched, armBody])` shape). The analyzer cleared the pending wasMoved
// yet still ran save-assign-destroy → double-free / use-after-free. Invisible to test-ms (Bun
// JS-GC, no DRC). Fixed in inject.ms processAssignment (consumedInRhs + the movedBeforeRhs gate)
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

// nim-guard: a Maybe carrier is one type per payload, pointees included, on BOTH backends
//
// INVARIANT (reference searchInstTypes dedups an instantiation with compareTypes, and sameTypeAux
//   compares tyRef/tyPtr by their children): `((a: Box, b: Box) => boolean) | null` and
//   `((a: Pt, b: Pt) => boolean) | null` are two carriers, so a generic body instantiated for Box
//   and then for Pt checks each call of the nullable comparator against its own pointee.
//
// WHAT IT CATCHES: a structural type key that spells a pointer by its kind alone, fusing every
//   struct pointee into the first carrier created — the second instantiation then fails its body
//   check (`got Pt, expected Box`) or, if the check is bypassed, calls the comparator through the
//   wrong closure type.
//
// RED MEANS: exit != 0, or GUARD-OK missing on either lane.
//
// GUARD-JS

interface Box { w: number; }
interface Pt { x: number; }

function pick<T>(fn: () => T, equals: ((a: T, b: T) => boolean) | null = null): T {
	const v = fn();
	if (equals !== null && equals(v, v)) { return v; }
	return v;
}

function main(): void {
	let calls = 0;
	const b = pick((): Box => { const o: Box = { w: 1 }; return o; }, (a: Box, c: Box): boolean => { calls = calls + 1; return a.w === c.w; });
	const p = pick((): Pt => { const o: Pt = { x: 2 }; return o; }, (a: Pt, c: Pt): boolean => { calls = calls + 1; return a.x === c.x; });
	const q = pick((): Pt => { const o: Pt = { x: 3 }; return o; });
	if (b.w === 1 && p.x === 2 && q.x === 3 && calls === 2) {
		console.log("GUARD-OK");
	} else {
		console.log("GUARD-FAIL b=" + b.w.toString() + " p=" + p.x.toString() + " q=" + q.x.toString() + " calls=" + calls.toString());
	}
}

main();

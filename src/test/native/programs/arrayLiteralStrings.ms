// OPEN BUG (xfail) — array literal of RC (string) elements leaks per iteration.
//
// Surfaced by the native tier itself: `const parts: string[] = [a, b, c]` built
// inside a hot loop grows RSS unbounded (~32 MB / 1M iters), so the array
// literal and/or its string elements are not destroyed at scope exit. Distinct
// from leak-call-in-cond (that's a non-RC binding skipping cleanup); this is an
// RC-typed local (`parts`) whose array-literal initializer isn't fully cleaned.
//
// Kept as an xfail regression anchor: when the array-literal RC cleanup is
// fixed, drop the xfail and this becomes a permanent guard.

function main(): void {
	let acc = 0;
	let i = 0;
	while (i < 3000000) {
		const parts: string[] = [`a-${i % 100}-pad`, `b-${i % 100}-pad`, "suffix-pad"];
		let len = 0;
		for (const p of parts) { len = len + p.length; }
		acc = (acc + len) % 100000;
		i = i + 1;
	}
	console.log(`array-literal-strings acc=${acc}`);
}

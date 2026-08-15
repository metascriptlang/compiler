// @maxrss: 40
// @stdout: array-literal-strings acc=
// @skip-js: migrated from native/ — JS-lane audit pending
// note: FIXED in runtime/core/array.c: msStringArrayFromArr deep-copied each element, allocating a redundant 2nd buffer and orphaning the analyzer's already-owned element (the analyzer copies aliased + moves last-read upstream, then assumes FromArr moves). Changed FromArr to MOVE (take the handle as-is), mirroring msGenericArrayPush (ref arrays) and Nim's sink. Permanent regression guard — was 177MB leaking, now flat.

// FIXED — array literal of RC (string) elements no longer leaks.
//
// Root cause was in runtime/core/array.c: msStringArrayFromArr deep-copied each
// element, allocating a redundant second buffer and orphaning the analyzer's
// already-owned element. The analyzer copies aliased occurrences and moves
// last-read ones upstream, then assumes FromArr MOVES them in; the deep-copy
// broke that contract. Fix: FromArr now moves (takes the handle as-is), like
// msGenericArrayPush (ref arrays) and Nim's sink. Permanent regression guard.

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

main();

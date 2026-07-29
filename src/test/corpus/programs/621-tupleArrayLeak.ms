// @maxrss: 40
// @stdout: tuple-array done
// @skip-js: migrated from native/ — JS-lane audit pending
// note: FIXED (Array->Ref residual): `[T,U][]` leaked each tuple's heap fields. Two coordinated fixes: (1) checker arrayElementNeedsCleanup adds a Tuple case (recurse children) so the ref-array box selects the per-type msTuple_<hash>ArrayDestroy walker instead of the free-only msNumberArrayDestroy; (2) codegen forward.ms isDrcLifecycleName recognizes the generated msTuple_<hash>Array walker as a DRC hook — without it DCE removed the walker (its ms prefix was misread as a runtime-provided family), leaving an undefined symbol. Was 386MB @ 100k, now ~2.4MB drc+orc.

// Guards the tuple-element ref-array leak. `[T, U][]` (array of tuples) leaked each tuple's
// heap fields on drop: the checker's arrayElementNeedsCleanup had no Tuple case, so the box
// destroyFn fell to the free-only msNumberArrayDestroy. Routing it to the per-type
// msTuple_<hash>ArrayDestroy walker then exposed a second hole — DCE removed the generated
// walker because isDrcLifecycleName read its ms-prefixed name as a runtime-provided family.
// Was 386MB @ 100k, now ~2.4MB drc+orc.

type Pair = [number, string];

function makeArr(): Pair[] {
	const a: Pair[] = [];
	for (let i = 0; i < 8; i = i + 1) {
		let s = "x";
		for (let k = 0; k < 9; k = k + 1) { s = s + s; }
		a.push([i, s]);
	}
	return a;
}

function main(): void {
	let acc = 0;
	for (let m = 0; m < 100000; m = m + 1) {
		const arr = makeArr();
		acc = (acc + arr.length) % 1000;
	}
	console.log(`tuple-array done acc=${acc}`);
}
main();

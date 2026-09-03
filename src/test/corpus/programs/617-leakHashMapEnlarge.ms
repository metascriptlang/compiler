// @xfail(esm): tree emit: prelude container class binding never imported into the referencing module
// @maxrss: 40
// @stdout: leak-hashmap-enlarge acc=
// note: FIXED by classifyArray reading the instantiated body's hasAsgn + mono-TypeInfo wiring. hashMapEnlarge swaps the slot array (const old = m.data; m.data = newData; migrate), orphaning the old HashMapEntry__K_V[]. classifyArray decided RC from the abstract base (Entry<K,V>, K/V unbound → hasAsgn false) not the instantiated body (Entry__string → true), so the array of a mono'd generic struct misclassified non-RC → no per-element destroy on field-reassign; AND the mono HashMap__K_V TypeInfo.destroyFn was NULL (see leak-map-drop) so dropping never recursed. Nim parity: tfHasAsgn set per-instantiation. Was 574MB @ 50k×50 fill(+enlarge)+drop, now flat ~2MB drc+orc.

// FIXED by classifyArray reading the instantiated body's hasAsgn (analyzer) + destructorLifting
// mono-TypeInfo wiring. hashMapEnlarge swaps the slot array (const old = m.data; m.data = newData;
// migrate), orphaning the old HashMapEntry__K_V[]. Two root causes had to be fixed together:
//   1. classifyArray decided RC-ness from the abstract base (Entry<K,V>, K/V unbound → hasAsgn
//      false) instead of the instantiated body (Entry__string → hasAsgn true), so an array of a
//      mono'd generic struct was misclassified non-RC → no per-element destroy on field-reassign.
//   2. the mono HashMap__K_V instance had TypeInfo.destroyFn NULL (see leakMapDrop), so dropping
//      the map never recursed into the entry array at all.
// Nim parity: tfHasAsgn set per-instantiation; classify reads the instantiated type's flag.
//
// Permanent regression guard: was 574MB @ 50k×50 fill(+enlarge)+drop, now flat ~2MB drc+orc.

function fillAndDrop(n: number): number {
	const m = new HashMap<string, string>();
	for (let i = 0; i < n; i = i + 1) {
		m.set("key-" + i, "value-payload-here-longer-string");
	}
	return m.size;
}

function main(): void {
	let acc = 0;
	for (let r = 0; r < 50000; r = r + 1) {
		acc = (acc + fillAndDrop(50)) % 1000;
	}
	console.log(`leak-hashmap-enlarge acc=${acc}`);
}
main();

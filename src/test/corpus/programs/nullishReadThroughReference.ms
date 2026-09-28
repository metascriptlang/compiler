// @stdout: ref 4 out 6 boxed 5 leaf 9 leafRef 9 missing -1 missingRef -1
// note: `??` and `?.` read their operand in the test and again in the taken arm; when that operand is a field reached through a ref or out parameter, or through a local the caller boxed for one, each read dereferences the binding once and yields the field.

class Leaf {
	v: int32;
	constructor(v: int32) { this.v = v; }
}

struct Slot {
	o: int32 | null;
	leaf: Leaf | null;
}

function readRef(ref slot: Slot): int32 {
	return slot.o ?? -1;
}

function readOut(out slot: Slot): int32 {
	slot = { o: 6, leaf: null };
	return slot.o ?? -1;
}

function bump(ref slot: Slot): void {
	if (slot.o != null) slot.o = slot.o + 1;
}

function readLeafRef(ref slot: Slot): int32 {
	const leaf = slot.leaf ?? new Leaf(-1);
	return leaf.v;
}

function main(): void {
	let slot: Slot = { o: 4, leaf: new Leaf(9) };
	const viaRef = readRef(slot);
	let fresh: Slot = { o: null, leaf: null };
	const viaOut = readOut(fresh);
	bump(slot);
	const boxed = slot.o ?? -1;
	const boxedLeaf = slot.leaf?.v ?? -1;
	const leafRef = readLeafRef(slot);
	let empty: Slot = { o: null, leaf: null };
	bump(empty);
	const missing = empty.o ?? -1;
	const missingRef = readLeafRef(empty);
	console.log(`ref ${viaRef} out ${viaOut} boxed ${boxed} leaf ${boxedLeaf} leafRef ${leafRef} missing ${missing} missingRef ${missingRef}`);
}

main();

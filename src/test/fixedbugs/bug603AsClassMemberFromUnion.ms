// bug603 — `as Row | null` out of a union that holds a class did not compile on C and tested nothing on JS
//
// Symptom:    `a as Row | null` from `number | Row | null` stopped clang (Row* assigned a union),
//             from `number | Row` hit "reached codegen unprojected", and on JS every class member
//             passed `as` unchecked, so a number came out as a Row whose fields read undefined.
// Root cause: a nullable class target is pointer-shaped, not a Maybe, so the assertion never took
//             the checked slot projection that `as Row` already took, and JS tested only the
//             string, number and boolean members of a union.
// Fix:        assertionPayload and the slot-union arm unwrap a nullable class target into the
//             member's checked projection (NodeFlag.ConvCheck); JS tests `instanceof` when no
//             other member of the union could hold an instance of the class.

class Row {
	value: int32;
	constructor(value: int32) { this.value = value; }
}

class Other { tag: int32 = 5; }

class Slot { row: Row | null = null; }

function carriedOf(k: int32): number | Row | null {
	if (k == 0) return new Row(7);
	if (k == 1) return null;
	return 9;
}

function plainOf(k: int32): number | Row {
	if (k == 0) return new Row(7);
	return 9;
}

function twoOf(k: int32): Row | Other | null {
	if (k == 0) return new Other();
	if (k == 1) return null;
	return new Row(7);
}

function carriedRow(k: int32): Row | null {
	const a: number | Row | null = carriedOf(k);
	return a as Row | null;
}

function plainRow(k: int32): Row | null {
	const a: number | Row = plainOf(k);
	return a as Row | null;
}

function narrowedRow(a: number | Row | null): Row | null {
	if (a !== null) return a as Row | null;
	return null;
}

test "bug603: a Row held by a nullable union converts to Row | null" {
	const r = carriedRow(0);
	assert r != null;
	if (r != null) assert r.value == 7;
}

test "bug603: null held by a nullable union converts to null" {
	assert carriedRow(1) == null;
}

test "bug603: a Row held by a plain union converts to Row | null" {
	const r = plainRow(0);
	assert r != null;
	if (r != null) assert r.value == 7;
}

test "bug603: a Row held by a nullable union converts to Row" {
	const a: number | Row | null = carriedOf(0);
	const r: Row = a as Row;
	assert r.value == 7;
}

test "bug603: a Row held by a plain union converts to Row" {
	const a: number | Row = plainOf(0);
	const r: Row = a as Row;
	assert r.value == 7;
}

test "bug603: a flow-narrowed nullable union converts to Row | null" {
	const r = narrowedRow(carriedOf(0));
	assert r != null;
	if (r != null) assert r.value == 7;
	assert narrowedRow(carriedOf(1)) == null;
}

test "bug603: the converted Row stores into a field and a null clears it" {
	const slot = new Slot();
	const a: number | Row | null = carriedOf(0);
	slot.row = a as Row | null;
	assert slot.row != null;
	const b: number | Row | null = carriedOf(1);
	slot.row = b as Row | null;
	assert slot.row == null;
}

test "bug603: an unrelated class member converts out of a union of two classes" {
	const a: Row | Other | null = twoOf(0);
	const o = a as Other | null;
	assert o != null;
	if (o != null) assert o.tag == 5;
	const b: Row | Other | null = twoOf(1);
	assert (b as Other | null) == null;
}

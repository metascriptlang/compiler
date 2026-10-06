// nim-guard: `as` out of a union tests a member the JS value itself names
//
// INVARIANT (NIM-REF CK-136): a conversion to a union member reads the member's discriminator
//   on every backend (Nim `genCheckedFieldOp`, jsgen.nim). JS stores no tag, so it tests the
//   value when the member is the only one of its runtime kind: `typeof` for a primitive,
//   `Array.isArray` for an array, a non-array object of no member class for a struct or an
//   interface. A wrong member is rejected; the held member converts.
//
// WHAT IT CATCHES: a JS test that rejects the held member. A wrong member stops the program
//   (NIM-REF RT-34), so the rejections are pinned in corpus/programs/asUnion*Stops.ms.
//
// RED MEANS: emitCheckedNarrowing (codegen/js/expressions.ms) or materializeIntConv
//   (transform/coercion/intConvJS.ms) tests the wrong member. Run /trace-nim on them.
// GUARD-JS

class Row {
	v: int32;
	constructor(v: int32) { this.v = v; }
}

interface Named { name: string; }

struct Point { x: int32 }

struct Other { y: int32 }

function pointOrOther(k: int32): Point | Other {
	if (k == 0) { const p: Point = { x: 3 }; return p; }
	const o: Other = { y: 4 };
	return o;
}

function intOrFloat(k: int32): int32 | float64 {
	if (k == 0) return 7;
	return 1.5;
}

function numOrText(k: int32): int32 | string {
	if (k == 0) return 41;
	return "s";
}

function rowOrList(k: int32): Row | int32[] {
	if (k == 0) return [4, 5];
	return new Row(1);
}

function rowOrNamed(k: int32): Row | Named {
	if (k == 0) { const n: Named = { name: "n" }; return n; }
	return new Row(1);
}

function pointOrText(k: int32): Point | string {
	if (k == 0) { const p: Point = { x: 3 }; return p; }
	return "s";
}

function asInt(k: int32): int32 { return numOrText(k) as int32; }
function asList(k: int32): int32[] { return rowOrList(k) as int32[]; }
function asNamed(k: int32): Named { return rowOrNamed(k) as Named; }
function asPoint(k: int32): Point { return pointOrText(k) as Point; }

function asPointOfPair(k: int32): Point { return pointOrOther(k) as Point; }
function asOtherOfPair(k: int32): Other { return pointOrOther(k) as Other; }
function asIntOfNum(k: int32): int32 { return intOrFloat(k) as int32; }
function asFloatOfNum(k: int32): float64 { return intOrFloat(k) as float64; }

type RowOrLists = Row | int32[] | string[];

function sameHeld(x: RowOrLists, y: RowOrLists): boolean {
	let same = true;
	when (js) {
		same = x == y;
	}
	return same;
}

function sameHeldRow(): boolean {
	const held = new Row(1);
	return sameHeld(held, held);
}

function rejected(f: () => void): boolean {
	try {
		f();
	} catch (e) {
		return true;
	}
	return false;
}

function validPaths(): boolean {
	return asInt(0) + 1 == 42 && asList(0).length == 2 && asNamed(0).name == "n" && asPoint(0).x == 3
		&& asPointOfPair(0).x == 3 && asOtherOfPair(1).y == 4 && asIntOfNum(0) == 7 && asFloatOfNum(1) == 1.5
		&& sameHeldRow();
}

function wrongPathsRejected(): boolean {
	let ok = true;
	when (js) {
		ok = rejected((): void => { asPointOfPair(1); })
			&& rejected((): void => { asOtherOfPair(0); })
			&& rejected((): void => { asIntOfNum(1); })
			&& rejected((): void => { asFloatOfNum(0); });
	}
	return ok;
}

if (validPaths() && wrongPathsRejected()) {
	console.log("GUARD-OK");
} else {
	process.exit(1);
}

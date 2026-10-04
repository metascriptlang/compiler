// nim-guard: `as` out of a union tests a member the JS value itself names
//
// INVARIANT (NIM-REF CK-136): a conversion to a union member reads the member's discriminator
//   on every backend (Nim `genCheckedFieldOp`, jsgen.nim). JS stores no tag, so it tests the
//   value when the member is the only one of its runtime kind: `typeof` for a primitive,
//   `Array.isArray` for an array, a non-array object of no member class for a struct or an
//   interface. A wrong member is rejected; the held member converts.
//
// WHAT IT CATCHES: a JS conversion emitted without a test, so the wrong member reads undefined
//   fields or a string arrives as an int32 (`| 0` of a string).
//
// RED MEANS: emitCheckedNarrowing (codegen/js/expressions.ms) or materializeIntConv
//   (transform/coercion/intConvJS.ms) stopped testing. Run /trace-nim on them.
// GUARD-JS

class Row {
	v: int32;
	constructor(v: int32) { this.v = v; }
}

interface Named { name: string; }

struct Point { x: int32 }

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

function rejected(f: () => void): boolean {
	try {
		f();
	} catch (e) {
		return true;
	}
	return false;
}

function validPaths(): boolean {
	return asInt(0) + 1 == 42 && asList(0).length == 2 && asNamed(0).name == "n" && asPoint(0).x == 3;
}

function wrongPathsRejected(): boolean {
	let ok = true;
	when (js) {
		ok = rejected((): void => { asInt(1); })
			&& rejected((): void => { asList(1); })
			&& rejected((): void => { asNamed(1); })
			&& rejected((): void => { asPoint(1); });
	}
	return ok;
}

if (validPaths() && wrongPathsRejected()) {
	console.log("GUARD-OK");
} else {
	process.exit(1);
}

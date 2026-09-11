// bug143 — `typeof v === "function"` never narrowed, and a typeof-narrowed union read reached C as the whole union
// Symptom: `if (typeof v === "function") return v(cur);` on `int32 | ((prev: int32) => int32)` failed with
//          "Return type mismatch: expected int32, got int32 | function"; on `string | int32` the guard
//          type-checked but clang rejected `(*v) + 1` and `msStringLength((*v))` (the whole msUnion at an
//          operand); a union with a closure member emitted the closure's parameter list as its variant
//          struct (`typedef struct { int32_t prev; } msUnion_…_v1`).
// Root cause: the checker's typeof table stopped at string/number/boolean while the C backend already
//             classified function/bigint/object; the fit-site projection (narrowUnionToVariant) never
//             reached operand, callee and condition positions; genUnionType treated every non-primitive
//             member as a struct variant and read its parameter names as fields.
// Fix: one typeof classification shared by the checker and the C backend; project every narrowed union
//      read no fit site wrapped (a transform pass beside lowerNullable); raw payload slots for members
//      that do not peel to a struct.

function apply143(v: int32 | ((prev: int32) => int32), cur: int32): int32 {
	if (typeof v === "function") { return v(cur); }
	return v;
}

function applyT143<T>(v: T | ((prev: T) => T), cur: T): T {
	if (typeof v === "function") { return v(cur); }
	return v;
}

function pick143(v: string | int32): int32 {
	if (typeof v === "number") { return v + 1; }
	return v.length;
}

function chain143(v: string | int32 | boolean): int32 {
	if (typeof v === "boolean") { return v ? 1 : 0; }
	if (typeof v === "number") { return v * 2; }
	return v.length;
}

interface Point143 { x: int32; }

function unwrap143(v: Point143 | int32): int32 {
	if (typeof v === "object") { return v.x; }
	return v;
}

function notFn143(v: int32 | (() => int32)): int32 {
	if (typeof v !== "function") { return v + 1; }
	return v();
}

test "typeof function selects the updater branch" {
	assert apply143(5, 1) == 5;
	assert apply143((p: int32) => p + 1, 1) == 2;
}

test "typeof function narrows in a generic body" {
	assert applyT143<int32>(5, 1) == 5;
	assert applyT143<int32>((p: int32) => p * 10, 3) == 30;
}

test "the negated guard excludes the callable member" {
	assert notFn143(4) == 5;
	assert notFn143(() => 9) == 9;
}

test "a narrowed primitive member is read as an operand" {
	assert pick143(41) == 42;
	assert pick143("abc") == 3;
}

test "a chain of typeof guards narrows through the residual union" {
	assert chain143(true) == 1;
	assert chain143(21) == 42;
	assert chain143("abcd") == 4;
}

test "typeof object selects the struct member" {
	const p: Point143 = { x: 3 };
	assert unwrap143(p) == 3;
	assert unwrap143(7) == 7;
}

test "a closure with a captured environment survives the union" {
	let hits = 0;
	const bump = (p: int32) => { hits += 1; return p + 100; };
	assert apply143(bump, 1) == 101;
	assert apply143(bump, 2) == 102;
	assert hits == 2;
}

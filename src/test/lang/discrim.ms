// Language tests: Discriminated Unions (4 shapes) + edge cases
//
// Coverage matrix:
//   1. TS-style string DU       — interface A { kind: "a" } | interface B { kind: "b" }
//   2. TS-style boolean DU      — interface Ok { ok: true } | interface Err { ok: false }
//   3. Match-type w/ enum disc  — type X = match (k: K) { K.A => {...}, ... }
//   4. Match-type w/ bool disc  — type X = match (ok: boolean) { true => {...}, false => {...} }
//
// Plus regression coverage for:
//   - Multiple generic instantiations of the same DU (Either<str,num>, Either<num,num>)
//   - Structurally-identical-but-different-name generics coexisting (Either + Result-shape)
//   - Variant struct sharing across distinct outer DUs
//   - Ref<DU> heap-wrapped form (mono-name preservation)
//   - Narrowing via discriminator across all 4 shapes
//   - DU containing RC types (string, array)

// =====================================================================
// SHAPE 1: TS-style string DU
// =====================================================================

interface CircleD { kind: "circle"; radius: number }
interface SquareD { kind: "square"; side: number }
type ShapeD = CircleD | SquareD;

function areaD(s: ShapeD): number {
	if (s.kind == "circle") return s.radius * s.radius * 3;
	return s.side * s.side;
}

test "TS-style string DU narrowing" {
	const c: ShapeD = { kind: "circle", radius: 5 };
	const sq: ShapeD = { kind: "square", side: 4 };
	assert areaD(c) == 75;
	assert areaD(sq) == 16;
}

test "TS-style string DU disc field readable" {
	const c: ShapeD = { kind: "circle", radius: 5 };
	assert c.kind == "circle";
}

// =====================================================================
// SHAPE 2: TS-style boolean DU
// =====================================================================

interface OkB { ok: true; value: number }
interface ErrB { ok: false; error: string }
type ResB = OkB | ErrB;

function unwrapB(r: ResB): number {
	if (r.ok) return r.value;
	return -1;
}

test "TS-style boolean DU narrowing true branch" {
	const r: ResB = { ok: true, value: 42 };
	assert unwrapB(r) == 42;
}

test "TS-style boolean DU narrowing false branch" {
	const r: ResB = { ok: false, error: "boom" };
	assert unwrapB(r) == -1;
}

test "TS-style boolean DU disc field is real boolean" {
	const r: ResB = { ok: true, value: 7 };
	assert r.ok == true;
	const e: ResB = { ok: false, error: "x" };
	assert e.ok == false;
}

// =====================================================================
// SHAPE 3: Match-type with enum discriminator
// =====================================================================

enum NodeK { Num, Str, Bin }
type NodeD = match (kind: NodeK) {
	NodeK.Num => { numVal: number },
	NodeK.Str => { strVal: string },
	NodeK.Bin => { left: number, right: number },
};

function evalNode(n: NodeD): number {
	if (n.kind == NodeK.Num) return n.numVal;
	if (n.kind == NodeK.Str) return -1;
	if (n.kind == NodeK.Bin) return n.left + n.right;
	return 0;
}

test "match-type enum disc narrowing" {
	const a: NodeD = { kind: NodeK.Num, numVal: 42 };
	const b: NodeD = { kind: NodeK.Bin, left: 10, right: 20 };
	assert evalNode(a) == 42;
	assert evalNode(b) == 30;
}

test "match-type enum disc string variant" {
	const s: NodeD = { kind: NodeK.Str, strVal: "hello" };
	if (s.kind == NodeK.Str) {
		assert s.strVal == "hello";
	}
}

// =====================================================================
// SHAPE 4: Match-type with boolean discriminator
// =====================================================================

type EitherBool = match (ok: boolean) {
	true => { value: number },
	false => { error: string },
};

function unwrapEitherBool(r: EitherBool): number {
	if (r.ok) return r.value;
	return -1;
}

test "match-type bool disc narrowing" {
	const a: EitherBool = { ok: true, value: 100 };
	const b: EitherBool = { ok: false, error: "fail" };
	assert unwrapEitherBool(a) == 100;
	assert unwrapEitherBool(b) == -1;
}

// =====================================================================
// GENERIC DU — multiple instantiations
// =====================================================================

type Either<L, R> = match (ok: boolean) {
	true => { value: R },
	false => { error: L },
};

function eitherDivStr(a: number, b: number): Either<string, number> {
	if (b == 0) return { ok: false, error: "div0" };
	return { ok: true, value: a / b };
}

function eitherDivInt(a: number, b: number): Either<number, number> {
	if (b == 0) return { ok: false, error: -1 };
	return { ok: true, value: a / b };
}

test "Generic DU — single instantiation Either<string, number>" {
	const r = eitherDivStr(20, 4);
	assert r.ok == true;
	if (r.ok) assert r.value == 5;
}

test "Generic DU — error variant Either<string, number>" {
	const r = eitherDivStr(10, 0);
	assert r.ok == false;
	if (!r.ok) assert r.error == "div0";
}

test "Generic DU — multiple instantiations coexist" {
	// Either<string, number> AND Either<number, number> in the same module.
	// Mono mangling produces distinct types: Either__string_number,
	// Either__number_number.
	const a = eitherDivStr(10, 2);
	const b = eitherDivInt(10, 0);
	assert a.ok == true;
	if (a.ok) assert a.value == 5;
	assert b.ok == false;
	if (!b.ok) assert b.error == -1;
}

test "Generic DU — same type for both type params Either<number, number>" {
	const ok = eitherDivInt(10, 2);
	const err = eitherDivInt(10, 0);
	if (ok.ok) assert ok.value == 5;
	if (!err.ok) assert err.error == -1;
}

// =====================================================================
// REGRESSION — Structural-key cache collision
// =====================================================================
// Either<string, number> and Result<number, string> have IDENTICAL variant
// shapes ({ok:true,value:number} | {ok:false,error:string}). A prior bug in
// genUnionType collapsed them to one C typedef via structural-key cache,
// causing the second-emitted type to lack its typedef → link error.
// This test exercises both in the same module — must compile and run.

function resultDiv(a: number, b: number): Result<number, string> {
	if (b == 0) return Result.err("div0");
	return Result.ok(a / b);
}

test "Either + Result with identical shape coexist (structural-key regression)" {
	const e = eitherDivStr(20, 4);
	const r = resultDiv(20, 4);
	assert e.ok && r.ok;
	if (e.ok) assert e.value == 5;
	if (r.ok) assert r.value == 5;
}

test "Either err + Result err with identical shape coexist" {
	const e = eitherDivStr(10, 0);
	const r = resultDiv(10, 0);
	assert !e.ok && !r.ok;
	if (!e.ok) assert e.error == "div0";
	if (!r.ok) assert r.error == "div0";
}

// =====================================================================
// Ref<GenericInstance> — heap-allocated DU wrapper
// =====================================================================
// Regression for: peelToStructOrUnion in literal codegen lost the GI's
// monomorphized typeName, causing `MyData*` (base) instead of
// `MyData__T_E*` (mono) typedef references.

enum DBodyK { Ok, Err }
type DBody<T, E> = match (kind: DBodyK) {
	DBodyK.Ok => { value: T },
	DBodyK.Err => { error: E },
};
type DRef<T, E> = Ref<DBody<T, E>>;

function dOk(v: number): DRef<number, string> {
	return { kind: DBodyK.Ok, value: v };
}

function dErr(e: string): DRef<number, string> {
	return { kind: DBodyK.Err, error: e };
}

test "Ref<GI<DU>> mono name preserved (Ref<GI> regression)" {
	const ok = dOk(99);
	const err = dErr("boom");
	if (ok.kind == DBodyK.Ok) assert ok.value == 99;
	if (err.kind == DBodyK.Err) assert err.error == "boom";
}

// =====================================================================
// DU + RC types — ensure no double-free / leak with managed payloads
// =====================================================================

type StrRes = match (ok: boolean) {
	true => { value: string },
	false => { error: string },
};

function makeStr(s: string, isOk: boolean): StrRes {
	if (isOk) return { ok: true, value: s };
	return { ok: false, error: s };
}

test "DU with string payload — ok variant" {
	const r = makeStr("hello", true);
	assert r.ok;
	if (r.ok) assert r.value == "hello";
}

test "DU with string payload — err variant" {
	const r = makeStr("oops", false);
	assert !r.ok;
	if (!r.ok) assert r.error == "oops";
}

test "DU with string payload — multiple in same scope" {
	// Stress DRC: 3 RC-bearing DUs alive simultaneously, all destructed at scope exit.
	const a = makeStr("x", true);
	const b = makeStr("y", false);
	const c = makeStr("z", true);
	if (a.ok) assert a.value == "x";
	if (!b.ok) assert b.error == "y";
	if (c.ok) assert c.value == "z";
}

// =====================================================================
// Variant sharing — different DUs, structurally identical variants
// =====================================================================
// genUnionType caches variant typedefs by structural typeKey so that
// `Either<string, number>` and `Result<number, string>` share variant
// struct definitions but have distinct outer-union typedefs. This test
// just exercises the path; correctness is verified by the regression
// test above.

test "Variant struct sharing across distinct outer DUs" {
	const e = eitherDivStr(8, 2);
	const r = resultDiv(8, 2);
	if (e.ok && r.ok) {
		assert e.value == 4;
		assert r.value == 4;
	}
}

// =====================================================================
// Flow-merge identity — a narrowing must not outlive its sub-expression
// =====================================================================
// `const c = d.kind === K.A && …` narrows `d` inside the right operand of
// `&&` only. At the end of the expression both edges (lhs-true, lhs-false)
// merge back to the declared union. The merge dedups antecedent types by
// identity; identity computed by NAME alone makes the two anonymous
// variants indistinguishable, collapsing the merge to the true-branch
// variant — every later disc read then routes to the wrong variant.

enum FmK { Alpha, Beta }
type FmEnumDU = match (kind: FmK) { FmK.Alpha => { a: int32 }, FmK.Beta => { b: string } };
type FmBoolDU = match (ok: boolean) { true => { value: int32 }, false => { error: string } };

function fmAlpha(): FmEnumDU { return { kind: FmK.Alpha, a: 7 }; }
function fmBeta(): FmEnumDU { return { kind: FmK.Beta, b: "beta" }; }
function fmOk(): FmBoolDU { return { ok: true, value: 5 }; }
function fmErr(): FmBoolDU { return { ok: false, error: "no" }; }

function fmAfterAnd(d: FmEnumDU): int32 {
	const probe = (d.kind == FmK.Alpha) && true;
	if (d.kind == FmK.Beta) return 2;
	return 1;
}

function fmAfterOr(d: FmEnumDU): int32 {
	const probe = (d.kind == FmK.Alpha) || false;
	if (d.kind == FmK.Beta) return 2;
	return 1;
}

function fmAfterTernary(d: FmEnumDU): int32 {
	const probe = d.kind == FmK.Alpha ? 1 : 0;
	if (d.kind == FmK.Beta) return 2;
	return 1;
}

function fmAfterIf(d: FmEnumDU): int32 {
	if (d.kind == FmK.Alpha) {
		const inner = d.a;
	}
	if (d.kind == FmK.Beta) return 2;
	return 1;
}

function fmBoolAfterAnd(e: FmBoolDU): int32 {
	const probe = e.ok && true;
	if (e.ok) return e.value;
	return -1;
}

test "flow merge: && does not leak the narrowed variant" {
	assert fmAfterAnd(fmBeta()) == 2;
	assert fmAfterAnd(fmAlpha()) == 1;
}

test "flow merge: || does not leak the narrowed variant" {
	assert fmAfterOr(fmBeta()) == 2;
	assert fmAfterOr(fmAlpha()) == 1;
}

test "flow merge: ternary condition does not leak" {
	assert fmAfterTernary(fmBeta()) == 2;
	assert fmAfterTernary(fmAlpha()) == 1;
}

test "flow merge: if-without-return does not leak past the block" {
	assert fmAfterIf(fmBeta()) == 2;
	assert fmAfterIf(fmAlpha()) == 1;
}

// Coverage only — NOT red-capable: both bool-disc variants carry `ok` at the
// same offset, so a leaked narrow still emits valid, correct C. The enum-disc
// cases above are the ones that fail when the merge collapses.
test "flow merge: bool-disc && does not leak" {
	assert fmBoolAfterAnd(fmErr()) == -1;
	assert fmBoolAfterAnd(fmOk()) == 5;
}

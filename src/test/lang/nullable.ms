// Language tests: T | null nullability via Maybe<T> wrapper.
//
// Covers the end-to-end pipeline for non-pointer T | null:
//   - resolver wraps Union(T, Null) → Maybe<T> for value types
//   - fitNode wraps T → Maybe<T> at var-decl/return/object-field/call-arg/assign
//   - flow.ms narrows Maybe<T> via `=== null` / `!== null` checks
//   - nullableLower rewrites narrowed identifier/member to .value
//
// Each section guards against a specific regression. If any of these fail
// in the future, the gap re-opened.

// ===== Shared definitions =====

struct Token { kind: number; }

interface Cube {
	tweet: string;
	cursor: string | null;
}

// ===== Var-decl with value (regression for fitNode wrap + boolValue field name) =====
// Regression: fitNode emitted `{ value: true }` instead of `{ boolValue: true }`,
// silently producing `present: false` for ALL non-null inits. Probes that only
// asserted "ok" missed it; only assertions that READ the value catch the bug.

test "var-decl primitive | null with non-null value narrows + reads correctly" {
	const x: number | null = 42;
	if (x == null) {
		assert false;  // unreachable
	} else {
		assert x == 42;        // narrowed read — was MS_FALSE → unreachable pre-fix
		assert x + 100 == 142; // arithmetic on narrowed primitive
	}
}

test "var-decl string | null with non-null value" {
	const s: string | null = "hi";
	if (s != null) {
		assert s == "hi";
	} else {
		assert false;
	}
}

test "var-decl boolean | null with non-null value" {
	const b: boolean | null = true;
	if (b != null) {
		assert b == true;
	} else {
		assert false;
	}
}

test "var-decl struct | null with non-null value, member access after narrow" {
	const t: Token | null = { kind: 7 };
	if (t != null) {
		assert t.kind == 7;  // narrowed MemberExpr access
	} else {
		assert false;
	}
}

// ===== Var-decl with null (regression for null retype path) =====

test "var-decl primitive | null with null retypes correctly" {
	const x: number | null = null;
	assert x == null;
}

test "var-decl struct | null with null retypes correctly" {
	const t: Token | null = null;
	assert t == null;
}

// ===== Function param Maybe<T> + narrowing (Gap 2) =====

function paramPrim(x: number | null): number {
	if (x == null) return 0;
	return x;  // narrowed — Gap 2: param path must call removeNullFromType
}

test "function param primitive | null narrows in else branch" {
	assert paramPrim(42) == 42;
	assert paramPrim(null) == 0;
}

function paramStruct(t: Token | null): number {
	if (t == null) return -1;
	return t.kind;  // narrowed member access on param
}

test "function param struct | null narrows + member access" {
	assert paramStruct({ kind: 9 }) == 9;
	assert paramStruct(null) == -1;
}

// ===== Function call argument auto-wrap (Gap 1) =====
// f(42) where f: (number | null) — needsStdConv didn't know about Maybe wrap.

test "call arg auto-wraps T → Maybe<T>" {
	assert paramPrim(42) == 42;
}

test "call arg auto-wraps null → Maybe<T>" {
	assert paramPrim(null) == 0;
}

test "call arg auto-wraps struct → Maybe<Struct>" {
	assert paramStruct({ kind: 5 }) == 5;
}

// ===== Function returning T | null =====

function returnPrim(b: boolean): number | null {
	if (b) return 42;
	return null;
}

test "function returning primitive | null with null" {
	assert returnPrim(false) == null;
}

function returnStruct(b: boolean): Token | null {
	if (b) return { kind: 1 };
	return null;
}

test "function returning struct | null with value" {
	const t = returnStruct(true);
	assert t != null;
	if (t != null) assert t.kind == 1;
}

test "function returning struct | null with null" {
	assert returnStruct(false) == null;
}

// ===== Object literal field T | null (struct field of Maybe type) =====

test "object literal Maybe field with non-null value" {
	const c: Cube = { tweet: "hi", cursor: "abc" };
	if (c.cursor != null) {
		assert c.cursor == "abc";  // narrowed member access — Gap 3
	} else {
		assert false;
	}
}

test "object literal Maybe field with null value" {
	const c: Cube = { tweet: "hi", cursor: null };
	assert c.cursor == null;
}

// ===== Ternary on narrowed Maybe member (Gap 3) =====

test "ternary on Maybe member field unwraps narrow on true arm" {
	const c: Cube = { tweet: "hi", cursor: "ok" };
	const display: string = c.cursor != null ? c.cursor : "default";
	assert display == "ok";
}

test "ternary on null Maybe member takes default arm" {
	const c: Cube = { tweet: "hi", cursor: null };
	const display: string = c.cursor != null ? c.cursor : "default";
	assert display == "default";
}

// ===== Assignment to Maybe variable =====

test "assign null to mutable Maybe<T> variable" {
	let x: number | null = 42;
	if (x != null) assert x == 42;
	x = null;
	assert x == null;
}

// ===== A read narrowed to null reads the slot, which a call may have filled =====

struct Cam { x: float32; }
interface CamHolder { cam: Cam | null; n: number | null; }

function fillHolder(h: CamHolder): void {
	h.cam = { x: 1.0 };
	h.n = 0;
}

test "struct and number fields narrowed to null, refilled through a call" {
	const h: CamHolder = { cam: null, n: null };
	if (h.cam != null || h.n !== null) { assert false; return; }
	fillHolder(h);
	assert h.cam !== null;
	assert !(h.n == null);
	assert `${h.n}` == "0";
}

test "an int32 local narrowed to null, refilled with 0 by a closure" {
	let v: int32 | null = null;
	const fill = (): void => { v = 0; };
	if (v !== null) { assert false; return; }
	fill();
	assert v != null;
	assert !(v === null);
}

test "a number local narrowed to null, refilled by a closure, read as a value" {
	let v: number | null = null;
	const fill = (): void => { v = 7; };
	if (v === null) {
		fill();
		assert (v ? "truthy" : "falsy") == "truthy";
		assert `${v}` == "7";
	}
}

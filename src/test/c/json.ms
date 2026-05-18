// E2E: typed JSON.parse<T> + JSON.stringify → C output
// Migrated from examples/json.ms — covers the post-Result-migration fix in
// `checkDiscriminatedConstruction` (BooleanLiteral disc value extraction).
// Without that fix, `Result.ok({...})` synthesized by `__jsonParse_T` failed
// to stamp the inner literal as T — emitting `T* = anon_struct` C errors.

import { compileToC } from "../helpers";

test "E2E C: JSON.parse<Person> typed parse compiles" {
	const src = `
interface Person { name: string; age: int32; }

function main(): void {
	const r = JSON.parse<Person>("{\\"name\\":\\"Alice\\",\\"age\\":30}");
	if (r.ok) {
		const p = r.value;
		const _name = p.name;
		const _age = p.age;
	}
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: JSON round-trip (stringify + typed parse) compiles" {
	const src = `
interface Person { name: string; age: int32; }

function main(): void {
	const p: Person = { name: "Bob", age: 25 };
	const s = JSON.stringify(p);
	const r = JSON.parse<Person>(s);
	if (r.ok) { const out = r.value; }
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: untyped JSON parse with JsonValue accessors compiles" {
	// Both prelude paths reach the same code: JSON.parseValue is a thin
	// wrapper around parseJson. Test verifies the JsonValue accessor protocol
	// (.asString, .asInt32, .getDynamicField) compiles end-to-end with
	// untyped parsing. NOTE: avoid field names that collide with extension
	// methods on string/array types (e.g. "count") — see overload-matching
	// follow-up. "howmany" is unambiguously a dynamic field.
	const src = `
function main(): void {
	const r = parseJson("{\\"status\\":\\"ok\\",\\"howmany\\":3}");
	if (r.ok) {
		const v = r.value;
		const _s = v.status.asString();
		const _n = v.howmany.asInt32(0);
	}
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: JSON.stringify nested struct compiles" {
	// Regression: pre-fix, nested struct field hit `_ => jsonNumber` fallback
	// in the synthesizer, producing `jsonNumber(value.b)` (struct → number)
	// type error. Now: nested struct triggers `__jsonValueOf_<inner>` recursion.
	const src = `
interface Inner { c: number; }
interface Outer { a: number; b: Inner; }

function main(): void {
	const o: Outer = { a: 1, b: { c: 2 } };
	const s = JSON.stringify(o);
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: JSON.stringify enum field compiles" {
	// Regression: pre-fix, enum field reached jsonInt(int64) but enum value
	// wasn't auto-cast → type mismatch error. Now: needsCast wraps fieldAccess
	// in `as int64` for sized-int / enum types on stringify side.
	const src = `
enum Color { Red, Green, Blue }
interface Painted { c: Color; }

function main(): void {
	const p: Painted = { c: Color.Green };
	const s = JSON.stringify(p);
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: JSON.stringify sized int fields compile" {
	const src = `
interface Sized { a: int8; b: int32; c: int64; d: uint16; }

function main(): void {
	const s: Sized = { a: 1, b: 1000, c: 99999, d: 65000 };
	const r = JSON.stringify(s);
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: JSON.stringify rejects unsupported field type" {
	// Array field has no JSON synthesis support yet — must produce explicit
	// compile error (regression for the silent `_ => jsonNumber` fallback).
	const src = `
interface WithArr { items: number[]; }

function main(): void {
	const w: WithArr = { items: [1, 2, 3] };
	const s = JSON.stringify(w);
}
`;
	const c = compileToC(src);
	assert !c.ok;  // expect explicit error, not silent miscompile
}

// ===== Stdlib helper sanity tests =====
//
// These tests exist because of a 2026-05-15 incident where:
//   - Em refactored encode.ms to use a new discDetect.ms helper
//   - test-ms (Bun TS transpile) reported all-pass
//   - run-ms (full MS compile) reported 30 type errors
//   - The test-ms vs run-ms gap hid stdlib type errors for several hours
//
// Lesson: stdlib changes need pipeline tests via compileToC, not test-ms only.
// compileToC exercises the full MS pipeline (parse → check → mono → ... → codegen)
// including loading the prelude + std/serialize. Type errors in any prelude
// file (e.g., missing transitive imports in discDetect.ms) surface here.

test "E2E C: minimal program compiles (smoke for stdlib loadability)" {
	// Empty program forces the full prelude to load + type-check. If any
	// stdlib file (including std/serialize/discDetect.ms) has type errors
	// — e.g. missing transitive imports — this test fails.
	const c = compileToC("function main(): void {}");
	assert c.ok;
}

test "E2E C: importing detectUnionDisc helper compiles" {
	// Direct user-space import of the discDetect helper. Catches:
	//   - Missing transitive type imports in discDetect.ms
	//   - Helper signature changes that break callers
	const src = `
import { detectUnionDisc } from "std/serialize/discDetect";

function main(): void {
	// Reference detectUnionDisc to force resolution + import-graph load
	const _ref = detectUnionDisc;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: stdlib JSON encode/decode surface usable" {
	// Smoke test for the most common JSON pattern (parse + stringify of a
	// plain struct). If em's recent encode.ms / decode.ms refactor breaks
	// the basic struct path, this catches it.
	const src = `
interface Item { id: int32; label: string; }

function main(): void {
	const it: Item = { id: 1, label: "x" };
	const s = JSON.stringify(it);
	const r = JSON.parse<Item>(s);
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: JSON.stringify literal-string disc field (Bug A)" {
	// Bug A regression — bridge used to emit literal types as
	// Identifier(name=literal_value), making `kind: "circle"` look like a
	// type alias named "circle". Encode atomic dispatch fell to jsonInt
	// with a bad msString-as-int64 cast → C compile error in
	// _jsonStringifyTyped<Circle>. Fixed by emitting StringLiteral nodes
	// for TypeKind.StringLiteral in bridge.ms mapTypeToAstWith.
	const src = `
interface Circle { kind: "circle"; r: int32; }

function main(): void {
	const c: Circle = { kind: "circle", r: 5 };
	const s = JSON.stringify(c);
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: JSON.stringify literal-bool disc field (Bug A)" {
	// Same Bug A pattern but for BooleanLiteral types (`ok: true`).
	const src = `
interface OkBag { ok: true; val: int32; }

function main(): void {
	const o: OkBag = { ok: true, val: 42 };
	const s = JSON.stringify(o);
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: CBOR literal-string disc field (Bug A mirror)" {
	const src = `
import { cborEncode } from "std/serialize/cbor";

interface Circle { kind: "circle"; r: int32; }

function main(): void {
	const c: Circle = { kind: "circle", r: 5 };
	const bytes = cborEncode(c);
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: CBOR literal-bool disc field (Bug A mirror)" {
	const src = `
import { cborEncode } from "std/serialize/cbor";

interface OkBag { ok: true; val: int32; }

function main(): void {
	const o: OkBag = { ok: true, val: 42 };
	const bytes = cborEncode(o);
}
`;
	const c = compileToC(src);
	assert c.ok;
}

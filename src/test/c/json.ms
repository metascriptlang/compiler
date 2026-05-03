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

test "E2E C: untyped JSON.parse with JsonValue accessors compiles" {
	const src = `
function main(): void {
	const r = JSON.parse("{\\"status\\":\\"ok\\",\\"count\\":3}");
	if (r.ok) {
		const v = r.value;
		const _s = v.status.asString();
		const _n = v.count.asInt(0);
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

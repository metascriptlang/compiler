import { compileToC, compileToJS } from "../helpers";

const CALLS = `
class Box<T> { v: T; constructor(v: T) { this.v = v; } }
function one<T>(a: T): Box<T> { return new Box<T>(a); }
function id<T>(x: T): T { return x; }
function pick<T>(a: T, b: T): T { return a; }
function make<T>(): T[] { return []; }
function wrap<T>(xs: T[]): Box<T[]> { return new Box<T[]>(xs); }
const i: int32 = 3;
const w: int64 = 5;
const u: uint16 = 7;
`;

const CONSTRUCTED = `
class Box<T> { v: T; constructor(v: T) { this.v = v; } }
class Pair<A, B> { a: A; b: B; constructor(a: A, b: B) { this.a = a; this.b = b; } }
function show(b: Box<string>): string { return b.v; }
`;

const MEMBERS = `
enum K { A, B }
enum L { X, Y, Z }
function id<T>(x: T): T { return x; }
`;

function errorOnC(source: string): string {
	const c = compileToC(source);
	return c.ok ? "" : c.error;
}

function errorOnEither(source: string): string {
	const c = compileToC(source);
	if (!c.ok) return c.error;
	const js = compileToJS(source);
	return js.ok ? "" : js.error;
}

function refusalOnBoth(source: string): string {
	const c = compileToC(source);
	const js = compileToJS(source);
	if (c.ok || js.ok) return "";
	return c.error;
}

function emittedC(source: string): string {
	const c = compileToC(source);
	return c.ok ? c.value : c.error;
}

test "genericContextBinding: the destination binds a parameter no typed argument binds" {
	const rows = [
		{
			name: "a literal argument takes a wider destination",
			body: "const b: Box<int64> = one(1);",
		},
		{
			name: "no argument binds the parameter",
			body: "const xs: string[] = make(); xs.push(\"a\");",
		},
		{
			name: "an arrow takes its parameter types from the destination",
			body: "const f: (x: int32) => int32 = id((x) => x * 2);",
		},
		{
			name: "an empty array takes its element type from the destination",
			body: "const xs: int32[] = id([]); xs.push(1);",
		},
	];
	for (const row of rows) {
		const failure = errorOnC(CALLS + row.body);
		assert failure == "", row.name + ": " + failure;
	}
}

test "genericContextBinding: a typed argument binds its parameter before the destination" {
	const rows = [
		{
			name: "a literal before a variable follows the variable under a cast",
			body: "const d = pick(1, i) as int64;",
		},
		{
			name: "a literal before a variable follows the variable under a declared type",
			body: "const e: int64 = Math.max(1, i);",
		},
		{
			name: "an argument spelled in the destination's type binds it",
			body: "const b: Box<number> = one(i as number);",
		},
	];
	for (const row of rows) {
		const failure = errorOnC(CALLS + row.body);
		assert failure == "", row.name + ": " + failure;
	}
}

test "genericContextBinding: a literal outside the destination's range is refused" {
	const rows = [
		{
			name: "above an unsigned byte",
			body: "const b: Box<uint8> = one(300);",
			needle: "cannot convert 300 to uint8",
		},
		{
			name: "a negative into an unsigned word",
			body: "const b: Box<uint64> = one(-1);",
			needle: "cannot convert -1 to uint64",
		},
	];
	for (const row of rows) {
		const failure = refusalOnBoth(CALLS + row.body);
		assert failure.contains(row.needle), row.name + ": " + failure;
	}
}

test "genericContextBinding: the destination does not rebind a lossy or explicit binding" {
	const rows = [
		{
			name: "a signed argument against an unsigned destination",
			body: "const b: Box<uint32> = one(i);",
			needle: "'Box<int32>' is not assignable to type 'Box<uint32>'",
		},
		{
			name: "a wider argument against a narrower destination",
			body: "const b: Box<int32> = one(w);",
			needle: "'Box<int64>' is not assignable to type 'Box<int32>'",
		},
		{
			name: "an array argument against another element type",
			body: "const xs: int32[] = [1, 2]; const b: Box<number[]> = wrap(xs);",
			needle: "'Box<int32[]>' is not assignable to type 'Box<number[]>'",
		},
		{
			name: "an explicit type argument against a wider destination",
			body: "const b: Box<number> = one<int32>(i);",
			needle: "'Box<int32>' is not assignable to type 'Box<number>'",
		},
	];
	for (const row of rows) {
		const failure = refusalOnBoth(CALLS + row.body);
		assert failure.contains(row.needle), row.name + ": " + failure;
	}
}

test "genericContextBinding: a fitting result keeps the instance its arguments bound" {
	const rows = [
		{
			name: "a variable argument",
			body: "const d: int64 = pick(i, 1); const e = pick(i, 2) as int64; console.log(d, e);",
		},
		{
			name: "a call argument",
			body: "function f(): int32 { return 3; } " +
				"const d: int64 = pick(f(), 1); console.log(d);",
		},
	];
	for (const row of rows) {
		const code = emittedC(CALLS + row.body);
		assert code.contains("__int32__"), row.name;
		assert !code.contains("__int64__"), row.name;
	}
}

test "genericContextBinding: new fits its arguments to the instance the destination names" {
	const rows = [
		{
			name: "a literal of another type",
			body: "const a: Box<string> = new Box(7);",
			needle: "not assignable",
		},
		{
			name: "a literal outside the parameter's range",
			body: "const a: Box<uint8> = new Box(300);",
			needle: "cannot convert 300 to uint8",
		},
		{
			name: "a boolean against an integer parameter",
			body: "const a: Box<int32> = new Box(true);",
			needle: "not assignable",
		},
		{
			name: "a typed argument of another type",
			body: "const n: int32 = 7; const a: Box<string> = new Box(n);",
			needle: "not assignable",
		},
		{
			name: "a destination spelled by a call parameter",
			body: "console.log(show(new Box(7)));",
			needle: "not assignable",
		},
		{
			name: "a destination spelled by a return type",
			body: "function mk(): Box<string> { return new Box(7); }",
			needle: "not assignable",
		},
		{
			name: "a destination spelled by the parameter of an outer new",
			body: "const b: Box<Box<string>> = new Box(new Box(7));",
			needle: "not assignable",
		},
		{
			name: "the second parameter of a two-parameter class",
			body: "const p: Pair<string, string> = new Pair(\"x\", 1);",
			needle: "not assignable",
		},
	];
	for (const row of rows) {
		const failure = refusalOnBoth(CONSTRUCTED + row.body);
		assert failure.contains(row.needle), row.name + ": " + failure;
	}
}

test "genericContextBinding: new with fitting arguments compiles on both backends" {
	const rows = [
		{
			name: "a literal that fits the destination's integer",
			body: "const a: Box<uint8> = new Box(7); console.log(a.v);",
		},
		{
			name: "a literal widened to the second parameter",
			body: "const p: Pair<string, int64> = new Pair(\"x\", 1); console.log(p.b);",
		},
		{
			name: "an inner new fitting the outer parameter",
			body: "const b: Box<Box<string>> = new Box(new Box(\"in\")); console.log(b.v.v);",
		},
		{
			name: "a new as a call argument",
			body: "console.log(show(new Box(\"s\")));",
		},
		{
			name: "a builtin generic named by its destination",
			body: "const m: Map<string, int32> = new Map(); m.set(\"a\", 1); " +
				"console.log(m.get(\"a\"));",
		},
	];
	for (const row of rows) {
		const failure = errorOnEither(CONSTRUCTED + row.body);
		assert failure == "", row.name + ": " + failure;
	}
}

test "genericContextBinding: an enum member argument takes the member its destination names" {
	const rows = [
		{
			name: "the first member of two",
			body: "const x: K.A = id(K.A); console.log(x == K.A);",
		},
		{
			name: "the last member of three",
			body: "const z: L.Z = id(L.Z); console.log(z == L.Z);",
		},
		{
			name: "without a destination the member binds its enum",
			body: "const k = id(K.B); console.log(k == K.B);",
		},
	];
	for (const row of rows) {
		const failure = errorOnEither(MEMBERS + row.body);
		assert failure == "", row.name + ": " + failure;
	}
}

test "genericContextBinding: an enum member argument is refused by another member's destination" {
	const failure = refusalOnBoth(MEMBERS + "const y: K.A = id(K.B);");
	assert failure.contains("not assignable"), failure;
}

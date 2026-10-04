import { compileToCWithStd, compileProjectToJSWithStd } from "../helpers";

test "value storage writes require a mutable root through every access path" {
	const writes = ["s.a = 2;", "s.inner.v = 3;", "s.xs[0] = 4;", "k = 2;", "limit = 2;", "take(s);", "s.a += 1;", "k++;"];
	for (const binding of ["const", "let"]) {
		for (const body of writes) {
			const result = compileToCWithStd(`
struct Inner { v: int32; }
struct State { a: int32; inner: Inner; xs: int32[3]; }
function take(ref s: State): void { s.a = 1; }
${binding} limit: int32 = 1;
function run(): void {
	${binding} s: State = { a: 1, inner: { v: 1 }, xs: [1, 2, 3] };
	${binding} k: int32 = 1;
	${body}
	console.log(s.a, k, limit);
}
run();
`);
			assert result.ok == (binding == "let"), binding + ": " + body;
		}
	}
}

test "string byte views permit reads and detached writes but never mutable aliases" {
	const refused = [
		"const b = s.asBytes(); b[0] = 65;",
		"const b = s.asBytes(); b.push(66);",
		"const b: uint8[] = s.asBytes();",
		"const b: Span<uint8> = s.asBytes();",
		"function w(b: Span<uint8>): void {} w(s.asBytes());",
		"function view(t: string): Readonly<Span<uint8>> { return t.asBytes(); }",
		"class H { b: Readonly<uint8[]> = []; } const h = new H(); h.b = s.asBytes();",
		"const kept: Readonly<uint8[]>[] = []; kept.push(s.asBytes());",
		"function g(t: string): () => int32 { const v = t.asBytes(); return (): int32 => v[0] as int32; }",
	];
	for (const body of refused) {
		const source = `const s = "x".repeat(4); ${body}`;
		const c = compileToCWithStd(source);
		const js = compileProjectToJSWithStd([{ entryPath: "test/view.ms", entrySource: source }], "test/view.ms");
		assert !c.ok, body;
		assert js.startsWith("ERROR:"), body;
	}
	const source = `function run(): void { const s = "x".repeat(4); const view = s.asBytes(); const copy = view.slice(0, view.length); copy[0] = 65; copy.push(66); console.log(view[0], copy.asString()); } run();`;
	const c = compileToCWithStd(source);
	const js = compileProjectToJSWithStd([{ entryPath: "test/view.ms", entrySource: source }], "test/view.ms");
	assert c.ok, c.ok ? "" : c.error;
	assert !js.startsWith("ERROR:"), js;
}

test "a view borrows only from a path that outlives it and stays unchanged while it is read" {
	const refused = [
		"function f(): int32 { let v: Readonly<Span<uint8>> = \"\".asBytes(); { const s = \"ab\".repeat(2); v = s.asBytes(); } return v[0] as int32; }",
		"function f(): int32 { let v: Readonly<Span<uint8>> = \"\".asBytes(); let i = 0; while (i < 2) { const s = \"ab\".repeat(i + 1); v = s.asBytes(); i += 1; } return v.length as int32; }",
		"function f(): int32 { let s = \"ab\".repeat(2); const v = s.asBytes(); s = \"cd\".repeat(2); return v[0] as int32; }",
		"function f(): int32 { const a: uint8[] = [1, 2]; const v: Span<uint8> = a; a.push(3); return v[0] as int32; }",
		"function f(): int32 { const a: uint8[] = [1]; const v: Readonly<Span<uint8>> = a; let t: int32 = 0; for (let i = 0; i < 3; i += 1) { t += v[0] as int32; a.push(1); } return t; }",
		"function grow(a: uint8[]): void { a.push(1); } function f(): int32 { const a: uint8[] = [1, 2]; const v: Readonly<Span<uint8>> = a; grow(a); return v[0] as int32; }",
		"function mk(): string { return \"ab\".repeat(2); } function f(): int32 { const v = mk().asBytes(); return v[0] as int32; }",
		"let buf: uint8[] = [1, 2]; function f(): int32 { const v: Span<uint8> = buf; return v[0] as int32; }",
		"function f(t: string): () => int32 { const s = t; return (): int32 => { const v = s.asBytes(); return v[0] as int32; }; }",
		"struct Chunk { bytes: Readonly<Span<uint8>>; }",
		"class Holder { bytes: Span<int32>; constructor(b: Span<int32>) { this.bytes = b; } }",
		"function f(s: string): int32 { const vs: Readonly<Span<uint8>>[] = []; return vs.length as int32; }",
		"function f(vs: Span<uint8>[]): int32 { return vs.length as int32; }",

		"function f(ref n: int32): () => int32 { return (): int32 => n; }",
		"function fill(s: Span<uint8>): void { s[0] = 7; } function f(): void { const v: Vec<uint8> = new Array(2); fill(v); }",
		"function f(): void { const v: Vec<uint8> = new Array(2); const view: Span<uint8> = v; view[0] = 1; }",
		"function f(): int32 { const a: uint8[] = [1, 2]; const alias = a; const v: Readonly<Span<uint8>> = a; alias.push(9); return v[0] as int32; }",
		"function myAppend(this a: uint8[]): void { a.push(1); } function f(): int32 { const a: uint8[] = [1]; const v: Readonly<Span<uint8>> = a; a.myAppend(); return v[0] as int32; }",
		"function f(c: boolean): int32 { const a: uint8[] = [1]; const b: uint8[] = [2]; let v: Readonly<Span<uint8>> = a; if (c) { v = b; } a.push(3); return v[0] as int32; }",
		"function f(): int32 { const s = \"ab\".repeat(2); const v = s.asBytes(); { const t = s; console.log(t); } return v[0] as int32; }",
		"function f(): int32 { const s = \"ab\".repeat(2); const v = s.asBytes(); const pair = [s, \"x\"]; return (v[0] as int32) + (pair.length as int32); }",
		"function f(): int32 { const xs = [\"ab\".repeat(2)]; let t: int32 = 0; for (const s of xs) { const v = s.asBytes(); xs[0] = \"z\"; t += v[0] as int32; } return t; }",
		"function f(): int32 { const a: uint8[] = [1]; let v: Readonly<Span<uint8>> = a; a.push(2); v = a; return v.length as int32; }",
		"function f(): int32 { const a: uint8[] = [1]; let t: int32 = 0; for (let i = 0; i < 3; i += 1) { const v: Readonly<Span<uint8>> = a; t += v.length as int32; a.push(1); } return t; }",
		"function f(): int32 { const a: uint8[] = [1, 2]; const v: Readonly<Span<uint8>> = a; const i = a.indexOf(2); return (v[0] as int32) + (i as int32); }",
		"function same(a: uint8[]): uint8[] { return a; } function f(): int32 { const a: uint8[] = [1]; const v: Readonly<Span<uint8>> = a; const b = same(a); b.push(2); return v[0] as int32; }",
		"function f(): int32 { const s = \"ab\".repeat(2); const v = s.asBytes(); { const g = (): int32 => s.length as int32; console.log(g()); } return v[0] as int32; }",
		"function viewOf(a: uint8[], b: uint8[]): int32 { const v: Readonly<Span<uint8>> = a; b.push(1); return v[0] as int32; }",
		"function f(): int32 { const a: uint8[] = [1]; const grow = (): void => { a.push(1); }; const v: Readonly<Span<uint8>> = a; grow(); return v[0] as int32; }",
		"let keep: uint8[] = []; function growKeep(): void { keep.push(1); } function f(): int32 { const a: uint8[] = [1]; keep = a; const v: Readonly<Span<uint8>> = a; growKeep(); return v[0] as int32; }",
	];
	for (const body of refused) {
		const c = compileToCWithStd(body);
		const js = compileProjectToJSWithStd([{ entryPath: "test/borrow.ms", entrySource: body }], "test/borrow.ms");
		assert !c.ok, body;
		assert js.startsWith("ERROR:"), body;
	}
	const accepted = [
		"function f(text: string): int32 { const b = text.asBytes(); return b[0] as int32; }",
		"function f(): int32 { const s = \"ab\".repeat(2); const b = s.asBytes(); return b[1] as int32; }",
		"function f(): int32 { const a: uint8[] = [1, 2, 3]; const v: Span<uint8> = a; v[0] = 9; const n = a.length; return (v[0] as int32) + (n as int32); }",
		"function f(): int32 { const a: uint8[] = [1, 2]; const v: Readonly<Span<uint8>> = a; const x = v[0] as int32; a.push(3); return x; }",
		"function f(): int32 { const a: uint8[] = [1]; const v: Readonly<Span<uint8>> = a; const x = v[0] as int32; a.push(2); const w: Readonly<Span<uint8>> = a; return x + (w.length as int32); }",
		"function f(): int32 { const a: uint8[] = [1, 2]; const alias = a; const v: Readonly<Span<uint8>> = a; const n = alias.length; return (v[0] as int32) + (n as int32); }",
		"function f(): int32 { const s = \"ab\".repeat(2); const v = s.asBytes(); const i = s.indexOf(\"b\"); return (v[0] as int32) + (i as int32); }",
		"function f(): int32 { const s = \"ab\".repeat(2); const v = s.asBytes(); const x = v[0] as int32; const t = s; return x + (t.length as int32); }",
		"function copied(t: string): uint8[] { return [...t.asBytes()]; } function f(): int32 { const s = \"ab\".repeat(2); const v = s.asBytes(); const kept = copied(s); kept.push(1); return (v[0] as int32) + (kept.length as int32); }",
		"function g(ref n: int32, s: string): int32 { const v = s.asBytes(); n = v.length as int32; return v[0] as int32; }",
		"const text = \"abc\"; function f(): int32 { const b = text.asBytes(); return b[0] as int32; }",
		"function count(a: Readonly<uint8[]>): int32 { return a.length as int32; } function f(): int32 { const a: uint8[] = [1, 2]; const v: Readonly<Span<uint8>> = a; const n = count(a); return (v[0] as int32) + n; }",
		"function fill(s: Span<uint8>): void { s[0] = 7; } function f(): void { let v: Vec<uint8> = new Array(2); fill(v); }",
		"struct S { xs: uint8[]; } function f(s: S): int32 { const v: Readonly<Span<uint8>> = s.xs; return v[0] as int32; }",
		"function f(): int32 { const v: Readonly<Span<uint8>> = [5, 6]; return v[1] as int32; }",
		"function f(b: Span<uint8>): int32 { const w = b; return w.length as int32; }",
		"function f(): int32 { const a: uint8[] = [1]; const v: Readonly<Span<uint8>> = a; const x = v[0] as int32; const g = (): int32 => a.length as int32; return x + g(); }",
		"function count(a: Readonly<uint8[]>): int32 { return a.length as int32; } function f(a: uint8[]): int32 { const v: Readonly<Span<uint8>> = a; const n = count(a); return (v[0] as int32) + n; }",
		"const s = \"ab\"; const top = s.asBytes(); console.log(top[0]);",
	];
	for (const body of accepted) {
		const c = compileToCWithStd(body);
		const js = compileProjectToJSWithStd([{ entryPath: "test/borrow.ms", entrySource: body }], "test/borrow.ms");
		assert c.ok, body + (c.ok ? "" : " — " + c.error);
		assert !js.startsWith("ERROR:"), body + " — " + js;
	}
}

test "an async or generator function refuses a view or ref parameter" {
	const refused = [
		"async function g(b: Readonly<Span<uint8>>): Promise<int32> { return b[0] as int32; }",
		"async function g(b: Span<int32>): Promise<int32> { return b[0]; }",
		"async function g(ref n: int32): Promise<void> { n = 1; }",
		"function* g(b: Span<int32>): Iterator<int32> { yield b[0]; }",
		"class C { async m(b: Span<int32>): Promise<int32> { return b[0]; } }",
		"const g = async (b: Span<int32>): Promise<int32> => b[0];",
	];
	for (const body of refused) {
		const c = compileToCWithStd(body);
		const js = compileProjectToJSWithStd([{ entryPath: "test/suspparam.ms", entrySource: body }], "test/suspparam.ms");
		assert !c.ok, body;
		assert js.startsWith("ERROR:"), body;
	}
}

test "a view local does not live across an await or a yield" {
	const refused = [
		"async function f(a: uint8[]): Promise<int32> { const v: Readonly<Span<uint8>> = a; const h = spawn((): int32 => 1); await h; return v[0] as int32; }",
		"function* f(a: uint8[]): Iterator<int32> { const v: Readonly<Span<uint8>> = a; yield 1; const n = v[0] as int32; yield n; }",
	];
	for (const body of refused) {
		const c = compileToCWithStd(body);
		const js = compileProjectToJSWithStd([{ entryPath: "test/suspend.ms", entrySource: body }], "test/suspend.ms");
		assert !c.ok, body;
		assert js.startsWith("ERROR:"), body;
	}
	const accepted = [
		"async function f(a: uint8[]): Promise<int32> { const v: Readonly<Span<uint8>> = a; const n = v[0] as int32; const h = spawn((): int32 => 1); await h; return n; }",
	];
	for (const body of accepted) {
		const c = compileToCWithStd(body);
		const js = compileProjectToJSWithStd([{ entryPath: "test/suspend.ms", entrySource: body }], "test/suspend.ms");
		assert c.ok, body + (c.ok ? "" : " — " + c.error);
		assert !js.startsWith("ERROR:"), body + " — " + js;
	}
}

test "a read-only Span refuses writes and a Span binding never escapes into a closure" {
	const refused = [
		"function w(b: Readonly<Span<int32>>): void { b[0] = 1; }",
		"function w(b: Readonly<Span<int32>>): void { const m: Span<int32> = b; }",
		"function g(b: Span<int32>): () => int32 { return (): int32 => b[0]; }",
		"function g(b: Span<int32>): int32 { const f = (): int32 => b.length as int32; return f(); }",
	];
	for (const body of refused) {
		const c = compileToCWithStd(body);
		const js = compileProjectToJSWithStd([{ entryPath: "test/span.ms", entrySource: body }], "test/span.ms");
		assert !c.ok, body;
		assert js.startsWith("ERROR:"), body;
	}
	const source = `function sum(b: Readonly<Span<int32>>): int32 { let t: int32 = 0; for (const x of b) { t = t + x; } return t; }
function bump(b: Span<int32>): void { b[0] = b[0] + 1; }
const xs: int32[] = [1, 2, 3];
const ro: Readonly<int32[]> = xs;
bump(xs);
const each = (b: Readonly<Span<int32>>): int32 => sum(b);
console.log(sum(xs), sum(ro), each(xs));`;
	const c = compileToCWithStd(source);
	const js = compileProjectToJSWithStd([{ entryPath: "test/span.ms", entrySource: source }], "test/span.ms");
	assert c.ok, c.ok ? "" : c.error;
	assert !js.startsWith("ERROR:"), js;
}

test "an unprojected discriminant is not writable even through a parameter" {
	const source = `struct Point { kind: "point"; x: int32; } interface Named { kind: "named"; name: string; } export function write(value: Point | Named): void { value.kind = "point"; }`;
	const c = compileToCWithStd(source);
	assert !c.ok;
}

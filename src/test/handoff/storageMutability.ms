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

test "a mutating array method writes the value storage of its receiver" {
	const head = "struct Bag { items: Vec<int32>; shared: int32[]; }\nclass Box { items: Vec<int32> = []; }\ntype Loose = { items: Vec<int32> };\n";
	const refused = [
		"const v: Vec<int32> = [1]; v.push(2);",
		"const bag: Bag = { items: [], shared: [] }; bag.items.push(1);",
		"const rows: Vec<Vec<int32>> = [[1]]; rows[0].pop();",
		"function grow<T>(x: T): int32 { const v: Vec<T> = [x]; v.push(x); return v.length; } grow(1);",
	];
	for (const body of refused) {
		const source = head + `function run(): void { ${body} } run();`;
		const c = compileToCWithStd(source);
		const js = compileProjectToJSWithStd([{ entryPath: "test/mutator.ms", entrySource: source }], "test/mutator.ms");
		assert !c.ok && c.error.contains("is const (use 'let')"), body;
		assert js.startsWith("ERROR:") && js.contains("is const (use 'let')"), body;
	}
	const legal = head + `function run(): void {
	let v: Vec<int32> = [1]; v.push(2);
	const a: int32[] = [1]; a.push(2);
	const bag: Bag = { items: [], shared: [] }; bag.shared.push(3);
	const box = new Box(); box.items.push(4);
	const loose: Loose = { items: [] }; loose.items.push(5);
	const byKey = new HashMap<string, int32[]>(); byKey.set("k", [1]);
	const bucket = byKey.get("k"); if (bucket != null) bucket.push(6);
	console.log(v.length, a.length, bag.shared[0], box.items[0], loose.items[0], byKey.get("k")!.length);
} run();`;
	const c = compileToCWithStd(legal);
	assert c.ok, c.ok ? "" : c.error;
	const js = compileProjectToJSWithStd([{ entryPath: "test/mutator.ms", entrySource: legal }], "test/mutator.ms");
	assert !js.startsWith("ERROR:"), js;
}

test "an array receiver declared T[] writes the value storage it is called on, Vec<T> only reads it" {
	const head = "struct Bag { items: Vec<int32>; }\nclass C { n: int32 = 1; }\nfunction zero(this arr: int32[]): void { arr[0] = 0; }\nfunction firstOf<T>(this arr: Vec<T>): T { return arr[0]; }\n";
	const refused = [
		"const v: Vec<int32> = [1, 2]; v.zero();",
		"const bag: Bag = { items: [1] }; bag.items.zero();",
		"const rows: Vec<Vec<int32>> = [[1]]; rows[0].zero();",
	];
	for (const body of refused) {
		const source = head + `function run(): void { ${body} } run();`;
		const c = compileToCWithStd(source);
		const js = compileProjectToJSWithStd([{ entryPath: "test/receiver.ms", entrySource: source }], "test/receiver.ms");
		assert !c.ok && c.error.contains("cannot mutate") && c.error.contains("with 'zero'") && c.error.contains("is const (use 'let')"), body;
		assert js.startsWith("ERROR:") && js.contains("is const (use 'let')"), body;
	}
	const param = head + "function relay(v: Vec<int32>): void { v.zero(); }";
	const cp = compileToCWithStd(param);
	assert !cp.ok && cp.error.contains("value parameters are read-only views"), cp.ok ? "accepted" : cp.error;
	const legal = head + `function run(): void {
	let w: Vec<int32> = [1, 2]; w.zero();
	const shared: int32[] = [3, 4]; shared.zero();
	const v: Vec<int32> = [5, 6];
	const cs: Vec<C> = [new C()]; cs.firstOf().n = 7;
	const words: Vec<string> = ["a", "b"];
	console.log(w[0], shared[0], v.firstOf(), shared.firstOf(), cs[0].n, v.indexOf(6), v.includes(5), v.join(","),
		v.slice(1).length, v.at(0), v.concat([7]).length, v.map((x: int32, i: number): int32 => x + 1)[0], words.join("-"));
} run();`;
	const c = compileToCWithStd(legal);
	assert c.ok, c.ok ? "" : c.error;
	const js = compileProjectToJSWithStd([{ entryPath: "test/receiver.ms", entrySource: legal }], "test/receiver.ms");
	assert !js.startsWith("ERROR:"), js;
}

test "a read-only array view refuses a receiver declared T[] or Span<T>" {
	const head = "function zero(this arr: int32[]): void { arr[0] = 0; }\nfunction setFirst(this s: Span<int32>, x: int32): void { s[0] = x; }\nfunction firstOf<T>(this arr: Vec<T>): T { return arr[0]; }\n";
	const refused = [
		"const r: Readonly<int32[]> = [1, 2]; r.zero();",
		"const r: Readonly<int32[]> = [1, 2]; r.push(3);",
		"let t: int32[2] = [1, 2]; const rs: Readonly<Span<int32>> = t; rs.setFirst(5);",
		"const items: int32[] = [1]; const f = spawn(() => { items.zero(); return 0; }); await f;",
	];
	for (const body of refused) {
		const source = head + `async function run(): Promise<void> { ${body} } run();`;
		const c = compileToCWithStd(source);
		const js = compileProjectToJSWithStd([{ entryPath: "test/receiver.ms", entrySource: source }], "test/receiver.ms");
		assert !c.ok && c.error.contains("mutates its receiver") && c.error.contains("is a read-only view (PARALOCK E24)"), body;
		assert js.startsWith("ERROR:") && js.contains("mutates its receiver"), body;
	}
	const legal = head + `function run(): void {
	const r: Readonly<int32[]> = [1, 2];
	console.log(r.firstOf(), r.indexOf(2), r.join(","), r.slice(0).length, r.at(1));
} run();`;
	const c = compileToCWithStd(legal);
	assert c.ok, c.ok ? "" : c.error;
	const js = compileProjectToJSWithStd([{ entryPath: "test/receiver.ms", entrySource: legal }], "test/receiver.ms");
	assert !js.startsWith("ERROR:"), js;
}

test "a writable Span over a value container writes that container" {
	const head = "type Row = int32[2];\nstruct Holder { t: int32[4]; }\nfunction poke(s: Span<int32>, i: int32): void { s[i] = 42; }\nfunction peek(s: Readonly<Span<int32>>, i: int32): int32 { return s[i]; }\nfunction setFirst(this s: Span<int32>, x: int32): void { s[0] = x; }\nconst MODT: int32[4] = [3, 5, 7, 9];\n";
	const refused = [
		"const t: int32[4] = [1, 2, 3, 4]; poke(t, 1);",
		"poke(MODT, 1);",
		"const v: Vec<int32> = [1, 2]; poke(v, 0);",
		"const h: Holder = { t: [1, 2, 3, 4] }; poke(h.t, 0);",
		"const g: Row[2] = [[1, 2], [3, 4]]; poke(g[1], 0);",
		"const t: int32[4] = [1, 2, 3, 4]; poke(t[1..3], 0);",
		"const t: int32[4] = [1, 2, 3, 4]; t.setFirst(5);",
		"const t: int32[4] = [1, 2, 3, 4]; const w: Span<int32> = t; w[0] = 1;",
		"const t: int32[4] = [1, 2, 3, 4]; t[1..3][0] = 7;",
		"const t: int32[4] = [1, 2, 3, 4]; let w: Span<int32> = t[0..1]; w = t;",
	];
	for (const body of refused) {
		const source = head + `function run(): void { ${body} } run();`;
		const c = compileToCWithStd(source);
		const js = compileProjectToJSWithStd([{ entryPath: "test/view.ms", entrySource: source }], "test/view.ms");
		assert !c.ok && c.error.contains("is const (use 'let')"), body;
		assert js.startsWith("ERROR:") && js.contains("is const (use 'let')"), body;
	}
	const param = head + "function relay(v: Vec<int32>): void { poke(v, 0); }";
	const cp = compileToCWithStd(param);
	assert !cp.ok && cp.error.contains("value parameters are read-only views"), cp.ok ? "accepted" : cp.error;
	const legal = head + `function relay(s: Span<int32>): void { poke(s, 0); poke(s[1..2], 0); }
function run(): void {
	let t: int32[4] = [1, 2, 3, 4]; poke(t, 1); relay(t); t.setFirst(5);
	const c: int32[4] = [9, 8, 7, 6]; const r: Readonly<Span<int32>> = c;
	const a: int32[] = [1, 2]; poke(a, 0);
	console.log(t[0], t[1], peek(c, 2), peek(MODT, 3), r[1], a[0]);
} run();`;
	const c = compileToCWithStd(legal);
	assert c.ok, c.ok ? "" : c.error;
	const js = compileProjectToJSWithStd([{ entryPath: "test/view.ms", entrySource: legal }], "test/view.ms");
	assert !js.startsWith("ERROR:"), js;
}

test "a string reaches only a read-only Span, its slices too" {
	const head = "function poke(s: Span<char>): void { s[0] = 65 as char; }\nfunction setFirst(this s: Span<char>): void { s[0] = 66 as char; }\nfunction count<T>(s: Span<T>): int32 { return s.length as int32; }\nfunction title(): string { return \"abc\"; }\n";
	const refused = [
		"const lit = \"hello\"; poke(lit);",
		"let built = \"x\".repeat(3); poke(built);",
		"poke(title());",
		"const lit = \"hello\"; poke(lit[1..3]);",
		"const lit = \"hello\"; const w: Span<char> = lit;",
		"let built = \"x\".repeat(3); let w: Span<char> = built[0..1]; w = built;",
		"const lit = \"hello\"; lit.setFirst();",
		"const lit = \"hello\"; count(lit);",
		"const lit = \"hello\"; const mid = lit[1..3]; mid[0] = 65 as char;",
	];
	for (const body of refused) {
		const source = head + `function run(): void { ${body} } run();`;
		const c = compileToCWithStd(source);
		const js = compileProjectToJSWithStd([{ entryPath: "test/text.ms", entrySource: source }], "test/text.ms");
		assert !c.ok, body;
		assert js.startsWith("ERROR:"), body;
	}
	const legal = `function peek(s: Readonly<Span<char>>): int32 { return s[0] as int32; }
function size<T>(s: Readonly<Span<T>>): int32 { return s.length as int32; }
function firstOf(this s: Readonly<Span<char>>): int32 { return s[0] as int32; }
function run(): void {
	const lit = "hello";
	let built = "x".repeat(3);
	const r: Readonly<Span<char>> = built;
	const mid = lit[1..3];
	console.log(peek(lit), peek(built), peek(lit[1..2]), r.length, size(lit), lit.firstOf(), peek("raw"), mid[0]);
} run();`;
	const c = compileToCWithStd(legal);
	assert c.ok, c.ok ? "" : c.error;
	const js = compileProjectToJSWithStd([{ entryPath: "test/text.ms", entrySource: legal }], "test/text.ms");
	assert !js.startsWith("ERROR:"), js;
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
		"let buf: uint8[] = [1, 2]; function f(): int32 { const v: Span<uint8> = buf; return v[0] as int32; }",
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
		"function f(): int32 { const a: uint8[] = [1]; let v: Readonly<Span<uint8>> = a; a.push(2); v = a; return v.length as int32; }",
		"function same(a: uint8[]): uint8[] { return a; } function f(): int32 { const a: uint8[] = [1]; const v: Readonly<Span<uint8>> = a; const b = same(a); b.push(2); return v[0] as int32; }",
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
		"function mk(): string { return \"ab\".repeat(2); } function f(): int32 { const v = mk().asBytes(); return v[0] as int32; }",
		"function f(t: string): () => int32 { const s = t; return (): int32 => { const v = s.asBytes(); return v[0] as int32; }; }",
		"struct Chunk { bytes: Readonly<Span<uint8>>; }",
		"struct TextWindow { chars: Readonly<Span<char>>; }",
		"function f(): int32 { const s = \"ab\".repeat(2); const v = s.asBytes(); const pair = [s, \"x\"]; return (v[0] as int32) + (pair.length as int32); }",
		"function f(): int32 { const xs = [\"ab\".repeat(2)]; let t: int32 = 0; for (const s of xs) { const v = s.asBytes(); xs[0] = \"z\"; t += v[0] as int32; } return t; }",
		"function f(): int32 { const a: uint8[] = [1]; let t: int32 = 0; for (let i = 0; i < 3; i += 1) { const v: Readonly<Span<uint8>> = a; t += v.length as int32; a.push(1); } return t; }",
		"function f(): int32 { const a: uint8[] = [1, 2]; const v: Readonly<Span<uint8>> = a; const i = a.indexOf(2); return (v[0] as int32) + (i as int32); }",
		"function f(): int32 { const s = \"ab\".repeat(2); const v = s.asBytes(); { const g = (): int32 => s.length as int32; console.log(g()); } return v[0] as int32; }",
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

test "only a variable, a field or an element is an assignment target" {
	const head = "struct Inner { v: int32; }\nstruct P { v: int32; inner: Inner; }\nclass C { v: int32 = 0; inner: Inner = { v: 0 }; get(): int32 { return this.v; } }\n"
		+ "let p: P = { v: 1, inner: { v: 1 } };\nlet x: int32 = 0;\nconst c = new C();\n"
		+ "function g(): int32 { return 1; }\nfunction h(): P { return p; }\nfunction getC(): C { return c; }\n";
	for (const body of ["g() = 4;", "(g()) = 5;", "c.get() = 6;", "g() += 1;", "h().v = 5;", "h().inner.v = 5;"]) {
		const cr = compileToCWithStd(head + body);
		assert !cr.ok && cr.error.contains("cannot be assigned to"), body;
		const js = compileProjectToJSWithStd([{ entryPath: "test/target.ms", entrySource: head + body }], "test/target.ms");
		assert js.startsWith("ERROR:") && js.contains("cannot be assigned to"), body;
	}
	const ok = head + "(x) = 7;\nc.v = 2;\nx += g();\ngetC().v = 3;\ngetC().inner.v = 4;\np.inner.v = 5;\nconsole.log(x, c.v, c.inner.v, p.inner.v);";
	const cr = compileToCWithStd(ok);
	assert cr.ok, cr.ok ? "" : cr.error;
	const js = compileProjectToJSWithStd([{ entryPath: "test/target.ms", entrySource: ok }], "test/target.ms");
	assert !js.startsWith("ERROR:"), js;
}

test "an Arc interior binds no ref or out parameter, as it takes no write" {
	const prelude = `struct Ctr { n: int32; }
struct Holder { inner: Ctr; }
function bump(ref c: Ctr): void { c.n = 9; }
function reset(out c: Ctr): void { c = { n: 0 }; }
function heal(this ref c: Ctr): void { c.n = 5; }
function swap(ref a: Arc<Ctr>): void { a = new Arc({ n: 3 }); }
`;
	const refused = [
		"const s: Arc<Ctr> = new Arc({ n: 1 }); bump(s[]);",
		"const s: Arc<Ctr> = new Arc({ n: 1 }); reset(s[]);",
		"const s: Arc<Ctr> = new Arc({ n: 1 }); s[].heal();",
		"const h: Arc<Holder> = new Arc({ inner: { n: 2 } }); bump(h.inner);",
	];
	for (const body of refused) {
		const source = prelude + `function run(): void { ${body} } run();`;
		const c = compileToCWithStd(source);
		const js = compileProjectToJSWithStd([{ entryPath: "test/arc.ms", entrySource: source }], "test/arc.ms");
		assert !c.ok && c.error.contains("SHARE is immutable"), body;
		assert js.startsWith("ERROR:") && js.contains("SHARE is immutable"), body;
	}
}

test "an out argument written as `out b.val` reaches the field of a local" {
	const head = "struct Inner { v: int32; }\nstruct Box { val: int32; inner: Inner; }\nfunction setInt(out x: int32): void { x = 42; }\nfunction h(): Box { return { val: 0, inner: { v: 0 } }; }\n";
	const ok = head + "function run(): void { let b: Box = { val: 0, inner: { v: 0 } }; setInt(out b.val); setInt(out b.inner.v); console.log(b.val + b.inner.v); }\nrun();\n";
	const cr = compileToCWithStd(ok);
	assert cr.ok, cr.ok ? "" : cr.error;
	const js = compileProjectToJSWithStd([{ entryPath: "test/out.ms", entrySource: ok }], "test/out.ms");
	assert !js.startsWith("ERROR:"), js;
	const bad = head + "function run(): void { setInt(out h().val); }\nrun();\n";
	const cb = compileToCWithStd(bad);
	assert !cb.ok && cb.error.contains("requires a variable"), cb.ok ? "accepted" : cb.error;
}

test "a ref or out parameter never escapes into a closure" {
	const refused = [
		"function twice(ref n: int32): void { const add = (): void => { n = n + 10; }; add(); }",
		"function read(ref n: int32): () => int32 { return (): int32 => n; }",
		"function fill(out v: int32): void { const set = (): void => { v = 1; }; set(); }",
		"function grow(this ref n: int32): void { const f = (): int32 => n; n = f() + 1; }",
	];
	for (const body of refused) {
		const c = compileToCWithStd(body);
		const js = compileProjectToJSWithStd([{ entryPath: "test/ref.ms", entrySource: body }], "test/ref.ms");
		assert !c.ok && c.error.includes("which cannot be captured as it would violate memory safety"), body;
		assert js.includes("which cannot be captured as it would violate memory safety"), body;
	}
	const source = `function twice(ref n: int32): void { const add = (k: int32): int32 => k + 10; n = add(add(n)); }
let k: int32 = 1;
twice(k);
console.log(k);`;
	const c = compileToCWithStd(source);
	assert c.ok, c.ok ? "" : c.error;
}

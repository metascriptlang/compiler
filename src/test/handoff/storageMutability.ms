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
	const source = `const s = "x".repeat(4); const view = s.asBytes(); const copy = view.slice(0, view.length); copy[0] = 65; copy.push(66); console.log(view[0], copy.asString());`;
	const c = compileToCWithStd(source);
	const js = compileProjectToJSWithStd([{ entryPath: "test/view.ms", entrySource: source }], "test/view.ms");
	assert c.ok, c.ok ? "" : c.error;
	assert !js.startsWith("ERROR:"), js;
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

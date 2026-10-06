import { compileToCWithStd, compileProjectToJSWithStd } from "../helpers";

const HEAD = "struct S { n: int32; name: string; }\nstruct R { items: int32[]; k: int32; }\nclass Bag { items: S[] = []; count: int32 = 0; }\n"
	+ "struct World { pets: S[]; k: int32; }\n"
	+ "function grow(ref a: S[]): void { a.push({ n: 2, name: \"g\" }); }\n"
	+ "function growShared(a: S[]): void { a.push({ n: 2, name: \"g\" }); }\n"
	+ "function growBag(b: Bag): void { b.items.push({ n: 2, name: \"g\" }); }\n"
	+ "function take(a: S[]): int32 { return a.length as int32; }\n"
	+ "function kOf(this w: World): int32 { return w.k; }\n"
	+ "function bump(p: Ptr<S>): void { p[].n = p[].n + 1; }\n";

function compiles(body: string): string {
	const source = HEAD + `function run(): int32 { ${body} } run();`;
	const c = compileToCWithStd(source);
	const js = compileProjectToJSWithStd([{ entryPath: "test/views.ms", entrySource: source }], "test/views.ms");
	if (c.ok && !js.startsWith("ERROR:")) return "";
	if (!c.ok && js.startsWith("ERROR:")) return c.error + "\n" + js;
	return "backends disagree: " + (c.ok ? "C ok" : c.error) + " / " + js;
}

function refusedWith(body: string, needle: string): boolean {
	const errors = compiles(body);
	return errors != "" && !errors.startsWith("backends disagree") && errors.split(needle).length >= 3;
}

test "a view is refused while the storage it reads can move or be freed" {
	const xs = "let xs: S[] = [{ n: 1, name: \"a\" }];";
	const refused = [
		`${xs} const sp: Span<S> = xs; xs.push({ n: 2, name: "b" }); return sp[0].n;`,
		`${xs} const sp = xs as Span<S>; for (let i = 0; i < 9; i++) { xs.push({ n: i, name: "c" }); } return sp[0].n;`,
		`${xs} const sp: Span<S> = xs; while (sp.length < 4) { xs.push({ n: 2, name: "b" }); } return sp[0].n;`,
		`${xs} const sp: Span<S> = xs; xs = [{ n: 7, name: "d" }]; return sp[0].n;`,
		`${xs} const sp: Span<S> = xs; grow(xs); return sp[0].n;`,
		`${xs} const sp: Span<S> = xs; growShared(xs); return sp[0].n;`,
		"const b = new Bag(); const sp: Span<S> = b.items; growBag(b); return sp.length as int32;",
		"const b = new Bag(); const sp: Span<S> = b.items; b.items.push({ n: 3, name: \"e\" }); return sp.length as int32;",
		`${xs} const sp: Span<S> = xs; const w: Span<S> = sp[0..1]; xs.push({ n: 3, name: "f" }); return w[0].n;`,
		`${xs} const sp: Span<S> = xs; const alias = xs; alias.push({ n: 2, name: "b" }); return sp[0].n;`,
		`${xs} const sp: Span<S> = xs; const k = take(move xs); return sp[0].n + k;`,
		`${xs} const sp: Span<S> = xs; if (sp.length > 0) { const t = xs; } return sp[0].n;`,
		"let s = \"ab\" + String(1); const b = s.asBytes(); s = \"x\"; return b[0] as int32;",
		"let rows: R[] = [{ items: [1, 2], k: 0 }]; const v: Span<int32> = rows[0].items; rows[0] = { items: [7], k: 1 }; return v[0];",
	];
	for (const body of refused) {
		assert refusedWith(body, "is potentially changed at"), body;
	}
}

test "a view stays legal when nothing can move the storage it reads" {
	const xs = "let xs: S[] = [{ n: 1, name: \"a\" }];";
	const legal = [
		`${xs} const sp: Span<S> = xs; const first = sp[0].n; xs.push({ n: 2, name: "b" }); return first;`,
		`${xs} let t: int32 = 0; for (let i = 0; i < 3; i++) { const sp: Span<S> = xs; t += sp[0].n; xs.push({ n: i, name: "c" }); } return t;`,
		`${xs} const sp: Span<S> = xs; const k = xs.indexOf(xs[0]); return sp[0].n + (k as int32) + (xs.length as int32);`,
		`${xs} const sp: Span<S> = xs; xs[0].n = 5; xs[0] = { n: 9, name: "z" }; xs[0].name = "y"; return sp[0].n;`,
		"const b = new Bag(); b.items.push({ n: 1, name: \"a\" }); const sp: Span<S> = b.items; b.count = 3; return sp[0].n + b.count;",
		"let rows: R[] = [{ items: [1, 2], k: 0 }]; const v: Span<R> = rows; rows[0].items.push(3); rows[0].k = 5; return v[0].k;",
		"const w: World = { pets: [{ n: 4, name: \"p\" }], k: 2 }; const sp: Span<S> = w.pets; const k = w.kOf(); return sp[0].n + k;",
		"const s = \"ab\" + String(1); const b = s.asBytes(); const t = s + \"!\"; return (b[0] as int32) + (t.length as int32);",
		`${xs} const sp: Span<S> = xs; if (sp.length > 0) { xs.push({ n: 2, name: "b" }); } return xs.length as int32;`,
	];
	for (const body of legal) {
		assert compiles(body) == "", body;
	}
}

test "a view borrows only from a path that outlives it" {
	const body = "const outer: S[] = []; let sp: Span<S> = outer; { const inner: S[] = [{ n: 1, name: \"a\" }]; sp = inner; } return sp.length as int32;";
	assert refusedWith(body, "which does not live long enough"), body;
}

test "a pointer into array storage is refused while the array can grow" {
	const refused = [
		"let xs: S[] = [{ n: 1, name: \"a\" }]; const p = xs[0] as Ptr<S>; for (let i = 0; i < 9; i++) { xs.push({ n: i, name: \"b\" }); } return p[].n;",
		"let xs: S[] = [{ n: 1, name: \"a\" }]; const sp: Span<S> = xs; const p = sp as Ptr<S>; xs = []; return p[].n;",
	];
	for (const body of refused) {
		assert refusedWith(body, "which is potentially changed at"), body;
	}
	const legal = [
		"let s: S = { n: 1, name: \"a\" }; const p = s as Ptr<S>; s.n = 4; s = { n: 5, name: \"b\" }; s.name = \"c\"; bump(p); return p[].n;",
		"let arr: S[2] = [{ n: 1, name: \"x\" }, { n: 2, name: \"y\" }]; const q = arr[1] as Ptr<S>; arr[0] = { n: 9, name: \"z\" }; return q[].n;",
		"let xs: S[] = [{ n: 1, name: \"a\" }]; const p = xs[0] as Ptr<S>; xs[0].n = 3; const n = p[].n; xs.push({ n: 2, name: \"b\" }); return n;",
	];
	for (const body of legal) {
		assert compiles(body) == "", body;
	}
}

test "a local's address never outlives its frame" {
	const heads = [
		"function leak(): Ptr<S> { let s: S = { n: 5, name: \"a\" }; return s as Ptr<S>; }",
		"class Holder { p: Ptr<S> = null as unknown as Ptr<S>; }\nfunction keep(h: Holder): void { let s: S = { n: 5, name: \"a\" }; h.p = s as Ptr<S>; }",
		"let g: Ptr<S> = null as unknown as Ptr<S>;\nfunction keep(): void { let s: S = { n: 5, name: \"a\" }; g = s as Ptr<S>; }",
		"function keep(out: Ptr<S>[]): void { let s: S = { n: 5, name: \"a\" }; out.push(s as Ptr<S>); }",
		"function keep(ref p: Ptr<S>): void { let s: S = { n: 5, name: \"a\" }; p = s as Ptr<S>; }",
		"struct W { link: Ptr<S>; }\nfunction leak(): W { let s: S = { n: 5, name: \"a\" }; const p = s as Ptr<S>; const w: W = { link: p }; return w; }",
		"struct In { n: int32; }\nstruct O { inner: In; }\nfunction leak(): Ptr<In> { let o: O = { inner: { n: 5 } }; return o.inner as Ptr<In>; }",
	];
	for (const head of heads) {
		const source = HEAD + head + "\n";
		const c = compileToCWithStd(source);
		const js = compileProjectToJSWithStd([{ entryPath: "test/frame.ms", entrySource: source }], "test/frame.ms");
		assert !c.ok && c.error.includes("escapes its stack frame"), head;
		assert js.startsWith("ERROR:") && js.includes("escapes its stack frame"), head;
	}
	const legal = [
		"let s: S = { n: 5, name: \"a\" }; const p = s as Ptr<S>; bump(p); bump(s as Ptr<S>); return s.n;",
		"const xs: S[] = [{ n: 7, name: \"a\" }]; const p = xs[0] as Ptr<S>; return p[].n;",
	];
	for (const body of legal) {
		assert compiles(body) == "", body;
	}
	const kept = HEAD + "function first(xs: S[]): Ptr<S> { return xs[0] as Ptr<S>; }\nfunction firstOf(ref s: S): Ptr<S> { return s as Ptr<S>; }\n";
	assert compileToCWithStd(kept).ok;
}

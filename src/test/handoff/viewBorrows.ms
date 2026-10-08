import { compileToCWithStd, compileProjectToJSWithStd } from "../helpers";

const HEAD = "struct S { n: int32; name: string; }\nstruct R { items: int32[]; k: int32; }\nclass Bag { items: S[] = []; count: int32 = 0; }\n"
	+ "struct World { pets: S[]; k: int32; }\nstruct L { tags: Vec<int32>; n: int32; }\n"
	+ "function grow(ref a: S[]): void { a.push({ n: 2, name: \"g\" }); }\n"
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
		`${xs} const sp: Span<S> = xs; const k = take(xs); return sp[0].n + k;`,
		`${xs} const sp: Span<S> = xs; const kept = xs; return sp[0].n + (kept.length as int32);`,
		"let arr: S[2] = [{ n: 1, name: \"a\" }, { n: 2, name: \"b\" }]; const sp: Span<S> = arr; arr = [{ n: 3, name: \"c\" }, { n: 4, name: \"d\" }]; return sp[0].n;",
	];
	for (const body of legal) {
		assert compiles(body) == "", body;
	}
}

test "a generic routine is checked in each instance" {
	const view = "function firstAfter<T>(xs: T[], x: T): T { const sp: Span<T> = xs; xs.push(x); return sp[0]; }\nfirstAfter([1, 2], 3);";
	const frame = "function leakOf<T>(x: T): Ptr<T> { let s: T = x; return s as Ptr<T>; }\nstruct G { n: int32; }\nleakOf<G>({ n: 1 });";
	const legal = "function firstThen<T>(xs: T[], x: T): T { const sp: Span<T> = xs; const f = sp[0]; xs.push(x); return f; }\nfirstThen([1, 2], 3);";
	for (const source of [view, frame]) {
		const c = compileToCWithStd(source);
		const js = compileProjectToJSWithStd([{ entryPath: "test/generic.ms", entrySource: source }], "test/generic.ms");
		assert !c.ok && (c.error.includes("is potentially changed at") || c.error.includes("escapes its stack frame")), source;
		assert js.startsWith("ERROR:"), source;
	}
	assert compileToCWithStd(legal).ok;
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
		"let bag: L = { tags: [1], n: 0 }; const field = bag.tags as Ptr<Vec<int32>>; bag = { tags: [4, 5, 6], n: 1 }; return field[].length as int32;",
		"let xs: S[] = [{ n: 1, name: \"a\" }]; const view = xs[0] as Ptr<S>; const inner = xs[0] as Ptr<S>; view[] = { n: 2, name: \"b\" }; return inner[].n;",
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

test "a Borrow<T> local is refused while its place is changed in place" {
	const refused = [
		"let n: int32 = 1; const b: Borrow<int32> = n; n = 2; return b;",
		"let n: int32 = 1; const b: Borrow<int32> = n; n++; return b;",
		"let n: int32 = 1; const b: Borrow<int32> = n; n += 3; return b;",
		"let s: S = { n: 1, name: \"a\" }; const b: Borrow<int32> = s.n; s.n = 5; return b;",
		"let s: S = { n: 1, name: \"a\" }; const b: Borrow<int32> = s.n; s = { n: 8, name: \"b\" }; return b;",
		"const xs: int32[] = [1, 2]; const b: Borrow<int32> = xs[0]; xs[0] = 7; return b;",
		"const xs: S[] = [{ n: 1, name: \"a\" }]; const b: Borrow<S> = xs[0]; xs[0] = { n: 9, name: \"z\" }; return b.n;",
		"const xs: int32[] = [1, 2]; const b: Borrow<int32[]> = xs; xs.push(3); return b.length as int32;",
		"const xs: int32[] = [1, 2]; const sp: Span<int32> = xs; const b: Borrow<int32> = xs[0]; sp[0] = 4; return b;",
	];
	for (const body of refused) {
		assert refusedWith(body, "is potentially changed at"), body;
	}
	const legal = [
		"let s: S = { n: 1, name: \"a\" }; const b: Borrow<int32> = s.n; s.name = \"q\"; const e: Borrow<S> = s; return b + e.n;",
		"let n: int32 = 1; const b: Borrow<int32> = n; const k = b; n = 2; return k + n;",
		"const xs: int32[] = [1, 2]; const sp: Span<int32> = xs; xs[0] = 7; return sp[0];",
		"let s: S = { n: 1, name: \"a\" }; const e: Borrow<S> = s; s.n = 4; return e.n;",
	];
	for (const body of legal) {
		assert compiles(body) == "", body;
	}
}

test "a Borrow<T> local is a read-only view of a place" {
	const writes = [
		"let s: S = { n: 1, name: \"a\" }; const b: Borrow<S> = s; b.n = 2; return s.n;",
		"let s: S = { n: 1, name: \"a\" }; let b: Borrow<S> = s; const t: S = { n: 2, name: \"b\" }; b = t; return b.n;",
		"const xs: int32[] = [1, 2]; const b: Borrow<int32[]> = xs; b[0] = 5; return xs[0];",
		"const xs: int32[] = [1, 2]; const b: Borrow<int32[]> = xs; b[0] += 5; return xs[0];",
		"const xs: int32[] = [1, 2]; const b: Borrow<int32[]> = xs; b.push(3); return xs[0];",
		"const bag = new Bag(); const b: Borrow<Bag> = bag; b.count = 2; return bag.count;",
		"const bag = new Bag(); const b: Borrow<Bag> = bag; b.items.push({ n: 1, name: \"a\" }); return bag.count;",
		"let xs: S[] = [{ n: 1, name: \"a\" }]; const b: Borrow<S[]> = xs; grow(b); return xs[0].n;",
		"const xs: int32[] = [1, 2]; const b: Borrow<int32[]> = xs; const sp: Span<int32> = b; return sp[0];",
	];
	for (const body of writes) {
		assert refusedWith(body, "is a read-only Borrow<T> view"), body;
	}
	assert refusedWith("const b: Borrow<S> = { n: 1, name: \"a\" }; return b.n;", "cannot borrow from this expression"), "literal";
	assert refusedWith("const b: Borrow<int32> = take([]); return b;", "cannot borrow from this expression"), "call result";
	assert refusedWith("const xs: int32[] = [1]; const b: Borrow<int32[]> = xs; const f = (): int32 => b.length as int32; return f();", "cannot be captured"), "closure";
	assert compiles("const xs: int32[] = [1, 2]; const b: Borrow<int32[]> = xs; const r: Readonly<Span<int32>> = b; return r[0] + b[1];") == "", "a read-only view of the borrowed array";
}

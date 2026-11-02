import { compileToCWithStd, compileProjectToJSWithStd } from "../helpers";

test "a view struct borrows through field writes, spreads and view calls, and is never written through ref or out" {
	const chunk = "struct Chunk { bytes: Readonly<Span<uint8>>; n: int32; }\n";
	const tok = "struct Tok { text: Readonly<Span<char>>; }\n";
	const box = "struct Box<T> { v: Readonly<Span<T>>; n: int32; }\n";
	const buf = "struct Buf { data: Readonly<Span<uint8>>; base: int32; size: int32; cursor: int32; }\n";
	const w32 = "struct W { s: Readonly<Span<int32>>; n: int32; }\nfunction fill(n: int32, v: int32): int32[] { const xs: int32[] = []; for (let i = 0; i < n; i++) xs.push(v); return xs; }\n";
	const fill = "const xs: uint8[] = []; for (let i = 0; i < 64; i++) xs.push(7);";
	const owner = "class Owner { data: uint8[] = []; constructor() { for (let i = 0; i < 64; i++) this.data.push(7); } view(): Chunk { return { bytes: this.data, n: 1 }; } }\n";
	const refused = [
		[chunk + `function mk(first: Readonly<Span<uint8>>): Chunk { let c: Chunk = { bytes: first, n: 1 }; ${fill} c.bytes = xs; return c; }`, "'xs' escapes its stack frame: 'mk' returns Chunk"],
		[chunk + `function setTo(this ref c: Chunk, xs: Readonly<Span<uint8>>): void { c.bytes = xs; }\nfunction mk(first: Readonly<Span<uint8>>): Chunk { let c: Chunk = { bytes: first, n: 1 }; ${fill} c.setTo(xs); return c; }`, "'c' is a ref or out parameter, so a view cannot be written through it"],
		[chunk + `function fill(out r: Chunk): void { ${fill} r = { bytes: xs, n: 64 }; }`, "'r' is a ref or out parameter, so a view cannot be written through it"],
		[chunk + `function fill(ref r: Chunk): void { ${fill} r.bytes = xs; }`, "'r' is a ref or out parameter, so a view cannot be written through it"],
		[chunk + "function setTo(this ref c: Chunk, xs: Readonly<Span<uint8>>): void { c.bytes = xs; }", "'c' is a ref or out parameter, so a view cannot be written through it"],
		[chunk + "function fill(out r: Chunk, xs: Readonly<Span<uint8>>): void { r = { bytes: xs, n: 1 }; }", "'r' is a ref or out parameter, so a view cannot be written through it"],
		["function reslice(ref s: Readonly<Span<uint8>>, xs: Readonly<Span<uint8>>): void { s = xs; }", "'s' is a ref or out parameter, so a view cannot be written through it"],
		[buf + "function subrs(cff: Buf, dict: Buf): Buf { let d = dict; return d; }", "'dict' is not the first parameter"],
		[tok + "function mk(): Tok { const s = \"ab\".repeat(40); const t: Tok = { text: s }; return { ...t }; }", "'s' escapes its stack frame: 'mk' returns Tok"],
		[chunk + `async function h() { ${fill} const c: Chunk = { bytes: xs, n: 1 }; return c; }`, "a return value of type Promise<Chunk> cannot hold Chunk, a struct that holds Readonly<Span<uint8>> inside it"],
		[chunk + owner + "function run(): int32 { const o = new Owner(); const c = o.view(); o.data = []; return c.bytes[0] as int32; }", "cannot borrow 'c': what it borrows from ('o')"],
		[chunk + "class Box2<T> { v: T; constructor(v: T) { this.v = v; } }\nlet g2: unknown = null;\nfunction stash(c: Chunk): void { g2 = new Box2<Chunk>(c); }", "type argument 'Chunk' of 'Box2' cannot hold Chunk, a struct that holds Readonly<Span<uint8>>"],
		[box + "class K { b: Box<uint8>; constructor(b: Box<uint8>) { this.b = b; } }", "field 'b' of 'K' cannot hold Box<uint8>, a struct that holds"],
		[box + "let g: Box<uint8> | null = null;", "'g' lives for the whole program and cannot hold Box<uint8>, a struct that holds"],
		[box + "function f(a: Readonly<Span<uint8>>): int32 { const bs: Box<uint8>[] = [{ v: a, n: 1 }]; return bs.length as int32; }", "cannot hold Box<uint8>, a struct that holds"],
		["struct N { v: Readonly<Span<uint8>>; next: N | null; }\nfunction f(n: N): int32 { return 0; }", "a struct cannot contain itself"],
		["struct A { v: Readonly<Span<uint8>>; b: B | null; }\nstruct B { a: A | null; }\nfunction f(x: A): int32 { return 0; }\nfunction g(x: B): int32 { return 0; }", "a struct cannot contain itself"],
		[chunk + "struct Pair { cs: Chunk[2]; }", "field 'cs' of 'Pair' of type Chunk[2] cannot hold Chunk, a struct that holds Readonly<Span<uint8>> inside it"],
		[w32 + "function f(a: int32[8]): W { return { s: a, n: 1 }; }", "'a' is owned by the call, so it is freed at the return"],
		[w32 + "function f(sink xs: int32[]): W { return { s: xs, n: 1 }; }", "'xs' is owned by the call, so it is freed at the return"],
		[w32 + "struct Pair<A> { a: A; k: int32; }\nfunction run(): int32 { let xs = fill(64, 0); const p: Pair<W> = { a: { s: xs, n: 1 }, k: 2 }; xs = fill(64, 500); return p.a.s[3]; }", "cannot borrow 'p'"],
		[w32 + "class O { data: int32[] = fill(64, 0); }\nstruct S { o: O; n: int32; }\nfunction view(this s: S): W { return { s: s.o.data, n: 1 }; }\nfunction run(): int32 { const s: S = { o: new O(), n: 1 }; const c = s.view(); s.o.data = fill(64, 500); return c.s[3]; }", "cannot borrow 'c'"],
		[w32 + "struct Bag { s: Readonly<Span<int32>>; items: int32[]; }\nfunction grow(this ref b: Bag): void { for (let i = 0; i < 64; i++) b.items.push(i); }\nfunction run(): int32 { const xs = fill(4, 0); let b: Bag = { s: xs, items: [1] }; const v: Readonly<Span<int32>> = b.items; b.grow(); return v[0]; }", "cannot borrow 'v'"],
		[w32 + "struct S { s: Span<int32[]>; n: int32; }\nfunction bump(ref c: S): void { c.s[0] = fill(64, 500); c.n += 1; }\nfunction run(): int32 { const rows: int32[][] = [fill(64, 0)]; let c: S = { s: rows, n: 0 }; const v: Readonly<Span<int32>> = rows[0]; bump(c); return v[3]; }", "cannot borrow 'v'"],
		["struct T { text: Readonly<Span<char>>; name: string; n: int32; }\nfunction bump(ref c: T): void { c.name = \"zz\".repeat(30); }\nfunction run(): int32 { const s = \"ab\".repeat(20); let c: T = { text: s, name: \"q\".repeat(20), n: 0 }; const v: Readonly<Span<char>> = c.name; bump(c); return v.length as int32; }", "cannot borrow 'v'"],
		[w32 + "function f(ref r: W, xs: Readonly<Span<int32>>): void { [r] = [{ s: xs, n: 1 }]; }", "'r' is a ref or out parameter, so a view cannot be written through it"],
		[w32 + "function f(ref r: W, xs: Readonly<Span<int32>>): void { ({ r } = { r: { s: xs, n: 1 } }); }", "'r' is a ref or out parameter, so a view cannot be written through it"],
		[w32 + "function f(ref r: W, xs: Readonly<Span<int32>>): void { const p = r as Ptr<W>; p[0] = { s: xs, n: 1 }; }", "'r' is a ref or out parameter that holds a view, so its address cannot be taken"],
		[w32 + "struct P { buf: int32[2]; n: int32; }\nfunction view(p: P): W { return { s: p.buf, n: p.n }; }", "'p' is owned by the call, so it is freed at the return"],
		[w32 + "struct P { buf: int32[16]; n: int32; }\nfunction view(this p: P): W { return { s: p.buf, n: p.n }; }", "'p' is owned by the call, so it is freed at the return"],
		[w32 + "struct Q { items: int32[]; n: int32; }\nfunction view(q: Q): W { return { s: q.items, n: q.n }; }\nfunction run(): int32 { const keep = fill(4, 1); let w: W = { s: keep, n: 0 }; { const inner = fill(64, 8); w = view({ items: inner, n: 1 }); } return w.s[3]; }", "'w' borrows from a temporary that ends with its block"],
		[w32 + "struct Q { items: int32[]; n: int32; }\nfunction view(q: Q): W { return { s: q.items, n: q.n }; }\nfunction mk(n: int32): W { return view({ items: fill(64, 7), n: n }); }", "cannot borrow from a temporary: 'mk' returns W"],
		[w32 + "function run(k: int32, a: Readonly<Span<int32>>): int32 { const r: W = k > 0 ? { s: a, n: 1 } : { s: fill(64, 9), n: 2 }; return r.s[3]; }", "'r' borrows from a temporary made in a branch"],
		[w32 + "function run(o: W | null): int32 { const r: W = o ?? { s: fill(64, 9), n: 2 }; return r.s[3]; }", "'r' borrows from a temporary made in a branch"],
		[w32 + "function run(): int32 { const outer = fill(4, 1); let t: W = { s: outer, n: 1 }; { const inner = fill(64, 8); const u: W = { s: inner, n: 2 }; [t] = [u]; } return t.s[3]; }", "cannot borrow 't': what it borrows from ('inner')"],
		[w32 + "function run(): int32 { const outer = fill(4, 1); let t: W = { s: outer, n: 1 }; let k = 0; { const inner = fill(64, 8); const u: W = { s: inner, n: 2 }; [t, k] = [u, 1]; } return t.s[3] + k; }", "cannot borrow 't': what it borrows from ('inner')"],
		[w32 + "struct Q { items: int32[]; n: int32; }\nfunction view(q: Q): W { return { s: q.items, n: q.n }; }\nfunction run(): int32 { const keep = fill(4, 1); let w: W = { s: keep, n: 0 }; { w = view({ items: fill(64, 7), n: 1 } as Q); } return w.s[3]; }", "'w' borrows from a temporary that ends with its block"],
		[w32 + "struct Q { items: int32[]; n: int32; }\nfunction view(q: Q): W { return { s: q.items, n: q.n }; }\nfunction run(k: int32): int32 { const keep = fill(4, 1); let w: W = { s: keep, n: 0 }; { w = view(k > 0 ? { items: fill(64, 7), n: 1 } : { items: fill(64, 9), n: 2 }); } return w.s[3]; }", "'w' borrows from a temporary that ends with its block"],
		[w32 + "struct Q { items: int32[]; n: int32; }\nfunction view(q: Q): W { return { s: q.items, n: q.n }; }\nfunction mk(k: int32): W { return view(k > 0 ? { items: fill(64, 7), n: 1 } : { items: fill(64, 9), n: 2 }); }", "cannot borrow from a temporary: 'mk' returns W"],
		["struct Tok { text: Readonly<Span<char>>; }\nstruct T2 { name: string; n: int32; }\nfunction tv(t: T2): Tok { return { text: t.name }; }\nfunction mk(): Tok { return tv({ name: \"ab\".repeat(40), n: 1 }); }", "cannot borrow from a temporary: 'mk' returns Tok"],
		[w32 + "struct P { buf: int32[2]; n: int32; }\nfunction view(p: P | null): W { return { s: p!.buf, n: 1 }; }", "'p' is owned by the call, so it is freed at the return"],
	];
	const missed: string[] = [];
	for (const row of refused) {
		const c = compileToCWithStd(row[0]);
		const js = compileProjectToJSWithStd([{ entryPath: "test/viewStruct.ms", entrySource: row[0] }], "test/viewStruct.ms");
		if (c.ok || c.error.indexOf(row[1]) < 0) missed.push(row[0] + " — C: " + (c.ok ? "compiled" : c.error));
		if (!js.startsWith("ERROR:") || js.indexOf(row[1]) < 0) missed.push(row[0] + " — JS: " + js);
	}
	const accepted = [
		tok + "function tag(b: Tok, label: string): Tok { return b; }\nfunction outer(b: Tok, label: string): Tok { return tag(b, label); }",
		tok + "function sub(this b: Tok, label: string): Tok { return b; }\nfunction outer2(b: Tok, label: string): Tok { return b.sub(label); }",
		tok + "function cp(t: Tok): Tok { return { ...t }; }",
		chunk + "function bump(this ref c: Chunk): void { c.n += 1; }\nfunction twice(this ref c: Chunk): int32 { c.bump(); c.bump(); return c.n; }",
		buf + "function range(this b: Buf, at: int32, size: int32): Buf { if (at < 0) { return { data: b.data, base: 0, size: 0, cursor: 0 }; } return { data: b.data, base: b.base + at, size: size, cursor: 0 }; }\nfunction get8(this ref b: Buf): int32 { const v = b.data[b.base + b.cursor] as int32; b.cursor += 1; return v; }\nfunction readIndex(this ref b: Buf): Buf { const start = b.cursor; b.get8(); return b.range(start, b.cursor - start); }\nfunction indexGet(index: Buf, i: int32): Buf { let b = index; b.cursor = i; return b.range(i, 1); }\nfunction subrs(cff: Buf, dict: Buf): Buf { let d = dict; d.get8(); let source = cff; return source.readIndex(); }",
		chunk + owner + "function run(): int32 { const o = new Owner(); const c = o.view(); return c.bytes[0] as int32; }",
		box + "function first(b: Box<uint8>): int32 { return b.v[0] as int32; }",
		w32 + "struct Q { items: int32[]; n: int32; }\nfunction view(q: Q): W { return { s: q.items, n: q.n }; }\nfunction run(): int32 { const inner = fill(8, 1); const w = view({ items: inner, n: 1 }); return w.s[3]; }",
		w32 + "function pick(k: int32, a: Readonly<Span<int32>>, b: Readonly<Span<int32>>): int32 { const r: W = k > 0 ? { s: a, n: 1 } : { s: b, n: 2 }; return r.s[0]; }",
		w32 + "function run(): int32 { const a = fill(4, 1); const b = fill(4, 2); let t: W = { s: a, n: 1 }; const u: W = { s: b, n: 2 }; [t] = [u]; return t.s[0]; }",
		w32 + "class O { data: int32[] = fill(64, 0); }\nstruct S { o: O; n: int32; }\nfunction view(this s: S): W { return { s: s.o.data, n: 1 }; }\nfunction run(): int32 { let s: S = { o: new O(), n: 1 }; const c = s.view(); s.n = 2; return c.s[3]; }",
		w32 + "function advance(this ref w: W, k: int32): void { w.n += k; }\nfunction run(): int32 { const xs = fill(4, 1); let w: W = { s: xs, n: 0 }; w.advance(2); w.advance(1); return w.s[0] + w.n; }",
		w32 + "function clear(ref r: W | null): void { r = null; }\nfunction run(): int32 { const xs = fill(4, 1); let r: W | null = { s: xs, n: 0 }; clear(r); return r == null ? 1 : 0; }",
		w32 + "function run(k: int32, a: Readonly<Span<int32>>): int32 { const r: Readonly<Span<int32>> = k > 0 ? a : fill(64, 9); return r[3]; }",
		w32 + "function none(): W { return { s: [], n: 0 }; }",
		w32 + "struct Q { items: int32[]; n: int32; }\nfunction view(q: Q): W { return { s: q.items, n: q.n }; }\nfunction run(k: int32): int32 { const w = view(k > 0 ? { items: fill(64, 7), n: 1 } : { items: fill(64, 9), n: 2 }); return w.s[3]; }",
	];
	for (const body of accepted) {
		const c = compileToCWithStd(body);
		const js = compileProjectToJSWithStd([{ entryPath: "test/viewStruct.ms", entrySource: body }], "test/viewStruct.ms");
		if (!c.ok) missed.push(body + " — C: " + c.error);
		if (js.startsWith("ERROR:")) missed.push(body + " — JS: " + js);
	}
	assert missed.length == 0, missed.join("\n");
}

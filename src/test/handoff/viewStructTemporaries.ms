import { compileToCWithStd, compileProjectToJSWithStd } from "../helpers";

test "a view struct is a path from a parameter or a longer-lived local, never from a temporary" {
	const chunk = "struct Chunk { bytes: Readonly<Span<uint8>>; n: int32; }\nstruct Pair { c: Chunk; k: int32; }\nfunction wrapC(a: Readonly<Span<uint8>>): Chunk { return { bytes: a, n: 1 }; }\n";
	const fill = "const xs: uint8[] = []; for (let i = 0; i < 64; i++) xs.push(7);";
	const refused = [
		[chunk + `function mk(first: Chunk, k: int32): Chunk { ${fill} const local: Chunk = { bytes: xs, n: 2 }; const c = match (k) { 0 => first, _ => local }; return c; }`, "'xs' escapes its stack frame: 'mk' returns Chunk"],
		[chunk + "function mk(a: uint8[]): Chunk { const c: Chunk = { bytes: a, n: 1 }; try { return c; } finally { a.push(3); } }", "by a finally or defer that runs after the return: 'mk' returns Chunk"],
		[chunk + "function mk(a: uint8[]): Chunk { defer { a.push(3); } return { bytes: a, n: 1 }; }", "by a finally or defer that runs after the return: 'mk' returns Chunk"],
		[chunk + `function fill3(out r: Chunk, a: uint8[]): void { r = { bytes: a, n: 1 }; }\nfunction run(): int32 { let r: Chunk; { const xs: uint8[] = [7, 7]; fill3(out r, xs); } return r.bytes[0] as int32; }`, "'r' is a ref or out parameter, so a view cannot be written through it"],
		[chunk + `function fill4(xs: Readonly<Span<uint8>>, out r: Chunk): void { r = { bytes: xs, n: 1 }; }\nfunction run(): int32 { let r: Chunk; { const xs: uint8[] = [7, 7]; fill4(xs, out r); } return r.bytes[0] as int32; }`, "'r' is a ref or out parameter, so a view cannot be written through it"],
		[chunk + `function fill4(xs: Readonly<Span<uint8>>, out r: Chunk): void { r = { bytes: xs, n: 1 }; }\nfunction mk(): Chunk { let r: Chunk; const xs: uint8[] = [7, 7]; fill4(xs, out r); return r; }`, "'r' is a ref or out parameter, so a view cannot be written through it"],
		[chunk + `function setArr(this ref c: Chunk, a: uint8[]): void { c.bytes = a; }\nfunction mk(first: Readonly<Span<uint8>>): Chunk { let c: Chunk = { bytes: first, n: 1 }; const xs: uint8[] = [7, 7]; c.setArr(xs); return c; }`, "'c' is a ref or out parameter, so a view cannot be written through it"],
		[chunk + "function mk(): Chunk { const c = wrapC([7, 7]); return c; }", "'c' borrows from a temporary: 'mk' returns Chunk"],
		[chunk + "function mk(): Chunk { const c: Chunk = { bytes: [7, 7], n: 1 }; return c; }", "'c' borrows from a temporary: 'mk' returns Chunk"],
		[chunk + "function mk(): Chunk { const c = wrapC(wrapC([7, 7]).bytes); return c; }", "'c' borrows from a temporary: 'mk' returns Chunk"],
		["struct Tok { text: Readonly<Span<char>>; }\nfunction mk(): Tok { const t: Tok = { text: \"ab\".repeat(40) }; return t; }", "'t' borrows from a temporary: 'mk' returns Tok"],
		[chunk + "function fill5(out r: Chunk): void { const c = wrapC([1, 2]); r = c; }", "'r' is a ref or out parameter, so a view cannot be written through it"],
		[chunk + "class Holder<T> { v: T; constructor(v: T) { this.v = v; } }\nclass Sub extends Holder<Chunk> { constructor(c: Chunk) { super(c); } }", "type argument 'Chunk' of 'Holder"],
		[chunk + "class Bag<T> { items: T[] = []; add(v: T): void { this.items.push(v); } }\nclass ChunkBag extends Bag<Chunk> {}", "type argument 'Chunk' of 'Bag"],
		[chunk + `function run(): int32 { ${fill} const p: Pair = { c: { bytes: xs, n: 1 }, k: 2 }; const { c } = p; xs.push(1); return c.bytes[0] as int32; }`, "cannot borrow 'c': what it borrows from ('xs') is potentially changed"],
		[chunk + `function run(): int32 { ${fill} const c0: Chunk = { bytes: xs, n: 1 }; const { bytes } = c0; xs.push(1); return bytes[0] as int32; }`, "cannot borrow 'bytes': what it borrows from ('xs') is potentially changed"],
		[chunk + `function run(k: int32): int32 { ${fill} const a: uint8[] = [1]; const v: Readonly<Span<uint8>> = match (k) { 0 => a, _ => xs }; xs.push(1); return v[0] as int32; }`, "cannot borrow 'v': what it borrows from ('xs') is potentially changed"],
	];
	const missed: string[] = [];
	for (const row of refused) {
		const c = compileToCWithStd(row[0]);
		const js = compileProjectToJSWithStd([{ entryPath: "test/viewStruct.ms", entrySource: row[0] }], "test/viewStruct.ms");
		if (c.ok || c.error.indexOf(row[1]) < 0) missed.push(row[0] + " — C: " + (c.ok ? "compiled" : c.error));
		if (!js.startsWith("ERROR:") || js.indexOf(row[1]) < 0) missed.push(row[0] + " — JS: " + js);
	}
	const accepted = [
		chunk + "const TABLE: Readonly<uint8[]> = [1, 2, 3];\nfunction view(n: int32): Chunk { return { bytes: TABLE, n: n }; }",
		chunk + "function f(p: Pair): Chunk { const { c } = p; return c; }",
		chunk + "function f(p: Pair, k: int32): Chunk { return match (k) { 0 => p.c, _ => p.c }; }",
		chunk + "function mk(a: uint8[]): Chunk { try { a.push(1); } finally { a.push(2); } return { bytes: a, n: 1 }; }",
		"struct Cur { data: Readonly<Span<uint8>>; at: int32; }\nfunction seek(this ref c: Cur, name: string): int32 { c.at += name.length as int32; return c.at; }\nfunction walk(ref c: Cur): int32 { return c.seek(\"ab\"); }",
	];
	for (const body of accepted) {
		const c = compileToCWithStd(body);
		const js = compileProjectToJSWithStd([{ entryPath: "test/viewStruct.ms", entrySource: body }], "test/viewStruct.ms");
		if (!c.ok) missed.push(body + " — C: " + c.error);
		if (js.startsWith("ERROR:")) missed.push(body + " — JS: " + js);
	}
	assert missed.length == 0, missed.join("\n");
}

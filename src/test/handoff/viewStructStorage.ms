import { compileToCWithStd, compileProjectToJSWithStd } from "../helpers";

test "a parameter whose union holds a view is refused on a constructor and a method as on a function" {
	const refused = [
		["class W { n: number; constructor(src: number | Readonly<Span<uint8>>) { this.n = 0; } }", "parameter 'src' of type Readonly<Span<uint8>> | number cannot hold Readonly<Span<uint8>> inside it"],
		["class W { n: number = 0; set(src: number | Readonly<Span<uint8>>): void {} }", "parameter 'src' of type Readonly<Span<uint8>> | number cannot hold Readonly<Span<uint8>> inside it"],
		["function f(src: number | Readonly<Span<uint8>>): number { return 0; }", "parameter 'src' of type Readonly<Span<uint8>> | number cannot hold Readonly<Span<uint8>> inside it"],
	];
	const missed: string[] = [];
	for (const row of refused) {
		const c = compileToCWithStd(row[0]);
		const js = compileProjectToJSWithStd([{ entryPath: "test/viewParam.ms", entrySource: row[0] }], "test/viewParam.ms");
		if (c.ok || c.error.indexOf(row[1]) < 0) missed.push(row[0] + " — C: " + (c.ok ? "compiled" : c.error));
		if (!js.startsWith("ERROR:") || js.indexOf(row[1]) < 0) missed.push(row[0] + " — JS: " + js);
	}
	assert missed.length == 0, missed.join("\n");
}

test "a struct that holds a view is a view: refused where a view is stored" {
	const chunk = "struct Chunk { bytes: Readonly<Span<uint8>>; n: int32; }\n";
	const refused = [
		[chunk + "class Keep { c: Chunk; constructor(c: Chunk) { this.c = c; } }", "field 'c' of 'Keep' cannot hold Chunk, a struct that holds Readonly<Span<uint8>>"],
		[chunk + "class Keep { cs: Chunk[] = []; }", "field 'cs' of 'Keep' cannot hold Chunk, a struct that holds Readonly<Span<uint8>>"],
		[chunk + "function f(t: [int32, Chunk]): int32 { return t[0]; }", "cannot hold Chunk, a struct that holds Readonly<Span<uint8>> inside it"],
		[chunk + "function f(b: Readonly<Span<uint8>>): int32 { const t: [int32, Chunk] = [1, { bytes: b, n: 2 }]; return t[0]; }", "cannot hold Chunk, a struct that holds Readonly<Span<uint8>> inside it"],
		[chunk + "function f(x: Chunk | string): int32 { return 0; }", "cannot hold Chunk, a struct that holds Readonly<Span<uint8>> inside it"],
		[chunk + "function f(b: Readonly<Span<uint8>>): int32 { const cs: Chunk[] = [{ bytes: b, n: 1 }]; return cs.length as int32; }", "cannot hold Chunk, a struct that holds Readonly<Span<uint8>> inside it"],
		[chunk + "function f(n: int32): int32 { let cs: Chunk[] = new Array<Chunk>(4); return n + (cs.length as int32); }", "cannot hold Chunk, a struct that holds Readonly<Span<uint8>> inside it"],
		[chunk + "let kept: Chunk | null = null;", "'kept' lives for the whole program and cannot hold Chunk, a struct that holds Readonly<Span<uint8>>"],
		[chunk + "async function g(c: Chunk): Promise<int32> { return c.n; }", "parameter 'c' of an async or generator function cannot be"],
	];
	const missed: string[] = [];
	for (const row of refused) {
		const c = compileToCWithStd(row[0]);
		const js = compileProjectToJSWithStd([{ entryPath: "test/viewStruct.ms", entrySource: row[0] }], "test/viewStruct.ms");
		if (c.ok || c.error.indexOf(row[1]) < 0) missed.push(row[0] + " — C: " + (c.ok ? "compiled" : c.error));
		if (!js.startsWith("ERROR:") || js.indexOf(row[1]) < 0) missed.push(row[0] + " — JS: " + js);
	}
	assert missed.length == 0, missed.join("\n");
}

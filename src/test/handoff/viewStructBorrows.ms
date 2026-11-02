import { compileToCWithStd, compileProjectToJSWithStd } from "../helpers";

test "a struct that holds a view is returned only from its first parameter" {
	const chunk = "struct Chunk { bytes: Readonly<Span<uint8>>; n: int32; }\n";
	const refused = [
		["struct Tok { text: Readonly<Span<char>>; } function mk(): Tok { const s = \"ab\".repeat(40); const t: Tok = { text: s }; return t; }", "'s' escapes its stack frame: 'mk' returns Tok, a struct that holds a view"],
		["struct Win { nums: Readonly<Span<int32>>; } function mkw(): Win { const xs: int32[] = []; xs.push(1); return { nums: xs }; }", "'xs' escapes its stack frame: 'mkw' returns Win, a struct that holds a view"],
		[chunk + "function pick(n: int32, b: Readonly<Span<uint8>>): Chunk { return { bytes: b, n: n }; }", "'b' is not the first parameter: 'pick' returns Chunk"],
		[chunk + "function lit(n: int32): Chunk { return { bytes: [1, 2], n: n }; }", "cannot borrow from a temporary: 'lit' returns Chunk"],
	];
	const missed: string[] = [];
	for (const row of refused) {
		const c = compileToCWithStd(row[0]);
		const js = compileProjectToJSWithStd([{ entryPath: "test/viewStruct.ms", entrySource: row[0] }], "test/viewStruct.ms");
		if (c.ok || c.error.indexOf(row[1]) < 0) missed.push(row[0] + " — C: " + (c.ok ? "compiled" : c.error));
		if (!js.startsWith("ERROR:") || js.indexOf(row[1]) < 0) missed.push(row[0] + " — JS: " + js);
	}
	assert missed.length == 0, missed.join("\n");
	const buf = "struct Buf { data: Readonly<Span<uint8>>; base: int64; size: int32; }\n"
		+ "function newBuf(data: Readonly<Span<uint8>>): Buf { return { data: data, base: 0, size: 0 }; }\n"
		+ "function rangeOf(this b: Buf, size: int32): Buf { if (size < 0) { return newBuf(b.data); } return { data: b.data, base: b.base + 1, size: size }; }\n"
		+ "function readIndex(this ref b: Buf): Buf { b.size = 1; return b.rangeOf(0); }\n"
		+ "struct Info { data: Readonly<Span<uint8>>; cff: Buf; n: int32; }\n";
	const accepted = [
		buf + "function initInfo(data: Readonly<Span<uint8>>, n: int32): Info | null { let info: Info = { data: data, cff: newBuf(data), n: n }; if (n == 0) { return null; } info.cff = newBuf(data); return info; }",
		buf + "function blank(data: Readonly<Span<uint8>>): Info { return { data: data, cff: { data: data, base: 0, size: 0 }, n: 0 }; }",
		buf + "function sizeIn(info: Info): int32 { let b = info.cff; const r = b.readIndex(); return r.size + info.n; }",
		buf + "function run(): int32 { const a: uint8[] = [1, 2, 3]; const b = newBuf(a); const r = b.rangeOf(2); return r.size + (r.data[0] as int32); } console.log(run());",
	];
	for (const body of accepted) {
		const c = compileToCWithStd(body);
		const js = compileProjectToJSWithStd([{ entryPath: "test/viewStruct.ms", entrySource: body }], "test/viewStruct.ms");
		assert c.ok, body + (c.ok ? "" : " — " + c.error);
		assert !js.startsWith("ERROR:"), body + " — " + js;
	}
}

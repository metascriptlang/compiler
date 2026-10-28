import { compileToC } from "../helpers";

const body = "function f(h: Holder): int32 { let n = 0; if (h.shape !== null) { n = 1; } const s: Shape | null = h.shape; return s !== null ? 2 : n; }\n";

function declsOf(kinds: string, arms: string): string {
	return `enum K { ${kinds} }\nstruct Shape = match (kind: K) { ${arms} };\nstruct Holder { shape: Shape | null }\n`;
}

test "nullableDeclaredUnionJoin: a nullable declared union joined after its null test is the declared carrier, so a re-read converts nothing" {
	const r = compileToC(declsOf("Zed, Alpha, Mid", "K.Zed => { z: int32 }, K.Alpha => { a: int32, b: int32 }, K.Mid => { m: int32 }") + body);
	assert r.ok, "compileToC failed";
	assert !r.value.contains("msUnionConv"), r.value;
}

test "nullableDeclaredUnionJoin: a declared union beside another member and null joins to the declared carrier" {
	const r = compileToC("enum K { Zed, Alpha, Mid }\nstruct A = match (kind: K) { K.Zed => { z: int32 }, K.Alpha => { a: int32, b: int32 }, K.Mid => { m: int32 } };\nstruct B { w: string }\nstruct Holder { v: A | B | null }\nfunction f(h: Holder): int32 { let n = 0; if (h.v !== null) { n = 1; } const s: A | B | null = h.v; return s !== null ? 2 : n; }\n");
	assert r.ok, "compileToC failed";
	assert !r.value.contains("msUnionConv"), r.value;
}

test "nullableDeclaredUnionJoin: a plain union whose declared order sorts differently joins to the declared carrier" {
	const r = compileToC("struct Zebra { z: int32 }\nstruct Apple { a: int32 }\nstruct Holder { v: Zebra | Apple | null }\nfunction f(h: Holder): int32 { let n = 0; if (h.v !== null) { n = 1; } const s: Zebra | Apple | null = h.v; return s !== null ? 2 : n; }\n");
	assert r.ok, "compileToC failed";
	assert !r.value.contains("msUnionConv"), r.value;
}

test "nullableDeclaredUnionJoin: another variant order joins to the same carrier" {
	const r = compileToC(declsOf("Alpha, Mid, Zed", "K.Alpha => { a: int32, b: int32 }, K.Mid => { m: int32 }, K.Zed => { z: int32 }") + body);
	assert r.ok, "compileToC failed";
	assert !r.value.contains("msUnionConv"), r.value;
}

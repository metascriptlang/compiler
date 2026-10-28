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

test "nullableDeclaredUnionJoin: another variant order joins to the same carrier" {
	const r = compileToC(declsOf("Alpha, Mid, Zed", "K.Alpha => { a: int32, b: int32 }, K.Mid => { m: int32 }, K.Zed => { z: int32 }") + body);
	assert r.ok, "compileToC failed";
	assert !r.value.contains("msUnionConv"), r.value;
}

import { assertFmtIdempotent } from "../roundtrip";

test "fmt: one-line async functions expanded by the first pass keep their spacing on the second" {
	assert assertFmtIdempotent("let t = \"\";\nasync function a(v: int32): Promise<int32> { t += \"a\"; return v; }\nasync function b(v: int32): Promise<int32> { t += \"b\"; return v; }\nfunction c(): string { return t; }\n");
}

test "fmt: one-line templates expanded by the first pass keep their spacing on the second" {
	assert assertFmtIdempotent("template same(x: int32): boolean { const y = x; return x == y; }\ntemplate other(x: int32): boolean { const y = x; return x != y; }\nconst k = 1;\n");
}

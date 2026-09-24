import { assertFmtLossless } from "../roundtrip";

test "fmt: an extension function keeps its this receiver" {
	assert assertFmtLossless("interface Holder { p: int32; }\nexport function probeGet(this h: Holder): int32 {\n\treturn h.p;\n}\n");
}

test "fmt: a static extension keeps this typeof" {
	assert assertFmtLossless("class Point { x: int32 = 0; }\nfunction origin(this typeof Point, x: int32): Point {\n\treturn new Point();\n}\n");
}

test "fmt: a static extension keeps each modifier and pattern on its own parameter" {
	assert assertFmtLossless("struct Ctx { n: int32; }\nstruct R { k: int32; }\nfunction create(this typeof R, k: int32, ref c: Ctx, readonly d: Ctx, { n }: Ctx): R {\n\treturn { k: k + c.n + d.n + n };\n}\n");
}

test "fmt: out, ref, readonly and sink parameters keep their modifiers" {
	assert assertFmtLossless("interface Box { v: int32; }\nfunction f(out a: int32, ref b: Box, readonly c: Box, sink d: Box): void {\n\ta = b.v + c.v + d.v;\n}\n");
}

test "fmt: a method keeps an out parameter" {
	assert assertFmtLossless("class A {\n\tm(out x: int32): void {\n\t\tx = 1;\n\t}\n}\n");
}

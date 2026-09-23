import { assertFmtLossless } from "../roundtrip";

test "fmt: an extension function keeps its this receiver" {
	assert assertFmtLossless("interface Holder { p: int32; }\nexport function probeGet(this h: Holder): int32 {\n\treturn h.p;\n}\n");
}

test "fmt: a static extension keeps this typeof" {
	assert assertFmtLossless("class Point { x: int32 = 0; }\nfunction origin(this typeof Point, x: int32): Point {\n\treturn new Point();\n}\n");
}

test "fmt: out, ref, readonly and sink parameters keep their modifiers" {
	assert assertFmtLossless("interface Box { v: int32; }\nfunction f(out a: int32, ref b: Box, readonly c: Box, sink d: Box): void {\n\ta = b.v + c.v + d.v;\n}\n");
}

test "fmt: a method keeps an out parameter" {
	assert assertFmtLossless("class A {\n\tm(out x: int32): void {\n\t\tx = 1;\n\t}\n}\n");
}

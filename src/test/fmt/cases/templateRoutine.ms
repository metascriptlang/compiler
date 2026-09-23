import { assertFmtLossless } from "../roundtrip";

test "fmt: a template routine keeps its keyword" {
	assert assertFmtLossless("template viaMaybe(x: int32): boolean {\n\treturn x == x;\n}\n");
}

test "fmt: an exported generic operator template keeps its keyword" {
	assert assertFmtLossless("export template `!=`<T>(a: T, b: T): boolean {\n\treturn !(a == b);\n}\n");
}

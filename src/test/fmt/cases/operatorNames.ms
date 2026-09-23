import { assertFmtLossless } from "../roundtrip";

test "fmt: an operator-named function keeps its backticks" {
	assert assertFmtLossless("export function `==`(a: string, b: string): boolean {\n\treturn true;\n}\n");
}

test "fmt: an operator-named extension and a generic operator keep their backticks" {
	assert assertFmtLossless("interface V { x: int32; }\nfunction `*`(this a: V, b: V): V {\n\treturn a;\n}\nfunction `[]`<T>(a: T[], i: int32): T {\n\treturn a[i];\n}\n");
}

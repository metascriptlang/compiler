import { assertFmtLossless } from "../roundtrip";

test "fmt: an optional interface field keeps its question mark" {
	assert assertFmtLossless("interface Box {\n\ta: int32;\n\tcb?: (x: int32) => int32;\n}\n");
}

test "fmt: an optional field already typed with null keeps its spelling" {
	assert assertFmtLossless("interface Opt {\n\ts?: string | null;\n\tn: int32;\n}\n");
}

test "fmt: an optional class property keeps its question mark" {
	assert assertFmtLossless("class C {\n\tlabel?: string;\n\tn: int32 = 0;\n}\n");
}

test "fmt: an optional parenthesized function type with null keeps its parentheses" {
	assert assertFmtLossless("interface Props {\n\tonPress?: ((e: int32) => void) | null;\n}\n");
}

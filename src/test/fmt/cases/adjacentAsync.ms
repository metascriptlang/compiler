import { assertFmtIdempotent } from "../roundtrip";

test "fmt: one-line async functions in a row format the same twice" {
	assert assertFmtIdempotent("async function a(): Promise<int32> { const x = 1; return x; }\nfunction b(): int32 { return 2; }\n");
	assert assertFmtIdempotent("async function a(): Promise<int32> { const x = 1; return x; }\nasync function b(): Promise<int32> { const y = 2; return y; }\n");
}

test "fmt: a multi-line async function keeps its separation from the next declaration" {
	assert assertFmtIdempotent("async function a(): Promise<int32> {\n\tconst x = 1;\n\treturn x;\n}\nfunction b(): int32 { return 2; }\n");
}

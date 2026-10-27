import { assertFmtLossless, assertFmtIdempotent } from "../roundtrip";

const ownLine = "function f(): void {\n\t// reuses g if needed, \n\tg();\n}\n";
const endOfLine = "class C {\n\tm(): void {\n\t\tg(); // tail, \n\t}\n}\n";

test "fmt: an own-line comment keeps the blank it ends with" {
	assert assertFmtLossless(ownLine);
	assert assertFmtIdempotent(ownLine);
}

test "fmt: an end-of-line comment one level deeper keeps the blank it ends with" {
	assert assertFmtLossless(endOfLine);
	assert assertFmtIdempotent(endOfLine);
}

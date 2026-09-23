import { assertFmtLossless, assertFmtIdempotent } from "../roundtrip";

const fn = "export function record(\n\tkey: string,\n\tcurrentRevision: int32,\n\toutputHash: number,  // content hash\n\t// computed this round\n\twasComputed: boolean\n): void {\n\tg();\n}\n";

test "fmt: comments inside a parameter list stay in place" {
	assert assertFmtLossless(fn);
}

test "fmt: comments inside a parameter list are stable" {
	assert assertFmtIdempotent(fn);
}

test "fmt: comments inside a method parameter list stay in place" {
	assert assertFmtLossless("class C {\n\tm(\n\t\ta: int32, // first\n\t\tb: int32,\n\t): void {}\n}\n");
}

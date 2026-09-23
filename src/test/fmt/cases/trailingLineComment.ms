import { assertFmtLossless, assertFmtIdempotent } from "../roundtrip";

const loop = "function reg(name: string): void {\n\tfor (const e of xs) {\n\t\tif (e.name == name) return; // already registered\n\t}\n\txs.push(name);\n}\n";

test "fmt: a trailing line comment inside a one-statement block stays before the brace" {
	assert assertFmtLossless(loop);
}

test "fmt: a trailing line comment inside a one-statement block is stable" {
	assert assertFmtIdempotent(loop);
}

test "fmt: a trailing line comment on a braceless else-if stays before the brace" {
	assert assertFmtLossless("function f(op: string, v: int32): int32 {\n\tif (op == \"*\") {\n\t\tv = v * 2;\n\t} else if (op == \"/\") v = v / 2; // integer division\n\treturn v;\n}\n");
}

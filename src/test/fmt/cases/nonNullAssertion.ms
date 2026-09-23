import { assertFmtLossless } from "../roundtrip";

test "fmt: a non-null assertion stays a postfix bang" {
	assert assertFmtLossless("function f(m: Map<string, int32>, k: string): int32 {\n\treturn m.get(k)! + 1;\n}\n");
}

test "fmt: a member access on a non-null assertion gains no parentheses" {
	assert assertFmtLossless("interface N { t: N | null; v: int32; }\nfunction f(n: N): int32 {\n\treturn n.t!.v;\n}\n");
}

import { assertFmtLossless, assertFmtIdempotent } from "../roundtrip";

const inBody = "function f(): int32 {\n\tlet n = 1;\n\twhen (js) {\n\t\tn = 2;\n\t} else when (ios) {\n\t\tn = 3;\n\t} else {\n\t\tn = 4;\n\t}\n\treturn n;\n}\n";

test "fmt: a when chain inside a body keeps every branch" {
	assert assertFmtLossless(inBody);
}

test "fmt: a when chain inside a body is stable" {
	assert assertFmtIdempotent(inBody);
}

test "fmt: a top-level when chain with comments keeps every branch" {
	assert assertFmtLossless("// before\nwhen (!testBuild) {\n\t// chosen or not\n\textern function g(): void;\n} else {\n\tfunction g(): void {}\n}\nconst x = 1; // after\n");
}

test "fmt: a when chain closing a block keeps every branch" {
	assert assertFmtLossless("function f(): void {\n\tg();\n\twhen (js) {\n\t\th();\n\t}\n}\n");
}

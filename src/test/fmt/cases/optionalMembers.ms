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

test "fmt: a multi-line parenthesized function type in a union keeps its parentheses on an optional interface field" {
	assert assertFmtLossless("export interface O {\n\tm?: (\n\t\t(p: number) => string | null\n\t) | null;\n}\n");
}

test "fmt: a multi-line parenthesized function type in a union keeps its parentheses on an optional interface field returning a plain type" {
	assert assertFmtLossless("interface O {\n\tm?: (\n\t\t(p: number) => string\n\t) | null;\n}\n");
}

test "fmt: a multi-line parenthesized function type in a union keeps its parentheses on an optional class field" {
	assert assertFmtLossless("class C {\n\tm?: (\n\t\t(p: number) => string\n\t) | null = null;\n}\n");
}

test "fmt: a multi-line parenthesized function type in a union keeps its parentheses on an optional parameter" {
	assert assertFmtLossless("function f(m?: (\n\t(p: number) => string\n) | null): void {}\n");
}

test "fmt: a multi-line parenthesized function type in a union keeps its parentheses on a type alias" {
	assert assertFmtLossless("type T = (\n\t(p: number) => string\n) | null;\n");
}

test "fmt: a multi-line parenthesized function type in a union keeps its parentheses on two nesting levels" {
	assert assertFmtLossless("interface O {\n\tm?: (\n\t\t(\n\t\t\t(p: number) => string\n\t\t) | null\n\t) | null;\n}\n");
}

test "fmt: a multi-line parenthesized function type in a union keeps its parentheses on a nested return" {
	assert assertFmtLossless("interface O {\n\tm?: (\n\t\t(p: number) => (\n\t\t\t(q: string) => number\n\t\t) | null\n\t) | null;\n}\n");
}

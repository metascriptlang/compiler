import { assertFmtLossless } from "../roundtrip";

test "fmt: a generic default on a type alias stays" {
	assert assertFmtLossless("export type ComponentFn<P = unknown> = (props: P) => int32;\n");
}

test "fmt: a generic default with an arrow type stays" {
	assert assertFmtLossless("type Mk<F = (x: int32) => int32, G = {}> = F;\n");
}

test "fmt: a generic constraint with arguments stays on a function and a class" {
	assert assertFmtLossless("function pick<T extends Map<string, int32>>(m: T): T {\n\treturn m;\n}\nclass Box<T extends Array<int32> = int32[]> {\n\tv: T;\n}\n");
}

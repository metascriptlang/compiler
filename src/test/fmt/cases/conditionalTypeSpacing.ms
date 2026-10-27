import { assertFmtContains, assertFmtPreservesAst } from "../roundtrip";

test "fmt: a conditional type keeps the spaces around its ? and :" {
	const src = "type A<T> = T extends string ? 1 : 2;\nfunction f(x: int32 extends int32 ? int32 : string): void {}\nlet v: (int32 extends string ? 1 : 2) | null = null;\n";
	assert assertFmtPreservesAst(src);
	assert assertFmtContains(src, "type A<T> = T extends string ? 1 : 2;");
	assert assertFmtContains(src, "x: int32 extends int32 ? int32 : string");
	assert assertFmtContains(src, "(int32 extends string ? 1 : 2) | null");
}

test "fmt: a nested and a chained conditional type keep their spaces, an optional member stays tight" {
	const src = "type B<T> = T extends string ? (T extends \"a\" ? 1 : 2) : 3;\ntype C<T> = T extends string ? 1 : T extends boolean ? 2 : 3;\ntype D<T extends string> = { a?: T };\ntype F<T> = T extends string ? [T] : T[];\n";
	assert assertFmtContains(src, "T extends string ? (T extends \"a\" ? 1 : 2) : 3;");
	assert assertFmtContains(src, "T extends string ? 1 : T extends boolean ? 2 : 3;");
	assert assertFmtContains(src, "{ a?: T }");
	assert assertFmtContains(src, "T extends string ? [T] : T[];");
}

test "fmt: a function type after a colon keeps its space" {
	const src = "type E<T> = (fn: (draft: T) => void) => void;\n";
	assert assertFmtContains(src, "(fn: (draft: T) => void) => void");
}

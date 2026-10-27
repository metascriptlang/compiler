import { assertFmtContains, assertFmtPreservesAst } from "../roundtrip";

test "fmt: a one-line abstract class keeps abstract" {
	const src = "abstract class Poker {}";
	assert assertFmtPreservesAst(src);
	assert assertFmtContains(src, "abstract class Poker");
}

test "fmt: an abstract class keeps abstract on itself and on its abstract members" {
	const src = "abstract class Poker {\n\tabstract poke(d: number): void;\n\tprotected abstract size: int32;\n\tdone(): void {}\n}\n";
	assert assertFmtPreservesAst(src);
	assert assertFmtContains(src, "abstract class Poker");
	assert assertFmtContains(src, "abstract poke(d: number): void;");
	assert assertFmtContains(src, "protected abstract size: int32;");
}

test "fmt: an exported abstract class keeps abstract" {
	const src = "export abstract class Shape {\n\tabstract area(): number;\n}\n";
	assert assertFmtPreservesAst(src);
	assert assertFmtContains(src, "export abstract class Shape");
}

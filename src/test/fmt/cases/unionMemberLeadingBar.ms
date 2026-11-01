import { assertFmtContains, assertFmtIdempotent, assertFmtLossless } from "../roundtrip";
import { checkLossless } from "../../../compiler/fmt/lossless";

const longParam = "export function A<T>(props: {\n\ta: number;\n\tr?: ((section: T, index: number, isActive: Accessor<boolean>) => NeonNode) | null;\n\tb: number;\n}): NeonNode {\n\treturn props;\n}\n";
const barParam = "export function A(props: {\n\ta: number;\n\tr?:\n\t\t| string\n\t\t| null;\n}): number {\n\treturn 1;\n}\n";
const barAlias = "type X = {\n\ta: number;\n\tr?:\n\t\t| string\n\t\t| null;\n};\n";

test "fmt: an object-type parameter whose member union breaks with a leading bar is stable" {
	assert assertFmtIdempotent(longParam);
	assert assertFmtLossless(longParam);
}

test "fmt: a leading bar on an object-type member union is printed by the tree, in a parameter and an alias" {
	assert assertFmtContains(barParam, "\tr?: string | null;\n");
	assert assertFmtContains(barAlias, "\tr?: string | null;\n");
	assert assertFmtIdempotent(barParam);
	assert assertFmtIdempotent(barAlias);
}

test "fmt: a leading bar on a member union or a later type argument keeps the program, and a changed member still differs" {
	const member = "type X = {\n\tr?: A | null;\n};\n";
	assert checkLossless(member, "type X = {\n\tr?:\n\t\t| A\n\t\t| null;\n};\n").ok;
	assert checkLossless("type X = {\n\tr?: Map<K, A | null>;\n};\n", "type X = {\n\tr?: Map<\n\t\tK,\n\t\t| A\n\t\t| null\n\t>;\n};\n").ok;
	assert !checkLossless(member, "type X = {\n\tr?:\n\t\t| B\n\t\t| null;\n};\n").ok;
}

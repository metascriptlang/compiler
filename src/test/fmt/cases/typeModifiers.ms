import { assertFmtLossless, assertFmtIdempotent, assertFmtPreservesAst } from "../roundtrip";

const spellings = [
	"import type { A } from \"./a\";\n",
	"import { type A, b } from \"./a\";\n",
	"import { type A as B } from \"./a\";\n",
	"import type * as ns from \"./a\";\n",
	"export type { A } from \"./a\";\n",
	"export { type A, b } from \"./a\";\n",
	"export type * from \"./a\";\n",
	"import { type, type as t } from \"./a\";\n",
];

test "fmt: every TypeScript type modifier on an import or re-export is kept" {
	for (const source of spellings) assert assertFmtLossless(source);
}

test "fmt: type modifiers on imports and re-exports are stable" {
	for (const source of spellings) assert assertFmtIdempotent(source);
}

test "fmt: type modifiers survive in the reparsed tree" {
	for (const source of spellings) assert assertFmtPreservesAst(source);
}

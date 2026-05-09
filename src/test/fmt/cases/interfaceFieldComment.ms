// Trailing comments on interface fields stay attached.
//
// Symptom:    `interface I { a: T; // foo \n b: T; // bar }` formats
//             with comments hoisted to AFTER the closing `}` (or
//             worse: misaligned via sequential mapping).
// Root cause: printStructLikeDecl previously did either nothing
//             (dump after `}`) or sequential 1-to-1 mapping which
//             misaligns when comment count != field count.
// Fix:        Use line-matching like printEnumDecl. The parser stores
//             field source positions on `node.paramLocations` (a
//             repurposed slot since InterfaceDeclData doesn't have a
//             dedicated fieldLocations array yet — but the data is
//             there via that slot).

import { assertFmtContains, assertFmtPreservesAst } from "../roundtrip";

test "fmt: interface field with trailing comment preserves attachment" {
	const src = "interface I {\n\ta: number; // alpha\n\tb: number; // beta\n}";
	assertFmtPreservesAst(src);
	assertFmtContains(src, "a: number; // alpha");
	assertFmtContains(src, "b: number; // beta");
}

test "fmt: interface mixed trailing + standalone comments preserved" {
	const src = "interface I {\n\ta: number; // alpha\n\t// standalone before b\n\tb: number;\n}";
	assertFmtPreservesAst(src);
	assertFmtContains(src, "a: number; // alpha");
	assertFmtContains(src, "// standalone before b");
}

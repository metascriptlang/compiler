// Imports stay on one line when they fit printWidth.
//
// Symptom:    `import { A, B, C } from "...";` (~50 chars) gets bung
//             across multiple lines unconditionally:
//                 import {
//                     A,
//                     B,
//                     C,
//                 } from "...";
// Root cause: printImportDecl always emits multi-name imports with
//             docLine separators, but the surrounding docGroup uses
//             docLine which CAN flatten — yet the layout engine has
//             always broken because... [TBD investigation].
// Fix:        Use docSoftLine + docLine pattern that flattens cleanly
//             and matches Prettier's behavior.

import { assertFmtContains } from "../roundtrip";

test "fmt: short import stays one line" {
	assertFmtContains(
		"import { A, B, C } from \"./mod\";",
		"import { A, B, C } from \"./mod\";",
	);
}

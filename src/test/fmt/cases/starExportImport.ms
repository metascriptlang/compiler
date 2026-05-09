// `export * from` and `import * as Name from` patterns.
//
// Symptom 1:  `export * from "./mod";` formats to
//             `export { * } from "./mod";` — the `*` gets wrapped as
//             a named specifier, which fails to parse.
// Symptom 2:  `import * as M from "./mod";` may format to
//             `import { * as M } from "./mod";` — same issue.
// Fix:        printReExport / printImportDecl detect the single-`*`
//             specifier and emit the bare `*` (or `* as Alias`) form
//             without `{...}` wrapper.

import { assertFmtPreservesAst } from "../roundtrip";

test "fmt: export * from preserves bare star" {
	assertFmtPreservesAst("export * from \"./mod\";");
}

test "fmt: import * as Name from preserves namespace import" {
	assertFmtPreservesAst("import * as M from \"./mod\";");
}

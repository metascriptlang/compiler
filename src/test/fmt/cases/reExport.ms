// Re-export `export { x } from "module"` printer bug.
//
// Symptom:    `export { MapEntry } from "../module/loader";` formats to
//             `export import { MapEntry } from "../module/loader";` —
//             a stray `import` keyword is inserted between `export` and
//             the `{`. The result is a parse error.
// Root cause: printExportDecl emits the inner ImportDecl-shaped node
//             without stripping the leading `import` keyword that
//             printImportDecl produces.
// Fix:        printExportDecl detects re-export shape and emits the
//             `export { ... } from "..."` form directly.

import { assertFmtPreservesAst } from "../roundtrip";

test "fmt: export { x } from \"...\" preserves shape" {
	assertFmtPreservesAst("export { foo, bar } from \"./mod\";");
}

test "fmt: export { x as y } from \"...\" preserves alias" {
	assertFmtPreservesAst("export { foo as renamed } from \"./mod\";");
}

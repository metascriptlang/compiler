// bug196 — a named import or re-export from a prelude module ignored aliases and missing names
//
// Symptom:    `import { hashString as h } from "std/core/struct"` left `h`
//             undefined; `export { hashString as h } from …` exported nothing,
//             and `export { push as append } from "std/core/array"` exported
//             the unrelated prelude `append`; `export { nope } from
//             "std/core/array"` and `export { push } from "std/core/struct"`
//             compiled clean.
// Cause:      a prelude source took its own branch that looked each name up by
//             its alias in the merged prelude scope, never checked the module
//             the name came from, and dropped a name it could not find.
// Reference:  a named import takes the name from that module's export table or
//             fails at the import ("undeclared identifier"); an alias binds a
//             new local name to the same declaration, as the ordinary import
//             path already does.
import { checkProjectDiagnostics, compileProjectToCWithStd, MapEntry } from "../helpers";

function projectC(xSource: string, mainSource: string): string {
	const entries: MapEntry[] = [
		{ entryPath: "src/x.ms", entrySource: xSource },
		{ entryPath: "src/main.ms", entrySource: mainSource },
	];
	return compileProjectToCWithStd(entries, "src/main.ms");
}

test "bug196: an aliased import from a prelude module binds the alias" {
	const entries: MapEntry[] = [
		{ entryPath: "src/main.ms", entrySource: `import { hashString as h } from "std/core/struct";\nconsole.log(h("a").toString());\n` },
	];
	const d = checkProjectDiagnostics(entries, "src/main.ms").join("\n");
	assert d == "", d;
}

test "bug196: an aliased re-export of a prelude name exports the alias" {
	const fn = projectC(`export { hashString as h } from "std/core/struct";\nexport const k = 7;\n`,
		`import { k, h } from "./x";\nconsole.log(h("a").toString() + k.toString());\n`);
	assert !fn.startsWith("ERROR"), fn;
	const ext = projectC(`export { push as append } from "std/core/array";\nexport const k = 7;\n`,
		`import { k, append } from "./x";\nconst a: number[] = [];\nappend(a, k);\nconsole.log(a.length.toString());\n`);
	assert !ext.startsWith("ERROR"), ext;
}

test "bug196: a name the prelude module does not export fails at the re-export" {
	const main = `import { k } from "./x";\nconsole.log(k.toString());\n`;
	const missing = projectC(`export { nope } from "std/core/array";\nexport const k = 7;\n`, main);
	assert missing.contains("Module 'std/core/array' has no export 'nope'"), missing;
	const elsewhere = projectC(`export { push } from "std/core/struct";\nexport const k = 7;\n`, main);
	assert elsewhere.contains("Module 'std/core/struct' has no export 'push'"), elsewhere;
}

test "bug196: a name the prelude module does not export fails at the import" {
	const entries: MapEntry[] = [
		{ entryPath: "src/main.ms", entrySource: `import { nope } from "std/core/array";\n` },
	];
	const d = checkProjectDiagnostics(entries, "src/main.ms").join("\n");
	assert d.contains("Module 'std/core/array' has no export 'nope'"), d;
}

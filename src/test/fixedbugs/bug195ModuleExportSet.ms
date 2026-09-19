// bug195 — a module exported the prelude names it only imported
//
// Symptom:    `import { push } from "./x"` resolved although x.ms never
//             exported `push` (x imported it, or did not name it at all), and
//             on C the call then failed "Ambiguous call to overloaded
//             extension method 'push'"; `export { hashString } from
//             "std/core/struct"` was dropped, so importers got "no export".
// Cause:      `collectExports` read "M exports X" off `SymbolFlag.Exported` on
//             the symbol, and a prelude symbol is one object shared by every
//             module and already carries the flag; a re-export whose source is
//             the prelude skipped the whole re-export branch.
// Reference:  each module owns its export table; a declaration marked for
//             export or an explicit re-export writes it, an import never does,
//             and a re-export hands on the same symbol, not a copy.
import { checkProjectDiagnostics, compileProjectToCWithStd, MapEntry } from "../helpers";

function diagnostics(xSource: string, mainSource: string): string {
	const entries: MapEntry[] = [
		{ entryPath: "src/x.ms", entrySource: xSource },
		{ entryPath: "src/main.ms", entrySource: mainSource },
	];
	return checkProjectDiagnostics(entries, "src/main.ms").join("\n");
}

const PUSH_VIA_X = `import { k, push } from "./x";
const a: number[] = [];
push(a, k);
a.push(k);
`;

const HASH_VIA_X = `import { k, hashString } from "./x";
console.log(hashString("a").toString() + k.toString());
`;

test "bug195: a module that does not name a prelude extension does not export it" {
	const d = diagnostics(`export const k = 7;\n`, PUSH_VIA_X);
	assert d.contains("Module './x' has no export 'push'"), d;
}

test "bug195: importing a prelude name does not export it" {
	const ext = diagnostics(`import { push } from "std/core/array";\nexport const k = 7;\n`, PUSH_VIA_X);
	assert ext.contains("Module './x' has no export 'push'"), ext;
	const fn = diagnostics(`import { hashString } from "std/core/struct";\nexport const k = 7;\n`, HASH_VIA_X);
	assert fn.contains("Module './x' has no export 'hashString'"), fn;
}

test "bug195: a named re-export of a prelude name exports it" {
	const fn = diagnostics(`export { hashString } from "std/core/struct";\nexport const k = 7;\n`, HASH_VIA_X);
	assert fn == "", fn;
	const ext = diagnostics(`export { push } from "std/core/array";\nexport const k = 7;\n`, PUSH_VIA_X);
	assert ext == "", ext;
}

test "bug195: a star re-export of a prelude module exports its names" {
	const d = diagnostics(`export * from "std/core/array";\nexport const k = 7;\n`, PUSH_VIA_X);
	assert d == "", d;
}

test "bug195: a re-exported prelude extension is the prelude symbol, not a second overload" {
	const entries: MapEntry[] = [
		{ entryPath: "src/x.ms", entrySource: `export { push } from "std/core/array";\nexport const k = 7;\n` },
		{ entryPath: "src/main.ms", entrySource: PUSH_VIA_X },
	];
	const c = compileProjectToCWithStd(entries, "src/main.ms");
	assert !c.startsWith("ERROR"), c;
}

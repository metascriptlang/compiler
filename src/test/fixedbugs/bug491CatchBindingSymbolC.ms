// bug491 — a shadowing catch binding was released under the outer binding's name
//
// Symptom:    `catch (e) { try { … } catch (e) { … } … }`: the inner handler ended with
//             `msDecref(e)` on the OUTER exception, so it was released twice (DOUBLE-DESTROY,
//             then a use-after-free in the outer handler) and the inner one leaked.
// Root cause: the checker renames the shadowing binding (`e$1`), C codegen declared it under the
//             new name but never mapped its symbol, and the analyzer's release refers to the
//             symbol, whose name is still `e`.
// Fix:        the catch binding gets a unique local name mapped to its symbol, as a variable
//             declaration does (fillLocalName + setLocalSymName).

import { compileToC } from "../helpers";

function cOf(source: string): string {
	const c = compileToC(source);
	return c.ok ? c.value : c.error;
}

function catchVars(c: string): string[] {
	const names: string[] = [];
	let at = c.indexOf("msCurrException;", 0);
	while (at >= 0) {
		const sol = c.lastIndexOf("\n", at) + 1;
		const line = c.slice(sol, at).trim();
		const eq = line.indexOf(" = (", 0);
		if (eq > 0 && line.contains("*)")) {
			const decl = line.slice(0, eq);
			names.push(decl.slice(decl.lastIndexOf(" ") + 1, decl.byteLength));
		}
		at = c.indexOf("msCurrException;", at + 1);
	}
	return names;
}

function count(c: string, needle: string): int32 {
	let n: int32 = 0;
	let at = c.indexOf(needle, 0);
	while (at >= 0) {
		n += 1;
		at = c.indexOf(needle, at + 1);
	}
	return n;
}

const BOOM = "function boom(m: string): void { throw new Error(m); }\n";

test "bug491: a nested catch that shadows its outer binding releases each binding once" {
	const c = cOf(BOOM + "export function run(): string {\n\tlet out = \"\";\n\ttry { boom(\"o\"); } catch (e) {\n\t\ttry { boom(\"i\"); } catch (e) { out = e.message; }\n\t\tout = out + e.message;\n\t}\n\treturn out;\n}\n");
	const names = catchVars(c);
	assert names.length == 2;
	assert names[0] != names[1];
	assert count(c, `msDecref(${names[0]});`) == 1;
	assert count(c, `msDecref(${names[1]});`) == 1;
}

test "bug491: the shadowing binding two levels deep is released under its own name" {
	const c = cOf(BOOM + "export function run(): string {\n\tlet out = \"\";\n\ttry { boom(\"a\"); } catch (e) {\n\t\ttry { boom(\"b\"); } catch (e) {\n\t\t\ttry { boom(\"c\"); } catch (e) { out = e.message; }\n\t\t\tout = out + e.message;\n\t\t}\n\t\tout = out + e.message;\n\t}\n\treturn out;\n}\n");
	const names = catchVars(c);
	assert names.length == 3;
	for (const n of names) assert count(c, `msDecref(${n});`) == 1;
}

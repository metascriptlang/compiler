// Route 17: Union narrowing via as-cast — codegen must emit .vN, not anonymous struct
//
// Bug: `doc.data as { flat: Doc, broken: Doc }` where DocData is a union type
// emits `msAnon_xxx d = ...` in C instead of `DocData_v3 d = ((*doc).data).v3`.

import { compileToC, compileProjectToC, contains } from "../helpers";

test "union narrowing as-cast emits variant accessor" {
	const r = compileToC(`
		enum DocKind { Nil, Text, Group, Indent, Line, HardLine, IfBreak, LineSuffix }

		type DocData =
			| { text: string }
			| { children: number }
			| { isSoft: boolean }
			| { flat: number, broken: number };

		class Doc {
			kind: DocKind;
			data: DocData;
		}

		export function getIfBreak(doc: Doc): number {
			const d = doc.data as { flat: number, broken: number };
			return d.flat;
		}
	`);
	if (!r.ok) {
		console.log("COMPILE ERROR: " + r.error);
		assert false;
	}
	const cCode = r.value;
	assert !contains(cCode, "msAnon_");
	assert contains(cCode, "DocData_v3");
	assert contains(cCode, ".v3");
}

test "partial as-cast resolves to full variant" {
	const r = compileToC(`
		type DocData =
			| { text: string }
			| { children: number }
			| { isSoft: boolean }
			| { flat: number, broken: number };

		class Doc {
			kind: number;
			data: DocData;
		}

		export function getFlatOnly(doc: Doc): number {
			const d = doc.data as { flat: number };
			return d.flat;
		}
	`);
	if (!r.ok) {
		console.log("COMPILE ERROR: " + r.error);
		assert false;
	}
	const cCode = r.value;
	assert !contains(cCode, "msAnon_");
	assert contains(cCode, "DocData_v3");
	assert contains(cCode, ".v3");
}

test "union narrowing as-cast works across files" {
	const entries = [
		{ entryPath: "src/doc.ms", entrySource: `
			export enum DocKind { Nil, Text, Group, Indent, Line, HardLine, IfBreak, LineSuffix }

			export type DocData =
				| { text: string }
				| { children: number }
				| { isSoft: boolean }
				| { flat: number, broken: number };

			export class Doc {
				kind: DocKind;
				data: DocData;
			}
		` },
		{ entryPath: "src/layout.ms", entrySource: `
			import { Doc, DocKind, DocData } from "./doc";

			export function getIfBreak(doc: Doc): number {
				const d = doc.data as { flat: number, broken: number };
				return d.flat;
			}
		` },
	];
	const cCode = compileProjectToC(entries, "src/layout.ms");
	if (contains(cCode, "ERROR:")) {
		console.log("compileProjectToC failed: " + cCode);
		assert false;
	}
	assert !contains(cCode, "msAnon_");
	assert contains(cCode, "DocData_v3");
	assert contains(cCode, ".v3");
}

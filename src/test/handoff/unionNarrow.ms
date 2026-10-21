// Route 17: Union narrowing via as-cast — codegen reads the union's variant member
//
// Bug: `doc.data as { flat: Doc, broken: Doc }` where DocData is a union type
// emitted a fresh anonymous struct instead of reading the variant. The cast must
// read `((*doc).data).vN`, and the local must have that member's struct type,
// whose fields are the full variant's.

import { compileToC, compileProjectToC } from "../helpers";
import { MapEntry } from "../../module/loader";

// The struct body the as-cast local `d` reads, when it reads a union member of
// that same struct type; "" otherwise.
function variantReadBody(code: string): string {
	const access = "((*doc).data).v";
	const at = code.indexOf(access);
	if (at < 0) return "";
	const idx = code.slice(at + access.length, code.indexOf(")", at + access.length));
	const memberAt = code.indexOf("* v" + idx + ";");
	if (memberAt < 0) return "";
	const memberType = code.slice(code.lastIndexOf(" ", memberAt - 1) + 1, memberAt);
	if (!code.contains(memberType + "* d_")) return "";
	const bodyAt = code.indexOf("struct " + memberType + " {");
	if (bodyAt < 0) return "";
	return code.slice(bodyAt, code.indexOf("}", bodyAt));
}

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
	if (!r.ok) console.log("COMPILE ERROR: " + r.error);
	assert r.ok;
	const cCode = r.value;
	const body = variantReadBody(cCode);
	assert body.contains(" flat;");
	assert body.contains(" broken;");
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
	if (!r.ok) console.log("COMPILE ERROR: " + r.error);
	assert r.ok;
	const cCode = r.value;
	const body = variantReadBody(cCode);
	assert body.contains(" flat;");
	assert body.contains(" broken;");
}

test "union narrowing as-cast works across files" {
	const entries: MapEntry[] = [
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
	if (cCode.contains("ERROR:")) {
		console.log("compileProjectToC failed: " + cCode);
		assert false;
	}
	const body = variantReadBody(cCode);
	assert body.contains(" flat;");
	assert body.contains(" broken;");
}

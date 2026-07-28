// bug054 — getTypeImpl(TypeName): macros can read a FIXED interface's shape
//
// Gap (A4 follow-on): `arg.nodeType` only works when the argument has a type.
// A macro whose argument is a bare object literal — `createStyles({ box: {...} })`
// — gets nothing, because the literal has no contextual type at expand time.
// Validating it against a known interface required a witness parameter, which
// framework-facing APIs cannot ask users for.
//
// Capability: `getTypeImpl(Style)` inside a macro body resolves `Style` in the
// macro's DECLARING module scope and splices its type-AST literal in, so the
// macro can walk `typExprFieldNames` with no value to read from. Name follows
// docs/SERIALIZE.md Phase A1 (reference parity: getType/getTypeImpl/...).

import { compileToCWithStd } from "../helpers";

const sheetMacro = `
import { Node, NodeKind } from "std/meta";

interface Style { width: number; color: string; }

export macro createStyles(sheet: Node): Node {
	const st = getTypeImpl(Style);
	if (sheet.kind === NodeKind.ObjectLiteral && st.kind === NodeKind.TypeObject) {
		let e = 0;
		while (e < sheet.properties.length) {
			const entry = sheet.properties[e];
			if (entry.kind === NodeKind.ObjectLiteral) {
				let i = 0;
				while (i < entry.keys.length) {
					let found = false;
					let j = 0;
					while (j < st.typExprFieldNames.length) {
						if (entry.keys[i] === st.typExprFieldNames[j]) { found = true; }
						j = j + 1;
					}
					if (!found) {
						let avail = "";
						let k = 0;
						while (k < st.typExprFieldNames.length) {
							if (k > 0) { avail = avail + ", "; }
							avail = avail + st.typExprFieldNames[k];
							k = k + 1;
						}
						error("createStyles: unknown style field '" + entry.keys[i] + "' in '" + sheet.keys[e] + "' — available: " + avail, entry);
					}
					i = i + 1;
				}
			}
			e = e + 1;
		}
	}
	return sheet;
}
`;

const srcBadKey = sheetMacro + `
function main(): void {
	const s = createStyles({ box: { widht: 5.0 } });
}
`;

test "bug054: macro validates a bare sheet literal against a fixed interface" {
	const c = compileToCWithStd(srcBadKey);
	assert !c.ok;
	assert c.error.indexOf("unknown style field 'widht' in 'box'", 0) >= 0;
	assert c.error.indexOf("available: width, color", 0) >= 0;
}

const srcGoodKeys = sheetMacro + `
function main(): void {
	const s = createStyles({ box: { width: 5.0, color: "red" } });
}
`;

test "bug054: valid sheet keys pass the macro's own validation" {
	const c = compileToCWithStd(srcGoodKeys);
	assert c.ok;
}

const srcUnknownType = `
import { Node, NodeKind } from "std/meta";

export macro bad(x: Node): Node {
	const t = getTypeImpl(NoSuchTypeAnywhere);
	return x;
}

function main(): void {
	const v = bad(1);
}
`;

test "bug054: getTypeImpl on an unresolvable name is a compile error" {
	const c = compileToCWithStd(srcUnknownType);
	assert !c.ok;
	assert c.error.indexOf("cannot resolve type 'NoSuchTypeAnywhere'", 0) >= 0;
}

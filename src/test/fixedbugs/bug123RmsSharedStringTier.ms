// bug123 — 21 of 38 externs in the .rms string prelude were dead
//
// Symptom:    a macro body calling shared-tier string ops (repeat/count/
//             split/equalsIgnoreCase...) or the byte kernels (asBytes/
//             asString/byteSlice) failed — the checker rejected undeclared
//             members (asBytes), or the VM died at "Unknown host function"
//             for the externs no bridge ever backed.
// Root cause: index.rms predated shared.ms and redeclared 15 of the 17
//             shared names as its own externs instead of re-exporting,
//             and declared no kernels for a byte tier.
// Fix:        std/core/string/index.rms now mirrors index.cms (asBytes +
//             byteAt/byteLength/byteSlice + the 17-name re-export from
//             ./shared), array/index.rms declares asString, and
//             hostTable.ms bridges msAsBytes/msAsString (the only bridges
//             that create/read VM heap arrays).

import { compileToCWithStd } from "../helpers";

const src = `
import { Node, NodeKind } from "std/meta";

export macro strfeat(node: Node): Node {
	const s = "Hello, MetaScript!";
	const a = s.trim().toLowerCase().repeat(2);
	const parts = a.split(",");
	const probe = s.byteSlice(0, 5).asBytes().asString();
	const found = s.indexOf("Meta");
	const n = s.count("l");
	let v = "FAIL";
	if (s.startsWith("Hello")) {
		if (s.endsWith("!")) {
			if (s.contains("Meta")) {
				v = probe + found.toString() + n.toString() + parts.length.toString();
			}
		}
	}
	return { kind: NodeKind.StringLiteral, line: node.line, column: node.column, value: v };
}

function main(): void {
	const x = strfeat(0);
	console.log(x);
}
main();
`;

test "bug123: shared-tier string ops fold inside a macro body" {
	const c = compileToCWithStd(src);
	assert c.ok;
	if (c.ok) {
		assert c.value.contains("Hello723");
	}
}

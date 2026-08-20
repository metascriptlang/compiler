// bug112 — macro VM had no host bridge for msStringCharCodeAt
//
// Symptom:    a macro body calling "s".charCodeAt(i) died at expansion with
//             "Unknown host function: msStringCharCodeAt" — std declares the
//             extern (std/core/string) but hostTable never registered a
//             bridge. Found by Neon's createStyles CSS class-name hashing.
//
// Fix:        _bridge_msStringCharCodeAt in compiler/meta/hostTable.ms,
//             reading the index via unboxInt (the _msNode accessors' form —
//             NOT args[i].intVal, which misreads a Float-kind index).

import { compileToCWithStd } from "../helpers";

const src = `
import { Node, NodeKind } from "std/meta";

export macro hashName(node: Node): Node {
	const s = "padding:8px;";
	let h = 5381;
	for (let i = 0; i < s.length; i += 1) {
		h = (h * 33 + s.charCodeAt(i)) % 4294967296;
	}
	return { kind: NodeKind.StringLiteral, line: node.line, column: node.column, value: "n_" + h.toString() };
}

function main(): void {
	const x = hashName(0);
}
`;

test "bug112: charCodeAt inside a macro body expands clean" {
	const c = compileToCWithStd(src);
	assert c.ok;
}

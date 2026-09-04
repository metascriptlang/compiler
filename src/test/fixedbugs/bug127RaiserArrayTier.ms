// bug127 — generic-array methods were unusable at comptime, blocked twice
//
// Symptom:    a macro body calling arr.pop()/at()/setLength()/capacity()/
//             splice() died at "no host bridge for '&msGenericArrayPop'" —
//             the '&' prefix stays inside Symbol.nativeName so the CallHost
//             registry key can never match, and the VM heap had no shrink
//             primitive, so the methods could not be written in MS either.
// Fix:        one new opcode, ArraySetLen (truncate or nil-extend), plus a
//             setLength codegen intercept mirroring the push pattern. All
//             six methods are now portable MS in std/core/array/index.rms
//             over push/setLength/index/length — the '&' names never reach
//             CallHost and the externs left the .rms dead list.

import { compileToCWithStd } from "../helpers";

const src = `
import { Node, NodeKind } from "std/meta";

export macro arrfeat(node: Node): Node {
	const a: string[] = [];
	a.push("x");
	a.push("y");
	a.push("z");
	const last = a.pop();
	const second = a.at(1);
	a.splice(0, 1);
	a.push("w");
	const cap = a.capacity();
	const v = last + second + a[0] + cap.toString() + a.length.toString();
	return { kind: NodeKind.StringLiteral, line: node.line, column: node.column, value: v };
}

function main(): void {
	const x = arrfeat(0);
	console.log(x);
}
main();
`;

test "bug127: array methods fold inside macro bodies" {
	const c = compileToCWithStd(src);
	assert c.ok;
	if (c.ok) {
		assert c.value.contains("zyy22");
	}
}

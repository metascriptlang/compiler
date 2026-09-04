// bug125 — a macro calling an unbridged extern only failed at expansion RUN
// time, with the span on the macro CALL SITE, not the extern call
//
// Symptom:    "Macro 'usesDead' failed: Unknown host function:
//             msStringSubstring" pointing at `usesDead(0)` — the user had to
//             hunt through the macro body for whichever extern died.
// Root cause: compileCallExpr emitted CallHost for any callee symbol with a
// nativeName without checking the host registry (populated before codegen by
// transformForEngine), so a missing bridge surfaced only when the VM
// dispatched the call.
// Fix:        checkHostBridgeCoverage (codegen/raiser/expressions.ms) runs
//             at both CallHost emission sites and queues a compile error
//             naming the extern — span lands on the extern call itself.

import { compileToCWithStd } from "../helpers";

const src = `
import { Node, NodeKind } from "std/meta";

export macro usesDead(node: Node): Node {
	const v = "Hello".substring(1, 3);
	return { kind: NodeKind.StringLiteral, line: node.line, column: node.column, value: v };
}

function main(): void {
	const x = usesDead(0);
	console.log(x);
}
main();
`;

test "bug125: unbridged extern in a macro body errors at the call site" {
	const c = compileToCWithStd(src);
	assert !c.ok;
	if (!c.ok) {
		assert c.error.contains("no host bridge for 'msStringSubstring'");
	}
}

// A macro that reports a compile error still type-checks: `error(...)` is
// rewritten into a return of a compiler-built sentinel, and that sentinel is
// not an author value, so it never has to satisfy the macro's return type.
//
// A red guard means enforcing the declared return type started rejecting the
// compiler's own control flow — every macro that reports an error breaks, the
// regression that reached main on 2026-09-14 and was reverted.

import { Node, NodeKind } from "std/meta";

export macro needsNode(n: Node): Node {
	if (n == null) error("needsNode wants a node", n);
	return { kind: NodeKind.NumberLiteral, line: n.line, column: n.column, value: 7, isFloat: false };
}

function expect(actual: string, want: string, name: string): int32 {
	if (actual != want) {
		console.log(`GUARD-FAIL ${name}: got ${actual}, want ${want}`);
		return 1;
	}
	return 0;
}

function main(): int32 {
	let rc: int32 = 0;
	rc += expect(`${needsNode(0)}`, "7", "macroWithErrorCallStillExpands");
	if (rc == 0) { console.log("GUARD-OK macroErrorCallReturns"); }
	return rc;
}

const rc = main();
if (rc != 0) { process.exit(rc); }

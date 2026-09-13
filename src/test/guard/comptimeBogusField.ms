// A Node literal inside a @comptime block is checked exactly like one inside a
// macro body: a key that exists on no NodeData variant is rejected, and the
// diagnostic names the block it came from.
//
// A red guard means the comptime path went back to discarding the errors its
// own body already produced — the block compiles clean and folds to garbage.
//
// GUARD-CHECK-FAIL @comptime block:
// GUARD-CHECK-FAIL 'bogusKey' does not exist in type 'Node'

import { Node, NodeKind } from "std/meta";

const LINE: int32 = @comptime {
	const n: Node = {
		kind: NodeKind.NumberLiteral, line: 7, column: 3,
		value: 1, isFloat: false, bogusKey: 1,
	};
	return n.line;
};

function main(): int32 {
	console.log(`${LINE}`);
	return 0;
}

const rc = main();
if (rc != 0) { process.exit(rc); }

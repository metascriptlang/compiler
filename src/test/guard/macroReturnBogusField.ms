// A macro's declared return type reaches its own body: the literal it returns
// is checked against Node, so a key that exists on no NodeData variant is
// rejected in return position too — the one position that carried no expected
// type at all while the body wrapper erased the declared type.
//
// A red guard means the wrapper went back to an empty return type, and a
// returned literal is unchecked at every depth no matter what it contains.
//
// GUARD-CHECK-FAIL Macro 'mRet' body:
// GUARD-CHECK-FAIL 'bogusKey' does not exist in type 'Node'

import { Node, NodeKind } from "std/meta";

export macro mRet(n: Node): Node {
	return {
		kind: NodeKind.NumberLiteral, line: n.line, column: n.column,
		value: 1, isFloat: false, bogusKey: 1,
	};
}

function main(): int32 {
	return mRet(0) - 1;
}

const rc = main();
if (rc != 0) { process.exit(rc); }

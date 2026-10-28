import { Node, NodeKind, bindSym, createNodeAt } from "std/meta";

export function target(value: int32): int32 { return value + 1; }

function describe(): string { return bindSym("target") == null ? "null" : "found"; }
function twoDeep(): string { return describe(); }

function callTarget(value: Node): Node {
	return createNodeAt(NodeKind.CallExpr, { callee: bindSym("target")!, arguments: [value], isDirectCall: false, resolvedOverloadIdx: -1 }, value.location);
}

export macro viaHelper(value: Node): Node { return callTarget(value); }
export macro probeHelper(value: Node): Node {
	return createNodeAt(NodeKind.StringLiteral, { value: describe() }, value.location);
}
export macro probeTwoDeep(value: Node): Node {
	return createNodeAt(NodeKind.StringLiteral, { value: twoDeep() }, value.location);
}

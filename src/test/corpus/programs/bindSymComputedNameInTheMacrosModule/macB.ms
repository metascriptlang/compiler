import { Node, NodeKind, bindSym, createNodeAt } from "std/meta";
import { other } from "./libB";

function callOne(name: string, at: Node): Node {
	const s = bindSym(name);
	if (s === null) throw new Error(`cannot bind ${name}`);
	return createNodeAt(NodeKind.CallExpr, { callee: s!, arguments: [at], isDirectCall: false, resolvedOverloadIdx: -1 }, at.location);
}

export macro callOtherB(x: Node): Node { return callOne("other", x); }

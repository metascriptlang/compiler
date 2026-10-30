import { Node, NodeKind, bindSym, createNodeAt } from "std/meta";
import { cube, other, weights, Mode } from "./libA";

function bound(name: string): Node {
	const s = bindSym(name);
	if (s === null) throw new Error(`cannot bind ${name}`);
	return s!;
}

function callOne(name: string, at: Node): Node {
	return createNodeAt(NodeKind.CallExpr, { callee: bound(name), arguments: [at], isDirectCall: false, resolvedOverloadIdx: -1 }, at.location);
}

export macro callCube(x: Node): Node { return callOne("cube", x); }
export macro callOther(x: Node): Node { return callOne("other", x); }
export macro weightAt(i: Node): Node {
	const table = bound("weights");
	return quote { ${table}[${i}] };
}
export macro fastIndex(i: Node): Node {
	const mode = bound("Mode");
	return quote { (${mode}.Fast as int32) + ${i} };
}

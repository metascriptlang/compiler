import { Node, NodeKind, bindSym, getImpl } from "std/meta";
import { sampler2D } from "./glsl";

function helper(x: int32): int32 { return x + 1; }

function show(n: Node | null): string {
	if (n == null) { return "no node"; }
	if (n.resolvedSym == null) { return "no symbol"; }
	const path = n.resolvedSym.modulePath;
	return n.resolvedSym.name + "@" + path.substring(path.lastIndexOf("/") + 1);
}

export macro probe(fn: Node): Node {
	const impl = getImpl(fn);
	let typed = "no body";
	if (impl != null && impl.kind == NodeKind.FunctionDecl) {
		const ret = impl.fnBody.statements[0];
		if (ret.kind == NodeKind.ReturnStmt && ret.argument != null && ret.argument.kind == NodeKind.CallExpr) {
			typed = show(ret.argument.callee);
		}
	}
	const text = "typed " + typed + " literal " + show(bindSym("sampler2D")) + " local " + show(bindSym("helper"));
	return { kind: NodeKind.StringLiteral, line: fn.line, column: fn.column, value: text };
}

export macro callBound(fn: Node): Node {
	return { kind: NodeKind.CallExpr, line: fn.line, column: fn.column, callee: bindSym("sampler2D"),
		arguments: [{ kind: NodeKind.NumberLiteral, line: fn.line, column: fn.column, value: 4 }] };
}

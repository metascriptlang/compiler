import { Node, NodeKind, TypeKind, getImpl, getType, typeKind, childCount, childAt } from "std/meta";

function getterCalls(n: Node, calls: Node[]): void {
	if (n.kind == NodeKind.CallExpr) calls.push(n);
	for (let i = 0; i < childCount(n); i++) getterCalls(childAt(n, i), calls);
}

export macro getters(fn: Node): Node {
	const calls: Node[] = [];
	const impl = getImpl(fn);
	if (impl != null) getterCalls(impl, calls);
	const out: string[] = [];
	for (const call of calls) {
		const decl = getImpl(childAt(call, 0));
		if (decl != null && decl.kind == NodeKind.FunctionDecl) {
			out.push(decl.fnName + ":" + (typeKind(getType(call)) == TypeKind.Struct ? "struct" : "other"));
		}
	}
	return { kind: NodeKind.StringLiteral, line: fn.line, column: fn.column, value: out.join(" ") };
}

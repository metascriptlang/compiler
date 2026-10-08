import { Node, NodeKind, SymbolKind, getImpl, childCount, childAt, symKind, intValue } from "std/meta";

function firstNumber(n: Node): string {
	if (n.kind == NodeKind.NumberLiteral) return String(intValue(n));
	for (let i = 0; i < childCount(n); i++) {
		const found = firstNumber(childAt(n, i));
		if (found != "") return found;
	}
	return "";
}

function implNumbers(n: Node, out: string[]): void {
	if (n.kind == NodeKind.CallExpr) {
		const impl = getImpl(childAt(n, 0));
		out.push(impl == null ? "nil" : firstNumber(impl));
	} else if (n.kind == NodeKind.Identifier && symKind(n) == SymbolKind.Variable) {
		const impl = getImpl(n);
		if (impl != null) out.push(firstNumber(impl));
	}
	for (let i = 0; i < childCount(n); i++) implNumbers(childAt(n, i), out);
}

export macro calleeNumbers(fn: Node): Node {
	const out: string[] = [];
	const impl = getImpl(fn);
	if (impl != null) implNumbers(impl, out);
	return { kind: NodeKind.StringLiteral, line: fn.line, column: fn.column, value: out.join(" ") };
}

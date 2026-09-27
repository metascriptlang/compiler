import { Node, NodeKind } from "std/meta";

function dbl(n: number): number { return n * 2; }

export macro twice(x: Node): Node {
	return { kind: NodeKind.CallExpr, line: x.line, column: x.column,
		callee: bindSym("dbl"), arguments: [x] };
}

export macro inner(x: Node): Node {
	return { kind: NodeKind.CallExpr, line: x.line, column: x.column,
		callee: bindSym("dbl"), arguments: [x] };
}

export macro outer(x: Node): Node {
	return { kind: NodeKind.CallExpr, line: x.line, column: x.column,
		callee: bindSym("inner"), arguments: [x] };
}

export macro callIt(f: Node): Node {
	return { kind: NodeKind.CallExpr, line: f.line, column: f.column,
		callee: f,
		arguments: [{ kind: NodeKind.NumberLiteral, line: f.line, column: f.column, value: 21 }] };
}

export macro outer2(x: Node): Node {
	return { kind: NodeKind.CallExpr, line: x.line, column: x.column,
		callee: bindSym("callIt"), arguments: [bindSym("dbl")] };
}

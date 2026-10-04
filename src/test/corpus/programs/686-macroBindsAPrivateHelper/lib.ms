import { Node, NodeKind } from "std/meta";

function dbl(n: number): number { return n * 2; }
function offset(n: number): number { return n + 100; }

export function apply(f: (n: number) => number, x: number): number { return f(x); }

export macro twice(x: Node): Node {
	return { kind: NodeKind.CallExpr, line: x.line, column: x.column, callee: bindSym("dbl"), arguments: [x] };
}

export macro shifted(x: Node): Node {
	return { kind: NodeKind.CallExpr, line: x.line, column: x.column, callee: bindSym("offset"), arguments: [x] };
}

export macro applyDbl(x: Node): Node {
	return { kind: NodeKind.CallExpr, line: x.line, column: x.column, callee: bindSym("apply"), arguments: [bindSym("dbl"), x] };
}

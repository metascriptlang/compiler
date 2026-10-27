// @stdout: 1 3 2
// note: a macro reads a node's fields through its NodeData alias (`n as BinaryExprData`, `n as ArrayLiteralData`), an anonymous object type whose layout is not the wire node's, so each field is found by its name, not by the alias's slot.

import { Node, NodeKind, BinaryExprData, ArrayLiteralData } from "std/meta";

macro rightOperand(n: Node): Node {
	const d: BinaryExprData = n as BinaryExprData;
	return d.right;
}

macro elementCount(n: Node): Node {
	const d: ArrayLiteralData = n as ArrayLiteralData;
	return { kind: NodeKind.NumberLiteral, line: n.line, column: n.column, value: d.elements.length };
}

macro innerCount(n: Node): Node {
	const outer: ArrayLiteralData = n as ArrayLiteralData;
	const inner: ArrayLiteralData = outer.elements[1] as ArrayLiteralData;
	return { kind: NodeKind.NumberLiteral, line: n.line, column: n.column, value: inner.elements.length };
}

console.log(rightOperand(1 + 2) - 1, elementCount([4, 5, 6]), innerCount([[1], [2, 3]]));

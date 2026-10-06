import { Node, NodeKind, bindSym } from "std/meta";

export function takes(b: Readonly<Span<uint8>>): int32 { return b.length; }
export function half(x: float32): float32 { return x / 2; }

export macro same(operand: Node): Node { return operand; }

export macro lengthOf(operand: Node): Node {
	return {
		kind: NodeKind.CallExpr, line: operand.line, column: operand.column,
		callee: bindSym("takes"),
		arguments: [{ kind: NodeKind.MemberExpr, line: operand.line, column: operand.column, object: operand, property: "bytes", isOptional: false }],
		isDirectCall: false, resolvedOverloadIdx: -1,
	};
}

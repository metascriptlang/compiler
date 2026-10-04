import { Node, NodeKind, bindSym } from "std/meta";

export function pick<E>(witness: E, other: E): E { return witness; }
export function pick(witness: string, other: string): string { return witness + "!"; }

export macro first(x: Node): Node {
	return { kind: NodeKind.CallExpr, line: x.line, column: x.column, callee: bindSym("pick"),
		arguments: [x, x], isDirectCall: false, resolvedOverloadIdx: -1 };
}

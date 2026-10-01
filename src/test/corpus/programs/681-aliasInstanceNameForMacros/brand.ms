import { Node, NodeKind } from "std/meta";

export type Brand<T> = T;
type Wrapped<T> = { v: T };

export function brand<T>(o: T): Brand<T> { return o; }
export function wrapped<T>(o: T): Wrapped<T> { return { v: o }; }

export macro head(node: Node): Node {
	let what = "none";
	const t = node.nodeType;
	if (t !== null) {
		what = "other";
		if (t.kind === NodeKind.TypeGeneric) {
			const base = t.typExprBase;
			what = "generic";
			if (base.kind === NodeKind.Identifier) { what = "generic:" + base.name; }
		} else if (t.kind === NodeKind.Identifier) {
			what = "ident:" + t.name;
		}
	}
	return { kind: NodeKind.StringLiteral, line: node.line, column: node.column, value: what };
}

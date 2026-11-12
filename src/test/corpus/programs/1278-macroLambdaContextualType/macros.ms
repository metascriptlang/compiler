import { ArrowFunctionData, BinaryExprData, MemberExprData, Node, NodeKind, TypeObjectData, createNodeAt, getType } from "std/meta";

export class Table<R, K> {
	rows: R[] = [];
	key: K | null = null;
}

function shown(n: Node): string {
	const t = getType(n);
	if (t == null) return "none";
	if (t.kind === NodeKind.TypeObject) {
		const o = t as TypeObjectData;
		return "row:" + o.typExprTypeName + "{" + o.typExprFieldNames.join(",") + "}";
	}
	return "other";
}

function report(f: Node): string {
	const arrow = f as ArrowFunctionData;
	const body = arrow.arrowBody.kind === NodeKind.BinaryExpr ? (arrow.arrowBody as BinaryExprData).left : arrow.arrowBody;
	return "declared=[" + arrow.arrowParamTypes.join(",") + "] " + shown((body as MemberExprData).object);
}

export macro where<R, K>(this t: Table<R, K>, f: (row: R) => boolean): Node {
	return createNodeAt(NodeKind.StringLiteral, { value: report(f) }, f.location);
}

export macro whereOne<R>(t: Table<R, string>, f: (row: R) => boolean): Node {
	return createNodeAt(NodeKind.StringLiteral, { value: report(f) }, f.location);
}

export macro untyped(fn: Node): Node {
	return createNodeAt(NodeKind.StringLiteral, { value: report(fn) }, fn.location);
}

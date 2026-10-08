import { Node, NodeKind, TypeKind, getImpl, getType, typeKind, childCount, childAt } from "std/meta";

function binaryKinds(n: Node, out: string[], depth: int32): void {
	if (n.kind == NodeKind.BinaryExpr) out.push(typeKind(getType(n)) == TypeKind.Float32 ? "f32" : "other");
	if (n.kind == NodeKind.CallExpr && depth == 0) {
		const impl = getImpl(childAt(n, 0));
		if (impl != null) binaryKinds(impl, out, depth + 1);
	}
	for (let i = 0; i < childCount(n); i++) binaryKinds(childAt(n, i), out, depth);
}

export macro bodyKinds(fn: Node): Node {
	const out: string[] = [];
	const impl = getImpl(fn);
	if (impl != null) binaryKinds(impl, out, 0);
	return { kind: NodeKind.StringLiteral, line: fn.line, column: fn.column, value: out.join(" ") };
}

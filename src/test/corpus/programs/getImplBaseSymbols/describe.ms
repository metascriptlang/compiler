import { Node, NodeKind, getImpl } from "std/meta";

export macro chain(t: Node): Node {
	function walk(decl: Node): string {
		let out = decl.interfaceName + "(" + decl.interfaceFields.join("+") + ")";
		for (const b of decl.baseExprs!) {
			const generic = b.kind == NodeKind.TypeGeneric;
			const base = getImpl(generic ? b.typExprBase : b);
			out = out + " <" + (generic ? " " + b.typExprArgs.length + "@" : "") + (base == null ? " null" : " " + walk(base));
		}
		return out;
	}
	return { kind: NodeKind.StringLiteral, line: t.line, column: t.column, value: walk(getImpl(t)!) };
}

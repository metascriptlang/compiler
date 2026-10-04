import { Node, NodeKind, getImpl } from "std/meta";

export macro fieldDecls(t: Node): Node {
	function declCode(d: Node | null): string {
		if (d == null) return "0";
		if (d.kind == NodeKind.StructDecl) return "S";
		if (d.kind == NodeKind.EnumDecl) return "E";
		if (d.kind == NodeKind.ClassDecl) return "C";
		if (d.kind == NodeKind.InterfaceDecl) return "I";
		if (d.kind == NodeKind.TypeAliasDecl) return "T";
		return "?";
	}
	function typeCode(n: Node | null): string {
		if (n == null) return "-";
		if (n.kind == NodeKind.Identifier) return n.name == "null" ? "n" : declCode(getImpl(n));
		if (n.kind == NodeKind.TypeArray) return "A" + typeCode(n.typExprElement);
		if (n.kind == NodeKind.TypeUnion) {
			let u = "U";
			for (const m of n.typExprMembers) u = u + typeCode(m);
			return u;
		}
		if (n.kind == NodeKind.TypeGeneric) {
			let g = "G" + typeCode(n.typExprBase);
			for (const a of n.typExprArgs) g = g + typeCode(a);
			return g;
		}
		return "?";
	}
	const decl = getImpl(t)!;
	let out = "";
	if (decl.kind == NodeKind.ClassDecl) {
		for (const m of decl.classBody) {
			if (m.kind == NodeKind.PropertyDecl) out = out + (out == "" ? "" : " ") + typeCode(m.typeExpr);
		}
	} else {
		for (const n of decl.typeExprs!) out = out + (out == "" ? "" : " ") + typeCode(n);
	}
	return { kind: NodeKind.StringLiteral, line: t.line, column: t.column, value: out };
}

export macro leafPaths(t: Node): Node {
	function walk(decl: Node, prefix: string): string {
		let out = "";
		for (let i = 0; i < decl.interfaceFields.length; i = i + 1) {
			const path = prefix + decl.interfaceFields[i];
			const ft = decl.typeExprs![i];
			const nested = ft.kind == NodeKind.Identifier ? getImpl(ft) : null;
			const part = nested != null && nested.kind == NodeKind.StructDecl ? walk(nested, path + ".") : path;
			out = out + (out == "" ? "" : " ") + part;
		}
		return out;
	}
	return { kind: NodeKind.StringLiteral, line: t.line, column: t.column, value: walk(getImpl(t)!, "") };
}

// Parity program — a computed key inside a macro argument reaches the macro as
// a ComputedProperty node: the key expression stays a MemberExpr whose object
// `getImpl` follows to its declaration, at the top of the argument and two
// object levels down, and two keys stay two properties.
//
// @stdout: [screen.wide:VariableDecl][screen.narrow:VariableDecl]|[screen.wide:VariableDecl]
// @exit: 0

import { Node, NodeKind, getImpl } from "std/meta";

const screen = { wide: 900, narrow: 400 };

macro breakpoints(v: Node): Node {
	let s = "";
	for (const p of v.properties) {
		if (p.kind != NodeKind.ComputedProperty) continue;
		const k = p.computedKey;
		const decl = getImpl(k.object);
		s = s + "[" + k.object.name + "." + k.property + ":" + (decl != null && decl.kind == NodeKind.VariableDecl ? "VariableDecl" : "none") + "]";
	}
	return { kind: NodeKind.StringLiteral, line: v.line, column: v.column, value: s };
}

macro sidebarWhen(v: Node): Node {
	const p = v.properties[0].properties[0].properties[0];
	if (p.kind != NodeKind.ComputedProperty) return { kind: NodeKind.StringLiteral, line: v.line, column: v.column, value: "not computed" };
	const k = p.computedKey;
	const decl = getImpl(k.object);
	const s = "[" + k.object.name + "." + k.property + ":" + (decl != null && decl.kind == NodeKind.VariableDecl ? "VariableDecl" : "none") + "]";
	return { kind: NodeKind.StringLiteral, line: v.line, column: v.column, value: s };
}

const flat = breakpoints({ [screen.wide]: { width: 280 }, [screen.narrow]: { width: 120 } });
const deep = sidebarWhen({ sidebar: { when: { [screen.wide]: { width: 280 } } } });
console.log(flat + "|" + deep);

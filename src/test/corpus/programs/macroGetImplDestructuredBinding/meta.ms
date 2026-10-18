import { Node, NodeKind, bindSym, getImpl, childAt, childCount } from "std/meta";

export macro creator(name: Node): Node {
	const impl = getImpl(bindSym(name.name));
	let shown = "null";
	if (impl !== null && impl.kind == NodeKind.DestructuringDecl) {
		const call = impl.destrInit;
		shown = "init " + call.kind.toString();
		if (call.kind == NodeKind.CallExpr) {
			const opts = call.arguments[1];
			if (opts.kind == NodeKind.ObjectLiteral) {
				const flag = opts.properties[0];
				shown = opts.keys[0] + "=" + (flag.kind == NodeKind.BooleanLiteral ? (flag.boolValue ? "true" : "false") : "?");
			}
		}
	} else if (impl !== null) {
		shown = "kind " + impl.kind.toString();
	}
	return { kind: NodeKind.StringLiteral, line: name.line, column: name.column, value: shown };
}

export macro bodyRead(fn: Node, read: Node): Node {
	const body = getImpl(bindSym(fn.name));
	const todo: Node[] = body === null ? [] : [body];
	let shown = "none";
	while (todo.length > 0) {
		const n = todo.pop()!;
		if (n.kind == NodeKind.CallExpr) {
			const callee = n.callee;
			if (callee.kind == NodeKind.Identifier && callee.name == read.name) {
				const arg = getImpl(n.arguments[0]);
				shown = arg === null ? "null" : arg.kind == NodeKind.DestructuringDecl ? "destructure" : "kind " + arg.kind.toString();
			}
		}
		for (let i = 0; i < childCount(n); i++) todo.push(childAt(n, i));
	}
	return { kind: NodeKind.StringLiteral, line: fn.line, column: fn.column, value: shown };
}

export macro implKind(name: Node): Node {
	const i = getImpl(bindSym(name.name));
	return { kind: NodeKind.StringLiteral, line: name.line, column: name.column, value: i === null ? "null" : "set" };
}

import { Node, NodeKind, getImpl, bindSym, childCount, childAt } from "std/meta";

export macro viaIf(fn: Node): Node {
	const impl = getImpl(bindSym(fn.name))!;
	let shown = "a";
	if (childCount(impl) > 0) {
		const child = childAt(impl, 0);
		shown = "b";
	}
	return { kind: NodeKind.StringLiteral, line: fn.line, column: fn.column, value: shown };
}

export macro viaLoop(fn: Node): Node {
	const impl = getImpl(bindSym(fn.name))!;
	const kinds: string[] = [];
	for (let i = 0; i < childCount(impl); i++) {
		const child = childAt(impl, i);
		kinds.push(child.kind.toString());
	}
	return { kind: NodeKind.StringLiteral, line: fn.line, column: fn.column, value: kinds.length.toString() + ":" + kinds.join(",") };
}

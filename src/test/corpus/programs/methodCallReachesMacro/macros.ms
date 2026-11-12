import { Node, NodeKind, createNodeAt, getType } from "std/meta";

export class Table<R> {
	name: string;
	constructor(name: string) { this.name = name; }
}

export macro whereM(this src: Node, fn: Node): Node {
	return createNodeAt(NodeKind.StringLiteral, { value: "method macro ran" }, fn.location);
}

export macro typeOfM(this src: Node): Node {
	let t = getType(src);
	if (t != null && t.kind == NodeKind.TypeGeneric && t.typExprBase.name == "Ref") t = t.typExprArgs[0];
	let text = "untyped";
	if (t != null && t.kind == NodeKind.Identifier) text = t.name;
	if (t != null && t.kind == NodeKind.TypeObject) text = "{" + t.typExprFieldNames.join(",") + "}";
	if (t != null && t.kind == NodeKind.TypeGeneric) {
		const args: string[] = [];
		for (const a of t.typExprArgs) args.push(a.kind == NodeKind.TypeObject ? "{" + a.typExprFieldNames.join(",") + "}" : a.name);
		text = t.typExprBase.name + "<" + args.join(",") + ">";
	}
	return createNodeAt(NodeKind.StringLiteral, { value: text }, src.location);
}

export macro twoM(this src: Node, a: Node, b: Node): Node {
	return createNodeAt(NodeKind.StringLiteral, { value: "two" }, src.location);
}

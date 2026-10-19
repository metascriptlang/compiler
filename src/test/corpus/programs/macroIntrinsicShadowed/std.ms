import { Node, NodeKind, splice, error } from "std/meta";

export macro doubled(x: Node): Node {
	return quote { ${x} * 2 };
}

export macro bumped(x: Node): Node {
	return quote { splice(x) + 1 };
}

export macro checked(x: Node): Node {
	if (x.kind == NodeKind.StringLiteral) error("checked wants a number", x);
	return x;
}

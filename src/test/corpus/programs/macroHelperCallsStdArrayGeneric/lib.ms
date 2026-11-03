import { Node, createNodeAt, NodeKind } from "std/meta";

export function doubled(xs: int32[]): string {
	return xs.map((n) => String(n * 2)).join(",");
}

export function rest(xs: string[]): string {
	return xs.slice(1).join("+");
}

function bumped(xs: int32[]): int32[] {
	return xs.map((n) => n + 1);
}

export function bumpedTail(xs: int32[]): string {
	return bumped(xs).slice(1).join("/");
}

export macro mapped(at: Node): Node {
	return createNodeAt(NodeKind.StringLiteral, { value: doubled([1, 2, 3]) }, at.location);
}

export macro sliced(at: Node): Node {
	return createNodeAt(NodeKind.StringLiteral, { value: rest(["a", "b", "c"]) }, at.location);
}

export macro nested(at: Node): Node {
	return createNodeAt(NodeKind.StringLiteral, { value: bumpedTail([1, 2, 3]) }, at.location);
}

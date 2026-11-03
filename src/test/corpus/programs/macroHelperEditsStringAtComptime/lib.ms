import { Node, createNodeAt, NodeKind } from "std/meta";

export function slashed(path: string): string {
	return path.split("\\").join("/");
}

export function edited(s: string): string {
	return s.replace("a", "A").replaceAll("b", "") + "|" + s.padStart(7, ".") + "|" + s.padEnd(7, "-");
}

function segments(path: string): string[] {
	return slashed(path).split("/");
}

export function lastSegment(path: string): string {
	const parts = segments(path);
	return parts[parts.length - 1];
}

export macro slashedAt(at: Node): Node {
	return createNodeAt(NodeKind.StringLiteral, { value: slashed("src\\core\\x.ms") }, at.location);
}

export macro editedAt(at: Node): Node {
	return createNodeAt(NodeKind.StringLiteral, { value: edited("abab") }, at.location);
}

export macro leafAt(at: Node): Node {
	return createNodeAt(NodeKind.StringLiteral, { value: lastSegment("a\\b\\leaf") }, at.location);
}

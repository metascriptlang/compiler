import { Node, childCount } from "std/meta";

export function arity(n: Node): number {
	return childCount(n);
}

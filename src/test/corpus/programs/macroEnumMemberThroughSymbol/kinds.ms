import { Node, NodeKind } from "std/meta";

export function isComputed(p: Node): boolean {
	return p.kind == NodeKind.ComputedProperty;
}

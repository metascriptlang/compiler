import { Node, NodeKind, TypeKind, typeKind } from "std/meta";

export function namesEnum(n: Node): boolean {
	return n.kind == NodeKind.Identifier && typeKind(n) == TypeKind.Enum;
}

console.log("HCR-CT entry");

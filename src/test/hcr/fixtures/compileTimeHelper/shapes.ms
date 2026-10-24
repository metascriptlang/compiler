import { Node, NodeKind, TypeKind, typeKind, getTypeImpl } from "std/meta";

export function namesStruct(n: Node): boolean {
	return n.kind == NodeKind.Identifier && typeKind(n) == TypeKind.Struct;
}

export function describe(n: Node): string {
	return namesStruct(n) ? "struct" : "other";
}

@comptime
export function implOf(n: Node): Node | null {
	return getTypeImpl(n);
}

export macro kindOf(x: Node): Node {
	return { kind: NodeKind.StringLiteral, line: x.line, column: x.column, value: describe(x) };
}

export function label(): string {
	return "shapes";
}

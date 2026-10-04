import { Node, NodeKind, getImpl } from "std/meta";

function declKindCode(d: Node | null): int32 {
	if (d == null) return 0;
	if (d.kind == NodeKind.StructDecl) return 1;
	if (d.kind == NodeKind.EnumDecl) return 2;
	if (d.kind == NodeKind.ClassDecl) return 3;
	return 9;
}

export macro declKind(x: Node): Node {
	const v = declKindCode(getImpl(x));
	return { kind: NodeKind.NumberLiteral, line: x.line, column: x.column, value: v as number, isFloat: false, intVal: v as int64, outOfRangeText: "", isBitPattern: false };
}

export macro firstDeclKind(list: Node): Node {
	const v = declKindCode(getImpl(list.elements[0]));
	return { kind: NodeKind.NumberLiteral, line: list.line, column: list.column, value: v as number, isFloat: false, intVal: v as int64, outOfRangeText: "", isBitPattern: false };
}

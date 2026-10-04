import { Node, NodeKind, getImpl, getTypeImpl } from "std/meta";

function declKindCode(d: Node | null): int32 {
	if (d == null) return 0;
	if (d.kind == NodeKind.StructDecl) return 1;
	if (d.kind == NodeKind.ClassDecl) return 3;
	return 9;
}

export macro declKind(x: Node): Node {
	const v = declKindCode(getImpl(x));
	return { kind: NodeKind.NumberLiteral, line: x.line, column: x.column, value: v as number, isFloat: false, intVal: v as int64, outOfRangeText: "", isBitPattern: false };
}

export macro typeArgKind(): Node {
	const t = getTypeArg();
	const v: int32 = t.kind == NodeKind.TypeObject ? 2 : 1;
	return { kind: NodeKind.NumberLiteral, line: t.line, column: t.column, value: v as number, isFloat: false, intVal: v as int64, outOfRangeText: "", isBitPattern: false };
}

export macro hasTypeImpl(x: Node): Node {
	const v: int32 = getTypeImpl(x) == null ? 0 : 1;
	return { kind: NodeKind.NumberLiteral, line: x.line, column: x.column, value: v as number, isFloat: false, intVal: v as int64, outOfRangeText: "", isBitPattern: false };
}

import { Node, NodeKind, bindSym, getType, stringValue, error } from "std/meta";

export macro scopeType(n: Node): Node {
	const name = stringValue(n);
	const t = getType(bindSym(name));
	if (t === null || t.kind !== NodeKind.TypeGeneric) error(name + " has no inferred type");
	return { kind: NodeKind.NumberLiteral, value: 1, isFloat: false, intVal: 1 };
}

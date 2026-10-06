// GUARD-CHECK-FAIL getSize: node has no type
// GUARD-CHECK-FAIL getAlign: node has no type
// GUARD-CHECK-FAIL getOffset: node type is not a struct
// GUARD-CHECK-FAIL getOffset: struct 'LayoutGuard' has no field 'missing'

import { Node, NodeKind, getSize, getAlign, getOffset } from "std/meta";

struct LayoutGuard { field: int32; }

macro missingSize(value: Node): Node {
	const bare: Node = { kind: NodeKind.Identifier, name: "unboundLayout" };
	const size = getSize(bare);
	return value;
}
macro missingAlign(value: Node): Node {
	const bare: Node = { kind: NodeKind.Identifier, name: "unboundLayout" };
	const alignment = getAlign(bare);
	return value;
}
macro scalarOffset(value: Node): Node {
	const offset = getOffset(value, "field");
	return value;
}
macro missingField(value: Node): Node {
	const offset = getOffset(value, "missing");
	return value;
}

const a = missingSize(1);
const b = missingAlign(1);
const c = scalarOffset(1);
const d = missingField(LayoutGuard);

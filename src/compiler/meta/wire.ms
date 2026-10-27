// Node wire metadata keys — the ONE list shared by the wire writer
// (nodeToASTLiteral in expand.ms) and the child-traversal reader (the
// msNodeChildCount/At bridges in hostTable.ms), and the checker's Node literal
// key check (engineNodeHasVirtualKey). resolvedSym and nodeType
// are node-shaped on the wire (Object with a numeric "kind"), so telling
// children from metadata rests entirely on both sides using this predicate.
// Adding a metadata key to nodeToASTLiteral without adding it here would
// silently turn it into a phantom child.

import { RaiserRegClass } from "../../raiser/bytecode";
import {
	RaiserValue, RaiserValueKind, RaiserObjectData, RaiserObjectHeap, RaiserArrayHeap, RaiserClassType, handleIndex, raiserNil, raiserInt, createStructHeap, createArrayHeap,
	createClassType, layOutObject, heapAllocObject, fieldIndex, fieldValueAt, fieldStoreAt, appendField,
	isObjectCell, heapObjectGetField, heapObjectSetField, heapNewObjectCell, objectCellHandle, OWNED_BY_RECEIVER_RC,
} from "../../raiser/value";

const NODE_WIRE_META: string[] = ["kind", "line", "column", "endLine", "endColumn", "argOrigin", "declSymHandle", "paramSymHandles",
	"symHandle", "typeHandle", "nodeType", "resolvedSym", "gensym"];

export function isNodeWireMetaField(name: string): boolean {
	return NODE_WIRE_META.includes(name) || name == "boundTypeExpr" || name == "boundTypeExprs" || name == "boundTypeNames";
}

export interface WireClass {
	classType: RaiserClassType;
	slots: Map<string, int32>;
}

function wireClass(fields: string[]): WireClass {
	const kinds: RaiserRegClass[] = [];
	const slots = new Map<string, int32>();
	for (let i = 0; i < fields.length; i += 1) {
		kinds.push(RaiserRegClass.Dyn);
		slots.set(fields[i], i as int32);
	}
	return { classType: createClassType("", -1, [], fields, kinds), slots };
}

export const WIRE_LOC: WireClass = wireClass(["line", "column", "endLine", "endColumn"]);
export const WIRE_SYMBOL: WireClass = wireClass(["name", "symbolKind", "modulePath", "builtinKind"]);
export const WIRE_UNION: WireClass = wireClass(["$tag", "$v"]);

export function allocWireObject(objHeap: RaiserObjectHeap, cls: WireClass): int64 {
	const handle = heapAllocObject(objHeap);
	layOutObject(objHeap.objects[handleIndex(handle)], cls.classType);
	return handle;
}

function wireClassOf(obj: RaiserObjectData): WireClass | null {
	if (obj.classType == WIRE_LOC.classType) return WIRE_LOC;
	if (obj.classType == WIRE_SYMBOL.classType) return WIRE_SYMBOL;
	if (obj.classType == WIRE_UNION.classType) return WIRE_UNION;
	return null;
}

function wireFieldIndex(obj: RaiserObjectData, name: string): number {
	const cls = wireClassOf(obj);
	if (cls != null) {
		const slot = cls.slots.get(name);
		if (slot != null) return slot;
	}
	return fieldIndex(obj, name);
}

export function wireGet(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, h: int64, name: string): RaiserValue {
	if (isObjectCell(h)) return heapObjectGetField(arrHeap, objHeap, h, name);
	const obj = objHeap.objects[handleIndex(h)];
	const i = wireFieldIndex(obj, name);
	return i >= 0 ? fieldValueAt(obj, i) : raiserNil();
}

export function wireSet(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, h: int64, name: string, val: RaiserValue): void {
	if (isObjectCell(h)) {
		heapObjectSetField(arrHeap, objHeap, h, name, val);
		return;
	}
	const obj = objHeap.objects[handleIndex(h)];
	const i = wireFieldIndex(obj, name);
	if (i >= 0) fieldStoreAt(obj, i, val);
	else appendField(obj, name, val);
}

test "a wire read or write of an object cell goes through the cell's own layout" {
	const arrHeap = createArrayHeap();
	const objHeap = createStructHeap();
	const t = createClassType("Tag", 0, [1], ["count", "bytes"], [RaiserRegClass.Word, RaiserRegClass.Ref]);
	const cell = objectCellHandle(heapNewObjectCell(arrHeap.mem, t, OWNED_BY_RECEIVER_RC as int64));
	wireSet(arrHeap, objHeap, cell, "count", raiserInt(7));
	assert wireGet(arrHeap, objHeap, cell, "count").intVal == 7;
	assert wireGet(arrHeap, objHeap, cell, "$tag").kind == RaiserValueKind.Nil;
	assert wireGet(arrHeap, objHeap, cell, "kind").kind == RaiserValueKind.Nil;
}

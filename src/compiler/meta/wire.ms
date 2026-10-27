// Node wire metadata keys — the ONE list shared by the wire writer
// (nodeToASTLiteral in expand.ms) and the child-traversal reader (the
// msNodeChildCount/At bridges in hostTable.ms), and the checker's Node literal
// key check (engineNodeHasVirtualKey). resolvedSym and nodeType
// are node-shaped on the wire (Object with a numeric "kind"), so telling
// children from metadata rests entirely on both sides using this predicate.
// Adding a metadata key to nodeToASTLiteral without adding it here would
// silently turn it into a phantom child.

import { Node, NodeKind, Type, SourceLocation, createNodeAt, makeLoc } from "../../ast/node";
import { nodeFields, nodeKindName, FieldSink } from "../../ast/fieldspec";
import { RaiserRegClass } from "../../raiser/bytecode";
import {
	RaiserValue, RaiserValueKind, RaiserObjectData, RaiserObjectHeap, RaiserClassType, handleIndex, raiserNil, raiserInt, createStructHeap,
	createClassType, layOutObject, heapAllocObject, fieldIndex, fieldValueAt, fieldStoreAt, appendField,
	heapObjectFieldNameAt, createArrayHeap, isObjectCell, heapObjectGetField, heapObjectSetField, heapNewObjectCell, objectCellHandle, OWNED_BY_RECEIVER_RC,
} from "../../raiser/value";

const NODE_WIRE_META: string[] = ["kind", "line", "column", "endLine", "endColumn", "argOrigin", "declSymHandle", "paramSymHandles",
	"symHandle", "typeHandle", "nodeType", "resolvedSym", "gensym"];
const NODE_WIRE_HEADER: string[] = [...NODE_WIRE_META, "flags", "folded", "typeArg"];

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

let _nodeClasses: (WireClass | null)[] = [];

function namesInto(fields: string[]): FieldSink {
	const add = (name: string): void => { fields.push(name); };
	return {
		node: (name: string, n: Node | null): void => { add(name); },
		nodes: (name: string, a: Node[] | null): void => { add(name); },
		nodesNested: (name: string, a: Node[][] | null): void => { add(name); },
		typ: (name: string, t: Type | null): void => { add(name); },
		str: (name: string, s: string): void => { add(name); },
		strArr: (name: string, a: string[] | null): void => { add(name); },
		integer: (name: string, v: int64): void => { add(name); },
		float: (name: string, v: float64): void => { add(name); },
		bool: (name: string, b: boolean): void => { add(name); },
		loc: (name: string, l: SourceLocation | null): void => { add(name); },
		locs: (name: string, l: SourceLocation[] | null): void => { add(name); },
		floats: (name: string, a: number[] | null): void => { add(name); },
	};
}

export function nodeWireClass(node: Node): WireClass {
	const kind = node.kind as int32;
	while (_nodeClasses.length <= kind) _nodeClasses.push(null);
	const known = _nodeClasses[kind];
	if (known != null) return known;
	if (nodeKindName(node.kind) == `Kind${kind}`) throw new Error(`internal: node kind ${kind} has no field spec, so it has no wire class`);
	const fields: string[] = [...NODE_WIRE_HEADER];
	nodeFields(node, namesInto(fields));
	const made = wireClass(fields);
	_nodeClasses[kind] = made;
	return made;
}

export function allocWireObject(objHeap: RaiserObjectHeap, cls: WireClass): int64 {
	const handle = heapAllocObject(objHeap);
	layOutObject(objHeap.objects[handleIndex(handle)], cls.classType);
	return handle;
}

function nodeClassOf(obj: RaiserObjectData): WireClass | null {
	if (obj.slots.length == 0 || obj.classType.fields[0] != "kind") return null;
	const kind = fieldValueAt(obj, 0);
	if (kind.kind != RaiserValueKind.Int || kind.intVal < 0 || kind.intVal >= _nodeClasses.length) return null;
	const cls = _nodeClasses[kind.intVal as int32];
	return cls != null && cls.classType == obj.classType ? cls : null;
}

function wireClassOf(obj: RaiserObjectData): WireClass | null {
	const node = nodeClassOf(obj);
	if (node != null) return node;
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

export function wireGet(objHeap: RaiserObjectHeap, h: int64, name: string): RaiserValue {
	if (isObjectCell(h)) return heapObjectGetField(objHeap, h, name);
	const obj = objHeap.objects[handleIndex(h)];
	const i = wireFieldIndex(obj, name);
	return i >= 0 ? fieldValueAt(obj, i) : raiserNil();
}

export function wireSet(objHeap: RaiserObjectHeap, h: int64, name: string, val: RaiserValue): void {
	if (isObjectCell(h)) {
		heapObjectSetField(objHeap, h, name, val);
		return;
	}
	const obj = objHeap.objects[handleIndex(h)];
	const i = wireFieldIndex(obj, name);
	if (i >= 0) fieldStoreAt(obj, i, val);
	else appendField(obj, name, val);
}

export function isNodeWireMetaSlot(objHeap: RaiserObjectHeap, h: int64, index: int32): boolean {
	const obj = objHeap.objects[handleIndex(h)];
	if (nodeClassOf(obj) != null && index < obj.slots.length) return index < NODE_WIRE_META.length;
	return isNodeWireMetaField(heapObjectFieldNameAt(objHeap, h, index));
}

test "a laid wire node reads its header as metadata and its kind's fields as children" {
	const heap = createStructHeap();
	const node = createNodeAt(NodeKind.UnaryExpr, { unaryOp: "-", operand: null as unknown as Node }, makeLoc(1, 0));
	const h = allocWireObject(heap, nodeWireClass(node));
	wireSet(heap, h, "kind", raiserInt(NodeKind.UnaryExpr as int64));
	wireSet(heap, h, "operand", raiserInt(7));
	const obj = heap.objects[handleIndex(h)];
	assert obj.added.length == 0;
	assert obj.classType.fields[NODE_WIRE_HEADER.length + 1] == "operand";
	assert wireGet(heap, h, "operand").intVal == 7;
	assert isNodeWireMetaSlot(heap, h, 0);
	assert isNodeWireMetaSlot(heap, h, (NODE_WIRE_META.length - 1) as int32);
	assert !isNodeWireMetaSlot(heap, h, NODE_WIRE_META.length as int32);
	const u = allocWireObject(heap, WIRE_UNION);
	assert !isNodeWireMetaSlot(heap, u, 1);
}

test "a wire read or write of an object cell goes through the cell's own layout" {
	const arrHeap = createArrayHeap();
	const objHeap = createStructHeap();
	const t = createClassType("Tag", 0, [1], ["count", "bytes"], [RaiserRegClass.Word, RaiserRegClass.Ref]);
	const cell = objectCellHandle(heapNewObjectCell(arrHeap.mem, t, OWNED_BY_RECEIVER_RC as int64));
	wireSet(objHeap, cell, "count", raiserInt(7));
	assert wireGet(objHeap, cell, "count").intVal == 7;
	assert wireGet(objHeap, cell, "$tag").kind == RaiserValueKind.Nil;
	assert wireGet(objHeap, cell, "kind").kind == RaiserValueKind.Nil;
}

import { VmMemory, createVmMemory, newCell, disposeCell, cellRc, setCellRc, setCellRootIdx, cellTypeIndex, cellAllocSize, isLiveCell, liveCellBlocks, ld64, st64 } from "./memory";
import { RaiserRegClass } from "./bytecode";import { RaiserClassType, RaiserValueKind, RaiserHeapKind, createClassType, objectCellHandle, raiserObject, RAISER_NO_CLASS, createArrayHeap, createStructHeap, handleKind, handleAgrees, rcIncrefHandle, rcDecrefHandle, rcDecIsLast, rcCountOf, rcFreeHandle, raiserInt, raiserFloat, heapObjectSetField, heapObjectGetField, heapObjectFieldCount, heapObjectFieldNameAt, heapObjectFieldRefusal, heapObjectFieldIndex, heapObjectClass, OBJECT_CELL_SLOT_BYTES, classTypeIndex, classTypeAt } from "./value";

// An object with a layout is a cell: the reference header, then one 8 byte slot per laid field in layout order.
// The header's type word indexes the class type table, so a cell knows its class and its destroy routine without a handle
// heap. A Dyn slot holds the handle of its box, as a Dyn register does; every other slot holds the word its class holds.
export function objectCellNew(mem: VmMemory, t: RaiserClassType, rc: int64): int64 {
	when (mode != "danger") { if (t.kinds.length != t.fields.length) throw new Error(`internal: class ${t.name} has ${t.fields.length} fields and ${t.kinds.length} slot classes`); }
	when (mode != "danger") { if (t.kinds.includes(RaiserRegClass.Dyn)) throw new Error(`internal: class ${t.name} has a Dyn slot, which a cell holds only once Dyn values are cells`); }
	const cell = newCell(mem, (t.fields.length as int64) * OBJECT_CELL_SLOT_BYTES, 8, classTypeIndex(t) as int64, true);
	setCellRc(cell, rc);
	setCellRootIdx(cell, 0);
	return cell;
}

export function objectCellType(cell: int64): RaiserClassType {
	return classTypeAt(cellTypeIndex(cell));
}

@inline
export function objectCellSlot(cell: int64, i: number): int64 {
	return ld64(cell + (i as int64) * OBJECT_CELL_SLOT_BYTES);
}

@inline
export function objectCellSetSlot(cell: int64, i: number, v: int64): void {
	st64(cell + (i as int64) * OBJECT_CELL_SLOT_BYTES, v);
}

export function objectCellSlotCount(cell: int64): number {
	return objectCellType(cell).fields.length;
}

export function objectCellFree(mem: VmMemory, cell: int64): void {
	if (!disposeCell(mem, cell, 8)) throw new Error(`internal: object cell ${cell} is not a live cell`);
}

function pointType(): RaiserClassType {
	return createClassType("Point", 0, [1], ["x", "y", "name"], [RaiserRegClass.Word, RaiserRegClass.Float, RaiserRegClass.Ref]);
}

test "an object cell starts zeroed, keeps its slots and names its class through the header" {
	const mem = createVmMemory();
	const t = pointType();
	const cell = objectCellNew(mem, t, 0);
	assert isLiveCell(cell);
	assert objectCellType(cell).name == "Point" && objectCellSlotCount(cell) == 3;
	for (let i = 0; i < 3; i += 1) assert objectCellSlot(cell, i) == 0;
	objectCellSetSlot(cell, 0, 7);
	objectCellSetSlot(cell, 2, 99);
	assert objectCellSlot(cell, 0) == 7 && objectCellSlot(cell, 1) == 0 && objectCellSlot(cell, 2) == 99;
	assert cellRc(cell) == 0 && cellAllocSize(cell) >= 24 + 24;
	objectCellFree(mem, cell);
	assert liveCellBlocks(mem).length == 0;
}

test "an object cell's handle reads as an object and a release of the last holder frees the cells it holds" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const t = pointType();
	const inner = objectCellNew(arr.mem, t, 1);
	const outer = objectCellNew(arr.mem, t, 1);
	objectCellSetSlot(outer, 2, objectCellHandle(inner));
	assert handleKind(objectCellHandle(outer)) == RaiserValueKind.Object;
	assert handleAgrees(RaiserValueKind.Object, objectCellHandle(outer)) && !handleAgrees(RaiserValueKind.Array, objectCellHandle(outer));
	rcIncrefHandle(arr, obj, objectCellHandle(inner));
	assert rcCountOf(arr, obj, objectCellHandle(inner)) == 2;
	rcDecrefHandle(arr, obj, objectCellHandle(outer));
	assert rcCountOf(arr, obj, objectCellHandle(inner)) == 1;
	assert liveCellBlocks(arr.mem).length == 1;
	assert rcDecIsLast(arr, obj, objectCellHandle(inner));
	rcFreeHandle(arr, obj, objectCellHandle(inner));
	assert liveCellBlocks(arr.mem).length == 0;
}

test "the host field accessors read and store a cell's laid slots in their classes" {
	const obj = createStructHeap();
	const cell = objectCellNew(createArrayHeap().mem, pointType(), 0);
	const h = objectCellHandle(cell);
	heapObjectSetField(obj, h, "x", raiserInt(7));
	heapObjectSetField(obj, h, "y", raiserInt(2));
	assert heapObjectFieldCount(obj, h) == 3 && heapObjectFieldNameAt(obj, h, 1) == "y";
	assert heapObjectGetField(obj, h, "x").intVal == 7 && heapObjectGetField(obj, h, "y").floatVal == 2.0;
	assert heapObjectGetField(obj, h, "name").kind == RaiserValueKind.Nil && heapObjectGetField(obj, h, "none").kind == RaiserValueKind.Nil;
	assert heapObjectFieldRefusal(obj, h, 0, raiserFloat(1.5)) != "" && heapObjectFieldRefusal(obj, h, 1, raiserInt(1)) == "";
	assert heapObjectFieldIndex(obj, h, "name") == 2 && heapObjectClass(obj, h).name == "Point";
}

test "one class type shares a table index however many cells hold it" {
	const mem = createVmMemory();
	const a = objectCellNew(mem, pointType(), 0);
	const b = objectCellNew(mem, pointType(), 0);
	assert cellTypeIndex(a) == cellTypeIndex(b);
	assert objectCellType(a).fields.length == 3;
	objectCellFree(mem, a);
	objectCellFree(mem, b);
	assert liveCellBlocks(mem).length == 0;
}

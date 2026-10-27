import { VmMemory, createVmMemory, newCell, disposeCell, cellRc, setCellRc, setCellRootIdx, cellTypeIndex, cellAllocSize, isLiveCell, liveCellBlocks, ld64, st64 } from "./memory";
import { RaiserRegClass } from "./bytecode";
import { RaiserClassType, RaiserValueKind, RaiserHeapKind, createClassType, copyGraph, heapNewObjectCell, objectCellHandle, raiserObject, RAISER_NO_CLASS, createArrayHeap, createStructHeap, handleKind, handleAgrees, rcIncrefHandle, rcDecrefHandle, rcDecIsLast, rcCountOf, rcFreeHandle, raiserInt, raiserFloat, heapObjectSetField, heapObjectGetField, heapObjectFieldCount, heapObjectFieldNameAt, heapObjectFieldRefusal, heapObjectFieldIndex, heapObjectClass, OBJECT_CELL_SLOT_BYTES, classTypeIndex, classTypeAt, raiserNil, heapAllocString, heapBoxLive, heapStringText } from "./value";

// An object with a layout is a cell: the reference header, then one 8 byte slot per laid field in layout order.
// The header's type word indexes the class type table, so a cell knows its class and its destroy routine without a handle
// heap. A Dyn slot holds the handle of its box, as a Dyn register does; every other slot holds the word its class holds.
export function objectCellNew(mem: VmMemory, t: RaiserClassType, rc: int64): int64 {
	return heapNewObjectCell(mem, t, rc);
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
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const cell = objectCellNew(arr.mem, pointType(), 0);
	const h = objectCellHandle(cell);
	heapObjectSetField(arr, obj, h, "x", raiserInt(7));
	heapObjectSetField(arr, obj, h, "y", raiserInt(2));
	assert heapObjectFieldCount(obj, h) == 3 && heapObjectFieldNameAt(obj, h, 1) == "y";
	assert heapObjectGetField(arr, obj, h, "x").intVal == 7 && heapObjectGetField(arr, obj, h, "y").floatVal == 2.0;
	assert heapObjectGetField(arr, obj, h, "name").kind == RaiserValueKind.Nil && heapObjectGetField(arr, obj, h, "none").kind == RaiserValueKind.Nil;
	assert heapObjectFieldRefusal(obj, h, 0, raiserFloat(1.5)) != "" && heapObjectFieldRefusal(obj, h, 1, raiserInt(1)) == "";
	assert heapObjectFieldIndex(obj, h, "name") == 2 && heapObjectClass(obj, h).name == "Point";
}

test "copyGraph copies a ring of cells into another heap, keeping the ring and leaving the source alone" {
	const sArr = createArrayHeap();
	const sObj = createStructHeap();
	const dArr = createArrayHeap();
	const dObj = createStructHeap();
	const a = objectCellNew(sArr.mem, pointType(), 1);
	const b = objectCellNew(sArr.mem, pointType(), 1);
	objectCellSetSlot(a, 0, 3);
	objectCellSetSlot(a, 2, objectCellHandle(b));
	objectCellSetSlot(b, 2, objectCellHandle(a));
	const copied = copyGraph(sArr, sObj, dArr, dObj, raiserObject(objectCellHandle(a)));
	assert copied.intVal != objectCellHandle(a) && heapObjectGetField(dArr, dObj, copied.intVal, "x").intVal == 3;
	const next = heapObjectGetField(dArr, dObj, copied.intVal, "name");
	assert next.intVal != objectCellHandle(b) && heapObjectGetField(dArr, dObj, next.intVal, "name").intVal == copied.intVal;
	assert liveCellBlocks(dArr.mem).length == 2 && liveCellBlocks(sArr.mem).length == 2;
	assert objectCellSlot(a, 2) == objectCellHandle(b);
}

test "one class type shares a table index however many cells hold it" {
	const mem = createVmMemory();
	const t = pointType();
	const a = objectCellNew(mem, t, 0);
	const b = objectCellNew(mem, t, 0);
	assert cellTypeIndex(a) == cellTypeIndex(b) && objectCellType(a) == t;
	const other = objectCellNew(mem, pointType(), 0);
	assert cellTypeIndex(other) != cellTypeIndex(a);
	assert objectCellType(a).fields.length == 3;
	objectCellFree(mem, other);
	objectCellFree(mem, a);
	objectCellFree(mem, b);
	assert liveCellBlocks(mem).length == 0;
}

function dynType(): RaiserClassType {
	return createClassType("Dynamo", -1, [], ["n", "d"], [RaiserRegClass.Word, RaiserRegClass.Dyn]);
}

test "a Dyn slot of a cell holds one box for the cell's lifetime, written in place and freed with the cell" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const cell = objectCellNew(arr.mem, dynType(), 1);
	const h = objectCellHandle(cell);
	assert heapObjectGetField(arr, obj, h, "d").kind == RaiserValueKind.Nil && heapBoxLive(arr) == 0;
	heapObjectSetField(arr, obj, h, "d", raiserNil());
	assert heapBoxLive(arr) == 0;
	for (let i = 0; i < 200; i += 1) heapObjectSetField(arr, obj, h, "d", raiserInt(i));
	assert heapObjectGetField(arr, obj, h, "d").intVal == 199;
	assert heapBoxLive(arr) == 1 && arr.boxes.items.length == 1;
	heapObjectSetField(arr, obj, h, "d", heapAllocString(arr, "kept"));
	assert heapBoxLive(arr) == 1 && arr.boxes.items.length == 1;
	assert heapStringText(arr, heapObjectGetField(arr, obj, h, "d")) == "kept";
	rcDecrefHandle(arr, obj, h);
	assert heapBoxLive(arr) == 0 && liveCellBlocks(arr.mem).length == 0;
}

test "a copied cell takes its own box for a Dyn slot and keeps the references the slot holds" {
	const sArr = createArrayHeap();
	const sObj = createStructHeap();
	const dArr = createArrayHeap();
	const dObj = createStructHeap();
	const cell = objectCellNew(sArr.mem, dynType(), 1);
	heapObjectSetField(sArr, sObj, objectCellHandle(cell), "d", heapAllocString(sArr, "shared"));
	const copied = copyGraph(sArr, sObj, dArr, dObj, raiserObject(objectCellHandle(cell)));
	assert heapBoxLive(sArr) == 1 && heapBoxLive(dArr) == 1;
	assert heapStringText(dArr, heapObjectGetField(dArr, dObj, copied.intVal, "d")) == "shared";
	heapObjectSetField(dArr, dObj, copied.intVal, "d", raiserInt(4));
	assert heapStringText(sArr, heapObjectGetField(sArr, sObj, objectCellHandle(cell), "d")) == "shared";
}

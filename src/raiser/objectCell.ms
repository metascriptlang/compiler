import { VmMemory, createVmMemory, newCell, disposeCell, cellRc, setCellRc, setCellRootIdx, cellTypeIndex, cellAllocSize, isLiveCell, liveCellBlocks, ld64, st64 } from "./memory";
import { RaiserRegClass } from "./bytecode";
import { RaiserClassType, RaiserValueKind, RaiserHeapKind, createClassType, createArrayHeap, createStructHeap, handleKind, handleAgrees, rcIncrefHandle, rcDecrefHandle, rcDecIsLast, rcCountOf, rcFreeHandle, OBJECT_CELL_SLOT_BYTES, classTypeIndex, classTypeAt } from "./value";

// An object with a layout is a cell: the reference header, then one 8 byte slot per laid field in layout order.
// The header's type word indexes the class type table, so a cell knows its class and its destroy routine without a handle
// heap. A Dyn slot holds the handle of its box, as a Dyn register does; every other slot holds the word its class holds.
export function objectCellNew(mem: VmMemory, t: RaiserClassType, rc: int64): int64 {
	when (mode != "danger") { if (t.kinds.length != t.fields.length) throw new Error(`internal: class ${t.name} has ${t.fields.length} fields and ${t.kinds.length} slot classes`); }
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

function cellHandle(cell: int64): int64 {
	return cell | (RaiserHeapKind.Seq as int64);
}

test "an object cell's handle reads as an object and a release of the last holder frees the cells it holds" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const t = pointType();
	const inner = objectCellNew(arr.mem, t, 1);
	const outer = objectCellNew(arr.mem, t, 1);
	objectCellSetSlot(outer, 2, cellHandle(inner));
	assert handleKind(cellHandle(outer)) == RaiserValueKind.Object;
	assert handleAgrees(RaiserValueKind.Object, cellHandle(outer)) && !handleAgrees(RaiserValueKind.Array, cellHandle(outer));
	rcIncrefHandle(arr, obj, cellHandle(inner));
	assert rcCountOf(arr, obj, cellHandle(inner)) == 2;
	rcDecrefHandle(arr, obj, cellHandle(outer));
	assert rcCountOf(arr, obj, cellHandle(inner)) == 1;
	assert liveCellBlocks(arr.mem).length == 1;
	assert rcDecIsLast(arr, obj, cellHandle(inner));
	rcFreeHandle(arr, obj, cellHandle(inner));
	assert liveCellBlocks(arr.mem).length == 0;
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

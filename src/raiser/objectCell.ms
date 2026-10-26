import { VmMemory, createVmMemory, newCell, disposeCell, cellRc, setCellRc, setCellRootIdx, cellTypeIndex, cellAllocSize, isLiveCell, liveCellBlocks, ld64, st64 } from "./memory";
import { RaiserRegClass } from "./bytecode";
import { RaiserClassType, createClassType } from "./value";

// An object with a layout is a cell: the reference header, then one 8 byte slot per laid field in layout order.
// The header's type word indexes the table below, so a cell knows its class and its destroy routine without a handle
// heap. A Dyn slot holds the handle of its box, as a Dyn register does; every other slot holds the word its class holds.
export const OBJECT_SLOT_SIZE: int64 = 8;

const classTypes: RaiserClassType[] = [];
const registered: Map<string, int32> = new Map<string, int32>();

// The table index of a class type, adding it on first use. Two types of one name and one field layout share an index.
export function classTypeIndex(t: RaiserClassType): int32 {
	const key = `${t.name}/${t.depth}/${t.fields.join(",")}`;
	if (registered.has(key)) return registered.get(key)!;
	const index = classTypes.length as int32;
	classTypes.push(t);
	registered.set(key, index);
	return index;
}

export function classTypeAt(index: int64): RaiserClassType {
	if (index < 0 || index >= classTypes.length) throw new Error(`internal: type index ${index} is not in the type table`);
	return classTypes[index as number];
}

export function objectCellNew(mem: VmMemory, t: RaiserClassType, rc: int64): int64 {
	const cell = newCell(mem, (t.fields.length as int64) * OBJECT_SLOT_SIZE, 8, classTypeIndex(t) as int64, true);
	setCellRc(cell, rc);
	setCellRootIdx(cell, 0);
	return cell;
}

export function objectCellType(cell: int64): RaiserClassType {
	return classTypeAt(cellTypeIndex(cell));
}

@inline
export function objectCellSlot(cell: int64, i: number): int64 {
	return ld64(cell + (i as int64) * OBJECT_SLOT_SIZE);
}

@inline
export function objectCellSetSlot(cell: int64, i: number, v: int64): void {
	st64(cell + (i as int64) * OBJECT_SLOT_SIZE, v);
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

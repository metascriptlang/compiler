// Raiser live-0 ledger. Under orc every holder of a heap item counts it, so once the
// roots are released an item whose count is higher than the references that remain
// would stay live. The audit finds those items without releasing anything: it counts
// the references the roots and the live items make and compares them with each count.

import {
	RaiserValue, RaiserValueKind, RaiserHeapKind, handleIndex, handleHeapKind, raiserArray, raiserObject,
	RaiserArrayHeap, RaiserObjectHeap, createArrayHeap, createStructHeap, heapAllocString, heapAllocArray, heapAllocObject, heapAllocBox,
	heapArrayPush, rcIncref, rcDecref
} from "./value";

interface LedgerTally {
	strings: int32[];
	arrays: int32[];
	objects: int32[];
	boxes: int32[];
}

function zeros(count: int32): int32[] {
	const out: int32[] = [];
	for (let i = 0; i < count; i += 1) out.push(0);
	return out;
}

function tallyRef(tally: LedgerTally, v: RaiserValue): void {
	if (v.kind < RaiserValueKind.String) return;
	const index = handleIndex(v.intVal);
	match (handleHeapKind(v.intVal)) {
		RaiserHeapKind.String => { tally.strings[index] += 1; },
		RaiserHeapKind.Array => { tally.arrays[index] += 1; },
		RaiserHeapKind.Object => { tally.objects[index] += 1; },
		RaiserHeapKind.Box => { tally.boxes[index] += 1; },
		RaiserHeapKind.None | RaiserHeapKind.ConstString | RaiserHeapKind.Future => {},
		_ => { throw new Error(`internal: handle ${v.intVal} names no heap kind`); },
	}
}

function freeFlags(count: int32, freeList: int64[]): boolean[] {
	const free: boolean[] = [];
	for (let i = 0; i < count; i += 1) free.push(false);
	for (const index of freeList) free[index] = true;
	return free;
}

// "" when every live item's count is the number of references the roots and the live items
// make to it; otherwise the message that names the first disagreement.
export function ledgerAudit(arr: RaiserArrayHeap, obj: RaiserObjectHeap, roots: RaiserValue[], where: string): string {
	const tally: LedgerTally = {
		strings: zeros(arr.strings.texts.length), arrays: zeros(arr.arrays.length),
		objects: zeros(obj.objects.length), boxes: zeros(arr.boxes.items.length),
	};
	const freeStrings = freeFlags(arr.strings.texts.length, arr.strings.freeList);
	const freeArrays = freeFlags(arr.arrays.length, arr.freeList);
	const freeObjects = freeFlags(obj.objects.length, obj.freeList);
	const freeBoxes = freeFlags(arr.boxes.items.length, arr.boxes.freeList);
	for (const root of roots) tallyRef(tally, root);
	for (let i = 0; i < arr.arrays.length; i += 1) {
		if (!freeArrays[i]) for (const item of arr.arrays[i].items) tallyRef(tally, item);
	}
	for (let i = 0; i < obj.objects.length; i += 1) {
		if (!freeObjects[i]) for (const field of obj.objects[i].fields) tallyRef(tally, field.value);
	}
	for (let i = 0; i < arr.boxes.items.length; i += 1) {
		if (!freeBoxes[i]) tallyRef(tally, arr.boxes.items[i].value);
	}
	let leakedStrings = 0;
	let leakedArrays = 0;
	let leakedObjects = 0;
	let leakedBoxes = 0;
	for (let i = 0; i < tally.strings.length; i += 1) {
		if (freeStrings[i]) continue;
		if (arr.strings.rc[i] < tally.strings[i]) return `internal: string ${i} counts ${arr.strings.rc[i]} holders but ${tally.strings[i]} hold it at ${where} end`;
		if (arr.strings.rc[i] > tally.strings[i]) leakedStrings += 1;
	}
	for (let i = 0; i < tally.arrays.length; i += 1) {
		if (freeArrays[i]) continue;
		if (arr.arrays[i].rc < tally.arrays[i]) return `internal: array ${i} counts ${arr.arrays[i].rc} holders but ${tally.arrays[i]} hold it at ${where} end`;
		if (arr.arrays[i].rc > tally.arrays[i]) leakedArrays += 1;
	}
	for (let i = 0; i < tally.objects.length; i += 1) {
		if (freeObjects[i]) continue;
		if (obj.objects[i].rc < tally.objects[i]) return `internal: object ${i} counts ${obj.objects[i].rc} holders but ${tally.objects[i]} hold it at ${where} end`;
		if (obj.objects[i].rc > tally.objects[i]) leakedObjects += 1;
	}
	for (let i = 0; i < tally.boxes.length; i += 1) {
		if (freeBoxes[i]) continue;
		if (arr.boxes.items[i].rc < tally.boxes[i]) return `internal: box ${i} counts ${arr.boxes.items[i].rc} holders but ${tally.boxes[i]} hold it at ${where} end`;
		if (arr.boxes.items[i].rc > tally.boxes[i]) leakedBoxes += 1;
	}
	if (leakedStrings > 0) return `internal: ${leakedStrings} string items live after ${where} end`;
	if (leakedArrays > 0) return `internal: ${leakedArrays} array items live after ${where} end`;
	if (leakedObjects > 0) return `internal: ${leakedObjects} object items live after ${where} end`;
	if (leakedBoxes > 0) return `internal: ${leakedBoxes} box items live after ${where} end`;
	return "";
}

test "the audit accepts a graph whose counts are its references" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const s = heapAllocString(arr, "kept");
	rcIncref(arr, obj, s);
	const a = heapAllocArray(arr);
	heapArrayPush(arr, a, s);
	rcIncref(arr, obj, s);
	rcIncref(arr, obj, raiserArray(a));
	const b = heapAllocBox(arr, raiserArray(a));
	rcIncref(arr, obj, raiserArray(a));
	rcIncref(arr, obj, { kind: RaiserValueKind.Box, intVal: b, floatVal: 0.0 });
		const boxed: RaiserValue = { kind: RaiserValueKind.Box, intVal: b, floatVal: 0.0 };
	const roots: RaiserValue[] = [s, raiserArray(a), boxed];
	assert ledgerAudit(arr, obj, roots, "program") == "";
}

test "the audit names a heap whose item outlives its roots" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const s = heapAllocString(arr, "leaked");
	rcIncref(arr, obj, s);
	const o = heapAllocObject(obj);
	rcIncref(arr, obj, raiserObject(o));
	assert ledgerAudit(arr, obj, [raiserObject(o)], "strand") == "internal: 1 string items live after strand end";
	rcDecref(arr, obj, s);
	assert ledgerAudit(arr, obj, [raiserObject(o)], "strand") == "";
	assert ledgerAudit(arr, obj, [], "strand") == "internal: 1 object items live after strand end";
}

test "the audit names an item held more often than it is counted" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const s = heapAllocString(arr, "twice");
	rcIncref(arr, obj, s);
	assert ledgerAudit(arr, obj, [s, s], "program") == "internal: string 0 counts 1 holders but 2 hold it at program end";
}

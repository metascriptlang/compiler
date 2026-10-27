// Raiser live-0 ledger. Under orc every holder of a heap item counts it, so once the
// roots are released an item whose count is higher than the references that remain
// would stay live. The audit finds those items without releasing anything: it counts
// the references the roots and the live items make and compares them with each count.

import {
	RaiserValue, RaiserValueKind, RaiserHeapKind, handleIndex, handleHeapKind, raiserArray, raiserObject,
	RaiserArrayHeap, RaiserObjectHeap, createArrayHeap, createStructHeap, heapAllocString, heapAllocArray, heapAllocObject, heapAllocBox,
	heapArrayPush, rcIncref, rcDecref, objectFieldCount, fieldValueAt, arrayHoldsHandles, arrayHeldCount, arrayHeldAt, stringBytesHandles, heapStringHandles, heapSeqHandles, heapObjectCellHandles, objectCellClass, objectCellFieldValue, objectCellRawSlot, stringHandleRc,
	heapArrayIsView, heapArrayRc, makeHandle, createClassType, objectCellHandle
} from "./value";
import { RaiserRegClass } from "./bytecode";
import { objectCellNew, objectCellSetSlot } from "./objectCell";

interface LedgerTally {
	strings: HashMap<int64, int32>;
	seqs: HashMap<int64, int32>;
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
		RaiserHeapKind.String => { const held = tally.strings.get(v.intVal); tally.strings.set(v.intVal, (held != null ? held : 0) + 1); },
		RaiserHeapKind.Seq => { const held = tally.seqs.get(v.intVal); tally.seqs.set(v.intVal, (held != null ? held : 0) + 1); },
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
		strings: new HashMap<int64, int32>(), seqs: new HashMap<int64, int32>(), arrays: zeros(arr.arrays.length),
		objects: zeros(obj.objects.length), boxes: zeros(arr.boxes.items.length),
	};
	const freeArrays = freeFlags(arr.arrays.length, arr.freeList);
	const freeObjects = freeFlags(obj.objects.length, obj.freeList);
	const freeBoxes = freeFlags(arr.boxes.items.length, arr.boxes.freeList);
	const stringBytes = stringBytesHandles(arr);
	for (const root of roots) {
		if (root.kind == RaiserValueKind.Array && stringBytes.includes(root.intVal)) continue;
		tallyRef(tally, root);
	}
	for (const bytes of stringBytes) tallyRef(tally, raiserArray(bytes));
	for (let i = 0; i < arr.arrays.length; i += 1) {
		const handle = makeHandle(i, RaiserHeapKind.Array);
		if (freeArrays[i] || !arrayHoldsHandles(arr, handle)) continue;
		const held = arrayHeldCount(arr, handle);
		for (let k = 0; k < held; k += 1) tallyRef(tally, arrayHeldAt(arr, handle, k));
	}
	const seqHandles = heapSeqHandles(arr);
	for (const handle of seqHandles) {
		if (heapArrayIsView(arr, handle)) continue;
		if (arrayHoldsHandles(arr, handle)) {
			const held = arrayHeldCount(arr, handle);
			for (let k = 0; k < held; k += 1) tallyRef(tally, arrayHeldAt(arr, handle, k));
		}
	}
	const cellHandles = heapObjectCellHandles(arr);
	for (const handle of cellHandles) {
		const kinds = objectCellClass(handle).kinds;
		for (let f = 0; f < kinds.length; f += 1) {
			if (kinds[f] == RaiserRegClass.Dyn) {
				const box = objectCellRawSlot(handle, f);
				if (box != 0) tallyRef(tally, { kind: RaiserValueKind.Box, intVal: box, floatVal: 0.0 });
			} else tallyRef(tally, objectCellFieldValue(arr, handle, f));
		}
	}
	for (let i = 0; i < obj.objects.length; i += 1) {
		if (freeObjects[i]) continue;
		const count = objectFieldCount(obj.objects[i]);
		for (let f = 0; f < count; f += 1) tallyRef(tally, fieldValueAt(obj.objects[i], f));
	}
	for (let i = 0; i < arr.boxes.items.length; i += 1) {
		if (!freeBoxes[i]) tallyRef(tally, arr.boxes.items[i].value);
	}
	let leakedStrings = 0;
	let leakedArrays = 0;
	let leakedObjects = 0;
	let leakedBoxes = 0;
	for (const handle of heapStringHandles(arr)) {
		const held = tally.strings.get(handle);
		const holders = held != null ? held : 0;
		const counted = stringHandleRc(handle);
		if (counted < holders) return `internal: string ${handle} counts ${counted} holders but ${holders} hold it at ${where} end`;
		if (counted > holders) leakedStrings += 1;
	}
	for (const handle of seqHandles) {
		if (heapArrayIsView(arr, handle)) continue;
		const held = tally.seqs.get(handle);
		const holders = held != null ? held : 0;
		const counted = heapArrayRc(arr, handle);
		if (counted < holders) return `internal: array ${handle} counts ${counted} holders but ${holders} hold it at ${where} end`;
		if (counted > holders) leakedArrays += 1;
	}
	for (const handle of cellHandles) {
		const held = tally.seqs.get(handle);
		const holders = held != null ? held : 0;
		const counted = heapArrayRc(arr, handle);
		if (counted < holders) return `internal: object ${handle} counts ${counted} holders but ${holders} hold it at ${where} end`;
		if (counted > holders) leakedObjects += 1;
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
	const a = heapAllocArray(arr);
	heapArrayPush(arr, a, s);
	rcIncref(arr, obj, s);
	const b = heapAllocBox(arr, raiserArray(a));
	rcIncref(arr, obj, raiserArray(a));
	const boxed: RaiserValue = { kind: RaiserValueKind.Box, intVal: b, floatVal: 0.0 };
	const roots: RaiserValue[] = [s, raiserArray(a), boxed];
	assert ledgerAudit(arr, obj, roots, "program") == "";
}

test "the audit names a heap whose item outlives its roots" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const s = heapAllocString(arr, "leaked");
	const o = heapAllocObject(obj);
	assert ledgerAudit(arr, obj, [raiserObject(o)], "strand") == "internal: 1 string items live after strand end";
	rcDecref(arr, obj, s);
	assert ledgerAudit(arr, obj, [raiserObject(o)], "strand") == "";
	assert ledgerAudit(arr, obj, [], "strand") == "internal: 1 object items live after strand end";
}

test "the audit names an item held more often than it is counted" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const s = heapAllocString(arr, "twice");
	assert ledgerAudit(arr, obj, [s, s], "program").endsWith("counts 1 holders but 2 hold it at program end");
}

test "the audit counts the references an object cell holds and names a cell that outlives its roots" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const holder = createClassType("Holder", -1, [], ["item"], [RaiserRegClass.Ref]);
	const s = heapAllocString(arr, "kept");
	const cell = objectCellNew(arr.mem, holder, 1);
	objectCellSetSlot(cell, 0, s.intVal);
	const root = raiserObject(objectCellHandle(cell));
	assert ledgerAudit(arr, obj, [root], "program") == "", ledgerAudit(arr, obj, [root], "program");
	assert ledgerAudit(arr, obj, [], "program") == "internal: 1 object items live after program end";
	assert ledgerAudit(arr, obj, [root, root], "program").endsWith("counts 1 holders but 2 hold it at program end");
}

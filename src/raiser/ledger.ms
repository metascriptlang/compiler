// Raiser live-0 ledger. Under orc every holder of a heap item counts it, so once the
// roots are released an item whose count is higher than the references that remain
// would stay live. The audit finds those items without releasing anything: it counts
// the references the roots and the live items make and compares them with each count.

import {
	RaiserObjectData, RaiserValue, RaiserValueKind, RaiserHeapKind, handleIndex, handleHeapKind, raiserArray, raiserObject,
	RaiserArrayHeap, RaiserObjectHeap, createArrayHeap, createStructHeap, heapAllocString, heapStringText, heapAllocArray, heapAllocObject, heapAllocBox, heapBoxHandles, heapBoxValue, heapBoxRc,
	heapArrayPush, rcIncref, rcDecref, objectFieldCount, fieldNameAt, fieldValueAt, arrayHoldsHandles, arrayHeldCount, arrayHeldAt, stringBytesHandles, heapStringHandles, heapSeqHandles, heapObjectCellHandles, objectCellClass, objectCellFieldValue, objectCellRawSlot, stringHandleRc,
	heapArrayIsView, heapArrayRc, makeHandle, createClassType, objectCellHandle
} from "./value";
import { RaiserRegClass } from "./bytecode";
import { objectCellNew, objectCellSetSlot } from "./objectCell";

interface LedgerTally {
	strings: HashMap<int64, int32>;
	seqs: HashMap<int64, int32>;
	objects: int32[];
	boxes: HashMap<int64, int32>;
	holders: HashMap<int64, string[]>;
}

function zeros(count: int32): int32[] {
	const out: int32[] = [];
	for (let i = 0; i < count; i += 1) out.push(0);
	return out;
}

function tallyRef(tally: LedgerTally, v: RaiserValue, holder: string): void {
	if (v.kind < RaiserValueKind.String) return;
	const named = tally.holders.get(v.intVal);
	if (named != null) named.push(holder);
	else tally.holders.set(v.intVal, [holder]);
	const index = handleIndex(v.intVal);
	match (handleHeapKind(v.intVal)) {
		RaiserHeapKind.String => { const held = tally.strings.get(v.intVal); tally.strings.set(v.intVal, (held != null ? held : 0) + 1); },
		RaiserHeapKind.Seq => { const held = tally.seqs.get(v.intVal); tally.seqs.set(v.intVal, (held != null ? held : 0) + 1); },
		RaiserHeapKind.Object => { tally.objects[index] += 1; },
		RaiserHeapKind.Box => { const held = tally.boxes.get(v.intVal); tally.boxes.set(v.intVal, (held != null ? held : 0) + 1); },
		RaiserHeapKind.None | RaiserHeapKind.ConstString | RaiserHeapKind.Future => {},
		_ => { throw new Error(`internal: handle ${v.intVal} names no heap kind`); },
	}
}

function holderNames(tally: LedgerTally, handle: int64): string {
	const named = tally.holders.get(handle);
	return named != null ? named.join(", ") : "";
}

function objectFieldNames(data: RaiserObjectData): string {
	const names: string[] = [];
	for (let f = 0; f < objectFieldCount(data); f += 1) names.push(fieldNameAt(data, f));
	return names.join(",");
}

function freeFlags(count: int32, freeList: int64[]): boolean[] {
	const free: boolean[] = [];
	for (let i = 0; i < count; i += 1) free.push(false);
	for (const index of freeList) free[index] = true;
	return free;
}

// "" when every live item's count is the number of references the roots and the live items
// make to it; otherwise the message that names the first disagreement.
export function ledgerAudit(arr: RaiserArrayHeap, obj: RaiserObjectHeap, roots: RaiserValue[], where: string, rootNames: string[] = []): string {
	const tally: LedgerTally = {
		strings: new HashMap<int64, int32>(), seqs: new HashMap<int64, int32>(),
		objects: zeros(obj.objects.length), boxes: new HashMap<int64, int32>(), holders: new HashMap<int64, string[]>(),
	};
	const freeObjects = freeFlags(obj.objects.length, obj.freeList);
	const boxHandles = heapBoxHandles(arr);
	const stringBytes = stringBytesHandles(arr);
	for (let r = 0; r < roots.length; r += 1) {
		if (roots[r].kind == RaiserValueKind.Array && stringBytes.includes(roots[r].intVal)) continue;
		tallyRef(tally, roots[r], (r < rootNames.length ? rootNames[r] : `root ${r}`));
	}
	for (const bytes of stringBytes) tallyRef(tally, raiserArray(bytes), "string bytes");
	const seqHandles = heapSeqHandles(arr);
	for (const handle of seqHandles) {
		if (heapArrayIsView(arr, handle)) continue;
		if (arrayHoldsHandles(arr, handle)) {
			const held = arrayHeldCount(arr, handle);
			for (let k = 0; k < held; k += 1) tallyRef(tally, arrayHeldAt(arr, handle, k), `array ${handle}`);
		}
	}
	const cellHandles = heapObjectCellHandles(arr);
	for (const handle of cellHandles) {
		const kinds = objectCellClass(handle).kinds;
		for (let f = 0; f < kinds.length; f += 1) {
			if (kinds[f] == RaiserRegClass.Dyn) {
				const box = objectCellRawSlot(handle, f);
				if (box != 0) tallyRef(tally, { kind: RaiserValueKind.Box, intVal: box, floatVal: 0.0 }, `cell ${objectCellClass(handle).name}#${handle} field ${f}`);
			} else tallyRef(tally, objectCellFieldValue(arr, handle, f), `cell ${objectCellClass(handle).name}#${handle} field ${f}`);
		}
	}
	for (let i = 0; i < obj.objects.length; i += 1) {
		if (freeObjects[i]) continue;
		const count = objectFieldCount(obj.objects[i]);
		for (let f = 0; f < count; f += 1) tallyRef(tally, fieldValueAt(obj.objects[i], f), `object ${i} field ${f}`);
	}
	for (const handle of boxHandles) tallyRef(tally, heapBoxValue(arr, handle), `box ${handle}`);
	let leakedStrings = 0;
	let leakedArrays = 0;
	let leakedObjects = 0;
	let leakedBoxes = 0;
	let firstBox = "";
	let firstLeak = "";
	let firstString = "";
	for (const handle of heapStringHandles(arr)) {
		const held = tally.strings.get(handle);
		const holders = held != null ? held : 0;
		const counted = stringHandleRc(handle);
		if (counted < holders) return `internal: string ${handle} counts ${counted} holders but ${holders} hold it at ${where} end: ${holderNames(tally, handle)}`;
		if (counted > holders) {
			leakedStrings += 1;
			if (leakedStrings <= 4) firstString += `${firstString == "" ? "" : "; "}"${heapStringText(arr, { kind: RaiserValueKind.String, intVal: handle, floatVal: 0.0 }).slice(0, 40)}" counts ${counted} holders ${holders}`;
		}
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
		if (counted < holders) return `internal: object ${handle} (${objectCellClass(handle).name}) counts ${counted} holders but ${holders} hold it at ${where} end: ${holderNames(tally, handle)}`;
		if (counted > holders) {
			leakedObjects += 1;
			if (leakedObjects <= 4) firstLeak += `${firstLeak == "" ? "" : "; "}${objectCellClass(handle).name}[${objectCellClass(handle).fields.join(",")}]#${handle} counts ${counted} holders ${holders}`;
		}
	}
	for (let i = 0; i < tally.objects.length; i += 1) {
		if (freeObjects[i]) continue;
		if (obj.objects[i].rc < tally.objects[i]) return `internal: object ${i} counts ${obj.objects[i].rc} holders but ${tally.objects[i]} hold it at ${where} end`;
		if (obj.objects[i].rc > tally.objects[i]) {
			leakedObjects += 1;
			if (leakedObjects <= 4) firstLeak += `${firstLeak == "" ? "" : "; "}${obj.objects[i].classType.name}[${objectFieldNames(obj.objects[i])}]#${i} counts ${obj.objects[i].rc} holders ${tally.objects[i]} slots ${obj.objects[i].slots.length} values ${obj.objects[i].values.length} layout ${obj.objects[i].classType.kinds.length}`;
		}
	}
	for (const handle of boxHandles) {
		const held = tally.boxes.get(handle);
		const holders = held != null ? held : 0;
		const counted = heapBoxRc(handle);
		if (counted < holders) return `internal: box ${handle} counts ${counted} holders but ${holders} hold it at ${where} end`;
		if (counted > holders) {
			leakedBoxes += 1;
			if (firstBox == "") firstBox = `Box#${handle} counts ${counted} holders ${holders} holding kind ${heapBoxValue(arr, handle).kind}`;
		}
	}
	if (leakedStrings > 0) return `internal: ${leakedStrings} string items live after ${where} end (leaked: ${firstString})`;
	if (leakedArrays > 0) return `internal: ${leakedArrays} array items live after ${where} end`;
	if (leakedObjects > 0) return `internal: ${leakedObjects} object items live after ${where} end${firstLeak == "" ? "" : " (leaked: " + firstLeak + ")"}`;
	if (leakedBoxes > 0) return `internal: ${leakedBoxes} box items live after ${where} end (first: ${firstBox})`;
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
	assert ledgerAudit(arr, obj, [raiserObject(o)], "strand") == "internal: 1 string items live after strand end (leaked: \"leaked\" counts 1 holders 0)";
	rcDecref(arr, obj, s);
	assert ledgerAudit(arr, obj, [raiserObject(o)], "strand") == "";
	assert ledgerAudit(arr, obj, [], "strand").startsWith("internal: 1 object items live after strand end (leaked: [");
}

test "the audit names an item held more often than it is counted" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const s = heapAllocString(arr, "twice");
	assert ledgerAudit(arr, obj, [s, s], "program").includes("counts 1 holders but 2 hold it at program end");
}

test "the audit of one item held a hundred thousand times takes one pass over its holders" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const s = heapAllocString(arr, "shared");
	const a = heapAllocArray(arr);
	for (let i = 0; i < 100000; i += 1) {
		heapArrayPush(arr, a, s);
		rcIncref(arr, obj, s);
	}
	rcDecref(arr, obj, s);
	assert ledgerAudit(arr, obj, [raiserArray(a)], "program") == "";
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
	assert ledgerAudit(arr, obj, [], "program").startsWith("internal: 1 object items live after program end (leaked: Holder[");
	assert ledgerAudit(arr, obj, [root, root], "program").includes("counts 1 holders but 2 hold it at program end");
}

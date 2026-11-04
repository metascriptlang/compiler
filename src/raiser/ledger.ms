// Raiser live-0 ledger. Under orc every holder of a heap item counts it, so once the
// roots are released an item whose count is higher than the references that remain
// would stay live. The audit finds those items without releasing anything: it counts
// the references the roots and the live items make and compares them with each count.

import {
	RaiserObjectData, RaiserValue, RaiserValueKind, RaiserHeapKind, handleIndex, handleHeapKind, raiserArray, raiserObject,
	RaiserArrayHeap, RaiserObjectHeap, createArrayHeap, createStructHeap, heapAllocString, heapStringText, heapAllocArray, heapAllocObject, heapAllocBox, heapBoxHandles, heapBoxValue, heapBoxRc,
	heapArrayPush, rcIncref, rcDecref, objectFieldCount, fieldNameAt, fieldValueAt, arrayHoldsHandles, arrayHeldCount, arrayHeldAt, stringBytesHandles, heapStringHandles, heapSeqHandles, heapObjectCellHandles, objectCellClass, objectCellFieldValue, objectCellRawSlot, stringHandleRc,
	heapArrayIsView, heapArrayRc, makeHandle, createClassType, objectCellHandle, holdsCount, isObjectCell, seqCellOf, heapObjectSetField, raiserNil
} from "./value";
import { RaiserRegClass } from "./bytecode";
import { objectCellNew, objectCellSetSlot } from "./objectCell";
import { seqBase } from "./vmSeq";

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
	if (!holdsCount(v.kind)) return;
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

function cellFieldRef(arr: RaiserArrayHeap, handle: int64, f: int32): RaiserValue {
	if (objectCellClass(handle).kinds[f] != RaiserRegClass.Dyn) return objectCellFieldValue(arr, handle, f);
	const box = objectCellRawSlot(handle, f);
	return box != 0 ? { kind: RaiserValueKind.Box, intVal: box, floatVal: 0.0 } : raiserNil();
}

function itemRefs(arr: RaiserArrayHeap, obj: RaiserObjectHeap, handle: int64, out: RaiserValue[]): void {
	match (handleHeapKind(handle)) {
		RaiserHeapKind.Seq => {
			if (isObjectCell(handle)) {
				for (let f = 0; f < objectCellClass(handle).kinds.length; f += 1) out.push(cellFieldRef(arr, handle, f));
			} else if (heapArrayIsView(arr, handle)) {
				out.push(raiserArray(seqBase(seqCellOf(handle))));
			} else if (arrayHoldsHandles(arr, handle)) {
				const held = arrayHeldCount(arr, handle);
				for (let k = 0; k < held; k += 1) out.push(arrayHeldAt(arr, handle, k));
			}
		},
		RaiserHeapKind.Object => {
			const data = obj.objects[handleIndex(handle)];
			for (let f = 0; f < objectFieldCount(data); f += 1) out.push(fieldValueAt(data, f));
		},
		RaiserHeapKind.Box => { out.push(heapBoxValue(arr, handle)); },
		_ => {},
	}
}

// The live items that the roots, and the items no holder counts, do not reach: each is held only by
// other such items, so a garbage cycle balances its counts and only this walk finds it.
function unreachedItems(arr: RaiserArrayHeap, obj: RaiserObjectHeap, roots: RaiserValue[], stringBytes: int64[], live: int64[], counts: int64[]): int64[] {
	const reached = new HashMap<int64, boolean>();
	const work: RaiserValue[] = [];
	for (const root of roots) work.push(root);
	for (const bytes of stringBytes) work.push(raiserArray(bytes));
	for (let i = 0; i < live.length; i += 1) if (counts[i] == 0) work.push({ kind: RaiserValueKind.Array, intVal: live[i], floatVal: 0.0 });
	while (work.length > 0) {
		const v = work.pop();
		if (!holdsCount(v.kind) || reached.has(v.intVal)) continue;
		reached.set(v.intVal, true);
		itemRefs(arr, obj, v.intVal, work);
	}
	const out: int64[] = [];
	for (const handle of live) if (!reached.has(handle)) out.push(handle);
	return out;
}

function itemName(arr: RaiserArrayHeap, obj: RaiserObjectHeap, handle: int64): string {
	return match (handleHeapKind(handle)) {
		RaiserHeapKind.Seq => isObjectCell(handle) ? `${objectCellClass(handle).name}#${handle}` : `array#${handle}`,
		RaiserHeapKind.Object => `${obj.objects[handleIndex(handle)].classType.name}#${handleIndex(handle)}`,
		RaiserHeapKind.Box => `Box#${handle}`,
		RaiserHeapKind.String => `"${heapStringText(arr, { kind: RaiserValueKind.String, intVal: handle, floatVal: 0.0 }).slice(0, 40)}"`,
		_ => `item#${handle}`,
	};
}

function freeFlags(count: int32, freeList: int64[]): boolean[] {
	const free: boolean[] = [];
	for (let i = 0; i < count; i += 1) free.push(false);
	for (const index of freeList) free[index] = true;
	return free;
}

let audits: int64 = 0;

export function ledgerAudits(): int64 {
	return audits;
}

// "" when every live item's count is the number of references the roots and the live items
// make to it; otherwise the message that names the first disagreement.
export function ledgerAudit(arr: RaiserArrayHeap, obj: RaiserObjectHeap, roots: RaiserValue[], where: string, rootNames: string[] = []): string {
	audits += 1;
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
		for (let f = 0; f < kinds.length; f += 1) tallyRef(tally, cellFieldRef(arr, handle, f), `cell ${objectCellClass(handle).name}#${handle} field ${f}`);
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
	const live: int64[] = [];
	const counts: int64[] = [];
	for (const handle of cellHandles) { live.push(handle); counts.push(heapArrayRc(arr, handle) as int64); }
	for (let i = 0; i < obj.objects.length; i += 1) {
		if (!freeObjects[i]) { live.push(makeHandle(i as int64, RaiserHeapKind.Object)); counts.push(obj.objects[i].rc as int64); }
	}
	for (const handle of seqHandles) {
		if (!heapArrayIsView(arr, handle)) { live.push(handle); counts.push(heapArrayRc(arr, handle) as int64); }
	}
	for (const handle of boxHandles) { live.push(handle); counts.push(heapBoxRc(handle) as int64); }
	for (const handle of heapStringHandles(arr)) { live.push(handle); counts.push(stringHandleRc(handle)); }
	const unreached = unreachedItems(arr, obj, roots, stringBytes, live, counts);
	if (unreached.length > 0) {
		const named: string[] = [];
		for (let i = 0; i < unreached.length && i < 4; i += 1) named.push(itemName(arr, obj, unreached[i]));
		return `internal: ${unreached.length} items live after ${where} end held only by a cycle no root reaches (leaked: ${named.join("; ")})`;
	}
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

test "the audit names a garbage ring of objects whose counts balance and accepts the same ring held by a root" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const a = heapAllocObject(obj);
	const b = heapAllocObject(obj);
	rcIncref(arr, obj, raiserObject(b));
	heapObjectSetField(arr, obj, a, "next", raiserObject(b));
	rcIncref(arr, obj, raiserObject(a));
	heapObjectSetField(arr, obj, b, "next", raiserObject(a));
	rcDecref(arr, obj, raiserObject(a));
	rcDecref(arr, obj, raiserObject(b));
	const verdict = ledgerAudit(arr, obj, [], "program");
	assert verdict.startsWith("internal: 2 items live after program end held only by a cycle no root reaches (leaked: "), verdict;
	rcIncref(arr, obj, raiserObject(a));
	assert ledgerAudit(arr, obj, [raiserObject(a)], "program") == "";
}

test "the audit names a garbage ring of object cells and the string it alone holds" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const ring = createClassType("Ring", -1, [], ["next", "name"], [RaiserRegClass.Ref, RaiserRegClass.Ref]);
	const a = objectCellNew(arr.mem, ring, 1);
	const b = objectCellNew(arr.mem, ring, 1);
	objectCellSetSlot(a, 0, objectCellHandle(b));
	objectCellSetSlot(b, 0, objectCellHandle(a));
	objectCellSetSlot(a, 1, heapAllocString(arr, "tail").intVal);
	const verdict = ledgerAudit(arr, obj, [], "strand");
	assert verdict.startsWith("internal: 3 items live after strand end held only by a cycle no root reaches (leaked: Ring#"), verdict;
	assert verdict.includes("\"tail\""), verdict;
}

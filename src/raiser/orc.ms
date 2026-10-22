// Raiser ORC — cycle collector (Bacon synchronous trial deletion).
//
// ARC (rcIncref/rcDecref in value.ms) reclaims everything except reference
// cycles, whose rc never reaches 0. This collector finds garbage cycles via
// trial deletion: tentatively remove every heap-internal edge; objects left
// with rc>0 still have an external (register) reference and are kept; objects
// left at rc==0 are pure garbage cycles and are reclaimed.
//
// v1: full-heap scan (every live object is a candidate root). The buffered-root
// optimisation (only scan objects decref'd to a nonzero rc) is a later refinement.
// Generic trace — VM objects are self-describing (fields/items), so no per-type
// trace hooks are needed.

import {
	RaiserValue, RaiserValueKind, RaiserHeapKind, makeHandle, handleIndex, raiserArray, raiserObject,
	RaiserArrayHeap, RaiserObjectHeap, rcDecref,
	createArrayHeap, createStructHeap, heapAllocArray, heapAllocObject,
	heapObjectSetField, heapArrayPush, rcIncref, heldHandle, objectFieldCount, fieldValueAt
} from "./value";

const COL_BLACK = 0;   // in use / alive (alloc default)
const COL_GRAY = 1;    // under examination
const COL_WHITE = 2;   // condemned (garbage)

function isRef(held: RaiserValue): boolean {
	const v = heldHandle(held);
	return v.kind == RaiserValueKind.Array || v.kind == RaiserValueKind.Object;
}

function colorOf(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, held: RaiserValue): int32 {
	const v = heldHandle(held);
	if (v.kind == RaiserValueKind.Array) return arrHeap.arrays[handleIndex(v.intVal)].color;
	return objHeap.objects[handleIndex(v.intVal)].color;
}

function setColorOf(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, held: RaiserValue, col: int32): void {
	const v = heldHandle(held);
	if (v.kind == RaiserValueKind.Array) { arrHeap.arrays[handleIndex(v.intVal)].color = col; }
	else { objHeap.objects[handleIndex(v.intVal)].color = col; }
}

function rcOf(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, held: RaiserValue): int32 {
	const v = heldHandle(held);
	if (v.kind == RaiserValueKind.Array) return arrHeap.arrays[handleIndex(v.intVal)].rc;
	return objHeap.objects[handleIndex(v.intVal)].rc;
}

function decRcRaw(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, held: RaiserValue): void {
	const v = heldHandle(held);
	if (v.kind == RaiserValueKind.Array) { arrHeap.arrays[handleIndex(v.intVal)].rc = arrHeap.arrays[handleIndex(v.intVal)].rc - 1; }
	else { objHeap.objects[handleIndex(v.intVal)].rc = objHeap.objects[handleIndex(v.intVal)].rc - 1; }
}

function incRcRaw(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, held: RaiserValue): void {
	const v = heldHandle(held);
	if (v.kind == RaiserValueKind.Array) { arrHeap.arrays[handleIndex(v.intVal)].rc = arrHeap.arrays[handleIndex(v.intVal)].rc + 1; }
	else { objHeap.objects[handleIndex(v.intVal)].rc = objHeap.objects[handleIndex(v.intVal)].rc + 1; }
}

// Each phase walks the heap with its own work list rather than native recursion, so a chain as long as the heap
// itself costs list space, not stack frames.

function pushChildren(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, v: RaiserValue, work: RaiserValue[]): void {
	if (v.kind == RaiserValueKind.Array) {
		for (const child of arrHeap.arrays[handleIndex(v.intVal)].items) {
			if (isRef(child)) work.push(heldHandle(child));
		}
	} else {
		const obj = objHeap.objects[handleIndex(v.intVal)];
		const count = objectFieldCount(obj);
		for (let i = 0; i < count; i += 1) {
			const child = fieldValueAt(obj, i);
			if (isRef(child)) work.push(heldHandle(child));
		}
	}
}

// --- Phase 1: mark gray + trial-delete internal edges ---

function markGray(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, held: RaiserValue): void {
	const v = heldHandle(held);
	if (colorOf(arrHeap, objHeap, v) == COL_GRAY) return;
	setColorOf(arrHeap, objHeap, v, COL_GRAY);
	const work: RaiserValue[] = [];
	pushChildren(arrHeap, objHeap, v, work);
	while (work.length > 0) {
		const t = work.pop()!;
		decRcRaw(arrHeap, objHeap, t);
		if (colorOf(arrHeap, objHeap, t) != COL_GRAY) {
			setColorOf(arrHeap, objHeap, t, COL_GRAY);
			pushChildren(arrHeap, objHeap, t, work);
		}
	}
}

// --- Phase 2: scan — restore alive (rc>0) to black, condemn (rc==0) to white ---

function scanBlack(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, held: RaiserValue): void {
	const v = heldHandle(held);
	setColorOf(arrHeap, objHeap, v, COL_BLACK);
	const work: RaiserValue[] = [];
	pushChildren(arrHeap, objHeap, v, work);
	while (work.length > 0) {
		const t = work.pop()!;
		incRcRaw(arrHeap, objHeap, t);
		if (colorOf(arrHeap, objHeap, t) != COL_BLACK) {
			setColorOf(arrHeap, objHeap, t, COL_BLACK);
			pushChildren(arrHeap, objHeap, t, work);
		}
	}
}

function scan(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, held: RaiserValue): void {
	const work: RaiserValue[] = [heldHandle(held)];
	while (work.length > 0) {
		const t = work.pop()!;
		if (colorOf(arrHeap, objHeap, t) != COL_GRAY) continue;
		if (rcOf(arrHeap, objHeap, t) > 0) {
			scanBlack(arrHeap, objHeap, t);
		} else {
			setColorOf(arrHeap, objHeap, t, COL_WHITE);
			pushChildren(arrHeap, objHeap, t, work);
		}
	}
}

function releaseWhiteChild(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, child: RaiserValue, work: RaiserValue[]): void {
	if (isRef(child)) {
		if (colorOf(arrHeap, objHeap, child) == COL_WHITE) work.push(heldHandle(child));
		else if (colorOf(arrHeap, objHeap, child) != COL_GRAY) rcDecref(arrHeap, objHeap, child);
	} else if (child.kind == RaiserValueKind.String) rcDecref(arrHeap, objHeap, child);
}

// --- Phase 3: collect white — recycle the garbage cycle, release external refs ---
// White → mark GRAY (in-collect-set) to disambiguate from external BLACK refs.

function collectWhite(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, held: RaiserValue): int32 {
	const toFree: RaiserValue[] = [];
	const work: RaiserValue[] = [heldHandle(held)];
	while (work.length > 0) {
		const v = work.pop()!;
		if (colorOf(arrHeap, objHeap, v) != COL_WHITE) continue;
		setColorOf(arrHeap, objHeap, v, COL_GRAY);
		toFree.push(v);
		if (v.kind == RaiserValueKind.Array) {
			for (const child of arrHeap.arrays[handleIndex(v.intVal)].items) releaseWhiteChild(arrHeap, objHeap, child, work);
		} else {
			const obj = objHeap.objects[handleIndex(v.intVal)];
			const count = objectFieldCount(obj);
			for (let i = 0; i < count; i += 1) releaseWhiteChild(arrHeap, objHeap, fieldValueAt(obj, i), work);
		}
	}
	for (const v of toFree) {
		if (v.kind == RaiserValueKind.Array) {
			const data = arrHeap.arrays[handleIndex(v.intVal)];
			data.items.length = 0;
			data.rc = 0;
			data.color = COL_BLACK;
			arrHeap.freeList.push(handleIndex(v.intVal));
		} else {
			const data = objHeap.objects[handleIndex(v.intVal)];
			data.slots.length = 0;
			data.wordSlots = 0;
			data.refSlots = 0;
			data.values.length = 0;
			data.added.length = 0;
			data.rc = 0;
			data.color = COL_BLACK;
			objHeap.freeList.push(handleIndex(v.intVal));
		}
	}
	return toFree.length as int32;
}

// --- Driver: full-heap trial-deletion collect. Returns count of freed objects. ---

function arrayAt(h: int32): RaiserValue {
	return raiserArray(makeHandle(h, RaiserHeapKind.Array));
}

function objectAt(h: int32): RaiserValue {
	return raiserObject(makeHandle(h, RaiserHeapKind.Object));
}

export function orcCollectCycles(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap): int32 {
	for (let h = 0; h < arrHeap.arrays.length; h = h + 1) {
		if (arrHeap.arrays[h].rc > 0) markGray(arrHeap, objHeap, arrayAt(h));
	}
	for (let h = 0; h < objHeap.objects.length; h = h + 1) {
		if (objHeap.objects[h].rc > 0) markGray(arrHeap, objHeap, objectAt(h));
	}
	for (let h = 0; h < arrHeap.arrays.length; h = h + 1) {
		if (colorOf(arrHeap, objHeap, arrayAt(h)) == COL_GRAY) scan(arrHeap, objHeap, arrayAt(h));
	}
	for (let h = 0; h < objHeap.objects.length; h = h + 1) {
		if (colorOf(arrHeap, objHeap, objectAt(h)) == COL_GRAY) scan(arrHeap, objHeap, objectAt(h));
	}
	let freed = 0;
	for (let h = 0; h < arrHeap.arrays.length; h = h + 1) {
		if (colorOf(arrHeap, objHeap, arrayAt(h)) == COL_WHITE) freed = (freed + collectWhite(arrHeap, objHeap, arrayAt(h))) as int32;
	}
	for (let h = 0; h < objHeap.objects.length; h = h + 1) {
		if (colorOf(arrHeap, objHeap, objectAt(h)) == COL_WHITE) freed = (freed + collectWhite(arrHeap, objHeap, objectAt(h))) as int32;
	}
	return freed;
}

// --- Tests ---

test "orc collects a pure object cycle" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const a = heapAllocObject(obj);
	const b = heapAllocObject(obj);
	const aVal = raiserObject(a);
	const bVal = raiserObject(b);
	rcIncref(arr, obj, bVal);
	heapObjectSetField(obj, a, "next", bVal);
	rcIncref(arr, obj, aVal);
	heapObjectSetField(obj, b, "next", aVal);
	assert obj.objects[handleIndex(a)].rc == 1;
	assert obj.objects[handleIndex(b)].rc == 1;
	const freed = orcCollectCycles(arr, obj);
	assert freed == 2;
	assert obj.freeList.length == 2;
}

test "orc keeps externally-referenced cycle" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const a = heapAllocObject(obj);
	const b = heapAllocObject(obj);
	const aVal = raiserObject(a);
	const bVal = raiserObject(b);
	rcIncref(arr, obj, bVal);
	heapObjectSetField(obj, a, "next", bVal);
	rcIncref(arr, obj, aVal);
	heapObjectSetField(obj, b, "next", aVal);
	rcIncref(arr, obj, aVal);          // external (register) reference to a
	const freed = orcCollectCycles(arr, obj);
	assert freed == 0;                // reachable → kept
	assert obj.objects[handleIndex(a)].rc == 2;    // rc restored
	assert obj.objects[handleIndex(b)].rc == 1;
}

test "orc collects array cycle, leaves acyclic" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const live = heapAllocArray(arr);   // acyclic, externally referenced
	rcIncref(arr, obj, raiserArray(live));
	const a = heapAllocArray(arr);
	const b = heapAllocArray(arr);
	rcIncref(arr, obj, raiserArray(b));
	heapArrayPush(arr, a, raiserArray(b));
	rcIncref(arr, obj, raiserArray(a));
	heapArrayPush(arr, b, raiserArray(a));
	const freed = orcCollectCycles(arr, obj);
	assert freed == 2;
	assert arr.arrays[handleIndex(live)].rc == 1;   // untouched
}

test "orc walks a chain as long as the heap without native recursion, kept and collected" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const count = 300000;
	const first = heapAllocObject(obj);
	let prev = first;
	for (let i = 1; i < count; i += 1) {
		const next = heapAllocObject(obj);
		rcIncref(arr, obj, raiserObject(next));
		heapObjectSetField(obj, prev, "next", raiserObject(next));
		prev = next;
	}
	rcIncref(arr, obj, raiserObject(first));
	heapObjectSetField(obj, prev, "next", raiserObject(first));
	rcIncref(arr, obj, raiserObject(first));
	assert orcCollectCycles(arr, obj) == 0;
	assert obj.objects[handleIndex(first)].rc == 2 && obj.objects[handleIndex(prev)].rc == 1;
	rcDecref(arr, obj, raiserObject(first));
	assert orcCollectCycles(arr, obj) == count;
	assert obj.freeList.length == count;
}

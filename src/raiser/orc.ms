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
	RaiserValue, RaiserValueKind, raiserArray, raiserObject,
	RaiserArrayHeap, RaiserObjectHeap, rcDecref,
	createArrayHeap, createStructHeap, heapAllocArray, heapAllocObject,
	heapObjectSetField, heapArrayPush, rcIncref
} from "./value";

const COL_BLACK = 0;   // in use / alive (alloc default)
const COL_GRAY = 1;    // under examination
const COL_WHITE = 2;   // condemned (garbage)

function isRef(v: RaiserValue): boolean {
	return v.kind === RaiserValueKind.Array || v.kind === RaiserValueKind.Object;
}

function colorOf(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, v: RaiserValue): int32 {
	if (v.kind === RaiserValueKind.Array) return arrHeap.arrays[v.intVal].color;
	return objHeap.objects[v.intVal].color;
}

function setColorOf(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, v: RaiserValue, col: int32): void {
	if (v.kind === RaiserValueKind.Array) { arrHeap.arrays[v.intVal].color = col; }
	else { objHeap.objects[v.intVal].color = col; }
}

function rcOf(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, v: RaiserValue): int32 {
	if (v.kind === RaiserValueKind.Array) return arrHeap.arrays[v.intVal].rc;
	return objHeap.objects[v.intVal].rc;
}

function decRcRaw(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, v: RaiserValue): void {
	if (v.kind === RaiserValueKind.Array) { arrHeap.arrays[v.intVal].rc = arrHeap.arrays[v.intVal].rc - 1; }
	else { objHeap.objects[v.intVal].rc = objHeap.objects[v.intVal].rc - 1; }
}

function incRcRaw(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, v: RaiserValue): void {
	if (v.kind === RaiserValueKind.Array) { arrHeap.arrays[v.intVal].rc = arrHeap.arrays[v.intVal].rc + 1; }
	else { objHeap.objects[v.intVal].rc = objHeap.objects[v.intVal].rc + 1; }
}

// --- Phase 1: mark gray + trial-delete internal edges ---

function markGray(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, v: RaiserValue): void {
	if (colorOf(arrHeap, objHeap, v) === COL_GRAY) return;
	setColorOf(arrHeap, objHeap, v, COL_GRAY);
	if (v.kind === RaiserValueKind.Array) {
		const items = arrHeap.arrays[v.intVal].items;
		for (const child of items) {
			if (isRef(child)) { decRcRaw(arrHeap, objHeap, child); markGray(arrHeap, objHeap, child); }
		}
	} else {
		const fields = objHeap.objects[v.intVal].fields;
		for (const f of fields) {
			if (isRef(f.value)) { decRcRaw(arrHeap, objHeap, f.value); markGray(arrHeap, objHeap, f.value); }
		}
	}
}

// --- Phase 2: scan — restore alive (rc>0) to black, condemn (rc==0) to white ---

function scanBlack(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, v: RaiserValue): void {
	setColorOf(arrHeap, objHeap, v, COL_BLACK);
	if (v.kind === RaiserValueKind.Array) {
		const items = arrHeap.arrays[v.intVal].items;
		for (const child of items) {
			if (isRef(child)) {
				incRcRaw(arrHeap, objHeap, child);
				if (colorOf(arrHeap, objHeap, child) !== COL_BLACK) scanBlack(arrHeap, objHeap, child);
			}
		}
	} else {
		const fields = objHeap.objects[v.intVal].fields;
		for (const f of fields) {
			if (isRef(f.value)) {
				incRcRaw(arrHeap, objHeap, f.value);
				if (colorOf(arrHeap, objHeap, f.value) !== COL_BLACK) scanBlack(arrHeap, objHeap, f.value);
			}
		}
	}
}

function scan(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, v: RaiserValue): void {
	if (colorOf(arrHeap, objHeap, v) !== COL_GRAY) return;
	if (rcOf(arrHeap, objHeap, v) > 0) {
		scanBlack(arrHeap, objHeap, v);
		return;
	}
	setColorOf(arrHeap, objHeap, v, COL_WHITE);
	if (v.kind === RaiserValueKind.Array) {
		for (const child of arrHeap.arrays[v.intVal].items) {
			if (isRef(child)) scan(arrHeap, objHeap, child);
		}
	} else {
		for (const f of objHeap.objects[v.intVal].fields) {
			if (isRef(f.value)) scan(arrHeap, objHeap, f.value);
		}
	}
}

// --- Phase 3: collect white — recycle the garbage cycle, release external refs ---
// White → mark GRAY (in-collect-set) to disambiguate from external BLACK refs.

function collectWhite(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, v: RaiserValue): int32 {
	if (colorOf(arrHeap, objHeap, v) !== COL_WHITE) return 0;
	setColorOf(arrHeap, objHeap, v, COL_GRAY);
	let freed = 1;
	if (v.kind === RaiserValueKind.Array) {
		const data = arrHeap.arrays[v.intVal];
		for (const child of data.items) {
			if (isRef(child)) {
				if (colorOf(arrHeap, objHeap, child) === COL_WHITE) freed = (freed + collectWhite(arrHeap, objHeap, child)) as int32;
				else if (colorOf(arrHeap, objHeap, child) !== COL_GRAY) rcDecref(arrHeap, objHeap, child);
			}
		}
		data.items.length = 0;
		data.rc = 0;
		data.color = COL_BLACK;
		arrHeap.freeList.push(v.intVal);
	} else {
		const data = objHeap.objects[v.intVal];
		for (const f of data.fields) {
			if (isRef(f.value)) {
				if (colorOf(arrHeap, objHeap, f.value) === COL_WHITE) freed = (freed + collectWhite(arrHeap, objHeap, f.value)) as int32;
				else if (colorOf(arrHeap, objHeap, f.value) !== COL_GRAY) rcDecref(arrHeap, objHeap, f.value);
			}
		}
		data.fields.length = 0;
		data.rc = 0;
		data.color = COL_BLACK;
		objHeap.freeList.push(v.intVal);
	}
	return freed;
}

// --- Driver: full-heap trial-deletion collect. Returns count of freed objects. ---

export function orcCollectCycles(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap): int32 {
	for (let h = 0; h < arrHeap.arrays.length; h = h + 1) {
		if (arrHeap.arrays[h].rc > 0) markGray(arrHeap, objHeap, raiserArray(h));
	}
	for (let h = 0; h < objHeap.objects.length; h = h + 1) {
		if (objHeap.objects[h].rc > 0) markGray(arrHeap, objHeap, raiserObject(h));
	}
	for (let h = 0; h < arrHeap.arrays.length; h = h + 1) {
		if (colorOf(arrHeap, objHeap, raiserArray(h)) === COL_GRAY) scan(arrHeap, objHeap, raiserArray(h));
	}
	for (let h = 0; h < objHeap.objects.length; h = h + 1) {
		if (colorOf(arrHeap, objHeap, raiserObject(h)) === COL_GRAY) scan(arrHeap, objHeap, raiserObject(h));
	}
	let freed = 0;
	for (let h = 0; h < arrHeap.arrays.length; h = h + 1) {
		if (colorOf(arrHeap, objHeap, raiserArray(h)) === COL_WHITE) freed = (freed + collectWhite(arrHeap, objHeap, raiserArray(h))) as int32;
	}
	for (let h = 0; h < objHeap.objects.length; h = h + 1) {
		if (colorOf(arrHeap, objHeap, raiserObject(h)) === COL_WHITE) freed = (freed + collectWhite(arrHeap, objHeap, raiserObject(h))) as int32;
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
	assert obj.objects[a].rc === 1;
	assert obj.objects[b].rc === 1;
	const freed = orcCollectCycles(arr, obj);
	assert freed === 2;
	assert obj.freeList.length === 2;
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
	assert freed === 0;                // reachable → kept
	assert obj.objects[a].rc === 2;    // rc restored
	assert obj.objects[b].rc === 1;
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
	assert freed === 2;
	assert arr.arrays[live].rc === 1;   // untouched
}

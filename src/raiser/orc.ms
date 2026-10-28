// Raiser ORC — cycle collector (Bacon synchronous trial deletion).
//
// ARC (rcIncref/rcDecref in value.ms) reclaims everything except reference
// cycles, whose rc never reaches 0. This collector finds garbage cycles via
// trial deletion: tentatively remove every heap-internal edge; objects left
// with rc>0 still have an external (register) reference and are kept; objects
// left at rc==0 are pure garbage cycles and are reclaimed.

import {
	RaiserValue, RaiserValueKind, RaiserHeapKind, handleIndex, raiserArray, raiserObject,
	RaiserArrayHeap, RaiserObjectHeap, rcDecref,
	createArrayHeap, createStructHeap, heapSeqHandles, heapAllocArray, heapAllocObject,
	heapObjectSetField, heapArrayPush, rcIncref, objectFieldCount, fieldValueAt, arrayHoldsHandles, arrayHeldCount, arrayHeldAt,
	handleHeapKind, raiserNil, rcDecrefHandle, rcForgetRoot, ORC_COLOR_MASK, ORC_ROOT_SHIFT, heapAllocArrayOf, ORC_DEFAULT_THRESHOLD, RaiserClassType, createClassType, layOutObject,
	isSeqHandle, isObjectCell, objectCellHandle, objectCellClass, objectCellFieldValue, objectCellStoreField, seqCellOf, heapArrayRc, heapArraySetRc, heapArrayCyclic, arrayHeldStore, heapArraySetFlags, handleValue
} from "./value";
import { cellRootIdx, setCellRootIdx, liveCellBlocks } from "./memory";
import { objectCellNew, objectCellSlot, objectCellSetSlot } from "./objectCell";
import { RaiserRegClass } from "./bytecode";

const COL_BLACK = 0;   // in use / alive (alloc default)
const COL_GRAY = 1;    // under examination
const COL_WHITE = 2;   // condemned (garbage)

export type OrcDestroy = (handle: int64) => void;

const COLOR_MASK = ORC_COLOR_MASK;
const ROOT_SHIFT = ORC_ROOT_SHIFT;
const MIN_THRESHOLD = 16;
const NEVER_COLLECT = 2147483647;

function colorField(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, h: int64): int32 {
	const kind = handleHeapKind(h);
	if (kind == RaiserHeapKind.Seq) return cellRootIdx(seqCellOf(h)) as int32;
	if (kind == RaiserHeapKind.Object) return objHeap.objects[handleIndex(h)].color;
	throw new Error(`internal: handle ${h} is no collectable cell`);
}

function setColorField(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, h: int64, field: int32): void {
	const kind = handleHeapKind(h);
	if (kind == RaiserHeapKind.Seq) { setCellRootIdx(seqCellOf(h), field as int64); }
	else { objHeap.objects[handleIndex(h)].color = field; }
}

function colorAt(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, h: int64): int32 {
	return colorField(arrHeap, objHeap, h) & COLOR_MASK;
}

function setColorAt(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, h: int64, col: int32): void {
	setColorField(arrHeap, objHeap, h, (colorField(arrHeap, objHeap, h) & ~COLOR_MASK) | col);
}

function registered(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, h: int64): boolean {
	return (colorField(arrHeap, objHeap, h) >> ROOT_SHIFT) != 0;
}

function countAt(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, h: int64): int32 {
	const kind = handleHeapKind(h);
	if (kind == RaiserHeapKind.Seq) return heapArrayRc(arrHeap, h);
	return objHeap.objects[handleIndex(h)].rc;
}

function addCount(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, h: int64, delta: int32): void {
	const kind = handleHeapKind(h);
	if (kind == RaiserHeapKind.Seq) { heapArraySetRc(arrHeap, h, heapArrayRc(arrHeap, h) + delta); }
	else { objHeap.objects[handleIndex(h)].rc += delta; }
}

function setCount(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, h: int64, count: int32): void {
	const kind = handleHeapKind(h);
	if (kind == RaiserHeapKind.Seq) { heapArraySetRc(arrHeap, h, count); }
	else { objHeap.objects[handleIndex(h)].rc = count; }
}

interface OrcEnv {
	owners: int64[];
	indices: int32[];
	children: int64[];
	toFree: int64[];
	touched: number;
	edges: number;
	rcSum: number;
	keepThreshold: boolean;
}

function collectableHandle(held: RaiserValue): int64 {
	return held.kind == RaiserValueKind.Array || held.kind == RaiserValueKind.Object ? held.intVal : 0;
}

function pushSlot(env: OrcEnv, owner: int64, index: int32, held: RaiserValue): void {
	const child = collectableHandle(held);
	if (child == 0) return;
	env.owners.push(owner);
	env.indices.push(index);
	env.children.push(child);
}

function traceCell(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, env: OrcEnv, h: int64): void {
	const kind = handleHeapKind(h);
	if (isObjectCell(h)) {
		const t = objectCellClass(h);
		for (let i = 0; i < t.cyclic.length; i += 1) {
			if (!t.cyclic[i]) continue;
			pushSlot(env, h, i as int32, t.kinds[i] == RaiserRegClass.Dyn ? objectCellFieldValue(arrHeap, h, i) : handleValue(objectCellSlot(seqCellOf(h), i)));
		}
	} else if (kind == RaiserHeapKind.Seq) {
		if (!heapArrayCyclic(arrHeap, h) || !arrayHoldsHandles(arrHeap, h)) return;
		const count = arrayHeldCount(arrHeap, h);
		for (let i = 0; i < count; i += 1) pushSlot(env, h, i as int32, arrayHeldAt(arrHeap, h, i));
	} else {
		const obj = objHeap.objects[handleIndex(h)];
		const cyclic = obj.classType.cyclic;
		for (let i = 0; i < obj.slots.length; i += 1) {
			if (cyclic[i]) pushSlot(env, h, i as int32, fieldValueAt(obj, i));
		}
	}
}

function clearSlot(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, owner: int64, index: int32): void {
	if (isObjectCell(owner)) {
		if (objectCellClass(owner).kinds[index] == RaiserRegClass.Dyn) objectCellStoreField(arrHeap, owner, index, raiserNil());
		else objectCellSetSlot(seqCellOf(owner), index, 0);
		return;
	}
	if (isSeqHandle(owner)) {
		arrayHeldStore(arrHeap, owner, index, raiserNil());
		return;
	}
	const obj = objHeap.objects[handleIndex(owner)];
	const kind = obj.classType.kinds[index];
	if (kind == RaiserRegClass.Ref) { obj.slots[index] = 0; }
	else if (kind == RaiserRegClass.Dyn) { obj.values[obj.slots[index]] = raiserNil(); }
	else throw new Error("internal: a collector slot names a field that holds no handle");
}

function popSlot(env: OrcEnv): void {
	env.owners.length = env.owners.length - 1;
	env.indices.length = env.indices.length - 1;
	env.children.length = env.children.length - 1;
}

function markGrayCell(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, env: OrcEnv, h: int64): void {
	if (colorAt(arrHeap, objHeap, h) == COL_GRAY) return;
	setColorAt(arrHeap, objHeap, h, COL_GRAY);
	env.touched += 1;
	env.rcSum += countAt(arrHeap, objHeap, h);
	traceCell(arrHeap, objHeap, env, h);
	while (env.children.length > 0) {
		const child = env.children[env.children.length - 1];
		popSlot(env);
		addCount(arrHeap, objHeap, child, -1);
		env.edges += 1;
		if (colorAt(arrHeap, objHeap, child) != COL_GRAY) {
			setColorAt(arrHeap, objHeap, child, COL_GRAY);
			env.touched += 1;
			env.rcSum += countAt(arrHeap, objHeap, child) + 1;
			traceCell(arrHeap, objHeap, env, child);
		}
	}
}

function scanBlackCell(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, env: OrcEnv, h: int64): void {
	setColorAt(arrHeap, objHeap, h, COL_BLACK);
	const until = env.children.length;
	traceCell(arrHeap, objHeap, env, h);
	while (env.children.length > until) {
		const child = env.children[env.children.length - 1];
		popSlot(env);
		addCount(arrHeap, objHeap, child, 1);
		if (colorAt(arrHeap, objHeap, child) != COL_BLACK) {
			setColorAt(arrHeap, objHeap, child, COL_BLACK);
			traceCell(arrHeap, objHeap, env, child);
		}
	}
}

function scanCell(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, env: OrcEnv, h: int64): void {
	if (colorAt(arrHeap, objHeap, h) != COL_GRAY) return;
	if (countAt(arrHeap, objHeap, h) > 0) { scanBlackCell(arrHeap, objHeap, env, h); return; }
	setColorAt(arrHeap, objHeap, h, COL_WHITE);
	traceCell(arrHeap, objHeap, env, h);
	while (env.children.length > 0) {
		const child = env.children[env.children.length - 1];
		popSlot(env);
		if (colorAt(arrHeap, objHeap, child) != COL_GRAY) continue;
		if (countAt(arrHeap, objHeap, child) > 0) {
			scanBlackCell(arrHeap, objHeap, env, child);
		} else {
			setColorAt(arrHeap, objHeap, child, COL_WHITE);
			traceCell(arrHeap, objHeap, env, child);
		}
	}
}

function collectColorCell(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, env: OrcEnv, h: int64, col: int32): void {
	if (colorAt(arrHeap, objHeap, h) != col || registered(arrHeap, objHeap, h)) return;
	setColorAt(arrHeap, objHeap, h, COL_BLACK);
	env.toFree.push(h);
	traceCell(arrHeap, objHeap, env, h);
	while (env.children.length > 0) {
		const at = env.children.length - 1;
		const owner = env.owners[at];
		const index = env.indices[at];
		const child = env.children[at];
		popSlot(env);
		clearSlot(arrHeap, objHeap, owner, index);
		if (colorAt(arrHeap, objHeap, child) == col && !registered(arrHeap, objHeap, child)) {
			setColorAt(arrHeap, objHeap, child, COL_BLACK);
			env.toFree.push(child);
			traceCell(arrHeap, objHeap, env, child);
		}
	}
}

export function orcRegisterCandidate(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, handle: int64): boolean {
	if (handle == 0) return false;
	const kind = handleHeapKind(handle);
	if (kind != RaiserHeapKind.Seq && kind != RaiserHeapKind.Object) return false;
	if (registered(arrHeap, objHeap, handle)) return false;
	const roots = arrHeap.orcRoots;
	setColorField(arrHeap, objHeap, handle, COL_BLACK | ((roots.length + 1) << ROOT_SHIFT));
	roots.push(handle);
	return roots.length - ORC_DEFAULT_THRESHOLD >= arrHeap.orcThreshold;
}

export function orcUnregister(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, handle: int64): void {
	const kind = handleHeapKind(handle);
	if (kind != RaiserHeapKind.Seq && kind != RaiserHeapKind.Object) return;
	if (!registered(arrHeap, objHeap, handle)) return;
	rcForgetRoot(arrHeap, objHeap, handle);
}

export function orcCollect(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, destroy: OrcDestroy): int32 {
	const roots = arrHeap.orcRoots;
	if (roots.length == 0) return 0;
	const env: OrcEnv = { owners: [], indices: [], children: [], toFree: [], touched: 0, edges: 0, rcSum: 0, keepThreshold: false };
	const count = roots.length;
	for (let i = count - 1; i >= 0; i -= 1) markGrayCell(arrHeap, objHeap, env, roots[i]);
	let colToCollect = COL_WHITE;
	if (env.rcSum == env.edges) {
		colToCollect = COL_GRAY;
		env.keepThreshold = true;
	} else {
		for (let i = count - 1; i >= 0; i -= 1) scanCell(arrHeap, objHeap, env, roots[i]);
	}
	for (let i = 0; i < count; i += 1) {
		const h = roots[i];
		setColorField(arrHeap, objHeap, h, colorField(arrHeap, objHeap, h) & COLOR_MASK);
		collectColorCell(arrHeap, objHeap, env, h, colToCollect);
	}
	const oldThreshold = arrHeap.orcThreshold;
	arrHeap.orcThreshold = NEVER_COLLECT;
	roots.length = 0;
	for (const h of env.toFree) {
		setCount(arrHeap, objHeap, h, 1);
		destroy(h);
	}
	arrHeap.orcThreshold = oldThreshold;
	const freed = env.toFree.length;
	if (!env.keepThreshold) {
		if (freed * 2 >= env.touched) {
			arrHeap.orcThreshold = Math.max(Math.floor(oldThreshold * 2 / 3), MIN_THRESHOLD);
		} else if (oldThreshold < Math.floor(NEVER_COLLECT / 4)) {
			const base = oldThreshold <= 0 ? ORC_DEFAULT_THRESHOLD : oldThreshold;
			arrHeap.orcThreshold = Math.floor(base / 2) + base;
		}
	}
	return freed as int32;
}

// --- Tests ---

function nodeType(): RaiserClassType {
	const type = createClassType("Node", -1, [], ["next", "kids", "more", "spare", "items"], [RaiserRegClass.Dyn, RaiserRegClass.Dyn, RaiserRegClass.Dyn, RaiserRegClass.Dyn, RaiserRegClass.Dyn]);
	for (let i = 0; i < 5; i += 1) type.cyclic[i] = true;
	return type;
}

function allocNode(obj: RaiserObjectHeap): int64 {
	const h = heapAllocObject(obj);
	layOutObject(obj.objects[handleIndex(h)], nodeType());
	obj.objects[handleIndex(h)].rc = 0;
	return h;
}

function linkObjects(arr: RaiserArrayHeap, obj: RaiserObjectHeap, from: int64, to: int64, name: string): void {
	rcIncref(arr, obj, raiserObject(to));
	heapObjectSetField(arr, obj, from, name, raiserObject(to));
}

function freeByCount(arr: RaiserArrayHeap, obj: RaiserObjectHeap): OrcDestroy {
	return (h: int64): void => { rcDecrefHandle(arr, obj, h); };
}

test "orcCollect walks a ring as long as the heap without native recursion, kept and collected" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const count = 300000;
	const first = allocNode(obj);
	let prev = first;
	for (let i = 1; i < count; i += 1) {
		const next = allocNode(obj);
		linkObjects(arr, obj, prev, next, "next");
		prev = next;
	}
	linkObjects(arr, obj, prev, first, "next");
	rcIncref(arr, obj, raiserObject(first));
	orcRegisterCandidate(arr, obj, first);
	assert orcCollect(arr, obj, freeByCount(arr, obj)) == 0;
	assert obj.objects[handleIndex(first)].rc == 2 && obj.objects[handleIndex(prev)].rc == 1;
	rcDecref(arr, obj, raiserObject(first));
	orcRegisterCandidate(arr, obj, first);
	assert orcCollect(arr, obj, freeByCount(arr, obj)) == count;
	assert obj.freeList.length == count;
}

test "orcCollect frees a registered garbage cycle and leaves unregistered cells alone" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const a = allocNode(obj);
	const b = allocNode(obj);
	linkObjects(arr, obj, a, b, "next");
	linkObjects(arr, obj, b, a, "next");
	const c = allocNode(obj);
	const d = allocNode(obj);
	linkObjects(arr, obj, c, d, "next");
	linkObjects(arr, obj, d, c, "next");
	const live = allocNode(obj);
	rcIncref(arr, obj, raiserObject(live));
	assert !orcRegisterCandidate(arr, obj, a);
	assert arr.orcRoots.length == 1;
	assert orcCollect(arr, obj, freeByCount(arr, obj)) == 2;
	assert obj.freeList.length == 2;
	assert obj.objects[handleIndex(c)].rc == 1 && obj.objects[handleIndex(d)].rc == 1;
	assert obj.objects[handleIndex(live)].rc == 1;
	assert arr.orcRoots.length == 0;
}

test "orcCollect keeps an externally referenced registered cycle and drops it from the roots" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const a = allocNode(obj);
	const b = allocNode(obj);
	linkObjects(arr, obj, a, b, "next");
	linkObjects(arr, obj, b, a, "next");
	rcIncref(arr, obj, raiserObject(a));
	orcRegisterCandidate(arr, obj, a);
	assert orcCollect(arr, obj, freeByCount(arr, obj)) == 0;
	assert obj.objects[handleIndex(a)].rc == 2 && obj.objects[handleIndex(b)].rc == 1;
	assert arr.orcRoots.length == 0;
	assert obj.objects[handleIndex(a)].color == 0;
	assert !orcRegisterCandidate(arr, obj, a);
	assert arr.orcRoots.length == 1;
}

test "orcCollect clears each slot of a three-node ring before its destroy runs, once per cell" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const a = allocNode(obj);
	const b = allocNode(obj);
	const c = allocNode(obj);
	linkObjects(arr, obj, a, b, "next");
	linkObjects(arr, obj, b, c, "next");
	linkObjects(arr, obj, c, a, "next");
	orcRegisterCandidate(arr, obj, b);
	const calls: int64[] = [];
	const destroy: OrcDestroy = (h: int64): void => {
		const cell = obj.objects[handleIndex(h)];
		assert fieldValueAt(cell, 0).kind == RaiserValueKind.Nil;
		assert cell.rc == 1;
		calls.push(h);
		rcDecrefHandle(arr, obj, h);
	};
	assert orcCollect(arr, obj, destroy) == 3;
	assert calls.length == 3;
	assert calls[0] != calls[1] && calls[1] != calls[2] && calls[0] != calls[2];
	assert obj.freeList.length == 3;
}

test "orcCollect frees a cycle that runs through an array, holding handles as items and as words" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const o = allocNode(obj);
	const items = heapAllocArray(arr);
	const words = heapAllocArrayOf(arr, RaiserRegClass.Ref);
	heapArraySetFlags(arr, items, true, false);
	heapArraySetFlags(arr, words, true, false);
	heapObjectSetField(arr, obj, o, "items", raiserArray(items));
	heapArrayPush(arr, items, raiserArray(words));
	heapArrayPush(arr, words, handleValue(o));
	rcIncref(arr, obj, raiserObject(o));
	orcRegisterCandidate(arr, obj, items);
	assert orcCollect(arr, obj, freeByCount(arr, obj)) == 3;
	assert heapSeqHandles(arr).length == 0 && obj.freeList.length == 1;
}

test "orcRegisterCandidate asks for a collection at 128 plus the threshold and the threshold follows the runtime rule" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	for (let i = 0; i < 255; i += 1) {
		const h = allocNode(obj);
		rcIncref(arr, obj, raiserObject(h));
		assert !orcRegisterCandidate(arr, obj, h);
	}
	const last = allocNode(obj);
	rcIncref(arr, obj, raiserObject(last));
	assert orcRegisterCandidate(arr, obj, last);
	assert orcCollect(arr, obj, freeByCount(arr, obj)) == 0;
	assert arr.orcThreshold == 192;
	assert arr.orcRoots.length == 0;

	const a = allocNode(obj);
	const b = allocNode(obj);
	linkObjects(arr, obj, a, b, "next");
	linkObjects(arr, obj, b, a, "next");
	orcRegisterCandidate(arr, obj, a);
	orcRegisterCandidate(arr, obj, last);
	assert orcCollect(arr, obj, freeByCount(arr, obj)) == 2;
	assert arr.orcThreshold == 128;
}

test "orcCollect keeps the threshold when every reference of the roots is internal" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const a = allocNode(obj);
	const b = allocNode(obj);
	linkObjects(arr, obj, a, b, "next");
	linkObjects(arr, obj, b, a, "next");
	orcRegisterCandidate(arr, obj, a);
	assert orcCollect(arr, obj, freeByCount(arr, obj)) == 2;
	assert arr.orcThreshold == 128;
}

test "orcUnregister swaps the last root into the freed slot and a freed cell stays out of the collection" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const a = allocNode(obj);
	const b = allocNode(obj);
	const c = allocNode(obj);
	rcIncref(arr, obj, raiserObject(a));
	rcIncref(arr, obj, raiserObject(b));
	rcIncref(arr, obj, raiserObject(c));
	orcRegisterCandidate(arr, obj, a);
	orcRegisterCandidate(arr, obj, b);
	orcRegisterCandidate(arr, obj, c);
	orcUnregister(arr, obj, a);
	assert arr.orcRoots.length == 2;
	assert obj.objects[handleIndex(a)].color == 0;
	assert obj.objects[handleIndex(c)].color >> 2 == 1;
	orcUnregister(arr, obj, c);
	assert obj.objects[handleIndex(b)].color >> 2 == 1;
	assert orcCollect(arr, obj, freeByCount(arr, obj)) == 0;
	assert obj.objects[handleIndex(a)].rc == 1 && obj.objects[handleIndex(c)].rc == 1;
}

test "orcCollect frees a ring of object cells, clearing each slot before its destroy runs" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const ring = createClassType("Ring", -1, [], ["next"], [RaiserRegClass.Ref]);
	ring.cyclic[0] = true;
	const a = objectCellNew(arr.mem, ring, 1);
	const b = objectCellNew(arr.mem, ring, 1);
	objectCellSetSlot(a, 0, objectCellHandle(b));
	objectCellSetSlot(b, 0, objectCellHandle(a));
	orcRegisterCandidate(arr, obj, objectCellHandle(a));
	const calls: int64[] = [];
	const destroy: OrcDestroy = (h: int64): void => {
		assert objectCellSlot(seqCellOf(h), 0) == 0;
		calls.push(h);
		rcDecrefHandle(arr, obj, h);
	};
	assert orcCollect(arr, obj, destroy) == 2;
	assert calls.length == 2 && liveCellBlocks(arr.mem).length == 0;
}

test "orcCollect keeps an object cell ring that an outside holder still counts" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const ring = createClassType("Ring", -1, [], ["next"], [RaiserRegClass.Ref]);
	ring.cyclic[0] = true;
	const a = objectCellNew(arr.mem, ring, 2);
	const b = objectCellNew(arr.mem, ring, 1);
	objectCellSetSlot(a, 0, objectCellHandle(b));
	objectCellSetSlot(b, 0, objectCellHandle(a));
	orcRegisterCandidate(arr, obj, objectCellHandle(a));
	assert orcCollect(arr, obj, (h: int64): void => { assert false; }) == 0;
	assert liveCellBlocks(arr.mem).length == 2 && objectCellSlot(a, 0) == objectCellHandle(b);
}

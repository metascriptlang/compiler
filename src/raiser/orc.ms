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
	heapObjectSetField, heapArrayPush, rcIncref, heldHandle, objectFieldCount, fieldValueAt, arrayHoldsHandles, arrayHeldCount, arrayHeldAt,
	handleHeapKind, raiserNil, rcDecrefHandle, heapAllocArrayOf
} from "./value";
import { RaiserRegClass } from "./bytecode";

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
		const data = arrHeap.arrays[handleIndex(v.intVal)];
		if (!arrayHoldsHandles(data)) return;
		const count = arrayHeldCount(data);
		for (let i = 0; i < count; i += 1) {
			const child = arrayHeldAt(data, i);
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
// White → mark GRAY (in-collect-set) to disambiguate from external BLACK refs. Every root's set joins one
// list that is freed only after all roots are traced: a node freed early turns BLACK again and a later
// root's trace would release it as an external ref a second time.

function collectWhite(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, held: RaiserValue, toFree: RaiserValue[]): void {
	const work: RaiserValue[] = [heldHandle(held)];
	while (work.length > 0) {
		const v = work.pop()!;
		if (colorOf(arrHeap, objHeap, v) != COL_WHITE) continue;
		setColorOf(arrHeap, objHeap, v, COL_GRAY);
		toFree.push(v);
		if (v.kind == RaiserValueKind.Array) {
			const data = arrHeap.arrays[handleIndex(v.intVal)];
			if (arrayHoldsHandles(data)) {
				const count = arrayHeldCount(data);
				for (let i = 0; i < count; i += 1) releaseWhiteChild(arrHeap, objHeap, arrayHeldAt(data, i), work);
			}
		} else {
			const obj = objHeap.objects[handleIndex(v.intVal)];
			const count = objectFieldCount(obj);
			for (let i = 0; i < count; i += 1) releaseWhiteChild(arrHeap, objHeap, fieldValueAt(obj, i), work);
		}
	}
}

function freeCollected(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, toFree: RaiserValue[]): void {
	for (const v of toFree) {
		if (v.kind == RaiserValueKind.Array) {
			const data = arrHeap.arrays[handleIndex(v.intVal)];
			data.items.length = 0;
			data.words.length = 0;
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
	const toFree: RaiserValue[] = [];
	for (let h = 0; h < arrHeap.arrays.length; h = h + 1) {
		if (colorOf(arrHeap, objHeap, arrayAt(h)) == COL_WHITE) collectWhite(arrHeap, objHeap, arrayAt(h), toFree);
	}
	for (let h = 0; h < objHeap.objects.length; h = h + 1) {
		if (colorOf(arrHeap, objHeap, objectAt(h)) == COL_WHITE) collectWhite(arrHeap, objHeap, objectAt(h), toFree);
	}
	freeCollected(arrHeap, objHeap, toFree);
	return toFree.length as int32;
}

export type OrcDestroy = (handle: int64) => void;

const COLOR_MASK = 3;
const ROOT_SHIFT = 2;
const DEFAULT_THRESHOLD = 128;
const MIN_THRESHOLD = 16;
const NEVER_COLLECT = 2147483647;

interface OrcRoots {
	arrHeap: RaiserArrayHeap;
	objHeap: RaiserObjectHeap;
	handles: int64[];
	threshold: number;
}

const orcRegistries: OrcRoots[] = [];

function registryIndex(arrHeap: RaiserArrayHeap): number {
	for (let i = 0; i < orcRegistries.length; i += 1) {
		if (orcRegistries[i].arrHeap === arrHeap) return i;
	}
	return -1;
}

function colorField(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, h: int64): int32 {
	const kind = handleHeapKind(h);
	if (kind == RaiserHeapKind.Array) return arrHeap.arrays[handleIndex(h)].color;
	if (kind == RaiserHeapKind.Object) return objHeap.objects[handleIndex(h)].color;
	throw new Error(`internal: handle ${h} is no collectable cell`);
}

function setColorField(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, h: int64, field: int32): void {
	if (handleHeapKind(h) == RaiserHeapKind.Array) { arrHeap.arrays[handleIndex(h)].color = field; }
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
	if (handleHeapKind(h) == RaiserHeapKind.Array) return arrHeap.arrays[handleIndex(h)].rc;
	return objHeap.objects[handleIndex(h)].rc;
}

function addCount(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, h: int64, delta: int32): void {
	if (handleHeapKind(h) == RaiserHeapKind.Array) { arrHeap.arrays[handleIndex(h)].rc += delta; }
	else { objHeap.objects[handleIndex(h)].rc += delta; }
}

function setCount(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, h: int64, count: int32): void {
	if (handleHeapKind(h) == RaiserHeapKind.Array) { arrHeap.arrays[handleIndex(h)].rc = count; }
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
	const v = heldHandle(held);
	return v.kind == RaiserValueKind.Array || v.kind == RaiserValueKind.Object ? v.intVal : 0;
}

function pushSlot(env: OrcEnv, owner: int64, index: int32, held: RaiserValue): void {
	const child = collectableHandle(held);
	if (child == 0) return;
	env.owners.push(owner);
	env.indices.push(index);
	env.children.push(child);
}

function traceCell(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, env: OrcEnv, h: int64): void {
	if (handleHeapKind(h) == RaiserHeapKind.Array) {
		const data = arrHeap.arrays[handleIndex(h)];
		if (!arrayHoldsHandles(data)) return;
		const count = arrayHeldCount(data);
		for (let i = 0; i < count; i += 1) pushSlot(env, h, i as int32, arrayHeldAt(data, i));
	} else {
		const obj = objHeap.objects[handleIndex(h)];
		const count = objectFieldCount(obj);
		for (let i = 0; i < count; i += 1) pushSlot(env, h, i as int32, fieldValueAt(obj, i));
	}
}

function clearSlot(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, owner: int64, index: int32): void {
	if (handleHeapKind(owner) == RaiserHeapKind.Array) {
		const data = arrHeap.arrays[handleIndex(owner)];
		if (data.elemClass == RaiserRegClass.Dyn) { data.items[index] = raiserNil(); }
		else if (data.elemClass == RaiserRegClass.Ref) { data.words[index] = 0; }
		else throw new Error("internal: a collector slot names an array that holds no handles");
		return;
	}
	const obj = objHeap.objects[handleIndex(owner)];
	const laid = obj.slots.length;
	if (index >= laid) { obj.values[obj.values.length - obj.added.length + index - laid] = raiserNil(); return; }
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

function unregisterAt(roots: OrcRoots, h: int64): void {
	const slot = (colorField(roots.arrHeap, roots.objHeap, h) >> ROOT_SHIFT) - 1;
	const last = roots.handles.length - 1;
	const moved = roots.handles[last];
	roots.handles[slot] = moved;
	roots.handles.length = last;
	if (moved != h) {
		const field = colorField(roots.arrHeap, roots.objHeap, moved);
		setColorField(roots.arrHeap, roots.objHeap, moved, (field & COLOR_MASK) | ((slot + 1) << ROOT_SHIFT));
	}
	setColorField(roots.arrHeap, roots.objHeap, h, colorField(roots.arrHeap, roots.objHeap, h) & COLOR_MASK);
}

export function orcRegisterCandidate(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, handle: int64): boolean {
	if (handle == 0) return false;
	if (registered(arrHeap, objHeap, handle)) return false;
	let at = registryIndex(arrHeap);
	if (at < 0) {
		orcRegistries.push({ arrHeap, objHeap, handles: [], threshold: DEFAULT_THRESHOLD });
		at = orcRegistries.length - 1;
	}
	const roots = orcRegistries[at];
	setColorField(arrHeap, objHeap, handle, COL_BLACK | ((roots.handles.length + 1) << ROOT_SHIFT));
	roots.handles.push(handle);
	return roots.handles.length - DEFAULT_THRESHOLD >= roots.threshold;
}

export function orcUnregister(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, handle: int64): void {
	if (handle == 0 || !registered(arrHeap, objHeap, handle)) return;
	const at = registryIndex(arrHeap);
	if (at < 0) throw new Error(`internal: cell ${handle} is registered but its heap has no collector roots`);
	unregisterAt(orcRegistries[at], handle);
}

export function orcRelease(arrHeap: RaiserArrayHeap): void {
	const at = registryIndex(arrHeap);
	if (at < 0) return;
	orcRegistries[at] = orcRegistries[orcRegistries.length - 1];
	orcRegistries.pop();
}

export function orcRootCount(arrHeap: RaiserArrayHeap): number {
	const at = registryIndex(arrHeap);
	return at < 0 ? 0 : orcRegistries[at].handles.length;
}

export function orcThreshold(arrHeap: RaiserArrayHeap): number {
	const at = registryIndex(arrHeap);
	return at < 0 ? DEFAULT_THRESHOLD : orcRegistries[at].threshold;
}

export function orcCollect(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, destroy: OrcDestroy): int32 {
	const at = registryIndex(arrHeap);
	if (at < 0) return 0;
	const roots = orcRegistries[at];
	if (roots.handles.length == 0) return 0;
	const env: OrcEnv = { owners: [], indices: [], children: [], toFree: [], touched: 0, edges: 0, rcSum: 0, keepThreshold: false };
	const count = roots.handles.length;
	for (let i = count - 1; i >= 0; i -= 1) markGrayCell(arrHeap, objHeap, env, roots.handles[i]);
	let colToCollect = COL_WHITE;
	if (env.rcSum == env.edges) {
		colToCollect = COL_GRAY;
		env.keepThreshold = true;
	} else {
		for (let i = count - 1; i >= 0; i -= 1) scanCell(arrHeap, objHeap, env, roots.handles[i]);
	}
	for (let i = 0; i < count; i += 1) {
		const h = roots.handles[i];
		setColorField(arrHeap, objHeap, h, colorField(arrHeap, objHeap, h) & COLOR_MASK);
		collectColorCell(arrHeap, objHeap, env, h, colToCollect);
	}
	const oldThreshold = roots.threshold;
	roots.threshold = NEVER_COLLECT;
	roots.handles.length = 0;
	for (const h of env.toFree) {
		setCount(arrHeap, objHeap, h, 1);
		destroy(h);
	}
	roots.threshold = oldThreshold;
	const freed = env.toFree.length;
	if (!env.keepThreshold) {
		if (freed * 2 >= env.touched) {
			roots.threshold = Math.max(Math.floor(roots.threshold * 2 / 3), MIN_THRESHOLD);
		} else if (roots.threshold < Math.floor(NEVER_COLLECT / 4)) {
			if (roots.threshold <= 0) roots.threshold = DEFAULT_THRESHOLD;
			roots.threshold = Math.floor(roots.threshold / 2) + roots.threshold;
		}
	}
	return freed as int32;
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

test "orc frees a node reachable from two garbage roots once" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const a = heapAllocObject(obj);
	const more = heapAllocArray(arr);
	const spare = heapAllocArray(arr);
	const kids = heapAllocArray(arr);
	rcIncref(arr, obj, raiserArray(kids));
	heapObjectSetField(obj, a, "kids", raiserArray(kids));
	rcIncref(arr, obj, raiserArray(more));
	heapObjectSetField(obj, a, "more", raiserArray(more));
	rcIncref(arr, obj, raiserArray(spare));
	heapObjectSetField(obj, a, "spare", raiserArray(spare));
	rcIncref(arr, obj, raiserObject(a));
	heapArrayPush(arr, kids, raiserObject(a));
	assert orcCollectCycles(arr, obj) == 4;
	assert arr.freeList.length == 3 && obj.freeList.length == 1;
}

function linkObjects(arr: RaiserArrayHeap, obj: RaiserObjectHeap, from: int64, to: int64, name: string): void {
	rcIncref(arr, obj, raiserObject(to));
	heapObjectSetField(obj, from, name, raiserObject(to));
}

function freeByCount(arr: RaiserArrayHeap, obj: RaiserObjectHeap): OrcDestroy {
	return (h: int64): void => { rcDecrefHandle(arr, obj, h); };
}

test "orcCollect frees a registered garbage cycle and leaves unregistered cells alone" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const a = heapAllocObject(obj);
	const b = heapAllocObject(obj);
	linkObjects(arr, obj, a, b, "next");
	linkObjects(arr, obj, b, a, "next");
	const c = heapAllocObject(obj);
	const d = heapAllocObject(obj);
	linkObjects(arr, obj, c, d, "next");
	linkObjects(arr, obj, d, c, "next");
	const live = heapAllocObject(obj);
	rcIncref(arr, obj, raiserObject(live));
	assert !orcRegisterCandidate(arr, obj, a);
	assert orcRootCount(arr) == 1;
	assert orcCollect(arr, obj, freeByCount(arr, obj)) == 2;
	assert obj.freeList.length == 2;
	assert obj.objects[handleIndex(c)].rc == 1 && obj.objects[handleIndex(d)].rc == 1;
	assert obj.objects[handleIndex(live)].rc == 1;
	assert orcRootCount(arr) == 0;
	orcRelease(arr);
}

test "orcCollect keeps an externally referenced registered cycle and drops it from the roots" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const a = heapAllocObject(obj);
	const b = heapAllocObject(obj);
	linkObjects(arr, obj, a, b, "next");
	linkObjects(arr, obj, b, a, "next");
	rcIncref(arr, obj, raiserObject(a));
	orcRegisterCandidate(arr, obj, a);
	assert orcCollect(arr, obj, freeByCount(arr, obj)) == 0;
	assert obj.objects[handleIndex(a)].rc == 2 && obj.objects[handleIndex(b)].rc == 1;
	assert orcRootCount(arr) == 0;
	assert obj.objects[handleIndex(a)].color == 0;
	assert !orcRegisterCandidate(arr, obj, a);
	assert orcRootCount(arr) == 1;
	orcRelease(arr);
}

test "orcCollect clears each slot of a three-node ring before its destroy runs, once per cell" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const a = heapAllocObject(obj);
	const b = heapAllocObject(obj);
	const c = heapAllocObject(obj);
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
	orcRelease(arr);
}

test "orcCollect frees a cycle that runs through an array, holding handles as items and as words" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const o = heapAllocObject(obj);
	const items = heapAllocArray(arr);
	const words = heapAllocArrayOf(arr, RaiserRegClass.Ref);
	rcIncref(arr, obj, raiserArray(items));
	heapObjectSetField(obj, o, "items", raiserArray(items));
	rcIncref(arr, obj, raiserArray(words));
	heapArrayPush(arr, items, raiserArray(words));
	arr.arrays[handleIndex(words)].words.push(o);
	rcIncref(arr, obj, raiserObject(o));
	orcRegisterCandidate(arr, obj, items);
	assert orcCollect(arr, obj, freeByCount(arr, obj)) == 3;
	assert arr.freeList.length == 2 && obj.freeList.length == 1;
	orcRelease(arr);
}

test "orcRegisterCandidate asks for a collection at 128 plus the threshold and the threshold follows the runtime rule" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	for (let i = 0; i < 255; i += 1) {
		const h = heapAllocObject(obj);
		rcIncref(arr, obj, raiserObject(h));
		assert !orcRegisterCandidate(arr, obj, h);
	}
	const last = heapAllocObject(obj);
	rcIncref(arr, obj, raiserObject(last));
	assert orcRegisterCandidate(arr, obj, last);
	assert orcCollect(arr, obj, freeByCount(arr, obj)) == 0;
	assert orcThreshold(arr) == 192;
	assert orcRootCount(arr) == 0;

	const a = heapAllocObject(obj);
	const b = heapAllocObject(obj);
	linkObjects(arr, obj, a, b, "next");
	linkObjects(arr, obj, b, a, "next");
	orcRegisterCandidate(arr, obj, a);
	orcRegisterCandidate(arr, obj, last);
	assert orcCollect(arr, obj, freeByCount(arr, obj)) == 2;
	assert orcThreshold(arr) == 128;
	orcRelease(arr);
}

test "orcCollect keeps the threshold when every reference of the roots is internal" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const a = heapAllocObject(obj);
	const b = heapAllocObject(obj);
	linkObjects(arr, obj, a, b, "next");
	linkObjects(arr, obj, b, a, "next");
	orcRegisterCandidate(arr, obj, a);
	assert orcCollect(arr, obj, freeByCount(arr, obj)) == 2;
	assert orcThreshold(arr) == 128;
	orcRelease(arr);
}

test "orcUnregister swaps the last root into the freed slot and a freed cell stays out of the collection" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const a = heapAllocObject(obj);
	const b = heapAllocObject(obj);
	const c = heapAllocObject(obj);
	rcIncref(arr, obj, raiserObject(a));
	rcIncref(arr, obj, raiserObject(b));
	rcIncref(arr, obj, raiserObject(c));
	orcRegisterCandidate(arr, obj, a);
	orcRegisterCandidate(arr, obj, b);
	orcRegisterCandidate(arr, obj, c);
	orcUnregister(arr, obj, a);
	assert orcRootCount(arr) == 2;
	assert obj.objects[handleIndex(a)].color == 0;
	assert obj.objects[handleIndex(c)].color >> 2 == 1;
	orcUnregister(arr, obj, c);
	assert obj.objects[handleIndex(b)].color >> 2 == 1;
	assert orcCollect(arr, obj, freeByCount(arr, obj)) == 0;
	assert obj.objects[handleIndex(a)].rc == 1 && obj.objects[handleIndex(c)].rc == 1;
	orcRelease(arr);
}

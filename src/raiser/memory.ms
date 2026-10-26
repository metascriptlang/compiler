import { MemKind } from "./layout";

extern function msBitsFloat64(u: int64): float64;
extern function msFloat64Bits(d: float64): int64;

export enum RegionKind { Stack, Globals, Const, Heap }

export interface Region {
	start: int64;
	size: int64;
	kind: RegionKind;
	used: int64;
}

export interface StackSegment {
	base: int64;
	cap: int64;
	used: int64;
}

export interface StackMark {
	seg: int32;
	used: int64;
	boxes: int32;
}

export interface BumpArea {
	cur: int64;
	left: int64;
	kind: RegionKind;
}

export interface VmMemory {
	words: int64[];
	regions: Region[];
	lastHit: int32;
	freeLists: int64[];
	heapCur: int64;
	heapLeft: int64;
	heapRegion: int32;
	stack: StackSegment[];
	sp: StackMark;
	boxes: int64[];
	globals: BumpArea;
	consts: BumpArea;
	bytesInUse: int64;
}

export interface HeapAudit {
	allocated: int32;
	free: int32;
	bytes: int64;
}

export const HEAP_CHUNK_SIZE: int64 = 256 * 1024;
export const BUMP_CHUNK_SIZE: int64 = 64 * 1024;
export const STACK_SEGMENT_SIZE: int64 = 2 * 1024 * 1024;
export const BLOCK_HEADER_SIZE: int64 = 16;
export const BLOCK_ALIGN: int64 = 16;
export const STATE_ALLOCATED: int64 = 0xA110C8ED;
export const STATE_FREE: int64 = 0xF4EEB10C;
export const REF_HEADER_SIZE: int64 = 24;

const SMALL_CLASSES = 8;
const FIRST_LARGE_BLOCK: int64 = 256;

export function createVmMemory(): VmMemory {
	return {
		words: [0, 0], regions: [], lastHit: 0, freeLists: [], heapCur: 0, heapLeft: 0, heapRegion: -1, stack: [],
		sp: { seg: 0, used: 0, boxes: 0 }, boxes: [],
		globals: { cur: 0, left: 0, kind: RegionKind.Globals }, consts: { cur: 0, left: 0, kind: RegionKind.Const }, bytesInUse: 0,
	};
}

function alignUp(x: int64, a: int64): int64 {
	return (x + a - 1) & ~(a - 1);
}

function hostGrow(mem: VmMemory, size: int64): int64 {
	const start = mem.words.length * 8;
	mem.words.length = (mem.words.length + size / 8) as int32;
	return start;
}

function addRegion(mem: VmMemory, start: int64, size: int64, kind: RegionKind): int32 {
	mem.regions.push({ start, size, kind, used: 0 });
	mem.lastHit = mem.regions.length - 1;
	return mem.lastHit;
}

function findRegion(mem: VmMemory, a: int64): int32 {
	if (mem.lastHit < mem.regions.length) {
		const r = mem.regions[mem.lastHit];
		if (a >= r.start && a - r.start < r.size) return mem.lastHit;
	}
	let lo = 0;
	let hi = mem.regions.length - 1;
	while (lo <= hi) {
		const mid = (lo + hi) >> 1;
		const r = mem.regions[mid];
		if (a < r.start) hi = mid - 1;
		else if (a - r.start >= r.size) lo = mid + 1;
		else {
			mem.lastHit = mid;
			return mid;
		}
	}
	return -1;
}

export function canRead(mem: VmMemory, a: int64, size: int64): boolean {
	if (size == 0) return true;
	const i = findRegion(mem, a);
	return i >= 0 && a - mem.regions[i].start + size <= mem.regions[i].size;
}

export function canWrite(mem: VmMemory, a: int64, size: int64): boolean {
	if (size == 0) return true;
	const i = findRegion(mem, a);
	return i >= 0 && mem.regions[i].kind != RegionKind.Const && a - mem.regions[i].start + size <= mem.regions[i].size;
}

export function accessRefusal(mem: VmMemory, a: int64, size: int64, write: boolean): string {
	if (write ? canWrite(mem, a, size) : canRead(mem, a, size)) return "";
	const i = findRegion(mem, a);
	if (i >= 0 && write && mem.regions[i].kind == RegionKind.Const && a - mem.regions[i].start + size <= mem.regions[i].size) {
		return `memory write of ${size} bytes at address ${a} is into read-only constant memory`;
	}
	return `memory ${write ? "write" : "read"} of ${size} bytes at address ${a} is outside VM memory`;
}

export function isConstMemory(mem: VmMemory, a: int64): boolean {
	const i = findRegion(mem, a);
	return i >= 0 && mem.regions[i].kind == RegionKind.Const;
}

function checkAligned(a: int64, width: int64): void {
	when (mode != "danger") {
		if (a <= 0 || a % width != 0) throw new Error(`internal: a ${width} byte access at address ${a} is not aligned`);
	}
}

export function ld64(mem: VmMemory, a: int64): int64 {
	checkAligned(a, 8);
	return mem.words[a >> 3];
}

export function st64(mem: VmMemory, a: int64, v: int64): void {
	checkAligned(a, 8);
	mem.words[a >> 3] = v;
}

function laneShift(a: int64): int64 {
	return (a & 7) * 8;
}

function laneMask(width: int64): int64 {
	return width == 1 ? 0xFF : width == 2 ? 0xFFFF : 0xFFFFFFFF;
}

function ldUnsigned(mem: VmMemory, a: int64, width: int64): int64 {
	checkAligned(a, width);
	return (mem.words[a >> 3] >> laneShift(a)) & laneMask(width);
}

function stLane(mem: VmMemory, a: int64, width: int64, v: int64): void {
	checkAligned(a, width);
	const mask = laneMask(width);
	const shift = laneShift(a);
	const index = a >> 3;
	mem.words[index] = (mem.words[index] & ~(mask << shift)) | ((v & mask) << shift);
}

function signExtend(v: int64, width: int64): int64 {
	const sign = laneMask(width) / 2 + 1;
	return (v ^ sign) - sign;
}

export function memLoad(mem: VmMemory, a: int64, kind: MemKind): int64 {
	if (kind == MemKind.F32 || kind == MemKind.Block) throw new Error(`internal: a typed load of kind ${kind as number} is not provided`);
	return match (kind) {
		MemKind.U8 => ldUnsigned(mem, a, 1),
		MemKind.U16 => ldUnsigned(mem, a, 2),
		MemKind.U32 => ldUnsigned(mem, a, 4),
		MemKind.I8 => signExtend(ldUnsigned(mem, a, 1), 1),
		MemKind.I16 => signExtend(ldUnsigned(mem, a, 2), 2),
		MemKind.I32 => signExtend(ldUnsigned(mem, a, 4), 4),
		MemKind.I64 | MemKind.U64 | MemKind.Ptr => ld64(mem, a),
		MemKind.F64 => ld64(mem, a),
		MemKind.F32 | MemKind.Block => 0,
	};
}

export function memStore(mem: VmMemory, a: int64, kind: MemKind, v: int64): void {
	if (kind == MemKind.F32 || kind == MemKind.Block) throw new Error(`internal: a typed store of kind ${kind as number} is not provided`);
	match (kind) {
		MemKind.U8 | MemKind.I8 => { stLane(mem, a, 1, v); },
		MemKind.U16 | MemKind.I16 => { stLane(mem, a, 2, v); },
		MemKind.U32 | MemKind.I32 => { stLane(mem, a, 4, v); },
		MemKind.I64 | MemKind.U64 | MemKind.Ptr | MemKind.F64 => { st64(mem, a, v); },
		MemKind.F32 | MemKind.Block => {},
	}
}

export function ldF64(mem: VmMemory, a: int64): float64 {
	return msBitsFloat64(ld64(mem, a));
}

export function stF64(mem: VmMemory, a: int64, v: float64): void {
	st64(mem, a, msFloat64Bits(v));
}

function zeroRange(mem: VmMemory, a: int64, size: int64): void {
	const end = (a + size) >> 3;
	for (let i = a >> 3; i < end; i += 1) mem.words[i] = 0;
}

function sizeClass(size: int64): int64[] {
	if (size <= 128) {
		const s = Math.max(alignUp(size, 16), 16);
		return [s / 16 - 1, s];
	}
	let s = FIRST_LARGE_BLOCK;
	let c = SMALL_CLASSES;
	while (s < size) {
		s = s * 2;
		c += 1;
	}
	return [c, s];
}

export function heapAlloc(mem: VmMemory, size: int64): int64 {
	if (size <= 0) return 0;
	const cls = sizeClass(size);
	const index = cls[0] as int32;
	const bs = cls[1];
	while (mem.freeLists.length <= index) mem.freeLists.push(0);
	let b = mem.freeLists[index];
	if (b != 0) {
		mem.freeLists[index] = ld64(mem, b + BLOCK_HEADER_SIZE);
		zeroRange(mem, b + BLOCK_HEADER_SIZE, bs);
	} else {
		const total = BLOCK_HEADER_SIZE + bs;
		if (mem.heapLeft < total) {
			const chunk = Math.max(HEAP_CHUNK_SIZE, total);
			mem.heapCur = hostGrow(mem, chunk);
			mem.heapLeft = chunk;
			mem.heapRegion = addRegion(mem, mem.heapCur, chunk, RegionKind.Heap);
		}
		b = mem.heapCur;
		mem.heapCur = mem.heapCur + total;
		mem.heapLeft = mem.heapLeft - total;
		mem.regions[mem.heapRegion].used = mem.heapCur - mem.regions[mem.heapRegion].start;
	}
	st64(mem, b, bs);
	st64(mem, b + 8, STATE_ALLOCATED);
	mem.bytesInUse = mem.bytesInUse + bs;
	return b + BLOCK_HEADER_SIZE;
}

function blockState(mem: VmMemory, p: int64): int64 {
	if (p < BLOCK_HEADER_SIZE || (p & (BLOCK_ALIGN - 1)) != 0) return 0;
	const i = findRegion(mem, p - BLOCK_HEADER_SIZE);
	if (i < 0 || mem.regions[i].kind != RegionKind.Heap) return 0;
	return ld64(mem, p - 8);
}

export function isHeapBlock(mem: VmMemory, p: int64): boolean {
	return blockState(mem, p) == STATE_ALLOCATED;
}

export function isFreedBlock(mem: VmMemory, p: int64): boolean {
	return blockState(mem, p) == STATE_FREE;
}

export function blockSize(mem: VmMemory, p: int64): int64 {
	return ld64(mem, p - BLOCK_HEADER_SIZE);
}

export function heapDealloc(mem: VmMemory, p: int64): boolean {
	if (p == 0) return true;
	if (!isHeapBlock(mem, p)) return false;
	const b = p - BLOCK_HEADER_SIZE;
	const bs = ld64(mem, b);
	mem.bytesInUse = mem.bytesInUse - bs;
	const index = sizeClass(bs)[0] as int32;
	st64(mem, b + 8, STATE_FREE);
	st64(mem, p, mem.freeLists[index]);
	mem.freeLists[index] = b;
	return true;
}

export function auditHeap(mem: VmMemory): HeapAudit {
	const audit: HeapAudit = { allocated: 0, free: 0, bytes: 0 };
	for (const r of mem.regions) {
		if (r.kind != RegionKind.Heap) continue;
		let at = r.start;
		const end = r.start + r.used;
		while (at < end) {
			const bs = ld64(mem, at);
			const state = ld64(mem, at + 8);
			if (state == STATE_ALLOCATED) {
				audit.allocated += 1;
				audit.bytes = audit.bytes + bs;
			} else if (state == STATE_FREE) audit.free += 1;
			else throw new Error(`internal: heap block at address ${at} holds state ${state}`);
			at = at + BLOCK_HEADER_SIZE + bs;
		}
	}
	return audit;
}

function bumpAlloc(mem: VmMemory, area: BumpArea, size: int64, align: int64): int64 {
	const need = Math.max(size, 1);
	let pad = alignUp(area.cur, align) - area.cur;
	if (area.cur == 0 || area.left < pad + need) {
		const chunk = Math.max(BUMP_CHUNK_SIZE, alignUp(need, BLOCK_ALIGN));
		area.cur = hostGrow(mem, chunk);
		area.left = chunk;
		addRegion(mem, area.cur, chunk, area.kind);
		pad = 0;
	}
	const result = area.cur + pad;
	area.cur = result + need;
	area.left = area.left - pad - need;
	return result;
}

export function allocGlobal(mem: VmMemory, size: int64, align: int64): int64 {
	return bumpAlloc(mem, mem.globals, size, align);
}

export function allocConst(mem: VmMemory, size: int64, align: int64): int64 {
	return bumpAlloc(mem, mem.consts, size, align);
}

export function stackMark(mem: VmMemory): StackMark {
	return { seg: mem.sp.seg, used: mem.sp.used, boxes: mem.sp.boxes };
}

export function pushFrame(mem: VmMemory, size: int64): int64 {
	if (size > STACK_SEGMENT_SIZE) throw new Error(`internal: a frame of ${size} bytes exceeds the stack segment`);
	let seg = mem.sp.seg;
	let used = mem.sp.used;
	if (seg >= mem.stack.length || used + size > mem.stack[seg].cap) {
		if (seg < mem.stack.length) seg += 1;
		used = 0;
		if (seg >= mem.stack.length) {
			const base = hostGrow(mem, STACK_SEGMENT_SIZE);
			addRegion(mem, base, STACK_SEGMENT_SIZE, RegionKind.Stack);
			mem.stack.push({ base, cap: STACK_SEGMENT_SIZE, used: 0 });
		}
	}
	const frame = mem.stack[seg].base + used;
	zeroRange(mem, frame, size);
	mem.sp = { seg, used: used + size, boxes: mem.boxes.length };
	return frame;
}

export function popFrames(mem: VmMemory, mark: StackMark): void {
	while (mem.boxes.length > mark.boxes) heapDealloc(mem, mem.boxes.pop());
	mem.sp = mark;
}

export function allocBox(mem: VmMemory, size: int64): int64 {
	const block = heapAlloc(mem, Math.max(size, 1));
	mem.boxes.push(block);
	mem.sp.boxes = mem.boxes.length;
	return block;
}

export function refBlockOffset(align: int64): int64 {
	return alignUp(REF_HEADER_SIZE, Math.max(align, 1));
}

export function newCell(mem: VmMemory, size: int64, align: int64, typeIndex: int64): int64 {
	const offset = refBlockOffset(align);
	const total = offset + Math.max(size, 1);
	const cell = heapAlloc(mem, total) + offset;
	st64(mem, cell - REF_HEADER_SIZE + 8, typeIndex + 1);
	st64(mem, cell - REF_HEADER_SIZE + 16, (total * 4294967296) | 0xFFFFFFFF);
	return cell;
}

export function cellRc(mem: VmMemory, cell: int64): int64 {
	return ld64(mem, cell - REF_HEADER_SIZE);
}

export function setCellRc(mem: VmMemory, cell: int64, rc: int64): void {
	st64(mem, cell - REF_HEADER_SIZE, rc);
}

export function cellTypeIndex(mem: VmMemory, cell: int64): int64 {
	return ld64(mem, cell - REF_HEADER_SIZE + 8) - 1;
}

export function cellRootIdx(mem: VmMemory, cell: int64): int64 {
	return signExtend(ld64(mem, cell - REF_HEADER_SIZE + 16) & 0xFFFFFFFF, 4);
}

export function setCellRootIdx(mem: VmMemory, cell: int64, idx: int64): void {
	const w = cell - REF_HEADER_SIZE + 16;
	st64(mem, w, (ld64(mem, w) & ~laneMask(4)) | (idx & laneMask(4)));
}

export function cellAllocSize(mem: VmMemory, cell: int64): int64 {
	return (ld64(mem, cell - REF_HEADER_SIZE + 16) >> 32) & laneMask(4);
}

export function disposeCell(mem: VmMemory, cell: int64, align: int64): boolean {
	if (cell == 0) return true;
	return heapDealloc(mem, cell - refBlockOffset(align));
}

test "a mixed alloc and free sequence leaves allocated blocks equal to the live allocations, and freeing all leaves none" {
	const mem = createVmMemory();
	const sizes: int64[] = [1, 16, 17, 129, 300, 40000, 300000, 8, 5000, 64];
	const live: int64[] = [];
	for (const size of sizes) live.push(heapAlloc(mem, size));
	assert heapAlloc(mem, 0) == 0 && heapAlloc(mem, -4) == 0;
	for (const p of live) assert isHeapBlock(mem, p);
	assert heapDealloc(mem, live[1]) && heapDealloc(mem, live[6]) && heapDealloc(mem, live[3]);
	assert !heapDealloc(mem, live[1]) && isFreedBlock(mem, live[1]);
	live.push(heapAlloc(mem, 20));
	live.push(heapAlloc(mem, 250000));
	const audit = auditHeap(mem);
	const total = audit.allocated + audit.free;
	assert audit.allocated == 9 && audit.free == total - 9, `${audit.allocated} ${audit.free}`;
	for (let i = 0; i < live.length; i += 1) {
		if (i != 1 && i != 6 && i != 3) assert heapDealloc(mem, live[i]);
	}
	const drained = auditHeap(mem);
	assert drained.allocated == 0 && drained.free == total && drained.bytes == 0 && mem.bytesInUse == 0, `${drained.allocated} ${drained.free} ${mem.bytesInUse}`;
}

test "a freed block is reused by its size class and comes back zeroed, another class is not reused" {
	const mem = createVmMemory();
	const first = heapAlloc(mem, 20);
	st64(mem, first, 77);
	assert heapDealloc(mem, first);
	const other = heapAlloc(mem, 100);
	assert other != first;
	const again = heapAlloc(mem, 30);
	assert again == first && ld64(mem, again) == 0 && blockSize(mem, again) == 32;
	const big = heapAlloc(mem, 70000);
	assert blockSize(mem, big) == 131072;
	assert heapDealloc(mem, big);
	assert heapAlloc(mem, 100000) == big;
}

test "an access outside VM memory, across a region end or into constant memory is refused with a user-facing message" {
	const mem = createVmMemory();
	const cell = heapAlloc(mem, 64);
	const konst = allocConst(mem, 16, 8);
	const global = allocGlobal(mem, 8, 8);
	assert accessRefusal(mem, cell, 8, true) == "" && accessRefusal(mem, konst, 8, false) == "" && accessRefusal(mem, global, 8, true) == "";
	const outside = accessRefusal(mem, 8, 8, true);
	assert outside.includes("outside VM memory") && !outside.includes("internal:"), outside;
	assert accessRefusal(mem, 1, 8, false).includes("read of 8 bytes at address 1");
	const readOnly = accessRefusal(mem, konst, 8, true);
	assert readOnly.includes("read-only constant memory") && !readOnly.includes("internal:") && isConstMemory(mem, konst) && !isConstMemory(mem, cell), readOnly;
	const region = mem.regions[findRegion(mem, global)];
	assert !canWrite(mem, region.start + region.size - 4, 8) && canWrite(mem, region.start + region.size - 8, 8);
	assert canRead(mem, 123456789, 0);
}

test "popFrames restores the bump, frees the boxes of the popped frames and a new frame starts zeroed" {
	const mem = createVmMemory();
	const mark = stackMark(mem);
	const first = pushFrame(mem, 64);
	st64(mem, first + 8, 5);
	const second = pushFrame(mem, 128);
	assert second == first + 64;
	const box = allocBox(mem, 40);
	assert isHeapBlock(mem, box) && mem.sp.boxes == 1;
	popFrames(mem, mark);
	assert mem.sp.seg == mark.seg && mem.sp.used == mark.used && mem.sp.boxes == 0;
	assert !isHeapBlock(mem, box) && auditHeap(mem).allocated == 0;
	assert pushFrame(mem, 64) == first && ld64(mem, first + 8) == 0;
}

test "a frame that does not fit starts the next stack segment and popping returns to the first" {
	const mem = createVmMemory();
	const outer = pushFrame(mem, 64);
	const mark = stackMark(mem);
	pushFrame(mem, STACK_SEGMENT_SIZE - 64);
	const spill = pushFrame(mem, 64);
	assert mem.sp.seg == 1 && mem.stack.length == 2 && spill == mem.stack[1].base;
	assert accessRefusal(mem, spill, 64, true) == "" && accessRefusal(mem, outer, 64, true) == "";
	popFrames(mem, mark);
	assert mem.sp.seg == 0 && mem.sp.used == 64;
	assert pushFrame(mem, 64) == outer + 64;
}

test "typed loads and stores keep their lane, widen by sign, and leave their neighbours alone" {
	const mem = createVmMemory();
	const a = heapAlloc(mem, 32);
	memStore(mem, a, MemKind.I8, -2);
	memStore(mem, a + 1, MemKind.U8, 200);
	memStore(mem, a + 2, MemKind.I16, -300);
	memStore(mem, a + 4, MemKind.U32, 4000000000);
	assert memLoad(mem, a, MemKind.I8) == -2 && memLoad(mem, a, MemKind.U8) == 254 && memLoad(mem, a + 1, MemKind.U8) == 200 && memLoad(mem, a + 1, MemKind.I8) == -56;
	assert memLoad(mem, a + 2, MemKind.I16) == -300 && memLoad(mem, a + 2, MemKind.U16) == 65236;
	assert memLoad(mem, a + 4, MemKind.U32) == 4000000000 && memLoad(mem, a + 4, MemKind.I32) == -294967296;
	memStore(mem, a, MemKind.U8, 7);
	assert memLoad(mem, a, MemKind.U8) == 7 && memLoad(mem, a + 1, MemKind.U8) == 200 && memLoad(mem, a + 2, MemKind.I16) == -300;
	memStore(mem, a + 8, MemKind.I64, -9);
	memStore(mem, a + 16, MemKind.Ptr, a);
	stF64(mem, a + 24, 2.5);
	assert memLoad(mem, a + 8, MemKind.I64) == -9 && memLoad(mem, a + 16, MemKind.Ptr) == a && ldF64(mem, a + 24) == 2.5;
	let refused = "";
	try { memLoad(mem, a, MemKind.Block); } catch (e) { refused = e.message; }
	assert refused.includes("is not provided"), refused;
}

test "a ref cell carries the 24 byte header: count, type index, root index and allocation size ahead of the object" {
	const mem = createVmMemory();
	const cell = newCell(mem, 24, 8, 5);
	assert cell % 8 == 0 && isHeapBlock(mem, cell - refBlockOffset(8)) && refBlockOffset(8) == REF_HEADER_SIZE && refBlockOffset(16) == 32;
	assert cellRc(mem, cell) == 0 && cellTypeIndex(mem, cell) == 5 && cellRootIdx(mem, cell) == -1 && cellAllocSize(mem, cell) == 48;
	setCellRc(mem, cell, 32);
	setCellRootIdx(mem, cell, 9);
	assert cellRc(mem, cell) == 32 && cellRootIdx(mem, cell) == 9 && cellAllocSize(mem, cell) == 48 && cellTypeIndex(mem, cell) == 5;
	const untyped = newCell(mem, 8, 8, -1);
	assert cellTypeIndex(mem, untyped) == -1;
	st64(mem, cell, 11);
	assert disposeCell(mem, cell, 8) && !disposeCell(mem, cell, 8) && disposeCell(mem, untyped, 8) && disposeCell(mem, 0, 8);
	assert auditHeap(mem).allocated == 0;
}

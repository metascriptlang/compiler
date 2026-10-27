import { MemKind } from "./layout";

@include("stdlib.h")
@include("string.h")
@include("runtime/core/hashBits.h")
extern function msBitsFloat64(u: int64): float64;
extern function msFloat64Bits(d: float64): int64;
extern function calloc(count: uint64, size: uint64): Ptr<void>;
extern function free(p: Ptr<void>): void;
extern function memset(p: Ptr<void>, c: int32, n: uint64): Ptr<void>;
extern function memcpy(dst: Ptr<void>, src: Ptr<void>, n: uint64): Ptr<void>;
extern function memmove(dst: Ptr<void>, src: Ptr<void>, n: uint64): Ptr<void>;

class NativeBlock {
	address: int64;
	constructor(address: int64) { this.address = address; }
}

function onDestroy(this block: NativeBlock): void {
	free(block.address as Ptr<void>);
}

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
	blocks: NativeBlock[];
	regions: Region[];
	lastHit: int32;
	freeLists: int64[];
	heapCur: int64;
	heapLeft: int64;
	stack: StackSegment[];
	sp: StackMark;
	boxes: int64[];
	globals: BumpArea;
	consts: BumpArea;
	bytesInUse: int64;
	carved: int64;   // blocks cut fresh from a heap chunk, never taken from a free list; counted outside danger builds, so a test can bound the peak number of live blocks of a loop
	allocations: int64;   // blocks handed out since the heap was made; counted outside danger builds so a test can tell an in-place append from a copy per append
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
export const STATE_CELL: int64 = 0xCE11B10C;
export const REF_HEADER_SIZE: int64 = 24;

const LOW32: int64 = 0xFFFFFFFF;
const SMALL_CLASSES = 8;
const FIRST_LARGE_BLOCK: int64 = 256;

export function createVmMemory(): VmMemory {
	return {
		blocks: [], regions: [], lastHit: 0, freeLists: [], heapCur: 0, heapLeft: 0, stack: [],
		sp: { seg: 0, used: 0, boxes: 0 }, boxes: [],
		globals: { cur: 0, left: 0, kind: RegionKind.Globals }, consts: { cur: 0, left: 0, kind: RegionKind.Const }, bytesInUse: 0, carved: 0, allocations: 0,
	};
}

function alignUp(x: int64, a: int64): int64 {
	return (x + a - 1) & ~(a - 1);
}

function hostGrow(mem: VmMemory, size: int64): int64 {
	const address = calloc(1, size as uint64) as int64;
	if (address == 0) throw new Error(`internal: the host refused ${size} bytes of VM memory`);
	mem.blocks.push(new NativeBlock(address));
	return address;
}

function addRegion(mem: VmMemory, start: int64, size: int64, kind: RegionKind): int32 {
	mem.regions.push({ start, size, kind, used: 0 });
	let at = mem.regions.length - 1;
	while (at > 0 && mem.regions[at - 1].start > start) {
		const moved = mem.regions[at - 1];
		mem.regions[at - 1] = mem.regions[at];
		mem.regions[at] = moved;
		at -= 1;
	}
	mem.lastHit = at;
	return at;
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

@inline
function checkAligned(a: int64, width: int64): void {
	when (mode != "danger") {
		if (a == 0 || (a & (width - 1)) != 0) throw new Error(`internal: a ${width} byte access at address ${a} is not aligned`);
	}
}

@inline
export function ld64(a: int64): int64 {
	checkAligned(a, 8);
	return (a as Ptr<int64>)[0];
}

@inline
export function st64(a: int64, v: int64): void {
	checkAligned(a, 8);
	(a as Ptr<int64>)[0] = v;
}

function signExtend(v: int64, width: int64): int64 {
	const sign: int64 = width == 1 ? 0x80 : width == 2 ? 0x8000 : 0x80000000;
	return (v ^ sign) - sign;
}

export function memLoad(a: int64, kind: MemKind): int64 {
	if (kind == MemKind.F32 || kind == MemKind.Block) throw new Error(`internal: a typed load of kind ${kind as number} is not provided`);
	checkAligned(a, memKindWidth(kind));
	return match (kind) {
		MemKind.U8 => (a as Ptr<uint8>)[0] as int64,
		MemKind.U16 => (a as Ptr<uint16>)[0] as int64,
		MemKind.U32 => (a as Ptr<uint32>)[0] as int64,
		MemKind.I8 => (a as Ptr<int8>)[0] as int64,
		MemKind.I16 => (a as Ptr<int16>)[0] as int64,
		MemKind.I32 => (a as Ptr<int32>)[0] as int64,
		MemKind.I64 | MemKind.U64 | MemKind.Ptr | MemKind.F64 => (a as Ptr<int64>)[0],
		MemKind.F32 | MemKind.Block => 0,
	};
}

export function memStore(a: int64, kind: MemKind, v: int64): void {
	if (kind == MemKind.F32 || kind == MemKind.Block) throw new Error(`internal: a typed store of kind ${kind as number} is not provided`);
	checkAligned(a, memKindWidth(kind));
	match (kind) {
		MemKind.U8 | MemKind.I8 => { (a as Ptr<uint8>)[0] = (v & 0xFF) as uint8; },
		MemKind.U16 | MemKind.I16 => { (a as Ptr<uint16>)[0] = (v & 0xFFFF) as uint16; },
		MemKind.U32 | MemKind.I32 => { (a as Ptr<uint32>)[0] = (v & 0xFFFFFFFF) as uint32; },
		MemKind.I64 | MemKind.U64 | MemKind.Ptr | MemKind.F64 => { (a as Ptr<int64>)[0] = v; },
		MemKind.F32 | MemKind.Block => {},
	}
}

function memKindWidth(kind: MemKind): int64 {
	return match (kind) {
		MemKind.U8 | MemKind.I8 => 1,
		MemKind.U16 | MemKind.I16 => 2,
		MemKind.U32 | MemKind.I32 | MemKind.F32 => 4,
		_ => 8,
	};
}

export function ldF64(a: int64): float64 {
	return msBitsFloat64(ld64(a));
}

export function stF64(a: int64, v: float64): void {
	st64(a, msFloat64Bits(v));
}

@inline
export function ldByte(a: int64): int64 {
	return (a as Ptr<uint8>)[0] as int64;
}

@inline
export function stByte(a: int64, v: int64): void {
	(a as Ptr<uint8>)[0] = (v & 0xFF) as uint8;
}

@inline
export function copyBytes(dst: int64, src: int64, size: int64): void {
	if (size > 0) memmove(dst as Ptr<void>, src as Ptr<void>, size as uint64);
}

@inline
export function zeroRange(a: int64, size: int64): void {
	memset(a as Ptr<void>, 0, size as uint64);
}

function classBytes(size: int64): int64 {
	if (size <= 128) return Math.max(alignUp(size, 16), 16);
	let s = FIRST_LARGE_BLOCK;
	while (s < size) s = s * 2;
	return s;
}

function classIndex(bytes: int64): int32 {
	if (bytes <= 128) return (bytes / 16 - 1) as int32;
	let s = FIRST_LARGE_BLOCK;
	let c = SMALL_CLASSES;
	while (s < bytes) {
		s = s * 2;
		c += 1;
	}
	return c as int32;
}

function allocBlock(mem: VmMemory, size: int64, zeroed: boolean): int64 {
	if (size <= 0) return 0;
	const bs = classBytes(size);
	const index = classIndex(bs);
	while (mem.freeLists.length <= index) mem.freeLists.push(0);
	let b = mem.freeLists[index];
	if (b != 0) {
		mem.freeLists[index] = ld64(b + BLOCK_HEADER_SIZE);
		if (zeroed) zeroRange(b + BLOCK_HEADER_SIZE, bs);
	} else {
		const total = BLOCK_HEADER_SIZE + bs;
		if (mem.heapLeft < total) {
			const chunk = Math.max(HEAP_CHUNK_SIZE, total);
			mem.heapCur = hostGrow(mem, chunk);
			mem.heapLeft = chunk;
			addRegion(mem, mem.heapCur, chunk, RegionKind.Heap);
		}
		b = mem.heapCur;
		mem.heapCur = mem.heapCur + total;
		mem.heapLeft = mem.heapLeft - total;
		const region = mem.regions[findRegion(mem, b)];
		region.used = mem.heapCur - region.start;
		when (mode != "danger") { mem.carved += 1; }
	}
	st64(b, bs);
	st64(b + 8, STATE_ALLOCATED);
	mem.bytesInUse = mem.bytesInUse + bs;
	when (mode != "danger") { mem.allocations += 1; }
	return b + BLOCK_HEADER_SIZE;
}

export function heapAlloc(mem: VmMemory, size: int64): int64 {
	return allocBlock(mem, size, true);
}

export function heapAllocUninit(mem: VmMemory, size: int64): int64 {
	return allocBlock(mem, size, false);
}

function blockState(mem: VmMemory, p: int64): int64 {
	if (p < BLOCK_HEADER_SIZE || (p & (BLOCK_ALIGN - 1)) != 0) return 0;
	const i = findRegion(mem, p - BLOCK_HEADER_SIZE);
	if (i < 0 || mem.regions[i].kind != RegionKind.Heap) return 0;
	return ld64(p - 8);
}

export function isHeapBlock(mem: VmMemory, p: int64): boolean {
	const state = blockState(mem, p);
	return state == STATE_ALLOCATED || state == STATE_CELL;
}

export function isFreedBlock(mem: VmMemory, p: int64): boolean {
	return blockState(mem, p) == STATE_FREE;
}

export function blockSize(mem: VmMemory, p: int64): int64 {
	return ld64(p - BLOCK_HEADER_SIZE);
}

export function heapDealloc(mem: VmMemory, p: int64): boolean {
	if (p == 0) return true;
	if (!isHeapBlock(mem, p)) return false;
	const b = p - BLOCK_HEADER_SIZE;
	const bs = ld64(b);
	mem.bytesInUse = mem.bytesInUse - bs;
	const index = classIndex(bs);
	st64(b + 8, STATE_FREE);
	st64(p, mem.freeLists[index]);
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
			const bs = ld64(at);
			const state = ld64(at + 8);
			if (state == STATE_ALLOCATED || state == STATE_CELL) {
				audit.allocated += 1;
				audit.bytes = audit.bytes + bs;
			} else if (state == STATE_FREE) audit.free += 1;
			else throw new Error(`internal: heap block at address ${at} holds state ${state}`);
			at = at + BLOCK_HEADER_SIZE + bs;
		}
	}
	return audit;
}

export function liveCellBlocks(mem: VmMemory): int64[] {
	const found: int64[] = [];
	for (const r of mem.regions) {
		if (r.kind != RegionKind.Heap) continue;
		let at = r.start;
		const end = r.start + r.used;
		while (at < end) {
			if (ld64(at + 8) == STATE_CELL) found.push(at + BLOCK_HEADER_SIZE);
			at = at + BLOCK_HEADER_SIZE + ld64(at);
		}
	}
	return found;
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

// A frame stack for registers: one block that never moves, so the address of a slot stays valid for as long as the memory lives.
export function reserveSlots(mem: VmMemory, count: int64): int64 {
	const bytes = count * 8;
	const address = hostGrow(mem, bytes);
	addRegion(mem, address, bytes, RegionKind.Stack);
	return address;
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
	zeroRange(frame, size);
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

export function newCell(mem: VmMemory, size: int64, align: int64, typeIndex: int64, zeroed: boolean): int64 {
	const offset = refBlockOffset(align);
	const total = offset + Math.max(size, 1);
	const block = allocBlock(mem, total, zeroed);
	st64(block - 8, STATE_CELL);
	const cell = block + offset;
	st64(cell - REF_HEADER_SIZE + 8, typeIndex + 1);
	st64(cell - REF_HEADER_SIZE + 16, (total * 4294967296) | 0xFFFFFFFF);
	return cell;
}

@inline
export function isLiveCell(cell: int64): boolean {
	return ld64(cell - REF_HEADER_SIZE - 8) == STATE_CELL;
}

@inline
export function cellRc(cell: int64): int64 {
	return ld64(cell - REF_HEADER_SIZE);
}

@inline
export function setCellRc(cell: int64, rc: int64): void {
	st64(cell - REF_HEADER_SIZE, rc);
}

export function cellTypeIndex(cell: int64): int64 {
	return ld64(cell - REF_HEADER_SIZE + 8) - 1;
}

export function cellRootIdx(cell: int64): int64 {
	return signExtend(ld64(cell - REF_HEADER_SIZE + 16) & 0xFFFFFFFF, 4);
}

export function setCellRootIdx(cell: int64, idx: int64): void {
	const w = cell - REF_HEADER_SIZE + 16;
	st64(w, (ld64(w) & ~LOW32) | (idx & LOW32));
}

export function cellAllocSize(cell: int64): int64 {
	return (ld64(cell - REF_HEADER_SIZE + 16) >> 32) & LOW32;
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
	st64(first, 77);
	assert heapDealloc(mem, first);
	const other = heapAlloc(mem, 100);
	assert other != first;
	const again = heapAlloc(mem, 30);
	assert again == first && ld64(again) == 0 && blockSize(mem, again) == 32;
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
	st64(first + 8, 5);
	const second = pushFrame(mem, 128);
	assert second == first + 64;
	const box = allocBox(mem, 40);
	assert isHeapBlock(mem, box) && mem.sp.boxes == 1;
	popFrames(mem, mark);
	assert mem.sp.seg == mark.seg && mem.sp.used == mark.used && mem.sp.boxes == 0;
	assert !isHeapBlock(mem, box) && auditHeap(mem).allocated == 0;
	assert pushFrame(mem, 64) == first && ld64(first + 8) == 0;
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
	memStore(a, MemKind.I8, -2);
	memStore(a + 1, MemKind.U8, 200);
	memStore(a + 2, MemKind.I16, -300);
	memStore(a + 4, MemKind.U32, 4000000000);
	assert memLoad(a, MemKind.I8) == -2 && memLoad(a, MemKind.U8) == 254 && memLoad(a + 1, MemKind.U8) == 200 && memLoad(a + 1, MemKind.I8) == -56;
	assert memLoad(a + 2, MemKind.I16) == -300 && memLoad(a + 2, MemKind.U16) == 65236;
	assert memLoad(a + 4, MemKind.U32) == 4000000000 && memLoad(a + 4, MemKind.I32) == -294967296;
	memStore(a, MemKind.U8, 7);
	assert memLoad(a, MemKind.U8) == 7 && memLoad(a + 1, MemKind.U8) == 200 && memLoad(a + 2, MemKind.I16) == -300;
	memStore(a + 8, MemKind.I64, -9);
	memStore(a + 16, MemKind.Ptr, a);
	stF64(a + 24, 2.5);
	assert memLoad(a + 8, MemKind.I64) == -9 && memLoad(a + 16, MemKind.Ptr) == a && ldF64(a + 24) == 2.5;
	let refused = "";
	try { memLoad(a, MemKind.Block); } catch (e) { refused = e.message; }
	assert refused.includes("is not provided"), refused;
}

test "a ref cell carries the 24 byte header: count, type index, root index and allocation size ahead of the object" {
	const mem = createVmMemory();
	const cell = newCell(mem, 24, 8, 5, true);
	assert cell % 8 == 0 && isHeapBlock(mem, cell - refBlockOffset(8)) && refBlockOffset(8) == REF_HEADER_SIZE && refBlockOffset(16) == 32;
	assert cellRc(cell) == 0 && cellTypeIndex(cell) == 5 && cellRootIdx(cell) == -1 && cellAllocSize(cell) == 48;
	setCellRc(cell, 32);
	setCellRootIdx(cell, 9);
	assert cellRc(cell) == 32 && cellRootIdx(cell) == 9 && cellAllocSize(cell) == 48 && cellTypeIndex(cell) == 5;
	const untyped = newCell(mem, 8, 8, -1, true);
	assert cellTypeIndex(untyped) == -1;
	st64(cell, 11);
	assert disposeCell(mem, cell, 8) && !disposeCell(mem, cell, 8) && disposeCell(mem, untyped, 8) && disposeCell(mem, 0, 8);
	assert auditHeap(mem).allocated == 0;
}

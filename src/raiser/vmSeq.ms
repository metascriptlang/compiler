import { VmMemory, createVmMemory, heapAllocUninit, heapDealloc, newCell, disposeCell, setCellRc, setCellRootIdx, ld64, st64, copyBytes, zeroRange } from "./memory";
import { RaiserRegClass, ElemWidth } from "./bytecode";

@include("runtime/core/hashBits.h")
extern function msBitsFloat64(u: int64): float64;
extern function msFloat64Bits(d: float64): int64;

// A typed array cell: `{len, p, meta, base}` after the reference header. `p` is the payload `{cap, elements}`
// and `base` is the handle of the array a view stands on (0 for a plain array). A view's `p` points into its
// base's payload, so an element is read the same way from both.
export const SEQ_CELL_SIZE: int64 = 32;
export const SEQ_TYPE_INDEX: int64 = -2;

const PAYLOAD_DATA: int64 = 8;
const MIN_CAP: int64 = 4;
const CLASS_MASK: int64 = 7;
const WIDTH_SHIFT: int64 = 3;
const CYCLIC_BIT: int64 = 64;
const UNCOUNTED_BIT: int64 = 128;
const SHIFT_SHIFT: int64 = 8;

function widthShift(width: ElemWidth): int64 {
	return match (width) {
		ElemWidth.Wide => 3,
		ElemWidth.I32 | ElemWidth.U32 | ElemWidth.F32 => 2,
		ElemWidth.I16 | ElemWidth.U16 => 1,
		ElemWidth.I8 | ElemWidth.U8 => 0,
	};
}

export function seqNew(mem: VmMemory, cls: RaiserRegClass, width: ElemWidth, cyclic: boolean, uncounted: boolean, rc: int64): int64 {
	const cell = newCell(mem, SEQ_CELL_SIZE, 8, SEQ_TYPE_INDEX, true);
	setCellRc(cell, rc);
	setCellRootIdx(cell, 0);
	const meta: int64 = (cls as int64) | ((width as int64) << WIDTH_SHIFT) | (cyclic ? CYCLIC_BIT : 0) | (uncounted ? UNCOUNTED_BIT : 0) | (widthShift(width) << SHIFT_SHIFT);
	st64(cell + 16, meta);
	return cell;
}

@inline
export function seqLen(c: int64): number {
	return ld64(c) as number;
}

@inline
export function seqClass(c: int64): RaiserRegClass {
	return (ld64(c + 16) & CLASS_MASK) as RaiserRegClass;
}

export function seqWidth(c: int64): ElemWidth {
	return ((ld64(c + 16) >> WIDTH_SHIFT) & 7) as ElemWidth;
}

export function seqCyclic(c: int64): boolean {
	return (ld64(c + 16) & CYCLIC_BIT) != 0;
}

export function seqUncounted(c: int64): boolean {
	return (ld64(c + 16) & UNCOUNTED_BIT) != 0;
}

export function seqSetFlags(c: int64, cyclic: boolean, uncounted: boolean): void {
	st64(c + 16, (ld64(c + 16) & ~(CYCLIC_BIT | UNCOUNTED_BIT)) | (cyclic ? CYCLIC_BIT : 0) | (uncounted ? UNCOUNTED_BIT : 0));
}

@inline
export function seqBase(c: int64): int64 {
	return ld64(c + 24);
}

function narrowLoad(at: int64, width: ElemWidth): int64 {
	return match (width) {
		ElemWidth.I32 => (at as Ptr<int32>)[0] as int64,
		ElemWidth.I16 => (at as Ptr<int16>)[0] as int64,
		ElemWidth.I8 => (at as Ptr<int8>)[0] as int64,
		ElemWidth.U32 => (at as Ptr<uint32>)[0] as int64,
		ElemWidth.U16 => (at as Ptr<uint16>)[0] as int64,
		ElemWidth.U8 => (at as Ptr<uint8>)[0] as int64,
		ElemWidth.F32 => msFloat64Bits((at as Ptr<float32>)[0] as float64),
		ElemWidth.Wide => (at as Ptr<int64>)[0],
	};
}

function narrowStore(at: int64, width: ElemWidth, v: int64): void {
	match (width) {
		ElemWidth.I32 | ElemWidth.U32 => { (at as Ptr<uint32>)[0] = (v & 0xFFFFFFFF) as uint32; },
		ElemWidth.I16 | ElemWidth.U16 => { (at as Ptr<uint16>)[0] = (v & 0xFFFF) as uint16; },
		ElemWidth.I8 | ElemWidth.U8 => { (at as Ptr<uint8>)[0] = (v & 0xFF) as uint8; },
		ElemWidth.F32 => { (at as Ptr<float32>)[0] = msBitsFloat64(v) as float32; },
		ElemWidth.Wide => { (at as Ptr<int64>)[0] = v; },
	}
}

@inline
function elemAt(c: int64, meta: int64, i: number): int64 {
	return ld64(c + 8) + PAYLOAD_DATA + ((i as int64) << ((meta >> SHIFT_SHIFT) & 3));
}

// The element at `i` as the word its register class holds; the index is the caller's to have checked.
@inline
export function seqLoad(c: int64, i: number): int64 {
	const meta = ld64(c + 16);
	const at = elemAt(c, meta, i);
	const width = (meta >> WIDTH_SHIFT) & 7;
	if (width == 0) return ld64(at);
	return narrowLoad(at, width as ElemWidth);
}

@inline
export function seqStore(c: int64, i: number, v: int64): void {
	const meta = ld64(c + 16);
	const at = elemAt(c, meta, i);
	const width = (meta >> WIDTH_SHIFT) & 7;
	if (width == 0) {
		st64(at, v);
		return;
	}
	narrowStore(at, width as ElemWidth, v);
}

function reserve(mem: VmMemory, c: int64, newLen: int64): void {
	const p = ld64(c + 8);
	const cap = p == 0 ? 0 : ld64(p);
	if (newLen <= cap) return;
	const shift = (ld64(c + 16) >> SHIFT_SHIFT) & 3;
	const grown = Math.max(Math.max(newLen, MIN_CAP), cap * 3 / 2);
	const fresh = heapAllocUninit(mem, PAYLOAD_DATA + (grown << shift));
	st64(fresh, grown);
	if (p != 0) {
		copyBytes(fresh + PAYLOAD_DATA, p + PAYLOAD_DATA, ld64(c) << shift);
		heapDealloc(mem, p);
	}
	st64(c + 8, fresh);
}

export function seqPush(mem: VmMemory, c: int64, v: int64): void {
	const n = ld64(c);
	reserve(mem, c, n + 1);
	st64(c, n + 1);
	seqStore(c, n as number, v);
}

// Truncates, or extends with zeros (the zero of every element class is the all-zero word).
export function seqSetLen(mem: VmMemory, c: int64, n: int64): void {
	const len = ld64(c);
	if (n > len) {
		reserve(mem, c, n);
		const shift = (ld64(c + 16) >> SHIFT_SHIFT) & 3;
		const at = ld64(c + 8) + PAYLOAD_DATA + (len << shift);
		const bytes = (n - len) << shift;
		zeroRange(at, bytes);
	}
	st64(c, n);
}

export function seqRemove(c: int64, start: number, count: number): void {
	const len = ld64(c);
	const shift = (ld64(c + 16) >> SHIFT_SHIFT) & 3;
	const data = ld64(c + 8) + PAYLOAD_DATA;
	copyBytes(data + ((start as int64) << shift), data + (((start + count) as int64) << shift), (len - ((start + count) as int64)) << shift);
	st64(c, len - (count as int64));
}

export function seqInsert(mem: VmMemory, c: int64, index: number, v: int64): void {
	const len = ld64(c);
	reserve(mem, c, len + 1);
	const shift = (ld64(c + 16) >> SHIFT_SHIFT) & 3;
	const data = ld64(c + 8) + PAYLOAD_DATA;
	copyBytes(data + (((index + 1) as int64) << shift), data + ((index as int64) << shift), (len - (index as int64)) << shift);
	st64(c, len + 1);
	seqStore(c, index, v);
}

export function seqReverse(c: int64): void {
	let j = seqLen(c) - 1;
	for (let i = 0; i < j; i += 1) {
		const kept = seqLoad(c, i);
		seqStore(c, i, seqLoad(c, j));
		seqStore(c, j, kept);
		j -= 1;
	}
}

// A view over `len` elements of the plain array `base` from `off`.
export function seqNewView(mem: VmMemory, base: int64, baseHandle: int64, off: int64, len: int64, rc: int64): int64 {
	const meta = ld64(base + 16);
	const view = newCell(mem, SEQ_CELL_SIZE, 8, SEQ_TYPE_INDEX, true);
	setCellRc(view, rc);
	setCellRootIdx(view, 0);
	st64(view + 16, meta);
	st64(view, len);
	const p = ld64(base + 8);
	st64(view + 8, p == 0 ? 0 : p + (off << ((meta >> SHIFT_SHIFT) & 3)));
	st64(view + 24, baseHandle);
	return view;
}

// How many elements into its base's payload a view starts.
export function seqViewOffset(view: int64): int64 {
	const base = (ld64(view + 24) >> 3) << 3;
	const p = ld64(view + 8);
	return p == 0 ? 0 : (p - ld64(base + 8)) >> ((ld64(view + 16) >> SHIFT_SHIFT) & 3);
}

// Points a view at `off` elements into the payload its base has now.
export function seqPointViewInto(view: int64, off: int64): void {
	const base = (ld64(view + 24) >> 3) << 3;
	const p = ld64(base + 8);
	st64(view + 8, p == 0 ? 0 : p + (off << ((ld64(view + 16) >> SHIFT_SHIFT) & 3)));
}

export function seqSwapContents(a: int64, b: int64): void {
	for (let off = 0; off < SEQ_CELL_SIZE; off += 8) {
		const kept = ld64(a + off);
		st64(a + off, ld64(b + off));
		st64(b + off, kept);
	}
}

// Returns the cell and, for a plain array, its payload to the heap.
export function seqFree(mem: VmMemory, c: int64): void {
	const p = ld64(c + 8);
	if (ld64(c + 24) == 0 && p != 0) heapDealloc(mem, p);
	disposeCell(mem, c, 8);
}

test "a typed sequence stores each width, grows, removes, inserts and reverses" {
	const mem = createVmMemory();
	const a = seqNew(mem, RaiserRegClass.Word, ElemWidth.I32, false, false, 1);
	for (let i = 0; i < 100; i += 1) seqPush(mem, a, i * 3 - 50);
	assert seqLen(a) == 100 && seqLoad(a, 0) == -50 && seqLoad(a, 99) == 247;
	seqStore(a, 5, 4294967295 + 2);
	assert seqLoad(a, 5) == 1;
	seqRemove(a, 0, 10);
	assert seqLen(a) == 90 && seqLoad(a, 0) == -20 && seqLoad(a, 89) == 247;
	seqInsert(mem, a, 2, -7);
	assert seqLen(a) == 91 && seqLoad(a, 2) == -7 && seqLoad(a, 3) == -14;
	seqReverse(a);
	assert seqLoad(a, 0) == 247 && seqLoad(a, 90) == -20;
	seqSetLen(mem, a, 3);
	seqSetLen(mem, a, 6);
	assert seqLen(a) == 6 && seqLoad(a, 3) == 0 && seqLoad(a, 5) == 0;
	const u = seqNew(mem, RaiserRegClass.Word, ElemWidth.U8, false, false, 1);
	seqPush(mem, u, 300);
	seqPush(mem, u, -1);
	assert seqLoad(u, 0) == 44 && seqLoad(u, 1) == 255;
	const f = seqNew(mem, RaiserRegClass.Float, ElemWidth.F32, false, false, 1);
	seqPush(mem, f, msFloat64Bits(0.5));
	assert msBitsFloat64(seqLoad(f, 0)) == 0.5;
	const view = seqNewView(mem, a, 0, 1, 2, 1);
	assert seqLen(view) == 2 && seqLoad(view, 0) == seqLoad(a, 1);
}

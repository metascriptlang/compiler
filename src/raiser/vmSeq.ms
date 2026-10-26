import { VmMemory, createVmMemory, heapAlloc, heapAllocUninit, heapDealloc, ld64, st64, copyBytes } from "./memory";

const SEQ_VALUE_SIZE: int64 = 16;
const PAYLOAD_DATA: int64 = 8;
const WORD: int64 = 8;
const MIN_CAP: int64 = 4;

export class WordSeq {
	mem: VmMemory;
	head: int64;
	constructor(mem: VmMemory) {
		this.mem = mem;
		this.head = heapAlloc(mem, SEQ_VALUE_SIZE);
	}
}

@inline
export function wlen(this s: WordSeq): number {
	return ld64(s.head) as number;
}

@inline
function slotAt(s: WordSeq, i: number): int64 {
	const n = ld64(s.head) as number;
	if (i < 0 || i >= n) throw new Error(`internal: word sequence index ${i} outside its ${n} elements`);
	return ld64(s.head + 8) + PAYLOAD_DATA + (i as int64) * WORD;
}

@inline
export function watIn(this s: WordSeq, i: number): int64 {
	return ld64(ld64(s.head + 8) + PAYLOAD_DATA + (i as int64) * WORD);
}

@inline
export function wputIn(this s: WordSeq, i: number, v: int64): void {
	st64(ld64(s.head + 8) + PAYLOAD_DATA + (i as int64) * WORD, v);
}

@inline
export function wat(this s: WordSeq, i: number): int64 {
	return ld64(slotAt(s, i));
}

@inline
export function wput(this s: WordSeq, i: number, v: int64): void {
	st64(slotAt(s, i), v);
}

function reserve(s: WordSeq, newLen: int64): void {
	const p = ld64(s.head + 8);
	const cap = p == 0 ? 0 : ld64(p);
	if (newLen <= cap) return;
	const grown = Math.max(Math.max(newLen, MIN_CAP), cap * 3 / 2);
	const fresh = heapAllocUninit(s.mem, PAYLOAD_DATA + grown * WORD);
	st64(fresh, grown);
	if (p != 0) {
		copyBytes(fresh + PAYLOAD_DATA, p + PAYLOAD_DATA, ld64(s.head) * WORD);
		heapDealloc(s.mem, p);
	}
	st64(s.head + 8, fresh);
}

export function wpush(this s: WordSeq, v: int64): void {
	const n = ld64(s.head);
	reserve(s, n + 1);
	st64(ld64(s.head + 8) + PAYLOAD_DATA + n * WORD, v);
	st64(s.head, n + 1);
}

export function wshrink(this s: WordSeq, n: number): void {
	if (n < 0 || n > (ld64(s.head) as number)) throw new Error(`internal: word sequence shrunk to ${n} from ${ld64(s.head)}`);
	st64(s.head, n as int64);
}

export function wclear(this s: WordSeq): void {
	st64(s.head, 0);
}

test "word sequence grows, reads, shrinks and refuses an index outside it" {
	const mem = createVmMemory();
	const s = new WordSeq(mem);
	for (let i = 0; i < 100; i += 1) s.wpush(i * 3);
	assert s.wlen() == 100 && s.wat(99) == 297 && s.wat(0) == 0;
	s.wput(7, -5);
	assert s.wat(7) == -5;
	s.wshrink(10);
	assert s.wlen() == 10 && s.wat(9) == 27;
	s.wclear();
	assert s.wlen() == 0;
	let refused = false;
	try { s.wat(0); } catch (e) { refused = true; }
	assert refused;
}

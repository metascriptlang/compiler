import {
	VmMemory, createVmMemory, allocConst, heapAllocUninit, heapDealloc, newCell, disposeCell, cellRc, setCellRc, st64, ld64, ldByte, stByte, copyBytes, liveCellBlocks,
} from "./memory";

@include("runtime/core/vmString.h")
extern function msVmTextLength(addr: int64): int64;
extern function msVmTextCharCodeAt(addr: int64, idx: int64): int64;
extern function msVmTextEquals(a: int64, b: int64): int64;
extern function msVmTextCompare(a: int64, b: int64): int64;
extern function msVmTextSlice(addr: int64, start: int64, end: int64): string;
extern function msVmTextLoad(addr: int64): string;
extern function msVmTextStore(payloadData: int64, s: string): void;
extern function msVmTextTryAppend(dst: int64, src: int64): int64;

const STRLIT_FLAG: int64 = 4611686018427387904;
const CAP_FLAGS: int64 = 8070450532247928832;
const PAYLOAD_DATA = 8;
const STRING_VALUE_SIZE = 16;
const MIN_CAP: int64 = 4;

export const constMemory: VmMemory = createVmMemory();

function payloadBytes(cap: int64): int64 {
	return PAYLOAD_DATA + cap + 1;
}

function fillText(at: int64, payload: int64, len: int64, text: string, flags: int64): void {
	st64(at, len);
	st64(at + 8, payload);
	if (len == 0) return;
	st64(payload, len | flags);
	msVmTextStore(payload + PAYLOAD_DATA, text);
}

export function allocConstText(text: string): int64 {
	const len = text.byteLength as int64;
	const at = allocConst(constMemory, STRING_VALUE_SIZE, 8);
	fillText(at, len == 0 ? 0 : allocConst(constMemory, payloadBytes(len), 8), len, text, STRLIT_FLAG);
	return at;
}

export const EMPTY_TEXT: int64 = allocConstText("");

export function allocHeapText(mem: VmMemory, text: string, rc: int64): int64 {
	const len = text.byteLength as int64;
	const cell = newCell(mem, STRING_VALUE_SIZE, 8, -1, false);
	setCellRc(cell, rc);
	fillText(cell, len == 0 ? 0 : heapAllocUninit(mem, payloadBytes(len)), len, text, 0);
	return cell;
}

function isLiteralPayload(payload: int64): boolean {
	return (ld64(payload) & STRLIT_FLAG) != 0;
}

export function freeHeapText(mem: VmMemory, cell: int64): void {
	const payload = ld64(cell + 8);
	if (payload != 0 && !isLiteralPayload(payload)) heapDealloc(mem, payload);
	disposeCell(mem, cell, 8);
}

@inline
export function textRc(cell: int64): int64 {
	return cellRc(cell);
}

@inline
export function setTextRc(cell: int64, rc: int64): void {
	setCellRc(cell, rc);
}

@inline
export function textLoad(at: int64): string {
	return msVmTextLoad(at);
}

@inline
export function textByteLength(at: int64): int64 {
	return ld64(at);
}

@inline
export function textLength(at: int64): int64 {
	return msVmTextLength(at);
}

@inline
export function textEquals(a: int64, b: int64): boolean {
	return msVmTextEquals(a, b) != 0;
}

export function textLess(a: int64, b: int64): boolean {
	return msVmTextCompare(a, b) < 0;
}

export function textLessEq(a: int64, b: int64): boolean {
	return msVmTextCompare(a, b) <= 0;
}

export function textSlice(at: int64, start: int64, end: int64): string {
	return msVmTextSlice(at, start, end);
}

export function textCharCodeAt(at: int64, idx: int64): int64 {
	if (idx < 0) return -1;
	return msVmTextCharCodeAt(at, idx);
}

export function textByteAt(at: int64, idx: int64): int64 {
	if (idx < 0 || idx >= ld64(at)) return -1;
	return ldByte(ld64(at + 8) + PAYLOAD_DATA + idx);
}

export function textConcat(mem: VmMemory, a: int64, b: int64, rc: int64): int64 {
	const la = ld64(a);
	const lb = ld64(b);
	const cell = newCell(mem, STRING_VALUE_SIZE, 8, -1, false);
	setCellRc(cell, rc);
	st64(cell, la + lb);
	st64(cell + 8, 0);
	if (la + lb == 0) return cell;
	const payload = heapAllocUninit(mem, payloadBytes(la + lb));
	st64(payload, la + lb);
	copyBytes(payload + PAYLOAD_DATA, ld64(a + 8) + PAYLOAD_DATA, la);
	copyBytes(payload + PAYLOAD_DATA + la, ld64(b + 8) + PAYLOAD_DATA, lb);
	stByte(payload + PAYLOAD_DATA + la + lb, 0);
	st64(cell + 8, payload);
	return cell;
}

export function textAppend(mem: VmMemory, dst: int64, src: int64): void {
	if (msVmTextTryAppend(dst, src) != 0) return;
	const len = ld64(dst);
	const added = ld64(src);
	const newLen = len + added;
	const old = ld64(dst + 8);
	const reusable = old != 0 && !isLiteralPayload(old);
	let cap = Math.max(newLen, MIN_CAP);
	if (reusable) cap = Math.max(cap, ((ld64(old) & ~CAP_FLAGS) * 3) / 2);
	const payload = heapAllocUninit(mem, payloadBytes(cap));
	st64(payload, cap);
	if (len > 0) copyBytes(payload + PAYLOAD_DATA, old + PAYLOAD_DATA, len);
	copyBytes(payload + PAYLOAD_DATA + len, ld64(src + 8) + PAYLOAD_DATA, added);
	stByte(payload + PAYLOAD_DATA + newLen, 0);
	if (reusable) heapDealloc(mem, old);
	st64(dst + 8, payload);
	st64(dst, newLen);
}

test "a heap string stores its bytes in VM memory and the string runtime reads it in place" {
	const mem = createVmMemory();
	const s = allocHeapText(mem, "aé€😀", 1);
	assert textByteLength(s) == 10 && textLength(s) == 5 && textLoad(s) == "aé€😀" && textRc(s) == 1;
	assert textSlice(s, 1, 3) == "é€" && textCharCodeAt(s, 0) == 97 && textCharCodeAt(s, 9) == -1 && textByteAt(s, 1) == 195 && textByteAt(s, 10) == -1;
	const other = allocHeapText(mem, "aé€😁", 1);
	assert !textEquals(s, other) && textLess(s, other) && textLessEq(s, s) && textEquals(s, allocHeapText(mem, "aé€😀", 1));
	assert textLoad(EMPTY_TEXT) == "" && textLength(EMPTY_TEXT) == 0 && textLoad(allocConstText("kept")) == "kept";
}

test "an append stays in the payload while it fits, grows it by half and frees the old one, and a literal is copied first" {
	const mem = createVmMemory();
	const literal = allocConstText("ab");
	const dst = allocHeapText(mem, "x", 1);
	textAppend(mem, dst, literal);
	const first = ld64(dst + 8);
	assert textLoad(dst) == "xab" && ld64(first) == 4;
	const tail = allocHeapText(mem, "cdefgh", 1);
	textAppend(mem, dst, tail);
	const grown = ld64(dst + 8);
	assert textLoad(dst) == "xabcdefgh" && grown != first && ld64(grown) == 9;
	textAppend(mem, dst, EMPTY_TEXT);
	assert ld64(dst + 8) == grown;
	const fromLiteral = allocHeapText(mem, "", 1);
	textAppend(mem, fromLiteral, literal);
	assert textLoad(fromLiteral) == "ab" && textLoad(literal) == "ab" && ld64(fromLiteral + 8) != ld64(literal + 8);
	const joined = textConcat(mem, dst, literal, 1);
	assert textLoad(joined) == "xabcdefghab";
	freeHeapText(mem, dst);
	freeHeapText(mem, tail);
	freeHeapText(mem, fromLiteral);
	freeHeapText(mem, joined);
	assert liveCellBlocks(mem).length == 0;
}

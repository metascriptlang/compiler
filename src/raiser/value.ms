import { SEQ_TYPE_INDEX, seqNew, seqNewView, seqFree, seqLen, seqClass, seqWidth, seqCyclic, seqUncounted, seqSetFlags, seqBase, seqLoad, seqStore, seqPush, seqSetLen, seqRemove, seqInsert, seqReverse, seqViewOffset, seqPointViewInto } from "./vmSeq";
// Raiser VM — Value representation
// Day-1: flat tagged interface. No NaN-boxing.
// Bool stored as intVal (0/1) to keep the interface simple.

import { RaiserRegClass, ElemWidth, regClassLetter, TYPED_SLOTS } from "./bytecode";
import { VmMemory, createVmMemory, reserveSlots, st64, liveCellBlocks, refBlockOffset, ld64, ldByte, isHeapBlock, isConstMemory, cellRc, setCellRc, cellTypeIndex, disposeCell } from "./memory";
import { EMPTY_TEXT, constMemory, allocConstText, allocHeapText, freeHeapText, textRc, setTextRc, textLoad, textByteLength, textLength, textEquals, textLess, textLessEq, textSlice, textCharCodeAt, textByteAt, textConcat, textAppend } from "./vmString";

@include("runtime/core/hashBits.h");
extern function msBitsFloat64(u: int64): float64;
extern function msFloat64Bits(d: float64): int64;


// A kind from String up holds one heap handle in intVal; the kinds below it hold no reference.
export enum RaiserValueKind {
	Nil,
	Bool,
	Int,        // i64 integer
	Float,      // f64 float
	RegAddr,    // address of a register slot: intVal = the slot's address | its register class
	GlobalAddr, // address of a global: intVal = global index
	String,     // string value
	Array,      // handle into RaiserArrayHeap
	Object,     // handle into RaiserObjectHeap
	Future,     // handle into RaiserFutures — the VM's msFuture
	ElemAddr,   // address of an array element: intVal = array handle, floatVal = index
	FieldAddr,  // address of an object field: intVal = object handle, floatVal = field name constant handle
	Box,        // handle into RaiserArrayHeap.boxes: a dynamic value held by a Dyn register
}

// A heap reference is one word: (index << 3) | heapKind, and 0 is nil. The word names its own heap,
// so reference counting, a copy and a read dispatch on it without the value's kind.
export enum RaiserHeapKind {
	None,
	String,       // text on the running strand's string heap
	ConstString,  // text in the process-wide constant table
	Array,
	Object,
	Future,       // the VM-wide future table
	Box,
	Seq,          // a typed array: the address of its cell in the running strand's VM memory
}

const HEAP_KIND_BITS = 3;
const HEAP_KIND_MASK = 7;

export function bitsToFloat(w: int64): float64 {
	return msBitsFloat64(w);
}

export function makeHandle(index: int64, heapKind: RaiserHeapKind): int64 {
	return (index << HEAP_KIND_BITS) | (heapKind as int64);
}

export function handleIndex(handle: int64): int64 {
	return handle >> HEAP_KIND_BITS;
}

export function handleTag(handle: int64): int64 {
	return handle & HEAP_KIND_MASK;
}

export function handleHeapKind(handle: int64): RaiserHeapKind {
	return handleTag(handle) as RaiserHeapKind;
}

// The value kind a handle's heap kind implies; nil for the empty handle.
export function handleKind(handle: int64): RaiserValueKind {
	when (mode != "danger") { checkHeapKind(handle); }
	return match (handleHeapKind(handle)) {
		RaiserHeapKind.None => RaiserValueKind.Nil,
		RaiserHeapKind.String | RaiserHeapKind.ConstString => RaiserValueKind.String,
		RaiserHeapKind.Array => RaiserValueKind.Array,
		RaiserHeapKind.Seq => isObjectCell(handle) ? RaiserValueKind.Object : RaiserValueKind.Array,
		RaiserHeapKind.Object => RaiserValueKind.Object,
		RaiserHeapKind.Future => RaiserValueKind.Future,
		RaiserHeapKind.Box => RaiserValueKind.Box,
	};
}

function checkHeapKind(handle: int64): void {
	if (handleTag(handle) > (RaiserHeapKind.Seq as int64)) throw new Error(`internal: handle ${handle} names no heap kind`);
}

// The value a ref register's handle stands for.
export function handleValue(h: int64): RaiserValue {
	if (h == 0) return raiserNil();
	return { kind: handleKind(h), intVal: h, floatVal: 0.0 };
}

// A reference-holding value's kind must be the one its handle names; location values name the heap they point into.
export function handleAgrees(kind: RaiserValueKind, handle: int64): boolean {
	const tag = handleTag(handle);
	return match (kind) {
		RaiserValueKind.ElemAddr | RaiserValueKind.Array => tag == (RaiserHeapKind.Array as int64) || (tag == (RaiserHeapKind.Seq as int64) && !isObjectCell(handle)),
		RaiserValueKind.FieldAddr | RaiserValueKind.Object => tag == (RaiserHeapKind.Object as int64) || (tag == (RaiserHeapKind.Seq as int64) && isObjectCell(handle)),
		RaiserValueKind.String => tag == (RaiserHeapKind.String as int64) || tag == (RaiserHeapKind.ConstString as int64),
		RaiserValueKind.Future => tag == (RaiserHeapKind.Future as int64),
		RaiserValueKind.Box => tag == (RaiserHeapKind.Box as int64),
		RaiserValueKind.Nil => handle == 0,
		_ => true,
	};
}

// Flat interface — all fields always present, unused ones zeroed.
// Matches project convention (see checker/types.ms Type interface).
// A String's text lives on a string heap: a String handle indexes the running
// strand's heap, a ConstString handle names a constant (see "String Heap" below).
export struct RaiserValue {
	kind: RaiserValueKind;
	intVal: int64;
	floatVal: number;
}

// --- Constructors ---

export function raiserNil(): RaiserValue {
	return { kind: RaiserValueKind.Nil, intVal: 0, floatVal: 0.0 };
}

export function raiserBool(b: boolean): RaiserValue {
	let v = 0;
	if (b) { v = 1; }
	return { kind: RaiserValueKind.Bool, intVal: v, floatVal: 0.0 };
}

export function raiserInt(n: int64): RaiserValue {
	return { kind: RaiserValueKind.Int, intVal: n, floatVal: 0.0 };
}

export function raiserFloat(f: number): RaiserValue {
	return { kind: RaiserValueKind.Float, intVal: 0, floatVal: f };
}

// A constant string: interned once for the process, never freed, readable from any heap.
// Only code generation and module load call this, because the table never shrinks;
// every run-time string goes through heapAllocString.
export function raiserConstString(s: string): RaiserValue {
	return { kind: RaiserValueKind.String, intVal: constHandle(s), floatVal: 0.0 };
}

export function raiserArray(handle: int64): RaiserValue {
	return { kind: RaiserValueKind.Array, intVal: handle, floatVal: 0.0 };
}

export function raiserObject(handle: int64): RaiserValue {
	return { kind: RaiserValueKind.Object, intVal: handle, floatVal: 0.0 };
}

export function raiserFuture(handle: int64): RaiserValue {
	return { kind: RaiserValueKind.Future, intVal: handle, floatVal: 0.0 };
}

export function raiserRegAddr(slot: int64): RaiserValue {
	return { kind: RaiserValueKind.RegAddr, intVal: slot, floatVal: 0.0 };
}

export function raiserGlobalAddr(index: int64): RaiserValue {
	return { kind: RaiserValueKind.GlobalAddr, intVal: index, floatVal: 0.0 };
}

export function raiserElemAddr(handle: int64, index: int64): RaiserValue {
	return { kind: RaiserValueKind.ElemAddr, intVal: handle, floatVal: index as number };
}

// floatVal holds the field name's constant handle.
export function raiserFieldAddr(handle: int64, name: string): RaiserValue {
	return raiserFieldAddrAt(handle, constHandle(name));
}

export function raiserFieldAddrAt(handle: int64, nameHandle: int64): RaiserValue {
	return { kind: RaiserValueKind.FieldAddr, intVal: handle, floatVal: nameHandle as number };
}

export function fieldAddrName(v: RaiserValue): string {
	return constText(v.floatVal as int64);
}

export function kindFitsClass(kind: RaiserValueKind, cls: RaiserRegClass): boolean {
	return match (kind) {
		RaiserValueKind.Int => cls == RaiserRegClass.Word,
		RaiserValueKind.Float => cls == RaiserRegClass.Float,
		RaiserValueKind.Bool => cls == RaiserRegClass.Bool,
		RaiserValueKind.Nil => cls == RaiserRegClass.Ref || cls == RaiserRegClass.Dyn,
		RaiserValueKind.String | RaiserValueKind.Array | RaiserValueKind.Object | RaiserValueKind.Future => cls == RaiserRegClass.Ref,
		RaiserValueKind.Box => cls == RaiserRegClass.Dyn,
		RaiserValueKind.RegAddr | RaiserValueKind.GlobalAddr | RaiserValueKind.ElemAddr | RaiserValueKind.FieldAddr => false,
		_ => { throw new Error(`internal: value kind ${kind} has no register class`); },
	};
}

export function heldHandle(v: RaiserValue): RaiserValue {
	if (v.kind == RaiserValueKind.ElemAddr) return raiserArray(v.intVal);
	if (v.kind == RaiserValueKind.FieldAddr) return raiserObject(v.intVal);
	return v;
}

// --- String Heap ---
// A string is an msString value (len, payload) in VM memory, and its handle is the address of that value with the heap
// kind in the low bits. A run-time string is a counted cell on the strand's VmMemory; a constant sits in the
// process-wide constant segment, shared, append-only and never freed. Read-only operations run the string runtime on
// the stored value in place.

const constIndex: Map<string, int64> = new Map<string, int64>();
constIndex.set("", emptyTextHandle());

function constMemoryHandle(at: int64): int64 {
	return at | (RaiserHeapKind.ConstString as int64);
}

function heapTextHandle(at: int64): int64 {
	return at | (RaiserHeapKind.String as int64);
}

function textAddress(handle: int64): int64 {
	return handle - handleTag(handle);
}

function constHandle(text: string): int64 {
	if (constIndex.has(text)) return constIndex.get(text)!;
	const handle = constMemoryHandle(allocConstText(text));
	constIndex.set(text, handle);
	return handle;
}

export function constNameIds(names: string[]): int64[] {
	const ids: int64[] = [];
	for (const n of names) ids.push(constHandle(n));
	return ids;
}

function constText(handle: int64): string {
	return textLoad(textAddress(handle));
}

function isConstHandle(handle: int64): boolean {
	return handleHeapKind(handle) == RaiserHeapKind.ConstString;
}

function isTextHandle(handle: int64): boolean {
	const kind = handleHeapKind(handle);
	return kind == RaiserHeapKind.String || kind == RaiserHeapKind.ConstString;
}

// The stored value a handle names; a handle that names no string reads as the empty constant, like a non-String value.
function textOf(handle: int64): int64 {
	return isTextHandle(handle) ? textAddress(handle) : EMPTY_TEXT;
}

// The byte array a placed asBytes handed out for this string, or 0. A borrowed view in the C runtime, so
// the string holds the only count and frees the array with itself; the array stays when the text changes
// and is refilled by the next asBytes.
export function stringBytesHandle(arr: RaiserArrayHeap, str: RaiserValue): int64 {
	const held = arr.stringBytes.get(str.intVal);
	return held != null ? held : 0;
}

export function setStringBytesHandle(arr: RaiserArrayHeap, str: RaiserValue, bytes: int64): void {
	arr.stringBytes.set(str.intVal, bytes);
}

export function stringBytesHandles(arr: RaiserArrayHeap): int64[] {
	const held: int64[] = [];
	for (const h of arr.stringBytes.values()) if (h != 0) held.push(h);
	return held;
}

// Module constants and field names are interned, so reading one needs no heap.
export function constStringText(v: RaiserValue): string {
	if (v.kind != RaiserValueKind.String || !isConstHandle(v.intVal)) throw new Error("internal: a module constant must be an interned string");
	return constText(v.intVal);
}

export function constStringCount(): number {
	return constIndex.size;
}

export function emptyTextHandle(): int64 {
	return constMemoryHandle(EMPTY_TEXT);
}

export function heapAllocString(arr: RaiserArrayHeap, text: string): RaiserValue {
	if (text.byteLength == 0) return { kind: RaiserValueKind.String, intVal: emptyTextHandle(), floatVal: 0.0 };
	return { kind: RaiserValueKind.String, intVal: heapTextHandle(allocHeapText(arr.mem, text, OWNED_BY_RECEIVER_RC as int64)), floatVal: 0.0 };
}

// A string the host stores into a container it built: the container holds the first count.
export function heapAllocStoredString(arr: RaiserArrayHeap, text: string): RaiserValue {
	const v = heapAllocString(arr, text);
	if (!isConstHandle(v.intVal)) setTextRc(textAddress(v.intVal), 1);
	return v;
}

// A value that is not a String reads as "", the way an unset text field always did.
export function heapStringText(arr: RaiserArrayHeap, v: RaiserValue): string {
	if (v.kind != RaiserValueKind.String) return "";
	return textLoad(textOf(v.intVal));
}

// The operations below read a string where it lives and never hand its text out as an owned copy.

function textOfValue(v: RaiserValue): int64 {
	return v.kind == RaiserValueKind.String ? textOf(v.intVal) : EMPTY_TEXT;
}

export function heapStringEquals(arr: RaiserArrayHeap, a: RaiserValue, b: RaiserValue): boolean {
	if (a.intVal == b.intVal) return true;
	return textEquals(textOfValue(a), textOfValue(b));
}

export function heapStringLess(arr: RaiserArrayHeap, a: RaiserValue, b: RaiserValue): boolean {
	return textLess(textOfValue(a), textOfValue(b));
}

export function heapStringLessEq(arr: RaiserArrayHeap, a: RaiserValue, b: RaiserValue): boolean {
	return textLessEq(textOfValue(a), textOfValue(b));
}

export function heapStringLength(arr: RaiserArrayHeap, v: RaiserValue): int64 {
	return textLength(textOfValue(v));
}

export function heapStringByteLength(arr: RaiserArrayHeap, v: RaiserValue): int64 {
	return textByteLength(textOfValue(v));
}

export function heapStringSlice(arr: RaiserArrayHeap, v: RaiserValue, start: int32, end: int32): string {
	return textSlice(textOfValue(v), start, end);
}

function concatText(arr: RaiserArrayHeap, a: int64, b: int64): int64 {
	if (textByteLength(a) + textByteLength(b) == 0) return emptyTextHandle();
	return heapTextHandle(textConcat(arr.mem, a, b, OWNED_BY_RECEIVER_RC as int64));
}

export function heapConcat(arr: RaiserArrayHeap, a: RaiserValue, b: RaiserValue): RaiserValue {
	return { kind: RaiserValueKind.String, intVal: concatText(arr, textOfValue(a), textOfValue(b)), floatVal: 0.0 };
}

// Appends in place to a heap string; the caller has checked that the destination is
// held once and that the suffix is not the destination itself.
export function heapAppend(arr: RaiserArrayHeap, dst: int64, suffix: RaiserValue): void {
	textAppend(arr.mem, textAddress(dst), textOfValue(suffix));
}

export function heapStringHeldOnce(arr: RaiserArrayHeap, v: RaiserValue): boolean {
	return handleHeapKind(v.intVal) == RaiserHeapKind.String && textRc(textAddress(v.intVal)) == 1;
}

// The handle forms of the readers above, for an operand a typed Ref register holds: a handle that names no
// string reads as "" like a non-String value.
export function heapConcatHandles(arr: RaiserArrayHeap, a: int64, b: int64): int64 {
	return concatText(arr, textOf(a), textOf(b));
}

export function heapAppendHandle(arr: RaiserArrayHeap, dst: int64, suffix: int64): void {
	textAppend(arr.mem, textAddress(dst), textOf(suffix));
}

export function heapHandleHeldOnce(arr: RaiserArrayHeap, h: int64): boolean {
	return handleHeapKind(h) == RaiserHeapKind.String && textRc(textAddress(h)) == 1;
}

// -1 outside the text, the way msStringByteAt answers.
export function heapHandleCharCodeAt(arr: RaiserArrayHeap, h: int64, idx: int64): int64 {
	return textCharCodeAt(textOf(h), idx);
}

export function heapHandleByteAt(arr: RaiserArrayHeap, h: int64, idx: int64): int64 {
	return textByteAt(textOf(h), idx);
}

export function heapStringLive(arr: RaiserArrayHeap): number {
	return liveCellBlocks(arr.mem).length;
}

// The handle of every live string cell on the heap, for the ledger.
export function heapStringHandles(arr: RaiserArrayHeap): int64[] {
	const handles: int64[] = [];
	for (const block of liveCellBlocks(arr.mem)) {
		const cell = block + refBlockOffset(8);
		if (cellTypeIndex(cell) != SEQ_TYPE_INDEX) handles.push(heapTextHandle(cell));
	}
	return handles;
}

// The handle of every live typed array cell on the heap, for the ledger.
export function heapSeqHandles(arr: RaiserArrayHeap): int64[] {
	const handles: int64[] = [];
	for (const block of liveCellBlocks(arr.mem)) {
		const cell = block + refBlockOffset(8);
		if (cellTypeIndex(cell) == SEQ_TYPE_INDEX) handles.push(cell | (RaiserHeapKind.Seq as int64));
	}
	return handles;
}

export function stringHandleRc(handle: int64): int64 {
	return textRc(textAddress(handle));
}

// --- Accessors ---

export function raiserToInt(v: RaiserValue): number {
	return v.intVal as number;
}

export function raiserToFloat(v: RaiserValue): number {
	if (v.kind == RaiserValueKind.Float) return v.floatVal;
	return v.intVal as float64;
}

// A Dyn register holds a box; every generic operation reads its operand through the box.
export function readDyn(arr: RaiserArrayHeap, v: RaiserValue): RaiserValue {
	if (v.kind == RaiserValueKind.Box) return heapBoxValue(arr, v.intVal);
	return v;
}

export function raiserToBool(arr: RaiserArrayHeap, v: RaiserValue): boolean {
	return match (v.kind) {
		RaiserValueKind.Box => raiserToBool(arr, heapBoxValue(arr, v.intVal)),
		RaiserValueKind.Nil => false,
		RaiserValueKind.Bool | RaiserValueKind.Int => v.intVal != 0,
		RaiserValueKind.Float => v.floatVal != 0.0 && v.floatVal == v.floatVal,
		RaiserValueKind.String => heapStringLength(arr, v) > 0,
		RaiserValueKind.Array | RaiserValueKind.Object | RaiserValueKind.Future => true,
		RaiserValueKind.RegAddr | RaiserValueKind.GlobalAddr | RaiserValueKind.ElemAddr | RaiserValueKind.FieldAddr => true,
	};
}

export function raiserIsNil(v: RaiserValue): boolean {
	return v.kind == RaiserValueKind.Nil;
}

// --- Equality ---

export function raiserEqual(arr: RaiserArrayHeap, left: RaiserValue, right: RaiserValue): boolean {
	const a = readDyn(arr, left);
	const b = readDyn(arr, right);
	if (a.kind != b.kind) return false;
	return match (a.kind) {
		RaiserValueKind.Nil => true,
		RaiserValueKind.Bool | RaiserValueKind.Int | RaiserValueKind.Array | RaiserValueKind.Object => a.intVal == b.intVal,
		RaiserValueKind.Float => a.floatVal == b.floatVal,
		RaiserValueKind.String => heapStringEquals(arr, a, b),
		_ => false,
	};
}

// --- Debug ---

export function raiserToString(arr: RaiserArrayHeap, v: RaiserValue): string {
	return match (v.kind) {
		RaiserValueKind.Box => raiserToString(arr, heapBoxValue(arr, v.intVal)),
		RaiserValueKind.Nil => "null",
		RaiserValueKind.Bool => { if (v.intVal != 0) { return "true"; } else { return "false"; } },
		RaiserValueKind.Int => `${v.intVal}`,
		RaiserValueKind.Float => `${v.floatVal}`,
		RaiserValueKind.String => heapStringText(arr, v),
		RaiserValueKind.Array => "[array]",
		RaiserValueKind.Object => "[object]",
		_ => "?",
	};
}

// --- Tests ---
test "nil" {
	const v = raiserNil();
	assert v.kind == RaiserValueKind.Nil;
	assert raiserIsNil(v);
	assert !raiserToBool(createArrayHeap(), v);
}

test "bool true" {
	const v = raiserBool(true);
	assert v.kind == RaiserValueKind.Bool;
	assert v.intVal == 1;
	assert raiserToBool(createArrayHeap(), v);
}

test "bool false" {
	const v = raiserBool(false);
	assert v.kind == RaiserValueKind.Bool;
	assert v.intVal == 0;
	assert !raiserToBool(createArrayHeap(), v);
}

test "int" {
	const v = raiserInt(42);
	assert v.kind == RaiserValueKind.Int;
	assert raiserToInt(v) == 42;
	assert raiserToBool(createArrayHeap(), v);
}

test "int zero is falsy" {
	const v = raiserInt(0);
	assert !raiserToBool(createArrayHeap(), v);
}

test "float" {
	const v = raiserFloat(3.14);
	assert v.kind == RaiserValueKind.Float;
	assert v.floatVal == 3.14;
}

test "float NaN, 0 and -0 are falsy" {
	const zero = 0.0;
	assert !raiserToBool(createArrayHeap(), raiserFloat(zero / zero));
	assert !raiserToBool(createArrayHeap(), raiserFloat(zero));
	assert !raiserToBool(createArrayHeap(), raiserFloat(-zero));
	assert raiserToBool(createArrayHeap(), raiserFloat(0.5));
}

test "int to float conversion" {
	const v = raiserInt(5);
	assert raiserToFloat(v) == 5.0;
}

test "nil equals nil" { assert raiserEqual(createArrayHeap(), raiserNil(), raiserNil()); }

test "int equals same int" { assert raiserEqual(createArrayHeap(), raiserInt(42), raiserInt(42)); }

test "int not equals different int" { assert !raiserEqual(createArrayHeap(), raiserInt(1), raiserInt(2)); }

test "different kinds not equal" {
	assert !raiserEqual(createArrayHeap(), raiserInt(0), raiserNil());
	assert !raiserEqual(createArrayHeap(), raiserInt(1), raiserBool(true));
}

test "bool equality" {
	assert raiserEqual(createArrayHeap(), raiserBool(true), raiserBool(true));
	assert !raiserEqual(createArrayHeap(), raiserBool(true), raiserBool(false));
}

test "nil prints as null" { assert raiserToString(createArrayHeap(), raiserNil()) == "null"; }

test "true" { assert raiserToString(createArrayHeap(), raiserBool(true)) == "true"; }

test "false" { assert raiserToString(createArrayHeap(), raiserBool(false)) == "false"; }

test "int" { assert raiserToString(createArrayHeap(), raiserInt(42)) == "42"; }

test "array" { assert raiserToString(createArrayHeap(), raiserArray(0)) == "[array]"; }

// --- Array Heap ---
// An array of tagged values (Dyn) lives on a side heap and its handle is an index into it. Every other array is a
// typed cell in VM memory (vmSeq.ms): a Word, Float or Bool element as raw bits at the width its type has and a Ref
// element as its handle (0 is nil), and its handle is the address of the cell. Reference semantics (shared handle).
// A view holds only the array it stands on: as the one item of a Dyn view, as `base` of a typed one.
export interface RaiserArrayData {
	items: RaiserValue[];
	rc: int32;
	color: int32;
	viewOff: int64;
	viewLen: int32;
	views: int64[];   // a placed module's slice cells over this array: they stand for borrowed pointers, so they go when it does
	elemUncounted: boolean;   // the elements are borrowed (a cursor): destroy and copy never count them
	elemCyclic: boolean;   // the element type can reach the array again: a release that leaves the element alive registers it with the cycle collector
}

export interface RaiserArrayHeap {
	arrays: RaiserArrayData[];
	freeList: int64[];
	mem: VmMemory;
	stringBytes: HashMap<int64, int64>;
	seqViews: HashMap<int64, int64[]>;
	boxes: RaiserBoxHeap;
	orcRoots: int64[];
	orcThreshold: number;
}

export const ORC_DEFAULT_THRESHOLD = 128;

export const OWNED_BY_RECEIVER_RC: int32 = 1;

export function createArrayHeap(): RaiserArrayHeap {
	const arrays: RaiserArrayData[] = [];
	const freeList: int64[] = [];
	const orcRoots: int64[] = [];
	return { arrays, freeList, mem: createVmMemory(), stringBytes: new HashMap<int64, int64>(), seqViews: new HashMap<int64, int64[]>(), boxes: createBoxHeap(), orcRoots, orcThreshold: ORC_DEFAULT_THRESHOLD };
}

@inline
export function isSeqHandle(handle: int64): boolean {
	return (handle & HEAP_KIND_MASK) == (RaiserHeapKind.Seq as int64);
}

@inline
export function seqCellOf(handle: int64): int64 {
	return (handle >> HEAP_KIND_BITS) << HEAP_KIND_BITS;
}

// A Seq-tagged handle is a cell; an array cell carries SEQ_TYPE_INDEX in its header and an object cell its class's table index.
export function isObjectCell(handle: int64): boolean {
	return isSeqHandle(handle) && cellTypeIndex(seqCellOf(handle)) >= 0;
}

export function heapAllocArray(heap: RaiserArrayHeap): int64 {
	return dynAllocArray(heap);
}

function dynAllocArray(heap: RaiserArrayHeap): int64 {
	if (heap.freeList.length > 0) {
		const reused = heap.freeList[heap.freeList.length - 1];
		heap.freeList.length = heap.freeList.length - 1;
		const data = heap.arrays[reused];
		data.items.length = 0;
		data.rc = OWNED_BY_RECEIVER_RC;
		data.color = 0;
		data.viewOff = -1;
		data.viewLen = 0;
		data.views.length = 0;
		data.elemCyclic = false;
		data.elemUncounted = false;
		return makeHandle(reused, RaiserHeapKind.Array);
	}
	const idx = heap.arrays.length;
	const items: RaiserValue[] = [];
	const views: int64[] = [];
	const data: RaiserArrayData = { items, rc: OWNED_BY_RECEIVER_RC, color: 0, viewOff: -1, viewLen: 0, views, elemCyclic: false, elemUncounted: false };
	heap.arrays.push(data);
	return makeHandle(idx, RaiserHeapKind.Array);
}

export function heapAllocArrayOf(heap: RaiserArrayHeap, elemClass: RaiserRegClass, width: ElemWidth = ElemWidth.Wide): int64 {
	if (elemClass == RaiserRegClass.Dyn) return dynAllocArray(heap);
	const stored = elemClass == RaiserRegClass.Bool ? ElemWidth.U8 : elemClass == RaiserRegClass.Float ? (width == ElemWidth.F32 ? ElemWidth.F32 : ElemWidth.Wide) : elemClass == RaiserRegClass.Word && width != ElemWidth.F32 ? width : ElemWidth.Wide;
	return seqNew(heap.mem, elemClass, stored, false, false, OWNED_BY_RECEIVER_RC as int64) | (RaiserHeapKind.Seq as int64);
}

// A view (a slice) owns no elements: it stands on the plain array it views, which it keeps alive through RC, the
// collector and copyGraph.
export function heapAllocView(heap: RaiserArrayHeap, base: RaiserValue, off: int64, len: int32): int64 {
	if (isSeqHandle(base.intVal)) {
		const view = seqNewView(heap.mem, seqCellOf(base.intVal), base.intVal, off, len as int64, OWNED_BY_RECEIVER_RC as int64) | (RaiserHeapKind.Seq as int64);
		const held = heap.seqViews.get(base.intVal);
		if (held == null) {
			const list: int64[] = [view];
			heap.seqViews.set(base.intVal, list);
		} else {
			held.push(view);
		}
		return view;
	}
	const handle = dynAllocArray(heap);
	heapArrayPush(heap, handle, base);
	heap.arrays[handleIndex(handle)].viewOff = off;
	heap.arrays[handleIndex(handle)].viewLen = len;
	heap.arrays[handleIndex(base.intVal)].views.push(handle);
	return handle;
}

export function heapArrayIsView(heap: RaiserArrayHeap, handle: int64): boolean {
	if (isSeqHandle(handle)) return seqBase(seqCellOf(handle)) != 0;
	return heap.arrays[handleIndex(handle)].viewOff >= 0;
}

// The array a view stands on, or the array itself.
export function arrayBaseOf(heap: RaiserArrayHeap, handle: int64): int64 {
	if (isSeqHandle(handle)) {
		const base = seqBase(seqCellOf(handle));
		return base != 0 ? base : handle;
	}
	const data = heap.arrays[handleIndex(handle)];
	return data.viewOff >= 0 ? data.items[0].intVal : handle;
}

export function heapArrayClass(heap: RaiserArrayHeap, handle: int64): RaiserRegClass {
	return isSeqHandle(handle) ? seqClass(seqCellOf(handle)) : RaiserRegClass.Dyn;
}

export function heapArrayCyclic(heap: RaiserArrayHeap, handle: int64): boolean {
	const base = arrayBaseOf(heap, handle);
	return isSeqHandle(base) ? seqCyclic(seqCellOf(base)) : heap.arrays[handleIndex(base)].elemCyclic;
}

export function heapArrayUncounted(heap: RaiserArrayHeap, handle: int64): boolean {
	const base = arrayBaseOf(heap, handle);
	return isSeqHandle(base) ? seqUncounted(seqCellOf(base)) : heap.arrays[handleIndex(base)].elemUncounted;
}

// A new empty array in `dst` of the element class, width and flags of the array `source` (or the one it stands on) in `src`.
export function heapAllocArrayLike(dst: RaiserArrayHeap, src: RaiserArrayHeap, source: int64): int64 {
	const base = arrayBaseOf(src, source);
	let handle: int64 = 0;
	if (isSeqHandle(base)) {
		handle = heapAllocArrayOf(dst, seqClass(seqCellOf(base)), seqWidth(seqCellOf(base)));
	} else {
		handle = dynAllocArray(dst);
	}
	heapArraySetFlags(dst, handle, heapArrayCyclic(src, base), heapArrayUncounted(src, base));
	return handle;
}

export function heapArrayRc(heap: RaiserArrayHeap, handle: int64): int32 {
	return isSeqHandle(handle) ? cellRc(seqCellOf(handle)) as int32 : heap.arrays[handleIndex(handle)].rc;
}

export function heapArraySetRc(heap: RaiserArrayHeap, handle: int64, rc: int32): void {
	if (isSeqHandle(handle)) {
		setCellRc(seqCellOf(handle), rc as int64);
		return;
	}
	heap.arrays[handleIndex(handle)].rc = rc;
}

export function heapArraySetFlags(heap: RaiserArrayHeap, handle: int64, cyclic: boolean, uncounted: boolean): void {
	if (isSeqHandle(handle)) {
		seqSetFlags(seqCellOf(handle), cyclic, uncounted);
		return;
	}
	heap.arrays[handleIndex(handle)].elemCyclic = cyclic;
	heap.arrays[handleIndex(handle)].elemUncounted = uncounted;
}

// The number of values the array holds: its elements, or the one array a Dyn view stands on.
export function arrayHeldCount(heap: RaiserArrayHeap, handle: int64): number {
	return isSeqHandle(handle) ? seqLen(seqCellOf(handle)) : heap.arrays[handleIndex(handle)].items.length;
}

// Whether any held value can be a heap reference.
export function arrayHoldsHandles(heap: RaiserArrayHeap, handle: int64): boolean {
	if (isSeqHandle(handle)) {
		const c = seqCellOf(handle);
		return !seqUncounted(c) && seqClass(c) == RaiserRegClass.Ref;
	}
	return !heap.arrays[handleIndex(handle)].elemUncounted;
}

function heldFromWord(cls: RaiserRegClass, w: int64): RaiserValue {
	if (cls == RaiserRegClass.Word) return raiserInt(w);
	if (cls == RaiserRegClass.Float) return raiserFloat(msBitsFloat64(w));
	if (cls == RaiserRegClass.Bool) return raiserBool(w != 0);
	if (cls == RaiserRegClass.Ref) return handleValue(w);
	throw new Error("internal: a typed array cell holds no tagged value");
}

// The value held at `index`, read in the array's element class.
export function arrayHeldAt(heap: RaiserArrayHeap, handle: int64, index: number): RaiserValue {
	if (isSeqHandle(handle)) {
		const c = seqCellOf(handle);
		when (mode != "danger") { if (index < 0 || index >= seqLen(c)) throw new Error(`internal: array index ${index} outside its ${seqLen(c)} elements`); }
		return heldFromWord(seqClass(c), seqLoad(c, index));
	}
	return heap.arrays[handleIndex(handle)].items[index];
}

// "" when the array can hold the value, otherwise why it cannot. A view holds what the array it stands on does.
export function arrayRefusal(heap: RaiserArrayHeap, handle: int64, val: RaiserValue): string {
	const base = arrayBaseOf(heap, handle);
	if (!isSeqHandle(base)) return "";
	const cls = seqClass(seqCellOf(base));
	if (slotFits(cls, val)) return "";
	return `internal: an array of ${regClassLetter(cls)} elements got a value of kind ${val.kind}`;
}

// Stores a value at `index` without counting: the array takes over the caller's count of it.
export function arrayHeldStore(heap: RaiserArrayHeap, handle: int64, index: number, val: RaiserValue): void {
	if (!isSeqHandle(handle)) {
		heap.arrays[handleIndex(handle)].items[index] = val;
		return;
	}
	const c = seqCellOf(handle);
	const refused = arrayRefusal(heap, handle, val);
	if (refused != "") throw new Error(refused);
	when (mode != "danger") { if (index < 0 || index >= seqLen(c)) throw new Error(`internal: array index ${index} outside its ${seqLen(c)} elements`); }
	seqStore(c, index, slotWord(seqClass(c), val));
}

function heldCopy(val: RaiserValue): RaiserValue {
	const copy: RaiserValue = { kind: val.kind, intVal: val.intVal, floatVal: val.floatVal };
	return copy;
}

function heldSwap(heap: RaiserArrayHeap, handle: int64, i: number, j: number): void {
	if (isSeqHandle(handle)) {
		const c = seqCellOf(handle);
		const kept = seqLoad(c, i);
		seqStore(c, i, seqLoad(c, j));
		seqStore(c, j, kept);
		return;
	}
	const items = heap.arrays[handleIndex(handle)].items;
	const kept = heldCopy(items[i]);
	items[i] = heldCopy(items[j]);
	items[j] = kept;
}

// Removes `count` held values from `start` without counting: the caller reads and releases them first.
export function arrayHeldRemove(heap: RaiserArrayHeap, handle: int64, start: number, count: number): void {
	if (isSeqHandle(handle)) {
		seqRemove(seqCellOf(handle), start, count);
		return;
	}
	const items = heap.arrays[handleIndex(handle)].items;
	const n = items.length;
	for (let i = start; i + count < n; i += 1) items[i] = heldCopy(items[i + count]);
	items.shrink((n - count) as int64);
}

// Inserts a value at `index` without counting: the array takes over the caller's count of it.
export function arrayHeldInsert(heap: RaiserArrayHeap, handle: int64, index: number, val: RaiserValue): void {
	if (isSeqHandle(handle)) {
		const refused = arrayRefusal(heap, handle, val);
		if (refused != "") throw new Error(refused);
		const c = seqCellOf(handle);
		seqInsert(heap.mem, c, index, slotWord(seqClass(c), val));
		return;
	}
	arrayHeldPush(heap, handle, val);
	for (let i = arrayHeldCount(heap, handle) - 1; i > index; i -= 1) heldSwap(heap, handle, i, i - 1);
}

export function arrayHeldReverse(heap: RaiserArrayHeap, handle: int64): void {
	if (isSeqHandle(handle)) {
		seqReverse(seqCellOf(handle));
		return;
	}
	let j = arrayHeldCount(heap, handle) - 1;
	for (let i = 0; i < j; i += 1) {
		heldSwap(heap, handle, i, j);
		j -= 1;
	}
}

function heldLess(heap: RaiserArrayHeap, cls: RaiserRegClass, x: int64, y: int64): boolean {
	if (cls == RaiserRegClass.Float) return msBitsFloat64(x) < msBitsFloat64(y);
	if (cls == RaiserRegClass.Ref) return heapStringLess(heap, handleValue(x), handleValue(y));
	return x < y;
}

// Sorts the held values in place, stable: numbers by value (a NaN compares equal to everything, as the C kernel's
// comparator does) and strings by bytes. "" on success, otherwise why the array cannot be sorted.
export function arrayHeldSort(heap: RaiserArrayHeap, handle: int64): string {
	if (!isSeqHandle(handle)) return "internal: sort of an array of tagged values";
	const c = seqCellOf(handle);
	const cls = seqClass(c);
	const n = seqLen(c);
	if (cls == RaiserRegClass.Ref) {
		for (let i = 0; i < n; i += 1) {
			if (!isStringHandleTag(handleTag(seqLoad(c, i)))) return "internal: sort of an array whose element is no string";
		}
	}
	const from: int64[] = [];
	const to: int64[] = [];
	for (let i = 0; i < n; i += 1) {
		from.push(seqLoad(c, i));
		to.push(0);
	}
	let width = 1;
	while (width < n) {
		let lo = 0;
		while (lo < n) {
			const mid = lo + width < n ? lo + width : n;
			const hi = lo + 2 * width < n ? lo + 2 * width : n;
			let i = lo;
			let j = mid;
			let k = lo;
			while (i < mid && j < hi) {
				if (heldLess(heap, cls, from[j], from[i])) {
					to[k] = from[j];
					j += 1;
				} else {
					to[k] = from[i];
					i += 1;
				}
				k += 1;
			}
			while (i < mid) {
				to[k] = from[i];
				i += 1;
				k += 1;
			}
			while (j < hi) {
				to[k] = from[j];
				j += 1;
				k += 1;
			}
			lo += 2 * width;
		}
		for (let i = 0; i < n; i += 1) from[i] = to[i];
		width *= 2;
	}
	for (let i = 0; i < n; i += 1) seqStore(c, i, from[i]);
	return "";
}

function isStringHandleTag(tag: int64): boolean {
	return tag == (RaiserHeapKind.String as int64) || tag == (RaiserHeapKind.ConstString as int64);
}

function arrayHeldPush(heap: RaiserArrayHeap, handle: int64, val: RaiserValue): void {
	if (!isSeqHandle(handle)) {
		const copy: RaiserValue = { kind: val.kind, intVal: val.intVal, floatVal: val.floatVal };
		heap.arrays[handleIndex(handle)].items.push(copy);
		return;
	}
	const refused = arrayRefusal(heap, handle, val);
	if (refused != "") throw new Error(refused);
	const c = seqCellOf(handle);
	seqPush(heap.mem, c, slotWord(seqClass(c), val));
}

export function heapArrayLen(heap: RaiserArrayHeap, handle: int64): int32 {
	if (isSeqHandle(handle)) return seqLen(seqCellOf(handle)) as int32;
	const data = heap.arrays[handleIndex(handle)];
	return data.viewOff >= 0 ? data.viewLen : data.items.length as int32;
}

export function heapArrayGet(heap: RaiserArrayHeap, handle: int64, index: int64): RaiserValue {
	if (isSeqHandle(handle)) return arrayHeldAt(heap, handle, index as number);
	const data = heap.arrays[handleIndex(handle)];
	if (data.viewOff >= 0) return heap.arrays[handleIndex(data.items[0].intVal)].items[(data.viewOff + index) as number];
	return data.items[index as number];
}

export function heapArraySet(heap: RaiserArrayHeap, handle: int64, index: int64, val: RaiserValue): void {
	if (isSeqHandle(handle)) {
		arrayHeldStore(heap, handle, index as number, val);
		return;
	}
	const data = heap.arrays[handleIndex(handle)];
	if (data.viewOff >= 0) {
		arrayHeldStore(heap, data.items[0].intVal, (data.viewOff + index) as number, val);
		return;
	}
	arrayHeldStore(heap, handle, index as number, val);
}

export function heapArrayPush(heap: RaiserArrayHeap, handle: int64, val: RaiserValue): void {
	arrayHeldPush(heap, handle, val);
}

// The only shrink primitive on the heap: truncate drops references (arena
// regime — no per-value RC), extend pads with the zero of the element class.
export function heapArraySetLen(heap: RaiserArrayHeap, handle: int64, newLen: int64): void {
	const target = newLen < 0 ? 0 : newLen;
	if (isSeqHandle(handle)) {
		seqSetLen(heap.mem, seqCellOf(handle), target);
		return;
	}
	const data = heap.arrays[handleIndex(handle)];
	if (newLen < data.items.length) {
		data.items.shrink(target);
	} else {
		while (data.items.length < newLen) {
			const nilCopy: RaiserValue = { kind: RaiserValueKind.Nil, intVal: 0, floatVal: 0.0 };
			data.items.push(nilCopy);
		}
	}
}

// --- Array Heap Tests ---
test "alloc empty array" {
	const heap = createArrayHeap();
	const h = heapAllocArray(heap);
	assert handleIndex(h) == 0;
	assert heapArrayLen(heap, h) == 0;
}

test "push and get" {
	const heap = createArrayHeap();
	const h = heapAllocArray(heap);
	const v1 = raiserInt(10);
	const v2 = raiserInt(20);
	heapArrayPush(heap, h, v1);
	heapArrayPush(heap, h, v2);
	assert heapArrayLen(heap, h) == 2;
	assert heapArrayGet(heap, h, 0).intVal == 10;
	assert heapArrayGet(heap, h, 1).intVal == 20;
}

test "set element" {
	const heap = createArrayHeap();
	const h = heapAllocArray(heap);
	const v0 = raiserInt(0);
	heapArrayPush(heap, h, v0);
	const v42 = raiserInt(42);
	heapArraySet(heap, h, 0, v42);
	assert heapArrayGet(heap, h, 0).intVal == 42;
}

test "multiple arrays independent" {
	const heap = createArrayHeap();
	const h1 = heapAllocArray(heap);
	const h2 = heapAllocArray(heap);
	const v1 = raiserInt(1);
	const v2 = raiserInt(2);
	heapArrayPush(heap, h1, v1);
	heapArrayPush(heap, h2, v2);
	assert heapArrayGet(heap, h1, 0).intVal == 1;
	assert heapArrayGet(heap, h2, 0).intVal == 2;
}

test "array value kind" {
	const v = raiserArray(3);
	assert v.kind == RaiserValueKind.Array;
	assert v.intVal == 3;
	assert raiserToBool(createArrayHeap(), v);
}

// --- Box Heap ---
// A box holds one dynamic value for a Dyn register. It is immutable once made, so any
// number of registers can share it; under orc its count is the number of holders.

export interface RaiserBoxData {
	value: RaiserValue;
	rc: int32;
}

export interface RaiserBoxHeap {
	items: RaiserBoxData[];
	freeList: int64[];
}

export function createBoxHeap(): RaiserBoxHeap {
	const items: RaiserBoxData[] = [];
	const freeList: int64[] = [];
	return { items, freeList };
}

// The box holds the value's reference; the caller counts it where the heaps are counted.
export function heapAllocBox(heap: RaiserArrayHeap, value: RaiserValue): int64 {
	const boxes = heap.boxes;
	const copy: RaiserValue = { kind: value.kind, intVal: value.intVal, floatVal: value.floatVal };
	if (boxes.freeList.length > 0) {
		const reused = boxes.freeList[boxes.freeList.length - 1];
		boxes.freeList.length = boxes.freeList.length - 1;
		boxes.items[reused].value = copy;
		boxes.items[reused].rc = OWNED_BY_RECEIVER_RC;
		return makeHandle(reused, RaiserHeapKind.Box);
	}
	const index = boxes.items.length;
	boxes.items.push({ value: copy, rc: OWNED_BY_RECEIVER_RC });
	return makeHandle(index, RaiserHeapKind.Box);
}

export function heapBoxValue(heap: RaiserArrayHeap, handle: int64): RaiserValue {
	return heap.boxes.items[handleIndex(handle)].value;
}

export function heapBoxLive(heap: RaiserArrayHeap): number {
	return heap.boxes.items.length - heap.boxes.freeList.length;
}

// --- Object Heap ---
// Objects live on a side heap like arrays. A slot inside the class layout is named by the
// class and holds one word in its register class: a Word, Float or Bool slot its raw bits, a
// Ref slot its handle (0 is nil), a Dyn slot the index of its value in `values`. A field added
// past the layout carries its name on the object and its value in `values`, after the Dyn slots'.
// Linear scan for field lookup (fast for typical <20 field objects).

export interface RaiserClassType {
	name: string;
	depth: int32;       // the number of ancestors; -1 for a layout that is no class
	display: int64[];   // the ids of the class and its ancestors, indexed by depth, so display[depth] is the class's own
	fields: string[];   // the layout NewObject lays out, so a field sits at the slot its type gives it
	fieldIds: int64[];   // constNameIds(fields): the interned handle of each field name, so a cached field read compares integers
	kinds: RaiserRegClass[];
	zeroSlots: int64[];   // the slots of a fresh object: zero bits, a nil handle, the index of each Dyn slot's value in order
	zeroWordSlots: int64;
	zeroRefSlots: int64;
	dynCount: int32;   // the nil values a fresh object holds, one per Dyn slot
	cyclic: boolean[];   // per slot: the slot's type can reach the object again, so a release that leaves its referent alive registers it with the cycle collector
	uncounted: boolean[];   // per slot: the slot borrows its referent (a cursor), so a destroy or copy of the object never counts it
	destroyFn: int32;   // function index of the lifted destroy routine of the type, -1 when the VM destroys its cells by walking them
}

// A class type with its zero object computed once, so NewObject copies it instead of laying out each slot.
export function createClassType(name: string, depth: int32, display: int64[], fields: string[], kinds: RaiserRegClass[]): RaiserClassType {
	const zeroSlots: int64[] = [];
	let zeroWordSlots: int64 = 0;
	let zeroRefSlots: int64 = 0;
	let dynCount: int32 = 0;
	const cyclic: boolean[] = [];
	const uncounted: boolean[] = [];
	for (let i = 0; i < fields.length; i += 1) {
		cyclic.push(false);
		uncounted.push(false);
		const cls = kinds[i];
		const bit: int64 = i < TYPED_SLOTS ? (1 as int64) << (i as int64) : 0;
		if (cls == RaiserRegClass.Word) zeroWordSlots = zeroWordSlots | bit;
		if (cls == RaiserRegClass.Ref) zeroRefSlots = zeroRefSlots | bit;
		if (cls == RaiserRegClass.Dyn) {
			zeroSlots.push(dynCount as int64);
			dynCount += 1;
		} else {
			zeroSlots.push(0);
		}
	}
	return { name, depth, display, fields, fieldIds: constNameIds(fields), kinds, zeroSlots, zeroWordSlots, zeroRefSlots, dynCount, cyclic, uncounted, destroyFn: -1 };
}

export const OBJECT_CELL_SLOT_BYTES: int64 = 8;

const classTypes: RaiserClassType[] = [];
const registeredClassTypes: Map<string, int32> = new Map<string, int32>();

// The table index of a class type, adding it on first use. Two types of one name and one field layout share an index.
export function classTypeIndex(t: RaiserClassType): int32 {
	const key = `${t.name}/${t.depth}/${t.fields.join(",")}`;
	if (registeredClassTypes.has(key)) return registeredClassTypes.get(key)!;
	const index = classTypes.length as int32;
	classTypes.push(t);
	registeredClassTypes.set(key, index);
	return index;
}

export function classTypeAt(index: int64): RaiserClassType {
	if (index < 0 || index >= classTypes.length) throw new Error(`internal: type index ${index} is not in the type table`);
	return classTypes[index as number];
}

export const RAISER_NO_CLASS: RaiserClassType = createClassType("", -1, [], [], []);

export interface RaiserObjectData {
	slots: int64[];
	wordSlots: int64;   // bit i set when slot i (below TYPED_SLOTS) is a Word slot, so a typed slot opcode checks its slot in one load
	refSlots: int64;    // the same for Ref slots
	values: RaiserValue[];
	added: string[];   // the names of the fields past the layout, in insertion order
	rc: int32;
	color: int32;
	classType: RaiserClassType;
}

// Whether a class is, or extends, the one a module constant names: the constant packs the target's
// id and depth (id * 64 + depth), and an ancestor at the target's depth must carry its id.
export function raiserIsInstance(classType: RaiserClassType, key: RaiserValue): boolean {
	when (mode != "danger") { if (key.kind != RaiserValueKind.Int) throw new Error("internal: a class key must be a packed class id"); }
	const depth = (key.intVal & 63) as int32;
	return depth <= classType.depth && classType.display[depth] == (key.intVal >> 6);
}

export interface RaiserObjectHeap {
	objects: RaiserObjectData[];
	freeList: int64[];
}

export function createStructHeap(): RaiserObjectHeap {
	const objects: RaiserObjectData[] = [];
	const freeList: int64[] = [];
	return { objects, freeList };
}

export function heapAllocObject(heap: RaiserObjectHeap): int64 {
	if (heap.freeList.length > 0) {
		const reused = heap.freeList[heap.freeList.length - 1];
		heap.freeList.length = heap.freeList.length - 1;
		const data: Cursor<RaiserObjectData> = heap.objects[reused];
		data.slots.length = 0;
		data.wordSlots = 0;
		data.refSlots = 0;
		data.values.length = 0;
		data.added.length = 0;
		data.rc = OWNED_BY_RECEIVER_RC;
		data.color = 0;
		data.classType = RAISER_NO_CLASS;
		return makeHandle(reused, RaiserHeapKind.Object);
	}
	const idx = heap.objects.length;
	const slots: int64[] = [];
	const values: RaiserValue[] = [];
	const added: string[] = [];
	const data: RaiserObjectData = { slots, wordSlots: 0, refSlots: 0, values, added, rc: OWNED_BY_RECEIVER_RC, color: 0, classType: RAISER_NO_CLASS };
	heap.objects.push(data);
	return makeHandle(idx, RaiserHeapKind.Object);
}

function laySlot(obj: RaiserObjectData): void {
	const cls = obj.classType.kinds[obj.slots.length];
	const bit: int64 = obj.slots.length < TYPED_SLOTS ? (1 as int64) << (obj.slots.length as int64) : 0;
	if (cls == RaiserRegClass.Word) obj.wordSlots = obj.wordSlots | bit;
	if (cls == RaiserRegClass.Ref) obj.refSlots = obj.refSlots | bit;
	if (cls == RaiserRegClass.Dyn) {
		obj.slots.push(obj.values.length as int64);
		obj.values.push(raiserNil());
	} else {
		obj.slots.push(0);
	}
}

// Every slot of the object's class at its zero: zero bits, a nil handle, a nil value.
export function layOutObject(obj: RaiserObjectData, classType: RaiserClassType): void {
	obj.classType = classType;
	const count = classType.zeroSlots.length;
	obj.slots.length = count;
	obj.wordSlots = classType.zeroWordSlots;
	obj.refSlots = classType.zeroRefSlots;
	if (classType.dynCount > 0) {
		for (let i = 0; i < count; i += 1) obj.slots[i] = classType.zeroSlots[i];
		for (let i: int32 = 0; i < classType.dynCount; i += 1) obj.values.push(raiserNil());
	}
}

// The register class slot `index` holds, which must be laid.
@inline
export function slotKind(obj: RaiserObjectData, index: int32): RaiserRegClass {
	return obj.classType.kinds[index];
}

export function objectFieldCount(obj: RaiserObjectData): int32 {
	return (obj.slots.length + obj.added.length) as int32;
}

export function heapObjectFieldCount(heap: RaiserObjectHeap, handle: int64): int32 {
	if (isObjectCell(handle)) return objectCellClass(handle).fields.length as int32;
	return objectFieldCount(heap.objects[handleIndex(handle)]);
}

export function objectCellClass(handle: int64): RaiserClassType {
	return classTypeAt(cellTypeIndex(seqCellOf(handle)));
}

// The class type of an object handle, whichever heap holds it.
export function heapObjectClass(heap: RaiserObjectHeap, handle: int64): RaiserClassType {
	return isObjectCell(handle) ? objectCellClass(handle) : heap.objects[handleIndex(handle)].classType;
}

// The value of laid slot `index` of an object cell, read in its slot's class.
export function objectCellFieldValue(handle: int64, index: number): RaiserValue {
	const bits = ld64(seqCellOf(handle) + (index as int64) * OBJECT_CELL_SLOT_BYTES);
	return match (objectCellClass(handle).kinds[index]) {
		RaiserRegClass.Word => raiserInt(bits),
		RaiserRegClass.Float => raiserFloat(msBitsFloat64(bits)),
		RaiserRegClass.Bool => raiserBool(bits != 0),
		RaiserRegClass.Ref => handleValue(bits),
		RaiserRegClass.Dyn => raiserNil(),
	};
}

// Stores a value into laid slot `index` of an object cell without counting it: the slot takes over the caller's count.
export function objectCellStoreField(handle: int64, index: number, val: RaiserValue): void {
	const t = objectCellClass(handle);
	const cls = t.kinds[index];
	if (!slotFits(cls, val)) throw new Error(`internal: field '${t.fields[index]}' of ${t.name} is a ${regClassLetter(cls)} slot, got a value of kind ${val.kind}`);
	st64(seqCellOf(handle) + (index as int64) * OBJECT_CELL_SLOT_BYTES, slotWord(cls, val));
}

// "" when field `index` of the object can hold the value, otherwise why it cannot.
export function heapObjectFieldRefusal(heap: RaiserObjectHeap, handle: int64, index: number, val: RaiserValue): string {
	if (!isObjectCell(handle)) return fieldRefusal(heap.objects[handleIndex(handle)], index, val);
	const t = objectCellClass(handle);
	const cls = t.kinds[index];
	if (slotFits(cls, val)) return "";
	return `internal: field '${t.fields[index]}' of ${t.name} is a ${regClassLetter(cls)} slot, got a value of kind ${val.kind}`;
}

// The position of the field called `name`, -1 when the object has none.
export function heapObjectFieldIndex(heap: RaiserObjectHeap, handle: int64, name: string): number {
	if (isObjectCell(handle)) return objectCellClass(handle).fields.indexOf(name);
	return fieldIndex(heap.objects[handleIndex(handle)], name);
}

// Stores a value into field `index` without counting it: the field takes over the caller's count.
export function heapObjectStoreFieldAt(heap: RaiserObjectHeap, handle: int64, index: number, val: RaiserValue): void {
	if (isObjectCell(handle)) objectCellStoreField(handle, index, val);
	else fieldStoreAt(heap.objects[handleIndex(handle)], index, val);
}

export function heapObjectAppendField(heap: RaiserObjectHeap, handle: int64, name: string, val: RaiserValue): void {
	if (isObjectCell(handle)) throw new Error(`internal: ${objectCellClass(handle).name} has no field '${name}' and a laid object takes none past its layout`);
	appendField(heap.objects[handleIndex(handle)], name, val);
}

export function fieldNameAt(obj: RaiserObjectData, index: number): string {
	const laid = obj.slots.length;
	return index < laid ? obj.classType.fields[index] : obj.added[index - laid];
}

export function fieldNameIs(obj: RaiserObjectData, index: number, name: string): boolean {
	const laid = obj.slots.length;
	return index < laid ? obj.classType.fields[index] == name : obj.added[index - laid] == name;
}

export function fieldIndex(obj: RaiserObjectData, name: string): number {
	const count = objectFieldCount(obj);
	for (let i = 0; i < count; i += 1) {
		if (fieldNameIs(obj, i, name)) return i;
	}
	return -1;
}

// The value a field holds, read in its slot's class.
export function fieldValueAt(obj: RaiserObjectData, index: number): RaiserValue {
	const laid = obj.slots.length;
	if (index >= laid) return obj.values[obj.values.length - obj.added.length + index - laid];
	const bits = obj.slots[index];
	return match (obj.classType.kinds[index]) {
		RaiserRegClass.Word => raiserInt(bits),
		RaiserRegClass.Float => raiserFloat(msBitsFloat64(bits)),
		RaiserRegClass.Bool => raiserBool(bits != 0),
		RaiserRegClass.Ref => handleValue(bits),
		RaiserRegClass.Dyn => obj.values[bits],
	};
}

// Whether a value fits a slot of class `cls`; an Int widens into a Float slot as it does into a Float register.
export function slotFits(cls: RaiserRegClass, val: RaiserValue): boolean {
	if (cls == RaiserRegClass.Float) return val.kind == RaiserValueKind.Float || val.kind == RaiserValueKind.Int;
	if (cls == RaiserRegClass.Dyn) return true;
	return kindFitsClass(val.kind, cls);
}

// The word a slot of class `cls` holds for a value that fits it.
export function slotWord(cls: RaiserRegClass, val: RaiserValue): int64 {
	if (cls == RaiserRegClass.Float) return val.kind == RaiserValueKind.Int ? msFloat64Bits(val.intVal as number) : msFloat64Bits(val.floatVal);
	return val.kind == RaiserValueKind.Nil ? 0 : val.intVal;
}

// "" when field `index` can hold the value, otherwise why it cannot.
export function fieldRefusal(obj: RaiserObjectData, index: number, val: RaiserValue): string {
	if (index >= obj.slots.length) return "";
	const cls = obj.classType.kinds[index];
	if (slotFits(cls, val)) return "";
	return `internal: field '${obj.classType.fields[index]}' of ${obj.classType.name != "" ? obj.classType.name : "a typed object"} is a ${regClassLetter(cls)} slot, got a value of kind ${val.kind}`;
}

// Stores a value into a field without counting: the field takes over the caller's count of it.
export function fieldStoreAt(obj: RaiserObjectData, index: number, val: RaiserValue): void {
	const laid = obj.slots.length;
	if (index >= laid) {
		obj.values[obj.values.length - obj.added.length + index - laid] = val;
		return;
	}
	const cls = obj.classType.kinds[index];
	if (cls == RaiserRegClass.Dyn) {
		obj.values[obj.slots[index]] = val;
		return;
	}
	const refused = fieldRefusal(obj, index, val);
	if (refused != "") throw new Error(refused);
	obj.slots[index] = slotWord(cls, val);
}

export function appendField(obj: RaiserObjectData, name: string, val: RaiserValue): void {
	if (obj.slots.length < obj.classType.fields.length) {
		laySlot(obj);
		fieldStoreAt(obj, obj.slots.length - 1, val);
		return;
	}
	obj.added.push(name);
	obj.values.push(val);
}

export function heapObjectFieldNameAt(heap: RaiserObjectHeap, handle: int64, index: int64): string {
	if (isObjectCell(handle)) {
		const fields = objectCellClass(handle).fields;
		return index < 0 || index >= fields.length ? "" : fields[index as number];
	}
	const obj = heap.objects[handleIndex(handle)];
	if (index < 0 || index >= objectFieldCount(obj)) return "";
	return fieldNameAt(obj, index as number);
}

test "heapObjectFieldNameAt/ValueAt follow insertion order" {
	const heap = createStructHeap();
	const h = heapAllocObject(heap);
	heapObjectSetField(heap, h, "kind", raiserInt(5));
	heapObjectSetField(heap, h, "left", raiserConstString("L"));
	assert heapObjectFieldNameAt(heap, h, 0) == "kind";
	assert heapObjectFieldNameAt(heap, h, 1) == "left";
	assert heapStringText(createArrayHeap(), heapObjectFieldValueAt(heap, h, 1)) == "L";
	assert heapObjectFieldNameAt(heap, h, 2) == "";
	assert heapObjectFieldValueAt(heap, h, 9).kind == RaiserValueKind.Nil;
}

export function heapObjectFieldValueAt(heap: RaiserObjectHeap, handle: int64, index: int64): RaiserValue {
	if (isObjectCell(handle)) {
		if (index < 0 || index >= objectCellClass(handle).fields.length) return raiserNil();
		return objectCellFieldValue(handle, index as number);
	}
	const obj = heap.objects[handleIndex(handle)];
	if (index < 0 || index >= objectFieldCount(obj)) return { kind: RaiserValueKind.Nil, intVal: 0, floatVal: 0.0 };
	return fieldValueAt(obj, index as number);
}

export function heapObjectGetField(heap: RaiserObjectHeap, handle: int64, name: string): RaiserValue {
	if (isObjectCell(handle)) {
		const at = objectCellClass(handle).fields.indexOf(name);
		return at >= 0 ? objectCellFieldValue(handle, at) : raiserNil();
	}
	const obj = heap.objects[handleIndex(handle)];
	const i = fieldIndex(obj, name);
	return i >= 0 ? fieldValueAt(obj, i) : raiserNil();
}

export function heapObjectSetField(heap: RaiserObjectHeap, handle: int64, name: string, val: RaiserValue): void {
	if (isObjectCell(handle)) {
		const at = objectCellClass(handle).fields.indexOf(name);
		if (at < 0) throw new Error(`internal: ${objectCellClass(handle).name} has no field '${name}' and a laid object takes none past its layout`);
		objectCellStoreField(handle, at, val);
		return;
	}
	const obj = heap.objects[handleIndex(handle)];
	const i = fieldIndex(obj, name);
	if (i >= 0) fieldStoreAt(obj, i, val);
	else appendField(obj, name, val);
}

// --- ORC refcount primitives ---
// A handle names its heap, so the counters dispatch on it alone; a handle can hold
// cross-heap children, so both heaps are threaded through. Destroy is generic (the
// heap object is self-describing). Only a kind from String up holds a handle.

export function rcIncref(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, held: RaiserValue): void {
	if (held.kind >= RaiserValueKind.String) rcIncrefHandle(arrHeap, objHeap, held.intVal);
}

export function rcDecref(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, held: RaiserValue): void {
	if (held.kind >= RaiserValueKind.String) rcDecrefHandle(arrHeap, objHeap, held.intVal);
}

export function rcIncrefHandle(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, handle: int64): void {
	when (mode != "danger") { checkHeapKind(handle); }
	const index = handleIndex(handle);
	match (handleHeapKind(handle)) {
		RaiserHeapKind.Array => { const data: Cursor<RaiserArrayData> = arrHeap.arrays[index]; data.rc += 1; },
		RaiserHeapKind.Object => { const data: Cursor<RaiserObjectData> = objHeap.objects[index]; data.rc += 1; },
		RaiserHeapKind.String => { const cell = textAddress(handle); setTextRc(cell, textRc(cell) + 1); },
		RaiserHeapKind.Box => { const data: Cursor<RaiserBoxData> = arrHeap.boxes.items[index]; data.rc += 1; },
		RaiserHeapKind.Seq => { const cell = seqCellOf(handle); setCellRc(cell, cellRc(cell) + 1); },
		RaiserHeapKind.None | RaiserHeapKind.ConstString | RaiserHeapKind.Future => {},
	}
}

export function rcDecrefHandle(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, handle: int64): void {
	when (mode != "danger") { checkHeapKind(handle); }
	const index = handleIndex(handle);
	match (handleHeapKind(handle)) {
		RaiserHeapKind.Array => {
			const data: Cursor<RaiserArrayData> = arrHeap.arrays[index];
			data.rc = data.rc - 1;
			if (data.rc <= 0) { rcDestroyArray(arrHeap, objHeap, index); }
		},
		RaiserHeapKind.Object => {
			const data: Cursor<RaiserObjectData> = objHeap.objects[index];
			data.rc = data.rc - 1;
			if (data.rc <= 0) { rcDestroyObject(arrHeap, objHeap, index); }
		},
		RaiserHeapKind.String => {
			const cell = textAddress(handle);
			const left = textRc(cell) - 1;
			setTextRc(cell, left);
			if (left <= 0) { rcDestroyString(arrHeap, handle); }
		},
		RaiserHeapKind.Box => {
			const data: Cursor<RaiserBoxData> = arrHeap.boxes.items[index];
			data.rc = data.rc - 1;
			if (data.rc <= 0) { rcDestroyBox(arrHeap, objHeap, index); }
		},
		RaiserHeapKind.Seq => {
			const cell = seqCellOf(handle);
			const left = cellRc(cell) - 1;
			setCellRc(cell, left);
			if (left <= 0) { rcDestroySeq(arrHeap, objHeap, handle); }
		},
		RaiserHeapKind.None | RaiserHeapKind.ConstString | RaiserHeapKind.Future => {},
	}
}

// The decrement of a counted handle that reports whether it was the last holder, leaving the destroying to the caller;
// a nil, constant or future handle is never last.
export function rcDecIsLast(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, handle: int64): boolean {
	if (handle == 0) return false;
	when (mode != "danger") { checkHeapKind(handle); }
	const index = handleIndex(handle);
	let last = false;
	match (handleHeapKind(handle)) {
		RaiserHeapKind.Array => { const data: Cursor<RaiserArrayData> = arrHeap.arrays[index]; data.rc = data.rc - 1; last = data.rc <= 0; },
		RaiserHeapKind.Object => { const data: Cursor<RaiserObjectData> = objHeap.objects[index]; data.rc = data.rc - 1; last = data.rc <= 0; },
		RaiserHeapKind.String => { const cell = textAddress(handle); setTextRc(cell, textRc(cell) - 1); last = textRc(cell) <= 0; },
		RaiserHeapKind.Box => { const data: Cursor<RaiserBoxData> = arrHeap.boxes.items[index]; data.rc = data.rc - 1; last = data.rc <= 0; },
		RaiserHeapKind.Seq => { const cell = seqCellOf(handle); setCellRc(cell, cellRc(cell) - 1); last = cellRc(cell) <= 0; },
		RaiserHeapKind.None | RaiserHeapKind.ConstString | RaiserHeapKind.Future => {},
	}
	return last;
}

// The count a cell holds: 0 for nil and for handles that are not counted.
export function rcCountOf(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, handle: int64): int32 {
	if (handle == 0) return 0;
	const index = handleIndex(handle);
	let count: int32 = 0;
	match (handleHeapKind(handle)) {
		RaiserHeapKind.Array => { count = arrHeap.arrays[index].rc; },
		RaiserHeapKind.Object => { count = objHeap.objects[index].rc; },
		RaiserHeapKind.String => { count = textRc(textAddress(handle)) as int32; },
		RaiserHeapKind.Box => { count = arrHeap.boxes.items[index].rc; },
		RaiserHeapKind.Seq => { count = cellRc(seqCellOf(handle)) as int32; },
		RaiserHeapKind.None | RaiserHeapKind.ConstString | RaiserHeapKind.Future => {},
	}
	return count;
}

// Returns a cell's storage to its heap without touching what it held: the caller has released the contents.
export function rcFreeHandle(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, handle: int64): void {
	const index = handleIndex(handle);
	match (handleHeapKind(handle)) {
		RaiserHeapKind.Array => {
			const data = arrHeap.arrays[index];
			for (let v = 0; v < data.views.length; v += 1) {
				const view = arrHeap.arrays[handleIndex(data.views[v])];
				if (view.viewOff < 0) continue;
				view.items.length = 0;
				view.viewOff = -1;
				arrHeap.freeList.push(handleIndex(data.views[v]));
			}
			data.views.length = 0;
			data.viewOff = -1;
			data.items.length = 0;
			arrHeap.freeList.push(index);
		},
		RaiserHeapKind.Seq => rcFreeSeq(arrHeap, handle),
		RaiserHeapKind.Object => {
			const data: Cursor<RaiserObjectData> = objHeap.objects[index];
			data.slots.length = 0;
			data.wordSlots = 0;
			data.refSlots = 0;
			data.values.length = 0;
			data.added.length = 0;
			objHeap.freeList.push(index);
		},
		RaiserHeapKind.String => rcDestroyString(arrHeap, handle),
		RaiserHeapKind.Box => {
			arrHeap.boxes.items[index].value = raiserNil();
			arrHeap.boxes.freeList.push(index);
		},
		RaiserHeapKind.None | RaiserHeapKind.ConstString | RaiserHeapKind.Future => { throw new Error(`internal: handle ${handle} names no cell to free`); },
	}
}

@noinline
function rcDestroyString(arrHeap: RaiserArrayHeap, handle: int64): void {
	const held = arrHeap.stringBytes.get(handle);
	if (held != null && held != 0) {
		const bytes = arrHeap.arrays[handleIndex(held)];
		bytes.items.length = 0;
		arrHeap.freeList.push(handleIndex(held));
	}
	arrHeap.stringBytes.delete(handle);
	freeHeapText(arrHeap.mem, textAddress(handle));
}

@noinline
function rcDestroyArray(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, index: int64): void {
	const data = arrHeap.arrays[index];
	if (!data.elemUncounted) {
		for (const item of data.items) {
			rcDecref(arrHeap, objHeap, item);
		}
	}
	data.items.length = 0;
	arrHeap.freeList.push(index);
}

function removeSeqView(arrHeap: RaiserArrayHeap, base: int64, view: int64): void {
	const held = arrHeap.seqViews.get(base);
	if (held == null) return;
	const at = held.indexOf(view);
	if (at >= 0) held.splice(at, 1);
	if (held.length == 0) arrHeap.seqViews.delete(base);
}

@noinline
function rcDestroySeq(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, handle: int64): void {
	const c = seqCellOf(handle);
	if (cellTypeIndex(c) >= 0) {
		rcDestroyObjectCell(arrHeap, objHeap, c);
		return;
	}
	const base = seqBase(c);
	if (base != 0) {
		removeSeqView(arrHeap, base, handle);
	} else if (!seqUncounted(c) && seqClass(c) == RaiserRegClass.Ref) {
		for (let i = 0; i < seqLen(c); i += 1) {
			const child = seqLoad(c, i);
			if (child != 0) rcDecrefHandle(arrHeap, objHeap, child);
		}
	}
	rcFreeSeq(arrHeap, handle);
}

// Frees the cell of a typed array and, with a plain one, the views over it.
function rcFreeSeq(arrHeap: RaiserArrayHeap, handle: int64): void {
	const c = seqCellOf(handle);
	if (cellTypeIndex(c) >= 0) {
		if (!disposeCell(arrHeap.mem, c, 8)) throw new Error(`internal: object cell ${c} is not a live cell`);
		return;
	}
	const base = seqBase(c);
	if (base != 0) {
		removeSeqView(arrHeap, base, handle);
	} else {
		const views = arrHeap.seqViews.get(handle);
		if (views != null) {
			for (const view of views) seqFree(arrHeap.mem, seqCellOf(view));
			arrHeap.seqViews.delete(handle);
		}
	}
	seqFree(arrHeap.mem, c);
}

@noinline
function rcDestroyObject(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, index: int64): void {
	const data: Cursor<RaiserObjectData> = objHeap.objects[index];
	const kinds = data.classType.kinds;
	for (let i = 0; i < data.slots.length; i += 1) {
		if (kinds[i] == RaiserRegClass.Ref && !data.classType.uncounted[i] && data.slots[i] != 0) rcDecrefHandle(arrHeap, objHeap, data.slots[i]);
	}
	for (let i = 0; i < data.values.length; i += 1) {
		if (data.values[i].kind >= RaiserValueKind.String) rcDecrefHandle(arrHeap, objHeap, data.values[i].intVal);
	}
	data.slots.length = 0;
	data.wordSlots = 0;
	data.refSlots = 0;
	data.values.length = 0;
	data.added.length = 0;
	objHeap.freeList.push(index);
}

@noinline
function rcDestroyObjectCell(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, cell: int64): void {
	const t = classTypeAt(cellTypeIndex(cell));
	for (let i = 0; i < t.kinds.length; i += 1) {
		const cls = t.kinds[i];
		if (cls != RaiserRegClass.Ref && cls != RaiserRegClass.Dyn) continue;
		if (cls == RaiserRegClass.Ref && t.uncounted[i]) continue;
		const held = ld64(cell + (i as int64) * OBJECT_CELL_SLOT_BYTES);
		if (held != 0) rcDecrefHandle(arrHeap, objHeap, held);
	}
	if (!disposeCell(arrHeap.mem, cell, 8)) throw new Error(`internal: object cell ${cell} is not a live cell`);
}

@noinline
function rcDestroyBox(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, index: int64): void {
	const data = arrHeap.boxes.items[index];
	rcDecref(arrHeap, objHeap, data.value);
	data.value = raiserNil();
	arrHeap.boxes.freeList.push(index);
}

// --- Cross-heap graph copy ---
// A handle indexes the heap that allocated it, so a value crossing into
// another heap must be materialized there. The src->dst handle maps preserve
// sharing and terminate on cycles: a graph the collector exists to reclaim
// would otherwise recurse forever. Scalars carry their payload inline and
// Future handles index the VM-wide future table, so both cross unchanged.
// Reaching a node allocates its destination shell and queues a job to fill it, so a chain as long as the heap
// costs job-list space, not stack frames.

enum RaiserCopyKind { Array, Object, Slot }

interface RaiserCopyJob {
	kind: RaiserCopyKind;
	source: RaiserValue;
	dst: int64;
}

export interface RaiserCopyMap {
	arrays: Map<int64, int64>;
	objects: Map<int64, int64>;
	registerSlots: Map<int64, int64>;
	globalSlots: Map<int64, int64>;
	jobs: RaiserCopyJob[];
	viewFixups: int64[];
	sourceGlobals: RaiserValue[] | null;
	destGlobals: RaiserValue[] | null;
}

export function createCopyMap(): RaiserCopyMap {
	return {
		arrays: new Map<int64, int64>(),
		objects: new Map<int64, int64>(),
		registerSlots: new Map<int64, int64>(),
		globalSlots: new Map<int64, int64>(),
		jobs: [],
		viewFixups: [],
		sourceGlobals: null,
		destGlobals: null,
	};
}

export function copyGraph(srcArr: RaiserArrayHeap, srcObj: RaiserObjectHeap, dstArr: RaiserArrayHeap, dstObj: RaiserObjectHeap, val: RaiserValue): RaiserValue {
	const map = createCopyMap();
	return copyGraphWith(srcArr, srcObj, dstArr, dstObj, val, map);
}

// The value in the register a RegAddr names: its intVal is the slot's address | register class.
function copiedRegisterValue(address: int64): RaiserValue {
	const cls = (address & 7) as RaiserRegClass;
	const w = ld64(address - (address & 7));
	if (cls == RaiserRegClass.Ref || cls == RaiserRegClass.Dyn) return handleValue(w);
	if (cls == RaiserRegClass.Word) return raiserInt(w);
	if (cls == RaiserRegClass.Bool) return raiserBool(w != 0);
	return raiserFloat(bitsToFloat(w));
}

function disownFresh(dstArr: RaiserArrayHeap, dstObj: RaiserObjectHeap, handle: int64): void {
	if (handle == 0) return;
	const index = handleIndex(handle);
	match (handleHeapKind(handle)) {
		RaiserHeapKind.Array => { dstArr.arrays[index].rc = 0; },
		RaiserHeapKind.Object => { dstObj.objects[index].rc = 0; },
		RaiserHeapKind.String => { setTextRc(textAddress(handle), 0); },
		RaiserHeapKind.Box => { dstArr.boxes.items[index].rc = 0; },
		RaiserHeapKind.Seq => { setCellRc(seqCellOf(handle), 0); },
		RaiserHeapKind.None | RaiserHeapKind.ConstString | RaiserHeapKind.Future => {},
	}
}

function copySlotShell(dstArr: RaiserArrayHeap, val: RaiserValue, map: RaiserCopyMap): RaiserValue {
	const isRegister = val.kind == RaiserValueKind.RegAddr;
	const source = map.sourceGlobals;
	if (!isRegister) {
		if (source == null || val.intVal < 0 || val.intVal >= source.length) throw new Error("internal: a copied slot address must have its source storage");
		if (map.destGlobals != null) return raiserGlobalAddr(val.intVal);
	}
	const slots = isRegister ? map.registerSlots : map.globalSlots;
	if (slots.has(val.intVal)) return raiserElemAddr(slots.get(val.intVal)!, 0);
	const handle = heapAllocArray(dstArr);
	dstArr.arrays[handleIndex(handle)].rc = 0;
	slots.set(val.intVal, handle);
	const held = isRegister ? copiedRegisterValue(val.intVal) : source![val.intVal];
	map.jobs.push({ kind: RaiserCopyKind.Slot, source: held, dst: handle });
	return raiserElemAddr(handle, 0);
}

function copyArrayShell(srcArr: RaiserArrayHeap, dstArr: RaiserArrayHeap, val: RaiserValue, map: RaiserCopyMap): RaiserValue {
	const isArray = val.kind == RaiserValueKind.Array;
	if (map.arrays.has(val.intVal)) {
		const known = map.arrays.get(val.intVal)!;
		return isArray ? raiserArray(known) : raiserElemAddr(known, val.floatVal as int64);
	}
	if (!isSeqHandle(val.intVal) && handleIndex(val.intVal) >= srcArr.arrays.length) {
		if (!isArray) throw new Error("internal: a copied element address must have an array owner");
		return raiserNil();
	}
	if (isSeqHandle(val.intVal) && seqBase(seqCellOf(val.intVal)) != 0) {
		const view = copySeqViewShell(srcArr, dstArr, val.intVal, map);
		return isArray ? raiserArray(view) : raiserElemAddr(view, val.floatVal as int64);
	}
	const dstHandle = heapAllocArrayLike(dstArr, srcArr, val.intVal);
	heapArraySetRc(dstArr, dstHandle, 0);
	map.arrays.set(val.intVal, dstHandle);
	map.jobs.push({ kind: RaiserCopyKind.Array, source: raiserArray(val.intVal), dst: dstHandle });
	return isArray ? raiserArray(dstHandle) : raiserElemAddr(dstHandle, val.floatVal as int64);
}

// A view of a typed array is copied as a view of the copy of the array it stands on; it points into that copy's
// payload once the copy is filled (see the fixups at the end of copyGraphWith).
function copySeqViewShell(srcArr: RaiserArrayHeap, dstArr: RaiserArrayHeap, view: int64, map: RaiserCopyMap): int64 {
	const sc = seqCellOf(view);
	const sbase = seqBase(sc);
	const baseCopy = copyArrayShell(srcArr, dstArr, raiserArray(sbase), map).intVal;
	const dstView = seqNewView(dstArr.mem, seqCellOf(baseCopy), baseCopy, 0, seqLen(sc) as int64, 0) | (RaiserHeapKind.Seq as int64);
	const held = dstArr.seqViews.get(baseCopy);
	if (held == null) {
		const list: int64[] = [dstView];
		dstArr.seqViews.set(baseCopy, list);
	} else {
		held.push(dstView);
	}
	map.arrays.set(view, dstView);
	map.viewFixups.push(dstView);
	map.viewFixups.push(seqViewOffset(sc));
	return dstView;
}

function copyObjectShell(srcObj: RaiserObjectHeap, dstObj: RaiserObjectHeap, val: RaiserValue, map: RaiserCopyMap): RaiserValue {
	const isObject = val.kind == RaiserValueKind.Object;
	if (map.objects.has(val.intVal)) {
		const known = map.objects.get(val.intVal)!;
		return isObject ? raiserObject(known) : raiserFieldAddrAt(known, val.floatVal as int64);
	}
	if (handleIndex(val.intVal) >= srcObj.objects.length) {
		if (!isObject) throw new Error("internal: a copied field address must have an object owner");
		return raiserNil();
	}
	const dstHandle = heapAllocObject(dstObj);
	dstObj.objects[handleIndex(dstHandle)].classType = srcObj.objects[handleIndex(val.intVal)].classType;
	dstObj.objects[handleIndex(dstHandle)].rc = 0;
	map.objects.set(val.intVal, dstHandle);
	map.jobs.push({ kind: RaiserCopyKind.Object, source: raiserObject(val.intVal), dst: dstHandle });
	return isObject ? raiserObject(dstHandle) : raiserFieldAddrAt(dstHandle, val.floatVal as int64);
}

// The destination of one value: a scalar is itself, a node is its destination shell, filled by a queued job.
function copyShell(srcArr: RaiserArrayHeap, srcObj: RaiserObjectHeap, dstArr: RaiserArrayHeap, dstObj: RaiserObjectHeap, val: RaiserValue, map: RaiserCopyMap): RaiserValue {
	if (val.kind == RaiserValueKind.RegAddr || val.kind == RaiserValueKind.GlobalAddr) return copySlotShell(dstArr, val, map);
	if (val.kind == RaiserValueKind.Array || val.kind == RaiserValueKind.ElemAddr) return copyArrayShell(srcArr, dstArr, val, map);
	if (val.kind == RaiserValueKind.Object || val.kind == RaiserValueKind.FieldAddr) return copyObjectShell(srcObj, dstObj, val, map);
	if (val.kind == RaiserValueKind.String && handleHeapKind(val.intVal) == RaiserHeapKind.String) {
		const text = heapAllocString(dstArr, heapStringText(srcArr, val));
		disownFresh(dstArr, dstObj, text.intVal);
		return text;
	}
	if (val.kind == RaiserValueKind.Box) {
		const inner = copyShell(srcArr, srcObj, dstArr, dstObj, heapBoxValue(srcArr, val.intVal), map);
		const copy = heapAllocBox(dstArr, inner);
		dstArr.boxes.items[handleIndex(copy)].rc = 0;
		rcIncref(dstArr, dstObj, inner);
		return { kind: RaiserValueKind.Box, intVal: copy, floatVal: 0.0 };
	}
	return val;
}

function fillArray(srcArr: RaiserArrayHeap, srcObj: RaiserObjectHeap, dstArr: RaiserArrayHeap, dstObj: RaiserObjectHeap, job: RaiserCopyJob, map: RaiserCopyMap): void {
	const sourceHandle = job.source.intVal;
	const held = arrayHeldCount(srcArr, sourceHandle);
	for (let i = 0; i < held; i = i + 1) {
		const copied = copyShell(srcArr, srcObj, dstArr, dstObj, arrayHeldAt(srcArr, sourceHandle, i), map);
		heapArrayPush(dstArr, job.dst, copied);
		rcIncref(dstArr, dstObj, copied);
	}
	if (!isSeqHandle(job.dst)) {
		const source = srcArr.arrays[handleIndex(sourceHandle)];
		dstArr.arrays[handleIndex(job.dst)].viewOff = source.viewOff;
		dstArr.arrays[handleIndex(job.dst)].viewLen = source.viewLen;
	}
}

function fillObject(srcArr: RaiserArrayHeap, srcObj: RaiserObjectHeap, dstArr: RaiserArrayHeap, dstObj: RaiserObjectHeap, job: RaiserCopyJob, map: RaiserCopyMap): void {
	const source = srcObj.objects[handleIndex(job.source.intVal)];
	const count = objectFieldCount(source);
	for (let i = 0; i < count; i = i + 1) {
		const copied = copyShell(srcArr, srcObj, dstArr, dstObj, fieldValueAt(source, i), map);
		appendField(dstObj.objects[handleIndex(job.dst)], fieldNameAt(source, i), copied);
		rcIncref(dstArr, dstObj, copied);
	}
}

function fillSlot(srcArr: RaiserArrayHeap, srcObj: RaiserObjectHeap, dstArr: RaiserArrayHeap, dstObj: RaiserObjectHeap, job: RaiserCopyJob, map: RaiserCopyMap): void {
	const copied = copyShell(srcArr, srcObj, dstArr, dstObj, job.source, map);
	heapArrayPush(dstArr, job.dst, copied);
	rcIncref(dstArr, dstObj, copied);
}

export function copyGraphWith(srcArr: RaiserArrayHeap, srcObj: RaiserObjectHeap, dstArr: RaiserArrayHeap, dstObj: RaiserObjectHeap, val: RaiserValue, map: RaiserCopyMap): RaiserValue {
	const root = copyShell(srcArr, srcObj, dstArr, dstObj, val, map);
	while (map.jobs.length > 0) {
		const job = map.jobs.pop()!;
		match (job.kind) {
			RaiserCopyKind.Array => fillArray(srcArr, srcObj, dstArr, dstObj, job, map),
			RaiserCopyKind.Object => fillObject(srcArr, srcObj, dstArr, dstObj, job, map),
			RaiserCopyKind.Slot => fillSlot(srcArr, srcObj, dstArr, dstObj, job, map),
		}
	}
	for (let f = 0; f < map.viewFixups.length; f += 2) seqPointViewInto(seqCellOf(map.viewFixups[f]), map.viewFixups[f + 1]);
	return root;
}

test "copyGraph relocates a field address that points into its own owner" {
	const sArr = createArrayHeap();
	const sObj = createStructHeap();
	const dArr = createArrayHeap();
	const dObj = createStructHeap();
	const padding = heapAllocObject(sObj);
	heapObjectSetField(sObj, padding, "text", raiserConstString("unrelated"));
	const owner = heapAllocObject(sObj);
	heapObjectSetField(sObj, owner, "text", heapAllocString(sArr, "source"));
	heapObjectSetField(sObj, owner, "pointer", raiserFieldAddr(owner, "text"));
	const copied = copyGraph(sArr, sObj, dArr, dObj, raiserObject(owner));
	const pointer = heapObjectGetField(dObj, copied.intVal, "pointer");
	heapObjectSetField(dObj, pointer.intVal, fieldAddrName(pointer), heapAllocString(dArr, "destination"));
	assert heapObjectGetString(dArr, dObj, copied.intVal, "text") == "destination";
	assert heapObjectGetString(sArr, sObj, owner, "text") == "source";
}

test "copyGraph preserves aliases to a register snapshot without retaining its source slot" {
	const sArr = createArrayHeap();
	const sObj = createStructHeap();
	const dArr = createArrayHeap();
	const dObj = createStructHeap();
	const slot = reserveSlots(sArr.mem, 1);
	st64(slot, heapAllocString(sArr, "source").intVal);
	const owner = heapAllocArray(sArr);
	heapArrayPush(sArr, owner, raiserRegAddr(slot | 1));
	heapArrayPush(sArr, owner, raiserRegAddr(slot | 1));
	const map = createCopyMap();
	const copied = copyGraphWith(sArr, sObj, dArr, dObj, raiserArray(owner), map);
	const first = heapArrayGet(dArr, copied.intVal, 0);
	const second = heapArrayGet(dArr, copied.intVal, 1);
	assert heapStringText(dArr, heapArrayGet(dArr, first.intVal, first.floatVal as int64)) == "source";
	heapArraySet(dArr, first.intVal, first.floatVal as int64, heapAllocString(dArr, "destination"));
	assert heapStringText(dArr, heapArrayGet(dArr, second.intVal, second.floatVal as int64)) == "destination";
	assert heapStringText(sArr, handleValue(ld64(slot))) == "source";
}

// --- Cross-heap copy tests ---
test "copyGraph materializes a nested graph in the destination heap" {
	const sArr = createArrayHeap();
	const sObj = createStructHeap();
	const dArr = createArrayHeap();
	const dObj = createStructHeap();
	const inner = heapAllocArray(sArr);
	heapArrayPush(sArr, inner, raiserInt(7));
	const outer = heapAllocObject(sObj);
	heapObjectSetField(sObj, outer, "kids", raiserArray(inner));
	heapObjectSetField(sObj, outer, "tag", heapAllocString(sArr, "t"));

	const copied = copyGraph(sArr, sObj, dArr, dObj, raiserObject(outer));
	assert copied.kind == RaiserValueKind.Object;
	assert heapObjectGetString(dArr, dObj, copied.intVal, "tag") == "t";
	const kids = heapObjectGetField(dObj, copied.intVal, "kids");
	assert kids.kind == RaiserValueKind.Array;
	assert heapArrayLen(dArr, kids.intVal) == 1;
	assert heapArrayGet(dArr, kids.intVal, 0).intVal == 7;
}

test "copyGraph leaves the source heap untouched by destination writes" {
	const sArr = createArrayHeap();
	const sObj = createStructHeap();
	const dArr = createArrayHeap();
	const dObj = createStructHeap();
	const src = heapAllocObject(sObj);
	heapObjectSetField(sObj, src, "n", raiserInt(1));
	const copied = copyGraph(sArr, sObj, dArr, dObj, raiserObject(src));
	heapObjectSetField(dObj, copied.intVal, "n", raiserInt(99));
	assert heapObjectGetInt(sObj, src, "n") == 1;
	assert heapObjectGetInt(dObj, copied.intVal, "n") == 99;
}

test "copyGraph preserves sharing instead of duplicating" {
	const sArr = createArrayHeap();
	const sObj = createStructHeap();
	const dArr = createArrayHeap();
	const dObj = createStructHeap();
	const shared = heapAllocObject(sObj);
	heapObjectSetField(sObj, shared, "v", raiserInt(5));
	const holder = heapAllocArray(sArr);
	heapArrayPush(sArr, holder, raiserObject(shared));
	heapArrayPush(sArr, holder, raiserObject(shared));

	const copied = copyGraph(sArr, sObj, dArr, dObj, raiserArray(holder));
	const a = heapArrayGet(dArr, copied.intVal, 0);
	const b = heapArrayGet(dArr, copied.intVal, 1);
	assert a.intVal == b.intVal;
	assert dObj.objects.length == 1;
}

test "copyGraph terminates on a cycle" {
	const sArr = createArrayHeap();
	const sObj = createStructHeap();
	const dArr = createArrayHeap();
	const dObj = createStructHeap();
	const a = heapAllocObject(sObj);
	const b = heapAllocObject(sObj);
	heapObjectSetField(sObj, a, "next", raiserObject(b));
	heapObjectSetField(sObj, b, "back", raiserObject(a));

	const copied = copyGraph(sArr, sObj, dArr, dObj, raiserObject(a));
	assert dObj.objects.length == 2;
	const next = heapObjectGetField(dObj, copied.intVal, "next");
	const back = heapObjectGetField(dObj, next.intVal, "back");
	assert back.intVal == copied.intVal;
}

test "copyGraph passes scalars and future handles through" {
	const sArr = createArrayHeap();
	const sObj = createStructHeap();
	const dArr = createArrayHeap();
	const dObj = createStructHeap();
	assert copyGraph(sArr, sObj, dArr, dObj, raiserInt(3)).intVal == 3;
	const text = copyGraph(sArr, sObj, dArr, dObj, heapAllocString(sArr, "s"));
	assert heapStringText(dArr, text) == "s";
	assert heapStringLive(sArr) == 1 && heapStringLive(dArr) == 1;
	const fut = copyGraph(sArr, sObj, dArr, dObj, raiserFuture(4));
	assert fut.kind == RaiserValueKind.Future;
	assert fut.intVal == 4;
	assert dArr.arrays.length == 0;
	assert dObj.objects.length == 0;
}

test "copyGraph refcounts the destination edges" {
	const sArr = createArrayHeap();
	const sObj = createStructHeap();
	const dArr = createArrayHeap();
	const dObj = createStructHeap();
	const child = heapAllocArray(sArr);
	const parent = heapAllocArray(sArr);
	heapArrayPush(sArr, parent, raiserArray(child));
	const copied = copyGraph(sArr, sObj, dArr, dObj, raiserArray(parent));
	const kid = heapArrayGet(dArr, copied.intVal, 0);
	assert dArr.arrays[handleIndex(kid.intVal)].rc == 1;
	assert dArr.arrays[handleIndex(copied.intVal)].rc == 0;
}

test "copyGraph copies a linked list as long as the heap without native recursion" {
	const sArr = createArrayHeap();
	const sObj = createStructHeap();
	const dArr = createArrayHeap();
	const dObj = createStructHeap();
	const count = 200000;
	const first = heapAllocObject(sObj);
	let prev = first;
	for (let i = 1; i < count; i += 1) {
		const next = heapAllocObject(sObj);
		heapObjectSetField(sObj, prev, "next", raiserObject(next));
		prev = next;
	}
	const copied = copyGraph(sArr, sObj, dArr, dObj, raiserObject(first));
	assert dObj.objects.length == count;
	let length = 1;
	let at = copied;
	while (true) {
		const next = heapObjectGetField(dObj, at.intVal, "next");
		if (next.kind != RaiserValueKind.Object) break;
		at = next;
		length += 1;
	}
	assert length == count;
}

test "copyGraph keeps a shared element and a cycle through an array of objects" {
	const sArr = createArrayHeap();
	const sObj = createStructHeap();
	const dArr = createArrayHeap();
	const dObj = createStructHeap();
	const shared = heapAllocObject(sObj);
	const list = heapAllocArray(sArr);
	heapArrayPush(sArr, list, raiserObject(shared));
	heapArrayPush(sArr, list, raiserObject(shared));
	heapObjectSetField(sObj, shared, "owner", raiserArray(list));
	const copied = copyGraph(sArr, sObj, dArr, dObj, raiserArray(list));
	assert dObj.objects.length == 1 && dArr.arrays.length == 1;
	const first = heapArrayGet(dArr, copied.intVal, 0);
	const second = heapArrayGet(dArr, copied.intVal, 1);
	assert first.intVal == second.intVal;
	assert heapObjectGetField(dObj, first.intVal, "owner").intVal == copied.intVal;
}

// --- ORC refcount tests ---
test "rc incref/decref frees at zero" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const h = heapAllocArray(arr);
	const v = raiserArray(h);
	assert arr.arrays[handleIndex(h)].rc == 1;
	rcIncref(arr, obj, v);
	assert arr.arrays[handleIndex(h)].rc == 2;
	rcDecref(arr, obj, v);
	assert arr.arrays[handleIndex(h)].rc == 1;
	rcDecref(arr, obj, v);
	assert arr.freeList.length == 1;
	assert arr.freeList[0] == handleIndex(h);
}

test "rc destroy decrefs children" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const parent = heapAllocArray(arr);
	const child = heapAllocArray(arr);
	const childVal = raiserArray(child);
	heapArrayPush(arr, parent, childVal);
	const parentVal = raiserArray(parent);
	assert arr.arrays[handleIndex(child)].rc == 1;
	rcDecref(arr, obj, parentVal);
	assert arr.freeList.length == 2;
}

test "alloc reuses free-list slot" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const h1 = heapAllocArray(arr);
	const v = raiserArray(h1);
	rcDecref(arr, obj, v);
	const h2 = heapAllocArray(arr);
	assert h2 == h1;
	assert arr.freeList.length == 0;
}

test "rc object destroy decrefs field refs" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const o = heapAllocObject(obj);
	const childArr = heapAllocArray(arr);
	const childVal = raiserArray(childArr);
	heapObjectSetField(obj, o, "kids", childVal);
	const oVal = raiserObject(o);
	assert arr.arrays[handleIndex(childArr)].rc == 1;
	rcDecref(arr, obj, oVal);
	assert obj.freeList.length == 1;
	assert arr.freeList.length == 1;
}

// --- Object field convenience accessors ---
// These let the host read typed config fields from a VM result object.

export function heapObjectGetString(arr: RaiserArrayHeap, heap: RaiserObjectHeap, handle: int64, field: string): string {
	const val = heapObjectGetField(heap, handle, field);
	return heapStringText(arr, val);
}

export function heapObjectGetInt(heap: RaiserObjectHeap, handle: int64, field: string): number {
	const val = heapObjectGetField(heap, handle, field);
	return val.intVal as number;
}

export function heapObjectGetObjectHandle(heap: RaiserObjectHeap, handle: int64, field: string): int64 {
	const val = heapObjectGetField(heap, handle, field);
	if (val.kind == RaiserValueKind.Object) return val.intVal;
	return -1;
}

// --- Heap Recycling ---
// Reset heaps to reclaim memory between @comptime evaluations.

export function clearArrayHeap(heap: RaiserArrayHeap): void {
	heap.arrays.length = 0;
	heap.freeList.length = 0;
	heap.mem = createVmMemory();
	heap.stringBytes.clear();
	heap.boxes = createBoxHeap();
}

export function clearObjectHeap(heap: RaiserObjectHeap): void {
	heap.objects.length = 0;
	heap.freeList.length = 0;
}

// --- Object Heap Tests ---
test "alloc empty object" {
	const heap = createStructHeap();
	const h = heapAllocObject(heap);
	assert handleIndex(h) == 0;
	assert heapObjectFieldCount(heap, h) == 0;
}

test "set and get field" {
	const heap = createStructHeap();
	const h = heapAllocObject(heap);
	const v = raiserInt(42);
	heapObjectSetField(heap, h, "x", v);
	assert heapObjectFieldCount(heap, h) == 1;
	assert heapObjectGetField(heap, h, "x").intVal == 42;
}

test "multiple fields" {
	const heap = createStructHeap();
	const h = heapAllocObject(heap);
	const v1 = raiserInt(10);
	const v2 = raiserInt(20);
	heapObjectSetField(heap, h, "x", v1);
	heapObjectSetField(heap, h, "y", v2);
	assert heapObjectFieldCount(heap, h) == 2;
	assert heapObjectGetField(heap, h, "x").intVal == 10;
	assert heapObjectGetField(heap, h, "y").intVal == 20;
}

test "update existing field" {
	const heap = createStructHeap();
	const h = heapAllocObject(heap);
	const v1 = raiserInt(1);
	heapObjectSetField(heap, h, "x", v1);
	const v2 = raiserInt(99);
	heapObjectSetField(heap, h, "x", v2);
	assert heapObjectFieldCount(heap, h) == 1;
	assert heapObjectGetField(heap, h, "x").intVal == 99;
}

test "get missing field returns nil" {
	const heap = createStructHeap();
	const h = heapAllocObject(heap);
	const val = heapObjectGetField(heap, h, "missing");
	assert val.kind == RaiserValueKind.Nil;
}

test "object value kind" {
	const v = raiserObject(5);
	assert v.kind == RaiserValueKind.Object;
	assert v.intVal == 5;
	assert raiserToBool(createArrayHeap(), v);
}

test "clearArrayHeap resets storage" {
	const heap = createArrayHeap();
	const h = heapAllocArray(heap);
	const v = raiserInt(1);
	heapArrayPush(heap, h, v);
	assert heap.arrays.length == 1;
	clearArrayHeap(heap);
	assert heap.arrays.length == 0;
	// Re-allocate works after clear
	const h2 = heapAllocArray(heap);
	assert handleIndex(h2) == 0;
}

test "clearObjectHeap resets storage" {
	const heap = createStructHeap();
	const h = heapAllocObject(heap);
	const v = raiserInt(42);
	heapObjectSetField(heap, h, "x", v);
	assert heap.objects.length == 1;
	clearObjectHeap(heap);
	assert heap.objects.length == 0;
	// Re-allocate works after clear
	const h2 = heapAllocObject(heap);
	assert handleIndex(h2) == 0;
}

test "a kind below String holds no handle the counters touch" {
	const arrays = createArrayHeap();
	const objects = createStructHeap();
	const array = heapAllocArray(arrays);
	const object = heapAllocObject(objects);
	arrays.arrays[0].rc = 1;
	objects.objects[0].rc = 1;
	for (let k = 0; k < (RaiserValueKind.String as number); k++) rcIncref(arrays, objects, { kind: k as RaiserValueKind, intVal: array, floatVal: 0.0 });
	for (let k = 0; k < (RaiserValueKind.String as number); k++) rcIncref(arrays, objects, { kind: k as RaiserValueKind, intVal: object, floatVal: 0.0 });
	assert arrays.arrays[0].rc == 1 && objects.objects[0].rc == 1;
	for (let k = 0; k < (RaiserValueKind.String as number); k++) rcDecref(arrays, objects, { kind: k as RaiserValueKind, intVal: array, floatVal: 0.0 });
	assert arrays.arrays[0].rc == 1 && objects.objects[0].rc == 1 && arrays.freeList.length == 0;
}

// --- String heap tests ---
test "a string frees at rc zero and its slot is reused" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const s = heapAllocString(arr, "abc");
	rcIncref(arr, obj, s);
	rcDecref(arr, obj, s);
	assert heapStringLive(arr) == 1;
	rcDecref(arr, obj, s);
	assert heapStringLive(arr) == 0;
	const again = heapAllocString(arr, "xyz");
	assert again.intVal == s.intVal;
	assert heapStringText(arr, again) == "xyz";
}

test "a string is an msString in VM memory: the length, then a payload that opens with its capacity and ends in a zero byte" {
	const arr = createArrayHeap();
	const v = heapAllocString(arr, "g\u00e9");
	const at = textAddress(v.intVal);
	assert ld64(at) == 3 && ld64(ld64(at + 8)) >= 3 && ldByte(ld64(at + 8) + 8 + 3) == 0 && isHeapBlock(arr.mem, ld64(at + 8)) && !isHeapBlock(constMemory, ld64(at + 8));
	assert heapStringHandles(arr).length == 1 && heapStringHandles(arr)[0] == v.intVal;
	const konst = raiserConstString("kept");
	const constAt = textAddress(konst.intVal);
	assert ld64(constAt) == 4 && (ld64(ld64(constAt + 8)) & 4611686018427387904) != 0 && isConstMemory(constMemory, constAt);
}

test "a constant string is shared by every heap and never freed" {
	const a = createArrayHeap();
	const b = createArrayHeap();
	const obj = createStructHeap();
	const c = raiserConstString("shared");
	assert handleHeapKind(c.intVal) == RaiserHeapKind.ConstString && raiserConstString("shared").intVal == c.intVal;
	rcIncref(a, obj, c);
	rcDecref(a, obj, c);
	assert heapStringText(a, c) == "shared" && heapStringText(b, c) == "shared";
	assert heapStringLive(a) == 0;
}

test "a string whose bytes are not a whole UTF-8 sequence is stored, not taken for empty" {
	const heap = createArrayHeap();
	for (const text of ["é".byteSlice(0, 1), "é".byteSlice(1, 2), "a€".byteSlice(1, 3)]) {
		const v = heapAllocString(heap, text);
		assert v.intVal >= 0;
		assert heapStringText(heap, v).byteLength == text.byteLength;
	}
	assert heapAllocString(heap, "").intVal == emptyTextHandle();
}

test "destroying a container releases its strings" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const holder = heapAllocArray(arr);
	const s = heapAllocString(arr, "kept");
	heapArrayPush(arr, holder, s);
	assert heapStringLive(arr) == 1;
	rcDecref(arr, obj, raiserArray(holder));
	assert heapStringLive(arr) == 0;
}

test "a non-string reads as empty text" {
	assert heapStringText(createArrayHeap(), raiserInt(5)) == "";
}

// --- Handle tests ---
test "a handle names its heap kind: the kind recomputed from the handle equals the value's tag, for every heap" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const strand = heapAllocString(arr, "strand text");
	const constant = raiserConstString("constant text");
	const array = raiserArray(heapAllocArray(arr));
	const object = raiserObject(heapAllocObject(obj));
	const future = raiserFuture(makeHandle(3, RaiserHeapKind.Future));
	const box: RaiserValue = { kind: RaiserValueKind.Box, intVal: heapAllocBox(arr, raiserInt(5)), floatVal: 0.0 };
	for (const v of [strand, constant, array, object, future, box]) {
		assert v.intVal != 0;
		assert handleKind(v.intVal) == v.kind, `${v.kind}`;
		assert handleAgrees(v.kind, v.intVal);
	}
	assert handleHeapKind(strand.intVal) == RaiserHeapKind.String && textRc(textAddress(strand.intVal)) == OWNED_BY_RECEIVER_RC;
	assert handleHeapKind(constant.intVal) == RaiserHeapKind.ConstString;
	assert handleKind(0) == RaiserValueKind.Nil && handleAgrees(RaiserValueKind.Nil, 0);
	assert handleKind(heapAllocString(arr, "").intVal) == RaiserValueKind.String;
}

test "a handle that names a different heap than the value's kind disagrees" {
	const arr = createArrayHeap();
	const array = heapAllocArray(arr);
	assert !handleAgrees(RaiserValueKind.Object, array);
	assert !handleAgrees(RaiserValueKind.String, array);
	assert !handleAgrees(RaiserValueKind.Nil, array);
	assert handleAgrees(RaiserValueKind.ElemAddr, array);
	assert !handleAgrees(RaiserValueKind.FieldAddr, array);
	assert handleAgrees(RaiserValueKind.Int, 12345);
}

test "a graph copy into another heap keeps each value's kind and the handle that names it" {
	const sArr = createArrayHeap();
	const sObj = createStructHeap();
	const dArr = createArrayHeap();
	const dObj = createStructHeap();
	const holder = heapAllocObject(sObj);
	heapObjectSetField(sObj, holder, "text", heapAllocString(sArr, "heap"));
	heapObjectSetField(sObj, holder, "kept", raiserConstString("const"));
	heapObjectSetField(sObj, holder, "list", raiserArray(heapAllocArray(sArr)));
	heapObjectSetField(sObj, holder, "box", { kind: RaiserValueKind.Box, intVal: heapAllocBox(sArr, heapAllocString(sArr, "boxed")), floatVal: 0.0 });
	const copied = copyGraph(sArr, sObj, dArr, dObj, raiserObject(holder));
	assert copied.kind == RaiserValueKind.Object && handleKind(copied.intVal) == RaiserValueKind.Object;
	for (const name of ["text", "kept", "list", "box"]) {
		const field = heapObjectGetField(dObj, copied.intVal, name);
		assert handleKind(field.intVal) == field.kind, name;
	}
	assert heapStringText(dArr, heapObjectGetField(dObj, copied.intVal, "text")) == "heap";
	assert heapStringText(dArr, heapBoxValue(dArr, heapObjectGetField(dObj, copied.intVal, "box").intVal)) == "boxed";
	assert dArr.boxes.items.length == 1 && sArr.boxes.items.length == 1;
}

test "a box shares through its handle and frees its held value when its last holder lets go" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const text = heapAllocString(arr, "inside");
	const handle = heapAllocBox(arr, text);
	const box: RaiserValue = { kind: RaiserValueKind.Box, intVal: handle, floatVal: 0.0 };
	rcIncref(arr, obj, box);
	assert heapBoxLive(arr) == 1 && heapStringLive(arr) == 1;
	rcDecref(arr, obj, box);
	assert heapBoxLive(arr) == 1 && heapStringLive(arr) == 1;
	rcDecref(arr, obj, box);
	assert heapBoxLive(arr) == 0 && heapStringLive(arr) == 0;
	assert heapAllocBox(arr, raiserInt(1)) == handle;
}

test "readDyn reads through a box and passes anything else through" {
	const arr = createArrayHeap();
	const box: RaiserValue = { kind: RaiserValueKind.Box, intVal: heapAllocBox(arr, raiserInt(9)), floatVal: 0.0 };
	assert readDyn(arr, box).intVal == 9 && readDyn(arr, box).kind == RaiserValueKind.Int;
	assert readDyn(arr, raiserFloat(1.5)).floatVal == 1.5;
	assert raiserToBool(arr, box) && raiserToString(arr, box) == "9";
	assert raiserEqual(arr, box, raiserInt(9));
}

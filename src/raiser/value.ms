// Raiser VM — Value representation
// Day-1: flat tagged interface. No NaN-boxing.
// Bool stored as intVal (0/1) to keep the interface simple.

import { RaiserRegClass } from "./bytecode";

@include("runtime/core/hashBits.h");
extern function msBitsFloat64(u: int64): float64;


// A kind from String up holds one heap handle in intVal; the kinds below it hold no reference.
export enum RaiserValueKind {
	Nil,
	Bool,
	Int,        // i64 integer
	Float,      // f64 float
	RegAddr,    // address of a register slot: intVal = absolute slot index
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
		RaiserHeapKind.Object => RaiserValueKind.Object,
		RaiserHeapKind.Future => RaiserValueKind.Future,
		RaiserHeapKind.Box => RaiserValueKind.Box,
	};
}

function checkHeapKind(handle: int64): void {
	if (handleTag(handle) > (RaiserHeapKind.Box as int64)) throw new Error(`internal: handle ${handle} names no heap kind`);
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
		RaiserValueKind.ElemAddr | RaiserValueKind.Array => tag == (RaiserHeapKind.Array as int64),
		RaiserValueKind.FieldAddr | RaiserValueKind.Object => tag == (RaiserHeapKind.Object as int64),
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
// A string is immutable text on a side heap, like arrays and objects: the value
// holds an index, rc counts the holders (only under gcMode "orc"), a freed slot
// goes on the free list. The heap hangs off the array heap, so every place that
// already carries the strand's heaps reaches it. Handles below zero index the
// constant table instead; the table is shared, append-only and never freed.

export interface RaiserStringHeap {
	texts: string[];
	rc: int32[];
	freeList: int64[];
}

export function createStringHeap(): RaiserStringHeap {
	const texts: string[] = [];
	const rc: int32[] = [];
	const freeList: int64[] = [];
	return { texts, rc, freeList };
}

const constTexts: string[] = [""];
const constIndex: Map<string, int64> = new Map<string, int64>();
constIndex.set("", makeHandle(0, RaiserHeapKind.ConstString));

function constHandle(text: string): int64 {
	if (constIndex.has(text)) return constIndex.get(text)!;
	constTexts.push(text);
	const handle = makeHandle((constTexts.length - 1) as int64, RaiserHeapKind.ConstString);
	constIndex.set(text, handle);
	return handle;
}

function constText(handle: int64): string {
	return constTexts[handleIndex(handle) as number];
}

function isConstHandle(handle: int64): boolean {
	return handleHeapKind(handle) == RaiserHeapKind.ConstString;
}

// Module constants and field names are interned, so reading one needs no heap.
export function constStringText(v: RaiserValue): string {
	if (v.kind != RaiserValueKind.String || !isConstHandle(v.intVal)) throw new Error("internal: a module constant must be an interned string");
	return constText(v.intVal);
}

export function constStringCount(): number {
	return constTexts.length;
}

export function heapAllocString(arr: RaiserArrayHeap, text: string): RaiserValue {
	if (text.byteLength == 0) return { kind: RaiserValueKind.String, intVal: makeHandle(0, RaiserHeapKind.ConstString), floatVal: 0.0 };
	const heap = arr.strings;
	let index: int64 = 0;
	if (heap.freeList.length > 0) {
		index = heap.freeList[heap.freeList.length - 1];
		heap.freeList.length = heap.freeList.length - 1;
		heap.texts[index] = text;
		heap.rc[index] = 0;
	} else {
		index = heap.texts.length;
		heap.texts.push(text);
		heap.rc.push(0);
	}
	return { kind: RaiserValueKind.String, intVal: makeHandle(index, RaiserHeapKind.String), floatVal: 0.0 };
}

// A string the host stores into a container it built: the container holds the first count.
export function heapAllocStoredString(arr: RaiserArrayHeap, text: string): RaiserValue {
	const v = heapAllocString(arr, text);
	if (!isConstHandle(v.intVal)) arr.strings.rc[handleIndex(v.intVal)] = 1;
	return v;
}

// A value that is not a String reads as "", the way an unset text field always did.
export function heapStringText(arr: RaiserArrayHeap, v: RaiserValue): string {
	if (v.kind != RaiserValueKind.String) return "";
	if (isConstHandle(v.intVal)) return constText(v.intVal);
	return arr.strings.texts[handleIndex(v.intVal)];
}

// The operations below read a string where it lives and never hand its text out as an
// owned copy: a handle below zero selects the constant table, otherwise the strand's
// heap, and an element read inside an expression is a cursor.

function textTable(arr: RaiserArrayHeap, v: RaiserValue): string[] {
	return v.kind == RaiserValueKind.String && !isConstHandle(v.intVal) ? arr.strings.texts : constTexts;
}

function textIndex(v: RaiserValue): number {
	if (v.kind != RaiserValueKind.String) return 0;
	return handleIndex(v.intVal) as number;
}

export function heapStringEquals(arr: RaiserArrayHeap, a: RaiserValue, b: RaiserValue): boolean {
	if (a.intVal == b.intVal) return true;
	const ta = textTable(arr, a);
	const tb = textTable(arr, b);
	const ia = textIndex(a);
	const ib = textIndex(b);
	return ta[ia] == tb[ib];
}

export function heapStringLess(arr: RaiserArrayHeap, a: RaiserValue, b: RaiserValue): boolean {
	const ta = textTable(arr, a);
	const tb = textTable(arr, b);
	const ia = textIndex(a);
	const ib = textIndex(b);
	return ta[ia] < tb[ib];
}

export function heapStringLessEq(arr: RaiserArrayHeap, a: RaiserValue, b: RaiserValue): boolean {
	const ta = textTable(arr, a);
	const tb = textTable(arr, b);
	const ia = textIndex(a);
	const ib = textIndex(b);
	return ta[ia] <= tb[ib];
}

export function heapStringLength(arr: RaiserArrayHeap, v: RaiserValue): int64 {
	const t = textTable(arr, v);
	const i = textIndex(v);
	return t[i].length as int64;
}

export function heapStringByteLength(arr: RaiserArrayHeap, v: RaiserValue): int64 {
	const t = textTable(arr, v);
	const i = textIndex(v);
	return t[i].byteLength as int64;
}

export function heapStringSlice(arr: RaiserArrayHeap, v: RaiserValue, start: int32, end: int32): string {
	const t = textTable(arr, v);
	const i = textIndex(v);
	return t[i].slice(start, end);
}

export function heapConcat(arr: RaiserArrayHeap, a: RaiserValue, b: RaiserValue): RaiserValue {
	const ta = textTable(arr, a);
	const tb = textTable(arr, b);
	const ia = textIndex(a);
	const ib = textIndex(b);
	return heapAllocString(arr, ta[ia] + tb[ib]);
}

// Appends in place to a heap string; the caller has checked that the destination is
// held once and that the suffix is not the destination itself.
export function heapAppend(arr: RaiserArrayHeap, dst: int64, suffix: RaiserValue): void {
	const texts = arr.strings.texts;
	const tb = textTable(arr, suffix);
	const i = textIndex(suffix);
	texts[handleIndex(dst) as number] += tb[i];
}

export function heapStringHeldOnce(arr: RaiserArrayHeap, v: RaiserValue): boolean {
	return handleHeapKind(v.intVal) == RaiserHeapKind.String && arr.strings.rc[handleIndex(v.intVal)] == 1;
}

export function heapStringLive(arr: RaiserArrayHeap): number {
	return arr.strings.texts.length - arr.strings.freeList.length;
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
// Arrays live on a side heap. RaiserValue with kind=Array stores an integer handle
// in intVal that indexes into the heap. Reference semantics (shared handle).

export interface RaiserArrayData {
	items: RaiserValue[];
	rc: int32;
	color: int32;
	viewOff: int64;
	viewLen: int32;
}

export interface RaiserArrayHeap {
	arrays: RaiserArrayData[];
	freeList: int64[];
	strings: RaiserStringHeap;
	boxes: RaiserBoxHeap;
}

export function createArrayHeap(): RaiserArrayHeap {
	const arrays: RaiserArrayData[] = [];
	const freeList: int64[] = [];
	return { arrays, freeList, strings: createStringHeap(), boxes: createBoxHeap() };
}

export function heapAllocArray(heap: RaiserArrayHeap): int64 {
	if (heap.freeList.length > 0) {
		const reused = heap.freeList[heap.freeList.length - 1];
		heap.freeList.length = heap.freeList.length - 1;
		const data = heap.arrays[reused];
		data.items.length = 0;
		data.rc = 0;
		data.color = 0;
		data.viewOff = -1;
		data.viewLen = 0;
		return makeHandle(reused, RaiserHeapKind.Array);
	}
	const idx = heap.arrays.length;
	const items: RaiserValue[] = [];
	const data: RaiserArrayData = { items, rc: 0, color: 0, viewOff: -1, viewLen: 0 };
	heap.arrays.push(data);
	return makeHandle(idx, RaiserHeapKind.Array);
}

// A view (a slice) owns no elements: its only item is the plain array it
// views, which keeps that array alive through RC, the collector and copyGraph.
export function heapAllocView(heap: RaiserArrayHeap, base: RaiserValue, off: int64, len: int32): int64 {
	const handle = heapAllocArray(heap);
	heapArrayPush(heap, handle, base);
	heap.arrays[handleIndex(handle)].viewOff = off;
	heap.arrays[handleIndex(handle)].viewLen = len;
	return handle;
}

export function heapArrayIsView(heap: RaiserArrayHeap, handle: int64): boolean {
	return heap.arrays[handleIndex(handle)].viewOff >= 0;
}

export function heapArrayLen(heap: RaiserArrayHeap, handle: int64): int32 {
	const data = heap.arrays[handleIndex(handle)];
	return data.viewOff >= 0 ? data.viewLen : data.items.length;
}

export function heapArrayGet(heap: RaiserArrayHeap, handle: int64, index: int64): RaiserValue {
	const data = heap.arrays[handleIndex(handle)];
	if (data.viewOff >= 0) return heap.arrays[handleIndex(data.items[0].intVal)].items[data.viewOff + index];
	return data.items[index];
}

export function heapArraySet(heap: RaiserArrayHeap, handle: int64, index: int64, val: RaiserValue): void {
	const data = heap.arrays[handleIndex(handle)];
	if (data.viewOff >= 0) {
		heap.arrays[handleIndex(data.items[0].intVal)].items[data.viewOff + index] = val;
		return;
	}
	// Deep copy to avoid pointer aliasing
	data.items[index] = val;
}

export function heapArrayPush(heap: RaiserArrayHeap, handle: int64, val: RaiserValue): void {
	// Deep copy to avoid pointer aliasing (register values are shared objects)
	const copy: RaiserValue = { kind: val.kind, intVal: val.intVal, floatVal: val.floatVal };
	heap.arrays[handleIndex(handle)].items.push(copy);
}

// The only shrink primitive on the heap: truncate drops references (arena
// regime — no per-value RC), extend pads with nil copies.
export function heapArraySetLen(heap: RaiserArrayHeap, handle: int64, newLen: int64): void {
	const items = heap.arrays[handleIndex(handle)].items;
	if (newLen < items.length) {
		items.shrink(newLen < 0 ? 0 : newLen);
	} else {
		while (items.length < newLen) {
			const nilCopy: RaiserValue = { kind: RaiserValueKind.Nil, intVal: 0, floatVal: 0.0 };
			items.push(nilCopy);
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
		boxes.items[reused].rc = 0;
		return makeHandle(reused, RaiserHeapKind.Box);
	}
	const index = boxes.items.length;
	boxes.items.push({ value: copy, rc: 0 });
	return makeHandle(index, RaiserHeapKind.Box);
}

export function heapBoxValue(heap: RaiserArrayHeap, handle: int64): RaiserValue {
	return heap.boxes.items[handleIndex(handle)].value;
}

export function heapBoxLive(heap: RaiserArrayHeap): number {
	return heap.boxes.items.length - heap.boxes.freeList.length;
}

// --- Object Heap ---
// Objects live on a side heap like arrays, their values inline. A slot inside the class
// layout is named by the class; only a field added past it carries its name on the object.
// Linear scan for field lookup (fast for typical <20 field objects).

export interface RaiserClassType {
	name: string;
	chain: string[];
	fields: string[];   // the layout NewObject lays out, so a field sits at the slot its type gives it
}

export const RAISER_NO_CLASS: RaiserClassType = { name: "", chain: [], fields: [] };

export interface RaiserObjectData {
	fields: RaiserValue[];
	added: string[];   // the names of fields[layout length..], in insertion order
	rc: int32;
	color: int32;
	classType: RaiserClassType;
}

// Whether a class is, or extends, the one a module constant names; the constant is read in place.
export function raiserIsInstance(classType: RaiserClassType, key: RaiserValue): boolean {
	when (mode != "danger") { if (key.kind != RaiserValueKind.String || !isConstHandle(key.intVal)) throw new Error("internal: a class key must be an interned string"); }
	const at = handleIndex(key.intVal) as number;
	for (let i = 0; i < classType.chain.length; i += 1) {
		if (classType.chain[i] == constTexts[at]) return true;
	}
	return false;
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
		data.fields.length = 0;
		data.added.length = 0;
		data.rc = 0;
		data.color = 0;
		data.classType = RAISER_NO_CLASS;
		return makeHandle(reused, RaiserHeapKind.Object);
	}
	const idx = heap.objects.length;
	const fields: RaiserValue[] = [];
	const added: string[] = [];
	const data: RaiserObjectData = { fields, added, rc: 0, color: 0, classType: RAISER_NO_CLASS };
	heap.objects.push(data);
	return makeHandle(idx, RaiserHeapKind.Object);
}

export function heapObjectFieldCount(heap: RaiserObjectHeap, handle: int64): int32 {
	const obj = heap.objects[handleIndex(handle)];
	return obj.fields.length;
}

export function fieldNameAt(obj: RaiserObjectData, index: number): string {
	const laid = obj.classType.fields.length;
	return index < laid ? obj.classType.fields[index] : obj.added[index - laid];
}

export function fieldNameIs(obj: RaiserObjectData, index: number, name: string): boolean {
	const laid = obj.classType.fields.length;
	return index < laid ? obj.classType.fields[index] == name : obj.added[index - laid] == name;
}

export function fieldIndex(obj: RaiserObjectData, name: string): number {
	for (let i = 0; i < obj.fields.length; i += 1) {
		if (fieldNameIs(obj, i, name)) return i;
	}
	return -1;
}

export function appendField(obj: RaiserObjectData, name: string, val: RaiserValue): void {
	if (obj.fields.length >= obj.classType.fields.length) obj.added.push(name);
	obj.fields.push(val);
}

export function heapObjectFieldNameAt(heap: RaiserObjectHeap, handle: int64, index: int64): string {
	const obj = heap.objects[handleIndex(handle)];
	if (index < 0 || index >= obj.fields.length) return "";
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
	const obj = heap.objects[handleIndex(handle)];
	if (index < 0 || index >= obj.fields.length) return { kind: RaiserValueKind.Nil, intVal: 0, floatVal: 0.0 };
	return obj.fields[index];
}

export function heapObjectGetField(heap: RaiserObjectHeap, handle: int64, name: string): RaiserValue {
	const obj = heap.objects[handleIndex(handle)];
	const i = fieldIndex(obj, name);
	return i >= 0 ? obj.fields[i] : raiserNil();
}

export function heapObjectSetField(heap: RaiserObjectHeap, handle: int64, name: string, val: RaiserValue): void {
	const obj = heap.objects[handleIndex(handle)];
	const i = fieldIndex(obj, name);
	if (i >= 0) obj.fields[i] = val;
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
		RaiserHeapKind.String => { const strings: Cursor<RaiserStringHeap> = arrHeap.strings; strings.rc[index] += 1; },
		RaiserHeapKind.Box => { const data: Cursor<RaiserBoxData> = arrHeap.boxes.items[index]; data.rc += 1; },
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
			const strings: Cursor<RaiserStringHeap> = arrHeap.strings;
			strings.rc[index] = strings.rc[index] - 1;
			if (strings.rc[index] <= 0) { strings.texts[index] = ""; strings.freeList.push(index); }
		},
		RaiserHeapKind.Box => {
			const data: Cursor<RaiserBoxData> = arrHeap.boxes.items[index];
			data.rc = data.rc - 1;
			if (data.rc <= 0) { rcDestroyBox(arrHeap, objHeap, index); }
		},
		RaiserHeapKind.None | RaiserHeapKind.ConstString | RaiserHeapKind.Future => {},
	}
}

function rcDestroyArray(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, index: int64): void {
	const data = arrHeap.arrays[index];
	for (const item of data.items) {
		rcDecref(arrHeap, objHeap, item);
	}
	data.items.length = 0;
	arrHeap.freeList.push(index);
}

function rcDestroyObject(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, index: int64): void {
	const data: Cursor<RaiserObjectData> = objHeap.objects[index];
	for (let i = 0; i < data.fields.length; i += 1) {
		if (data.fields[i].kind >= RaiserValueKind.String) rcDecrefHandle(arrHeap, objHeap, data.fields[i].intVal);
	}
	data.fields.length = 0;
	data.added.length = 0;
	objHeap.freeList.push(index);
}

function rcDestroyBox(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, index: int64): void {
	const data = arrHeap.boxes.items[index];
	rcDecref(arrHeap, objHeap, data.value);
	data.value = raiserNil();
	arrHeap.boxes.freeList.push(index);
}

// --- Cross-heap graph copy ---
// A handle indexes the heap that allocated it, so a value crossing into
// another heap must be materialized there. The src->dst handle map preserves
// sharing and terminates on cycles: a graph the collector exists to reclaim
// would otherwise recurse forever. Scalars carry their payload inline and
// Future handles index the VM-wide future table, so both cross unchanged.

export interface RaiserCopyMap {
	arrSrc: int64[];
	arrDst: int64[];
	objSrc: int64[];
	objDst: int64[];
	sourceWords: int64[] | null;
	sourceRefs: int64[] | null;
	sourceGlobals: RaiserValue[] | null;
	destGlobals: RaiserValue[] | null;
	slotSrc: RaiserValue[] | null;
	slotDst: RaiserValue[] | null;
}

export function createCopyMap(): RaiserCopyMap {
	const arrSrc: int64[] = [];
	const arrDst: int64[] = [];
	const objSrc: int64[] = [];
	const objDst: int64[] = [];
	return { arrSrc, arrDst, objSrc, objDst, sourceWords: null, sourceRefs: null, sourceGlobals: null, destGlobals: null, slotSrc: null, slotDst: null };
}

export function copyGraph(srcArr: RaiserArrayHeap, srcObj: RaiserObjectHeap, dstArr: RaiserArrayHeap, dstObj: RaiserObjectHeap, val: RaiserValue): RaiserValue {
	const map = createCopyMap();
	return copyGraphWith(srcArr, srcObj, dstArr, dstObj, val, map);
}

// The value in the register a RegAddr names: its intVal is (absolute rank << 3) | register class.
function copiedRegisterValue(map: RaiserCopyMap, address: int64): RaiserValue {
	const cls = (address & 7) as RaiserRegClass;
	const abs = address >> 3;
	const words = map.sourceWords;
	const refs = map.sourceRefs;
	if (words == null || refs == null) throw "internal: a copied slot address must have its source storage";
	if (cls == RaiserRegClass.Ref || cls == RaiserRegClass.Dyn) {
		if (abs >= refs.length) throw "internal: a copied slot address must have its source storage";
		const h = refs[abs];
		return handleValue(h);
	}
	if (abs >= words.length) throw "internal: a copied slot address must have its source storage";
	if (cls == RaiserRegClass.Word) return raiserInt(words[abs]);
	if (cls == RaiserRegClass.Bool) return raiserBool(words[abs] != 0);
	return raiserFloat(bitsToFloat(words[abs]));
}

export function copyGraphWith(srcArr: RaiserArrayHeap, srcObj: RaiserObjectHeap, dstArr: RaiserArrayHeap, dstObj: RaiserObjectHeap, val: RaiserValue, map: RaiserCopyMap): RaiserValue {
	if (val.kind == RaiserValueKind.RegAddr || val.kind == RaiserValueKind.GlobalAddr) {
		const source = map.sourceGlobals;
		if (val.kind == RaiserValueKind.GlobalAddr) {
			if (source == null || val.intVal < 0 || val.intVal >= source.length) throw "internal: a copied slot address must have its source storage";
			if (map.destGlobals != null) return raiserGlobalAddr(val.intVal);
		}
		let keys = map.slotSrc;
		let copies = map.slotDst;
		if (keys == null || copies == null) {
			keys = [];
			copies = [];
			map.slotSrc = keys;
			map.slotDst = copies;
		}
		for (let i = 0; i < keys.length; i += 1) {
			if (keys[i].kind == val.kind && keys[i].intVal == val.intVal) return copies[i];
		}
		const handle = heapAllocArray(dstArr);
		const address = raiserElemAddr(handle, 0);
		keys.push(val);
		copies.push(address);
		const held = val.kind == RaiserValueKind.RegAddr ? copiedRegisterValue(map, val.intVal) : source![val.intVal];
		const copied = copyGraphWith(srcArr, srcObj, dstArr, dstObj, held, map);
		heapArrayPush(dstArr, handle, copied);
		rcIncref(dstArr, dstObj, copied);
		return address;
	}
	if (val.kind == RaiserValueKind.Array || val.kind == RaiserValueKind.ElemAddr) {
		for (let i = 0; i < map.arrSrc.length; i = i + 1) {
			if (map.arrSrc[i] == val.intVal) {
				return val.kind == RaiserValueKind.Array ? raiserArray(map.arrDst[i]) : raiserElemAddr(map.arrDst[i], val.floatVal as int64);
			}
		}
		if (handleIndex(val.intVal) >= srcArr.arrays.length) {
			if (val.kind == RaiserValueKind.ElemAddr) throw "internal: a copied element address must have an array owner";
			return raiserNil();
		}
		const dstHandle = heapAllocArray(dstArr);
		map.arrSrc.push(val.intVal);
		map.arrDst.push(dstHandle);
		const items = srcArr.arrays[handleIndex(val.intVal)].items;
		for (let i = 0; i < items.length; i = i + 1) {
			const copied = copyGraphWith(srcArr, srcObj, dstArr, dstObj, items[i], map);
			heapArrayPush(dstArr, dstHandle, copied);
			rcIncref(dstArr, dstObj, copied);
		}
		dstArr.arrays[handleIndex(dstHandle)].viewOff = srcArr.arrays[handleIndex(val.intVal)].viewOff;
		dstArr.arrays[handleIndex(dstHandle)].viewLen = srcArr.arrays[handleIndex(val.intVal)].viewLen;
		return val.kind == RaiserValueKind.Array ? raiserArray(dstHandle) : raiserElemAddr(dstHandle, val.floatVal as int64);
	}
	if (val.kind == RaiserValueKind.Object || val.kind == RaiserValueKind.FieldAddr) {
		for (let i = 0; i < map.objSrc.length; i = i + 1) {
			if (map.objSrc[i] == val.intVal) {
				return val.kind == RaiserValueKind.Object ? raiserObject(map.objDst[i]) : raiserFieldAddrAt(map.objDst[i], val.floatVal as int64);
			}
		}
		if (handleIndex(val.intVal) >= srcObj.objects.length) {
			if (val.kind == RaiserValueKind.FieldAddr) throw "internal: a copied field address must have an object owner";
			return raiserNil();
		}
		const dstHandle = heapAllocObject(dstObj);
		dstObj.objects[handleIndex(dstHandle)].classType = srcObj.objects[handleIndex(val.intVal)].classType;
		map.objSrc.push(val.intVal);
		map.objDst.push(dstHandle);
		const source = srcObj.objects[handleIndex(val.intVal)];
		for (let i = 0; i < source.fields.length; i = i + 1) {
			const copied = copyGraphWith(srcArr, srcObj, dstArr, dstObj, source.fields[i], map);
			appendField(dstObj.objects[handleIndex(dstHandle)], fieldNameAt(source, i), copied);
			rcIncref(dstArr, dstObj, copied);
		}
		return val.kind == RaiserValueKind.Object ? raiserObject(dstHandle) : raiserFieldAddrAt(dstHandle, val.floatVal as int64);
	}
	if (val.kind == RaiserValueKind.String && handleHeapKind(val.intVal) == RaiserHeapKind.String) return heapAllocString(dstArr, heapStringText(srcArr, val));
	if (val.kind == RaiserValueKind.Box) {
		const inner = copyGraphWith(srcArr, srcObj, dstArr, dstObj, heapBoxValue(srcArr, val.intVal), map);
		const copy = heapAllocBox(dstArr, inner);
		rcIncref(dstArr, dstObj, inner);
		return { kind: RaiserValueKind.Box, intVal: copy, floatVal: 0.0 };
	}
	return val;
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
	const refs: int64[] = [heapAllocString(sArr, "source").intVal];
	const owner = heapAllocArray(sArr);
	heapArrayPush(sArr, owner, raiserRegAddr(1));
	heapArrayPush(sArr, owner, raiserRegAddr(1));
	const map = createCopyMap();
	map.sourceWords = [];
	map.sourceRefs = refs;
	const copied = copyGraphWith(sArr, sObj, dArr, dObj, raiserArray(owner), map);
	const first = heapArrayGet(dArr, copied.intVal, 0);
	const second = heapArrayGet(dArr, copied.intVal, 1);
	assert heapStringText(dArr, heapArrayGet(dArr, first.intVal, first.floatVal as int64)) == "source";
	heapArraySet(dArr, first.intVal, first.floatVal as int64, heapAllocString(dArr, "destination"));
	assert heapStringText(dArr, heapArrayGet(dArr, second.intVal, second.floatVal as int64)) == "destination";
	assert heapStringText(sArr, handleValue(refs[0])) == "source";
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
	assert handleIndex(text.intVal) == 0 && sArr.strings.texts.length == 1 && dArr.strings.texts.length == 1;
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

// --- ORC refcount tests ---
test "rc incref/decref frees at zero" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const h = heapAllocArray(arr);
	const v = raiserArray(h);
	rcIncref(arr, obj, v);
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
	rcIncref(arr, obj, childVal);
	heapArrayPush(arr, parent, childVal);
	const parentVal = raiserArray(parent);
	rcIncref(arr, obj, parentVal);
	assert arr.arrays[handleIndex(child)].rc == 1;
	rcDecref(arr, obj, parentVal);
	assert arr.freeList.length == 2;
}

test "alloc reuses free-list slot" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const h1 = heapAllocArray(arr);
	const v = raiserArray(h1);
	rcIncref(arr, obj, v);
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
	rcIncref(arr, obj, childVal);
	heapObjectSetField(obj, o, "kids", childVal);
	const oVal = raiserObject(o);
	rcIncref(arr, obj, oVal);
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
	heap.strings = createStringHeap();
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
	rcIncref(arr, obj, s);
	rcDecref(arr, obj, s);
	assert heapStringLive(arr) == 1;
	rcDecref(arr, obj, s);
	assert heapStringLive(arr) == 0;
	const again = heapAllocString(arr, "xyz");
	assert again.intVal == s.intVal;
	assert heapStringText(arr, again) == "xyz";
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
	assert heapAllocString(heap, "").intVal == makeHandle(0, RaiserHeapKind.ConstString);
}

test "destroying a container releases its strings" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const holder = heapAllocArray(arr);
	const s = heapAllocString(arr, "kept");
	heapArrayPush(arr, holder, s);
	rcIncref(arr, obj, s);
	rcIncref(arr, obj, raiserArray(holder));
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
	assert handleHeapKind(strand.intVal) == RaiserHeapKind.String && handleIndex(strand.intVal) == 0;
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
	rcIncref(arr, obj, text);
	const box: RaiserValue = { kind: RaiserValueKind.Box, intVal: handle, floatVal: 0.0 };
	rcIncref(arr, obj, box);
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

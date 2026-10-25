// Raiser VM — Value representation
// Day-1: flat tagged interface. No NaN-boxing.
// Bool stored as intVal (0/1) to keep the interface simple.

import { RaiserRegClass, regClassLetter, TYPED_SLOTS } from "./bytecode";

@include("runtime/core/hashBits.h");
extern function msBitsFloat64(u: int64): float64;
extern function msFloat64Bits(d: float64): int64;


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

export function constNameIds(names: string[]): int64[] {
	const ids: int64[] = [];
	for (const n of names) ids.push(constHandle(n));
	return ids;
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

// The handle forms of the readers above, for an operand a typed Ref register holds: the heap kind
// in the handle picks the table, and a handle that names no string reads as "" like a non-String value.
function handleTexts(arr: RaiserArrayHeap, h: int64): string[] {
	return handleHeapKind(h) == RaiserHeapKind.String ? arr.strings.texts : constTexts;
}

function handleTextIndex(h: int64): number {
	const kind = handleHeapKind(h);
	return kind == RaiserHeapKind.String || kind == RaiserHeapKind.ConstString ? handleIndex(h) as number : 0;
}

export function heapConcatHandles(arr: RaiserArrayHeap, a: int64, b: int64): int64 {
	return heapAllocString(arr, handleTexts(arr, a)[handleTextIndex(a)] + handleTexts(arr, b)[handleTextIndex(b)]).intVal;
}

export function heapAppendHandle(arr: RaiserArrayHeap, dst: int64, suffix: int64): void {
	arr.strings.texts[handleIndex(dst) as number] += handleTexts(arr, suffix)[handleTextIndex(suffix)];
}

export function heapHandleHeldOnce(arr: RaiserArrayHeap, h: int64): boolean {
	return handleHeapKind(h) == RaiserHeapKind.String && arr.strings.rc[handleIndex(h)] == 1;
}

// -1 outside the text, the way msStringByteAt answers.
export function heapHandleCharCodeAt(arr: RaiserArrayHeap, h: int64, idx: int64): int64 {
	const t = handleTexts(arr, h);
	const i = handleTextIndex(h);
	if (idx < 0 || idx >= (t[i].length as int64)) return -1;
	return t[i].charCodeAt(idx as int32) as int64;
}

export function heapHandleByteAt(arr: RaiserArrayHeap, h: int64, idx: int64): int64 {
	const t = handleTexts(arr, h);
	const i = handleTextIndex(h);
	if (idx < 0 || idx >= (t[i].byteLength as int64)) return -1;
	return t[i].byteAt(idx as int32) as int64;
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

// An array holds its elements in the class its NewArray names: a Word, Float or Bool element as raw
// bits and a Ref element as its handle (0 is nil), both in `words`, or any other element as a value in
// `items`. A view holds only the array it stands on, as the one value of `items`.
export interface RaiserArrayData {
	items: RaiserValue[];
	words: int64[];
	elemClass: RaiserRegClass;
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
	return heapAllocArrayOf(heap, RaiserRegClass.Dyn);
}

export function heapAllocArrayOf(heap: RaiserArrayHeap, elemClass: RaiserRegClass): int64 {
	if (heap.freeList.length > 0) {
		const reused = heap.freeList[heap.freeList.length - 1];
		heap.freeList.length = heap.freeList.length - 1;
		const data = heap.arrays[reused];
		data.items.length = 0;
		data.words.length = 0;
		data.elemClass = elemClass;
		data.rc = 0;
		data.color = 0;
		data.viewOff = -1;
		data.viewLen = 0;
		return makeHandle(reused, RaiserHeapKind.Array);
	}
	const idx = heap.arrays.length;
	const items: RaiserValue[] = [];
	const words: int64[] = [];
	const data: RaiserArrayData = { items, words, elemClass, rc: 0, color: 0, viewOff: -1, viewLen: 0 };
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

// The number of values the array holds: its elements, or the one array a view stands on.
export function arrayHeldCount(data: RaiserArrayData): number {
	return data.elemClass == RaiserRegClass.Dyn ? data.items.length : data.words.length;
}

// Whether any held value can be a heap reference.
export function arrayHoldsHandles(data: RaiserArrayData): boolean {
	return data.elemClass == RaiserRegClass.Dyn || data.elemClass == RaiserRegClass.Ref;
}

// The value held at `index`, read in the array's element class.
export function arrayHeldAt(data: RaiserArrayData, index: number): RaiserValue {
	return match (data.elemClass) {
		RaiserRegClass.Dyn => data.items[index],
		RaiserRegClass.Word => raiserInt(data.words[index]),
		RaiserRegClass.Float => raiserFloat(msBitsFloat64(data.words[index])),
		RaiserRegClass.Bool => raiserBool(data.words[index] != 0),
		RaiserRegClass.Ref => handleValue(data.words[index]),
	};
}

// "" when the array can hold the value, otherwise why it cannot.
export function arrayRefusal(data: RaiserArrayData, val: RaiserValue): string {
	if (slotFits(data.elemClass, val)) return "";
	return `internal: an array of ${regClassLetter(data.elemClass)} elements got a value of kind ${val.kind}`;
}

// Stores a value at `index` without counting: the array takes over the caller's count of it.
export function arrayHeldStore(data: RaiserArrayData, index: number, val: RaiserValue): void {
	if (data.elemClass == RaiserRegClass.Dyn) {
		data.items[index] = val;
		return;
	}
	const refused = arrayRefusal(data, val);
	if (refused != "") throw new Error(refused);
	data.words[index] = slotWord(data.elemClass, val);
}

function arrayHeldPush(data: RaiserArrayData, val: RaiserValue): void {
	if (data.elemClass == RaiserRegClass.Dyn) {
		const copy: RaiserValue = { kind: val.kind, intVal: val.intVal, floatVal: val.floatVal };
		data.items.push(copy);
		return;
	}
	const refused = arrayRefusal(data, val);
	if (refused != "") throw new Error(refused);
	data.words.push(slotWord(data.elemClass, val));
}

// The array a view stands on, or the array itself.
export function arrayBaseOf(heap: RaiserArrayHeap, data: RaiserArrayData): RaiserArrayData {
	return data.viewOff >= 0 ? heap.arrays[handleIndex(data.items[0].intVal)] : data;
}

export function heapArrayLen(heap: RaiserArrayHeap, handle: int64): int32 {
	const data = heap.arrays[handleIndex(handle)];
	return data.viewOff >= 0 ? data.viewLen : arrayHeldCount(data) as int32;
}

export function heapArrayGet(heap: RaiserArrayHeap, handle: int64, index: int64): RaiserValue {
	const data = heap.arrays[handleIndex(handle)];
	if (data.viewOff >= 0) return arrayHeldAt(arrayBaseOf(heap, data), (data.viewOff + index) as number);
	return arrayHeldAt(data, index as number);
}

export function heapArraySet(heap: RaiserArrayHeap, handle: int64, index: int64, val: RaiserValue): void {
	const data = heap.arrays[handleIndex(handle)];
	if (data.viewOff >= 0) {
		arrayHeldStore(arrayBaseOf(heap, data), (data.viewOff + index) as number, val);
		return;
	}
	arrayHeldStore(data, index as number, val);
}

export function heapArrayPush(heap: RaiserArrayHeap, handle: int64, val: RaiserValue): void {
	arrayHeldPush(heap.arrays[handleIndex(handle)], val);
}

// The only shrink primitive on the heap: truncate drops references (arena
// regime — no per-value RC), extend pads with the zero of the element class.
export function heapArraySetLen(heap: RaiserArrayHeap, handle: int64, newLen: int64): void {
	const data = heap.arrays[handleIndex(handle)];
	const target = newLen < 0 ? 0 : newLen;
	if (data.elemClass != RaiserRegClass.Dyn) {
		if (target < data.words.length) data.words.shrink(target);
		while (data.words.length < target) data.words.push(0);
		return;
	}
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
}

// A class type with its zero object computed once, so NewObject copies it instead of laying out each slot.
export function createClassType(name: string, depth: int32, display: int64[], fields: string[], kinds: RaiserRegClass[]): RaiserClassType {
	const zeroSlots: int64[] = [];
	let zeroWordSlots: int64 = 0;
	let zeroRefSlots: int64 = 0;
	let dynCount: int32 = 0;
	for (let i = 0; i < fields.length; i += 1) {
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
	return { name, depth, display, fields, fieldIds: constNameIds(fields), kinds, zeroSlots, zeroWordSlots, zeroRefSlots, dynCount };
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
		data.rc = 0;
		data.color = 0;
		data.classType = RAISER_NO_CLASS;
		return makeHandle(reused, RaiserHeapKind.Object);
	}
	const idx = heap.objects.length;
	const slots: int64[] = [];
	const values: RaiserValue[] = [];
	const added: string[] = [];
	const data: RaiserObjectData = { slots, wordSlots: 0, refSlots: 0, values, added, rc: 0, color: 0, classType: RAISER_NO_CLASS };
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
	return objectFieldCount(heap.objects[handleIndex(handle)]);
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
	const obj = heap.objects[handleIndex(handle)];
	if (index < 0 || index >= objectFieldCount(obj)) return { kind: RaiserValueKind.Nil, intVal: 0, floatVal: 0.0 };
	return fieldValueAt(obj, index as number);
}

export function heapObjectGetField(heap: RaiserObjectHeap, handle: int64, name: string): RaiserValue {
	const obj = heap.objects[handleIndex(handle)];
	const i = fieldIndex(obj, name);
	return i >= 0 ? fieldValueAt(obj, i) : raiserNil();
}

export function heapObjectSetField(heap: RaiserObjectHeap, handle: int64, name: string, val: RaiserValue): void {
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
			const left = strings.rc[index] - 1;
			strings.rc[index] = left;
			if (left <= 0) { rcDestroyString(arrHeap, index); }
		},
		RaiserHeapKind.Box => {
			const data: Cursor<RaiserBoxData> = arrHeap.boxes.items[index];
			data.rc = data.rc - 1;
			if (data.rc <= 0) { rcDestroyBox(arrHeap, objHeap, index); }
		},
		RaiserHeapKind.None | RaiserHeapKind.ConstString | RaiserHeapKind.Future => {},
	}
}

@noinline
function rcDestroyString(arrHeap: RaiserArrayHeap, index: int64): void {
	const strings: Cursor<RaiserStringHeap> = arrHeap.strings;
	strings.texts[index] = "";
	strings.freeList.push(index);
}

@noinline
function rcDestroyArray(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, index: int64): void {
	const data = arrHeap.arrays[index];
	if (data.elemClass == RaiserRegClass.Ref) {
		for (const handle of data.words) {
			if (handle != 0) rcDecrefHandle(arrHeap, objHeap, handle);
		}
	}
	for (const item of data.items) {
		rcDecref(arrHeap, objHeap, item);
	}
	data.items.length = 0;
	data.words.length = 0;
	arrHeap.freeList.push(index);
}

@noinline
function rcDestroyObject(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, index: int64): void {
	const data: Cursor<RaiserObjectData> = objHeap.objects[index];
	const kinds = data.classType.kinds;
	for (let i = 0; i < data.slots.length; i += 1) {
		if (kinds[i] == RaiserRegClass.Ref && data.slots[i] != 0) rcDecrefHandle(arrHeap, objHeap, data.slots[i]);
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
	sourceWords: int64[] | null;
	sourceRefs: int64[] | null;
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
		sourceWords: null,
		sourceRefs: null,
		sourceGlobals: null,
		destGlobals: null,
	};
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
	if (words == null || refs == null) throw new Error("internal: a copied slot address must have its source storage");
	if (cls == RaiserRegClass.Ref || cls == RaiserRegClass.Dyn) {
		if (abs >= refs.length) throw new Error("internal: a copied slot address must have its source storage");
		const h = refs[abs];
		return handleValue(h);
	}
	if (abs >= words.length) throw new Error("internal: a copied slot address must have its source storage");
	if (cls == RaiserRegClass.Word) return raiserInt(words[abs]);
	if (cls == RaiserRegClass.Bool) return raiserBool(words[abs] != 0);
	return raiserFloat(bitsToFloat(words[abs]));
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
	slots.set(val.intVal, handle);
	const held = isRegister ? copiedRegisterValue(map, val.intVal) : source![val.intVal];
	map.jobs.push({ kind: RaiserCopyKind.Slot, source: held, dst: handle });
	return raiserElemAddr(handle, 0);
}

function copyArrayShell(srcArr: RaiserArrayHeap, dstArr: RaiserArrayHeap, val: RaiserValue, map: RaiserCopyMap): RaiserValue {
	const isArray = val.kind == RaiserValueKind.Array;
	if (map.arrays.has(val.intVal)) {
		const known = map.arrays.get(val.intVal)!;
		return isArray ? raiserArray(known) : raiserElemAddr(known, val.floatVal as int64);
	}
	if (handleIndex(val.intVal) >= srcArr.arrays.length) {
		if (!isArray) throw new Error("internal: a copied element address must have an array owner");
		return raiserNil();
	}
	const dstHandle = heapAllocArrayOf(dstArr, srcArr.arrays[handleIndex(val.intVal)].elemClass);
	map.arrays.set(val.intVal, dstHandle);
	map.jobs.push({ kind: RaiserCopyKind.Array, source: raiserArray(val.intVal), dst: dstHandle });
	return isArray ? raiserArray(dstHandle) : raiserElemAddr(dstHandle, val.floatVal as int64);
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
	map.objects.set(val.intVal, dstHandle);
	map.jobs.push({ kind: RaiserCopyKind.Object, source: raiserObject(val.intVal), dst: dstHandle });
	return isObject ? raiserObject(dstHandle) : raiserFieldAddrAt(dstHandle, val.floatVal as int64);
}

// The destination of one value: a scalar is itself, a node is its destination shell, filled by a queued job.
function copyShell(srcArr: RaiserArrayHeap, srcObj: RaiserObjectHeap, dstArr: RaiserArrayHeap, dstObj: RaiserObjectHeap, val: RaiserValue, map: RaiserCopyMap): RaiserValue {
	if (val.kind == RaiserValueKind.RegAddr || val.kind == RaiserValueKind.GlobalAddr) return copySlotShell(dstArr, val, map);
	if (val.kind == RaiserValueKind.Array || val.kind == RaiserValueKind.ElemAddr) return copyArrayShell(srcArr, dstArr, val, map);
	if (val.kind == RaiserValueKind.Object || val.kind == RaiserValueKind.FieldAddr) return copyObjectShell(srcObj, dstObj, val, map);
	if (val.kind == RaiserValueKind.String && handleHeapKind(val.intVal) == RaiserHeapKind.String) return heapAllocString(dstArr, heapStringText(srcArr, val));
	if (val.kind == RaiserValueKind.Box) {
		const inner = copyShell(srcArr, srcObj, dstArr, dstObj, heapBoxValue(srcArr, val.intVal), map);
		const copy = heapAllocBox(dstArr, inner);
		rcIncref(dstArr, dstObj, inner);
		return { kind: RaiserValueKind.Box, intVal: copy, floatVal: 0.0 };
	}
	return val;
}

function fillArray(srcArr: RaiserArrayHeap, srcObj: RaiserObjectHeap, dstArr: RaiserArrayHeap, dstObj: RaiserObjectHeap, job: RaiserCopyJob, map: RaiserCopyMap): void {
	const source = srcArr.arrays[handleIndex(job.source.intVal)];
	const held = arrayHeldCount(source);
	for (let i = 0; i < held; i = i + 1) {
		const copied = copyShell(srcArr, srcObj, dstArr, dstObj, arrayHeldAt(source, i), map);
		heapArrayPush(dstArr, job.dst, copied);
		rcIncref(dstArr, dstObj, copied);
	}
	dstArr.arrays[handleIndex(job.dst)].viewOff = source.viewOff;
	dstArr.arrays[handleIndex(job.dst)].viewLen = source.viewLen;
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

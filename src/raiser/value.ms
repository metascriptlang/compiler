// Raiser VM — Value representation
// Day-1: flat tagged interface. No NaN-boxing.
// Bool stored as intVal (0/1) to keep the interface simple.


export enum RaiserValueKind {
	Nil,
	Bool,
	Int,        // i64 integer
	Float,      // f64 float
	String,     // string value
	Array,      // handle into RaiserArrayHeap
	Object,     // handle into RaiserObjectHeap
	Future,     // handle into RaiserFutures — the VM's msFuture
	RegAddr,    // address of a register slot: intVal = absolute slot index
	GlobalAddr, // address of a global: intVal = global index
	ElemAddr,   // address of an array element: intVal = array handle, floatVal = index
	FieldAddr,  // address of an object field: intVal = object handle, floatVal = field name constant handle
}

// Flat interface — all fields always present, unused ones zeroed.
// Matches project convention (see checker/types.ms Type interface).
// A String's text lives on a string heap: intVal >= 0 indexes the running
// strand's heap, intVal < 0 names a constant (see "String Heap" below).
export interface RaiserValue {
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
constIndex.set("", -1);

function constHandle(text: string): int64 {
	if (constIndex.has(text)) return constIndex.get(text)!;
	constTexts.push(text);
	const handle = -(constTexts.length as int64);
	constIndex.set(text, handle);
	return handle;
}

function constText(handle: int64): string {
	// bound first: .inbox/compiler/2026-10-19-return-of-an-array-element-leaks-a-reference.md
	const text = constTexts[(-handle - 1) as number];
	return text;
}

// Module constants and field names are interned, so reading one needs no heap.
export function constStringText(v: RaiserValue): string {
	if (v.kind != RaiserValueKind.String || v.intVal >= 0) throw new Error("internal: a module constant must be an interned string");
	return constText(v.intVal);
}

export function constStringCount(): number {
	return constTexts.length;
}

export function heapAllocString(arr: RaiserArrayHeap, text: string): RaiserValue {
	if (text.length == 0) return { kind: RaiserValueKind.String, intVal: -1, floatVal: 0.0 };
	const heap = arr.strings;
	let handle: int64 = 0;
	if (heap.freeList.length > 0) {
		handle = heap.freeList[heap.freeList.length - 1];
		heap.freeList.length = heap.freeList.length - 1;
		heap.texts[handle] = text;
		heap.rc[handle] = 0;
	} else {
		handle = heap.texts.length;
		heap.texts.push(text);
		heap.rc.push(0);
	}
	return { kind: RaiserValueKind.String, intVal: handle, floatVal: 0.0 };
}

// A string the host stores into a container it built: the container holds the first count.
export function heapAllocStoredString(arr: RaiserArrayHeap, text: string): RaiserValue {
	const v = heapAllocString(arr, text);
	if (v.intVal >= 0) arr.strings.rc[v.intVal] = 1;
	return v;
}

// A value that is not a String reads as "", the way an unset text field always did.
export function heapStringText(arr: RaiserArrayHeap, v: RaiserValue): string {
	if (v.kind != RaiserValueKind.String) return "";
	if (v.intVal < 0) return constText(v.intVal);
	// bound first: .inbox/compiler/2026-10-19-return-of-an-array-element-leaks-a-reference.md
	const text = arr.strings.texts[v.intVal];
	return text;
}

export function heapStringLive(arr: RaiserArrayHeap): number {
	return arr.strings.texts.length - arr.strings.freeList.length;
}

// --- Deep copy (avoids pointer aliasing) ---

export function copyValueInto(dst: RaiserValue, src: RaiserValue): void {
	dst.kind = src.kind;
	dst.intVal = src.intVal;
	dst.floatVal = src.floatVal;
}

// --- Accessors ---

export function raiserToInt(v: RaiserValue): number {
	return v.intVal as number;
}

export function raiserToFloat(v: RaiserValue): number {
	if (v.kind == RaiserValueKind.Float) return v.floatVal;
	return v.intVal as float64;
}

export function raiserToBool(arr: RaiserArrayHeap, v: RaiserValue): boolean {
	return match (v.kind) {
		RaiserValueKind.Nil => false,
		RaiserValueKind.Bool | RaiserValueKind.Int => v.intVal != 0,
		RaiserValueKind.Float => v.floatVal != 0.0 && v.floatVal == v.floatVal,
		RaiserValueKind.String => heapStringText(arr, v).length > 0,
		RaiserValueKind.Array | RaiserValueKind.Object | RaiserValueKind.Future => true,
		RaiserValueKind.RegAddr | RaiserValueKind.GlobalAddr | RaiserValueKind.ElemAddr | RaiserValueKind.FieldAddr => true,
	};
}

export function raiserIsNil(v: RaiserValue): boolean {
	return v.kind == RaiserValueKind.Nil;
}

// --- Equality ---

export function raiserEqual(arr: RaiserArrayHeap, a: RaiserValue, b: RaiserValue): boolean {
	if (a.kind != b.kind) return false;
	return match (a.kind) {
		RaiserValueKind.Nil => true,
		RaiserValueKind.Bool | RaiserValueKind.Int | RaiserValueKind.Array | RaiserValueKind.Object => a.intVal == b.intVal,
		RaiserValueKind.Float => a.floatVal == b.floatVal,
		RaiserValueKind.String => heapStringText(arr, a) == heapStringText(arr, b),
		_ => false,
	};
}

// --- Debug ---

export function raiserToString(arr: RaiserArrayHeap, v: RaiserValue): string {
	return match (v.kind) {
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
}

export function createArrayHeap(): RaiserArrayHeap {
	const arrays: RaiserArrayData[] = [];
	const freeList: int64[] = [];
	return { arrays, freeList, strings: createStringHeap() };
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
		return reused;
	}
	const idx = heap.arrays.length;
	const items: RaiserValue[] = [];
	const data: RaiserArrayData = { items, rc: 0, color: 0, viewOff: -1, viewLen: 0 };
	heap.arrays.push(data);
	return idx;
}

// A view (a slice) owns no elements: its only item is the plain array it
// views, which keeps that array alive through RC, the collector and copyGraph.
export function heapAllocView(heap: RaiserArrayHeap, base: RaiserValue, off: int64, len: int32): int64 {
	const handle = heapAllocArray(heap);
	heapArrayPush(heap, handle, base);
	heap.arrays[handle].viewOff = off;
	heap.arrays[handle].viewLen = len;
	return handle;
}

export function heapArrayIsView(heap: RaiserArrayHeap, handle: int64): boolean {
	return heap.arrays[handle].viewOff >= 0;
}

export function heapArrayLen(heap: RaiserArrayHeap, handle: int64): int32 {
	const data = heap.arrays[handle];
	return data.viewOff >= 0 ? data.viewLen : data.items.length;
}

export function heapArrayGet(heap: RaiserArrayHeap, handle: int64, index: int64): RaiserValue {
	const data = heap.arrays[handle];
	if (data.viewOff >= 0) return heap.arrays[data.items[0].intVal].items[data.viewOff + index];
	return data.items[index];
}

export function heapArraySet(heap: RaiserArrayHeap, handle: int64, index: int64, val: RaiserValue): void {
	const data = heap.arrays[handle];
	if (data.viewOff >= 0) {
		copyValueInto(heap.arrays[data.items[0].intVal].items[data.viewOff + index], val);
		return;
	}
	// Deep copy to avoid pointer aliasing
	copyValueInto(data.items[index], val);
}

export function heapArrayPush(heap: RaiserArrayHeap, handle: int64, val: RaiserValue): void {
	// Deep copy to avoid pointer aliasing (register values are shared objects)
	const copy: RaiserValue = { kind: val.kind, intVal: val.intVal, floatVal: val.floatVal };
	heap.arrays[handle].items.push(copy);
}

// The only shrink primitive on the heap: truncate drops references (arena
// regime — no per-value RC), extend pads with nil copies.
export function heapArraySetLen(heap: RaiserArrayHeap, handle: int64, newLen: int64): void {
	const items = heap.arrays[handle].items;
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
	assert h == 0;
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

// --- Object Heap ---
// Objects live on a side heap like arrays. Fields stored as name-value pairs.
// Linear scan for field lookup (fast for typical <20 field objects).

export interface RaiserObjectField {
	name: string;
	value: RaiserValue;
}

export interface RaiserClassType {
	name: string;
	chain: string[];
}

export const RAISER_NO_CLASS: RaiserClassType = { name: "", chain: [] };

export interface RaiserObjectData {
	fields: RaiserObjectField[];
	rc: int32;
	color: int32;
	classType: RaiserClassType;
}

export function raiserIsInstance(classType: RaiserClassType, key: string): boolean {
	for (const k of classType.chain) {
		if (k == key) return true;
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
		const data = heap.objects[reused];
		data.fields.length = 0;
		data.rc = 0;
		data.color = 0;
		data.classType = RAISER_NO_CLASS;
		return reused;
	}
	const idx = heap.objects.length;
	const fields: RaiserObjectField[] = [];
	const data: RaiserObjectData = { fields, rc: 0, color: 0, classType: RAISER_NO_CLASS };
	heap.objects.push(data);
	return idx;
}

export function heapObjectFieldCount(heap: RaiserObjectHeap, handle: int64): int32 {
	const obj = heap.objects[handle];
	return obj.fields.length;
}

export function heapObjectFieldNameAt(heap: RaiserObjectHeap, handle: int64, index: int64): string {
	const obj = heap.objects[handle];
	if (index < 0 || index >= obj.fields.length) return "";
	return obj.fields[index].name;
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
	const obj = heap.objects[handle];
	if (index < 0 || index >= obj.fields.length) return { kind: RaiserValueKind.Nil, intVal: 0, floatVal: 0.0 };
	return obj.fields[index].value;
}

export function heapObjectGetField(heap: RaiserObjectHeap, handle: int64, name: string): RaiserValue {
	const obj = heap.objects[handle];
	for (const field of obj.fields) {
		if (field.name == name) {
			return field.value;
		}
	}
	// Field not found — return nil
	return { kind: RaiserValueKind.Nil, intVal: 0, floatVal: 0.0 };
}

export function heapObjectSetField(heap: RaiserObjectHeap, handle: int64, name: string, val: RaiserValue): void {
	const obj = heap.objects[handle];
	// Check if field already exists
	for (const field of obj.fields) {
		if (field.name == name) {
			// Update existing field (deep copy)
			copyValueInto(field.value, val);
			return;
		}
	}
	// Add new field (deep copy value)
	const copy: RaiserValue = { kind: val.kind, intVal: val.intVal, floatVal: val.floatVal };
	const field: RaiserObjectField = { name, value: copy };
	obj.fields.push(field);
}

// --- ORC refcount primitives ---
// Array, Object and String are heap refs; a ref can hold cross-heap children, so both
// heaps are threaded through. Destroy is generic (the heap object is self-describing).

export function rcIncref(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, held: RaiserValue): void {
	rcIncrefHandle(arrHeap, objHeap, held.kind, held.intVal);
}

export function rcDecref(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, held: RaiserValue): void {
	rcDecrefHandle(arrHeap, objHeap, held.kind, held.intVal);
}

export function rcIncrefHandle(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, kind: RaiserValueKind, handle: int64): void {
	if (kind == RaiserValueKind.Array || kind == RaiserValueKind.ElemAddr) {
		arrHeap.arrays[handle].rc = arrHeap.arrays[handle].rc + 1;
	} else if (kind == RaiserValueKind.Object || kind == RaiserValueKind.FieldAddr) {
		objHeap.objects[handle].rc = objHeap.objects[handle].rc + 1;
	} else if (kind == RaiserValueKind.String && handle >= 0) {
		arrHeap.strings.rc[handle] = arrHeap.strings.rc[handle] + 1;
	}
}

export function rcDecrefHandle(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, kind: RaiserValueKind, handle: int64): void {
	if (kind == RaiserValueKind.Array || kind == RaiserValueKind.ElemAddr) {
		const data = arrHeap.arrays[handle];
		data.rc = data.rc - 1;
		if (data.rc <= 0) { rcDestroyArray(arrHeap, objHeap, handle); }
	} else if (kind == RaiserValueKind.Object || kind == RaiserValueKind.FieldAddr) {
		const data = objHeap.objects[handle];
		data.rc = data.rc - 1;
		if (data.rc <= 0) { rcDestroyObject(arrHeap, objHeap, handle); }
	} else if (kind == RaiserValueKind.String && handle >= 0) {
		const strings = arrHeap.strings;
		strings.rc[handle] = strings.rc[handle] - 1;
		if (strings.rc[handle] <= 0) { strings.texts[handle] = ""; strings.freeList.push(handle); }
	}
}

function rcDestroyArray(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, handle: int64): void {
	const data = arrHeap.arrays[handle];
	for (const item of data.items) {
		rcDecref(arrHeap, objHeap, item);
	}
	data.items.length = 0;
	arrHeap.freeList.push(handle);
}

function rcDestroyObject(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, handle: int64): void {
	const data = objHeap.objects[handle];
	for (const field of data.fields) {
		rcDecref(arrHeap, objHeap, field.value);
	}
	data.fields.length = 0;
	objHeap.freeList.push(handle);
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
	sourceRegs: RaiserValue[] | null;
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
	return { arrSrc, arrDst, objSrc, objDst, sourceRegs: null, sourceGlobals: null, destGlobals: null, slotSrc: null, slotDst: null };
}

export function copyGraph(srcArr: RaiserArrayHeap, srcObj: RaiserObjectHeap, dstArr: RaiserArrayHeap, dstObj: RaiserObjectHeap, val: RaiserValue): RaiserValue {
	const map = createCopyMap();
	return copyGraphWith(srcArr, srcObj, dstArr, dstObj, val, map);
}

export function copyGraphWith(srcArr: RaiserArrayHeap, srcObj: RaiserObjectHeap, dstArr: RaiserArrayHeap, dstObj: RaiserObjectHeap, val: RaiserValue, map: RaiserCopyMap): RaiserValue {
	if (val.kind == RaiserValueKind.RegAddr || val.kind == RaiserValueKind.GlobalAddr) {
		const source = val.kind == RaiserValueKind.RegAddr ? map.sourceRegs : map.sourceGlobals;
		if (source == null || val.intVal < 0 || val.intVal >= source.length) throw "internal: a copied slot address must have its source storage";
		if (val.kind == RaiserValueKind.GlobalAddr && map.destGlobals != null) return raiserGlobalAddr(val.intVal);
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
		const copied = copyGraphWith(srcArr, srcObj, dstArr, dstObj, source![val.intVal], map);
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
		if (val.intVal < 0 || val.intVal >= srcArr.arrays.length) {
			if (val.kind == RaiserValueKind.ElemAddr) throw "internal: a copied element address must have an array owner";
			return raiserNil();
		}
		const dstHandle = heapAllocArray(dstArr);
		map.arrSrc.push(val.intVal);
		map.arrDst.push(dstHandle);
		const items = srcArr.arrays[val.intVal].items;
		for (let i = 0; i < items.length; i = i + 1) {
			const copied = copyGraphWith(srcArr, srcObj, dstArr, dstObj, items[i], map);
			heapArrayPush(dstArr, dstHandle, copied);
			rcIncref(dstArr, dstObj, copied);
		}
		dstArr.arrays[dstHandle].viewOff = srcArr.arrays[val.intVal].viewOff;
		dstArr.arrays[dstHandle].viewLen = srcArr.arrays[val.intVal].viewLen;
		return val.kind == RaiserValueKind.Array ? raiserArray(dstHandle) : raiserElemAddr(dstHandle, val.floatVal as int64);
	}
	if (val.kind == RaiserValueKind.Object || val.kind == RaiserValueKind.FieldAddr) {
		for (let i = 0; i < map.objSrc.length; i = i + 1) {
			if (map.objSrc[i] == val.intVal) {
				return val.kind == RaiserValueKind.Object ? raiserObject(map.objDst[i]) : raiserFieldAddrAt(map.objDst[i], val.floatVal as int64);
			}
		}
		if (val.intVal < 0 || val.intVal >= srcObj.objects.length) {
			if (val.kind == RaiserValueKind.FieldAddr) throw "internal: a copied field address must have an object owner";
			return raiserNil();
		}
		const dstHandle = heapAllocObject(dstObj);
		dstObj.objects[dstHandle].classType = srcObj.objects[val.intVal].classType;
		map.objSrc.push(val.intVal);
		map.objDst.push(dstHandle);
		const fields = srcObj.objects[val.intVal].fields;
		for (let i = 0; i < fields.length; i = i + 1) {
			const copied = copyGraphWith(srcArr, srcObj, dstArr, dstObj, fields[i].value, map);
			heapObjectSetField(dstObj, dstHandle, fields[i].name, copied);
			rcIncref(dstArr, dstObj, copied);
		}
		return val.kind == RaiserValueKind.Object ? raiserObject(dstHandle) : raiserFieldAddrAt(dstHandle, val.floatVal as int64);
	}
	if (val.kind == RaiserValueKind.String && val.intVal >= 0) return heapAllocString(dstArr, heapStringText(srcArr, val));
	const out = raiserNil();
	copyValueInto(out, val);
	return out;
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
	const slots: RaiserValue[] = [heapAllocString(sArr, "source")];
	const owner = heapAllocArray(sArr);
	heapArrayPush(sArr, owner, raiserRegAddr(0));
	heapArrayPush(sArr, owner, raiserRegAddr(0));
	const map = createCopyMap();
	map.sourceRegs = slots;
	const copied = copyGraphWith(sArr, sObj, dArr, dObj, raiserArray(owner), map);
	const first = heapArrayGet(dArr, copied.intVal, 0);
	const second = heapArrayGet(dArr, copied.intVal, 1);
	assert heapStringText(dArr, heapArrayGet(dArr, first.intVal, first.floatVal as int64)) == "source";
	heapArraySet(dArr, first.intVal, first.floatVal as int64, heapAllocString(dArr, "destination"));
	assert heapStringText(dArr, heapArrayGet(dArr, second.intVal, second.floatVal as int64)) == "destination";
	assert heapStringText(sArr, slots[0]) == "source";
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
	assert text.intVal == 0 && sArr.strings.texts.length == 1 && dArr.strings.texts.length == 1;
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
	assert dArr.arrays[kid.intVal].rc == 1;
	assert dArr.arrays[copied.intVal].rc == 0;
}

// --- ORC refcount tests ---
test "rc incref/decref frees at zero" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const h = heapAllocArray(arr);
	const v = raiserArray(h);
	rcIncref(arr, obj, v);
	assert arr.arrays[h].rc == 1;
	rcIncref(arr, obj, v);
	assert arr.arrays[h].rc == 2;
	rcDecref(arr, obj, v);
	assert arr.arrays[h].rc == 1;
	rcDecref(arr, obj, v);
	assert arr.freeList.length == 1;
	assert arr.freeList[0] == h;
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
	assert arr.arrays[child].rc == 1;
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
	assert arr.arrays[childArr].rc == 1;
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
	heap.strings = createStringHeap();
}

export function clearObjectHeap(heap: RaiserObjectHeap): void {
	heap.objects.length = 0;
}

// --- Object Heap Tests ---
test "alloc empty object" {
	const heap = createStructHeap();
	const h = heapAllocObject(heap);
	assert h == 0;
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
	assert h2 == 0;
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
	assert h2 == 0;
}

test "a kind below String holds no handle the counters touch" {
	const arrays = createArrayHeap();
	const objects = createStructHeap();
	heapAllocArray(arrays);
	heapAllocObject(objects);
	arrays.arrays[0].rc = 1;
	objects.objects[0].rc = 1;
	for (let k = 0; k < (RaiserValueKind.String as number); k++) rcIncrefHandle(arrays, objects, k as RaiserValueKind, 0);
	assert arrays.arrays[0].rc == 1 && objects.objects[0].rc == 1;
	for (let k = 0; k < (RaiserValueKind.String as number); k++) rcDecrefHandle(arrays, objects, k as RaiserValueKind, 0);
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
	assert c.intVal < 0 && raiserConstString("shared").intVal == c.intVal;
	rcIncref(a, obj, c);
	rcDecref(a, obj, c);
	assert heapStringText(a, c) == "shared" && heapStringText(b, c) == "shared";
	assert heapStringLive(a) == 0;
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

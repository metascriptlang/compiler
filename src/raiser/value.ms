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
}

// Flat interface — all fields always present, unused ones zeroed.
// Matches project convention (see checker/types.ms Type interface).
export interface RaiserValue {
	kind: RaiserValueKind;
	intVal: number;
	floatVal: number;
	strVal: string;
}

// --- Constructors ---

export function raiserNil(): RaiserValue {
	return { kind: RaiserValueKind.Nil, intVal: 0, floatVal: 0.0, strVal: "" };
}

export function raiserBool(b: boolean): RaiserValue {
	let v = 0;
	if (b) { v = 1; }
	return { kind: RaiserValueKind.Bool, intVal: v, floatVal: 0.0, strVal: "" };
}

export function raiserInt(n: number): RaiserValue {
	return { kind: RaiserValueKind.Int, intVal: n, floatVal: 0.0, strVal: "" };
}

export function raiserFloat(f: number): RaiserValue {
	return { kind: RaiserValueKind.Float, intVal: 0, floatVal: f, strVal: "" };
}

export function raiserString(s: string): RaiserValue {
	return { kind: RaiserValueKind.String, intVal: 0, floatVal: 0.0, strVal: s };
}

export function raiserArray(handle: number): RaiserValue {
	return { kind: RaiserValueKind.Array, intVal: handle, floatVal: 0.0, strVal: "" };
}

export function raiserObject(handle: number): RaiserValue {
	return { kind: RaiserValueKind.Object, intVal: handle, floatVal: 0.0, strVal: "" };
}

// --- Deep copy (avoids pointer aliasing) ---

export function copyValueInto(dst: RaiserValue, src: RaiserValue): void {
	dst.kind = src.kind;
	dst.intVal = src.intVal;
	dst.floatVal = src.floatVal;
	dst.strVal = src.strVal;
}

// --- Accessors ---

export function raiserToInt(v: RaiserValue): number {
	return v.intVal;
}

export function raiserToFloat(v: RaiserValue): number {
	if (v.kind === RaiserValueKind.Float) return v.floatVal;
	return v.intVal + 0.0;
}

export function raiserToBool(v: RaiserValue): boolean {
	return match (v.kind) {
		RaiserValueKind.Nil => false,
		RaiserValueKind.Bool | RaiserValueKind.Int => v.intVal !== 0,
		RaiserValueKind.Float => v.floatVal !== 0.0,
		RaiserValueKind.String => v.strVal.length > 0,
		RaiserValueKind.Array | RaiserValueKind.Object => true,
		_ => false,
	};
}

export function raiserIsNil(v: RaiserValue): boolean {
	return v.kind === RaiserValueKind.Nil;
}

// --- Equality ---

export function raiserEqual(a: RaiserValue, b: RaiserValue): boolean {
	if (a.kind !== b.kind) return false;
	return match (a.kind) {
		RaiserValueKind.Nil => true,
		RaiserValueKind.Bool | RaiserValueKind.Int | RaiserValueKind.Array | RaiserValueKind.Object => a.intVal === b.intVal,
		RaiserValueKind.Float => a.floatVal === b.floatVal,
		RaiserValueKind.String => a.strVal === b.strVal,
		_ => false,
	};
}

// --- Debug ---

export function raiserToString(v: RaiserValue): string {
	return match (v.kind) {
		RaiserValueKind.Nil => "nil",
		RaiserValueKind.Bool => { if (v.intVal !== 0) { return "true"; } else { return "false"; } },
		RaiserValueKind.Int => `${v.intVal}`,
		RaiserValueKind.Float => `${v.floatVal}`,
		RaiserValueKind.String => v.strVal,
		RaiserValueKind.Array => "[array]",
		RaiserValueKind.Object => "[object]",
		_ => "?",
	};
}

// --- Tests ---
test "nil" {
	const v = raiserNil();
	assert v.kind === RaiserValueKind.Nil;
	assert raiserIsNil(v);
	assert !raiserToBool(v);
}

test "bool true" {
	const v = raiserBool(true);
	assert v.kind === RaiserValueKind.Bool;
	assert v.intVal === 1;
	assert raiserToBool(v);
}

test "bool false" {
	const v = raiserBool(false);
	assert v.kind === RaiserValueKind.Bool;
	assert v.intVal === 0;
	assert !raiserToBool(v);
}

test "int" {
	const v = raiserInt(42);
	assert v.kind === RaiserValueKind.Int;
	assert raiserToInt(v) === 42;
	assert raiserToBool(v);
}

test "int zero is falsy" {
	const v = raiserInt(0);
	assert !raiserToBool(v);
}

test "float" {
	const v = raiserFloat(3.14);
	assert v.kind === RaiserValueKind.Float;
	assert v.floatVal === 3.14;
}

test "int to float conversion" {
	const v = raiserInt(5);
	assert raiserToFloat(v) === 5.0;
}

test "nil equals nil" { assert raiserEqual(raiserNil(), raiserNil()); }

test "int equals same int" { assert raiserEqual(raiserInt(42), raiserInt(42)); }

test "int not equals different int" { assert !raiserEqual(raiserInt(1), raiserInt(2)); }

test "different kinds not equal" {
	assert !raiserEqual(raiserInt(0), raiserNil());
	assert !raiserEqual(raiserInt(1), raiserBool(true));
}

test "bool equality" {
	assert raiserEqual(raiserBool(true), raiserBool(true));
	assert !raiserEqual(raiserBool(true), raiserBool(false));
}

test "nil" { assert raiserToString(raiserNil()) === "nil"; }

test "true" { assert raiserToString(raiserBool(true)) === "true"; }

test "false" { assert raiserToString(raiserBool(false)) === "false"; }

test "int" { assert raiserToString(raiserInt(42)) === "42"; }

test "array" { assert raiserToString(raiserArray(0)) === "[array]"; }

// --- Array Heap ---
// Arrays live on a side heap. RaiserValue with kind=Array stores an integer handle
// in intVal that indexes into the heap. Reference semantics (shared handle).

export interface RaiserArrayData {
	items: RaiserValue[];
	rc: int32;
	color: int32;
}

export interface RaiserArrayHeap {
	arrays: RaiserArrayData[];
	freeList: number[];
}

export function createArrayHeap(): RaiserArrayHeap {
	const arrays: RaiserArrayData[] = [];
	const freeList: number[] = [];
	return { arrays, freeList };
}

export function heapAllocArray(heap: RaiserArrayHeap): number {
	if (heap.freeList.length > 0) {
		const reused = heap.freeList[heap.freeList.length - 1];
		heap.freeList.length = heap.freeList.length - 1;
		const data = heap.arrays[reused];
		data.items.length = 0;
		data.rc = 0;
		data.color = 0;
		return reused;
	}
	const idx = heap.arrays.length;
	const items: RaiserValue[] = [];
	const data: RaiserArrayData = { items, rc: 0, color: 0 };
	heap.arrays.push(data);
	return idx;
}

export function heapArrayLen(heap: RaiserArrayHeap, handle: number): number {
	return heap.arrays[handle].items.length;
}

export function heapArrayGet(heap: RaiserArrayHeap, handle: number, index: number): RaiserValue {
	return heap.arrays[handle].items[index];
}

export function heapArraySet(heap: RaiserArrayHeap, handle: number, index: number, val: RaiserValue): void {
	// Deep copy to avoid pointer aliasing
	copyValueInto(heap.arrays[handle].items[index], val);
}

export function heapArrayPush(heap: RaiserArrayHeap, handle: number, val: RaiserValue): void {
	// Deep copy to avoid pointer aliasing (register values are shared objects)
	const copy: RaiserValue = { kind: val.kind, intVal: val.intVal, floatVal: val.floatVal, strVal: val.strVal };
	heap.arrays[handle].items.push(copy);
}

// --- Array Heap Tests ---
test "alloc empty array" {
	const heap = createArrayHeap();
	const h = heapAllocArray(heap);
	assert h === 0;
	assert heapArrayLen(heap, h) === 0;
}

test "push and get" {
	const heap = createArrayHeap();
	const h = heapAllocArray(heap);
	const v1 = raiserInt(10);
	const v2 = raiserInt(20);
	heapArrayPush(heap, h, v1);
	heapArrayPush(heap, h, v2);
	assert heapArrayLen(heap, h) === 2;
	assert heapArrayGet(heap, h, 0).intVal === 10;
	assert heapArrayGet(heap, h, 1).intVal === 20;
}

test "set element" {
	const heap = createArrayHeap();
	const h = heapAllocArray(heap);
	const v0 = raiserInt(0);
	heapArrayPush(heap, h, v0);
	const v42 = raiserInt(42);
	heapArraySet(heap, h, 0, v42);
	assert heapArrayGet(heap, h, 0).intVal === 42;
}

test "multiple arrays independent" {
	const heap = createArrayHeap();
	const h1 = heapAllocArray(heap);
	const h2 = heapAllocArray(heap);
	const v1 = raiserInt(1);
	const v2 = raiserInt(2);
	heapArrayPush(heap, h1, v1);
	heapArrayPush(heap, h2, v2);
	assert heapArrayGet(heap, h1, 0).intVal === 1;
	assert heapArrayGet(heap, h2, 0).intVal === 2;
}

test "array value kind" {
	const v = raiserArray(3);
	assert v.kind === RaiserValueKind.Array;
	assert v.intVal === 3;
	assert raiserToBool(v);
}

// --- Object Heap ---
// Objects live on a side heap like arrays. Fields stored as name-value pairs.
// Linear scan for field lookup (fast for typical <20 field objects).

export interface RaiserObjectField {
	name: string;
	value: RaiserValue;
}

export interface RaiserObjectData {
	fields: RaiserObjectField[];
	rc: int32;
	color: int32;
}

export interface RaiserObjectHeap {
	objects: RaiserObjectData[];
	freeList: number[];
}

export function createStructHeap(): RaiserObjectHeap {
	const objects: RaiserObjectData[] = [];
	const freeList: number[] = [];
	return { objects, freeList };
}

export function heapAllocObject(heap: RaiserObjectHeap): number {
	if (heap.freeList.length > 0) {
		const reused = heap.freeList[heap.freeList.length - 1];
		heap.freeList.length = heap.freeList.length - 1;
		const data = heap.objects[reused];
		data.fields.length = 0;
		data.rc = 0;
		data.color = 0;
		return reused;
	}
	const idx = heap.objects.length;
	const fields: RaiserObjectField[] = [];
	const data: RaiserObjectData = { fields, rc: 0, color: 0 };
	heap.objects.push(data);
	return idx;
}

export function heapObjectFieldCount(heap: RaiserObjectHeap, handle: number): number {
	const obj = heap.objects[handle];
	return obj.fields.length;
}

export function heapObjectFieldNameAt(heap: RaiserObjectHeap, handle: number, index: number): string {
	const obj = heap.objects[handle];
	if (index < 0 || index >= obj.fields.length) return "";
	return obj.fields[index].name;
}

test "heapObjectFieldNameAt/ValueAt follow insertion order" {
	const heap = createStructHeap();
	const h = heapAllocObject(heap);
	heapObjectSetField(heap, h, "kind", raiserInt(5));
	heapObjectSetField(heap, h, "left", raiserString("L"));
	assert heapObjectFieldNameAt(heap, h, 0) === "kind";
	assert heapObjectFieldNameAt(heap, h, 1) === "left";
	assert heapObjectFieldValueAt(heap, h, 1).strVal === "L";
	assert heapObjectFieldNameAt(heap, h, 2) === "";
	assert heapObjectFieldValueAt(heap, h, 9).kind === RaiserValueKind.Nil;
}

export function heapObjectFieldValueAt(heap: RaiserObjectHeap, handle: number, index: number): RaiserValue {
	const obj = heap.objects[handle];
	if (index < 0 || index >= obj.fields.length) return { kind: RaiserValueKind.Nil, intVal: 0, floatVal: 0.0, strVal: "" };
	return obj.fields[index].value;
}

export function heapObjectGetField(heap: RaiserObjectHeap, handle: number, name: string): RaiserValue {
	const obj = heap.objects[handle];
	for (const field of obj.fields) {
		if (field.name === name) {
			return field.value;
		}
	}
	// Field not found — return nil
	return { kind: RaiserValueKind.Nil, intVal: 0, floatVal: 0.0, strVal: "" };
}

export function heapObjectSetField(heap: RaiserObjectHeap, handle: number, name: string, val: RaiserValue): void {
	const obj = heap.objects[handle];
	// Check if field already exists
	for (const field of obj.fields) {
		if (field.name === name) {
			// Update existing field (deep copy)
			copyValueInto(field.value, val);
			return;
		}
	}
	// Add new field (deep copy value)
	const copy: RaiserValue = { kind: val.kind, intVal: val.intVal, floatVal: val.floatVal, strVal: val.strVal };
	const field: RaiserObjectField = { name, value: copy };
	obj.fields.push(field);
}

// --- ORC refcount primitives ---
// Only Array/Object are heap refs; a ref can hold cross-heap children, so both
// heaps are threaded through. Destroy is generic (the heap object is self-describing).

export function rcIncref(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, val: RaiserValue): void {
	if (val.kind === RaiserValueKind.Array) {
		arrHeap.arrays[val.intVal].rc = arrHeap.arrays[val.intVal].rc + 1;
	} else if (val.kind === RaiserValueKind.Object) {
		objHeap.objects[val.intVal].rc = objHeap.objects[val.intVal].rc + 1;
	}
}

export function rcDecref(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, val: RaiserValue): void {
	if (val.kind === RaiserValueKind.Array) {
		const data = arrHeap.arrays[val.intVal];
		data.rc = data.rc - 1;
		if (data.rc <= 0) { rcDestroyArray(arrHeap, objHeap, val.intVal); }
	} else if (val.kind === RaiserValueKind.Object) {
		const data = objHeap.objects[val.intVal];
		data.rc = data.rc - 1;
		if (data.rc <= 0) { rcDestroyObject(arrHeap, objHeap, val.intVal); }
	}
}

function rcDestroyArray(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, handle: number): void {
	const data = arrHeap.arrays[handle];
	for (const item of data.items) {
		rcDecref(arrHeap, objHeap, item);
	}
	data.items.length = 0;
	arrHeap.freeList.push(handle);
}

function rcDestroyObject(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, handle: number): void {
	const data = objHeap.objects[handle];
	for (const field of data.fields) {
		rcDecref(arrHeap, objHeap, field.value);
	}
	data.fields.length = 0;
	objHeap.freeList.push(handle);
}

// --- ORC refcount tests ---
test "rc incref/decref frees at zero" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const h = heapAllocArray(arr);
	const v = raiserArray(h);
	rcIncref(arr, obj, v);
	assert arr.arrays[h].rc === 1;
	rcIncref(arr, obj, v);
	assert arr.arrays[h].rc === 2;
	rcDecref(arr, obj, v);
	assert arr.arrays[h].rc === 1;
	rcDecref(arr, obj, v);
	assert arr.freeList.length === 1;
	assert arr.freeList[0] === h;
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
	assert arr.arrays[child].rc === 1;
	rcDecref(arr, obj, parentVal);
	assert arr.freeList.length === 2;
}

test "alloc reuses free-list slot" {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const h1 = heapAllocArray(arr);
	const v = raiserArray(h1);
	rcIncref(arr, obj, v);
	rcDecref(arr, obj, v);
	const h2 = heapAllocArray(arr);
	assert h2 === h1;
	assert arr.freeList.length === 0;
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
	assert arr.arrays[childArr].rc === 1;
	rcDecref(arr, obj, oVal);
	assert obj.freeList.length === 1;
	assert arr.freeList.length === 1;
}

// --- Object field convenience accessors ---
// These let the host read typed config fields from a VM result object.

export function heapObjectGetString(heap: RaiserObjectHeap, handle: number, field: string): string {
	const val = heapObjectGetField(heap, handle, field);
	return val.strVal;
}

export function heapObjectGetInt(heap: RaiserObjectHeap, handle: number, field: string): number {
	const val = heapObjectGetField(heap, handle, field);
	return val.intVal;
}

export function heapObjectGetObjectHandle(heap: RaiserObjectHeap, handle: number, field: string): number {
	const val = heapObjectGetField(heap, handle, field);
	if (val.kind === RaiserValueKind.Object) return val.intVal;
	return -1;
}

// --- Heap Recycling ---
// Reset heaps to reclaim memory between @comptime evaluations.

export function clearArrayHeap(heap: RaiserArrayHeap): void {
	heap.arrays.length = 0;
}

export function clearObjectHeap(heap: RaiserObjectHeap): void {
	heap.objects.length = 0;
}

// --- Object Heap Tests ---
test "alloc empty object" {
	const heap = createStructHeap();
	const h = heapAllocObject(heap);
	assert h === 0;
	assert heapObjectFieldCount(heap, h) === 0;
}

test "set and get field" {
	const heap = createStructHeap();
	const h = heapAllocObject(heap);
	const v = raiserInt(42);
	heapObjectSetField(heap, h, "x", v);
	assert heapObjectFieldCount(heap, h) === 1;
	assert heapObjectGetField(heap, h, "x").intVal === 42;
}

test "multiple fields" {
	const heap = createStructHeap();
	const h = heapAllocObject(heap);
	const v1 = raiserInt(10);
	const v2 = raiserInt(20);
	heapObjectSetField(heap, h, "x", v1);
	heapObjectSetField(heap, h, "y", v2);
	assert heapObjectFieldCount(heap, h) === 2;
	assert heapObjectGetField(heap, h, "x").intVal === 10;
	assert heapObjectGetField(heap, h, "y").intVal === 20;
}

test "update existing field" {
	const heap = createStructHeap();
	const h = heapAllocObject(heap);
	const v1 = raiserInt(1);
	heapObjectSetField(heap, h, "x", v1);
	const v2 = raiserInt(99);
	heapObjectSetField(heap, h, "x", v2);
	assert heapObjectFieldCount(heap, h) === 1;
	assert heapObjectGetField(heap, h, "x").intVal === 99;
}

test "get missing field returns nil" {
	const heap = createStructHeap();
	const h = heapAllocObject(heap);
	const val = heapObjectGetField(heap, h, "missing");
	assert val.kind === RaiserValueKind.Nil;
}

test "object value kind" {
	const v = raiserObject(5);
	assert v.kind === RaiserValueKind.Object;
	assert v.intVal === 5;
	assert raiserToBool(v);
}

test "clearArrayHeap resets storage" {
	const heap = createArrayHeap();
	const h = heapAllocArray(heap);
	const v = raiserInt(1);
	heapArrayPush(heap, h, v);
	assert heap.arrays.length === 1;
	clearArrayHeap(heap);
	assert heap.arrays.length === 0;
	// Re-allocate works after clear
	const h2 = heapAllocArray(heap);
	assert h2 === 0;
}

test "clearObjectHeap resets storage" {
	const heap = createStructHeap();
	const h = heapAllocObject(heap);
	const v = raiserInt(42);
	heapObjectSetField(heap, h, "x", v);
	assert heap.objects.length === 1;
	clearObjectHeap(heap);
	assert heap.objects.length === 0;
	// Re-allocate works after clear
	const h2 = heapAllocObject(heap);
	assert h2 === 0;
}

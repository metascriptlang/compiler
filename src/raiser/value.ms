// Raiser VM — Value representation
// Day-1: flat tagged interface. No NaN-boxing.
// Bool stored as intVal (0/1) to keep the interface simple.

import { check } from "std/testing";

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
		RaiserValueKind.Bool => { if (v.intVal !== 0) { "true" } else { "false" } },
		RaiserValueKind.Int => "" + v.intVal,
		RaiserValueKind.Float => "" + v.floatVal,
		RaiserValueKind.String => v.strVal,
		RaiserValueKind.Array => "[array]",
		RaiserValueKind.Object => "[object]",
		_ => "?",
	};
}

// --- Tests ---
test "nil" {
	const v = raiserNil();
	check(v.kind === RaiserValueKind.Nil);
	check(raiserIsNil(v));
	check(!raiserToBool(v));
}

test "bool true" {
	const v = raiserBool(true);
	check(v.kind === RaiserValueKind.Bool);
	check(v.intVal === 1);
	check(raiserToBool(v));
}

test "bool false" {
	const v = raiserBool(false);
	check(v.kind === RaiserValueKind.Bool);
	check(v.intVal === 0);
	check(!raiserToBool(v));
}

test "int" {
	const v = raiserInt(42);
	check(v.kind === RaiserValueKind.Int);
	check(raiserToInt(v) === 42);
	check(raiserToBool(v));
}

test "int zero is falsy" {
	const v = raiserInt(0);
	check(!raiserToBool(v));
}

test "float" {
	const v = raiserFloat(3.14);
	check(v.kind === RaiserValueKind.Float);
	check(v.floatVal === 3.14);
}

test "int to float conversion" {
	const v = raiserInt(5);
	check(raiserToFloat(v) === 5.0);
}

test "nil equals nil" { check(raiserEqual(raiserNil(), raiserNil())); }

test "int equals same int" { check(raiserEqual(raiserInt(42), raiserInt(42))); }

test "int not equals different int" { check(!raiserEqual(raiserInt(1), raiserInt(2))); }

test "different kinds not equal" {
	check(!raiserEqual(raiserInt(0), raiserNil()));
	check(!raiserEqual(raiserInt(1), raiserBool(true)));
}

test "bool equality" {
	check(raiserEqual(raiserBool(true), raiserBool(true)));
	check(!raiserEqual(raiserBool(true), raiserBool(false)));
}

test "nil" { check(raiserToString(raiserNil()) === "nil"); }

test "true" { check(raiserToString(raiserBool(true)) === "true"); }

test "false" { check(raiserToString(raiserBool(false)) === "false"); }

test "int" { check(raiserToString(raiserInt(42)) === "42"); }

test "array" { check(raiserToString(raiserArray(0)) === "[array]"); }

// --- Array Heap ---
// Arrays live on a side heap. RaiserValue with kind=Array stores an integer handle
// in intVal that indexes into the heap. Reference semantics (shared handle).

export interface RaiserArrayData {
	items: RaiserValue[];
}

export interface RaiserArrayHeap {
	arrays: RaiserArrayData[];
}

export function createArrayHeap(): RaiserArrayHeap {
	const arrays: RaiserArrayData[] = [];
	return { arrays };
}

export function heapAllocArray(heap: RaiserArrayHeap): number {
	const idx = heap.arrays.length;
	const items: RaiserValue[] = [];
	const data: RaiserArrayData = { items };
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
	const target = heap.arrays[handle].items[index];
	target.kind = val.kind;
	target.intVal = val.intVal;
	target.floatVal = val.floatVal;
	target.strVal = val.strVal;
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
	check(h === 0);
	check(heapArrayLen(heap, h) === 0);
}

test "push and get" {
	const heap = createArrayHeap();
	const h = heapAllocArray(heap);
	const v1 = raiserInt(10);
	const v2 = raiserInt(20);
	heapArrayPush(heap, h, v1);
	heapArrayPush(heap, h, v2);
	check(heapArrayLen(heap, h) === 2);
	check(heapArrayGet(heap, h, 0).intVal === 10);
	check(heapArrayGet(heap, h, 1).intVal === 20);
}

test "set element" {
	const heap = createArrayHeap();
	const h = heapAllocArray(heap);
	const v0 = raiserInt(0);
	heapArrayPush(heap, h, v0);
	const v42 = raiserInt(42);
	heapArraySet(heap, h, 0, v42);
	check(heapArrayGet(heap, h, 0).intVal === 42);
}

test "multiple arrays independent" {
	const heap = createArrayHeap();
	const h1 = heapAllocArray(heap);
	const h2 = heapAllocArray(heap);
	const v1 = raiserInt(1);
	const v2 = raiserInt(2);
	heapArrayPush(heap, h1, v1);
	heapArrayPush(heap, h2, v2);
	check(heapArrayGet(heap, h1, 0).intVal === 1);
	check(heapArrayGet(heap, h2, 0).intVal === 2);
}

test "array value kind" {
	const v = raiserArray(3);
	check(v.kind === RaiserValueKind.Array);
	check(v.intVal === 3);
	check(raiserToBool(v));
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
}

export interface RaiserObjectHeap {
	objects: RaiserObjectData[];
}

export function createObjectHeap(): RaiserObjectHeap {
	const objects: RaiserObjectData[] = [];
	return { objects };
}

export function heapAllocObject(heap: RaiserObjectHeap): number {
	const idx = heap.objects.length;
	const fields: RaiserObjectField[] = [];
	const data: RaiserObjectData = { fields };
	heap.objects.push(data);
	return idx;
}

export function heapObjectFieldCount(heap: RaiserObjectHeap, handle: number): number {
	const obj = heap.objects[handle];
	return obj.fields.length;
}

export function heapObjectGetField(heap: RaiserObjectHeap, handle: number, name: string): RaiserValue {
	const obj = heap.objects[handle];
	for (let i = 0; i < obj.fields.length; i = i + 1) {
		if (obj.fields[i].name === name) {
			return obj.fields[i].value;
		}
	}
	// Field not found — return nil
	return { kind: RaiserValueKind.Nil, intVal: 0, floatVal: 0.0, strVal: "" };
}

export function heapObjectSetField(heap: RaiserObjectHeap, handle: number, name: string, val: RaiserValue): void {
	const obj = heap.objects[handle];
	// Check if field already exists
	for (let i = 0; i < obj.fields.length; i = i + 1) {
		if (obj.fields[i].name === name) {
			// Update existing field (deep copy)
			obj.fields[i].value.kind = val.kind;
			obj.fields[i].value.intVal = val.intVal;
			obj.fields[i].value.floatVal = val.floatVal;
			obj.fields[i].value.strVal = val.strVal;
			return;
		}
	}
	// Add new field (deep copy value)
	const copy: RaiserValue = { kind: val.kind, intVal: val.intVal, floatVal: val.floatVal, strVal: val.strVal };
	const field: RaiserObjectField = { name, value: copy };
	obj.fields.push(field);
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

// --- Object Heap Tests ---
test "alloc empty object" {
	const heap = createObjectHeap();
	const h = heapAllocObject(heap);
	check(h === 0);
	check(heapObjectFieldCount(heap, h) === 0);
}

test "set and get field" {
	const heap = createObjectHeap();
	const h = heapAllocObject(heap);
	const v = raiserInt(42);
	heapObjectSetField(heap, h, "x", v);
	check(heapObjectFieldCount(heap, h) === 1);
	check(heapObjectGetField(heap, h, "x").intVal === 42);
}

test "multiple fields" {
	const heap = createObjectHeap();
	const h = heapAllocObject(heap);
	const v1 = raiserInt(10);
	const v2 = raiserInt(20);
	heapObjectSetField(heap, h, "x", v1);
	heapObjectSetField(heap, h, "y", v2);
	check(heapObjectFieldCount(heap, h) === 2);
	check(heapObjectGetField(heap, h, "x").intVal === 10);
	check(heapObjectGetField(heap, h, "y").intVal === 20);
}

test "update existing field" {
	const heap = createObjectHeap();
	const h = heapAllocObject(heap);
	const v1 = raiserInt(1);
	heapObjectSetField(heap, h, "x", v1);
	const v2 = raiserInt(99);
	heapObjectSetField(heap, h, "x", v2);
	check(heapObjectFieldCount(heap, h) === 1);
	check(heapObjectGetField(heap, h, "x").intVal === 99);
}

test "get missing field returns nil" {
	const heap = createObjectHeap();
	const h = heapAllocObject(heap);
	const val = heapObjectGetField(heap, h, "missing");
	check(val.kind === RaiserValueKind.Nil);
}

test "object value kind" {
	const v = raiserObject(5);
	check(v.kind === RaiserValueKind.Object);
	check(v.intVal === 5);
	check(raiserToBool(v));
}

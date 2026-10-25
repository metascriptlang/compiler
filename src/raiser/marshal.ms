// Raiser VM — Marshalling helpers for host-call boundary
//
// Defines the uniform ABI between Raiser bytecode and native host functions:
// every registered host function takes `RaiserValue[]` and returns one
// `RaiserValue`. These helpers extract typed values from the boxed register
// representation and box returns back into the register file.
//
// Auto-generated wrappers (see codegen/raiser/hostTable.ms) call into these
// to bridge between Raiser's tagged register file and the host's native C
// types (cstring, int32, etc.).
//
// The scalar unbox helpers are defensive: kind mismatches return a safe
// zero-equivalent rather than corrupting register state. Callers should pass
// already-validated values where possible (extern type signatures enforce this
// at the call site).

import {
	RaiserValue, RaiserValueKind,
	raiserNil, raiserBool, raiserInt, raiserFloat, raiserObject, raiserArray,
	RaiserArrayHeap, RaiserObjectHeap, createArrayHeap, createStructHeap, copyGraph,
	heapAllocObject, heapObjectSetField, heapObjectGetField,
	heapAllocArray, heapArrayPush, heapArrayLen, heapArrayGet,
	heapAllocString, heapStringText, handleIndex,
} from "./value";
import { activeHostArrayHeap, setActiveHostHeaps } from "./hostRegistry";

export { RaiserHostFn } from "./hostRegistry";

export type RaiserPrintSink = (text: string) => void;

// --- Unbox helpers ---

// A host function sees a string as a handle on the running strand's heap; these two
// are where text crosses to and from a host string.
function hostStringHeap(): RaiserArrayHeap {
	const heap = activeHostArrayHeap();
	if (heap == null) throw new Error("internal: a host string needs an active host heap");
	return heap;
}

export function unboxString(v: RaiserValue): string {
	if (v.kind != RaiserValueKind.String) return "";
	return heapStringText(hostStringHeap(), v);
}

export function unboxInt(v: RaiserValue): number {
	return match (v.kind) {
		RaiserValueKind.Int | RaiserValueKind.Bool => v.intVal as number,
		RaiserValueKind.Float => v.floatVal,
		_ => 0,
	};
}

export function unboxFloat(v: RaiserValue): number {
	if (v.kind == RaiserValueKind.Float) return v.floatVal;
	if (v.kind == RaiserValueKind.Int) return v.intVal as number;
	return 0.0;
}

export function unboxBool(v: RaiserValue): boolean {
	return match (v.kind) {
		RaiserValueKind.Bool | RaiserValueKind.Int => v.intVal != 0,
		RaiserValueKind.Nil => false,
		_ => true,
	};
}

// --- Box helpers ---

export function boxVoid(): RaiserValue {
	return raiserNil();
}

export function boxString(s: string): RaiserValue {
	return heapAllocString(hostStringHeap(), s);
}

export function boxInt(n: number): RaiserValue {
	return raiserInt(n as int64);
}

export function boxFloat(f: number): RaiserValue {
	return raiserFloat(f);
}

export function boxBool(b: boolean): RaiserValue {
	return raiserBool(b);
}

// --- Host-owned values ---

export interface RaiserHostValue {
	root: RaiserValue;
	arrayHeap: RaiserArrayHeap;
	objectHeap: RaiserObjectHeap;
}

const SCALAR_ARRAYS: RaiserArrayHeap = createArrayHeap();
const SCALAR_OBJECTS: RaiserObjectHeap = createStructHeap();

function isScalarKind(kind: RaiserValueKind): boolean {
	return kind == RaiserValueKind.Nil || kind == RaiserValueKind.Bool
		|| kind == RaiserValueKind.Int || kind == RaiserValueKind.Float
		|| kind == RaiserValueKind.String;
}

function isHeapString(v: RaiserValue): boolean {
	return v.kind == RaiserValueKind.String && v.intVal >= 0;
}

function crossHeaps(
	v: RaiserValue,
	fromArrays: RaiserArrayHeap,
	fromObjects: RaiserObjectHeap,
	toArrays: RaiserArrayHeap,
	toObjects: RaiserObjectHeap,
): RaiserValue {
	return copyGraph(fromArrays, fromObjects, toArrays, toObjects, v);
}

export function hostValue(v: RaiserValue): RaiserHostValue {
	if (!isScalarKind(v.kind)) {
		const kind = v.kind.toString();
		throw new Error(`hostValue takes a boxed scalar, not a handle of kind ${kind}: `
			+ "build an aggregate with hostObject or hostArray");
	}
	if (isHeapString(v)) {
		const arrayHeap = createArrayHeap();
		return { root: heapAllocString(arrayHeap, unboxString(v)), arrayHeap, objectHeap: SCALAR_OBJECTS };
	}
	return { root: v, arrayHeap: SCALAR_ARRAYS, objectHeap: SCALAR_OBJECTS };
}

export function hostObject(names: string[], values: RaiserHostValue[]): RaiserHostValue {
	if (names.length != values.length) {
		throw new Error(`hostObject: ${names.length} field name(s) for ${values.length} value(s)`);
	}
	const arrayHeap = createArrayHeap();
	const objectHeap = createStructHeap();
	const handle = heapAllocObject(objectHeap);
	for (let i = 0; i < names.length; i += 1) {
		const v = values[i];
		const copied = crossHeaps(v.root, v.arrayHeap, v.objectHeap, arrayHeap, objectHeap);
		heapObjectSetField(objectHeap, handle, names[i], copied);
	}
	return { root: raiserObject(handle), arrayHeap, objectHeap };
}

export function hostArray(items: RaiserHostValue[]): RaiserHostValue {
	const arrayHeap = createArrayHeap();
	const objectHeap = createStructHeap();
	const handle = heapAllocArray(arrayHeap);
	for (const v of items) {
		const copied = crossHeaps(v.root, v.arrayHeap, v.objectHeap, arrayHeap, objectHeap);
		heapArrayPush(arrayHeap, handle, copied);
	}
	return { root: raiserArray(handle), arrayHeap, objectHeap };
}

function part(v: RaiserHostValue, slot: RaiserValue): RaiserHostValue {
	return { root: slot, arrayHeap: v.arrayHeap, objectHeap: v.objectHeap };
}

export function field(this v: RaiserHostValue, name: string): RaiserHostValue {
	if (v.root.kind != RaiserValueKind.Object) {
		const kind = v.root.kind.toString();
		throw new Error(`field '${name}' of a value of kind ${kind}: only an object has fields`);
	}
	return part(v, heapObjectGetField(v.objectHeap, v.root.intVal, name));
}

export function length(this v: RaiserHostValue): int32 {
	if (v.root.kind != RaiserValueKind.Array) {
		const kind = v.root.kind.toString();
		throw new Error(`length of a value of kind ${kind}: only an array has a length`);
	}
	return heapArrayLen(v.arrayHeap, v.root.intVal);
}

export function text(this v: RaiserHostValue): string {
	if (v.root.kind != RaiserValueKind.String) {
		const kind = v.root.kind.toString();
		throw new Error(`text of a value of kind ${kind}: only a string has text`);
	}
	return heapStringText(v.arrayHeap, v.root);
}

export function at(this v: RaiserHostValue, index: int32): RaiserHostValue {
	const count = v.length();
	if (index < 0 || index >= count) throw new Error(`element ${index} of an array of ${count}`);
	return part(v, heapArrayGet(v.arrayHeap, v.root.intVal, index));
}

export function copyToHost(
	arrayHeap: RaiserArrayHeap,
	objectHeap: RaiserObjectHeap,
	v: RaiserValue,
): RaiserHostValue {
	if (isScalarKind(v.kind) && !isHeapString(v)) return hostValue(v);
	const arrays = createArrayHeap();
	const objects = createStructHeap();
	const root = copyGraph(arrayHeap, objectHeap, arrays, objects, v);
	return { root, arrayHeap: arrays, objectHeap: objects };
}

export function copyToVm(
	arrayHeap: RaiserArrayHeap,
	objectHeap: RaiserObjectHeap,
	v: RaiserHostValue,
): RaiserValue {
	return crossHeaps(v.root, v.arrayHeap, v.objectHeap, arrayHeap, objectHeap);
}

// --- Tests ---

test "unboxString from string value" {
	setActiveHostHeaps(createStructHeap(), createArrayHeap());
	const v = boxString("hello");
	assert unboxString(v) == "hello";
}

test "unboxString from non-string returns empty" {
	setActiveHostHeaps(createStructHeap(), createArrayHeap());
	const v = raiserInt(42);
	assert unboxString(v) == "";
}

test "unboxInt from int value" {
	const v = raiserInt(7);
	assert unboxInt(v) == 7;
}

test "unboxInt coerces bool" {
	const v = raiserBool(true);
	assert unboxInt(v) == 1;
}

test "unboxBool from bool" {
	assert unboxBool(raiserBool(true)) == true;
	assert unboxBool(raiserBool(false)) == false;
}

test "unboxBool from int" {
	assert unboxBool(raiserInt(1)) == true;
	assert unboxBool(raiserInt(0)) == false;
}

test "boxString roundtrip keeps non-ASCII bytes" {
	setActiveHostHeaps(createStructHeap(), createArrayHeap());
	const v = boxString("hi é 日本");
	assert v.kind == RaiserValueKind.String;
	assert unboxString(v) == "hi é 日本";
}

test "boxInt roundtrip" {
	const v = boxInt(99);
	assert v.kind == RaiserValueKind.Int;
	assert v.intVal == 99;
}

test "boxBool roundtrip" {
	const v = boxBool(true);
	assert v.kind == RaiserValueKind.Bool;
	assert v.intVal == 1;
}

test "boxVoid is nil" {
	const v = boxVoid();
	assert v.kind == RaiserValueKind.Nil;
}

test "a host value built from scalars crosses into a VM heap and back with its children counted" {
	const keys = hostValue(boxString("ctrl+a"));
	const bind = hostObject(["keys", "text"], [keys, hostValue(boxString("home"))]);
	const binds = hostArray([bind, bind]);
	const config = hostObject(["binds", "fontSize"], [binds, hostValue(boxVoid())]);
	const vmArrays = createArrayHeap();
	const vmObjects = createStructHeap();
	const placed = copyToVm(vmArrays, vmObjects, config);
	assert vmObjects.objects[handleIndex(placed.intVal)].rc == 0;
	const placedBinds = heapObjectGetField(vmObjects, placed.intVal, "binds");
	assert vmArrays.arrays[handleIndex(placedBinds.intVal)].rc == 1;
	assert vmObjects.objects[handleIndex(heapArrayGet(vmArrays, placedBinds.intVal, 1).intVal)].rc == 1;
	const back = copyToHost(vmArrays, vmObjects, placed);
	assert back.objectHeap != vmObjects;
	assert back.field("binds").length() == 2;
	assert back.field("binds").at(1).field("text").text() == "home";
	assert back.field("fontSize").root.kind == RaiserValueKind.Nil;
	assert back.field("absent").root.kind == RaiserValueKind.Nil;
}

test "a host value refuses a walk its kind does not have" {
	let refused = "";
	try { hostValue(boxInt(1)).field("x"); } catch (e) { refused = e.message; }
	assert refused == "field 'x' of a value of kind Int: only an object has fields";
	try { hostArray([]).at(0); } catch (e) { refused = e.message; }
	assert refused == "element 0 of an array of 0";
	try { hostValue(raiserObject(0)); } catch (e) { refused = e.message; }
	assert refused.startsWith("hostValue takes a boxed scalar, not a handle of kind Object");
}

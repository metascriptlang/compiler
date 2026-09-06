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
// Defensive: kind mismatches return a safe zero-equivalent rather than
// corrupting register state. Callers should pass already-validated values
// where possible (extern type signatures enforce this at the call site).

import {
	RaiserValue, RaiserValueKind,
	raiserNil, raiserBool, raiserInt, raiserFloat, raiserString,
} from "./value";

// --- Host function signature ---
// Every registered host call has this shape. Wrappers handle per-native
// type-specific marshalling internally.

export type RaiserHostFn = (args: RaiserValue[]) => RaiserValue;

// --- Unbox helpers ---

export function unboxString(v: RaiserValue): string {
	if (v.kind != RaiserValueKind.String) return "";
	return v.strVal;
}

export function unboxInt(v: RaiserValue): number {
	return match (v.kind) {
		RaiserValueKind.Int | RaiserValueKind.Bool => v.intVal,
		RaiserValueKind.Float => v.floatVal,
		_ => 0,
	};
}

export function unboxFloat(v: RaiserValue): number {
	if (v.kind == RaiserValueKind.Float) return v.floatVal;
	if (v.kind == RaiserValueKind.Int) return v.intVal;
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
	return raiserString(s);
}

export function boxInt(n: number): RaiserValue {
	return raiserInt(n);
}

export function boxFloat(f: number): RaiserValue {
	return raiserFloat(f);
}

export function boxBool(b: boolean): RaiserValue {
	return raiserBool(b);
}

// --- Tests ---

test "unboxString from string value" {
	const v = raiserString("hello");
	assert unboxString(v) == "hello";
}

test "unboxString from non-string returns empty" {
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

test "boxString roundtrip" {
	const v = boxString("hi");
	assert v.kind == RaiserValueKind.String;
	assert v.strVal == "hi";
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

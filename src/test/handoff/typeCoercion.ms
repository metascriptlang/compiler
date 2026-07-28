// Route 13: Type coercion at phase boundaries
//
// Tests implicit type coercions that the checker must support.
// Each coercion is verified against standard reference behavior.

import { Type, TypeKind } from "../../ast/node";
import { createStruct, createRef, createEnum, createArray, createSpan, createUnion, createPrimitive, numberType, stringType, int32Type, float64Type, booleanType } from "../../checker/types";
import { isAssignable, isReinterpretUnsafe } from "../../checker/compat";

// ===== Ref<T> → T auto-deref =====
// Standard reference: managed references auto-dereference transparently.

test "isAssignable: Ref<Struct> → Struct (auto-deref)" {
	const inner = createStruct("Foo", ["x"], [numberType()], true);
	const ref = createRef(inner);
	assert isAssignable(ref, inner);
}

test "isAssignable: Struct → Struct (same type)" {
	const s = createStruct("Bar", ["x"], [numberType()], true);
	assert isAssignable(s, s);
}

// ===== Enum → number: NOT implicit =====
// Standard reference: enums do NOT implicitly convert to integers.
// Our hasFlag/setFlag should accept the enum type directly.

test "isAssignable: Enum → number is NOT allowed" {
	const e = createEnum("Color", ["Red", "Green", "Blue"], null as unknown as number[]);
	assert !isAssignable(e, numberType());
}

test "isAssignable: Enum → Enum same name" {
	const e = createEnum("Color", ["Red", "Green", "Blue"], null as unknown as number[]);
	assert isAssignable(e, e);
}

// ===== Container element repr (Nim typeRel invariance, sigmatch.nim:1502) =====
// A ref array/span/ptr assigns by raw payload cast — no per-element conversion —
// so a numeric element-repr mismatch (int32 4B vs number 8B) reinterprets → OOB.

test "isAssignable: int32[] → number[] rejected (element repr differs)" {
	assert !isAssignable(createArray(int32Type()), createArray(numberType()));
}

test "isAssignable: number[] → number[] allowed" {
	assert isAssignable(createArray(numberType()), createArray(numberType()));
}

test "isAssignable: int32[] → int32[] allowed" {
	assert isAssignable(createArray(int32Type()), createArray(int32Type()));
}

test "isReinterpretUnsafe: int32[] → number[] is unsafe" {
	assert isReinterpretUnsafe(createArray(int32Type()), createArray(numberType()));
}

test "isReinterpretUnsafe: number[] → number[] is safe" {
	assert !isReinterpretUnsafe(createArray(numberType()), createArray(numberType()));
}

test "isReinterpretUnsafe: int32[] → int32[] is safe" {
	assert !isReinterpretUnsafe(createArray(int32Type()), createArray(int32Type()));
}

test "isReinterpretUnsafe: number[] → float64[] is safe (same 8B repr)" {
	assert !isReinterpretUnsafe(createArray(numberType()), createArray(float64Type()));
}

test "isReinterpretUnsafe: scalar int32 → number is not a container" {
	assert !isReinterpretUnsafe(int32Type(), numberType());
}

test "isReinterpretUnsafe: string[] → number[] is not a numeric reinterpret" {
	assert !isReinterpretUnsafe(createArray(stringType()), createArray(numberType()));
}

test "isReinterpretUnsafe: Ref<int32[]> → Ref<number[]> peels Ref" {
	assert isReinterpretUnsafe(createRef(createArray(int32Type())), createRef(createArray(numberType())));
}

test "isReinterpretUnsafe: nested int32[][] → number[][]" {
	assert isReinterpretUnsafe(createArray(createArray(int32Type())), createArray(createArray(numberType())));
}

test "isReinterpretUnsafe: int32-span → number-span is unsafe" {
	assert isReinterpretUnsafe(createSpan(int32Type()), createSpan(numberType()));
}

// ===== Struct field repr (neon+yoga 2026-07-27: Style raw-cast into FlexStyle) =====
// Structural object assign is a raw ref/value cast — no per-field conversion — so
// shared fields whose union/numeric repr differs reinterpret both tag and payload.

function numStrField(name: string): Type {
	return createStruct(name, ["w"], [createUnion([numberType(), stringType()])], true);
}

function f32StrField(name: string): Type {
	return createStruct(name, ["w"], [createUnion([createPrimitive(TypeKind.Float32), stringType()])], true);
}

test "isReinterpretUnsafe: struct field union(number|string) → union(float32|string) is unsafe" {
	assert isReinterpretUnsafe(numStrField("A"), f32StrField("B"));
}

test "isAssignable: struct field union repr mismatch rejected" {
	assert !isAssignable(numStrField("A"), f32StrField("B"));
}

test "isReinterpretUnsafe: identical union field across names is safe" {
	assert !isReinterpretUnsafe(numStrField("A"), numStrField("B"));
}

test "isAssignable: identical union field across names still structural" {
	assert isAssignable(numStrField("A"), numStrField("B"));
}

test "isReinterpretUnsafe: union member-count mismatch in field is unsafe" {
	const a = createStruct("A", ["w"], [createUnion([numberType(), stringType()])], true);
	const b = createStruct("B", ["w"], [createUnion([numberType(), stringType(), booleanType()])], true);
	assert isReinterpretUnsafe(a, b);
}

test "isReinterpretUnsafe: numeric field width mismatch is unsafe" {
	const a = createStruct("A", ["n"], [int32Type()], true);
	const b = createStruct("B", ["n"], [numberType()], true);
	assert isReinterpretUnsafe(a, b);
}

test "isReinterpretUnsafe: disjoint field names stay safe" {
	const a = createStruct("A", ["value", "present"], [createUnion([numberType(), stringType()]), booleanType()], true);
	const b = createStruct("B", ["other"], [numberType()], true);
	assert !isReinterpretUnsafe(a, b);
}

test "isReinterpretUnsafe: same-named struct types skip the field walk" {
	assert !isReinterpretUnsafe(numStrField("Same"), f32StrField("Same"));
}

test "isReinterpretUnsafe: nested struct field with union repr mismatch is unsafe" {
	const a = createStruct("OuterA", ["inner"], [numStrField("MA")], true);
	const b = createStruct("OuterB", ["inner"], [f32StrField("MB")], true);
	assert isReinterpretUnsafe(a, b);
}

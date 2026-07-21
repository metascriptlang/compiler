// Route 13: Type coercion at phase boundaries
//
// Tests implicit type coercions that the checker must support.
// Each coercion is verified against standard reference behavior.

import { Type, TypeKind } from "../../ast/node";
import { createStruct, createRef, createEnum, createArray, createSpan, numberType, stringType, int32Type, float64Type } from "../../checker/types";
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

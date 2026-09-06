// Route 3: getTypeSize accuracy + TypeReference fallback
//
// Verifies type size computation and documents the known bug where
// TypeReference falls through to the default case (8 bytes) instead
// of resolving to the actual type size.

import { TypeKind } from "../../ast/node";
import { createStruct, numberType, stringType, getTypeSize, createTypeRef } from "../../checker/types";
import { ccgIntroducedPtr } from "../../codegen/c/types";

test "getTypeSize: number = 8" {
	assert getTypeSize(numberType()) == 8;
}

test "getTypeSize: string = 16" {
	assert getTypeSize(stringType()) == 16;
}

test "getTypeSize: struct = sum of fields" {
	const t = createStruct("Pair", ["x", "y"], [numberType(), numberType()], true);
	assert getTypeSize(t) == 16;
}

test "getTypeSize: struct with string = 24" {
	const t = createStruct("Named", ["id", "name"], [numberType(), stringType()], true);
	assert getTypeSize(t) == 24;
}

test "getTypeSize: 24 is NOT above threshold" {
	// Threshold is strictly > 24, so exactly 24 bytes → no pointer introduction
	const t = createStruct("Exact", ["id", "name"], [numberType(), stringType()], true);
	assert !ccgIntroducedPtr(t);
}

// ROOT CAUSE: getTypeSize for TypeReference
// TypeReference falls through to `_ => 8` (targetPtrSize) instead of
// resolving to the actual type. This causes ccgIntroducedPtr to see
// a smaller size than the real struct, preventing pointer introduction.

test "getTypeSize: TypeReference falls through to 8" {
	// BUG: TypeReference("DocData") → getTypeSize → _ => 8 (fallback)
	// Should resolve to actual size, but doesn't
	const tref = createTypeRef("DocData");
	// This returns 8 (pointer fallback) instead of the real union size
	assert getTypeSize(tref) == 8;
}

test "getTypeSize: struct with TypeReference field is underestimated" {
	// Doc = { kind: enum(4), data: TypeReference("DocData") }
	// getTypeSize sees kind=4, data=8 (TypeRef fallback) → total=12
	// Real size: kind=4, data=36 (union) → total=40
	const enumType = createStruct("DocKind", [], [], false);
	const dataRef = createTypeRef("DocData");
	const doc = createStruct("Doc", ["kind", "data"], [enumType, dataRef], true);
	// BUG: returns 12 instead of 40
	// So ccgIntroducedPtr(doc) = false (12 < 24) → no pointer params → `.` instead of `->`
	assert getTypeSize(doc) <= 24;  // this is the bug — size underestimated
	assert !ccgIntroducedPtr(doc);  // consequence: no pointer introduction
}

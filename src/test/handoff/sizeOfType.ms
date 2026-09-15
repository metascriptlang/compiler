// Route 3: the one size table the C ABI threshold reads.

import { createStruct, numberType, stringType, sizeOfType, createTypeRef, SIZE_NOT_COMPUTABLE } from "../../checker/types";
import { ccgIntroducedPtr } from "../../codegen/c/types";

test "sizeOfType: number = 8" {
	assert sizeOfType(numberType()) == 8;
}

test "sizeOfType: string = 16" {
	assert sizeOfType(stringType()) == 16;
}

test "sizeOfType: struct pads to its widest field" {
	const t = createStruct("Pair", ["x", "y"], [numberType(), numberType()], true);
	assert sizeOfType(t) == 16;
}

test "sizeOfType: struct with string = 24" {
	const t = createStruct("Named", ["id", "name"], [numberType(), stringType()], true);
	assert sizeOfType(t) == 24;
}

test "exactly 24 stays below the pointer threshold" {
	const t = createStruct("Exact", ["id", "name"], [numberType(), stringType()], true);
	assert !ccgIntroducedPtr(t);
}

test "an unresolved reference has no computable layout" {
	assert sizeOfType(createTypeRef("DocData")) == SIZE_NOT_COMPUTABLE;
}

test "a struct carrying an unresolved reference has none either" {
	const enumType = createStruct("DocKind", [], [], false);
	const doc = createStruct("Doc", ["kind", "data"], [enumType, createTypeRef("DocData")], true);
	assert sizeOfType(doc) == SIZE_NOT_COMPUTABLE;
	assert !ccgIntroducedPtr(doc);
}

// Route 3: the one size table the C ABI threshold reads.

import { TargetInfo, createStruct, numberType, stringType, sizeOfType, createTypeRef, SIZE_NOT_COMPUTABLE } from "../../checker/types";
import { ccgIntroducedPtr } from "../../codegen/c/types";

test "sizeOfType: number = 8" {
	const tg: TargetInfo = { ptrSize: 8, floatSize: 8 };
	assert sizeOfType(tg, numberType()) == 8;
}

test "sizeOfType: string = 16" {
	const tg: TargetInfo = { ptrSize: 8, floatSize: 8 };
	assert sizeOfType(tg, stringType()) == 16;
}

test "sizeOfType: struct pads to its widest field" {
	const tg: TargetInfo = { ptrSize: 8, floatSize: 8 };
	const t = createStruct("Pair", ["x", "y"], [numberType(), numberType()], true);
	assert sizeOfType(tg, t) == 16;
}

test "sizeOfType: struct with string = 24" {
	const tg: TargetInfo = { ptrSize: 8, floatSize: 8 };
	const t = createStruct("Named", ["id", "name"], [numberType(), stringType()], true);
	assert sizeOfType(tg, t) == 24;
}

test "exactly 24 stays below the pointer threshold" {
	const tg: TargetInfo = { ptrSize: 8, floatSize: 8 };
	const t = createStruct("Exact", ["id", "name"], [numberType(), stringType()], true);
	assert !ccgIntroducedPtr(tg, t);
}

test "an unresolved reference has no computable layout" {
	const tg: TargetInfo = { ptrSize: 8, floatSize: 8 };
	assert sizeOfType(tg, createTypeRef("DocData")) == SIZE_NOT_COMPUTABLE;
}

test "a struct carrying an unresolved reference has none either" {
	const tg: TargetInfo = { ptrSize: 8, floatSize: 8 };
	const enumType = createStruct("DocKind", [], [], false);
	const doc = createStruct("Doc", ["kind", "data"], [enumType, createTypeRef("DocData")], true);
	assert sizeOfType(tg, doc) == SIZE_NOT_COMPUTABLE;
	assert !ccgIntroducedPtr(tg, doc);
}

// Route 2: ccgIntroducedPtr — type→pointer decision
//
// Verifies the codegen decision of whether to introduce pointer params
// based on struct size, interface flag, and Ref wrapping.

import {
	TypeKind, createStruct, createRef, createPtr,
	numberType, stringType, createMaybeType,
} from "../../checker/types";
import { ccgIntroducedPtr } from "../../codegen/c/types";

test "ccgIntroducedPtr: small struct = false" {
	const t = createStruct("Small", ["x", "y"], [numberType(), numberType()], true);
	assert !ccgIntroducedPtr(t);
}

test "ccgIntroducedPtr: large struct = true" {
	const t = createStruct("Big", ["a", "b", "c", "d"], [numberType(), numberType(), numberType(), numberType()], true);
	assert ccgIntroducedPtr(t);
}

test "ccgIntroducedPtr: struct with string fields = true" {
	const t = createStruct("WithStr", ["x", "name", "desc"], [numberType(), stringType(), stringType()], true);
	assert ccgIntroducedPtr(t);
}

test "ccgIntroducedPtr: Ref type = false" {
	const inner = createStruct("FooRef", ["x"], [numberType()], true);
	const ref = createRef(inner);
	assert !ccgIntroducedPtr(ref);
}

test "ccgIntroducedPtr: non-interface struct = false" {
	const t = createStruct("Raw", ["a", "b", "c", "d"], [numberType(), numberType(), numberType(), numberType()], false);
	assert !ccgIntroducedPtr(t);
}

test "ccgIntroducedPtr: class type (Ref<Struct>) = false" {
	const inner = createStruct("DocR", ["kind", "name", "desc", "extra"], [numberType(), stringType(), stringType(), stringType()], true);
	const classType = createRef(inner);
	assert !ccgIntroducedPtr(classType);
}

test "ccgIntroducedPtr: unwrapped class inner struct = true" {
	const inner = createStruct("DocRI", ["kind", "name", "desc", "extra"], [numberType(), stringType(), stringType(), stringType()], true);
	assert ccgIntroducedPtr(inner);
}

test "ccgIntroducedPtr: Maybe wrapper large enough" {
	const inner = createStruct("BigTokM", ["kind", "value", "extra"], [numberType(), stringType(), stringType()], true);
	const maybe = createMaybeType(inner);
	assert ccgIntroducedPtr(maybe);
}

test "ccgIntroducedPtr: collapsed Maybe<Ref<T>> = false" {
	const inner = createStruct("FooMC", ["x"], [numberType()], true);
	const ref = createRef(inner);
	const maybe = createMaybeType(ref);
	assert !ccgIntroducedPtr(maybe);
}

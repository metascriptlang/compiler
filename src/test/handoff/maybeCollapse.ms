// Route 9: Maybe<T> type collapse
//
// Maybe<Ref<T>> and Maybe<Ptr<T>> collapse to the inner pointer type
// (natively nullable). Maybe<Struct> creates a wrapper with hasValue flag.

import {
	TypeKind, createStruct, createRef, createPtr,
	numberType, stringType,
	createMaybeType, isMaybeType,
} from "../../checker/types";
import { ccgIntroducedPtr } from "../../codegen/c/types";

test "Maybe<Ref<T>> collapses to Ref<T>" {
	const inner = createStruct("FooM", ["x"], [numberType()], true);
	const ref = createRef(inner);
	const maybe = createMaybeType(ref);
	assert maybe.kind === TypeKind.Ref;
	assert !isMaybeType(maybe);
}

test "Maybe<Ptr<T>> collapses to Ptr<T>" {
	const inner = createStruct("BarM", ["x"], [numberType()], true);
	const ptr = createPtr(inner);
	const maybe = createMaybeType(ptr);
	assert maybe.kind === TypeKind.Ptr;
	assert !isMaybeType(maybe);
}

test "Maybe<Struct> creates wrapper" {
	const inner = createStruct("TokM", ["kind", "value"], [numberType(), stringType()], true);
	const maybe = createMaybeType(inner);
	assert maybe.kind === TypeKind.Struct;
	assert isMaybeType(maybe);
	assert maybe.typeNames.length === 2;
}

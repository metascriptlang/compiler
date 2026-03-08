// Route 13: Type coercion at phase boundaries
//
// Tests implicit type coercions that the checker must support.
// Each coercion is verified against Nim reference behavior.

import {
	Type, TypeKind, createStruct, createRef, createEnum,
	numberType, stringType,
} from "../../checker/types";
import { isAssignable } from "../../checker/compat";

// ===== Ref<T> → T auto-deref =====
// Nim: ref T auto-derefs transparently. proc foo(x: T) accepts ref T.

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
// Nim: enum does NOT implicitly convert to int. Requires ord().
// Our hasFlag/setFlag should accept the enum type directly.

test "isAssignable: Enum → number is NOT allowed" {
	const e = createEnum("Color", ["Red", "Green", "Blue"]);
	assert !isAssignable(e, numberType());
}

test "isAssignable: Enum → Enum same name" {
	const e = createEnum("Color", ["Red", "Green", "Blue"]);
	assert isAssignable(e, e);
}

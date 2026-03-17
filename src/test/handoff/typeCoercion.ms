// Route 13: Type coercion at phase boundaries
//
// Tests implicit type coercions that the checker must support.
// Each coercion is verified against standard reference behavior.

import { Type, TypeKind } from "../../ast/node";
import { createStruct, createRef, createEnum, numberType, stringType } from "../../checker/types";
import { isAssignable } from "../../checker/compat";

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

// Type Compatibility - table-driven assignability checking

import { Type, TypeKind, isNumeric } from "./types";
import { test, check, testGroup } from "std/testing";
import {
	numberType, stringType, booleanType, voidType, nullType, unknownType,
	createPrimitive, createArray, createFunction, createObject, createUnion,
} from "./types";

// ===== Assignability =====

export function isAssignable(source: Type, target: Type): boolean {
	// Same kind is always compatible
	if (source.kind === target.kind) {
		// For compound types, check structural compatibility
		if (source.kind === TypeKind.Array) {
			return isAssignable(source.typeReturn, target.typeReturn);
		}
		if (source.kind === TypeKind.Function) {
			return isFunctionAssignable(source, target);
		}
		if (source.kind === TypeKind.Object) {
			return isObjectAssignable(source, target);
		}
		return true;
	}

	// Unknown on either side: inference pending, allow
	if (source.kind === TypeKind.Unknown || target.kind === TypeKind.Unknown) {
		return true;
	}

	// Error type is compatible with everything (suppress cascading errors)
	if (source.kind === TypeKind.Error || target.kind === TypeKind.Error) {
		return true;
	}

	// null assignable to nullable targets (Object, Array, Function, Ref, Ptr)
	if (source.kind === TypeKind.Null) {
		return target.kind === TypeKind.Object || target.kind === TypeKind.Array ||
			target.kind === TypeKind.Function || target.kind === TypeKind.Ref ||
			target.kind === TypeKind.Ptr;
	}

	// Numeric widening: any numeric type assignable to Number
	if (isNumeric(source) && target.kind === TypeKind.Number) {
		return true;
	}

	// Source is union: all members must be assignable to target
	if (source.kind === TypeKind.Union) {
		for (const member of source.typeChildren) {
			if (!isAssignable(member, target)) return false;
		}
		return true;
	}

	// Target is union: source must be assignable to at least one member
	if (target.kind === TypeKind.Union) {
		for (const member of target.typeChildren) {
			if (isAssignable(source, member)) return true;
		}
		return false;
	}

	return false;
}

// Function assignability: contravariant params, covariant return
function isFunctionAssignable(source: Type, target: Type): boolean {
	if (source.typeChildren.length !== target.typeChildren.length) return false;
	// Check params (contravariant: target params assignable to source params)
	let i = 0;
	for (const sourceParam of source.typeChildren) {
		if (i < target.typeChildren.length) {
			if (!isAssignable(target.typeChildren[i], sourceParam)) return false;
		}
		i += 1;
	}
	// Check return (covariant)
	if (source.typeReturn !== null && target.typeReturn !== null) {
		return isAssignable(source.typeReturn, target.typeReturn);
	}
	return true;
}

// Object assignability: structural (source has all target properties)
function isObjectAssignable(source: Type, target: Type): boolean {
	for (const targetProp of target.typeNames) {
		let found = false;
		let ti = 0;
		// Find index of targetProp in target.typeNames
		let targetIdx = 0;
		let idx = 0;
		for (const tn of target.typeNames) {
			if (tn === targetProp) { targetIdx = idx; }
			idx += 1;
		}
		// Look for matching prop in source
		let si = 0;
		for (const sourceProp of source.typeNames) {
			if (sourceProp === targetProp) {
				found = true;
				// Check type compatibility
				if (si < source.typeChildren.length && targetIdx < target.typeChildren.length) {
					if (!isAssignable(source.typeChildren[si], target.typeChildren[targetIdx])) {
						return false;
					}
				}
			}
			si += 1;
		}
		if (!found) return false;
	}
	return true;
}

// ===== Tests =====

testGroup("Compat Primitives", () => {
	test("same kind", () => {
		check(isAssignable(numberType(), numberType()));
		check(isAssignable(stringType(), stringType()));
		check(isAssignable(booleanType(), booleanType()));
	});
	test("different kind", () => {
		check(!isAssignable(numberType(), stringType()));
		check(!isAssignable(stringType(), booleanType()));
	});
	test("unknown compatible", () => {
		check(isAssignable(unknownType(), numberType()));
		check(isAssignable(numberType(), unknownType()));
	});
	test("numeric widening", () => {
		check(isAssignable(createPrimitive(TypeKind.Int32), numberType()));
		check(isAssignable(createPrimitive(TypeKind.Float64), numberType()));
	});
	test("null to nullable", () => {
		check(isAssignable(nullType(), createObject("Foo", [], [], false)));
		check(isAssignable(nullType(), createArray(numberType())));
		check(!isAssignable(nullType(), numberType()));
	});
});

testGroup("Compat Arrays", () => {
	test("same element", () => {
		check(isAssignable(createArray(numberType()), createArray(numberType())));
	});
	test("different element", () => {
		check(!isAssignable(createArray(numberType()), createArray(stringType())));
	});
	test("unknown element", () => {
		check(isAssignable(createArray(unknownType()), createArray(numberType())));
	});
});

testGroup("Compat Functions", () => {
	test("same signature", () => {
		const f1 = createFunction([numberType()], ["a"], stringType());
		const f2 = createFunction([numberType()], ["b"], stringType());
		check(isAssignable(f1, f2));
	});
	test("different param count", () => {
		const f1 = createFunction([numberType()], ["a"], voidType());
		const f2 = createFunction([], [], voidType());
		check(!isAssignable(f1, f2));
	});
	test("covariant return", () => {
		const f1 = createFunction([], [], unknownType());
		const f2 = createFunction([], [], numberType());
		check(isAssignable(f1, f2));
	});
});

testGroup("Compat Objects", () => {
	test("exact match", () => {
		const o1 = createObject("A", ["x"], [numberType()], false);
		const o2 = createObject("B", ["x"], [numberType()], false);
		check(isAssignable(o1, o2));
	});
	test("source has extra props", () => {
		const o1 = createObject("A", ["x", "y"], [numberType(), stringType()], false);
		const o2 = createObject("B", ["x"], [numberType()], false);
		check(isAssignable(o1, o2));
	});
	test("source missing prop", () => {
		const o1 = createObject("A", ["x"], [numberType()], false);
		const o2 = createObject("B", ["x", "y"], [numberType(), stringType()], false);
		check(!isAssignable(o1, o2));
	});
});

testGroup("Compat Unions", () => {
	test("source union all match", () => {
		const u = createUnion([numberType(), stringType()]);
		check(!isAssignable(u, numberType()));
	});
	test("target union has match", () => {
		const u = createUnion([numberType(), stringType()]);
		check(isAssignable(numberType(), u));
		check(isAssignable(stringType(), u));
		check(!isAssignable(booleanType(), u));
	});
});

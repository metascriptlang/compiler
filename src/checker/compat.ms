// Type Compatibility - table-driven assignability checking

import {
	Type, TypeKind, isNumeric,
	numberType, stringType, booleanType, voidType, nullType, unknownType, errorType,
	createPrimitive, createArray, createFunction, createObject, createUnion,
	createEnum, createResult, createRef, createPtr, createDistinct, createGenericParam,
} from "./types";
import { test, check, testGroup } from "std/testing";

// ===== Assignability =====

export function isAssignable(source: Type, target: Type): boolean {
	// Same kind is always compatible
	if (source.kind === target.kind) {
		return match (source.kind) {
			TypeKind.Array | TypeKind.Ref | TypeKind.Ptr => isAssignable(source.typeReturn, target.typeReturn),
			TypeKind.Function => isFunctionAssignable(source, target),
			TypeKind.Object => isObjectAssignable(source, target),
			TypeKind.Enum | TypeKind.Distinct => source.typeName === target.typeName,
			TypeKind.Result => {
				const okCompat = isAssignable(source.typeReturn, target.typeReturn);
				const errCompat = isAssignable(source.typeExtra, target.typeExtra);
				okCompat && errCompat
			},
			_ => true,
		};
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
		return match (target.kind) {
			TypeKind.Object | TypeKind.Array | TypeKind.Function | TypeKind.Ref | TypeKind.Ptr => true,
			_ => false,
		};
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
		if (!isAssignable(target.typeChildren[i], sourceParam)) return false;
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
	let targetIdx = 0;
	for (const targetProp of target.typeNames) {
		// Look for matching prop in source
		let found = false;
		let si = 0;
		for (const sourceProp of source.typeNames) {
			if (sourceProp === targetProp) {
				found = true;
				if (si < source.typeChildren.length && targetIdx < target.typeChildren.length) {
					if (!isAssignable(source.typeChildren[si], target.typeChildren[targetIdx])) {
						return false;
					}
				}
			}
			si += 1;
		}
		if (!found) return false;
		targetIdx += 1;
	}
	return true;
}

// ===== Overload Resolution =====

export enum TypeRelation {
	None,           // 0 - no match
	Convertible,    // 1 - requires conversion
	IntConv,        // 2 - int/float conversion
	Subtype,        // 3 - inheritance/structural
	Generic,        // 4 - generic param match / inference pending
	FromLiteral,    // 5 - from literal (proven safe)
	Exact,          // 6 - exact match
}

export function typeRelation(formal: Type, actual: Type): TypeRelation {
	// Same kind: dispatch on type-specific rules
	if (formal.kind === actual.kind) {
		return match (formal.kind) {
			TypeKind.Object => {
				if (formal.typeName === actual.typeName) return TypeRelation.Exact;
				if (isObjectAssignable(actual, formal)) return TypeRelation.Subtype;
				TypeRelation.None
			},
			TypeKind.Enum | TypeKind.Distinct => {
				if (formal.typeName === actual.typeName) return TypeRelation.Exact;
				TypeRelation.None
			},
			TypeKind.Result => {
				if (formal.typeReturn !== null && actual.typeReturn !== null) {
					const okRel = typeRelation(formal.typeReturn, actual.typeReturn);
					if (okRel === TypeRelation.None) return TypeRelation.None;
				}
				if (formal.typeExtra !== null && actual.typeExtra !== null) {
					const errRel = typeRelation(formal.typeExtra, actual.typeExtra);
					if (errRel === TypeRelation.None) return TypeRelation.None;
				}
				TypeRelation.Exact
			},
			_ => TypeRelation.Exact,
		};
	}
	// Unknown = inference pending
	if (formal.kind === TypeKind.Unknown || actual.kind === TypeKind.Unknown) {
		return TypeRelation.Generic;
	}
	// GenericParam = inference pending
	if (formal.kind === TypeKind.GenericParam || actual.kind === TypeKind.GenericParam) {
		return TypeRelation.Generic;
	}
	// Error type = suppress cascading
	if (formal.kind === TypeKind.Error || actual.kind === TypeKind.Error) {
		return TypeRelation.Exact;
	}
	// Numeric widening: sized → Number
	if (isNumeric(actual) && formal.kind === TypeKind.Number) {
		return TypeRelation.IntConv;
	}
	// FromLiteral: Number literal → sized numeric formal
	if (isNumeric(formal) && actual.kind === TypeKind.Number) {
		return TypeRelation.FromLiteral;
	}
	// Null to nullable
	if (actual.kind === TypeKind.Null) {
		if (formal.kind === TypeKind.Object || formal.kind === TypeKind.Array ||
			formal.kind === TypeKind.Function || formal.kind === TypeKind.Ref || formal.kind === TypeKind.Ptr) {
			return TypeRelation.Subtype;
		}
	}
	// Union target: best match
	if (formal.kind === TypeKind.Union) {
		let best = TypeRelation.None;
		for (const member of formal.typeChildren) {
			const rel = typeRelation(member, actual);
			if ((rel as number) > (best as number)) { best = rel; }
		}
		return best;
	}
	return TypeRelation.None;
}

// Score a candidate function against actual arguments.
// Returns sum of TypeRelation values, or -1 if any param doesn't match.
export function scoreCandidate(paramTypes: Type[], argTypes: Type[]): number {
	if (paramTypes.length !== argTypes.length) return -1;
	let score = 0;
	for (let i = 0; i < paramTypes.length; i += 1) {
		const rel = typeRelation(paramTypes[i], argTypes[i]);
		if (rel === TypeRelation.None) return -1;
		score = score + (rel as number);
	}
	return score;
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

testGroup("TypeRelation", () => {
	test("exact match", () => {
		check(typeRelation(numberType(), numberType()) === TypeRelation.Exact);
		check(typeRelation(stringType(), stringType()) === TypeRelation.Exact);
	});
	test("no match", () => {
		check(typeRelation(numberType(), stringType()) === TypeRelation.None);
	});
	test("unknown = generic", () => {
		check(typeRelation(numberType(), unknownType()) === TypeRelation.Generic);
		check(typeRelation(unknownType(), numberType()) === TypeRelation.Generic);
	});
	test("int conversion", () => {
		check(typeRelation(numberType(), createPrimitive(TypeKind.Int32)) === TypeRelation.IntConv);
	});
	test("null to object", () => {
		check(typeRelation(createObject("Foo", [], [], false), nullType()) === TypeRelation.Subtype);
	});
});

testGroup("ScoreCandidate", () => {
	test("exact args", () => {
		const score = scoreCandidate([numberType(), stringType()], [numberType(), stringType()]);
		check(score === 12); // 6 + 6
	});
	test("arity mismatch", () => {
		check(scoreCandidate([numberType()], []) === -1);
	});
	test("type mismatch", () => {
		check(scoreCandidate([numberType()], [stringType()]) === -1);
	});
	test("mixed scoring", () => {
		const score = scoreCandidate([numberType(), numberType()], [numberType(), createPrimitive(TypeKind.Int32)]);
		check(score === 8); // 6 (exact) + 2 (intconv)
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

testGroup("Compat Result", () => {
	test("same result types", () => {
		const r1 = createResult(numberType(), stringType());
		const r2 = createResult(numberType(), stringType());
		check(isAssignable(r1, r2));
	});
	test("different ok type", () => {
		const r1 = createResult(numberType(), stringType());
		const r2 = createResult(stringType(), stringType());
		check(!isAssignable(r1, r2));
	});
	test("different err type", () => {
		const r1 = createResult(numberType(), stringType());
		const r2 = createResult(numberType(), numberType());
		check(!isAssignable(r1, r2));
	});
	test("unknown ok compatible", () => {
		const r1 = createResult(unknownType(), stringType());
		const r2 = createResult(numberType(), stringType());
		check(isAssignable(r1, r2));
	});
});

testGroup("Compat Enums", () => {
	test("same enum name", () => {
		const e1 = createEnum("Color", ["Red", "Green"]);
		const e2 = createEnum("Color", ["Red", "Green"]);
		check(isAssignable(e1, e2));
	});
	test("different enum name", () => {
		const e1 = createEnum("Color", ["Red"]);
		const e2 = createEnum("Shape", ["Circle"]);
		check(!isAssignable(e1, e2));
	});
});

testGroup("Compat Ref/Ptr", () => {
	test("same ref inner", () => {
		const r1 = createRef(numberType());
		const r2 = createRef(numberType());
		check(isAssignable(r1, r2));
	});
	test("different ref inner", () => {
		const r1 = createRef(numberType());
		const r2 = createRef(stringType());
		check(!isAssignable(r1, r2));
	});
	test("same ptr inner", () => {
		const p1 = createPtr(numberType());
		const p2 = createPtr(numberType());
		check(isAssignable(p1, p2));
	});
	test("null to ref", () => {
		check(isAssignable(nullType(), createRef(numberType())));
	});
	test("null to ptr", () => {
		check(isAssignable(nullType(), createPtr(numberType())));
	});
});

testGroup("Compat Distinct", () => {
	test("same distinct name", () => {
		const d1 = createDistinct(numberType());
		d1.typeName = "UserId";
		const d2 = createDistinct(numberType());
		d2.typeName = "UserId";
		check(isAssignable(d1, d2));
	});
	test("different distinct name", () => {
		const d1 = createDistinct(numberType());
		d1.typeName = "UserId";
		const d2 = createDistinct(numberType());
		d2.typeName = "GroupId";
		check(!isAssignable(d1, d2));
	});
});

testGroup("TypeRelation Extended", () => {
	test("enum exact", () => {
		const e1 = createEnum("Color", ["Red"]);
		const e2 = createEnum("Color", ["Red"]);
		check(typeRelation(e1, e2) === TypeRelation.Exact);
	});
	test("enum mismatch", () => {
		const e1 = createEnum("Color", ["Red"]);
		const e2 = createEnum("Shape", ["Circle"]);
		check(typeRelation(e1, e2) === TypeRelation.None);
	});
	test("result exact", () => {
		const r1 = createResult(numberType(), stringType());
		const r2 = createResult(numberType(), stringType());
		check(typeRelation(r1, r2) === TypeRelation.Exact);
	});
	test("result mismatch", () => {
		const r1 = createResult(numberType(), stringType());
		const r2 = createResult(stringType(), stringType());
		check(typeRelation(r1, r2) === TypeRelation.None);
	});
	test("from literal", () => {
		check(typeRelation(createPrimitive(TypeKind.Int32), numberType()) === TypeRelation.FromLiteral);
		check(typeRelation(createPrimitive(TypeKind.Float64), numberType()) === TypeRelation.FromLiteral);
	});
	test("generic param", () => {
		const gp = createGenericParam("T");
		check(typeRelation(gp, numberType()) === TypeRelation.Generic);
		check(typeRelation(numberType(), gp) === TypeRelation.Generic);
	});
});

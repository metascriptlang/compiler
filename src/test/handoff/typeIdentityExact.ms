// Route 1: Checker — type identity (`sameType`) is structural
//
// Identity answers "are these the same type"; assignability (`typeRelation`,
// `isAssignable`) answers "may one stand in for the other". They are separate
// relations and must stay separate: control-flow merges dedup branch types by
// IDENTITY, so a relation that reports two different aggregates as "the same"
// silently drops a union variant at the merge point.
//
// Reference model (`sameType`/`sameTypeAux`): dispatch on kind; nominal types
// compare by name; anonymous aggregates compare field names + field types +
// repr flags; value-carrying types compare values; transparent wrappers
// compare their inner type.

import { Type, TypeKind } from "../../ast/node";
import {
	createPrimitive, createStruct, createStringLiteral, createBooleanLiteral,
	createUnion, createTuple, createFunction, createArray,
	createGenericParam, createBorrow, createVar, createVarargs,
	createConditionalType, nullType,
} from "../../checker/types";
import { sameType } from "../../checker/compat";
import { canonicalizeBranchJoin } from "../../checker/flow";

function num(): Type { return createPrimitive(TypeKind.Number); }
function str(): Type { return createPrimitive(TypeKind.String); }
function bool(): Type { return createPrimitive(TypeKind.Boolean); }

test "identity: anonymous structs compare field types" {
	const a = createStruct("", ["ok", "value"], [bool(), num()], false);
	const b = createStruct("", ["ok", "error"], [bool(), str()], false);
	assert !sameType(a, b);
}

test "identity: anonymous structs with the same shape are identical" {
	const a = createStruct("", ["a"], [num()], false);
	const b = createStruct("", ["a"], [num()], false);
	assert sameType(a, b);
}

test "identity: anonymous structs with different field names differ" {
	const a = createStruct("", ["a"], [num()], false);
	const b = createStruct("", ["b"], [num()], false);
	assert !sameType(a, b);
}

test "identity: same fields but different repr are not identical" {
	// isInterface flips IsStruct — a value aggregate and a reference aggregate
	// share no C representation and must never compare identical.
	const value = createStruct("", ["a"], [num()], false);
	const reference = createStruct("", ["a"], [num()], true);
	assert !sameType(value, reference);
}

test "identity: named structs compare nominally" {
	const a = createStruct("Foo", ["a"], [num()], false);
	const b = createStruct("Foo", ["a"], [num()], false);
	const c = createStruct("Bar", ["a"], [num()], false);
	assert sameType(a, b);
	assert !sameType(a, c);
}

test "identity: string literal types compare values" {
	assert !sameType(createStringLiteral("x"), createStringLiteral("y"));
	assert sameType(createStringLiteral("x"), createStringLiteral("x"));
}

test "identity: boolean literal types compare values" {
	assert !sameType(createBooleanLiteral(true), createBooleanLiteral(false));
	assert sameType(createBooleanLiteral(true), createBooleanLiteral(true));
}

test "identity: unions compare members pairwise" {
	assert sameType(createUnion([num(), str()]), createUnion([num(), str()]));
	assert !sameType(createUnion([num(), str()]), createUnion([num(), bool()]));
}

test "identity: tuples compare elements" {
	assert sameType(createTuple([num(), str()]), createTuple([num(), str()]));
	assert !sameType(createTuple([num(), str()]), createTuple([num(), num()]));
}

test "identity: functions compare params and return" {
	assert sameType(createFunction([num()], ["a"], str()), createFunction([num()], ["a"], str()));
	assert !sameType(createFunction([num()], ["a"], str()), createFunction([str()], ["a"], str()));
	assert !sameType(createFunction([num()], ["a"], str()), createFunction([num()], ["a"], num()));
}

test "identity: transparent wrappers compare their inner type" {
	assert !sameType(createBorrow(num()), createBorrow(str()));
	assert sameType(createBorrow(num()), createBorrow(num()));
	assert !sameType(createVar(num()), createVar(str()));
	assert !sameType(createVarargs(createArray(num())), createVarargs(createArray(str())));
}

test "identity: conditional types compare their four components" {
	const a = createConditionalType(num(), str(), num(), str());
	assert !sameType(a, createConditionalType(str(), num(), str(), num()));
	assert sameType(a, createConditionalType(num(), str(), num(), str()));
}

test "identity: distinct generic params are not identical" {
	assert !sameType(createGenericParam("T"), createGenericParam("U"));
	assert sameType(createGenericParam("T"), createGenericParam("T"));
}

test "identity: different kinds are never identical" {
	assert !sameType(num(), str());
	assert !sameType(createArray(num()), createTuple([num()]));
}

function nestedIdentityType(leaf: Type, depth: int32, tuple: boolean): Type {
	let result = leaf;
	for (let i = 0; i < depth; i++) {
		result = tuple ? createTuple([result]) : createArray(result);
	}
	return result;
}

test "identity: deep arrays preserve unequal leaves" {
	let failures = "";
	for (const depth of [11, 13, 15, 30]) {
		const left = nestedIdentityType(createPrimitive(TypeKind.Int32), depth, false);
		const right = nestedIdentityType(str(), depth, false);
		if (sameType(left, right)) failures += " " + depth;
	}
	assert failures == "", "array depths" + failures;
}

test "identity: separately allocated deep arrays with equal leaves match" {
	for (const depth of [11, 13, 15, 30]) {
		const left = nestedIdentityType(createPrimitive(TypeKind.Int32), depth, false);
		const right = nestedIdentityType(createPrimitive(TypeKind.Int32), depth, false);
		assert sameType(left, right), "array depth " + depth;
	}
}

test "identity: deep tuples preserve unequal leaves" {
	let failures = "";
	for (const depth of [11, 13, 15, 30]) {
		const left = nestedIdentityType(createPrimitive(TypeKind.Int32), depth, true);
		const right = nestedIdentityType(str(), depth, true);
		if (sameType(left, right)) failures += " " + depth;
	}
	assert failures == "", "tuple depths" + failures;
}

test "identity: separately allocated deep tuples with equal leaves match" {
	for (const depth of [11, 13, 15, 30]) {
		const left = nestedIdentityType(createPrimitive(TypeKind.Int32), depth, true);
		const right = nestedIdentityType(createPrimitive(TypeKind.Int32), depth, true);
		assert sameType(left, right), "tuple depth " + depth;
	}
}

test "identity: recursive array pairs terminate without poisoning later queries" {
	const left = createArray(null);
	const right = createArray(null);
	left.typeReturn = left;
	right.typeReturn = right;
	const equal = sameType(left, right);
	left.typeReturn = null;
	right.typeReturn = null;
	assert equal;
	assert !sameType(createPrimitive(TypeKind.Int32), str());
}

test "identity: recursive tuples still compare leaves after revisiting a pair" {
	const left = createTuple([]);
	const right = createTuple([]);
	left.typeChildren.push(left);
	left.typeChildren.push(createPrimitive(TypeKind.Int32));
	right.typeChildren.push(right);
	right.typeChildren.push(str());
	const equal = sameType(left, right);
	left.typeChildren = [];
	right.typeChildren = [];
	assert !equal;
}

test "identity: nullable flow joins keep distinct deep array leaves" {
	const left = nestedIdentityType(createPrimitive(TypeKind.Int32), 15, false);
	const different = nestedIdentityType(str(), 15, false);
	const joined = canonicalizeBranchJoin(createUnion([left, different, nullType()]));
	assert joined.typeReturn != null;
	assert joined.typeReturn.kind == TypeKind.Union;
	assert joined.typeReturn.typeChildren.length == 2;
}

test "identity: nullable flow joins deduplicate equal deep array leaves" {
	const left = nestedIdentityType(createPrimitive(TypeKind.Int32), 15, false);
	const equal = nestedIdentityType(createPrimitive(TypeKind.Int32), 15, false);
	const joined = canonicalizeBranchJoin(createUnion([left, equal, nullType()]));
	assert joined.typeReturn != null;
	assert joined.typeReturn.kind == TypeKind.Array;
	assert sameType(joined.typeReturn, left);
}

test "identity: repeated deep queries preserve both outcomes" {
	const left = nestedIdentityType(createPrimitive(TypeKind.Int32), 15, false);
	const different = nestedIdentityType(str(), 15, false);
	const equal = nestedIdentityType(createPrimitive(TypeKind.Int32), 15, false);
	for (let i = 0; i < 3; i++) {
		assert sameType(left, equal);
		assert !sameType(left, different);
		assert !sameType(different, left);
	}
}

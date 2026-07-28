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
	createConditionalType,
} from "../../checker/types";
import { sameType } from "../../checker/compat";

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

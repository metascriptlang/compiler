// Route 1: Checker — typeRelation identity (Exact) must be structural
//
// `TypeRelation.Exact` means "these are the same type", and flow-merge dedup
// (checker/flow.ms getTypeAtBranchLabel) relies on it to decide whether two
// narrowed antecedents collapse into one. Comparing only `typeName` makes
// every anonymous aggregate identical to every other, which silently drops
// union variants at a merge point.
//
// Reference model: identity compares field names + field types pairwise for
// anonymous aggregates, values for value-carrying types, and inner types for
// transparent wrappers. Named nominal types keep comparing by name.

import { Type, TypeKind } from "../../ast/node";
import {
	createPrimitive, createStruct, createStringLiteral, createBooleanLiteral,
	createUnion, createTuple, createFunction, createArray,
	createGenericParam, createBorrow, createVar, createVarargs,
	createConditionalType,
} from "../../checker/types";
import { typeRelation, TypeRelation } from "../../checker/compat";

function num(): Type { return createPrimitive(TypeKind.Number); }
function str(): Type { return createPrimitive(TypeKind.String); }

test "identity: anonymous structs compare field types" {
	const a = createStruct("", ["ok", "value"], [createPrimitive(TypeKind.Boolean), num()], false);
	const b = createStruct("", ["ok", "error"], [createPrimitive(TypeKind.Boolean), str()], false);
	assert typeRelation(a, b) !== TypeRelation.Exact;
}

test "identity: anonymous structs with the same shape are Exact" {
	const a = createStruct("", ["a"], [num()], false);
	const b = createStruct("", ["a"], [num()], false);
	assert typeRelation(a, b) === TypeRelation.Exact;
}

test "identity: anonymous structs with different field names differ" {
	const a = createStruct("", ["a"], [num()], false);
	const b = createStruct("", ["b"], [num()], false);
	assert typeRelation(a, b) !== TypeRelation.Exact;
}

test "identity: same fields but different repr are not identical" {
	// isInterface flips IsStruct — a value aggregate and a reference aggregate
	// share no C representation and must never compare identical.
	const value = createStruct("", ["a"], [num()], false);
	const reference = createStruct("", ["a"], [num()], true);
	assert typeRelation(value, reference) !== TypeRelation.Exact;
}

test "identity: named structs still compare nominally" {
	const a = createStruct("Foo", ["a"], [num()], false);
	const b = createStruct("Foo", ["a"], [num()], false);
	assert typeRelation(a, b) === TypeRelation.Exact;
}

test "identity: string literal types compare values" {
	assert typeRelation(createStringLiteral("x"), createStringLiteral("y")) === TypeRelation.None;
	assert typeRelation(createStringLiteral("x"), createStringLiteral("x")) === TypeRelation.Exact;
}

test "identity: boolean literal types compare values" {
	assert typeRelation(createBooleanLiteral(true), createBooleanLiteral(false)) === TypeRelation.None;
	assert typeRelation(createBooleanLiteral(true), createBooleanLiteral(true)) === TypeRelation.Exact;
}

test "identity: unions compare members pairwise" {
	const a = createUnion([num(), str()]);
	const b = createUnion([num(), str()]);
	assert typeRelation(a, b) === TypeRelation.Exact;
	const c = createUnion([num(), createPrimitive(TypeKind.Boolean)]);
	assert typeRelation(a, c) !== TypeRelation.Exact;
}

test "identity: tuples compare elements" {
	assert typeRelation(createTuple([num(), str()]), createTuple([num(), str()])) === TypeRelation.Exact;
	assert typeRelation(createTuple([num(), str()]), createTuple([num(), num()])) !== TypeRelation.Exact;
}

test "identity: functions compare params and return" {
	const f = createFunction([num()], ["a"], str());
	const g = createFunction([num()], ["a"], str());
	const h = createFunction([str()], ["a"], str());
	assert typeRelation(f, g) === TypeRelation.Exact;
	assert typeRelation(f, h) !== TypeRelation.Exact;
}

test "identity: transparent wrappers compare their inner type" {
	assert typeRelation(createBorrow(num()), createBorrow(str())) === TypeRelation.None;
	assert typeRelation(createBorrow(num()), createBorrow(num())) === TypeRelation.Exact;
	assert typeRelation(createVar(num()), createVar(str())) === TypeRelation.None;
	assert typeRelation(createVarargs(createArray(num())), createVarargs(createArray(str()))) === TypeRelation.None;
}

test "identity: conditional types compare their four components" {
	const a = createConditionalType(num(), str(), num(), str());
	const b = createConditionalType(str(), num(), str(), num());
	assert typeRelation(a, b) === TypeRelation.None;
	const c = createConditionalType(num(), str(), num(), str());
	assert typeRelation(a, c) === TypeRelation.Exact;
}

test "identity: distinct generic params are not identical" {
	assert typeRelation(createGenericParam("T"), createGenericParam("U")) !== TypeRelation.Exact;
	assert typeRelation(createGenericParam("T"), createGenericParam("T")) === TypeRelation.Exact;
}

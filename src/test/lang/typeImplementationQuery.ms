import { Node, NodeKind, TypeKind, bindSym, getType, getTypeImpl, resolveType, sameType, typeKind } from "std/meta";

struct QueryPoint { x: int32; label: string; }
struct QueryPair<T> { value: T; label: string; }
struct QueryNest<T> { inner: QueryPair<T>; label: string; }
struct QueryUniform<T> { first: T; second: T; }
interface QueryLink<T> { value: T; children: QueryLink<T>[]; }
type QueryAlias1<T> = QueryPair<T>;
type QueryAlias2<T> = QueryAlias1<T>;
type QueryAlias3<T> = QueryAlias2<T>;
type QueryAlias4<T> = QueryAlias3<T>;
type QueryAlias5<T> = QueryAlias4<T>;
type QueryAlias6<T> = QueryAlias5<T>;

macro pairFields(value: Node, expectedField: Node): Node {
	const shape = getTypeImpl(value);
	if (shape == null || shape.kind != NodeKind.TypeObject) error("missing concrete pair implementation", value);
	if (!sameType(value, shape) || typeKind(value) != typeKind(shape)) error("implementation lost nominal identity", value);
	const original = getType(shape);
	if (original == null || !sameType(original, value)) error("implementation cannot be re-queried", value);
	if (!sameType(shape.typExprFieldTypes[0], expectedField)) error("generic value field was not substituted", value);
	if (typeKind(shape.typExprFieldTypes[1]) != TypeKind.String) error("label field lost string identity", value);
	if (sameType(resolveType("QueryPair<int32>"), resolveType("QueryPair<string>"))) error("generic argument identity was erased", value);
	return { kind: NodeKind.StringLiteral, line: value.line, column: value.column, value: shape.typExprFieldNames.join(",") };
}

macro namedPointFields(value: Node): Node {
	const shape = getTypeImpl(QueryPoint);
	if (shape == null || shape.kind != NodeKind.TypeObject || !sameType(shape, value)) error("named implementation lost identity", value);
	if (typeKind(shape.typExprFieldTypes[0]) != TypeKind.Int32) error("named field lost int32 identity", value);
	return { kind: NodeKind.StringLiteral, line: value.line, column: value.column, value: shape.typExprFieldNames.join(",") };
}

macro nestedPairFields(value: Node, expectedPair: Node): Node {
	const shape = getTypeImpl(value);
	if (shape == null || shape.kind != NodeKind.TypeObject) error("missing nested implementation", value);
	const inner = shape.typExprFieldTypes[0];
	if (!sameType(inner, expectedPair)) error("nested generic field lost identity", value);
	const innerShape = getTypeImpl(inner);
	if (innerShape == null || innerShape.kind != NodeKind.TypeObject || !sameType(innerShape, expectedPair)) error("nested field cannot be queried", value);
	if (typeKind(innerShape.typExprFieldTypes[0]) != TypeKind.Int32) error("nested generic argument was not substituted", value);
	return { kind: NodeKind.StringLiteral, line: value.line, column: value.column, value: innerShape.typExprFieldNames.join(",") };
}

macro recursiveFields(value: Node): Node {
	const shape = getTypeImpl(value);
	if (shape == null || shape.kind != NodeKind.TypeObject || !sameType(shape, value)) error("recursive implementation lost identity", value);
	if (typeKind(shape.typExprFieldTypes[0]) != TypeKind.Int32) error("recursive generic argument was not substituted", value);
	const children = getTypeImpl(shape.typExprFieldTypes[1]);
	if (children == null || children.kind != NodeKind.TypeArray) error("missing recursive array implementation", value);
	if (!sameType(children.typExprElement, value)) error("recursive array element lost nominal identity", value);
	const childShape = getTypeImpl(children.typExprElement);
	if (childShape == null || childShape.kind != NodeKind.TypeObject || !sameType(childShape, value)) error("recursive field cannot be queried", value);
	return { kind: NodeKind.StringLiteral, line: value.line, column: value.column, value: childShape.typExprFieldNames.join(",") };
}

test "implementation query substitutes integer generic fields" {
	const integer: int32 = 7;
	const pair: QueryPair<int32> = { value: integer, label: "seven" };
	assert pairFields(pair, integer) == "value,label";
}

test "implementation query substitutes string generic fields" {
	const text: string = "seven";
	const pair: QueryPair<string> = { value: text, label: text };
	assert pairFields(pair, text) == "value,label";
}

test "implementation query resolves deep generic aliases" {
	const integer: int32 = 7;
	const alias: QueryAlias6<int32> = { value: integer, label: "seven" };
	assert pairFields(alias, integer) == "value,label";
}

test "named implementation query retains field identity" {
	const point: QueryPoint = { x: 7, label: "seven" };
	assert namedPointFields(point) == "x,label";
}

test "reflected nested generic field can be queried independently" {
	const pair: QueryPair<int32> = { value: 7, label: "seven" };
	const nested: QueryNest<int32> = { inner: pair, label: "outer" };
	assert nestedPairFields(nested, pair) == "value,label";
}

test "recursive generic element retains its concrete type" {
	const link: QueryLink<int32> = { value: 7, children: [] };
	assert recursiveFields(link) == "value,children";
}

test "Object.keys uses concrete generic fields" {
	const pair: QueryPair<int32> = { value: 7, label: "seven" };
	assert Object.keys(pair).join(",") == "value,label";
}

test "Object.values uses concrete uniform generic fields" {
	const uniform: QueryUniform<int32> = { first: 7, second: 9 };
	const values = Object.values(uniform);
	assert values[0] == 7 && values[1] == 9;
}

macro argumentKind(value: Node): Node {
	if (getType(value) == null) error("the argument carries no type", value);
	const kind = typeKind(value);
	const name = kind == TypeKind.Int32 ? "int32" : kind == TypeKind.String ? "string" : "other";
	return { kind: NodeKind.StringLiteral, line: value.line, column: value.column, value: name };
}

macro firstElementKind(list: Node): Node {
	const element = list.elements[0];
	if (getType(element) == null) error("the first element carries no type", element);
	const name = typeKind(element) == TypeKind.Int32 ? "int32" : "other";
	return { kind: NodeKind.StringLiteral, line: list.line, column: list.column, value: name };
}

macro forwardArgumentKind(value: Node): Node {
	return {
		kind: NodeKind.CallExpr,
		line: value.line,
		column: value.column,
		callee: bindSym("argumentKind"),
		arguments: [value],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
}

macro forwardAgain(value: Node): Node {
	return {
		kind: NodeKind.CallExpr,
		line: value.line,
		column: value.column,
		callee: bindSym("forwardArgumentKind"),
		arguments: [value],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
}

macro forwardFirstElementKind(list: Node): Node {
	return {
		kind: NodeKind.CallExpr,
		line: list.line,
		column: list.column,
		callee: bindSym("firstElementKind"),
		arguments: [list],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
}

test "a type query reads the argument of a macro written at the call" {
	const integer: int32 = 3;
	assert argumentKind(integer) == "int32";
}

test "a type query reads an argument that a macro passed to another macro" {
	const integer: int32 = 3;
	assert forwardArgumentKind(integer) == "int32";
}

test "a type query reads an expression that a macro passed to another macro" {
	const integer: int32 = 3;
	assert forwardArgumentKind(integer + 1) == "int32";
}

test "a type query reads a string that a macro passed to another macro" {
	const text: string = "three";
	assert forwardArgumentKind(text) == "string";
}

test "a type query reads an argument forwarded through two macros" {
	const integer: int32 = 3;
	assert forwardAgain(integer) == "int32";
}

test "a type query reads an element of a list that a macro passed to another macro" {
	const first: int32 = 3;
	const second: int32 = 4;
	assert forwardFirstElementKind([first, second]) == "int32";
}

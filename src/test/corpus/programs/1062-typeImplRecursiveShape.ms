// Parity program — getTypeImpl maps a named struct met inside a shape as its name node, so a
// self-recursive struct's array field and a mutually recursive pair map finitely; asking
// getTypeImpl of that name node unfolds it one level.
//
// @stdout: array:Tree|Tree:v,kids|A:b|B:a|back:MutA
// @exit: 0

import { Node, NodeKind, getTypeImpl, sameType } from "std/meta";

struct Tree { v: int32; kids: Tree[]; }
struct MutA { b: MutB[]; n: int32; }
struct MutB { a: MutA[]; m: int32; }

macro arrayElement(value: Node): Node {
	const shape = getTypeImpl(value);
	const kids = getTypeImpl(shape.typExprFieldTypes[1]);
	if (kids == null || kids.kind != NodeKind.TypeArray) error("kids is not an array shape", value);
	const element = kids.typExprElement;
	if (element.kind != NodeKind.Identifier) error("a named struct inside a shape is its name", value);
	if (!sameType(element, value)) error("the element lost the struct's identity", value);
	const unfolded = getTypeImpl(element);
	if (unfolded == null || unfolded.kind != NodeKind.TypeObject) error("the name node does not unfold", value);
	return { kind: NodeKind.StringLiteral, line: value.line, column: value.column, value: "array:" + element.name + "|Tree:" + unfolded.typExprFieldNames.join(",") };
}

macro mutualPair(a: Node): Node {
	const shapeA = getTypeImpl(a);
	const arrB = getTypeImpl(shapeA.typExprFieldTypes[0]);
	if (arrB == null || arrB.kind != NodeKind.TypeArray) error("A.b is not an array shape", a);
	const b = arrB.typExprElement;
	const shapeB = getTypeImpl(b);
	if (shapeB == null || shapeB.kind != NodeKind.TypeObject) error("B does not unfold", a);
	const arrA = getTypeImpl(shapeB.typExprFieldTypes[0]);
	const back = arrA.typExprElement;
	if (!sameType(back, a)) error("B.a lost A's identity", a);
	return { kind: NodeKind.StringLiteral, line: a.line, column: a.column, value: "A:" + shapeA.typExprFieldNames[0] + "|B:" + shapeB.typExprFieldNames[0] + "|back:" + back.name };
}

const tree: Tree = { v: 1, kids: [] };
const a: MutA = { b: [], n: 1 };
console.log(arrayElement(tree) + "|" + mutualPair(a));

// @stdout: shallow false true
// @stdout: deep false true
// @stdout: generic false true
// @exit: 0

import { Node, NodeKind, getType, sameType } from "std/meta";

type DeepInt = int32[][][][][][][][][][][][][][][];
type DeepString = string[][][][][][][][][][][][][][][];

macro equalType(a: Node, b: Node): Node {
	return {
		kind: NodeKind.BooleanLiteral,
		boolValue: sameType(getType(a), getType(b)),
	};
}

function identity<T>(value: T): T { return value; }

const integer: int32 = 1;
const text: string = "x";
const left: DeepInt = [];
const equal: DeepInt = [];
const different: DeepString = [];

console.log("shallow", equalType(integer, text), equalType(integer, integer));
console.log("deep", equalType(left, different), equalType(left, equal));
console.log("generic", equalType(identity<DeepInt>(left), identity<DeepString>(different)),
	equalType(identity<DeepInt>(left), identity<DeepInt>(equal)));

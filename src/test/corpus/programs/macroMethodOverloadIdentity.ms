// @stdout: method 2 extension 2 static 2 generic 2 shape (int32,string)->string values x y z 7
// @exit: 0

import { Node, NodeKind } from "std/meta";
import { exit } from "std/process";

macro paramCount(call: Node): Node {
	const shape = call.callee.nodeType;
	if (shape == null || shape.kind !== NodeKind.TypeFunction) error("the callee carries no function type", call);
	return { kind: NodeKind.NumberLiteral, line: call.line, column: call.column, value: shape.typExprParams.length };
}

macro calleeShape(call: Node): Node {
	const shape = call.callee.nodeType;
	if (shape == null || shape.kind !== NodeKind.TypeFunction) error("the callee carries no function type", call);
	let text = "(";
	let first = true;
	for (const param of shape.typExprParams) {
		if (!first) text = text + ",";
		first = false;
		text = text + (param.kind === NodeKind.Identifier ? param.name : "other");
	}
	const result = shape.typExprReturn;
	text = text + ")->" + (result.kind === NodeKind.Identifier ? result.name : "other");
	return { kind: NodeKind.StringLiteral, line: call.line, column: call.column, value: text };
}

macro unchanged(call: Node): Node { return call; }

class Box {
	put(a: int32): int32 { return a; }
	put(a: int32, b: string): string { return b; }
	static make(a: int32): int32 { return a; }
	static make(a: int32, b: string): string { return b; }
}
function widen(this box: Box, a: int32): int32 { return a; }
function widen(this box: Box, a: int32, b: string): string { return b; }
function increase(this box: Box, a: int32): int32 { return a; }
function increase(this box: Box, a: int32, ref value: int32): int32 {
	value += a;
	return value;
}

struct Cell<T> { value: T; }
function choose<T>(this cell: Cell<T>, a: int32): int32 { return a; }
function choose<T>(this cell: Cell<T>, a: int32, b: T): T { return b; }

const box = new Box();
const cell: Cell<string> = { value: "value" };
let count: int32 = 4;
const grew = unchanged(box.increase(3, count));
if (grew != 7 || count != 7) exit(1);
console.log(`method ${paramCount(box.put(1, "x"))} extension ${paramCount(box.widen(1, "x"))} static ${paramCount(Box.make(1, "x"))} generic ${paramCount(cell.choose(1, "x"))} shape ${calleeShape(cell.choose(1, "x"))} values ${unchanged(box.put(1, "x"))} ${unchanged(box.widen(1, "y"))} ${unchanged(cell.choose(1, "z"))} ${count}`);

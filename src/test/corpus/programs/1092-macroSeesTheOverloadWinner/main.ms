// @stdout: (int32)->int32 (int32,string)->string (int32,int32)->int32 (string)->string two three two
// @exit: 0
// note: a macro that receives a call to an overloaded function sees the overload the call resolved to, not the first one declared: its parameter count and types, whether the overload is local or imported and whether the winner is generic. A macro that returns the call with another argument appended re-resolves to the sibling overload, and one that returns the call unchanged keeps its overload. The callee type used to be the first routine's.

import { Node, NodeKind } from "std/meta";
import { scale } from "./other";

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

macro unchanged(call: Node): Node {
	return call;
}

macro withFlag(call: Node): Node {
	const grown: Node[] = [];
	for (const argument of call.arguments) grown.push(argument);
	grown.push({ kind: NodeKind.BooleanLiteral, line: call.line, column: call.column, boolValue: true });
	return {
		kind: NodeKind.CallExpr,
		line: call.line,
		column: call.column,
		callee: call.callee,
		arguments: grown,
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
}

function pick(a: int32): string { return "one"; }
function pick(a: int32, b: boolean): string { return "two"; }
function pick(a: int32, b: boolean, c: boolean): string { return "three"; }

function render(a: int32): int32 { return a; }
function render(a: int32, b: string): string { return b; }

function wrap<T>(a: T): T { return a; }
function wrap(a: int32, b: int32): int32 { return a + b; }

function main(): void {
	console.log(`${calleeShape(render(1))} ${calleeShape(render(1, "x"))} ${calleeShape(scale(2, 3))} ${calleeShape(wrap("s"))} ${withFlag(pick(1))} ${unchanged(pick(1, true, false))} ${unchanged(pick(1, true))}`);
}
main();

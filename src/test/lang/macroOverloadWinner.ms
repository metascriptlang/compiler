import { Node, NodeKind, getType } from "std/meta";

macro calleeShape(call: Node): Node {
	if (call.kind !== NodeKind.CallExpr) error("a call is required", call);
	const shape = call.callee.nodeType;
	if (shape == null || shape.kind !== NodeKind.TypeFunction) error("the callee carries no function type", call);
	const queried = getType(call.callee);
	if (queried == null || queried.typExprParams.length != shape.typExprParams.length) {
		error("getType and nodeType disagree on the callee", call);
	}
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

function shortFirst(a: int32): int32 { return a; }
function shortFirst(a: int32, b: string): string { return b; }

function longFirst(a: int32, b: string): string { return b; }
function longFirst(a: int32): int32 { return a; }

function threeWay(a: int32): int32 { return a; }
function threeWay(a: int32, b: string): string { return b; }
function threeWay(a: int32, b: string, c: boolean): boolean { return c; }

function genericFirst<T>(a: T): T { return a; }
function genericFirst(a: int32, b: int32): int32 { return a + b; }

function genericLast(a: int32, b: int32): int32 { return a + b; }
function genericLast<T>(a: T): T { return a; }

test "macro overload winner: the shorter overload declared first" {
	assert calleeShape(shortFirst(1)) == "(int32)->int32";
	assert calleeShape(shortFirst(1, "x")) == "(int32,string)->string";
}

test "macro overload winner: the longer overload declared first" {
	assert calleeShape(longFirst(1)) == "(int32)->int32";
	assert calleeShape(longFirst(1, "x")) == "(int32,string)->string";
}

test "macro overload winner: three overloads, each call sees its own" {
	assert calleeShape(threeWay(1)) == "(int32)->int32";
	assert calleeShape(threeWay(1, "x")) == "(int32,string)->string";
	assert calleeShape(threeWay(1, "x", true)) == "(int32,string,boolean)->boolean";
}

test "macro overload winner: a generic overload declared first" {
	assert calleeShape(genericFirst("s")) == "(string)->string";
	assert calleeShape(genericFirst(1, 2)) == "(int32,int32)->int32";
}

test "macro overload winner: a generic overload declared last" {
	assert calleeShape(genericLast(1, 2)) == "(int32,int32)->int32";
	assert calleeShape(genericLast("s")) == "(string)->string";
}

test "macro overload winner: the call still runs the overload it resolved to" {
	assert shortFirst(1, "x") == "x";
	assert longFirst(2) == 2;
	assert threeWay(1, "x", true);
	assert genericFirst(3, 4) == 7;
}

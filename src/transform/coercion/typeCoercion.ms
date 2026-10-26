// String(x) becomes x.toString().

import { Node, NodeKind, CallExprData } from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeMember, makeCall, callBuiltinKind } from "../util";
import { firstExprKindAfter } from "../testUtil";

export function lowerTypeCoercion(program: Node, ctx: TransformContext): Node {
	return walkNode(program, lowerCoercionNode);
}

function lowerCoercionNode(node: Node): Node {
	if (node.kind != NodeKind.CallExpr) return node;
	const d = node.data as CallExprData;

	if (callBuiltinKind(node) != "ToString") return node;
	if (d.arguments.length != 1) return node;

	const loc = node.location;
	const toStringCallee = makeMember(d.arguments[0], "toString", loc);
	const call = makeCall(toStringCallee, [], loc);
	call.nodeType = node.nodeType;
	return call;
}

test "String(x) becomes call" { assert firstExprKindAfter("String(x);", lowerTypeCoercion) == NodeKind.CallExpr; }

test "Number(x) unchanged" { assert firstExprKindAfter("Number(x);", lowerTypeCoercion) == NodeKind.CallExpr; }

test "regular call unchanged" { assert firstExprKindAfter("foo(x);", lowerTypeCoercion) == NodeKind.CallExpr; }

test "String() no args unchanged" { assert firstExprKindAfter("String();", lowerTypeCoercion) == NodeKind.CallExpr; }

// String(x) becomes x.toString(); a bigint keeps String(x) for lowerBigIntOps.

import { Node, NodeKind, CallExprData, BuiltinKind, TypeKind, VariableDeclData, IdentifierData } from "../../ast/node";
import { isNullableBigInt } from "../../checker/types";
import { checkProgram } from "../../checker/checkPass";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeMember, makeCall, callBuiltinKind } from "../util";
import { firstExprKindAfter, parseInput, checkedCtx } from "../testUtil";

export function lowerTypeCoercion(program: Node, ctx: TransformContext): Node {
	return walkNode(program, lowerCoercionNode);
}

function lowerCoercionNode(node: Node): Node {
	if (node.kind != NodeKind.CallExpr) return node;
	const d = node.data as CallExprData;

	if (callBuiltinKind(node) != BuiltinKind.ToString) return node;
	if (d.arguments.length != 1) return node;
	const argType = d.arguments[0].nodeType;
	if (argType != null && (argType.kind == TypeKind.BigInt || isNullableBigInt(argType))) return node;

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

function calleeOfR(source: string, param: string): string {
	const result = parseInput("function f(b: " + param + "): void { const r = " + source + "; }");
	if (!result.ok) return "";
	lowerTypeCoercion(result.value, checkedCtx(checkProgram(result.value)));
	let callee = "";
	walkNode(result.value, (n: Node): Node => {
		if (n.kind != NodeKind.VariableDecl || (n.data as VariableDeclData).declName != "r") return n;
		const init = (n.data as VariableDeclData).initializer;
		if (init.kind == NodeKind.CallExpr && (init.data as CallExprData).callee.kind == NodeKind.Identifier) callee = ((init.data as CallExprData).callee.data as IdentifierData).name;
		return n;
	});
	return callee;
}

test "String of a bigint or a nullable bigint stays for the bigint lowering, String of a number does not" {
	assert calleeOfR("String(b)", "bigint") == "String";
	assert calleeOfR("String(b)", "bigint | null") == "String";
	assert calleeOfR("String(b)", "int32") == "";
}

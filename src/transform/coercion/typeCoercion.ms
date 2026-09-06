// Type Coercion Lowering — transforms String(x) → x.toString()
// Follows reference type_coercion.zig

import { Node, NodeKind, CallExprData, IdentifierData } from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeMember, makeCall } from "../util";
import { firstExprKindAfter } from "../testUtil";

// ===== Main Entry Point =====

export function lowerTypeCoercion(program: Node, ctx: TransformContext): Node {
	return walkNode(program, lowerCoercionNode);
}

// ===== Visitor =====

function lowerCoercionNode(node: Node): Node {
	if (node.kind != NodeKind.CallExpr) return node;
	const d = node.data as CallExprData;

	// Only transform String(x) with exactly 1 argument
	if (d.callee.kind != NodeKind.Identifier) return node;
	const calleeName = d.callee.data as IdentifierData;
	if (calleeName.name != "String") return node;
	if (d.arguments.length != 1) return node;

	const loc = node.location;
	// String(x) → x.toString()
	const toStringCallee = makeMember(d.arguments[0], "toString", loc);
	return makeCall(toStringCallee, [], loc);
}

// ===== Tests =====
test "String(x) becomes call" { assert firstExprKindAfter("String(x);", lowerTypeCoercion) == NodeKind.CallExpr; }

test "Number(x) unchanged" { assert firstExprKindAfter("Number(x);", lowerTypeCoercion) == NodeKind.CallExpr; }

test "regular call unchanged" { assert firstExprKindAfter("foo(x);", lowerTypeCoercion) == NodeKind.CallExpr; }

test "String() no args unchanged" { assert firstExprKindAfter("String();", lowerTypeCoercion) == NodeKind.CallExpr; }

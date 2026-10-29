import { Node, NodeKind, SourceLocation, TypeKind, BinaryExprData, CallExprData, IdentifierData, VariableDeclData } from "../../ast/node";
import { stringType, isStringLike, literalBase } from "../../checker/types";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeCall, makeNumber, makeMember, runtimeRef, isRuntimeProcCall } from "../util";
import { firstExprKindAfter, stmtCountAfter, parseInput, getStmts, makeCtx } from "../testUtil";

export function lowerStringConcatFlatten(program: Node, ctx: TransformContext): Node {
	walkNode(program, flattenConcat);
	return program;
}

export function lowerEnumOperandText(program: Node, ctx: TransformContext): Node {
	walkNode(program, stringifyEnumOperands);
	return program;
}

function isEnumTyped(node: Node): boolean {
	return node.nodeType != null && literalBase(node.nodeType).kind == TypeKind.Enum;
}

function stringifyEnumOperands(node: Node): Node {
	if (node.kind != NodeKind.BinaryExpr) return node;
	const d = node.data as BinaryExprData;
	if (d.operator == "+") {
		if (isEnumTyped(d.left) && isStringConcatChain(d.right)) d.left = coerceToString(d.left, d.left.location);
		if (isEnumTyped(d.right) && isStringConcatChain(d.left)) d.right = coerceToString(d.right, d.right.location);
	}
	return node;
}

function isStringLeaf(node: Node): boolean {
	if (node.kind == NodeKind.StringLiteral) return true;
	if (node.nodeType != null && isStringLike(node.nodeType)) return true;
	return isRuntimeProcCall(node, "msStringConcat") || isRuntimeProcCall(node, "msStringConcatArr");
}

function isStringConcatChain(node: Node): boolean {
	if (isStringLeaf(node)) return true;
	if (node.kind == NodeKind.BinaryExpr) {
		const bd = node.data as BinaryExprData;
		if (bd.operator == "+") {
			return isStringConcatChain(bd.left) || isStringConcatChain(bd.right);
		}
	}
	return false;
}

function collectConcatPartsDeep(node: Node): Node[] {
	const result: Node[] = [];
	const stack: Node[] = [node];
	while (stack.length > 0) {
		const cur = stack.pop();
		if (cur.kind == NodeKind.BinaryExpr) {
			const bd = cur.data as BinaryExprData;
			if (bd.operator == "+" && isStringConcatChain(cur)) {
				stack.push(bd.right);
				stack.push(bd.left);
				continue;
			}
		}
		if (cur.kind == NodeKind.CallExpr) {
			const cd = cur.data as CallExprData;
			if (isRuntimeProcCall(cur, "msStringConcat") && cd.arguments.length == 2) {
				stack.push(cd.arguments[1]);
				stack.push(cd.arguments[0]);
				continue;
			}
			if (isRuntimeProcCall(cur, "msStringConcatArr") && cd.arguments.length >= 1) {
				for (let i = cd.arguments.length - 1; i >= 1; i -= 1) {
					stack.push(cd.arguments[i]);
				}
				continue;
			}
		}
		result.push(cur);
	}
	return result;
}

function flattenConcat(node: Node): Node {
	if (node.kind != NodeKind.BinaryExpr) return node;
	const d = node.data as BinaryExprData;
	if (d.operator != "+") return node;

	const parts = collectConcatPartsDeep(node);

	if (!parts.some(isStringLeaf)) return node;

	const loc = node.location;

	if (parts.length == 2) {
		if (!parts.some(needsCoercion)) return node;
		const args: Node[] = [coerceToString(parts[0], loc), coerceToString(parts[1], loc)];
		const call2 = makeCall(runtimeRef("msStringConcat", loc), args, loc);
		call2.nodeType = stringType();
		return call2;
	}

	const allArgs: Node[] = [makeNumber(parts.length, loc)];
	for (const p of parts) {
		allArgs.push(coerceToString(p, loc));
	}
	const callN = makeCall(runtimeRef("msStringConcatArr", loc), allArgs, loc);
	callN.nodeType = stringType();
	return callN;
}

function needsCoercion(node: Node): boolean {
	if (node.kind == NodeKind.StringLiteral) return false;
	if (node.kind == NodeKind.NumberLiteral) return true;
	return node.nodeType != null && !isStringLike(node.nodeType);
}

function coerceToString(node: Node, loc: SourceLocation): Node {
	if (isStringLeaf(node)) return node;
	const member = makeMember(node, "toString", loc);
	const call = makeCall(member, [], loc);
	call.nodeType = stringType();
	return call;
}

test "variable addition unchanged" { assert firstExprKindAfter("x + y;", lowerStringConcatFlatten) == NodeKind.BinaryExpr; }

test "non-binary unchanged" { assert firstExprKindAfter("f();", lowerStringConcatFlatten) == NodeKind.CallExpr; }

test "single stmt passthrough" { assert stmtCountAfter("const x = 1;", lowerStringConcatFlatten) == 1; }

test "non-string binary unchanged" { assert firstExprKindAfter("x * y;", lowerStringConcatFlatten) == NodeKind.BinaryExpr; }

test "identifier unchanged" { assert firstExprKindAfter("x;", lowerStringConcatFlatten) == NodeKind.Identifier; }

test "two-part string stays binary" {
	assert firstExprKindAfter("\"a\" + x;", lowerStringConcatFlatten) == NodeKind.BinaryExpr;
}

test "numeric subtree inside string concat stays atomic" {
	const r = parseInput("const len = 21; const a = \"data[\" + (len + 1) + \"]\";");
	assert r.ok;
	const lowered = lowerStringConcatFlatten(r.value, makeCtx());
	const stmts = getStmts(lowered);
	const decl = stmts[stmts.length - 1];
	assert decl.kind == NodeKind.VariableDecl;
	const init = (decl.data as VariableDeclData).initializer;
	assert init.kind == NodeKind.CallExpr;
	const cd = init.data as CallExprData;
	assert (cd.callee.data as IdentifierData).name == "msStringConcatArr";
	assert cd.arguments.length == 4;
	const middle = cd.arguments[2];
	assert middle.kind == NodeKind.CallExpr;
	assert (middle.data as CallExprData).callee.kind == NodeKind.MemberExpr;
}

test "string-concat inner subtree gets descended" {
	const r = parseInput("const b = 0; const a = \"a\" + (b + \"c\");");
	assert r.ok;
	const lowered = lowerStringConcatFlatten(r.value, makeCtx());
	const stmts = getStmts(lowered);
	const decl = stmts[stmts.length - 1];
	assert decl.kind == NodeKind.VariableDecl;
	const init = (decl.data as VariableDeclData).initializer;
	assert init.kind == NodeKind.CallExpr;
	const cd = init.data as CallExprData;
	assert (cd.callee.data as IdentifierData).name == "msStringConcatArr";
	assert cd.arguments.length == 4;
}

test "all-numeric chain stays binary" {
	const r = parseInput("const a = 1 + 2 + 3;");
	assert r.ok;
	const lowered = lowerStringConcatFlatten(r.value, makeCtx());
	const stmts = getStmts(lowered);
	const decl = stmts[stmts.length - 1];
	assert decl.kind == NodeKind.VariableDecl;
	const init = (decl.data as VariableDeclData).initializer;
	assert init.kind == NodeKind.BinaryExpr;
	assert (init.data as BinaryExprData).operator == "+";
}

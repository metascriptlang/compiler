// A double carries more than 2·24+2 bits, so Math.fround of a double + - * / %
// over two float32 values is the exact IEEE float32 result C computes.

import { Node, NodeKind, BinaryExprData, UpdateExprData, TypeAssertionData, NumberLiteralData, ArrayLiteralData, ArrayAccessData, ExprStmtData, ForStmtData, Type, TypeKind, createNodeAt } from "../../ast/node";
import { TransformContext } from "../context";
import { peelToRepr, createPrimitive } from "../../checker/types";
import { addError } from "../../checker/context";
import { walkNode } from "../walker";
import { makeBinary, makeCall, makeMember, makeArrayAccess, makeNumber, runtimeRef } from "../util";
import { cloneIfPure } from "./intArithJS";

export function lowerFloat32JS(program: Node, ctx: TransformContext): Node {
	const postfixReads = new HashSet<Node>();
	walkNode(program, (node: Node): Node => materializeFloat32(node, ctx, postfixReads));
	return program;
}

function materializeFloat32(node: Node, ctx: TransformContext, postfixReads: HashSet<Node>): Node {
	return match (node.kind) {
		NodeKind.NumberLiteral => roundedLiteral(node),
		NodeKind.TypeAssertion => convertToFloat32(node),
		NodeKind.BinaryExpr => float32Binary(node, ctx),
		NodeKind.UpdateExpr => float32Update(node, ctx, postfixReads),
		NodeKind.ExprStmt => dropUnusedOldValue(node, postfixReads),
		NodeKind.ForStmt => dropUnusedUpdateValue(node, postfixReads),
		_ => node,
	};
}

function isFloat32(t: Type | null): boolean {
	const r = peelToRepr(t);
	return r != null && r.kind == TypeKind.Float32;
}

function fround(inner: Node): Node {
	const call = makeCall(makeMember(runtimeRef("Math", inner.location), "fround", inner.location), [inner], inner.location);
	call.nodeType = createPrimitive(TypeKind.Float32);
	return call;
}

function roundedLiteral(node: Node): Node {
	if (!isFloat32(node.nodeType)) return node;
	const d = node.data as NumberLiteralData;
	const narrowed = d.value as float32;
	const widened = narrowed as float64;
	if (widened == d.value || d.value != d.value) return node;
	const lit = makeNumber(widened, node.location);
	lit.nodeType = node.nodeType;
	return lit;
}

function convertToFloat32(node: Node): Node {
	if (!isFloat32(node.nodeType)) return node;
	const d = node.data as TypeAssertionData;
	const src = peelToRepr(d.asExpr != null ? d.asExpr.nodeType : null);
	if (src == null) return node;
	return match (src.kind) {
		TypeKind.Float64 | TypeKind.Number | TypeKind.Int32 | TypeKind.Uint32 => fround(d.asExpr),
		_ => node,
	};
}

function isFloat32Arithmetic(op: string): boolean {
	return op == "+" || op == "-" || op == "*" || op == "/" || op == "%" || op == "**";
}

function compoundBase(op: string): string {
	return match (op) {
		"+=" => "+",
		"-=" => "-",
		"*=" => "*",
		"/=" => "/",
		"%=" => "%",
		_ => "",
	};
}

function float32Binary(node: Node, ctx: TransformContext): Node {
	const d = node.data as BinaryExprData;
	const base = compoundBase(d.operator);
	if (base != "") {
		if (!isFloat32(d.left.nodeType)) return node;
		const readBack = cloneIfPure(d.left);
		if (readBack == null) {
			if (ctx.checkerCtx != null) {
				addError(ctx.checkerCtx, "float32 '" + d.operator + "' needs a left side that can be read twice; hoist the receiver or index into a local first", node.location.line, node.location.column);
			}
			return node;
		}
		const result = makeBinary(readBack, base, d.right, node.location);
		result.nodeType = d.left.nodeType;
		return makeBinary(d.left, "=", fround(result), node.location);
	}
	if (!isFloat32Arithmetic(d.operator) || !isFloat32(node.nodeType)) return node;
	return fround(node);
}

function float32Update(node: Node, ctx: TransformContext, postfixReads: HashSet<Node>): Node {
	const d = node.data as UpdateExprData;
	if (!isFloat32(d.updateArg.nodeType)) return node;
	const readBack = cloneIfPure(d.updateArg);
	const oldValue = d.isPrefix ? null : cloneIfPure(d.updateArg);
	if (readBack == null || (!d.isPrefix && oldValue == null)) {
		if (ctx.checkerCtx != null) {
			addError(ctx.checkerCtx, "float32 '" + d.updateOp + "' needs an operand that can be read twice; hoist the receiver or index into a local first", node.location.line, node.location.column);
		}
		return node;
	}
	const loc = node.location;
	const step = makeBinary(readBack, d.updateOp == "++" ? "+" : "-", makeNumber(1, loc), loc);
	step.nodeType = d.updateArg.nodeType;
	const stored = makeBinary(d.updateArg, "=", fround(step), loc);
	if (d.isPrefix) return stored;
	const pair = createNodeAt(NodeKind.ArrayLiteral, { elements: [oldValue as Node, stored] }, loc);
	const read = makeArrayAccess(pair, makeNumber(0, loc), loc);
	read.nodeType = d.updateArg.nodeType;
	postfixReads.add(read);
	return read;
}

function storeOfPostfixRead(expr: Node, postfixReads: HashSet<Node>): Node | null {
	if (expr == null || !postfixReads.has(expr)) return null;
	const pair = (expr.data as ArrayAccessData).array;
	return (pair.data as ArrayLiteralData).elements[1];
}

function dropUnusedOldValue(node: Node, postfixReads: HashSet<Node>): Node {
	const d = node.data as ExprStmtData;
	const store = storeOfPostfixRead(d.expr, postfixReads);
	if (store != null) d.expr = store;
	return node;
}

function dropUnusedUpdateValue(node: Node, postfixReads: HashSet<Node>): Node {
	const d = node.data as ForStmtData;
	const store = storeOfPostfixRead(d.forUpdate, postfixReads);
	if (store != null) d.forUpdate = store;
	return node;
}

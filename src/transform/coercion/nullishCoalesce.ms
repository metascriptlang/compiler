// Nullish Coalesce Lowering — transforms x ?? y → x !== null ? x : y
// Follows reference nullish_coalesce.zig
//
// Must run AFTER optionalChain so obj?.prop ?? fallback is already lowered.

import { Node, NodeKind, BinaryExprData, MemberExprData, TypeAssertionData, TypeKind, DeclKind, SourceLocation, Type, createNodeAt } from "../../ast/node";
import { isMaybeType, unwrapMaybeType, peelTransparentInstance, isNumeric, isBoolType, isStringLike, unknownType, createPtr, voidType } from "../../checker/types";
import { fitJoinedBranch, nullishPayloadType } from "../../checker/fit";
import { TransformContext, freshTempSym } from "../context";
import { walkNode, walkExpandBlocks } from "../walker";
import { makeNull, makeBinary, makeConditional, makeMember, makeVarDecl, makeAssign, makeIdentResolved } from "../util";
import { firstExprKindAfter } from "../testUtil";
import { cloneIfPure } from "./intArithJS";
import { cloneNodeKeepSem } from "../../monomorphize/clone";

// ===== Main Entry Point =====

export function lowerNullishCoalesce(program: Node, ctx: TransformContext): Node {
	if (ctx.jsBackend) {
		walkExpandBlocks(program, (stmt: Node, c: TransformContext): Node[] => lowerNullishStmt(stmt, c), ctx);
	}
	return walkNode(program, (node: Node): Node => lowerNullishNode(node, ctx, null));
}

function lowerNullishStmt(stmt: Node, ctx: TransformContext): Node[] {
	const temps: Node[] = [];
	const lowered = walkNode(stmt, (node: Node): Node => lowerNullishNode(node, ctx, temps));
	temps.push(lowered);
	return temps;
}

// ===== Visitor =====

export function rereadOperand(operand: Node): Node {
	return cloneIfPure(operand) != null ? cloneNodeKeepSem(operand) : operand;
}

export function asUnknown(n: Node, loc: SourceLocation): Node {
	const checked = createNodeAt(NodeKind.TypeAssertion, { asExpr: n, asType: "unknown" } as TypeAssertionData, loc);
	checked.nodeType = unknownType();
	return checked;
}

function nullishPresence(left: Node, loc: SourceLocation, ctx: TransformContext): Node {
	let checked = left;
	if (ctx.jsBackend) {
		checked = asUnknown(left, loc);
	} else if (left.nodeType != null && isStringLike(left.nodeType)) {
		checked = makeMember(left, "p", loc);
		checked.nodeType = createPtr(voidType());
	}
	return makeBinary(checked, "!==", makeNull(loc), loc);
}

function isPlainPath(n: Node): boolean {
	if (n.kind == NodeKind.Identifier) return true;
	if (n.kind != NodeKind.MemberExpr) return false;
	const d = n.data as MemberExprData;
	return !d.isOptional && isPlainPath(d.object);
}

export function nullishLowered(left: Node, right: Node, loc: SourceLocation, resultType: Type | null, ctx: TransformContext): Node {
	return lowerNullish(left, right, loc, resultType, ctx, null);
}

function lowerNullish(left: Node, right: Node, loc: SourceLocation, resultType: Type | null, ctx: TransformContext, temps: Node[] | null): Node {
	// A scalar left operand carries no null, and the lowered test would emit
	// `double !== NULL`, which is not valid C. TS keeps the expression legal and
	// its value is the left operand.
	const leftType = left.nodeType != null ? peelTransparentInstance(left.nodeType) : null;
	if (leftType != null && !isMaybeType(leftType) && (isNumeric(leftType) || isBoolType(leftType))) {
		return left;
	}

	// x ?? y → x !== null ? x : y
	let cond = nullishPresence(left, loc, ctx);
	let held = left;
	if (temps != null && !isPlainPath(left)) {
		const sym = freshTempSym(ctx, "nullish", leftType);
		const decl = makeVarDecl(sym.name, makeNull(loc), DeclKind.Var, loc);
		decl.resolvedSym = sym;
		decl.nodeType = sym.symbolType;
		temps.push(decl);
		cond = makeBinary(makeAssign(makeIdentResolved(sym, loc), asUnknown(left, loc), loc), "!==", makeNull(loc), loc);
		held = makeIdentResolved(sym, loc);
	} else {
		held = rereadOperand(left);
	}

	// Value-carried nullable (Maybe struct in C): when the fallback is non-null the
	// result type is the UNWRAPPED T, so the then-arm must read x.value — raw x would
	// mix carrier and payload in the C ternary (and JS backend strips .value back to x).
	// Nullable fallback keeps both arms in the carrier — no rewrite.
	const lt = leftType;
	const rt = right.nodeType != null ? peelTransparentInstance(right.nodeType) : null;
	const joined = resultType != null && nullishPayloadType(resultType) == null ? resultType : null;
	if (lt != null && isMaybeType(lt)
		&& rt != null && rt.kind != TypeKind.Null && !isMaybeType(rt)) {
		const read = makeMember(held, "value", loc);
		read.nodeType = unwrapMaybeType(lt);
		const val = payloadArm(read, joined, ctx);
		const c = makeConditional(cond, val, right, loc);
		c.nodeType = joined != null ? joined : val.nodeType;
		return c;
	}
	const payload = nullishPayloadType(lt);
	if (payload != null && joined != null && rt != null && nullishPayloadType(rt) == null && rt.kind != TypeKind.Null) {
		const asserted = createNodeAt(NodeKind.TypeAssertion, { asExpr: held, asType: "!" } as TypeAssertionData, loc);
		asserted.nodeType = payload;
		const val = payloadArm(asserted, joined, ctx);
		if (val != asserted) {
			const c = makeConditional(cond, val, right, loc);
			c.nodeType = joined;
			return c;
		}
	}
	const lowered = makeConditional(cond, held, right, loc);
	if (resultType != null) lowered.nodeType = resultType;
	return lowered;
}

function payloadArm(read: Node, joined: Type | null, ctx: TransformContext): Node {
	if (joined == null || ctx.checkerCtx == null) return read;
	return fitJoinedBranch(ctx.checkerCtx, read, joined);
}

function lowerNullishNode(node: Node, ctx: TransformContext, temps: Node[] | null): Node {
	if (node.kind != NodeKind.BinaryExpr) return node;
	const d = node.data as BinaryExprData;
	if (d.operator != "??") return node;
	return lowerNullish(d.left, d.right, node.location, node.nodeType, ctx, temps);
}

// ===== Tests =====
test "nullish coalesce becomes conditional" { assert firstExprKindAfter("x ?? 42;", lowerNullishCoalesce) == NodeKind.ConditionalExpr; }

test "other binary unchanged" { assert firstExprKindAfter("x + y;", lowerNullishCoalesce) == NodeKind.BinaryExpr; }

test "logical or unchanged" { assert firstExprKindAfter("x || y;", lowerNullishCoalesce) == NodeKind.BinaryExpr; }

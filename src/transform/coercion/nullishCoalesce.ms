// Nullish Coalesce Lowering — transforms x ?? y → x !== null ? x : y
// Follows reference nullish_coalesce.zig
//
// Must run AFTER optionalChain so obj?.prop ?? fallback is already lowered.
//
// The statements `p ??= v`, `p ||= v` and `p &&= v` lower here on every target but JS, which
// keeps them as written: the operands of the place `p` that are not simple are bound once,
// then `if (test(p)) { p = v; }`.

import { Node, NodeKind, BinaryExprData, ArrowFunctionData, TypeAssertionData, ConditionalExprData, ExprStmtData, MemberExprData, ArrayAccessData, HiddenDerefData, TypeKind, DeclKind, SourceLocation, Type, createNodeAt } from "../../ast/node";
import { isLogicalAssignOp } from "../../ast/operators";
import { isMaybeType, isCountedRef, unwrapMaybeType, peelTransparentInstance, isNumeric, isBoolType, isStringLike, unknownType } from "../../checker/types";
import { fitJoinedBranch, nullishPayloadType } from "../../checker/fit";
import { TransformContext, ModuleFact, freshOwnedSym, noteFact } from "../context";
import { walkNode, walkExpandBlocks, walkWithinStatement, walkOutsideInstanceFieldInits, isFuncBoundary } from "../walker";
import { forEachChild } from "../../ast/visitor";
import { makeNull, makeAbsent, isActorHandle, makeBinary, makeUnary, makeConditional, makeMember, makeVarDecl, makeLocalDecl, makeAssign, makeIdentResolved, makeTypedIdentResolved, makeExprStmt, makeIf, makeBlock, makeReturn } from "../util";
import { firstExprKindAfter, parseInput, makeCtx, getStmts } from "../testUtil";
import { cloneIfPure } from "./intArithJS";
import { cloneNodeKeepSem } from "../../monomorphize/clone";

// ===== Main Entry Point =====

export function lowerNullishCoalesce(program: Node, ctx: TransformContext): Node {
	blockifyArrowsReading(program, readsNullishOperandTwice);
	walkExpandBlocks(program, (stmt: Node, c: TransformContext): Node[] => lowerNullishStmt(stmt, c), ctx);
	return walkOutsideInstanceFieldInits(program, (node: Node): Node => lowerNullishNode(node, ctx, null));
}

function lowerNullishStmt(stmt: Node, ctx: TransformContext): Node[] {
	const out: Node[] = [];
	for (const piece of ctx.jsBackend ? [stmt] : lowerLogicalAssign(stmt, ctx)) {
		const temps: Node[] = [];
		const lowered = walkWithinStatement(piece, (node: Node): Node => lowerNullishNode(node, ctx, temps));
		for (const temp of temps) out.push(temp);
		out.push(lowered);
	}
	return out;
}

// ===== Logical assignment =====

function lowerLogicalAssign(stmt: Node, ctx: TransformContext): Node[] {
	if (stmt.kind != NodeKind.ExprStmt) return [stmt];
	const assign = (stmt.data as ExprStmtData).expr;
	if (assign == null || assign.kind != NodeKind.BinaryExpr) return [stmt];
	const d = assign.data as BinaryExprData;
	if (!isLogicalAssignOp(d.operator)) return [stmt];
	const loc = stmt.location;
	const out: Node[] = [];
	bindPlaceOperandsOnce(d.left, ctx, out, loc);
	if (d.operator == "??=" && neverNullish(d.left, ctx)) {
		out.push(makeExprStmt(d.left, loc));
		return out;
	}
	const test = match (d.operator) {
		"??=" => makeBinary(cloneNodeKeepSem(d.left), "===", makeAbsent(d.left.nodeType, loc), loc),
		"||=" => makeUnary("!", cloneNodeKeepSem(d.left), loc),
		_ => cloneNodeKeepSem(d.left),
	};
	const write = makeExprStmt(makeAssign(d.left, d.right, loc), loc);
	out.push(makeIf(test, makeBlock([write], loc), null, loc));
	return out;
}

// A place is read for the test and written after it, and its object and index run once, as
// when the reference binds them to temps: an object that is not a name and an index that is
// not a name or a literal. A value aggregate has no object of its own to bind, so a field or
// element of one stays a path that is re-read, which is what an lvalue is.
function bindPlaceOperandsOnce(place: Node, ctx: TransformContext, out: Node[], loc: SourceLocation): void {
	if (place.kind == NodeKind.MemberExpr) {
		const d = place.data as MemberExprData;
		d.object = placeOperand(d.object, ctx, out, loc);
	} else if (place.kind == NodeKind.ArrayAccess) {
		const d = place.data as ArrayAccessData;
		d.array = placeOperand(d.array, ctx, out, loc);
		if (!isSimpleOperand(d.index)) d.index = bindTemp(d.index, ctx, out, loc);
	} else if (place.kind == NodeKind.HiddenDeref) {
		const d = place.data as HiddenDerefData;
		d.expr = placeOperand(d.expr, ctx, out, loc);
	}
}

function placeOperand(operand: Node, ctx: TransformContext, out: Node[], loc: SourceLocation): Node {
	if (operand.kind == NodeKind.Identifier) return operand;
	const aggregate = (operand.kind == NodeKind.MemberExpr || operand.kind == NodeKind.ArrayAccess) && !isCountedRef(operand.nodeType);
	if (aggregate || operand.kind == NodeKind.HiddenDeref) {
		bindPlaceOperandsOnce(operand, ctx, out, loc);
		return operand;
	}
	return bindTemp(operand, ctx, out, loc);
}

function isSimpleOperand(n: Node): boolean {
	return n.kind == NodeKind.Identifier || n.kind == NodeKind.NumberLiteral || n.kind == NodeKind.StringLiteral;
}

function bindTemp(value: Node, ctx: TransformContext, out: Node[], loc: SourceLocation): Node {
	const sym = freshOwnedSym(ctx, "once", value.nodeType);
	out.push(makeLocalDecl(sym, value, value.nodeType!, loc));
	return makeTypedIdentResolved(sym, value.nodeType, loc);
}

function readsNullishOperandTwice(node: Node): boolean {
	if (node.kind != NodeKind.BinaryExpr) return false;
	const d = node.data as BinaryExprData;
	return d.operator == "??" && cloneIfPure(d.left) == null;
}

export function blockifyArrowsReading(program: Node, readsTwice: (node: Node) => boolean): void {
	walkNode(program, (node: Node): Node => {
		if (node.kind != NodeKind.ArrowFunction) return node;
		const d = node.data as ArrowFunctionData;
		const body = d.arrowBody;
		if (body != null && body.kind != NodeKind.BlockStmt && containsInRoutine(body, readsTwice)) {
			d.arrowBody = makeBlock([makeReturn(body, body.location)], body.location);
		}
		return node;
	});
}

function containsInRoutine(node: Node, test: (node: Node) => boolean): boolean {
	if (node == null || isFuncBoundary(node)) return false;
	if (test(node)) return true;
	let found = false;
	forEachChild(node, (child: Node): void => {
		if (!found && containsInRoutine(child, test)) found = true;
	});
	return found;
}

export function bindOnce(read: Node, ctx: TransformContext, temps: Node[], loc: SourceLocation): Node {
	const sym = freshOwnedSym(ctx, "once", read.nodeType);
	const decl = makeVarDecl(sym.name, makeAbsent(read.nodeType, loc), DeclKind.Let, loc);
	decl.resolvedSym = sym;
	decl.nodeType = sym.symbolType;
	temps.push(decl);
	const bound = makeAssign(makeIdentResolved(sym, loc), ctx.jsBackend ? asUnknown(read, loc) : read, loc);
	bound.nodeType = read.nodeType;
	return bound;
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

function neverNullish(left: Node, ctx: TransformContext): boolean {
	const leftType = left.nodeType != null ? peelTransparentInstance(left.nodeType) : null;
	return leftType != null && !isMaybeType(leftType) && !isActorHandle(leftType)
		&& (isNumeric(leftType) || isBoolType(leftType) || (!ctx.jsBackend && isStringLike(leftType)));
}

function nullishPresence(left: Node, loc: SourceLocation, ctx: TransformContext): Node {
	let checked = left;
	if (ctx.jsBackend) {
		checked = asUnknown(left, loc);
	}
	return makeBinary(checked, "!==", makeAbsent(left.nodeType, loc), loc);
}

export function nullishLowered(left: Node, right: Node, loc: SourceLocation, resultType: Type | null, ctx: TransformContext): Node {
	return lowerNullish(left, right, loc, resultType, ctx, null);
}

function lowerNullish(left: Node, right: Node, loc: SourceLocation, resultType: Type | null, ctx: TransformContext, temps: Node[] | null): Node {
	// A scalar or string left operand carries no null outside JS: TS keeps the
	// expression legal and its value is the left operand.
	const leftType = left.nodeType != null ? peelTransparentInstance(left.nodeType) : null;
	if (neverNullish(left, ctx)) return left;

	// x ?? y → x !== null ? x : y
	let cond = nullishPresence(left, loc, ctx);
	let held = left;
	if (temps != null && cloneIfPure(left) == null) {
		const bound = bindOnce(left, ctx, temps, loc);
		cond = ctx.jsBackend ? makeBinary(bound, "!==", makeNull(loc), loc) : nullishPresence(bound, loc, ctx);
		held = makeIdentResolved((bound.data as BinaryExprData).left.resolvedSym!, loc);
	} else {
		held = rereadOperand(left);
		if (held == left) noteFact(ctx, ModuleFact.OptionalChain);
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

function loweredArms(input: string): ConditionalExprData | null {
	const parsed = parseInput(input);
	if (!parsed.ok) return null;
	const stmts = getStmts(lowerNullishCoalesce(parsed.value, makeCtx()));
	if (stmts.length == 0 || stmts[0].kind != NodeKind.ExprStmt) return null;
	const expr = (stmts[0].data as ExprStmtData).expr;
	return expr.kind == NodeKind.ConditionalExpr ? expr.data as ConditionalExprData : null;
}

test "a pure left operand is read again through its own node" {
	for (const input of ["x ?? 1;", "q.o ?? 1;", "q.rows[i].o ?? 1;"]) {
		const arms = loweredArms(input);
		assert arms != null, input;
		if (arms != null) {
			const tested = (arms.ternaryCondition.data as BinaryExprData).left;
			assert arms.ternaryConsequent != tested && arms.ternaryConsequent.kind == tested.kind, input;
		}
	}
}

test "an impure operand's temp is declared inside the routine that reads it, on every backend" {
	for (const js of [true, false]) {
		for (const input of ["function f() { return g() ?? 1; }", "const h = () => g() ?? 1;"]) {
			const parsed = parseInput(input);
			assert parsed.ok, input;
			if (parsed.ok) {
				const ctx = makeCtx();
				ctx.jsBackend = js;
				assert getStmts(lowerNullishCoalesce(parsed.value, ctx)).length == 1, input;
			}
		}
	}
}

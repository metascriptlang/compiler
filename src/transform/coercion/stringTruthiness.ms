// Truthiness — a condition, a `!` operand and a short-circuit operand in a condition
// test what TS's ToBoolean tests, chosen by the operand's type: 0, NaN, "", false, 0n
// and null are falsy. A C double reads NaN as true, so C floats go through msNumberIsTruthy.

import { Node, NodeKind, IfStmtData, WhileStmtData, DoWhileStmtData, ForStmtData, ConditionalExprData, UnaryExprData, BinaryExprData, ExprStmtData, PropertyDeclData, TypeKind, Type } from "../../ast/node";
import { isStructType, isMaybeType, unwrapMaybeType, unwrapRefNullUnion, peelTransparentInstance, isNullableBigInt, booleanType, stringType, isNumeric, isStringLike, isBoolType, holdsFalsyValue } from "../../checker/types";
import { addError } from "../../checker/context";
import { TransformContext } from "../context";
import { walkNode, walkExpandBlocks, walkWithinStatement, walkOutsideInstanceFieldInits, isInstanceFieldInit } from "../walker";
import { makeBinary, makeMember, makeNumber, makeBool, makeNull, makeUnary, makeCall, makeConditional, runtimeRef, makeIdentResolved } from "../util";
import { bindOnce, blockifyArrowsReading } from "./nullishCoalesce";
import { cloneIfPure } from "../place";
import { isFloatKind } from "../numKinds";
import { cloneNodeKeepSem } from "../../monomorphize/clone";

import { firstStmtKindAfter, firstExprKindAfter, stmtCountAfter } from "../testUtil";

// ===== Main Entry Point =====

export function lowerStringTruthiness(program: Node, ctx: TransformContext): Node {
	if (ctx.jsBackend) return walkNode(program, (node: Node): Node => truthifyNode(node, ctx, null));
	blockifyArrowsReading(program, readsConditionTwice);
	walkExpandBlocks(program, (stmt: Node, c: TransformContext): Node[] => truthifyStmt(stmt, c), ctx);
	walkOutsideInstanceFieldInits(program, (node: Node): Node => truthifyNode(node, ctx, null));
	return walkNode(program, (node: Node): Node => isInstanceFieldInit(node) ? truthifyFieldInit(node, ctx) : node);
}

// A test in an instance field initializer that needs a temp waits for the constructor
// the initializer moves into: collect the initializers before the move, then lower
// the assignments they became.
function truthifyFieldInit(field: Node, ctx: TransformContext): Node {
	const d = field.data as PropertyDeclData;
	if (d.propInitializer != null) d.propInitializer = walkNode(d.propInitializer, (node: Node): Node => readsConditionTwice(node) ? node : truthifyNode(node, ctx, null));
	return field;
}

export function instanceFieldInitializers(program: Node): Node[] {
	const inits: Node[] = [];
	walkNode(program, (node: Node): Node => {
		if (isInstanceFieldInit(node) && (node.data as PropertyDeclData).propInitializer != null) inits.push((node.data as PropertyDeclData).propInitializer);
		return node;
	});
	return inits;
}

export function lowerMovedFieldInitTruthiness(program: Node, ctx: TransformContext, inits: Node[]): Node {
	if (inits.length == 0) return program;
	walkExpandBlocks(program, (stmt: Node, c: TransformContext): Node[] => assignsOneOf(stmt, inits) ? truthifyStmt(stmt, c) : [stmt], ctx);
	return program;
}

function assignsOneOf(stmt: Node, inits: Node[]): boolean {
	if (stmt.kind != NodeKind.ExprStmt) return false;
	const assign = (stmt.data as ExprStmtData).expr;
	return assign != null && assign.kind == NodeKind.BinaryExpr && (assign.data as BinaryExprData).operator == "="
		&& inits.includes((assign.data as BinaryExprData).right);
}

function truthifyStmt(stmt: Node, ctx: TransformContext): Node[] {
	const temps: Node[] = [];
	const lowered = walkWithinStatement(stmt, (node: Node): Node => truthifyNode(node, ctx, temps));
	temps.push(lowered);
	return temps;
}

function truthifyNode(node: Node, ctx: TransformContext, temps: Node[] | null): Node {
	return match (node.kind) {
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			d.condition = wrapTruthiness(d.condition, ctx, temps);
			return node;
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			d.whileCondition = wrapTruthiness(d.whileCondition, ctx, temps);
			return node;
		},
		NodeKind.DoWhileStmt => {
			const d = node.data as DoWhileStmtData;
			d.doCondition = wrapTruthiness(d.doCondition, ctx, temps);
			return node;
		},
		NodeKind.ForStmt => {
			const d = node.data as ForStmtData;
			if (d.forCondition != null) d.forCondition = wrapTruthiness(d.forCondition, ctx, temps);
			return node;
		},
		NodeKind.ConditionalExpr => {
			const d = node.data as ConditionalExprData;
			d.ternaryCondition = wrapTruthiness(d.ternaryCondition, ctx, temps);
			return node;
		},
		NodeKind.UnaryExpr => {
			const d = node.data as UnaryExprData;
			if (!ctx.jsBackend && d.unaryOp == "!" && negationNeedsTest(d.operand)) d.operand = wrapTruthiness(d.operand, ctx, temps);
			return node;
		},
		_ => node,
	};
}

function conditionType(cond: Node): Type | null {
	return cond.nodeType != null ? peelTransparentInstance(cond.nodeType) : null;
}

function isShortCircuit(cond: Node): boolean {
	if (cond.kind != NodeKind.BinaryExpr) return false;
	const op = (cond.data as BinaryExprData).operator;
	return op == "&&" || op == "||";
}

function negationNeedsTest(operand: Node): boolean {
	if (isShortCircuit(operand)) return true;
	const ct = conditionType(operand);
	return ct != null && (isMaybeType(ct) || isFloatingNumber(ct) || isStringLike(ct));
}

function isFloatingNumber(t: Type): boolean {
	return isFloatKind(t.kind);
}

function testsPayloadValue(payload: Type): boolean {
	return holdsFalsyValue(payload) && (isNumeric(payload) || isBoolType(payload) || isStringLike(payload));
}

function needsTemp(cond: Node): boolean {
	if (isShortCircuit(cond)) {
		const d = cond.data as BinaryExprData;
		return needsTemp(d.left) || needsTemp(d.right);
	}
	const ct = conditionType(cond);
	return ct != null && isMaybeType(ct) && testsPayloadValue(unwrapMaybeType(ct)) && cloneIfPure(cond) == null;
}

function readsConditionTwice(node: Node): boolean {
	if (node.kind == NodeKind.ConditionalExpr) return needsTemp((node.data as ConditionalExprData).ternaryCondition);
	if (node.kind != NodeKind.UnaryExpr) return false;
	const d = node.data as UnaryExprData;
	return d.unaryOp == "!" && needsTemp(d.operand);
}

// JS and the Raiser VM test ToBoolean natively; only C spells the test out.
export function truthinessTest(read: Node, ctx: TransformContext): Node {
	return ctx.jsBackend || ctx.raiserBackend ? read : wrapTruthiness(read, ctx, null);
}

function wrapTruthiness(cond: Node, ctx: TransformContext, temps: Node[] | null): Node {
	if (isShortCircuit(cond)) {
		const d = cond.data as BinaryExprData;
		d.left = wrapTruthiness(d.left, ctx, temps);
		d.right = wrapTruthiness(d.right, ctx, temps);
		cond.nodeType = booleanType();
		return cond;
	}
	const ct = conditionType(cond);
	// BooleanLiteral covers disc re-reads on narrowed bool-disc DU variants
	// (`ok: BooleanLiteral` injected by resolvePass) — same C repr as boolean.
	if (ct != null && (ct.kind == TypeKind.Boolean
		|| ct.kind == TypeKind.BooleanLiteral)) return cond;
	if (ct != null && isMaybeType(ct)) {
		return ctx.jsBackend ? cond : maybeTruthiness(cond, ct, ctx, temps);
	}
	// bigint → `!!b`. The inner `!` is what bigIntOpLower turns into msBigIntIsZero
	// on C; on js the double negation is already the native truthiness of 0n.
	if (ct != null && ct.kind == TypeKind.BigInt) {
		return makeUnary("!", makeUnary("!", cond, cond.location), cond.location);
	}
	if (isNullableBigInt(ct)) {
		return booleanCall("msBigIntIsTruthy", cond);
	}
	if (ct != null && isNumeric(ct)) {
		return ctx.jsBackend || !isFloatingNumber(ct) ? cond : booleanCall("msNumberIsTruthy", cond);
	}
	// Non-nullable value types → always true (Reference: rejects objects in boolean context)
	if (ct != null && isStructType(ct)) return makeBool(true, cond.location);
	// Arrays → len > 0
	if (ct != null && ct.kind == TypeKind.Array) {
		return makeBinary(makeMember(cond, "len", cond.location), ">", makeNumber(0, cond.location), cond.location);
	}
	// Ref values and nullable-pointer unions (Ref/Ptr/unknown | null — the Maybe
	// split leaves pointers unwrapped) → null-sentinel check; without this arm
	// both shapes fell into the string byteLength fallback below.
	if (ct != null && (ct.kind == TypeKind.Ref
			|| unwrapRefNullUnion(ct) != null)) {
		return makeBinary(cond, "!==", makeNull(cond.location), cond.location);
	}
	if (ct != null && isStringLike(ct) && !ctx.jsBackend) return nonEmpty(cond);
	if (isAlreadyBoolean(cond)) return cond;
	if ((ct == null || isStringLike(ct)) && (cond.kind == NodeKind.Identifier || cond.kind == NodeKind.MemberExpr)) {
		return nonEmpty(cond);
	}
	return cond;
}

function booleanCall(name: string, arg: Node): Node {
	const call = makeCall(runtimeRef(name, arg.location), [arg], arg.location);
	call.nodeType = booleanType();
	return call;
}

function nonEmpty(text: Node): Node {
	const loc = text.location;
	return makeBinary(makeMember(text, "byteLength", loc), ">", makeNumber(0, loc), loc);
}

function maybeTruthiness(cond: Node, carrier: Type, ctx: TransformContext, temps: Node[] | null): Node {
	const loc = cond.location;
	const payload = unwrapMaybeType(carrier);
	if (!testsPayloadValue(payload)) return presence(cond);
	if (cloneIfPure(cond) != null) return makeBinary(presence(cond), "&&", payloadTest(cloneNodeKeepSem(cond), payload), loc);
	if (temps != null) {
		const bound = bindOnce(cond, ctx, temps, loc);
		const held = makeIdentResolved((bound.data as BinaryExprData).left.resolvedSym!, loc);
		const test = makeConditional(makeBinary(bound, "!==", makeNull(loc), loc), payloadTest(held, payload), makeBool(false, loc), loc);
		test.nodeType = booleanType();
		return test;
	}
	if (ctx.checkerCtx != null) {
		addError(ctx.checkerCtx, "a test of a value that may be null reads it twice and nothing here can hold it; bind it to a const first", loc.line, loc.column);
	}
	return presence(cond);
}

function presence(carrier: Node): Node {
	const present = makeMember(carrier, "present", carrier.location);
	present.nodeType = booleanType();
	return present;
}

function payloadTest(carrier: Node, payload: Type): Node {
	const value = makeMember(carrier, "value", carrier.location);
	value.nodeType = isStringLike(payload) ? stringType() : payload;
	return isStringLike(payload) ? nonEmpty(value)
		: isFloatingNumber(payload) ? booleanCall("msNumberIsTruthy", value)
		: value;
}

// Check if an expression already produces a boolean (no wrapping needed)
function isAlreadyBoolean(node: Node): boolean {
	return match (node.kind) {
		NodeKind.BooleanLiteral | NodeKind.NumberLiteral | NodeKind.NullLiteral => true,
		NodeKind.CallExpr | NodeKind.BinaryExpr | NodeKind.UnaryExpr => true,
		NodeKind.ArrayAccess | NodeKind.ConditionalExpr => true,
		_ => false,
	};
}

// ===== Tests =====
test "if with comparison unchanged" { assert firstStmtKindAfter("if (x > 0) {}", lowerStringTruthiness) == NodeKind.IfStmt; }

test "while bool unchanged" { assert firstStmtKindAfter("while (true) {}", lowerStringTruthiness) == NodeKind.WhileStmt; }

test "call condition unchanged" { assert firstStmtKindAfter("if (f()) {}", lowerStringTruthiness) == NodeKind.IfStmt; }

test "binary expr unchanged" { assert firstExprKindAfter("x + y;", lowerStringTruthiness) == NodeKind.BinaryExpr; }

test "non-condition passthrough" { assert stmtCountAfter("const x = 1;", lowerStringTruthiness) == 1; }

test "already boolean passthrough" { assert firstStmtKindAfter("if (x === y) {}", lowerStringTruthiness) == NodeKind.IfStmt; }

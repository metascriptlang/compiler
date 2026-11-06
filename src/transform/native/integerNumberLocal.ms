// A const `number` initialized from a signed integer masked to 53 bits holds that integer exactly, so a cast of
// it back to an integer reads the integer from a const declared beside it instead of round-tripping a double:
//
//   const k = (i & 9007199254740991) as number;  ...xs[k]...
//   → const $int = i & 9007199254740991; const k = $int as number;  ...xs[$int]...
//
// The array iterator's keys() and entries() yield their index this way. The value and every check stay the same:
// a cast to a narrower integer still checks its range, now on the integer.

import { Node, NodeKind, DeclKind, Symbol, Type, TypeKind, ProgramData, BlockStmtData, VariableDeclData, BinaryExprData, TypeAssertionData, HiddenStdConvData, NumberLiteralData } from "../../ast/node";
import { isRoutineNode, peelStdConv } from "../../ast/shape";
import { peelToRepr, getSysType } from "../../checker/types";
import { forEachChild } from "../../ast/visitor";
import { TransformContext, freshTempSym } from "../context";
import { makeVarDecl, makeIdentResolved } from "../util";
import { isFloatKind, isSignedKind } from "../numKinds";

const EXACT_MASK: int64 = 9007199254740991;

export function keepIntegerNumberLocals(program: Node, ctx: TransformContext): Node {
	if (ctx.jsBackend || ctx.raiserBackend) return program;
	visit(program, ctx);
	return program;
}

function visit(n: Node, ctx: TransformContext): void {
	forEachChild(n, (c: Node): void => visit(c, ctx));
	if (n.kind == NodeKind.Program) (n.data as ProgramData).programStmts = rewriteList((n.data as ProgramData).programStmts, ctx);
	else if (n.kind == NodeKind.BlockStmt) (n.data as BlockStmtData).statements = rewriteList((n.data as BlockStmtData).statements, ctx);
}

function rewriteList(stmts: Node[], ctx: TransformContext): Node[] {
	const out: Node[] = [];
	for (let k: int32 = 0; k < stmts.length; k++) {
		const s = stmts[k];
		const masked = maskedSource(s);
		if (masked == null) {
			out.push(s);
			continue;
		}
		const i64 = getSysType(TypeKind.Int64);
		const intSym = freshTempSym(ctx, "int", i64);
		let reads = 0;
		for (let j = k + 1; j < stmts.length; j++) reads += redirectCasts(stmts[j], s.resolvedSym!, intSym);
		if (reads == 0) {
			out.push(s);
			continue;
		}
		const decl = makeVarDecl(intSym.name, masked, DeclKind.Const, s.location);
		decl.resolvedSym = intSym;
		decl.nodeType = i64;
		out.push(decl);
		setCastOperand((s.data as VariableDeclData).initializer!, makeIdentResolved(intSym, s.location));
		out.push(s);
	}
	return out;
}

// The integer behind `const k: number = (e & M) as number` when 0 <= M < 2^53, else null.
function maskedSource(s: Node): Node | null {
	if (s.kind != NodeKind.VariableDecl || s.resolvedSym == null) return null;
	const d = s.data as VariableDeclData;
	if (d.declKind != DeclKind.Const || d.initializer == null || !isFloat(s.resolvedSym.symbolType)) return null;
	const e = castOperand(d.initializer);
	if (e == null || e.kind != NodeKind.BinaryExpr || !isSignedInt(e.nodeType)) return null;
	const b = e.data as BinaryExprData;
	return b.operator == "&" && (exactMask(b.left) || exactMask(b.right)) ? e : null;
}

function exactMask(n: Node): boolean {
	const lit = peelStdConv(n);
	if (lit.kind != NodeKind.NumberLiteral) return false;
	const d = lit.data as NumberLiteralData;
	return !d.isFloat && d.intVal >= 0 && d.intVal <= EXACT_MASK;
}

function castOperand(n: Node): Node | null {
	if (n.kind == NodeKind.TypeAssertion) return (n.data as TypeAssertionData).asExpr;
	if (n.kind == NodeKind.HiddenStdConv) return (n.data as HiddenStdConvData).convExpr;
	return null;
}

function castTarget(n: Node): Type | null {
	return n.kind == NodeKind.HiddenStdConv ? (n.data as HiddenStdConvData).convType : n.nodeType;
}

function setCastOperand(n: Node, operand: Node): void {
	if (n.kind == NodeKind.TypeAssertion) (n.data as TypeAssertionData).asExpr = operand;
	else (n.data as HiddenStdConvData).convExpr = operand;
}

// Point every integer cast of `sym` inside `n` at `intSym`; the count of casts redirected.
function redirectCasts(n: Node, sym: Symbol, intSym: Symbol): int32 {
	if (isRoutineNode(n)) return 0;
	let count: int32 = 0;
	const operand = castOperand(n);
	if (operand != null && operand.kind == NodeKind.Identifier && operand.resolvedSym == sym && isInt(castTarget(n))) {
		setCastOperand(n, makeIdentResolved(intSym, operand.location));
		count += 1;
	}
	forEachChild(n, (c: Node): void => { count += redirectCasts(c, sym, intSym); });
	return count;
}

function isFloat(t: Type | null): boolean {
	const r = peelToRepr(t);
	return r != null && isFloatKind(r.kind);
}

function isSignedInt(t: Type | null): boolean {
	const r = peelToRepr(t);
	return r != null && isSignedKind(r.kind);
}

function isInt(t: Type | null): boolean {
	const r = peelToRepr(t);
	return r != null && (isSignedKind(r.kind) || r.kind == TypeKind.Uint8 || r.kind == TypeKind.Uint16 || r.kind == TypeKind.Uint32 || r.kind == TypeKind.Uint64);
}

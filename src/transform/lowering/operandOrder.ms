// Operand order — an expression kind that must become statements (an `await`, a `try`) is
// hoisted ahead of its statement, so every operand written to its left is evaluated into a
// temp first, in order: the call operands before it into temps in order. A `Spiller` names the
// kind: `has` finds it in an operand and `lower` hoists it into `pre`.

import {
	Node, NodeKind, DeclKind, SourceLocation, Symbol, SymbolKind, SymbolFlag, Type, TypeKind,
	CallExprData, BinaryExprData, UnaryExprData, MemberExprData, ArrayAccessData,
	ArrayLiteralData, ObjectLiteralData, NewExprData, TypeAssertionData, HiddenStdConvData, HiddenDerefData,
} from "../../ast/node";
import { makeSymbol } from "../../checker/symbol";
import { isStructType } from "../../checker/types";
import { TransformContext } from "../context";
import { makeVarDecl, makeTypedIdentResolved, makeBinary, isValueLayoutType } from "../util";
import { cloneIfPure } from "../coercion/intArithJS";

export type Spiller = { ctx: TransformContext, has: (n: Node) => boolean, lower: (n: Node, pre: Node[]) => Node };

export function isVoidType(t: Type | null): boolean {
	return t != null && t.kind == TypeKind.Void;
}

export function isAssignOp(op: string): boolean {
	if (op == "==" || op == "!=" || op == "===" || op == "!==" || op == "<=" || op == ">=") return false;
	return op.endsWith("=");
}

function isCallKind(e: Node): boolean {
	if (e.kind == NodeKind.CallExpr || e.kind == NodeKind.NewExpr
		|| e.kind == NodeKind.UnaryExpr || e.kind == NodeKind.UpdateExpr) return true;
	return e.kind == NodeKind.BinaryExpr && !isAssignOp((e.data as BinaryExprData).operator);
}

export function bindTemp(sp: Spiller, init: Node, declKind: DeclKind, t: Type | null, pre: Node[], loc: SourceLocation): Symbol {
	const name = "__ord_" + sp.ctx.tempCounter.toString();
	sp.ctx.tempCounter += 1;
	const sym = makeSymbol(name, SymbolKind.Variable, t, declKind != DeclKind.Const);
	const decl = makeVarDecl(name, init, declKind, loc);
	decl.nodeType = t;
	decl.resolvedSym = sym;
	pre.push(decl);
	return sym;
}

export function tempRef(sym: Symbol, loc: SourceLocation): Node {
	return makeTypedIdentResolved(sym, sym.symbolType, loc);
}

// A value aggregate stays in place: a temp copy would take the writes a call
// or a store makes through it. JS reads before an await: NIM-REF TR-24.
function snapshotsLikeJs(t: Type | null): boolean {
	if (t == null) return false;
	const k = t.kind;
	if (k == TypeKind.Void || k == TypeKind.Array || k == TypeKind.SizedArray || k == TypeKind.Span
		|| k == TypeKind.Tuple || k == TypeKind.Var || k == TypeKind.Lent || k == TypeKind.Sink
		|| k == TypeKind.Borrow || k == TypeKind.Ptr || k == TypeKind.Varargs || k == TypeKind.CString
		|| k == TypeKind.Null || k == TypeKind.Unknown || k == TypeKind.None || k == TypeKind.Pending) return false;
	return !isStructType(t) && !isValueLayoutType(t);
}

function isStorageRead(e: Node): boolean {
	if (e.kind == NodeKind.Identifier) {
		const s = e.resolvedSym;
		if (s == null || !s.symFlags.has(SymbolFlag.Mutable)) return false;
		return s.symbolKind == SymbolKind.Variable || s.symbolKind == SymbolKind.Parameter;
	}
	if (e.kind == NodeKind.MemberExpr) {
		const s = e.resolvedSym;
		return s == null || s.symbolKind == SymbolKind.Variable || s.symbolKind == SymbolKind.Property;
	}
	return e.kind == NodeKind.ArrayAccess;
}

function readsBeforeHoist(e: Node): boolean {
	if (e.kind == NodeKind.TypeAssertion) return readsBeforeHoist((e.data as TypeAssertionData).asExpr);
	if (e.kind == NodeKind.HiddenStdConv || e.kind == NodeKind.HiddenSubConv) return readsBeforeHoist((e.data as HiddenStdConvData).convExpr);
	return (isStorageRead(e) || e.kind == NodeKind.ConditionalExpr) && snapshotsLikeJs(e.nodeType);
}

function bindIfEarly(sp: Spiller, e: Node, pre: Node[]): Node {
	if (!readsBeforeHoist(e) && !(isCallKind(e) && !isVoidType(e.nodeType))) return e;
	return tempRef(bindTemp(sp, e, DeclKind.Const, e.nodeType, pre, e.location), e.location);
}

function bindOperand(sp: Spiller, e: Node, snapshot: boolean, pre: Node[]): Node {
	if ((snapshot && readsBeforeHoist(e)) || (isCallKind(e) && !isVoidType(e.nodeType))) {
		return tempRef(bindTemp(sp, e, DeclKind.Const, e.nodeType, pre, e.location), e.location);
	}
	return e;
}

function lowerOperands(sp: Spiller, ops: Node[], pre: Node[], receivers: int32): void {
	let last = -1;
	for (let i = 0; i < ops.length; i += 1) {
		if (sp.has(ops[i])) last = i;
	}
	if (last < 0) return;
	for (let i = 0; i < ops.length; i += 1) {
		if (ops[i] == null) continue;
		ops[i] = bindOperand(sp, sp.lower(ops[i], pre), i < last && i >= receivers, pre);
	}
}

// The kinds whose operands evaluate left to right; false for any other kind.
export function lowerOperandList(sp: Spiller, e: Node, pre: Node[]): boolean {
	const k = e.kind;
	if (k == NodeKind.BinaryExpr) {
		const d = e.data as BinaryExprData;
		const ops = [d.left, d.right];
		lowerOperands(sp, ops, pre, 0);
		d.left = ops[0];
		d.right = ops[1];
	} else if (k == NodeKind.CallExpr) {
		const d = e.data as CallExprData;
		const viaMember = d.callee.kind == NodeKind.MemberExpr;
		const ops: Node[] = [viaMember ? (d.callee.data as MemberExprData).object : d.callee];
		for (const a of d.arguments) ops.push(a);
		lowerOperands(sp, ops, pre, 1);
		if (viaMember) (d.callee.data as MemberExprData).object = ops[0];
		else d.callee = ops[0];
		for (let i = 0; i < d.arguments.length; i += 1) d.arguments[i] = ops[i + 1];
	} else if (k == NodeKind.NewExpr) {
		lowerOperands(sp, (e.data as NewExprData).newArguments, pre, 0);
	} else if (k == NodeKind.ArrayAccess) {
		const d = e.data as ArrayAccessData;
		const ops = [d.array, d.index];
		lowerOperands(sp, ops, pre, 0);
		d.array = ops[0];
		d.index = ops[1];
	} else if (k == NodeKind.ArrayLiteral) {
		lowerOperands(sp, (e.data as ArrayLiteralData).elements, pre, 0);
	} else if (k == NodeKind.ObjectLiteral) {
		lowerOperands(sp, (e.data as ObjectLiteralData).properties, pre, 0);
	} else {
		return false;
	}
	return true;
}

function settleTarget(sp: Spiller, e: Node, pre: Node[]): Node {
	if (e.kind == NodeKind.ArrayAccess) {
		const d = e.data as ArrayAccessData;
		d.array = settleTarget(sp, d.array, pre);
		d.index = bindIfEarly(sp, sp.lower(d.index, pre), pre);
	} else if (e.kind == NodeKind.MemberExpr) {
		const d = e.data as MemberExprData;
		d.object = settleObject(sp, sp.lower(d.object, pre), pre);
	}
	return e;
}

function settleObject(sp: Spiller, obj: Node, pre: Node[]): Node {
	if (obj.kind == NodeKind.HiddenDeref) {
		const hd = obj.data as HiddenDerefData;
		hd.expr = settleObject(sp, hd.expr, pre);
		return obj;
	}
	const bound = bindIfEarly(sp, obj, pre);
	return bound == obj ? settleTarget(sp, obj, pre) : bound;
}

// An assignment target evaluates before its value: what the target reads is settled first.
export function lowerAssign(sp: Spiller, e: Node, pre: Node[]): Node {
	const d = e.data as BinaryExprData;
	if (!sp.has(d.right)) {
		d.left = sp.lower(d.left, pre);
		return e;
	}
	d.left = settleTarget(sp, d.left, pre);
	const readBack = d.operator == "=" ? null : cloneIfPure(d.left);
	if (readBack == null) {
		d.right = bindIfEarly(sp, sp.lower(d.right, pre), pre);
		return e;
	}
	const before = tempRef(bindTemp(sp, readBack, DeclKind.Const, d.left.nodeType, pre, e.location), e.location);
	const value = sp.lower(d.right, pre);
	d.right = makeBinary(before, d.operator.slice(0, d.operator.length - 1), value, e.location);
	d.operator = "=";
	return e;
}

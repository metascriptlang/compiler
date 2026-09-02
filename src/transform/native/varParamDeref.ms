// Var (out/ref) param uses are locations behind a pointer. Materialize the
// deref in the AST (HiddenDeref) before the analyzer so lifecycle hooks see
// a location, not a raw pointer-typed identifier (Reference: tyVar use deref).
// Args bound to a Var formal get the implicit ADDR instead (Reference
// takeImplicitAddr): HiddenAddr around the lvalue, except forwarding — an
// arg that already denotes a Var param (user: resolvedSym; synthesized hook
// bodies: nodeType stamp from destructorLifting) passes its pointer raw.

import { Node, NodeKind, Type, TypeKind, CallExprData, OutExprData } from "../../ast/node";
import { TransformContext } from "../context";
import { mapChildren } from "../walker";
import { makeHiddenDeref, makeHiddenAddr } from "../util";

function isVarType(t: Type): boolean {
	return t !== null && t.kind === TypeKind.Var;
}

function calleeFormals(d: CallExprData): Type[] {
	let t = d.callee.nodeType;
	if ((t === null || t.kind !== TypeKind.Function) && d.callee.resolvedSym !== null) {
		t = d.callee.resolvedSym.symbolType;
	}
	if (t === null || t.kind !== TypeKind.Function) return null as unknown as Type[];
	return t.typeChildren;
}

function wrapVarUse(node: Node): Node {
	const s = node.resolvedSym;
	if (s === null || !isVarType(s.symbolType)) return node;
	const hd = makeHiddenDeref(node, node.location);
	// ONE peel off the SYMBOL's Var type — the ident's own nodeType may already
	// be peeled by the checker's read path, and `(*ident)` is exactly one
	// deref of the T* the ident denotes.
	if (s.symbolType.typeReturn !== null) {
		hd.nodeType = s.symbolType.typeReturn;
	}
	return hd;
}

function isForwardingVarIdent(n: Node): boolean {
	if (n === null || n.kind !== NodeKind.Identifier) return false;
	if (n.resolvedSym !== null) return isVarType(n.resolvedSym.symbolType);
	// Unannotated synthetic idents (destructorLifting forwarding args) pass raw;
	// checker-typed user idents always carry nodeType, so null means synthetic.
	if (n.nodeType === null) return true;
	return isVarType(n.nodeType);
}

function takeImplicitAddr(arg: Node): Node {
	if (arg.kind === NodeKind.Identifier) {
		if (isForwardingVarIdent(arg)) return arg;
		return makeHiddenAddr(arg, arg.location);
	}
	if (arg.kind === NodeKind.OutExpr) {
		const d = arg.data as OutExprData;
		if (d.outArg === null) return arg;
		if (isForwardingVarIdent(d.outArg)) return d.outArg;
		return makeHiddenAddr(visit(d.outArg), arg.location);
	}
	if (arg.kind === NodeKind.HiddenAddr) return arg;
	return makeHiddenAddr(visit(arg), arg.location);
}

function visit(node: Node): Node {
	if (node === null) return node;
	if (node.kind === NodeKind.Identifier) return wrapVarUse(node);
	if (node.kind === NodeKind.HiddenDeref || node.kind === NodeKind.HiddenAddr) return node;
	if (node.kind === NodeKind.OutExpr) {
		const d = node.data as OutExprData;
		if (d.outArg !== null && d.outArg.kind !== NodeKind.Identifier) d.outArg = visit(d.outArg);
		return node;
	}
	if (node.kind === NodeKind.CallExpr) {
		const d = node.data as CallExprData;
		d.callee = visit(d.callee);
		const formals = calleeFormals(d);
		let i = 0;
		while (i < d.arguments.length) {
			const a = d.arguments[i];
			const varFormal = formals !== null && i < formals.length && isVarType(formals[i]);
			if (a !== null) {
				d.arguments[i] = varFormal ? takeImplicitAddr(a) : visit(a);
			}
			i += 1;
		}
		return node;
	}
	mapChildren(node, visit);
	return node;
}

export function insertVarParamDerefs(program: Node, ctx: TransformContext): Node {
	mapChildren(program, visit);
	return program;
}

// Var (out/ref) param uses are locations behind a pointer. Materialize the
// deref in the AST (HiddenDeref) before the analyzer so lifecycle hooks see
// a location, not a raw pointer-typed identifier (Reference: tyVar use deref).
// Raw identifiers stay raw in addr contexts: OutExpr operands and args bound
// to a Var formal (forwarding) — codegen passes those as pointers already.

import { Node, NodeKind, Type, TypeKind, CallExprData, OutExprData } from "../../ast/node";
import { TransformContext } from "../context";
import { mapChildren } from "../walker";
import { makeHiddenDeref } from "../util";

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
	if (hd.nodeType !== null && hd.nodeType.kind === TypeKind.Var && hd.nodeType.typeReturn !== null) {
		hd.nodeType = hd.nodeType.typeReturn;
	}
	return hd;
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
			if (a !== null && (!varFormal || a.kind !== NodeKind.Identifier)) {
				d.arguments[i] = visit(a);
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

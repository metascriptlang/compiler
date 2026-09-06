import {
	Node, NodeKind, Type, TypeKind, Symbol, SymbolKind,
	CallExprData, MemberExprData, ArrayAccessData,
	OutExprData, HiddenDerefData, VariableDeclData, FunctionDeclData, BlockStmtData,
	createNodeAt,
} from "../../ast/node";
import { TransformContext } from "../context";
import { mapChildren } from "../walker";
import { makeIdentResolved, makeNumber, makeString, makeArrayAccess, makeAssign, makeExprStmt } from "../util";

let boxedSyms: Symbol[] = [];
let fnStack: Node[] = [];
let prologueFns: Node[] = [];
let prologueSyms: Symbol[][] = [];

function isBoxed(s: Symbol): boolean {
	for (const b of boxedSyms) { if (b == s) return true; }
	return false;
}

function isVarType(t: Type | null): boolean {
	return t != null && t.kind == TypeKind.Var;
}

function calleeFormals(d: CallExprData): Type[] | null {
	let t = d.callee.nodeType;
	if ((t == null || t.kind != TypeKind.Function)
		&& d.callee.resolvedSym != null) {
		t = d.callee.resolvedSym.symbolType;
	}
	if (t == null) return null;
	if (t.kind != TypeKind.Function) return null;
	return t.typeChildren;
}

function unwrapAddr(n: Node): Node {
	if (n == null) return n;
	if (n.kind == NodeKind.OutExpr) return unwrapAddr((n.data as OutExprData).outArg);
	if (n.kind == NodeKind.HiddenAddr) return unwrapAddr((n.data as HiddenDerefData).expr);
	return n;
}

function recordParamPrologue(s: Symbol): void {
	for (let i = fnStack.length - 1; i >= 0; i -= 1) {
		const fd = fnStack[i].data as FunctionDeclData;
		let found = false;
		for (const pn of fd.params) { if (pn == s.name) { found = true; break; } }
		if (!found) continue;
		for (let j = 0; j < prologueFns.length; j += 1) {
			if (prologueFns[j] == fnStack[i]) {
				for (const ps of prologueSyms[j]) { if (ps == s) return; }
				prologueSyms[j].push(s);
				return;
			}
		}
		prologueFns.push(fnStack[i]);
		prologueSyms.push([s]);
		return;
	}
}

function sc(node: Node): Node {
	if (node == null) return node;
	if (node.kind == NodeKind.FunctionDecl) {
		fnStack.push(node);
		mapChildren(node, sc);
		fnStack.pop();
		return node;
	}
	if (node.kind == NodeKind.CallExpr) {
		const d = node.data as CallExprData;
		const formals = calleeFormals(d);
		if (formals != null) {
			for (let i = 0; i < d.arguments.length && i < formals.length; i += 1) {
				if (!isVarType(formals[i])) continue;
				const inner = unwrapAddr(d.arguments[i]);
				if (inner.kind == NodeKind.Identifier && inner.resolvedSym != null) {
					const s = inner.resolvedSym;
					if (!isVarType(s.symbolType)) {
						if (!isBoxed(s)) boxedSyms.push(s);
						if (s.symbolKind == SymbolKind.Parameter) recordParamPrologue(s);
					}
				}
			}
		}
	}
	mapChildren(node, sc);
	return node;
}

function pairLit(a: Node, b: Node, at: Node): Node {
	return createNodeAt(NodeKind.ArrayLiteral, { elements: [a, b] }, at.location);
}

function cellLit(init: Node, at: Node): Node {
	return createNodeAt(NodeKind.ArrayLiteral, { elements: [init] }, at.location);
}

function derefPair(s: Symbol, at: Node): Node {
	const ci = makeIdentResolved(s, at.location);
	ci.nodeType = null;
	const ki = makeIdentResolved(s, at.location);
	ki.nodeType = null;
	const c = makeArrayAccess(ci, makeNumber(0, at.location), at.location);
	const k = makeArrayAccess(ki, makeNumber(1, at.location), at.location);
	const acc = makeArrayAccess(c, k, at.location);
	if (s.symbolType != null && s.symbolType.typeReturn != null) acc.nodeType = s.symbolType.typeReturn;
	else acc.nodeType = at.nodeType;
	return acc;
}

function pairize(arg: Node): Node {
	if (arg == null) return arg;
	const inner = unwrapAddr(arg);
	if (inner.kind == NodeKind.Identifier) {
		const s = inner.resolvedSym;
		if (s == null) return arg;
		if (isVarType(s.symbolType)) return inner;
		if (isBoxed(s)) {
			const cont = makeIdentResolved(s, inner.location);
			cont.nodeType = null;
			return pairLit(cont, makeNumber(0, inner.location), inner);
		}
		return arg;
	}
	if (inner.kind == NodeKind.MemberExpr) {
		const md = inner.data as MemberExprData;
		const cont = rw(unwrapAddr(md.object));
		cont.nodeType = null;
		return pairLit(cont, makeString(md.property, inner.location), inner);
	}
	if (inner.kind == NodeKind.ArrayAccess) {
		const ad = inner.data as ArrayAccessData;
		const cont = rw(unwrapAddr(ad.array));
		cont.nodeType = null;
		return pairLit(cont, rw(ad.index), inner);
	}
	return arg;
}

function rw(node: Node): Node {
	if (node == null) return node;
	if (node.kind == NodeKind.CallExpr) {
		const d = node.data as CallExprData;
		const formals = calleeFormals(d);
		d.callee = rw(d.callee);
		for (let i = 0; i < d.arguments.length; i += 1) {
			let formal: Type | null = null;
			if (formals != null && i < formals.length) formal = formals[i];
			if (isVarType(formal)) d.arguments[i] = pairize(d.arguments[i]);
			else d.arguments[i] = rw(d.arguments[i]);
		}
		return node;
	}
	if (node.kind == NodeKind.Identifier) {
		const s = node.resolvedSym;
		if (s != null && isVarType(s.symbolType) && s.symbolKind == SymbolKind.Parameter) {
			return derefPair(s, node);
		}
		if (s != null && isBoxed(s)) {
			const cont = makeIdentResolved(s, node.location);
			cont.nodeType = null;
			const cell = makeArrayAccess(cont, makeNumber(0, node.location), node.location);
			cell.nodeType = node.nodeType;
			return cell;
		}
		return node;
	}
	if (node.kind == NodeKind.VariableDecl) {
		mapChildren(node, rw);
		const s = node.resolvedSym;
		const d = node.data as VariableDeclData;
		if (s != null && isBoxed(s) && d.initializer != null) {
			d.initializer = cellLit(d.initializer, node);
		}
		return node;
	}
	mapChildren(node, rw);
	return node;
}

export function lowerJsVarParam(program: Node, ctx: TransformContext): Node {
	boxedSyms = [];
	fnStack = [];
	prologueFns = [];
	prologueSyms = [];
	sc(program);
	rw(program);
	for (let i = 0; i < prologueFns.length; i += 1) {
		const fd = prologueFns[i].data as FunctionDeclData;
		if (fd.fnBody == null) continue;
		const bs = fd.fnBody.data as BlockStmtData;
		const at = prologueFns[i];
		const pro: Node[] = [];
		for (const s of prologueSyms[i]) {
			pro.push(makeExprStmt(makeAssign(makeIdentResolved(s, at.location), cellLit(makeIdentResolved(s, at.location), at), at.location), at.location));
		}
		for (const st of bs.statements) { pro.push(st); }
		bs.statements = pro;
	}
	return program;
}

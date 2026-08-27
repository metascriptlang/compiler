// Param Reassign Lowering (C backend) — the DRC analyzer models params as
// borrowed slots that are never destroyed, so assigning an owned value into a
// param leaks it. Redirect assigned params through an owned shadow local; the
// analyzer's existing local sink/destroy handling then applies unchanged.
//
// function f(s: string): int32 {
//     s = s + "x";
//     return s.length;
// }
// →
// function f(s: string): int32 {
//     let $prs_0 = s;
//     $prs_0 = $prs_0 + "x";
//     return $prs_0.length;
// }

import {
	Node, NodeKind, DeclKind, Symbol, SymbolKind,
	FunctionDeclData, MethodDeclData, ConstructorDeclData,
	ArrowFunctionData, FunctionExprData,
	BinaryExprData, UpdateExprData, IdentifierData,
} from "../../ast/node";
import { TransformContext, freshOwnedSym } from "../context";
import { walkNode, mapChildren } from "../walker";
import { makeBlock, makeVarDecl, makeIdentResolved } from "../util";
import { firstStmtKindAfter, stmtCountAfter } from "../testUtil";

// ===== Main Entry Point =====

export function lowerParamReassign(program: Node, ctx: TransformContext): Node {
	walkNode(program, (node: Node): Node => {
		if (node.kind === NodeKind.FunctionDecl) {
			const d = node.data as FunctionDeclData;
			d.fnBody = processBody(d.params, d.fnBody, ctx);
		} else if (node.kind === NodeKind.MethodDecl) {
			const d = node.data as MethodDeclData;
			d.methodBody = processBody(d.methodParams, d.methodBody, ctx);
		} else if (node.kind === NodeKind.ConstructorDecl) {
			const d = node.data as ConstructorDeclData;
			d.ctorBody = processBody(d.ctorParams, d.ctorBody, ctx);
		} else if (node.kind === NodeKind.ArrowFunction) {
			const d = node.data as ArrowFunctionData;
			if (d.arrowBody !== null && d.arrowBody.kind === NodeKind.BlockStmt) {
				d.arrowBody = processBody(d.arrowParams, d.arrowBody, ctx);
			}
		} else if (node.kind === NodeKind.FunctionExpr) {
			const d = node.data as FunctionExprData;
			if (d.funcExprBody !== null && d.funcExprBody.kind === NodeKind.BlockStmt) {
				d.funcExprBody = processBody(d.funcExprParams, d.funcExprBody, ctx);
			}
		}
		return node;
	});
	return program;
}

function processBody(params: string[], body: Node, ctx: TransformContext): Node {
	if (body === null || params.length === 0) return body;
	const assigned: Symbol[] = [];
	collectAssigned(body, params, assigned);
	if (assigned.length === 0) return body;

	const loc = body.location;
	const stmts: Node[] = [];
	for (const ps of assigned) {
		const ls = freshOwnedSym(ctx, "prs", ps.symbolType);
		const decl = makeVarDecl(ls.name, makeIdentResolved(ps, loc), DeclKind.Let, loc);
		decl.resolvedSym = ls;
		stmts.push(decl);
		rewriteRefs(body, ps, ls);
	}
	stmts.push(body);
	return makeBlock(stmts, loc);
}

// Collect Parameter symbols that are assignment/update targets. Runs after
// nested functions were already processed (bottom-up walk), so any Parameter
// target found here belongs to an enclosing scope; the own-name check keeps
// only this function's params. Expression-bodied arrows are not descended
// into — their own params can't be distinguished from ours there.
function collectAssigned(n: Node, params: string[], out: Symbol[]): void {
	if (n === null) return;
	if (n.kind === NodeKind.ArrowFunction) {
		const ad = n.data as ArrowFunctionData;
		if (ad.arrowBody === null || ad.arrowBody.kind !== NodeKind.BlockStmt) return;
	}
	if (n.kind === NodeKind.BinaryExpr) {
		const bd = n.data as BinaryExprData;
		if (isAssignOp(bd.operator)) {
			recordTarget(bd.left, params, out);
		}
	} else if (n.kind === NodeKind.UpdateExpr) {
		const ud = n.data as UpdateExprData;
		recordTarget(ud.updateArg, params, out);
	}
	mapChildren(n, (c: Node): Node => {
		collectAssigned(c, params, out);
		return c;
	});
}

function recordTarget(target: Node, params: string[], out: Symbol[]): void {
	if (target === null || target.kind !== NodeKind.Identifier) return;
	if (target.resolvedSym === null) return;
	if (target.resolvedSym.symbolKind !== SymbolKind.Parameter) return;
	const id = target.data as IdentifierData;
	let inParams = false;
	for (const p of params) {
		if (p === id.name) {
			inParams = true;
		}
	}
	if (!inParams) return;
	for (const s of out) {
		if (s === target.resolvedSym) return;
	}
	out.push(target.resolvedSym);
}

function isAssignOp(op: string): boolean {
	if (op === "=") return true;
	if (op === "+=" || op === "-=" || op === "*=" || op === "/=" || op === "%=") return true;
	if (op === "**=" || op === "&=" || op === "|=" || op === "^=") return true;
	if (op === "<<=" || op === ">>=" || op === ">>>=") return true;
	if (op === "&&=" || op === "||=" || op === "??=") return true;
	return false;
}

function rewriteRefs(body: Node, fromSym: Symbol, toSym: Symbol): void {
	walkNode(body, (n: Node): Node => {
		if (n.kind !== NodeKind.Identifier) return n;
		if (n.resolvedSym !== fromSym) return n;
		const id = n.data as IdentifierData;
		id.name = toSym.name;
		n.resolvedSym = toSym;
		return n;
	});
}

// ===== Tests =====
test "no reassign unchanged" { assert firstStmtKindAfter("function foo(x: number): number { return x + 1; }", lowerParamReassign) === NodeKind.FunctionDecl; }

test "passthrough stmts" { assert stmtCountAfter("let a = 1; let b = 2;", lowerParamReassign) === 2; }

test "reassign without checker no-op" { assert firstStmtKindAfter("function f(s: string): string { s = s; return s; }", lowerParamReassign) === NodeKind.FunctionDecl; }

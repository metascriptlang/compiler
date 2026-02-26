// Transform Test Utilities — shared helpers for inline transform tests
// DRY: parseInput, firstStmtKindAfter, stmtCountAfter, firstExprKindAfter

import { Node, NodeKind, ProgramData, ExprStmtData, CallExprData, FunctionDeclData, BlockStmtData } from "../ast/node";
import { TransformContext, createTransformContext } from "./context";
import { lex } from "../lexer/lexer";
import { parseProgram } from "../parser/statements/core";

export function parseInput(input: string): Result<Node, string> {
	const lr = lex(input);
	if (!lr.ok) return Result.err(lr.error);
	return parseProgram(lr.value);
}

export function makeCtx(): TransformContext {
	return createTransformContext();
}

export function getStmts(prog: Node): Node[] {
	const d = prog.data as ProgramData;
	return d.programStmts;
}

// Shared: parse input, apply transform, return stmts (or empty on error)
function transformStmts(input: string, transform: (prog: Node, ctx: TransformContext) => Node): Node[] {
	const result = parseInput(input);
	if (!result.ok) return [];
	const lowered = transform(result.value, makeCtx());
	return getStmts(lowered);
}

export function stmtCountAfter(input: string, transform: (prog: Node, ctx: TransformContext) => Node): number {
	return transformStmts(input, transform).length;
}

export function firstStmtKindAfter(input: string, transform: (prog: Node, ctx: TransformContext) => Node): NodeKind {
	const stmts = transformStmts(input, transform);
	if (stmts.length === 0) return NodeKind.Program;
	return stmts[0].kind;
}

export function firstExprKindAfter(input: string, transform: (prog: Node, ctx: TransformContext) => Node): NodeKind {
	const stmts = transformStmts(input, transform);
	if (stmts.length === 0) return NodeKind.Program;
	const stmt = stmts[0];
	if (stmt.kind === NodeKind.ExprStmt) {
		const sd = stmt.data as ExprStmtData;
		return sd.expr.kind;
	}
	return stmt.kind;
}

// Get the kind of the first ExprStmt's inner expression from a transformed program.
export function firstExprKind(prog: Node): NodeKind {
	if (prog === null) return NodeKind.ExprStmt;
	const stmts = getStmts(prog);
	let i = 0;
	while (i < stmts.length) {
		if (stmts[i].kind === NodeKind.ExprStmt) {
			const d = stmts[i].data as ExprStmtData;
			return d.expr.kind;
		}
		i += 1;
	}
	return NodeKind.ExprStmt;
}

// Get the callee kind of the first CallExpr in an ExprStmt.
export function firstCalleeKind(prog: Node): NodeKind {
	if (prog === null) return NodeKind.ExprStmt;
	const stmts = getStmts(prog);
	let i = 0;
	while (i < stmts.length) {
		if (stmts[i].kind === NodeKind.ExprStmt) {
			const d = stmts[i].data as ExprStmtData;
			if (d.expr.kind === NodeKind.CallExpr) {
				const cd = d.expr.data as CallExprData;
				return cd.callee.kind;
			}
		}
		i += 1;
	}
	return NodeKind.ExprStmt;
}

// Count statements inside the body of the first FunctionDecl after transform.
export function fnBodyStmtCount(input: string, transform: (prog: Node, ctx: TransformContext) => Node): number {
	const stmts = transformStmts(input, transform);
	let i = 0;
	while (i < stmts.length) {
		if (stmts[i].kind === NodeKind.FunctionDecl) {
			const fd = stmts[i].data as FunctionDeclData;
			if (fd.fnBody !== null && fd.fnBody.kind === NodeKind.BlockStmt) {
				const bd = fd.fnBody.data as BlockStmtData;
				return bd.statements.length;
			}
		}
		i += 1;
	}
	return -1;
}

// Get the argument count of the first CallExpr in an ExprStmt.
export function firstCallArgCount(prog: Node): number {
	if (prog === null) return -1;
	const stmts = getStmts(prog);
	let i = 0;
	while (i < stmts.length) {
		if (stmts[i].kind === NodeKind.ExprStmt) {
			const d = stmts[i].data as ExprStmtData;
			if (d.expr.kind === NodeKind.CallExpr) {
				const cd = d.expr.data as CallExprData;
				return cd.arguments.length;
			}
		}
		i += 1;
	}
	return -1;
}

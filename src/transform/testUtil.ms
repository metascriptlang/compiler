// Transform Test Utilities — shared helpers for inline transform tests
// DRY: parseInput, firstStmtKindAfter, stmtCountAfter, firstExprKindAfter

import { Node, NodeKind, ProgramData, ExprStmtData } from "../ast/node";
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

// Transform Test Utilities — shared helpers for inline transform tests
// DRY: parseInput, firstStmtKindAfter, stmtCountAfter, firstExprKindAfter

import { Node, NodeKind, ProgramData, ExprStmtData } from "../ast/node";
import { TransformContext } from "./context";
import { CheckerContext } from "../checker/context";
import { lex } from "../lexer/lexer";
import { parseProgram } from "../parser/statements/core";

export function parseInput(input: string): Result<Node, string> {
	const lr = lex(input);
	if (!lr.ok) return Result.err(lr.error);
	return parseProgram(lr.value);
}

export function makeCtx(): TransformContext {
	const ctx: TransformContext = { tempCounter: 0, errors: [], fnDeclNames: [], checkerCtx: null as unknown as CheckerContext };
	return ctx;
}

export function getStmts(prog: Node): Node[] {
	const d = prog.data as ProgramData;
	return d.programStmts;
}

export function stmtCountAfter(input: string, transform: (prog: Node, ctx: TransformContext) => Node): number {
	const result = parseInput(input);
	if (!result.ok) return -1;
	const prog = result.value;
	const lowered = transform(prog, makeCtx());
	const stmts = getStmts(lowered);
	return stmts.length;
}

export function firstStmtKindAfter(input: string, transform: (prog: Node, ctx: TransformContext) => Node): NodeKind {
	const result = parseInput(input);
	if (!result.ok) return NodeKind.Program;
	const prog = result.value;
	const lowered = transform(prog, makeCtx());
	const stmts = getStmts(lowered);
	if (stmts.length === 0) return NodeKind.Program;
	return stmts[0].kind;
}

export function firstExprKindAfter(input: string, transform: (prog: Node, ctx: TransformContext) => Node): NodeKind {
	const result = parseInput(input);
	if (!result.ok) return NodeKind.Program;
	const prog = result.value;
	const lowered = transform(prog, makeCtx());
	const stmts = getStmts(lowered);
	if (stmts.length === 0) return NodeKind.Program;
	const stmt = stmts[0];
	if (stmt.kind === NodeKind.ExprStmt) {
		const sd = stmt.data as ExprStmtData;
		return sd.expr.kind;
	}
	return stmt.kind;
}

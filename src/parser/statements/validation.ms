// Statement Test Helpers - Convenience functions for parser tests

import { Node, NodeKind, ProgramData, createNodeAt, makeLoc } from "../../ast/node";
import { createState } from "../cursor";
import { lex } from "../../lexer/lexer";
import { parseProgram } from "./core";

type NodeResult = Result<Node, string>;

// ===== Convenience: lex + parse in one step =====

export function parseSource(input: string): NodeResult {
	const lr = lex(input);
	if (!lr.ok) return Result.err(lr.error);
	const state = createState(lr.value);
	const pr = parseProgram(state);
	if (state.errors.length > 0) return Result.err(state.errors[0]);
	if (!pr.ok) return Result.err(pr.error);
	return Result.ok(pr.value);
}

// Lenient parse: returns partial AST even when there are parse errors.
// Used by LSP — incomplete code (e.g. "config.") must still produce a usable AST.
export function parseSourceLenient(input: string): NodeResult {
	const lr = lex(input);
	if (!lr.ok) return Result.err(lr.error);
	const state = createState(lr.value);
	const pr = parseProgram(state);
	if (!pr.ok) return Result.err(pr.error);
	return Result.ok(pr.value);
}

export function programOk(input: string): boolean {
	const pr = parseSource(input);
	return pr.ok;
}

export function stmtKind(input: string): NodeKind {
	const pr = parseSource(input);
	if (!pr.ok) return NodeKind.ExprStmt;
	const stmts = pr.value.data as ProgramData;
	if (stmts.programStmts.length == 0) return NodeKind.ExprStmt;
	return stmts.programStmts[0].kind;
}

export function stmtAt(input: string, index: int32): Node {
	const pr = parseSource(input);
	if (!pr.ok) return createNodeAt(NodeKind.ExprStmt, { expr: createNodeAt(NodeKind.NullLiteral, { nullPlaceholder: true }, makeLoc(0, 0)) }, makeLoc(0, 0));
	const stmts = pr.value.data as ProgramData;
	return stmts.programStmts[index];
}

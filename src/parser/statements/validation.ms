// Statement Test Helpers - Convenience functions for parser tests
// Uses registered callbacks via callProgramParser/callStateProgramParser.

import { Node, NodeKind, ProgramData, createNodeAt, makeLoc } from "../../ast/node";
import { createState } from "../context";
import { lex } from "../../lexer/lexer";
import { callStateProgramParser } from "./callbacks";

type NodeResult = Result<Node, string>;

// ===== Convenience: lex + parse in one step =====

export function parseSource(input: string): NodeResult {
	const lr = lex(input);
	if (!lr.ok) return Result.err(lr.error);
	const state = createState(lr.value);
	const pr = callStateProgramParser(state);
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
	const pr = callStateProgramParser(state);
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

export function stmtCount(input: string): int32 {
	const pr = parseSource(input);
	if (!pr.ok) return -1;
	const stmts = pr.value.data as ProgramData;
	return stmts.programStmts.length;
}

// Returns the number of parse errors collected during error recovery.
export function parseErrorCount(input: string): int32 {
	const lr = lex(input);
	if (!lr.ok) return -1;
	const state = createState(lr.value);
	callStateProgramParser(state);
	return state.errors.length;
}

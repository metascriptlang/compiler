// Statement Test Helpers - Convenience functions for parser tests
// Uses registered callbacks via callProgramParser/callStateProgramParser.

import { Token, TokenKind } from "../../lexer/token";
import { Node, NodeKind, ProgramData, createNodeAt } from "../../ast/node";
import { ParserState, createState } from "../context";
import { lex } from "../../lexer/lexer";
import { callStateProgramParser } from "./callbacks";

type NodeResult = Result<Node, string>;

// ===== Convenience: lex + parse in one step =====

export function parseSource(input: string): NodeResult {
	const lr = lex(input);
	if (!lr.ok) return Result.err(lr.error);
	// parseProgramFromState always returns ok (partial AST on errors)
	// Check errors via parseErrorCount() or low-level state API
	const state = createState(lr.value);
	const pr = callStateProgramParser(state);
	if (state.errors.length > 0) return Result.err(state.errors[0]);
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
	if (stmts.programStmts.length === 0) return NodeKind.ExprStmt;
	return stmts.programStmts[0].kind;
}

export function stmtAt(input: string, index: number): Node {
	const pr = parseSource(input);
	if (!pr.ok) return createNodeAt(NodeKind.ExprStmt, { expr: createNodeAt(NodeKind.NullLiteral, { nullPlaceholder: true }, { line: 0, column: 0 }) }, { line: 0, column: 0 });
	const stmts = pr.value.data as ProgramData;
	return stmts.programStmts[index];
}

export function stmtCount(input: string): number {
	const pr = parseSource(input);
	if (!pr.ok) return -1;
	const stmts = pr.value.data as ProgramData;
	return stmts.programStmts.length;
}

// Returns the number of parse errors collected during error recovery.
export function parseErrorCount(input: string): number {
	const lr = lex(input);
	if (!lr.ok) return -1;
	const state = createState(lr.value);
	callStateProgramParser(state);
	return state.errors.length;
}

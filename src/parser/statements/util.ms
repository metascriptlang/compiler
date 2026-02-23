// Statement Utilities - Shared callbacks and test helpers
// Provides callBlockParser/callExprParser to avoid circular deps.
// core.ms registers the real implementations at module load time.

import { Token, TokenKind } from "../../lexer/token";
import { Node, NodeKind, Expression } from "../../ast/node";
import { ParserState } from "../context";
import { lex } from "../../lexer/lexer";

type NodeResult = Result<Node, string>;
type BlockParserFn = (state: ParserState) => NodeResult;
type ExprParserFn = (state: ParserState) => NodeResult;
type ProgramParserFn = (tokens: Token[]) => NodeResult;

let blockParserFn: BlockParserFn = (state: ParserState): NodeResult => {
	return Result.err("Block parser not registered");
};

let exprParserFn: ExprParserFn = (state: ParserState): NodeResult => {
	return Result.err("Expr parser not registered");
};

type StmtParserFn = (state: ParserState) => NodeResult;

let stmtParserFn: StmtParserFn = (state: ParserState): NodeResult => {
	return Result.err("Stmt parser not registered");
};

let programParserFn: ProgramParserFn = (tokens: Token[]): NodeResult => {
	return Result.err("Program parser not registered");
};

export function registerStmtBlockParser(fn: BlockParserFn): void {
	blockParserFn = fn;
}

export function registerStmtExprParser(fn: ExprParserFn): void {
	exprParserFn = fn;
}

export function registerStmtParser(fn: StmtParserFn): void {
	stmtParserFn = fn;
}

export function registerStmtProgramParser(fn: ProgramParserFn): void {
	programParserFn = fn;
}

export function callBlockParser(state: ParserState): NodeResult {
	return blockParserFn(state);
}

export function callExprParser(state: ParserState): NodeResult {
	return exprParserFn(state);
}

export function callStmtParser(state: ParserState): NodeResult {
	return stmtParserFn(state);
}

export function programOk(input: string): boolean {
	const lr = lex(input);
	if (!lr.ok) return false;
	const pr = programParserFn(lr.value);
	return pr.ok;
}

export function stmtKind(input: string): NodeKind {
	const lr = lex(input);
	if (!lr.ok) return NodeKind.ExprStmt;
	const pr = programParserFn(lr.value);
	if (!pr.ok) return NodeKind.ExprStmt;
	const stmts = pr.value.data as { programStmts: Node[] };
	if (stmts.programStmts.length === 0) return NodeKind.ExprStmt;
	return stmts.programStmts[0].kind;
}

export function stmtCount(input: string): number {
	const lr = lex(input);
	if (!lr.ok) return -1;
	const pr = programParserFn(lr.value);
	if (!pr.ok) return -1;
	const stmts = pr.value.data as { programStmts: Node[] };
	return stmts.programStmts.length;
}

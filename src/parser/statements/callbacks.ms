// Statement Callbacks - Runtime callback infrastructure
// Sub-parsers (control, declaration, errorHandling) use callBlockParser/callExprParser
// to call back into core.ms without circular imports.
// core.ms registers the real implementations at module load time.

import { Token, TokenKind } from "../../lexer/token";
import { Node, NodeKind } from "../../ast/node";
import { ParserState } from "../context";

type NodeResult = Result<Node, string>;
type BlockParserFn = (state: ParserState) => NodeResult;
type ExprParserFn = (state: ParserState) => NodeResult;
type ProgramParserFn = (tokens: Token[]) => NodeResult;
type StmtParserFn = (state: ParserState) => NodeResult;
type StateProgramParserFn = (state: ParserState) => NodeResult;

let blockParserFn: BlockParserFn = (state: ParserState): NodeResult => {
	return Result.err("Block parser not registered");
};

let exprParserFn: ExprParserFn = (state: ParserState): NodeResult => {
	return Result.err("Expr parser not registered");
};

let stmtParserFn: StmtParserFn = (state: ParserState): NodeResult => {
	return Result.err("Stmt parser not registered");
};

let programParserFn: ProgramParserFn = (tokens: Token[]): NodeResult => {
	return Result.err("Program parser not registered");
};

let stateProgramParserFn: StateProgramParserFn = (state: ParserState): NodeResult => {
	return Result.err("State program parser not registered");
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

export function registerStateProgramParser(fn: StateProgramParserFn): void {
	stateProgramParserFn = fn;
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

export function callProgramParser(tokens: Token[]): NodeResult {
	return programParserFn(tokens);
}

export function callStateProgramParser(state: ParserState): NodeResult {
	return stateProgramParserFn(state);
}

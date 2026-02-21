// Statement Utilities - Shared callbacks and test helpers
// Provides callBlockParser/callExprParser to avoid circular deps.
// core.ms registers the real implementations at module load time.

import { Token, TokenKind } from "../../lexer/token";
import { Node, NodeKind, Expression } from "../../ast/node";
import { ParserState } from "../context";
import { lex } from "../../lexer/lexer";

type Nodes = Node[];
type NodeResult = Result<Node, string>;
type NodesResult = Result<Nodes, string>;
type BlockParserFn = (state: ParserState) => NodeResult;
type ExprParserFn = (state: ParserState) => NodeResult;
type ProgramParserFn = (tokens: Token[]) => NodesResult;

let blockParserFn: BlockParserFn = (state: ParserState): NodeResult => {
	return Result.err("Block parser not registered");
};

let exprParserFn: ExprParserFn = (state: ParserState): NodeResult => {
	return Result.err("Expr parser not registered");
};

let programParserFn: ProgramParserFn = (tokens: Token[]): NodesResult => {
	return Result.err("Program parser not registered");
};

export function registerStmtBlockParser(fn: BlockParserFn): void {
	blockParserFn = fn;
}

export function registerStmtExprParser(fn: ExprParserFn): void {
	exprParserFn = fn;
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

export function programOk(input: string): boolean {
	const lr = lex(input);
	if (!lr.ok) return false;
	const pr = programParserFn(lr.value);
	return pr.ok;
}

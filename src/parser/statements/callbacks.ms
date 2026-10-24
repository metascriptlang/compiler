// Statement Callbacks - the slots declaration.ms and module/loader.ms still read.
// core.ms registers the real implementations at module load time.

import { Node } from "../../ast/node";
import { ParserState } from "../context";

type NodeResult = Result<Node, string>;
type BlockParserFn = (state: ParserState) => NodeResult;
type ExprParserFn = (state: ParserState) => NodeResult;
type StmtParserFn = (state: ParserState) => NodeResult;
type StateProgramParserFn = (state: ParserState) => NodeResult;
type PatternParserFn = (state: ParserState) => NodeResult;

let blockParserFn: BlockParserFn = (state: ParserState): NodeResult => {
	return Result.err("Block parser not registered");
};

let exprParserFn: ExprParserFn = (state: ParserState): NodeResult => {
	return Result.err("Expr parser not registered");
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

export function registerStateProgramParser(fn: StateProgramParserFn): void {
	stateProgramParserFn = fn;
}

export function registerStmtParser(fn: StmtParserFn): void {}

export function registerPatternParsers(objectFn: PatternParserFn, arrayFn: PatternParserFn): void {}

export function callBlockParser(state: ParserState): NodeResult {
	return blockParserFn(state);
}

export function callExprParser(state: ParserState): NodeResult {
	return exprParserFn(state);
}

export function callStateProgramParser(state: ParserState): NodeResult {
	return stateProgramParserFn(state);
}

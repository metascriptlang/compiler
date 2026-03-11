// Statement Parser Core - Dispatch, block/expr/program parsing
// Pattern: ~/projects/metascript/src/parser/parser.zig parseStatement()

import { Token, TokenKind } from "../../lexer/token";
import { Node, NodeKind, NodeData, createNode, MatchExprData } from "../../ast/node";
import { ParserState, createState, current, advance, isAtEnd, consumeSemicolon, addError, synchronize } from "../context";
import { parseExpressionFromState, registerBlockParser } from "../expressions/core";
import { parseIfStmt, parseWhileStmt, parseForStmt, parseBreakStmt, parseContinueStmt, parseReturnStmt, parseDoWhileStmt, parseSwitchStmt, parseDeferStmt, parseUnreachableStmt, parseTestDecl, parseAssertStmt } from "./control";
import { parseVariableDecl, parseFunctionDecl, parseImportDecl, parseExportDecl, parseTypeAliasDecl, parseEnumDecl, parseInterfaceDecl, parseClassDecl, parseMacroInvocation, parseExternDecl, parseDistinctTypeDecl, parseMacroDecl } from "./declaration";
import { parseThrowStmt, parseTryCatchStmt } from "./errorHandling";
import { registerStmtBlockParser, registerStmtExprParser, registerStmtParser, registerStateProgramParser } from "./callbacks";
import { programOk, stmtKind, stmtCount, parseErrorCount } from "./validation";
import { attachComments } from "../util";


// Type aliases
type NodeResult = Result<Node, string>;

// ===== Statement Dispatch (match on TokenKind) =====
// syntax: stmt = varDecl | ifStmt | whileStmt | forStmt | returnStmt | breakStmt
//              | continueStmt | funcDecl | block | importDecl | exportDecl | typeAlias
//              | enumDecl | interfaceDecl | classDecl | throwStmt | tryCatch
//              | doWhile | switchStmt | deferStmt | unreachableStmt | matchStmt | exprStmt

export function parseStatement(state: ParserState): NodeResult {
	const token = current(state);

	// Async function declaration — before match to avoid try-in-match-arm limitation
	if (token.kind === TokenKind.Async) {
		if (state.position + 1 < state.tokens.length &&
			state.tokens[state.position + 1].kind === TokenKind.Function) {
			const res = try parseFunctionDecl(state);
			return Result.ok(attachComments(state, res));
		}
		const res = try parseExprStmt(state);
		return Result.ok(attachComments(state, res));
	}

	// @comptime { ... } — intercept before decorator loop
	if (token.kind === TokenKind.At) {
		if (state.position + 1 < state.tokens.length &&
			state.tokens[state.position + 1].value === "comptime" &&
			state.position + 2 < state.tokens.length &&
			state.tokens[state.position + 2].kind === TokenKind.LBrace) {
			advance(state); // consume '@'
			advance(state); // consume 'comptime'
			const comptimeBody = try parseBlockStmt(state);
			const node = createNode(NodeKind.ComptimeBlock, { comptimeBody }, token);
			return Result.ok(attachComments(state, node));
		}
	}

	// Decorator / directive handling — before match to avoid try-in-match-arm limitation
	if (token.kind === TokenKind.At) {
		const decorators: Node[] = [];
		while (!isAtEnd(state) && current(state).kind === TokenKind.At) {
			const dec = try parseMacroInvocation(state);
			decorators.push(dec);
		}
		// Standalone directive: @name(args); — semicolon means no inner declaration
		if (decorators.length === 1 && !isAtEnd(state) && current(state).kind === TokenKind.Semicolon) {
			consumeSemicolon(state);
			const node = createNode(NodeKind.ExprStmt, { expr: decorators[0] }, token);
			return Result.ok(attachComments(state, node));
		}
		const decl = try parseStatement(state);
		const node = createNode(NodeKind.DecoratedDecl, {
			decorators,
			decoratedNode: decl,
		}, token);
		return Result.ok(attachComments(state, node));
	}

	const res = match (token.kind) {
		TokenKind.Const | TokenKind.Let | TokenKind.Var => parseVariableDecl(state),
		TokenKind.If => parseIfStmt(state),
		TokenKind.While => parseWhileStmt(state),
		TokenKind.For => parseForStmt(state),
		TokenKind.Return => parseReturnStmt(state),
		TokenKind.Break => parseBreakStmt(state),
		TokenKind.Continue => parseContinueStmt(state),
		TokenKind.Function => parseFunctionDecl(state),
		TokenKind.LBrace => parseBlockStmt(state),
		TokenKind.Import => parseImportDecl(state),
		TokenKind.Export => parseExportDecl(state),
		TokenKind.Type => parseTypeAliasDecl(state),
		TokenKind.Enum => parseEnumDecl(state),
		TokenKind.Interface => parseInterfaceDecl(state),
		TokenKind.Throw => parseThrowStmt(state),
		TokenKind.Try => parseTryCatchStmt(state),
		TokenKind.Do => parseDoWhileStmt(state),
		TokenKind.Switch => parseSwitchStmt(state),
		TokenKind.Class | TokenKind.Abstract => parseClassDecl(state),
		TokenKind.Defer => parseDeferStmt(state),
		TokenKind.Unreachable => parseUnreachableStmt(state),
		TokenKind.Extern => parseExternDecl(state),
		TokenKind.Distinct => parseDistinctTypeDecl(state),
		TokenKind.Macro => parseMacroDecl(state),
		TokenKind.Match => parseExprStmt(state),
		TokenKind.Test => parseTestDecl(state),
		TokenKind.Assert => parseAssertStmt(state),
		_ => parseExprStmt(state),
	};

	if (!res.ok) return res;
	return Result.ok(attachComments(state, res.value));
}

// ===== Block Parser =====
// syntax: block = '{' stmt* '}'

export function parseBlockStmt(state: ParserState): NodeResult {
	const token = current(state);
	if (token.kind !== TokenKind.LBrace) {
		return Result.err(`Expected '{' at line ${token.line}`);
	}
	advance(state); // consume '{'

	const stmts: Node[] = [];
	while (!isAtEnd(state) && current(state).kind !== TokenKind.RBrace) {
		const s = try parseStatement(state);
		stmts.push(s);
	}

	const closeToken = current(state);
	if (closeToken.kind !== TokenKind.RBrace) {
		return Result.err(`Expected '}' at line ${closeToken.line}`);
	}
	advance(state); // consume '}'

	return Result.ok(createNode(NodeKind.BlockStmt, { statements: stmts }, token));
}

// ===== Expression Statement Parser =====
// syntax: exprStmt = expr ';'

export function parseExprStmt(state: ParserState): NodeResult {
	const token = current(state);
	const expr = try parseExpressionFromState(state);
	consumeSemicolon(state);
	return Result.ok(createNode(NodeKind.ExprStmt, { expr }, token));
}

// ===== Program Parser =====
// Main entry point for parsing a full file.

export function parseProgram(state: ParserState): NodeResult {
	const token = current(state);
	const stmts: Node[] = [];
	while (!isAtEnd(state)) {
		const result = parseStatement(state);
		if (result.ok) {
			stmts.push(result.value);
		} else {
			addError(state, result.error);
			synchronize(state);
		}
	}
	const node = createNode(NodeKind.Program, { programStmts: stmts }, token);
	return Result.ok(attachComments(state, node));
}

// Register real implementations for callbacks
export function registerCoreParsers(): void {
	registerStmtParser(parseStatement);
	registerStmtBlockParser(parseBlockStmt);
	registerStmtExprParser(parseExpressionFromState);
	registerStateProgramParser(parseProgram);
	registerBlockParser(parseBlockStmt);
}

// Auto-register at module load so parser tests work without explicit init
registerCoreParsers();

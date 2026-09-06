// Statement Parser Core - Dispatch, block/expr/program parsing
// Pattern: ~/projects/metascript/src/parser/parser.zig parseStatement()

import { TokenKind } from "../../lexer/token";
import { Node, NodeKind, FunctionDeclData, BlockStmtData, createNode } from "../../ast/node";
import { ParserState, current, advance, peek, isAtEnd, consumeSemicolon, addError, synchronize, stampEnd } from "../context";
import { getParserDefines } from "../context";
import { isDefined, definedValue } from "../../compiler/defines";
import { parseIntStr } from "../../utils/string";
import { parseExpressionFromState, registerBlockParser } from "../expressions/core";
import { parseIfStmt, parseWhileStmt, parseForStmt, parseBreakStmt, parseContinueStmt, parseReturnStmt, parseDoWhileStmt, parseSwitchStmt, parseDeferStmt, parseUnreachableStmt, parseTestDecl, parseAssertStmt } from "./control";
import { parseVariableDecl, parseStaticVariableDecl, parseFunctionDecl, parseImportDecl, parseExportDecl, parseTypeAliasDecl, parseEnumDecl, parseInterfaceDecl, parseStructDecl, parseClassDecl, parseActorDecl, parseMacroInvocation, parseExternDecl, parseDistinctTypeDecl, parseMacroDecl, parseConverterDecl } from "./declaration";
import { parseThrowStmt, parseTryCatchStmt } from "./errorHandling";
import { registerStmtBlockParser, registerStmtExprParser, registerStmtParser, registerStateProgramParser } from "./callbacks";
import { attachComments } from "../util";


// Type aliases
type NodeResult = Result<Node, string>;
type NodesResult = Result<Node[], string>;

// ===== Statement Dispatch (match on TokenKind) =====
// syntax: stmt = varDecl | ifStmt | whileStmt | forStmt | returnStmt | breakStmt
//              | continueStmt | funcDecl | block | importDecl | exportDecl | typeAlias
//              | enumDecl | interfaceDecl | classDecl | throwStmt | tryCatch
//              | doWhile | switchStmt | deferStmt | unreachableStmt | matchStmt | exprStmt

export function parseStatement(state: ParserState): NodeResult {
	const token = current(state);

	// Async function declaration — before match to avoid try-in-match-arm limitation
	if (token.kind == TokenKind.Async) {
		if (peek(state, 1).kind == TokenKind.Function) {
			const asyncFn = try parseFunctionDecl(state);
			return Result.ok(attachComments(state, asyncFn));
		}
		const asyncExpr = try parseExprStmt(state);
		return Result.ok(attachComments(state, asyncExpr));
	}

	// @comptime { ... } — intercept before decorator loop
	if (token.kind == TokenKind.At) {
		if (peek(state, 1).value == "comptime" &&
			peek(state, 2).kind == TokenKind.LBrace) {
			advance(state); // consume '@'
			advance(state); // consume 'comptime'
			const comptimeBody = try parseBlockStmt(state);
			const node = createNode(NodeKind.ComptimeBlock, { comptimeBody }, token);
			return Result.ok(attachComments(state, node));
		}
	}

	// Template declaration — `template name<T>(...): T { ... }`
	// Parsed like a function but without the `function` keyword.
	if (token.kind == TokenKind.Template) {
		const fn = try parseFunctionDecl(state);
		const fd = fn.data as FunctionDeclData;
		fd.fnFlags = fd.fnFlags == "" ? "template" : fd.fnFlags + "|template";
		return Result.ok(attachComments(state, fn));
	}

	// Decorator / directive handling — before match to avoid try-in-match-arm limitation
	if (token.kind == TokenKind.At) {
		const decorators: Node[] = [];
		while (!isAtEnd(state) && current(state).kind == TokenKind.At) {
			const dec = try parseMacroInvocation(state);
			decorators.push(dec);
		}
		// Standalone directive: @name(args); — semicolon means no inner declaration
		if (decorators.length == 1 && !isAtEnd(state) && current(state).kind == TokenKind.Semicolon) {
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
		TokenKind.Static => parseStaticVariableDecl(state),
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
		TokenKind.Struct => parseStructDecl(state),
		TokenKind.Throw => parseThrowStmt(state),
		TokenKind.Try => parseTryCatchStmt(state),
		TokenKind.Do => parseDoWhileStmt(state),
		TokenKind.Switch => parseSwitchStmt(state),
		TokenKind.Class | TokenKind.Abstract => parseClassDecl(state),
		TokenKind.Actor => parseActorDecl(state),
		TokenKind.Defer => parseDeferStmt(state),
		TokenKind.Unreachable => parseUnreachableStmt(state),
		TokenKind.Extern => parseExternDecl(state),
		TokenKind.Distinct => parseDistinctTypeDecl(state),
		TokenKind.Macro => parseMacroDecl(state),
		TokenKind.Converter => parseConverterDecl(state),
		TokenKind.Match => parseExprStmt(state),
		TokenKind.Test => parseTestDecl(state),
		TokenKind.Assert => parseAssertStmt(state),
		_ => parseExprStmt(state),
	};

	if (!res.ok) return res;
	stampEnd(state, res.value);
	return Result.ok(attachComments(state, res.value));
}


// ===== Conditional Compilation =====
// `when (flag) { … } else when (…) { … } else { … }`.
//
// Nim's semWhen (semexprs.nim:2705-2712) takes the first true branch and returns
// immediately, so the other branches are never semantically checked. MetaScript
// resolves the chain HERE, at parse, because collectTopLevel runs before any check
// and would otherwise register declarations belonging to a dead branch — Haxe cuts
// at the same place ("discarded while parsing … not type-checked").
//
// The winning branch's statements are returned for splicing into the enclosing
// statement list: Nim splices an nkStmtList, never a scope-bearing block, so a
// `when` must not introduce a scope of its own.

function isNumericStr(s: string): boolean {
	if (s.length == 0) return false;
	for (let i = 0; i < s.length; i += 1) {
		const c = s.charAt(i);
		if (i == 0 && c == "-" && s.length > 1) continue;
		if (c < "0" || c > "9") return false;
	}
	return true;
}

function cmpStr(a: string, b: string): int32 {
	const n = a.length < b.length ? a.length : b.length;
	for (let i = 0; i < n; i += 1) {
		const ca = a.byteAt(i);
		const cb = b.byteAt(i);
		if (ca != cb) return ca < cb ? -1 : 1;
	}
	if (a.length == b.length) return 0;
	return a.length < b.length ? -1 : 1;
}

function applyCmp(lhs: string, rhs: string, op: TokenKind): boolean {
	let c = 0;
	if (isNumericStr(lhs) && isNumericStr(rhs)) {
		const a = parseIntStr(lhs);
		const b = parseIntStr(rhs);
		c = a == b ? 0 : (a < b ? -1 : 1);
	} else {
		c = cmpStr(lhs, rhs);
	}
	if (op == TokenKind.EqEq || op == TokenKind.EqEqEq) return c == 0;
	if (op == TokenKind.BangEq || op == TokenKind.BangEqEq) return c != 0;
	if (op == TokenKind.Lt) return c < 0;
	if (op == TokenKind.LtEq) return c <= 0;
	if (op == TokenKind.Gt) return c > 0;
	return c >= 0;
}

function isCmpOp(k: TokenKind): boolean {
	return k == TokenKind.EqEq || k == TokenKind.EqEqEq
		|| k == TokenKind.BangEq || k == TokenKind.BangEqEq
		|| k == TokenKind.Lt || k == TokenKind.LtEq
		|| k == TokenKind.Gt || k == TokenKind.GtEq;
}

// The condition grammar is CLOSED — flag names, literals, !, &&, ||, comparisons and
// parentheses, nothing else. Both references restrict it the same way; an open
// expression grammar would need a symbol table that does not exist at parse time.
function parseWhenPrimary(state: ParserState): Result<boolean, string> {
	const tok = current(state);
	if (tok.kind == TokenKind.LParen) {
		advance(state);
		const inner = try parseWhenOr(state);
		if (current(state).kind != TokenKind.RParen) {
			return Result.err(`Expected ')' in 'when' condition at line ${current(state).line}`);
		}
		advance(state);
		return Result.ok(inner);
	}
	if (tok.kind == TokenKind.Bang) {
		advance(state);
		const v = try parseWhenPrimary(state);
		return Result.ok(!v);
	}
	if (tok.kind == TokenKind.Ident) {
		const name = tok.value;
		advance(state);
		if (isCmpOp(current(state).kind)) {
			const op = current(state).kind;
			advance(state);
			const rhsTok = current(state);
			if (rhsTok.kind != TokenKind.String && rhsTok.kind != TokenKind.Number && rhsTok.kind != TokenKind.Ident) {
				return Result.err(`Expected a literal after the comparison in 'when' condition at line ${rhsTok.line}`);
			}
			advance(state);
			return Result.ok(applyCmp(definedValue(getParserDefines(), name), rhsTok.value, op));
		}
		return Result.ok(isDefined(getParserDefines(), name));
	}
	return Result.err(`Unsupported expression in 'when' condition at line ${tok.line} — only flag names, literals, !, &&, || and comparisons are allowed`);
}

function parseWhenAnd(state: ParserState): Result<boolean, string> {
	let left = try parseWhenPrimary(state);
	while (current(state).kind == TokenKind.AmpAmp) {
		advance(state);
		const right = try parseWhenPrimary(state);
		left = left && right;
	}
	return Result.ok(left);
}

function parseWhenOr(state: ParserState): Result<boolean, string> {
	let left = try parseWhenAnd(state);
	while (current(state).kind == TokenKind.PipePipe) {
		advance(state);
		const right = try parseWhenAnd(state);
		left = left || right;
	}
	return Result.ok(left);
}

function parseWhenHead(state: ParserState): Result<boolean, string> {
	if (current(state).kind != TokenKind.LParen) {
		return Result.err(`Expected '(' after 'when' at line ${current(state).line}`);
	}
	advance(state);
	const v = try parseWhenOr(state);
	if (current(state).kind != TokenKind.RParen) {
		return Result.err(`Expected ')' after 'when' condition at line ${current(state).line}`);
	}
	advance(state);
	return Result.ok(v);
}

function blockStatements(node: Node): Node[] {
	if (node.kind != NodeKind.BlockStmt) return [];
	return (node.data as BlockStmtData).statements;
}

// Every branch is PARSED (a dead branch must still be syntactically valid — Haxe says
// the same) but only the first true one is selected; later conditions are parsed for
// their tokens and not consulted, mirroring semWhen's early return.
export function parseWhenChain(state: ParserState): NodesResult {
	advance(state); // consume 'when'
	const firstCond = try parseWhenHead(state);
	const firstBlock = try parseBlockStmt(state);
	let chosen: Node[] = [];
	let picked = firstCond;
	if (firstCond) { chosen = blockStatements(firstBlock); }

	while (current(state).kind == TokenKind.Else) {
		advance(state);
		if (current(state).kind == TokenKind.When) {
			advance(state);
			const cond = try parseWhenHead(state);
			const blk = try parseBlockStmt(state);
			if (!picked && cond) { chosen = blockStatements(blk); picked = true; }
		} else {
			const blk = try parseBlockStmt(state);
			if (!picked) { chosen = blockStatements(blk); picked = true; }
			break;
		}
	}
	return Result.ok(chosen);
}

// ===== Block Parser =====
// syntax: block = '{' stmt* '}'

export function parseBlockStmt(state: ParserState): NodeResult {
	const token = current(state);
	if (token.kind != TokenKind.LBrace) {
		return Result.err(`Expected '{' at line ${token.line}`);
	}
	advance(state); // consume '{'

	const stmts: Node[] = [];
	while (!isAtEnd(state) && current(state).kind != TokenKind.RBrace) {
		if (current(state).kind == TokenKind.When) {
			const picked = try parseWhenChain(state);
			for (const w of picked) { stmts.push(w); }
			continue;
		}
		const s = try parseStatement(state);
		stmts.push(s);
	}

	const closeToken = current(state);
	if (closeToken.kind != TokenKind.RBrace) {
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
		if (current(state).kind == TokenKind.When) {
			const chain = parseWhenChain(state);
			if (chain.ok) {
				for (const w of chain.value) { stmts.push(w); }
			} else {
				addError(state, chain.error);
				synchronize(state);
			}
			continue;
		}
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

// Statement Parser Core - Dispatch, block/expr/program parsing
// Pattern: ~/projects/metascript/src/parser/parser.zig parseStatement()

import { Token, TokenKind } from "../../lexer/token";
import { Node, NodeKind, NodeData, createNode } from "../../ast/node";
import { ParserState, createState, current, advance, isAtEnd, consumeSemicolon, addError, synchronize } from "../context";
import { parseExpressionFromState, registerBlockParser } from "../expressions/core";
import { parseMatchExpr } from "../expressions/match";
import { parseIfStmt, parseWhileStmt, parseForStmt, parseBreakStmt, parseContinueStmt, parseReturnStmt, parseDoWhileStmt, parseSwitchStmt, parseDeferStmt, parseUnreachableStmt } from "./control";
import { parseVariableDecl, parseFunctionDecl, parseImportDecl, parseExportDecl, parseTypeAliasDecl, parseEnumDecl, parseInterfaceDecl, parseClassDecl, parseMacroInvocation, parseExternDecl, parseDistinctTypeDecl, parseMacroDecl } from "./declaration";
import { parseThrowStmt, parseTryCatchStmt } from "./errorHandling";
import { registerStmtBlockParser, registerStmtExprParser, registerStmtParser, registerStmtProgramParser, registerStateProgramParser, programOk, stmtKind, stmtCount, parseErrorCount } from "./util";
import { test, check, testGroup } from "std/testing";

// Type aliases
type NodeResult = Result<Node, string>;

// ===== Statement Dispatch (match on TokenKind) =====
// syntax: stmt = varDecl | ifStmt | whileStmt | forStmt | returnStmt | breakStmt
//              | continueStmt | funcDecl | block | importDecl | exportDecl | typeAlias
//              | enumDecl | interfaceDecl | classDecl | throwStmt | tryCatch
//              | doWhile | switchStmt | deferStmt | unreachableStmt | matchStmt | exprStmt

function parseStatement(state: ParserState): NodeResult {
	const token = current(state);

	// Async function declaration — before match to avoid try-in-match-arm limitation
	if (token.kind === TokenKind.Async) {
		if (state.position + 1 < state.tokens.length &&
			state.tokens[state.position + 1].kind === TokenKind.Function) {
			return parseFunctionDecl(state);
		}
		return parseExprStmt(state);
	}

	// Decorator handling — before match to avoid try-in-match-arm limitation
	if (token.kind === TokenKind.At) {
		const decorators: Node[] = [];
		while (!isAtEnd(state) && current(state).kind === TokenKind.At) {
			const dec = try parseMacroInvocation(state);
			decorators.push(dec);
		}
		const decl = try parseStatement(state);
		return Result.ok(createNode(NodeKind.DecoratedDecl, {
			decorators,
			decoratedNode: decl,
		}, token));
	}

	match (token.kind) {
		TokenKind.Const | TokenKind.Let | TokenKind.Var => {
			return parseVariableDecl(state);
		},
		TokenKind.If => {
			return parseIfStmt(state);
		},
		TokenKind.While => {
			return parseWhileStmt(state);
		},
		TokenKind.For => {
			return parseForStmt(state);
		},
		TokenKind.Return => {
			return parseReturnStmt(state);
		},
		TokenKind.Break => {
			return parseBreakStmt(state);
		},
		TokenKind.Continue => {
			return parseContinueStmt(state);
		},
		TokenKind.Function => {
			return parseFunctionDecl(state);
		},
		TokenKind.LBrace => {
			return parseBlockStmt(state);
		},
		TokenKind.Import => {
			return parseImportDecl(state);
		},
		TokenKind.Export => {
			return parseExportDecl(state);
		},
		TokenKind.Type => {
			return parseTypeAliasDecl(state);
		},
		TokenKind.Enum => {
			return parseEnumDecl(state);
		},
		TokenKind.Interface => {
			return parseInterfaceDecl(state);
		},
		TokenKind.Throw => {
			return parseThrowStmt(state);
		},
		TokenKind.Try => {
			return parseTryCatchStmt(state);
		},
		TokenKind.Do => {
			return parseDoWhileStmt(state);
		},
		TokenKind.Switch => {
			return parseSwitchStmt(state);
		},
		TokenKind.Class => {
			return parseClassDecl(state);
		},
		TokenKind.Abstract => {
			return parseClassDecl(state);
		},
		TokenKind.Defer => {
			return parseDeferStmt(state);
		},
		TokenKind.Unreachable => {
			return parseUnreachableStmt(state);
		},
		TokenKind.Extern => {
			return parseExternDecl(state);
		},
		TokenKind.Distinct => {
			return parseDistinctTypeDecl(state);
		},
		TokenKind.Macro => {
			return parseMacroDecl(state);
		},
		TokenKind.Match => {
			return parseMatchStmt(state);
		},
		_ => {
			return parseExprStmt(state);
		},
	};
	return Result.err("unreachable");
}

// ===== Block Statement =====
// syntax: '{' stmt* '}'

function parseBlockStmt(state: ParserState): NodeResult {
	const lbrace = current(state);
	if (lbrace.kind !== TokenKind.LBrace) {
		return Result.err(`Expected '{' at line ${lbrace.line.toString()}`);
	}

	advance(state);
	const stmts: Node[] = [];
	while (!isAtEnd(state) && current(state).kind !== TokenKind.RBrace) {
		if (current(state).kind === TokenKind.Semicolon) {
			advance(state);
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

	if (current(state).kind === TokenKind.RBrace) {
		advance(state);
	}

	return Result.ok(createNode(NodeKind.BlockStmt, { statements: stmts }, lbrace));
}

// ===== Expression Statement =====
// syntax: expr ';'

function parseExprStmt(state: ParserState): NodeResult {
	const token = current(state);
	const expression = try parseExpressionFromState(state);
	consumeSemicolon(state);

	return Result.ok(createNode(NodeKind.ExprStmt, { expr: expression }, token));
}

// ===== Match Statement =====
// match (expr) { cases } at statement level

function matchStmtExprParser(s: ParserState, _minPrec: number): NodeResult {
	return parseExpressionFromState(s);
}

function matchStmtBlockParser(s: ParserState): NodeResult {
	return parseBlockStmt(s);
}

function parseMatchStmt(state: ParserState): NodeResult {
	const matchToken = current(state);
	const matchNode = try parseMatchExpr(state, matchStmtExprParser, matchStmtBlockParser);
	const data = matchNode.data as { matchDisc: Node, matchCases: Node[] };
	return Result.ok(createNode(NodeKind.MatchStmt, {
		matchStmtDisc: data.matchDisc,
		matchStmtCases: data.matchCases,
	}, matchToken));
}

// ===== Top-Level Program Parser =====

export function parseProgramFromState(state: ParserState): NodeResult {
	const startToken = current(state);
	const stmts: Node[] = [];
	while (!isAtEnd(state)) {
		if (current(state).kind === TokenKind.Semicolon) {
			advance(state);
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

	// If errors were collected, return the first one
	if (state.errors.length > 0) {
		return Result.err(state.errors[0]);
	}
	return Result.ok(createNode(NodeKind.Program, { programStmts: stmts }, startToken));
}

export function parseProgram(tokens: Token[]): NodeResult {
	const state = createState(tokens);
	return parseProgramFromState(state);
}

// ===== Register callbacks for sub-modules =====
// Sub-modules call these via util.ms to avoid circular imports

registerStmtBlockParser((state: ParserState): NodeResult => { return parseBlockStmt(state); });
registerStmtExprParser((state: ParserState): NodeResult => { return parseExpressionFromState(state); });
registerStmtParser((state: ParserState): NodeResult => { return parseStatement(state); });
registerStmtProgramParser((tokens: Token[]): NodeResult => { return parseProgram(tokens); });
registerStateProgramParser((state: ParserState): NodeResult => { return parseProgramFromState(state); });

// Also register with expressions for arrow function block bodies
registerBlockParser((state: ParserState): NodeResult => { return parseBlockStmt(state); });

// ===== Core Tests =====

// --- Structural: verify dispatch produces correct node kinds ---

testGroup("Decorator/Async Stmt", () => {
	test("async fn is FunctionDecl", () => { check(stmtKind("async function f() {}") === NodeKind.FunctionDecl); });
	test("decorator is DecoratedDecl", () => { check(stmtKind("@foo function f() {}") === NodeKind.DecoratedDecl); });
	test("decorator class", () => { check(programOk("@derive(Eq) class Point { x: number; }")); });
	test("multi decorator", () => { check(programOk("@derive(Eq) @derive(Hash) class Foo {}")); });
	test("decorator export", () => { check(programOk("@export(\"name\") function f() {}")); });
	test("decorator inline", () => { check(programOk("@inline function f() {}")); });
	test("async arrow stmt", () => { check(programOk("const f = async () => 42;")); });
});

testGroup("Stmt Structure", () => {
	test("const is VariableDecl", () => { check(stmtKind("const x = 1;") === NodeKind.VariableDecl); });
	test("if is IfStmt", () => { check(stmtKind("if (x) {}") === NodeKind.IfStmt); });
	test("while is WhileStmt", () => { check(stmtKind("while (x) {}") === NodeKind.WhileStmt); });
	test("for is ForStmt", () => { check(stmtKind("for (let i = 0; i < n; i++) {}") === NodeKind.ForStmt); });
	test("for-of is ForOfStmt", () => { check(stmtKind("for (const x of items) {}") === NodeKind.ForOfStmt); });
	test("for-in is ForInStmt", () => { check(stmtKind("for (const k in obj) {}") === NodeKind.ForInStmt); });
	test("function is FunctionDecl", () => { check(stmtKind("function f() {}") === NodeKind.FunctionDecl); });
	test("import is ImportDecl", () => { check(stmtKind("import { x } from \"y\";") === NodeKind.ImportDecl); });
	test("export is ExportDecl", () => { check(stmtKind("export const x = 1;") === NodeKind.ExportDecl); });
	test("enum is EnumDecl", () => { check(stmtKind("enum X { A, B }") === NodeKind.EnumDecl); });
	test("interface is InterfaceDecl", () => { check(stmtKind("interface P { x: number; }") === NodeKind.InterfaceDecl); });
	test("class is ClassDecl", () => { check(stmtKind("class Foo {}") === NodeKind.ClassDecl); });
	test("defer is DeferStmt", () => { check(stmtKind("defer f();") === NodeKind.DeferStmt); });
	test("throw is ThrowStmt", () => { check(stmtKind("throw \"err\";") === NodeKind.ThrowStmt); });
	test("block is BlockStmt", () => { check(stmtKind("{ x; }") === NodeKind.BlockStmt); });
	test("unreachable is UnreachableStmt", () => { check(stmtKind("unreachable;") === NodeKind.UnreachableStmt); });
	test("match is MatchStmt", () => { check(stmtKind("match (x) { 1 => a, _ => b }") === NodeKind.MatchStmt); });
	// Counts
	test("two stmts", () => { check(stmtCount("x; y;") === 2); });
	test("bare semis = 0", () => { check(stmtCount(";;;") === 0); });
	test("three stmts", () => { check(stmtCount("const a = 1; f(a); return a;") === 3); });
});

// --- Negative: parser correctly rejects malformed input ---

testGroup("Stmt Rejects", () => {
	test("const no init", () => { check(!programOk("const x;")); });
	test("const no name", () => { check(!programOk("const ;")); });
	test("if no parens", () => { check(!programOk("if x { }")); });
	test("while no parens", () => { check(!programOk("while x { }")); });
	test("function no name", () => { check(!programOk("function () {}")); });
	test("try alone", () => { check(!programOk("try {}")); });
});

// --- Smoke: stmt-level integration that exercises distinct paths ---

testGroup("Stmt Smoke", () => {
	// Block body with arrow
	test("arrow block body", () => { check(programOk("const f = () => { return 1; };")); });
	test("testGroup pattern", () => { check(programOk("testGroup(\"g\", () => { test(\"t\", () => { check(1); }); });")); });
	// Object/array in stmt context
	test("object in var", () => { check(programOk("const x = { a: 1, b: 2 };")); });
	test("createNode pattern", () => {
		check(programOk("const n = createNode(NodeKind.X, { operator: op, left: a, right: b }, tok);"));
	});
	// Template in stmt
	test("template interp", () => { check(programOk("const s = `line ${token.line.toString()}`;")); });
	// Type assertion in stmt
	test("as in var", () => { check(programOk("const data = node.data as { value: number };")); });
	// Regex literal in stmt
	test("regex in var", () => { check(programOk("const re = /[a-z]+/gi;")); });
	// Nested control flow
	test("nested control", () => { check(programOk("function f() { if (x) { while (y) { z; } } }")); });
	// Nested generic type annotations (>> and >>> splitting)
	test("nested generic type", () => { check(programOk("const x: Result<Array<number>> = f();")); });
	test("triple nested generic", () => { check(programOk("function f(x: Map<string, Result<Array<T>>>): void {}")); });
});

// --- Self-Parsing: realistic code patterns from the compiler itself ---

testGroup("Self-Parsing Smoke", () => {
	test("import + function + template", () => {
		check(programOk("import { Token } from \"./token\"; function f(s) { return `val: ${s}`; }"));
	});
	test("export re-export hub", () => {
		check(programOk("export { Node, NodeKind } from \"./node\"; export { printNode } from \"./printer\";"));
	});
	test("char classify pattern", () => {
		check(programOk("function isDigit(ch) { return ch >= \"0\".code && ch <= \"9\".code; }"));
	});
	test("enum + match dispatch", () => {
		check(programOk("enum K { A, B } function f(k) { return match (k) { K.A => 1, _ => 0 }; }"));
	});
	test("interface + type alias", () => {
		check(programOk("interface Token { kind: number; value: string; } type Tokens = Token[];"));
	});
	test("for-of loop", () => {
		check(programOk("function process(items) { for (const item of items) { console.log(item); } }"));
	});
	test("try-catch + throw", () => {
		check(programOk("function f() { try { throw \"error\"; } catch (e) { console.log(e); } }"));
	});
	test("complex parser pattern", () => {
		check(programOk("function parse(state) { const token = current(state); if (token.kind === TokenKind.Number) { advance(state); return Result.ok(createNode(NodeKind.Lit, { value: 42 }, token)); } return Result.err(`Unexpected: ${token.value}`); }"));
	});
	test("class declaration", () => {
		check(programOk("class Animal { name: string; constructor(n: string) { this.name = n; } speak() { return this.name; } }"));
	});
	test("defer in function", () => {
		check(programOk("function cleanup() { const fd = open(); defer close(fd); process(fd); }"));
	});
});

// --- Error Recovery: parser continues past errors and collects multiple ---

testGroup("Error Recovery", () => {
	// Single error still detected
	test("single error detected", () => { check(parseErrorCount("const = 1;") === 1); });
	// Two independent errors both collected
	test("two errors collected", () => { check(parseErrorCount("const = 1; const = 2;") === 2); });
	// Valid code has zero errors
	test("valid has no errors", () => { check(parseErrorCount("const x = 1; const y = 2;") === 0); });
	// Error between valid stmts: errors collected, not just first
	test("error between valid", () => { check(parseErrorCount("const x = 1; const = bad; const y = 2;") >= 1); });
	// Block-level recovery: error inside block doesn't prevent function parse
	test("block recovery", () => { check(parseErrorCount("function f() { const = 1; const y = 2; }") === 1); });
	// Panic mode: cascading errors from same malformed stmt count as 1
	test("panic suppression", () => { check(parseErrorCount("const ;") === 1); });
	// Sync at keyword boundary: error then valid if-stmt
	test("sync at keyword", () => { check(parseErrorCount("const = 1 if (x) {}") === 1); });
});

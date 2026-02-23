// Statement Parser Core - Dispatch, block/expr/program parsing
// Pattern: ~/projects/metascript/src/parser/parser.zig parseStatement()

import { Token, TokenKind } from "../../lexer/token";
import { Node, NodeKind, NodeData, createNode } from "../../ast/node";
import { ParserState, createState, current, advance, isAtEnd } from "../context";
import { parseExpressionFromState, registerBlockParser } from "../expressions/core";
import { parseIfStmt, parseWhileStmt, parseForStmt, parseBreakStmt, parseContinueStmt, parseReturnStmt, parseDoWhileStmt, parseSwitchStmt, parseDeferStmt } from "./control";
import { parseVariableDecl, parseFunctionDecl, parseImportDecl, parseExportDecl, parseTypeAliasDecl, parseEnumDecl, parseInterfaceDecl, parseClassDecl } from "./declaration";
import { parseThrowStmt, parseTryCatchStmt } from "./errorHandling";
import { registerStmtBlockParser, registerStmtExprParser, registerStmtParser, registerStmtProgramParser, programOk, stmtKind, stmtCount } from "./util";
import { test, check, testGroup } from "std/testing";

// Type aliases
type NodeResult = Result<Node, string>;
type NodesResult = Result<Node[], string>;

// ===== Statement Dispatch (match on TokenKind) =====

function parseStatement(state: ParserState): NodeResult {
	const token = current(state);
	match (token.kind) {
		TokenKind.Const | TokenKind.Let => {
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
		_ => {
			return parseExprStmt(state);
		},
	};
	return Result.err("unreachable");
}

// ===== Block Statement =====
// { stmt1; stmt2; ... }

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
		const stmt = try parseStatement(state);
		stmts.push(stmt);
	}

	if (current(state).kind === TokenKind.RBrace) {
		advance(state);
	}

	return Result.ok(createNode(NodeKind.BlockStmt, { statements: stmts }, lbrace));
}

// ===== Expression Statement =====
// expr;

function parseExprStmt(state: ParserState): NodeResult {
	const token = current(state);
	const expression = try parseExpressionFromState(state);
	if (!isAtEnd(state) && current(state).kind === TokenKind.Semicolon) {
		advance(state);
	}

	return Result.ok(createNode(NodeKind.ExprStmt, { expr: expression }, token));
}

// ===== Top-Level Program Parser =====

export function parseProgram(tokens: Token[]): NodesResult {
	const state = createState(tokens);
	const stmts: Node[] = [];
	while (!isAtEnd(state)) {
		if (current(state).kind === TokenKind.Semicolon) {
			advance(state);
			continue;
		}
		const stmt = try parseStatement(state);
		stmts.push(stmt);
	}

	return Result.ok(stmts);
}

// ===== Register callbacks for sub-modules =====
// Sub-modules call these via util.ms to avoid circular imports

registerStmtBlockParser((state: ParserState): NodeResult => { return parseBlockStmt(state); });
registerStmtExprParser((state: ParserState): NodeResult => { return parseExpressionFromState(state); });
registerStmtParser((state: ParserState): NodeResult => { return parseStatement(state); });
registerStmtProgramParser((tokens: Token[]): NodesResult => { return parseProgram(tokens); });

// Also register with expressions for arrow function block bodies
registerBlockParser((state: ParserState): NodeResult => { return parseBlockStmt(state); });

// ===== Core Tests =====

// --- Structural: verify dispatch produces correct node kinds ---

testGroup("Stmt Structure", () => {
	test("const is VariableDecl", () => { check(stmtKind("const x = 1;") === NodeKind.VariableDecl); });
	test("if is IfStmt", () => { check(stmtKind("if (x) {}") === NodeKind.IfStmt); });
	test("while is WhileStmt", () => { check(stmtKind("while (x) {}") === NodeKind.WhileStmt); });
	test("for is ForStmt", () => { check(stmtKind("for (let i = 0; i < n; i++) {}") === NodeKind.ForStmt); });
	test("for-of is ForOfStmt", () => { check(stmtKind("for (const x of items) {}") === NodeKind.ForOfStmt); });
	test("function is FunctionDecl", () => { check(stmtKind("function f() {}") === NodeKind.FunctionDecl); });
	test("import is ImportDecl", () => { check(stmtKind("import { x } from \"y\";") === NodeKind.ImportDecl); });
	test("export is ExportDecl", () => { check(stmtKind("export const x = 1;") === NodeKind.ExportDecl); });
	test("enum is EnumDecl", () => { check(stmtKind("enum X { A, B }") === NodeKind.EnumDecl); });
	test("interface is InterfaceDecl", () => { check(stmtKind("interface P { x: number; }") === NodeKind.InterfaceDecl); });
	test("class is ClassDecl", () => { check(stmtKind("class Foo {}") === NodeKind.ClassDecl); });
	test("defer is DeferStmt", () => { check(stmtKind("defer f();") === NodeKind.DeferStmt); });
	test("throw is ThrowStmt", () => { check(stmtKind("throw \"err\";") === NodeKind.ThrowStmt); });
	test("block is BlockStmt", () => { check(stmtKind("{ x; }") === NodeKind.BlockStmt); });
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
	// Nested control flow
	test("nested control", () => { check(programOk("function f() { if (x) { while (y) { z; } } }")); });
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

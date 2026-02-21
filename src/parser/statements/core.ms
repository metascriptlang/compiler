// Statement Parser Core - Dispatch, block/expr/program parsing
// Pattern: ~/projects/metascript/src/parser/parser.zig parseStatement()

import { Token, TokenKind } from "../../lexer/token";
import { Node, NodeKind, NodeData, createNode } from "../../ast/node";
import { ParserState, createState, current, advance, isAtEnd } from "../context";
import { parseExpressionFromState, registerBlockParser } from "../expressions/core";
import { parseIfStmt, parseWhileStmt, parseForStmt, parseBreakStmt, parseContinueStmt, parseReturnStmt } from "./control";
import { parseVariableDecl, parseFunctionDecl, parseImportDecl, parseExportDecl, parseTypeAliasDecl, parseEnumDecl, parseInterfaceDecl } from "./declaration";
import { parseThrowStmt, parseTryCatchStmt } from "./errorHandling";
import { registerStmtBlockParser, registerStmtExprParser, registerStmtProgramParser, programOk } from "./util";
import { test, check, testGroup } from "std/testing";

// Type aliases
type Nodes = Node[];
type NodeResult = Result<Node, string>;
type NodesResult = Result<Nodes, string>;

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
registerStmtProgramParser((tokens: Token[]): NodesResult => { return parseProgram(tokens); });

// Also register with expressions for arrow function block bodies
registerBlockParser((state: ParserState): NodeResult => { return parseBlockStmt(state); });

// ===== Core Tests =====

testGroup("Stmt Expression Statements", () => {
	test("ident expr stmt", () => { check(programOk("x;")); });
	test("call expr stmt", () => { check(programOk("f(x);")); });
	test("member expr stmt", () => { check(programOk("a.b;")); });
	test("binary expr stmt", () => { check(programOk("a + b;")); });
});

testGroup("Stmt Blocks & Nesting", () => {
	test("empty block", () => { check(programOk("{ }")); });
	test("block with stmt", () => { check(programOk("{ x; }")); });
	test("block with multiple stmts", () => { check(programOk("{ x; y; z; }")); });
	test("deeply nested blocks", () => { check(programOk("{ { { x; } } }")); });
	test("nested control flow", () => { check(programOk("function f() { if (x) { while (y) { z; } } }")); });
});

testGroup("Stmt Multiple & Semicolons", () => {
	test("two const decls", () => { check(programOk("const x = 1; const y = 2;")); });
	test("decl then expr", () => { check(programOk("const x = 1; x;")); });
	test("two functions", () => { check(programOk("function f() {} function g() {}")); });
	test("bare semicolons", () => { check(programOk(";;;")); });
	test("extra semicolons", () => { check(programOk("x;; y;;")); });
	test("semicolons between decls", () => { check(programOk("const x = 1; ; const y = 2;")); });
});

testGroup("Stmt Object/Array Literals", () => {
	test("object in var init", () => { check(programOk("const x = { a: 1, b: 2 };")); });
	test("shorthand in var", () => { check(programOk("const obj = { name };")); });
	test("array in var init", () => { check(programOk("const arr = [1, 2, 3];")); });
	test("empty array init", () => { check(programOk("const arr = [];")); });
	test("object in call arg", () => { check(programOk("f({ x: 1 });")); });
	test("array in call arg", () => { check(programOk("f([a, b]);")); });
	test("return object", () => { check(programOk("function f() { return { x: 1 }; }")); });
	test("return array", () => { check(programOk("function f() { return [1, 2]; }")); });
	test("createNode pattern", () => {
		check(programOk("const n = createNode(NodeKind.X, { operator: op, left: a, right: b }, tok);"));
	});
});

testGroup("Stmt Error Cases", () => {
	test("missing name in decl", () => { check(!programOk("const ;")); });
	test("missing = in decl", () => { check(!programOk("const x ;")); });
	test("missing parens in if", () => { check(!programOk("if x { }")); });
	test("missing parens in while", () => { check(!programOk("while x { }")); });
	test("missing function name", () => { check(!programOk("function () {}")); });
});

testGroup("Stmt Arrow Functions", () => {
	test("empty block body", () => { check(programOk("const f = () => {};")); });
	test("block with stmt", () => { check(programOk("const f = () => { x; };")); });
	test("block with return", () => { check(programOk("const f = (x) => { return x + 1; };")); });
	test("block multi stmts", () => { check(programOk("const f = (a, b) => { const sum = a + b; return sum; };")); });
	test("block with if", () => { check(programOk("const f = (x) => { if (x) { return 1; } return 0; };")); });
	test("test callback", () => { check(programOk("test(\"name\", () => { check(true); });")); });
	test("testGroup pattern", () => { check(programOk("testGroup(\"group\", () => { test(\"t\", () => { check(1); }); });")); });
	test("expr body in stmt", () => { check(programOk("const f = (x) => x + 1;")); });
	test("arrow in var then use", () => { check(programOk("const f = (x) => x; f(42);")); });
	test("two params block", () => { check(programOk("const f = (a, b) => { return a + b; };")); });
});

testGroup("Stmt Type Assertions", () => {
	test("as in var init", () => { check(programOk("const data = node.data as { value: number };")); });
	test("as then member", () => { check(programOk("const v = (node.data as { value: number }).value;")); });
	test("printer pattern", () => { check(programOk("const data = node.data as { name: string }; console.log(data.name);")); });
});

testGroup("Stmt Template Literals", () => {
	test("template in var", () => { check(programOk("const msg = `hello`;")); });
	test("template with interp in var", () => { check(programOk("const msg = `hello ${name}`;")); });
	test("template in call", () => { check(programOk("console.log(`value: ${x}`);")); });
	test("template method chain", () => { check(programOk("const s = `line ${token.line.toString()}`;")); });
	test("template in return", () => { check(programOk("function f(x) { return `result: ${x}`; }")); });
	test("error msg pattern", () => { check(programOk("return Result.err(`Expected ')' at line ${current(state).line.toString()}`);")); });
	test("multi interp stmt", () => { check(programOk("const s = `${a} + ${b} = ${c}`;")); });
});

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
});

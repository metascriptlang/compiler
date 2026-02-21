// Statement Parser - Modern MetaScript patterns (match/try/Result)
// Pattern: ~/projects/metascript/src/parser/parser.zig parseStatement()

import { Token, TokenKind } from "../lexer/token";
import { Node, NodeKind, NodeData, createNode } from "../ast/node";
import { ParserState, createState, current, advance, isAtEnd } from "./context";
import { parseExpressionFromState, registerBlockParser } from "./expressions/core";
import { skipTypeAnnotation } from "./typeAnnotation";
import { lex } from "../lexer/lexer";
import { test, check, testGroup } from "std/testing";

// Type aliases: Node[] inside Result<> causes parser ambiguity; also reduces repetition
type Nodes = Node[];
type NodeResult = Result<Node, string>;
type NodesResult = Result<Nodes, string>;

// Register block parser for arrow function block bodies (breaks circular dep)
registerBlockParser((state: ParserState): NodeResult => { return parseBlockStmt(state); });

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
		_ => {
			return parseExprStmt(state);
		},
	};
	return Result.err("unreachable");
}

// ===== Variable Declaration =====
// const x = expr; | const x: Type = expr;

function parseVariableDecl(state: ParserState): NodeResult {
	const keyword = current(state);
	advance(state);
	const nameToken = current(state);
	if (nameToken.kind !== TokenKind.Ident) {
		return Result.err(`Expected identifier after ${keyword.value} at line ${nameToken.line.toString()}`);
	}

	advance(state);
	// Optional type annotation: const x: number = ...
	if (!isAtEnd(state) && current(state).kind === TokenKind.Colon) {
		advance(state);
		skipTypeAnnotation(state);
	}

	if (current(state).kind !== TokenKind.Assign) {
		return Result.err(`Expected '=' in variable declaration at line ${current(state).line.toString()}`);
	}

	advance(state);
	const init = try parseExpressionFromState(state);
	if (!isAtEnd(state) && current(state).kind === TokenKind.Semicolon) {
		advance(state);
	}

	return Result.ok(createNode(NodeKind.VariableDecl, {
		declName: nameToken.value,
		initializer: init,
		isConst: keyword.kind === TokenKind.Const,
	}, keyword));
}

// ===== If Statement =====
// if (condition) { ... } [else [if (...)] { ... }]

function parseIfStmt(state: ParserState): NodeResult {
	const ifToken = current(state);
	advance(state);
	if (current(state).kind !== TokenKind.LParen) {
		return Result.err(`Expected '(' after 'if' at line ${current(state).line.toString()}`);
	}

	advance(state);
	const condition = try parseExpressionFromState(state);
	if (current(state).kind !== TokenKind.RParen) {
		return Result.err(`Expected ')' after if condition at line ${current(state).line.toString()}`);
	}

	advance(state);
	const consequent = try parseBlockStmt(state);
	// Handle else branch: early return avoids try-in-assignment
	if (!isAtEnd(state) && current(state).kind === TokenKind.Else) {
		advance(state);
		if (current(state).kind === TokenKind.If) {
			return Result.ok(createNode(NodeKind.IfStmt, {
				condition,
				consequent,
				alternate: try parseIfStmt(state),
			}, ifToken));
		}

		return Result.ok(createNode(NodeKind.IfStmt, {
			condition,
			consequent,
			alternate: try parseBlockStmt(state),
		}, ifToken));
	}

	return Result.ok(createNode(NodeKind.IfStmt, {
		condition,
		consequent,
		alternate: createNode(NodeKind.BlockStmt, { statements: [] }, ifToken),
	}, ifToken));
}

// ===== While Statement =====
// while (condition) { ... }

function parseWhileStmt(state: ParserState): NodeResult {
	const whileToken = current(state);
	advance(state);
	if (current(state).kind !== TokenKind.LParen) {
		return Result.err(`Expected '(' after 'while' at line ${current(state).line.toString()}`);
	}

	advance(state);
	const condition = try parseExpressionFromState(state);
	if (current(state).kind !== TokenKind.RParen) {
		return Result.err(`Expected ')' after while condition at line ${current(state).line.toString()}`);
	}

	advance(state);
	return Result.ok(createNode(NodeKind.WhileStmt, {
		whileCondition: condition,
		whileBody: try parseBlockStmt(state),
	}, whileToken));
}

// ===== For Statement =====
// for (let i = 0; i < n; i++) { ... }
// for (const item of items) { ... }

function parseForStmt(state: ParserState): NodeResult {
	const forToken = current(state);
	advance(state);
	if (current(state).kind !== TokenKind.LParen) {
		return Result.err(`Expected '(' after 'for' at line ${current(state).line.toString()}`);
	}

	advance(state);
	// Check for for-of: for (const/let x of expr)
	const bindingToken = current(state);
	if (bindingToken.kind === TokenKind.Const || bindingToken.kind === TokenKind.Let) {
		const forIsConst = bindingToken.kind === TokenKind.Const;
		advance(state);

		const nameToken = current(state);
		if (nameToken.kind === TokenKind.Ident) {
			// Peek ahead: is this "name of" (for-of) or "name =" (C-style for)?
			const afterName = state.position + 1;
			if (afterName < state.tokens.length && state.tokens[afterName].kind === TokenKind.Of) {
				// for-of loop
				advance(state); // consume name
				advance(state); // consume 'of'
				const iterable = try parseExpressionFromState(state);
				if (current(state).kind !== TokenKind.RParen) {
					return Result.err(`Expected ')' after for-of iterable at line ${current(state).line.toString()}`);
				}

				advance(state);
				return Result.ok(createNode(NodeKind.ForOfStmt, {
					forOfBinding: nameToken.value,
					forOfIsConst: forIsConst,
					forOfIterable: iterable,
					forOfBody: try parseBlockStmt(state),
				}, forToken));
			}
		}

		// C-style for with variable declaration: for (let i = 0; ...)
		const varName = current(state);
		if (varName.kind !== TokenKind.Ident) {
			return Result.err(`Expected variable name in for init at line ${varName.line.toString()}`);
		}

		advance(state);
		// Optional type annotation
		if (!isAtEnd(state) && current(state).kind === TokenKind.Colon) {
			advance(state);
			skipTypeAnnotation(state);
		}

		if (current(state).kind !== TokenKind.Assign) {
			return Result.err(`Expected '=' in for init at line ${current(state).line.toString()}`);
		}
	
		advance(state);
		const initNode = createNode(NodeKind.VariableDecl, {
			declName: varName.value,
			initializer: try parseExpressionFromState(state),
			isConst: forIsConst
		}, bindingToken);
		if (current(state).kind !== TokenKind.Semicolon) {
			return Result.err(`Expected ';' after for init at line ${current(state).line.toString()}`);
		}

		advance(state);
		const cond = try parseExpressionFromState(state);
		if (current(state).kind !== TokenKind.Semicolon) {
			return Result.err(`Expected ';' after for condition at line ${current(state).line.toString()}`);
		}

		advance(state);
		const update = try parseExpressionFromState(state);
		if (current(state).kind !== TokenKind.RParen) {
			return Result.err(`Expected ')' after for clauses at line ${current(state).line.toString()}`);
		}

		advance(state);
		return Result.ok(createNode(NodeKind.ForStmt, {
			forInit: initNode,
			forCondition: cond,
			forUpdate: update,
			forBody: try parseBlockStmt(state),
		}, forToken));
	}

	// C-style for with expression init: for (i = 0; ...)
	const exprInit = try parseExpressionFromState(state);
	const exprInitNode = createNode(NodeKind.ExprStmt, { expr: exprInit }, forToken);
	if (current(state).kind !== TokenKind.Semicolon) {
		return Result.err(`Expected ';' after for init at line ${current(state).line.toString()}`);
	}

	advance(state);
	const exprCond = try parseExpressionFromState(state);
	if (current(state).kind !== TokenKind.Semicolon) {
		return Result.err(`Expected ';' after for condition at line ${current(state).line.toString()}`);
	}

	advance(state);
	const exprUpdate = try parseExpressionFromState(state);
	if (current(state).kind !== TokenKind.RParen) {
		return Result.err(`Expected ')' after for clauses at line ${current(state).line.toString()}`);
	}

	advance(state);
	return Result.ok(createNode(NodeKind.ForStmt, {
		forInit: exprInitNode,
		forCondition: exprCond,
		forUpdate: exprUpdate,
		forBody: try parseBlockStmt(state),
	}, forToken));
}

// ===== Break / Continue =====

function parseBreakStmt(state: ParserState): NodeResult {
	const token = current(state);
	advance(state);
	if (!isAtEnd(state) && current(state).kind === TokenKind.Semicolon) {
		advance(state);
	}
	return Result.ok(createNode(NodeKind.BreakStmt, { breakLabel: "" }, token));
}

function parseContinueStmt(state: ParserState): NodeResult {
	const token = current(state);
	advance(state);
	if (!isAtEnd(state) && current(state).kind === TokenKind.Semicolon) {
		advance(state);
	}
	return Result.ok(createNode(NodeKind.ContinueStmt, { continueLabel: "" }, token));
}

// ===== Return Statement =====
// return expr;

function parseReturnStmt(state: ParserState): NodeResult {
	const retToken = current(state);
	advance(state);
	const value = try parseExpressionFromState(state);
	if (!isAtEnd(state) && current(state).kind === TokenKind.Semicolon) {
		advance(state);
	}
	return Result.ok(createNode(NodeKind.ReturnStmt, { argument: value }, retToken));
}

// ===== Function Declaration =====
// function name(a: T, b: U): R { ... }

function parseFunctionDecl(state: ParserState): NodeResult {
	const fnToken = current(state);
	advance(state);
	const nameToken = current(state);
	if (nameToken.kind !== TokenKind.Ident) {
		return Result.err(`Expected function name at line ${nameToken.line.toString()}`);
	}

	advance(state);
	if (current(state).kind !== TokenKind.LParen) {
		return Result.err(`Expected '(' after function name at line ${current(state).line.toString()}`);
	}

	advance(state);
	const params: string[] = [];
	while (!isAtEnd(state) && current(state).kind !== TokenKind.RParen) {
		const param = current(state);
		if (param.kind !== TokenKind.Ident) {
			return Result.err(`Expected parameter name at line ${param.line.toString()}`);
		}
		params.push(param.value);
		advance(state);

		// Optional param type annotation: (a: string, b: number)
		if (!isAtEnd(state) && current(state).kind === TokenKind.Colon) {
			advance(state);
			skipTypeAnnotation(state);
		}

		if (current(state).kind === TokenKind.Comma) {
			advance(state);
		} else {
			break;
		}
	}

	if (current(state).kind !== TokenKind.RParen) {
		return Result.err(`Expected ')' after parameters at line ${current(state).line.toString()}`);
	}

	advance(state);
	// Optional return type annotation: function f(): string { ... }
	if (!isAtEnd(state) && current(state).kind === TokenKind.Colon) {
		advance(state);
		skipTypeAnnotation(state);
	}

	return Result.ok(createNode(NodeKind.FunctionDecl, {
		fnName: nameToken.value,
		params,
		fnBody: try parseBlockStmt(state),
	}, fnToken));
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

// ===== Test Helpers =====

function programOk(input: string): boolean {
	const lr = lex(input);
	if (!lr.ok) return false;
	const pr = parseProgram(lr.value);
	return pr.ok;
}

// ===== Statement Parser Tests =====

testGroup("Stmt Variable Declarations", () => {
	test("const decl", () => { check(programOk("const x = 42;")); });
	test("let decl", () => { check(programOk("let y = 0;")); });
	test("string decl", () => { check(programOk("const s = \"hello\";")); });
	test("expr decl", () => { check(programOk("const a = 1 + 2 * 3;")); });
	test("call decl", () => { check(programOk("const x = f(a, b);")); });
	test("member decl", () => { check(programOk("const x = a.b.c;")); });
});

testGroup("Stmt If/Else", () => {
	test("simple if", () => { check(programOk("if (x) { y; }")); });
	test("if-else", () => { check(programOk("if (x) { a; } else { b; }")); });
	test("if-else-if-else", () => { check(programOk("if (a) { x; } else if (b) { y; } else { z; }")); });
	test("nested if", () => { check(programOk("if (a) { if (b) { c; } }")); });
	test("comparison condition", () => { check(programOk("if (a === b) { x; }")); });
	test("call condition", () => { check(programOk("if (f(x)) { y; }")); });
});

testGroup("Stmt While", () => {
	test("simple while", () => { check(programOk("while (x) { y; }")); });
	test("comparison while", () => { check(programOk("while (i < 10) { i; }")); });
});

testGroup("Stmt Functions", () => {
	test("empty function", () => { check(programOk("function f() { }")); });
	test("single param", () => { check(programOk("function f(a) { return a; }")); });
	test("two params", () => { check(programOk("function add(a, b) { return a + b; }")); });
	test("three params", () => { check(programOk("function f(a, b, c) { return a; }")); });
	test("multi-statement body", () => { check(programOk("function f() { const x = 1; return x; }")); });
});

testGroup("Stmt Return", () => {
	test("return number", () => { check(programOk("function f() { return 42; }")); });
	test("return expr", () => { check(programOk("function f(x) { return x + 1; }")); });
	test("return call", () => { check(programOk("function f(a, b) { return a.method(b); }")); });
});

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

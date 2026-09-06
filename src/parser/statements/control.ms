// Control Flow Statements - if, while, for, break, continue, return
// Uses callback injection via util.ms to avoid circular imports

import { TokenKind } from "../../lexer/token";
import { Node, NodeKind, DeclKind, StringLiteralData, createNode, makeLoc } from "../../ast/node";
import { ParserState, current, advance, isAtEnd, consumeSemicolon } from "../context";
import { skipOptionalType, isIdentLike } from "../util";
import { callBlockParser, callExprParser, callStmtParser } from "./callbacks";
import { parseArrayPattern, parseObjectPattern } from "./declaration";
import { programOk, stmtKind } from "./validation";


type NodeResult = Result<Node, string>;

// ===== Body: block or single statement =====
// if (x) doSomething(); — wraps single stmt in BlockStmt for uniform downstream handling

function parseBodyOrStmt(state: ParserState): NodeResult {
	if (current(state).kind == TokenKind.LBrace) {
		return callBlockParser(state);
	}
	const tok = current(state);
	const stmt = try callStmtParser(state);
	return Result.ok(createNode(NodeKind.BlockStmt, { statements: [stmt] }, tok));
}

// ===== If Statement =====
// syntax: 'if' '(' expr ')' (block | stmt) ('else' (ifStmt | block | stmt))?

export function parseIfStmt(state: ParserState): NodeResult {
	const ifToken = current(state);
	advance(state);
	if (current(state).kind != TokenKind.LParen) {
		return Result.err(`Expected '(' after 'if' at line ${current(state).line}`);
	}

	advance(state);
	const condition = try callExprParser(state);
	if (current(state).kind != TokenKind.RParen) {
		return Result.err(`Expected ')' after if condition at line ${current(state).line}`);
	}

	advance(state);
	const consequent = try parseBodyOrStmt(state);
	// Handle else branch: early return avoids try-in-assignment
	if (!isAtEnd(state) && current(state).kind == TokenKind.Else) {
		advance(state);
		if (current(state).kind == TokenKind.If) {
			return Result.ok(createNode(NodeKind.IfStmt, {
				condition,
				consequent,
				alternate: try parseIfStmt(state),
			}, ifToken));
		}

		return Result.ok(createNode(NodeKind.IfStmt, {
			condition,
			consequent,
			alternate: try parseBodyOrStmt(state),
		}, ifToken));
	}

	return Result.ok(createNode(NodeKind.IfStmt, {
		condition,
		consequent,
		alternate: createNode(NodeKind.BlockStmt, { statements: [] }, ifToken),
	}, ifToken));
}

// ===== While Statement =====
// syntax: 'while' '(' expr ')' block

export function parseWhileStmt(state: ParserState): NodeResult {
	const whileToken = current(state);
	advance(state);
	if (current(state).kind != TokenKind.LParen) {
		return Result.err(`Expected '(' after 'while' at line ${current(state).line}`);
	}

	advance(state);
	const condition = try callExprParser(state);
	if (current(state).kind != TokenKind.RParen) {
		return Result.err(`Expected ')' after while condition at line ${current(state).line}`);
	}

	advance(state);
	return Result.ok(createNode(NodeKind.WhileStmt, {
		whileCondition: condition,
		whileBody: try parseBodyOrStmt(state),
		whileLabel: "",
	}, whileToken));
}

// ===== For Statement =====
// syntax: for '(' (let|const) ID '=' expr ';' expr ';' expr ')' block
//       | for '(' (let|const) ID 'of' expr ')' block
//       | for '(' (let|const) ID 'in' expr ')' block

export function parseForStmt(state: ParserState): NodeResult {
	const forToken = current(state);
	advance(state);
	if (current(state).kind != TokenKind.LParen) {
		return Result.err(`Expected '(' after 'for' at line ${current(state).line}`);
	}

	advance(state);
	// Check for for-of: for (const/let x of expr) or for (const/let { } of expr)
	const bindingToken = current(state);
	if (bindingToken.kind == TokenKind.Const || bindingToken.kind == TokenKind.Let || bindingToken.kind == TokenKind.Var) {
		const forIsConst = bindingToken.kind == TokenKind.Const;
		advance(state);

		// Destructured for-of: for (const [a, b] of items) or for (const { a, b } of items)
		if (current(state).kind == TokenKind.LBracket || current(state).kind == TokenKind.LBrace) {
			let pattern: Node = null as unknown as Node;
			if (current(state).kind == TokenKind.LBracket) {
				pattern = try parseArrayPattern(state);
			} else {
				pattern = try parseObjectPattern(state);
			}
			// Now expect 'of' or 'in'
			if (!isAtEnd(state) && current(state).kind == TokenKind.Of) {
				advance(state); // consume 'of'
				const iterable = try callExprParser(state);
				if (current(state).kind != TokenKind.RParen) {
					return Result.err(`Expected ')' after for-of iterable at line ${current(state).line}`);
				}
				advance(state);
				return Result.ok(createNode(NodeKind.ForOfStmt, {
					forOfBinding: "_destructure",
					forOfIsConst: forIsConst,
					forOfIterable: iterable,
					forOfBody: try parseBodyOrStmt(state),
					forOfPattern: pattern,
					bindingLocation: makeLoc(forToken.line, forToken.column),
					forOfLabel: "",
				}, forToken));
			}
			if (!isAtEnd(state) && current(state).kind == TokenKind.In) {
				advance(state); // consume 'in'
				const obj = try callExprParser(state);
				if (current(state).kind != TokenKind.RParen) {
					return Result.err(`Expected ')' after for-in object at line ${current(state).line}`);
				}
				advance(state);
				return Result.ok(createNode(NodeKind.ForInStmt, {
					forInBinding: "_destructure",
					forInIsConst: forIsConst,
					forInObject: obj,
					forInBody: try parseBodyOrStmt(state),
					forInLabel: "",
				}, forToken));
			}
			return Result.err(`Expected 'of' or 'in' after destructuring pattern at line ${current(state).line}`);
		}

		const nameToken = current(state);
		if (isIdentLike(nameToken)) {
			// Peek ahead: is this "name of" (for-of), "name in" (for-in), or "name =" (C-style for)?
			const afterName = state.position + 1;
			if (afterName < state.tokens.length && state.tokens[afterName].kind == TokenKind.Of) {
				// for-of loop
				advance(state); // consume name
				advance(state); // consume 'of'
				const iterable = try callExprParser(state);
				if (current(state).kind != TokenKind.RParen) {
					return Result.err(`Expected ')' after for-of iterable at line ${current(state).line}`);
				}

				advance(state);
				return Result.ok(createNode(NodeKind.ForOfStmt, {
					forOfBinding: nameToken.value,
					forOfIsConst: forIsConst,
					forOfIterable: iterable,
					forOfBody: try parseBodyOrStmt(state),
					forOfPattern: null as unknown as Node,
					bindingLocation: makeLoc(nameToken.line, nameToken.column),
					forOfLabel: "",
				}, forToken));
			}
			if (afterName < state.tokens.length && state.tokens[afterName].kind == TokenKind.In) {
				// for-in loop
				advance(state); // consume name
				advance(state); // consume 'in'
				const obj = try callExprParser(state);
				if (current(state).kind != TokenKind.RParen) {
					return Result.err(`Expected ')' after for-in object at line ${current(state).line}`);
				}

				advance(state);
				return Result.ok(createNode(NodeKind.ForInStmt, {
					forInBinding: nameToken.value,
					forInIsConst: forIsConst,
					forInObject: obj,
					forInBody: try parseBodyOrStmt(state),
					forInLabel: "",
				}, forToken));
			}
		}

		// C-style for with variable declaration: for (let i = 0; ...)
		const varName = current(state);
		if (!isIdentLike(varName)) {
			return Result.err(`Expected variable name in for init at line ${varName.line}`);
		}

		advance(state);
		// Optional type annotation
		skipOptionalType(state);

		if (current(state).kind != TokenKind.Assign) {
			return Result.err(`Expected '=' in for init at line ${current(state).line}`);
		}

		advance(state);
		const initNode = createNode(NodeKind.VariableDecl, {
			declName: varName.value,
			declType: "",
			initializer: try callExprParser(state),
			declKind: match (bindingToken.kind) { TokenKind.Const => DeclKind.Const, TokenKind.Var => DeclKind.Var, _ => DeclKind.Let },
			nameLocation: makeLoc(varName.line, varName.column),
		}, bindingToken);
		if (current(state).kind != TokenKind.Semicolon) {
			return Result.err(`Expected ';' after for init at line ${current(state).line}`);
		}

		advance(state);
		const cond = try callExprParser(state);
		if (current(state).kind != TokenKind.Semicolon) {
			return Result.err(`Expected ';' after for condition at line ${current(state).line}`);
		}

		advance(state);
		const update = try callExprParser(state);
		if (current(state).kind != TokenKind.RParen) {
			return Result.err(`Expected ')' after for clauses at line ${current(state).line}`);
		}

		advance(state);
		return Result.ok(createNode(NodeKind.ForStmt, {
			forInit: initNode,
			forCondition: cond,
			forUpdate: update,
			forBody: try parseBodyOrStmt(state),
			forLabel: "",
		}, forToken));
	}

	// C-style for with expression init: for (i = 0; ...)
	const exprInit = try callExprParser(state);
	const exprInitNode = createNode(NodeKind.ExprStmt, { expr: exprInit }, forToken);
	if (current(state).kind != TokenKind.Semicolon) {
		return Result.err(`Expected ';' after for init at line ${current(state).line}`);
	}

	advance(state);
	const exprCond = try callExprParser(state);
	if (current(state).kind != TokenKind.Semicolon) {
		return Result.err(`Expected ';' after for condition at line ${current(state).line}`);
	}

	advance(state);
	const exprUpdate = try callExprParser(state);
	if (current(state).kind != TokenKind.RParen) {
		return Result.err(`Expected ')' after for clauses at line ${current(state).line}`);
	}

	advance(state);
	return Result.ok(createNode(NodeKind.ForStmt, {
		forInit: exprInitNode,
		forCondition: exprCond,
		forUpdate: exprUpdate,
		forBody: try parseBodyOrStmt(state),
		forLabel: "",
	}, forToken));
}

// ===== Break / Continue =====
// syntax: 'break' ';' | 'continue' ';'

export function parseBreakStmt(state: ParserState): NodeResult {
	const token = current(state);
	advance(state);
	consumeSemicolon(state);
	return Result.ok(createNode(NodeKind.BreakStmt, { breakLabel: "" }, token));
}

export function parseContinueStmt(state: ParserState): NodeResult {
	const token = current(state);
	advance(state);
	consumeSemicolon(state);
	return Result.ok(createNode(NodeKind.ContinueStmt, { continueLabel: "" }, token));
}

// ===== Return Statement =====
// syntax: 'return' expr? ';'

export function parseReturnStmt(state: ParserState): NodeResult {
	const retToken = current(state);
	advance(state);
	// Bare return (no expression): return; or return at end of block
	if (!isAtEnd(state) && (current(state).kind == TokenKind.Semicolon || current(state).kind == TokenKind.RBrace)) {
		if (current(state).kind == TokenKind.Semicolon) {
			consumeSemicolon(state);
		}
		return Result.ok(createNode(NodeKind.ReturnStmt, { argument: null as unknown as Node }, retToken));
	}
	const value = try callExprParser(state);
	consumeSemicolon(state);
	return Result.ok(createNode(NodeKind.ReturnStmt, { argument: value }, retToken));
}

// ===== Do-While Statement =====
// do { body } while (condition);

export function parseDoWhileStmt(state: ParserState): NodeResult {
	const doToken = current(state);
	advance(state); // consume 'do'
	const body = try callBlockParser(state);

	if (isAtEnd(state) || current(state).kind != TokenKind.While) {
		return Result.err(`Expected 'while' after 'do' body at line ${doToken.line}`);
	}

	advance(state); // consume 'while'
	if (current(state).kind != TokenKind.LParen) {
		return Result.err(`Expected '(' after 'while' in do-while at line ${current(state).line}`);
	}

	advance(state);
	const condition = try callExprParser(state);
	if (current(state).kind != TokenKind.RParen) {
		return Result.err(`Expected ')' after do-while condition at line ${current(state).line}`);
	}

	advance(state);
	consumeSemicolon(state);

	return Result.ok(createNode(NodeKind.DoWhileStmt, {
		doBody: body,
		doCondition: condition,
		dwLabel: "",
		dwSwitchWrapper: false,
	}, doToken));
}

// ===== Switch Statement =====
// switch (expr) { case val: stmts... [break;] default: stmts... }

export function parseSwitchStmt(state: ParserState): NodeResult {
	const switchToken = current(state);
	advance(state); // consume 'switch'

	if (current(state).kind != TokenKind.LParen) {
		return Result.err(`Expected '(' after 'switch' at line ${current(state).line}`);
	}

	advance(state);
	const disc = try callExprParser(state);
	if (current(state).kind != TokenKind.RParen) {
		return Result.err(`Expected ')' after switch discriminant at line ${current(state).line}`);
	}

	advance(state);
	if (current(state).kind != TokenKind.LBrace) {
		return Result.err(`Expected '{' to start switch body at line ${current(state).line}`);
	}

	advance(state);
	const cases: Node[] = [];
	while (!isAtEnd(state) && current(state).kind != TokenKind.RBrace) {
		const caseNode = try parseSwitchCase(state);
		cases.push(caseNode);
	}

	if (current(state).kind == TokenKind.RBrace) {
		advance(state);
	}

	return Result.ok(createNode(NodeKind.SwitchStmt, {
		switchDisc: disc,
		switchCases: cases,
		switchLowered: false,
	}, switchToken));
}

function parseSwitchCase(state: ParserState): NodeResult {
	const caseToken = current(state);

	if (caseToken.kind == TokenKind.Default) {
		advance(state); // consume 'default'
		if (current(state).kind == TokenKind.Colon) {
			advance(state);
		}
		const stmts = try parseCaseBody(state);
		return Result.ok(createNode(NodeKind.SwitchCase, {
			caseTests: [],
			caseStmts: stmts,
			isDefault: true,
		}, caseToken));
	}

	if (caseToken.kind != TokenKind.Case) {
		return Result.err(`Expected 'case' or 'default' in switch at line ${caseToken.line}`);
	}

	advance(state); // consume 'case'
	const tests: Node[] = [];
	const firstTest = try callExprParser(state);
	tests.push(firstTest);
	if (current(state).kind == TokenKind.Colon) {
		advance(state);
	}

	const stmts = try parseCaseBody(state);
	return Result.ok(createNode(NodeKind.SwitchCase, {
		caseTests: tests,
		caseStmts: stmts,
		isDefault: false,
	}, caseToken));
}

type NodesResult = Result<Node[], string>;

function parseCaseBody(state: ParserState): NodesResult {
	const stmts: Node[] = [];
	while (!isAtEnd(state) &&
		current(state).kind != TokenKind.Case &&
		current(state).kind != TokenKind.Default &&
		current(state).kind != TokenKind.RBrace) {
		if (current(state).kind == TokenKind.Semicolon) {
			advance(state);
			continue;
		}
		// Use callBlockParser for block statements, callExprParser for expressions
		// But we need the full statement parser here. Use the registered stmt parser.
		const stmt = try callStmtParser(state);
		stmts.push(stmt);
	}
	return Result.ok(stmts);
}

// ===== Defer Statement =====
// defer expr; or defer { block }

export function parseDeferStmt(state: ParserState): NodeResult {
	const deferToken = current(state);
	advance(state);
	if (!isAtEnd(state) && current(state).kind == TokenKind.LBrace) {
		const body = try callBlockParser(state);
		return Result.ok(createNode(NodeKind.DeferStmt, { deferExpr: body }, deferToken));
	}
	const deferVal = try callExprParser(state);
	consumeSemicolon(state);
	return Result.ok(createNode(NodeKind.DeferStmt, { deferExpr: deferVal }, deferToken));
}

// ===== Unreachable Statement =====
// unreachable; or unreachable("message");

export function parseUnreachableStmt(state: ParserState): NodeResult {
	const unreachableToken = current(state);
	advance(state);
	let msg = "";
	if (!isAtEnd(state) && current(state).kind == TokenKind.LParen) {
		advance(state);
		if (!isAtEnd(state) && current(state).kind == TokenKind.String) {
			msg = current(state).value;
			advance(state);
		}
		if (!isAtEnd(state) && current(state).kind == TokenKind.RParen) {
			advance(state);
		}
	}
	consumeSemicolon(state);
	return Result.ok(createNode(NodeKind.UnreachableStmt, { unreachableMsg: msg }, unreachableToken));
}

// ===== Test Declaration =====
// syntax: 'test' StringLiteral Block

export function parseTestDecl(state: ParserState): NodeResult {
	const testToken = current(state);
	advance(state); // consume 'test'

	if (isAtEnd(state) || current(state).kind != TokenKind.String) {
		return Result.err(`Expected string literal after 'test' at line ${testToken.line}`);
	}
	const name = current(state).value;
	advance(state); // consume string

	const body = try callBlockParser(state);
	return Result.ok(createNode(NodeKind.TestDecl, { testName: name, testBody: body }, testToken));
}

// ===== Assert Statement =====
// syntax: 'assert' expr ';'
//       | 'assert' expr ':' stringLiteral ';'
// Captures source text of the expression for power assert output.
// Optional `: "message"` provides a custom failure message.

export function parseAssertStmt(state: ParserState): NodeResult {
	const assertToken = current(state);
	advance(state); // consume 'assert'

	// Record token range to reconstruct source text
	const startPos = state.position;
	const assertExpr = try callExprParser(state);
	const endPos = state.position;

	// Reconstruct source text from tokens
	let source = "";
	for (let i = startPos; i < endPos; i += 1) {
		if (i > startPos) source = source + " ";
		source = source + state.tokens[i].value;
	}

	// Optional message: assert expr, <message expression>;
	// A string literal takes the static fast path; any other expression is evaluated at runtime.
	let message = "";
	let messageExpr: Node | null = null;
	if (!isAtEnd(state) && current(state).kind == TokenKind.Comma) {
		advance(state); // consume ','
		const msgNode = try callExprParser(state);
		if (msgNode.kind == NodeKind.StringLiteral) {
			message = (msgNode.data as StringLiteralData).value;
		} else {
			messageExpr = msgNode;
		}
	}

	consumeSemicolon(state);
	return Result.ok(createNode(NodeKind.AssertStmt, { assertExpr, assertSource: source, assertMessage: message, assertMessageExpr: messageExpr }, assertToken));
}

// ===== Tests =====

import { ProgramData, AssertStmtData } from "../../ast/node";
import { parseSource } from "./validation";

// If — distinct paths: simple, else, else-if chain
test "simple if" { assert programOk("if (x) { y; }"); }

test "if-else" { assert programOk("if (x) { a; } else { b; }"); }

test "if-else-if-else" { assert programOk("if (a) { x; } else if (b) { y; } else { z; }"); }
// Braceless bodies
test "if braceless" { assert programOk("if (x) y;"); }

test "if-else braceless" { assert programOk("if (x) a; else b;"); }

test "while braceless" { assert programOk("while (x) y;"); }
// While
test "while" { assert programOk("while (x) { y; }"); }
test "return expr" { assert programOk("function f(x) { return x + 1; }"); }
// Do-while
test "do-while" { assert programOk("do { x; } while (y);"); }

test "do-while no semi" { assert programOk("do { x; } while (y)"); }
// Switch — distinct paths: case, default, multi-case, return-in-case
test "switch case+default" { assert programOk("switch (x) { case 1: a; break; default: b; }"); }

test "switch multi case" { assert programOk("switch (x) { case 1: a; break; case 2: b; break; }"); }

test "switch return" { assert programOk("function f(x) { switch (x) { case 1: return \"one\"; default: return \"other\"; } }"); }
// For-in
test "for-in const" { assert stmtKind("for (const key in obj) {}") == NodeKind.ForInStmt; }

test "for-in let" { assert programOk("for (let k in obj) { console.log(k); }"); }

test "for-in body" { assert programOk("for (const key in obj) { obj[key]; }"); }
// For-of with destructuring
test "for-of destr obj" { assert programOk("for (const {key, value} of entries) { key; }"); }

test "for-of destr arr" { assert programOk("for (const [k, v] of entries) { k; }"); }
// Defer — expression vs block body
test "defer call" { assert programOk("function f() { defer cleanup(); }"); }

test "defer block" { assert programOk("function f() { defer { close(fd); } }"); }
// Unreachable
test "unreachable bare" { assert programOk("unreachable;"); }

test "unreachable msg" { assert programOk("unreachable(\"should not reach\");"); }
// Test declaration
test "test decl basic" { assert programOk("test \"basic\" { const x = 1; }"); }

test "test decl with assert" { assert programOk("test \"math\" { assert 1 === 1; }"); }

test "test is TestDecl" { assert stmtKind("test \"x\" { }") == NodeKind.TestDecl; }

test "test no string rejects" { assert !programOk("test { }"); }

test "test with code body" { assert programOk("test \"loops\" { let x = 0; while (x < 3) { x = x + 1; } }"); }

test "assert unary" { assert programOk("assert !done;"); }

test "assert binary" { assert programOk("assert a > b;"); }

// Assert keyword
test "assert stmt basic" { assert programOk("assert x;"); }

test "assert stmt binary" { assert programOk("assert a === b;"); }

test "assert stmt kind" { assert stmtKind("assert x;") == NodeKind.AssertStmt; }

test "assert stmt member" { assert programOk("assert obj.prop;"); }

test "assert stmt call" { assert programOk("assert isValid(x);"); }

test "assert stmt with message" { assert programOk("assert x > 0, \"x must be positive\";"); }

test "assert stmt message parsed" {
	const pr = parseSource("assert x, \"hello\";");
	assert pr.ok;
	const pd = pr.value.data as ProgramData;
	const d = pd.programStmts[0].data as AssertStmtData;
	assert d.assertMessage == "hello";
}

test "assert stmt no message" {
	const pr = parseSource("assert x;");
	assert pr.ok;
	const pd = pr.value.data as ProgramData;
	const d = pd.programStmts[0].data as AssertStmtData;
	assert d.assertMessage == "";
}

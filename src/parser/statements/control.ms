// Control Flow Statements - if, while, for, break, continue, return
// Uses callback injection via util.ms to avoid circular imports

import { Token, TokenKind } from "../../lexer/token";
import { Node, NodeKind, NodeData, createNode } from "../../ast/node";
import { ParserState, current, advance, isAtEnd, skipDestructurePattern, consumeSemicolon } from "../context";
import { skipTypeAnnotation } from "../typeAnnotation";
import { callBlockParser, callExprParser, callStmtParser, programOk, stmtKind } from "./util";
import { test, check, testGroup } from "std/testing";

type NodeResult = Result<Node, string>;

// ===== If Statement =====
// if (condition) { ... } [else [if (...)] { ... }]

export function parseIfStmt(state: ParserState): NodeResult {
	const ifToken = current(state);
	advance(state);
	if (current(state).kind !== TokenKind.LParen) {
		return Result.err(`Expected '(' after 'if' at line ${current(state).line.toString()}`);
	}

	advance(state);
	const condition = try callExprParser(state);
	if (current(state).kind !== TokenKind.RParen) {
		return Result.err(`Expected ')' after if condition at line ${current(state).line.toString()}`);
	}

	advance(state);
	const consequent = try callBlockParser(state);
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
			alternate: try callBlockParser(state),
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

export function parseWhileStmt(state: ParserState): NodeResult {
	const whileToken = current(state);
	advance(state);
	if (current(state).kind !== TokenKind.LParen) {
		return Result.err(`Expected '(' after 'while' at line ${current(state).line.toString()}`);
	}

	advance(state);
	const condition = try callExprParser(state);
	if (current(state).kind !== TokenKind.RParen) {
		return Result.err(`Expected ')' after while condition at line ${current(state).line.toString()}`);
	}

	advance(state);
	return Result.ok(createNode(NodeKind.WhileStmt, {
		whileCondition: condition,
		whileBody: try callBlockParser(state),
	}, whileToken));
}

// ===== For Statement =====
// for (let i = 0; i < n; i++) { ... }
// for (const item of items) { ... }

export function parseForStmt(state: ParserState): NodeResult {
	const forToken = current(state);
	advance(state);
	if (current(state).kind !== TokenKind.LParen) {
		return Result.err(`Expected '(' after 'for' at line ${current(state).line.toString()}`);
	}

	advance(state);
	// Check for for-of: for (const/let x of expr) or for (const/let { } of expr)
	const bindingToken = current(state);
	if (bindingToken.kind === TokenKind.Const || bindingToken.kind === TokenKind.Let) {
		const forIsConst = bindingToken.kind === TokenKind.Const;
		advance(state);

		// Destructured for-of: for (const { a, b } of items) or for (const [a, b] of items)
		if (current(state).kind === TokenKind.LBrace || current(state).kind === TokenKind.LBracket) {
			skipDestructurePattern(state);
			// Now expect 'of' or 'in'
			if (!isAtEnd(state) && current(state).kind === TokenKind.Of) {
				advance(state); // consume 'of'
				const iterable = try callExprParser(state);
				if (current(state).kind !== TokenKind.RParen) {
					return Result.err(`Expected ')' after for-of iterable at line ${current(state).line.toString()}`);
				}
				advance(state);
				return Result.ok(createNode(NodeKind.ForOfStmt, {
					forOfBinding: "_destructure",
					forOfIsConst: forIsConst,
					forOfIterable: iterable,
					forOfBody: try callBlockParser(state),
				}, forToken));
			}
			if (!isAtEnd(state) && current(state).kind === TokenKind.In) {
				advance(state); // consume 'in'
				const obj = try callExprParser(state);
				if (current(state).kind !== TokenKind.RParen) {
					return Result.err(`Expected ')' after for-in object at line ${current(state).line.toString()}`);
				}
				advance(state);
				return Result.ok(createNode(NodeKind.ForInStmt, {
					forInBinding: "_destructure",
					forInIsConst: forIsConst,
					forInObject: obj,
					forInBody: try callBlockParser(state),
				}, forToken));
			}
			return Result.err(`Expected 'of' or 'in' after destructuring pattern at line ${current(state).line.toString()}`);
		}

		const nameToken = current(state);
		if (nameToken.kind === TokenKind.Ident) {
			// Peek ahead: is this "name of" (for-of), "name in" (for-in), or "name =" (C-style for)?
			const afterName = state.position + 1;
			if (afterName < state.tokens.length && state.tokens[afterName].kind === TokenKind.Of) {
				// for-of loop
				advance(state); // consume name
				advance(state); // consume 'of'
				const iterable = try callExprParser(state);
				if (current(state).kind !== TokenKind.RParen) {
					return Result.err(`Expected ')' after for-of iterable at line ${current(state).line.toString()}`);
				}

				advance(state);
				return Result.ok(createNode(NodeKind.ForOfStmt, {
					forOfBinding: nameToken.value,
					forOfIsConst: forIsConst,
					forOfIterable: iterable,
					forOfBody: try callBlockParser(state),
				}, forToken));
			}
			if (afterName < state.tokens.length && state.tokens[afterName].kind === TokenKind.In) {
				// for-in loop
				advance(state); // consume name
				advance(state); // consume 'in'
				const obj = try callExprParser(state);
				if (current(state).kind !== TokenKind.RParen) {
					return Result.err(`Expected ')' after for-in object at line ${current(state).line.toString()}`);
				}

				advance(state);
				return Result.ok(createNode(NodeKind.ForInStmt, {
					forInBinding: nameToken.value,
					forInIsConst: forIsConst,
					forInObject: obj,
					forInBody: try callBlockParser(state),
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
			initializer: try callExprParser(state),
			isConst: forIsConst
		}, bindingToken);
		if (current(state).kind !== TokenKind.Semicolon) {
			return Result.err(`Expected ';' after for init at line ${current(state).line.toString()}`);
		}

		advance(state);
		const cond = try callExprParser(state);
		if (current(state).kind !== TokenKind.Semicolon) {
			return Result.err(`Expected ';' after for condition at line ${current(state).line.toString()}`);
		}

		advance(state);
		const update = try callExprParser(state);
		if (current(state).kind !== TokenKind.RParen) {
			return Result.err(`Expected ')' after for clauses at line ${current(state).line.toString()}`);
		}

		advance(state);
		return Result.ok(createNode(NodeKind.ForStmt, {
			forInit: initNode,
			forCondition: cond,
			forUpdate: update,
			forBody: try callBlockParser(state),
		}, forToken));
	}

	// C-style for with expression init: for (i = 0; ...)
	const exprInit = try callExprParser(state);
	const exprInitNode = createNode(NodeKind.ExprStmt, { expr: exprInit }, forToken);
	if (current(state).kind !== TokenKind.Semicolon) {
		return Result.err(`Expected ';' after for init at line ${current(state).line.toString()}`);
	}

	advance(state);
	const exprCond = try callExprParser(state);
	if (current(state).kind !== TokenKind.Semicolon) {
		return Result.err(`Expected ';' after for condition at line ${current(state).line.toString()}`);
	}

	advance(state);
	const exprUpdate = try callExprParser(state);
	if (current(state).kind !== TokenKind.RParen) {
		return Result.err(`Expected ')' after for clauses at line ${current(state).line.toString()}`);
	}

	advance(state);
	return Result.ok(createNode(NodeKind.ForStmt, {
		forInit: exprInitNode,
		forCondition: exprCond,
		forUpdate: exprUpdate,
		forBody: try callBlockParser(state),
	}, forToken));
}

// ===== Break / Continue =====

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
// return expr;

export function parseReturnStmt(state: ParserState): NodeResult {
	const retToken = current(state);
	advance(state);
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

	if (isAtEnd(state) || current(state).kind !== TokenKind.While) {
		return Result.err(`Expected 'while' after 'do' body at line ${doToken.line.toString()}`);
	}

	advance(state); // consume 'while'
	if (current(state).kind !== TokenKind.LParen) {
		return Result.err(`Expected '(' after 'while' in do-while at line ${current(state).line.toString()}`);
	}

	advance(state);
	const condition = try callExprParser(state);
	if (current(state).kind !== TokenKind.RParen) {
		return Result.err(`Expected ')' after do-while condition at line ${current(state).line.toString()}`);
	}

	advance(state);
	consumeSemicolon(state);

	return Result.ok(createNode(NodeKind.DoWhileStmt, {
		doBody: body,
		doCondition: condition,
	}, doToken));
}

// ===== Switch Statement =====
// switch (expr) { case val: stmts... [break;] default: stmts... }

export function parseSwitchStmt(state: ParserState): NodeResult {
	const switchToken = current(state);
	advance(state); // consume 'switch'

	if (current(state).kind !== TokenKind.LParen) {
		return Result.err(`Expected '(' after 'switch' at line ${current(state).line.toString()}`);
	}

	advance(state);
	const disc = try callExprParser(state);
	if (current(state).kind !== TokenKind.RParen) {
		return Result.err(`Expected ')' after switch discriminant at line ${current(state).line.toString()}`);
	}

	advance(state);
	if (current(state).kind !== TokenKind.LBrace) {
		return Result.err(`Expected '{' to start switch body at line ${current(state).line.toString()}`);
	}

	advance(state);
	const cases: Node[] = [];
	while (!isAtEnd(state) && current(state).kind !== TokenKind.RBrace) {
		const caseNode = try parseSwitchCase(state);
		cases.push(caseNode);
	}

	if (current(state).kind === TokenKind.RBrace) {
		advance(state);
	}

	return Result.ok(createNode(NodeKind.SwitchStmt, {
		switchDisc: disc,
		switchCases: cases,
	}, switchToken));
}

function parseSwitchCase(state: ParserState): NodeResult {
	const caseToken = current(state);

	if (caseToken.kind === TokenKind.Default) {
		advance(state); // consume 'default'
		if (current(state).kind === TokenKind.Colon) {
			advance(state);
		}
		const stmts = try parseCaseBody(state);
		return Result.ok(createNode(NodeKind.SwitchCase, {
			caseTests: [],
			caseStmts: stmts,
			isDefault: true,
		}, caseToken));
	}

	if (caseToken.kind !== TokenKind.Case) {
		return Result.err(`Expected 'case' or 'default' in switch at line ${caseToken.line.toString()}`);
	}

	advance(state); // consume 'case'
	const tests: Node[] = [];
	const firstTest = try callExprParser(state);
	tests.push(firstTest);
	if (current(state).kind === TokenKind.Colon) {
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
		current(state).kind !== TokenKind.Case &&
		current(state).kind !== TokenKind.Default &&
		current(state).kind !== TokenKind.RBrace) {
		if (current(state).kind === TokenKind.Semicolon) {
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
	if (!isAtEnd(state) && current(state).kind === TokenKind.LBrace) {
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
	if (!isAtEnd(state) && current(state).kind === TokenKind.LParen) {
		advance(state);
		if (!isAtEnd(state) && current(state).kind === TokenKind.String) {
			msg = current(state).value;
			advance(state);
		}
		if (!isAtEnd(state) && current(state).kind === TokenKind.RParen) {
			advance(state);
		}
	}
	consumeSemicolon(state);
	return Result.ok(createNode(NodeKind.UnreachableStmt, { unreachableMsg: msg }, unreachableToken));
}

// ===== Tests =====

testGroup("Stmt Control Flow", () => {
	// If — distinct paths: simple, else, else-if chain
	test("simple if", () => { check(programOk("if (x) { y; }")); });
	test("if-else", () => { check(programOk("if (x) { a; } else { b; }")); });
	test("if-else-if-else", () => { check(programOk("if (a) { x; } else if (b) { y; } else { z; }")); });
	// While
	test("while", () => { check(programOk("while (x) { y; }")); });
	// Return
	test("return expr", () => { check(programOk("function f(x) { return x + 1; }")); });
	// Do-while
	test("do-while", () => { check(programOk("do { x; } while (y);")); });
	test("do-while no semi", () => { check(programOk("do { x; } while (y)")); });
	// Switch — distinct paths: case, default, multi-case, return-in-case
	test("switch case+default", () => { check(programOk("switch (x) { case 1: a; break; default: b; }")); });
	test("switch multi case", () => { check(programOk("switch (x) { case 1: a; break; case 2: b; break; }")); });
	test("switch return", () => { check(programOk("function f(x) { switch (x) { case 1: return \"one\"; default: return \"other\"; } }")); });
	// For-in
	test("for-in const", () => { check(stmtKind("for (const key in obj) {}") === NodeKind.ForInStmt); });
	test("for-in let", () => { check(programOk("for (let k in obj) { console.log(k); }")); });
	test("for-in body", () => { check(programOk("for (const key in obj) { obj[key]; }")); });
	// For-of with destructuring
	test("for-of destr obj", () => { check(programOk("for (const {key, value} of entries) { key; }")); });
	test("for-of destr arr", () => { check(programOk("for (const [k, v] of entries) { k; }")); });
	// Defer — expression vs block body
	test("defer call", () => { check(programOk("function f() { defer cleanup(); }")); });
	test("defer block", () => { check(programOk("function f() { defer { close(fd); } }")); });
	// Unreachable
	test("unreachable bare", () => { check(programOk("unreachable;")); });
	test("unreachable msg", () => { check(programOk("unreachable(\"should not reach\");")); });
});

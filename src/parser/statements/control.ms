// Control Flow Statements - if, while, for, break, continue, return
// Uses callback injection via util.ms to avoid circular imports

import { Token, TokenKind } from "../../lexer/token";
import { Node, NodeKind, NodeData, createNode } from "../../ast/node";
import { ParserState, current, advance, isAtEnd } from "../context";
import { skipTypeAnnotation } from "../typeAnnotation";
import { callBlockParser, callExprParser, programOk } from "./util";
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
	if (!isAtEnd(state) && current(state).kind === TokenKind.Semicolon) {
		advance(state);
	}
	return Result.ok(createNode(NodeKind.BreakStmt, { breakLabel: "" }, token));
}

export function parseContinueStmt(state: ParserState): NodeResult {
	const token = current(state);
	advance(state);
	if (!isAtEnd(state) && current(state).kind === TokenKind.Semicolon) {
		advance(state);
	}
	return Result.ok(createNode(NodeKind.ContinueStmt, { continueLabel: "" }, token));
}

// ===== Return Statement =====
// return expr;

export function parseReturnStmt(state: ParserState): NodeResult {
	const retToken = current(state);
	advance(state);
	const value = try callExprParser(state);
	if (!isAtEnd(state) && current(state).kind === TokenKind.Semicolon) {
		advance(state);
	}
	return Result.ok(createNode(NodeKind.ReturnStmt, { argument: value }, retToken));
}

// ===== Tests =====

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

testGroup("Stmt Return", () => {
	test("return number", () => { check(programOk("function f() { return 42; }")); });
	test("return expr", () => { check(programOk("function f(x) { return x + 1; }")); });
	test("return call", () => { check(programOk("function f(a, b) { return a.method(b); }")); });
});

// Error Handling Statements - throw, try/catch/finally
// Uses callback injection via util.ms to avoid circular imports

import { Token, TokenKind } from "../../lexer/token";
import { Node, NodeKind, NodeData, createNode } from "../../ast/node";
import { ParserState, current, advance, isAtEnd } from "../context";
import { skipTypeAnnotation } from "../typeAnnotation";
import { callBlockParser, callExprParser, programOk } from "./util";
import { test, check, testGroup } from "std/testing";

type NodeResult = Result<Node, string>;

// ===== Throw Statement =====
// throw expr;

export function parseThrowStmt(state: ParserState): NodeResult {
	const throwToken = current(state);
	advance(state);
	const expr = try callExprParser(state);
	if (!isAtEnd(state) && current(state).kind === TokenKind.Semicolon) {
		advance(state);
	}
	return Result.ok(createNode(NodeKind.ThrowStmt, { throwArg: expr }, throwToken));
}

// ===== Try/Catch/Finally Statement =====
// try { ... } catch (e) { ... } finally { ... }

export function parseTryCatchStmt(state: ParserState): NodeResult {
	const tryToken = current(state);

	advance(state);
	const tryBlock = try callBlockParser(state);
	// Case 1: try-catch[-finally]
	if (!isAtEnd(state) && current(state).kind === TokenKind.Catch) {
		advance(state);
		let catchParam = "";
		// Optional catch parameter: catch (e)
		if (!isAtEnd(state) && current(state).kind === TokenKind.LParen) {
			advance(state);
			if (current(state).kind === TokenKind.Ident) {
				catchParam = current(state).value;
				advance(state);
				if (!isAtEnd(state) && current(state).kind === TokenKind.Colon) {
					advance(state);
					skipTypeAnnotation(state);
				}
			}
			if (current(state).kind !== TokenKind.RParen) {
				return Result.err(`Expected ')' after catch parameter at line ${current(state).line.toString()}`);
			}
			advance(state);
		}
		const catchBlock = try callBlockParser(state);

		// try-catch-finally
		if (!isAtEnd(state) && current(state).kind === TokenKind.Finally) {
			advance(state);
			const finallyBlock = try callBlockParser(state);
			return Result.ok(createNode(NodeKind.TryCatchStmt, {
				tryBody: tryBlock, catchName: catchParam,
				catchBody: catchBlock, finallyBody: finallyBlock,
			}, tryToken));
		}
		// try-catch only
		return Result.ok(createNode(NodeKind.TryCatchStmt, {
			tryBody: tryBlock, catchName: catchParam,
			catchBody: catchBlock,
			finallyBody: createNode(NodeKind.BlockStmt, { statements: [] }, tryToken),
		}, tryToken));
	}

	// Case 2: try-finally only
	if (!isAtEnd(state) && current(state).kind === TokenKind.Finally) {
		advance(state);
		const finallyBlock = try callBlockParser(state);
		return Result.ok(createNode(NodeKind.TryCatchStmt, {
			tryBody: tryBlock, catchName: "",
			catchBody: createNode(NodeKind.BlockStmt, { statements: [] }, tryToken),
			finallyBody: finallyBlock,
		}, tryToken));
	}

	return Result.err(`Expected 'catch' or 'finally' after try block at line ${current(state).line.toString()}`);
}

// ===== Tests =====

testGroup("Stmt Error Handling", () => {
	// Throw
	test("throw string", () => { check(programOk("throw \"error\";")); });
	test("throw expr", () => { check(programOk("throw error;")); });
	// Try — distinct paths: catch, finally, both, no-param catch
	test("try-catch", () => { check(programOk("try { x; } catch (e) { y; }")); });
	test("try-finally", () => { check(programOk("try { x; } finally { y; }")); });
	test("try-catch-finally", () => { check(programOk("try { x; } catch (e) { y; } finally { z; }")); });
	test("catch no param", () => { check(programOk("try { x; } catch { y; }")); });
	// Negative
	test("try alone rejects", () => { check(!programOk("try { x; }")); });
});

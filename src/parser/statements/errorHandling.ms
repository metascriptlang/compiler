// Error Handling Statements - throw, try/catch/finally
// Uses callback injection via util.ms to avoid circular imports

import { TokenKind } from "../../lexer/token";
import { Node, NodeKind, createNode, makeLoc } from "../../ast/node";
import { ParserState, current, advance, isAtEnd, consumeSemicolon } from "../context";
import { skipOptionalType, isIdentLike } from "../util";
import { callBlockParser, callExprParser } from "./callbacks";
import { programOk } from "./validation";


type NodeResult = Result<Node, string>;

// ===== Throw Statement =====
// syntax: 'throw' expr ';'

export function parseThrowStmt(state: ParserState): NodeResult {
	const throwToken = current(state);
	advance(state);
	const expr = try callExprParser(state);
	consumeSemicolon(state);
	return Result.ok(createNode(NodeKind.ThrowStmt, { throwArg: expr }, throwToken));
}

// ===== Try/Catch/Finally Statement =====
// syntax: 'try' block ('catch' ('(' ID (':' type)? ')')? block)? ('finally' block)?

export function parseTryCatchStmt(state: ParserState): NodeResult {
	const tryToken = current(state);

	advance(state);
	const tryBlock = try callBlockParser(state);
	// Case 1: try-catch[-finally]
	if (!isAtEnd(state) && current(state).kind === TokenKind.Catch) {
		advance(state);
		let catchParam = "";
		let catchParamLine = 0;
		let catchParamCol = 0;
		// Optional catch parameter: catch (e)
		if (!isAtEnd(state) && current(state).kind === TokenKind.LParen) {
			advance(state);
			if (isIdentLike(current(state))) {
				const catchToken = current(state);
				catchParam = catchToken.value;
				catchParamLine = catchToken.line;
				catchParamCol = catchToken.column;
				advance(state);
				skipOptionalType(state);
			}
			if (current(state).kind !== TokenKind.RParen) {
				return Result.err(`Expected ')' after catch parameter at line ${current(state).line}`);
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
				catchBindingLocation: makeLoc(catchParamLine, catchParamCol), hasCatchClause: true,
			}, tryToken));
		}
		// try-catch only
		return Result.ok(createNode(NodeKind.TryCatchStmt, {
			tryBody: tryBlock, catchName: catchParam,
			catchBody: catchBlock,
			finallyBody: createNode(NodeKind.BlockStmt, { statements: [] }, tryToken),
			catchBindingLocation: makeLoc(catchParamLine, catchParamCol), hasCatchClause: true,
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
			catchBindingLocation: makeLoc(0, 0), hasCatchClause: false,
		}, tryToken));
	}

	return Result.err(`Expected 'catch' or 'finally' after try block at line ${current(state).line}`);
}

// ===== Tests =====
// Throw
test "throw string" { assert programOk("throw \"error\";"); }

test "throw expr" { assert programOk("throw error;"); }
// Try — distinct paths: catch, finally, both, no-param catch
test "try-catch" { assert programOk("try { x; } catch (e) { y; }"); }

test "try-finally" { assert programOk("try { x; } finally { y; }"); }

test "try-catch-finally" { assert programOk("try { x; } catch (e) { y; } finally { z; }"); }

test "catch no param" { assert programOk("try { x; } catch { y; }"); }
// Negative
test "try alone rejects" { assert !programOk("try { x; }"); }

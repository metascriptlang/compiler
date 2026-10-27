// Object Literal Parser
// Extracted from expression.ms with callback injection

import { TokenKind } from "../../lexer/token";
import { NodeKind, Expression, createNode, ObjectLiteralData, StringLiteralData, SourceLocation, makeLoc } from "../../ast/node";
import { ParserState, createState, current, advance, isAtEnd, expectCloser, finishNode, finishToken } from "../cursor";
import { lex } from "../../lexer/lexer";
import { parseOk, mockExpr } from "./testUtil";
import { isPropertyName } from "../util";


type ExprResult = Result<Expression, string>;
type ExprParser = (state: ParserState, minPrec: int32) => ExprResult;

// ===== Object Literal =====
// { key: value, ... } or { key, ... } (shorthand)

export function parseObjectLiteral(state: ParserState, exprParser: ExprParser): ExprResult {
	const lbrace = current(state);
	const keys: string[] = [];
	const values: Expression[] = [];
	const keyLocs: SourceLocation[] = [];

	advance(state);
	while (!isAtEnd(state) && current(state).kind != TokenKind.RBrace) {
		// Spread in object: { ...obj }
		if (current(state).kind == TokenKind.DotDotDot) {
			const spreadToken = current(state);
			advance(state);
			const spreadVal = try exprParser(state, 0);
			keys.push("...");
			keyLocs.push(makeLoc(spreadToken.line, spreadToken.column));
			values.push(finishNode(state, createNode(NodeKind.SpreadExpr, { spreadArg: spreadVal }, spreadToken)));
			if (current(state).kind == TokenKind.Comma) { advance(state); } else { break; }
			continue;
		}

		// Computed property: { [expr]: value }
		if (current(state).kind == TokenKind.LBracket) {
			const compToken = current(state);
			advance(state);
			const keyExpr = try exprParser(state, 0);
			expectCloser(state, compToken, TokenKind.RBracket);
			if (current(state).kind == TokenKind.Colon) { advance(state); }
			const compVal = try exprParser(state, 0);
			keyLocs.push(makeLoc(compToken.line, compToken.column));
			if (keyExpr.kind == NodeKind.StringLiteral) {
				keys.push((keyExpr.data as StringLiteralData).value);
				values.push(compVal);
			} else {
				keys.push("__computed__");
				values.push(finishNode(state, createNode(NodeKind.ComputedProperty, { computedKey: keyExpr, computedValue: compVal }, compToken)));
			}
			if (current(state).kind == TokenKind.Comma) { advance(state); } else { break; }
			continue;
		}

		// String key: { "key": value }
		if (current(state).kind == TokenKind.String) {
			const strKeyToken = current(state);
			advance(state);
			if (current(state).kind == TokenKind.Colon) { advance(state); }
			keys.push(strKeyToken.value);
			keyLocs.push(makeLoc(strKeyToken.line, strKeyToken.column));
			const strVal = try exprParser(state, 0);
			values.push(strVal);
			if (current(state).kind == TokenKind.Comma) { advance(state); } else { break; }
			continue;
		}

		// Attach any pending comments (e.g., commented-out properties) to the key token.
		// Comments between properties are collected during advance() and need to be
		// attached to the next property's value node.
		const keyToken = current(state);
		if (!isPropertyName(keyToken)) {
			return Result.err(`Expected property name at line ${keyToken.line}`);
		}
		advance(state);

		const keyLoc = makeLoc(keyToken.line, keyToken.column);
		if (current(state).kind == TokenKind.Colon) {
			// Full property: { key: value }
			advance(state);
			keys.push(keyToken.value);
			keyLocs.push(keyLoc);
			const val = try exprParser(state, 0);
			values.push(val);
		} else {
			// Shorthand property: { key } means { key: key }
			keys.push(keyToken.value);
			keyLocs.push(keyLoc);
			const ident = finishToken(createNode(NodeKind.Identifier, { name: keyToken.value }, keyToken), keyToken);
			values.push(ident);
		}

		if (current(state).kind == TokenKind.Comma) {
			advance(state);
		} else {
			break;
		}
	}

	expectCloser(state, lbrace, TokenKind.RBrace);

	const objNode = createNode(NodeKind.ObjectLiteral, {
		properties: values,
		keys,
		keyLocations: keyLocs,
	}, lbrace);
	return Result.ok(objNode);
}

// ===== Tests =====


function objKeyCount(input: string): int32 {
	const lr = lex(input);
	if (!lr.ok) return -1;
	const state = createState(lr.value);
	const result = parseObjectLiteral(state, mockExpr);
	if (!result.ok) return -1;
	const data = result.value.data as ObjectLiteralData;
	return data.keys.length;
}

function objOk(input: string): boolean {
	const lr = lex(input);
	if (!lr.ok) return false;
	const state = createState(lr.value);
	const result = parseObjectLiteral(state, mockExpr);
	return result.ok;
}

test "empty" { assert objKeyCount("{}") == 0; }

test "two props" { assert objKeyCount("{ x: 1, y: 2 }") == 2; }

test "shorthand" { assert objKeyCount("{ x }") == 1; }

test "mixed" { assert objKeyCount("{ x, y: 2 }") == 2; }

test "trailing comma" { assert objKeyCount("{ x: 1, }") == 1; }

test "non-ident key fails" { assert !objOk("{ 42: x }"); }
// Integration
test "nested" { assert parseOk("f({ a: { b: 1 } })"); }

test "createNode pattern" { assert parseOk("f({ kind, value, line: 1 })"); }

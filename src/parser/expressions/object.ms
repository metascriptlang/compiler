// Object Literal Parser
// Extracted from expression.ms with callback injection

import { Token, TokenKind } from "../../lexer/token";
import { Node, NodeKind, NodeData, Expression, createNode, ObjectLiteralData, SourceLocation, makeLoc } from "../../ast/node";
import { ParserState, createState, current, advance, isAtEnd } from "../context";
import { lex } from "../../lexer/lexer";
import { parseOk, mockExpr } from "./util";
import { isIdentLike, isPropertyName } from "../util";


type ExprResult = Result<Expression, string>;
type ExprParser = (state: ParserState, minPrec: number) => ExprResult;

// ===== Object Literal =====
// { key: value, ... } or { key, ... } (shorthand)

export function parseObjectLiteral(state: ParserState, exprParser: ExprParser): ExprResult {
	const lbrace = current(state);
	const keys: string[] = [];
	const values: Expression[] = [];
	const keyLocs: SourceLocation[] = [];

	advance(state);
	while (!isAtEnd(state) && current(state).kind !== TokenKind.RBrace) {
		// Spread in object: { ...obj }
		if (current(state).kind === TokenKind.DotDotDot) {
			const spreadToken = current(state);
			advance(state);
			const spreadVal = try exprParser(state, 0);
			keys.push("...");
			keyLocs.push(makeLoc(spreadToken.line, spreadToken.column));
			values.push(createNode(NodeKind.SpreadExpr, { spreadArg: spreadVal }, spreadToken));
			if (current(state).kind === TokenKind.Comma) { advance(state); } else { break; }
			continue;
		}

		// Computed property: { [expr]: value }
		if (current(state).kind === TokenKind.LBracket) {
			const compToken = current(state);
			advance(state);
			const keyExpr = try exprParser(state, 0);
			if (current(state).kind === TokenKind.RBracket) { advance(state); }
			if (current(state).kind === TokenKind.Colon) { advance(state); }
			const compVal = try exprParser(state, 0);
			keys.push("__computed__");
			keyLocs.push(makeLoc(compToken.line, compToken.column));
			values.push(compVal);
			if (current(state).kind === TokenKind.Comma) { advance(state); } else { break; }
			continue;
		}

		// String key: { "key": value }
		if (current(state).kind === TokenKind.String) {
			const strKeyToken = current(state);
			advance(state);
			if (current(state).kind === TokenKind.Colon) { advance(state); }
			keys.push(strKeyToken.value);
			keyLocs.push(makeLoc(strKeyToken.line, strKeyToken.column));
			const strVal = try exprParser(state, 0);
			values.push(strVal);
			if (current(state).kind === TokenKind.Comma) { advance(state); } else { break; }
			continue;
		}

		const keyToken = current(state);
		if (!isPropertyName(keyToken)) {
			return Result.err(`Expected property name at line ${keyToken.line}`);
		}
		advance(state);

		const keyLoc = makeLoc(keyToken.line, keyToken.column);
		if (current(state).kind === TokenKind.Colon) {
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
			values.push(createNode(NodeKind.Identifier, { name: keyToken.value }, keyToken));
		}

		if (current(state).kind === TokenKind.Comma) {
			advance(state);
		} else {
			break;
		}
	}

	if (current(state).kind === TokenKind.RBrace) { advance(state); }

	return Result.ok(createNode(NodeKind.ObjectLiteral, {
		properties: values,
		keys,
		keyLocations: keyLocs,
	}, lbrace));
}

// ===== Tests =====

function objKeyCount(input: string): number {
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

test "empty" { assert objKeyCount("{}") === 0; }

test "two props" { assert objKeyCount("{ x: 1, y: 2 }") === 2; }

test "shorthand" { assert objKeyCount("{ x }") === 1; }

test "mixed" { assert objKeyCount("{ x, y: 2 }") === 2; }

test "trailing comma" { assert objKeyCount("{ x: 1, }") === 1; }

test "non-ident key fails" { assert !objOk("{ 42: x }"); }
// Integration
test "nested" { assert parseOk("f({ a: { b: 1 } })"); }

test "createNode pattern" { assert parseOk("f({ kind, value, line: 1 })"); }

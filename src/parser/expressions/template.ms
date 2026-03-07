// Template Literal Desugaring
// `hello ${name}, age ${age}!` → "hello " + name + ", age " + age + "!"
// Pattern: ~/projects/metascript/src/parser/parser.zig parseTemplateExpression()

import { Token, TokenKind } from "../../lexer/token";
import { Node, NodeKind, NodeData, Expression, createNode } from "../../ast/node";
import { ParserState, current, advance, isAtEnd } from "../context";
import { parseOk } from "./util";


type ExprResult = Result<Expression, string>;
type PrecParserFn = (state: ParserState, minPrec: number) => ExprResult;

export function parseTemplateLiteral(state: ParserState, parsePrec: PrecParserFn): ExprResult {
	const headToken = current(state);

	advance(state); // consume TemplateHead
	const parts: Node[] = [];
	if (headToken.value.length > 0) {
		parts.push(createNode(NodeKind.StringLiteral, { value: headToken.value }, headToken));
	}

	// Parse first interpolated expression
	const firstExpr = try parsePrec(state, 0);
	parts.push(firstExpr);

	// Parse remaining middle parts
	while (!isAtEnd(state) && current(state).kind === TokenKind.TemplateMiddle) {
		const midToken = current(state);
		advance(state);
		if (midToken.value.length > 0) {
			parts.push(createNode(NodeKind.StringLiteral, { value: midToken.value }, midToken));
		}
		const midExpr = try parsePrec(state, 0);
		parts.push(midExpr);
	}

	// Handle tail
	if (!isAtEnd(state) && current(state).kind === TokenKind.TemplateTail) {
		const tailToken = current(state);
		if (tailToken.value.length > 0) {
			parts.push(createNode(NodeKind.StringLiteral, { value: tailToken.value }, tailToken));
		}
		advance(state);
	}

	// Build left-associative concatenation tree
	if (parts.length === 0) {
		return Result.ok(createNode(NodeKind.StringLiteral, { value: "" }, headToken));
	}

	let result = parts[0];
	for (let i = 1; i < parts.length; i++) {
		result = createNode(NodeKind.BinaryExpr, { operator: "+", left: result, right: parts[i] }, headToken);
	}
	return Result.ok(result);
}

// ===== Tests =====
test "no substitution" { expect(parseOk("`hello`")); }

test "single interpolation" { expect(parseOk("`hello ${name}`")); }

test "two interpolations" { expect(parseOk("`${a} and ${b}`")); }

test "expr in interpolation" { expect(parseOk("`sum is ${a + b}`")); }

test "method call" { expect(parseOk("`num ${x.toString()}`")); }

test "three adjacent" { expect(parseOk("`${a}${b}${c}`")); }

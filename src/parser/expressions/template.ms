// Template Literal Desugaring
// `hello ${name}, age ${age}!` → "hello " + name + ", age " + age + "!"

import { TokenKind } from "../../lexer/token";
import { Node, NodeKind, Expression, createNode } from "../../ast/node";
import { ParserState, current, advance, isAtEnd } from "../cursor";
import { parseOk } from "./testUtil";


type ExprResult = Result<Expression, string>;
type PrecParserFn = (state: ParserState, minPrec: int32) => ExprResult;

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
	while (!isAtEnd(state) && current(state).kind == TokenKind.TemplateMiddle) {
		const midToken = current(state);
		advance(state);
		if (midToken.value.length > 0) {
			parts.push(createNode(NodeKind.StringLiteral, { value: midToken.value }, midToken));
		}
		const midExpr = try parsePrec(state, 0);
		parts.push(midExpr);
	}

	if (isAtEnd(state) || current(state).kind != TokenKind.TemplateTail) {
		return Result.err(`Expected '}' to close the template substitution opened at line ${headToken.line}, column ${headToken.column}`);
	}
	const tailToken = current(state);
	if (tailToken.value.length > 0) {
		parts.push(createNode(NodeKind.StringLiteral, { value: tailToken.value }, tailToken));
	}
	advance(state);

	// Build left-associative concatenation tree
	if (parts.length == 0) {
		return Result.ok(createNode(NodeKind.StringLiteral, { value: "" }, headToken));
	}

	// A template that opens on an interpolation starts from "", so every `+` is a
	// concatenation: `${a}${b}` over two numbers is "31", not the sum 4.
	let result = parts[0];
	let first = 1;
	if (parts[0].kind != NodeKind.StringLiteral) {
		result = createNode(NodeKind.StringLiteral, { value: "" }, headToken);
		first = 0;
	}
	for (let i = first; i < parts.length; i++) {
		result = createNode(NodeKind.BinaryExpr, { operator: "+", left: result, right: parts[i] }, headToken);
	}
	return Result.ok(result);
}

// ===== Tests =====

test "no substitution" { assert parseOk("`hello`"); }

test "single interpolation" { assert parseOk("`hello ${name}`"); }

test "two interpolations" { assert parseOk("`${a} and ${b}`"); }

test "expr in interpolation" { assert parseOk("`sum is ${a + b}`"); }

test "method call" { assert parseOk("`num ${x.toString()}`"); }

test "three adjacent" { assert parseOk("`${a}${b}${c}`"); }

test "a template substitution without its closing brace is refused" {
	assert !parseOk("`a ${x");
	assert !parseOk("`a ${x}b ${y");
	assert !parseOk("`a ${x y}`");
}

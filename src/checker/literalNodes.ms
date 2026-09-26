import { Token, TokenKind, createToken } from "../lexer/token";
import { Node, NodeKind, SourceLocation, createNode } from "../ast/node";
import { int32Type, float64Type, stringType, booleanType } from "./types";

// Create a synthetic token from a source location (for transform-generated nodes)
export function syntheticToken(loc: SourceLocation): Token {
	return createToken(TokenKind.Ident, "", loc.line);
}

export function makeNumber(val: number, loc: SourceLocation): Node {
	const isFloat = val % 1 != 0 || val > 9007199254740992 || val < -9007199254740992;
	const n = createNode(NodeKind.NumberLiteral, { value: val, isFloat, intVal: isFloat ? 0 as int64 : val as int64 }, syntheticToken(loc));
	if (!isFloat) { n.nodeType = int32Type(); } else { n.nodeType = float64Type(); }
	return n;
}

// Integer literal built from an exact int64 — the double field is only the
// approximate view, so anything past 2^53 must be produced through here rather
// than makeNumber.
export function makeIntNumber(val: int64, loc: SourceLocation): Node {
	const n = createNode(NodeKind.NumberLiteral, { value: val as number, isFloat: false, intVal: val }, syntheticToken(loc));
	n.nodeType = int32Type();
	return n;
}

export function makeString(val: string, loc: SourceLocation): Node {
	const n = createNode(NodeKind.StringLiteral, { value: val }, syntheticToken(loc));
	n.nodeType = stringType();
	return n;
}

export function makeBool(val: boolean, loc: SourceLocation): Node {
	const n = createNode(NodeKind.BooleanLiteral, { boolValue: val }, syntheticToken(loc));
	n.nodeType = booleanType();
	return n;
}

// Expression Helpers - Shared by the expression parser (core.ms) and the match-pattern parser (match.ms)

import { TokenKind, isIdentOrKeyword } from "../../lexer/token";
import { Node, NodeKind, createNode } from "../../ast/node";
import { ParserState, current, advance, isAtEnd } from "../context";

// ===== Member Access Chain Parser =====
// Shared by new-expression (core.ms) and match-pattern (match.ms)
// Parses: base.prop1.prop2.prop3...

export function parseMemberChain(state: ParserState, base: Node): Node {
	let node = base;
	while (!isAtEnd(state) && current(state).kind == TokenKind.Dot) {
		const dotToken = current(state);
		advance(state);
		const prop = current(state);
		if (isIdentOrKeyword(prop.kind)) {
			advance(state);
			node = createNode(NodeKind.MemberExpr, { object: node, property: prop.value, isOptional: false }, dotToken);
		} else {
			break;
		}
	}
	return node;
}

// Try-parse a literal-keyword token (true/false/null) into the corresponding
// literal Node. Returns null if current token is not a literal keyword.
// Shared by expression parser (core.ms) and match-pattern parser (match.ms)
// — both must produce literal nodes (not Identifier-with-name) so downstream
// passes treat them as literals rather than binding names. See bug025.
export function tryParseLiteralKeyword(state: ParserState): Node {
	const token = current(state);
	if (token.kind == TokenKind.True || token.kind == TokenKind.False) {
		advance(state);
		return createNode(NodeKind.BooleanLiteral, { boolValue: token.kind == TokenKind.True }, token);
	}
	if (token.kind == TokenKind.Null) {
		advance(state);
		return createNode(NodeKind.NullLiteral, { nullPlaceholder: true }, token);
	}
	return null as unknown as Node;
}

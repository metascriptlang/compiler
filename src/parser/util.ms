// Parser Utilities - Shared helpers used by both expression and statement parsers
// Lives at parser/ level to avoid circular imports between expressions/ and statements/

import { Token, TokenKind } from "../lexer/token";
import { ParserState, current, advance, isAtEnd, skipDestructurePattern } from "./context";
import { skipTypeAnnotation } from "./typeAnnotation";

// ===== Initializer/Default Value Skip =====
// Skips an expression value (consumed but not stored, Phase 1)
// Tracks balanced parens, brackets, braces; stops at comma, semicolon, or unbalanced closer
// Used for: default param values, enum member values, class property initializers

export function skipDefaultValue(state: ParserState): void {
	let depth = 0;
	while (!isAtEnd(state)) {
		if (current(state).kind === TokenKind.LParen || current(state).kind === TokenKind.LBracket || current(state).kind === TokenKind.LBrace) {
			depth += 1;
		}
		if (current(state).kind === TokenKind.RParen || current(state).kind === TokenKind.RBracket || current(state).kind === TokenKind.RBrace) {
			if (depth === 0) { break; }
			depth -= 1;
		}
		if ((current(state).kind === TokenKind.Comma || current(state).kind === TokenKind.Semicolon) && depth === 0) { break; }
		advance(state);
	}
}

// ===== Parameter List Parser =====
// Parses (param1, param2: Type, ...rest) including destructured params
// Consumes opening '(' through closing ')'. Returns param name strings.
// Handles: rest params, destructured params, type annotations, default values,
// constructor modifiers (public/private/protected/readonly)

export function parseParamList(state: ParserState): string[] {
	const params: string[] = [];
	if (current(state).kind !== TokenKind.LParen) { return params; }
	advance(state);
	while (!isAtEnd(state) && current(state).kind !== TokenKind.RParen) {
		let paramPrefix = "";
		if (current(state).kind === TokenKind.DotDotDot) { paramPrefix = "..."; advance(state); }
		// Skip constructor param modifiers: public/private/protected/readonly
		if (current(state).kind === TokenKind.Public || current(state).kind === TokenKind.Private ||
			current(state).kind === TokenKind.Protected || current(state).kind === TokenKind.Readonly) {
			advance(state);
		}
		// Destructured param: { a, b } or [ a, b ]
		if (current(state).kind === TokenKind.LBrace || current(state).kind === TokenKind.LBracket) {
			skipDestructurePattern(state);
			params.push(paramPrefix + "_destructure");
			if (!isAtEnd(state) && current(state).kind === TokenKind.Colon) { advance(state); skipTypeAnnotation(state); }
			if (!isAtEnd(state) && current(state).kind === TokenKind.Assign) {
				advance(state);
				skipDefaultValue(state);
			}
			if (current(state).kind === TokenKind.Comma) { advance(state); } else { break; }
			continue;
		}
		const param = current(state);
		if (param.kind !== TokenKind.Ident) { break; }
		params.push(paramPrefix + param.value);
		advance(state);
		if (!isAtEnd(state) && current(state).kind === TokenKind.Colon) { advance(state); skipTypeAnnotation(state); }
		// Skip default value
		if (!isAtEnd(state) && current(state).kind === TokenKind.Assign) {
			advance(state);
			skipDefaultValue(state);
		}
		if (current(state).kind === TokenKind.Comma) { advance(state); } else { break; }
	}
	if (current(state).kind === TokenKind.RParen) { advance(state); }
	return params;
}

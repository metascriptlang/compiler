// Parser Utilities - Shared helpers used by both expression and statement parsers
// Lives at parser/ level to avoid circular imports between expressions/ and statements/

import { Token, TokenKind } from "../lexer/token";
import { Node } from "../ast/node";
import { ParserState, createState, current, advance, isAtEnd, skipDestructurePattern, takePendingComments, collectTokenText } from "./context";
import { skipTypeAnnotation } from "./typeAnnotation";
import { lex } from "../lexer/lexer";


// ===== Comment Preservation =====

export function attachComments(state: ParserState, node: Node): Node {
	if (node !== null) {
		const comments = takePendingComments(state);
		let i = 0;
		while (i < comments.length) {
			node.comments.push(comments[i]);
			i = i + 1;
		}
	}
	return node;
}

// ===== Skip Optional Type Annotation =====
// Checks for ':' and skips the following type. Used after identifiers/params.

export function skipOptionalType(state: ParserState): void {
	if (!isAtEnd(state) && current(state).kind === TokenKind.Colon) {
		advance(state);
		skipTypeAnnotation(state);
	}
}

// ===== Capture Optional Type Annotation =====
// Like skipOptionalType but returns the type text string ("" if no annotation).

export function captureOptionalType(state: ParserState): string {
	if (!isAtEnd(state) && current(state).kind === TokenKind.Colon) {
		advance(state);
		const typeStart = state.position;
		skipTypeAnnotation(state);
		const typeEnd = state.position;
		return collectTokenText(state, typeStart, typeEnd);
	}
	return "";
}

// ===== Identifier Recognition =====
// Returns true if the token is an identifier or a contextual keyword
// that can be used in identifier positions (variable names, fields, etc.)
export function isIdentLike(token: Token): boolean {
	const k = token.kind;
	if (k === TokenKind.Ident) { return true; }
	// Keywords from Abstract onwards are contextual (can be used as variable/param names)
	return (k as number) >= (TokenKind.Abstract as number) && k !== TokenKind.Comment && k !== TokenKind.Eof;
}

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
// Consumes opening '(' through closing ')'.
// Returns INTERLEAVED array: ["name", "typeAnnotation", "name", "typeAnnotation", ...]
// typeAnnotation is "" if no annotation present.
// Use extractParamNames/extractParamTypes to split the result.
// Handles: rest params, destructured params, type annotations, default values,
// constructor modifiers (public/private/protected/readonly)

// Module-level: defaults from the last parseParamList call.
// Indexed by param position (0-based). Empty string = no default.
let _lastDefaults: string[] = [];

// Get defaults from the most recent parseParamList call.
// Returns array parallel to params: "" for no default, text otherwise.
export function getLastParsedDefaults(): string[] {
	return _lastDefaults;
}

export function parseParamList(state: ParserState, fnName: string): string[] {
	const params: string[] = [];
	_lastDefaults = [];
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
		// Extension method receiver (must be first param)
		if (params.length === 0 && current(state).kind === TokenKind.This) {
			advance(state);
			// Static extension: this typeof TypeName
			if (current(state).kind === TokenKind.Typeof) {
				advance(state);
				const typeName = current(state);
				if (!isIdentLike(typeName)) { break; }
				params.push("typeof:" + typeName.value);
				advance(state);
				params.push("");
				if (current(state).kind === TokenKind.Comma) { advance(state); } else { break; }
				continue;
			}
			// Instance extension: this name: Type
			const receiverName = current(state);
			if (!isIdentLike(receiverName)) { break; }
			params.push("this:" + receiverName.value);
			advance(state);
			params.push(captureOptionalType(state));
			if (current(state).kind === TokenKind.Comma) { advance(state); } else { break; }
			continue;
		}
		// Destructured param: { a, b } or [ a, b ]
		if (current(state).kind === TokenKind.LBrace || current(state).kind === TokenKind.LBracket) {
			skipDestructurePattern(state);
			params.push(paramPrefix + "_destructure");
			params.push(captureOptionalType(state));
			if (!isAtEnd(state) && current(state).kind === TokenKind.Assign) {
				advance(state);
				const dStartIdx = state.position;
				skipDefaultValue(state);
				if (fnName !== "") {
					const dText = collectTokenText(state, dStartIdx, state.position);
					const dIdx = (params.length - 2) / 2;
					while (_lastDefaults.length < dIdx) { _lastDefaults.push(""); }
					_lastDefaults.push(dText);
				}
			}
			if (current(state).kind === TokenKind.Comma) { advance(state); } else { break; }
			continue;
		}
		const param = current(state);
		if (!isIdentLike(param)) { break; }
		params.push(paramPrefix + param.value);
		advance(state);
		params.push(captureOptionalType(state));
		// Capture default value
		if (!isAtEnd(state) && current(state).kind === TokenKind.Assign) {
			advance(state);
			const startIdx = state.position;
			skipDefaultValue(state);
			if (fnName !== "") {
				const defaultText = collectTokenText(state, startIdx, state.position);
				const paramIdx = (params.length - 2) / 2;
				while (_lastDefaults.length < paramIdx) { _lastDefaults.push(""); }
				_lastDefaults.push(defaultText);
			}
		}
		if (current(state).kind === TokenKind.Comma) { advance(state); } else { break; }
	}
	if (current(state).kind === TokenKind.RParen) { advance(state); }
	return params;
}

// ===== Param List Extraction Helpers =====

export function extractParamNames(raw: string[]): string[] {
	const names: string[] = [];
	for (let i = 0; i < raw.length; i += 2) { names.push(raw[i]); }
	return names;
}

export function extractParamTypes(raw: string[]): string[] {
	const types: string[] = [];
	for (let i = 1; i < raw.length; i += 2) { types.push(raw[i]); }
	return types;
}

// ===== Tests =====

function parseParams(input: string, fnName: string): string[] {
	const lr = lex(input);
	if (!lr.ok) return [];
	const state = createState(lr.value);
	return parseParamList(state, fnName);
}

test "capture number default via getLastParsedDefaults" {
	const raw = parseParams("(x: number, y: number = 5)", "testFn1");
	assert raw.length === 4;
	const defs = getLastParsedDefaults();
	assert defs.length === 2;
	assert defs[0] === "";
	assert defs[1] === "5";
}

test "multiple defaults via getLastParsedDefaults" {
	parseParams("(a: number, b: number = 1, c: number = 2)", "testFn2");
	const defs = getLastParsedDefaults();
	assert defs.length === 3;
	assert defs[0] === "";
	assert defs[1] === "1";
	assert defs[2] === "2";
}

test "no default returns empty array" {
	parseParams("(x: number, y: string)", "testFn3");
	const defs = getLastParsedDefaults();
	assert defs.length === 0;
}

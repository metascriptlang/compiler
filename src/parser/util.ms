// Parser Utilities - Shared helpers used by both expression and statement parsers
// Lives at parser/ level to avoid circular imports between expressions/ and statements/

import { Token, TokenKind } from "../lexer/token";
import { Node, NodeKind, SourceLocation, makeLoc, NumberLiteralData } from "../ast/node";
import { ParserState, createState, current, advance, peek, isAtEnd, skipDestructurePattern, takePendingComments, collectTokenText } from "./context";
import { skipTypeAnnotation, parseTypeExpr } from "./typeAnnotation";
import { lex } from "../lexer/lexer";
import { callExprParser } from "./statements/callbacks";


// ===== Comment Preservation =====

export function attachComments(state: ParserState, node: Node): Node {
	if (node != null) {
		const comments = takePendingComments(state);
		for (const comment of comments) {
			node.comments.push(comment);
		}
	}
	return node;
}

// ===== Skip Optional Type Annotation =====
// Checks for ':' and skips the following type. Used after identifiers/params.

export function skipOptionalType(state: ParserState): void {
	if (!isAtEnd(state) && current(state).kind == TokenKind.Colon) {
		advance(state);
		skipTypeAnnotation(state);
	}
}

// ===== Capture Optional Type Annotation =====
// Like skipOptionalType but returns the type text string ("" if no annotation).
// Also builds a positioned TypeExpr AST (standard parity: PNode type tree).
// Retrieve via getLastTypeExpr() after calling captureOptionalType().

let _lastTypeExpr: Node | null = null;

export function getLastTypeExpr(): Node | null {
	return _lastTypeExpr;
}

export function captureOptionalType(state: ParserState): string {
	_lastTypeExpr = null;
	if (!isAtEnd(state) && current(state).kind == TokenKind.Colon) {
		advance(state);
		// Type predicate return annotation: `: <paramName> is <Type>`.
		// Stored verbatim in the fnReturnType string; the checker detects the
		// " is " infix, resolves the RHS as the predicate target, and sets the
		// function's actual return type to `boolean`. This covers user-defined
		// type guards: `function isString(x: unknown): x is string { ... }`.
		// Assertion function: `asserts paramName is Type`. Detected before
		// regular predicates. `asserts` is a contextual keyword (TokenKind.Asserts).
		if (current(state).kind == TokenKind.Asserts
				&& state.position + 2 < state.tokens.length
				&& (state.tokens[state.position + 1].kind == TokenKind.Ident || isIdentLike(state.tokens[state.position + 1]))
				&& state.tokens[state.position + 2].kind == TokenKind.Is) {
			advance(state); // `asserts`
			const assertParamName = current(state).value;
			advance(state); // param name
			advance(state); // `is`
			const assertTargetStart = state.position;
			skipTypeAnnotation(state);
			const assertTargetEnd = state.position;
			const assertTargetText = collectTokenText(state, assertTargetStart, assertTargetEnd);
			const assertSavedPos = state.position;
			state.position = assertTargetStart;
			_lastTypeExpr = parseTypeExpr(state);
			state.position = assertSavedPos;
			return `asserts ${assertParamName} is ${assertTargetText}`;
		}
		// Type predicate: `paramName is Type`.
		if (current(state).kind == TokenKind.Ident
				&& state.position + 1 < state.tokens.length
				&& state.tokens[state.position + 1].kind == TokenKind.Is) {
			const paramName = current(state).value;
			advance(state); // param name
			advance(state); // `is`
			const targetStart = state.position;
			skipTypeAnnotation(state);
			const targetEnd = state.position;
			const targetText = collectTokenText(state, targetStart, targetEnd);
			// Re-parse target for positioned TypeExpr so LSP symbol recording works.
			const savedPos = state.position;
			state.position = targetStart;
			_lastTypeExpr = parseTypeExpr(state);
			state.position = savedPos;
			return `${paramName} is ${targetText}`;
		}
		const typeStart = state.position;
		// Skip using the battle-tested skip path (never changes parser behavior)
		skipTypeAnnotation(state);
		const typeEnd = state.position;
		const text = collectTokenText(state, typeStart, typeEnd);
		// Build positioned TypeExpr tree by re-parsing the same token range
		// This is safe: parseTypeExpr only reads tokens[typeStart..typeEnd], no side effects
		const savedPos = state.position;
		state.position = typeStart;
		_lastTypeExpr = parseTypeExpr(state);
		state.position = savedPos; // Restore to skip endpoint (authoritative)
		return text;
	}
	return "";
}

// ===== Identifier Recognition =====
// Returns true if the token is an identifier or a contextual keyword
// that can be used in identifier positions (variable names, fields, etc.)
export function isIdentLike(token: Token): boolean {
	const k = token.kind;
	if (k == TokenKind.Ident) { return true; }
	// Keywords from Abstract onwards are contextual (can be used as variable/param names)
	return (k as number) >= (TokenKind.Abstract as number) && k != TokenKind.Comment && k != TokenKind.Eof && (k as number) < (TokenKind.JsxTagStart as number);
}

// Property/method name position — allows ALL keywords (TypeScript parity).
// In TypeScript: promise.catch(), map.delete(), set.has() are all valid.
export function isPropertyName(token: Token): boolean {
	const k = token.kind;
	if (k == TokenKind.Ident) return true;
	// Any keyword can be a property/method name
	return (k as number) >= (TokenKind.Break as number) && k != TokenKind.Comment && k != TokenKind.Eof && (k as number) < (TokenKind.JsxTagStart as number);
}

// ===== Initializer/Default Value Skip =====
// Skips an expression value (consumed but not stored, Phase 1)
// Tracks balanced parens, brackets, braces; stops at comma, semicolon, or unbalanced closer
// Used for: default param values, enum member values, class property initializers

export function skipDefaultValue(state: ParserState): void {
	let depth = 0;
	while (!isAtEnd(state)) {
		if (current(state).kind == TokenKind.LParen || current(state).kind == TokenKind.LBracket || current(state).kind == TokenKind.LBrace) {
			depth += 1;
		}
		if (current(state).kind == TokenKind.RParen || current(state).kind == TokenKind.RBracket || current(state).kind == TokenKind.RBrace) {
			if (depth == 0) { break; }
			depth -= 1;
		}
		if ((current(state).kind == TokenKind.Comma || current(state).kind == TokenKind.Semicolon) && depth == 0) { break; }
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
// Indexed by param position (0-based). null = no default.
// Reference parity: defaults stored as AST nodes, not text.
let _lastDefaults: Node[] = [];

// Get defaults from the most recent parseParamList call.
// Returns array parallel to params: null for no default, Node otherwise.
export function getLastParsedDefaults(): Node[] {
	return _lastDefaults;
}

// Module-level: TypeExpr nodes for each param's type annotation from last parseParamList.
// Indexed by param position (0-based). null = no type annotation.
let _lastParamTypeExprs: Node[] = [];

export function getLastParamTypeExprs(): Node[] {
	return _lastParamTypeExprs;
}

// Module-level: per-param source locations from last parseParamList.
// Standard parity: capture per-param token positions for LSP.
let _lastParamLocations: SourceLocation[] = [];

export function getLastParamLocations(): SourceLocation[] {
	return _lastParamLocations;
}

export function parseParamList(state: ParserState, fnName: string): string[] {
	const params: string[] = [];
	_lastDefaults = [];
	_lastParamTypeExprs = [];
	_lastParamLocations = [];
	if (current(state).kind != TokenKind.LParen) { return params; }
	advance(state);
	while (!isAtEnd(state) && current(state).kind != TokenKind.RParen) {
		let paramPrefix = "";
		if (current(state).kind == TokenKind.DotDotDot) { paramPrefix = "..."; advance(state); }
		// Skip constructor param modifiers: public/private/protected
		if (current(state).kind == TokenKind.Public || current(state).kind == TokenKind.Private ||
			current(state).kind == TokenKind.Protected) {
			advance(state);
		}
		// Out parameter: out name: Type → stored as "out:name". `out` is a contextual keyword:
		// it's the modifier only when a param name follows; `out: Type` / `out, …` / `out)` mean
		// `out` is itself the param name (same rule as the out-expression parser).
		if (current(state).kind == TokenKind.Out && isIdentLike(peek(state, 1))) {
			advance(state);
			paramPrefix = `${paramPrefix}out:`;
		}
		// Ref parameter: ref name: Type → stored as "ref:name" (contextual, as above)
		if (current(state).kind == TokenKind.Ref && isIdentLike(peek(state, 1))) {
			advance(state);
			paramPrefix = `${paramPrefix}ref:`;
		}
		// Readonly parameter: readonly name: Type → stored as "rdonly:name" (contextual, as above)
		// Cannot combine with out/ref — readonly means value copy, out/ref means pointer
		if (current(state).kind == TokenKind.Readonly && isIdentLike(peek(state, 1)) && paramPrefix.indexOf("out:") < 0 && paramPrefix.indexOf("ref:") < 0) {
			advance(state);
			paramPrefix = `${paramPrefix}rdonly:`;
		}
		// Extension method receiver (must be first param)
		if (params.length == 0 && current(state).kind == TokenKind.This) {
			advance(state);
			// Static extension: this typeof TypeName
			if (current(state).kind == TokenKind.Typeof) {
				advance(state);
				const typeName = current(state);
				if (!isIdentLike(typeName)) { break; }
				params.push(`typeof:${typeName.value}`);
				_lastParamLocations.push(makeLoc(typeName.line, typeName.column));
				advance(state);
				params.push("");
				_lastParamTypeExprs.push(null);
				if (current(state).kind == TokenKind.Comma) { advance(state); } else { break; }
				continue;
			}
			// Instance extension: this name: Type
			const receiverName = current(state);
			if (!isIdentLike(receiverName)) { break; }
			params.push(`this:${receiverName.value}`);
			_lastParamLocations.push(makeLoc(receiverName.line, receiverName.column));
			advance(state);
			params.push(captureOptionalType(state));
			_lastParamTypeExprs.push(_lastTypeExpr);
			if (current(state).kind == TokenKind.Comma) { advance(state); } else { break; }
			continue;
		}
		// Destructured param: { a, b } or [ a, b ]
		if (current(state).kind == TokenKind.LBrace || current(state).kind == TokenKind.LBracket) {
			const destToken = current(state);
			_lastParamLocations.push(makeLoc(destToken.line, destToken.column));
			skipDestructurePattern(state);
			params.push(`${paramPrefix}_destructure`);
			params.push(captureOptionalType(state));
			_lastParamTypeExprs.push(_lastTypeExpr);
			if (!isAtEnd(state) && current(state).kind == TokenKind.Assign) {
				advance(state);
				const dIdx = (params.length - 2) / 2;
				while (_lastDefaults.length < dIdx) { _lastDefaults.push(null); }
				const dResult = callExprParser(state);
				_lastDefaults.push(dResult.ok ? dResult.value : null);
			}
			if (current(state).kind == TokenKind.Comma) { advance(state); } else { break; }
			continue;
		}
		const param = current(state);
		if (!isIdentLike(param)) { break; }
		_lastParamLocations.push(makeLoc(param.line, param.column));
		params.push(`${paramPrefix}${param.value}`);
		advance(state);
		params.push(captureOptionalType(state));
		_lastParamTypeExprs.push(_lastTypeExpr);
		// Capture default value as AST node (Reference parity: store default expression)
		if (!isAtEnd(state) && current(state).kind == TokenKind.Assign) {
			advance(state);
			const paramIdx = (params.length - 2) / 2;
			while (_lastDefaults.length < paramIdx) { _lastDefaults.push(null); }
			const defResult = callExprParser(state);
			_lastDefaults.push(defResult.ok ? defResult.value : null);
		}
		if (current(state).kind == TokenKind.Comma) { advance(state); } else { break; }
	}
	if (current(state).kind == TokenKind.RParen) { advance(state); }
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
	assert raw.length == 4;
	const defs = getLastParsedDefaults();
	assert defs.length == 2;
	assert defs[0] == null;
	assert defs[1] != null;
	assert defs[1].kind == NodeKind.NumberLiteral;
	assert (defs[1].data as NumberLiteralData).value == 5;
}

test "multiple defaults via getLastParsedDefaults" {
	parseParams("(a: number, b: number = 1, c: number = 2)", "testFn2");
	const defs = getLastParsedDefaults();
	assert defs.length == 3;
	assert defs[0] == null;
	assert defs[1] != null;
	assert (defs[1].data as NumberLiteralData).value == 1;
	assert defs[2] != null;
	assert (defs[2].data as NumberLiteralData).value == 2;
}

test "no default returns empty array" {
	parseParams("(x: number, y: string)", "testFn3");
	const defs = getLastParsedDefaults();
	assert defs.length == 0;
}

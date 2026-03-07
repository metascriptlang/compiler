// Type Annotation Parser - Consumes type annotations
// Pattern: ~/projects/metascript/src/parser/parser.zig type parsing
//
// Currently in "skip" mode: consumes type syntax without building AST.
// Handles: simple names, T[], Result<T, E>, A | B, { x: T }, (a: T) => R, T?

import { Token, TokenKind } from "../lexer/token";
import { Node, NodeKind, createNode, TypeAnnotationData } from "../ast/node";
import { ParserState, createState, current, advance, isAtEnd, skipBalanced, skipGenericParams, collectTokenText } from "./context";
import { lex } from "../lexer/lexer";


type NodeResult = Result<Node, string>;

// ===== Type Annotation Skipping =====

export function skipTypeAnnotation(state: ParserState): void {
	// Leading pipe for discriminated union types: | { ... } | { ... }
	if (!isAtEnd(state) && current(state).kind === TokenKind.Pipe) {
		advance(state);
	}
	skipTypeAtom(state);

	// Union types: T | U | V
	while (!isAtEnd(state) && current(state).kind === TokenKind.Pipe) {
		advance(state);
		skipTypeAtom(state);
	}
}

// ===== Type Annotation Parsing =====
// Captures the type text and returns a TypeAnnotation node.

export function parseTypeAnnotation(state: ParserState): NodeResult {
	const startToken = current(state);
	const startPos = state.position;
	skipTypeAnnotation(state);
	const endPos = state.position;
	const typeText = collectTokenText(state, startPos, endPos);
	return Result.ok(createNode(NodeKind.TypeAnnotation, { annotationType: typeText }, startToken));
}

function skipTypeAtom(state: ParserState): void {
	const token = current(state);

	// Parenthesized type or function type: (a: T) => R
	if (token.kind === TokenKind.LParen) {
		skipBalanced(state, TokenKind.LParen, TokenKind.RParen);
		// Arrow function type: (...) => R
		if (!isAtEnd(state) && current(state).kind === TokenKind.Arrow) {
			advance(state);
			skipTypeAtom(state);
		}
		return;
	}

	// Object type: { x: T; y: U }
	if (token.kind === TokenKind.LBrace) {
		skipBalanced(state, TokenKind.LBrace, TokenKind.RBrace);
		return;
	}

	// Named type (identifier or keyword type)
	advance(state);
	// Generic type arguments: Type<A, B> — handles >> and >>> for nested generics
	skipGenericParams(state);

	// Array type suffix: T[] or T[N] or T[][]
	while (!isAtEnd(state) && current(state).kind === TokenKind.LBracket) {
		skipBalanced(state, TokenKind.LBracket, TokenKind.RBracket);
	}

	// Optional marker: T?
	if (!isAtEnd(state) && current(state).kind === TokenKind.Question) {
		advance(state);
	}
}

// ===== Tests =====
// Strategy: lex "TYPE = x", skip the type, verify we land on "="

function skipsTo(input: string, expectedKind: TokenKind): boolean {
	const lr = lex(input);
	if (!lr.ok) return false;
	const state = createState(lr.value);
	skipTypeAnnotation(state);
	return current(state).kind === expectedKind;
}

function skipsType(typeStr: string): boolean {
	return skipsTo(typeStr + " = x", TokenKind.Assign);
}

test "identifier type" { assert skipsType("number"); }

test "custom type" { assert skipsType("Foo"); }

test "string keyword" { assert skipsType("string"); }

test "boolean keyword" { assert skipsType("boolean"); }

test "void keyword" { assert skipsType("void"); }

test "single generic" { assert skipsType("Array<number>"); }

test "two generics" { assert skipsType("Map<string, number>"); }

test "nested generics" { assert skipsType("Result<Array<number>, string>"); }

test "nested generics no space" { assert skipsType("Result<Array<number>>"); }

test "triple nested generics" { assert skipsType("Map<string, Result<Array<number>>>"); }

test "array in generic arg" { assert skipsType("Result<Node[], string>"); }

test "array in both generic args" { assert skipsType("Map<string[], number[]>"); }

test "single array" { assert skipsType("number[]"); }

test "fixed array" { assert skipsType("number[4]"); }

test "fixed array multi-dimensional" { assert skipsType("number[4][2]"); }

test "double array" { assert skipsType("number[][]"); }

test "generic array" { assert skipsType("Array<string>[]"); }

test "two types" { assert skipsType("string | number"); }

test "three types" { assert skipsType("string | number | boolean"); }

test "union with array" { assert skipsType("string[] | number"); }

test "simple optional" { assert skipsType("string?"); }

test "generic optional" { assert skipsType("Array<number>?"); }

test "array optional" { assert skipsType("string[]?"); }

test "no params" { assert skipsType("() => void"); }

test "one param" { assert skipsType("(a: string) => number"); }

test "two params" { assert skipsType("(a: string, b: number) => boolean"); }

test "single field" { assert skipsType("{ x: number }"); }

test "two fields" { assert skipsType("{ x: number; y: string }"); }

test "nested object" { assert skipsType("{ a: { b: number } }"); }

test "generic with array suffix" { assert skipsType("Result<Node, string>[]"); }

test "union of generics" { assert skipsType("Result<A, B> | Error"); }

test "optional generic array" { assert skipsType("Map<string, number>[]?"); }

// ===== TypeAnnotation Node Tests =====

function annotationKind(typeStr: string): NodeKind {
	const lr = lex(typeStr + " = x");
	if (!lr.ok) return NodeKind.ExprStmt;
	const state = createState(lr.value);
	const result = parseTypeAnnotation(state);
	if (!result.ok) return NodeKind.ExprStmt;
	return result.value.kind;
}

function annotationText(typeStr: string): string {
	const lr = lex(typeStr + " = x");
	if (!lr.ok) return "";
	const state = createState(lr.value);
	const result = parseTypeAnnotation(state);
	if (!result.ok) return "";
	const data = result.value.data as TypeAnnotationData;
	return data.annotationType;
}

test "kind is TypeAnnotation" { assert annotationKind("number") === NodeKind.TypeAnnotation; }

test "simple type text" { assert annotationText("number") === "number"; }

test "generic type text" { assert annotationText("Result<Node, string>") !== ""; }

test "union type text" { assert annotationText("string | number") !== ""; }

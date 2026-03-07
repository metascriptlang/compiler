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

test "identifier type" { expect(skipsType("number")); }

test "custom type" { expect(skipsType("Foo")); }

test "string keyword" { expect(skipsType("string")); }

test "boolean keyword" { expect(skipsType("boolean")); }

test "void keyword" { expect(skipsType("void")); }

test "single generic" { expect(skipsType("Array<number>")); }

test "two generics" { expect(skipsType("Map<string, number>")); }

test "nested generics" { expect(skipsType("Result<Array<number>, string>")); }

test "nested generics no space" { expect(skipsType("Result<Array<number>>")); }

test "triple nested generics" { expect(skipsType("Map<string, Result<Array<number>>>")); }

test "array in generic arg" { expect(skipsType("Result<Node[], string>")); }

test "array in both generic args" { expect(skipsType("Map<string[], number[]>")); }

test "single array" { expect(skipsType("number[]")); }

test "fixed array" { expect(skipsType("number[4]")); }

test "fixed array multi-dimensional" { expect(skipsType("number[4][2]")); }

test "double array" { expect(skipsType("number[][]")); }

test "generic array" { expect(skipsType("Array<string>[]")); }

test "two types" { expect(skipsType("string | number")); }

test "three types" { expect(skipsType("string | number | boolean")); }

test "union with array" { expect(skipsType("string[] | number")); }

test "simple optional" { expect(skipsType("string?")); }

test "generic optional" { expect(skipsType("Array<number>?")); }

test "array optional" { expect(skipsType("string[]?")); }

test "no params" { expect(skipsType("() => void")); }

test "one param" { expect(skipsType("(a: string) => number")); }

test "two params" { expect(skipsType("(a: string, b: number) => boolean")); }

test "single field" { expect(skipsType("{ x: number }")); }

test "two fields" { expect(skipsType("{ x: number; y: string }")); }

test "nested object" { expect(skipsType("{ a: { b: number } }")); }

test "generic with array suffix" { expect(skipsType("Result<Node, string>[]")); }

test "union of generics" { expect(skipsType("Result<A, B> | Error")); }

test "optional generic array" { expect(skipsType("Map<string, number>[]?")); }

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

test "kind is TypeAnnotation" { expect(annotationKind("number") === NodeKind.TypeAnnotation); }

test "simple type text" { expect(annotationText("number") === "number"); }

test "generic type text" { expect(annotationText("Result<Node, string>") !== ""); }

test "union type text" { expect(annotationText("string | number") !== ""); }

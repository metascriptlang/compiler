// Type Annotation Parser - Consumes type annotations
// Pattern: ~/projects/metascript/src/parser/parser.zig type parsing
//
// Currently in "skip" mode: consumes type syntax without building AST.
// Handles: simple names, T[], Result<T, E>, A | B, { x: T }, (a: T) => R, T?

import { TokenKind } from "../lexer/token";
import { ParserState, createState, current, advance, isAtEnd } from "./context";
import { lex } from "../lexer/lexer";
import { test, check, testGroup } from "std/testing";

// ===== Type Annotation Skipping =====

export function skipTypeAnnotation(state: ParserState): void {
	skipTypeAtom(state);

	// Union types: T | U | V
	while (!isAtEnd(state) && current(state).kind === TokenKind.Pipe) {
		advance(state);
		skipTypeAtom(state);
	}
}

function skipTypeAtom(state: ParserState): void {
	const token = current(state);

	// Parenthesized type or function type: (a: T) => R
	if (token.kind === TokenKind.LParen) {
		advance(state);
		let depth = 1;
		while (!isAtEnd(state) && depth > 0) {
			if (current(state).kind === TokenKind.LParen) { depth += 1; }
			if (current(state).kind === TokenKind.RParen) { depth -= 1; }
			if (depth > 0) { advance(state); }
		}
		if (current(state).kind === TokenKind.RParen) { advance(state); }
		// Arrow function type: (...) => R
		if (!isAtEnd(state) && current(state).kind === TokenKind.Arrow) {
			advance(state);
			skipTypeAtom(state);
		}
		return;
	}

	// Object type: { x: T; y: U }
	if (token.kind === TokenKind.LBrace) {
		advance(state);
		let depth = 1;
		while (!isAtEnd(state) && depth > 0) {
			if (current(state).kind === TokenKind.LBrace) { depth += 1; }
			if (current(state).kind === TokenKind.RBrace) { depth -= 1; }
			if (depth > 0) { advance(state); }
		}
		if (current(state).kind === TokenKind.RBrace) { advance(state); }
		return;
	}

	// Named type (identifier or keyword type)
	advance(state);
	// Generic type arguments: Type<A, B>
	if (!isAtEnd(state) && current(state).kind === TokenKind.Lt) {
		advance(state);
		let depth = 1;
		while (!isAtEnd(state) && depth > 0) {
			if (current(state).kind === TokenKind.Lt) { depth += 1; }
			if (current(state).kind === TokenKind.Gt) { depth -= 1; }
			if (depth > 0) { advance(state); }
		}
		if (current(state).kind === TokenKind.Gt) { advance(state); }
	}

	// Array type suffix: T[] or T[][]
	while (!isAtEnd(state) && current(state).kind === TokenKind.LBracket) {
		advance(state);
		if (current(state).kind === TokenKind.RBracket) { advance(state); }
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

testGroup("TypeAnnotation Simple Types", () => {
	test("identifier type", () => { check(skipsType("number")); });
	test("custom type", () => { check(skipsType("Foo")); });
	test("string keyword", () => { check(skipsType("string")); });
	test("boolean keyword", () => { check(skipsType("boolean")); });
	test("void keyword", () => { check(skipsType("void")); });
});

testGroup("TypeAnnotation Generic Types", () => {
	test("single generic", () => { check(skipsType("Array<number>")); });
	test("two generics", () => { check(skipsType("Map<string, number>")); });
	test("nested generics", () => { check(skipsType("Result<Array<number>, string>")); });
});

testGroup("TypeAnnotation Array Types", () => {
	test("single array", () => { check(skipsType("number[]")); });
	test("double array", () => { check(skipsType("number[][]")); });
	test("generic array", () => { check(skipsType("Array<string>[]")); });
});

testGroup("TypeAnnotation Union Types", () => {
	test("two types", () => { check(skipsType("string | number")); });
	test("three types", () => { check(skipsType("string | number | boolean")); });
	test("union with array", () => { check(skipsType("string[] | number")); });
});

testGroup("TypeAnnotation Optional Types", () => {
	test("simple optional", () => { check(skipsType("string?")); });
	test("generic optional", () => { check(skipsType("Array<number>?")); });
	test("array optional", () => { check(skipsType("string[]?")); });
});

testGroup("TypeAnnotation Function Types", () => {
	test("no params", () => { check(skipsType("() => void")); });
	test("one param", () => { check(skipsType("(a: string) => number")); });
	test("two params", () => { check(skipsType("(a: string, b: number) => boolean")); });
});

testGroup("TypeAnnotation Object Types", () => {
	test("single field", () => { check(skipsType("{ x: number }")); });
	test("two fields", () => { check(skipsType("{ x: number; y: string }")); });
	test("nested object", () => { check(skipsType("{ a: { b: number } }")); });
});

testGroup("TypeAnnotation Complex Combinations", () => {
	test("generic with array suffix", () => { check(skipsType("Result<Node, string>[]")); });
	test("union of generics", () => { check(skipsType("Result<A, B> | Error")); });
	test("optional generic array", () => { check(skipsType("Map<string, number>[]?")); });
});

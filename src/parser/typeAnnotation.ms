// Type Annotation Parser - Consumes type annotations and builds positioned TypeExpr AST
//
// Dual mode:
// - skipTypeAnnotation: fast skip (existing behavior, no allocation)
// - parseTypeExpr: builds positioned AST (standard parity: Identifier, GenericType, FunctionType)
//
// The TypeExpr tree uses Identifier nodes for leaf type names (like standard Identifier),
// plus TypeGeneric, TypeArray, TypeUnion, TypeFunction, TypeObject for structural types.
// Every node carries .location from the token it was parsed from, enabling LSP symbol recording.

import { Token, TokenKind } from "../lexer/token";
import { Node, NodeKind, createNode, createNodeAt, TypeAnnotationData, IdentifierData, TypeGenericData } from "../ast/node";
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

// ===== Positioned Type Expression Parser =====
// Builds a TypeExpr AST tree with position info for every type identifier.
// Standard parity: semTypeNode dispatches on Identifier/GenericType etc.

function isTypeIdent(token: Token): boolean {
	const k = token.kind;
	if (k === TokenKind.Ident) return true;
	// Contextual keywords usable as type names (string, number, boolean, void, etc.)
	return (k as number) >= (TokenKind.Abstract as number) && k !== TokenKind.Comment && k !== TokenKind.Eof;
}

export function parseTypeExpr(state: ParserState): Node {
	// Leading pipe for discriminated union types: | { ... } | { ... }
	if (!isAtEnd(state) && current(state).kind === TokenKind.Pipe) {
		advance(state);
	}
	const first = parseTypeAtom(state);

	// Union types: T | U | V → TypeUnion
	if (!isAtEnd(state) && current(state).kind === TokenKind.Pipe) {
		const members: Node[] = [];
		members.push(first);
		while (!isAtEnd(state) && current(state).kind === TokenKind.Pipe) {
			advance(state);
			members.push(parseTypeAtom(state));
		}
		return createNodeAt(NodeKind.TypeUnion, { typExprMembers: members }, first.location);
	}

	return first;
}

function parseTypeAtom(state: ParserState): Node {
	const token = current(state);

	// Function type: (a: T, b: U) => R
	if (token.kind === TokenKind.LParen) {
		return parseTypeFunctionOrParen(state);
	}

	// Object type: { x: T; y: U }
	if (token.kind === TokenKind.LBrace) {
		return parseTypeObjectLiteral(state);
	}

	// Named type: identifier (possibly with generics and array suffix)
	if (!isTypeIdent(token)) {
		// Fallback: create an Identifier with whatever token we have
		advance(state);
		return createNode(NodeKind.Identifier, { name: token.value }, token);
	}

	advance(state);
	let result = createNode(NodeKind.Identifier, { name: token.value }, token);

	// Generic type args: Type<A, B>
	if (!isAtEnd(state) && current(state).kind === TokenKind.Lt) {
		const args = parseGenericTypeArgs(state);
		if (args.length > 0) {
			result = createNode(NodeKind.TypeGeneric, { typExprBase: result, typExprArgs: args }, token);
		}
	}

	// Array type suffix: T[] or T[N] or T[][]
	while (!isAtEnd(state) && current(state).kind === TokenKind.LBracket) {
		const brackToken = current(state);
		advance(state); // consume [
		let size = -1;
		if (!isAtEnd(state) && current(state).kind === TokenKind.Number) {
			size = parseFloat(current(state).value);
			advance(state);
		}
		if (!isAtEnd(state) && current(state).kind === TokenKind.RBracket) {
			advance(state);
		}
		result = createNode(NodeKind.TypeArray, { typExprElement: result, typExprSize: size }, brackToken);
	}

	// Optional marker: T? — treat as union with null (skip but preserve base)
	if (!isAtEnd(state) && current(state).kind === TokenKind.Question) {
		advance(state);
	}

	return result;
}

function parseGenericTypeArgs(state: ParserState): Node[] {
	const args: Node[] = [];
	if (isAtEnd(state) || current(state).kind !== TokenKind.Lt) return args;
	advance(state); // consume <
	let depth = 1;
	while (!isAtEnd(state) && depth > 0) {
		// Parse each type arg
		const arg = parseTypeExpr(state);
		args.push(arg);
		// Comma separator
		if (!isAtEnd(state) && current(state).kind === TokenKind.Comma && depth === 1) {
			advance(state);
			continue;
		}
		// Closing >
		if (!isAtEnd(state) && current(state).kind === TokenKind.Gt) {
			depth -= 1;
			advance(state);
		} else if (!isAtEnd(state) && current(state).kind === TokenKind.GtGt) {
			depth -= 2;
			advance(state);
		} else if (!isAtEnd(state) && current(state).kind === TokenKind.GtGtGt) {
			depth -= 3;
			advance(state);
		} else {
			break;
		}
	}
	return args;
}

function parseTypeFunctionOrParen(state: ParserState): Node {
	const parenToken = current(state);
	advance(state); // consume (

	// Collect params: name: Type pairs
	const paramNames: string[] = [];
	const paramTypes: Node[] = [];

	while (!isAtEnd(state) && current(state).kind !== TokenKind.RParen) {
		// Param name (optional — could be just types)
		if (isTypeIdent(current(state))) {
			const nameToken = current(state);
			const nextKind = state.position + 1 < state.tokens.length ? state.tokens[state.position + 1].kind : TokenKind.Eof;
			// If followed by ':', it's "name: Type"
			if (nextKind === TokenKind.Colon) {
				paramNames.push(nameToken.value);
				advance(state); // consume name
				advance(state); // consume :
				paramTypes.push(parseTypeExpr(state));
			} else {
				// Just a type (no name)
				paramNames.push("");
				paramTypes.push(parseTypeExpr(state));
			}
		} else {
			paramNames.push("");
			paramTypes.push(parseTypeExpr(state));
		}
		if (!isAtEnd(state) && current(state).kind === TokenKind.Comma) {
			advance(state);
		}
	}
	if (!isAtEnd(state) && current(state).kind === TokenKind.RParen) {
		advance(state);
	}

	// Arrow => return type
	if (!isAtEnd(state) && current(state).kind === TokenKind.Arrow) {
		advance(state);
		const returnType = parseTypeAtom(state);
		return createNode(NodeKind.TypeFunction, {
			typExprParams: paramTypes,
			typExprReturn: returnType,
			typExprParamNames: paramNames,
		}, parenToken);
	}

	// Parenthesized type: (T) → unwrap to inner type
	if (paramTypes.length === 1 && paramNames[0] === "") {
		return paramTypes[0];
	}

	// Fallback: treat as function type with void return
	const voidNode = createNode(NodeKind.Identifier, { name: "void" }, parenToken);
	return createNode(NodeKind.TypeFunction, {
		typExprParams: paramTypes,
		typExprReturn: voidNode,
		typExprParamNames: paramNames,
	}, parenToken);
}

function parseTypeObjectLiteral(state: ParserState): Node {
	const braceToken = current(state);
	advance(state); // consume {

	const fieldNames: string[] = [];
	const fieldTypes: Node[] = [];

	while (!isAtEnd(state) && current(state).kind !== TokenKind.RBrace) {
		if (isTypeIdent(current(state))) {
			fieldNames.push(current(state).value);
			advance(state); // consume field name
			// Optional ? marker
			if (!isAtEnd(state) && current(state).kind === TokenKind.Question) {
				advance(state);
			}
			if (!isAtEnd(state) && current(state).kind === TokenKind.Colon) {
				advance(state);
				fieldTypes.push(parseTypeExpr(state));
			} else {
				fieldTypes.push(createNode(NodeKind.Identifier, { name: "unknown" }, braceToken));
			}
		} else {
			// Skip unexpected tokens
			advance(state);
		}
		if (!isAtEnd(state) && (current(state).kind === TokenKind.Semicolon || current(state).kind === TokenKind.Comma)) {
			advance(state);
		}
	}
	if (!isAtEnd(state) && current(state).kind === TokenKind.RBrace) {
		advance(state);
	}

	return createNode(NodeKind.TypeObject, {
		typExprFieldNames: fieldNames,
		typExprFieldTypes: fieldTypes,
	}, braceToken);
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

// ===== TypeExpr AST Tests =====

function typeExprKind(typeStr: string): NodeKind {
	const lr = lex(typeStr + " = x");
	if (!lr.ok) return NodeKind.Program;
	const state = createState(lr.value);
	const node = parseTypeExpr(state);
	return node.kind;
}

function typeExprName(typeStr: string): string {
	const lr = lex(typeStr + " = x");
	if (!lr.ok) return "";
	const state = createState(lr.value);
	const node = parseTypeExpr(state);
	if (node.kind !== NodeKind.Identifier) return "";
	return (node.data as IdentifierData).name;
}

test "typeExpr simple ident" {
	assert typeExprKind("number") === NodeKind.Identifier;
	assert typeExprName("number") === "number";
}

test "typeExpr custom type" {
	assert typeExprKind("Person") === NodeKind.Identifier;
	assert typeExprName("Person") === "Person";
}

test "typeExpr generic" {
	assert typeExprKind("Result<Node, string>") === NodeKind.TypeGeneric;
}

test "typeExpr array" {
	assert typeExprKind("number[]") === NodeKind.TypeArray;
}

test "typeExpr union" {
	assert typeExprKind("string | number") === NodeKind.TypeUnion;
}

test "typeExpr function type" {
	assert typeExprKind("(a: string) => number") === NodeKind.TypeFunction;
}

test "typeExpr object type" {
	assert typeExprKind("{ x: number }") === NodeKind.TypeObject;
}

test "typeExpr generic has positioned base" {
	const lr = lex("Result<Node, string> = x");
	if (!lr.ok) { assert false; return; }
	const state = createState(lr.value);
	const node = parseTypeExpr(state);
	assert node.kind === NodeKind.TypeGeneric;
	const d = node.data as TypeGenericData;
	assert d.typExprBase.kind === NodeKind.Identifier;
	assert (d.typExprBase.data as IdentifierData).name === "Result";
	assert d.typExprBase.location.line === 1;
	assert d.typExprBase.location.column === 1;
	assert d.typExprArgs.length === 2;
	assert (d.typExprArgs[0].data as IdentifierData).name === "Node";
	assert (d.typExprArgs[1].data as IdentifierData).name === "string";
}

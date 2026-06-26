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
import { Node, NodeKind, createNode, createNodeAt, TypeAnnotationData, IdentifierData, TypeGenericData, TypeObjectData } from "../ast/node";
import { ParserState, createState, current, advance, isAtEnd, skipBalanced, skipGenericParams, collectTokenText } from "./context";
import { lex } from "../lexer/lexer";


type NodeResult = Result<Node, string>;

// ===== Type Annotation Skipping =====

// Skip the trailing `& T & U` of an intersection chain after an atom has already
// been consumed. Reused by the top-level skipper and by each union member.
// Erasure-tier — accepted by parser, collapsed by resolver to first operand.
function skipIntersectionTail(state: ParserState): void {
	while (!isAtEnd(state) && current(state).kind === TokenKind.Amp) {
		advance(state);
		skipTypeAtom(state);
	}
}

export function skipTypeAnnotation(state: ParserState): void {
	// Leading pipe for discriminated union types: | { ... } | { ... }
	if (!isAtEnd(state) && current(state).kind === TokenKind.Pipe) {
		advance(state);
	}
	skipTypeAtom(state);

	// Intersection: T & U & V (binds tighter than union and conditional)
	skipIntersectionTail(state);

	// Tier 3: Conditional type: T extends U ? A : B
	// Must be checked BEFORE union pipe so `T extends U ? A : B` isn't split as `T extends U ? A` | `B`
	if (!isAtEnd(state) && current(state).kind === TokenKind.Extends) {
		advance(state); // consume 'extends'
		// Skip constraint type WITHOUT consuming '?' (which skipTypeAtom would eat as optional marker)
		skipTypeAtomNoOptional(state);
		if (!isAtEnd(state) && current(state).kind === TokenKind.Question) {
			advance(state); // consume '?'
			skipTypeAnnotation(state); // skip true branch (recursive — handles nested conditionals)
			if (!isAtEnd(state) && current(state).kind === TokenKind.Colon) {
				advance(state); // consume ':'
				skipTypeAnnotation(state); // skip false branch
			}
		}
		return;
	}

	// Union types: T | U | V — each member may itself be an intersection (T & U).
	while (!isAtEnd(state) && current(state).kind === TokenKind.Pipe) {
		advance(state);
		skipTypeAtom(state);
		skipIntersectionTail(state);
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
	return (k as number) >= (TokenKind.Abstract as number) && k !== TokenKind.Comment && k !== TokenKind.Eof && (k as number) < (TokenKind.JsxTagStart as number);
}

// Given an already-parsed leading atom, fold any trailing `& T & U` into a
// TypeIntersection node. If no `&` follows, returns `first` unchanged.
// Reused by parseTypeExpr at the top level and within each union member.
function parseIntersectionTail(state: ParserState, first: Node): Node {
	if (!isAtEnd(state) && current(state).kind === TokenKind.Amp) {
		const members: Node[] = [];
		members.push(first);
		while (!isAtEnd(state) && current(state).kind === TokenKind.Amp) {
			advance(state);
			members.push(parseTypeAtom(state));
		}
		return createNodeAt(NodeKind.TypeIntersection, { typExprMembers: members }, members[0].location);
	}
	return first;
}

export function parseTypeExpr(state: ParserState): Node {
	// Leading pipe for discriminated union types: | { ... } | { ... }
	if (!isAtEnd(state) && current(state).kind === TokenKind.Pipe) {
		advance(state);
	}
	const first = parseIntersectionTail(state, parseTypeAtom(state));

	// Union types: T | U | V → TypeUnion. Each union member may itself be an intersection.
	if (!isAtEnd(state) && current(state).kind === TokenKind.Pipe) {
		const members: Node[] = [];
		members.push(first);
		while (!isAtEnd(state) && current(state).kind === TokenKind.Pipe) {
			advance(state);
			members.push(parseIntersectionTail(state, parseTypeAtom(state)));
		}
		return createNodeAt(NodeKind.TypeUnion, {
			typExprMembers: members,
			discFieldName: "",
			variantKeys: [],
			discKind: "",
		}, first.location);
	}

	return first;
}

function parseTypeAtom(state: ParserState): Node {
	const token = current(state);

	// Function type: (a: T, b: U) => R
	if (token.kind === TokenKind.LParen) {
		return parseTypeFunctionOrParen(state);
	}

	// Object type: { x: T; y: U } — with array suffix: { ... }[]
	if (token.kind === TokenKind.LBrace) {
		return applyArraySuffix(state, parseTypeObjectLiteral(state));
	}

	// Tuple type: [T, U, ...] — bracket at start of type position (not array suffix).
	// The string form (resolveAnnotation) is the source of truth for the type;
	// we balance-skip and emit a placeholder Identifier so parser state is preserved.
	// (Positioned tuple AST as a dedicated NodeKind is a future enhancement.)
	if (token.kind === TokenKind.LBracket) {
		skipBalanced(state, TokenKind.LBracket, TokenKind.RBracket);
		return createNode(NodeKind.Identifier, { name: "[tuple]" }, token);
	}

	// Named type: identifier (possibly with generics and array suffix)
	if (!isTypeIdent(token)) {
		// Fallback: create an Identifier with whatever token we have
		advance(state);
		return createNode(NodeKind.Identifier, { name: token.value }, token);
	}

	advance(state);
	let result = createNode(NodeKind.Identifier, { name: token.value }, token);

	// Enum literal type: K.A — consume "." Ident chain and produce a MemberExpr-shaped node
	// in type position. The checker's resolveAnnotation handles the string path ("K.A") via
	// splitting on ".", and resolveTypeExpr can walk the MemberExpr for LSP recording.
	while (!isAtEnd(state) && current(state).kind === TokenKind.Dot) {
		advance(state); // consume .
		if (isAtEnd(state) || !isTypeIdent(current(state))) break;
		const memberToken = current(state);
		advance(state);
		result = createNode(NodeKind.MemberExpr, { object: result, property: memberToken.value, isOptional: false }, token);
	}

	// Generic type args: Type<A, B>
	if (!isAtEnd(state) && current(state).kind === TokenKind.Lt) {
		const args = parseGenericTypeArgs(state);
		if (args.length > 0) {
			result = createNode(NodeKind.TypeGeneric, { typExprBase: result, typExprArgs: args }, token);
		}
	}

	// Array type suffix: T[] or T[N] or T[][]
	result = applyArraySuffix(state, result);

	// Optional marker: T? — treat as union with null (skip but preserve base)
	if (!isAtEnd(state) && current(state).kind === TokenKind.Question) {
		advance(state);
	}

	return result;
}

// Apply the array type suffix `[]` / `[N]` (repeatable) to a parsed type atom. Shared by the
// named-type path and inline object types so `{ ... }[]` parses like `Name[]`.
function applyArraySuffix(state: ParserState, result: Node): Node {
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
	return result;
}

function parseGenericTypeArgs(state: ParserState): Node[] {
	const args: Node[] = [];
	if (isAtEnd(state) || current(state).kind !== TokenKind.Lt) return args;
	advance(state); // consume <
	let depth = 1;
	while (!isAtEnd(state) && depth > 0) {
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
	let indexKey: Node = null as unknown as Node;
	let indexValue: Node = null as unknown as Node;

	let hasIndexSig = false;

	while (!isAtEnd(state) && current(state).kind !== TokenKind.RBrace) {
		// Index signature: [name: K]: V
		// This is syntactic sugar for HashMap<K, V> — the checker normalizes both to the
		// same internal Type. See docs/PACKAGE.md (open design) and the impl plan.
		if (current(state).kind === TokenKind.LBracket) {
			if (hasIndexSig) {
				// Second index signature in the same object type — skip silently.
				// Only the first is kept. This is invalid TypeScript but we don't
				// crash; we just ignore the duplicate.
				advance(state);
				continue;
			}
			if (fieldNames.length > 0) {
				// Mixed named fields + index signature is not supported in v1.
				// Skip the index signature and keep the named fields.
				advance(state);
				continue;
			}
			advance(state); // consume [
			// Consume the binding name (we only care about the key TYPE, not the name)
			if (!isAtEnd(state) && isTypeIdent(current(state))) {
				advance(state); // consume key binding name
			}
			if (!isAtEnd(state) && current(state).kind === TokenKind.Colon) {
				advance(state); // consume :
			}
			const keyType = parseTypeExpr(state);
			if (!isAtEnd(state) && current(state).kind === TokenKind.RBracket) {
				advance(state); // consume ]
			}
			if (!isAtEnd(state) && current(state).kind === TokenKind.Colon) {
				advance(state); // consume :
			}
			const valueType = parseTypeExpr(state);
			indexKey = keyType;
			indexValue = valueType;
			hasIndexSig = true;
			// Consume optional separator
			if (!isAtEnd(state) && (current(state).kind === TokenKind.Semicolon || current(state).kind === TokenKind.Comma)) {
				advance(state);
			}
			continue;
		}

		if (isTypeIdent(current(state)) && !hasIndexSig) {
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
			advance(state);
		}
		if (!isAtEnd(state) && (current(state).kind === TokenKind.Semicolon || current(state).kind === TokenKind.Comma)) {
			advance(state);
		}
	}
	if (!isAtEnd(state) && current(state).kind === TokenKind.RBrace) {
		advance(state);
	}

	// Anonymous object types in source can't carry decorators on fields —
	// parser only accepts `name: Type;` syntax. Per-field decorators are
	// only sourced from `class` declarations (see bridge.ms collectFieldDecorators).
	const emptyDecorators: Node[][] = [];
	for (let i = 0; i < fieldNames.length; i = i + 1) emptyDecorators.push([]);
	return createNode(NodeKind.TypeObject, {
		typExprFieldNames: fieldNames,
		typExprFieldTypes: fieldTypes,
		typExprIndexKey: indexKey,
		typExprIndexValue: indexValue,
		typExprFieldDecorators: emptyDecorators,
		typExprTypeName: "",
	}, braceToken);
}

// Tier 3: skip a type atom WITHOUT consuming the trailing '?' (needed for conditional types
// where '?' is the ternary operator, not the optional marker).
function skipTypeAtomNoOptional(state: ParserState): void {
	const token = current(state);
	// Tier 3: infer X — consume keyword + identifier name
	if (token.kind === TokenKind.Infer) {
		advance(state); // consume 'infer'
		if (!isAtEnd(state) && isTypeIdent(current(state))) {
			advance(state); // consume the inferred type name
		}
		return;
	}
	if (token.kind === TokenKind.LParen) {
		skipBalanced(state, TokenKind.LParen, TokenKind.RParen);
		if (!isAtEnd(state) && current(state).kind === TokenKind.Arrow) {
			advance(state);
			skipTypeAtomNoOptional(state);
		}
		// Array type suffix: ((T) => U)[] or (T)[]
		while (!isAtEnd(state) && current(state).kind === TokenKind.LBracket) {
			skipBalanced(state, TokenKind.LBracket, TokenKind.RBracket);
		}
		return;
	}
	if (token.kind === TokenKind.LBrace) {
		skipBalanced(state, TokenKind.LBrace, TokenKind.RBrace);
		return;
	}
	// Tuple type: [T, U, ...] — bracket at start of type position (not array suffix)
	if (token.kind === TokenKind.LBracket) {
		skipBalanced(state, TokenKind.LBracket, TokenKind.RBracket);
		return;
	}
	advance(state);
	while (!isAtEnd(state) && current(state).kind === TokenKind.Dot) {
		advance(state);
		if (isAtEnd(state) || !isTypeIdent(current(state))) break;
		advance(state);
	}
	skipGenericParams(state);
	while (!isAtEnd(state) && current(state).kind === TokenKind.LBracket) {
		skipBalanced(state, TokenKind.LBracket, TokenKind.RBracket);
	}
	// No '?' consumption — that's the whole point
}

function skipTypeAtom(state: ParserState): void {
	const token = current(state);

	// Tier 3: infer X — consume keyword + identifier name
	if (token.kind === TokenKind.Infer) {
		advance(state);
		if (!isAtEnd(state) && isTypeIdent(current(state))) {
			advance(state);
		}
		return;
	}

	// Parenthesized type or function type: (a: T) => R
	if (token.kind === TokenKind.LParen) {
		skipBalanced(state, TokenKind.LParen, TokenKind.RParen);
		// Arrow function type: (...) => R
		if (!isAtEnd(state) && current(state).kind === TokenKind.Arrow) {
			advance(state);
			skipTypeAtom(state);
		}
		// Array type suffix on parenthesized/function type: ((n) => T)[] or (T)[]
		while (!isAtEnd(state) && current(state).kind === TokenKind.LBracket) {
			skipBalanced(state, TokenKind.LBracket, TokenKind.RBracket);
		}
		return;
	}

	// Object type: { x: T; y: U } — with array suffix: { ... }[]
	if (token.kind === TokenKind.LBrace) {
		skipBalanced(state, TokenKind.LBrace, TokenKind.RBrace);
		while (!isAtEnd(state) && current(state).kind === TokenKind.LBracket) {
			skipBalanced(state, TokenKind.LBracket, TokenKind.RBracket);
		}
		return;
	}

	// Tuple type: [T, U, ...] — bracket at start of type position (not array suffix)
	if (token.kind === TokenKind.LBracket) {
		skipBalanced(state, TokenKind.LBracket, TokenKind.RBracket);
		// Optional marker: [T, U]?
		if (!isAtEnd(state) && current(state).kind === TokenKind.Question) {
			advance(state);
		}
		return;
	}

	// Named type (identifier or keyword type)
	advance(state);
	// Qualified/enum-literal type: K.A — consume .Ident chain greedily
	while (!isAtEnd(state) && current(state).kind === TokenKind.Dot) {
		advance(state); // consume .
		if (isAtEnd(state) || !isTypeIdent(current(state))) break;
		advance(state); // consume member name
	}
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

test "two generics" { assert skipsType("HashMap<string, number>"); }

test "nested generics" { assert skipsType("Result<Array<number>, string>"); }

test "nested generics no space" { assert skipsType("Result<Array<number>>"); }

test "triple nested generics" { assert skipsType("HashMap<string, Result<Array<number>>>"); }

test "array in generic arg" { assert skipsType("Result<Node[], string>"); }

test "array in both generic args" { assert skipsType("HashMap<string[], number[]>"); }

test "single array" { assert skipsType("number[]"); }

test "fixed array" { assert skipsType("number[4]"); }

test "fixed array multi-dimensional" { assert skipsType("number[4][2]"); }

test "double array" { assert skipsType("number[][]"); }

test "generic array" { assert skipsType("Array<string>[]"); }

test "two types" { assert skipsType("string | number"); }

test "three types" { assert skipsType("string | number | boolean"); }

test "union with array" { assert skipsType("string[] | number"); }

test "intersection two types" { assert skipsType("A & B"); }

test "intersection three types" { assert skipsType("A & B & C"); }

test "intersection with generics" { assert skipsType("Result<A, B> & Error"); }

test "intersection branded primitive" { assert skipsType("string & { __brand: \"X\" }"); }

test "intersection mixed with union" { assert skipsType("A | B & C"); }

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

test "optional generic array" { assert skipsType("HashMap<string, number>[]?"); }

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

test "typeExpr intersection" {
	assert typeExprKind("A & B") === NodeKind.TypeIntersection;
}

test "typeExpr branded primitive" {
	// Branded type pattern: `string & { __brand: "X" }` parses as TypeIntersection.
	// Resolver collapses to `string` at type-check time (erasure tier).
	assert typeExprKind("string & { __brand: \"X\" }") === NodeKind.TypeIntersection;
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

// ===== Index Signature Tests =====
// `{ [key: K]: V }` is syntactic sugar for `HashMap<K, V>`. The parser captures
// the key/value types on the TypeObject node; the checker normalizes to HashMap<K,V>.

test "index signature basic" {
	assert skipsType("{ [key: string]: number }");
}

test "index signature with number key" {
	assert skipsType("{ [k: number]: string }");
}

test "index signature with complex value" {
	assert skipsType("{ [key: string]: number[] }");
}

test "index signature nested" {
	assert skipsType("{ [key: string]: { [k: string]: number } }");
}

test "index signature with trailing semicolon" {
	assert skipsType("{ [key: string]: number; }");
}

test "index signature in generic arg" {
	assert skipsType("Result<{ [key: string]: string }, string>");
}

// Parse tests — verify the AST carries the index signature fields
function parseIndexSig(typeStr: string): Node {
	const lr = lex(typeStr + " = x");
	if (!lr.ok) return null as unknown as Node;
	const state = createState(lr.value);
	return parseTypeExpr(state);
}

test "index signature produces TypeObject" {
	const node = parseIndexSig("{ [key: string]: number }");
	assert node !== null;
	assert node.kind === NodeKind.TypeObject;
}

test "index signature has index fields" {
	const node = parseIndexSig("{ [key: string]: number }");
	const d = node.data as TypeObjectData;
	assert d.typExprFieldNames.length === 0;
	assert d.typExprIndexKey !== null;
	assert d.typExprIndexValue !== null;
	assert (d.typExprIndexKey.data as IdentifierData).name === "string";
	assert (d.typExprIndexValue.data as IdentifierData).name === "number";
}

test "non-index-sig object type has null index fields" {
	const node = parseIndexSig("{ x: number, y: string }");
	const d = node.data as TypeObjectData;
	assert d.typExprFieldNames.length === 2;
	assert d.typExprIndexKey === null;
	assert d.typExprIndexValue === null;
}

// E2E C: Type introspection via macros (SERIALIZE Phase A1 Step 3)
//
// Tests that macros can READ `value.nodeType` (synthesized type AST emitted
// by mapTypeToAst + nodeToValue, Days 1-9). The macro body dereferences the
// field path; if any layer is broken (Type→AST mapping, heap serialization,
// Raiser compileMemberExpr), the macro body crashes and compileToC fails.

import { compileToC } from "../helpers";

test "E2E: macro reads nodeType.kind on int32 argument (atomic primitive)" {
	const src = `
import { Node, NodeKind } from "std/meta";

macro typeKindOf(x: Node): Node {
	return {
		kind: NodeKind.NumberLiteral,
		line: x.line,
		column: x.column,
		value: x.nodeType.kind,
		isFloat: false,
	};
}

function main(): void {
	const n: int32 = 42;
	const k = typeKindOf(n);
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E: macro reads nodeType.typExprFieldNames.length on Struct argument" {
	const src = `
import { Node, NodeKind } from "std/meta";

interface User { name: string; age: int32; }

macro fieldCountOf(x: Node): Node {
	return {
		kind: NodeKind.NumberLiteral,
		line: x.line,
		column: x.column,
		value: x.nodeType.typExprFieldNames.length,
		isFloat: false,
	};
}

function main(): void {
	const u: User = { name: "x", age: 1 };
	const n = fieldCountOf(u);
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E: macro reads nodeType.typExprBase.kind on GenericInstance argument" {
	const src = `
import { Node, NodeKind } from "std/meta";

interface Container<T> { items: T[]; }

macro baseKindOf(x: Node): Node {
	return {
		kind: NodeKind.NumberLiteral,
		line: x.line,
		column: x.column,
		value: x.nodeType.typExprBase.kind,
		isFloat: false,
	};
}

function main(): void {
	const c: Container<int32> = { items: [1, 2, 3] };
	const k = baseKindOf(c);
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E: macro reads nodeType.kind on self-referential Tree (cycle safety)" {
	const src = `
import { Node, NodeKind } from "std/meta";

class Tree { children: Tree[]; }

macro typeKindOfTree(x: Node): Node {
	return {
		kind: NodeKind.NumberLiteral,
		line: x.line,
		column: x.column,
		value: x.nodeType.kind,
		isFloat: false,
	};
}

function main(): void {
	const t: Tree = new Tree();
	const k = typeKindOfTree(t);
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E: macro reads nodeType.typExprMembers.length on Union argument" {
	// Use function return type to force Union (avoids narrowing on direct assignment)
	const src = `
import { Node, NodeKind } from "std/meta";

function getEither(b: boolean): string | int32 {
	if (b) return "x";
	return 42;
}

macro variantCountOf(x: Node): Node {
	return {
		kind: NodeKind.NumberLiteral,
		line: x.line,
		column: x.column,
		value: x.nodeType.typExprMembers.length,
		isFloat: false,
	};
}

function main(): void {
	const v = getEither(true);
	const n = variantCountOf(v);
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E: macro inside generic function defers expansion until post-mono (A3)" {
	// `save<T>` body invokes `peek(t)`. At eager-check time, `t.nodeType` is
	// GenericParam("T") — defer fires, MacroInvocation persists.
	// monomorphize generates `save<int32>` with t.nodeType = int32 (concrete).
	// Post-mono expandMacros fires `peek` with `t: int32`, macro succeeds.
	const src = `
import { Node, NodeKind } from "std/meta";

macro peek(x: Node): Node {
	// Reads x.nodeType.kind — would crash if T were still GenericParam.
	// Compiler-driven defer prevents that crash by skipping eager expansion.
	return {
		kind: NodeKind.NumberLiteral,
		line: x.line,
		column: x.column,
		value: x.nodeType.kind,
		isFloat: false,
	};
}

function save<T>(t: T): void {
	const k = peek(t);
}

function main(): void {
	save<int32>(42);
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E: codec-style macro reads typExprFieldNames after defer + monomorphize (A3 acceptance)" {
	// The real A3 use case: codec macro inside a generic helper. At eager-check
	// time, `t.nodeType` is GenericParam — typExprFieldNames doesn't exist on
	// Identifier. Defer holds the call. Mono substitutes T → User. Post-mono
	// expandMacros fires the macro with t.nodeType = TypeObject (Struct shape).
	const src = `
import { Node, NodeKind } from "std/meta";

class User { name: string; age: int32; }

macro fieldCount(x: Node): Node {
	return {
		kind: NodeKind.NumberLiteral,
		line: x.line,
		column: x.column,
		value: x.nodeType.typExprFieldNames.length,
		isFloat: false,
	};
}

function describe<T>(t: T): void {
	const n = fieldCount(t);  // defers: t.nodeType is GenericParam at this point
}

function main(): void {
	const u: User = new User();
	describe<User>(u);
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E: macro defer is per-call — non-generic call site still expands eagerly" {
	const src = `
import { Node, NodeKind } from "std/meta";

macro peek(x: Node): Node {
	return {
		kind: NodeKind.NumberLiteral,
		line: x.line,
		column: x.column,
		value: x.nodeType.kind,
		isFloat: false,
	};
}

function main(): void {
	const n: int32 = 42;
	const k = peek(n);  // concrete type — eager expansion fires immediately
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E: macro reads resolvedSym.name on bound Identifier (Day 9 surface)" {
	const src = `
import { Node, NodeKind } from "std/meta";

macro symKindOf(x: Node): Node {
	return {
		kind: NodeKind.NumberLiteral,
		line: x.line,
		column: x.column,
		value: x.resolvedSym.kind,
		isFloat: false,
	};
}

function main(): void {
	const myVar: int32 = 7;
	const s = symKindOf(myVar);
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E: macro reads typExprFieldDecorators[0][0].kind on @-decorated class field (V2 gate)" {
	const src = `
import { Node, NodeKind } from "std/meta";

class Doc {
	@rename("_id") id: string;
	name: string;
}

macro firstDecoratorKind(x: Node): Node {
	return {
		kind: NodeKind.NumberLiteral,
		line: x.line,
		column: x.column,
		value: x.nodeType.typExprFieldDecorators[0][0].kind,
		isFloat: false,
	};
}

function main(): void {
	const d: Doc = new Doc();
	const k = firstDecoratorKind(d);
}
`;
	const c = compileToC(src);
	assert c.ok;
}

// E2E C: Type introspection via macros (SERIALIZE Phase A1 Step 3)
//
// Tests that macros can READ `value.nodeType` (synthesized type AST emitted
// by mapTypeToAst + nodeToValue, Days 1-9). The macro body dereferences the
// field path; if any layer is broken (Type→AST mapping, heap serialization,
// Raiser compileMemberExpr), the macro body crashes and compileToC fails.

import { compileToCWithStd } from "../helpers";

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
	const c = compileToCWithStd(src);
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
	const c = compileToCWithStd(src);
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
	const c = compileToCWithStd(src);
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
	const c = compileToCWithStd(src);
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
	const c = compileToCWithStd(src);
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
	const c = compileToCWithStd(src);
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
	const c = compileToCWithStd(src);
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
	const c = compileToCWithStd(src);
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
	const c = compileToCWithStd(src);
	assert c.ok;
}

test "E2E: macro reads typExprFieldDecorators[0][0].kind on @-decorated class field (V2 gate)" {
	const src = `
import { Node, NodeKind } from "std/meta";

function rename(name: string): (value: Node) => void {
	return (value: Node): void => {};
}

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
	const c = compileToCWithStd(src);
	assert c.ok;
}

test "E2E: static getTypeImpl on a class declared later in the module sees shaped field types" {
	const src = `
import { Node, NodeKind, ClassDecoratorContext } from "std/meta";

macro check(value: Node, context: ClassDecoratorContext): Node {
	const t = getTypeImpl(Later);
	if (t.typExprFieldNames.length != 2) error("expected 2 fields, got " + t.typExprFieldNames.length, value);
	const y = t.typExprFieldTypes[0];
	if (y.kind != NodeKind.Identifier || y.name != "int32") error("y is not int32: " + y.name, value);
	const arr = t.typExprFieldTypes[1];
	if (arr.kind == NodeKind.Identifier) error("arr collapsed to " + arr.name, value);
	return value;
}

@check
class Widget { a: int32 = 1; }

class Later {
	y: int32 = 2;
	arr: int32[] = [];
}

function main(): void {
	const w = new Widget();
	const l = new Later();
}
main();
`;
	const c = compileToCWithStd(src);
	assert c.ok;
}

test "E2E: dynamic bindSym plus runtime getTypeImpl from a decorator on a class declared later" {
	const src = `
import { Node, NodeKind, ClassDecoratorContext, bindSym, getTypeImpl } from "std/meta";

macro check(value: Node, context: ClassDecoratorContext): Node {
	const name = "La" + "ter";
	const sym = bindSym(name);
	if (sym == null) error("bindSym missed " + name, value);
	else {
		const t = getTypeImpl(sym);
		if (t == null) error("getTypeImpl returned null", value);
		else if (t.typExprFieldNames.length != 1) error("expected 1 field", value);
		else {
			const y = t.typExprFieldTypes[0];
			if (y.kind != NodeKind.Identifier || y.name != "int32") error("y is not int32", value);
		}
	}
	return value;
}

@check
class Widget { a: int32 = 1; }

class Later { y: int32 = 2; }

function main(): void {
	const w = new Widget();
	const l = new Later();
}
main();
`;
	const c = compileToCWithStd(src);
	assert c.ok;
}

test "E2E: getImpl returns the declaration of a bound class symbol" {
	const src = `
import { Node, NodeKind, ClassDecoratorContext, getImpl } from "std/meta";

macro check(value: Node, context: ClassDecoratorContext): Node {
	const d = getImpl(bindSym("Later"));
	if (d == null) error("getImpl returned null", value);
	else if (d.kind != NodeKind.ClassDecl) error("not a class decl: " + d.kind, value);
	else if (d.classBody.length != 2) error("expected 2 members", value);
	return value;
}

@check
class Widget { a: int32 = 1; }

class Later {
	y: int32 = 2;
	z: string = "";
}

function main(): void {
	const w = new Widget();
	const l = new Later();
}
main();
`;
	const c = compileToCWithStd(src);
	assert c.ok;
}

test "E2E: resolveType resolves annotation text in the decorated module scope" {
	const src = `
import { Node, NodeKind, ClassDecoratorContext, resolveType } from "std/meta";

macro check(value: Node, context: ClassDecoratorContext): Node {
	let seen = 0;
	for (const m of value.classBody) {
		if (m.kind == NodeKind.PropertyDecl) {
			const t = resolveType(m.propType);
			if (t == null) error("resolveType returned null for " + m.propName, value);
			else if (m.propName == "a" && (t.kind != NodeKind.Identifier || t.name != "int32")) error("a is not int32", value);
			else if (m.propName == "b" && t.kind != NodeKind.TypeUnion) error("b is not a union: " + t.kind, value);
			else seen = seen + 1;
		}
	}
	if (seen != 2) error("saw " + seen + " fields", value);
	return value;
}

@check
class Widget {
	a: int32 = 1;
	b: Later | null = null;
}

class Later { y: int32 = 2; }

function main(): void {
	const w = new Widget();
	const l = new Later();
}
main();
`;
	const c = compileToCWithStd(src);
	assert c.ok;
}

test "E2E: querying the class under decoration is a loud error" {
	const src = `
import { Node, NodeKind, ClassDecoratorContext, getTypeImpl } from "std/meta";

macro check(value: Node, context: ClassDecoratorContext): Node {
	const t = getTypeImpl(bindSym("Widget"));
	return value;
}

@check
class Widget { a: int32 = 1; }

function main(): void {
	const w = new Widget();
}
main();
`;
	const c = compileToCWithStd(src);
	assert !c.ok;
	if (!c.ok) assert c.error.contains("still being decorated");
}

test "E2E: a forward class referenced through another type renders name-only and is upgraded in place" {
	const src = `
import { Node, NodeKind, ClassDecoratorContext, bindSym, getTypeImpl } from "std/meta";

macro check(value: Node, context: ClassDecoratorContext): Node {
	const t = getTypeImpl(bindSym("Holder"));
	if (t == null) error("getTypeImpl returned null", value);
	else {
		let inner = t.typExprFieldTypes[0];
		if (inner.kind == NodeKind.TypeGeneric) inner = inner.typExprArgs[0];
		if (inner.kind != NodeKind.Identifier || inner.name != "Widget") error("forward class did not render name-only: " + inner.kind, value);
	}
	value.classBody.push({
		kind: NodeKind.PropertyDecl, line: value.line, column: value.column,
		propName: "extra", propType: "int32", propIsStatic: false, propIsReadonly: false,
		propVisibility: "public",
		propInitializer: { kind: NodeKind.NumberLiteral, line: value.line, column: value.column, value: 42, isFloat: false },
	});
	return value;
}

@check
class Widget { a: int32 = 1; }

class Holder { w: Widget = new Widget(); }

function main(): void {
	const h = new Holder();
	const k: int32 = h.w.extra;
}
main();
`;
	const c = compileToCWithStd(src);
	assert c.ok;
}

test "E2E: error() inside a decorator body is reported at the decorated declaration" {
	const src = `
import { Node, NodeKind, ClassDecoratorContext } from "std/meta";

macro check(value: Node, context: ClassDecoratorContext): Node {
	if (value.classBody.length == 1) error("boom", value);
	return value;
}

@check
class Widget { a: int32 = 1; }

function main(): void {
	const w = new Widget();
}
main();
`;
	const c = compileToCWithStd(src);
	assert !c.ok;
	if (!c.ok) assert c.error.contains("boom");
}

test "E2E: dynamic bindSym inside an expression macro sees a function-local symbol" {
	const src = `
import { Node, NodeKind, bindSym, getType } from "std/meta";

macro localIsInt(x: Node): Node {
	const s = bindSym("lo" + "cal");
	if (s == null) error("dynamic bindSym missed the local", x);
	else {
		const t = getType(s);
		if (t == null) error("getType returned null", x);
		else if (t.kind != NodeKind.Identifier || t.name != "int32") error("local is not int32", x);
	}
	return x;
}

function main(): void {
	const local: int32 = 1;
	const k = localIsInt(local);
}
main();
`;
	const c = compileToCWithStd(src);
	assert c.ok;
}

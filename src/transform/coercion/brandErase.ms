// Brand erasure — TS branded primitives exist only in the checker (TSGAP
// item 5 S1). Erasing BrandWiden Distincts to their base BEFORE any lowering
// means string/number lowerings and codegen never see a Distinct to peel.

import { Node, Type, TypeKind, TypeFlag, ProgramData, ExprStmtData, BinaryExprData } from "../../ast/node";
import { mapChildren } from "../walker";
import { TransformContext, ModuleFact } from "../context";
import { factsOf } from "../moduleFacts";
import { parseInput, makeCtx } from "../testUtil";

const ERASE_MAX_DEPTH: int32 = 8;

function eraseBrandType(t: Type | null, depth: int32): Type | null {
	if (t == null || depth > ERASE_MAX_DEPTH) return t;
	if (t.kind == TypeKind.Distinct && t.typeFlags.has(TypeFlag.BrandWiden) && t.typeReturn != null) {
		return eraseBrandType(t.typeReturn, depth + 1);
	}
	if (t.kind == TypeKind.Union && t.typeChildren != null) {
		for (let i = 0; i < t.typeChildren.length; i += 1) {
			t.typeChildren[i] = eraseBrandType(t.typeChildren[i], depth + 1) as Type;
		}
	}
	if (t.typeReturn != null && (t.kind == TypeKind.Array || t.kind == TypeKind.SizedArray
		|| t.kind == TypeKind.Ref || t.kind == TypeKind.Ptr || t.kind == TypeKind.Span
		|| t.kind == TypeKind.Var || t.kind == TypeKind.Borrow)) {
		t.typeReturn = eraseBrandType(t.typeReturn, depth + 1) as Type;
	}
	return t;
}

let seenFacts = 0 as BitSet<ModuleFact>;

function walkErase(node: Node): Node {
	if (node == null) return node;
	if (node.nodeType != null) {
		node.nodeType = eraseBrandType(node.nodeType, 0) as Type;
	}
	mapChildren(node, walkErase);
	seenFacts = seenFacts.union(factsOf(node));
	return node;
}

export function eraseBrandTypes(program: Node, ctx: TransformContext): Node {
	seenFacts = 0 as BitSet<ModuleFact>;
	const erased = walkErase(program);
	ctx.facts = ctx.facts.union(seenFacts);
	ctx.factsCollected = true;
	return erased;
}

function scannedFacts(src: string): BitSet<ModuleFact> {
	const parsed = parseInput(src);
	const ctx = makeCtx();
	if (parsed.ok) eraseBrandTypes(parsed.value, ctx);
	return ctx.facts;
}

function scansAs(src: string, f: ModuleFact): boolean {
	const facts = scannedFacts(src);
	return facts.has(f) && facts.size() == 1;
}

test "a module without a gated feature collects no fact" {
	const src = "const a = 1; function f(x: int32): int32 { return x > a ? x : a; }";
	assert parseInput(src).ok;
	assert scannedFacts(src).isEmpty();
}

test "the brand-erasure walk collects each gated feature wherever it sits" {
	assert scansAs("async function f(): Promise<void> {}", ModuleFact.Async);
	assert scansAs("const h = async () => 1;", ModuleFact.Async);
	assert scansAs("class C { async m(): Promise<void> {} }", ModuleFact.Async);
	assert scansAs("function* g() { yield 1; }", ModuleFact.Generator);
	assert scansAs("const g = function* () { yield 1; };", ModuleFact.Generator);
	assert scansAs("function f() { defer g(); }", ModuleFact.Defer);
	assert scansAs("const h = () => { defer { g(); } };", ModuleFact.Defer);
	assert scansAs("a?.b;", ModuleFact.OptionalChain);
	assert scansAs("function f() { return g(a.b?.c); }", ModuleFact.OptionalChain);
	assert scansAs("x ?? 1;", ModuleFact.Nullish);
	assert scansAs("class C { v = g() ?? 1; }", ModuleFact.Nullish);
	assert scansAs("f([...xs]);", ModuleFact.Spread);
	assert scansAs("const o = { ...p, a: 1 };", ModuleFact.Spread);
	assert scansAs("switch (x) { case 1: f(); }", ModuleFact.Switch);
	assert scansAs("function f() { while (c) { switch (x) { default: g(); } } }", ModuleFact.Switch);
}

test "a logical assignment collects the nullish fact, since the nullish pass lowers it" {
	const parsed = parseInput("x += 1;");
	assert parsed.ok;
	const stmt = (parsed.value.data as ProgramData).programStmts[0];
	const assign = (stmt.data as ExprStmtData).expr;
	for (const op of ["??=", "||=", "&&="]) {
		(assign.data as BinaryExprData).operator = op;
		const facts = factsOf(assign);
		assert facts.has(ModuleFact.Nullish) && facts.size() == 1, op;
	}
	(assign.data as BinaryExprData).operator = "+=";
	assert factsOf(assign).isEmpty();
}

test "an await collects both the await and its async routine" {
	const facts = scannedFacts("async function f() { await g(); }");
	assert facts.has(ModuleFact.Async) && facts.has(ModuleFact.Await) && facts.size() == 2;
}

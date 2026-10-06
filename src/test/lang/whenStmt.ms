// Conditional compilation — `when (flag) { … } else when (…) { … } else { … }`.
//
// Mechanism follows Nim (`semWhen`, semexprs.nim:2656) and Haxe (`#if`): the taken
// branch's statements are SPLICED into the enclosing statement list (no new scope,
// Nim's nkStmtList), and the untaken branches are dropped without ever being
// type-checked. MetaScript cuts at PARSE — Haxe's placement rather than Nim's sem —
// because collectTopLevel would otherwise register declarations from a dead branch.
//
// Flags come from the define table (src/compiler/defines.ms, a port of Nim's
// condsyms.nim); the parser reads it through a side channel.

import { compileToC, compileToCWithStd } from "../helpers";
import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { setParserDefines, resetParserDefines } from "../../parser/context";
import { DefineTable, createDefineTable, defineSymbol, applyDefineSwitch } from "../../compiler/defines";
import { Node, NodeKind, NodeFlag, ProgramData, FunctionDeclData, BlockStmtData, IfStmtData } from "../../ast/node";

function withFlags(pairs: string[]): DefineTable {
	const t = createDefineTable();
	for (const p of pairs) { applyDefineSwitch(t, "-d:" + p); }
	return t;
}

function topLevel(source: string, flags: string[]): Node[] {
	setParserDefines(withFlags(flags));
	const parsed = parseSource(source);
	resetParserDefines();
	if (!parsed.ok) return [];
	return (parsed.value.data as ProgramData).programStmts;
}

test "when: taken branch splices its statements into the parent list" {
	const stmts = topLevel("when (js) { const a = 1; const b = 2; }", ["js"]);
	assert stmts.length == 2;
	assert stmts[0].kind == NodeKind.VariableDecl;
	assert stmts[1].kind == NodeKind.VariableDecl;
}

test "when: untaken branch is dropped entirely" {
	const stmts = topLevel("when (js) { const a = 1; }", ["c"]);
	assert stmts.length == 0;
}

test "when: unknown flag is false, not an error" {
	const stmts = topLevel("when (nosuchflag) { const a = 1; }", ["c"]);
	assert stmts.length == 0;
}

test "when: else branch runs when the condition is false" {
	const stmts = topLevel("when (js) { const a = 1; } else { const b = 2; const c = 3; }", ["c"]);
	assert stmts.length == 2;
}

test "when: else-when chain picks the first true branch" {
	const src = "when (js) { const a = 1; } else when (c) { const b = 2; const bb = 3; } else { const z = 9; }";
	const stmts = topLevel(src, ["c"]);
	assert stmts.length == 2;
}

test "when: chain with no match yields nothing" {
	const src = "when (js) { const a = 1; } else when (erlang) { const b = 2; }";
	const stmts = topLevel(src, ["c"]);
	assert stmts.length == 0;
}

test "when: negation" {
	const stmts = topLevel("when (!js) { const a = 1; }", ["c"]);
	assert stmts.length == 1;
}

test "when: conjunction and disjunction" {
	assert topLevel("when (c && !debug) { const a = 1; }", ["c"]).length == 1;
	assert topLevel("when (c && debug) { const a = 1; }", ["c"]).length == 0;
	assert topLevel("when (js || c) { const a = 1; }", ["c"]).length == 1;
}

test "when: value flag compares numerically" {
	assert topLevel("when (tier > 2) { const a = 1; }", ["tier=3"]).length == 1;
	assert topLevel("when (tier > 5) { const a = 1; }", ["tier=3"]).length == 0;
	assert topLevel("when (tier == 3) { const a = 1; }", ["tier=3"]).length == 1;
}

test "when: value flag compares as string when not numeric" {
	assert topLevel(`when (mode == "danger") { const a = 1; }`, ["mode=danger"]).length == 1;
	assert topLevel(`when (mode == "debug") { const a = 1; }`, ["mode=danger"]).length == 0;
}

test "when: nested blocks splice correctly" {
	const src = "when (c) { when (debug) { const a = 1; } const b = 2; }";
	const stmts = topLevel(src, ["c", "debug"]);
	assert stmts.length == 2;
}

test "when: top-level declarations splice at program level" {
	const stmts = topLevel("when (c) { export function f(): number { return 1; } }", ["c"]);
	assert stmts.length == 1;
	assert stmts[0].kind == NodeKind.ExportDecl;
}

test "when: inside a function body" {
	const src = "function g(): number { when (c) { return 1; } return 2; }";
	const stmts = topLevel(src, ["c"]);
	assert stmts.length == 1;
	assert stmts[0].kind == NodeKind.FunctionDecl;
}

// The load-bearing invariant: a dropped branch never reaches the checker, so it may
// name symbols that do not exist on this target (Nim semexprs.nim:2705 returns on the
// first true branch; Haxe: "not type-checked").
test "when: dropped branch is never type-checked" {
	setParserDefines(withFlags(["c"]));
	const r = compileToC(`
when (js) {
	function jsOnly(): number { return totallyUndefinedSymbol(1, 2, 3); }
}
function main(): void { console.log("ok"); }
`);
	resetParserDefines();
	assert r.ok;
}

test "when: taken branch IS type-checked" {
	setParserDefines(withFlags(["c"]));
	const r = compileToC(`
when (c) {
	function bad(): number { return totallyUndefinedSymbol(1); }
}
function main(): void { console.log("ok"); }
`);
	resetParserDefines();
	assert !r.ok;
}

function bodyOf(fn: Node): Node[] {
	return ((fn.data as FunctionDeclData).fnBody.data as BlockStmtData).statements;
}

test "when: a type-trait condition keeps the chain for the checker" {
	const stmts = topLevel("function g<T>(): number { when (isPlainData<T>()) { return 1; } else { return 2; } }", ["c"]);
	assert stmts.length == 1;
	const body = bodyOf(stmts[0]);
	assert body.length == 1;
	assert body[0].kind == NodeKind.IfStmt && body[0].flags.has(NodeFlag.WhenDeferred);
	assert (body[0].data as IfStmtData).condition.kind == NodeKind.CallExpr;
}

test "when: flags ahead of a type trait still decide at parse" {
	const src = "function g<T>(): number { when (c) { return 1; } else when (isPlainData<T>()) { return 2; } return 3; }";
	const takenTop = topLevel(src, ["c"]);
	assert takenTop.length == 1;
	const taken = bodyOf(takenTop[0]);
	assert taken.length == 2 && taken[0].kind == NodeKind.ReturnStmt;
	const deferredTop = topLevel(src, ["js"]);
	assert deferredTop.length == 1;
	const deferred = bodyOf(deferredTop[0]);
	assert deferred.length == 2 && deferred[0].flags.has(NodeFlag.WhenDeferred);
}

test "when: a type-trait condition at module level is refused" {
	const r = parseSource("when (isPlainData<int32>()) { const a = 1; }");
	assert !r.ok;
	if (!r.ok) { assert r.error.contains("function body"); }
}

test "when: a type-trait branch is picked per instance and the other is never checked" {
	const r = compileToCWithStd(`
import { isPlainData } from "std/typetraits";
function onlyPlain<T>(x: T): int32 {
	when (isPlainData<T>()) { return sizeof(T); } else { return x.length; }
}
function main(): void { console.log(onlyPlain(1 as int32) + onlyPlain("abc")); }
`);
	assert r.ok;
}

test "when: the picked type-trait branch IS checked for its instance" {
	const r = compileToCWithStd(`
import { isPlainData } from "std/typetraits";
function f<T>(x: T): int32 {
	when (isPlainData<T>()) { return x.nope; } else { return 0; }
}
function main(): void { console.log(f<string>("a") + f<int32>(1)); }
`);
	assert !r.ok;
	if (!r.ok) { assert r.error.contains("nope"); }
}

test "when: a call that is not a type trait is refused in a condition" {
	const r = compileToCWithStd(`
function yes<T>(): boolean { return true; }
function f<T>(): int32 {
	when (yes<T>()) { return 1; } else { return 2; }
}
function main(): void { console.log(f<int32>()); }
`);
	assert !r.ok;
	if (!r.ok) { assert r.error.contains("type traits"); }
}

// `@target` / `@platform` are retired in favour of `when`. They must DIAGNOSE, not
// silently drop: a directive block that vanishes without a word is exactly how
// `@target` passed for a working feature while gating nothing.
test "when: @target is retired with a migration message" {
	const r = compileToC(`
@target("c") { function f(): number { return 1; } }
function main(): void { console.log("ok"); }
`);
	assert !r.ok;
	if (!r.ok) { assert r.error.contains("retired"); }
}

test "when: @platform is retired with a migration message" {
	const r = compileToC(`
@platform("macos") { @passL("-framework Foundation"); }
function main(): void { console.log("ok"); }
`);
	assert !r.ok;
	if (!r.ok) { assert r.error.contains("retired"); }
}

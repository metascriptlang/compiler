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

import { compileToC } from "../helpers";
import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { setParserDefines, resetParserDefines } from "../../parser/context";
import { DefineTable, createDefineTable, defineSymbol, applyDefineSwitch } from "../../compiler/defines";
import { Node, NodeKind, ProgramData } from "../../ast/node";

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
	assert stmts.length === 2;
	assert stmts[0].kind === NodeKind.VariableDecl;
	assert stmts[1].kind === NodeKind.VariableDecl;
}

test "when: untaken branch is dropped entirely" {
	const stmts = topLevel("when (js) { const a = 1; }", ["c"]);
	assert stmts.length === 0;
}

test "when: unknown flag is false, not an error" {
	const stmts = topLevel("when (nosuchflag) { const a = 1; }", ["c"]);
	assert stmts.length === 0;
}

test "when: else branch runs when the condition is false" {
	const stmts = topLevel("when (js) { const a = 1; } else { const b = 2; const c = 3; }", ["c"]);
	assert stmts.length === 2;
}

test "when: else-when chain picks the first true branch" {
	const src = "when (js) { const a = 1; } else when (c) { const b = 2; const bb = 3; } else { const z = 9; }";
	const stmts = topLevel(src, ["c"]);
	assert stmts.length === 2;
}

test "when: chain with no match yields nothing" {
	const src = "when (js) { const a = 1; } else when (erlang) { const b = 2; }";
	const stmts = topLevel(src, ["c"]);
	assert stmts.length === 0;
}

test "when: negation" {
	const stmts = topLevel("when (!js) { const a = 1; }", ["c"]);
	assert stmts.length === 1;
}

test "when: conjunction and disjunction" {
	assert topLevel("when (c && !debug) { const a = 1; }", ["c"]).length === 1;
	assert topLevel("when (c && debug) { const a = 1; }", ["c"]).length === 0;
	assert topLevel("when (js || c) { const a = 1; }", ["c"]).length === 1;
}

test "when: value flag compares numerically" {
	assert topLevel("when (tier > 2) { const a = 1; }", ["tier=3"]).length === 1;
	assert topLevel("when (tier > 5) { const a = 1; }", ["tier=3"]).length === 0;
	assert topLevel("when (tier == 3) { const a = 1; }", ["tier=3"]).length === 1;
}

test "when: value flag compares as string when not numeric" {
	assert topLevel(`when (mode == "danger") { const a = 1; }`, ["mode=danger"]).length === 1;
	assert topLevel(`when (mode == "debug") { const a = 1; }`, ["mode=danger"]).length === 0;
}

test "when: nested blocks splice correctly" {
	const src = "when (c) { when (debug) { const a = 1; } const b = 2; }";
	const stmts = topLevel(src, ["c", "debug"]);
	assert stmts.length === 2;
}

test "when: top-level declarations splice at program level" {
	const stmts = topLevel("when (c) { export function f(): number { return 1; } }", ["c"]);
	assert stmts.length === 1;
	assert stmts[0].kind === NodeKind.ExportDecl;
}

test "when: inside a function body" {
	const src = "function g(): number { when (c) { return 1; } return 2; }";
	const stmts = topLevel(src, ["c"]);
	assert stmts.length === 1;
	assert stmts[0].kind === NodeKind.FunctionDecl;
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

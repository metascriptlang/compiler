// Dead Code Elimination — stub implementation
// Marks all symbols as alive (trivial single-module behavior).
// Real DCE needs cross-module graph (deferred to multi-module pipeline).
//
// API established for Phase 5 codegen:
//   isAlive(syms, name) → boolean
//   lowerDCE(program, ctx) → Node (passthrough)

import { Node, NodeKind } from "../../ast/node";
import { TransformContext, NameSet, nameSetAdd, nameSetContains } from "../context";
import { test, check, testGroup } from "std/testing";
import { stmtCountAfter, firstStmtKindAfter } from "../testUtil";

// ===== AliveSyms =====
// Re-exports NameSet as AliveSyms for API compatibility.

export function createAliveSyms(): NameSet {
	const syms: NameSet = { names: [] };
	return syms;
}

export function markAlive(syms: NameSet, name: string): void {
	nameSetAdd(syms, name);
}

export function isAlive(syms: NameSet, name: string): boolean {
	// Stub: everything is alive in single-module mode
	return true;
}

// ===== Main Entry Point =====

export function lowerDCE(program: Node, ctx: TransformContext): Node {
	// Stub: no analysis, return program unchanged.
	// Future: seed worklist with exports + main, walk reachable symbols,
	// collect into AliveSyms for codegen to query.
	return program;
}

// ===== Tests =====

testGroup("DCE Stub", () => {
	test("passthrough unchanged", () => {
		check(stmtCountAfter("const x = 1;", lowerDCE) === 1);
	});
	test("isAlive always true", () => {
		const syms = createAliveSyms();
		check(isAlive(syms, "anything") === true);
		check(isAlive(syms, "nonexistent") === true);
	});
	test("function passthrough", () => {
		check(firstStmtKindAfter("function foo() { return 1; }", lowerDCE) === NodeKind.FunctionDecl);
	});
});

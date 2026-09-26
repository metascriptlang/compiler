// Defer Lowering — transforms DeferStmt → TryCatchStmt with finally
//
// Input:  defer cleanup();  stmt1; stmt2;
// Output: try { stmt1; stmt2; } finally { cleanup(); }
//
// Multiple defers nest: last defer is innermost finally.
//
// DRC safety notes:
// - `const d = node.data as SomeData` creates a raw struct copy in C with shared
//   array backing buffers. Reassigning d.field corrupts the shared buffer.
// - Fix: use `node.data = { ... }` to write back to the actual node.
// - Node* fields work through pointers: lowerDeferInNode(d.fnBody) modifies
//   the body node in-place (data changes, pointer stays same).

import { Node, NodeKind, SourceLocation, ProgramData, BlockStmtData, DeferStmtData, SwitchCaseData } from "../../ast/node";
import { forEachChild } from "../../ast/visitor";
import { TransformContext } from "../context";
import { makeBlock, makeExprStmt, makeTryFinally } from "../util";
import { stmtCountAfter, firstStmtKindAfter, parseInput, makeCtx } from "../testUtil";

// ===== Main Entry Point =====

export function lowerDefer(program: Node, ctx: TransformContext): Node {
	lowerDeferInNode(program);
	return program;
}

// ===== Check if a statement list contains any DeferStmt =====

function hasDefer(stmts: Node[]): boolean {
	for (const stmt of stmts) {
		if (stmt.kind == NodeKind.DeferStmt) return true;
	}
	return false;
}

// ===== Recursive Node Lowering =====
// Every statement list (program, block, switch case) lowers its defers; every
// other node only recurses into its children, so no node kind can hide a defer.

function lowerDeferInNode(node: Node): void {
	match (node.kind) {
		NodeKind.Program => {
			const d = node.data as ProgramData;
			if (hasDefer(d.programStmts)) {
				const newStmts = lowerDeferInBlock(d.programStmts, node.location);
				walkStmtList(newStmts);
				node.data = { programStmts: newStmts };
			} else {
				walkStmtList(d.programStmts);
			}
		},
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			if (hasDefer(d.statements)) {
				const newStmts = lowerDeferInBlock(d.statements, node.location);
				walkStmtList(newStmts);
				node.data = { statements: newStmts };
			} else {
				walkStmtList(d.statements);
			}
		},
		NodeKind.SwitchCase => {
			const d = node.data as SwitchCaseData;
			if (hasDefer(d.caseStmts)) {
				const newStmts = lowerDeferInBlock(d.caseStmts, node.location);
				walkStmtList(newStmts);
				node.data = { caseTests: d.caseTests, caseStmts: newStmts, isDefault: d.isDefault };
			} else {
				walkStmtList(d.caseStmts);
			}
		},
		_ => {
			forEachChild(node, (child: Node): void => lowerDeferInNode(child));
		},
	};
}

// Walk a statement list recursively (for nodes already processed by lowerDeferInBlock)
function walkStmtList(stmts: Node[]): void {
	for (const stmt of stmts) {
		lowerDeferInNode(stmt);
	}
}

// ===== Core: Lower Defers in a Statement List =====
// PRECONDITION: stmts contains at least one DeferStmt (checked by hasDefer).
// Always returns a freshly built array (never returns stmts parameter unchanged).
// Uses in-place recursion via lowerDeferInNode to avoid Node[] return aliasing.

function lowerDeferInBlock(stmts: Node[], loc: SourceLocation): Node[] {
	let deferIdx = 0;
	for (deferIdx = 0; deferIdx < stmts.length; deferIdx += 1) {
		if (stmts[deferIdx].kind == NodeKind.DeferStmt) break;
	}

	// Extract defer info
	const deferData = stmts[deferIdx].data as DeferStmtData;
	const deferBody = deferData.deferExpr;
	const deferLoc = stmts[deferIdx].location;

	// Build "after" stmts into a BlockStmt (sink semantics move the array)
	const afterStmts: Node[] = [];
	for (let a = deferIdx + 1; a < stmts.length; a += 1) {
		afterStmts.push(stmts[a]);
	}
	const tryBody = makeBlock(afterStmts, deferLoc);

	// Recursively lower nested defers in-place (no array return aliasing)
	lowerDeferInNode(tryBody);

	// Build try { after... } finally { deferBody }
	const emptyBlock = makeBlock([], deferLoc);
	// If deferBody is already a BlockStmt, use it directly as finallyBody.
	// Otherwise wrap the expression in an ExprStmt inside a BlockStmt.
	let finallyBody: Node = emptyBlock;
	if (deferBody.kind == NodeKind.BlockStmt) {
		finallyBody = deferBody;
	} else {
		finallyBody = makeBlock([makeExprStmt(deferBody, deferLoc)], deferLoc);
	}
	const tryCatch = makeTryFinally(tryBody, finallyBody, deferLoc);

	// Result: before + [tryCatch]
	const result: Node[] = [];
	for (let b = 0; b < deferIdx; b += 1) {
		result.push(stmts[b]);
	}
	result.push(tryCatch);
	return result;
}

// ===== Tests =====
test "no defer passthrough" { assert firstStmtKindAfter("const x = 1;", lowerDefer) == NodeKind.VariableDecl; }

test "single defer becomes try-catch" { assert firstStmtKindAfter("defer cleanup(); work();", lowerDefer) == NodeKind.TryCatchStmt; }

test "defer at start" {
	assert stmtCountAfter("defer cleanup();", lowerDefer) == 1;
	assert firstStmtKindAfter("defer cleanup();", lowerDefer) == NodeKind.TryCatchStmt;
}

test "defer preserves before stmts" { assert stmtCountAfter("setup(); defer cleanup(); work();", lowerDefer) == 2; }

test "multiple defers nest" {
	assert stmtCountAfter("defer a(); defer b(); work();", lowerDefer) == 1;
	assert firstStmtKindAfter("defer a(); defer b(); work();", lowerDefer) == NodeKind.TryCatchStmt;
}

function holdsDefer(node: Node): boolean {
	if (node.kind == NodeKind.DeferStmt) return true;
	let found = false;
	forEachChild(node, (child: Node): void => {
		if (!found && holdsDefer(child)) found = true;
	});
	return found;
}

function deferLeftAfter(input: string): boolean {
	const r = parseInput(input);
	if (!r.ok) return true;
	lowerDefer(r.value, makeCtx());
	return holdsDefer(r.value);
}

test "defer in a switch case lowers" { assert !deferLeftAfter("switch (k) { case 1: defer a(); b(); default: c(); }"); }

test "defer in an arrow argument lowers" { assert !deferLeftAfter("each(xs, (x) => { defer a(); b(); });"); }

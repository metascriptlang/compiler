// DRC Post-Optimizer — eliminate redundant RC operation pairs
//
// Pattern: wasMoved(x); destroy(x); → remove the destroy
// When a variable is marked as moved (wasMoved zeroes it), the subsequent
// destroy is a no-op on a zeroed value. Removing it saves a function call.
//
// Walks all blocks recursively, scanning consecutive statements.

import {
	Node, NodeKind, ProgramData,
	BlockStmtData, ExprStmtData, CallExprData, IdentifierData,
	FunctionDeclData, IfStmtData, WhileStmtData, ForStmtData,
	TryCatchStmtData, SwitchStmtData, SwitchCaseData,
	ExportDeclData, ClassDeclData, MethodDeclData, ConstructorDeclData,
	ForOfStmtData, DoWhileStmtData,
} from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { NameSet, createNameSet, nameSetContains, nameSetAdd, nameSetIntersect } from "../transform/context";
import { makeIdent, makeBlock, makeExprStmt, makeCall } from "../transform/util";
import { testLoc } from "./inject";

// ===== Known wasMoved / destroy function names =====

function isWasMovedFn(name: string): boolean {
	return name === "msStringWasMoved"
		|| name === "msArrayNumberWasMoved"
		|| name === "msArrayStringWasMoved"
		|| name === "msArrayRefWasMoved"
		|| name === "msClosureWasMoved"
		|| name === "msPtrWasMoved"
		|| name.endsWith("WasMoved");
}

function isDestroyFn(name: string): boolean {
	return name === "msStringDecref"
		|| name === "msDecref"
		|| name === "msArrayDestroy"
		|| name === "msArrayStringDestroy"
		|| name === "msArrayRefDestroy"
		|| name === "msClosureDestroy"
		|| name.endsWith("Destroy");
}


// ===== Moved-var tracking for branch-aware optimization =====
// Uses NameSet from transform/context (DRY: same interface as NameSet was).

// Scan a block's top-level statements for wasMoved calls
function collectBlockMoved(block: Node): NameSet {
	const result: NameSet = createNameSet();
	if (block === null) return result;
	if (block.kind !== NodeKind.BlockStmt) return result;
	const bd = block.data as BlockStmtData;
	for (const stmt of bd.statements) {
		const wm = getWasMovedVar(stmt);
		if (wm !== "") {
			nameSetAdd(result, wm);
		}
		// Also collect from nested if/else branches
		if (stmt.kind === NodeKind.IfStmt) {
			const nested = collectIfMoved(stmt);
			for (const v of nested.items) {
				nameSetAdd(result, v);
			}
		}
	}
	return result;
}

// Collect moved vars from if/else — intersection of all branches
function collectIfMoved(ifNode: Node): NameSet {
	const d = ifNode.data as IfStmtData;
	const consMoved = collectBlockMoved(d.consequent);

	// No else — can't guarantee moved on all paths
	if (d.alternate === null) return createNameSet();

	// else-if chain: recurse
	if (d.alternate.kind === NodeKind.IfStmt) {
		const altMoved = collectIfMoved(d.alternate);
		return nameSetIntersect(consMoved, altMoved);
	}

	// else block
	const altMoved = collectBlockMoved(d.alternate);
	return nameSetIntersect(consMoved, altMoved);
}

// ===== Extract var name from wasMoved/destroy call =====

// Extract single argument name from a call expression statement
function extractSingleCallArg(stmt: Node): string {
	if (stmt === null || stmt.kind !== NodeKind.ExprStmt) return "";
	const ed = stmt.data as ExprStmtData;
	if (ed.expr === null || ed.expr.kind !== NodeKind.CallExpr) return "";
	const cd = ed.expr.data as CallExprData;
	if (cd.arguments.length !== 1) return "";
	// Access arguments[0] inline — avoid local Node variable (DRC use-after-free on return)
	if (cd.arguments[0] === null || cd.arguments[0].kind !== NodeKind.Identifier) return "";
	return (cd.arguments[0].data as IdentifierData).name;
}

// Extract callee name from ExprStmt(CallExpr(...))
function extractCalleeName(stmt: Node): string {
	if (stmt === null || stmt.kind !== NodeKind.ExprStmt) return "";
	const ed = stmt.data as ExprStmtData;
	if (ed.expr === null || ed.expr.kind !== NodeKind.CallExpr) return "";
	const cd = ed.expr.data as CallExprData;
	if (cd.callee === null || cd.callee.kind !== NodeKind.Identifier) return "";
	return (cd.callee.data as IdentifierData).name;
}

function getWasMovedVar(stmt: Node): string {
	const callee = extractCalleeName(stmt);
	if (callee === "") return "";
	if (!isWasMovedFn(callee)) return "";
	return extractSingleCallArg(stmt);
}

function getDestroyVar(stmt: Node): string {
	const callee = extractCalleeName(stmt);
	if (callee === "") return "";
	if (!isDestroyFn(callee)) return "";
	return extractSingleCallArg(stmt);
}

// ===== Block Optimization =====
// Tracks wasMoved vars across the block (not just adjacent pairs).
// Also collects definitely-moved vars from exhaustive if/else branches.

function optimizeBlock(stmts: Node[]): Node[] {
	const result: Node[] = [];
	const moved: NameSet = createNameSet();

	let i = 0;
	while (i < stmts.length) {
		const stmt = stmts[i];
		if (stmt === null) {
			i += 1;
			continue;
		}

		// Track wasMoved calls — add var to moved set
		const wmVar = getWasMovedVar(stmt);
		if (wmVar !== "") {
			nameSetAdd(moved, wmVar);
			result.push(stmt);
			i += 1;
			continue;
		}

		// Eliminate destroy for definitely-moved vars
		const dVar = getDestroyVar(stmt);
		if (dVar !== "" && nameSetContains(moved, dVar)) {
			i += 1;  // skip destroy — var was already zeroed by wasMoved
			continue;
		}

		// Collect moved vars from exhaustive if/else branches
		if (stmt.kind === NodeKind.IfStmt) {
			const ifMoved = collectIfMoved(stmt);
			for (const v of ifMoved.items) {
				nameSetAdd(moved, v);
			}
		}

		result.push(stmt);
		i += 1;
	}
	return result;
}

// ===== Recursive Walker =====

function walkOptimize(node: Node): void {
	if (node === null) return;

	match (node.kind) {
		NodeKind.Program => {
			const d = node.data as ProgramData;
			d.programStmts = optimizeBlock(d.programStmts);
			for (const s of d.programStmts) { walkOptimize(s); }
		},
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			d.statements = optimizeBlock(d.statements);
			for (const s of d.statements) { walkOptimize(s); }
		},
		NodeKind.FunctionDecl => { walkOptimize((node.data as FunctionDeclData).fnBody); },
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			walkOptimize(d.consequent);
			walkOptimize(d.alternate);
		},
		NodeKind.WhileStmt => { walkOptimize((node.data as WhileStmtData).whileBody); },
		NodeKind.ForStmt => { walkOptimize((node.data as ForStmtData).forBody); },
		NodeKind.ForOfStmt => { walkOptimize((node.data as ForOfStmtData).forOfBody); },
		NodeKind.DoWhileStmt => { walkOptimize((node.data as DoWhileStmtData).doBody); },
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			walkOptimize(d.tryBody);
			walkOptimize(d.catchBody);
			walkOptimize(d.finallyBody);
		},
		NodeKind.SwitchStmt => {
			for (const c of (node.data as SwitchStmtData).switchCases) { walkOptimize(c); }
		},
		NodeKind.SwitchCase => {
			const d = node.data as SwitchCaseData;
			d.caseStmts = optimizeBlock(d.caseStmts);
			for (const s of d.caseStmts) { walkOptimize(s); }
		},
		NodeKind.ExportDecl => { walkOptimize((node.data as ExportDeclData).exportedDecl); },
		NodeKind.ClassDecl => {
			for (const member of (node.data as ClassDeclData).classBody) { walkOptimize(member); }
		},
		NodeKind.MethodDecl => { walkOptimize((node.data as MethodDeclData).methodBody); },
		NodeKind.ConstructorDecl => { walkOptimize((node.data as ConstructorDeclData).ctorBody); },
		// Default: descend via canonical walker so any new container kind still
		// has its nested blocks reached. Block-level optimization runs on
		// BlockStmt / SwitchCase / Program — if an unknown container wraps those,
		// they'll be hit via forEachChild recursion. Correctness-preserving.
		_ => { forEachChild(node, (child: Node): void => { walkOptimize(child); }); },
	};
}

// ===== Public Entry Point =====

export function optimizeDrc(program: Node): Node {
	walkOptimize(program);
	return program;
}

// ===== Tests =====

function makeWmCall(varName: string): Node {
	const loc = testLoc();
	return makeExprStmt(
		makeCall(makeIdent("msStringWasMoved", loc), [makeIdent(varName, loc)], loc), loc);
}

function makeDestroyCallForTest(varName: string): Node {
	const loc = testLoc();
	return makeExprStmt(
		makeCall(makeIdent("msStringDecref", loc), [makeIdent(varName, loc)], loc), loc);
}

function makeOtherStmt(): Node {
	const loc = testLoc();
	return makeExprStmt(makeIdent("something", loc), loc);
}

test "eliminates wasMoved+destroy pair" {
	const wm = makeWmCall("x");
	const destroy = makeDestroyCallForTest("x");
	const stmts: Node[] = [wm, destroy];
	const result = optimizeBlock(stmts);
	// destroy eliminated, only wasMoved remains
	assert result.length === 1;
}

test "eliminates non-adjacent wasMoved+destroy" {
	const wm = makeWmCall("x");
	const other = makeOtherStmt();
	const destroy = makeDestroyCallForTest("x");
	const stmts: Node[] = [wm, other, destroy];
	const result = optimizeBlock(stmts);
	// Non-adjacent destroy eliminated — wasMoved + other remain
	assert result.length === 2;
}

test "preserves different vars" {
	const wm = makeWmCall("x");
	const destroy = makeDestroyCallForTest("y");
	const stmts: Node[] = [wm, destroy];
	const result = optimizeBlock(stmts);
	// Different vars — both preserved
	assert result.length === 2;
}

test "eliminates multiple pairs" {
	const wm1 = makeWmCall("a");
	const d1 = makeDestroyCallForTest("a");
	const wm2 = makeWmCall("b");
	const d2 = makeDestroyCallForTest("b");
	const stmts: Node[] = [wm1, d1, wm2, d2];
	const result = optimizeBlock(stmts);
	// Both destroy calls eliminated
	assert result.length === 2;
}

test "preserves standalone wasMoved" {
	const wm = makeWmCall("x");
	const other = makeOtherStmt();
	const stmts: Node[] = [wm, other];
	const result = optimizeBlock(stmts);
	assert result.length === 2;
}

test "preserves standalone destroy" {
	const destroy = makeDestroyCallForTest("x");
	const other = makeOtherStmt();
	const stmts: Node[] = [destroy, other];
	const result = optimizeBlock(stmts);
	assert result.length === 2;
}

test "extracts var from wasMoved call" {
	const wm = makeWmCall("myVar");
	const name = getWasMovedVar(wm);
	assert name === "myVar";
}

test "returns empty for non-wasMoved" {
	const other = makeOtherStmt();
	const name = getWasMovedVar(other);
	assert name === "";
}

test "if/else both move same var → eliminate destroy" {
	const loc = testLoc();
	// Build: if (cond) { wasMoved(x); } else { wasMoved(x); } destroy(x);
	const wmCons = makeWmCall("x");
	const consBlock = makeBlock([wmCons], loc);
	const wmAlt = makeWmCall("x");
	const altBlock = makeBlock([wmAlt], loc);
	const ifNode: Node = {
		kind: NodeKind.IfStmt, location: loc,
		data: { condition: makeIdent("cond", loc), consequent: consBlock, alternate: altBlock },
	};
	const destroy = makeDestroyCallForTest("x");
	const stmts: Node[] = [ifNode, destroy];
	const result = optimizeBlock(stmts);
	// destroy(x) eliminated — x was moved on all paths
	assert result.length === 1;
}

test "if without else → preserve destroy" {
	const loc = testLoc();
	const wmCons = makeWmCall("x");
	const consBlock = makeBlock([wmCons], loc);
	const ifNode: Node = {
		kind: NodeKind.IfStmt, location: loc,
		data: { condition: makeIdent("cond", loc), consequent: consBlock, alternate: null as unknown as Node },
	};
	const destroy = makeDestroyCallForTest("x");
	const stmts: Node[] = [ifNode, destroy];
	const result = optimizeBlock(stmts);
	// No else — can't guarantee moved, destroy preserved
	assert result.length === 2;
}

test "if/else move different vars → preserve both destroys" {
	const loc = testLoc();
	const consBlock = makeBlock([makeWmCall("x")], loc);
	const altBlock = makeBlock([makeWmCall("y")], loc);
	const ifNode: Node = {
		kind: NodeKind.IfStmt, location: loc,
		data: { condition: makeIdent("cond", loc), consequent: consBlock, alternate: altBlock },
	};
	const destroyX = makeDestroyCallForTest("x");
	const destroyY = makeDestroyCallForTest("y");
	const stmts: Node[] = [ifNode, destroyX, destroyY];
	const result = optimizeBlock(stmts);
	// Neither is moved on ALL paths — both preserved
	assert result.length === 3;
}

// DRC Post-Optimizer — eliminate redundant RC operation pairs
//
// Pattern: wasMoved(x); destroy(x); → remove the destroy
// When a variable is marked as moved (wasMoved zeroes it), the subsequent
// destroy is a no-op on a zeroed value. Removing it saves a function call.
//
// Walks all blocks recursively, scanning consecutive statements.

import {
	Node, NodeKind, ProgramData, Symbol, SourceLocation, AttachedOp,
	BlockStmtData, ExprStmtData, CallExprData,
	FunctionDeclData, IfStmtData, WhileStmtData, ForStmtData,
	TryCatchStmtData, SwitchStmtData, SwitchCaseData,
	ExportDeclData, ClassDeclData, MethodDeclData, ConstructorDeclData,
	ForOfStmtData, DoWhileStmtData,
} from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { hasFlag, SymbolFlag } from "../checker/symbol";
import { makeIdent, makeIdentResolved, makeBlock, makeExprStmt, makeCall, makeTypedIdentResolved, attachedOpSym, runtimeRef } from "../transform/util";
import { testLoc } from "./inject";
import { testVarSym } from "./scope";

function symListHas(list: Symbol[], sym: Symbol): boolean {
	for (const s of list) {
		if (s == sym) return true;
	}
	return false;
}

function symListAdd(list: Symbol[], sym: Symbol): void {
	if (!symListHas(list, sym)) list.push(sym);
}

function symListIntersect(a: Symbol[], b: Symbol[]): Symbol[] {
	const result: Symbol[] = [];
	for (const s of a) {
		if (symListHas(b, s)) result.push(s);
	}
	return result;
}

// ===== Moved-var tracking for branch-aware optimization =====

// Scan a block's top-level statements for wasMoved calls
function collectBlockMoved(block: Node): Symbol[] {
	const result: Symbol[] = [];
	if (block == null) return result;
	if (block.kind != NodeKind.BlockStmt) return result;
	const bd = block.data as BlockStmtData;
	for (const stmt of bd.statements) {
		const wm = opCallTarget(stmt, SymbolFlag.WasMovedOp);
		if (wm != null) {
			symListAdd(result, wm);
		}
		// Also collect from nested if/else branches
		if (stmt.kind == NodeKind.IfStmt) {
			for (const v of collectIfMoved(stmt)) {
				symListAdd(result, v);
			}
		}
	}
	return result;
}

// Collect moved vars from if/else — intersection of all branches
function collectIfMoved(ifNode: Node): Symbol[] {
	const d = ifNode.data as IfStmtData;
	const consMoved = collectBlockMoved(d.consequent);

	// No else — can't guarantee moved on all paths
	if (d.alternate == null) return [];

	// else-if chain: recurse
	if (d.alternate.kind == NodeKind.IfStmt) {
		return symListIntersect(consMoved, collectIfMoved(d.alternate));
	}

	// else block
	return symListIntersect(consMoved, collectBlockMoved(d.alternate));
}

// ===== The variable a wasMoved/destroy call acts on =====

function opCallTarget(stmt: Node, op: SymbolFlag): Symbol | null {
	if (stmt == null || stmt.kind != NodeKind.ExprStmt) return null;
	const ed = stmt.data as ExprStmtData;
	if (ed.expr == null || ed.expr.kind != NodeKind.CallExpr) return null;
	const cd = ed.expr.data as CallExprData;
	if (cd.callee == null || cd.callee.resolvedSym == null || !hasFlag(cd.callee.resolvedSym, op)) return null;
	if (cd.arguments.length != 1) return null;
	// Access arguments[0] inline — avoid local Node variable (DRC use-after-free on return)
	if (cd.arguments[0] == null || cd.arguments[0].kind != NodeKind.Identifier) return null;
	return cd.arguments[0].resolvedSym;
}

// ===== Block Optimization =====
// Tracks wasMoved vars across the block (not just adjacent pairs).
// Also collects definitely-moved vars from exhaustive if/else branches.

function optimizeBlock(stmts: Node[]): Node[] {
	const result: Node[] = [];
	const moved: Symbol[] = [];

	let i = 0;
	while (i < stmts.length) {
		const stmt = stmts[i];
		if (stmt == null) {
			i += 1;
			continue;
		}

		// Track wasMoved calls — add var to moved set
		const wmVar = opCallTarget(stmt, SymbolFlag.WasMovedOp);
		if (wmVar != null) {
			symListAdd(moved, wmVar);
			result.push(stmt);
			i += 1;
			continue;
		}

		// Eliminate destroy for definitely-moved vars
		const dVar = opCallTarget(stmt, SymbolFlag.DestroyOp);
		if (dVar != null && symListHas(moved, dVar)) {
			i += 1;  // skip destroy — var was already zeroed by wasMoved
			continue;
		}

		// Collect moved vars from exhaustive if/else branches
		if (stmt.kind == NodeKind.IfStmt) {
			for (const v of collectIfMoved(stmt)) {
				symListAdd(moved, v);
			}
		}

		result.push(stmt);
		i += 1;
	}
	return result;
}

// ===== Recursive Walker =====

function walkOptimize(node: Node): void {
	if (node == null) return;

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

function makeWmCall(v: Symbol): Node {
	const loc = testLoc();
	return makeExprStmt(
		makeCall(makeTypedIdentResolved(attachedOpSym("msStringWasMoved", AttachedOp.AttachedWasMoved), null, loc), [makeIdentResolved(v, loc)], loc), loc);
}

function makeDestroyCallForTest(v: Symbol): Node {
	const loc = testLoc();
	return makeExprStmt(
		makeCall(makeTypedIdentResolved(attachedOpSym("msStringDecref", AttachedOp.AttachedDestructor), null, loc), [makeIdentResolved(v, loc)], loc), loc);
}

function makeOtherStmt(): Node {
	const loc = testLoc();
	return makeExprStmt(makeIdent("something", loc), loc);
}

function makeIfElse(cons: Node[], alt: Node[] | null, loc: SourceLocation): Node {
	return {
		kind: NodeKind.IfStmt, location: loc,
		data: {
			condition: makeIdent("cond", loc), consequent: makeBlock(cons, loc),
			alternate: alt != null ? makeBlock(alt, loc) : null as unknown as Node,
		},
	};
}

test "eliminates wasMoved+destroy pair" {
	const x = testVarSym("x");
	const result = optimizeBlock([makeWmCall(x), makeDestroyCallForTest(x)]);
	assert result.length == 1;
}

test "eliminates non-adjacent wasMoved+destroy" {
	const x = testVarSym("x");
	const result = optimizeBlock([makeWmCall(x), makeOtherStmt(), makeDestroyCallForTest(x)]);
	assert result.length == 2;
}

test "preserves different vars" {
	const result = optimizeBlock([makeWmCall(testVarSym("x")), makeDestroyCallForTest(testVarSym("y"))]);
	assert result.length == 2;
}

test "keeps apart two variables spelled alike" {
	const result = optimizeBlock([makeWmCall(testVarSym("x")), makeDestroyCallForTest(testVarSym("x"))]);
	assert result.length == 2;
}

test "a call named like a wasMoved op that is not one pairs with nothing" {
	const loc = testLoc();
	const x = testVarSym("x");
	const lookalike = makeExprStmt(makeCall(runtimeRef("noteWasMoved", loc), [makeIdentResolved(x, loc)], loc), loc);
	const result = optimizeBlock([lookalike, makeDestroyCallForTest(x)]);
	assert result.length == 2;
}

test "eliminates multiple pairs" {
	const a = testVarSym("a");
	const b = testVarSym("b");
	const result = optimizeBlock([makeWmCall(a), makeDestroyCallForTest(a), makeWmCall(b), makeDestroyCallForTest(b)]);
	assert result.length == 2;
}

test "preserves standalone wasMoved" {
	const result = optimizeBlock([makeWmCall(testVarSym("x")), makeOtherStmt()]);
	assert result.length == 2;
}

test "preserves standalone destroy" {
	const result = optimizeBlock([makeDestroyCallForTest(testVarSym("x")), makeOtherStmt()]);
	assert result.length == 2;
}

test "extracts var from wasMoved call" {
	const v = testVarSym("myVar");
	assert opCallTarget(makeWmCall(v), SymbolFlag.WasMovedOp) == v;
}

test "returns null for non-wasMoved" {
	assert opCallTarget(makeOtherStmt(), SymbolFlag.WasMovedOp) == null;
}

test "if/else both move same var → eliminate destroy" {
	const loc = testLoc();
	const x = testVarSym("x");
	const result = optimizeBlock([makeIfElse([makeWmCall(x)], [makeWmCall(x)], loc), makeDestroyCallForTest(x)]);
	assert result.length == 1;
}

test "if without else → preserve destroy" {
	const loc = testLoc();
	const x = testVarSym("x");
	const result = optimizeBlock([makeIfElse([makeWmCall(x)], null, loc), makeDestroyCallForTest(x)]);
	assert result.length == 2;
}

test "if/else move different vars → preserve both destroys" {
	const loc = testLoc();
	const x = testVarSym("x");
	const y = testVarSym("y");
	const ifNode = makeIfElse([makeWmCall(x)], [makeWmCall(y)], loc);
	const result = optimizeBlock([ifNode, makeDestroyCallForTest(x), makeDestroyCallForTest(y)]);
	assert result.length == 3;
}

// Definite Assignment Tracking — Reference Parity
//
// Clones the reference's init + intersection + BreakState model.
// Tracks which variables have been initialized, with branch merging via
// count tables and exhaustiveness checks.
//
// Uses name strings (not Symbol identity) for tracking. This avoids DRC
// refcount issues with the save/restore pattern (truncating Symbol[] leaks refs).
//
// Set + branch-merge primitives live in branchSet.ms and are shared with
// spawnAffinity.ms so both trackers stay in lockstep.

import { Node, NodeKind, BlockStmtData, CallExprData, ExprStmtData, BooleanLiteralData, TypeKind } from "../ast/node";
import { hasFlag, SymbolFlag } from "./symbol";
import { BreakState, addName, hasName, collectSince, mergeBranches } from "./branchSet";

// Re-export BreakState for existing importers (checkPass, checkExprPass, etc.)
export { BreakState } from "./branchSet";

// Reference parity: effects.init + currentBlock + leftPartOfAsgn + scopes
export interface InitTracker {
	initialized: string[];     // append-only list of initialized var names
	currentBlock: number;      // scope depth counter
	leftPartOfAsgn: number;    // >0 when processing LHS of assignment
	declScopes: string[];      // parallel with declBlocks: var name at declaration
	declBlocks: number[];      // block depth where each variable was declared
}

// ===== Constructors =====

export function createInitTracker(): InitTracker {
	return {
		initialized: [],
		currentBlock: 0,
		leftPartOfAsgn: 0,
		declScopes: [],
		declBlocks: [],
	};
}

// ===== Core Operations =====

// Reference parity: initVar — marks variable initialized
export function markInitialized(t: InitTracker, name: string): void {
	addName(t.initialized, name);
}

// Reference parity: check if variable is initialized
export function isInitialized(t: InitTracker, name: string): boolean {
	return hasName(t.initialized, name);
}

// Reference parity: save init.len for branch merging
export function saveInitState(t: InitTracker): int32 {
	return t.initialized.length;
}

// Reference parity: restore init state
export function restoreInitState(t: InitTracker, state: int32): void {
	t.initialized.length = state;
}

// ===== Scope Tracking (for nfFirstWrite) =====

// Reference parity: varDecl — records the block where a variable was declared.
// Used by initVar to set nfFirstWrite only when assignment is in the same block.
export function varDecl(t: InitTracker, name: string): void {
	t.declScopes.push(name);
	t.declBlocks.push(t.currentBlock);
}

// Reference parity: lookup the block where a variable was declared.
// Returns -1 if not found (import/global — never declared locally).
export function getDeclBlock(t: InitTracker, name: string): number {
	let i = t.declScopes.length - 1;
	while (i >= 0) {
		if (t.declScopes[i] === name) return t.declBlocks[i];
		i = i - 1;
	}
	return -1;
}

// ===== Break State Detection =====

// Reference parity: breaksBlock — walks to last statement and determines exit state.
export function breaksBlock(node: Node): BreakState {
	if (node === null) return BreakState.BsNone;
	let it = node;
	while (it.kind === NodeKind.BlockStmt) {
		const bd = it.data as BlockStmtData;
		if (bd.statements.length === 0) return BreakState.BsNone;
		it = bd.statements[bd.statements.length - 1];
	}
	if (it.kind === NodeKind.BreakStmt || it.kind === NodeKind.ReturnStmt) {
		return BreakState.BsBreakOrReturn;
	}
	if (it.kind === NodeKind.ThrowStmt || it.kind === NodeKind.UnreachableStmt) {
		return BreakState.BsNoReturn;
	}
	// Ref parity: check for noreturn call (exit(), abort(), etc.)
	// ExprStmt wrapping a CallExpr whose callee returns Never
	if (it.kind === NodeKind.ExprStmt) {
		const ed = it.data as ExprStmtData;
		if (ed.expr !== null && ed.expr.kind === NodeKind.CallExpr) {
			const cd = ed.expr.data as CallExprData;
			if (cd.callee !== null && cd.callee.resolvedSym !== null) {
				const calleeSym = cd.callee.resolvedSym;
				if (hasFlag(calleeSym, SymbolFlag.NoReturn)) return BreakState.BsNoReturn;
				const retType = calleeSym.symbolType;
				if (retType !== null && retType.typeReturn !== null && retType.typeReturn.kind === TypeKind.Never) {
					return BreakState.BsNoReturn;
				}
			}
		}
	}
	return BreakState.BsNone;
}

// ===== Branch Merging =====

// Reference parity: branch merge for if/match. Delegates to shared branchSet.
export function mergeInitBranches(
	t: InitTracker,
	oldState: int32,
	branchInits: string[][],
	branchBreaks: BreakState[],
	isExhaustive: boolean,
): void {
	mergeBranches(t.initialized, oldState, branchInits, branchBreaks, isExhaustive);
}

// Collect names initialized between oldState and current state
export function collectNewInits(t: InitTracker, oldState: int32): string[] {
	return collectSince(t.initialized, oldState);
}

// ===== Helpers =====

// Reference parity: check for `while (true)` literal
export function isAlwaysTrue(node: Node): boolean {
	if (node === null) return false;
	if (node.kind === NodeKind.BooleanLiteral) {
		const d = node.data as BooleanLiteralData;
		return d.boolValue;
	}
	return false;
}

// Phase 4: `impliesNotNull` (fact-list null query) deleted. Replaced by
// `isDefinitelyNonNullAt` in src/checker/flow.ms which walks the CFG.

// ===== Tests =====

test "basic init and check" {
	const t = createInitTracker();
	assert !isInitialized(t, "x");
	markInitialized(t, "x");
	assert isInitialized(t, "x");
	assert !isInitialized(t, "y");
}

test "save and restore" {
	const t = createInitTracker();
	markInitialized(t, "a");
	const snap = saveInitState(t);
	markInitialized(t, "b");
	assert isInitialized(t, "b");
	restoreInitState(t, snap);
	assert isInitialized(t, "a");
	assert !isInitialized(t, "b");
}

test "no duplicate init" {
	const t = createInitTracker();
	markInitialized(t, "x");
	markInitialized(t, "x");
	assert t.initialized.length === 1;
}

test "merge exhaustive both init" {
	const t = createInitTracker();
	const old = saveInitState(t);
	const b1: string[] = ["x"];
	const b2: string[] = ["x"];
	mergeInitBranches(t, old, [b1, b2],
		[BreakState.BsNone, BreakState.BsNone], true);
	assert isInitialized(t, "x");
}

test "merge exhaustive only one inits" {
	const t = createInitTracker();
	const old = saveInitState(t);
	const b1: string[] = ["x"];
	const b2: string[] = [];
	mergeInitBranches(t, old, [b1, b2], [BreakState.BsNone, BreakState.BsNone], true);
	assert !isInitialized(t, "x");
}

test "merge non-exhaustive" {
	const t = createInitTracker();
	const old = saveInitState(t);
	const b1: string[] = ["x"];
	mergeInitBranches(t, old, [b1], [BreakState.BsNone], false);
	assert !isInitialized(t, "x");
}

test "merge with exiting branch" {
	const t = createInitTracker();
	const old = saveInitState(t);
	const b1: string[] = [];
	const b2: string[] = ["x"];
	mergeInitBranches(t, old, [b1, b2],
		[BreakState.BsBreakOrReturn, BreakState.BsNone], true);
	assert isInitialized(t, "x");
}

test "merge with noreturn branch" {
	const t = createInitTracker();
	const old = saveInitState(t);
	const b1: string[] = [];
	const b2: string[] = ["x"];
	mergeInitBranches(t, old, [b1, b2],
		[BreakState.BsNoReturn, BreakState.BsNone], true);
	assert isInitialized(t, "x");
}

test "collectNewInits" {
	const t = createInitTracker();
	markInitialized(t, "a");
	const snap = saveInitState(t);
	markInitialized(t, "b");
	markInitialized(t, "c");
	const newInits = collectNewInits(t, snap);
	assert newInits.length === 2;
}

test "varDecl records block" {
	const t = createInitTracker();
	varDecl(t, "x");
	assert getDeclBlock(t, "x") === 0;
	t.currentBlock = t.currentBlock + 1;
	varDecl(t, "y");
	assert getDeclBlock(t, "y") === 1;
	assert getDeclBlock(t, "x") === 0;
}

test "getDeclBlock returns -1 for unknown" {
	const t = createInitTracker();
	assert getDeclBlock(t, "nonexistent") === -1;
}

test "varDecl same block as currentBlock enables firstWrite" {
	const t = createInitTracker();
	varDecl(t, "x");
	assert getDeclBlock(t, "x") === t.currentBlock;
	t.currentBlock = t.currentBlock + 1;
	assert getDeclBlock(t, "x") !== t.currentBlock;
}

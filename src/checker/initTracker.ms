// Definite Assignment Tracking — Reference Parity
//
// Clones the reference's init + intersection + BreakState model.
// Tracks which variables have been initialized, with branch merging via
// count tables and exhaustiveness checks.
// Uses Symbol identity (not name strings) to handle shadowing correctly.

import {
	Node, NodeKind, Symbol, BlockStmtData, CallExprData, ExprStmtData, IdentifierData, BooleanLiteralData, BinaryExprData,
} from "../ast/node";
import { TypeKind } from "./types";
import { hasFlag, SymbolFlag } from "./symbol";

// Reference parity: BreakState for branch merging
export enum BreakState {
	BsNone,           // normal flow — branch contributes to merge
	BsBreakOrReturn,  // break/return — exits branch, doesn't affect merge
	BsNoReturn,       // raise/noreturn — never reaches merge point
}

// Reference parity: intersection count table (uses Symbol identity)
interface InitCount {
	sym: Symbol;
	count: number;
}

// Reference parity: effects.init + currentBlock + leftPartOfAsgn + scopes
export interface InitTracker {
	initialized: Symbol[];     // append-only list of initialized symbols (identity-based)
	currentBlock: number;      // scope depth counter
	leftPartOfAsgn: number;    // >0 when processing LHS of assignment
	declScopes: Symbol[];      // parallel with declBlocks: symbol at declaration
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

// Reference parity: initVar — marks variable initialized (by symbol identity)
export function markInitialized(t: InitTracker, sym: Symbol): void {
	let i = 0;
	while (i < t.initialized.length) {
		if (t.initialized[i] === sym) return;
		i = i + 1;
	}
	t.initialized.push(sym);
}

// Reference parity: check if variable is initialized (by symbol identity)
export function isInitialized(t: InitTracker, sym: Symbol): boolean {
	let i = 0;
	while (i < t.initialized.length) {
		if (t.initialized[i] === sym) return true;
		i = i + 1;
	}
	return false;
}

// Reference parity: save init.len for branch merging
export function saveInitState(t: InitTracker): number {
	return t.initialized.length;
}

// Reference parity: restore init state
export function restoreInitState(t: InitTracker, state: number): void {
	t.initialized.length = state;
}

// ===== Scope Tracking (for nfFirstWrite) =====

// Reference parity: varDecl — records the block where a variable was declared.
// Used by initVar to set nfFirstWrite only when assignment is in the same block.
export function varDecl(t: InitTracker, sym: Symbol): void {
	t.declScopes.push(sym);
	t.declBlocks.push(t.currentBlock);
}

// Reference parity: lookup the block where a variable was declared.
// Returns -1 if not found (import/global — never declared locally).
export function getDeclBlock(t: InitTracker, sym: Symbol): number {
	let i = t.declScopes.length - 1;
	while (i >= 0) {
		if (t.declScopes[i] === sym) return t.declBlocks[i];
		i = i - 1;
	}
	return -1;
}

// ===== Break State Detection =====

// Reference parity: breaksBlock — walks to last statement and determines exit state.
export function breaksBlock(node: Node): BreakState {
	if (node === null) return BreakState.BsNone;
	// Walk to last statement in block
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

// Reference parity: addToIntersection (uses Symbol identity)
function addToIntersection(counts: InitCount[], sym: Symbol, breakState: BreakState): void {
	// Look for existing entry (identity comparison)
	let j = 0;
	while (j < counts.length) {
		if (counts[j].sym === sym) {
			if (breakState === BreakState.BsNone) {
				counts[j].count = counts[j].count + 1;
			}
			return;
		}
		j = j + 1;
	}
	// New entry
	if (breakState === BreakState.BsNone) {
		counts.push({ sym, count: 1 });
	} else {
		counts.push({ sym, count: 0 });
	}
}

// Reference parity: branch merge for if/match.
// Merges initialization state from multiple branches.
// Only promotes vars initialized in ALL non-exiting branches of exhaustive constructs.
export function mergeInitBranches(
	t: InitTracker,
	oldState: number,
	branchInits: Symbol[][],
	branchBreaks: BreakState[],
	isExhaustive: boolean,
): void {
	if (!isExhaustive) {
		// No else branch / no default case → can't prove any var initialized on all paths
		restoreInitState(t, oldState);
		return;
	}

	// Build count table
	let toCover = 0;
	const counts: InitCount[] = [];

	let b = 0;
	while (b < branchInits.length) {
		const inits = branchInits[b];
		const breakState = branchBreaks[b];

		if (breakState === BreakState.BsNone) {
			toCover = toCover + 1;
		}

		// Add each newly-initialized var from this branch
		let i = 0;
		while (i < inits.length) {
			addToIntersection(counts, inits[i], breakState);
			i = i + 1;
		}
		b = b + 1;
	}

	// Restore to pre-branch state
	restoreInitState(t, oldState);

	// Add only vars initialized in ALL non-exiting branches
	if (toCover > 0) {
		let i = 0;
		while (i < counts.length) {
			if (counts[i].count >= toCover) {
				markInitialized(t, counts[i].sym);
			}
			i = i + 1;
		}
	}
}

// Collect symbols initialized between oldState and current state
export function collectNewInits(t: InitTracker, oldState: number): Symbol[] {
	const result: Symbol[] = [];
	let i = oldState;
	while (i < t.initialized.length) {
		result.push(t.initialized[i]);
		i = i + 1;
	}
	return result;
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

// ===== Null Fact Query =====

// Check if a BinaryExprData is a null comparison for a specific variable
function isNullCompareFor(d: BinaryExprData, varName: string): boolean {
	if (d.left.kind === NodeKind.Identifier && d.right.kind === NodeKind.NullLiteral) {
		return (d.left.data as IdentifierData).name === varName;
	}
	if (d.right.kind === NodeKind.Identifier && d.left.kind === NodeKind.NullLiteral) {
		return (d.right.data as IdentifierData).name === varName;
	}
	return false;
}

// Query: do narrow facts prove varName is not null?
// Returns: 1 = yes (not null), -1 = no (is null), 0 = unknown
export function impliesNotNull(facts: Node[], varName: string): number {
	let i = 0;
	while (i < facts.length) {
		const fact = facts[i];
		if (fact.kind === NodeKind.BinaryExpr) {
			const d = fact.data as BinaryExprData;
			if (isNullCompareFor(d, varName)) {
				if (d.operator === "!==") return 1;
				if (d.operator === "===") return -1;
			}
		}
		i = i + 1;
	}
	return 0;
}

// ===== Tests =====

// Helper: create a minimal Symbol for testing (identity-based)
function testSym(name: string): Symbol {
	const s = new Symbol();
	s.name = name;
	return s;
}

test "basic init and check" {
	const t = createInitTracker();
	const x = testSym("x");
	assert !isInitialized(t, x);
	markInitialized(t, x);
	assert isInitialized(t, x);
	assert !isInitialized(t, testSym("y"));
}

test "save and restore" {
	const t = createInitTracker();
	const a = testSym("a");
	const b = testSym("b");
	markInitialized(t, a);
	const snap = saveInitState(t);
	markInitialized(t, b);
	assert isInitialized(t, b);
	restoreInitState(t, snap);
	assert isInitialized(t, a);
	assert !isInitialized(t, b);
}

test "no duplicate init" {
	const t = createInitTracker();
	const x = testSym("x");
	markInitialized(t, x);
	markInitialized(t, x);
	assert t.initialized.length === 1;
}

test "name shadowing handled correctly" {
	const t = createInitTracker();
	const outer = testSym("x");
	const inner = testSym("x");
	markInitialized(t, inner);
	assert isInitialized(t, inner);
	assert !isInitialized(t, outer);
}

test "merge exhaustive both init" {
	const t = createInitTracker();
	const x = testSym("x");
	const old = saveInitState(t);
	const b1: Symbol[] = [x];
	const b2: Symbol[] = [x];
	mergeInitBranches(t, old, [b1, b2],
		[BreakState.BsNone, BreakState.BsNone], true);
	assert isInitialized(t, x);
}

test "merge exhaustive only one inits" {
	const t = createInitTracker();
	const x = testSym("x");
	const old = saveInitState(t);
	const b1: Symbol[] = [x];
	const b2: Symbol[] = [];
	mergeInitBranches(t, old, [b1, b2], [BreakState.BsNone, BreakState.BsNone], true);
	assert !isInitialized(t, x);
}

test "merge non-exhaustive" {
	const t = createInitTracker();
	const x = testSym("x");
	const old = saveInitState(t);
	const b1: Symbol[] = [x];
	mergeInitBranches(t, old, [b1], [BreakState.BsNone], false);
	assert !isInitialized(t, x);
}

test "merge with exiting branch" {
	const t = createInitTracker();
	const x = testSym("x");
	const old = saveInitState(t);
	const b1: Symbol[] = [];
	const b2: Symbol[] = [x];
	mergeInitBranches(t, old, [b1, b2],
		[BreakState.BsBreakOrReturn, BreakState.BsNone], true);
	assert isInitialized(t, x);
}

test "merge with noreturn branch" {
	const t = createInitTracker();
	const x = testSym("x");
	const old = saveInitState(t);
	const b1: Symbol[] = [];
	const b2: Symbol[] = [x];
	mergeInitBranches(t, old, [b1, b2],
		[BreakState.BsNoReturn, BreakState.BsNone], true);
	assert isInitialized(t, x);
}

test "collectNewInits" {
	const t = createInitTracker();
	const a = testSym("a");
	const b = testSym("b");
	const c = testSym("c");
	markInitialized(t, a);
	const snap = saveInitState(t);
	markInitialized(t, b);
	markInitialized(t, c);
	const newInits = collectNewInits(t, snap);
	assert newInits.length === 2;
}

test "varDecl records block" {
	const t = createInitTracker();
	const x = testSym("x");
	const y = testSym("y");
	varDecl(t, x);
	assert getDeclBlock(t, x) === 0;
	t.currentBlock = t.currentBlock + 1;
	varDecl(t, y);
	assert getDeclBlock(t, y) === 1;
	assert getDeclBlock(t, x) === 0;
}

test "getDeclBlock returns -1 for unknown" {
	const t = createInitTracker();
	assert getDeclBlock(t, testSym("nonexistent")) === -1;
}

test "varDecl same block as currentBlock enables firstWrite" {
	const t = createInitTracker();
	const x = testSym("x");
	varDecl(t, x);
	assert getDeclBlock(t, x) === t.currentBlock;
	t.currentBlock = t.currentBlock + 1;
	assert getDeclBlock(t, x) !== t.currentBlock;
}

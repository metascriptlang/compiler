// Name strings, not Symbol identity, key the tracking: truncating a Symbol[] on restore leaks refs under DRC.

import { Node, NodeKind, BlockStmtData, CallExprData, ExprStmtData, BooleanLiteralData, TypeKind } from "../ast/node";
import { hasFlag, SymbolFlag } from "./symbol";
import { BreakState, addName, hasName, collectSince, mergeBranches } from "./branchSet";

export { BreakState } from "./branchSet";

export interface InitTracker {
	initialized: string[];     // append-only list of initialized var names
	currentBlock: number;      // scope depth counter
	leftPartOfAsgn: number;    // >0 when processing LHS of assignment
	assignTarget: Node | null; // the identifier an `=` or `out` writes; its own check is not a read
	definiteTarget: Node | null; // the left operand of `=`, `&&=`, `||=`, `??=`: only it reads its declared type, a receiver or compound target reads the flow-narrowed one
	argIdents: Node[];         // bare identifiers passed as call arguments: whether the callee takes them `out` is known only after resolution
	pendingReads: Node[];      // those of argIdents read while unassigned, settled when the call resolves
	declScopes: string[];      // parallel with declBlocks: var name at declaration
	declBlocks: number[];      // block depth where each variable was declared
	outParams: string[];       // out parameters of the routine being checked: each must be written before every exit
}

// ===== Constructors =====

export function createInitTracker(): InitTracker {
	return {
		initialized: [],
		currentBlock: 0,
		leftPartOfAsgn: 0,
		assignTarget: null,
		definiteTarget: null,
		argIdents: [],
		pendingReads: [],
		declScopes: [],
		declBlocks: [],
		outParams: [],
	};
}

// ===== Core Operations =====

export function markInitialized(t: InitTracker, name: string): void {
	addName(t.initialized, name);
}

export function isInitialized(t: InitTracker, name: string): boolean {
	return hasName(t.initialized, name);
}

export function saveInitState(t: InitTracker): int32 {
	return t.initialized.length;
}

export function restoreInitState(t: InitTracker, state: int32): void {
	t.initialized.length = state;
}

// First out parameter of the current routine that is not written on the path being checked, or null.
export function unwrittenOutParam(t: InitTracker): string | null {
	for (const name of t.outParams) {
		if (!hasName(t.initialized, name)) return name;
	}
	return null;
}

export function isOutParamName(t: InitTracker, name: string): boolean {
	return hasName(t.outParams, name);
}

// ===== Scope Tracking (for nfFirstWrite) =====

export function varDecl(t: InitTracker, name: string): void {
	t.declScopes.push(name);
	t.declBlocks.push(t.currentBlock);
}

// null when the name was never declared locally (import or global).
export function getDeclBlock(t: InitTracker, name: string): number | null {
	let i = t.declScopes.length - 1;
	while (i >= 0) {
		if (t.declScopes[i] == name) return t.declBlocks[i];
		i = i - 1;
	}
	return null;
}

// ===== Break State Detection =====

export function breaksBlock(node: Node): BreakState {
	if (node == null) return BreakState.BsNone;
	let it = node;
	while (it.kind == NodeKind.BlockStmt) {
		const bd = it.data as BlockStmtData;
		if (bd.statements.length == 0) return BreakState.BsNone;
		it = bd.statements[bd.statements.length - 1];
	}
	if (it.kind == NodeKind.BreakStmt || it.kind == NodeKind.ReturnStmt) {
		return BreakState.BsBreakOrReturn;
	}
	if (it.kind == NodeKind.ThrowStmt || it.kind == NodeKind.UnreachableStmt) {
		return BreakState.BsNoReturn;
	}
	if (it.kind == NodeKind.ExprStmt) {
		const ed = it.data as ExprStmtData;
		if (ed.expr != null && ed.expr.kind == NodeKind.CallExpr) {
			const cd = ed.expr.data as CallExprData;
			if (cd.callee != null && cd.callee.resolvedSym != null) {
				const calleeSym = cd.callee.resolvedSym;
				if (hasFlag(calleeSym, SymbolFlag.NoReturn)) return BreakState.BsNoReturn;
				const retType = calleeSym.symbolType;
				if (retType != null && retType.typeReturn != null && retType.typeReturn.kind == TypeKind.Never) {
					return BreakState.BsNoReturn;
				}
			}
		}
	}
	return BreakState.BsNone;
}

// ===== Branch Merging =====

export function mergeInitBranches(
	t: InitTracker,
	oldState: int32,
	branchInits: string[][],
	branchBreaks: BreakState[],
	isExhaustive: boolean,
): void {
	mergeBranches(t.initialized, oldState, branchInits, branchBreaks, isExhaustive);
}

export function collectNewInits(t: InitTracker, oldState: int32): string[] {
	return collectSince(t.initialized, oldState);
}

// ===== Helpers =====

export function isAlwaysTrue(node: Node): boolean {
	if (node == null) return false;
	if (node.kind == NodeKind.BooleanLiteral) {
		const d = node.data as BooleanLiteralData;
		return d.boolValue;
	}
	return false;
}

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
	assert t.initialized.length == 1;
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
	assert newInits.length == 2;
}

test "varDecl records block" {
	const t = createInitTracker();
	varDecl(t, "x");
	assert getDeclBlock(t, "x") == 0;
	t.currentBlock = t.currentBlock + 1;
	varDecl(t, "y");
	assert getDeclBlock(t, "y") == 1;
	assert getDeclBlock(t, "x") == 0;
}

test "getDeclBlock returns null for unknown" {
	const t = createInitTracker();
	assert getDeclBlock(t, "nonexistent") == null;
}

test "varDecl same block as currentBlock enables firstWrite" {
	const t = createInitTracker();
	varDecl(t, "x");
	assert getDeclBlock(t, "x") == t.currentBlock;
	t.currentBlock = t.currentBlock + 1;
	assert getDeclBlock(t, "x") != t.currentBlock;
}

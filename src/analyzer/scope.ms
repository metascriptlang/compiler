// DRC Scope Management — tracks variables and cleanup obligations per scope
//
// Each scope (function, block, loop) tracks:
//   - varsToCleanup: variables needing =destroy at scope exit
//   - wasMoved: variables whose ownership was transferred (skip destroy)
//   - needsTry: whether scope needs try/finally wrapping for cleanup
//
// Arrays passed by pointer — bare T[] types (wrappers removed).

import { Node, SourceLocation } from "../ast/node";
import { RcInfo, RcKind, noRcInfo } from "./classify";
import { CursorSet, createCursorSet } from "./cursors";
import { CfgCache, createCfgCache } from "./cfg";
import { TransformContext, NameSet, freshTemp, createTransformContext } from "../transform/context";
import { makeExprStmt, makeNull } from "../transform/util";

// ===== Variable Info =====

export interface VarInfo {
	varName: string;
	rcInfo: RcInfo;
	isCursor: boolean;    // borrowed ref — never destroyed
	isInitialized: boolean; // first-write optimization: skip destroy on first assignment
}

export interface MovedVar {
	varName: string;
}

// ===== DRC Scope =====

export interface DrcScope {
	varsToCleanup: VarInfo[];     // variables needing cleanup at scope exit
	wasMoved: MovedVar[];         // variables that were moved (skip destroy)
	needsTry: boolean;            // does this scope need try/finally wrapping?
	isLoop: boolean;              // is this a loop body scope?
	isFunction: boolean;          // is this a function scope?
}

// ===== Outer Statement Context (for cross-scope last-read analysis) =====

export interface OuterEntry {
	outerStmts: Node[];
	fromIndex: number;
	isFunctionBoundary: boolean;  // function boundary — stop cross-scope search
}

// ===== DRC Context =====

export interface DrcContext {
	ctx: TransformContext;
	scopes: DrcScope[];          // scope stack
	pendingStmts: Node[];        // stmts to flush after current statement
	preStmts: Node[];            // stmts to flush before current statement
	outerCtx: OuterEntry[];      // cross-scope remaining stmts for last-read
	currentStmtIdx: number;      // Index of the statement currently being processed
	currentStmtList: Node[];     // The list containing the current statement
	finallyProtectedVars: NameSet;  // vars in enclosing finally blocks — never last-read (Phase A)
	cursors: CursorSet;             // cursor variables — skip all RC ops (Phase B)
	cfgCache: CfgCache;             // CFG cache per variable — Phase C
	currentFuncBody: Node;          // current function body for CFG building — Phase C
	currentFuncName: string;        // current function name — for DRC hook detection
}

// ===== Constructors =====

export function createDrcContext(ctx: TransformContext): DrcContext {
	return {
		ctx,
		scopes: [],
		pendingStmts: [],
		preStmts: [],
		outerCtx: [],
		currentStmtIdx: 0,
		currentStmtList: [],
		finallyProtectedVars: [],
		cursors: createCursorSet(),
		cfgCache: createCfgCache(),
		currentFuncBody: null as unknown as Node,
		currentFuncName: "",
	};
}

function createScope(isLoop: boolean, isFunction: boolean): DrcScope {
	return {
		varsToCleanup: [],
		wasMoved: [],
		needsTry: false,
		isLoop,
		isFunction,
	};
}

// ===== Scope Operations =====

export function pushScope(dctx: DrcContext, isLoop: boolean, isFunction: boolean): void {
	const scope = createScope(isLoop, isFunction);
	dctx.scopes.push(scope);
}

export function popScope(dctx: DrcContext): DrcScope {
	return dctx.scopes.pop();
}

export function currentScope(dctx: DrcContext): DrcScope {
	return dctx.scopes[dctx.scopes.length - 1];
}

export function scopeDepth(dctx: DrcContext): number {
	return dctx.scopes.length;
}

// ===== Variable Registration =====

export function registerVar(dctx: DrcContext, varName: string, rcInfo: RcInfo, isCursor: boolean): void {
	if (!rcInfo.needsCleanup) return;
	if (isCursor) return;  // cursors are borrowed, never cleaned up
	const scope = currentScope(dctx);
	const info: VarInfo = { varName, rcInfo, isCursor: false, isInitialized: true };
	scope.varsToCleanup.push(info);
}

// Mark a variable as uninitialized (for `let x;` without initializer — Phase D first-write optimization)
export function markUninitialized(dctx: DrcContext, varName: string): void {
	const vi = findVarInfoInContext(dctx, varName);
	if (vi !== null) {
		vi.isInitialized = false;
	}
}

// ===== Move Tracking =====

export function recordMove(dctx: DrcContext, varName: string): void {
	const scope = currentScope(dctx);
	const mv: MovedVar = { varName };
	scope.wasMoved.push(mv);
}

export function wasMovedInScope(scope: DrcScope, varName: string): boolean {
	for (const mv of scope.wasMoved) {
		if (mv.varName === varName) return true;
	}
	return false;
}

// Record move in the scope that actually tracks the variable (for return cleanup)
export function recordMoveInContext(dctx: DrcContext, varName: string): void {
	let i = dctx.scopes.length;
	while (i > 0) {
		i -= 1;
		const vi = findVarInfo(dctx.scopes[i], varName);
		if (vi !== null) {
			const mv: MovedVar = { varName };
			dctx.scopes[i].wasMoved.push(mv);
			return;
		}
	}
	// Fallback: record on current scope
	recordMove(dctx, varName);
}

// ===== needsTry Propagation =====

// Set needsTry on all scopes from innermost to loop boundary (break/continue)
export function setNeedsTryToLoop(dctx: DrcContext): void {
	let i = dctx.scopes.length;
	while (i > 0) {
		i -= 1;
		dctx.scopes[i].needsTry = true;
		if (dctx.scopes[i].isLoop) return;
	}
}

// Set needsTry on ALL scopes (return/throw)
export function setNeedsTryAll(dctx: DrcContext): void {
	for (let i = 0; i < dctx.scopes.length; i += 1) {
		dctx.scopes[i].needsTry = true;
	}
}

// ===== Lookup =====

export function findVarInfo(scope: DrcScope, varName: string): VarInfo {
	for (const vi of scope.varsToCleanup) {
		if (vi.varName === varName) return vi;
	}
	return null as unknown as VarInfo;
}

// Search all scopes from innermost outward
export function findVarInfoInContext(dctx: DrcContext, varName: string): VarInfo {
	let i = dctx.scopes.length;
	while (i > 0) {
		i -= 1;
		const vi = findVarInfo(dctx.scopes[i], varName);
		if (vi !== null) return vi;
	}
	return null as unknown as VarInfo;
}

// ===== Pending Statement Buffers =====

export function addPending(dctx: DrcContext, stmt: Node): void {
	dctx.pendingStmts.push(stmt);
}

export function addPre(dctx: DrcContext, stmt: Node): void {
	dctx.preStmts.push(stmt);
}

export function flushPending(dctx: DrcContext, target: Node[]): void {
	for (const s of dctx.pendingStmts) {
		target.push(s);
	}
	const empty: Node[] = [];
	dctx.pendingStmts = empty;
}

export function flushPre(dctx: DrcContext, target: Node[]): void {
	for (const s of dctx.preStmts) {
		target.push(s);
	}
	const empty: Node[] = [];
	dctx.preStmts = empty;
}

export function hasPending(dctx: DrcContext): boolean {
	return dctx.pendingStmts.length > 0;
}

export function hasPre(dctx: DrcContext): boolean {
	return dctx.preStmts.length > 0;
}

// ===== Outer Statement Context Operations =====

export function pushOuterStmts(dctx: DrcContext, stmts: Node[], fromIndex: number, isFunctionBoundary: boolean): void {
	const entry: OuterEntry = { outerStmts: stmts, fromIndex, isFunctionBoundary };
	dctx.outerCtx.push(entry);
}

export function popOuterStmts(dctx: DrcContext): void {
	dctx.outerCtx.pop();
}

// ===== Test Helpers =====

function testDrcCtx(): DrcContext {
	const ctx = createTransformContext();
	return createDrcContext(ctx);
}

export function testStringRc(): RcInfo {
	return {
		rcKind: RcKind.String, typeName: "", needsCleanup: true,
		destroyFn: "msStringDecref", copyFn: "msStringIncref",
		wasMovedFn: "msStringWasMoved", sinkFn: "msStringSink",
	};
}

function testMinimalRc(): RcInfo {
	return {
		rcKind: RcKind.String, typeName: "", needsCleanup: true,
		destroyFn: "msStringDecref", copyFn: "",
		wasMovedFn: "", sinkFn: "",
	};
}

// ===== Tests =====
test "create context" {
	const dctx = testDrcCtx();
	assert scopeDepth(dctx) === 0;
}

test "push and pop scope" {
	const dctx = testDrcCtx();
	pushScope(dctx, false, true);
	assert scopeDepth(dctx) === 1;
	assert currentScope(dctx).isFunction;
	assert !currentScope(dctx).isLoop;
	popScope(dctx);
	assert scopeDepth(dctx) === 0;
}

test "nested scopes" {
	const dctx = testDrcCtx();
	pushScope(dctx, false, true);
	pushScope(dctx, true, false);
	assert scopeDepth(dctx) === 2;
	assert currentScope(dctx).isLoop;
	popScope(dctx);
	assert scopeDepth(dctx) === 1;
	assert currentScope(dctx).isFunction;
	popScope(dctx);
}

test "register RC var" {
	const dctx = testDrcCtx();
	pushScope(dctx, false, true);
	const rcInfo = testStringRc();
	registerVar(dctx, "s", rcInfo, false);
	assert currentScope(dctx).varsToCleanup.length === 1;
	assert currentScope(dctx).varsToCleanup[0].varName === "s";
	popScope(dctx);
}

test "skip non-cleanup type" {
	const dctx = testDrcCtx();
	pushScope(dctx, false, true);
	const info = noRcInfo();
	registerVar(dctx, "x", info, false);
	assert currentScope(dctx).varsToCleanup.length === 0;
	popScope(dctx);
}

test "skip cursor" {
	const dctx = testDrcCtx();
	pushScope(dctx, false, true);
	const rcInfo = testStringRc();
	registerVar(dctx, "s", rcInfo, true);
	assert currentScope(dctx).varsToCleanup.length === 0;
	popScope(dctx);
}

test "recordMove + wasMovedInScope" {
	const dctx = testDrcCtx();
	pushScope(dctx, false, true);
	recordMove(dctx, "x");
	assert wasMovedInScope(currentScope(dctx), "x");
	assert !wasMovedInScope(currentScope(dctx), "y");
	popScope(dctx);
}

test "setNeedsTryAll" {
	const dctx = testDrcCtx();
	pushScope(dctx, false, true);
	pushScope(dctx, true, false);
	pushScope(dctx, false, false);
	setNeedsTryAll(dctx);
	assert dctx.scopes[0].needsTry;
	assert dctx.scopes[1].needsTry;
	assert dctx.scopes[2].needsTry;
	popScope(dctx);
	popScope(dctx);
	popScope(dctx);
}

test "setNeedsTryToLoop stops at loop" {
	const dctx = testDrcCtx();
	pushScope(dctx, false, true);   // function
	pushScope(dctx, true, false);   // loop
	pushScope(dctx, false, false);  // block inside loop
	setNeedsTryToLoop(dctx);
	assert !dctx.scopes[0].needsTry;  // function — NOT set
	assert dctx.scopes[1].needsTry;    // loop — set (it's the boundary)
	assert dctx.scopes[2].needsTry;    // block — set
	popScope(dctx);
	popScope(dctx);
	popScope(dctx);
}

test "findVarInfo found" {
	const dctx = testDrcCtx();
	pushScope(dctx, false, true);
	const rcInfo = testMinimalRc();
	registerVar(dctx, "s", rcInfo, false);
	const vi = findVarInfo(currentScope(dctx), "s");
	assert vi !== null;
	assert vi.varName === "s";
	popScope(dctx);
}

test "findVarInfo not found" {
	const dctx = testDrcCtx();
	pushScope(dctx, false, true);
	const vi = findVarInfo(currentScope(dctx), "nope");
	assert vi === null;
	popScope(dctx);
}

test "findVarInfoInContext searches outer scopes" {
	const dctx = testDrcCtx();
	pushScope(dctx, false, true);
	const rcInfo = testMinimalRc();
	registerVar(dctx, "outer", rcInfo, false);
	pushScope(dctx, false, false);
	const vi = findVarInfoInContext(dctx, "outer");
	assert vi !== null;
	assert vi.varName === "outer";
	const none = findVarInfoInContext(dctx, "nope");
	assert none === null;
	popScope(dctx);
	popScope(dctx);
}

test "initially empty" {
	const dctx = testDrcCtx();
	assert !hasPending(dctx);
	assert dctx.pendingStmts.length === 0;
}

test "add and flush cycle" {
	const dctx = testDrcCtx();
	const loc: SourceLocation = { line: 0, column: 0 };
	addPending(dctx, makeExprStmt(makeNull(loc), loc));
	assert hasPending(dctx);
	const target: Node[] = [];
	flushPending(dctx, target);
	assert !hasPending(dctx);
	assert target.length === 1;
}

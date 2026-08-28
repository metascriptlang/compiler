// DRC Scope Management — tracks variables and cleanup obligations per scope
//
// Each scope (function, block, loop) tracks:
//   - varsToCleanup: variables needing =destroy at scope exit
//   - wasMoved: expr-level wasMoved calls (finally, before destroys) + var-level move
//     bookkeeping — destroys are UNCONDITIONAL; moved vars are zeroed inline at the move site
//   - needsTry: whether scope needs try/finally wrapping for cleanup
//
// Arrays passed by pointer — bare T[] types (wrappers removed).

import { Node, NodeKind, makeLoc, ExprStmtData, CallExprData, IdentifierData, Symbol } from "../ast/node";
import { RcInfo, RcKind, noRcInfo } from "./classify";
import { hasFlag, SymbolFlag } from "../checker/symbol";
import { CursorSet, createCursorSet } from "./cursors";
import { CfgCache, createCfgCache } from "./cfg";
import { TransformContext, NameSet, createTransformContext, createNameSet } from "../transform/context";
import { makeExprStmt, makeNull } from "../transform/util";

// Null symbol constant — used when DRC-generated temps have no checker symbol.
export const noSym: Symbol | null = null;

// ===== Variable Info =====

export interface VarInfo {
	varName: string;
	sym: Symbol | null;          // resolved symbol — used by codegen for unique naming
	rcInfo: RcInfo;
	isCursor: boolean;    // borrowed ref — never destroyed
	isInitialized: boolean; // first-write optimization: skip destroy on first assignment
}

export class MovedVar {
	varName: string;       // variable name (empty for expression-level moves)
	exprNode: Node;        // pre-built wasMoved call node (null for variable-level moves)
}

export class BorrowRead {
	readName: string;      // variable name read inline (Normal mode) in the current statement
	readNode: Node;        // the identifier node — rewritten in place if the var moves later
}

// ===== DRC Scope =====

export interface DrcScope {
	varsToCleanup: VarInfo[];     // variables needing cleanup at scope exit
	wasMoved: MovedVar[];         // expr-level wasMoved calls (emitted in finally) + var-level move bookkeeping
	preStmts: Node[];             // stmts to flush before current statement (per-scope isolation, reference parity)
	pendingStmts: Node[];         // stmts to flush after current statement (per-scope isolation, reference parity)
	needsTry: boolean;            // does this scope need try/finally wrapping?
	isLoop: boolean;              // is this a loop body scope?
	isFunction: boolean;          // is this a function scope?
}

// ===== Outer Statement Context (for cross-scope last-read analysis) =====

export class OuterEntry {
	outerStmts: Node[];
	fromIndex: number;
	isFunctionBoundary: boolean;  // function boundary — stop cross-scope search
}

// ===== DRC Context =====

export interface DrcContext {
	ctx: TransformContext;
	scopes: DrcScope[];          // scope stack
	outerCtx: OuterEntry[];      // cross-scope remaining stmts for last-read
	currentStmtIdx: number;      // Index of the statement currently being processed
	currentStmtList: Node[];     // The list containing the current statement
	finallyProtectedVars: NameSet;  // vars in enclosing finally blocks — never last-read (Phase A)
	cursors: CursorSet;             // cursor variables — skip all RC ops (Phase B)
	cfgCache: CfgCache;             // CFG cache per variable — Phase C
	currentFuncBody: Node | null;   // current function body for CFG building — Phase C
	currentFuncName: string;        // current function name — for DRC hook detection
	stmtBorrowReads: BorrowRead[];  // Normal-mode inline reads of RC vars in the current statement
	                                // — retro-hoisted to borrow temps if the var moves later in it
	inEnsureMove: number;           // depth of explicit `move` arguments being walked — a copy
	                                // decision under it is errFailedMove (reference parity)
	capturedNodes: Node[];
	capturedSyms: Symbol[];
	skipAwaitableCapture: boolean;  // set ONLY while walking a non-RC binding/cond initializer:
	                                // ensureDestruction must not capture a future there (the
	                                // await/spawn lowering's stepper owns it — PARALOCK). The
	                                // existing discarded-call path leaves this false so a genuine
	                                // fire-and-forget future IS still captured + destroyed.
}

// ===== Constructors =====

export function createDrcContext(ctx: TransformContext): DrcContext {
	return {
		ctx,
		scopes: [],
		outerCtx: [],
		currentStmtIdx: 0,
		currentStmtList: [],
		finallyProtectedVars: createNameSet(),
		cursors: createCursorSet(),
		cfgCache: createCfgCache(),
		currentFuncBody: null,
		currentFuncName: "",
		stmtBorrowReads: [],
		inEnsureMove: 0,
		skipAwaitableCapture: false,
		capturedNodes: [],
		capturedSyms: [],
	};
}

function createScope(isLoop: boolean, isFunction: boolean): DrcScope {
	return {
		varsToCleanup: [],
		wasMoved: [],
		preStmts: [],
		pendingStmts: [],
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

export function registerVar(dctx: DrcContext, varName: string, rcInfo: RcInfo, isCursor: boolean, sym: Symbol | null): void {
	if (isCursor) {
		// Cursors are borrowed — never cleaned up, but MUST be registered so
		// field accesses (d.field) are recognized as borrows by isLastReadFieldSafe.
		const scope = currentScope(dctx);
		const info: VarInfo = { varName, sym, rcInfo, isCursor: true, isInitialized: true };
		scope.varsToCleanup.push(info);
		return;
	}
	if (!rcInfo.needsCleanup) return;
	// Module-scope storage outlives every frame that touches it, so it must not
	// join this scope's cleanup list — destroying it at scope exit frees the value
	// for all later callers. Reference parity: the decision is made at the
	// declaration, which routes a global's destroy to a program-exit list instead
	// of the scope's final section; module globals are never destroyed here, so
	// declining to register is that same routing.
	if (sym !== null && hasFlag(sym, SymbolFlag.Global)) return;
	const scope = currentScope(dctx);
	const info: VarInfo = { varName, sym, rcInfo, isCursor: false, isInitialized: true };
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
	if (wasMovedInScope(scope, varName)) return;
	const mv: MovedVar = { varName, exprNode: null as unknown as Node };
	scope.wasMoved.push(mv);
}

export function wasMovedInScope(scope: DrcScope, varName: string): boolean {
	for (const mv of scope.wasMoved) {
		if (mv.varName === varName) return true;
	}
	return false;
}

// Record move bookkeeping in the scope that tracks the variable — read only by
// varMovedInContext (the self-consume assignment gates); cleanup destroys unconditionally.
export function recordMoveInContext(dctx: DrcContext, varName: string): void {
	let i = dctx.scopes.length;
	while (i > 0) {
		i -= 1;
		const vi = findVarInfo(dctx.scopes[i], varName);
		if (vi !== null) {
			if (!wasMovedInScope(dctx.scopes[i], varName)) {
				const mv: MovedVar = { varName, exprNode: null as unknown as Node };
				dctx.scopes[i].wasMoved.push(mv);
			}
			return;
		}
	}
	// Fallback: record on current scope
	recordMove(dctx, varName);
}

// Record an expression-level wasMoved call (for move obj.field / move arr[i]).
// Stored in wasMoved with empty varName — emitted in finally before destructors.
export function recordMoveExpr(dctx: DrcContext, wasMovedCall: Node): void {
	const scope = currentScope(dctx);
	const mv: MovedVar = { varName: "", exprNode: wasMovedCall };
	scope.wasMoved.push(mv);
}

// True if varName was recorded moved in the scope that actually tracks it.
export function varMovedInContext(dctx: DrcContext, varName: string): boolean {
	let i = dctx.scopes.length;
	while (i > 0) {
		i -= 1;
		if (findVarInfo(dctx.scopes[i], varName) !== null) {
			return wasMovedInScope(dctx.scopes[i], varName);
		}
	}
	return false;
}

// Clear the moved record for varName in its owning scope — used when a reassignment gives
// the var a fresh value, so scope-exit destroys the new value instead of skipping it.
export function clearMoveInContext(dctx: DrcContext, varName: string): void {
	let i = dctx.scopes.length;
	while (i > 0) {
		i -= 1;
		if (findVarInfo(dctx.scopes[i], varName) !== null) {
			const filtered: MovedVar[] = [];
			for (const mv of dctx.scopes[i].wasMoved) {
				if (mv.varName !== varName) filtered.push(mv);
			}
			dctx.scopes[i].wasMoved = filtered;
			return;
		}
	}
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

// Search scopes only within the current function boundary.
// Stops at function scope boundaries — won't find module-level variables.
// Use this when determining if a variable is "local owned" vs "borrowed from outer scope".
export function findVarInfoInFunction(dctx: DrcContext, varName: string): VarInfo {
	let i = dctx.scopes.length;
	while (i > 0) {
		i -= 1;
		const scope = dctx.scopes[i];
		const vi = findVarInfo(scope, varName);
		if (vi !== null) return vi;
		// Once we pass through a function scope, everything below is outer/module scope
		if (scope.isFunction) return null as unknown as VarInfo;
	}
	return null as unknown as VarInfo;
}

// ===== Pending Statement Buffers =====

export function addPending(dctx: DrcContext, stmt: Node): void {
	currentScope(dctx).pendingStmts.push(stmt);
}

export function addPre(dctx: DrcContext, stmt: Node): void {
	currentScope(dctx).preStmts.push(stmt);
}

export function flushPending(dctx: DrcContext, target: Node[]): void {
	const scope = currentScope(dctx);
	for (const s of scope.pendingStmts) { target.push(s); }
	scope.pendingStmts = [];
}

export function flushPre(dctx: DrcContext, target: Node[]): void {
	const scope = currentScope(dctx);
	for (const s of scope.preStmts) { target.push(s); }
	scope.preStmts = [];
}

export function hasPending(dctx: DrcContext): boolean {
	return currentScope(dctx).pendingStmts.length > 0;
}

// Remove pending wasMoved stmts for a variable that was prematurely marked as last-read.
// Used when `x = f(x)` — the RHS arg `x` gets wasMoved but the assignment overwrites `x`.
export function clearPendingForVar(dctx: DrcContext, varName: string): void {
	const scope = currentScope(dctx);
	const filtered: Node[] = [];
	for (const s of scope.pendingStmts) {
		if (!isPendingWasMovedFor(s, varName)) {
			filtered.push(s);
		}
	}
	scope.pendingStmts = filtered;
}

function isPendingWasMovedFor(s: Node, varName: string): boolean {
	if (s.kind !== NodeKind.ExprStmt) return false;
	const ed = s.data as ExprStmtData;
	if (ed.expr.kind !== NodeKind.CallExpr) return false;
	const cd = ed.expr.data as CallExprData;
	if (cd.arguments.length === 0) return false;
	const arg = cd.arguments[0];
	// Ref types: msPtrWasMoved(varName) — direct Identifier arg
	if (arg.kind === NodeKind.Identifier) {
		return (arg.data as IdentifierData).name === varName;
	}
	// Named types: T_wasMoved(&varName) — HiddenAddr wrapping Identifier
	if (arg.kind === NodeKind.HiddenAddr) {
		const hd = arg.data as { expr: Node };
		if (hd.expr.kind === NodeKind.Identifier) {
			return (hd.expr.data as IdentifierData).name === varName;
		}
	}
	return false;
}

export function hasPre(dctx: DrcContext): boolean {
	return currentScope(dctx).preStmts.length > 0;
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
		destroyFn: "msStringDecref", copyFn: "msStringCopy",
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
	registerVar(dctx, "s", rcInfo, false, noSym);
	assert currentScope(dctx).varsToCleanup.length === 1;
	assert currentScope(dctx).varsToCleanup[0].varName === "s";
	popScope(dctx);
}

test "skip non-cleanup type" {
	const dctx = testDrcCtx();
	pushScope(dctx, false, true);
	const info = noRcInfo();
	registerVar(dctx, "x", info, false, noSym);
	assert currentScope(dctx).varsToCleanup.length === 0;
	popScope(dctx);
}

test "skip cursor" {
	const dctx = testDrcCtx();
	pushScope(dctx, false, true);
	const rcInfo = testStringRc();
	registerVar(dctx, "s", rcInfo, true, noSym);
	// Cursor IS registered (for findVarInfoInContext visibility) but marked isCursor=true.
	// generateCleanup skips cursor vars, so no destroy/wasMoved is emitted.
	assert currentScope(dctx).varsToCleanup.length === 1;
	const vi = currentScope(dctx).varsToCleanup[0];
	assert vi.isCursor;
	assert vi.varName === "s";
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
	registerVar(dctx, "s", rcInfo, false, noSym);
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
	registerVar(dctx, "outer", rcInfo, false, noSym);
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
	pushScope(dctx, false, false);
	assert !hasPending(dctx);
	assert currentScope(dctx).pendingStmts.length === 0;
}

test "add and flush cycle" {
	const dctx = testDrcCtx();
	pushScope(dctx, false, false);
	const loc = makeLoc(0, 0);
	addPending(dctx, makeExprStmt(makeNull(loc), loc));
	assert hasPending(dctx);
	const target: Node[] = [];
	flushPending(dctx, target);
	assert !hasPending(dctx);
	assert target.length === 1;
}

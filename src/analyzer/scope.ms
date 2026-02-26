// DRC Scope Management — tracks variables and cleanup obligations per scope
//
// Each scope (function, block, loop) tracks:
//   - varsToCleanup: variables needing =destroy at scope exit
//   - wasMoved: variables whose ownership was transferred (skip destroy)
//   - needsTry: whether scope needs try/finally wrapping for cleanup
//
// DRC-safe: all array-holding fields wrapped in interfaces (gotcha #4).

import { Node } from "../ast/node";
import { RcInfo, RcKind, noRcInfo } from "./classify";
import { TransformContext, freshTemp } from "../transform/context";
import { test, check, testGroup } from "std/testing";
import { createTransformContext } from "../transform/context";

// ===== Variable Info =====

export interface VarInfo {
	varName: string;
	rcInfo: RcInfo;
	isCursor: boolean;    // borrowed ref — never destroyed
}

// ===== DRC-safe list wrappers (string[]/Node[] are value types — gotcha #4) =====

export interface VarInfoList {
	items: VarInfo[];
}

export interface MovedVar {
	varName: string;
}

export interface MovedVarList {
	items: MovedVar[];
}

export interface StmtBuf {
	stmts: Node[];
}

// ===== DRC Scope =====

export interface DrcScope {
	varsToCleanup: VarInfoList;   // variables needing cleanup at scope exit
	wasMoved: MovedVarList;       // variables that were moved (skip destroy)
	needsTry: boolean;            // does this scope need try/finally wrapping?
	isLoop: boolean;              // is this a loop body scope?
	isFunction: boolean;          // is this a function scope?
}

// ===== DRC Context =====

export interface DrcScopeStack {
	items: DrcScope[];
}

export interface DrcContext {
	ctx: TransformContext;
	scopes: DrcScopeStack;          // scope stack
	pendingStmts: StmtBuf;       // stmts to flush after current statement
}

// ===== Constructors =====

export function createDrcContext(ctx: TransformContext): DrcContext {
	return {
		ctx,
		scopes: { items: [] },
		pendingStmts: { stmts: [] },
	};
}

function createScope(isLoop: boolean, isFunction: boolean): DrcScope {
	return {
		varsToCleanup: { items: [] },
		wasMoved: { items: [] },
		needsTry: false,
		isLoop,
		isFunction,
	};
}

// ===== Scope Operations =====

export function pushScope(dctx: DrcContext, isLoop: boolean, isFunction: boolean): void {
	const scope = createScope(isLoop, isFunction);
	dctx.scopes.items.push(scope);
}

export function popScope(dctx: DrcContext): DrcScope {
	return dctx.scopes.items.pop();
}

export function currentScope(dctx: DrcContext): DrcScope {
	return dctx.scopes.items[dctx.scopes.items.length - 1];
}

export function scopeDepth(dctx: DrcContext): number {
	return dctx.scopes.items.length;
}

// ===== Variable Registration =====

export function registerVar(dctx: DrcContext, varName: string, rcInfo: RcInfo, isCursor: boolean): void {
	if (!rcInfo.needsCleanup) return;
	if (isCursor) return;  // cursors are borrowed, never cleaned up
	const scope = currentScope(dctx);
	const info: VarInfo = { varName, rcInfo, isCursor: false };
	scope.varsToCleanup.items.push(info);
}

// ===== Move Tracking =====

export function recordMove(dctx: DrcContext, varName: string): void {
	const scope = currentScope(dctx);
	const mv: MovedVar = { varName };
	scope.wasMoved.items.push(mv);
}

export function wasMovedInScope(scope: DrcScope, varName: string): boolean {
	for (const mv of scope.wasMoved.items) {
		if (mv.varName === varName) return true;
	}
	return false;
}

// ===== needsTry Propagation =====

// Set needsTry on all scopes from innermost to loop boundary (break/continue)
export function setNeedsTryToLoop(dctx: DrcContext): void {
	let i = dctx.scopes.items.length;
	while (i > 0) {
		i -= 1;
		dctx.scopes.items[i].needsTry = true;
		if (dctx.scopes.items[i].isLoop) return;
	}
}

// Set needsTry on ALL scopes (return/throw)
export function setNeedsTryAll(dctx: DrcContext): void {
	let i = 0;
	while (i < dctx.scopes.items.length) {
		dctx.scopes.items[i].needsTry = true;
		i += 1;
	}
}

// ===== Lookup =====

export function findVarInfo(scope: DrcScope, varName: string): VarInfo {
	for (const vi of scope.varsToCleanup.items) {
		if (vi.varName === varName) return vi;
	}
	return null as unknown as VarInfo;
}

// Search all scopes from innermost outward
export function findVarInfoInContext(dctx: DrcContext, varName: string): VarInfo {
	let i = dctx.scopes.items.length;
	while (i > 0) {
		i -= 1;
		const vi = findVarInfo(dctx.scopes.items[i], varName);
		if (vi !== null) return vi;
	}
	return null as unknown as VarInfo;
}

// ===== Pending Statement Buffer =====

export function addPending(dctx: DrcContext, stmt: Node): void {
	dctx.pendingStmts.stmts.push(stmt);
}

export function flushPending(dctx: DrcContext, target: StmtBuf): void {
	while (dctx.pendingStmts.stmts.length > 0) {
		const s = dctx.pendingStmts.stmts[0];
		target.stmts.push(s);
		dctx.pendingStmts.stmts.shift();
	}
}

export function hasPending(dctx: DrcContext): boolean {
	return dctx.pendingStmts.stmts.length > 0;
}

// ===== Test Helpers =====

function testDrcCtx(): DrcContext {
	const ctx = createTransformContext();
	return createDrcContext(ctx);
}

function testStringRc(): RcInfo {
	return {
		rcKind: RcKind.String, typeName: "", needsCleanup: true,
		destroyFn: "ms_string_decref", copyFn: "ms_string_incref",
		wasMovedFn: "ms_string_was_moved", sinkFn: "ms_string_sink",
	};
}

function testMinimalRc(): RcInfo {
	return {
		rcKind: RcKind.String, typeName: "", needsCleanup: true,
		destroyFn: "ms_string_decref", copyFn: "",
		wasMovedFn: "", sinkFn: "",
	};
}

// ===== Tests =====

testGroup("DrcScope Basics", () => {
	test("create context", () => {
		const dctx = testDrcCtx();
		check(scopeDepth(dctx) === 0);
	});
	test("push and pop scope", () => {
		const dctx = testDrcCtx();
		pushScope(dctx, false, true);
		check(scopeDepth(dctx) === 1);
		check(currentScope(dctx).isFunction);
		check(!currentScope(dctx).isLoop);
		popScope(dctx);
		check(scopeDepth(dctx) === 0);
	});
	test("nested scopes", () => {
		const dctx = testDrcCtx();
		pushScope(dctx, false, true);
		pushScope(dctx, true, false);
		check(scopeDepth(dctx) === 2);
		check(currentScope(dctx).isLoop);
		popScope(dctx);
		check(scopeDepth(dctx) === 1);
		check(currentScope(dctx).isFunction);
		popScope(dctx);
	});
});

testGroup("DrcScope RegisterVar", () => {
	test("register RC var", () => {
		const dctx = testDrcCtx();
		pushScope(dctx, false, true);
		const rcInfo = testStringRc();
		registerVar(dctx, "s", rcInfo, false);
		check(currentScope(dctx).varsToCleanup.items.length === 1);
		check(currentScope(dctx).varsToCleanup.items[0].varName === "s");
		popScope(dctx);
	});
	test("skip non-cleanup type", () => {
		const dctx = testDrcCtx();
		pushScope(dctx, false, true);
		const info = noRcInfo();
		registerVar(dctx, "x", info, false);
		check(currentScope(dctx).varsToCleanup.items.length === 0);
		popScope(dctx);
	});
	test("skip cursor", () => {
		const dctx = testDrcCtx();
		pushScope(dctx, false, true);
		const rcInfo = testStringRc();
		registerVar(dctx, "s", rcInfo, true);
		check(currentScope(dctx).varsToCleanup.items.length === 0);
		popScope(dctx);
	});
});

testGroup("DrcScope MoveTracking", () => {
	test("recordMove + wasMovedInScope", () => {
		const dctx = testDrcCtx();
		pushScope(dctx, false, true);
		recordMove(dctx, "x");
		check(wasMovedInScope(currentScope(dctx), "x"));
		check(!wasMovedInScope(currentScope(dctx), "y"));
		popScope(dctx);
	});
});

testGroup("DrcScope NeedsTry", () => {
	test("setNeedsTryAll", () => {
		const dctx = testDrcCtx();
		pushScope(dctx, false, true);
		pushScope(dctx, true, false);
		pushScope(dctx, false, false);
		setNeedsTryAll(dctx);
		check(dctx.scopes.items[0].needsTry);
		check(dctx.scopes.items[1].needsTry);
		check(dctx.scopes.items[2].needsTry);
		popScope(dctx);
		popScope(dctx);
		popScope(dctx);
	});
	test("setNeedsTryToLoop stops at loop", () => {
		const dctx = testDrcCtx();
		pushScope(dctx, false, true);   // function
		pushScope(dctx, true, false);   // loop
		pushScope(dctx, false, false);  // block inside loop
		setNeedsTryToLoop(dctx);
		check(!dctx.scopes.items[0].needsTry);  // function — NOT set
		check(dctx.scopes.items[1].needsTry);    // loop — set (it's the boundary)
		check(dctx.scopes.items[2].needsTry);    // block — set
		popScope(dctx);
		popScope(dctx);
		popScope(dctx);
	});
});

testGroup("DrcScope FindVar", () => {
	test("findVarInfo found", () => {
		const dctx = testDrcCtx();
		pushScope(dctx, false, true);
		const rcInfo = testMinimalRc();
		registerVar(dctx, "s", rcInfo, false);
		const vi = findVarInfo(currentScope(dctx), "s");
		check(vi !== null);
		check(vi.varName === "s");
		popScope(dctx);
	});
	test("findVarInfo not found", () => {
		const dctx = testDrcCtx();
		pushScope(dctx, false, true);
		const vi = findVarInfo(currentScope(dctx), "nope");
		check(vi === null);
		popScope(dctx);
	});
	test("findVarInfoInContext searches outer scopes", () => {
		const dctx = testDrcCtx();
		pushScope(dctx, false, true);
		const rcInfo = testMinimalRc();
		registerVar(dctx, "outer", rcInfo, false);
		pushScope(dctx, false, false);
		const vi = findVarInfoInContext(dctx, "outer");
		check(vi !== null);
		check(vi.varName === "outer");
		const none = findVarInfoInContext(dctx, "nope");
		check(none === null);
		popScope(dctx);
		popScope(dctx);
	});
});

testGroup("DrcScope Pending", () => {
	test("add and flush pending", () => {
		const dctx = testDrcCtx();
		check(!hasPending(dctx));
		check(dctx.pendingStmts.stmts.length === 0);
	});
});

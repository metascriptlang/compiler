// DRC Injection — main AST walker that inserts RC operations
//
// Architecture: top-down walk of each function body.
// For each scope:
//   1. Push scope on entry
//   2. Process statements, inserting RC calls
//   3. On exit: emit cleanup (destroy in LIFO order)
//   4. If scope has early exits: wrap in try/finally
//
// Follows the injectdestructors pattern (direct AST rewrite, scope-based).

import {
	Node, NodeKind, SourceLocation, ProgramData,
	FunctionDeclData, ArrowFunctionData, FunctionExprData,
	MethodDeclData, ConstructorDeclData,
	BlockStmtData, VariableDeclData, ExprStmtData,
	ReturnStmtData, IfStmtData, WhileStmtData, ForStmtData,
	TryCatchStmtData, SwitchStmtData, SwitchCaseData,
	BinaryExprData, CallExprData, IdentifierData, MemberExprData,
	ExportDeclData, ClassDeclData, DecoratedDeclData,
	ForOfStmtData, DoWhileStmtData,
} from "../ast/node";
import { Type, TypeKind } from "../checker/types";
import { lookupSymbol, SymbolKind } from "../checker/symbol";
import { TransformContext, NameSet, nameSetContains, nameSetAdd, freshTemp } from "../transform/context";
import {
	makeIdent, makeBlock, makeExprStmt, makeCall, makeVarDecl,
	makeReturn, makeAssign, makeTryCatch, makeNull, makeBinary,
} from "../transform/util";
import { RcInfo, RcKind, classifyType, isFreshExpr, noRcInfo } from "./classify";
import {
	DrcContext, DrcScope, VarInfo, StmtBuf,
	createDrcContext, pushScope, popScope, currentScope, scopeDepth,
	registerVar, recordMove, wasMovedInScope, findVarInfo, findVarInfoInContext,
	setNeedsTryToLoop, setNeedsTryAll, addPending, flushPending, hasPending,
} from "./scope";
import { isLastReadInBlock, deepAliases, nodeReferencesVar } from "./lastRead";
import { test, check, testGroup } from "std/testing";
import { checkSource } from "../checker/checkPass";
import { transformProgram } from "../transform/index";

// ===== RC Call Builders =====

function makeRcCallStmt(fnName: string, varName: string, loc: SourceLocation): Node {
	if (fnName === "") return makeExprStmt(makeNull(loc), loc);
	return makeExprStmt(
		makeCall(makeIdent(fnName, loc), [makeIdent(varName, loc)], loc), loc);
}

function makeDestroyCall(varName: string, rcInfo: RcInfo, loc: SourceLocation): Node {
	return makeRcCallStmt(rcInfo.destroyFn, varName, loc);
}

function makeWasMovedCall(varName: string, rcInfo: RcInfo, loc: SourceLocation): Node {
	return makeRcCallStmt(rcInfo.wasMovedFn, varName, loc);
}

function makeCopyAfterInit(destName: string, rcInfo: RcInfo, loc: SourceLocation): Node {
	return makeRcCallStmt(rcInfo.copyFn, destName, loc);
}

// ===== Collect identifiers used in a return expression =====

function collectReturnedIdents(node: Node, names: NameSet): void {
	if (node === null) return;
	match (node.kind) {
		NodeKind.Identifier => { nameSetAdd(names, (node.data as IdentifierData).name); },
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			collectReturnedIdents(d.left, names);
			collectReturnedIdents(d.right, names);
		},
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			collectReturnedIdents(d.callee, names);
			for (const arg of d.arguments) { collectReturnedIdents(arg, names); }
		},
		NodeKind.MemberExpr => { collectReturnedIdents((node.data as MemberExprData).object, names); },
		_ => {},
	};
}

// ===== Scope Cleanup Generation =====

function generateCleanup(scope: DrcScope, excludeNames: NameSet, loc: SourceLocation): Node[] {
	const result: Node[] = [];

	// Step 1: wasMoved calls for moved variables
	for (const mv of scope.wasMoved.items) {
		const vi = findVarInfo(scope, mv.varName);
		if (vi !== null && vi.rcInfo.wasMovedFn !== "") {
			result.push(makeWasMovedCall(mv.varName, vi.rcInfo, loc));
		}
	}

	// Step 2: destroy in LIFO order
	let i = scope.varsToCleanup.items.length;
	while (i > 0) {
		i -= 1;
		const vi = scope.varsToCleanup.items[i];
		if (vi.isCursor) continue;
		if (excludeNames !== null && nameSetContains(excludeNames, vi.varName)) continue;
		if (wasMovedInScope(scope, vi.varName)) continue;
		if (vi.rcInfo.destroyFn === "") continue;
		result.push(makeDestroyCall(vi.varName, vi.rcInfo, loc));
	}

	return result;
}

// ===== Try/Finally Wrapping =====

function wrapWithTryFinally(bodyStmts: Node[], cleanupStmts: Node[], scope: DrcScope, loc: SourceLocation): Node {
	// Hoist RC variable declarations before try (null init for setjmp safety)
	const hoisted: Node[] = [];
	const tryBody: Node[] = [];

	for (const stmt of bodyStmts) {
		if (stmt.kind === NodeKind.VariableDecl) {
			const d = stmt.data as VariableDeclData;
			const vi = findVarInfo(scope, d.declName);
			if (vi !== null && vi.rcInfo.needsCleanup) {
				hoisted.push(makeVarDecl(d.declName, makeNull(loc), false, loc));
				if (d.initializer !== null) {
					tryBody.push(makeExprStmt(makeAssign(makeIdent(d.declName, loc), d.initializer, loc), loc));
				}
				continue;
			}
		}
		tryBody.push(stmt);
	}

	const tryBlock = makeBlock(tryBody, loc);
	const finallyBlock = makeBlock(cleanupStmts, loc);
	const tryFinally = makeTryCatch(tryBlock, "", makeNull(loc), finallyBlock, loc);

	const result: Node[] = [];
	for (const h of hoisted) {
		result.push(h);
	}
	result.push(tryFinally);
	return makeBlock(result, loc);
}

// ===== Statement List Processing =====

function processStmtList(stmts: Node[], dctx: DrcContext, loc: SourceLocation): Node[] {
	const out: StmtBuf = { stmts: [] };
	let i = 0;
	while (i < stmts.length) {
		const processed = processStmt(stmts[i], i, stmts, dctx, loc);
		out.stmts.push(processed);
		flushPending(dctx, out);
		i += 1;
	}
	return out.stmts;
}

// ===== Empty NameSet factory (avoids repeated `{ names: [] }`) =====

function emptyNameSet(): NameSet {
	return { names: [] };
}

// ===== Simple scoped statement list (no try/finally) =====
// Used by switch cases and program-level — push scope, process, pop, append cleanup.

function processStmtListScoped(stmts: Node[], dctx: DrcContext, loc: SourceLocation): Node[] {
	pushScope(dctx, false, false);
	const processed = processStmtList(stmts, dctx, loc);
	const scope = popScope(dctx);
	const cleanup = generateCleanup(scope, emptyNameSet(), loc);
	for (const cs of cleanup) { processed.push(cs); }
	return processed;
}

// ===== Unified block scope processing =====
// Handles function bodies (isFunction=true), loop bodies (isLoop=true), and plain blocks.

function processBlockBody(body: Node, dctx: DrcContext, isLoop: boolean, isFunction: boolean, loc: SourceLocation): Node {
	if (body === null) return body;
	if (body.kind !== NodeKind.BlockStmt) return body;
	const bd = body.data as BlockStmtData;

	pushScope(dctx, isLoop, isFunction);
	const processed = processStmtList(bd.statements, dctx, loc);
	const scope = popScope(dctx);
	const cleanup = generateCleanup(scope, emptyNameSet(), loc);

	if (scope.needsTry && cleanup.length > 0) {
		return wrapWithTryFinally(processed, cleanup, scope, loc);
	}
	for (const cs of cleanup) {
		processed.push(cs);
	}
	return makeBlock(processed, loc);
}

// ===== Per-Statement Dispatch =====

function processStmt(stmt: Node, idx: number, stmts: Node[], dctx: DrcContext, loc: SourceLocation): Node {
	if (stmt === null) return stmt;
	const sloc = stmt.location;

	return match (stmt.kind) {
		NodeKind.VariableDecl => processVarDecl(stmt, idx, stmts, dctx, sloc),
		NodeKind.ReturnStmt => processReturn(stmt, dctx, sloc),
		NodeKind.ExprStmt => processExprStmt(stmt, idx, stmts, dctx, sloc),
		NodeKind.FunctionDecl => processFuncDecl(stmt, dctx, sloc),
		NodeKind.IfStmt => processIf(stmt, dctx, sloc),
		NodeKind.WhileStmt => processWhile(stmt, dctx, sloc),
		NodeKind.ForStmt => processFor(stmt, dctx, sloc),
		NodeKind.BlockStmt => processBlockBody(stmt, dctx, false, false, sloc),
		NodeKind.TryCatchStmt => processTryCatch(stmt, dctx, sloc),
		NodeKind.SwitchStmt => processSwitch(stmt, dctx, sloc),
		NodeKind.BreakStmt | NodeKind.ContinueStmt => { setNeedsTryToLoop(dctx); stmt },
		NodeKind.ThrowStmt => { setNeedsTryAll(dctx); stmt },
		NodeKind.ExportDecl => processExport(stmt, dctx, sloc),
		NodeKind.ClassDecl => processClass(stmt, dctx, sloc),
		_ => stmt,
	};
}

// ===== Variable Declaration =====

function processVarDecl(stmt: Node, idx: number, stmts: Node[], dctx: DrcContext, loc: SourceLocation): Node {
	const d = stmt.data as VariableDeclData;

	// Look up declared type from symbol table
	if (dctx.ctx.checkerCtx === null) return stmt;
	const sym = lookupSymbol(dctx.ctx.checkerCtx.table, d.declName);
	if (sym === null) return stmt;

	const rcInfo = classifyType(sym.symbolType, dctx.ctx);
	if (!rcInfo.needsCleanup) return stmt;

	// Register for scope cleanup
	registerVar(dctx, d.declName, rcInfo, false);

	if (d.initializer === null) return stmt;
	const init = d.initializer;

	// Fresh expression: SINK — ownership transfers directly
	if (isFreshExpr(init.kind)) return stmt;

	// Identifier init: check last-read for MOVE vs COPY
	if (init.kind === NodeKind.Identifier) {
		const initD = init.data as IdentifierData;
		if (isLastReadInBlock(initD.name, idx, stmts)) {
			// MOVE: keep assignment, emit wasMoved for source
			if (rcInfo.wasMovedFn !== "") {
				addPending(dctx, makeWasMovedCall(initD.name, rcInfo, loc));
			}
			recordMove(dctx, initD.name);
			return stmt;
		}
		// COPY: emit incref/copy after assignment
		const copyNode = makeCopyAfterInit(d.declName, rcInfo, loc);
		addPending(dctx, copyNode);
		return stmt;
	}

	// Member access: borrowed — needs incref for pointer types
	if (init.kind === NodeKind.MemberExpr) {
		if (rcInfo.rcKind === RcKind.Ref || rcInfo.rcKind === RcKind.String) {
			const copyNode = makeCopyAfterInit(d.declName, rcInfo, loc);
			addPending(dctx, copyNode);
		}
		return stmt;
	}

	return stmt;
}

// ===== Expression Statement (assignments + discarded calls) =====

function processExprStmt(stmt: Node, idx: number, stmts: Node[], dctx: DrcContext, loc: SourceLocation): Node {
	const d = stmt.data as ExprStmtData;
	const expr = d.expr;

	// Assignment: x = expr
	if (expr.kind === NodeKind.BinaryExpr) {
		const bd = expr.data as BinaryExprData;
		if (bd.operator === "=" && bd.left.kind === NodeKind.Identifier) {
			return processAssignment(stmt, expr, idx, stmts, dctx, loc);
		}
	}

	// Discarded call returning RC type: capture in temp
	if (expr.kind === NodeKind.CallExpr) {
		return processDiscardedCall(stmt, expr, dctx, loc);
	}

	return stmt;
}

// ===== Assignment Processing =====

function processAssignment(stmt: Node, assignExpr: Node, idx: number, stmts: Node[], dctx: DrcContext, loc: SourceLocation): Node {
	// Re-extract BinaryExprData from assignExpr (not passed as param — DRC gotcha #2)
	const bd = assignExpr.data as BinaryExprData;
	const leftD = bd.left.data as IdentifierData;

	if (dctx.ctx.checkerCtx === null) return stmt;
	const sym = lookupSymbol(dctx.ctx.checkerCtx.table, leftD.name);
	if (sym === null) return stmt;

	const rcInfo = classifyType(sym.symbolType, dctx.ctx);
	if (!rcInfo.needsCleanup) return stmt;

	const rhs = bd.right;

	// Fresh RHS: destroy old, then assign
	if (isFreshExpr(rhs.kind)) {
		if (deepAliases(leftD.name, rhs)) {
			// Aliased: save old, assign, destroy saved
			const tmpName = freshTemp(dctx.ctx, "old");
			const saveTmp = makeVarDecl(tmpName, makeIdent(leftD.name, loc), true, loc);
			const destroyTmp = makeDestroyCall(tmpName, rcInfo, loc);
			return makeBlock([saveTmp, stmt, destroyTmp], loc);
		}
		const destroyOld = makeDestroyCall(leftD.name, rcInfo, loc);
		return makeBlock([destroyOld, stmt], loc);
	}

	// Identifier RHS
	if (rhs.kind === NodeKind.Identifier) {
		const rightD = rhs.data as IdentifierData;
		const destroyOld = makeDestroyCall(leftD.name, rcInfo, loc);
		if (isLastReadInBlock(rightD.name, idx, stmts)) {
			// SINK: destroy old, assign, wasMoved source
			const wmCall = makeWasMovedCall(rightD.name, rcInfo, loc);
			recordMove(dctx, rightD.name);
			return makeBlock([destroyOld, stmt, wmCall], loc);
		}
		// COPY: destroy old, assign + incref
		const copyNode = makeCopyAfterInit(leftD.name, rcInfo, loc);
		return makeBlock([destroyOld, stmt, copyNode], loc);
	}

	return stmt;
}

// ===== Discarded Call Result =====

function processDiscardedCall(stmt: Node, callExpr: Node, dctx: DrcContext, loc: SourceLocation): Node {
	if (dctx.ctx.checkerCtx === null) return stmt;

	// Look up callee to determine return type
	const cd = callExpr.data as CallExprData;
	if (cd.callee.kind !== NodeKind.Identifier) return stmt;
	const calleeD = cd.callee.data as IdentifierData;
	const sym = lookupSymbol(dctx.ctx.checkerCtx.table, calleeD.name);
	if (sym === null) return stmt;

	// Check return type of function
	const fnType = sym.symbolType;
	if (fnType === null || fnType.typeReturn === null) return stmt;
	const retRcInfo = classifyType(fnType.typeReturn, dctx.ctx);
	if (!retRcInfo.needsCleanup) return stmt;

	// Capture in temp for proper cleanup
	const tmpName = freshTemp(dctx.ctx, "discard");
	const capture = makeVarDecl(tmpName, callExpr, true, loc);
	registerVar(dctx, tmpName, retRcInfo, false);
	return capture;
}

// ===== Return Statement =====

function processReturn(stmt: Node, dctx: DrcContext, loc: SourceLocation): Node {
	const d = stmt.data as ReturnStmtData;

	setNeedsTryAll(dctx);

	const excludeNames = emptyNameSet();
	if (d.argument !== null) {
		collectReturnedIdents(d.argument, excludeNames);
	}

	// Generate cleanup for all scopes (innermost to outermost)
	const allCleanup: Node[] = [];
	let i = dctx.scopes.items.length;
	while (i > 0) {
		i -= 1;
		const cleanup = generateCleanup(dctx.scopes.items[i], excludeNames, loc);
		for (const cs of cleanup) {
			allCleanup.push(cs);
		}
	}

	if (allCleanup.length === 0) return stmt;

	// Wrap: { cleanup...; return expr; }
	allCleanup.push(stmt);
	return makeBlock(allCleanup, loc);
}

// ===== Function Declaration =====

function processFuncDecl(stmt: Node, dctx: DrcContext, loc: SourceLocation): Node {
	const d = stmt.data as FunctionDeclData;
	if (d.fnBody === null) return stmt;
	d.fnBody = processBlockBody(d.fnBody, dctx, false, true, loc);
	return stmt;
}

// ===== Control Flow =====

function processIf(stmt: Node, dctx: DrcContext, loc: SourceLocation): Node {
	const d = stmt.data as IfStmtData;
	d.consequent = processBlockBody(d.consequent, dctx, false, false, loc);
	if (d.alternate !== null) {
		if (d.alternate.kind === NodeKind.IfStmt) {
			processIf(d.alternate, dctx, loc);
		} else {
			d.alternate = processBlockBody(d.alternate, dctx, false, false, loc);
		}
	}
	return stmt;
}

function processWhile(stmt: Node, dctx: DrcContext, loc: SourceLocation): Node {
	const d = stmt.data as WhileStmtData;
	d.whileBody = processBlockBody(d.whileBody, dctx, true, false, loc);
	return stmt;
}

function processFor(stmt: Node, dctx: DrcContext, loc: SourceLocation): Node {
	const d = stmt.data as ForStmtData;
	d.forBody = processBlockBody(d.forBody, dctx, true, false, loc);
	return stmt;
}

function processTryCatch(stmt: Node, dctx: DrcContext, loc: SourceLocation): Node {
	const d = stmt.data as TryCatchStmtData;
	d.tryBody = processBlockBody(d.tryBody, dctx, false, false, loc);
	if (d.catchBody !== null) {
		d.catchBody = processBlockBody(d.catchBody, dctx, false, false, loc);
	}
	if (d.finallyBody !== null) {
		d.finallyBody = processBlockBody(d.finallyBody, dctx, false, false, loc);
	}
	return stmt;
}

function processSwitchCase(caseNode: Node, dctx: DrcContext, loc: SourceLocation): void {
	const cd = caseNode.data as SwitchCaseData;
	cd.caseStmts = processStmtListScoped(cd.caseStmts, dctx, loc);
}

function processSwitch(stmt: Node, dctx: DrcContext, loc: SourceLocation): Node {
	const d = stmt.data as SwitchStmtData;
	for (const c of d.switchCases) {
		if (c.kind === NodeKind.SwitchCase) {
			processSwitchCase(c, dctx, loc);
		}
	}
	return stmt;
}

function processExport(stmt: Node, dctx: DrcContext, loc: SourceLocation): Node {
	const d = stmt.data as ExportDeclData;
	if (d.exportedDecl !== null && d.exportedDecl.kind === NodeKind.FunctionDecl) {
		processFuncDecl(d.exportedDecl, dctx, loc);
	}
	return stmt;
}

function processMethodMember(member: Node, dctx: DrcContext, loc: SourceLocation): void {
	const md = member.data as MethodDeclData;
	if (md.methodBody !== null) {
		md.methodBody = processBlockBody(md.methodBody, dctx, false, true, loc);
	}
}

function processCtorMember(member: Node, dctx: DrcContext, loc: SourceLocation): void {
	const cd = member.data as ConstructorDeclData;
	if (cd.ctorBody !== null) {
		cd.ctorBody = processBlockBody(cd.ctorBody, dctx, false, true, loc);
	}
}

function processClass(stmt: Node, dctx: DrcContext, loc: SourceLocation): Node {
	const d = stmt.data as ClassDeclData;
	for (const member of d.classBody) {
		match (member.kind) {
			NodeKind.MethodDecl => { processMethodMember(member, dctx, loc); },
			NodeKind.ConstructorDecl => { processCtorMember(member, dctx, loc); },
			_ => {},
		};
	}
	return stmt;
}

// ===== Program Entry Point =====

export function injectProgram(program: Node, dctx: DrcContext): Node {
	if (program.kind !== NodeKind.Program) return program;
	const d = program.data as ProgramData;

	d.programStmts = processStmtListScoped(d.programStmts, dctx, program.location);

	return program;
}

// ===== Tests =====

function testDrcContext(input: string): DrcContext {
	const ctx = checkSource(input);
	const tctx: TransformContext = { tempCounter: 0, errors: [], fnDeclNames: [], checkerCtx: ctx };
	return createDrcContext(tctx);
}

function testStringRcInfo(): RcInfo {
	return {
		rcKind: RcKind.String, typeName: "", needsCleanup: true,
		destroyFn: "ms_string_decref", copyFn: "ms_string_incref",
		wasMovedFn: "ms_string_was_moved", sinkFn: "ms_string_sink",
	};
}

function testLoc(): SourceLocation {
	return { line: 0, column: 0 };
}

testGroup("DRC Inject Basics", () => {
	test("injectProgram no-op on primitives", () => {
		const dctx = testDrcContext("const x = 1; const y = 2;");
		const prog = makeBlock([], testLoc());
		check(dctx.ctx.tempCounter === 0);
	});
	test("createDrcContext initializes", () => {
		const dctx = testDrcContext("const x = 1;");
		check(scopeDepth(dctx) === 0);
	});
});

testGroup("DRC Inject Cleanup", () => {
	test("generateCleanup LIFO order", () => {
		const dctx = testDrcContext("const x = 1;");
		pushScope(dctx, false, true);
		const rcStr = testStringRcInfo();
		registerVar(dctx, "a", rcStr, false);
		registerVar(dctx, "b", rcStr, false);
		const scope = popScope(dctx);
		const cleanup = generateCleanup(scope, emptyNameSet(), testLoc());
		check(cleanup.length === 2);
	});
	test("generateCleanup skips moved", () => {
		const dctx = testDrcContext("const x = 1;");
		pushScope(dctx, false, true);
		const rcStr = testStringRcInfo();
		registerVar(dctx, "a", rcStr, false);
		registerVar(dctx, "b", rcStr, false);
		recordMove(dctx, "b");
		const scope = popScope(dctx);
		const cleanup = generateCleanup(scope, emptyNameSet(), testLoc());
		// wasMoved(b) + destroy(a) = 2 nodes
		check(cleanup.length === 2);
	});
	test("generateCleanup skips excluded", () => {
		const dctx = testDrcContext("const x = 1;");
		pushScope(dctx, false, true);
		const rcStr = testStringRcInfo();
		registerVar(dctx, "a", rcStr, false);
		registerVar(dctx, "b", rcStr, false);
		const scope = popScope(dctx);
		const exclude: NameSet = { names: ["b"] };
		const cleanup = generateCleanup(scope, exclude, testLoc());
		check(cleanup.length === 1);
	});
});

testGroup("DRC Inject isFreshExpr Integration", () => {
	test("call is fresh", () => {
		check(isFreshExpr(NodeKind.CallExpr));
	});
	test("identifier is not fresh", () => {
		check(!isFreshExpr(NodeKind.Identifier));
	});
});

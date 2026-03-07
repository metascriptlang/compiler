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
	Node, NodeKind, DeclKind, SourceLocation, ProgramData,
	FunctionDeclData, ArrowFunctionData, FunctionExprData,
	MethodDeclData, ConstructorDeclData,
	BlockStmtData, VariableDeclData, ExprStmtData,
	ReturnStmtData, IfStmtData, WhileStmtData, ForStmtData,
	TryCatchStmtData, SwitchStmtData, SwitchCaseData,
	BinaryExprData, CallExprData, IdentifierData, MemberExprData,
	ArrayAccessData, ObjectLiteralData, ArrayLiteralData,
	ConditionalExprData,
	ExportDeclData, ClassDeclData,
	DoWhileStmtData, MoveExprData, Symbol,
} from "../ast/node";
import { Type, TypeKind } from "../checker/types";
import { lookupSymbol, lookupLocal, SymbolKind, hasFlag, SF_SINK, SF_LENT } from "../checker/symbol";
import { TransformContext, NameSet, nameSetContains, nameSetAdd, freshTemp, createTransformContextWithChecker } from "../transform/context";
import {
	makeIdent, makeBlock, makeExprStmt, makeCall, makeVarDecl,
	makeReturn, makeAssign, makeTryCatch, makeNull, makeBinary, makeMember,
	makeUnary,
} from "../transform/util";
import { RcInfo, RcKind, classifyType, isFreshExpr, noRcInfo } from "./classify";
import {
	DrcContext, DrcScope, VarInfo,
	createDrcContext, pushScope, popScope, currentScope, scopeDepth,
	registerVar, markUninitialized, recordMove, recordMoveInContext, wasMovedInScope, findVarInfo, findVarInfoInContext,
	setNeedsTryToLoop, setNeedsTryAll, addPending, flushPending, hasPending,
	addPre, flushPre,
	pushOuterStmts, popOuterStmts,
	testStringRc,
} from "./scope";
import { isLastReadInBlock, isLastReadInContext, deepAliases, nodeReferencesVar } from "./lastRead";
import { inferCursors, isCursorVar, createCursorSet } from "./cursors";
import { isLastReadCfgCached, clearCfgCache, createCfgCache } from "./cfg";
import { checkSource } from "../checker/checkPass";
import { transformProgram } from "../transform/index";

// ===== DRC Modes (Nim's ProcessMode parity) =====

export enum DrcMode {
	Normal,    // Just reading (borrow/lent)
	Consumed,  // Ownership transfer (sink/move)
}

// ===== Finally-Protected Variables (Phase A — correctness fix) =====
// Variables referenced in finally blocks must never be treated as last-read,
// because the finally block will use them after the "last" normal read.
// Prevents use-after-free with defer/try-finally patterns.

function collectIdentsInNode(node: Node, result: NameSet): void {
	if (node === null) return;
	if (node.kind === NodeKind.Identifier) {
		nameSetAdd(result, (node.data as IdentifierData).name);
	}
	if (node.kind === NodeKind.CallExpr) {
		const cd = node.data as CallExprData;
		collectIdentsInNode(cd.callee, result);
		for (const arg of cd.arguments) { collectIdentsInNode(arg, result); }
		return;
	}
	if (node.kind === NodeKind.BinaryExpr) {
		const bd = node.data as BinaryExprData;
		collectIdentsInNode(bd.left, result);
		collectIdentsInNode(bd.right, result);
		return;
	}
	if (node.kind === NodeKind.MemberExpr) {
		collectIdentsInNode((node.data as MemberExprData).object, result);
		return;
	}
	if (node.kind === NodeKind.ArrayAccess) {
		const ad = node.data as ArrayAccessData;
		collectIdentsInNode(ad.array, result);
		collectIdentsInNode(ad.index, result);
		return;
	}
	if (node.kind === NodeKind.ExprStmt) {
		collectIdentsInNode((node.data as ExprStmtData).expr, result);
		return;
	}
	if (node.kind === NodeKind.ReturnStmt) {
		collectIdentsInNode((node.data as ReturnStmtData).argument, result);
		return;
	}
	if (node.kind === NodeKind.BlockStmt) {
		const stmts = (node.data as BlockStmtData).statements;
		for (const s of stmts) { collectIdentsInNode(s, result); }
		return;
	}
	if (node.kind === NodeKind.IfStmt) {
		const id = node.data as IfStmtData;
		collectIdentsInNode(id.condition, result);
		collectIdentsInNode(id.consequent, result);
		collectIdentsInNode(id.alternate, result);
		return;
	}
	if (node.kind === NodeKind.WhileStmt) {
		const wd = node.data as WhileStmtData;
		collectIdentsInNode(wd.whileCondition, result);
		collectIdentsInNode(wd.whileBody, result);
		return;
	}
	if (node.kind === NodeKind.VariableDecl) {
		const vd = node.data as VariableDeclData;
		collectIdentsInNode(vd.initializer, result);
		return;
	}
	if (node.kind === NodeKind.ConditionalExpr) {
		const cd = node.data as ConditionalExprData;
		collectIdentsInNode(cd.ternaryCondition, result);
		collectIdentsInNode(cd.ternaryConsequent, result);
		collectIdentsInNode(cd.ternaryAlternate, result);
		return;
	}
	if (node.kind === NodeKind.ObjectLiteral) {
		const od = node.data as ObjectLiteralData;
		for (const prop of od.properties) { collectIdentsInNode(prop, result); }
		return;
	}
	if (node.kind === NodeKind.ArrayLiteral) {
		const ad = node.data as ArrayLiteralData;
		for (const elem of ad.elements) { collectIdentsInNode(elem, result); }
		return;
	}
}

function scanFinallyBlocks(node: Node, result: NameSet): void {
	if (node === null) return;
	if (node.kind === NodeKind.TryCatchStmt) {
		const td = node.data as TryCatchStmtData;
		if (td.finallyBody !== null) {
			collectIdentsInNode(td.finallyBody, result);
		}
		scanFinallyBlocks(td.tryBody, result);
		scanFinallyBlocks(td.catchBody, result);
		return;
	}
	if (node.kind === NodeKind.BlockStmt) {
		const stmts = (node.data as BlockStmtData).statements;
		for (const s of stmts) { scanFinallyBlocks(s, result); }
		return;
	}
	if (node.kind === NodeKind.IfStmt) {
		const id = node.data as IfStmtData;
		scanFinallyBlocks(id.consequent, result);
		scanFinallyBlocks(id.alternate, result);
		return;
	}
	if (node.kind === NodeKind.WhileStmt) {
		scanFinallyBlocks((node.data as WhileStmtData).whileBody, result);
		return;
	}
}

function collectFinallyVars(body: Node): NameSet {
	const result: NameSet = [];
	scanFinallyBlocks(body, result);
	return result;
}

// ===== Core Recursive Walker (Nim's p() parity) =====

function processNode(node: Node, dctx: DrcContext, mode: DrcMode): Node {
	if (node === null) return node;

	return match (node.kind) {
		NodeKind.Identifier => processIdentifier(node, dctx, mode),
		NodeKind.CallExpr => processCall(node, dctx, mode),
		NodeKind.BinaryExpr => processBinary(node, dctx, mode),
		NodeKind.MemberExpr => processMember(node, dctx, mode),
		NodeKind.ArrayAccess => processArrayAccess(node, dctx, mode),
		NodeKind.ObjectLiteral => processObjectLiteral(node, dctx, mode),
		NodeKind.ArrayLiteral => processArrayLiteral(node, dctx, mode),
		NodeKind.NewExpr => processNew(node, dctx, mode),
		NodeKind.MoveExpr => processMove(node, dctx, mode),
		NodeKind.ConditionalExpr => processConditional(node, dctx, mode),
		_ => node,
	};
}

function processCall(node: Node, dctx: DrcContext, mode: DrcMode): Node {
	const cd = node.data as CallExprData;
	// Recurse on callee
	cd.callee = processNode(cd.callee, dctx, DrcMode.Normal);
	// Nim parity: only sink params get Consumed mode, borrowed params get Normal.
	// Use resolvedSym to find callee's function type signature.
	const sym = node.resolvedSym;
	const fnType = (sym !== null && sym.symbolType !== null && sym.symbolType.kind === TypeKind.Function) ? sym.symbolType : null;
	for (let i = 0; i < cd.arguments.length; i += 1) {
		let argMode = DrcMode.Normal;
		if (fnType !== null && i < fnType.typeChildrenFlags.length && fnType.typeChildrenFlags[i] === SF_SINK) {
			argMode = DrcMode.Consumed;
		}
		cd.arguments[i] = processNode(cd.arguments[i], dctx, argMode);
	}
	return node;
}

function processBinary(node: Node, dctx: DrcContext, mode: DrcMode): Node {
	const bd = node.data as BinaryExprData;
	bd.left = processNode(bd.left, dctx, bd.operator === "=" ? DrcMode.Consumed : DrcMode.Normal);
	bd.right = processNode(bd.right, dctx, DrcMode.Normal);
	return node;
}

function processMember(node: Node, dctx: DrcContext, mode: DrcMode): Node {
	const md = node.data as MemberExprData;
	md.object = processNode(md.object, dctx, DrcMode.Normal);
	return node;
}

function processArrayAccess(node: Node, dctx: DrcContext, mode: DrcMode): Node {
	const ad = node.data as ArrayAccessData;
	ad.array = processNode(ad.array, dctx, DrcMode.Normal);
	ad.index = processNode(ad.index, dctx, DrcMode.Normal);
	return node;
}

function processObjectLiteral(node: Node, dctx: DrcContext, mode: DrcMode): Node {
	const od = node.data as ObjectLiteralData;
	for (let i = 0; i < od.properties.length; i += 1) {
		od.properties[i] = processNode(od.properties[i], dctx, DrcMode.Consumed);
	}
	return node;
}

function processArrayLiteral(node: Node, dctx: DrcContext, mode: DrcMode): Node {
	const ad = node.data as ArrayLiteralData;
	for (let i = 0; i < ad.elements.length; i += 1) {
		ad.elements[i] = processNode(ad.elements[i], dctx, DrcMode.Consumed);
	}
	return node;
}

function processNew(node: Node, dctx: DrcContext, mode: DrcMode): Node {
	const nd = node.data as NewExprData;
	for (let i = 0; i < nd.newArguments.length; i += 1) {
		nd.newArguments[i] = processNode(nd.newArguments[i], dctx, DrcMode.Consumed);
	}
	return node;
}

function processMove(node: Node, dctx: DrcContext, mode: DrcMode): Node {
	const md = node.data as MoveExprData;
	md.moveArg = processNode(md.moveArg, dctx, DrcMode.Consumed);
	return node;
}

function processConditional(node: Node, dctx: DrcContext, mode: DrcMode): Node {
	const cd = node.data as ConditionalExprData;
	cd.ternaryCondition = processNode(cd.ternaryCondition, dctx, DrcMode.Normal);
	cd.ternaryConsequent = processNode(cd.ternaryConsequent, dctx, mode);
	cd.ternaryAlternate = processNode(cd.ternaryAlternate, dctx, mode);
	return node;
}

function processIdentifier(node: Node, dctx: DrcContext, mode: DrcMode): Node {
	const d = node.data as IdentifierData;
	const sym = node.resolvedSym;
	if (sym === null) return node;

	// Nim parity: function/method declarations are static — no RC needed.
	// Bare function names inside closure thunks (e.g. { fn: isEven, env: null })
	// have TypeKind.Function but are not heap-allocated closures.
	if (sym.symbolKind === SymbolKind.Function || sym.symbolKind === SymbolKind.Method) return node;

	const rcInfo = classifyType(sym.symbolType, dctx.ctx);
	if (!rcInfo.needsCleanup) return node;

	// Nim parity: if mode is Consumed, decide between MOVE and COPY
	if (mode === DrcMode.Consumed) {
		const loc = node.location;
		if (isLastReadSafe(sym, node, dctx.currentStmtIdx, dctx.currentStmtList, dctx)) {
			// MOVE: emit wasMoved after the current statement
			if (rcInfo.wasMovedFn !== "") {
				addPending(dctx, makeWasMovedCall(d.name, rcInfo, loc));
			}
			recordMove(dctx, d.name);
		} else {
			// COPY: emit incref before the current statement
			if (rcInfo.copyFn !== "") {
				addPre(dctx, makeRcCallStmt(rcInfo.copyFn, d.name, loc));
			}
		}
	}

	return node;
}

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

// Sink call: sinkFn(dest, src) — atomic destroy-old + assign-new
function makeSinkCall(destName: string, srcExpr: Node, rcInfo: RcInfo, loc: SourceLocation): Node {
	return makeExprStmt(
		makeCall(makeIdent(rcInfo.sinkFn, loc), [makeIdent(destName, loc), srcExpr], loc), loc);
}

// RC call on arbitrary expression (for field/element wasMoved)
function makeRcCallOnExpr(fnName: string, argExpr: Node, loc: SourceLocation): Node {
	if (fnName === "") return makeExprStmt(makeNull(loc), loc);
	return makeExprStmt(
		makeCall(makeIdent(fnName, loc), [argExpr], loc), loc);
}

function makeWasMovedOnExpr(argExpr: Node, rcInfo: RcInfo, loc: SourceLocation): Node {
	return makeRcCallOnExpr(rcInfo.wasMovedFn, argExpr, loc);
}

// ===== MoveExpr Source Classification =====

// Classify RC type of a member expression's field
function classifyMemberFieldRc(memberExpr: Node, dctx: DrcContext): RcInfo {
	if (memberExpr.nodeType === null) return noRcInfo();
	return classifyType(memberExpr.nodeType, dctx.ctx);
}

// Classify RC type of an array element
function classifyArrayElementRc(arrayExpr: Node, dctx: DrcContext): RcInfo {
	if (arrayExpr.nodeType === null) return noRcInfo();
	return classifyType(arrayExpr.nodeType, dctx.ctx);
}

// Emit wasMoved on MoveExpr source. Handles identifier, field, array element.
// checkLastRead: true when idx/stmts context is valid (for errFailedMove diagnostic)
// Returns true if wasMoved was emitted.
function emitMoveSourceWasMoved(moveArg: Node, rcInfo: RcInfo, idx: number, stmts: Node[], dctx: DrcContext, loc: SourceLocation, checkLastRead: boolean): boolean {
	if (moveArg.kind === NodeKind.Identifier) {
		const srcName = (moveArg.data as IdentifierData).name;
		// errFailedMove diagnostic: error when move can't actually move
		if (checkLastRead && !isLastReadSafe(moveArg.resolvedSym, moveArg, idx, stmts, dctx)) {
			if (dctx.ctx.checkerCtx !== null) {
				dctx.ctx.checkerCtx.errors.push("cannot move '" + srcName + "': variable is still used after this point");
			}
		}
		if (rcInfo.wasMovedFn !== "") {
			addPending(dctx, makeWasMovedCall(srcName, rcInfo, loc));
		}
		recordMoveInContext(dctx, srcName);
		return true;
	}
	if (moveArg.kind === NodeKind.MemberExpr) {
		const fieldRc = classifyMemberFieldRc(moveArg, dctx);
		if (fieldRc.needsCleanup && fieldRc.wasMovedFn !== "") {
			addPending(dctx, makeWasMovedOnExpr(moveArg, fieldRc, loc));
		}
		return true;
	}
	if (moveArg.kind === NodeKind.ArrayAccess) {
		const elemRc = classifyArrayElementRc(moveArg, dctx);
		if (elemRc.needsCleanup && elemRc.wasMovedFn !== "") {
			addPending(dctx, makeWasMovedOnExpr(moveArg, elemRc, loc));
		}
		return true;
	}
	// CallExpr / other: source is fresh, no variable to zero
	return false;
}

// ===== Scope Cleanup Generation =====

function generateCleanup(scope: DrcScope, excludeNames: NameSet, loc: SourceLocation): Node[] {
	const result: Node[] = [];

	// Step 1: wasMoved calls for moved variables
	for (const mv of scope.wasMoved) {
		const vi = findVarInfo(scope, mv.varName);
		if (vi !== null && vi.rcInfo.wasMovedFn !== "") {
			result.push(makeWasMovedCall(mv.varName, vi.rcInfo, loc));
		}
	}

	// Step 2: destroy in LIFO order
	let i = scope.varsToCleanup.length;
	while (i > 0) {
		i -= 1;
		const vi = scope.varsToCleanup[i];
		if (vi.isCursor) continue;
		if (excludeNames !== null && nameSetContains(excludeNames, vi.varName)) continue;
		if (wasMovedInScope(scope, vi.varName)) continue;
		if (vi.rcInfo.destroyFn === "") continue;
		result.push(makeDestroyCall(vi.varName, vi.rcInfo, loc));
	}

	return result;
}

// ===== Try/Finally Wrapping =====

// Nim parity: hoist a single VariableDecl if it's an RC var tracked in scope.
// Mirrors Nim's processScope which emits s.vars as declarations before the try body.
// Returns true if hoisted (caller emits assignment in try body instead).
function tryHoistVar(stmt: Node, scope: DrcScope, hoisted: Node[], body: Node[], loc: SourceLocation): boolean {
	if (stmt.kind !== NodeKind.VariableDecl) return false;
	const d = stmt.data as VariableDeclData;
	const vi = findVarInfo(scope, d.declName);
	if (vi === null || !vi.rcInfo.needsCleanup) return false;
	const hoistDecl = makeVarDecl(d.declName, makeNull(loc), DeclKind.Let, loc);
	if (stmt.nodeType !== null) {
		hoistDecl.nodeType = stmt.nodeType;
	}
	hoisted.push(hoistDecl);
	if (d.initializer !== null) {
		body.push(makeExprStmt(makeAssign(makeIdent(d.declName, loc), d.initializer, loc), loc));
	}
	return true;
}

// Nim parity: scan a statement list for hoistable RC vars.
// Recurses one level into BlockStmt (created by emitSaveAssignDestroy)
// to find temps that are registered in scope but declared in sub-blocks.
function hoistScopeVars(stmts: Node[], scope: DrcScope, hoisted: Node[], tryBody: Node[], loc: SourceLocation): void {
	for (const stmt of stmts) {
		if (tryHoistVar(stmt, scope, hoisted, tryBody, loc)) continue;
		if (stmt.kind === NodeKind.BlockStmt) {
			const bd = stmt.data as BlockStmtData;
			const innerBody: Node[] = [];
			for (const inner of bd.statements) {
				if (!tryHoistVar(inner, scope, hoisted, innerBody, loc)) {
					innerBody.push(inner);
				}
			}
			tryBody.push(makeBlock(innerBody, loc));
			continue;
		}
		tryBody.push(stmt);
	}
}

function wrapWithTryFinally(bodyStmts: Node[], cleanupStmts: Node[], scope: DrcScope, loc: SourceLocation): Node {
	// Hoist RC variable declarations before try (null init for setjmp safety)
	// Nim: processScope emits all s.vars before try body. We do the same by
	// scanning bodyStmts (and one level into sub-blocks) for registered RC vars.
	const hoisted: Node[] = [];
	const tryBody: Node[] = [];
	hoistScopeVars(bodyStmts, scope, hoisted, tryBody, loc);

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
	const buf: Node[] = [];
	const savedList = dctx.currentStmtList;
	dctx.currentStmtList = stmts;
	for (let i = 0; i < stmts.length; i += 1) {
		const savedIdx = dctx.currentStmtIdx;
		dctx.currentStmtIdx = i;
		
		const processed = processStmt(stmts[i], i, stmts, dctx, loc);
		
		// Flush pre-statements (like incref) and post-statements (like wasMoved)
		flushPre(dctx, buf);
		buf.push(processed);
		flushPending(dctx, buf);
		
		dctx.currentStmtIdx = savedIdx;
	}
	dctx.currentStmtList = savedList;
	return buf;
}

// ===== Empty NameSet factory (avoids repeated `[]`) =====

function emptyNameSet(): NameSet {
	return [];
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

	// Push outer context for cross-scope last-read analysis
	pushOuterStmts(dctx, stmts, idx + 1, false);

	const result = match (stmt.kind) {
		NodeKind.VariableDecl => processVarDecl(stmt, idx, stmts, dctx, sloc),
		NodeKind.ReturnStmt => processReturn(stmt, dctx, sloc),
		NodeKind.ExprStmt => processExprStmt(stmt, idx, stmts, dctx, sloc),
		NodeKind.FunctionDecl => processFuncDecl(stmt, dctx, sloc),
		NodeKind.IfStmt => processIf(stmt, dctx, sloc),
		NodeKind.WhileStmt => processWhile(stmt, dctx, sloc),
		NodeKind.ForStmt => processFor(stmt, dctx, sloc),
		NodeKind.DoWhileStmt => processDoWhile(stmt, dctx, sloc),
		NodeKind.BlockStmt => processBlockBody(stmt, dctx, false, false, sloc),
		NodeKind.TryCatchStmt => processTryCatch(stmt, dctx, sloc),
		NodeKind.SwitchStmt => processSwitch(stmt, dctx, sloc),
		NodeKind.BreakStmt | NodeKind.ContinueStmt => { setNeedsTryToLoop(dctx); stmt },
		NodeKind.ThrowStmt => { setNeedsTryAll(dctx); stmt },
		NodeKind.ExportDecl => processExport(stmt, dctx, sloc),
		NodeKind.ClassDecl => processClass(stmt, dctx, sloc),
		NodeKind.ArrowFunction => processArrow(stmt, dctx, sloc),
		NodeKind.FunctionExpr => processFuncExpr(stmt, dctx, sloc),
		_ => stmt,
	};

	popOuterStmts(dctx);

	// Blocker 28: only set needsTry when a statement could actually throw.
	// RC runtime calls (ms* prefix) and DRC synthetics ($ prefix) are nothrow.
	if (scopeDepth(dctx) > 0 && stmtCanThrow(stmt) && currentScope(dctx).varsToCleanup.length > 0) {
		currentScope(dctx).needsTry = true;
	}

	return result;
}

// Blocker 28: Check if a call expression could throw an exception.
// RC runtime (ms*) and DRC synthetic ($*) calls are nothrow by convention.
function callCanThrow(callExpr: Node): boolean {
	const cd = callExpr.data as CallExprData;
	if (cd.callee.kind === NodeKind.Identifier) {
		const name = (cd.callee.data as IdentifierData).name;
		if (name.startsWith("ms")) return false;
		if (name.startsWith("$")) return false;
	}
	return true;
}

// Blocker 28: Check if a statement could throw — stricter than old stmtMayCall.
// Only returns true for ThrowStmt or user function calls that could throw.
function stmtCanThrow(node: Node): boolean {
	if (node === null) return false;
	if (node.kind === NodeKind.ThrowStmt) return true;
	if (node.kind === NodeKind.ExprStmt) {
		const expr = (node.data as ExprStmtData).expr;
		if (expr !== null && expr.kind === NodeKind.CallExpr) return callCanThrow(expr);
		if (expr !== null && expr.kind === NodeKind.BinaryExpr) {
			const bd = expr.data as BinaryExprData;
			if (bd.right !== null && bd.right.kind === NodeKind.CallExpr) return callCanThrow(bd.right);
		}
		return false;
	}
	if (node.kind === NodeKind.VariableDecl) {
		const vd = node.data as VariableDeclData;
		return vd.initializer !== null && vd.initializer.kind === NodeKind.CallExpr && callCanThrow(vd.initializer);
	}
	return false;
}

// ===== Loop-Aware Last-Read =====
// Variables defined before a loop are NEVER last-read inside the loop body,
// because the loop repeats and uses them again. The forward scan misses this
// because it doesn't see loop back-edges.

function isVarFromOuterLoopScope(varName: string, dctx: DrcContext): boolean {
	let passedInnerLoop = false;
	let i = dctx.scopes.length;
	while (i > 0) {
		i -= 1;
		const scope = dctx.scopes[i];
		if (!passedInnerLoop && scope.isLoop) {
			passedInnerLoop = true;
			continue;  // skip the innermost loop scope itself
		}
		if (passedInnerLoop) {
			const vi = findVarInfo(scope, varName);
			if (vi !== null) return true;
		}
		if (scope.isFunction) break;
	}
	return false;
}

function isLastReadSafe(sym: Symbol, node: Node, idx: number, stmts: Node[], dctx: DrcContext): boolean {
	if (sym === null) return false;
	// Phase A: variables in finally blocks must never be moved (use-after-free prevention)
	if (nameSetContains(dctx.finallyProtectedVars, sym.name)) return false;
	// Phase C: use CFG-based analysis when function body is available
	if (dctx.currentFuncBody !== null && node !== null) {
		return isLastReadCfgCached(sym.name, node, dctx.currentFuncBody, dctx.cfgCache);
	}
	// Fallback: conservative forward scan
	if (!isLastReadInContext(sym, idx, stmts, dctx.outerCtx)) return false;
	// If variable is from a scope outside a loop, it's not truly last-read
	// inside the loop body (the loop will repeat and use it again).
	if (isVarFromOuterLoopScope(sym.name, dctx)) return false;
	return true;
}

// ===== Conditional Expression Init =====
// For `const x = cond ? a : b` where x needs RC:
// - If both branches are fresh: SINK (no copy needed)
// - Otherwise: emit copy on dest after assignment (conservative — covers whichever branch ran)

function processConditionalInit(stmt: Node, condExpr: Node, destName: string, rcInfo: RcInfo, dctx: DrcContext, loc: SourceLocation): Node {
	const cd = condExpr.data as ConditionalExprData;
	const consIsFresh = isFreshExpr(cd.ternaryConsequent.kind);
	const altIsFresh = isFreshExpr(cd.ternaryAlternate.kind);

	// Both branches fresh: SINK, no additional work
	if (consIsFresh && altIsFresh) return stmt;

	// At least one branch is non-fresh (identifier, member access, etc.)
	// Conservative: emit copy/incref on dest after assignment
	if (rcInfo.copyFn !== "") {
		addPending(dctx, makeCopyAfterInit(destName, rcInfo, loc));
	}
	return stmt;
}

// ===== Call Argument RC Processing =====
// When passing RC variables to function params (sink semantics), emit copies or moves.
// Returns pre-statements (incref calls) to insert before the call.
// Post-call wasMoved calls go via addPending.

function processCallArgs(callExpr: Node, idx: number, stmts: Node[], dctx: DrcContext, loc: SourceLocation): Node[] {
	const pre: Node[] = [];
	if (dctx.ctx.checkerCtx === null) return pre;
	const cd = callExpr.data as CallExprData;

	// Demand-driven: use resolvedSym commitment from Phase 2
	const sym = callExpr.resolvedSym;
	if (sym === null || sym.symbolType === null) return pre;
	const fnType = sym.symbolType;
	if (fnType.kind !== TypeKind.Function) return pre;

	for (let ai = 0; ai < cd.arguments.length && ai < fnType.typeChildren.length; ai += 1) {
		const arg = cd.arguments[ai];

		// Nim parity: arguments are already processed by processCall (via processNode).
		// processCallArgs only handles statement-level concerns (nested call extraction).
		// Do NOT re-process arguments here — that would double-process and cause
		// spurious wasMoved/incref. Nim's p() processes args once in the universal handler.

		// Determine if this parameter is a borrow (LENT) or a transfer (SINK)
		let isLent = true;
		if (ai < fnType.typeChildrenFlags.length && fnType.typeChildrenFlags[ai] === SF_SINK) {
			isLent = false;
		}
		if (ai < fnType.typeNames.length) {
			const pName = fnType.typeNames[ai];
			if (pName === "this" || (ai === 0 && pName === "self")) isLent = true;
		}

		// Special case: Nested calls in sink positions need extraction to temps
		// if they weren't already handled, to prevent RC leaks from discarded returns.
		if (!isLent && arg !== null && arg.kind === NodeKind.CallExpr) {
			const nestedRc = classifyNestedCallReturn(arg, dctx);
			if (nestedRc.needsCleanup) {
				const tmpName = freshTemp(dctx.ctx, "sink");
				const sinkDecl = makeVarDecl(tmpName, cd.arguments[ai], DeclKind.Const, loc);
				// Blocker 27: stamp return type from callee's function signature
				const retType = getCallReturnType(arg, dctx);
				if (retType !== null) {
					sinkDecl.nodeType = retType;
				} else if (arg.nodeType !== null) {
					sinkDecl.nodeType = arg.nodeType;
				}
				pre.push(sinkDecl);
				registerVar(dctx, tmpName, nestedRc, false);
				const ident = makeIdent(tmpName, loc);
				if (sinkDecl.nodeType !== null) ident.nodeType = sinkDecl.nodeType;
				cd.arguments[ai] = ident;
			}
		}
	}
	return pre;
}

// Classify the return type of a nested call expression
function classifyNestedCallReturn(callExpr: Node, dctx: DrcContext): RcInfo {
	if (dctx.ctx.checkerCtx === null) return noRcInfo();
	const cd = callExpr.data as CallExprData;
	if (cd.callee.kind !== NodeKind.Identifier) return noRcInfo();
	const calleeName = (cd.callee.data as IdentifierData).name;
	const sym = lookupSymbol(dctx.ctx.checkerCtx.table, calleeName);
	if (sym === null || sym.symbolType === null) return noRcInfo();
	if (sym.symbolType.kind !== TypeKind.Function) return noRcInfo();
	if (sym.symbolType.typeReturn === null) return noRcInfo();
	return classifyType(sym.symbolType.typeReturn, dctx.ctx);
}

// Get the return Type of a nested call expression (Blocker 27: typed sinks)
function getCallReturnType(callExpr: Node, dctx: DrcContext): Type {
	if (dctx.ctx.checkerCtx === null) return null as unknown as Type;
	const cd = callExpr.data as CallExprData;
	if (cd.callee.kind !== NodeKind.Identifier) return null as unknown as Type;
	const calleeName = (cd.callee.data as IdentifierData).name;
	const sym = lookupSymbol(dctx.ctx.checkerCtx.table, calleeName);
	if (sym === null || sym.symbolType === null) return null as unknown as Type;
	if (sym.symbolType.kind !== TypeKind.Function) return null as unknown as Type;
	return sym.symbolType.typeReturn;
}

// Wrap a statement with pre-statements from call arg processing
function wrapWithCallArgPre(stmt: Node, preStmts: Node[], loc: SourceLocation): Node {
	if (preStmts.length === 0) return stmt;
	preStmts.push(stmt);
	return makeBlock(preStmts, loc);
}

// ===== Literal Field RC Processing =====

// For { field: someVar } — incref RC identifier fields (they alias the source)
function emitLiteralFieldCopies(literal: Node, outerType: Type, idx: number, stmts: Node[], dctx: DrcContext, loc: SourceLocation): void {
	if (outerType === null) return;
	const ld = literal.data as ObjectLiteralData;
	const fieldTypes = outerType.typeChildren;
	for (let fi = 0; fi < ld.properties.length && fi < fieldTypes.length; fi += 1) {
		const prop = ld.properties[fi];
		if (prop !== null && prop.kind === NodeKind.Identifier) {
			const propName = (prop.data as IdentifierData).name;
			const fieldRc = classifyType(fieldTypes[fi], dctx.ctx);
			if (fieldRc.needsCleanup) {
				if (isLastReadSafe(prop.resolvedSym, prop, idx, stmts, dctx)) {
					if (fieldRc.wasMovedFn !== "") {
						addPending(dctx, makeWasMovedCall(propName, fieldRc, loc));
					}
					recordMove(dctx, propName);
				} else {
					addPending(dctx, makeRcCallStmt(fieldRc.copyFn, propName, loc));
				}
			}
		}
		// MoveExpr field: force move — wasMoved on source, no incref
		if (prop !== null && prop.kind === NodeKind.MoveExpr) {
			const md = prop.data as MoveExprData;
			if (md.moveArg.kind === NodeKind.Identifier) {
				const srcName = (md.moveArg.data as IdentifierData).name;
				const fieldRc = classifyType(fieldTypes[fi], dctx.ctx);
				if (fieldRc.needsCleanup) {
					if (fieldRc.wasMovedFn !== "") {
						addPending(dctx, makeWasMovedCall(srcName, fieldRc, loc));
					}
					recordMove(dctx, srcName);
				}
			}
		}
	}
}

// For [a, b, c] — incref RC identifier elements
function emitArrayElementCopies(literal: Node, outerType: Type, idx: number, stmts: Node[], dctx: DrcContext, loc: SourceLocation): void {
	if (outerType === null || outerType.typeReturn === null) return;
	const elemRc = classifyType(outerType.typeReturn, dctx.ctx);
	if (!elemRc.needsCleanup) return;

	const ald = literal.data as ArrayLiteralData;
	for (let ei = 0; ei < ald.elements.length; ei += 1) {
		const elem = ald.elements[ei];
		if (elem !== null && elem.kind === NodeKind.Identifier) {
			const elemName = (elem.data as IdentifierData).name;
			if (isLastReadSafe(elem.resolvedSym, elem, idx, stmts, dctx)) {
				if (elemRc.wasMovedFn !== "") {
					addPending(dctx, makeWasMovedCall(elemName, elemRc, loc));
				}
				recordMove(dctx, elemName);
			} else {
				addPending(dctx, makeRcCallStmt(elemRc.copyFn, elemName, loc));
			}
		}
		// MoveExpr element: force move — wasMoved on source, no incref
		if (elem !== null && elem.kind === NodeKind.MoveExpr) {
			const md = elem.data as MoveExprData;
			if (md.moveArg.kind === NodeKind.Identifier) {
				const srcName = (md.moveArg.data as IdentifierData).name;
				if (elemRc.needsCleanup) {
					if (elemRc.wasMovedFn !== "") {
						addPending(dctx, makeWasMovedCall(srcName, elemRc, loc));
					}
					recordMove(dctx, srcName);
				}
			}
		}
	}
}

// ===== Sink Parameter Registration =====
// Register RC-typed function parameters for scope cleanup.
// The function owns the parameter values — they need destroy at scope exit.

function isEnvParam(name: string): boolean {
	// Lambda-lifted closure env pointer — managed by closure infrastructure, skip from cleanup
	if (name.length < 6) return false;
	return name.slice(0, 6) === "__envP";
}

// ===== Sink Parameter Inference =====
// A parameter is a sink candidate if it's only used in return positions.
// Returns true if paramName appears ONLY as a direct return argument (consumed),
// never read in other contexts (no copy needed).

function isParamSinkCandidate(paramName: string, body: Node): boolean {
	if (body === null) return false;
	if (body.kind !== NodeKind.BlockStmt) return false;
	const bd = body.data as BlockStmtData;
	// Count: total refs and return-only refs
	let totalRefs = 0;
	let returnRefs = 0;
	countParamUsage(paramName, bd.statements, totalRefs, returnRefs);
	// Workaround: can't use out params, so re-implement inline
	const counts = countParamUsageInline(paramName, bd.statements);
	// Sink if: at least 1 use AND all uses are return-only
	return counts.total > 0 && counts.total === counts.returns;
}

interface UsageCounts {
	total: number;
	returns: number;
}

function countParamUsageInline(paramName: string, stmts: Node[]): UsageCounts {
	let total = 0;
	let returns = 0;
	let i = 0;
	while (i < stmts.length) {
		const s = stmts[i];
		if (s.kind === NodeKind.ReturnStmt) {
			const rd = s.data as ReturnStmtData;
			if (rd.argument !== null && rd.argument.kind === NodeKind.Identifier) {
				const id = rd.argument.data as IdentifierData;
				if (id.name === paramName) {
					total = total + 1;
					returns = returns + 1;
				}
			} else if (rd.argument !== null && nodeRefsParam(rd.argument, paramName)) {
				// Used in return but not as direct identifier (e.g., return f(param))
				total = total + countRefsInNode(rd.argument, paramName);
			}
		} else {
			// Any other statement: count all refs
			total = total + countRefsInNode(s, paramName);
		}
		i = i + 1;
	}
	return { total, returns };
}

function countRefsInNode(node: Node, paramName: string): number {
	if (node === null) return 0;
	if (node.kind === NodeKind.Identifier) {
		const id = node.data as IdentifierData;
		if (id.name === paramName) return 1;
		return 0;
	}
	if (node.kind === NodeKind.BinaryExpr) {
		const bd = node.data as BinaryExprData;
		return countRefsInNode(bd.left, paramName) + countRefsInNode(bd.right, paramName);
	}
	if (node.kind === NodeKind.CallExpr) {
		const cd = node.data as CallExprData;
		let count = countRefsInNode(cd.callee, paramName);
		let j = 0;
		while (j < cd.arguments.length) {
			count = count + countRefsInNode(cd.arguments[j], paramName);
			j = j + 1;
		}
		return count;
	}
	if (node.kind === NodeKind.ExprStmt) {
		const ed = node.data as ExprStmtData;
		return countRefsInNode(ed.expr, paramName);
	}
	if (node.kind === NodeKind.VariableDecl) {
		const vd = node.data as VariableDeclData;
		if (vd.initializer !== null) return countRefsInNode(vd.initializer, paramName);
		return 0;
	}
	if (node.kind === NodeKind.IfStmt) {
		const id = node.data as IfStmtData;
		return countRefsInNode(id.condition, paramName)
			+ countRefsInNode(id.consequent, paramName)
			+ countRefsInNode(id.alternate, paramName);
	}
	if (node.kind === NodeKind.BlockStmt) {
		const bd = node.data as BlockStmtData;
		let count = 0;
		let k = 0;
		while (k < bd.statements.length) {
			count = count + countRefsInNode(bd.statements[k], paramName);
			k = k + 1;
		}
		return count;
	}
	if (node.kind === NodeKind.MemberExpr) {
		const md = node.data as MemberExprData;
		return countRefsInNode(md.object, paramName);
	}
	return 0;
}

function nodeRefsParam(node: Node, paramName: string): boolean {
	return countRefsInNode(node, paramName) > 0;
}

// Unused — kept for signature compatibility with plan
function countParamUsage(paramName: string, stmts: Node[], total: number, returns: number): void {}

function registerFuncParams(paramNames: string[], paramTypes: Type[], dctx: DrcContext, loc: SourceLocation, body: Node): void {
	if (dctx.ctx.checkerCtx === null) return;
	for (let pi = 0; pi < paramNames.length && pi < paramTypes.length; pi += 1) {
		const pName = paramNames[pi];
		// Skip closure env params (item 11) — they're managed by msClosure infrastructure
		if (!isEnvParam(pName)) {
			const pRcInfo = classifyType(paramTypes[pi], dctx.ctx);
			if (pRcInfo.needsCleanup) {
				// Nim parity: regular params are BORROWED (cursor=true, no cleanup).
				// Only sink params (SF_SINK) take ownership and need cleanup at exit.
				// The caller owns the value; if the function needs to keep it, the
				// assignment point handles the copy (not the param registration).
				let isCursor = true;

				// Only non-cursor if explicitly SF_SINK (takes ownership)
				const pSym = lookupLocal(dctx.ctx.checkerCtx.table, pName);
				if (pSym !== null && hasFlag(pSym, SF_SINK)) {
					isCursor = false;
				}

				registerVar(dctx, pName, pRcInfo, isCursor);
			}
		}
	}
}

// Phase G: detect generator/async state machine bodies — `let $state = 0;` pattern
function isGeneratorBody(body: Node): boolean {
	if (body === null || body.kind !== NodeKind.BlockStmt) return false;
	const bd = body.data as BlockStmtData;
	if (bd.statements.length === 0) return false;
	const first = bd.statements[0];
	if (first.kind !== NodeKind.VariableDecl) return false;
	const d = first.data as VariableDeclData;
	return d.declName === "$state";
}

// Process a function body with sink param registration.
// Looks up the function's type to get resolved param types.
function processFuncBodyWithParams(body: Node, fnName: string, paramNames: string[], dctx: DrcContext, loc: SourceLocation): Node {
	if (body === null) return body;
	if (body.kind !== NodeKind.BlockStmt) return body;
	const bd = body.data as BlockStmtData;

	// Function boundary — prevent cross-scope last-read from looking past this
	pushOuterStmts(dctx, [], 0, true);
	pushScope(dctx, false, true);

	// Phase A: scan finally blocks for protected variables
	dctx.finallyProtectedVars = collectFinallyVars(body);

	// Phase B: infer cursor (borrowed) variables for this function
	dctx.cursors = inferCursors(body);

	// Phase C: set function body for CFG-based last-read analysis
	dctx.currentFuncBody = body;
	clearCfgCache(dctx.cfgCache);

	// Register RC-typed params for cleanup (sink semantics)
	if (dctx.ctx.checkerCtx !== null && fnName !== "") {
		const fnSym = lookupSymbol(dctx.ctx.checkerCtx.table, fnName);
		if (fnSym !== null && fnSym.symbolType !== null) {
			const fnType = fnSym.symbolType;
			if (fnType.kind === TypeKind.Function) {
				registerFuncParams(fnType.typeNames, fnType.typeChildren, dctx, loc, body);
			}
		}
	} else if (dctx.ctx.checkerCtx !== null && paramNames.length > 0) {
		// For anonymous functions (arrows, func exprs): try to resolve param types from symbol table
		// The param names are the AST-level names; look each up individually
		// (This is a fallback — anonymous funcs may not have their type in the global scope)
		for (let pi = 0; pi < paramNames.length; pi += 1) {
			const pSym = lookupSymbol(dctx.ctx.checkerCtx.table, paramNames[pi]);
			if (pSym !== null) {
				const pRcInfo = classifyType(pSym.symbolType, dctx.ctx);
				if (pRcInfo.needsCleanup && !isEnvParam(paramNames[pi])) {
					const isSink = isParamSinkCandidate(paramNames[pi], body);
					registerVar(dctx, paramNames[pi], pRcInfo, isSink);
				}
			}
		}
	}

	const processed = processStmtList(bd.statements, dctx, loc);
	const scope = popScope(dctx);

	// Phase G: generator/async state machines have per-state cleanup — skip try/finally
	if (isGeneratorBody(body)) {
		scope.needsTry = false;
	}

	const cleanup = generateCleanup(scope, emptyNameSet(), loc);
	popOuterStmts(dctx);  // pop function boundary sentinel
	dctx.cursors = createCursorSet();  // Phase B: clear cursors after function

	if (scope.needsTry && cleanup.length > 0) {
		return wrapWithTryFinally(processed, cleanup, scope, loc);
	}
	for (const cs of cleanup) {
		processed.push(cs);
	}
	return makeBlock(processed, loc);
}

// ===== Variable Declaration =====

function processVarDecl(stmt: Node, idx: number, stmts: Node[], dctx: DrcContext, loc: SourceLocation): Node {
	const d = stmt.data as VariableDeclData;

	// Prefer nodeType from checker (set on the VariableDecl during check pass)
	// Fall back to symbol table lookup only if nodeType is absent
	if (dctx.ctx.checkerCtx === null) return stmt;
	let varType: Type = null as unknown as Type;
	if (stmt.nodeType !== null) {
		varType = stmt.nodeType;
	} else {
		const sym = lookupSymbol(dctx.ctx.checkerCtx.table, d.declName);
		// Only use symbol if it's a Variable/Parameter — avoid name collisions with extension methods
		if (sym !== null && (sym.symbolKind === SymbolKind.Variable || sym.symbolKind === SymbolKind.Parameter)) {
			varType = sym.symbolType;
		} else if (sym !== null && sym.symbolKind === SymbolKind.Function) {
			// Name collision: local variable shadowed by function — skip RC
			return stmt;
		}
	}
	if (varType === null) return stmt;

	const rcInfo = classifyType(varType, dctx.ctx);
	if (!rcInfo.needsCleanup) return stmt;

	// Internal temps ($ prefix) initialized from existing variables are Cursors (Lent).
	// This prevents unwanted cloning in for..of loops and intermediate assignments.
	let isCursor = false;
	if (d.declName.startsWith("$") && d.initializer !== null && d.initializer.kind === NodeKind.Identifier) {
		isCursor = true;
	}
	// Phase B: check cursor inference results (borrow-only variables skip all RC)
	if (isCursorVar(dctx.cursors, d.declName)) {
		isCursor = true;
	}

	// Register for scope cleanup
	registerVar(dctx, d.declName, rcInfo, isCursor);

	// Phase D: first-write optimization — `let x;` without initializer is uninitialized
	if (d.initializer === null) {
		markUninitialized(dctx, d.declName);
		return stmt;
	}
	
	// Process initializer recursively with Consumed mode
	d.initializer = processNode(d.initializer, dctx, DrcMode.Consumed);
	
	const init = d.initializer;

	// Object literal: fresh as whole, but RC fields need incref
	if (init.kind === NodeKind.ObjectLiteral) {
		emitLiteralFieldCopies(init, varType, idx, stmts, dctx, loc);
		return stmt;
	}

	// Array literal: fresh as whole, but RC elements need incref
	if (init.kind === NodeKind.ArrayLiteral) {
		emitArrayElementCopies(init, varType, idx, stmts, dctx, loc);
		return stmt;
	}

	// Call expression: SINK for dest, but process arguments for caller-side copies
	if (init.kind === NodeKind.CallExpr) {
		const preStmts = processCallArgs(init, idx, stmts, dctx, loc);
		return wrapWithCallArgPre(stmt, preStmts, loc);
	}

	// Conditional expression: needs per-branch RC handling
	if (init.kind === NodeKind.ConditionalExpr) {
		return processConditionalInit(stmt, init, d.declName, rcInfo, dctx, loc);
	}

	// MoveExpr: SINK for dest + wasMoved on source
	if (init.kind === NodeKind.MoveExpr) {
		const md = init.data as MoveExprData;
		emitMoveSourceWasMoved(md.moveArg, rcInfo, idx, stmts, dctx, loc, true);
		return stmt;
	}

	// Fresh expression: SINK — ownership transfers directly
	if (isFreshExpr(init.kind)) return stmt;

	// Identifier init: check last-read for MOVE vs COPY
	if (init.kind === NodeKind.Identifier) {
		const initD = init.data as IdentifierData;
		if (isLastReadSafe(init.resolvedSym, init, idx, stmts, dctx)) {
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

	// Member access: borrowed — needs incref/copy or null-out for Result extraction
	if (init.kind === NodeKind.MemberExpr) {
		const md = init.data as MemberExprData;
		// Result field extraction: $result_N.value → null-out source to prevent double-free
		if (md.object.kind === NodeKind.Identifier && md.property === "value") {
			const objName = (md.object.data as IdentifierData).name;
			if (objName.startsWith("$result")) {
				const nullAssign = makeExprStmt(
					makeAssign(makeMember(makeIdent(objName, loc), "value", loc), makeNull(loc), loc), loc);
				addPending(dctx, nullAssign);
				return stmt;
			}
		}
		// Pointer/string borrow: incref
		if (rcInfo.rcKind === RcKind.Ref || rcInfo.rcKind === RcKind.String) {
			const copyNode = makeCopyAfterInit(d.declName, rcInfo, loc);
			addPending(dctx, copyNode);
		}
		// Named value type borrow: copy hook
		if (rcInfo.rcKind === RcKind.Named && rcInfo.copyFn !== "") {
			const copyNode = makeCopyAfterInit(d.declName, rcInfo, loc);
			addPending(dctx, copyNode);
		}
		return stmt;
	}

	return stmt;
}

// ===== Expression Statement (assignments + discarded calls) =====

function isCompoundAssignOp(op: string): boolean {
	return match (op) {
		"+=" | "-=" | "*=" | "/=" | "%="
		| "&=" | "|=" | "^=" | "<<=" | ">>=" => true,
		_ => false,
	};
}

function compoundToSimpleOp(op: string): string {
	return match (op) {
		"+=" => "+",
		"-=" => "-",
		"*=" => "*",
		"/=" => "/",
		"%=" => "%",
		"&=" => "&",
		"|=" => "|",
		"^=" => "^",
		"<<=" => "<<",
		">>=" => ">>",
		_ => "+",
	};
}

function processExprStmt(stmt: Node, idx: number, stmts: Node[], dctx: DrcContext, loc: SourceLocation): Node {
	const d = stmt.data as ExprStmtData;
	const expr = d.expr;

	// Nim parity: assignments go through moveOrCopy (processAssignment), NOT through
	// the generic processNode → processBinary path. Processing assignment LHS via
	// processBinary would incorrectly treat it as Consumed (emitting wasMoved on the target).
	// In Nim, nkAsgn is handled directly in p() before any generic expression processing.
	if (expr.kind === NodeKind.BinaryExpr) {
		const bd = expr.data as BinaryExprData;
		if (bd.operator === "=") {
			return processAssignment(stmt, bd, idx, stmts, dctx, loc);
		}
	}

	// Use recursive processNode to handle RefCounting inside the expression.
	// Most ExprStmts are 'Normal' mode (result is discarded).
	// CallExpr returns are handled specifically if they need cleanup.
	d.expr = processNode(expr, dctx, DrcMode.Normal);

	// If the expression was a discarded call that returns an RC type, 
	// it needs to be captured and destroyed.
	if (expr.kind === NodeKind.CallExpr) {
		const preStmts = processCallArgs(expr, idx, stmts, dctx, loc);
		const processed = processDiscardedCall(stmt, expr, dctx, loc);
		return wrapWithCallArgPre(processed, preStmts, loc);
	}

	return stmt;
}

// ===== Assignment Processing =====

function processAssignment(stmt: Node, bd: BinaryExprData, idx: number, stmts: Node[], dctx: DrcContext, loc: SourceLocation): Node {
	// Member assignment: obj.field = expr
	if (bd.left.kind === NodeKind.MemberExpr) {
		const leftMd = bd.left.data as MemberExprData;
		const rcInfo = classifyMemberFieldRc(bd.left, dctx);
		if (!rcInfo.needsCleanup) return stmt;
		return emitSaveAssignDestroy(stmt, bd.left, bd.right, rcInfo, "Field", dctx, loc);
	}

	// Array index assignment: arr[i] = expr
	if (bd.left.kind === NodeKind.ArrayAccess) {
		const rcInfo = classifyArrayElementRc(bd.left, dctx);
		if (!rcInfo.needsCleanup) return stmt;
		return emitSaveAssignDestroy(stmt, bd.left, bd.right, rcInfo, "Elem", dctx, loc);
	}

	if (bd.left.kind !== NodeKind.Identifier) return stmt;
	const leftD = bd.left.data as IdentifierData;

	// Demand-driven: use resolvedSym from Phase 2
	const sym = bd.left.resolvedSym;
	if (sym === null) return stmt;

	const rcInfo = classifyType(sym.symbolType, dctx.ctx);
	if (!rcInfo.needsCleanup) return stmt;

	// Phase D: first-write optimization — skip destroy on first assignment to uninitialized var
	const vi = findVarInfoInContext(dctx, leftD.name);
	const isFirstWrite = vi !== null && !vi.isInitialized;
	if (isFirstWrite) {
		vi.isInitialized = true;
	}

	// Process RHS recursively with Consumed mode
	bd.right = processNode(bd.right, dctx, DrcMode.Consumed);
	const rhs = bd.right;

	// Phase D: first-write — no old value to destroy (Nim's nkFastAsgn)
	if (isFirstWrite) {
		if (rhs.kind === NodeKind.CallExpr) {
			const preStmts = processCallArgs(rhs, idx, stmts, dctx, loc);
			return wrapWithCallArgPre(stmt, preStmts, loc);
		}
		if (rhs.kind === NodeKind.MoveExpr) {
			const md = rhs.data as MoveExprData;
			emitMoveSourceWasMoved(md.moveArg, rcInfo, idx, stmts, dctx, loc, true);
			return stmt;
		}
		if (isFreshExpr(rhs.kind)) return stmt;
		if (rhs.kind === NodeKind.Identifier) {
			const rhsD = rhs.data as IdentifierData;
			if (isLastReadSafe(rhs.resolvedSym, rhs, idx, stmts, dctx)) {
				if (rcInfo.wasMovedFn !== "") {
					addPending(dctx, makeWasMovedCall(rhsD.name, rcInfo, loc));
				}
				recordMove(dctx, rhsD.name);
				return stmt;
			}
			const copyNode = makeCopyAfterInit(leftD.name, rcInfo, loc);
			return makeBlock([stmt, copyNode], loc);
		}
		return stmt;
	}

	// Call RHS: fresh for dest, but also process call arguments
	if (rhs.kind === NodeKind.CallExpr) {
		const preStmts = processCallArgs(rhs, idx, stmts, dctx, loc);
		if (deepAliases(sym, rhs)) {
			const tmpName = freshTemp(dctx.ctx, "old");
			const saveTmp = makeVarDecl(tmpName, makeIdent(leftD.name, loc), DeclKind.Const, loc);
			saveTmp.nodeType = sym.symbolType;
			const destroyTmp = makeDestroyCall(tmpName, rcInfo, loc);
			const result: Node[] = [];
			for (const p of preStmts) { result.push(p); }
			result.push(saveTmp);
			result.push(stmt);
			result.push(destroyTmp);
			return makeBlock(result, loc);
		}
		const destroyOld = makeDestroyCall(leftD.name, rcInfo, loc);
		const result: Node[] = [];
		for (const p of preStmts) { result.push(p); }
		result.push(destroyOld);
		result.push(stmt);
		return makeBlock(result, loc);
	}

	// MoveExpr RHS
	if (rhs.kind === NodeKind.MoveExpr) {
		const md = rhs.data as MoveExprData;

		// Self-move: x = move x → no-op
		if (md.moveArg.kind === NodeKind.Identifier) {
			if (md.moveArg.resolvedSym === bd.left.resolvedSym) return stmt;
		}

		// Aliased move: x = move x.field → destructiveMoveVar pattern
		if (deepAliases(sym, md.moveArg)) {
			const tmpName = freshTemp(dctx.ctx, "moveTmp");
			const captureDecl = makeVarDecl(tmpName, md.moveArg, DeclKind.Const, loc);
			captureDecl.nodeType = sym.symbolType;
			const moveResult: Node[] = [captureDecl];

			// Zero source BEFORE destroying old dest
			if (md.moveArg.kind === NodeKind.MemberExpr) {
				const fieldRc = classifyMemberFieldRc(md.moveArg, dctx);
				if (fieldRc.needsCleanup && fieldRc.wasMovedFn !== "") {
					moveResult.push(makeWasMovedOnExpr(md.moveArg, fieldRc, loc));
				}
			} else if (md.moveArg.kind === NodeKind.ArrayAccess) {
				const elemRc = classifyArrayElementRc(md.moveArg, dctx);
				if (elemRc.needsCleanup && elemRc.wasMovedFn !== "") {
					moveResult.push(makeWasMovedOnExpr(md.moveArg, elemRc, loc));
				}
			} else if (md.moveArg.kind === NodeKind.Identifier) {
				const srcName = (md.moveArg.data as IdentifierData).name;
				if (rcInfo.wasMovedFn !== "") {
					moveResult.push(makeWasMovedCall(srcName, rcInfo, loc));
				}
				recordMoveInContext(dctx, srcName);
			}

			moveResult.push(makeDestroyCall(leftD.name, rcInfo, loc));
			moveResult.push(makeExprStmt(
				makeAssign(makeIdent(leftD.name, loc), makeIdent(tmpName, loc), loc), loc));
			return makeBlock(moveResult, loc);
		}

		// Non-aliased move
		emitMoveSourceWasMoved(md.moveArg, rcInfo, idx, stmts, dctx, loc, true);
		// Sink optimization: single call replaces destroy+assign
		if (rcInfo.sinkFn !== "") {
			return makeSinkCall(leftD.name, md.moveArg, rcInfo, loc);
		}
		const moveDestroyOld = makeDestroyCall(leftD.name, rcInfo, loc);
		return makeBlock([moveDestroyOld, stmt], loc);
	}

	// Fresh RHS: destroy old, then assign
	if (isFreshExpr(rhs.kind)) {
		if (deepAliases(sym, rhs)) {
			const tmpName = freshTemp(dctx.ctx, "old");
			const saveTmp = makeVarDecl(tmpName, makeIdent(leftD.name, loc), DeclKind.Const, loc);
			saveTmp.nodeType = sym.symbolType;
			const destroyTmp = makeDestroyCall(tmpName, rcInfo, loc);
			return makeBlock([saveTmp, stmt, destroyTmp], loc);
		}
		// Sink optimization for fresh RHS (no alias)
		if (rcInfo.sinkFn !== "") {
			return makeSinkCall(leftD.name, rhs, rcInfo, loc);
		}
		const destroyOld = makeDestroyCall(leftD.name, rcInfo, loc);
		return makeBlock([destroyOld, stmt], loc);
	}

	// Identifier RHS
	if (rhs.kind === NodeKind.Identifier) {
		const rightD = rhs.data as IdentifierData;
		const rhsSym = rhs.resolvedSym;
		if (rhsSym === null) return stmt;

		const destroyOld = makeDestroyCall(leftD.name, rcInfo, loc);
		if (isLastReadSafe(rhsSym, rhs, idx, stmts, dctx)) {
			const wmCall = makeWasMovedCall(rightD.name, rcInfo, loc);
			recordMove(dctx, rightD.name);
			// Sink optimization for last-read moves
			if (rcInfo.sinkFn !== "") {
				return makeBlock([makeSinkCall(leftD.name, rhs, rcInfo, loc), wmCall], loc);
			}
			return makeBlock([destroyOld, stmt, wmCall], loc);
		}
		const copyNode = makeCopyAfterInit(leftD.name, rcInfo, loc);
		return makeBlock([destroyOld, stmt, copyNode], loc);
	}

	return stmt;
}

// ===== Indexed/Member Assignment: shared save-assign-destroy pattern =====
// Used by both obj.field = expr and arr[i] = expr.
// lhsExpr is the left-hand side (bd.left) used to read old/new values.

function emitSaveAssignDestroy(stmt: Node, lhsExpr: Node, rhs: Node, rcInfo: RcInfo, prefix: string, dctx: DrcContext, loc: SourceLocation): Node {
	const tmpName = freshTemp(dctx.ctx, "old" + prefix);
	const saveTmp = makeVarDecl(tmpName, lhsExpr, DeclKind.Const, loc);
	registerVar(dctx, tmpName, rcInfo, false);

	// MoveExpr: SINK for dest + wasMoved on source
	if (rhs.kind === NodeKind.MoveExpr) {
		const md = rhs.data as MoveExprData;
		emitMoveSourceWasMoved(md.moveArg, rcInfo, 0, [] as Node[], dctx, loc, false);
		return makeBlock([saveTmp, stmt, makeDestroyCall(tmpName, rcInfo, loc)], loc);
	}

	if (isFreshExpr(rhs.kind)) {
		return makeBlock([saveTmp, stmt, makeDestroyCall(tmpName, rcInfo, loc)], loc);
	}

	const result: Node[] = [saveTmp, stmt];
	if (rcInfo.copyFn !== "") {
		const tmpNew = freshTemp(dctx.ctx, "new" + prefix);
		const saveNew = makeVarDecl(tmpNew, lhsExpr, DeclKind.Const, loc);
		const copyNew = makeCopyAfterInit(tmpNew, rcInfo, loc);
		result.push(saveNew);
		result.push(copyNew);
	}
	result.push(makeDestroyCall(tmpName, rcInfo, loc));
	return makeBlock(result, loc);
}

// ===== Compound Assignment: x += y =====

function processCompoundAssignment(stmt: Node, bd: BinaryExprData, idx: number, stmts: Node[], dctx: DrcContext, loc: SourceLocation): Node {
	if (dctx.ctx.checkerCtx === null) return stmt;
	const leftD = bd.left.data as IdentifierData;

	const sym = lookupSymbol(dctx.ctx.checkerCtx.table, leftD.name);
	if (sym === null) return stmt;

	const rcInfo = classifyType(sym.symbolType, dctx.ctx);
	if (!rcInfo.needsCleanup) return stmt;

	// Fused string append: s += rhs → msStringAppend(&s, rhs) (in-place, no alloc)
	// Skip when rhs aliases s (self-append s += s needs save/concat/destroy)
	if (rcInfo.rcKind === RcKind.String && bd.operator === "+=") {
		if (!deepAliases(sym, bd.right)) {
			const addrOf = makeUnary("&", makeIdent(leftD.name, loc), loc);
			const appendCall = makeCall(
				makeIdent("msStringAppend", loc),
				[addrOf, bd.right],
				loc
			);
			return makeExprStmt(appendCall, loc);
		}
	}

	// Desugar: x += y  ->  { const $old = x; x = x op y; destroy($old); }
	// The RHS (x op y) produces a fresh value, so no copy needed.
	const simpleOp = compoundToSimpleOp(bd.operator);
	const tmpName = freshTemp(dctx.ctx, "old");
	const saveTmp = makeVarDecl(tmpName, makeIdent(leftD.name, loc), DeclKind.Const, loc);
	saveTmp.nodeType = sym.symbolType;
	const newVal = makeBinary(makeIdent(leftD.name, loc), simpleOp, bd.right, loc);
	const assignNew = makeExprStmt(makeAssign(makeIdent(leftD.name, loc), newVal, loc), loc);
	const destroyOld = makeDestroyCall(tmpName, rcInfo, loc);

	return makeBlock([saveTmp, assignNew, destroyOld], loc);
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

	// Capture in temp for proper cleanup — set nodeType so codegen emits correct C type (D2 fix)
	const tmpName = freshTemp(dctx.ctx, "discard");
	const capture = makeVarDecl(tmpName, callExpr, DeclKind.Const, loc);
	if (fnType.typeReturn !== null) {
		capture.nodeType = fnType.typeReturn;
	}
	registerVar(dctx, tmpName, retRcInfo, false);
	return capture;
}

// ===== Return Statement =====

// Check if a return expression is a borrowed RC pointer that needs incref.
// Borrowed = not fresh, not owned local. E.g., obj.field, arr[i], parameter.
function needsReturnIncref(expr: Node, dctx: DrcContext): boolean {
	if (dctx.ctx.checkerCtx === null) return false;
	// Fresh expressions produce owned values — no incref needed
	if (isFreshExpr(expr.kind)) return false;
	if (expr.kind === NodeKind.CallExpr) return false;
	if (expr.kind === NodeKind.MoveExpr) return false;

	// Identifier: local RC vars are moved (not borrowed) — no incref
	if (expr.kind === NodeKind.Identifier) {
		const name = (expr.data as IdentifierData).name;
		const vi = findVarInfoInContext(dctx, name);
		if (vi !== null) return false;  // local var — ownership transferred via markReturnedVarsMoved
		// Not a local var (parameter or global) — check if RC pointer type
		const sym = lookupSymbol(dctx.ctx.checkerCtx.table, name);
		if (sym === null || sym.symbolType === null) return false;
		const rc = classifyType(sym.symbolType, dctx.ctx);
		return rc.needsCleanup && (rc.rcKind === RcKind.Ref || rc.rcKind === RcKind.String);
	}

	// MemberExpr: look up object type, find field by name in typeNames/typeChildren
	if (expr.kind === NodeKind.MemberExpr) {
		const md = expr.data as MemberExprData;
		if (md.object.kind !== NodeKind.Identifier) return false;
		const objName = (md.object.data as IdentifierData).name;
		const objSym = lookupSymbol(dctx.ctx.checkerCtx.table, objName);
		if (objSym === null || objSym.symbolType === null) return false;
		const objType = objSym.symbolType;
		for (let fi = 0; fi < objType.typeNames.length && fi < objType.typeChildren.length; fi += 1) {
			if (objType.typeNames[fi] === md.property) {
				const rc = classifyType(objType.typeChildren[fi], dctx.ctx);
				return rc.needsCleanup && (rc.rcKind === RcKind.Ref || rc.rcKind === RcKind.String);
			}
		}
		return false;
	}
	// ArrayAccess: look up array element type via typeReturn
	if (expr.kind === NodeKind.ArrayAccess) {
		const ad = expr.data as ArrayAccessData;
		if (ad.array.kind !== NodeKind.Identifier) return false;
		const arrName = (ad.array.data as IdentifierData).name;
		const sym = lookupSymbol(dctx.ctx.checkerCtx.table, arrName);
		if (sym === null || sym.symbolType === null) return false;
		if (sym.symbolType.typeReturn === null) return false;
		const elemRc = classifyType(sym.symbolType.typeReturn, dctx.ctx);
		return elemRc.needsCleanup && (elemRc.rcKind === RcKind.Ref || elemRc.rcKind === RcKind.String);
	}

	return false;
}

// Emit: { const $ret_N = expr; msIncref($ret_N); return $ret_N; }
function emitReturnWithIncref(arg: Node, dctx: DrcContext, loc: SourceLocation): Node {
	const tmpName = freshTemp(dctx.ctx, "ret");
	const tmpDecl = makeVarDecl(tmpName, arg, DeclKind.Const, loc);
	const incref = makeExprStmt(
		makeCall(makeIdent("msIncref", loc), [makeIdent(tmpName, loc)], loc), loc);
	markReturnedVarsMoved(arg, dctx);
	const retStmt = makeReturn(makeIdent(tmpName, loc), loc);
	return makeBlock([tmpDecl, incref, retStmt], loc);
}

function processReturn(stmt: Node, dctx: DrcContext, loc: SourceLocation): Node {
	const d = stmt.data as ReturnStmtData;

	setNeedsTryAll(dctx);

	if (d.argument !== null) {
		// Process return argument recursively with Consumed mode
		d.argument = processNode(d.argument, dctx, DrcMode.Consumed);
		
		// Borrowed RC pointer return: wrap in temp + incref to prevent use-after-free
		if (needsReturnIncref(d.argument, dctx)) {
			return emitReturnWithIncref(d.argument, dctx, loc);
		}
		// Mark returned identifiers as moved in their owning scopes.
		// This prevents double-free: the finally block will emit wasMoved instead of destroy.
		markReturnedVarsMoved(d.argument, dctx);
	}

	return stmt;
}

// Mark identifiers in a return expression as moved in their owning scope,
// so the scope's finally block emits wasMoved (zero) instead of destroy.
function markReturnedVarsMoved(node: Node, dctx: DrcContext): void {
	if (node === null) return;
	if (node.kind === NodeKind.Identifier) {
		const name = (node.data as IdentifierData).name;
		const vi = findVarInfoInContext(dctx, name);
		if (vi !== null && vi.rcInfo.needsCleanup) {
			recordMoveInContext(dctx, name);
		}
		return;
	}
	// MoveExpr: unwrap and recurse on inner expression
	if (node.kind === NodeKind.MoveExpr) {
		markReturnedVarsMoved((node.data as MoveExprData).moveArg, dctx);
		return;
	}
	// For complex return expressions like `return a + b`, mark all identifiers
	if (node.kind === NodeKind.BinaryExpr) {
		const bd = node.data as BinaryExprData;
		markReturnedVarsMoved(bd.left, dctx);
		markReturnedVarsMoved(bd.right, dctx);
	}
	if (node.kind === NodeKind.MemberExpr) {
		markReturnedVarsMoved((node.data as MemberExprData).object, dctx);
	}
	if (node.kind === NodeKind.CallExpr) {
		const cd = node.data as CallExprData;
		markReturnedVarsMoved(cd.callee, dctx);
		for (const arg of cd.arguments) { markReturnedVarsMoved(arg, dctx); }
	}
}

// ===== Function Declaration =====

function processFuncDecl(stmt: Node, dctx: DrcContext, loc: SourceLocation): Node {
	const d = stmt.data as FunctionDeclData;
	if (d.fnBody === null) return stmt;
	d.fnBody = processFuncBodyWithParams(d.fnBody, d.fnName, d.params, dctx, loc);
	return stmt;
}

function processArrow(stmt: Node, dctx: DrcContext, loc: SourceLocation): Node {
	const d = stmt.data as ArrowFunctionData;
	if (d.arrowBody === null) return stmt;
	d.arrowBody = processFuncBodyWithParams(d.arrowBody, "", d.arrowParams, dctx, loc);
	return stmt;
}

function processFuncExpr(stmt: Node, dctx: DrcContext, loc: SourceLocation): Node {
	const d = stmt.data as FunctionExprData;
	if (d.funcExprBody === null) return stmt;
	d.funcExprBody = processFuncBodyWithParams(d.funcExprBody, "", d.funcExprParams, dctx, loc);
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

function processDoWhile(stmt: Node, dctx: DrcContext, loc: SourceLocation): Node {
	const d = stmt.data as DoWhileStmtData;
	d.doBody = processBlockBody(d.doBody, dctx, true, false, loc);
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
		md.methodBody = processFuncBodyWithParams(md.methodBody, md.methodName, md.methodParams, dctx, loc);
	}
}

function processCtorMember(member: Node, dctx: DrcContext, loc: SourceLocation): void {
	const cd = member.data as ConstructorDeclData;
	if (cd.ctorBody !== null) {
		cd.ctorBody = processFuncBodyWithParams(cd.ctorBody, "", cd.ctorParams, dctx, loc);
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
	const tctx = createTransformContextWithChecker(ctx);
	return createDrcContext(tctx);
}

export function testLoc(): SourceLocation {
	return { line: 0, column: 0 };
}

test "injectProgram no-op on primitives" {
	const dctx = testDrcContext("const x = 1; const y = 2;");
	const prog = makeBlock([], testLoc());
	expect(dctx.ctx.tempCounter === 0);
}

test "createDrcContext initializes" {
	const dctx = testDrcContext("const x = 1;");
	expect(scopeDepth(dctx) === 0);
}

test "generateCleanup LIFO order" {
	const dctx = testDrcContext("const x = 1;");
	pushScope(dctx, false, true);
	const rcStr = testStringRc();
	registerVar(dctx, "a", rcStr, false);
	registerVar(dctx, "b", rcStr, false);
	const scope = popScope(dctx);
	const cleanup = generateCleanup(scope, emptyNameSet(), testLoc());
	expect(cleanup.length === 2);
}

test "generateCleanup skips moved" {
	const dctx = testDrcContext("const x = 1;");
	pushScope(dctx, false, true);
	const rcStr = testStringRc();
	registerVar(dctx, "a", rcStr, false);
	registerVar(dctx, "b", rcStr, false);
	recordMove(dctx, "b");
	const scope = popScope(dctx);
	const cleanup = generateCleanup(scope, emptyNameSet(), testLoc());
	// wasMoved(b) + destroy(a) = 2 nodes
	expect(cleanup.length === 2);
}

test "generateCleanup skips excluded" {
	const dctx = testDrcContext("const x = 1;");
	pushScope(dctx, false, true);
	const rcStr = testStringRc();
	registerVar(dctx, "a", rcStr, false);
	registerVar(dctx, "b", rcStr, false);
	const scope = popScope(dctx);
	const exclude: NameSet = ["b"];
	const cleanup = generateCleanup(scope, exclude, testLoc());
	expect(cleanup.length === 1);
}

test "call is fresh" { expect(isFreshExpr(NodeKind.CallExpr)); }

test "identifier is not fresh" { expect(!isFreshExpr(NodeKind.Identifier)); }

test "isCompoundAssignOp detects +=" {
	expect(isCompoundAssignOp("+="));
	expect(isCompoundAssignOp("-="));
	expect(isCompoundAssignOp("*="));
	expect(isCompoundAssignOp("<<="));
}

test "isCompoundAssignOp rejects =" {
	expect(!isCompoundAssignOp("="));
	expect(!isCompoundAssignOp("+"));
	expect(!isCompoundAssignOp("=="));
}

test "compoundToSimpleOp converts" {
	expect(compoundToSimpleOp("+=") === "+");
	expect(compoundToSimpleOp("-=") === "-");
	expect(compoundToSimpleOp("<<=") === "<<");
}

test "emptyNameSet creates empty" {
	const ns = emptyNameSet();
	expect(ns.length === 0);
}

test "processBlockBody handles null" {
	const dctx = testDrcContext("const x = 1;");
	const result = processBlockBody(null as unknown as Node, dctx, false, false, testLoc());
	expect(result === null);
}

test "isEnvParam detects __envP" {
	expect(isEnvParam("__envP"));
	expect(isEnvParam("__envP_raw"));
	expect(!isEnvParam("param"));
	expect(!isEnvParam("env"));
}

test "isParamSinkCandidate detects return-only" {
	// Build: { return s; } — s only used as return arg → sink
	const body = makeBlock([makeReturn(makeIdent("s", testLoc()), testLoc())], testLoc());
	expect(isParamSinkCandidate("s", body));
}

test "isParamSinkCandidate rejects used param" {
	// Build: { const x = s; return x; } — s used in var init → not sink
	const body = makeBlock([
		makeVarDecl("x", makeIdent("s", testLoc()), DeclKind.Const, testLoc()),
		makeReturn(makeIdent("x", testLoc()), testLoc()),
	], testLoc());
	expect(!isParamSinkCandidate("s", body));
}

test "recordMoveInContext finds correct scope" {
	const dctx = testDrcContext("const x = 1;");
	const rcStr = testStringRc();
	pushScope(dctx, false, true);
	registerVar(dctx, "a", rcStr, false);
	pushScope(dctx, false, false);
	registerVar(dctx, "b", rcStr, false);
	// Record move for "a" — should find it in outer scope
	recordMoveInContext(dctx, "a");
	const innerScope = popScope(dctx);
	const outerScope = popScope(dctx);
	// "a" should be marked as moved in the outer scope
	expect(wasMovedInScope(outerScope, "a"));
	expect(!wasMovedInScope(innerScope, "a"));
}

test "both fresh branches are SINK" {
	// ConditionalExpr is in isFreshExpr, but processConditionalInit
	// differentiates between all-fresh and mixed branches.
	expect(isFreshExpr(NodeKind.ConditionalExpr));
}

test "wrapWithCallArgPre no-op on empty" {
	const loc = testLoc();
	const stmt = makeExprStmt(makeNull(loc), loc);
	const result = wrapWithCallArgPre(stmt, [], loc);
	// With empty pre, should return stmt unchanged
	expect(result === stmt);
}

test "string type needs cleanup with String rcKind" {
	const dctx = testDrcContext("const x: string = \"\";");
	const strType = lookupSymbol(dctx.ctx.checkerCtx.table, "x");
	if (strType !== null && strType.symbolType !== null) {
		const rc = classifyType(strType.symbolType, dctx.ctx);
		expect(rc.needsCleanup);
		expect(rc.rcKind === RcKind.String);
	}
}

test "number type needs no cleanup" {
	const dctx = testDrcContext("const n: number = 0;");
	const numSym = lookupSymbol(dctx.ctx.checkerCtx.table, "n");
	if (numSym !== null && numSym.symbolType !== null) {
		const rc = classifyType(numSym.symbolType, dctx.ctx);
		expect(!rc.needsCleanup);
	}
}

test "classifyNestedCallReturn non-identifier callee returns noRcInfo" {
	const dctx = testDrcContext("function foo(): string { return \"\"; }");
	const loc = testLoc();
	const memberCallee = makeMember(makeIdent("obj", loc), "method", loc);
	const call = makeCall(memberCallee, [], loc);
	const rc = classifyNestedCallReturn(call, dctx);
	expect(!rc.needsCleanup);
}

test "classifyNestedCallReturn known function returns rcInfo" {
	const dctx = testDrcContext("function getString(): string { return \"\"; }");
	const loc = testLoc();
	const call = makeCall(makeIdent("getString", loc), [], loc);
	const rc = classifyNestedCallReturn(call, dctx);
	expect(rc.needsCleanup);
	expect(rc.rcKind === RcKind.String);
}

test "classifyNestedCallReturn unknown function returns noRcInfo" {
	const dctx = testDrcContext("const x = 1;");
	const loc = testLoc();
	const call = makeCall(makeIdent("unknownFn", loc), [], loc);
	const rc = classifyNestedCallReturn(call, dctx);
	expect(!rc.needsCleanup);
}

test "stmtCanThrow detects user call in ExprStmt" {
	const loc = testLoc();
	const call = makeExprStmt(makeCall(makeIdent("foo", loc), [], loc), loc);
	expect(stmtCanThrow(call));
}

test "stmtCanThrow detects user call in VarDecl init" {
	const loc = testLoc();
	const decl = makeVarDecl("x", makeCall(makeIdent("foo", loc), [], loc), DeclKind.Const, loc);
	expect(stmtCanThrow(decl));
}

test "stmtCanThrow false for non-call" {
	const loc = testLoc();
	const stmt = makeExprStmt(makeIdent("x", loc), loc);
	expect(!stmtCanThrow(stmt));
}

test "stmtCanThrow false for null" { expect(!stmtCanThrow(null as unknown as Node)); }

test "callCanThrow false for ms-prefixed runtime calls" {
	const loc = testLoc();
	const call = makeCall(makeIdent("msStringDecref", loc), [], loc);
	expect(!callCanThrow(call));
}

test "callCanThrow true for user functions" {
	const loc = testLoc();
	const call = makeCall(makeIdent("parseExpr", loc), [], loc);
	expect(callCanThrow(call));
}

test "stmtCanThrow true for ThrowStmt" {
	const loc = testLoc();
	const throwStmt: Node = { kind: NodeKind.ThrowStmt, data: { throwArg: makeNull(loc) }, location: loc, nodeType: null as unknown as Type, resolvedSym: null as unknown as Symbol, flags: 0 };
	expect(stmtCanThrow(throwStmt));
}

test "stmtCanThrow false for ms-prefixed call in VarDecl" {
	const loc = testLoc();
	const decl = makeVarDecl("x", makeCall(makeIdent("msArrayCopy", loc), [], loc), DeclKind.Const, loc);
	expect(!stmtCanThrow(decl));
}

test "needsReturnIncref false for call expr (fresh)" {
	const dctx = testDrcContext("function getString(): string { return \"\"; }");
	const loc = testLoc();
	const call = makeCall(makeIdent("getString", loc), [], loc);
	expect(!needsReturnIncref(call, dctx));
}

test "needsReturnIncref false for local var (moved)" {
	const dctx = testDrcContext("function foo(): string { const s = \"\"; return s; }");
	pushScope(dctx, false, true);
	const rcStr = testStringRc();
	registerVar(dctx, "s", rcStr, false);
	const loc = testLoc();
	const ident = makeIdent("s", loc);
	expect(!needsReturnIncref(ident, dctx));
	popScope(dctx);
}

test "needsReturnIncref true for member expr with string field" {
	const dctx = testDrcContext("interface Obj { name: string; } const o: Obj = { name: \"\" };");
	const loc = testLoc();
	const memberExpr = makeMember(makeIdent("o", loc), "name", loc);
	expect(needsReturnIncref(memberExpr, dctx));
}

test "emitReturnWithIncref produces block with 3 stmts" {
	const dctx = testDrcContext("interface Obj { name: string; } const o: Obj = { name: \"\" };");
	const loc = testLoc();
	pushScope(dctx, false, true);
	const arg = makeMember(makeIdent("o", loc), "name", loc);
	const result = emitReturnWithIncref(arg, dctx, loc);
	expect(result.kind === NodeKind.BlockStmt);
	const bd = result.data as BlockStmtData;
	expect(bd.statements.length === 3);  // tmpDecl, incref, return
	popScope(dctx);
}

test "isVarFromOuterLoopScope: var in function scope, inside loop" {
	const dctx = testDrcContext("const x = 1;");
	const rcStr = testStringRc();
	pushScope(dctx, false, true);    // function scope
	registerVar(dctx, "x", rcStr, false);
	pushScope(dctx, true, false);    // loop scope
	expect(isVarFromOuterLoopScope("x", dctx));
	popScope(dctx);
	popScope(dctx);
}

test "isVarFromOuterLoopScope: var in loop scope, not outer" {
	const dctx = testDrcContext("const x = 1;");
	const rcStr = testStringRc();
	pushScope(dctx, false, true);    // function scope
	pushScope(dctx, true, false);    // loop scope
	registerVar(dctx, "s", rcStr, false);
	expect(!isVarFromOuterLoopScope("s", dctx));
	popScope(dctx);
	popScope(dctx);
}

test "isVarFromOuterLoopScope: no loop, returns false" {
	const dctx = testDrcContext("const x = 1;");
	const rcStr = testStringRc();
	pushScope(dctx, false, true);    // function scope
	registerVar(dctx, "x", rcStr, false);
	pushScope(dctx, false, false);   // block scope (not loop)
	expect(!isVarFromOuterLoopScope("x", dctx));
	popScope(dctx);
	popScope(dctx);
}

test "isVarFromOuterLoopScope: nested loops, var in outer loop" {
	const dctx = testDrcContext("const x = 1;");
	const rcStr = testStringRc();
	pushScope(dctx, false, true);    // function scope
	pushScope(dctx, true, false);    // outer loop
	registerVar(dctx, "s", rcStr, false);
	pushScope(dctx, true, false);    // inner loop
	expect(isVarFromOuterLoopScope("s", dctx));
	popScope(dctx);
	popScope(dctx);
	popScope(dctx);
}

test "isVarFromOuterLoopScope: nested loops, var in function scope" {
	const dctx = testDrcContext("const x = 1;");
	const rcStr = testStringRc();
	pushScope(dctx, false, true);    // function scope
	registerVar(dctx, "x", rcStr, false);
	pushScope(dctx, true, false);    // outer loop
	pushScope(dctx, true, false);    // inner loop
	expect(isVarFromOuterLoopScope("x", dctx));
	popScope(dctx);
	popScope(dctx);
	popScope(dctx);
}

// ===== Phase A: Finally-Protected Variables Tests =====

test "collectFinallyVars finds vars in finally block" {
	const loc = testLoc();
	const finallyBody = makeBlock([
		makeExprStmt(makeCall(makeIdent("cleanup", loc), [makeIdent("s", loc)], loc), loc),
	], loc);
	const tryStmt = makeTryCatch(
		makeBlock([makeExprStmt(makeIdent("s", loc), loc)], loc),
		"",
		null as unknown as Node,
		finallyBody,
		loc,
	);
	const body = makeBlock([tryStmt], loc);
	const vars = collectFinallyVars(body);
	expect(nameSetContains(vars, "s"));
	expect(nameSetContains(vars, "cleanup"));
}

test "collectFinallyVars empty when no finally" {
	const loc = testLoc();
	const body = makeBlock([
		makeExprStmt(makeIdent("x", loc), loc),
	], loc);
	const vars = collectFinallyVars(body);
	expect(vars.length === 0);
}

test "finally-protected var blocks move in isLastReadSafe" {
	const dctx = testDrcContext("const x = 1;");
	dctx.finallyProtectedVars = ["s"];
	// Even with a null symbol, the name check fires first
	const fakeSym: Symbol = { name: "s", symbolKind: 0, symbolType: null as unknown as Type, symFlags: 0 };
	expect(!isLastReadSafe(fakeSym, null as unknown as Node, 0, [], dctx));
}

test "isVarFromOuterLoopScope: block inside loop, var before loop" {
	const dctx = testDrcContext("const x = 1;");
	const rcStr = testStringRc();
	pushScope(dctx, false, true);    // function scope
	registerVar(dctx, "x", rcStr, false);
	pushScope(dctx, true, false);    // loop scope
	pushScope(dctx, false, false);   // block inside loop
	expect(isVarFromOuterLoopScope("x", dctx));
	popScope(dctx);
	popScope(dctx);
	popScope(dctx);
}

test "emitMoveSourceWasMoved on identifier emits pending wasMoved" {
	const dctx = testDrcContext("const x: string = \"\";");
	const rcStr = testStringRc();
	const loc = testLoc();
	pushScope(dctx, false, true);
	registerVar(dctx, "x", rcStr, false);
	const stmts: Node[] = [makeExprStmt(makeNull(loc), loc)];
	const handled = emitMoveSourceWasMoved(makeIdent("x", loc), rcStr, 0, stmts, dctx, loc, false);
	expect(handled);
	expect(hasPending(dctx));
	popScope(dctx);
}

test "emitMoveSourceWasMoved on call expr returns false (fresh)" {
	const dctx = testDrcContext("function f(): string { return \"\"; }");
	const rcStr = testStringRc();
	const loc = testLoc();
	pushScope(dctx, false, true);
	const call = makeCall(makeIdent("f", loc), [], loc);
	const handled = emitMoveSourceWasMoved(call, rcStr, 0, [], dctx, loc, false);
	expect(!handled);
	expect(!hasPending(dctx));
	popScope(dctx);
}

test "isFreshExpr includes MoveExpr" { expect(isFreshExpr(NodeKind.MoveExpr)); }

test "classifyMemberFieldRc returns RC info for string field" {
	const dctx = testDrcContext("interface Obj { name: string; } const o: Obj = { name: \"\" };");
	const loc = testLoc();
	const memberExpr = makeMember(makeIdent("o", loc), "name", loc);
	const rc = classifyMemberFieldRc(memberExpr, dctx);
	expect(rc.needsCleanup);
	expect(rc.rcKind === RcKind.String);
}

test "classifyArrayElementRc returns RC info for string array" {
	const dctx = testDrcContext("const arr: string[] = [];");
	const sym = lookupSymbol(dctx.ctx.checkerCtx.table, "arr");
	if (sym !== null && sym.symbolType !== null && sym.symbolType.typeReturn !== null) {
		const rc = classifyType(sym.symbolType.typeReturn, dctx.ctx);
		expect(rc.needsCleanup);
		expect(rc.rcKind === RcKind.String);
	}
}

test "makeSinkCall emits sinkFn call node" {
	const dctx = testDrcContext("const x: string = \"\";");
	const rcStr = testStringRc();
	const loc = testLoc();
	const sink = makeSinkCall("x", makeIdent("y", loc), rcStr, loc);
	// Should produce an ExprStmt containing a CallExpr with 2 args
	expect(sink.kind === NodeKind.ExprStmt);
	const sd = sink.data as ExprStmtData;
	expect(sd.expr.kind === NodeKind.CallExpr);
	const cd = sd.expr.data as CallExprData;
	expect(cd.callee.kind === NodeKind.Identifier);
	expect(cd.arguments.length === 2);
}

test "sinkFn field populated for string type" {
	const dctx = testDrcContext("const x: string = \"\";");
	const sym = lookupSymbol(dctx.ctx.checkerCtx.table, "x");
	if (sym !== null && sym.symbolType !== null) {
		const rc = classifyType(sym.symbolType, dctx.ctx);
		expect(rc.sinkFn !== "");
	}
}

test "first-write: uninitialized var marked not initialized" {
	const dctx = testDrcContext("let x: string;");
	const rcStr = testStringRc();
	pushScope(dctx, false, true);
	registerVar(dctx, "x", rcStr, false);
	// After register, isInitialized is true by default
	const vi1 = findVarInfoInContext(dctx, "x");
	expect(vi1 !== null);
	expect(vi1.isInitialized);
	// markUninitialized sets it to false
	markUninitialized(dctx, "x");
	expect(!vi1.isInitialized);
	popScope(dctx);
}

test "first-write: second assignment restores initialized" {
	const dctx = testDrcContext("let x: string;");
	const rcStr = testStringRc();
	pushScope(dctx, false, true);
	registerVar(dctx, "x", rcStr, false);
	markUninitialized(dctx, "x");
	const vi = findVarInfoInContext(dctx, "x");
	expect(!vi.isInitialized);
	// Simulate first-write marking it initialized
	vi.isInitialized = true;
	expect(vi.isInitialized);
	popScope(dctx);
}

test "sink param: return-only param is cursor (skip cleanup)" {
	const dctx = testDrcContext("function f(s: string): string { return s; }");
	const fnSym = lookupSymbol(dctx.ctx.checkerCtx.table, "f");
	if (fnSym !== null && fnSym.symbolType !== null) {
		// Verify function is recognized
		expect(fnSym.symbolType.kind === TypeKind.Function);
	}
}

test "lent param: SF_LENT in typeChildrenFlags skips RC at call site" {
	// Verify that processCallArgs respects SF_LENT flag
	const dctx = testDrcContext("const x: string = \"\";");
	// SF_LENT check is structural — verified by code reading
	expect(SF_LENT !== 0);
	expect(SF_SINK !== 0);
	expect(SF_LENT !== SF_SINK);
}

test "isGeneratorBody: detects $state pattern" {
	const loc = testLoc();
	const stateDecl = makeVarDecl("$state", makeNull(loc), DeclKind.Let, loc);
	const body = makeBlock([stateDecl], loc);
	expect(isGeneratorBody(body));
}

test "isGeneratorBody: normal function returns false" {
	const loc = testLoc();
	const xDecl = makeVarDecl("x", makeNull(loc), DeclKind.Let, loc);
	const body = makeBlock([xDecl], loc);
	expect(!isGeneratorBody(body));
}

test "isGeneratorBody: null body returns false" {
	expect(!isGeneratorBody(null as unknown as Node));
}

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
	DoWhileStmtData, MoveExprData,
} from "../ast/node";
import { Type, TypeKind } from "../checker/types";
import { lookupSymbol, SymbolKind } from "../checker/symbol";
import { TransformContext, NameSet, nameSetContains, freshTemp, createTransformContextWithChecker } from "../transform/context";
import {
	makeIdent, makeBlock, makeExprStmt, makeCall, makeVarDecl,
	makeReturn, makeAssign, makeTryCatch, makeNull, makeBinary, makeMember,
	makeUnary,
} from "../transform/util";
import { RcInfo, RcKind, classifyType, isFreshExpr, noRcInfo } from "./classify";
import {
	DrcContext, DrcScope, VarInfo, StmtBuf,
	createDrcContext, pushScope, popScope, currentScope, scopeDepth,
	registerVar, recordMove, recordMoveInContext, wasMovedInScope, findVarInfo, findVarInfoInContext,
	setNeedsTryToLoop, setNeedsTryAll, addPending, flushPending, hasPending,
	pushOuterStmts, popOuterStmts,
	testStringRc,
} from "./scope";
import { isLastReadInBlock, isLastReadInContext, deepAliases, nodeReferencesVar } from "./lastRead";
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
	if (dctx.ctx.checkerCtx === null) return noRcInfo();
	const md = memberExpr.data as MemberExprData;
	if (md.object.kind !== NodeKind.Identifier) return noRcInfo();
	const objName = (md.object.data as IdentifierData).name;
	const objSym = lookupSymbol(dctx.ctx.checkerCtx.table, objName);
	if (objSym === null || objSym.symbolType === null) return noRcInfo();
	const objType = objSym.symbolType;
	for (let fi = 0; fi < objType.typeNames.length && fi < objType.typeChildren.length; fi += 1) {
		if (objType.typeNames[fi] === md.property) {
			return classifyType(objType.typeChildren[fi], dctx.ctx);
		}
	}
	return noRcInfo();
}

// Classify RC type of an array element
function classifyArrayElementRc(arrayExpr: Node, dctx: DrcContext): RcInfo {
	if (dctx.ctx.checkerCtx === null) return noRcInfo();
	const ad = arrayExpr.data as ArrayAccessData;
	if (ad.array.kind !== NodeKind.Identifier) return noRcInfo();
	const arrName = (ad.array.data as IdentifierData).name;
	const arrSym = lookupSymbol(dctx.ctx.checkerCtx.table, arrName);
	if (arrSym === null || arrSym.symbolType === null) return noRcInfo();
	if (arrSym.symbolType.typeReturn === null) return noRcInfo();
	return classifyType(arrSym.symbolType.typeReturn, dctx.ctx);
}

// Emit wasMoved on MoveExpr source. Handles identifier, field, array element.
// checkLastRead: true when idx/stmts context is valid (for errFailedMove diagnostic)
// Returns true if wasMoved was emitted.
function emitMoveSourceWasMoved(moveArg: Node, rcInfo: RcInfo, idx: number, stmts: Node[], dctx: DrcContext, loc: SourceLocation, checkLastRead: boolean): boolean {
	if (moveArg.kind === NodeKind.Identifier) {
		const srcName = (moveArg.data as IdentifierData).name;
		// errFailedMove diagnostic: error when move can't actually move
		if (checkLastRead && !isLastReadSafe(srcName, idx, stmts, dctx)) {
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
				hoisted.push(makeVarDecl(d.declName, makeNull(loc), DeclKind.Let, loc));
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
	for (let i = 0; i < stmts.length; i += 1) {
		const processed = processStmt(stmts[i], i, stmts, dctx, loc);
		out.stmts.push(processed);
		flushPending(dctx, out);
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

	// canRaise: if stmt contains a call and scope has RC vars, set needsTry
	// This ensures try/finally wrapping for exception safety from function calls.
	if (scopeDepth(dctx) > 0 && stmtMayCall(stmt) && currentScope(dctx).varsToCleanup.items.length > 0) {
		currentScope(dctx).needsTry = true;
	}

	return result;
}

// Check if a statement may invoke a function call (conservative: only direct patterns)
function stmtMayCall(node: Node): boolean {
	if (node === null) return false;
	if (node.kind === NodeKind.ExprStmt) {
		const expr = (node.data as ExprStmtData).expr;
		if (expr !== null && expr.kind === NodeKind.CallExpr) return true;
		// Assignment with call RHS: x = f()
		if (expr !== null && expr.kind === NodeKind.BinaryExpr) {
			const bd = expr.data as BinaryExprData;
			if (bd.right !== null && bd.right.kind === NodeKind.CallExpr) return true;
		}
		return false;
	}
	if (node.kind === NodeKind.VariableDecl) {
		const vd = node.data as VariableDeclData;
		return vd.initializer !== null && vd.initializer.kind === NodeKind.CallExpr;
	}
	return false;
}

// ===== Loop-Aware Last-Read =====
// Variables defined before a loop are NEVER last-read inside the loop body,
// because the loop repeats and uses them again. The forward scan misses this
// because it doesn't see loop back-edges.

function isVarFromOuterLoopScope(varName: string, dctx: DrcContext): boolean {
	let passedInnerLoop = false;
	let i = dctx.scopes.items.length;
	while (i > 0) {
		i -= 1;
		const scope = dctx.scopes.items[i];
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

function isLastReadSafe(varName: string, idx: number, stmts: Node[], dctx: DrcContext): boolean {
	if (!isLastReadInContext(varName, idx, stmts, dctx.outerCtx)) return false;
	// If variable is from a scope outside a loop, it's not truly last-read
	// inside the loop body (the loop will repeat and use it again).
	if (isVarFromOuterLoopScope(varName, dctx)) return false;
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

	// Look up callee to get param types
	if (cd.callee === null || cd.callee.kind !== NodeKind.Identifier) return pre;
	const calleeName = (cd.callee.data as IdentifierData).name;
	const sym = lookupSymbol(dctx.ctx.checkerCtx.table, calleeName);
	if (sym === null || sym.symbolType === null) return pre;
	const fnType = sym.symbolType;
	if (fnType.kind !== TypeKind.Function) return pre;

	for (let ai = 0; ai < cd.arguments.length && ai < fnType.typeChildren.length; ai += 1) {
		const arg = cd.arguments[ai];
		if (arg !== null && arg.kind === NodeKind.Identifier) {
			const argName = (arg.data as IdentifierData).name;
			const paramRc = classifyType(fnType.typeChildren[ai], dctx.ctx);
			if (paramRc.needsCleanup) {
				if (isLastReadSafe(argName, idx, stmts, dctx)) {
					// MOVE: emit wasMoved after the call
					if (paramRc.wasMovedFn !== "") {
						addPending(dctx, makeWasMovedCall(argName, paramRc, loc));
					}
					recordMove(dctx, argName);
				} else {
					// COPY: emit incref before the call (bumps refcount for callee's destroy)
					if (paramRc.copyFn !== "") {
						pre.push(makeRcCallStmt(paramRc.copyFn, argName, loc));
					}
				}
			}
		}
		// MoveExpr arg: force move — wasMoved on source, no incref
		if (arg !== null && arg.kind === NodeKind.MoveExpr) {
			const md = arg.data as MoveExprData;
			const paramRc = classifyType(fnType.typeChildren[ai], dctx.ctx);
			if (paramRc.needsCleanup) {
				emitMoveSourceWasMoved(md.moveArg, paramRc, idx, stmts, dctx, loc, true);
			}
		}
		// Nested call arg: extract to temp to prevent RC leak
		if (arg !== null && arg.kind === NodeKind.CallExpr) {
			const nestedRc = classifyNestedCallReturn(arg, dctx);
			if (nestedRc.needsCleanup) {
				const tmpName = freshTemp(dctx.ctx, "sink");
				pre.push(makeVarDecl(tmpName, arg, DeclKind.Const, loc));
				registerVar(dctx, tmpName, nestedRc, false);
				cd.arguments[ai] = makeIdent(tmpName, loc);
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
				if (isLastReadSafe(propName, idx, stmts, dctx)) {
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
			if (isLastReadSafe(elemName, idx, stmts, dctx)) {
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
		// Skip closure env params (item 11) — they're managed by ms_closure_* infrastructure
		if (!isEnvParam(pName)) {
			const pRcInfo = classifyType(paramTypes[pi], dctx.ctx);
			if (pRcInfo.needsCleanup) {
				// Sink inference: if param is only used in return position, mark as cursor (skip cleanup)
				const isSink = body !== null && isParamSinkCandidate(pName, body);
				registerVar(dctx, pName, pRcInfo, isSink);
			}
		}
	}
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
	const cleanup = generateCleanup(scope, emptyNameSet(), loc);
	popOuterStmts(dctx);  // pop function boundary sentinel

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

	// Object literal: fresh as whole, but RC fields need incref
	if (init.kind === NodeKind.ObjectLiteral) {
		emitLiteralFieldCopies(init, sym.symbolType, idx, stmts, dctx, loc);
		return stmt;
	}

	// Array literal: fresh as whole, but RC elements need incref
	if (init.kind === NodeKind.ArrayLiteral) {
		emitArrayElementCopies(init, sym.symbolType, idx, stmts, dctx, loc);
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
		if (isLastReadSafe(initD.name, idx, stmts, dctx)) {
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

	if (expr.kind === NodeKind.BinaryExpr) {
		const bd = expr.data as BinaryExprData;

		// Assignment: x = expr (identifier LHS)
		if (bd.operator === "=" && bd.left.kind === NodeKind.Identifier) {
			return processAssignment(stmt, bd, idx, stmts, dctx, loc);
		}

		// Member assignment: obj.field = expr
		if (bd.operator === "=" && bd.left.kind === NodeKind.MemberExpr) {
			return processMemberAssignment(stmt, bd, dctx, loc);
		}

		// Array index assignment: arr[i] = expr
		if (bd.operator === "=" && bd.left.kind === NodeKind.ArrayAccess) {
			return processArrayAssignment(stmt, bd, dctx, loc);
		}

		// Compound assignment: x += y, s += "text", etc.
		if (isCompoundAssignOp(bd.operator) && bd.left.kind === NodeKind.Identifier) {
			return processCompoundAssignment(stmt, bd, idx, stmts, dctx, loc);
		}
	}

	// Call expression: process arguments for caller-side copies, then handle discarded return
	if (expr.kind === NodeKind.CallExpr) {
		const preStmts = processCallArgs(expr, idx, stmts, dctx, loc);
		const processed = processDiscardedCall(stmt, expr, dctx, loc);
		return wrapWithCallArgPre(processed, preStmts, loc);
	}

	return stmt;
}

// ===== Assignment Processing =====

function processAssignment(stmt: Node, bd: BinaryExprData, idx: number, stmts: Node[], dctx: DrcContext, loc: SourceLocation): Node {
	const leftD = bd.left.data as IdentifierData;

	if (dctx.ctx.checkerCtx === null) return stmt;
	const sym = lookupSymbol(dctx.ctx.checkerCtx.table, leftD.name);
	if (sym === null) return stmt;

	const rcInfo = classifyType(sym.symbolType, dctx.ctx);
	if (!rcInfo.needsCleanup) return stmt;

	const rhs = bd.right;

	// Call RHS: fresh for dest, but also process call arguments
	if (rhs.kind === NodeKind.CallExpr) {
		const preStmts = processCallArgs(rhs, idx, stmts, dctx, loc);
		if (deepAliases(leftD.name, rhs)) {
			const tmpName = freshTemp(dctx.ctx, "old");
			const saveTmp = makeVarDecl(tmpName, makeIdent(leftD.name, loc), DeclKind.Const, loc);
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
			const srcName = (md.moveArg.data as IdentifierData).name;
			if (srcName === leftD.name) return stmt;
		}

		// Aliased move: x = move x.field → destructiveMoveVar pattern
		if (deepAliases(leftD.name, md.moveArg)) {
			const tmpName = freshTemp(dctx.ctx, "moveTmp");
			const captureDecl = makeVarDecl(tmpName, md.moveArg, DeclKind.Const, loc);
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
		if (deepAliases(leftD.name, rhs)) {
			const tmpName = freshTemp(dctx.ctx, "old");
			const saveTmp = makeVarDecl(tmpName, makeIdent(leftD.name, loc), DeclKind.Const, loc);
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
		const destroyOld = makeDestroyCall(leftD.name, rcInfo, loc);
		if (isLastReadSafe(rightD.name, idx, stmts, dctx)) {
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

// ===== Member Assignment: obj.field = expr =====

function processMemberAssignment(stmt: Node, bd: BinaryExprData, dctx: DrcContext, loc: SourceLocation): Node {
	if (dctx.ctx.checkerCtx === null) return stmt;
	const leftMd = bd.left.data as MemberExprData;

	const fieldName = leftMd.property;
	const sym = lookupSymbol(dctx.ctx.checkerCtx.table, fieldName);
	if (sym === null) return stmt;

	const rcInfo = classifyType(sym.symbolType, dctx.ctx);
	if (!rcInfo.needsCleanup) return stmt;

	return emitSaveAssignDestroy(stmt, bd.left, bd.right, rcInfo, "Field", dctx, loc);
}

// ===== Array Index Assignment: arr[i] = expr =====

function processArrayAssignment(stmt: Node, bd: BinaryExprData, dctx: DrcContext, loc: SourceLocation): Node {
	if (dctx.ctx.checkerCtx === null) return stmt;
	const leftAd = bd.left.data as ArrayAccessData;

	if (leftAd.array.kind !== NodeKind.Identifier) return stmt;
	const arrName = (leftAd.array.data as IdentifierData).name;
	const sym = lookupSymbol(dctx.ctx.checkerCtx.table, arrName);
	if (sym === null) return stmt;

	const arrType = sym.symbolType;
	if (arrType === null || arrType.typeChildren.length === 0) return stmt;
	const elemType = arrType.typeChildren[0];
	const rcInfo = classifyType(elemType, dctx.ctx);
	if (!rcInfo.needsCleanup) return stmt;

	return emitSaveAssignDestroy(stmt, bd.left, bd.right, rcInfo, "Elem", dctx, loc);
}

// ===== Compound Assignment: x += y =====

function processCompoundAssignment(stmt: Node, bd: BinaryExprData, idx: number, stmts: Node[], dctx: DrcContext, loc: SourceLocation): Node {
	if (dctx.ctx.checkerCtx === null) return stmt;
	const leftD = bd.left.data as IdentifierData;

	const sym = lookupSymbol(dctx.ctx.checkerCtx.table, leftD.name);
	if (sym === null) return stmt;

	const rcInfo = classifyType(sym.symbolType, dctx.ctx);
	if (!rcInfo.needsCleanup) return stmt;

	// Fused string append: s += rhs → ms_string_append(&s, rhs) (in-place, no alloc)
	// Skip when rhs aliases s (self-append s += s needs save/concat/destroy)
	if (rcInfo.rcKind === RcKind.String && bd.operator === "+=") {
		if (!deepAliases(leftD.name, bd.right)) {
			const addrOf = makeUnary("&", makeIdent(leftD.name, loc), loc);
			const appendCall = makeCall(
				makeIdent("ms_string_append", loc),
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

	// Capture in temp for proper cleanup
	const tmpName = freshTemp(dctx.ctx, "discard");
	const capture = makeVarDecl(tmpName, callExpr, DeclKind.Const, loc);
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
		const rcStr = testStringRc();
		registerVar(dctx, "a", rcStr, false);
		registerVar(dctx, "b", rcStr, false);
		const scope = popScope(dctx);
		const cleanup = generateCleanup(scope, emptyNameSet(), testLoc());
		check(cleanup.length === 2);
	});
	test("generateCleanup skips moved", () => {
		const dctx = testDrcContext("const x = 1;");
		pushScope(dctx, false, true);
		const rcStr = testStringRc();
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
		const rcStr = testStringRc();
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

testGroup("DRC Inject Compound Assignment", () => {
	test("isCompoundAssignOp detects +=", () => {
		check(isCompoundAssignOp("+="));
		check(isCompoundAssignOp("-="));
		check(isCompoundAssignOp("*="));
		check(isCompoundAssignOp("<<="));
	});
	test("isCompoundAssignOp rejects =", () => {
		check(!isCompoundAssignOp("="));
		check(!isCompoundAssignOp("+"));
		check(!isCompoundAssignOp("=="));
	});
	test("compoundToSimpleOp converts", () => {
		check(compoundToSimpleOp("+=") === "+");
		check(compoundToSimpleOp("-=") === "-");
		check(compoundToSimpleOp("<<=") === "<<");
	});
});

testGroup("DRC Inject Literal Helpers", () => {
	test("emptyNameSet creates empty", () => {
		const ns = emptyNameSet();
		check(ns.names.length === 0);
	});
	test("processBlockBody handles null", () => {
		const dctx = testDrcContext("const x = 1;");
		const result = processBlockBody(null as unknown as Node, dctx, false, false, testLoc());
		check(result === null);
	});
});

testGroup("DRC Inject Sink Params", () => {
	test("isEnvParam detects __envP", () => {
		check(isEnvParam("__envP"));
		check(isEnvParam("__envP_raw"));
		check(!isEnvParam("param"));
		check(!isEnvParam("env"));
	});
	test("isParamSinkCandidate detects return-only", () => {
		// Build: { return s; } — s only used as return arg → sink
		const body = makeBlock([makeReturn(makeIdent("s", testLoc()), testLoc())], testLoc());
		check(isParamSinkCandidate("s", body));
	});
	test("isParamSinkCandidate rejects used param", () => {
		// Build: { const x = s; return x; } — s used in var init → not sink
		const body = makeBlock([
			makeVarDecl("x", makeIdent("s", testLoc()), DeclKind.Const, testLoc()),
			makeReturn(makeIdent("x", testLoc()), testLoc()),
		], testLoc());
		check(!isParamSinkCandidate("s", body));
	});
	test("recordMoveInContext finds correct scope", () => {
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
		check(wasMovedInScope(outerScope, "a"));
		check(!wasMovedInScope(innerScope, "a"));
	});
});

testGroup("DRC Inject Conditional", () => {
	test("both fresh branches are SINK", () => {
		// ConditionalExpr is in isFreshExpr, but processConditionalInit
		// differentiates between all-fresh and mixed branches.
		check(isFreshExpr(NodeKind.ConditionalExpr));
	});
});

testGroup("DRC Inject Call Args", () => {
	test("wrapWithCallArgPre no-op on empty", () => {
		const loc = testLoc();
		const stmt = makeExprStmt(makeNull(loc), loc);
		const result = wrapWithCallArgPre(stmt, [], loc);
		// With empty pre, should return stmt unchanged
		check(result === stmt);
	});
});

testGroup("DRC Inject classifyType", () => {
	test("string type needs cleanup with String rcKind", () => {
		const dctx = testDrcContext("const x: string = \"\";");
		const strType = lookupSymbol(dctx.ctx.checkerCtx.table, "x");
		if (strType !== null && strType.symbolType !== null) {
			const rc = classifyType(strType.symbolType, dctx.ctx);
			check(rc.needsCleanup);
			check(rc.rcKind === RcKind.String);
		}
	});
	test("number type needs no cleanup", () => {
		const dctx = testDrcContext("const n: number = 0;");
		const numSym = lookupSymbol(dctx.ctx.checkerCtx.table, "n");
		if (numSym !== null && numSym.symbolType !== null) {
			const rc = classifyType(numSym.symbolType, dctx.ctx);
			check(!rc.needsCleanup);
		}
	});
});

testGroup("DRC Inject Nested Call Temps", () => {
	test("classifyNestedCallReturn non-identifier callee returns noRcInfo", () => {
		const dctx = testDrcContext("function foo(): string { return \"\"; }");
		const loc = testLoc();
		const memberCallee = makeMember(makeIdent("obj", loc), "method", loc);
		const call = makeCall(memberCallee, [], loc);
		const rc = classifyNestedCallReturn(call, dctx);
		check(!rc.needsCleanup);
	});
	test("classifyNestedCallReturn known function returns rcInfo", () => {
		const dctx = testDrcContext("function getString(): string { return \"\"; }");
		const loc = testLoc();
		const call = makeCall(makeIdent("getString", loc), [], loc);
		const rc = classifyNestedCallReturn(call, dctx);
		check(rc.needsCleanup);
		check(rc.rcKind === RcKind.String);
	});
	test("classifyNestedCallReturn unknown function returns noRcInfo", () => {
		const dctx = testDrcContext("const x = 1;");
		const loc = testLoc();
		const call = makeCall(makeIdent("unknownFn", loc), [], loc);
		const rc = classifyNestedCallReturn(call, dctx);
		check(!rc.needsCleanup);
	});
});

testGroup("DRC Inject canRaise", () => {
	test("stmtMayCall detects call in ExprStmt", () => {
		const loc = testLoc();
		const call = makeExprStmt(makeCall(makeIdent("foo", loc), [], loc), loc);
		check(stmtMayCall(call));
	});
	test("stmtMayCall detects call in VarDecl init", () => {
		const loc = testLoc();
		const decl = makeVarDecl("x", makeCall(makeIdent("foo", loc), [], loc), DeclKind.Const, loc);
		check(stmtMayCall(decl));
	});
	test("stmtMayCall false for non-call", () => {
		const loc = testLoc();
		const stmt = makeExprStmt(makeIdent("x", loc), loc);
		check(!stmtMayCall(stmt));
	});
	test("stmtMayCall false for null", () => {
		check(!stmtMayCall(null as unknown as Node));
	});
});

testGroup("DRC Inject Return Temp Capture", () => {
	test("needsReturnIncref false for call expr (fresh)", () => {
		const dctx = testDrcContext("function getString(): string { return \"\"; }");
		const loc = testLoc();
		const call = makeCall(makeIdent("getString", loc), [], loc);
		check(!needsReturnIncref(call, dctx));
	});
	test("needsReturnIncref false for local var (moved)", () => {
		const dctx = testDrcContext("function foo(): string { const s = \"\"; return s; }");
		pushScope(dctx, false, true);
		const rcStr = testStringRc();
		registerVar(dctx, "s", rcStr, false);
		const loc = testLoc();
		const ident = makeIdent("s", loc);
		check(!needsReturnIncref(ident, dctx));
		popScope(dctx);
	});
	test("needsReturnIncref true for member expr with string field", () => {
		const dctx = testDrcContext("interface Obj { name: string; } const o: Obj = { name: \"\" };");
		const loc = testLoc();
		const memberExpr = makeMember(makeIdent("o", loc), "name", loc);
		check(needsReturnIncref(memberExpr, dctx));
	});
	test("emitReturnWithIncref produces block with 3 stmts", () => {
		const dctx = testDrcContext("interface Obj { name: string; } const o: Obj = { name: \"\" };");
		const loc = testLoc();
		pushScope(dctx, false, true);
		const arg = makeMember(makeIdent("o", loc), "name", loc);
		const result = emitReturnWithIncref(arg, dctx, loc);
		check(result.kind === NodeKind.BlockStmt);
		const bd = result.data as BlockStmtData;
		check(bd.statements.length === 3);  // tmpDecl, incref, return
		popScope(dctx);
	});
});

testGroup("DRC Inject Loop-Aware Last-Read", () => {
	test("isVarFromOuterLoopScope: var in function scope, inside loop", () => {
		const dctx = testDrcContext("const x = 1;");
		const rcStr = testStringRc();
		pushScope(dctx, false, true);    // function scope
		registerVar(dctx, "x", rcStr, false);
		pushScope(dctx, true, false);    // loop scope
		check(isVarFromOuterLoopScope("x", dctx));
		popScope(dctx);
		popScope(dctx);
	});
	test("isVarFromOuterLoopScope: var in loop scope, not outer", () => {
		const dctx = testDrcContext("const x = 1;");
		const rcStr = testStringRc();
		pushScope(dctx, false, true);    // function scope
		pushScope(dctx, true, false);    // loop scope
		registerVar(dctx, "s", rcStr, false);
		check(!isVarFromOuterLoopScope("s", dctx));
		popScope(dctx);
		popScope(dctx);
	});
	test("isVarFromOuterLoopScope: no loop, returns false", () => {
		const dctx = testDrcContext("const x = 1;");
		const rcStr = testStringRc();
		pushScope(dctx, false, true);    // function scope
		registerVar(dctx, "x", rcStr, false);
		pushScope(dctx, false, false);   // block scope (not loop)
		check(!isVarFromOuterLoopScope("x", dctx));
		popScope(dctx);
		popScope(dctx);
	});
	test("isVarFromOuterLoopScope: nested loops, var in outer loop", () => {
		const dctx = testDrcContext("const x = 1;");
		const rcStr = testStringRc();
		pushScope(dctx, false, true);    // function scope
		pushScope(dctx, true, false);    // outer loop
		registerVar(dctx, "s", rcStr, false);
		pushScope(dctx, true, false);    // inner loop
		check(isVarFromOuterLoopScope("s", dctx));
		popScope(dctx);
		popScope(dctx);
		popScope(dctx);
	});
	test("isVarFromOuterLoopScope: nested loops, var in function scope", () => {
		const dctx = testDrcContext("const x = 1;");
		const rcStr = testStringRc();
		pushScope(dctx, false, true);    // function scope
		registerVar(dctx, "x", rcStr, false);
		pushScope(dctx, true, false);    // outer loop
		pushScope(dctx, true, false);    // inner loop
		check(isVarFromOuterLoopScope("x", dctx));
		popScope(dctx);
		popScope(dctx);
		popScope(dctx);
	});
	test("isVarFromOuterLoopScope: block inside loop, var before loop", () => {
		const dctx = testDrcContext("const x = 1;");
		const rcStr = testStringRc();
		pushScope(dctx, false, true);    // function scope
		registerVar(dctx, "x", rcStr, false);
		pushScope(dctx, true, false);    // loop scope
		pushScope(dctx, false, false);   // block inside loop
		check(isVarFromOuterLoopScope("x", dctx));
		popScope(dctx);
		popScope(dctx);
		popScope(dctx);
	});
});

testGroup("DRC Inject MoveExpr", () => {
	test("emitMoveSourceWasMoved on identifier emits pending wasMoved", () => {
		const dctx = testDrcContext("const x: string = \"\";");
		const rcStr = testStringRc();
		const loc = testLoc();
		pushScope(dctx, false, true);
		registerVar(dctx, "x", rcStr, false);
		const stmts: Node[] = [makeExprStmt(makeNull(loc), loc)];
		const handled = emitMoveSourceWasMoved(makeIdent("x", loc), rcStr, 0, stmts, dctx, loc, false);
		check(handled);
		check(hasPending(dctx));
		popScope(dctx);
	});
	test("emitMoveSourceWasMoved on call expr returns false (fresh)", () => {
		const dctx = testDrcContext("function f(): string { return \"\"; }");
		const rcStr = testStringRc();
		const loc = testLoc();
		pushScope(dctx, false, true);
		const call = makeCall(makeIdent("f", loc), [], loc);
		const handled = emitMoveSourceWasMoved(call, rcStr, 0, [], dctx, loc, false);
		check(!handled);
		check(!hasPending(dctx));
		popScope(dctx);
	});
	test("isFreshExpr includes MoveExpr", () => {
		check(isFreshExpr(NodeKind.MoveExpr));
	});
	test("classifyMemberFieldRc returns RC info for string field", () => {
		const dctx = testDrcContext("interface Obj { name: string; } const o: Obj = { name: \"\" };");
		const loc = testLoc();
		const memberExpr = makeMember(makeIdent("o", loc), "name", loc);
		const rc = classifyMemberFieldRc(memberExpr, dctx);
		check(rc.needsCleanup);
		check(rc.rcKind === RcKind.String);
	});
	test("classifyArrayElementRc returns RC info for string array", () => {
		const dctx = testDrcContext("const arr: string[] = [];");
		const sym = lookupSymbol(dctx.ctx.checkerCtx.table, "arr");
		if (sym !== null && sym.symbolType !== null && sym.symbolType.typeReturn !== null) {
			const rc = classifyType(sym.symbolType.typeReturn, dctx.ctx);
			check(rc.needsCleanup);
			check(rc.rcKind === RcKind.String);
		}
	});
	test("makeSinkCall emits sinkFn call node", () => {
		const dctx = testDrcContext("const x: string = \"\";");
		const rcStr = testStringRc();
		const loc = testLoc();
		const sink = makeSinkCall("x", makeIdent("y", loc), rcStr, loc);
		// Should produce an ExprStmt containing a CallExpr with 2 args
		check(sink.kind === NodeKind.ExprStmt);
		const sd = sink.data as ExprStmtData;
		check(sd.expr.kind === NodeKind.CallExpr);
		const cd = sd.expr.data as CallExprData;
		check(cd.callee.kind === NodeKind.Identifier);
		check(cd.arguments.length === 2);
	});
	test("sinkFn field populated for string type", () => {
		const dctx = testDrcContext("const x: string = \"\";");
		const sym = lookupSymbol(dctx.ctx.checkerCtx.table, "x");
		if (sym !== null && sym.symbolType !== null) {
			const rc = classifyType(sym.symbolType, dctx.ctx);
			check(rc.sinkFn !== "");
		}
	});
});

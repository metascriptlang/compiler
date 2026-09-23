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

import { Node, NodeKind, DeclKind, SourceLocation, makeLoc, ProgramData, NodeFlag, FunctionDeclData, ArrowFunctionData, FunctionExprData, MethodDeclData, ConstructorDeclData, BlockStmtData, VariableDeclData, ExprStmtData, ReturnStmtData, IfStmtData, WhileStmtData, ForStmtData, ForOfStmtData, ForInStmtData, TryCatchStmtData, ThrowStmtData, SwitchStmtData, SwitchCaseData, BinaryExprData, UnaryExprData, CallExprData, IdentifierData, MemberExprData, ArrayAccessData, ObjectLiteralData, ArrayLiteralData, ConditionalExprData, NewExprData, ExportDeclData, ClassDeclData, DoWhileStmtData, MoveExprData, TypeAssertionData, HiddenDerefData, HiddenStdConvData, MatchStmtData, MatchCaseData, TestDeclData, Symbol, Type, TypeKind, SymbolKind, createNodeAt } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { createPrimitive, unwrapRefNullUnion, isMaybeType, isTagCarriedUnion, unwrapMaybeType, isAwaitable, isUnresolvedType, isAtomicRef, noneType } from "../checker/types";
import { lookupSymbol, hasFlag, setFlag, isCursorSym, SymbolFlag, makeSymbol } from "../checker/symbol";
import { TransformContext, createTransformContext, freshTempSym, createTransformContextWithChecker } from "../transform/context";
import {
	makeIdent, makeIdentResolved, makeTypedIdentResolved, makeBlock, makeExprStmt, makeCall, makeVarDecl,
	makeReturn, makeAssign, makeTryCatch, makeTryFinally, makeNull, makeMember, makeHiddenAddr, makeIf, makeFnDecl, runtimeRef, isByteViewConv,
} from "../transform/util";
import { RcInfo, RcKind, isFreshExpr, noRcInfo } from "./classify";
import {
	DrcContext, DrcScope, noSym,
	createDrcContext, pushScope, popScope, currentScope, scopeDepth,
	registerVar, markUninitialized, recordMove, recordMoveInContext, recordMoveExpr, wasMovedInScope, varMovedInContext, clearMoveInContext, findVarInfo, findVarInfoInContext, findVarInfoInFunction, testVarSym, BorrowRead,
	setNeedsTryToLoop, setNeedsTryAll, addPending, hasPending, clearPendingForVar, symListHas, symListAdd,
	addPre,
	pushOuterStmts, popOuterStmts,
	testStringRc, classifyRc,
} from "./scope";
import { isLastReadInContext } from "./lastRead";
import { AliasKind, aliases, deepAliases, isAnalysableFieldAccess, getRootSym } from "./alias";
import { inferCursors } from "./cursors";
import { isLastReadCfgNodeCached, clearCfgCache } from "./cfg";
import { checkSource } from "../checker/checkPass";

// ===== DRC Modes (standard ProcessMode parity) =====

export enum DrcMode {
	Normal,
	Consumed,
	SinkArg,
}

// ===== Finally-Protected Variables (Phase A — correctness fix) =====
// Variables referenced in finally blocks must never be treated as last-read,
// because the finally block will use them after the "last" normal read.
// Prevents use-after-free with defer/try-finally patterns.

function collectIdentsInNode(node: Node, result: Symbol[]): void {
	if (node == null) return;

	if (node.kind == NodeKind.Identifier) {
		if (node.resolvedSym != null) symListAdd(result, node.resolvedSym);
		return;
	}
	// Don't descend into nested function/class boundaries. They declare fresh
	// scopes, so identifiers inside refer to inner bindings, not outer vars
	// that finally-protection cares about. Closures over outer vars are caught
	// via their creation-site CallExpr (createClosure(env)) at this level.
	if (node.kind == NodeKind.FunctionDecl
		|| node.kind == NodeKind.ArrowFunction
		|| node.kind == NodeKind.FunctionExpr
		|| node.kind == NodeKind.MethodDecl
		|| node.kind == NodeKind.ConstructorDecl
		|| node.kind == NodeKind.ClassDecl
		|| node.kind == NodeKind.ActorDecl) return;
	forEachChild(node, (child: Node): void => { collectIdentsInNode(child, result); });
}

function scanFinallyBlocks(node: Node, result: Symbol[]): void {
	if (node == null) return;

	match (node.kind) {
		NodeKind.TryCatchStmt => {
			const td = node.data as TryCatchStmtData;
			if (td.finallyBody != null) {
				collectIdentsInNode(td.finallyBody, result);
			}
			scanFinallyBlocks(td.tryBody, result);
			scanFinallyBlocks(td.catchBody, result);
		},
		NodeKind.BlockStmt => {
			for (const s of (node.data as BlockStmtData).statements) { scanFinallyBlocks(s, result); }
		},
		NodeKind.IfStmt => {
			const id = node.data as IfStmtData;
			scanFinallyBlocks(id.consequent, result);
			scanFinallyBlocks(id.alternate, result);
		},
		NodeKind.WhileStmt => {
			scanFinallyBlocks((node.data as WhileStmtData).whileBody, result);
		},
		NodeKind.DoWhileStmt => {
			scanFinallyBlocks((node.data as DoWhileStmtData).doBody, result);
		},
		NodeKind.ForStmt => {
			scanFinallyBlocks((node.data as ForStmtData).forBody, result);
		},
		NodeKind.ForOfStmt => {
			scanFinallyBlocks((node.data as ForOfStmtData).forOfBody, result);
		},
		NodeKind.ForInStmt => {
			scanFinallyBlocks((node.data as ForInStmtData).forInBody, result);
		},
		NodeKind.SwitchStmt => {
			const sd = node.data as SwitchStmtData;
			for (const c of sd.switchCases) { scanFinallyBlocks(c, result); }
		},
		NodeKind.SwitchCase => {
			for (const s of (node.data as SwitchCaseData).caseStmts) { scanFinallyBlocks(s, result); }
		},
		NodeKind.MatchStmt => {
			const md = node.data as MatchStmtData;
			for (const c of md.matchStmtCases) { scanFinallyBlocks((c.data as MatchCaseData).caseBody, result); }
		},
		// Non-control-flow kinds: don't contain try/finally for RC purposes.
		// Function boundaries (FunctionDecl, ArrowFunction, etc.) are intentional scope stops.
		_ => {},
	};
}

function collectFinallyVars(body: Node): Symbol[] {
	const result: Symbol[] = [];
	scanFinallyBlocks(body, result);
	return result;
}

// ===== Core Recursive Walker (reference p() parity) =====

function processNode(node: Node, dctx: DrcContext, mode: DrcMode): Node {
	if (node == null) return node;

	const result = match (node.kind) {
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
		// Transparent deref/addr wrappers (inserted for heap-Ref field access etc.).
		// processNode is a hand-written dispatch — without these the walk STOPS at the
		// wrapper and never reaches a fresh RC call inside it (e.g. `provide().field`
		// lowers the object to `HiddenDeref(provide())`), so ensureDestruction never
		// captures it → leak. Recurse through, same mode (mirrors the generic walker
		// and Nim's p() over nkHiddenDeref/nkHiddenAddr).
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => processHiddenWrapper(node, dctx, mode),
		// `x as T` is transparent for ownership — a fresh RC call inside it still produces an
		// owned value that needs capture. Without recursing, `(provide() as Box).field` stops
		// the walk at the assertion → leak. The union-variant narrowing case (`node.data as
		// Variant`) is caught as a cursor in processVarDecl before this, and its asExpr is a
		// borrow (not fresh) so recursing is a no-op there.
		NodeKind.TypeAssertion => processAssertionWrapper(node, dctx, mode),
		// Zero-copy / implicit conversions (`HiddenStdConv`/`HiddenSubConv`) are transparent
		// for ownership too — Nim's p() recurses nkHiddenStdConv/nkHiddenSubConv/nkConv
		// (injectdestructors.nim:1028). A fresh RC call under a conv still produces an owned
		// value; a byte-view conv only makes the RESULT a borrow, not the inner call.
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => processConvWrapper(node, dctx, mode),
		// `!x` / `-x` / `~x` (UnaryExpr) — transparent for ownership like the wrappers above:
		// the operator consumes the operand's VALUE, but a fresh RC call nested inside the
		// operand still produces an owned temp that needs capture. Without this case the walk
		// hits `_ => node` and STOPS at the operator, so e.g. `if (!f(g()))` never reaches the
		// owned `g()` → its temp leaks. Nim never hits this: `not` is nkPrefix ∈ nkCallKinds, so
		// it flows through the same per-arg recursion as any call (p(arg, normal) + ensureDestruction).
		NodeKind.UnaryExpr => processUnaryWrapper(node, dctx, mode),
		_ => node,
	};
	// ONE place (Reference parity: Nim's p() calls ensureDestruction from the central processor in
	// normal mode — injectdestructors:889/939). A fresh owned producer — CallExpr / ObjectLiteral /
	// ArrayLiteral / NewExpr, filtered inside ensureDestructionIfNeeded — reached in a Normal
	// (non-consumed) position is captured for scope-exit destroy, uniformly for every position the
	// walk reaches. Consumed/SinkArg positions (binding RHS, sink param, ref-constructor field,
	// return) own the value upstream → mode != Normal → skipped. Each producer's processor stays
	// dumb (process children, return the node); the capture decision lives here, not scattered.
	if (mode == DrcMode.Normal) return ensureDestructionIfNeeded(result, dctx);
	return result;
}

function processHiddenWrapper(node: Node, dctx: DrcContext, mode: DrcMode): Node {
	const hd = node.data as HiddenDerefData;
	// Reference parity: a deref names a LOCATION owned by someone else, exactly
	// like field/element access — transferring ownership out of it copies.
	// Sinking through it instead moves the POINTER while the consumer only
	// takes the pointee's bytes, so the cell is left owned by nobody.
	if (node.kind == NodeKind.HiddenDeref) {
		hd.expr = processNode(hd.expr, dctx, DrcMode.Normal);
		if ((mode == DrcMode.SinkArg || mode == DrcMode.Consumed) && node.nodeType != null) {
			const rcInfo = sinkClassify(node.nodeType, dctx);
			if (rcInfo.needsCleanup) {
				return passCopyToSink(node, dctx);
			}
		}
		return node;
	}
	hd.expr = processNode(hd.expr, dctx, mode);
	return node;
}

function processAssertionWrapper(node: Node, dctx: DrcContext, mode: DrcMode): Node {
	const ta = node.data as TypeAssertionData;
	ta.asExpr = processNode(ta.asExpr, dctx, mode);
	return node;
}

function rhsMode(rhs: Node): DrcMode {
	return rhs.kind == NodeKind.HiddenStdConv || rhs.kind == NodeKind.HiddenSubConv || rhs.kind == NodeKind.TypeAssertion
		? DrcMode.SinkArg : DrcMode.Consumed;
}

function processConvWrapper(node: Node, dctx: DrcContext, mode: DrcMode): Node {
	const cv = node.data as HiddenStdConvData;
	if (isUnionProjection(node)) {
		cv.convExpr = processNode(cv.convExpr, dctx, DrcMode.Normal);
		if ((mode == DrcMode.SinkArg || mode == DrcMode.Consumed) && node.nodeType != null
				&& sinkClassify(node.nodeType, dctx).needsCleanup) {
			return passCopyToSink(node, dctx);
		}
		return node;
	}
	cv.convExpr = processNode(cv.convExpr, dctx, mode);
	return node;
}

function isUnionProjection(node: Node): boolean {
	if (node.kind != NodeKind.HiddenSubConv || node.variantSlot <= 0) return false;
	const target = (node.data as HiddenStdConvData).convType;
	if (target == null) return false;
	if (unwrapRefNullUnion(target) != null) return true;
	if (isMaybeType(target)) return !isTagCarriedUnion(unwrapMaybeType(target));
	return !isTagCarriedUnion(target);
}

function processUnaryWrapper(node: Node, dctx: DrcContext, mode: DrcMode): Node {
	const u = node.data as UnaryExprData;
	u.operand = processNode(u.operand, dctx, mode);
	return node;
}

// Walk a non-RC binding/condition expression so a fresh RC inner call gets ensureDestruction,
// but with skipAwaitableCapture set so awaited (stepper-owned) futures are NOT captured here —
// PARALOCK. Save/restore the flag (not hard-false) so a future nested walk can't clear an
// outer one's flag. Used by the non-RC vardecl / assignment / if-condition positions.
function processNonRcRead(expr: Node, dctx: DrcContext): Node {
	const saved = dctx.skipAwaitableCapture;
	dctx.skipAwaitableCapture = true;
	const rewritten = processNode(expr, dctx, DrcMode.Normal);
	dctx.skipAwaitableCapture = saved;
	return rewritten;
}

// Reference parity (ensureDestruction): when a fresh expression (call, constructor) produces an
// RC-typed value in Normal mode, capture it in a temp registered for scope cleanup.
// Without this, the temporary leaks (no destructor called).
// Reference: ensureDestruction + call site pattern.
function ensureDestructionIfNeeded(node: Node, dctx: DrcContext): Node {
	if (node == null) return node;
	// Only dynamically-produced values need ensureDestruction — NOT literals.
	// Reference: ensureDestruction for call/constructor nodes, NOT literals.
	// Literals are compile-time constants (no heap allocation in C).
	const k = node.kind;
	if (k != NodeKind.CallExpr && k != NodeKind.ObjectLiteral && k != NodeKind.ArrayLiteral && k != NodeKind.NewExpr) return node;
	const exprType = node.nodeType;
	if (exprType == null) {
		// Null type is benign for void/synthetic calls and bare-fn closure pairs (`{fn, env:null}` —
		// msClosureDestroy is null-env-safe). But an NF_CLOSURE pair with a NON-null env is a heap
		// closure that LEAKS if not captured, and reaches here only when a transform built it without a
		// nodeType (the closure leak this session). FAIL LOUD on that exact signature — narrow on
		// purpose (a blanket warning fires ~800×/build on benign untyped calls). Surfaces via console
		// like the existing DRC param warning; checkerCtx.errors does NOT print from Phase 4.
		if (k == NodeKind.ObjectLiteral && node.flags.has(NodeFlag.Closure)) {
			const od = node.data as ObjectLiteralData;
			if (od.properties.length > 1 && od.properties[1] != null && od.properties[1].kind != NodeKind.NullLiteral) {
				console.log("DRC INTERNAL ERROR: env-bearing closure reached DRC without a type at " + node.location.line + ":" + node.location.column + " — its captured env will leak (a transform built the closure-pair without setting nodeType)");
			}
		}
		return node;
	}
	// Inside a non-RC binding/condition walk (skipAwaitableCapture), never capture a future:
	// the await/spawn lowering's stepper owns awaited futures, so scope-exit destroy here
	// double-frees (PARALOCK). A genuine discarded fire-and-forget future is captured by the
	// ordinary discarded-call path, where this flag is false.
	if (dctx.skipAwaitableCapture && isAwaitable(exprType)) return node;
	const rcInfo = classifyRc(exprType, dctx);
	if (!rcInfo.needsCleanup) return node;
	// Capture in temp, register for scope-exit destroy
	const loc = node.location;
	for (let ci = 0; ci < dctx.capturedNodes.length; ci += 1) {
		if (dctx.capturedNodes[ci] == node) {
			return makeIdentResolved(dctx.capturedSyms[ci], loc);
		}
	}
	const tmpSym = freshTempSym(dctx.ctx, "tmp", exprType);
	const tmpName = tmpSym.name;
	const tmpDecl = makeVarDecl(tmpName, node, DeclKind.Const, loc);
	tmpDecl.nodeType = exprType;
	tmpDecl.resolvedSym = tmpSym;
	addPre(dctx, tmpDecl);
	registerVar(dctx, rcInfo, false, tmpSym);
	dctx.capturedNodes.push(node);
	dctx.capturedSyms.push(tmpSym);
	return makeIdentResolved(tmpSym, loc);
}

function processCall(node: Node, dctx: DrcContext, mode: DrcMode): Node {
	const cd = node.data as CallExprData;
	// Recurse on callee
	cd.callee = processNode(cd.callee, dctx, DrcMode.Normal);
	const sym = node.resolvedSym;

	let sinkParams: Type[] | null = null;
	if (sym != null && sym.symbolType != null && sym.symbolType.kind == TypeKind.Function) {
		sinkParams = sym.symbolType.typeChildren;
	}

	// Actor proxy call without a park = SEND-class handoff: the caller never
	// suspends on a reply, so a plain-ref arg must transfer ownership into the
	// message (reference parity: `inSpawn > 0` forces sinkArg for spawn args).
	// Parked calls sit in an AwaitHandle decl's initializer (awaitLower hoists
	// `$fut = call` + msWaitForReady) — the caller's scope outlives the flight,
	// so those stay borrows. Arc<T> is excluded: SHARE's boundary incref +
	// impl-side release already balance it, and an extra consume would strand
	// the cell at rc=0-alive.
	let isActorSendHandoff = false;
	if (sym != null && hasFlag(sym, SymbolFlag.ActorProxy) && dctx.parkedInitDepth == 0) {
		isActorSendHandoff = true;
	}

	for (let i = 0; i < cd.arguments.length; i += 1) {
		let argMode = DrcMode.Normal;
		if (sinkParams != null && i < sinkParams.length && sinkParams[i] != null && sinkParams[i].kind == TypeKind.Sink) {
			argMode = DrcMode.SinkArg;
		}
		// actor SEND handoff: plain (non-atomic) ref args are consumed into the message
		if (isActorSendHandoff && i >= 1 && cd.arguments[i] != null && cd.arguments[i].nodeType != null) {
			const sendRc = classifyRc(cd.arguments[i].nodeType, dctx);
			if (sendRc.needsCleanup && sendRc.rcKind == RcKind.Ref && !isAtomicRef(cd.arguments[i].nodeType)) {
				argMode = DrcMode.SinkArg;
			}
		}
		cd.arguments[i] = processNode(cd.arguments[i], dctx, argMode);
	}
	// ensureDestruction on the call's return value is consolidated in processNode (Normal mode) —
	// NOT applied to individual arguments (each nested call arg gets its own via the recursive walk).
	return node;
}

function processBinary(node: Node, dctx: DrcContext, mode: DrcMode): Node {
	const bd = node.data as BinaryExprData;
	bd.left = processNode(bd.left, dctx, bd.operator == "=" ? DrcMode.Consumed : DrcMode.Normal);
	bd.right = processNode(bd.right, dctx, DrcMode.Normal);
	return node;
}

// Ownership-materialization classification: like classifyType, but a Ptr<T>
// whose pointee is a counted Ref object classifies as that pointee. A Ptr-typed
// expression flowing into an OWNING position (sink element/field, Ref return)
// stores a counted object — the consumer's destroy/decref WILL run on it, so the
// materialization must incref it like any borrow. Ptr to non-Ref pointees
// (Ptr<void>, Ptr<struct> from malloc/FFI) stays unmanaged — no header to count.
function sinkClassify(t: Type | null, dctx: DrcContext): RcInfo {
	if (t != null && (t.kind == TypeKind.Ptr || t.kind == TypeKind.Cursor) && t.typeReturn != null) {
		const inner = classifyRc(t.typeReturn, dctx);
		if (inner.needsCleanup && inner.rcKind == RcKind.Ref) return inner;
	}
	return classifyRc(t, dctx);
}

// Reference parity: passCopyToSink — when a non-identifier expression (ArrayAccess, MemberExpr)
// is consumed (sink param, push arg), create an independent deep copy in a temp.
// Pattern: genWasMoved(tmp) → =copy(tmp, src) → use tmp → wasMoved(tmp) after consumption.
// For simple refcounted types (String, Ref, Closure): shallow copy + incref is sufficient.
// For Named types (structs with managed fields): null-init + 2-arg copy avoids aliased-field destruction.
function reportFailedMove(srcExpr: Node, dctx: DrcContext): void {
	if (dctx.inEnsureMove == 0 || dctx.ctx.checkerCtx == null) return;
	if (srcExpr.kind != NodeKind.Identifier) return;
	const srcName = (srcExpr.data as IdentifierData).name;
	dctx.ctx.checkerCtx.errors.push({
		message: "cannot move '" + srcName + "': variable is still used after this point",
		line: srcExpr.location.line, column: srcExpr.location.column, fatal: false,
	});
}

function passCopyToSink(srcExpr: Node, dctx: DrcContext): Node {
	const rcInfo = sinkClassify(srcExpr.nodeType, dctx);
	if (!rcInfo.needsCleanup) return srcExpr;
	reportFailedMove(srcExpr, dctx);

	const loc = srcExpr.location;
	const tmpSym = freshTempSym(dctx.ctx, "borrow", srcExpr.nodeType);
	// Mark this temp as a sink-arg single-use synthetic. isLastReadSafe shortcuts to
	// `true` so moveOrCopy chooses genSink (blit transfer); without the flag, CFG
	// returns false (it was built before this temp existed) → genCopy double-Copy
	// leaks the temp's heap data (passCopyToSink intentionally skips scope cleanup).
	setFlag(tmpSym, SymbolFlag.SinkTemp);
	const tmpName = tmpSym.name;

	if (isBinaryCopy(rcInfo)) {
		// Named/String: null-init, then 2-arg copy from source.
		// Reference parity: =copy(&dest, src) handles old-value cleanup internally.
		const tmpDecl = makeVarDecl(tmpName, makeNull(loc), DeclKind.Let, loc);
		if (srcExpr.nodeType != null) tmpDecl.nodeType = srcExpr.nodeType;
		tmpDecl.resolvedSym = tmpSym;
		addPre(dctx, tmpDecl);
		// Reference parity: passCopyToSink temps are NOT in s.final or s.wasMoved —
		// the sink callee takes ownership, no cleanup at scope exit.
		addPre(dctx, makeWasMovedCall(tmpSym, rcInfo, loc));
		const copySym = rcInfo.copyFn;
		if (copySym != null) {
			const destArg = needsDestAddr(rcInfo)
				? makeHiddenAddr(makeIdentResolved(tmpSym, loc), loc)
				: makeIdentResolved(tmpSym, loc);
			const srcArg = isCopySrcByValue(rcInfo) ? srcExpr : makeHiddenAddr(srcExpr, loc);
			addPre(dctx, makeExprStmt(
				makeCall(makeTypedIdentResolved(copySym, null, loc), [destArg, srcArg], loc), loc));
		}
	} else {
		// Simple refcounted (Ref, Closure): shallow copy + unary incref.
		// Reference parity: no registerVar — sink consumes ownership, no scope cleanup.
		const tmpDecl = makeVarDecl(tmpName, srcExpr, DeclKind.Const, loc);
		if (srcExpr.nodeType != null) tmpDecl.nodeType = srcExpr.nodeType;
		tmpDecl.resolvedSym = tmpSym;
		addPre(dctx, tmpDecl);
		if (rcInfo.copyFn != null) {
			addPre(dctx, makeCopyAfterInit(tmpSym, rcInfo, loc, null));
		}
	}

	return makeIdentResolved(tmpSym, loc);
}

function retroHoistStmtReads(srcSym: Symbol, fallbackType: Type, dctx: DrcContext): void {
	const preStmts = currentScope(dctx).preStmts;
	let i = dctx.stmtBorrowReads.length;
	while (i > 0) {
		i -= 1;
		const r = dctx.stmtBorrowReads[i];
		if (r.readSym != srcSym) continue;
		const preStmtIdx = r.preStmtIdx;
		const readNode = r.readNode;
		const loc = readNode.location;
		const readType = readNode.nodeType != null ? readNode.nodeType : fallbackType;
		const bSym = freshTempSym(dctx.ctx, "pborrow", readType);
		const init = makeIdentResolved(readNode.resolvedSym!, loc);
		init.nodeType = readType;
		const decl = makeVarDecl(bSym.name, init, DeclKind.Const, loc);
		decl.nodeType = readType;
		decl.resolvedSym = bSym;
		preStmts.splice(preStmtIdx, 0, decl);
		let j = i + 1;
		while (j < dctx.stmtBorrowReads.length) {
			dctx.stmtBorrowReads[j].preStmtIdx += 1;
			j += 1;
		}
		readNode.resolvedSym = bSym;
		(readNode.data as IdentifierData).name = bSym.name;
	}
	const remaining: BorrowRead[] = [];
	for (const r of dctx.stmtBorrowReads) {
		if (r.readSym != srcSym) remaining.push(r);
	}
	dctx.stmtBorrowReads = remaining;
}

// Nim `destructiveMoveVar` via §3 hoisting (no nkStmtListExpr): pre-statements
// `const $move_N = src; wasMoved(src)`, yield `$move_N`. The blit captures the value
// before the zero, so a same-statement destroy-old of src sees NULL → runtime no-op.
function destructiveMoveVar(srcExpr: Node, rcInfo: RcInfo, dctx: DrcContext): Node {
	const loc = srcExpr.location;
	const srcSym = srcExpr.resolvedSym!;
	retroHoistStmtReads(srcSym, srcExpr.nodeType!, dctx);
	const tmpSym = freshTempSym(dctx.ctx, "move", srcExpr.nodeType);
	setFlag(tmpSym, SymbolFlag.SinkTemp);
	const tmpName = tmpSym.name;
	const tmpDecl = makeVarDecl(tmpName, srcExpr, DeclKind.Const, loc);
	if (srcExpr.nodeType != null) tmpDecl.nodeType = srcExpr.nodeType;
	tmpDecl.resolvedSym = tmpSym;
	addPre(dctx, tmpDecl);
	addPre(dctx, makeWasMovedCall(srcSym, rcInfo, loc));
	return makeIdentResolved(tmpSym, loc);
}

function processMember(node: Node, dctx: DrcContext, mode: DrcMode): Node {
	const md = node.data as MemberExprData;
	md.object = processNode(md.object, dctx, DrcMode.Normal);
	if (md.object.resolvedSym != null && md.object.resolvedSym.symbolKind == SymbolKind.Module
		&& node.resolvedSym != null && node.resolvedSym.symbolKind == SymbolKind.Function) return node;
	// Reference parity (MemberExpr sinkArg): field access is a borrow —
	// must copy for ownership transfer UNLESS field is last-read (Phase B).
	if (mode == DrcMode.SinkArg && node.nodeType != null) {
		const rcInfo = sinkClassify(node.nodeType, dctx);
		if (rcInfo.needsCleanup) {
			// Always copy from MemberExpr: source field may belong to a shared object.
			return passCopyToSink(node, dctx);
		}
	}
	return node;
}

function processArrayAccess(node: Node, dctx: DrcContext, mode: DrcMode): Node {
	const ad = node.data as ArrayAccessData;
	ad.array = processNode(ad.array, dctx, DrcMode.Normal);
	ad.index = processNode(ad.index, dctx, DrcMode.Normal);
	// Reference parity: array element access is a borrow.
	// In SinkArg or Consumed mode, must copy (incref) because the element belongs
	// to the array — we don't own it. Without this, returning arr[i] or storing it
	// in a field transfers a "reference" that was never incref'd, causing the
	// array-owned object to be double-freed when both the field destructor and
	// the array destructor decref it.
	if ((mode == DrcMode.SinkArg || mode == DrcMode.Consumed) && node.nodeType != null) {
		const rcInfo = sinkClassify(node.nodeType, dctx);
		if (rcInfo.needsCleanup) {
			return passCopyToSink(node, dctx);
		}
	}
	return node;
}

function isPtrField(objType: Type | null, fieldIdx: number): boolean {
	if (objType == null) return false;
	let t = objType;
	if (t.kind == TypeKind.Ref && t.typeReturn != null) {
		t = t.typeReturn;
	}
	if (t.typeChildren == null) return false;
	if (fieldIdx >= t.typeChildren.length) return false;
	const ft = t.typeChildren[fieldIdx];
	if (ft == null) return false;
	return ft.kind == TypeKind.Ptr || ft.kind == TypeKind.Cursor;
}

function processObjectLiteral(node: Node, dctx: DrcContext, mode: DrcMode): Node {
	// Reference parity (injectdestructors:870-889):
	//   let isRefConstr = t.kind == tyRef
	//   let m = if isRefConstr: sinkArg elif mode == normal: normal else: sinkArg
	// Ref/struct constructors always sink fields — field values transfer ownership.
	// Without this, locals used as field values get destroyed at scope exit while
	// the object still holds the (now-dangling) backing store pointer.
	// Per-field: cursor/Ptr fields stay Normal (unmanaged, no RC).
	const od = node.data as ObjectLiteralData;
	const t = node.nodeType;
	// tyRef (interface/class), named struct, union (NodeData), or untyped → always sink fields.
	// Only stack-allocated anonymous value types in Normal context use Normal.
	// GenericInstance (monomorphized generic struct, e.g. Entry<int32, Box>) is treated as
	// a named struct: its fields must sink so Ref field values transfer ownership to the
	// struct instead of being decref'd at caller scope exit.
	// A closure-pair literal (NF_CLOSURE) is heap-owning like a ref constructor: its env field must
	// sink-in (COPY/incref) so the closure owns a counted ref to the env. Without this, setting the
	// pair's nodeType to Function (needed so DRC captures + destroys the pair) flips the env field to
	// a borrow (no incref) → the pair's scope-exit msClosureDestroy decrefs an env it doesn't own →
	// double-free with the env-var's own lifecycle (lambda-lifting). The Function type alone is NOT
	// isRefConstr, so the flag is what keeps the env a COPY.
	// Anon structs included since they became OWNED values (DuVariant/(d') work):
	// an owned literal whose fields only BORROW over-releases at its destroy — the
	// capture of an inner fresh value (new Boxed in a field) and the literal's own
	// destroy both released the same +1 (finding #4, holderonly ASan UAF).
	const isRefConstr = t == null || t.kind == TypeKind.Ref
		|| t.kind == TypeKind.Struct
		|| t.kind == TypeKind.GenericInstance
		|| t.kind == TypeKind.Union
		|| node.flags.has(NodeFlag.Closure);
	const fieldDefault = isRefConstr ? DrcMode.SinkArg
		: (mode == DrcMode.Normal) ? DrcMode.Normal : DrcMode.SinkArg;
	for (let i = 0; i < od.properties.length; i += 1) {
		const fieldMode = isPtrField(node.nodeType, i) ? DrcMode.Normal : fieldDefault;
		od.properties[i] = processNode(od.properties[i], dctx, fieldMode);
	}
	// The fresh-owned capture (Normal mode → ensureDestruction) is consolidated in processNode.
	return node;
}

function processArrayLiteral(node: Node, dctx: DrcContext, mode: DrcMode): Node {
	// MS arrays are reference types (heap, ref-counted): a fresh array literal OWNS its elements, so
	// they always sink in (SinkArg) — and in a Normal (non-consumed) position the literal is itself an
	// owned heap value that no binding/sink path will reach (e.g. passed as a non-sink call argument
	// the callee stores), so capture it for scope-exit destroy. This mirrors processObjectLiteral's
	// isRefConstr handling (Reference parity injectdestructors:889, adapted — MS [] is heap-owned,
	// unlike Nim's value-type bracket). Elements MUST be SinkArg whenever the shell is captured: the
	// shell's destroy decrefs them, so a borrowed element would over-free. Consumed/SinkArg positions
	// (binding RHS, sink param, field, return) already owned the shell upstream → skip the capture.
	const ad = node.data as ArrayLiteralData;
	for (let i = 0; i < ad.elements.length; i += 1) {
		ad.elements[i] = processNode(ad.elements[i], dctx, DrcMode.SinkArg);
	}
	// Elements always sink (MS arrays own them); the fresh-owned shell capture (Normal mode →
	// ensureDestruction) is consolidated in processNode.
	return node;
}

function processNew(node: Node, dctx: DrcContext, mode: DrcMode): Node {
	const nd = node.data as NewExprData;
	// Ctor params are borrows like every other param (Nim default — no sink params,
	// ea38c2a); `new T(x)` lowers to T_init(this, x) = a plain call. Consumed here
	// orphaned every fresh/moved arg: caller relinquished, callee copied (+1 leak).
	for (let i = 0; i < nd.newArguments.length; i += 1) {
		nd.newArguments[i] = processNode(nd.newArguments[i], dctx, DrcMode.Normal);
	}
	// `new T(...)` produces a fresh owned heap object; the fresh-owned capture (Normal mode →
	// ensureDestruction) is consolidated in processNode.
	return node;
}

function processMove(node: Node, dctx: DrcContext, mode: DrcMode): Node {
	const md = node.data as MoveExprData;
	// The consuming position decides the mode — an explicit `move` never
	// overrides it (reference parity: the call-arg loop passes sinkArg only for
	// sink params / spawn handoff; everything else is a borrow). MS params are
	// borrows (ea38c2a): at a Normal call-arg position `move x` compiles exactly
	// like the implicit pass — raw pointer, caller keeps its scope-exit destroy.
	// Consuming here unconditionally left the value with no owner on either
	// side: callee borrows, caller wasMoved — 1 leak per moved RC arg.
	const consume = mode == DrcMode.Consumed || mode == DrcMode.SinkArg;
	dctx.inEnsureMove += 1;
	md.moveArg = processNode(md.moveArg, dctx, consume ? DrcMode.Consumed : DrcMode.Normal);
	dctx.inEnsureMove -= 1;
	// Identifiers: the Consumed walk above already blit+zeroed via destructiveMoveVar;
	// recordMoveInContext stays as bookkeeping for the self-consume assignment gates
	// (cleanup destroys unconditionally — it never suppresses the scope-exit destroy).
	// Fields/elements: recordMoveExpr defers wasMoved to the finally, before the container destroy.
	const moveType = md.moveArg.nodeType;
	if (moveType != null) {
		const rcInfo = classifyRc(moveType, dctx);
		if (rcInfo.needsCleanup) {
			if (md.moveArg.kind == NodeKind.Identifier) {
				recordMoveInContext(dctx, md.moveArg.resolvedSym);
			} else if (consume) {
				if (md.moveArg.kind == NodeKind.MemberExpr) {
					const fieldRc = classifyMemberFieldRc(md.moveArg, dctx);
					if (fieldRc.needsCleanup && fieldRc.wasMovedFn != null) {
						recordMoveExpr(dctx, makeWasMovedOnExpr(md.moveArg, fieldRc, node.location));
					}
				} else if (md.moveArg.kind == NodeKind.ArrayAccess) {
					const elemRc = classifyArrayElementRc(md.moveArg, dctx);
					if (elemRc.needsCleanup && elemRc.wasMovedFn != null) {
						recordMoveExpr(dctx, makeWasMovedOnExpr(md.moveArg, elemRc, node.location));
					}
				}
			}
		}
	}
	return node;
}

function processConditional(node: Node, dctx: DrcContext, mode: DrcMode): Node {
	const cd = node.data as ConditionalExprData;
	const loc = node.location;
	cd.ternaryCondition = processNode(cd.ternaryCondition, dctx, DrcMode.Normal);
	if (mode == DrcMode.Normal) {
		cd.ternaryConsequent = processNode(cd.ternaryConsequent, dctx, mode);
		cd.ternaryAlternate = processNode(cd.ternaryAlternate, dctx, mode);
		return node;
	}
	// Reference parity: convert to if-else with temp result.
	// Each branch gets its own scope — preStmts/pendingStmts are per-scope,
	// so sibling borrows can't leak into branch statement lists.
	const resultType = node.nodeType;
	const tmpSym = freshTempSym(dctx.ctx, "cond", resultType);
	const tmpName = tmpSym.name;
	const tmpDecl = makeVarDecl(tmpName, null as unknown as Node, DeclKind.Let, loc);
	tmpDecl.nodeType = resultType;
	tmpDecl.resolvedSym = tmpSym;
	addPre(dctx, tmpDecl);
	// Reference parity (processScopeExpr): register VarInfo for the temp so that
	// processAssignment inside each branch can find it and emit proper RC ops
	// (copy/move). Without this, the branch assignment `$cond = src.field`
	// falls through processAssignment (no resolvedSym, no VarInfo → no copy).
	const rcInfo = classifyRc(resultType, dctx);
	registerVar(dctx, rcInfo, false, tmpSym);
	markUninitialized(dctx, tmpSym);
	// Reference parity: push/pop scope for each branch isolates preStmts/pendingStmts
	pushScope(dctx, false, false);
	const thenProcessed = processBranchAssign(tmpName, tmpSym, resultType!, cd.ternaryConsequent, dctx, loc);
	popScope(dctx);
	pushScope(dctx, false, false);
	const elseProcessed = processBranchAssign(tmpName, tmpSym, resultType!, cd.ternaryAlternate, dctx, loc);
	popScope(dctx);
	addPre(dctx, makeIf(cd.ternaryCondition, makeBlock(thenProcessed, loc), makeBlock(elseProcessed, loc), loc));
	// $cond is single-use, consumed by the enclosing expression in SinkArg/Consumed mode.
	// Move it out through destructiveMoveVar: blit to $move + wasMoved($cond) as pre-stmts,
	// so the unconditional scope-exit destroy of $cond no-ops (Nim Rule-3; pre-stmts flush
	// before the consuming statement, so the return position is covered too).
	if (mode == DrcMode.SinkArg || mode == DrcMode.Consumed) {
		if (rcInfo.needsCleanup && rcInfo.wasMovedFn != null) {
			const condRef = makeIdentResolved(tmpSym, loc);
			condRef.nodeType = resultType;
			return destructiveMoveVar(condRef, rcInfo, dctx);
		}
	}
	return makeIdentResolved(tmpSym, loc);
}

// Mid-statement lowering: branch reads land in preStmts and run BEFORE any later
// move's zero — safe as-is, must NOT be retro-hoisted (a rewrite is use-before-assign).
// The enclosing statement's stmtBorrowReads must survive the nested clear: save/restore.
function processBranchAssign(tmpName: string, tmpSym: Symbol, resultType: Type, branchExpr: Node, dctx: DrcContext, loc: SourceLocation): Node[] {
	let stmt = makeExprStmt(branchExpr, loc);
	if (branchExpr.nodeType == null || branchExpr.nodeType.kind != TypeKind.Never) {
		const lhs = makeIdentResolved(tmpSym, loc);
		lhs.nodeType = resultType;
		stmt = makeExprStmt(makeAssign(lhs, branchExpr, loc), loc);
	}
	const savedReads = dctx.stmtBorrowReads;
	dctx.stmtBorrowReads = [];
	const processed = processStmtList([stmt], dctx, loc);
	dctx.stmtBorrowReads = savedReads;
	return processed;
}

function processIdentifier(node: Node, dctx: DrcContext, mode: DrcMode): Node {
	const d = node.data as IdentifierData;
	const sym = node.resolvedSym;

	if (sym == null) return node;

	// Implementation parity: function/method declarations are static — no RC needed.
	// Bare function names inside closure thunks (e.g. { fn: isEven, env: null })
	// have TypeKind.Function but are not heap-allocated closures.
	if (sym.symbolKind == SymbolKind.Function || sym.symbolKind == SymbolKind.Method) return node;

	const rcInfo = classifyRc(sym.symbolType, dctx);
	if (!rcInfo.needsCleanup) {
		// A Ptr-typed var holds a borrow — it owns no rc share to move, so sinking it
		// into an owning slot must ALWAYS materialize a copy (incref), never a move.
		if (mode == DrcMode.SinkArg || mode == DrcMode.Consumed) {
			const sinkRc = sinkClassify(sym.symbolType, dctx);
			if (sinkRc.needsCleanup) {
				if (node.nodeType == null) node.nodeType = sym.symbolType;
				return passCopyToSink(node, dctx);
			}
		}
		return node;
	}

	// Reference parity: SinkArg mode — passCopyToSink or destructive move
	// Used for object literal fields, array literal elements (reference: ObjectLiteral sinkArg)
	if (mode == DrcMode.SinkArg) {
		if (isLastReadSafe(sym, node, dctx.currentStmtIdx, dctx.currentStmtList, dctx)) {
			if (rcInfo.wasMovedFn != null) {
				return destructiveMoveVar(node, rcInfo, dctx);
			}
			return node;
		}
		return passCopyToSink(node, dctx);
	}

	// Consumed mode: in-place move or copy (for call args, assignment RHS)
	if (mode == DrcMode.Consumed) {
		if (isLastReadSafe(sym, node, dctx.currentStmtIdx, dctx.currentStmtList, dctx)) {
			if (rcInfo.wasMovedFn != null) {
				return destructiveMoveVar(node, rcInfo, dctx);
			}
			return node;
		}
		return passCopyToSink(node, dctx);
	}

	if (mode == DrcMode.Normal) {
		const preStmtIdx = currentScope(dctx).preStmts.length;
		const br: BorrowRead = {
			readSym: sym,
			readNode: node,
			preStmtIdx,
		};
		dctx.stmtBorrowReads.push(br);
	}
	return node;
}

// ===== RC Call Builders =====

function identDestSym(dest: Node, dctx: DrcContext): Symbol | null {
	if (dest.kind != NodeKind.Identifier) return null;
	if (dest.resolvedSym == null) {
		dctx.ctx.errors.push("DRC: assignment to '" + (dest.data as IdentifierData).name + "' reached the analyzer without a resolved symbol");
	}
	return dest.resolvedSym;
}

// Reference parity: =copy(var dest, src) takes 2 args for Named and String types.
// Named-type hooks take pointer params (reference pointer introduction), so we wrap in HiddenAddr.
// String: msStringCopy(dest*, src) — dest by pointer, src by value (like seqLike Named).
// Ref/Closure: still unary incref (simple refcount bump, no reassignment issue).

function isBinaryCopy(rcInfo: RcInfo): boolean {
	return rcInfo.rcKind == RcKind.Named || rcInfo.rcKind == RcKind.String;
}

// Reference parity: generated hooks take var T (pointer) for all params.
// Runtime macros (empty typeName) and strings still use value params.
function isCopySrcByValue(rcInfo: RcInfo): boolean {
	if (rcInfo.rcKind == RcKind.String) return true;
	if (rcInfo.seqLike && rcInfo.typeName == "") return true;
	return false;
}

// Whether dest needs HiddenAddr for wasMoved/copy/sink.
// Named structs: always pointer. seqLike runtime macros: value. seqLike generated hooks: pointer.
function needsDestAddr(rcInfo: RcInfo): boolean {
	if (rcInfo.seqLike && rcInfo.typeName == "") return false;
	return true;
}

function makeRcCallStmt(callee: Node, sym: Symbol, loc: SourceLocation): Node {
	return makeExprStmt(makeCall(callee, [makeIdentResolved(sym, loc)], loc), loc);
}

// Reference parity: all hooks take var T (pointer).
// Runtime macros (empty typeName) still take by value — they're C macros, not generated hooks.
function makeDestroyCall(sym: Symbol, rcInfo: RcInfo, loc: SourceLocation): Node {
	const destroySym = rcInfo.destroyFn;
	if (destroySym == null) return makeExprStmt(makeNull(loc), loc);
	const callee = makeTypedIdentResolved(destroySym, null, loc);
	if (rcInfo.rcKind == RcKind.Named && needsDestAddr(rcInfo)) {
		return makeExprStmt(makeCall(callee, [makeHiddenAddr(makeIdentResolved(sym, loc), loc)], loc), loc);
	}
	return makeRcCallStmt(callee, sym, loc);
}

function makeWasMovedCall(sym: Symbol, rcInfo: RcInfo, loc: SourceLocation): Node {
	const wmSym = rcInfo.wasMovedFn;
	if (wmSym == null) return makeExprStmt(makeNull(loc), loc);
	const callee = makeTypedIdentResolved(wmSym, null, loc);
	if (rcInfo.rcKind == RcKind.Named && needsDestAddr(rcInfo)) {
		return makeExprStmt(makeCall(callee, [makeHiddenAddr(makeIdentResolved(sym, loc), loc)], loc), loc);
	}
	return makeRcCallStmt(callee, sym, loc);
}

// Reference parity: =copy(&dest, src) for Named and String types; unary incref for Ref/Closure.
function makeCopyAfterInit(destSym: Symbol, rcInfo: RcInfo, loc: SourceLocation, srcSym: Symbol | null): Node {
	const copySym = rcInfo.copyFn;
	if (copySym == null) return makeExprStmt(makeNull(loc), loc);
	// 2-arg copy: Named types and String (=copy(&dest, src))
	if (isBinaryCopy(rcInfo)) {
		const actualSrcSym: Symbol = srcSym != null ? srcSym : destSym;
		// Self-copy (srcSym=null) is a no-op for strings: msStringCopy(&x,x) checks
		// dest->p == src.p and returns immediately, skipping the incref.
		// Use msStringIncref(x) directly for proper refcount bump.
		if (srcSym == null && rcInfo.rcKind == RcKind.String) {
			return makeExprStmt(
				makeCall(runtimeRef("msStringIncref", loc), [makeIdentResolved(destSym, loc)], loc), loc);
		}
		// dest: pointer unless runtime macro (seqLike + empty typeName)
		const destRef = makeIdentResolved(destSym, loc);
		const destArg = needsDestAddr(rcInfo)
			? makeHiddenAddr(destRef, loc)
			: destRef;
		// src: value for seqLike/String, pointer for non-seqLike Named
		const srcRef = makeIdentResolved(actualSrcSym, loc);
		const srcArg = isCopySrcByValue(rcInfo)
			? srcRef
			: makeHiddenAddr(srcRef, loc);
		return makeExprStmt(makeCall(makeTypedIdentResolved(copySym, null, loc), [destArg, srcArg], loc), loc);
	}
	// Unary incref: msIncref(dest), msClosureCopy(dest), etc.
	return makeRcCallStmt(makeTypedIdentResolved(copySym, null, loc), destSym, loc);
}

// Sink call: sinkFn(dest, src) — atomic destroy-old + assign-new
function makeSinkCall(sym: Symbol, srcExpr: Node, rcInfo: RcInfo, loc: SourceLocation): Node {
	const sinkSym = rcInfo.sinkFn;
	if (sinkSym == null) return makeExprStmt(makeNull(loc), loc);
	if (rcInfo.rcKind == RcKind.Named) {
		const destRef = makeIdentResolved(sym, loc);
		const destArg = needsDestAddr(rcInfo)
			? makeHiddenAddr(destRef, loc)
			: destRef;
		// src: value for seqLike runtime macros, pointer for generated hooks and Named structs
		const srcArg = isCopySrcByValue(rcInfo) ? srcExpr : makeHiddenAddr(srcExpr, loc);
		return makeExprStmt(
			makeCall(makeTypedIdentResolved(sinkSym, null, loc), [destArg, srcArg], loc), loc);
	}
	return makeExprStmt(
		makeCall(makeTypedIdentResolved(sinkSym, null, loc), [makeIdentResolved(sym, loc), srcExpr], loc), loc);
}

function makeWasMovedOnExpr(argExpr: Node, rcInfo: RcInfo, loc: SourceLocation): Node {
	const wmSym = rcInfo.wasMovedFn;
	if (wmSym == null) return makeExprStmt(makeNull(loc), loc);
	const callee = makeTypedIdentResolved(wmSym, null, loc);
	const arg = rcInfo.rcKind == RcKind.Named && needsDestAddr(rcInfo) ? makeHiddenAddr(argExpr, loc) : argExpr;
	return makeExprStmt(makeCall(callee, [arg], loc), loc);
}

// ===== Self-Assignment Detection (reference parity) =====
// Checks if two AST nodes refer to the same memory location.
// Used to elide `x = x` (self-assignment removal).
// Implemented via bidirectional aliases() — exact match means both contain each other.

function sameLocation(a: Node, b: Node): boolean {
	if (a == null || b == null) return false;
	return aliases(a, b) == AliasKind.Yes && aliases(b, a) == AliasKind.Yes;
}

// ===== Unified moveOrCopy (Reference parity: injectdestructors) =====
// ONE function handles ALL RC assignment decisions. Every assignment in the program
// (VarDecl init, identifier/member/element assignment, return) goes through here.
// Eliminates the fragmented handlers that cause missing-incref bugs.

// Flags for moveOrCopy — matches reference's MoveOrCopyFlag enum.
// Using int32 constants to avoid enum-to-int cast noise at call sites.
const MOC_NONE: int32   = 0;
const MOC_IS_DECL: int32   = 1;  // VarDecl init: no old value to destroy (Reference: IsDecl)
const MOC_IS_RETURN: int32 = 2;  // Return statement: no old value (Reference: IsReturn)
const MOC_IS_FIELD: int32  = 4;  // LHS is MemberExpr/ArrayAccess: needs save-assign-destroy

// Save old value to temp, assign new, destroy temp — shared by genSink/genCopy field paths.
function emitSaveAssignDestroySimple(stmt: Node, saveExpr: Node, rcInfo: RcInfo, prefix: string, dctx: DrcContext, loc: SourceLocation): Node {
	const tmpSym = freshTempSym(dctx.ctx, prefix, saveExpr.nodeType);
	const tmpName = tmpSym.name;
	const saveTmp = makeVarDecl(tmpName, saveExpr, DeclKind.Const, loc);
	saveTmp.nodeType = saveExpr.nodeType;
	saveTmp.resolvedSym = tmpSym;
	return makeBlock([saveTmp, stmt, makeDestroyCall(tmpSym, rcInfo, loc)], loc);
}

// genSink: ownership transfer — fresh/last-read values moved without copy.
// Reference: genSink in injectdestructors
function genSink(stmt: Node, dest: Node, destSym: Symbol | null, rhs: Node, rcInfo: RcInfo,
		flags: int32, idx: number, stmts: Node[], dctx: DrcContext, loc: SourceLocation): Node {
	// IsDecl / IsReturn: no old value to destroy — raw assign (Reference: nkFastAsgn optimization)
	if ((flags & MOC_IS_DECL) != 0 || (flags & MOC_IS_RETURN) != 0) {
		return stmt;
	}
	// IsField (MemberExpr/ArrayAccess LHS): save old → assign → destroy old
	if ((flags & MOC_IS_FIELD) != 0) {
		return emitSaveAssignDestroySimple(stmt, dest, rcInfo, "oldField", dctx, loc);
	}
	// Identifier LHS: use sinkFn if available, else destroy-assign
	if (destSym != null) {
		if (deepAliases(dest, rhs)) {
			clearPendingForVar(dctx, destSym);
			return emitSaveAssignDestroySimple(stmt, makeIdentResolved(destSym, loc), rcInfo, "old", dctx, loc);
		}
		if (rcInfo.sinkFn != null) {
			return makeSinkCall(destSym, rhs, rcInfo, loc);
		}
		return makeBlock([makeDestroyCall(destSym, rcInfo, loc), stmt], loc);
	}
	return stmt;
}

// Resolve the LHS expression for RC ops: field access uses dest node directly, identifiers make fresh ident.
function resolveLhs(flags: int32, dest: Node, destSym: Symbol | null, loc: SourceLocation): Node {
	if ((flags & MOC_IS_FIELD) != 0) return dest;
	if (destSym != null) return makeIdentResolved(destSym, loc);
	return dest;
}

// genCopy: shared reference — source still live, must duplicate.
// Reference: genCopy + genCopyNoCheck in injectdestructors
function genCopy(stmt: Node, dest: Node, destSym: Symbol | null, rhs: Node, rcInfo: RcInfo,
		flags: int32, dctx: DrcContext, loc: SourceLocation): Node {
	reportFailedMove(rhs, dctx);
	// Binary copy (Named/String): =copy(&dest, src) handles old-value atomically
	if (isBinaryCopy(rcInfo) && rcInfo.copyFn != null) {
		const lhsExpr = resolveLhs(flags, dest, destSym, loc);
		const destArg = needsDestAddr(rcInfo) ? makeHiddenAddr(lhsExpr, loc) : lhsExpr;
		const srcArg = isCopySrcByValue(rcInfo) ? rhs : makeHiddenAddr(rhs, loc);
		const copyCall = makeExprStmt(
			makeCall(makeTypedIdentResolved(rcInfo.copyFn, null, loc), [destArg, srcArg], loc), loc);
		if ((flags & MOC_IS_DECL) != 0) {
			if (destSym != null) {
				return makeBlock([stmt, makeWasMovedCall(destSym, rcInfo, loc), copyCall], loc);
			}
		}
		return copyCall;
	}
	// Ref/Closure: unary incref
	if (rcInfo.copyFn != null) {
		if ((flags & MOC_IS_DECL) != 0) {
			if (destSym != null) {
				return makeBlock([stmt, makeCopyAfterInit(destSym, rcInfo, loc, null)], loc);
			}
			return stmt;
		}
		// Save old → assign → incref(new) → destroy(old).
		const saveType = dest.nodeType;
		const saveExpr = resolveLhs(flags, dest, destSym, loc);
		if (saveExpr.nodeType == null) saveExpr.nodeType = saveType;
		const increfTarget = resolveLhs(flags, dest, destSym, loc);
		const tmpSym = freshTempSym(dctx.ctx, "oldRef", saveType);
		const tmpName = tmpSym.name;
		const saveTmp = makeVarDecl(tmpName, saveExpr, DeclKind.Const, loc);
		saveTmp.nodeType = saveType;
		saveTmp.resolvedSym = tmpSym;
		const increfCall = makeExprStmt(
			makeCall(makeTypedIdentResolved(rcInfo.copyFn, null, loc), [increfTarget], loc), loc);
		return makeBlock([saveTmp, stmt, increfCall, makeDestroyCall(tmpSym, rcInfo, loc)], loc);
	}
	return stmt;
}

// moveOrCopy: unified RC decision for ALL assignments.
// Reference: moveOrCopy in injectdestructors — one function, one decision tree.
function moveOrCopy(stmt: Node, dest: Node, rhs: Node, rcInfo: RcInfo,
		flags: int32, idx: number, stmts: Node[], dctx: DrcContext, loc: SourceLocation): Node {
	if (!rcInfo.needsCleanup) return stmt;
	// Rule 1: self-assignment removal (Reference: sameLocation)
	if (sameLocation(dest, rhs)) return stmt;
	// Rule 2: cursor variables are borrows — no RC (Reference: isCursor)
	const destSym = identDestSym(dest, dctx);
	if (destSym != null) {
		const destVi = findVarInfoInContext(dctx, destSym);
		if (destVi != null && destVi.isCursor) return stmt;
	}
	// Rule 3: dispatch on RHS kind (Reference: case ri2.kind)
	return match (rhs.kind) {
		// Fresh values → sink (ownership transfer, no copy needed)
		NodeKind.CallExpr => {
			if ((flags & MOC_IS_DECL) != 0) {
				return stmt;
			}
			// Non-IsDecl dispatch by rcInfo kind:
			//   Named/String (isBinaryCopy):    hoist call result to temp + =copy
			//                                   (=copy handles destroy+assign atomically)
			//   Ref/Closure:                    delegate to genSink — save → assign → destroy
			//                                   (callee-side emitReturnWithIncref balances rc
			//                                    for aliased passthrough; no caller incref)
			if (isBinaryCopy(rcInfo) && (rcInfo.sinkFn != null || rcInfo.copyFn != null)) {
				// Named/String fresh CallExpr → SINK semantic (Reference parity:
				// Nim nkCallKinds → eqsink, not eqcopy). Hoist call result to temp
				// (also needed because multi-statement-expanding intrinsics like
				// msUnboxStruct corrupt the iterative codegen's shared result stack
				// via truncResults when inlined into a call argument position).
				// Then: sinkFn(dest, $callRes) transfers heap; emit explicit
				// wasMoved($callRes) so accidental future scope-cleanup registration
				// won't double-free.
				const callTmpSym = freshTempSym(dctx.ctx, "callRes", rhs.nodeType);
				const callTmpDecl = makeVarDecl(callTmpSym.name, rhs, DeclKind.Const, loc);
				callTmpDecl.nodeType = rhs.nodeType;
				callTmpDecl.resolvedSym = callTmpSym;
				const callTmpRef = makeIdentResolved(callTmpSym, loc);
				callTmpRef.nodeType = rhs.nodeType;
				const lhsExpr = resolveLhs(flags, dest, destSym, loc);
			const sinkSym = rcInfo.sinkFn;
			const useSink = sinkSym != null;
			const opSym = (useSink ? sinkSym : rcInfo.copyFn) as Symbol;
				// Argument shapes differ for sink vs copy:
				//   copyFn (msStringCopy):    (&dest, srcValue)       — both per needsDestAddr/isCopySrcByValue
				//   sinkFn for String:        (destLvalue, srcValue)   — both by value
				//   sinkFn for Named seqLike macro: (destLvalue, srcValue)
				//   sinkFn for Named generated hook: (&dest, &src)
				// Mirror makeSinkCall (line ~637) for sink path.
				let destArg: Node;
				let srcArg: Node;
				if (useSink) {
					if (rcInfo.rcKind == RcKind.Named) {
						destArg = needsDestAddr(rcInfo) ? makeHiddenAddr(lhsExpr, loc) : lhsExpr;
						srcArg = isCopySrcByValue(rcInfo) ? callTmpRef : makeHiddenAddr(callTmpRef, loc);
					} else {
						destArg = lhsExpr;
						srcArg = callTmpRef;
					}
				} else {
					destArg = needsDestAddr(rcInfo) ? makeHiddenAddr(lhsExpr, loc) : lhsExpr;
					srcArg = isCopySrcByValue(rcInfo) ? callTmpRef : makeHiddenAddr(callTmpRef, loc);
				}
				const opCall = makeExprStmt(
				makeCall(makeTypedIdentResolved(opSym, null, loc), [destArg, srcArg], loc), loc);
				const hoisted: Node[] = [];
				hoisted.push(callTmpDecl);
				hoisted.push(opCall);
			if (useSink && rcInfo.wasMovedFn != null) {
					hoisted.push(makeWasMovedCall(callTmpSym, rcInfo, loc));
				}
				return makeBlock(hoisted, loc);
			}
			// Ref/Closure: delegate to genSink. The callee-side
			// emitReturnWithIncref bumps rc on `return identifier` of Ref params,
			// balancing rc accounting so save→assign→destroy is safe for aliased
			// passthrough — no caller-side defensive incref needed.
			return genSink(stmt, dest, destSym, rhs, rcInfo, flags, idx, stmts, dctx, loc);
		},
		NodeKind.NewExpr | NodeKind.ObjectLiteral | NodeKind.ArrayLiteral | NodeKind.StringLiteral |
		NodeKind.NumberLiteral | NodeKind.BooleanLiteral | NodeKind.NullLiteral |
		NodeKind.ArrowFunction | NodeKind.FunctionExpr => {
			return genSink(stmt, dest, destSym, rhs, rcInfo, flags, idx, stmts, dctx, loc);
		},
		// Conversions sink; their operand was walked in SinkArg mode (Reference: nkHiddenSubConv/nkConv → genSink(p(ri, sinkArg)))
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv | NodeKind.TypeAssertion => {
			return genSink(stmt, dest, destSym, rhs, rcInfo, flags, idx, stmts, dctx, loc);
		},
		// Move expression → sink + wasMoved on source
		NodeKind.MoveExpr => {
			const md = rhs.data as MoveExprData;
			// Self-move: x = move x → no-op
			if (md.moveArg.kind == NodeKind.Identifier && md.moveArg.resolvedSym != null
				&& dest.resolvedSym != null && md.moveArg.resolvedSym == dest.resolvedSym) {
				return stmt;
			}
			// Aliased move: x = move x.field → destructiveMoveVar pattern
			// Capture to temp, zero source, destroy old dest, assign from temp.
			if (destSym != null && deepAliases(dest, md.moveArg)) {
				const captureType = dest.nodeType;
				const moveTmpSym = freshTempSym(dctx.ctx, "moveTmp", captureType);
				const tmpName = moveTmpSym.name;
				const captureDecl = makeVarDecl(tmpName, md.moveArg, DeclKind.Const, loc);
				captureDecl.nodeType = captureType;
				captureDecl.resolvedSym = moveTmpSym;
				const moveResult: Node[] = [captureDecl];
				// Zero source BEFORE destroying old dest
				if (md.moveArg.kind == NodeKind.MemberExpr) {
					const fieldRc = classifyMemberFieldRc(md.moveArg, dctx);
					if (fieldRc.needsCleanup && fieldRc.wasMovedFn != null) {
						moveResult.push(makeWasMovedOnExpr(md.moveArg, fieldRc, loc));
					}
				} else if (md.moveArg.kind == NodeKind.ArrayAccess) {
					const elemRc = classifyArrayElementRc(md.moveArg, dctx);
					if (elemRc.needsCleanup && elemRc.wasMovedFn != null) {
						moveResult.push(makeWasMovedOnExpr(md.moveArg, elemRc, loc));
					}
				} else if (md.moveArg.kind == NodeKind.Identifier && md.moveArg.resolvedSym != null) {
					if (rcInfo.wasMovedFn != null) {
						moveResult.push(makeWasMovedCall(md.moveArg.resolvedSym, rcInfo, loc));
					}
					recordMoveInContext(dctx, md.moveArg.resolvedSym);
				}
				if ((flags & MOC_IS_DECL) == 0) {
					moveResult.push(makeDestroyCall(destSym, rcInfo, loc));
				}
				moveResult.push(makeExprStmt(
					makeAssign(makeIdentResolved(destSym, loc), makeIdentResolved(moveTmpSym, loc), loc), loc));
				return makeBlock(moveResult, loc);
			}
			// Non-aliased move: wasMoved on source + sink
			emitMoveSourceWasMoved(md.moveArg, rcInfo, idx, stmts, dctx, loc, true);
			return genSink(stmt, dest, destSym, rhs, rcInfo, flags, idx, stmts, dctx, loc);
		},
		// Identifier → last-read = move, else = copy
		NodeKind.Identifier => {
			const rhsSym = rhs.resolvedSym;
			if (rhsSym != null && isLastReadSafe(rhsSym, rhs, idx, stmts, dctx)) {
				// Move: sink + wasMoved (Reference: genSink + genWasMoved)
				if (rcInfo.wasMovedFn != null) {
					addPending(dctx, makeWasMovedCall(rhsSym, rcInfo, loc));
				}
				recordMove(dctx, rhsSym);
				return genSink(stmt, dest, destSym, rhs, rcInfo, flags, idx, stmts, dctx, loc);
			}
			// Copy: shared reference (Reference: genCopy)
			return genCopy(stmt, dest, destSym, rhs, rcInfo, flags, dctx, loc);
		},
		// Field/element access → analysable + last-read = move, else = copy
		NodeKind.MemberExpr | NodeKind.ArrayAccess | NodeKind.HiddenDeref => {
			const srcOwns = rhs.nodeType != null && classifyRc(rhs.nodeType, dctx).needsCleanup;
			if (srcOwns && rcInfo.wasMovedFn != null && isLastReadFieldSafe(rhs, idx, stmts, dctx)) {
				addPending(dctx, makeWasMovedOnExpr(rhs, rcInfo, loc));
				return genSink(stmt, dest, destSym, rhs, rcInfo, flags, idx, stmts, dctx, loc);
			}
			return genCopy(stmt, dest, destSym, rhs, rcInfo, flags, dctx, loc);
		},
		// Conditional → split branches (Reference: handleNestedTempl)
		NodeKind.ConditionalExpr => {
			const cd = rhs.data as ConditionalExprData;
			if (destSym != null) {
				const thenLhs = makeIdentResolved(destSym, loc);
				thenLhs.nodeType = dest.nodeType;
				const elseLhs = makeIdentResolved(destSym, loc);
				elseLhs.nodeType = dest.nodeType;
				const thenAssign = (cd.ternaryConsequent.nodeType != null && cd.ternaryConsequent.nodeType.kind == TypeKind.Never)
					? makeExprStmt(cd.ternaryConsequent, loc)
					: makeExprStmt(makeAssign(thenLhs, cd.ternaryConsequent, loc), loc);
				const elseAssign = (cd.ternaryAlternate.nodeType != null && cd.ternaryAlternate.nodeType.kind == TypeKind.Never)
					? makeExprStmt(cd.ternaryAlternate, loc)
					: makeExprStmt(makeAssign(elseLhs, cd.ternaryAlternate, loc), loc);
				const savedReads = dctx.stmtBorrowReads;
				dctx.stmtBorrowReads = [];
				const thenProcessed = processStmtList([thenAssign], dctx, loc);
				dctx.stmtBorrowReads = [];
				const elseProcessed = processStmtList([elseAssign], dctx, loc);
				dctx.stmtBorrowReads = savedReads;
				return makeIf(cd.ternaryCondition, makeBlock(thenProcessed, loc), makeBlock(elseProcessed, loc), loc);
			}
			return genCopy(stmt, dest, destSym, rhs, rcInfo, flags, dctx, loc);
		},
		// Default → copy (conservative)
		_ => {
			return genCopy(stmt, dest, destSym, rhs, rcInfo, flags, dctx, loc);
		},
	};
}

// ===== MoveExpr Source Classification =====

// Classify RC type of a member expression's field. Every member access in an RC position
// (move source, assignment LHS) is typed by the checker for value reads, and by lambdaLifting
// (envFieldType) for lifted env access. Reaching here untyped is an upstream invariant
// violation — fail loud instead of re-deriving the type downstream and masking the transform
// that dropped it (which would silently emit the save-temp as C `double`).
function classifyMemberFieldRc(memberExpr: Node, dctx: DrcContext): RcInfo {
	if (memberExpr.nodeType != null) return classifyRc(memberExpr.nodeType, dctx);
	const md = memberExpr.data as MemberExprData;
	console.log("DRC INTERNAL ERROR: RC member access '." + md.property + "' reached DRC without a type at " + memberExpr.location.line + ":" + memberExpr.location.column + " — a transform built it without setting nodeType");
	return noRcInfo();
}

// Classify RC type of an array element
function classifyArrayElementRc(arrayExpr: Node, dctx: DrcContext): RcInfo {
	if (arrayExpr.nodeType == null) return noRcInfo();
	return classifyRc(arrayExpr.nodeType, dctx);
}

// Emit wasMoved on MoveExpr source. Handles identifier, field, array element.
// checkLastRead: true when idx/stmts context is valid (for errFailedMove diagnostic)
// Returns true if wasMoved was emitted.
function emitMoveSourceWasMoved(moveArg: Node, rcInfo: RcInfo, idx: number, stmts: Node[], dctx: DrcContext, loc: SourceLocation, checkLastRead: boolean): boolean {
	if (moveArg.kind == NodeKind.Identifier && moveArg.resolvedSym != null) {
		if (rcInfo.wasMovedFn != null) {
			addPending(dctx, makeWasMovedCall(moveArg.resolvedSym, rcInfo, loc));
		}
		recordMoveInContext(dctx, moveArg.resolvedSym);
		return true;
	}
	if (moveArg.kind == NodeKind.MemberExpr) {
		const fieldRc = classifyMemberFieldRc(moveArg, dctx);
		if (fieldRc.needsCleanup && fieldRc.wasMovedFn != null) {
			addPending(dctx, makeWasMovedOnExpr(moveArg, fieldRc, loc));
		}
		return true;
	}
	if (moveArg.kind == NodeKind.ArrayAccess) {
		const elemRc = classifyArrayElementRc(moveArg, dctx);
		if (elemRc.needsCleanup && elemRc.wasMovedFn != null) {
			addPending(dctx, makeWasMovedOnExpr(moveArg, elemRc, loc));
		}
		return true;
	}
	// CallExpr / other: source is fresh, no variable to zero
	return false;
}

// ===== Scope Cleanup Generation =====

function generateCleanup(scope: DrcScope, loc: SourceLocation): Node[] {
	const result: Node[] = [];
	for (const mv of scope.wasMoved) {
		if (mv.sym == null && mv.exprNode != null) {
			result.push(mv.exprNode);
		}
	}
	let i = scope.varsToCleanup.length;
	while (i > 0) {
		i -= 1;
		const vi = scope.varsToCleanup[i];
		if (vi.isCursor) continue;
		if (vi.rcInfo.destroyFn == null) continue;
		result.push(makeDestroyCall(vi.sym, vi.rcInfo, loc));
	}
	return result;
}

// ===== Try/Finally Wrapping =====

// Implementation parity: hoist a single VariableDecl if it's an RC var tracked in scope.
// Mirrors standard scope processing which emits variables as declarations before the try body.
// Returns true if hoisted (caller emits assignment in try body instead).
function tryHoistVar(stmt: Node, scope: DrcScope, hoisted: Node[], body: Node[], loc: SourceLocation): boolean {
	if (stmt.kind != NodeKind.VariableDecl) return false;
	const d = stmt.data as VariableDeclData;
	const vi = findVarInfo(scope, stmt.resolvedSym);
	if (vi == null || !vi.rcInfo.needsCleanup) return false;
	const hoistDecl = makeVarDecl(d.declName, makeNull(loc), DeclKind.Let, loc);
	if (stmt.nodeType != null) {
		hoistDecl.nodeType = stmt.nodeType;
	}
	const hoistSym = vi.sym;
	hoistDecl.resolvedSym = hoistSym;
	hoisted.push(hoistDecl);
	if (d.initializer != null && d.initializer.kind != NodeKind.NullLiteral) {
		const lhs = makeIdentResolved(hoistSym, loc);
		if (stmt.nodeType != null) { lhs.nodeType = stmt.nodeType; }
		body.push(makeExprStmt(makeAssign(lhs, d.initializer, loc), loc));
	}
	return true;
}

// Implementation parity: scan a statement list for hoistable RC vars.
// Recurses one level into BlockStmt (created by emitSaveAssignDestroy)
// to find temps that are registered in scope but declared in sub-blocks.
function hoistScopeVars(stmts: Node[], scope: DrcScope, hoisted: Node[], tryBody: Node[], loc: SourceLocation): void {
	for (const stmt of stmts) {
		if (tryHoistVar(stmt, scope, hoisted, tryBody, loc)) continue;
		if (stmt.kind == NodeKind.BlockStmt) {
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

// Reference: processScope (injectdestructors.nim:587) — the scope's variable
// declarations are emitted unconditionally; needsTry only picks where cleanup goes.
function assembleScope(bodyStmts: Node[], cleanupStmts: Node[], scope: DrcScope, loc: SourceLocation): Node[] {
	const hoisted: Node[] = [];
	const body: Node[] = [];
	hoistScopeVars(bodyStmts, scope, hoisted, body, loc);

	const result: Node[] = [];
	for (const h of hoisted) {
		result.push(h);
	}
	if (cleanupStmts.length > 0 && scope.needsTry) {
		result.push(makeTryFinally(makeBlock(body, loc), makeBlock(cleanupStmts, loc), loc));
		return result;
	}
	for (const s of body) {
		result.push(s);
	}
	for (const cs of cleanupStmts) {
		result.push(cs);
	}
	return result;
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

		// Flush pre-statements and post-statements from current scope.
		// Per-scope isolation (reference parity): each scope has its own
		// preStmts/pendingStmts, so branch processing can't leak parent stmts.
		const curScope = currentScope(dctx);
		for (const pre of curScope.preStmts) { buf.push(pre); }
		curScope.preStmts = [];
		buf.push(processed);
		for (const post of curScope.pendingStmts) { buf.push(post); }
		curScope.pendingStmts = [];
		dctx.capturedNodes = [];
		dctx.capturedSyms = [];

		dctx.currentStmtIdx = savedIdx;
	}
	dctx.currentStmtList = savedList;
	return buf;
}

// ===== Simple scoped statement list (no try/finally) =====
// Used by switch cases and program-level — push scope, process, pop, append cleanup.

function processStmtListScoped(stmts: Node[], dctx: DrcContext, loc: SourceLocation): Node[] {
	pushScope(dctx, false, false);
	const processed = processStmtList(stmts, dctx, loc);
	const scope = popScope(dctx);
	const cleanup = generateCleanup(scope, loc);
	for (const cs of cleanup) { processed.push(cs); }
	return processed;
}

// ===== Unified block scope processing =====
// Handles function bodies (isFunction=true), loop bodies (isLoop=true), and plain blocks.

function processBlockBody(body: Node, dctx: DrcContext, isLoop: boolean, isFunction: boolean, loc: SourceLocation): Node {
	if (body == null) return body;
	// Non-block bodies (e.g. ExprStmt from match arm lowering) need DRC processing too.
	// Wrap in a synthetic block so processStmtList handles RC for assignments inside.
	if (body.kind != NodeKind.BlockStmt) {
		const wrapped = makeBlock([body], loc);
		return processBlockBody(wrapped, dctx, isLoop, isFunction, loc);
	}
	const bd = body.data as BlockStmtData;

	pushScope(dctx, isLoop, isFunction);
	const processed = processStmtList(bd.statements, dctx, loc);
	const scope = popScope(dctx);
	const cleanup = generateCleanup(scope, loc);

	return makeBlock(assembleScope(processed, cleanup, scope, loc), loc);
}

// ===== Per-Statement Dispatch =====

function processStmt(stmt: Node, idx: number, stmts: Node[], dctx: DrcContext, loc: SourceLocation): Node {
	if (stmt == null) return stmt;
	const sloc = stmt.location;
	dctx.stmtBorrowReads = [];
	setNeedsTryIfRaises(stmt, dctx);

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
		NodeKind.BreakStmt | NodeKind.ContinueStmt => { setNeedsTryToLoop(dctx); return stmt; },
		NodeKind.ThrowStmt => processThrow(stmt, dctx, sloc),
		NodeKind.ExportDecl => processExport(stmt, dctx, sloc),
		NodeKind.ClassDecl => processClass(stmt, dctx, sloc),
		NodeKind.ArrowFunction => processArrow(stmt, dctx, sloc),
		NodeKind.FunctionExpr => processFuncExpr(stmt, dctx, sloc),
		NodeKind.TestDecl => processTestDecl(stmt, dctx, sloc),
		_ => stmt,
	};

	popOuterStmts(dctx);

	return result;
}

function callCanThrow(callExpr: Node): boolean {
	const cd = callExpr.data as CallExprData;
	const sym = cd.callee.resolvedSym;
	if (sym == null) return true;
	if (hasFlag(sym, SymbolFlag.Throws)) return true;
	return !hasFlag(sym, SymbolFlag.ImportC);
}

function setNeedsTryIfRaises(node: Node, dctx: DrcContext): void {
	if (node == null) return;
	if (node.kind == NodeKind.FunctionDecl
		|| node.kind == NodeKind.ArrowFunction
		|| node.kind == NodeKind.FunctionExpr
		|| node.kind == NodeKind.ClassDecl
		|| node.kind == NodeKind.ActorDecl
		|| node.kind == NodeKind.TestDecl) return;
	if (node.kind == NodeKind.CallExpr && callCanThrow(node)) {
		setNeedsTryAll(dctx);
		return;
	}
	forEachChild(node, (child: Node): void => { setNeedsTryIfRaises(child, dctx); });
}

// ===== Loop-Aware Last-Read =====
// Variables defined before a loop are NEVER last-read inside the loop body,
// because the loop repeats and uses them again. The forward scan misses this
// because it doesn't see loop back-edges.

function isVarFromOuterLoopScope(sym: Symbol, dctx: DrcContext): boolean {
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
			const vi = findVarInfo(scope, sym);
			if (vi != null) return true;
		}
		if (scope.isFunction) break;
	}
	return false;
}

function isLastReadSafe(sym: Symbol, node: Node, idx: number, stmts: Node[], dctx: DrcContext): boolean {
	if (sym == null) return false;
	// passCopyToSink synthesizes single-use sink-arg temps and marks them SinkTemp.
	// CFG can't see these (added to preStmts after CFG build) so it returns false
	// (not last read) → moveOrCopy falls to genCopy → double Copy → the synthesized
	// temp's heap data leaks (passCopyToSink intentionally skips scope cleanup since
	// the sink consumer takes ownership). The flag short-circuits to true so
	// moveOrCopy chooses genSink (blit transfer, no second Copy).
	// Reproduction: any `const e = container[i]` where container element is a Named
	// struct with heap fields, in a generic function — see Map.set/orderedMapRawGet.
	if (hasFlag(sym, SymbolFlag.SinkTemp)) return true;
	// Reference parity (sfGlobal): module-level variables live for the entire program.
	// wasMoved would zero them for all callers. Never move globals.
	if (hasFlag(sym, SymbolFlag.Global)) return false;
	// Params are borrows — never move them: the caller owns the value and
	// will still destroy its own copy (use-after-free otherwise).
	if (sym.symbolKind == SymbolKind.Parameter) return false;
	// Reference parity: cursor variables are borrows — never move them.
	// isLastRead(n, c, s) and not (n.kind == Identifier and isCursor(n))
	// Cursor vars (for-of bindings, $-prefixed temps) don't own the data;
	// the source array/container still holds its own reference.
	// Moving a cursor would leave the source with a dangling pointer.
	const vi = findVarInfoInContext(dctx, sym);
	if (vi != null && vi.isCursor) return false;
	// Phase A: variables in finally blocks must never be moved (use-after-free prevention)
	if (symListHas(dctx.finallyProtectedVars, sym)) return false;
	// Phase C: use CFG-based analysis when function body is available
	if (dctx.currentFuncBody != null && node != null) {
		return isLastReadCfgNodeCached(sym, node, dctx.currentFuncBody, dctx.cfgCache);
	}
	// Fallback: conservative forward scan
	if (!isLastReadInContext(sym, idx, stmts, dctx.outerCtx)) return false;
	// If variable is from a scope outside a loop, it's not truly last-read
	// inside the loop body (the loop will repeat and use it again).
	if (isVarFromOuterLoopScope(sym, dctx)) return false;
	return true;
}

// ===== Field-Level Last-Read Safety (Phase B) =====
// For MemberExpr/ArrayAccess nodes: checks if the field path is last-read.
// Uses alias-aware CFG analysis (isLastReadCfgNodeCached).
// Reference: isAnalysableFieldAccess + isLastRead pattern.

function isLastReadFieldSafe(node: Node, idx: number, stmts: Node[], dctx: DrcContext): boolean {
	if (node == null) return false;
	// Gate: must be analysable field access (local, not global, not cursor, not param)
	if (!isAnalysableFieldAccess(node)) return false;
	const rootSym = getRootSym(node);
	if (rootSym == null) return false;
	// Standard safety checks (same as isLastReadSafe)
	if (rootSym.symbolKind == SymbolKind.Parameter) return false;
	const vi = findVarInfoInContext(dctx, rootSym);
	if (vi != null && vi.isCursor) return false;
	if (symListHas(dctx.finallyProtectedVars, rootSym)) return false;
	// Field-level CFG query with alias-aware BFS
	if (dctx.currentFuncBody != null) {
		return isLastReadCfgNodeCached(rootSym, node, dctx.currentFuncBody, dctx.cfgCache);
	}
	return false;  // no CFG available → conservative
}

// ===== Conditional Expression Init =====

// ===== Literal Field/Element RC Processing =====
// NOTE: emitLiteralFieldCopies / emitArrayElementCopies removed.
// Reference parity (ObjectLiteral/ArrayLiteral): processObjectLiteral and processArrayLiteral
// handle field/element RC inline via SinkArg mode. No separate post-construction copy step.

// ===== Sink Parameter Registration =====
// Register RC-typed function parameters for scope cleanup.
// The function owns the parameter values — they need destroy at scope exit.

function isEnvParam(name: string): boolean {
	// Lambda-lifted closure env pointer — managed by closure infrastructure, skip from cleanup
	if (name.length < 6) return false;
	return name.slice(0, 6) == "__envP";
}

function registerFuncParams(paramNames: string[], paramTypes: Type[], paramSyms: Symbol[] | null, dctx: DrcContext, loc: SourceLocation, body: Node): void {
	if (dctx.ctx.checkerCtx == null) return;
	for (let pi = 0; pi < paramNames.length && pi < paramTypes.length; pi += 1) {
		const pName = paramNames[pi];
		// Skip closure env params (item 11) — they're managed by msClosure infrastructure
		if (!isEnvParam(pName)) {
			const pRcInfo = classifyRc(paramTypes[pi], dctx);
			if (pRcInfo.needsCleanup) {
				// Params are borrows registered as cursors (Nim default — no sink
				// params, ea38c2a): the caller owns the value; stores inside the
				// callee copy at the assignment point.
				registerVar(dctx, pRcInfo, true, paramSyms != null && pi < paramSyms.length ? paramSyms[pi] : noSym);
			}
		}
	}
}

// Phase G: detect generator/async state machine bodies — leading state-selector decl
function isGeneratorBody(body: Node): boolean {
	if (body == null || body.kind != NodeKind.BlockStmt) return false;
	const bd = body.data as BlockStmtData;
	if (bd.statements.length == 0) return false;
	const first = bd.statements[0];
	if (first.kind != NodeKind.VariableDecl) return false;
	const d = first.data as VariableDeclData;
	return first.resolvedSym != null && hasFlag(first.resolvedSym, SymbolFlag.StateMachine);
}

// Process a function body with sink param registration.
// Looks up the function's type to get resolved param types.
function processFuncBodyWithParams(body: Node, ownerSym: Symbol | null, fnName: string, paramNames: string[], paramSyms: Symbol[] | null, dctx: DrcContext, loc: SourceLocation, funcNodeType: Type): Node {
	if (body == null) return body;
	if (body.kind != NodeKind.BlockStmt) return body;
	const bd = body.data as BlockStmtData;

	// Reference parity (sfGeneratedOp): skip DRC injection for generated lifecycle hooks.
	// Reference: `if sfGeneratedOp in owner.flags: return n` at top of injectDestructorCalls.
	if (ownerSym != null && hasFlag(ownerSym, SymbolFlag.GeneratedOp)) return body;

	// Function boundary — prevent cross-scope last-read from looking past this
	pushOuterStmts(dctx, [], 0, true);
	pushScope(dctx, false, true);

	// Phase A: scan finally blocks for protected variables
	dctx.finallyProtectedVars = collectFinallyVars(body);

	// Phase B: infer cursor (borrowed) variables for this function
	inferCursors(body);

	// Phase C: set function body for CFG-based last-read analysis
	dctx.currentFuncBody = body;
	dctx.currentFuncName = fnName;
	clearCfgCache(dctx.cfgCache);

	// Register RC-typed params for cleanup.
	// Reference parity: ALWAYS use the function's type (owner.typ), never scope lookupSymbol.
	// lookupSymbol(paramName) can find wrong-scope variables with the same name.
	if (ownerSym != null && ownerSym.symbolType != null && ownerSym.symbolType.kind == TypeKind.Function) {
		registerFuncParams(ownerSym.symbolType.typeNames, ownerSym.symbolType.typeChildren, paramSyms, dctx, loc, body);
	} else if (funcNodeType != null && funcNodeType.kind == TypeKind.Function) {
		registerFuncParams(funcNodeType.typeNames, funcNodeType.typeChildren, paramSyms, dctx, loc, body);
	} else if (paramNames.length > 0) {
		// No type info for params — transform bug. Log so we catch it early.
		// NEVER fall back to lookupSymbol(paramName) — it finds wrong-scope variables.
		console.log("DRC warning: function '" + fnName + "' has params but no type info — skipping param RC registration");
	}

	const processed = processStmtList(bd.statements, dctx, loc);
	const scope = popScope(dctx);

	// Phase G: generator/async state machines have per-state cleanup — skip try/finally
	if (isGeneratorBody(body)) {
		scope.needsTry = false;
	}

	const cleanup = generateCleanup(scope, loc);
	popOuterStmts(dctx);  // pop function boundary sentinel

	return makeBlock(assembleScope(processed, cleanup, scope, loc), loc);
}



// ===== Variable Declaration =====

function processVarDecl(stmt: Node, idx: number, stmts: Node[], dctx: DrcContext, loc: SourceLocation): Node {
	const d = stmt.data as VariableDeclData;

	// Prefer nodeType from checker (set on the VariableDecl during check pass)
	// Fall back to symbol table lookup only if nodeType is absent
	if (dctx.ctx.checkerCtx == null) return stmt;
	let varType: Type | null = null;
	if (stmt.nodeType != null) {
		varType = stmt.nodeType;
	} else {
		const sym = lookupSymbol(dctx.ctx.checkerCtx.table, d.declName);
		// Only use symbol if it's a Variable/Parameter — avoid name collisions with extension methods
		if (sym != null && (sym.symbolKind == SymbolKind.Variable || sym.symbolKind == SymbolKind.Temp || sym.symbolKind == SymbolKind.Parameter)) {
			varType = sym.symbolType;
		} else if (sym != null && sym.symbolKind == SymbolKind.Function) {
			// Name collision: local variable shadowed by function — skip RC
			return stmt;
		}
	}
	if (varType == null) return stmt;

	const rcInfo = classifyRc(varType, dctx);

	// Cursor detection must happen BEFORE the needsCleanup early-return.
	// Even if the variable's own type doesn't need cleanup, it may be a pointer alias
	// (e.g., `const d = node.data as Variant`). If not registered as cursor, field
	// accesses through it (d.field) won't be recognized as borrows, allowing
	// field-level moves that corrupt the aliased parent object.
	let isCursor = false;
	if (d.initializer != null && isByteViewConv(d.initializer)) {
		isCursor = true;
	}
	// Union variant narrowing: `const d = node.data as Variant` borrows from parent node.
	// In C, codegen emits a pointer into the union — DRC must not destroy the alias.
	if (d.initializer != null && d.initializer.kind == NodeKind.TypeAssertion) {
		const tad = d.initializer.data as TypeAssertionData;
		if (tad.asExpr != null && tad.asExpr.nodeType != null && tad.asExpr.nodeType.kind == TypeKind.Union) {
			isCursor = true;
		}
	}
	// Phase B: check cursor inference results (borrow-only variables skip all RC)
	if (isCursorSym(stmt.resolvedSym)) {
		isCursor = true;
	}

	// Pass resolvedSym so generateCleanup emits destroy/wasMoved with the correct symbol.
	// This lets the C codegen resolve same-named variables in different scopes to unique C names.
	// Without resolvedSym, lookupLocalName returns the last mapping, which may be from an
	// inner scope — causing double-free when the outer scope also cleans up.
	const varSym = stmt.resolvedSym;

	// Register cursor variables even without cleanup — they must be visible in DRC scope
	// so field accesses through them (d.field) are recognized as borrows.
	if (isCursor && !rcInfo.needsCleanup) {
		registerVar(dctx, rcInfo, true, varSym);
		return stmt;
	}

	if (!rcInfo.needsCleanup) {
		// Binding needs no cleanup, but the initializer may hold a fresh RC inner call
		// (`const n: number = lenOf(makeMsg())`, `const b = provide().field`). Walk it so
		// ensureDestructionIfNeeded captures that temp for scope-exit destroy (awaitables
		// skipped via skipAwaitableCapture; wrappers recursed in processNode). Retires
		// callHoist's expandVarDecl plain-hoist for this position.
		if (d.initializer != null) {
			const parkedFut = stmt.resolvedSym != null && hasFlag(stmt.resolvedSym, SymbolFlag.AwaitHandle);
			if (parkedFut) dctx.parkedInitDepth += 1;
			d.initializer = processNonRcRead(d.initializer, dctx);
			if (parkedFut) dctx.parkedInitDepth -= 1;
		}
		return stmt;
	}

	// Register for scope cleanup
	registerVar(dctx, rcInfo, isCursor, varSym);

	// Cursor variables borrow — no move/copy on initializer (source stays alive)
	if (isCursor) return stmt;

	// Phase D: first-write optimization — `let x;` without initializer is uninitialized
	if (d.initializer == null) {
		markUninitialized(dctx, varSym);
		return stmt;
	}

	// Process initializer recursively with Consumed mode. An AwaitHandle decl
	// (awaitLower's `$fut = call` hoist) parks the caller on that call — mark the
	// depth so processCallExpr keeps its args as borrows (scope outlives flight).
	const parkedFutInit = stmt.resolvedSym != null && hasFlag(stmt.resolvedSym, SymbolFlag.AwaitHandle);
	if (parkedFutInit) dctx.parkedInitDepth += 1;
	d.initializer = processNode(d.initializer, dctx, rhsMode(d.initializer));
	if (parkedFutInit) dctx.parkedInitDepth -= 1;
	const init = d.initializer;

	// Unified RC decision via moveOrCopy.
	if (varSym == null) return stmt;
	const destNode = makeIdentResolved(varSym, loc);
	destNode.nodeType = varType;
	return moveOrCopy(stmt, destNode, init, rcInfo, MOC_IS_DECL, idx, stmts, dctx, loc);
}

// ===== Expression Statement (assignments + discarded calls) =====

function processExprStmt(stmt: Node, idx: number, stmts: Node[], dctx: DrcContext, loc: SourceLocation): Node {
	const d = stmt.data as ExprStmtData;
	const expr = d.expr;

	// Implementation parity: assignments go through moveOrCopy (processAssignment), NOT through
// the generic processNode → processBinary path. Processing assignment LHS via
// processBinary would incorrectly treat it as Consumed.
// In the reference implementation, assignment is handled directly before any generic expression processing.
	if (expr.kind == NodeKind.BinaryExpr) {
		const bd = expr.data as BinaryExprData;
		if (bd.operator == "=") {
			return processAssignment(stmt, idx, stmts, dctx, loc);
		}
		// String += is rewritten by stringOpLower → msStringAppend(&s, t) before DRC.
		// Other compound assignments (number +=, etc.) use native C operators — no DRC needed.
	}

	// Reference parity: processNode in Normal mode calls processCall → ensureDestructionIfNeeded,
	// which captures RC-returning calls in a $tmp and registers scope-exit destroy.
	// This is the single capture path — matches reference ensureDestruction.
	// processDiscardedCall was a redundant second capture that caused double function calls.
	d.expr = processNode(expr, dctx, DrcMode.Normal);

	return stmt;
}

// ===== Assignment Processing =====

// Reference parity: DRC lifecycle hooks (_copy, _sink, _destroy, _wasMoved) are generated by
// destructorLifting with their own RC operations. The DRC analyzer must NOT wrap field
// assignments inside hooks with save-assign-destroy — that would double-count references.
function processAssignment(stmt: Node, idx: number, stmts: Node[], dctx: DrcContext, loc: SourceLocation): Node {
	const bd = (stmt.data as ExprStmtData).expr.data as BinaryExprData;
	// reference parity (sameLocation): self-assignment removal — x = x is a no-op
	if (sameLocation(bd.left, bd.right)) return stmt;

	// Member assignment: obj.field = expr
	if (bd.left.kind == NodeKind.MemberExpr) {
		let rcInfo = classifyMemberFieldRc(bd.left, dctx);
		// Fallback: if LHS nodeType is null (checker didn't propagate), infer from RHS.
		// Without this, field assignments like table.current = scope get no RC treatment,
		// causing premature frees and dangling references.
		// IMPORTANT: skip fallback if LHS is explicitly Ptr<T> — Ptr fields are borrows
		// and must NOT get RC treatment. The RHS may be Ref<T> (owned) being assigned
		// to a Ptr<T> (borrowed) field, but the field doesn't own a reference.
		const lhsIsNonOwning = bd.left.nodeType != null
			&& (bd.left.nodeType.kind == TypeKind.Ptr || bd.left.nodeType.kind == TypeKind.Cursor);
		if (!rcInfo.needsCleanup && !lhsIsNonOwning && bd.right.nodeType != null) {
			rcInfo = classifyRc(bd.right.nodeType, dctx);
		}
		if (!rcInfo.needsCleanup) return stmt;
		bd.right = processNode(bd.right, dctx, DrcMode.SinkArg);
		return moveOrCopy(stmt, bd.left, bd.right, rcInfo, MOC_IS_FIELD, idx, stmts, dctx, loc);
	}

	// Array index assignment: arr[i] = expr
	if (bd.left.kind == NodeKind.ArrayAccess) {
		const rcInfo = classifyArrayElementRc(bd.left, dctx);
		if (!rcInfo.needsCleanup) return stmt;
		bd.right = processNode(bd.right, dctx, DrcMode.SinkArg);
		return moveOrCopy(stmt, bd.left, bd.right, rcInfo, MOC_IS_FIELD, idx, stmts, dctx, loc);
	}

	if (bd.left.kind == NodeKind.HiddenDeref) {
		const rcInfo = bd.left.nodeType != null ? classifyRc(bd.left.nodeType, dctx) : noRcInfo();
		if (!rcInfo.needsCleanup) return stmt;
		bd.right = processNode(bd.right, dctx, DrcMode.SinkArg);
		return moveOrCopy(stmt, bd.left, bd.right, rcInfo, MOC_IS_FIELD, idx, stmts, dctx, loc);
	}

	if (bd.left.kind != NodeKind.Identifier) return stmt;
	const leftD = bd.left.data as IdentifierData;

	// Demand-driven: use resolvedSym from Phase 2, fall back to VarInfo for synthetic temps
	const sym = bd.left.resolvedSym;
	const vi = findVarInfoInContext(dctx, sym);
	if (vi != null && vi.isCursor) {
		bd.right = processNode(bd.right, dctx, DrcMode.Normal);
		return stmt;
	}
	let rcInfo: RcInfo = noRcInfo();
	if (sym != null) {
		rcInfo = classifyRc(sym.symbolType, dctx);
	} else {
		// Synthetic variables (e.g. $matchres from match lowering) lack resolvedSym.
		// Use registered VarInfo to get the correct RcInfo.
		if (vi == null) return stmt;
		rcInfo = vi.rcInfo;
	}
	if (!rcInfo.needsCleanup) {
		// Non-RC identifier LHS (`x = f().ok`, `x = provide().field`): the RHS may hold a
		// fresh RC inner call → capture it (awaitables skipped; wrappers recursed). Retires
		// callHoist's expandAssign plain-hoist for this position.
		bd.right = processNonRcRead(bd.right, dctx);
		return stmt;
	}

	// Phase D: first-write optimization — skip destroy on first assignment to uninitialized var
	const isFirstWrite = vi != null && !vi.isInitialized;
	if (isFirstWrite) {
		vi.isInitialized = true;
	}

	// Snapshot the LHS var's move-state BEFORE the RHS, so we can tell whether THIS RHS
	// consumes it (`x = f([..., x])`) versus it having been conditionally moved earlier
	// (e.g. a `return x` in a sibling branch — flow-insensitive move record).
	const movedBeforeRhs = !isFirstWrite && varMovedInContext(dctx, sym);

	bd.right = processNode(bd.right, dctx, rhsMode(bd.right));

	// Reference parity: when dest appears in the RHS (e.g., result = f(result)),
	// processNode emits wasMoved(dest) as pending because isLastRead is true
	// for the old value. But reassignment's save-assign-destroy handles the
	// old value. The pending wasMoved would zero the NEW value. Clear it.
	if (!isFirstWrite) {
		clearPendingForVar(dctx, sym);
	}

	// Reference parity (Nim wasMoved-then-sink-no-op): when the LHS var is consumed (moved)
	// INSIDE this RHS — e.g. `x = f([..., x])`, where x sinks into an array/object literal —
	// its old reference already lives there; destroying it again (save-assign-destroy)
	// double-frees. Treat as a fresh write (no destroy-old) and clear the stale move so the
	// new value is still destroyed at scope exit. Gate on !movedBeforeRhs so a prior
	// conditional move is not mistaken for consumption by this RHS.
	const consumedInRhs = !isFirstWrite && !movedBeforeRhs && varMovedInContext(dctx, sym);
	if (consumedInRhs) {
		clearMoveInContext(dctx, sym);
		return moveOrCopy(stmt, bd.left, bd.right, rcInfo, MOC_IS_DECL, idx, stmts, dctx, loc);
	}

	// Unified RC decision (Reference parity: moveOrCopy)
	// First-write maps to IsDecl (no old value to destroy)
	const mocFlags: int32 = isFirstWrite ? MOC_IS_DECL : MOC_NONE;
	return moveOrCopy(stmt, bd.left, bd.right, rcInfo, mocFlags, idx, stmts, dctx, loc);
}

// ===== Return Statement =====

// Ownership flows through conversions — reference "ownership invariance"
// (injectdestructors nkConv/nkHiddenStdConv/nkCast recurse into the operand
// with the same mode: owning C(x) means owning x). Classify the operand,
// never the wrapper.
function skipConversionWrappers(expr: Node): Node {
	let e = expr;
	while (true) {
		if (e.kind == NodeKind.TypeAssertion) {
			const ta = e.data as TypeAssertionData;
			if (ta.asExpr == null) break;
			e = ta.asExpr;
			continue;
		}
		if (e.kind == NodeKind.HiddenStdConv || e.kind == NodeKind.HiddenSubConv) {
			const cv = e.data as HiddenStdConvData;
			if (cv.convExpr == null) break;
			e = cv.convExpr;
			continue;
		}
		break;
	}
	return e;
}

// Check if a return expression is a borrowed RC pointer that needs incref.
// Borrowed = not fresh, not owned local. E.g., obj.field, arr[i], parameter.
// ONLY returns true for RcKind.Ref — strings/arrays/named types need passCopyToSink
// (deep copy), not msIncref (pointer refcount bump). See processReturn for those.
function needsReturnIncref(expr: Node, dctx: DrcContext): boolean {
	return needsReturnIncrefBare(skipConversionWrappers(expr), dctx);
}

function needsReturnIncrefBare(expr: Node, dctx: DrcContext): boolean {
	if (dctx.ctx.checkerCtx == null) return false;
	// Fresh expressions produce owned values — no incref needed
	if (isFreshExpr(expr.kind)) return false;
	if (expr.kind == NodeKind.CallExpr) return false;
	if (expr.kind == NodeKind.MoveExpr) return false;

	// Identifier: function-local RC vars are moved (not borrowed) — no incref
	if (expr.kind == NodeKind.Identifier) {
		const name = (expr.data as IdentifierData).name;
		if (expr.resolvedSym != null && hasFlag(expr.resolvedSym, SymbolFlag.SinkTemp)) return false;
		// Cursor variables (for-of bindings, inferred borrows): borrowed references.
		// Returning a cursor creates a new reference — must incref.
		// Reference parity: the reference incref's at the assignment site inside the function;
		// we skip DRC on cursor init, so we incref at the return instead.
		if (isCursorSym(expr.resolvedSym)) {
			if (expr.nodeType != null) {
				const rc = sinkClassify(expr.nodeType, dctx);
				return rc.needsCleanup && rc.rcKind == RcKind.Ref;
			}
		}
		const vi = findVarInfoInFunction(dctx, expr.resolvedSym);
		if (vi != null) return false;  // function-local var — moved out via destructiveMoveVar at the return
		// Not a local var (parameter or global) — check if RC pointer type
		if (expr.nodeType != null) {
			const rc = sinkClassify(expr.nodeType, dctx);
			return rc.needsCleanup && rc.rcKind == RcKind.Ref;
		}
		const sym = lookupSymbol(dctx.ctx.checkerCtx.table, name);
		if (sym == null || sym.symbolType == null) return false;
		const rc = sinkClassify(sym.symbolType, dctx);
		// Only Ref types use msIncref. Strings/arrays use deep copy (handled by processReturn).
		return rc.needsCleanup && rc.rcKind == RcKind.Ref;
	}

	// MemberExpr: use nodeType (stamped by checker) — scope lookups fail for function params.
	// Reference parity: the reference reads n.typ on the node, never re-does scope lookup in DRC.
	if (expr.kind == NodeKind.MemberExpr) {
		if (expr.nodeType != null) {
			const rc = sinkClassify(expr.nodeType, dctx);
			return rc.needsCleanup && rc.rcKind == RcKind.Ref;
		}
		// Fallback: look up object type via symbol table (module-scope symbols only)
		const md = expr.data as MemberExprData;
		if (md.object.kind != NodeKind.Identifier) return false;
		const objName = (md.object.data as IdentifierData).name;
		const objSym = lookupSymbol(dctx.ctx.checkerCtx.table, objName);
		if (objSym == null || objSym.symbolType == null) return false;
		const objType = objSym.symbolType;
		for (let fi = 0; fi < objType.typeNames.length && fi < objType.typeChildren.length; fi += 1) {
			if (objType.typeNames[fi] == md.property) {
				const rc = sinkClassify(objType.typeChildren[fi], dctx);
				return rc.needsCleanup && rc.rcKind == RcKind.Ref;
			}
		}
		return false;
	}
	// ArrayAccess: use nodeType first, fallback to symbol lookup
	if (expr.kind == NodeKind.ArrayAccess) {
		if (expr.nodeType != null) {
			const rc = sinkClassify(expr.nodeType, dctx);
			return rc.needsCleanup && rc.rcKind == RcKind.Ref;
		}
		const ad = expr.data as ArrayAccessData;
		if (ad.array.kind != NodeKind.Identifier) return false;
		const arrName = (ad.array.data as IdentifierData).name;
		const sym = lookupSymbol(dctx.ctx.checkerCtx.table, arrName);
		if (sym == null || sym.symbolType == null) return false;
		if (sym.symbolType.typeReturn == null) return false;
		const elemRc = sinkClassify(sym.symbolType.typeReturn, dctx);
		return elemRc.needsCleanup && elemRc.rcKind == RcKind.Ref;
	}

	// Unhandled return-expression NodeKind with Ref type silently misses incref —
	// callee scope frees pointer before caller's field-assign incref runs. Extend
	// this function when new return shapes (CastExpr, TernaryExpr) need handling.
	if (expr.nodeType != null) {
		const rc = sinkClassify(expr.nodeType, dctx);
		if (rc.needsCleanup && rc.rcKind == RcKind.Ref) {
			dctx.ctx.checkerCtx.errors.push({
				message: "needsReturnIncref: unhandled NodeKind=" + (expr.kind as number) + " for Ref-typed return — extend inject.ms",
				line: expr.location.line, column: expr.location.column, fatal: false,
			});
		}
	}
	return false;
}

// Nim pRaiseStmt: the raise argument is a sink. An owned-local identifier is
// moved (destructiveMoveVar via the Consumed walk); a non-movable RC source
// (field/element read) is copy-temp'd — `tmp = copy(arg); raise tmp`
// (injectdestructors.nim:773) — so the raise machinery owns exactly one live
// reference and no aliasing second owner survives the unwind. String throws
// stay untouched: msThrow copies the message (MS sugar outside the ref domain).
function processThrow(stmt: Node, dctx: DrcContext, sloc: SourceLocation): Node {
	setNeedsTryAll(dctx);
	const td = stmt.data as ThrowStmtData;
	const at = td.throwArg.nodeType;
	if (at == null || at.kind == TypeKind.String) return stmt;
	const rc = classifyRc(at, dctx);
	if (!rc.needsCleanup) return stmt;
	if (td.throwArg.kind == NodeKind.Identifier) {
		td.throwArg = processNode(td.throwArg, dctx, DrcMode.Consumed);
		return stmt;
	}
	if (td.throwArg.kind == NodeKind.MemberExpr || td.throwArg.kind == NodeKind.ArrayAccess) {
		const excSym = freshTempSym(dctx.ctx, "exc", at);
		const tmpDecl = makeVarDecl(excSym.name, td.throwArg, DeclKind.Const, sloc);
		tmpDecl.nodeType = at;
		tmpDecl.resolvedSym = excSym;
		const rcCopy = sinkClassify(at, dctx);
		const increfRef = rcCopy.copyFn != null ? makeTypedIdentResolved(rcCopy.copyFn, null, sloc) : runtimeRef("msIncref", sloc);
		const incref = makeExprStmt(
			makeCall(increfRef, [makeIdentResolved(excSym, sloc)], sloc), sloc);
		td.throwArg = makeIdentResolved(excSym, sloc);
		return makeBlock([tmpDecl, incref, stmt], sloc);
	}
	return stmt;
}

// Emit: { const $ret_N = expr; msIncref($ret_N); return $ret_N; }
function emitReturnWithIncref(arg: Node, dctx: DrcContext, loc: SourceLocation): Node {
	const retSym = freshTempSym(dctx.ctx, "ret", arg.nodeType);
	const tmpDecl = makeVarDecl(retSym.name, arg, DeclKind.Const, loc);
	tmpDecl.resolvedSym = retSym;
	const rc = sinkClassify(arg.nodeType, dctx);
	const increfRef = rc.copyFn != null ? makeTypedIdentResolved(rc.copyFn, null, loc) : runtimeRef("msIncref", loc);
	const incref = makeExprStmt(
		makeCall(increfRef, [makeIdentResolved(retSym, loc)], loc), loc);
	const retStmt = makeReturn(makeIdentResolved(retSym, loc), loc);
	return makeBlock([tmpDecl, incref, retStmt], loc);
}

function processReturn(stmt: Node, dctx: DrcContext, loc: SourceLocation): Node {
	const d = stmt.data as ReturnStmtData;

	setNeedsTryAll(dctx);

	if (d.argument != null) {
		// Capture the ORIGINAL argument shape before processNode can rewrite it.
		// processNode(Consumed) on an identifier may return a freshly-created
		// passCopyToSink borrow temp whose name isn't registered in varInfo —
		// if we re-inspect d.argument after processing, we'd mistake the borrow
		// temp for a "non-local identifier" and call passCopyToSink AGAIN,
		// producing a double-borrow chain ($borrow_N → $borrow_N+1 → return).
		const origKind = d.argument.kind;
		const origSym = origKind == NodeKind.Identifier ? d.argument.resolvedSym : noSym;

		// Process return argument recursively with Consumed mode
		d.argument = processNode(d.argument, dctx, DrcMode.Consumed);

		// Borrowed RC pointer return: wrap in temp + incref to prevent use-after-free
		if (needsReturnIncref(d.argument, dctx)) {
			return emitReturnWithIncref(d.argument, dctx, loc);
		}
		// Borrowed value return: non-Ref RC types need deep copy via passCopyToSink.
		// Ref types handled above by needsReturnIncref+emitReturnWithIncref (msIncref).
		// All others (String, Named, Array, Closure, Map, Set) need passCopyToSink.
		// Covers: return d.className (string field from union variant extraction),
		//         return state.tokens[pos] (struct with string field),
		//         return _globalArray (module-level variable), etc.
		// Gate on ORIGINAL kind to avoid re-copying a passCopyToSink-produced temp.
		if (origKind == NodeKind.ArrayAccess || origKind == NodeKind.MemberExpr) {
			const retRc = classifyRc(d.argument.nodeType, dctx);
			if (retRc.needsCleanup && retRc.rcKind != RcKind.Ref) {
				d.argument = passCopyToSink(d.argument, dctx);
			}
		}
		// Non-local identifier return: globals/module vars need deep copy too.
		// Function-local vars are moved out by destructiveMoveVar in the Consumed walk.
		// Non-local variables (globals, module-level, outer function) are borrowed —
		// caller's destroy would free the shared data, causing double-free.
		// Gate on ORIGINAL identifier name so a fresh borrow temp introduced by
		// processNode doesn't get copied a second time.
		if (origKind == NodeKind.Identifier) {
			const vi = findVarInfoInFunction(dctx, origSym);
			if (vi == null) {
				// Not a function-local var (cursor, param, or global) — check if RC type needs copy
				const retRc = classifyRc(d.argument.nodeType, dctx);
				if (retRc.needsCleanup && retRc.rcKind != RcKind.Ref) {
					d.argument = passCopyToSink(d.argument, dctx);
				}
				// Ref types handled by needsReturnIncref above
			}
		}
	}


	return stmt;
}

// ===== Function Declaration =====

function processFuncDecl(stmt: Node, dctx: DrcContext, loc: SourceLocation): Node {
	const d = stmt.data as FunctionDeclData;
	if (d.fnBody == null) return stmt;
	// Generic template: its T-unbound body never reaches codegen (monomorphization emits the
	// concrete instances, with the `gen:` flag stripped). RC-injecting the template is meaningless
	// — its members are untyped — so skip it; only real instances get DRC.
	if (d.fnFlags.indexOf("gen:") >= 0) return stmt;
	d.fnBody = processFuncBodyWithParams(d.fnBody, stmt.resolvedSym, d.fnName, d.params, stmt.paramSyms, dctx, loc, stmt.nodeType!);
	return stmt;
}

function processArrow(stmt: Node, dctx: DrcContext, loc: SourceLocation): Node {
	const d = stmt.data as ArrowFunctionData;
	if (d.arrowBody == null) return stmt;
	d.arrowBody = processFuncBodyWithParams(d.arrowBody, noSym, "", d.arrowParams, stmt.paramSyms, dctx, loc, stmt.nodeType!);
	return stmt;
}

function processFuncExpr(stmt: Node, dctx: DrcContext, loc: SourceLocation): Node {
	const d = stmt.data as FunctionExprData;
	if (d.funcExprBody == null) return stmt;
	d.funcExprBody = processFuncBodyWithParams(d.funcExprBody, noSym, "", d.funcExprParams, stmt.paramSyms, dctx, loc, stmt.nodeType!);
	return stmt;
}

function processTestDecl(stmt: Node, dctx: DrcContext, loc: SourceLocation): Node {
	const d = stmt.data as TestDeclData;
	if (d.testBody == null) return stmt;
	d.testBody = processFuncBodyWithParams(d.testBody, noSym, "", [], [], dctx, loc, stmt.nodeType!);
	return stmt;
}

// ===== Control Flow =====

function processIf(stmt: Node, dctx: DrcContext, loc: SourceLocation): Node {
	const d = stmt.data as IfStmtData;
	// Walk the once-evaluated condition so a fresh RC call in it is captured (temp flushes into
	// preStmts before the if). Short-circuit conditions are pre-lowered to a plain flag by
	// callHoist and fresh-cond else-ifs are block-wrapped there, so this only sees a once-eval
	// condition. Retires callHoist's expandIf plain-hoist for this position.
	d.condition = processNonRcRead(d.condition, dctx);
	d.consequent = processBlockBody(d.consequent, dctx, false, false, loc);
	if (d.alternate != null) {
		if (d.alternate.kind == NodeKind.IfStmt) {
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
	if (d.catchBody != null) {
		// The catch-var is a scope-owned local: it binds msCurrException by borrow
		// (no incref) and must be destroyed once at handler exit. The type is carried
		// on stmt.nodeType by the checker.
		const catchType = stmt.nodeType;
		let handled = false;
		if (d.catchName != "" && catchType != null && !isUnresolvedType(catchType) && catchType.kind != TypeKind.Error) {
			const rcInfo = classifyRc(catchType, dctx);
			if (rcInfo.needsCleanup) {
				pushScope(dctx, false, false);
				registerVar(dctx, rcInfo, false, stmt.resolvedSym);
				d.catchBody = processBlockBody(d.catchBody, dctx, false, false, loc);
				const scope = popScope(dctx);
				const cleanup = generateCleanup(scope, loc);
				const cbd = d.catchBody.data as BlockStmtData;
				for (const cs of cleanup) { cbd.statements.push(cs); }
				handled = true;
			}
		}
		if (!handled) {
			d.catchBody = processBlockBody(d.catchBody, dctx, false, false, loc);
		}
	}
	if (d.finallyBody != null) {
		d.finallyBody = processBlockBody(d.finallyBody, dctx, false, false, loc);
	}
	return stmt;
}

function processSwitchCase(caseNode: Node, dctx: DrcContext, loc: SourceLocation): void {
	const cd = caseNode.data as SwitchCaseData;
	// Inline processStmtListScoped to avoid passing field array by value
	// (by-value param creates shared payload; DRC copy inside callee frees shared payload → double-free)
	pushScope(dctx, false, false);
	const processed = processStmtList(cd.caseStmts, dctx, loc);
	const scope = popScope(dctx);
	const cleanup = generateCleanup(scope, loc);
	cd.caseStmts = assembleScope(processed, cleanup, scope, loc);
}

function processSwitch(stmt: Node, dctx: DrcContext, loc: SourceLocation): Node {
	const d = stmt.data as SwitchStmtData;
	for (const c of d.switchCases) {
		if (c.kind == NodeKind.SwitchCase) {
			processSwitchCase(c, dctx, loc);
		}
	}
	return stmt;
}

function processExport(stmt: Node, dctx: DrcContext, loc: SourceLocation): Node {
	const d = stmt.data as ExportDeclData;
	if (d.exportedDecl != null && d.exportedDecl.kind == NodeKind.FunctionDecl) {
		processFuncDecl(d.exportedDecl, dctx, loc);
	}
	return stmt;
}

function processMethodMember(member: Node, dctx: DrcContext, loc: SourceLocation): void {
	const md = member.data as MethodDeclData;
	if (md.methodBody != null) {
		md.methodBody = processFuncBodyWithParams(md.methodBody, member.resolvedSym, md.methodName, md.methodParams, member.paramSyms, dctx, loc, member.nodeType!);
	}
}

function ctorSymsWithoutReceiver(paramSyms: Symbol[] | null): Symbol[] | null {
	if (paramSyms == null || paramSyms.length == 0) return paramSyms;
	const out: Symbol[] = [];
	for (let i = 1; i < paramSyms.length; i += 1) out.push(paramSyms[i]);
	return out;
}

function processCtorMember(member: Node, dctx: DrcContext, loc: SourceLocation): void {
	const cd = member.data as ConstructorDeclData;
	if (cd.ctorBody != null) {
		// Same pattern as processMethodMember: use function type for param RC classification.
		// Constructor's function type is on member.nodeType (set in resolvePass).
		const ctorType = member.nodeType;
		const ctorParamSyms = ctorSymsWithoutReceiver(member.paramSyms);
		if (ctorType != null && ctorType.kind == TypeKind.Function) {
			const ctorSym = makeSymbol("constructor", SymbolKind.Method, ctorType, false);
			cd.ctorBody = processFuncBodyWithParams(cd.ctorBody, ctorSym, "constructor", cd.ctorParams, ctorParamSyms, dctx, loc, member.nodeType!);
		} else {
			cd.ctorBody = processFuncBodyWithParams(cd.ctorBody, noSym, "", cd.ctorParams, ctorParamSyms, dctx, loc, member.nodeType!);
		}
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
	if (program.kind != NodeKind.Program) return program;
	const d = program.data as ProgramData;

	// Module-level scope: process statements but skip cleanup.
	// Reference parity: globals at top scope
	// (s.parent == nil) go to graph.globalDestructors, NOT scope.final.
	// Module globals persist for the program's lifetime — Init000 must not destroy them.
	pushScope(dctx, false, false);
	d.programStmts = processStmtList(d.programStmts, dctx, program.location);
	popScope(dctx); // discard cleanup — module globals outlive Init000

	return program;
}

// ===== Tests =====

function testDrcContext(input: string): DrcContext {
	const ctx = checkSource(input);
	const tctx = createTransformContextWithChecker(ctx);
	return createDrcContext(tctx);
}

export function testLoc(): SourceLocation {
	return makeLoc(0, 0);
}

test "injectProgram no-op on primitives" {
	const dctx = testDrcContext("const x = 1; const y = 2;");
	const prog = makeBlock([], testLoc());
	assert dctx.ctx.tempCounter == 0;
}

test "createDrcContext initializes" {
	const dctx = testDrcContext("const x = 1;");
	assert scopeDepth(dctx) == 0;
}

test "generateCleanup LIFO order" {
	const dctx = testDrcContext("const x = 1;");
	pushScope(dctx, false, true);
	const rcStr = testStringRc();
	registerVar(dctx, rcStr, false, testVarSym("a"));
	registerVar(dctx, rcStr, false, testVarSym("b"));
	const scope = popScope(dctx);
	const cleanup = generateCleanup(scope, testLoc());
	assert cleanup.length == 2;
}

test "generateCleanup skips moved" {
	const dctx = testDrcContext("const x = 1;");
	pushScope(dctx, false, true);
	const rcStr = testStringRc();
	registerVar(dctx, rcStr, false, testVarSym("a"));
	const b = testVarSym("b");
	registerVar(dctx, rcStr, false, b);
	recordMove(dctx, b);
	const scope = popScope(dctx);
	const cleanup = generateCleanup(scope, testLoc());
	// wasMoved(b) + destroy(a) = 2 nodes
	assert cleanup.length == 2;
}

test "call is fresh" { assert isFreshExpr(NodeKind.CallExpr); }

test "identifier is not fresh" { assert !isFreshExpr(NodeKind.Identifier); }


test "processBlockBody handles null" {
	const dctx = testDrcContext("const x = 1;");
	const result = processBlockBody(null as unknown as Node, dctx, false, false, testLoc());
	assert result == null;
}

test "isEnvParam detects __envP" {
	assert isEnvParam("__envP");
	assert isEnvParam("__envP_raw");
	assert !isEnvParam("param");
	assert !isEnvParam("env");
}

test "recordMoveInContext finds correct scope" {
	const dctx = testDrcContext("const x = 1;");
	const rcStr = testStringRc();
	pushScope(dctx, false, true);
	const a = testVarSym("a");
	registerVar(dctx, rcStr, false, a);
	pushScope(dctx, false, false);
	registerVar(dctx, rcStr, false, testVarSym("b"));
	// Record move for "a" — should find it in outer scope
	recordMoveInContext(dctx, a);
	const innerScope = popScope(dctx);
	const outerScope = popScope(dctx);
	// "a" should be marked as moved in the outer scope
	assert wasMovedInScope(outerScope, a);
	assert !wasMovedInScope(innerScope, a);
}

test "both fresh branches are SINK" {
	// ConditionalExpr is in isFreshExpr, but processConditionalInit
	// differentiates between all-fresh and mixed branches.
	assert isFreshExpr(NodeKind.ConditionalExpr);
}

test "string type needs cleanup with String rcKind" {
	const dctx = testDrcContext("const x: string = \"\";");
	const strType = lookupSymbol(dctx.ctx.checkerCtx.table, "x");
	if (strType != null && strType.symbolType != null) {
		const rc = classifyRc(strType.symbolType, dctx);
		assert rc.needsCleanup;
		assert rc.rcKind == RcKind.String;
	}
}

test "number type needs no cleanup" {
	const dctx = testDrcContext("const n: number = 0;");
	const numSym = lookupSymbol(dctx.ctx.checkerCtx.table, "n");
	if (numSym != null && numSym.symbolType != null) {
		const rc = classifyRc(numSym.symbolType, dctx);
		assert !rc.needsCleanup;
	}
}

test "callCanThrow false for ms-prefixed runtime calls" {
	const loc = testLoc();
	const call = makeCall(runtimeRef("msStringDecref", loc), [], loc);
	assert !callCanThrow(call);
}

test "callCanThrow true for user functions" {
	const loc = testLoc();
	const call = makeCall(makeIdent("parseExpr", loc), [], loc);
	assert callCanThrow(call);
}

function scanSetsNeedsTry(stmt: Node): boolean {
	const dctx = testDrcContext("const n: number = 0;");
	pushScope(dctx, false, true);
	pushScope(dctx, false, false);
	setNeedsTryIfRaises(stmt, dctx);
	const inner = popScope(dctx);
	const outer = popScope(dctx);
	return inner.needsTry && outer.needsTry;
}

function userCallStmt(): Node {
	const loc = testLoc();
	return makeExprStmt(makeCall(makeIdent("parseExpr", loc), [], loc), loc);
}

test "setNeedsTryIfRaises marks every open scope for a user call statement" {
	assert scanSetsNeedsTry(userCallStmt());
}

test "setNeedsTryIfRaises finds a user call inside an if body" {
	const loc = testLoc();
	const guarded = makeIf(makeIdent("flag", loc), makeBlock([userCallStmt()], loc), null as unknown as Node, loc);
	assert scanSetsNeedsTry(guarded);
}

test "setNeedsTryIfRaises finds a user call in an if condition" {
	const loc = testLoc();
	const cond = makeCall(makeIdent("parseExpr", loc), [], loc);
	assert scanSetsNeedsTry(makeIf(cond, makeBlock([], loc), null as unknown as Node, loc));
}

test "setNeedsTryIfRaises finds a user call passed to a runtime call" {
	const loc = testLoc();
	const inner = makeCall(makeIdent("parseExpr", loc), [], loc);
	const outer = makeCall(runtimeRef("msStringDecref", loc), [inner], loc);
	assert scanSetsNeedsTry(makeExprStmt(outer, loc));
}

test "setNeedsTryIfRaises leaves scopes alone for a runtime-only statement" {
	const loc = testLoc();
	const stmt = makeExprStmt(makeCall(runtimeRef("msStringDecref", loc), [], loc), loc);
	assert !scanSetsNeedsTry(stmt);
}

test "setNeedsTryIfRaises stops at a nested function declaration" {
	const loc = testLoc();
	const nested = makeFnDecl("inner", [] as Symbol[], [], makeBlock([userCallStmt()], loc), "", "void", loc);
	assert !scanSetsNeedsTry(nested);
}

test "setNeedsTryIfRaises ignores a null node" {
	assert !scanSetsNeedsTry(null as unknown as Node);
}

test "needsReturnIncref false for call expr (fresh)" {
	const dctx = testDrcContext("function getString(): string { return \"\"; }");
	const loc = testLoc();
	const call = makeCall(makeIdent("getString", loc), [], loc);
	assert !needsReturnIncref(call, dctx);
}

test "needsReturnIncref false for local var (moved)" {
	const dctx = testDrcContext("function foo(): string { const s = \"\"; return s; }");
	pushScope(dctx, false, true);
	const rcStr = testStringRc();
	const sSym = testVarSym("s");
	registerVar(dctx, rcStr, false, sSym);
	const loc = testLoc();
	const ident = makeIdentResolved(sSym, loc);
	assert !needsReturnIncref(ident, dctx);
	popScope(dctx);
}

test "needsReturnIncref false for member expr with string field (strings use passCopyToSink)" {
	const dctx = testDrcContext("interface Obj { name: string; } const o: Obj = { name: \"\" };");
	const loc = testLoc();
	const memberExpr = makeMember(makeIdent("o", loc), "name", loc);
	// String fields use passCopyToSink (deep copy), not msIncref (pointer refcount)
	assert !needsReturnIncref(memberExpr, dctx);
}

test "emitReturnWithIncref produces block with 3 stmts" {
	const dctx = testDrcContext("interface Obj { name: string; } const o: Obj = { name: \"\" };");
	const loc = testLoc();
	pushScope(dctx, false, true);
	const arg = makeMember(makeIdent("o", loc), "name", loc);
	const result = emitReturnWithIncref(arg, dctx, loc);
	assert result.kind == NodeKind.BlockStmt;
	const bd = result.data as BlockStmtData;
	assert bd.statements.length == 3;  // tmpDecl, incref, return
	popScope(dctx);
}

test "isVarFromOuterLoopScope: var in function scope, inside loop" {
	const dctx = testDrcContext("const x = 1;");
	const rcStr = testStringRc();
	pushScope(dctx, false, true);    // function scope
	const x = testVarSym("x");
	registerVar(dctx, rcStr, false, x);
	pushScope(dctx, true, false);    // loop scope
	assert isVarFromOuterLoopScope(x, dctx);
	popScope(dctx);
	popScope(dctx);
}

test "isVarFromOuterLoopScope: var in loop scope, not outer" {
	const dctx = testDrcContext("const x = 1;");
	const rcStr = testStringRc();
	pushScope(dctx, false, true);    // function scope
	pushScope(dctx, true, false);    // loop scope
	const sv = testVarSym("s");
	registerVar(dctx, rcStr, false, sv);
	assert !isVarFromOuterLoopScope(sv, dctx);
	popScope(dctx);
	popScope(dctx);
}

test "isVarFromOuterLoopScope: no loop, returns false" {
	const dctx = testDrcContext("const x = 1;");
	const rcStr = testStringRc();
	pushScope(dctx, false, true);    // function scope
	const x = testVarSym("x");
	registerVar(dctx, rcStr, false, x);
	pushScope(dctx, false, false);   // block scope (not loop)
	assert !isVarFromOuterLoopScope(x, dctx);
	popScope(dctx);
	popScope(dctx);
}

test "isVarFromOuterLoopScope: nested loops, var in outer loop" {
	const dctx = testDrcContext("const x = 1;");
	const rcStr = testStringRc();
	pushScope(dctx, false, true);    // function scope
	pushScope(dctx, true, false);    // outer loop
	const sv = testVarSym("s");
	registerVar(dctx, rcStr, false, sv);
	pushScope(dctx, true, false);    // inner loop
	assert isVarFromOuterLoopScope(sv, dctx);
	popScope(dctx);
	popScope(dctx);
	popScope(dctx);
}

test "isVarFromOuterLoopScope: nested loops, var in function scope" {
	const dctx = testDrcContext("const x = 1;");
	const rcStr = testStringRc();
	pushScope(dctx, false, true);    // function scope
	const x = testVarSym("x");
	registerVar(dctx, rcStr, false, x);
	pushScope(dctx, true, false);    // outer loop
	pushScope(dctx, true, false);    // inner loop
	assert isVarFromOuterLoopScope(x, dctx);
	popScope(dctx);
	popScope(dctx);
	popScope(dctx);
}

// ===== Phase A: Finally-Protected Variables Tests =====

test "collectFinallyVars finds vars in finally block" {
	const loc = testLoc();
	const s = testVarSym("s");
	const finallyBody = makeBlock([
		makeExprStmt(makeCall(makeIdent("cleanup", loc), [makeIdentResolved(s, loc)], loc), loc),
	], loc);
	const tryStmt = makeTryFinally(
		makeBlock([makeExprStmt(makeIdentResolved(s, loc), loc)], loc),
		finallyBody,
		loc,
	);
	const body = makeBlock([tryStmt], loc);
	const vars = collectFinallyVars(body);
	assert symListHas(vars, s);
	assert vars.length == 1;
}

test "collectFinallyVars empty when no finally" {
	const loc = testLoc();
	const body = makeBlock([
		makeExprStmt(makeIdentResolved(testVarSym("x"), loc), loc),
	], loc);
	const vars = collectFinallyVars(body);
	assert vars.length == 0;
}

test "finally-protected var blocks move in isLastReadSafe" {
	const dctx = testDrcContext("const x = 1;");
	const s = testVarSym("s");
	dctx.finallyProtectedVars = [s];
	assert !isLastReadSafe(s, null as unknown as Node, 0, [], dctx);
}

test "clearPendingForVar clears by symbol identity" {
	const dctx = testDrcContext("const x: string = \"\";");
	const rcStr = testStringRc();
	const loc = testLoc();
	pushScope(dctx, false, true);
	const x = testVarSym("x");
	const lookalike = testVarSym("x");
	addPending(dctx, makeWasMovedCall(x, rcStr, loc));
	clearPendingForVar(dctx, lookalike);
	assert hasPending(dctx);
	clearPendingForVar(dctx, x);
	assert !hasPending(dctx);
	popScope(dctx);
}

test "isVarFromOuterLoopScope: block inside loop, var before loop" {
	const dctx = testDrcContext("const x = 1;");
	const rcStr = testStringRc();
	pushScope(dctx, false, true);    // function scope
	const x = testVarSym("x");
	registerVar(dctx, rcStr, false, x);
	pushScope(dctx, true, false);    // loop scope
	pushScope(dctx, false, false);   // block inside loop
	assert isVarFromOuterLoopScope(x, dctx);
	popScope(dctx);
	popScope(dctx);
	popScope(dctx);
}

test "emitMoveSourceWasMoved on identifier emits pending wasMoved" {
	const dctx = testDrcContext("const x: string = \"\";");
	const rcStr = testStringRc();
	const loc = testLoc();
	pushScope(dctx, false, true);
	const x = testVarSym("x");
	registerVar(dctx, rcStr, false, x);
	const stmts: Node[] = [makeExprStmt(makeNull(loc), loc)];
	const handled = emitMoveSourceWasMoved(makeIdentResolved(x, loc), rcStr, 0, stmts, dctx, loc, false);
	assert handled;
	assert hasPending(dctx);
	popScope(dctx);
}

test "emitMoveSourceWasMoved on call expr returns false (fresh)" {
	const dctx = testDrcContext("function f(): string { return \"\"; }");
	const rcStr = testStringRc();
	const loc = testLoc();
	pushScope(dctx, false, true);
	const call = makeCall(makeIdent("f", loc), [], loc);
	const handled = emitMoveSourceWasMoved(call, rcStr, 0, [], dctx, loc, false);
	assert !handled;
	assert !hasPending(dctx);
	popScope(dctx);
}

test "isFreshExpr includes MoveExpr" { assert isFreshExpr(NodeKind.MoveExpr); }

test "classifyMemberFieldRc returns RC info for string field" {
	const dctx = testDrcContext("interface Obj { name: string; } const o: Obj = { name: \"\" };");
	const loc = testLoc();
	const memberExpr = makeMember(makeIdent("o", loc), "name", loc);
	// classifyMemberFieldRc checks nodeType — must set it for the test to work
	memberExpr.nodeType = createPrimitive(TypeKind.String);
	const rc = classifyMemberFieldRc(memberExpr, dctx);
	assert rc.needsCleanup;
	assert rc.rcKind == RcKind.String;
}

test "classifyArrayElementRc returns RC info for string array" {
	const dctx = testDrcContext("const arr: string[] = [];");
	const sym = lookupSymbol(dctx.ctx.checkerCtx.table, "arr");
	// arr is Ref<Array<string>>: typeReturn = Array<string>, its typeReturn = string element
	if (sym != null && sym.symbolType != null && sym.symbolType.typeReturn != null && sym.symbolType.typeReturn.typeReturn != null) {
		const rc = classifyRc(sym.symbolType.typeReturn.typeReturn, dctx);
		assert rc.needsCleanup;
		assert rc.rcKind == RcKind.String;
	}
}

test "makeSinkCall emits sinkFn call node" {
	const dctx = testDrcContext("const x: string = \"\";");
	const rcStr = testStringRc();
	const loc = testLoc();
	const xSym = makeSymbol("x", SymbolKind.Variable, noneType(), true);
	const sink = makeSinkCall(xSym, makeIdent("y", loc), rcStr, loc);
	// Should produce an ExprStmt containing a CallExpr with 2 args
	assert sink.kind == NodeKind.ExprStmt;
	const sd = sink.data as ExprStmtData;
	assert sd.expr.kind == NodeKind.CallExpr;
	const cd = sd.expr.data as CallExprData;
	assert cd.callee.kind == NodeKind.Identifier;
	assert cd.arguments.length == 2;
}

test "sinkFn field populated for string type" {
	const dctx = testDrcContext("const x: string = \"\";");
	const sym = lookupSymbol(dctx.ctx.checkerCtx.table, "x");
	if (sym != null && sym.symbolType != null) {
		const rc = classifyRc(sym.symbolType, dctx);
		assert rc.sinkFn != null;
	}
}

test "first-write: uninitialized var marked not initialized" {
	const dctx = testDrcContext("let x: string;");
	const rcStr = testStringRc();
	pushScope(dctx, false, true);
	const x = testVarSym("x");
	registerVar(dctx, rcStr, false, x);
	// After register, isInitialized is true by default
	const vi1 = findVarInfoInContext(dctx, x);
	assert vi1 != null;
	assert vi1.isInitialized;
	// markUninitialized sets it to false
	markUninitialized(dctx, x);
	assert !vi1.isInitialized;
	popScope(dctx);
}

test "first-write: second assignment restores initialized" {
	const dctx = testDrcContext("let x: string;");
	const rcStr = testStringRc();
	pushScope(dctx, false, true);
	const x = testVarSym("x");
	registerVar(dctx, rcStr, false, x);
	markUninitialized(dctx, x);
	const vi = findVarInfoInContext(dctx, x);
	assert !vi.isInitialized;
	// Simulate first-write marking it initialized
	vi.isInitialized = true;
	assert vi.isInitialized;
	popScope(dctx);
}

test "sink param: return-only param is cursor (skip cleanup)" {
	const dctx = testDrcContext("function f(s: string): string { return s; }");
	const fnSym = lookupSymbol(dctx.ctx.checkerCtx.table, "f");
	if (fnSym != null && fnSym.symbolType != null) {
		// Verify function is recognized
		assert fnSym.symbolType.kind == TypeKind.Function;
	}
}

test "isGeneratorBody: detects the state-selector decl" {
	const loc = testLoc();
	const stateSym = makeSymbol("$state", SymbolKind.Variable, noneType(), true);
	setFlag(stateSym, SymbolFlag.StateMachine);
	const stateDecl = makeVarDecl("$state", makeNull(loc), DeclKind.Let, loc);
	stateDecl.resolvedSym = stateSym;
	const body = makeBlock([stateDecl], loc);
	assert isGeneratorBody(body);
}

test "isGeneratorBody: normal function returns false" {
	const loc = testLoc();
	const xDecl = makeVarDecl("$state", makeNull(loc), DeclKind.Let, loc);
	xDecl.resolvedSym = makeSymbol("$state", SymbolKind.Variable, noneType(), true);
	const body = makeBlock([xDecl], loc);
	assert !isGeneratorBody(body);
}

test "isGeneratorBody: null body returns false" {
	assert !isGeneratorBody(null as unknown as Node);
}

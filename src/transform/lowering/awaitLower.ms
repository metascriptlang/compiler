// Await Lowering — sync-context AwaitExpr → typed future read or AwaitGroup
//
// Runs AFTER asyncDesugar (which converts await → yield inside async functions)
// and AFTER spawnLower (which boxes spawn closure return values). Any AwaitExpr
// node that survives past asyncDesugar is by definition in sync context — no
// ExecContext flags needed.
//
// Two paths based on expression shape:
//
// 1. Deferred (await handle): typed future reader for primitives, void* for rest.
//      const x = await handle;
//      →  (primitive: double, int32, bool)
//      msWaitForReady(handle);
//      const x = msFutureReadDouble(handle);
//      →  (struct/string/ref — void* fallback)
//      const x = msUnboxT(msWaitFor(handle));
//
// 2. Fused (await spawn(fn)): AwaitGroup lifecycle (PARALOCK §6.3).
//      const x = await spawn(fn);
//      →
//      const $ag = msAwaitGroupInit(1);
//      msSpawnTaskSubmit($ag, 0, fn);
//      msAwaitGroupBlocking($ag);
//      msAwaitGroupCheckFailed($ag);
//      const x = msUnboxT(msAwaitGroupResult($ag, 0));
//      msAwaitGroupFree($ag);
//
// REPROMISE T3 Stage A. See docs/PARALOCK.md §6.3 for the AwaitGroup lifecycle.

import {
	BlockStmtData, FunctionDeclData, MethodDeclData, ConstructorDeclData, TestDeclData,
} from "../../ast/node";
import {
	Node, NodeKind, NodeFlag, DeclKind, SourceLocation,
	VariableDeclData, ExprStmtData, ReturnStmtData, AssertStmtData,
	AwaitExprData, CallExprData, ObjectLiteralData, ExportDeclData, ProgramData,
	Type, NodeData, createNodeAt,
} from "../../ast/node";
import { TransformContext, ModuleFact, freshTempSym, freshOwnedSym, SymSet, createSymSet, symSetAdd, symSetContains, noteFact } from "../context";
import { skipsModule } from "../moduleFacts";
import { forEachChild, anyDescendant, Visit } from "../../ast/visitor";
import { walkExpandBlocksHooked, containsExprKind, walkNode } from "../walker";
import { makeCall, makeVarDecl, makeExprStmt, makeNumber, makeIdentResolved, makeBlock, makeReturn, makeString, makeIf, makeBinary, makeAssign, makeDefaultValue, unboxVoidPtrToTyped, runtimeRef, attachedOpSym, makeTypedIdentResolved, isRuntimeProcSym, ownedInFuture, isSoleFutureRead, makeFutureCopyRead, makeOwnsValueCheck, typedFutureReadFn, makeBool, makeUnary } from "../util";
import { lowerDefer } from "./deferLower";
import { createPtr, createPrimitive, awaitedType, booleanType, closureStorageType } from "../../checker/types";
import { TypeKind, AttachedOp, FunctionExprData, ArrowFunctionData, IdentifierData } from "../../ast/node";
import { injectCancelSafePoints } from "./cancelSafePoints";
import { RoutineFlag, routineFlagSet, setFlag, SymbolFlag } from "../../checker/symbol";
import { Symbol } from "../../ast/node";

// ===== Scoped Deferred → msAwaitSlot (Change 1) =====
// Tracks `const h = spawn(fn);` declarations. When `await h` is later found
// in the same scope, rewrites to zero-alloc msAwaitSlot path instead of
// heap-allocated msFuture. Cleared at function boundaries.
struct SpawnSlotEntry { slotIdent: Node; task: Symbol | null; innerType: Type | null; joined: Symbol | null; }
let _spawnSlotMap: HashMap<Symbol, SpawnSlotEntry> = new HashMap<Symbol, SpawnSlotEntry>();
let _awaitOnlyHandles: SymSet = createSymSet();
let _moduleLevelHandles: SymSet = createSymSet();
let _settleDeferred = false;
interface SpawnSlotFrame { slots: HashMap<Symbol, SpawnSlotEntry>; handles: SymSet; }
let _spawnSlotFrames: SpawnSlotFrame[] = [];

function isBuiltinSpawnCall(init: Node): boolean {
	const si = getSpawnInfo(init);
	const initSym = init.resolvedSym != null ? init.resolvedSym
		: (init.kind == NodeKind.CallExpr ? (init.data as CallExprData).callee.resolvedSym : null);
	return si.closure != null && si.timeout == null && initSym != null && initSym.builtinKind == "PromiseSpawn";
}

function scanHandleUses(n: Node | null, nested: boolean, decls: SymSet, others: SymSet): void {
	if (n == null) return;
	if (n.kind == NodeKind.Identifier) {
		if (n.resolvedSym != null) symSetAdd(others, n.resolvedSym);
		return;
	}
	if (!nested && n.kind == NodeKind.AwaitExpr) {
		const arg = (n.data as AwaitExprData).awaitArg;
		if (arg != null && arg.kind == NodeKind.Identifier) return;
	}
	if (!nested && n.kind == NodeKind.VariableDecl) {
		const d = n.data as VariableDeclData;
		if (d.declKind == DeclKind.Const && d.initializer != null && isBuiltinSpawnCall(d.initializer) && n.resolvedSym != null) symSetAdd(decls, n.resolvedSym);
	}
	const inner = nested || n.kind == NodeKind.FunctionDecl || n.kind == NodeKind.FunctionExpr || n.kind == NodeKind.ArrowFunction;
	forEachChild(n, (c: Node): void => { scanHandleUses(c, inner, decls, others); });
}

function awaitOnlyHandles(fn: Node): SymSet {
	const decls = createSymSet();
	const others = createSymSet();
	forEachChild(fn, (c: Node): void => { scanHandleUses(c, false, decls, others); });
	const out = createSymSet();
	for (const sym of decls.items) {
		if (!symSetContains(others, sym)) symSetAdd(out, sym);
	}
	return out;
}

function enterSpawnSlotFrame(fn: Node): void {
	_spawnSlotFrames.push({ slots: _spawnSlotMap, handles: _awaitOnlyHandles });
	_spawnSlotMap = new HashMap<Symbol, SpawnSlotEntry>();
	_awaitOnlyHandles = awaitOnlyHandles(fn);
}

function exitSpawnSlotFrame(_fn: Node): void {
	const frame = _spawnSlotFrames.pop();
	_spawnSlotMap = frame.slots;
	_awaitOnlyHandles = frame.handles;
}

function bindTask(ctx: TransformContext, closure: Node, loc: SourceLocation): { decl: Node, ident: Node, sym: Symbol } | null {
	if (closure.kind != NodeKind.CallExpr || closure.nodeType == null || closure.nodeType!.kind != TypeKind.Function) return null;
	const t = closureStorageType(closure.nodeType!);
	const sym = freshOwnedSym(ctx, "task", t);
	const decl = makeVarDecl(sym.name, closure, DeclKind.Const, loc);
	decl.nodeType = t;
	decl.resolvedSym = sym;
	return { decl, ident: makeIdentResolved(sym, loc), sym };
}

function dropTask(task: Symbol | null, loc: SourceLocation): Node[] {
	if (task == null) return [];
	return [ makeExprStmt(makeCall(makeTypedIdentResolved(attachedOpSym("msClosureDestroy", AttachedOp.AttachedDestructor), null, loc), [makeIdentResolved(task!, loc)], loc), loc)];
}

function settleOnExit(slot: Symbol, joined: Symbol, task: Symbol | null, loc: SourceLocation): Node {
	const notJoined = makeUnary("!", makeIdentResolved(joined, loc), loc);
	notJoined.nodeType = booleanType();
	const settle = makeExprStmt(makeCall(runtimeRef("msAwaitSlotSettle", loc), [makeIdentResolved(slot, loc)], loc), loc);
	const deferData: NodeData = { deferExpr: makeBlock([makeIf(notJoined, makeBlock([settle], loc), null, loc)].concat(dropTask(task, loc)), loc) };
	_settleDeferred = true;
	return createNodeAt(NodeKind.DeferStmt, deferData, loc);
}

function moduleLevelHandles(program: Node): SymSet {
	const out = createSymSet();
	for (const stmt of (program.data as ProgramData).programStmts) {
		if (stmt.kind == NodeKind.VariableDecl && stmt.resolvedSym != null) symSetAdd(out, stmt.resolvedSym!);
	}
	return out;
}

// Opaque pointer type → void* in C codegen. Used for AwaitGroup and result temps.
export const VOID_PTR_TYPE: Type = createPtr(createPrimitive(TypeKind.Void));

// P9 DRY: extract the 5-line "temp sym → call → typed VarDecl" pattern that
// repeats across fused, deferred, and timeout paths.
export function makeTempDecl(ctx: TransformContext, prefix: string, initExpr: Node, t: Type | null, loc: SourceLocation): { decl: Node, ident: Node, sym: Symbol } {
	const sym = freshTempSym(ctx, prefix, t);
	initExpr.nodeType = t;
	const decl = makeVarDecl(sym.name, initExpr, DeclKind.Const, loc);
	decl.nodeType = t;
	decl.resolvedSym = sym;
	return { decl, ident: makeIdentResolved(sym, loc), sym };
}

// ===== Unboxing =====
// Thin wrapper around the shared util helper. Kept named for callers below.
// Dispatch lives in util.ts to stay in sync with promiseLower's waitFor.
export function makeUnboxCall(voidPtrExpr: Node, innerType: Type | null, loc: SourceLocation): Node {
	return unboxVoidPtrToTyped(voidPtrExpr, innerType, loc);
}

// Get the inner type that an await expression should produce.
// Uses the T1/T2 semantic layer: if the expression type is `Promise<T>` (plain or affine),
// extract T. Otherwise returns null (let C handle it as void*).
function getAwaitInnerType(awaitArgExpr: Node): Type | null {
	if (awaitArgExpr == null || awaitArgExpr.nodeType == null) return null;
	return awaitedType(awaitArgExpr.nodeType);
}

// ===== Spawn Detection =====

// Check if a node is a spawn() call. Returns the closure argument and optional
// timeout from the options object: spawn(fn, { timeout: N }).
export function getSpawnInfo(node: Node): { closure: Node | null, timeout: Node | null } {
	if (node == null || node.kind != NodeKind.CallExpr) return { closure: null, timeout: null };
	const cd = node.data as CallExprData;
	const sym = node.resolvedSym != null ? node.resolvedSym : cd.callee.resolvedSym;
	if (sym == null || (sym.builtinKind != "PromiseSpawn" && !isRuntimeProcSym(sym, "msSpawn"))) return { closure: null, timeout: null };
	if (cd.arguments.length < 1) return { closure: null, timeout: null };
	const closure = cd.arguments[0];
	let timeout: Node | null = null;
	// Extract timeout from options object: spawn(fn, { timeout: N })
	if (cd.arguments.length >= 2 && cd.arguments[1].kind == NodeKind.ObjectLiteral) {
		const opts = cd.arguments[1].data as ObjectLiteralData;
		let i = 0;
		while (i < opts.keys.length) {
			if (opts.keys[i] == "timeout") {
				timeout = opts.properties[i];
				break;
			}
			i = i + 1;
		}
	}
	return { closure, timeout };
}

// ===== Timeout Helper =====

// A joined slot's result, read into an owned local of its type before the group can
// raise, so a sibling's failure or a timeout destroys it with the scope. A failed or
// skipped slot holds null, which reads as the type's default.
export function readGroupSlot(ctx: TransformContext, agIdent: Node, slot: int32, innerType: Type | null, loc: SourceLocation): { stmts: Node[], value: Node } {
	const raw = (): Node => {
		const c = makeCall(runtimeRef("msAwaitGroupResult", loc), [agIdent, makeNumber(slot, loc)], loc);
		c.nodeType = VOID_PTR_TYPE;
		return c;
	};
	if (innerType == null || innerType.kind == TypeKind.Void) {
		const t = makeTempDecl(ctx, "agr", raw(), VOID_PTR_TYPE, loc);
		return { stmts: [t.decl], value: t.ident };
	}
	const sym = freshOwnedSym(ctx, "agr", innerType);
	const decl = makeVarDecl(sym.name, makeDefaultValue(innerType, loc), DeclKind.Let, loc);
	decl.nodeType = innerType;
	decl.resolvedSym = sym;
	const value = makeUnboxCall(raw(), innerType, loc);
	value.nodeType = innerType;
	const take = makeExprStmt(makeAssign(makeIdentResolved(sym, loc), value, loc), loc);
	const present = makeBinary(raw(), "!=", makeDefaultValue(VOID_PTR_TYPE, loc), loc);
	return { stmts: [decl, makeIf(present, makeBlock([take], loc), null, loc)], value: makeIdentResolved(sym, loc) };
}

// Waits for the group, then runs `reads` while every slot is still held: a timed
// wait that expires joins the children first and throws only after the reads.
export function emitAwaitGroupWait(agIdent: Node, timeoutExpr: Node | null, loc: SourceLocation, ctx: TransformContext, reads: Node[]): Node[] {
	const stmts: Node[] = [];
	if (timeoutExpr == null) {
		stmts.push(makeExprStmt(
			makeCall(runtimeRef("msAwaitGroupBlocking", loc), [agIdent], loc), loc));
		for (const r of reads) stmts.push(r);
		return stmts;
	}
	// Phase 3: timed wait — const $deadline = msMonoTimeMs() + timeoutExpr;
	const int64Type = createPrimitive(TypeKind.Int64);
	const nowCall = makeCall(runtimeRef("msMonoTimeMs", loc), [], loc);
	nowCall.nodeType = int64Type;
	const dl = makeTempDecl(ctx, "deadline", makeBinary(nowCall, "+", timeoutExpr, loc), int64Type, loc);
	stmts.push(dl.decl);

	// msAwaitGroupBlockingWithDeadline($ag, $deadline);
	stmts.push(makeExprStmt(
		makeCall(runtimeRef("msAwaitGroupBlockingWithDeadline", loc), [
			agIdent, dl.ident,
		], loc), loc));

	// if (msAwaitGroupTimedOut($ag)) msAwaitGroupBlocking($ag);  reads;
	// if (msAwaitGroupTimedOut($ag)) { msAwaitGroupFree($ag); throw "await timeout"; }
	// The timed wait has already set the cancel flag (safe-points injected into
	// the children see it and unwind); JOIN the children before freeing: msAwaitGroupFree's
	// contract (awaitGroup.h) forbids freeing during an outstanding submission
	// - it spins on finishDone, which only the last finishSlot sets, so a
	// free-while-in-flight hangs forever when a child is still blocked. The
	// join is safe on the loop thread: the blocking wait pumps the event loop
	// while waiting, which is exactly what unblocks a timer-parked child.
	// msAwaitGroupFree reports a child failure only that join observed.
	const timedOut = (): Node => {
		const c = makeCall(runtimeRef("msAwaitGroupTimedOut", loc), [agIdent], loc);
		c.nodeType = booleanType();
		return c;
	};
	const joinCall = makeExprStmt(
		makeCall(runtimeRef("msAwaitGroupBlocking", loc), [agIdent], loc), loc);
	stmts.push(makeIf(timedOut(), makeBlock([joinCall], loc), null, loc));
	for (const r of reads) stmts.push(r);
	const freeCall = makeExprStmt(
		makeCall(runtimeRef("msAwaitGroupFree", loc), [agIdent], loc), loc);
	const throwData: NodeData = { throwArg: makeString("await timeout", loc) };
	const throwNode = createNodeAt(NodeKind.ThrowStmt, throwData, loc);
	stmts.push(makeIf(timedOut(), makeBlock([freeCall, throwNode], loc), null, loc));

	return stmts;
}

// ===== Fused Path: await spawn(fn) → zero-alloc or AwaitGroup lifecycle =====

// Fast path (no timeout): stack-allocated msAwaitSlot — zero heap alloc, zero condvar.
// Emits: $as = msAwaitSlotCreate(1); msSpawnSlotSubmit($as, 0, closure);
//        msAwaitSlotWait($as); result = msAwaitSlotResult($as); msAwaitSlotRelease();
// Slow path (timeout): heap-allocated msAwaitGroup with mutex/condvar for timed wait.
function expandFusedAwait(closureArg: Node, loc: SourceLocation, ctx: TransformContext): { stmts: Node[], resultIdent: Node } {
	// Fast path: stack-allocated msAwaitSlot (Malebolgia parity)
	const stmts: Node[] = [];

	// 1. const $as = msAwaitSlotCreate(1);
	const as = makeTempDecl(ctx, "as", makeCall(runtimeRef("msAwaitSlotCreate", loc), [makeNumber(1, loc)], loc), VOID_PTR_TYPE, loc);
	stmts.push(as.decl);

	// 2. msSpawnSlotSubmit($as, 0, closure);
	const task = bindTask(ctx, closureArg, loc);
	if (task != null) stmts.push(task!.decl);
	stmts.push(makeExprStmt(
		makeCall(runtimeRef("msSpawnSlotSubmit", loc), [as.ident, makeNumber(0, loc), task != null ? task!.ident : closureArg], loc), loc));

	// 3. msAwaitSlotWait($as); the joined task's closure and its moved captures drop here.
	stmts.push(makeExprStmt(
		makeCall(runtimeRef("msAwaitSlotWait", loc), [as.ident], loc), loc));
	for (const d of dropTask(task != null ? task!.sym : null, loc)) stmts.push(d);

	// 4. const $agr = msAwaitSlotResult($as);
	const agr = makeTempDecl(ctx, "agr", makeCall(runtimeRef("msAwaitSlotResult", loc), [as.ident], loc), VOID_PTR_TYPE, loc);
	stmts.push(agr.decl);

	// 5. msAwaitSlotRelease($as);
	stmts.push(makeExprStmt(
		makeCall(runtimeRef("msAwaitSlotRelease", loc), [as.ident], loc), loc));

	return { stmts, resultIdent: agr.ident };
}

// Heap-allocated AwaitGroup path — used when timeout is needed (mutex+condvar for timed wait).
// The result comes back typed.
function expandFusedAwaitHeap(closureArg: Node, loc: SourceLocation, ctx: TransformContext, timeoutExpr: Node, innerType: Type | null): { stmts: Node[], resultIdent: Node } {
	const stmts: Node[] = [];

	// 1. const $ag = msAwaitGroupInit(1);
	const ag = makeTempDecl(ctx, "ag", makeCall(runtimeRef("msAwaitGroupInit", loc), [makeNumber(1, loc)], loc), VOID_PTR_TYPE, loc);
	stmts.push(ag.decl);

	// 2. Inject cancel safe-points into the closure body
	let closureBody: Node | null = null;
	if (closureArg.kind == NodeKind.FunctionExpr) {
		closureBody = (closureArg.data as FunctionExprData).funcExprBody;
	} else if (closureArg.kind == NodeKind.ArrowFunction) {
		closureBody = (closureArg.data as ArrowFunctionData).arrowBody;
	}
	if (closureBody != null) {
		injectCancelSafePoints(closureBody, ag.ident, loc);
	}

	// 3. msSpawnTaskSubmit($ag, 0, closure);
	stmts.push(makeExprStmt(
		makeCall(runtimeRef("msSpawnTaskSubmit", loc), [ag.ident, makeNumber(0, loc), closureArg], loc), loc));

	// 4. Blocking wait with deadline, the result read before any raise
	const read = readGroupSlot(ctx, ag.ident, 0, innerType, loc);
	const waitStmts = emitAwaitGroupWait(ag.ident, timeoutExpr, loc, ctx, read.stmts);
	for (const ws of waitStmts) stmts.push(ws);
	stmts.push(makeExprStmt(
		makeCall(runtimeRef("msAwaitGroupCheckFailed", loc), [ag.ident], loc), loc));

	// 5. msAwaitGroupFree($ag);
	stmts.push(makeExprStmt(
		makeCall(runtimeRef("msAwaitGroupFree", loc), [ag.ident], loc), loc));

	return { stmts, resultIdent: read.value };
}

// ===== Deferred Path: await handle → msFutureReadT(handle) or msWaitFor(handle) =====

// Used when the spawn result was stored in a variable first. For primitive
// types (double, int32, bool), emits a typed future reader (msFutureReadDouble
// etc.) that handles both boxed and typed future layouts internally via the
// isBoxed flag — no separate unbox step needed. For structs/refs/strings,
// falls back to msWaitFor + unbox.
function expandDeferredAwait(handleExpr: Node, loc: SourceLocation, ctx: TransformContext, innerType: Type | null): { stmts: Node[], resultIdent: Node, typed: boolean } {
	const stmts: Node[] = [];

	// If handleExpr is a complex expression (call, member, etc.), hoist it into
	// a temp so it's only evaluated once. Without this, actor CALL futures get
	// created twice — once for msWaitForReady and once for msFutureReadT — and
	// the second future is never awaited, causing an assertion failure.
	const soleRead = isSoleFutureRead(handleExpr);
	let futIdent = handleExpr;
	if (handleExpr.kind != NodeKind.Identifier) {
		const tmp = makeTempDecl(ctx, "fut", handleExpr, handleExpr.nodeType, loc);
		// Parked-handle marker, on the SYMBOL (survives every later node rewrite —
		// extension-method and call-hoist passes rebuild the CallExpr node): the
		// analyzer reads it while walking this decl's initializer and keeps moved
		// args as borrows — the caller suspends on msWaitForReady below, so its
		// scope provably outlives the message flight. Unmarked actor proxy calls
		// are SEND-class handoffs (no park) and consume their plain-ref args.
		setFlag(tmp.sym, SymbolFlag.AwaitHandle);
		stmts.push(tmp.decl);
		futIdent = tmp.ident;
	}

	if (!soleRead && innerType != null && ownedInFuture(innerType)) {
		return expandSharedAwait(futIdent, stmts, loc, ctx, innerType);
	}

	// Typed path: msWaitForReady(handle) + msFutureReadT(handle) → typed value
	// msWaitForReady blocks until the future finishes (without consuming the value),
	// then msFutureReadT extracts the typed value from the future struct.
	const readFn = typedFutureReadFn(innerType);
	if (readFn != "") {
		stmts.push(makeExprStmt(
			makeCall(runtimeRef("msWaitForReady", loc), [futIdent], loc), loc));
		const res = makeTempDecl(ctx, "aw", makeCall(runtimeRef(readFn, loc), [futIdent], loc), innerType, loc);
		stmts.push(res.decl);
		return { stmts, resultIdent: res.ident, typed: true };
	}

	// Fallback: void* path (structs, refs, strings) — caller must apply unboxing
	const res = makeTempDecl(ctx, "aw", makeCall(runtimeRef("msWaitFor", loc), [futIdent], loc), VOID_PTR_TYPE, loc);
	stmts.push(res.decl);
	return { stmts, resultIdent: res.ident, typed: false };
}

// An await of a future that other code may also read: an owning future keeps its
// value and this reader copies it; a future completed across threads has one
// reader, which takes the value as before.
function expandSharedAwait(futIdent: Node, stmts: Node[], loc: SourceLocation, ctx: TransformContext, innerType: Type): { stmts: Node[], resultIdent: Node, typed: boolean } {
	const fut = (): Node => futIdent.resolvedSym != null ? makeIdentResolved(futIdent.resolvedSym!, loc) : futIdent;
	stmts.push(makeExprStmt(makeCall(runtimeRef("msWaitForReady", loc), [fut()], loc), loc));
	const res = makeTempDecl(ctx, "aw", makeDefaultValue(innerType, loc), innerType, loc);
	(res.decl.data as VariableDeclData).declKind = DeclKind.Let;
	stmts.push(res.decl);
	const readFn = typedFutureReadFn(innerType);
	let take: Node | null = null;
	if (readFn != "") {
		take = makeCall(runtimeRef(readFn, loc), [fut()], loc);
		take.nodeType = innerType;
	} else {
		const raw = makeCall(runtimeRef("msWaitFor", loc), [fut()], loc);
		raw.nodeType = VOID_PTR_TYPE;
		take = makeUnboxCall(raw, innerType, loc);
	}
	const copy = makeFutureCopyRead(fut(), innerType, loc);
	stmts.push(makeIf(makeOwnsValueCheck(fut(), loc),
		makeBlock([makeExprStmt(makeAssign(makeIdentResolved(res.sym, loc), copy, loc), loc)], loc),
		makeBlock([makeExprStmt(makeAssign(makeIdentResolved(res.sym, loc), take!, loc), loc)], loc), loc));
	return { stmts, resultIdent: makeIdentResolved(res.sym, loc), typed: true };
}

// ===== Unified Expansion =====

// Dispatches to fused (AwaitGroup) or deferred (msFutureReadT / msWaitFor)
// based on whether the awaited expression is a direct spawn() call.
// Fused path: AwaitGroup stores void* — still needs unboxing.
// Deferred path: typed reader handles both boxed/typed futures internally.
function expandSingleAwait(awaitArg: Node, loc: SourceLocation, ctx: TransformContext): { stmts: Node[], resultIdent: Node } {
	const spawnInfo = getSpawnInfo(awaitArg);
	const innerType = getAwaitInnerType(awaitArg);
	if (spawnInfo.closure != null) {
		if (spawnInfo.timeout != null) return expandFusedAwaitHeap(spawnInfo.closure, loc, ctx, spawnInfo.timeout!, innerType);
		// Fused path: AwaitGroup → void* results, needs unboxing
		let expansion = expandFusedAwait(spawnInfo.closure, loc, ctx);
		if (innerType != null) {
			expansion.resultIdent = makeUnboxCall(expansion.resultIdent, innerType, loc);
		}
		return expansion;
	}
	// Scoped deferred: `const h = spawn(fn); ... await h;` → msAwaitSlot
	// Check if the awaited identifier was registered as a spawn handle in this scope.
	if (awaitArg.kind == NodeKind.Identifier) {
		const handleSym = awaitArg.resolvedSym;
		const slotEntry = handleSym != null ? _spawnSlotMap.get(handleSym) : null;
		if (slotEntry != null && handleSym != null) {
			_spawnSlotMap.delete(handleSym);
			const stmts: Node[] = [];
			// msAwaitSlotWait($slot);
			stmts.push(makeExprStmt(
				makeCall(runtimeRef("msAwaitSlotWait", loc), [slotEntry.slotIdent], loc), loc));
			for (const d of dropTask(slotEntry.task, loc)) stmts.push(d);
			if (slotEntry.joined != null) {
				stmts.push(makeExprStmt(makeAssign(makeIdentResolved(slotEntry.joined!, loc), makeBool(true, loc), loc), loc));
			}
			// const $agr = msAwaitSlotResult($slot);
			const agr = makeTempDecl(ctx, "agr", makeCall(runtimeRef("msAwaitSlotResult", loc), [slotEntry.slotIdent], loc), VOID_PTR_TYPE, loc);
			stmts.push(agr.decl);
			// msAwaitSlotRelease($slot);
			stmts.push(makeExprStmt(
				makeCall(runtimeRef("msAwaitSlotRelease", loc), [slotEntry.slotIdent], loc), loc));
			let resultIdent = agr.ident;
			if (slotEntry.innerType != null) {
				resultIdent = makeUnboxCall(resultIdent, slotEntry.innerType, loc);
			}
			return { stmts, resultIdent };
		}
	}

	// Deferred path: typed future reader for primitives, msWaitFor for rest.
	// expandDeferredAwait signals via `typed` whether it used msFutureReadT
	// (no unboxing needed) or fell back to void* msWaitFor (needs unboxing).
	let expansion = expandDeferredAwait(awaitArg, loc, ctx, innerType);
	if (!expansion.typed && innerType != null) {
		expansion.resultIdent = makeUnboxCall(expansion.resultIdent, innerType, loc);
	}
	return { stmts: expansion.stmts, resultIdent: expansion.resultIdent };
}

// ===== Statement Expander (1:N) =====

// Shared expansion logic for any statement whose "expression slot" is an
// AwaitExpr. Returns expanded stmts + replacement node, or null if the slot
// holds no await. Caller sets the replacement back on the stmt's
// data field and appends the stmt. (P9 DRY — 3 match arms share this pattern.)
function tryExpandAwaitExpr(expr: Node | null, stmt: Node, ctx: TransformContext): { stmts: Node[], replacement: Node | null } {
	const noResult: { stmts: Node[], replacement: Node | null } = { stmts: [], replacement: null };
	if (expr == null) return noResult;
	// Direct: expr IS the AwaitExpr
	if (expr.kind == NodeKind.AwaitExpr) {
		const ad = expr.data as AwaitExprData;
		const expansion = expandSingleAwait(ad.awaitArg, stmt.location, ctx);
		return { stmts: expansion.stmts, replacement: expansion.resultIdent };
	}
	if (containsExprKind(expr, NodeKind.AwaitExpr)) {
		ctx.errors.push(`internal: an await nested in a ${expr.kind.toString()} expression reached awaitLower; awaitSpill leaves every await as a whole initializer or statement`);
	}
	return noResult;
}

// Called by walkExpandBlocks for each statement in a block. Returns the
// original statement unchanged (as [stmt]) or the expanded sequence.
function expandStmt(stmt: Node, ctx: TransformContext): Node[] {
	match (stmt.kind) {
		NodeKind.VariableDecl => {
			const d = stmt.data as VariableDeclData;
			// Scoped deferred detection: `const h = spawn(fn);` with no timeout
			// → rewrite to msAwaitSlotCreate + msSpawnSlotSubmit, register for later await.
			// Only matches builtin spawn() (builtinKind=PromiseSpawn), not raw msSpawn FFI.
			if (d.declKind == DeclKind.Const && d.initializer != null) {
				const si = getSpawnInfo(d.initializer);
				if (si.closure != null && isBuiltinSpawnCall(d.initializer)
					&& stmt.resolvedSym != null
					&& symSetContains(_awaitOnlyHandles, stmt.resolvedSym)
					&& !symSetContains(_moduleLevelHandles, stmt.resolvedSym)
					&& !_spawnSlotMap.has(stmt.resolvedSym)) {
					const innerType = getAwaitInnerType(d.initializer);
					const stmts: Node[] = [];
					const loc = stmt.location;
					// const $slot = msAwaitSlotCreate(1);
					const slot = makeTempDecl(ctx, "sl", makeCall(runtimeRef("msAwaitSlotCreate", loc), [makeNumber(1, loc)], loc), VOID_PTR_TYPE, loc);
					stmts.push(slot.decl);
					const flag = makeTempDecl(ctx, "joined", makeBool(false, loc), booleanType(), loc);
					(flag.decl.data as VariableDeclData).declKind = DeclKind.Let;
					stmts.push(flag.decl);
					// msSpawnSlotSubmit($slot, 0, closure);
					const task = bindTask(ctx, si.closure!, loc);
					const taskSym = task != null ? task!.sym : null;
					if (task != null) stmts.push(task!.decl);
					stmts.push(makeExprStmt(
						makeCall(runtimeRef("msSpawnSlotSubmit", loc), [slot.ident, makeNumber(0, loc), task != null ? task!.ident : si.closure!], loc), loc));
					stmts.push(settleOnExit(slot.sym, flag.sym, taskSym, loc));
					// Register for later `await h` lookup
					_spawnSlotMap.set(stmt.resolvedSym, { slotIdent: slot.ident, task: taskSym, innerType, joined: flag.sym });
					return stmts;  // Original VarDecl is eliminated (h is never emitted)
				}
			}
			const expanded = tryExpandAwaitExpr(d.initializer, stmt, ctx);
			if (expanded.replacement != null) {
				d.initializer = expanded.replacement;
				expanded.stmts.push(stmt);
				return expanded.stmts;
			}
		},
		NodeKind.ExprStmt => {
			const d = stmt.data as ExprStmtData;
			if (d.expr != null && d.expr.kind == NodeKind.AwaitExpr) {
				// Bare `await expr;` — the awaited value still belongs to this scope: the
				// await result carries the caller's reference exactly as in `const r = await h`.
				// Dropping the result ident here left that value with no owner and no
				// scope-exit destroy (measured: linear RSS growth, ~80 B/iteration, on Arc,
				// plain refs and strings alike). Bind it to a synthetic local so the ordinary
				// DRC vardecl path moves + destroys it — the emitted C then matches the bound
				// form byte-for-byte. freshOwnedSym, NOT freshTempSym: a `$`-prefixed name with
				// an identifier initializer is read as a cursor by the injector (inject.ms
				// processVarDecl) and would get no cleanup at all.
				const ad = d.expr.data as AwaitExprData;
				const expansion = expandSingleAwait(ad.awaitArg, stmt.location, ctx);
				const discardedType = getAwaitInnerType(ad.awaitArg);
				if (discardedType != null && discardedType.kind != TypeKind.Void) {
					const dloc = stmt.location;
					const dsym = freshOwnedSym(ctx, "disc", discardedType);
					const ddecl = makeVarDecl(dsym.name, expansion.resultIdent, DeclKind.Const, dloc);
					ddecl.resolvedSym = dsym;
					ddecl.nodeType = discardedType;
					expansion.stmts.push(ddecl);
				}
				return expansion.stmts;
			}
			const expanded = tryExpandAwaitExpr(d.expr, stmt, ctx);
			if (expanded.replacement != null) {
				d.expr = expanded.replacement;
				expanded.stmts.push(stmt);
				return expanded.stmts;
			}
		},
		NodeKind.ReturnStmt => {
			const d = stmt.data as ReturnStmtData;
			const expanded = tryExpandAwaitExpr(d.argument, stmt, ctx);
			if (expanded.replacement != null) {
				d.argument = expanded.replacement;
				expanded.stmts.push(stmt);
				return expanded.stmts;
			}
		},
		NodeKind.ExportDecl => {
			const ed = stmt.data as ExportDeclData;
			if (ed.exportedDecl != null && ed.exportedDecl.kind == NodeKind.VariableDecl) {
				const d = ed.exportedDecl.data as VariableDeclData;
				const expanded = tryExpandAwaitExpr(d.initializer, stmt, ctx);
				if (expanded.replacement != null) {
					d.initializer = expanded.replacement;
					expanded.stmts.push(stmt);
					return expanded.stmts;
				}
			}
		},
		NodeKind.AssertStmt => {
			const d = stmt.data as AssertStmtData;
			const expanded = tryExpandAwaitExpr(d.assertExpr, stmt, ctx);
			if (expanded.replacement != null) {
				d.assertExpr = expanded.replacement;
				expanded.stmts.push(stmt);
				return expanded.stmts;
			}
		},
		_ => {},
	};
	return [stmt];
}

// ===== Entry Point =====

export function blockifyAwaitingArrows(program: Node): void {
	walkNode(program, (n: Node): Node => {
		if (n.kind == NodeKind.ArrowFunction) {
			const d = n.data as ArrowFunctionData;
			const body = d.arrowBody;
			if (body != null && body.kind != NodeKind.BlockStmt
					&& containsExprKind(body, NodeKind.AwaitExpr)) {
				d.arrowBody = makeBlock([makeReturn(body, body.location)], body.location);
			}
		}
		return n;
	});
}

export function lowerAwait(program: Node, ctx: TransformContext): Node {
	blockifyAwaitingArrows(program);
	_spawnSlotMap = new HashMap<Symbol, SpawnSlotEntry>();
	_awaitOnlyHandles = awaitOnlyHandles(program);
	_moduleLevelHandles = moduleLevelHandles(program);
	_settleDeferred = false;
	_spawnSlotFrames = [];
	walkExpandBlocksHooked(program, expandStmt, ctx, enterSpawnSlotFrame, exitSpawnSlotFrame);
	if (_settleDeferred) {
		noteFact(ctx, ModuleFact.Defer);
		lowerDefer(program, ctx);
	}
	return program;
}

// ===== Held spawns: joined when their routine exits =====
// A spawn whose handle the routine keeps in a value (an array, a combinator
// argument, a binding that is not only awaited) is not joined by the slot path.
// Each such spawn receives the routine's held list as a second argument, so the
// runtime submits it under the list's cancel flag and keeps one reference; a
// scope-exit defer cancels what no worker has admitted and waits for the rest,
// on every exit. Runs before asyncDesugar, so the defer of an async routine runs
// when the routine ends, not at each suspension.

interface HeldFrame { held: Symbol | null; awaitOnly: SymSet | null; }

let _heldFrame: HeldFrame = { held: null, awaitOnly: null };
let _heldUsed = false;

function isSpawnNode(n: Node): boolean {
	if (n.kind != NodeKind.CallExpr) return false;
	const sym = n.resolvedSym != null ? n.resolvedSym : (n.data as CallExprData).callee.resolvedSym;
	return sym != null && sym.builtinKind == "PromiseSpawn";
}

function isRoutineNode(n: Node): boolean {
	return n.kind == NodeKind.FunctionDecl || n.kind == NodeKind.ArrowFunction || n.kind == NodeKind.FunctionExpr
		|| n.kind == NodeKind.MethodDecl || n.kind == NodeKind.ConstructorDecl || n.kind == NodeKind.TestDecl;
}

function routineFlags(n: Node): string {
	return match (n.kind) {
		NodeKind.FunctionDecl => (n.data as FunctionDeclData).fnFlags,
		NodeKind.MethodDecl => (n.data as MethodDeclData).methodFlags,
		NodeKind.ArrowFunction => (n.data as ArrowFunctionData).arrowFlags,
		NodeKind.FunctionExpr => (n.data as FunctionExprData).funcExprFlags,
		_ => "",
	};
}

function isSlotJoined(n: Node): boolean {
	const awaitOnly = _heldFrame.awaitOnly;
	if (n.kind == NodeKind.VariableDecl) {
		const init = (n.data as VariableDeclData).initializer;
		return init != null && isSpawnNode(init) && n.resolvedSym != null && awaitOnly != null && symSetContains(awaitOnly, n.resolvedSym);
	}
	if (n.kind == NodeKind.AwaitExpr) {
		const arg = (n.data as AwaitExprData).awaitArg;
		return arg != null && isSpawnNode(arg);
	}
	return false;
}

function holdSpawns(n: Node | null, ctx: TransformContext): void {
	if (n == null) return;
	if (isRoutineNode(n)) {
		joinHeldInRoutine(n, ctx);
		return;
	}
	if (_heldFrame.held != null && isSlotJoined(n)) {
		const sp = n.kind == NodeKind.VariableDecl ? (n.data as VariableDeclData).initializer! : (n.data as AwaitExprData).awaitArg!;
		forEachChild(sp, (c: Node): void => { holdSpawns(c, ctx); });
		return;
	}
	forEachChild(n, (c: Node): void => { holdSpawns(c, ctx); });
	if (_heldFrame.held != null && isSpawnNode(n) && !n.flags.has(NodeFlag.Isolated)) {
		const list = makeIdentResolved(_heldFrame.held!, n.location);
		list.nodeType = VOID_PTR_TYPE;
		(n.data as CallExprData).arguments.push(list);
		_heldUsed = true;
	}
}

function hasOwnSpawn(n: Node | null): boolean {
	return anyDescendant(n, (c: Node): Visit => {
		if (isRoutineNode(c)) return Visit.Skip;
		return isSpawnNode(c) ? Visit.Hit : Visit.Descend;
	});
}

function routineBodyBlock(n: Node): Node | null {
	if (n.kind == NodeKind.ArrowFunction) {
		const d = n.data as ArrowFunctionData;
		if (d.arrowBody != null && d.arrowBody.kind != NodeKind.BlockStmt && hasOwnSpawn(d.arrowBody)) {
			d.arrowBody = makeBlock([makeReturn(d.arrowBody, d.arrowBody.location)], d.arrowBody.location);
		}
		return d.arrowBody;
	}
	return match (n.kind) {
		NodeKind.FunctionDecl => (n.data as FunctionDeclData).fnBody,
		NodeKind.MethodDecl => (n.data as MethodDeclData).methodBody,
		NodeKind.ConstructorDecl => (n.data as ConstructorDeclData).ctorBody,
		NodeKind.TestDecl => (n.data as TestDeclData).testBody,
		NodeKind.FunctionExpr => (n.data as FunctionExprData).funcExprBody,
		_ => null,
	};
}

function joinHeldInRoutine(fn: Node, ctx: TransformContext): void {
	const body = routineBodyBlock(fn);
	if (body == null || body.kind != NodeKind.BlockStmt) {
		forEachChild(fn, (c: Node): void => { holdSpawns(c, ctx); });
		return;
	}
	const saved = _heldFrame;
	const savedUsed = _heldUsed;
	const loc = body.location;
	const isAsync = routineFlagSet(routineFlags(fn)).has(RoutineFlag.Async);
	const held = freshTempSym(ctx, "held", VOID_PTR_TYPE);
	_heldFrame = { held, awaitOnly: isAsync ? null : awaitOnlyHandles(fn) };
	_heldUsed = false;
	holdSpawns(body, ctx);
	if (_heldUsed) {
		const decl = makeVarDecl(held.name, makeCall(runtimeRef("msSpawnHeldCreate", loc), [], loc), DeclKind.Const, loc);
		decl.resolvedSym = held;
		decl.nodeType = VOID_PTR_TYPE;
		const settle = makeExprStmt(makeCall(runtimeRef("msSpawnHeldSettle", loc), [makeIdentResolved(held, loc)], loc), loc);
		const deferData: NodeData = { deferExpr: makeBlock([settle], loc) };
		const bd = body.data as BlockStmtData;
		const stmts: Node[] = [decl, createNodeAt(NodeKind.DeferStmt, deferData, loc)];
		noteFact(ctx, ModuleFact.Defer);
		for (const s of bd.statements) stmts.push(s);
		bd.statements = stmts;
	}
	_heldFrame = saved;
	_heldUsed = savedUsed;
}

export function lowerHeldSpawns(program: Node, ctx: TransformContext): Node {
	_heldFrame = { held: null, awaitOnly: null };
	_heldUsed = false;
	holdSpawns(program, ctx);
	if (!skipsModule(program, ctx, (0 as BitSet<ModuleFact>).incl(ModuleFact.Defer), "pass.lowerHeldSpawns.lowerDefer")) lowerDefer(program, ctx);
	return program;
}

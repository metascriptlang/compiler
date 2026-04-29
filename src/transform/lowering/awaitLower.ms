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
//      const x = msUnboxT(msAwaitGroupResult($ag, 0));
//      msAwaitGroupFree($ag);
//
// REPROMISE T3 Stage A. See docs/PARALOCK.md §6.3 for the AwaitGroup lifecycle.

import {
	Node, NodeKind, DeclKind, SourceLocation,
	VariableDeclData, ExprStmtData, ReturnStmtData,
	AwaitExprData, CallExprData, ObjectLiteralData,
	Type, NodeData, createNodeAt,
} from "../../ast/node";
import { TransformContext, freshTempSym } from "../context";
import { walkExpandBlocksHooked, containsExprKind, replaceInExpr } from "../walker";
import { makeIdent, makeCall, makeVarDecl, makeExprStmt, makeNumber, makeIdentResolved, makeBlock, makeString, makeIf, makeBinary } from "../util";
import { createPtr, createPrimitive, awaitedType, booleanType } from "../../checker/types";
import { typedFutureReadFn } from "./promiseLower";
import { TypeKind, FunctionExprData, ArrowFunctionData, IdentifierData } from "../../ast/node";
import { injectCancelSafePoints } from "./cancelSafePoints";

// ===== Scoped Deferred → msAwaitSlot (Change 1) =====
// Tracks `const h = spawn(fn);` declarations. When `await h` is later found
// in the same scope, rewrites to zero-alloc msAwaitSlot path instead of
// heap-allocated msFuture. Cleared at function boundaries.
struct SpawnSlotEntry { slotIdent: Node; closureArg: Node; innerType: Type | null; }
let _spawnSlotMap: HashMap<string, SpawnSlotEntry> = new HashMap<string, SpawnSlotEntry>();

// Opaque pointer type → void* in C codegen. Used for AwaitGroup and result temps.
export const VOID_PTR_TYPE: Type = createPtr(createPrimitive(TypeKind.Void));

// P9 DRY: extract the 5-line "temp sym → call → typed VarDecl" pattern that
// repeats across fused, deferred, and timeout paths.
export function makeTempDecl(ctx: TransformContext, prefix: string, initExpr: Node, t: Type | null, loc: SourceLocation): { decl: Node, ident: Node } {
	const sym = freshTempSym(ctx, prefix, t);
	initExpr.nodeType = t;
	const decl = makeVarDecl(sym.name, initExpr, DeclKind.Const, loc);
	decl.nodeType = t;
	decl.resolvedSym = sym;
	return { decl, ident: makeIdentResolved(sym, loc) };
}

// ===== Unboxing =====
// spawnLower.ms boxes primitive return values via msBoxDouble/msBoxInt32/msBoxBool/msBoxString.
// After await, we unbox the void* result back to the original type. Struct types don't need
// unboxing — they're already pointers in the C representation.
function unboxFnName(kind: TypeKind): string {
	return match (kind) {
		TypeKind.Number | TypeKind.Float64 | TypeKind.Float32 => "msUnboxDouble",
		TypeKind.Boolean => "msUnboxBool",
		TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 | TypeKind.Int64
			| TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 | TypeKind.Uint64 => "msUnboxInt32",
		TypeKind.String => "msUnboxString",
		_ => "",
	};
}

export function makeUnboxCall(voidPtrExpr: Node, innerType: Type | null, loc: SourceLocation): Node {
	if (innerType === null) return voidPtrExpr;
	const fn = unboxFnName(innerType.kind);
	if (fn === "") return voidPtrExpr;
	const c = makeCall(makeIdent(fn, loc), [voidPtrExpr], loc);
	c.nodeType = innerType;
	return c;
}

// Get the inner type that an await expression should produce.
// Uses the T1/T2 semantic layer: if the expression type is `Promise<T>` (plain or affine),
// extract T. Otherwise returns null (let C handle it as void*).
function getAwaitInnerType(awaitArgExpr: Node): Type | null {
	if (awaitArgExpr === null || awaitArgExpr.nodeType === null) return null;
	return awaitedType(awaitArgExpr.nodeType);
}

// ===== Spawn Detection =====

// Check if a node is a spawn() call. Returns the closure argument and optional
// timeout from the options object: spawn(fn, { timeout: N }).
export function getSpawnInfo(node: Node): { closure: Node | null, timeout: Node | null } {
	if (node === null || node.kind !== NodeKind.CallExpr) return { closure: null, timeout: null };
	const cd = node.data as CallExprData;
	const sym = node.resolvedSym !== null ? node.resolvedSym : cd.callee.resolvedSym;
	if (sym === null || (sym.builtinKind !== "PromiseSpawn" && sym.nativeName !== "msSpawn")) return { closure: null, timeout: null };
	if (cd.arguments.length < 1) return { closure: null, timeout: null };
	const closure = cd.arguments[0];
	let timeout: Node | null = null;
	// Extract timeout from options object: spawn(fn, { timeout: N })
	if (cd.arguments.length >= 2 && cd.arguments[1].kind === NodeKind.ObjectLiteral) {
		const opts = cd.arguments[1].data as ObjectLiteralData;
		let i = 0;
		while (i < opts.keys.length) {
			if (opts.keys[i] === "timeout") {
				timeout = opts.properties[i];
				break;
			}
			i = i + 1;
		}
	}
	return { closure, timeout };
}

// ===== Timeout Helper =====

// Emits timeout handling stmts for AwaitGroup: compute deadline, timed wait,
// check timedOut → free + throw. Returns the blocking call stmts (replaces
// the single msAwaitGroupBlocking call). If no timeout, returns single blocking call.
export function emitAwaitGroupWait(agIdent: Node, timeoutExpr: Node | null, loc: SourceLocation, ctx: TransformContext): Node[] {
	const stmts: Node[] = [];
	if (timeoutExpr === null) {
		// No timeout — simple blocking wait
		stmts.push(makeExprStmt(
			makeCall(makeIdent("msAwaitGroupBlocking", loc), [agIdent], loc), loc));
		return stmts;
	}
	// Phase 3: timed wait — const $deadline = msMonoTimeMs() + timeoutExpr;
	const int64Type = createPrimitive(TypeKind.Int64);
	const nowCall = makeCall(makeIdent("msMonoTimeMs", loc), [], loc);
	nowCall.nodeType = int64Type;
	const dl = makeTempDecl(ctx, "deadline", makeBinary(nowCall, "+", timeoutExpr, loc), int64Type, loc);
	stmts.push(dl.decl);

	// msAwaitGroupBlockingWithDeadline($ag, $deadline);
	stmts.push(makeExprStmt(
		makeCall(makeIdent("msAwaitGroupBlockingWithDeadline", loc), [
			agIdent, dl.ident,
		], loc), loc));

	// if (msAwaitGroupTimedOut($ag)) { msAwaitGroupFree($ag); throw "await timeout"; }
	const timedOutCall = makeCall(makeIdent("msAwaitGroupTimedOut", loc), [agIdent], loc);
	timedOutCall.nodeType = booleanType();
	const freeCall = makeExprStmt(
		makeCall(makeIdent("msAwaitGroupFree", loc), [agIdent], loc), loc);
	const throwData: NodeData = { throwArg: makeString("await timeout", loc) };
	const throwNode = createNodeAt(NodeKind.ThrowStmt, throwData, loc);
	const ifBody = makeBlock([freeCall, throwNode], loc);
	const ifNode = makeIf(timedOutCall, ifBody, null, loc);
	stmts.push(ifNode);

	return stmts;
}

// ===== Fused Path: await spawn(fn) → zero-alloc or AwaitGroup lifecycle =====

// Fast path (no timeout): stack-allocated msAwaitSlot — zero heap alloc, zero condvar.
// Emits: $as = msAwaitSlotCreate(1); msSpawnSlotSubmit($as, 0, closure);
//        msAwaitSlotWait($as); result = msAwaitSlotResult($as); msAwaitSlotRelease();
// Slow path (timeout): heap-allocated msAwaitGroup with mutex/condvar for timed wait.
function expandFusedAwait(closureArg: Node, loc: SourceLocation, ctx: TransformContext, timeoutExpr: Node | null): { stmts: Node[], resultIdent: Node } {
	// Timeout requires mutex+condvar → fall back to heap AwaitGroup
	if (timeoutExpr !== null) {
		return expandFusedAwaitHeap(closureArg, loc, ctx, timeoutExpr);
	}

	// Fast path: stack-allocated msAwaitSlot (Malebolgia parity)
	const stmts: Node[] = [];

	// 1. const $as = msAwaitSlotCreate(1);
	const as = makeTempDecl(ctx, "as", makeCall(makeIdent("msAwaitSlotCreate", loc), [makeNumber(1, loc)], loc), VOID_PTR_TYPE, loc);
	stmts.push(as.decl);

	// 2. msSpawnSlotSubmit($as, 0, closure);
	stmts.push(makeExprStmt(
		makeCall(makeIdent("msSpawnSlotSubmit", loc), [as.ident, makeNumber(0, loc), closureArg], loc), loc));

	// 3. msAwaitSlotWait($as);
	stmts.push(makeExprStmt(
		makeCall(makeIdent("msAwaitSlotWait", loc), [as.ident], loc), loc));

	// 4. const $agr = msAwaitSlotResult($as);
	const agr = makeTempDecl(ctx, "agr", makeCall(makeIdent("msAwaitSlotResult", loc), [as.ident], loc), VOID_PTR_TYPE, loc);
	stmts.push(agr.decl);

	// 5. msAwaitSlotRelease($as);
	stmts.push(makeExprStmt(
		makeCall(makeIdent("msAwaitSlotRelease", loc), [as.ident], loc), loc));

	return { stmts, resultIdent: agr.ident };
}

// Heap-allocated AwaitGroup path — used when timeout is needed (mutex+condvar for timed wait).
function expandFusedAwaitHeap(closureArg: Node, loc: SourceLocation, ctx: TransformContext, timeoutExpr: Node | null): { stmts: Node[], resultIdent: Node } {
	const stmts: Node[] = [];

	// 1. const $ag = msAwaitGroupInit(1);
	const ag = makeTempDecl(ctx, "ag", makeCall(makeIdent("msAwaitGroupInit", loc), [makeNumber(1, loc)], loc), VOID_PTR_TYPE, loc);
	stmts.push(ag.decl);

	// 2. Inject cancel safe-points into the closure body
	let closureBody: Node | null = null;
	if (closureArg.kind === NodeKind.FunctionExpr) {
		closureBody = (closureArg.data as FunctionExprData).funcExprBody;
	} else if (closureArg.kind === NodeKind.ArrowFunction) {
		closureBody = (closureArg.data as ArrowFunctionData).arrowBody;
	}
	if (closureBody !== null) {
		injectCancelSafePoints(closureBody, ag.ident, loc);
	}

	// 3. msSpawnTaskSubmit($ag, 0, closure);
	stmts.push(makeExprStmt(
		makeCall(makeIdent("msSpawnTaskSubmit", loc), [ag.ident, makeNumber(0, loc), closureArg], loc), loc));

	// 4. Blocking wait with deadline
	const waitStmts = emitAwaitGroupWait(ag.ident, timeoutExpr, loc, ctx);
	for (const ws of waitStmts) stmts.push(ws);

	// 5. const $agr = msAwaitGroupResult($ag, 0);
	const agr = makeTempDecl(ctx, "agr", makeCall(makeIdent("msAwaitGroupResult", loc), [ag.ident, makeNumber(0, loc)], loc), VOID_PTR_TYPE, loc);
	stmts.push(agr.decl);

	// 6. msAwaitGroupFree($ag);
	stmts.push(makeExprStmt(
		makeCall(makeIdent("msAwaitGroupFree", loc), [ag.ident], loc), loc));

	return { stmts, resultIdent: agr.ident };
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
	let futIdent = handleExpr;
	if (handleExpr.kind !== NodeKind.Identifier) {
		const tmp = makeTempDecl(ctx, "fut", handleExpr, handleExpr.nodeType, loc);
		stmts.push(tmp.decl);
		futIdent = tmp.ident;
	}

	// Typed path: msWaitForReady(handle) + msFutureReadT(handle) → typed value
	// msWaitForReady blocks until the future finishes (without consuming the value),
	// then msFutureReadT extracts the typed value from the future struct.
	const readFn = innerType !== null ? typedFutureReadFn(innerType) : "";
	if (readFn !== "") {
		stmts.push(makeExprStmt(
			makeCall(makeIdent("msWaitForReady", loc), [futIdent], loc), loc));
		const res = makeTempDecl(ctx, "aw", makeCall(makeIdent(readFn, loc), [futIdent], loc), innerType, loc);
		stmts.push(res.decl);
		return { stmts, resultIdent: res.ident, typed: true };
	}

	// Fallback: void* path (structs, refs, strings) — caller must apply unboxing
	const res = makeTempDecl(ctx, "aw", makeCall(makeIdent("msWaitFor", loc), [futIdent], loc), VOID_PTR_TYPE, loc);
	stmts.push(res.decl);
	return { stmts, resultIdent: res.ident, typed: false };
}

// ===== Unified Expansion =====

// Dispatches to fused (AwaitGroup) or deferred (msFutureReadT / msWaitFor)
// based on whether the awaited expression is a direct spawn() call.
// Fused path: AwaitGroup stores void* — still needs unboxing.
// Deferred path: typed reader handles both boxed/typed futures internally.
function expandSingleAwait(awaitArg: Node, loc: SourceLocation, ctx: TransformContext): { stmts: Node[], resultIdent: Node } {
	const spawnInfo = getSpawnInfo(awaitArg);
	const innerType = getAwaitInnerType(awaitArg);
	if (spawnInfo.closure !== null) {
		// Fused path: AwaitGroup → void* results, needs unboxing
		let expansion = expandFusedAwait(spawnInfo.closure, loc, ctx, spawnInfo.timeout);
		if (innerType !== null) {
			expansion.resultIdent = makeUnboxCall(expansion.resultIdent, innerType, loc);
		}
		return expansion;
	}
	// Scoped deferred: `const h = spawn(fn); ... await h;` → msAwaitSlot
	// Check if the awaited identifier was registered as a spawn handle in this scope.
	if (awaitArg.kind === NodeKind.Identifier) {
		const name = (awaitArg.data as IdentifierData).name;
		if (_spawnSlotMap.has(name)) {
			const slotEntry = _spawnSlotMap.get(name);
			_spawnSlotMap.delete(name);
			const stmts: Node[] = [];
			// msAwaitSlotWait($slot);
			stmts.push(makeExprStmt(
				makeCall(makeIdent("msAwaitSlotWait", loc), [slotEntry.slotIdent], loc), loc));
			// const $agr = msAwaitSlotResult($slot);
			const agr = makeTempDecl(ctx, "agr", makeCall(makeIdent("msAwaitSlotResult", loc), [slotEntry.slotIdent], loc), VOID_PTR_TYPE, loc);
			stmts.push(agr.decl);
			// msAwaitSlotRelease($slot);
			stmts.push(makeExprStmt(
				makeCall(makeIdent("msAwaitSlotRelease", loc), [slotEntry.slotIdent], loc), loc));
			// Apply unboxing
			let resultIdent = agr.ident;
			if (slotEntry.innerType !== null) {
				resultIdent = makeUnboxCall(resultIdent, slotEntry.innerType, loc);
			}
			return { stmts, resultIdent };
		}
	}

	// Deferred path: typed future reader for primitives, msWaitFor for rest.
	// expandDeferredAwait signals via `typed` whether it used msFutureReadT
	// (no unboxing needed) or fell back to void* msWaitFor (needs unboxing).
	let expansion = expandDeferredAwait(awaitArg, loc, ctx, innerType);
	if (!expansion.typed && innerType !== null) {
		expansion.resultIdent = makeUnboxCall(expansion.resultIdent, innerType, loc);
	}
	return { stmts: expansion.stmts, resultIdent: expansion.resultIdent };
}

// ===== Statement Expander (1:N) =====

// Shared expansion logic for any statement whose "expression slot" may contain
// an AwaitExpr (directly or nested). Returns expanded stmts + replacement node,
// or null if no await was found. Caller sets the replacement back on the stmt's
// data field and appends the stmt. (P9 DRY — 3 match arms share this pattern.)
function tryExpandAwaitExpr(expr: Node, stmt: Node, ctx: TransformContext): { stmts: Node[], replacement: Node } {
	const noResult: { stmts: Node[], replacement: Node } = { stmts: null as unknown as Node[], replacement: null as unknown as Node };
	if (expr === null) return noResult;
	// Direct: expr IS the AwaitExpr
	if (expr.kind === NodeKind.AwaitExpr) {
		const ad = expr.data as AwaitExprData;
		const expansion = expandSingleAwait(ad.awaitArg, stmt.location, ctx);
		return { stmts: expansion.stmts, replacement: expansion.resultIdent };
	}
	// Nested: expr CONTAINS an AwaitExpr (e.g. f(await g()), x + await y)
	if (containsExprKind(expr, NodeKind.AwaitExpr)) {
		return hoistNestedAwait(expr, stmt.location, ctx);
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
			// spawn() handles are affine Promises used exclusively with await, safe to eliminate.
			if (d.declKind === DeclKind.Const && d.initializer !== null) {
				const si = getSpawnInfo(d.initializer);
				const initSym = d.initializer.resolvedSym !== null ? d.initializer.resolvedSym
					: (d.initializer.kind === NodeKind.CallExpr ? (d.initializer.data as CallExprData).callee.resolvedSym : null);
				if (si.closure !== null && si.timeout === null
					&& initSym !== null && initSym.builtinKind === "PromiseSpawn"
					&& !_spawnSlotMap.has(d.declName)) {
					const innerType = getAwaitInnerType(d.initializer);
					const stmts: Node[] = [];
					const loc = stmt.location;
					// const $slot = msAwaitSlotCreate(1);
					const slot = makeTempDecl(ctx, "sl", makeCall(makeIdent("msAwaitSlotCreate", loc), [makeNumber(1, loc)], loc), VOID_PTR_TYPE, loc);
					stmts.push(slot.decl);
					// msSpawnSlotSubmit($slot, 0, closure);
					stmts.push(makeExprStmt(
						makeCall(makeIdent("msSpawnSlotSubmit", loc), [slot.ident, makeNumber(0, loc), si.closure], loc), loc));
					// Register for later `await h` lookup
					_spawnSlotMap.set(d.declName, { slotIdent: slot.ident, closureArg: si.closure, innerType });
					return stmts;  // Original VarDecl is eliminated (h is never emitted)
				}
			}
			const expanded = tryExpandAwaitExpr(d.initializer, stmt, ctx);
			if (expanded.replacement !== null) {
				d.initializer = expanded.replacement;
				expanded.stmts.push(stmt);
				return expanded.stmts;
			}
		},
		NodeKind.ExprStmt => {
			const d = stmt.data as ExprStmtData;
			if (d.expr !== null && d.expr.kind === NodeKind.AwaitExpr) {
				// Bare `await expr;` — expand and discard result (no stmt appended).
				const ad = d.expr.data as AwaitExprData;
				const expansion = expandSingleAwait(ad.awaitArg, stmt.location, ctx);
				return expansion.stmts;
			}
			const expanded = tryExpandAwaitExpr(d.expr, stmt, ctx);
			if (expanded.replacement !== null) {
				d.expr = expanded.replacement;
				expanded.stmts.push(stmt);
				return expanded.stmts;
			}
		},
		NodeKind.ReturnStmt => {
			const d = stmt.data as ReturnStmtData;
			const expanded = tryExpandAwaitExpr(d.argument, stmt, ctx);
			if (expanded.replacement !== null) {
				d.argument = expanded.replacement;
				expanded.stmts.push(stmt);
				return expanded.stmts;
			}
		},
		_ => {},
	};
	return [stmt];
}

// ===== Nested Await Hoisting =====

// For expressions like `f(await g())`, `x + await f()`, `(await f()).prop`,
// extract the first AwaitExpr into a preceding variable declaration and replace
// the await site with the temp identifier. Uses replaceInExpr for generic
// coverage across all expression kinds (CallExpr, BinaryExpr, MemberExpr, etc.).
// Deeply nested multiple awaits are handled by repeated passes — walkExpandBlocks
// re-enters after expansion and catches the next one.
//
// Returns null if no AwaitExpr was found.
let _hoistStmts: Node[] = [];
let _hoistCtx: TransformContext = null as unknown as TransformContext;
let _hoistLoc: SourceLocation = null as unknown as SourceLocation;

function hoistNestedAwait(expr: Node, loc: SourceLocation, ctx: TransformContext): { stmts: Node[], replacement: Node } {
	if (expr === null) return null;
	if (expr.kind === NodeKind.AwaitExpr) return null;

	_hoistStmts = [];
	_hoistCtx = ctx;
	_hoistLoc = loc;

	const replaced = replaceInExpr(expr, (node: Node): Node => {
		if (node.kind !== NodeKind.AwaitExpr) return node;
		// Extract every AwaitExpr into preceding statements + replace with result ident.
		// replaceInExpr is bottom-up (left subtrees first), so evaluation order is preserved:
		// `await a + await b` → expand(a) stmts, expand(b) stmts, then $aw0 + $aw1.
		const ad = node.data as AwaitExprData;
		const expansion = expandSingleAwait(ad.awaitArg, _hoistLoc, _hoistCtx);
		for (const s of expansion.stmts) { _hoistStmts.push(s); }
		return expansion.resultIdent;
	});

	if (_hoistStmts.length === 0) return null;
	return { stmts: _hoistStmts, replacement: replaced };
}

// ===== Entry Point =====

export function lowerAwait(program: Node, ctx: TransformContext): Node {
	_spawnSlotMap = new HashMap<string, SpawnSlotEntry>();
	walkExpandBlocksHooked(program, expandStmt, ctx,
		(_fn: Node): void => { _spawnSlotMap = new HashMap<string, SpawnSlotEntry>(); },
		(_fn: Node): void => { _spawnSlotMap = new HashMap<string, SpawnSlotEntry>(); });
	return program;
}

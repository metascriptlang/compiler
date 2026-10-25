// Spawn Group Lowering — await Promise.all([spawn(f), spawn(g)]) → N-slot AwaitGroup
//
// Runs BEFORE asyncDesugar and BEFORE spawnLower. Detects AwaitExpr whose
// awaitArg is a Promise.all() call with an ArrayLiteral where ALL elements
// are spawn() calls. Rewrites to the N-slot AwaitGroup lifecycle from PARALOCK §6.3:
//
// Sync context:
//   const $ag = msAwaitGroupInit(N);
//   msSpawnTaskSubmit($ag, 0, closure0); ... msSpawnTaskSubmit($ag, N-1, closureN);
//   msAwaitGroupBlocking($ag);
//   let __agr0: T0 = default; if (msAwaitGroupResult($ag, 0) != null) __agr0 = unbox(...); ...
//   msAwaitGroupCheckFailed($ag);  // a failed child: free the group, re-raise its error
//   msAwaitGroupFree($ag);
//   [$r0, ..., $rN]  // replacement array
//
// Async context:
//   msAwaitGroupSetDoneFut($ag, msFutureCreate()) before the first submit,
//   then instead of msAwaitGroupBlocking:
//   await msAwaitGroupGetDoneFut($ag);  // asyncDesugar → yield → cooperative
//   ... read results, check, free ...
//
// Every result is read into an owned local before the check can raise, so the
// results of a failed group's other children are destroyed with the scope.

import {
	Node, NodeKind, NodeFlag, SourceLocation, NodeData, createNodeAt,
	AwaitExprData, ArrayLiteralData, CallExprData, FunctionDeclData, MethodDeclData,
	FunctionExprData, ArrowFunctionData,
	VariableDeclData, ExprStmtData, ReturnStmtData,
	Type, TypeKind,
} from "../../ast/node";
import { TransformContext, ModuleFact, noteFact } from "../context";
import { RoutineFlag, routineFlagSet } from "../../checker/symbol";
import { walkExpandBlocksHooked } from "../walker";
import { makeCall, makeExprStmt, makeNumber, makeNull, makeObjectLiteral, runtimeRef } from "../util";
import { awaitedType, createPromise, createPtr, voidType } from "../../checker/types";
import { getSpawnInfo, makeTempDecl, emitAwaitGroupWait, readGroupSlot, VOID_PTR_TYPE } from "./awaitLower";
import { injectCancelSafePoints } from "./cancelSafePoints";
import { boxReturns, boxForType, disownResult, disownMovedCaptures, spawnThunk, mayHoldCycleRoot, callingThunk } from "./spawnLower";

// ===== Async Context Tracking =====

let _isAsync: boolean = false;

function isAsyncFn(node: Node): boolean {
	const flags = match (node.kind) {
		NodeKind.FunctionDecl => (node.data as FunctionDeclData).fnFlags,
		NodeKind.MethodDecl => (node.data as MethodDeclData).methodFlags,
		NodeKind.ArrowFunction => (node.data as ArrowFunctionData).arrowFlags,
		NodeKind.FunctionExpr => (node.data as FunctionExprData).funcExprFlags,
		_ => "",
	};
	return routineFlagSet(flags).has(RoutineFlag.Async);
}

// ===== Multi-Spawn Detection =====

interface SpawnSlot {
	closure: Node;
	timeout: Node | null;
	innerType: Type | null;
}

function getMultiSpawnSlots(awaitArg: Node): SpawnSlot[] {
	// Detect await Promise.all([spawn(a), spawn(b), ...]) where ALL elements are spawn calls.
	// Replaces the Promise.all callback path with AwaitGroup (condvar + zero-alloc).
	// Mixed arrays (spawn + non-spawn) fall through to the generic Promise.all combinator.
	if (awaitArg == null || awaitArg.kind != NodeKind.CallExpr) return [] as SpawnSlot[];
	const cd = awaitArg.data as CallExprData;
	const sym = awaitArg.resolvedSym != null ? awaitArg.resolvedSym : cd.callee.resolvedSym;
	if (sym == null || sym.builtinKind != "PromiseAll") return [] as SpawnSlot[];
	if (cd.arguments.length < 1 || cd.arguments[0].kind != NodeKind.ArrayLiteral) return [] as SpawnSlot[];
	const ad = cd.arguments[0].data as ArrayLiteralData;
	if (ad.elements.length < 2) return [] as SpawnSlot[];
	const slots: SpawnSlot[] = [];
	for (const elem of ad.elements) {
		const info = getSpawnInfo(elem);
		if (info.closure == null) return [] as SpawnSlot[];
		const innerType = awaitedType(elem.nodeType);
		slots.push({ closure: info.closure, timeout: info.timeout, innerType });
	}
	return slots;
}

// ===== Expansion =====

function expandSpawnGroup(slots: SpawnSlot[], loc: SourceLocation, ctx: TransformContext, isAsync: boolean): { stmts: Node[], resultExpr: Node | null } {
	const n = slots.length;
	const stmts: Node[] = [];

	// 1. const $ag = msAwaitGroupInit(N);
	const ag = makeTempDecl(ctx, "ag",
		makeCall(runtimeRef("msAwaitGroupInit", loc), [makeNumber(n, loc)], loc),
		VOID_PTR_TYPE, loc);
	stmts.push(ag.decl);

	// The last slot completes doneFut only if it is set when that slot finishes.
	let doneFut: { decl: Node, ident: Node } | null = null;
	if (isAsync) {
		doneFut = makeTempDecl(ctx, "doneFut",
			makeCall(runtimeRef("msFutureCreate", loc), [], loc),
			createPromise(voidType()), loc);
		stmts.push(doneFut.decl);
		stmts.push(makeExprStmt(
			makeCall(runtimeRef("msAwaitGroupSetDoneFut", loc), [ag.ident, doneFut.ident], loc), loc));
	}

	// 2. Inject cancel safe-points + submit tasks
	let groupTimeout: Node | null = null;
	let si = 0;
	while (si < n) {
		const slot = slots[si];
		if (slot.closure.kind == NodeKind.Identifier && slot.innerType != null && mayHoldCycleRoot(slot.innerType, ctx)) slot.closure = callingThunk(slot.closure, slot.innerType);
		const thunk = spawnThunk(slot.closure);
		// Use first non-null timeout found
		if (slot.timeout != null && groupTimeout == null) {
			groupTimeout = slot.timeout;
		}
		// Inject safe-points into closure body when timeout
		if (groupTimeout != null) {
			let closureBody: Node | null = null;
			if (thunk.kind == NodeKind.FunctionExpr) {
				closureBody = (thunk.data as FunctionExprData).funcExprBody;
			} else if (thunk.kind == NodeKind.ArrowFunction) {
				closureBody = (thunk.data as ArrowFunctionData).arrowBody;
			}
			if (closureBody != null) {
				injectCancelSafePoints(closureBody, ag.ident, loc);
			}
		}
		disownResult(thunk, slot.innerType, ctx);
		// Box return values in closure body (spawnGroupLower runs before spawnLower,
		// so closures extracted here bypass spawnLower's boxing pass).
		// Also update closure return type to void* so codegen emits correct signature.
		if (slot.innerType != null) {
			if (thunk.kind == NodeKind.FunctionExpr) {
				const fd = thunk.data as FunctionExprData;
				if (fd.funcExprBody != null) { boxReturns(fd.funcExprBody, slot.innerType); }
			} else if (thunk.kind == NodeKind.ArrowFunction) {
				const ad = thunk.data as ArrowFunctionData;
				if (ad.arrowBody != null) {
					if (ad.arrowBody.kind == NodeKind.BlockStmt) {
						boxReturns(ad.arrowBody, slot.innerType);
					} else {
						ad.arrowBody = boxForType(ad.arrowBody, slot.innerType, ad.arrowBody.location);
					}
				}
			}
			if (thunk != slot.closure && thunk.nodeType != null && thunk.nodeType.kind == TypeKind.Function) {
				thunk.nodeType.typeReturn = createPtr(voidType());
			}
			if (slot.closure.nodeType != null && slot.closure.nodeType.kind == TypeKind.Function) {
				slot.closure.nodeType.typeReturn = createPtr(voidType());
			}
		}
		disownMovedCaptures(slot.closure, ctx);
		// Wrap bare function reference as msClosure {fn, env: null}
		let closure = slot.closure;
		if (closure.kind == NodeKind.Identifier) {
			const pair = makeObjectLiteral(["fn", "env"], [closure, makeNull(loc)], loc);
			pair.flags = pair.flags.incl(NodeFlag.Closure);
			pair.nodeType = closure.nodeType;
			closure = pair;
		}
		// msSpawnTaskSubmit($ag, i, closure);
		stmts.push(makeExprStmt(
			makeCall(runtimeRef("msSpawnTaskSubmit", loc), [ag.ident, makeNumber(si, loc), closure], loc), loc));
		si = si + 1;
	}

	// 3. Results, read once the wait returns (skipped when every slot returns void)
	let allVoid = true;
	for (const slot of slots) {
		const it = slot.innerType;
		if (it == null || it.kind != TypeKind.Void) { allVoid = false; }
	}
	const reads: Node[] = [];
	let resultExpr: Node | null = null;
	if (!allVoid) {
		const values: Node[] = [];
		for (let ri = 0; ri < n; ri += 1) {
			const read = readGroupSlot(ctx, ag.ident, ri, slots[ri].innerType, loc);
			for (const r of read.stmts) reads.push(r);
			values.push(read.value);
		}
		resultExpr = createNodeAt(NodeKind.ArrayLiteral, { elements: values }, loc);
	}

	// 4. Wait
	if (doneFut != null) {
		// Emit: await $doneFut — asyncDesugar converts to yield, stepper handles cooperatively
		const awaitData: NodeData = { awaitArg: doneFut.ident };
		const awaitNode = createNodeAt(NodeKind.AwaitExpr, awaitData, loc);
		noteFact(ctx, ModuleFact.Await);
		stmts.push(makeExprStmt(awaitNode, loc));
		for (const r of reads) stmts.push(r);
	} else {
		// Sync: blocking wait (with optional timeout)
		const waitStmts = emitAwaitGroupWait(ag.ident, groupTimeout, loc, ctx, reads);
		for (const ws of waitStmts) stmts.push(ws);
	}
	stmts.push(makeExprStmt(
		makeCall(runtimeRef("msAwaitGroupCheckFailed", loc), [ag.ident], loc), loc));

	// 5. msAwaitGroupFree($ag);
	stmts.push(makeExprStmt(
		makeCall(runtimeRef("msAwaitGroupFree", loc), [ag.ident], loc), loc));

	return { stmts, resultExpr };
}

// ===== Statement Expander =====

function expandStmt(stmt: Node, ctx: TransformContext): Node[] {
	match (stmt.kind) {
		NodeKind.VariableDecl => {
			const d = stmt.data as VariableDeclData;
			if (d.initializer != null && d.initializer.kind == NodeKind.AwaitExpr) {
				const ad = d.initializer.data as AwaitExprData;
				const slots = getMultiSpawnSlots(ad.awaitArg);
				if (slots.length > 0) {
					const expansion = expandSpawnGroup(slots, stmt.location, ctx, _isAsync);
					if (expansion.resultExpr != null) {
						// Synthetic ArrayLiteral must carry type — codegen reads initializer nodeType
						if (expansion.resultExpr.nodeType == null && stmt.nodeType != null) {
							expansion.resultExpr.nodeType = stmt.nodeType;
						}
						d.initializer = expansion.resultExpr;
						expansion.stmts.push(stmt);
					}
					return expansion.stmts;
				}
			}
		},
		NodeKind.ExprStmt => {
			const d = stmt.data as ExprStmtData;
			if (d.expr != null && d.expr.kind == NodeKind.AwaitExpr) {
				const ad = d.expr.data as AwaitExprData;
				const slots = getMultiSpawnSlots(ad.awaitArg);
				if (slots.length > 0) {
					const expansion = expandSpawnGroup(slots, stmt.location, ctx, _isAsync);
					return expansion.stmts;
				}
			}
		},
		NodeKind.ReturnStmt => {
			const d = stmt.data as ReturnStmtData;
			if (d.argument != null && d.argument.kind == NodeKind.AwaitExpr) {
				const ad = d.argument.data as AwaitExprData;
				const slots = getMultiSpawnSlots(ad.awaitArg);
				if (slots.length > 0) {
					const expansion = expandSpawnGroup(slots, stmt.location, ctx, _isAsync);
					if (expansion.resultExpr != null) {
						d.argument = expansion.resultExpr;
					} else {
						d.argument = null;
					}
					expansion.stmts.push(stmt);
					return expansion.stmts;
				}
			}
		},
		_ => {},
	};
	return [stmt];
}

// ===== Entry Point =====

let _asyncStack: boolean[] = [];

export function lowerSpawnGroup(program: Node, ctx: TransformContext): Node {
	_isAsync = false;
	_asyncStack = [];
	walkExpandBlocksHooked(program, expandStmt, ctx,
		(node: Node): void => { _asyncStack.push(_isAsync); _isAsync = isAsyncFn(node); },
		(node: Node): void => { _isAsync = _asyncStack.length > 0 ? _asyncStack.pop() : false; },
	);
	return program;
}

// Async Bridge — rewrites async functions to return msFuture*
//
// Runs AFTER asyncDesugar, BEFORE generatorLower.
// Detects functions with NodeFlag.WasAsync (set by asyncDesugar).
//
// Two cases:
//
// Simple (no await): wraps body in msFutureCreate + msFutureComplete.
//   async function f() { console.log("hi"); }
//   → const $retFut = msFutureCreate(); console.log("hi"); msFutureComplete($retFut, NULL); return $retFut;
//
// Await (has yield): inline stepper with state machine. Reuses generatorLower's
//   state splitting but emits msFutureAddCallback at yield points instead of iterator results.
//   async function f() { const x = await p; return x; }
//   → const $retFut = msFutureCreate(); let $state=0; let x; let $stepper = function() {
//       while(true) { if ($state===0) { $yf0=p; $state=1; if(finished) continue; addCallback($yf0,$stepper); return; }
//       else if ($state===1) { x=read($yf0); complete($retFut,x); return; } } };
//     $stepper(); return $retFut;
//
// Both cases clear fnFlags so generatorLower skips these functions.

import { Node, NodeKind, NodeFlag, DeclKind, createNode, SourceLocation, BlockStmtData, FunctionDeclData, FunctionExprData, ArrowFunctionData, MethodDeclData, ReturnStmtData, VariableDeclData, Symbol, SymbolKind, IfStmtData, TryCatchStmtData, Type, TypeKind, isEmptyBlock } from "../../ast/node";
import { mapChildren, isFuncBoundary } from "../walker";
import { forEachChild } from "../../ast/visitor";
import { setFlag, SymbolFlag } from "../../checker/symbol";
import { TransformContext, mintSym } from "../context";
import {
	makeTypedIdentResolved, makeVarDecl, makeExprStmt, makeReturn,
	makeCall, makeBlock, makeNull, makeDefaultValue, makeIf, makeWhile, makeBool, makeNumber, makeString,
	makeAssign, makeBinary, makeTryCatch, makeCatchSym, makeContinue, syntheticToken, extractBodyStmts, runtimeRef,
} from "../util";
import { createSymSet, symSetAdd } from "../context";
import { createPromise, createClosureType, createPtr, createPrimitive, voidType, booleanType, numberType, isAwaitable, awaitedType } from "../../checker/types";
import { StateCollector, allocState, splitStmts, convertDeclsToAssigns, localsSpanningStates, collectStateLocals, makeStateAssign, hasExcLanding, wrapExcRouting, makeCurExcDecl, containsYield } from "./generatorLower";
import { stmtCountAfter } from "../testUtil";

// ===== Variable Type Collection =====
// Walk body to collect binding → Type BEFORE rewriting. Used to set nodeType
// on hoisted locals so lambda lifting creates correctly typed env struct fields.

interface VarTypeInfo { varType: Type; varSym: Symbol; }

function collectVarTypes(node: Node, result: VarTypeInfo[]): void {
	if (node == null || isFuncBoundary(node)) return;
	if (node.kind == NodeKind.VariableDecl && node.resolvedSym != null) {
		const d = node.data as VariableDeclData;
		let varType = node.nodeType;
		if (varType == null && d.initializer != null && d.initializer.nodeType != null) {
			varType = d.initializer.nodeType;
		}
		if (varType == null && node.resolvedSym != null && node.resolvedSym.symbolType != null) {
			varType = node.resolvedSym.symbolType;
		}
		if (varType != null) {
			result.push({ varType, varSym: node.resolvedSym });
		}
	}
	forEachChild(node, (child: Node): void => { collectVarTypes(child, result); });
}

function findVarType(entries: VarTypeInfo[], sym: Symbol): Type {
	for (const e of entries) {
		if (e.varSym == sym) return e.varType;
	}
	return null as unknown as Type;
}

// Promise<T> from inner type, or Promise<void> if null
function promiseTypeFor(inner: Type | null): Type {
	return inner != null ? createPromise(inner) : createPromise(voidType());
}

import { isStructLikeType, inlineInFuture, boxedInFuture } from "../util";

// $retFut allocation: String needs the 16-byte inline slot; everything else uses
// the 8-byte generic future (boxed types store a void*). nodeType carries
// Promise<T> so DRC's cross-pass contract holds; codegen extracts T via awaitedType.
function makeRetFutAlloc(innerType: Type | null, loc: SourceLocation): Node {
	if (inlineInFuture(innerType)) {
		const inlineCall = makeCall(runtimeRef("msFutureCreateInline", loc), [], loc);
		inlineCall.nodeType = promiseTypeFor(innerType);
		return inlineCall;
	}
	const call = makeCall(runtimeRef("msFutureCreate", loc), [], loc);
	call.nodeType = promiseTypeFor(innerType);
	return call;
}

// Zero value for a type — used as fallback in msFutureReadT(f, zeroval) when future failed
function zeroValueForType(t: Type, loc: SourceLocation): Node {
	if (t == null) return makeNull(loc);
	return match (t.kind) {
		TypeKind.Number | TypeKind.Float64 | TypeKind.Float32
			| TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 | TypeKind.Int64 => makeNumber(0, loc),
		TypeKind.Boolean => makeBool(false, loc),
		TypeKind.String => makeString("", loc),
		_ => makeNull(loc),
	};
}

// ===== Core: Rewrite a was-async function body =====

// ===== Await case: inline stepper with state machine =====
// Reuses generatorLower's state-splitting algorithm but emits a stepper function
// instead of an iterator object. The stepper IS the state machine.

// Rewrite return stmts in the body for the state machine:
// return val → msFutureComplete($retFut, val); return;
// Build the msFutureCompleteT or msFutureCompleteVoid statement(s) for a return value.
// Returns an array of statements (usually 1, but 2 for arrays due to msSinkBoxStruct expansion).
let asyncNameCounter = 0;

function makeFutureCompleteStmts(valueExpr: Node | null, isVoid: boolean, promiseType: Type, fnReturnInner: Type | null, loc: SourceLocation, retFutSym: Symbol, ctx: TransformContext): Node[] {
	if (isVoid || valueExpr == null) {
		return [makeExprStmt(makeCall(
			runtimeRef("msFutureCompleteVoid", loc),
			[makeTypedIdentResolved(retFutSym, promiseType, loc)],
			loc,
		), loc)];
	}
	// Boxed types: msSinkBoxStruct is a multi-statement codegen expansion (can't
	// nest in another call), so box via a separate VarDecl then complete with the
	// void* pointer. Codegen reads sizeof(T) from the box arg's nodeType.
	if (boxedInFuture(fnReturnInner)) {
		const voidPtrType = createPtr(createPrimitive(TypeKind.Void));
		const boxCall = makeCall(runtimeRef("msSinkBoxStruct", loc), [valueExpr], loc);
		boxCall.nodeType = voidPtrType;
		const boxSym = mintSym(ctx, SymbolKind.Variable, retFutSym.name + "_b", voidPtrType);
		const boxDecl = makeVarDecl(boxSym.name, boxCall, DeclKind.Const, loc);
		boxDecl.nodeType = voidPtrType;  // variable holds void* (the boxed pointer)
		boxDecl.resolvedSym = boxSym;
		const completeStmt = makeExprStmt(makeCall(
			runtimeRef("msFutureComplete", loc),
			[makeTypedIdentResolved(retFutSym, promiseType, loc), makeTypedIdentResolved(boxSym, voidPtrType, loc)],
			loc,
		), loc);
		return [boxDecl, completeStmt];
	}
	return [makeExprStmt(makeCall(
		runtimeRef("msFutureCompleteT", loc),
		[makeTypedIdentResolved(retFutSym, promiseType, loc), valueExpr],
		loc,
	), loc)];
}

// pendingFinallies: outer→inner finally bodies of every SPLIT try the return
// sits inside (finallyPath port — see splitTryFinally in generatorLower). The
// try's C-level finally disappears when it is split into states, so the return
// block must run them itself, innermost-first, BEFORE the completion. A
// yield-free try keeps its C-level finally (it is never split) and contributes
// nothing here. Returns an empty list when no split try encloses the return.
function finalliesBeforeReturn(pending: Node[][]): Node[] {
	const out: Node[] = [];
	let i = pending.length - 1;
	while (i >= 0) {
		for (const s of pending[i]) out.push(s);
		i = i - 1;
	}
	return out;
}

function rewriteAsyncReturns(stmts: Node[], promiseType: Type, fnReturnInner: Type | null, loc: SourceLocation, retFutSym: Symbol, pendingFinallies: Node[][], stateSym: Symbol, ctx: TransformContext): void {
	for (let i = 0; i < stmts.length; i += 1) {
		stmts[i] = rewriteAsyncReturn(stmts[i], promiseType, fnReturnInner, loc, retFutSym, pendingFinallies, stateSym, ctx);
	}
}

function rewriteAsyncReturn(node: Node, promiseType: Type, fnReturnInner: Type | null, loc: SourceLocation, retFutSym: Symbol, pendingFinallies: Node[][], stateSym: Symbol, ctx: TransformContext): Node {
	if (node == null || isFuncBoundary(node)) return node;
	if (node.kind == NodeKind.ReturnStmt) {
		const rd = node.data as ReturnStmtData;
		const isVoidReturn = fnReturnInner == null || fnReturnInner.kind == TypeKind.Void;
		const completeStmts = makeFutureCompleteStmts(rd.argument, isVoidReturn, promiseType, fnReturnInner, loc, retFutSym, ctx);
		const blockStmts: Node[] = [];
		for (const fs of finalliesBeforeReturn(pendingFinallies)) blockStmts.push(fs);
		blockStmts.push(makeStateAssign(-1, loc, stateSym));
		for (const cs of completeStmts) blockStmts.push(cs);
		blockStmts.push(makeReturn(makeNull(loc), loc));
		return makeBlock(blockStmts, loc);
	}
	if (node.kind == NodeKind.TryCatchStmt) {
		const td = node.data as TryCatchStmtData;
		td.finallyBody = rewriteAsyncReturn(td.finallyBody, promiseType, fnReturnInner, loc, retFutSym, pendingFinallies, stateSym, ctx);
		let childPending: Node[][] = pendingFinallies;
		const hasFin = td.finallyBody != null && !isEmptyBlock(td.finallyBody);
		if (hasFin && containsYield(node)) {
			childPending = [];
			for (const p of pendingFinallies) childPending.push(p);
			childPending.push(extractBodyStmts(td.finallyBody));
		}
		td.tryBody = rewriteAsyncReturn(td.tryBody, promiseType, fnReturnInner, loc, retFutSym, childPending, stateSym, ctx);
		td.catchBody = rewriteAsyncReturn(td.catchBody, promiseType, fnReturnInner, loc, retFutSym, childPending, stateSym, ctx);
		return node;
	}
	mapChildren(node, (child: Node): Node => rewriteAsyncReturn(child, promiseType, fnReturnInner, loc, retFutSym, pendingFinallies, stateSym, ctx));
	return node;
}

// Extract yield argument from nested stmts. Generator lower may place the yield return
// (return { value: future, done: false }) inside if/while blocks, not at the top level.
// This walks recursively to find and extract it, returning the yield arg (future node).
// Also replaces the found return+stateAssign with empty stmts to prevent duplicate emission.
function extractYieldArgDeep(stmts: Node[]): Node {
	for (let i = stmts.length - 1; i >= 0; i -= 1) {
		const s = stmts[i];
		if (s.kind == NodeKind.ReturnStmt) {
			const rd = s.data as ReturnStmtData;
			if (rd.argument != null && rd.argument.kind == NodeKind.ObjectLiteral) {
				const od = rd.argument.data as { properties: Node[], keys: string[] };
				if (od.properties.length > 0) {
					const yieldArg = od.properties[0];
					// Remove return + preceding state assign
					if (i > 0) { stmts.splice(i - 1, 2); }
					else { stmts.splice(i, 1); }
					return yieldArg;
				}
			}
		}
		// Recurse into blocks
		if (s.kind == NodeKind.BlockStmt) {
			const bd = s.data as BlockStmtData;
			const found = extractYieldArgDeep(bd.statements);
			if (found != null) return found;
		}
		if (s.kind == NodeKind.IfStmt) {
			const id = s.data as IfStmtData;
			if (id.consequent != null && id.consequent.kind == NodeKind.BlockStmt) {
				const found = extractYieldArgDeep((id.consequent.data as BlockStmtData).statements);
				if (found != null) return found;
			}
			if (id.alternate != null && id.alternate.kind == NodeKind.BlockStmt) {
				const found = extractYieldArgDeep((id.alternate.data as BlockStmtData).statements);
				if (found != null) return found;
			}
		}
	}
	return null as unknown as Node;
}

// Unbox function for msFutureRead result (same as builtinLower's unboxFnForType)
// Per-type smart read function — handles both boxed (spawn) and typed (async) via isBoxed flag
function readFnForAwait(t: Type | null): string {
	if (t == null) return "";
	return match (t.kind) {
		TypeKind.Number | TypeKind.Float64 | TypeKind.Float32 => "msFutureReadDouble",
		TypeKind.Boolean => "msFutureReadBool",
		TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 | TypeKind.Int64 => "msFutureReadInt32",
		TypeKind.String => "msFutureReadString",
		_ => "",
	};
}

// Build the async stepper dispatch: instead of generatorLower's iterator result pattern,
// emit msFutureAddCallback at yield points and msFutureComplete at return points.
interface YieldFuture { state: number; sym: Symbol; }

function yieldFutureSym(yfs: YieldFuture[], state: number): Symbol {
	for (const yf of yfs) {
		if (yf.state == state) return yf.sym;
	}
	throw new Error(`internal: async state ${state} resumes from a yield that holds no future`);
}

function buildAsyncStateDispatch(sc: StateCollector, yfs: YieldFuture[], promiseType: Type, closureType: Type, loc: SourceLocation): Node {
	// Default (terminal) state: return null (stepper done)
	let current: Node = makeBlock([makeReturn(makeNull(loc), loc)], loc);

	// Build if-else chain from last state to first
	for (let i = sc.items.length - 1; i >= 0; i -= 1) {
		const state = sc.items[i];
		const stateStmts: Node[] = [];

		// If previous state was a yield with a variable, emit unbox+assign at state entry.
		// This runs for BOTH yield and non-yield states (a state can resume from a previous
		// yield AND itself yield — e.g., `const num = await f(); const msg = await g();`).
		// Find the ACTUAL yield predecessor: the state whose nextState === i.
		// Can't use i-1 because splitIf creates parallel branches.
		let prevIdx = -1;
		let voidPrevIdx = -1;
		let pi = 0;
		while (pi < sc.items.length) {
			if (sc.items[pi].isYield && sc.items[pi].nextState == i) {
				if (sc.items[pi].yieldVarSym != null) prevIdx = pi;
				else voidPrevIdx = pi;
			}
			pi = pi + 1;
		}
		if (prevIdx < 0 && voidPrevIdx >= 0) {
			// Void await resume: no value to read, but the awaited future may have
			// failed — re-raise its error (reference: read() of Future[void] still
			// raises). The per-call check appends the goto to the catch.
			const yfSym = yieldFutureSym(yfs, voidPrevIdx);
			const yfType = promiseTypeFor(sc.items[voidPrevIdx].yieldVarType);
			const checkCall = makeCall(runtimeRef("msFutureCheckErr", loc), [makeTypedIdentResolved(yfSym, yfType, loc)], loc);
			stateStmts.push(makeExprStmt(checkCall, loc));
		}
		if (prevIdx >= 0) {
			const prevYfSym = yieldFutureSym(yfs, prevIdx);
			const varSym = sc.items[prevIdx].yieldVarSym!;
			let varType = sc.items[prevIdx].yieldVarType;
			// Defensive: if yieldVarType is still a Promise wrapper, extract inner type
			if (varType != null && isAwaitable(varType)) varType = awaitedType(varType);
			const prevYfType = promiseTypeFor(varType);
			const readFn = readFnForAwait(varType);
			let readExpr: Node | null = null;
			if (readFn != "") {
				readExpr = makeCall(runtimeRef(readFn, loc), [makeTypedIdentResolved(prevYfSym, prevYfType, loc)], loc);
				readExpr.nodeType = varType;
			} else {
				// Boxed types (struct/tuple/GI/array) — read the void* then copy out via
				// msUnboxStruct. String never reaches here (readFnForAwait handles it).
				const rawRead = makeCall(runtimeRef("msFutureRead", loc), [makeTypedIdentResolved(prevYfSym, prevYfType, loc)], loc);
				if (boxedInFuture(varType)) {
					readExpr = makeCall(runtimeRef("msUnboxStruct", loc), [rawRead], loc);
					readExpr.nodeType = varType;
				} else {
					readExpr = rawRead;
				}
			}
			stateStmts.push(makeExprStmt(
				makeAssign(makeTypedIdentResolved(varSym, varType, loc), readExpr, loc),
				loc,
			));
		}

		if (state.isYield) {
			// This state yields a future. The generator lower produces:
			//   [...stmts, $state=next, return {value: yieldArg, done: false}]
			// We replace with the stepper pattern:
			//   [...stmts, $yf_N = yieldArg, $state=next, if(finished) continue, return $yf_N]
			//
			// The yield return may be at the top level OR nested inside if/while blocks
			// (from splitIf/splitWhile). We handle both cases.
			let copyEnd = state.stmts.length;
			let yieldArg: Node = makeNull(loc);
			let foundTopLevel = false;

			// Try top-level pattern first (most common: last 2 stmts)
			if (copyEnd >= 2) {
				const returnStmt = state.stmts[copyEnd - 1];
				if (returnStmt.kind == NodeKind.ReturnStmt) {
					const rd = returnStmt.data as ReturnStmtData;
					if (rd.argument != null && rd.argument.kind == NodeKind.ObjectLiteral) {
						const od = rd.argument.data as { properties: Node[], keys: string[] };
						if (od.properties.length > 0) {
							yieldArg = od.properties[0];
							foundTopLevel = true;
						}
					}
				}
			}

			if (foundTopLevel) {
				// Top-level: copy all except last 2
				for (let j = 0; j < copyEnd - 2; j += 1) {
					stateStmts.push(state.stmts[j]);
				}

				// Save yielded future to a hoisted local (typed: Promise<T> from yield variable)
				const yfSym = yieldFutureSym(yfs, i);
				const yfType = promiseTypeFor(state.yieldVarType);
				const futAssign = makeExprStmt(
					makeAssign(makeTypedIdentResolved(yfSym, yfType, loc), yieldArg, loc),
					loc,
				);
				stateStmts.push(futAssign);

				// Set next state (reuse the state assign from splitStmts)
				stateStmts.push(state.stmts[copyEnd - 2]); // $state = nextState

				// Pre-resolved check: if (msFutureFinished($yf_N)) continue;
				const finishedCheck = makeCall(runtimeRef("msFutureFinished", loc), [makeTypedIdentResolved(yfSym, yfType, loc)], loc);
				finishedCheck.nodeType = booleanType();
				const continueStmt = makeContinue(loc);
				const preResolvedIf = makeIf(finishedCheck, makeBlock([continueStmt], loc), makeBlock([], loc), loc);
				stateStmts.push(preResolvedIf);

				// Not resolved: return the yielded future to msAsyncCb for registration
				stateStmts.push(makeReturn(makeTypedIdentResolved(yfSym, yfType, loc), loc));
			} else {
				// Nested yield: yield return is inside an if/while block (from splitIf/splitWhile).
				// Extract it recursively and replace with stepper pattern.
				const deepArg = extractYieldArgDeep(state.stmts);
				if (deepArg != null) {
					yieldArg = deepArg;
					// Copy remaining stmts (extractYieldArgDeep removed the yield return)
					for (const s of state.stmts) { stateStmts.push(s); }
					// Append stepper pattern
					const yfSym = yieldFutureSym(yfs, i);
					const yfType = promiseTypeFor(state.yieldVarType);
					stateStmts.push(makeExprStmt(makeAssign(makeTypedIdentResolved(yfSym, yfType, loc), yieldArg, loc), loc));
					stateStmts.push(makeExprStmt(makeAssign(makeTypedIdentResolved(sc.stateSym, null, loc), makeNumber(state.nextState, loc), loc), loc));
					const finishedCheck = makeCall(runtimeRef("msFutureFinished", loc), [makeTypedIdentResolved(yfSym, yfType, loc)], loc);
					finishedCheck.nodeType = booleanType();
					stateStmts.push(makeIf(finishedCheck, makeBlock([makeContinue(loc)], loc), makeBlock([], loc), loc));
					stateStmts.push(makeReturn(makeTypedIdentResolved(yfSym, yfType, loc), loc));
				} else {
					// Truly unexpected — copy all stmts unchanged
					for (const s of state.stmts) { stateStmts.push(s); }
				}
			}
		} else {
			// Non-yield state: copy stmts directly (unbox+assign already emitted above)
			for (const s of state.stmts) { stateStmts.push(s); }
		}

		const cond = makeBinary(
			makeTypedIdentResolved(sc.stateSym, numberType(), loc), "===",
			makeNumber(state.index, loc), loc,
		);
		const body = makeBlock(stateStmts, loc);
		current = makeIf(cond, body, current, loc);
	}
	return current;
}

function rewriteAwaitAsyncBody(body: Node, fnReturnInner: Type | null, ctx: TransformContext): Node {
	if (body == null) return body;
	if (body.kind != NodeKind.BlockStmt) return body;

	const loc = body.location;
	asyncNameCounter += 1;
	const retFutName = "$retFut" + asyncNameCounter;
	// retFutType: actual typed Promise for $retFut (Promise<number> → msFuture_double*)
	const retFutType = promiseTypeFor(fnReturnInner);
	const retFutSym = mintSym(ctx, SymbolKind.Variable, retFutName, retFutType);
	const promiseVoidType = createPromise(voidType());
	const stepperRetType = createClosureType([], [], createPtr(voidType()));  // returns void* (msFutureBase* or NULL)
	const closureType = stepperRetType;

	// 1. Extract body statements
	const bodyStmts = extractBodyStmts(body);

	// 1b. Collect variable types BEFORE rewriting (types are lost after transforms)
	const varTypes: VarTypeInfo[] = [];
	collectVarTypes(body, varTypes);

	// 2. Collect the locals for hoisting
	const locals = createSymSet();
	collectStateLocals(body, ctx, locals);

	const stateSym = mintSym(ctx, SymbolKind.Variable, "$state", numberType());
	setFlag(stateSym, SymbolFlag.Mutable);
	setFlag(stateSym, SymbolFlag.StateMachine);

	// 3. Rewrite returns: return val → msFutureComplete($retFut, val); return null;
	rewriteAsyncReturns(bodyStmts, retFutType, fnReturnInner, loc, retFutSym, [], stateSym, ctx);

	// 3b. Implicit void completion at body end
	bodyStmts.push(makeExprStmt(makeCall(
		runtimeRef("msFutureCompleteVoid", loc),
		[makeTypedIdentResolved(retFutSym, retFutType, loc)],
		loc,
	), loc));
	bodyStmts.push(makeReturn(makeNull(loc), loc));

	// 4. Split at yield points (reuse generatorLower's algorithm)
	const curExcSym = mintSym(ctx, SymbolKind.Variable, "$curExc", null);
	setFlag(curExcSym, SymbolFlag.Mutable);
	const sc: StateCollector = { items: [], loopStack: [], excType: null, finallyStack: [], stateSym, curExcSym };
	const initState = allocState(sc);
	const doneState = -1;
	splitStmts(bodyStmts, sc, initState, doneState, loc, null as unknown as Type);

	// 5. Patch yieldVarType from collected varTypes (nodeType may be cleared by transforms)
	for (let si = 0; si < sc.items.length; si += 1) {
		if (sc.items[si].isYield && sc.items[si].yieldVarSym != null) {
			const collected = findVarType(varTypes, sc.items[si].yieldVarSym!);
			if (collected != null) {
				// Collected type may be Promise<T> from async call return type — extract T
				sc.items[si].yieldVarType = isAwaitable(collected) ? awaitedType(collected) : collected;
			}
		}
	}

	// 6. Convert the declarations of the locals that outlive a state to assignments
	const lifted = localsSpanningStates(sc, locals);
	// Also add yielded-future locals ($yf0, $yf1, ...) to the hoisted set
	// with typed future types (Promise<T> from the yield variable type)
	const yfs: YieldFuture[] = [];
	for (let si = 0; si < sc.items.length; si += 1) {
		convertDeclsToAssigns(sc.items[si].stmts, lifted, loc);
		if (sc.items[si].isYield) {
			const yfName = "$yf" + si;
			// Set $yf type to Promise<T> where T = yield variable type
			const yfVarType = sc.items[si].yieldVarType;
			const yfFutType = promiseTypeFor(yfVarType);
			const yfSym = mintSym(ctx, SymbolKind.Variable, yfName, yfFutType);
			symSetAdd(lifted, yfSym);
			yfs.push({ state: si, sym: yfSym });
			varTypes.push({ varType: yfFutType, varSym: yfSym });
		}
	}

	// 6. Build async state dispatch (stepper pattern instead of iterator pattern)
	const dispatch = buildAsyncStateDispatch(sc, yfs, promiseVoidType, closureType, loc);

	// 6b. Inner exceptionTable routing (closureiters tầng 1): route a raised state
	// to its landing; the terminal re-raises `$curExc` out to the outer
	// fail-catch below (asyncmacro tầng 2). Mirrors transformGeneratorFn.
	const hasExc = hasExcLanding(sc);
	const dispatchBody = wrapExcRouting(dispatch, sc, ctx, loc);

	// 7. Wrap in while(true) + try/catch
	const loop = makeWhile(makeBool(true, loc), dispatchBody, loc);
	const tryBody = makeBlock([loop], loc);
	const excSym = makeCatchSym(ctx, "$e");
	const failCall = makeExprStmt(
		makeCall(
			runtimeRef("msFutureFail", loc),
			[makeTypedIdentResolved(retFutSym, retFutType, loc), makeTypedIdentResolved(excSym, null, loc)],
			loc,
		),
		loc,
	);
	const catchBody = makeBlock([failCall, makeReturn(makeNull(loc), loc)], loc);
	const tryCatch = makeTryCatch(tryBody, excSym, catchBody, makeBlock([], loc), loc);

	// 8. Build stepper as FunctionExpr
	const stepperBody = makeBlock([tryCatch, makeReturn(makeNull(loc), loc)], loc);
	const stepperFnExpr = createNode(NodeKind.FunctionExpr, {
		funcExprParams: [],
		funcExprParamTypes: [],
		funcExprBody: stepperBody,
		funcExprFlags: "",
		funcExprReturnType: "void*",  // returns msFuture* (next future) or NULL (done)
	}, syntheticToken(loc));
	stepperFnExpr.nodeType = closureType;
	stepperFnExpr.paramSyms = [];

	// 9. Build outer function body
	const outerStmts: Node[] = [];

	// const $retFut = msFutureCreate[Inline]();
	// Primitives use the generic 16-byte slot. Struct/tuple/generic-instance types
	// larger than 16 bytes need typed-sized allocation via msFutureCreateInline.
	const retFutInit = makeRetFutAlloc(fnReturnInner, loc);
	if (!isStructLikeType(fnReturnInner)) retFutInit.nodeType = retFutType;
	const retFutDecl = makeVarDecl(retFutName, retFutInit, DeclKind.Const, loc);
	retFutDecl.nodeType = retFutType;
	retFutDecl.resolvedSym = retFutSym;
	outerStmts.push(retFutDecl);

	// let $state = 0;
	const stateDecl = makeVarDecl("$state", makeNumber(0, loc), DeclKind.Let, loc);
	stateDecl.nodeType = numberType();
	stateDecl.resolvedSym = stateSym;
	outerStmts.push(stateDecl);

	// Env-carried current exception (reference :curExc) — buildExcRouting stores
	// the caught exception here so a catch state can bind its variable across the
	// await→raise→catch boundary.
	if (hasExc) outerStmts.push(makeCurExcDecl(sc, loc));

	// Hoisted locals: let a; let b; let $yf0; let $yf1; ...
	// Set nodeType from original declarations so lambda lifting creates typed env fields.
	for (const sym of lifted.items) {
		const origType = findVarType(varTypes, sym);
		const defaultInit = (origType != null) ? makeDefaultValue(origType, loc) : makeNull(loc);
		const localDecl = makeVarDecl(sym.name, defaultInit, DeclKind.Let, loc);
		if (origType != null) {
			localDecl.nodeType = origType;
		}
		localDecl.resolvedSym = sym;
		outerStmts.push(localDecl);
	}

	// const $stepper = function() { ... };
	// No self-reference needed — msAsyncCb handles re-registration externally.
	const stepperSym = mintSym(ctx, SymbolKind.Variable, "$stepper", closureType);
	const stepperDecl = makeVarDecl("$stepper", stepperFnExpr, DeclKind.Const, loc);
	stepperDecl.nodeType = closureType;
	stepperDecl.resolvedSym = stepperSym;
	outerStmts.push(stepperDecl);


	// msAsyncStart($retFut, $stepper) — createCb pattern: C callback drives the stepper
	const kickoffCall = makeCall(
		runtimeRef("msAsyncStart", loc),
		[makeTypedIdentResolved(retFutSym, retFutType, loc), makeTypedIdentResolved(stepperSym, closureType, loc)],
		loc,
	);
	outerStmts.push(makeExprStmt(kickoffCall, loc));

	// return $retFut;
	const returnFut = makeReturn(makeTypedIdentResolved(retFutSym, retFutType, loc), loc);
	outerStmts.push(returnFut);

	return makeBlock(outerStmts, loc);
}


// Recursively rewrite all ReturnStmt nodes to msFutureComplete + return $retFut.
// Stops at nested function boundaries (each function has its own return semantics).
function rewriteReturns(node: Node, promiseType: Type | null, fnReturnInner: Type | null, retFutSym: Symbol, ctx: TransformContext): void {
	if (node == null || isFuncBoundary(node)) return;
	if (node.kind == NodeKind.BlockStmt) {
		const d = node.data as BlockStmtData;
		const newStmts: Node[] = [];
		for (const stmt of d.statements) {
			if (stmt.kind == NodeKind.ReturnStmt) {
				for (const s of completeAndReturn(stmt, promiseType, fnReturnInner, retFutSym, ctx)) newStmts.push(s);
			} else {
				rewriteReturns(stmt, promiseType, fnReturnInner, retFutSym, ctx);
				newStmts.push(stmt);
			}
		}
		d.statements = newStmts;
		return;
	}
	mapChildren(node, (child: Node): Node => {
		if (child.kind == NodeKind.ReturnStmt) return makeBlock(completeAndReturn(child, promiseType, fnReturnInner, retFutSym, ctx), child.location);
		rewriteReturns(child, promiseType, fnReturnInner, retFutSym, ctx);
		return child;
	});
}

function completeAndReturn(stmt: Node, promiseType: Type | null, fnReturnInner: Type | null, retFutSym: Symbol, ctx: TransformContext): Node[] {
	const rd = stmt.data as ReturnStmtData;
	const loc = stmt.location;
	const out: Node[] = [];
	const isVoid = fnReturnInner == null || fnReturnInner.kind == TypeKind.Void;
	let completeCall: Node | null = null;
	if (isVoid || rd.argument == null) {
		completeCall = makeCall(runtimeRef("msFutureCompleteVoid", loc),
			[makeTypedIdentResolved(retFutSym, promiseType, loc)], loc);
	} else if (boxedInFuture(fnReturnInner)) {
		const voidPtrType = createPtr(createPrimitive(TypeKind.Void));
		const boxCall = makeCall(runtimeRef("msSinkBoxStruct", loc), [rd.argument], loc);
		boxCall.nodeType = voidPtrType;
		const boxSym = mintSym(ctx, SymbolKind.Variable, retFutSym.name + "_b", voidPtrType);
		const boxDecl = makeVarDecl(boxSym.name, boxCall, DeclKind.Const, loc);
		boxDecl.nodeType = voidPtrType;
		boxDecl.resolvedSym = boxSym;
		out.push(boxDecl);
		completeCall = makeCall(runtimeRef("msFutureComplete", loc),
			[makeTypedIdentResolved(retFutSym, promiseType, loc), makeTypedIdentResolved(boxSym, voidPtrType, loc)], loc);
	} else {
		completeCall = makeCall(runtimeRef("msFutureCompleteT", loc),
			[makeTypedIdentResolved(retFutSym, promiseType, loc), rd.argument], loc);
	}
	out.push(makeExprStmt(completeCall, loc));
	out.push(makeReturn(makeTypedIdentResolved(retFutSym, promiseType, loc), loc));
	return out;
}

// Simple wrapper: async function with no await → wrap return value in msFutureComplete
function rewriteSimpleAsyncBody(body: Node, fnReturnInner: Type | null, ctx: TransformContext): Node {
	if (body == null) return body;
	if (body.kind != NodeKind.BlockStmt) return body;

	const bd = body.data as BlockStmtData;
	const loc = body.location;
	asyncNameCounter += 1;
	const retFutName = "$retFut" + asyncNameCounter;

	const retFutType = promiseTypeFor(fnReturnInner);
	const retFutSym = mintSym(ctx, SymbolKind.Variable, retFutName, retFutType);
	const promiseVoidType = createPromise(voidType());

	// const $retFut = msFutureCreate[Inline]();  (see makeRetFutAlloc)
	const retFutInit = makeRetFutAlloc(fnReturnInner, loc);
	if (!isStructLikeType(fnReturnInner)) retFutInit.nodeType = retFutType;
	const retFutDecl = makeVarDecl(retFutName, retFutInit, DeclKind.Const, loc);
	retFutDecl.nodeType = retFutType;
	retFutDecl.resolvedSym = retFutSym;

	// Rewrite all return statements recursively (handles if/else, while, try/catch)
	rewriteReturns(body, retFutType, fnReturnInner, retFutSym, ctx);

	// Read bd.statements AFTER rewriteReturns (it mutates the array).
	const rewrittenStmts = bd.statements;
	const tryStmts: Node[] = [];
	for (const stmt of rewrittenStmts) {
		tryStmts.push(stmt);
	}

	// If no explicit return at end, add implicit void completion. No incref on
	// $retFut — DRC's caller-side `ensureDestructionIfNeeded` (inject.ms) emits
	// msFutureDrcDestroy, balancing the rc=0 sole-owner allocation.
	if (rewrittenStmts.length == 0 || rewrittenStmts[rewrittenStmts.length - 1].kind != NodeKind.ReturnStmt) {
		const completeCall = makeCall(
			runtimeRef("msFutureCompleteVoid", loc),
			[makeTypedIdentResolved(retFutSym, retFutType, loc)],
			loc,
		);
		tryStmts.push(makeExprStmt(completeCall, loc));
		tryStmts.push(makeReturn(makeTypedIdentResolved(retFutSym, retFutType, loc), loc));
	}

	// A throw in the body must FAIL $retFut and return it — otherwise the throw
	// escapes past the `return $retFut`, leaving the caller with an uncompleted /
	// NULL future (→ msWaitForReady crash). Mirrors the with-await stepper catch.
	const excSym = makeCatchSym(ctx, "$e");
	const failCall = makeExprStmt(
		makeCall(
			runtimeRef("msFutureFail", loc),
			[makeTypedIdentResolved(retFutSym, retFutType, loc), makeTypedIdentResolved(excSym, null, loc)],
			loc,
		),
		loc,
	);
	const catchBody = makeBlock([failCall, makeReturn(makeTypedIdentResolved(retFutSym, retFutType, loc), loc)], loc);
	const tryCatch = makeTryCatch(makeBlock(tryStmts, loc), excSym, catchBody, makeBlock([], loc), loc);

	return makeBlock([retFutDecl, tryCatch], loc);
}

// ===== Walk: Find was-async functions and rewrite =====

function isWasAsync(node: Node): boolean {
	return node.flags.has(NodeFlag.WasAsync);
}

// Extract Promise<T>'s inner type from a function's declared return type.
function getFnReturnInner(fnNode: Node): Type | null {
	if (fnNode == null || fnNode.nodeType == null) return null;
	const fnType = fnNode.nodeType;
	if (fnType.kind != TypeKind.Function || fnType.typeReturn == null) return null;
	if (isAwaitable(fnType.typeReturn)) return awaitedType(fnType.typeReturn);
	return null;
}

function rewriteAsyncFnBody(body: Node, fnReturnInner: Type | null, ctx: TransformContext): Node {
	if (body != null && body.kind != NodeKind.BlockStmt) {
		throw "internal: async fn body reached asyncBridge un-normalized (expected BlockStmt)";
	}
	if (!containsYield(body)) {
		return rewriteSimpleAsyncBody(body, fnReturnInner, ctx);
	}
	return rewriteAwaitAsyncBody(body, fnReturnInner, ctx);
}

function walkBridge(node: Node | null, ctx: TransformContext): void {
	if (node == null) return;
	match (node.kind) {
		NodeKind.FunctionDecl => {
			const d = node.data as FunctionDeclData;
			walkBridge(d.fnBody, ctx);
			if (isWasAsync(node)) { d.fnBody = rewriteAsyncFnBody(d.fnBody, getFnReturnInner(node), ctx); d.fnFlags = ""; }
		},
		NodeKind.MethodDecl => {
			const d = node.data as MethodDeclData;
			walkBridge(d.methodBody, ctx);
			if (isWasAsync(node)) { d.methodBody = rewriteAsyncFnBody(d.methodBody, getFnReturnInner(node), ctx); d.methodFlags = ""; }
		},
		NodeKind.FunctionExpr => {
			const d = node.data as FunctionExprData;
			walkBridge(d.funcExprBody, ctx);
			if (isWasAsync(node)) { d.funcExprBody = rewriteAsyncFnBody(d.funcExprBody, getFnReturnInner(node), ctx); d.funcExprFlags = ""; }
		},
		NodeKind.ArrowFunction => {
			const d = node.data as ArrowFunctionData;
			walkBridge(d.arrowBody, ctx);
			if (isWasAsync(node)) { d.arrowBody = rewriteAsyncFnBody(d.arrowBody, getFnReturnInner(node), ctx); d.arrowFlags = ""; }
		},
		_ => { forEachChild(node, (child: Node): void => { walkBridge(child, ctx); }); },
	};
}

// ===== Entry Point =====

export function lowerAsyncBridge(program: Node, ctx: TransformContext): Node {
	asyncNameCounter = 0;
	walkBridge(program, ctx);
	return program;
}

// ===== Tests =====

test "non-async passthrough" {
	assert stmtCountAfter("function f() { return 1; }", lowerAsyncBridge) == 1;
}

test "non-generator passthrough" {
	assert stmtCountAfter("const x = 1;", lowerAsyncBridge) == 1;
}

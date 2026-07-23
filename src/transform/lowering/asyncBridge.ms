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

import { Node, NodeKind, NodeFlag, DeclKind, createNode, SourceLocation, ProgramData, BlockStmtData, FunctionDeclData, FunctionExprData, ArrowFunctionData, MethodDeclData, ReturnStmtData, ExportDeclData, ClassDeclData, DecoratedDeclData, VariableDeclData, ExprStmtData, IfStmtData, WhileStmtData, TryCatchStmtData, CallExprData, BinaryExprData, Type, TypeKind } from "../../ast/node";
import { TransformContext } from "../context";
import {
	makeIdent, makeTypedIdent, makeVarDecl, makeExprStmt, makeReturn,
	makeCall, makeBlock, makeNull, makeDefaultValue, makeIf, makeWhile, makeBool, makeNumber, makeString,
	makeAssign, makeBinary, makeTryCatch, makeContinue, syntheticToken, extractBodyStmts, collectDeclNames,
} from "../util";
import { NameSet, createNameSet, nameSetAdd } from "../context";
import { createPromise, createFunction, createPtr, createPrimitive, voidType, unknownType, booleanType, numberType, isAwaitable, awaitedType } from "../../checker/types";
import { StateCollector, allocState, splitStmts, convertDeclsToAssigns, makeStateAssign, buildExcRouting } from "./generatorLower";
import { stmtCountAfter } from "../testUtil";

// ===== Variable Type Collection =====
// Walk body to collect variable name → Type BEFORE rewriting. Used to set nodeType
// on hoisted locals so lambda lifting creates correctly typed env struct fields.

interface VarTypeInfo { name: string; varType: Type; }

function collectVarTypes(node: Node, result: VarTypeInfo[]): void {
	if (node === null) return;
	match (node.kind) {
		NodeKind.FunctionDecl | NodeKind.ArrowFunction | NodeKind.FunctionExpr => {},
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			let varType = node.nodeType;
			if (varType === null && d.initializer !== null && d.initializer.nodeType !== null) {
				varType = d.initializer.nodeType;
			}
			if (varType === null && node.resolvedSym !== null && node.resolvedSym.symbolType !== null) {
				varType = node.resolvedSym.symbolType;
			}
			if (varType !== null) {
				result.push({ name: d.declName, varType });
			}
		},
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			for (const s of d.statements) { collectVarTypes(s, result); }
		},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			collectVarTypes(d.consequent, result);
			collectVarTypes(d.alternate, result);
		},
		NodeKind.WhileStmt => { collectVarTypes((node.data as WhileStmtData).whileBody, result); },
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			collectVarTypes(d.tryBody, result);
			collectVarTypes(d.catchBody, result);
		},
		_ => {},
	};
}

function findVarType(entries: VarTypeInfo[], name: string): Type {
	for (const e of entries) {
		if (e.name === name) return e.varType;
	}
	return null as unknown as Type;
}

// Promise<T> from inner type, or Promise<void> if null
function promiseTypeFor(inner: Type | null): Type {
	return inner !== null ? createPromise(inner) : createPromise(voidType());
}

import { isStructLikeType, inlineInFuture, boxedInFuture } from "../util";

// $retFut allocation: String needs the 16-byte inline slot; everything else uses
// the 8-byte generic future (boxed types store a void*). nodeType carries
// Promise<T> so DRC's cross-pass contract holds; codegen extracts T via awaitedType.
function makeRetFutAlloc(innerType: Type | null, loc: SourceLocation): Node {
	if (inlineInFuture(innerType)) {
		const inlineCall = makeCall(makeIdent("msFutureCreateInline", loc), [], loc);
		inlineCall.nodeType = promiseTypeFor(innerType);
		return inlineCall;
	}
	const call = makeCall(makeIdent("msFutureCreate", loc), [], loc);
	call.nodeType = promiseTypeFor(innerType);
	return call;
}

// Zero value for a type — used as fallback in msFutureReadT(f, zeroval) when future failed
function zeroValueForType(t: Type, loc: SourceLocation): Node {
	if (t === null) return makeNull(loc);
	return match (t.kind) {
		TypeKind.Number | TypeKind.Float64 | TypeKind.Float32
			| TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 | TypeKind.Int64 => makeNumber(0, loc),
		TypeKind.Boolean => makeBool(false, loc),
		TypeKind.String => makeString("", loc),
		_ => makeNull(loc),
	};
}

// ===== Core: Rewrite a was-async function body =====

// Check if this function body contains any yield (from asyncDesugar converting await→yield).
// If no yield, the async function is synchronous and can use the simple wrapper pattern.
function hasYieldInBody(node: Node): boolean {
	if (node === null) return false;
	return match (node.kind) {
		NodeKind.YieldExpr => true,
		NodeKind.FunctionDecl | NodeKind.FunctionExpr | NodeKind.ArrowFunction => false,
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			for (const s of d.statements) { if (hasYieldInBody(s)) return true; }
			return false;
		},
		NodeKind.ReturnStmt => { return hasYieldInBody((node.data as ReturnStmtData).argument); },
		NodeKind.ExprStmt => { return hasYieldInBody((node.data as ExprStmtData).expr); },
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			return hasYieldInBody(d.consequent) || hasYieldInBody(d.alternate);
		},
		NodeKind.WhileStmt => { return hasYieldInBody((node.data as WhileStmtData).whileBody); },
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			return hasYieldInBody(d.tryBody) || hasYieldInBody(d.catchBody) || hasYieldInBody(d.finallyBody);
		},
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			return hasYieldInBody(d.initializer);
		},
		_ => false,
	};
}

// ===== Await case: inline stepper with state machine =====
// Reuses generatorLower's state-splitting algorithm but emits a stepper function
// instead of an iterator object. The stepper IS the state machine.

// Rewrite return stmts in the body for the state machine:
// return val → msFutureComplete($retFut, val); return;
// Build the msFutureCompleteT or msFutureCompleteVoid statement(s) for a return value.
// Returns an array of statements (usually 1, but 2 for arrays due to msSinkBoxStruct expansion).
function makeFutureCompleteStmts(valueExpr: Node, isVoid: boolean, promiseType: Type, fnReturnInner: Type | null, loc: SourceLocation): Node[] {
	if (isVoid || valueExpr === null) {
		return [makeExprStmt(makeCall(
			makeIdent("msFutureCompleteVoid", loc),
			[makeTypedIdent("$retFut", promiseType, loc)],
			loc,
		), loc)];
	}
	// Boxed types: msSinkBoxStruct is a multi-statement codegen expansion (can't
	// nest in another call), so box via a separate VarDecl then complete with the
	// void* pointer. Codegen reads sizeof(T) from the box arg's nodeType.
	if (boxedInFuture(fnReturnInner)) {
		const voidPtrType = createPtr(createPrimitive(TypeKind.Void));
		const boxCall = makeCall(makeIdent("msSinkBoxStruct", loc), [valueExpr], loc);
		boxCall.nodeType = voidPtrType;
		const boxDecl = makeVarDecl("$boxed", boxCall, DeclKind.Const, loc);
		boxDecl.nodeType = voidPtrType;  // variable holds void* (the boxed pointer)
		const completeStmt = makeExprStmt(makeCall(
			makeIdent("msFutureComplete", loc),
			[makeTypedIdent("$retFut", promiseType, loc), makeIdent("$boxed", loc)],
			loc,
		), loc);
		return [boxDecl, completeStmt];
	}
	return [makeExprStmt(makeCall(
		makeIdent("msFutureCompleteT", loc),
		[makeTypedIdent("$retFut", promiseType, loc), valueExpr],
		loc,
	), loc)];
}

function rewriteAsyncReturns(stmts: Node[], promiseType: Type, fnReturnInner: Type | null, loc: SourceLocation): void {
	for (let i = 0; i < stmts.length; i += 1) {
		const stmt = stmts[i];
		if (stmt === null) continue;
		match (stmt.kind) {
			NodeKind.ReturnStmt => {
				const rd = stmt.data as ReturnStmtData;
				const isVoidReturn = fnReturnInner === null || fnReturnInner.kind === TypeKind.Void;

				const completeStmts = makeFutureCompleteStmts(rd.argument, isVoidReturn, promiseType, fnReturnInner, loc);
				const blockStmts: Node[] = [makeStateAssign(-1, loc)];
				for (const cs of completeStmts) blockStmts.push(cs);
				blockStmts.push(makeReturn(makeNull(loc), loc));
				const block = makeBlock(blockStmts, loc);
				stmts[i] = block;
			},
			NodeKind.BlockStmt => {
				const bd = stmt.data as BlockStmtData;
				rewriteAsyncReturns(bd.statements, promiseType, fnReturnInner, loc);
			},
			NodeKind.IfStmt => {
				const id = stmt.data as IfStmtData;
				if (id.consequent !== null && id.consequent.kind === NodeKind.BlockStmt) {
					rewriteAsyncReturns((id.consequent.data as BlockStmtData).statements, promiseType, fnReturnInner, loc);
				}
				if (id.alternate !== null && id.alternate.kind === NodeKind.BlockStmt) {
					rewriteAsyncReturns((id.alternate.data as BlockStmtData).statements, promiseType, fnReturnInner, loc);
				}
			},
			NodeKind.WhileStmt => {
				const wd = stmt.data as WhileStmtData;
				if (wd.whileBody !== null && wd.whileBody.kind === NodeKind.BlockStmt) {
					rewriteAsyncReturns((wd.whileBody.data as BlockStmtData).statements, promiseType, fnReturnInner, loc);
				}
			},
			NodeKind.TryCatchStmt => {
				const td = stmt.data as TryCatchStmtData;
				if (td.tryBody !== null && td.tryBody.kind === NodeKind.BlockStmt) {
					rewriteAsyncReturns((td.tryBody.data as BlockStmtData).statements, promiseType, fnReturnInner, loc);
				}
				if (td.catchBody !== null && td.catchBody.kind === NodeKind.BlockStmt) {
					rewriteAsyncReturns((td.catchBody.data as BlockStmtData).statements, promiseType, fnReturnInner, loc);
				}
			},
			_ => {},
		};
	}
}

// Extract yield argument from nested stmts. Generator lower may place the yield return
// (return { value: future, done: false }) inside if/while blocks, not at the top level.
// This walks recursively to find and extract it, returning the yield arg (future node).
// Also replaces the found return+stateAssign with empty stmts to prevent duplicate emission.
function extractYieldArgDeep(stmts: Node[]): Node {
	for (let i = stmts.length - 1; i >= 0; i -= 1) {
		const s = stmts[i];
		if (s.kind === NodeKind.ReturnStmt) {
			const rd = s.data as ReturnStmtData;
			if (rd.argument !== null && rd.argument.kind === NodeKind.ObjectLiteral) {
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
		if (s.kind === NodeKind.BlockStmt) {
			const bd = s.data as BlockStmtData;
			const found = extractYieldArgDeep(bd.statements);
			if (found !== null) return found;
		}
		if (s.kind === NodeKind.IfStmt) {
			const id = s.data as IfStmtData;
			if (id.consequent !== null && id.consequent.kind === NodeKind.BlockStmt) {
				const found = extractYieldArgDeep((id.consequent.data as BlockStmtData).statements);
				if (found !== null) return found;
			}
			if (id.alternate !== null && id.alternate.kind === NodeKind.BlockStmt) {
				const found = extractYieldArgDeep((id.alternate.data as BlockStmtData).statements);
				if (found !== null) return found;
			}
		}
	}
	return null as unknown as Node;
}

// Unbox function for msFutureRead result (same as builtinLower's unboxFnForType)
// Per-type smart read function — handles both boxed (spawn) and typed (async) via isBoxed flag
function readFnForAwait(t: Type): string {
	if (t === null) return "";
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
function buildAsyncStateDispatch(sc: StateCollector, promiseType: Type, closureType: Type, loc: SourceLocation): Node {
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
		let pi = 0;
		while (pi < sc.items.length) {
			if (sc.items[pi].isYield && sc.items[pi].nextState === i && sc.items[pi].yieldVarName !== "") {
				prevIdx = pi;
			}
			pi = pi + 1;
		}
		if (prevIdx >= 0) {
			const futName = "$yf" + prevIdx;
			const varName = sc.items[prevIdx].yieldVarName;
			let varType = sc.items[prevIdx].yieldVarType;
			// Defensive: if yieldVarType is still a Promise wrapper, extract inner type
			if (varType !== null && isAwaitable(varType)) varType = awaitedType(varType);
			const prevYfType = promiseTypeFor(varType);
			const readFn = readFnForAwait(varType);
			let readExpr: Node = null as unknown as Node;
			if (readFn !== "") {
				readExpr = makeCall(makeIdent(readFn, loc), [makeTypedIdent(futName, prevYfType, loc)], loc);
				readExpr.nodeType = varType;
			} else {
				// Boxed types (struct/tuple/GI/array) — read the void* then copy out via
				// msUnboxStruct. String never reaches here (readFnForAwait handles it).
				const rawRead = makeCall(makeIdent("msFutureRead", loc), [makeTypedIdent(futName, prevYfType, loc)], loc);
				if (boxedInFuture(varType)) {
					readExpr = makeCall(makeIdent("msUnboxStruct", loc), [rawRead], loc);
					readExpr.nodeType = varType;
				} else {
					readExpr = rawRead;
				}
			}
			stateStmts.push(makeExprStmt(
				makeAssign(makeTypedIdent(varName, varType, loc), readExpr, loc),
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
				if (returnStmt.kind === NodeKind.ReturnStmt) {
					const rd = returnStmt.data as ReturnStmtData;
					if (rd.argument !== null && rd.argument.kind === NodeKind.ObjectLiteral) {
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
				const futName = "$yf" + i;
				const yfType = promiseTypeFor(state.yieldVarType);
				const futAssign = makeExprStmt(
					makeAssign(makeTypedIdent(futName, yfType, loc), yieldArg, loc),
					loc,
				);
				stateStmts.push(futAssign);

				// Set next state (reuse the state assign from splitStmts)
				stateStmts.push(state.stmts[copyEnd - 2]); // $state = nextState

				// Pre-resolved check: if (msFutureFinished($yf_N)) continue;
				const finishedCheck = makeCall(makeIdent("msFutureFinished", loc), [makeTypedIdent(futName, yfType, loc)], loc);
				finishedCheck.nodeType = booleanType();
				const continueStmt = makeContinue(loc);
				const preResolvedIf = makeIf(finishedCheck, makeBlock([continueStmt], loc), makeBlock([], loc), loc);
				stateStmts.push(preResolvedIf);

				// Not resolved: return the yielded future to msAsyncCb for registration
				stateStmts.push(makeReturn(makeTypedIdent(futName, yfType, loc), loc));
			} else {
				// Nested yield: yield return is inside an if/while block (from splitIf/splitWhile).
				// Extract it recursively and replace with stepper pattern.
				const deepArg = extractYieldArgDeep(state.stmts);
				if (deepArg !== null) {
					yieldArg = deepArg;
					// Copy remaining stmts (extractYieldArgDeep removed the yield return)
					for (const s of state.stmts) { stateStmts.push(s); }
					// Append stepper pattern
					const futName = "$yf" + i;
					const yfType = promiseTypeFor(state.yieldVarType);
					stateStmts.push(makeExprStmt(makeAssign(makeTypedIdent(futName, yfType, loc), yieldArg, loc), loc));
					stateStmts.push(makeExprStmt(makeAssign(makeIdent("$state", loc), makeNumber(state.nextState, loc), loc), loc));
					const finishedCheck = makeCall(makeIdent("msFutureFinished", loc), [makeTypedIdent(futName, yfType, loc)], loc);
					finishedCheck.nodeType = booleanType();
					stateStmts.push(makeIf(finishedCheck, makeBlock([makeContinue(loc)], loc), makeBlock([], loc), loc));
					stateStmts.push(makeReturn(makeTypedIdent(futName, yfType, loc), loc));
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
			makeTypedIdent("$state", numberType(), loc), "===",
			makeNumber(state.index, loc), loc,
		);
		const body = makeBlock(stateStmts, loc);
		current = makeIf(cond, body, current, loc);
	}
	return current;
}

function rewriteAwaitAsyncBody(body: Node, fnReturnInner: Type | null): Node {
	if (body === null) return body;
	if (body.kind !== NodeKind.BlockStmt) return body;

	const loc = body.location;
	// retFutType: actual typed Promise for $retFut (Promise<number> → msFuture_double*)
	const retFutType = promiseTypeFor(fnReturnInner);
	const promiseVoidType = createPromise(voidType());
	const stepperRetType = createFunction([], [], unknownType());  // returns void* (msFutureBase* or NULL)
	const closureType = stepperRetType;

	// 1. Extract body statements
	const bodyStmts = extractBodyStmts(body);

	// 1b. Collect variable types BEFORE rewriting (types are lost after transforms)
	const varTypes: VarTypeInfo[] = [];
	collectVarTypes(body, varTypes);

	// 2. Collect local variable names for hoisting
	const nc: NameSet = createNameSet();
	collectDeclNames(body, nc, false);

	// 3. Rewrite returns: return val → msFutureComplete($retFut, val); return null;
	rewriteAsyncReturns(bodyStmts, retFutType, fnReturnInner, loc);

	// 3b. Implicit void completion at body end
	bodyStmts.push(makeExprStmt(makeCall(
		makeIdent("msFutureCompleteVoid", loc),
		[makeTypedIdent("$retFut", retFutType, loc)],
		loc,
	), loc));
	bodyStmts.push(makeReturn(makeNull(loc), loc));

	// 4. Split at yield points (reuse generatorLower's algorithm)
	const sc: StateCollector = { items: [], loopStack: [] };
	const initState = allocState(sc);
	const doneState = -1;
	splitStmts(bodyStmts, sc, initState, doneState, loc, null as unknown as Type);

	// 5. Patch yieldVarType from collected varTypes (nodeType may be cleared by transforms)
	for (let si = 0; si < sc.items.length; si += 1) {
		if (sc.items[si].isYield && sc.items[si].yieldVarName !== "") {
			const collected = findVarType(varTypes, sc.items[si].yieldVarName);
			if (collected !== null) {
				// Collected type may be Promise<T> from async call return type — extract T
				sc.items[si].yieldVarType = isAwaitable(collected) ? awaitedType(collected) : collected;
			}
		}
	}

	// 6. Convert variable declarations to assignments in all state bodies
	// Also add yielded-future locals ($yf0, $yf1, ...) to the hoisted set
	// with typed future types (Promise<T> from the yield variable type)
	for (let si = 0; si < sc.items.length; si += 1) {
		convertDeclsToAssigns(sc.items[si].stmts, nc, loc);
		if (sc.items[si].isYield) {
			const yfName = "$yf" + si;
			nameSetAdd(nc, yfName);
			// Set $yf type to Promise<T> where T = yield variable type
			const yfVarType = sc.items[si].yieldVarType;
			const yfFutType = promiseTypeFor(yfVarType);
			varTypes.push({ name: yfName, varType: yfFutType });
		}
	}

	// 6. Build async state dispatch (stepper pattern instead of iterator pattern)
	const dispatch = buildAsyncStateDispatch(sc, promiseVoidType, closureType, loc);

	// 6b. Inner exceptionTable routing (closureiters tầng 1): route a raised state
	// to its landing; the terminal re-raises `$excCaught` out to the outer
	// fail-catch below (asyncmacro tầng 2). Mirrors transformGeneratorFn.
	let hasExc = false;
	for (const st of sc.items) { if (st.excLanding >= 0) hasExc = true; }
	let dispatchBody = dispatch;
	if (hasExc) {
		dispatchBody = makeTryCatch(dispatch, "$excCaught", buildExcRouting(sc, loc), null as unknown as Node, loc);
	}

	// 7. Wrap in while(true) + try/catch
	const loop = makeWhile(makeBool(true, loc), dispatchBody, loc);
	const tryBody = makeBlock([loop], loc);
	const failCall = makeExprStmt(
		makeCall(
			makeIdent("msFutureFail", loc),
			[makeTypedIdent("$retFut", retFutType, loc), makeIdent("$e", loc)],
			loc,
		),
		loc,
	);
	const catchBody = makeBlock([failCall, makeReturn(makeNull(loc), loc)], loc);
	const tryCatch = makeTryCatch(tryBody, "$e", catchBody, makeBlock([], loc), loc);

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

	// 9. Build outer function body
	const outerStmts: Node[] = [];

	// const $retFut = msFutureCreate[Inline]();
	// Primitives use the generic 16-byte slot. Struct/tuple/generic-instance types
	// larger than 16 bytes need typed-sized allocation via msFutureCreateInline.
	const retFutInit = makeRetFutAlloc(fnReturnInner, loc);
	if (!isStructLikeType(fnReturnInner)) retFutInit.nodeType = retFutType;
	const retFutDecl = makeVarDecl("$retFut", retFutInit, DeclKind.Const, loc);
	retFutDecl.nodeType = retFutType;
	outerStmts.push(retFutDecl);

	// let $state = 0;
	const stateDecl = makeVarDecl("$state", makeNumber(0, loc), DeclKind.Let, loc);
	stateDecl.nodeType = numberType();
	outerStmts.push(stateDecl);

	// Hoisted locals: let a; let b; let $yf0; let $yf1; ...
	// Set nodeType from original declarations so lambda lifting creates typed env fields.
	for (const localName of nc.items) {
		const origType = findVarType(varTypes, localName);
		const defaultInit = (origType !== null) ? makeDefaultValue(origType, loc) : makeNull(loc);
		const localDecl = makeVarDecl(localName, defaultInit, DeclKind.Let, loc);
		if (origType !== null) {
			localDecl.nodeType = origType;
		}
		outerStmts.push(localDecl);
	}

	// const $stepper = function() { ... };
	// No self-reference needed — msAsyncCb handles re-registration externally.
	const stepperDecl = makeVarDecl("$stepper", stepperFnExpr, DeclKind.Const, loc);
	stepperDecl.nodeType = closureType;
	outerStmts.push(stepperDecl);


	// msAsyncStart($retFut, $stepper) — createCb pattern: C callback drives the stepper
	const kickoffCall = makeCall(
		makeIdent("msAsyncStart", loc),
		[makeTypedIdent("$retFut", retFutType, loc), makeTypedIdent("$stepper", closureType, loc)],
		loc,
	);
	outerStmts.push(makeExprStmt(kickoffCall, loc));

	// return $retFut;
	const returnFut = makeReturn(makeTypedIdent("$retFut", retFutType, loc), loc);
	outerStmts.push(returnFut);

	return makeBlock(outerStmts, loc);
}


// Recursively rewrite all ReturnStmt nodes to msFutureComplete + return $retFut.
// Stops at nested function boundaries (each function has its own return semantics).
function rewriteReturns(node: Node, promiseType: Type | null, fnReturnInner: Type | null): void {
	if (node === null) return;
	match (node.kind) {
		NodeKind.FunctionDecl | NodeKind.FunctionExpr | NodeKind.ArrowFunction => {},
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			const newStmts: Node[] = [];
			for (const stmt of d.statements) {
				if (stmt.kind === NodeKind.ReturnStmt) {
					const rd = stmt.data as ReturnStmtData;
					const loc = stmt.location;
					const isVoid = fnReturnInner === null || fnReturnInner.kind === TypeKind.Void;
					let completeCall: Node = null as unknown as Node;
					if (isVoid || rd.argument === null) {
						completeCall = makeCall(makeIdent("msFutureCompleteVoid", loc),
							[makeTypedIdent("$retFut", promiseType, loc)], loc);
					} else if (boxedInFuture(fnReturnInner)) {
						// Boxed types: msSinkBoxStruct is a multi-statement expansion (nesting it
						// corrupts the result stack), so box via a separate VarDecl.
						const voidPtrType = createPtr(createPrimitive(TypeKind.Void));
						const boxCall = makeCall(makeIdent("msSinkBoxStruct", loc), [rd.argument], loc);
						boxCall.nodeType = voidPtrType;
						const boxDecl = makeVarDecl("$boxed", boxCall, DeclKind.Const, loc);
						boxDecl.nodeType = voidPtrType;
						newStmts.push(boxDecl);
						completeCall = makeCall(makeIdent("msFutureComplete", loc),
							[makeTypedIdent("$retFut", promiseType, loc), makeIdent("$boxed", loc)], loc);
					} else {
						completeCall = makeCall(makeIdent("msFutureCompleteT", loc),
							[makeTypedIdent("$retFut", promiseType, loc), rd.argument], loc);
					}
					newStmts.push(makeExprStmt(completeCall, loc));
					newStmts.push(makeReturn(makeTypedIdent("$retFut", promiseType, loc), loc));
				} else {
					rewriteReturns(stmt, promiseType, fnReturnInner);
					newStmts.push(stmt);
				}
			}
			d.statements = newStmts;
		},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			rewriteReturns(d.consequent, promiseType, fnReturnInner);
			rewriteReturns(d.alternate, promiseType, fnReturnInner);
		},
		NodeKind.WhileStmt => { rewriteReturns((node.data as WhileStmtData).whileBody, promiseType, fnReturnInner); },
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			rewriteReturns(d.tryBody, promiseType, fnReturnInner);
			rewriteReturns(d.catchBody, promiseType, fnReturnInner);
			rewriteReturns(d.finallyBody, promiseType, fnReturnInner);
		},
		_ => {},
	};
}

// Simple wrapper: async function with no await → wrap return value in msFutureComplete
function rewriteSimpleAsyncBody(body: Node, fnReturnInner: Type | null): Node {
	if (body === null) return body;
	if (body.kind !== NodeKind.BlockStmt) return body;

	const bd = body.data as BlockStmtData;
	const loc = body.location;

	const retFutType = promiseTypeFor(fnReturnInner);
	const promiseVoidType = createPromise(voidType());

	// const $retFut = msFutureCreate[Inline]();  (see makeRetFutAlloc)
	const retFutInit = makeRetFutAlloc(fnReturnInner, loc);
	if (!isStructLikeType(fnReturnInner)) retFutInit.nodeType = retFutType;
	const retFutDecl = makeVarDecl("$retFut", retFutInit, DeclKind.Const, loc);
	retFutDecl.nodeType = retFutType;

	// Rewrite all return statements recursively (handles if/else, while, try/catch)
	rewriteReturns(body, retFutType, fnReturnInner);

	// Read bd.statements AFTER rewriteReturns (it mutates the array).
	const rewrittenStmts = bd.statements;
	const tryStmts: Node[] = [];
	for (const stmt of rewrittenStmts) {
		tryStmts.push(stmt);
	}

	// If no explicit return at end, add implicit void completion. No incref on
	// $retFut — DRC's caller-side `ensureDestructionIfNeeded` (inject.ms) emits
	// msFutureDrcDestroy, balancing the rc=0 sole-owner allocation.
	if (rewrittenStmts.length === 0 || rewrittenStmts[rewrittenStmts.length - 1].kind !== NodeKind.ReturnStmt) {
		const completeCall = makeCall(
			makeIdent("msFutureCompleteVoid", loc),
			[makeTypedIdent("$retFut", retFutType, loc)],
			loc,
		);
		tryStmts.push(makeExprStmt(completeCall, loc));
		tryStmts.push(makeReturn(makeTypedIdent("$retFut", retFutType, loc), loc));
	}

	// A throw in the body must FAIL $retFut and return it — otherwise the throw
	// escapes past the `return $retFut`, leaving the caller with an uncompleted /
	// NULL future (→ msWaitForReady crash). Mirrors the with-await stepper catch.
	const failCall = makeExprStmt(
		makeCall(
			makeIdent("msFutureFail", loc),
			[makeTypedIdent("$retFut", retFutType, loc), makeIdent("$e", loc)],
			loc,
		),
		loc,
	);
	const catchBody = makeBlock([failCall, makeReturn(makeTypedIdent("$retFut", retFutType, loc), loc)], loc);
	const tryCatch = makeTryCatch(makeBlock(tryStmts, loc), "$e", catchBody, makeBlock([], loc), loc);

	return makeBlock([retFutDecl, tryCatch], loc);
}

// ===== Walk: Find was-async functions and rewrite =====

function isWasAsync(node: Node): boolean {
	return (node.flags & NodeFlag.WasAsync) !== 0;
}

// Extract Promise<T>'s inner type from a function's declared return type.
function getFnReturnInner(fnNode: Node): Type | null {
	if (fnNode === null || fnNode.nodeType === null) return null;
	const fnType = fnNode.nodeType;
	if (fnType.kind !== TypeKind.Function || fnType.typeReturn === null) return null;
	if (isAwaitable(fnType.typeReturn)) return awaitedType(fnType.typeReturn);
	return null;
}

function rewriteAsyncFnBody(body: Node, fnReturnInner: Type | null): Node {
	if (!hasYieldInBody(body)) {
		return rewriteSimpleAsyncBody(body, fnReturnInner);
	}
	return rewriteAwaitAsyncBody(body, fnReturnInner);
}

// Walk expressions to find async FunctionExpr/ArrowFunction nodes
function walkBridgeExpr(node: Node): void {
	if (node === null) return;
	match (node.kind) {
		NodeKind.FunctionExpr => {
			const d = node.data as FunctionExprData;
			walkBridge(d.funcExprBody);
			if (isWasAsync(node)) { d.funcExprBody = rewriteAsyncFnBody(d.funcExprBody, getFnReturnInner(node)); d.funcExprFlags = ""; }
		},
		NodeKind.ArrowFunction => {
			const d = node.data as ArrowFunctionData;
			walkBridge(d.arrowBody);
			if (isWasAsync(node)) { d.arrowBody = rewriteAsyncFnBody(d.arrowBody, getFnReturnInner(node)); d.arrowFlags = ""; }
		},
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			walkBridgeExpr(d.callee);
			for (const arg of d.arguments) { walkBridgeExpr(arg); }
		},
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			walkBridgeExpr(d.left);
			walkBridgeExpr(d.right);
		},
		_ => {},
	};
}

function walkBridge(node: Node): void {
	if (node === null) return;
	match (node.kind) {
		NodeKind.Program => {
			const d = node.data as ProgramData;
			for (const s of d.programStmts) { walkBridge(s); }
		},
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			for (const s of d.statements) { walkBridge(s); }
		},
		NodeKind.FunctionDecl => {
			const d = node.data as FunctionDeclData;
			walkBridge(d.fnBody);
			if (isWasAsync(node)) { d.fnBody = rewriteAsyncFnBody(d.fnBody, getFnReturnInner(node)); d.fnFlags = ""; }
		},
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			walkBridgeExpr(d.initializer);
		},
		NodeKind.ExprStmt => {
			const d = node.data as ExprStmtData;
			walkBridgeExpr(d.expr);
		},
		NodeKind.ReturnStmt => {
			const d = node.data as ReturnStmtData;
			walkBridgeExpr(d.argument);
		},
		NodeKind.ExportDecl => {
			const d = node.data as ExportDeclData;
			walkBridge(d.exportedDecl);
		},
		NodeKind.ClassDecl => {
			const d = node.data as ClassDeclData;
			for (const member of d.classBody) { walkBridge(member); }
		},
		NodeKind.MethodDecl => {
			const d = node.data as MethodDeclData;
			walkBridge(d.methodBody);
			if (isWasAsync(node)) { d.methodBody = rewriteAsyncFnBody(d.methodBody, getFnReturnInner(node)); d.methodFlags = ""; }
		},
		NodeKind.DecoratedDecl => {
			const d = node.data as DecoratedDeclData;
			walkBridge(d.decoratedNode);
		},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			walkBridge(d.consequent);
			walkBridge(d.alternate);
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			walkBridge(d.whileBody);
		},
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			walkBridge(d.tryBody);
			walkBridge(d.catchBody);
			walkBridge(d.finallyBody);
		},
		_ => {},
	};
}

// ===== Entry Point =====

export function lowerAsyncBridge(program: Node, ctx: TransformContext): Node {
	walkBridge(program);
	return program;
}

// ===== Tests =====

test "non-async passthrough" {
	assert stmtCountAfter("function f() { return 1; }", lowerAsyncBridge) === 1;
}

test "non-generator passthrough" {
	assert stmtCountAfter("const x = 1;", lowerAsyncBridge) === 1;
}

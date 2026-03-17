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
	makeCall, makeBlock, makeNull, makeIf, makeWhile, makeBool, makeNumber,
	makeAssign, makeBinary, makeTryCatch, makeContinue,
	syntheticToken, extractBodyStmts, collectDeclNames,
} from "../util";
import { NameSet, createNameSet, nameSetContains, nameSetAdd } from "../context";
import { createPromise, createFunction, voidType, booleanType, numberType } from "../../checker/types";
import {
	GenState, StateCollector, allocState, containsYield, splitStmts, convertDeclsToAssigns, makeStateAssign,
} from "./generatorLower";
import { stmtCountAfter, firstStmtKindAfter } from "../testUtil";

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
		_ => false,
	};
}

// ===== Await case: inline stepper with state machine =====
// Reuses generatorLower's state-splitting algorithm but emits a stepper function
// instead of an iterator object. The stepper IS the state machine.

// Rewrite return stmts in the body for the state machine:
// return val → msFutureComplete($retFut, val); return;
function rewriteAsyncReturns(stmts: Node[], promiseType: Type, loc: SourceLocation): void {
	for (let i = 0; i < stmts.length; i += 1) {
		const stmt = stmts[i];
		if (stmt === null) continue;
		if (stmt.kind === NodeKind.ReturnStmt) {
			const rd = stmt.data as ReturnStmtData;
			const retVal = rd.argument !== null ? boxReturnValue(rd.argument, loc) : makeNull(loc);
			const block = makeBlock([
				makeStateAssign(-1, loc),
				makeExprStmt(makeCall(
					makeIdent("msFutureComplete", loc),
					[makeTypedIdent("$retFut", promiseType, loc), retVal],
					loc,
				), loc),
				makeReturn(null, loc),
			], loc);
			stmts[i] = block;
		} else if (stmt.kind === NodeKind.BlockStmt) {
			const bd = stmt.data as BlockStmtData;
			rewriteAsyncReturns(bd.statements, promiseType, loc);
		} else if (stmt.kind === NodeKind.IfStmt) {
			const id = stmt.data as IfStmtData;
			if (id.consequent !== null && id.consequent.kind === NodeKind.BlockStmt) {
				rewriteAsyncReturns((id.consequent.data as BlockStmtData).statements, promiseType, loc);
			}
			if (id.alternate !== null && id.alternate.kind === NodeKind.BlockStmt) {
				rewriteAsyncReturns((id.alternate.data as BlockStmtData).statements, promiseType, loc);
			}
		} else if (stmt.kind === NodeKind.WhileStmt) {
			const wd = stmt.data as WhileStmtData;
			if (wd.whileBody !== null && wd.whileBody.kind === NodeKind.BlockStmt) {
				rewriteAsyncReturns((wd.whileBody.data as BlockStmtData).statements, promiseType, loc);
			}
		} else if (stmt.kind === NodeKind.TryCatchStmt) {
			const td = stmt.data as TryCatchStmtData;
			if (td.tryBody !== null && td.tryBody.kind === NodeKind.BlockStmt) {
				rewriteAsyncReturns((td.tryBody.data as BlockStmtData).statements, promiseType, loc);
			}
			if (td.catchBody !== null && td.catchBody.kind === NodeKind.BlockStmt) {
				rewriteAsyncReturns((td.catchBody.data as BlockStmtData).statements, promiseType, loc);
			}
		}
	}
}

// Build the async stepper dispatch: instead of generatorLower's iterator result pattern,
// emit msFutureAddCallback at yield points and msFutureComplete at return points.
function buildAsyncStateDispatch(sc: StateCollector, promiseType: Type, closureType: Type, loc: SourceLocation): Node {
	// Default (terminal) state: return (stepper done)
	let current: Node = makeBlock([makeReturn(null, loc)], loc);

	// Build if-else chain from last state to first
	for (let i = sc.items.length - 1; i >= 0; i -= 1) {
		const state = sc.items[i];
		const stateStmts: Node[] = [];

		if (state.isYield) {
			// This state yields a future. The original stmts end with:
			//   makeStateAssign(nextState) + return makeIterResult(yieldArg, false)
			// We need to replace the last 2 stmts with our stepper pattern.
			// Copy all stmts except the last 2 (state assign + return iterResult)
			let copyEnd = state.stmts.length;
			// Find the return-iterResult at the end — it's the yield point
			// The pattern from splitStmts is: [...stmts, $state=next, return {value, done:false}]
			// We want: [...stmts, $yf_N = yieldArg, $state=next, if(finished) continue else addCallback+return]
			if (copyEnd >= 2) {
				// Copy everything except last 2 (stateAssign + return)
				for (let j = 0; j < copyEnd - 2; j += 1) {
					stateStmts.push(state.stmts[j]);
				}
				// Extract the yield argument from the return stmt
				const returnStmt = state.stmts[copyEnd - 1];
				let yieldArg: Node = makeNull(loc);
				if (returnStmt.kind === NodeKind.ReturnStmt) {
					const rd = returnStmt.data as ReturnStmtData;
					// rd.argument is makeIterResult(yieldArg, false) = ObjectLiteral {value: yieldArg, done: false}
					if (rd.argument !== null && rd.argument.kind === NodeKind.ObjectLiteral) {
						const od = rd.argument.data as { properties: Node[], keys: string[] };
						if (od.properties.length > 0) {
							yieldArg = od.properties[0]; // first property = value = the yielded expr
						}
					}
				}

				// Save yielded future to a hoisted local
				const futName = "$yf" + i;
				const futAssign = makeExprStmt(
					makeAssign(makeTypedIdent(futName, promiseType, loc), yieldArg, loc),
					loc,
				);
				stateStmts.push(futAssign);

				// Set next state (reuse the state assign from splitStmts)
				stateStmts.push(state.stmts[copyEnd - 2]); // $state = nextState

				// Pre-resolved check: if (msFutureFinished($yf_N)) continue;
				const finishedCheck = makeCall(makeIdent("msFutureFinished", loc), [makeTypedIdent(futName, promiseType, loc)], loc);
				finishedCheck.nodeType = booleanType();
				const continueStmt = makeContinue(loc);
				const preResolvedIf = makeIf(finishedCheck, makeBlock([continueStmt], loc), makeBlock([], loc), loc);
				stateStmts.push(preResolvedIf);

				// Not resolved: register callback and suspend
				const addCbCall = makeExprStmt(
					makeCall(
						makeIdent("msFutureAddCallback", loc),
						[makeTypedIdent(futName, promiseType, loc), makeTypedIdent("$stepper", closureType, loc)],
						loc,
					),
					loc,
				);
				stateStmts.push(addCbCall);
				stateStmts.push(makeReturn(null, loc)); // suspend (void return)
			} else {
				// Unexpected — just copy all stmts
				for (const s of state.stmts) { stateStmts.push(s); }
			}
		} else {
			// Non-yield state: copy stmts directly
			for (const s of state.stmts) { stateStmts.push(s); }
		}

		const cond = makeBinary(
			makeIdent("$state", loc), "===",
			makeNumber(state.index, loc), loc,
		);
		const body = makeBlock(stateStmts, loc);
		current = makeIf(cond, body, current, loc);
	}
	return current;
}

function rewriteAwaitAsyncBody(body: Node): Node {
	if (body === null) return body;
	if (body.kind !== NodeKind.BlockStmt) return body;

	const loc = body.location;
	const promiseVoidType = createPromise(voidType());
	const closureType = createFunction([], [], voidType());

	// 1. Extract body statements
	const bodyStmts = extractBodyStmts(body);

	// 2. Collect local variable names for hoisting
	const nc: NameSet = createNameSet();
	collectDeclNames(body, nc, false);

	// 3. Rewrite returns: return val → msFutureComplete($retFut, val); return;
	rewriteAsyncReturns(bodyStmts, promiseVoidType, loc);

	// 4. Split at yield points (reuse generatorLower's algorithm)
	const sc: StateCollector = { items: [] };
	const initState = allocState(sc);
	const doneState = -1;
	splitStmts(bodyStmts, sc, initState, doneState, loc);

	// 5. Convert variable declarations to assignments in all state bodies
	// Also add yielded-future locals ($yf0, $yf1, ...) to the hoisted set
	for (let si = 0; si < sc.items.length; si += 1) {
		convertDeclsToAssigns(sc.items[si].stmts, nc, loc);
		if (sc.items[si].isYield) {
			nameSetAdd(nc, "$yf" + si);
		}
	}

	// 6. Build async state dispatch (stepper pattern instead of iterator pattern)
	const dispatch = buildAsyncStateDispatch(sc, promiseVoidType, closureType, loc);

	// 7. Wrap in while(true) + try/catch
	const loop = makeWhile(makeBool(true, loc), dispatch, loc);
	const tryBody = makeBlock([loop], loc);
	const failCall = makeExprStmt(
		makeCall(
			makeIdent("msFutureFail", loc),
			[makeTypedIdent("$retFut", promiseVoidType, loc), makeIdent("$e", loc)],
			loc,
		),
		loc,
	);
	const catchBody = makeBlock([failCall], loc);
	const tryCatch = makeTryCatch(tryBody, "$e", catchBody, makeBlock([], loc), loc);

	// 8. Build stepper as FunctionExpr
	const stepperBody = makeBlock([tryCatch], loc);
	const stepperFnExpr = createNode(NodeKind.FunctionExpr, {
		funcExprParams: [],
		funcExprParamTypes: [],
		funcExprBody: stepperBody,
		funcExprFlags: "",
		funcExprReturnType: "",
	}, syntheticToken(loc));
	stepperFnExpr.nodeType = closureType;

	// 9. Build outer function body
	const outerStmts: Node[] = [];

	// const $retFut = msFutureCreate();
	const retFutInit = makeCall(makeIdent("msFutureCreate", loc), [], loc);
	retFutInit.nodeType = promiseVoidType;
	const retFutDecl = makeVarDecl("$retFut", retFutInit, DeclKind.Const, loc);
	retFutDecl.nodeType = promiseVoidType;
	outerStmts.push(retFutDecl);

	// let $state = 0;
	const stateDecl = makeVarDecl("$state", makeNumber(0, loc), DeclKind.Let, loc);
	stateDecl.nodeType = numberType();
	outerStmts.push(stateDecl);

	// Hoisted locals: let a; let b; let $yf0; let $yf1; ...
	for (const localName of nc.items) {
		const localDecl = makeVarDecl(localName, makeNull(loc), DeclKind.Let, loc);
		outerStmts.push(localDecl);
	}

	// let $stepper; (declared before assignment so lambdaLifting captures it)
	const stepperDecl = makeVarDecl("$stepper", makeNull(loc), DeclKind.Let, loc);
	stepperDecl.nodeType = closureType;
	outerStmts.push(stepperDecl);

	// $stepper = function() { ... }; (assign after decl)
	const stepperAssign = makeExprStmt(
		makeAssign(makeTypedIdent("$stepper", closureType, loc), stepperFnExpr, loc),
		loc,
	);
	outerStmts.push(stepperAssign);

	// $stepper(); — closure call (isDirectCall=false for closure dispatch)
	const kickoffCall = makeCall(makeTypedIdent("$stepper", closureType, loc), [], loc);
	const kickoffData = kickoffCall.data as CallExprData;
	kickoffData.isDirectCall = false;
	const kickoff = makeExprStmt(kickoffCall, loc);
	outerStmts.push(kickoff);

	// return $retFut;
	const returnFut = makeReturn(makeTypedIdent("$retFut", promiseVoidType, loc), loc);
	outerStmts.push(returnFut);

	return makeBlock(outerStmts, loc);
}

// Box a return value for msFutureComplete(fut, void*). Non-void non-pointer values
// need boxing via msBoxDouble/msBoxBool. Void returns pass NULL.
function boxReturnValue(retVal: Node, loc: SourceLocation): Node {
	if (retVal === null) return makeNull(loc);
	if (retVal.nodeType === null) return retVal;
	return match (retVal.nodeType.kind) {
		TypeKind.Number | TypeKind.Float64 | TypeKind.Float32 => makeCall(makeIdent("msBoxDouble", loc), [retVal], loc),
		TypeKind.Boolean => makeCall(makeIdent("msBoxBool", loc), [retVal], loc),
		TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 | TypeKind.Int64 => makeCall(makeIdent("msBoxInt32", loc), [retVal], loc),
		_ => retVal,
	};
}

// Recursively rewrite all ReturnStmt nodes to msFutureComplete + return $retFut.
// Stops at nested function boundaries (each function has its own return semantics).
function rewriteReturns(node: Node, promiseType: Type): void {
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
					const retVal = rd.argument !== null ? boxReturnValue(rd.argument, loc) : makeNull(loc);
					const completeCall = makeCall(
						makeIdent("msFutureComplete", loc),
						[makeTypedIdent("$retFut", promiseType, loc), retVal],
						loc,
					);
					newStmts.push(makeExprStmt(completeCall, loc));
					newStmts.push(makeReturn(makeTypedIdent("$retFut", promiseType, loc), loc));
				} else {
					rewriteReturns(stmt, promiseType);
					newStmts.push(stmt);
				}
			}
			d.statements = newStmts;
		},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			rewriteReturns(d.consequent, promiseType);
			rewriteReturns(d.alternate, promiseType);
		},
		NodeKind.WhileStmt => { rewriteReturns((node.data as WhileStmtData).whileBody, promiseType); },
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			rewriteReturns(d.tryBody, promiseType);
			rewriteReturns(d.catchBody, promiseType);
			rewriteReturns(d.finallyBody, promiseType);
		},
		_ => {},
	};
}

// Simple wrapper: async function with no await → wrap return value in msFutureComplete
function rewriteSimpleAsyncBody(body: Node): Node {
	if (body === null) return body;
	if (body.kind !== NodeKind.BlockStmt) return body;

	const bd = body.data as BlockStmtData;
	const loc = body.location;

	const promiseVoidType = createPromise(voidType());

	// const $retFut = msFutureCreate();
	const retFutInit = makeCall(makeIdent("msFutureCreate", loc), [], loc);
	retFutInit.nodeType = promiseVoidType;
	const retFutDecl = makeVarDecl("$retFut", retFutInit, DeclKind.Const, loc);
	retFutDecl.nodeType = promiseVoidType;

	// Rewrite all return statements recursively (handles if/else, while, try/catch)
	rewriteReturns(body, promiseVoidType);

	// Prepend $retFut declaration. Read bd.statements AFTER rewriteReturns (it mutates the array).
	const rewrittenStmts = bd.statements;
	const newStmts: Node[] = [];
	newStmts.push(retFutDecl);
	for (const stmt of rewrittenStmts) {
		newStmts.push(stmt);
	}

	// If no explicit return at end, add msFutureComplete + return
	if (rewrittenStmts.length === 0 || rewrittenStmts[rewrittenStmts.length - 1].kind !== NodeKind.ReturnStmt) {
		const completeCall = makeCall(
			makeIdent("msFutureComplete", loc),
			[makeTypedIdent("$retFut", promiseVoidType, loc), makeNull(loc)],
			loc,
		);
		newStmts.push(makeExprStmt(completeCall, loc));
		newStmts.push(makeReturn(makeTypedIdent("$retFut", promiseVoidType, loc), loc));
	}

	return makeBlock(newStmts, loc);
}

// ===== Walk: Find was-async functions and rewrite =====

function isWasAsync(node: Node): boolean {
	return (node.flags & NodeFlag.WasAsync) !== 0;
}

function rewriteAsyncFnBody(body: Node): Node {
	if (!hasYieldInBody(body)) {
		return rewriteSimpleAsyncBody(body);
	}
	return rewriteAwaitAsyncBody(body);
}

// Walk expressions to find async FunctionExpr/ArrowFunction nodes
function walkBridgeExpr(node: Node): void {
	if (node === null) return;
	match (node.kind) {
		NodeKind.FunctionExpr => {
			const d = node.data as FunctionExprData;
			walkBridge(d.funcExprBody);
			if (isWasAsync(node)) { d.funcExprBody = rewriteAsyncFnBody(d.funcExprBody); d.funcExprFlags = ""; }
		},
		NodeKind.ArrowFunction => {
			const d = node.data as ArrowFunctionData;
			walkBridge(d.arrowBody);
			if (isWasAsync(node)) { d.arrowBody = rewriteAsyncFnBody(d.arrowBody); d.arrowFlags = ""; }
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
			if (isWasAsync(node)) { d.fnBody = rewriteAsyncFnBody(d.fnBody); d.fnFlags = ""; }
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
			if (isWasAsync(node)) { d.methodBody = rewriteAsyncFnBody(d.methodBody); d.methodFlags = ""; }
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

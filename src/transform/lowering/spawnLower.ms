// Spawn Lowering — box return values in spawn closures
//
// Runs BEFORE lambda lifting so closure bodies are still accessible.
// Walks AST for spawn(fn) calls where fn returns a primitive type.
// Wraps return values in msBoxDouble/msBoxBool/msBoxInt32 so the
// C runtime can store them as void* in msFuture.value.

import { Node, NodeKind, NodeFlag, SourceLocation, CallExprData, ArrowFunctionData, FunctionExprData, BlockStmtData, ReturnStmtData, IfStmtData, WhileStmtData, ForOfStmtData, TryCatchStmtData, SwitchStmtData, SwitchCaseData, ObjectLiteralData, Type, TypeKind, SymbolKind, DeclKind, createNode } from "../../ast/node";
import { createFunction, createPtr, voidType, isAwaitable, awaitedType, literalBase, skipModifier, unwrapRefNullUnion, isAtomicRef } from "../../checker/types";
import { GcMode } from "../../checker/context";
import { TransformContext, freshOwnedSym } from "../context";
import { walkNode } from "../walker";
import { canFormAcycle } from "../cycles";
import { lowerDefer } from "./deferLower";
import { makeCall, makeNull, makeObjectLiteral, syntheticToken, runtimeRef, isRuntimeProcSym, boxedInFuture, makeBlock, makeExprStmt, makeIdentResolved, makeReturn, makeVarDecl } from "../util";

function needsBoxing(t: Type): boolean {
	if (t == null) return false;
	return match (literalBase(t).kind) {
		TypeKind.Number | TypeKind.Float64 | TypeKind.Float32 => true,
		TypeKind.Boolean => true,
		TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 | TypeKind.Int64
			| TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 | TypeKind.Uint64 => true,
		TypeKind.String => true,
		_ => boxedInFuture(t),
	};
}

// Build the boxing call for a given type (doesn't rely on retVal.nodeType)
export function boxForType(retVal: Node, retType: Type, loc: SourceLocation): Node {
	if (retVal == null || retType == null) return retVal;
	return match (literalBase(retType).kind) {
		TypeKind.Number | TypeKind.Float64 | TypeKind.Float32 => makeCall(runtimeRef("msBoxDouble", loc), [retVal], loc),
		TypeKind.Boolean => makeCall(runtimeRef("msBoxBool", loc), [retVal], loc),
		TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32
			| TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 => makeCall(runtimeRef("msBoxInt32", loc), [retVal], loc),
		TypeKind.Int64 | TypeKind.Uint64 => makeCall(runtimeRef("msBoxInt64", loc), [retVal], loc),
		TypeKind.String => {
			// Same sink contract as the struct case. msBoxString increfs the msString
			// payload, but strings are value types — the payload has NO refcount header
			// (msStrContentSize = cap + data only), so the incref writes into the heap
			// slot BEFORE the payload and corrupts it. msSinkBoxStruct memcpys the
			// 16-byte struct into the shell and memsets the source: payload ownership
			// transfers to the box, the source's scope-exit destroy becomes a no-op,
			// and readers (msUnboxString copy-out / worker inline memcpy) are unchanged.
			return boxValue(retVal, retType, loc);
		},
		_ => boxedInFuture(retType) ? boxValue(retVal, retType, loc) : retVal,
	};
}

// msSinkBoxStruct: codegen expands to malloc+memcpy+wasMoved (DRC-aware)
function boxValue(retVal: Node, retType: Type, loc: SourceLocation): Node {
	const call = makeCall(runtimeRef("msSinkBoxStruct", loc), [retVal], loc);
	call.nodeType = retType;
	return call;
}

// Recursively wrap ReturnStmt values in boxing calls.
// Stops at nested function boundaries. Covers all control flow.
export function boxReturns(node: Node, retType: Type): void {
	if (node == null) return;
	if (node.kind == NodeKind.FunctionDecl || node.kind == NodeKind.FunctionExpr || node.kind == NodeKind.ArrowFunction) return;
	match (node.kind) {
		NodeKind.ReturnStmt => {
			const d = node.data as ReturnStmtData;
			if (d.argument != null) {
				d.argument = boxForType(d.argument, retType, node.location);
			}
		},
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			for (const stmt of d.statements) { boxReturns(stmt, retType); }
		},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			boxReturns(d.consequent, retType);
			boxReturns(d.alternate, retType);
		},
		NodeKind.WhileStmt => { boxReturns((node.data as WhileStmtData).whileBody, retType); },
		NodeKind.ForOfStmt => { boxReturns((node.data as ForOfStmtData).forOfBody, retType); },
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			boxReturns(d.tryBody, retType);
			boxReturns(d.catchBody, retType);
			boxReturns(d.finallyBody, retType);
		},
		NodeKind.SwitchStmt => {
			const d = node.data as SwitchStmtData;
			for (const caseNode of d.switchCases) {
				const sc = caseNode.data as SwitchCaseData;
				for (const stmt of sc.caseStmts) { boxReturns(stmt, retType); }
			}
		},
		_ => {},
	};
}

export function spawnThunk(closure: Node): Node {
	if (closure.kind != NodeKind.CallExpr) return closure;
	const iife = (closure.data as CallExprData).callee;
	if (iife.kind != NodeKind.ArrowFunction) return closure;
	const inner = (iife.data as ArrowFunctionData).arrowBody;
	return inner != null && (inner.kind == NodeKind.ArrowFunction || inner.kind == NodeKind.FunctionExpr) ? inner : closure;
}

export function mayHoldCycleRoot(t: Type | null, ctx: TransformContext): boolean {
	if (ctx.checkerCtx == null || ctx.checkerCtx.gcMode != GcMode.Drc) return false;
	const bare = skipModifier(t);
	if (bare == null) return false;
	const ref = bare.kind == TypeKind.Ref ? bare : unwrapRefNullUnion(bare);
	if (ref == null || ref.kind != TypeKind.Ref || isAtomicRef(ref)) return false;
	if (ref.sym != null && ref.sym.symbolKind == SymbolKind.Actor) return false;
	return canFormAcycle(ref, ctx.cyclicCache, ctx.acyclicCache);
}

export function disownStmt(value: Node, loc: SourceLocation): Node {
	return makeExprStmt(makeCall(runtimeRef("msOrcDisown", loc), [value], loc), loc);
}

function prependStmts(fn: Node, stmts: Node[], loc: SourceLocation): void {
	if (fn.kind == NodeKind.FunctionExpr) {
		const bd = (fn.data as FunctionExprData).funcExprBody.data as BlockStmtData;
		bd.statements = stmts.concat(bd.statements);
		return;
	}
	const ad = fn.data as ArrowFunctionData;
	if (ad.arrowBody.kind == NodeKind.BlockStmt) {
		const bd = ad.arrowBody.data as BlockStmtData;
		bd.statements = stmts.concat(bd.statements);
	} else {
		ad.arrowBody = makeBlock(stmts.concat([makeReturn(ad.arrowBody, loc)]), loc);
	}
}

// ULTRALOCK V3: a moved capture leaves the sender's cycle roots before the task is submitted,
// and the worker's when the task settles, since its env is released on the sender's loop.
export function disownMovedCaptures(closure: Node, ctx: TransformContext): void {
	if (closure.kind != NodeKind.CallExpr) return;
	const cd = closure.data as CallExprData;
	const iife = cd.callee;
	if (iife.kind != NodeKind.ArrowFunction || iife.paramSyms == null) return;
	const params = iife.paramSyms!;
	const loc = iife.location;
	const atSubmit: Node[] = [];
	const atSettle: Node[] = [];
	for (let i = 0; i < params.length && i < cd.arguments.length; i += 1) {
		if (cd.arguments[i].kind == NodeKind.MoveExpr && mayHoldCycleRoot(params[i].symbolType, ctx)) {
			atSubmit.push(disownStmt(makeIdentResolved(params[i], loc), loc));
			atSettle.push(disownStmt(makeIdentResolved(params[i], loc), loc));
		}
	}
	if (atSubmit.length == 0) return;
	const thunk = spawnThunk(closure);
	if (thunk != closure) {
		prependStmts(thunk, [createNode(NodeKind.DeferStmt, { deferExpr: makeBlock(atSettle, loc) }, syntheticToken(loc))], loc);
		lowerDefer(thunk, ctx);
	}
	prependStmts(iife, atSubmit, loc);
}

function disownedReturn(arg: Node, retType: Type, ctx: TransformContext, loc: SourceLocation): Node {
	const tmp = freshOwnedSym(ctx, "result", retType);
	const decl = makeVarDecl(tmp.name, arg, DeclKind.Const, loc);
	decl.resolvedSym = tmp;
	decl.nodeType = retType;
	return makeBlock([decl, disownStmt(makeIdentResolved(tmp, loc), loc), makeReturn(makeIdentResolved(tmp, loc), loc)], loc);
}

function disownReturnsIn(node: Node | null, retType: Type, ctx: TransformContext): Node | null {
	if (node == null) return node;
	if (node.kind == NodeKind.ReturnStmt) {
		const arg = (node.data as ReturnStmtData).argument;
		return arg != null ? disownedReturn(arg, retType, ctx, node.location) : node;
	}
	if (node.kind == NodeKind.BlockStmt) {
		const d = node.data as BlockStmtData;
		d.statements = d.statements.map((s: Node): Node => disownReturnsIn(s, retType, ctx)!);
	} else if (node.kind == NodeKind.IfStmt) {
		const d = node.data as IfStmtData;
		d.consequent = disownReturnsIn(d.consequent, retType, ctx)!;
		d.alternate = disownReturnsIn(d.alternate, retType, ctx) as Node;
	} else if (node.kind == NodeKind.WhileStmt) {
		const d = node.data as WhileStmtData;
		d.whileBody = disownReturnsIn(d.whileBody, retType, ctx)!;
	} else if (node.kind == NodeKind.ForOfStmt) {
		const d = node.data as ForOfStmtData;
		d.forOfBody = disownReturnsIn(d.forOfBody, retType, ctx)!;
	} else if (node.kind == NodeKind.TryCatchStmt) {
		const d = node.data as TryCatchStmtData;
		d.tryBody = disownReturnsIn(d.tryBody, retType, ctx)!;
		d.catchBody = disownReturnsIn(d.catchBody, retType, ctx) as Node;
		d.finallyBody = disownReturnsIn(d.finallyBody, retType, ctx) as Node;
	} else if (node.kind == NodeKind.SwitchStmt) {
		for (const caseNode of (node.data as SwitchStmtData).switchCases) {
			const sc = caseNode.data as SwitchCaseData;
			sc.caseStmts = sc.caseStmts.map((s: Node): Node => disownReturnsIn(s, retType, ctx)!);
		}
	}
	return node;
}

// ULTRALOCK V3: a task result moved back to the awaiter leaves the worker's cycle roots before it is stored.
export function disownResult(thunk: Node, retType: Type | null, ctx: TransformContext): void {
	if (retType == null || !mayHoldCycleRoot(retType, ctx)) return;
	if (thunk.kind == NodeKind.ArrowFunction) {
		const ad = thunk.data as ArrowFunctionData;
		if (ad.arrowBody == null) return;
		if (ad.arrowBody.kind == NodeKind.BlockStmt) disownReturnsIn(ad.arrowBody, retType, ctx);
		else ad.arrowBody = disownedReturn(ad.arrowBody, retType, ctx, ad.arrowBody.location);
	} else if (thunk.kind == NodeKind.FunctionExpr) {
		disownReturnsIn((thunk.data as FunctionExprData).funcExprBody, retType, ctx);
	}
}

export function lowerSpawn(program: Node, ctx: TransformContext): Node {
	return walkNode(program, (node: Node): Node => {
		if (node.kind != NodeKind.CallExpr) return node;
		const cd = node.data as CallExprData;
		const sym = node.resolvedSym != null ? node.resolvedSym : cd.callee.resolvedSym;
		const isSpawn = sym != null && (sym.builtinKind == "PromiseSpawn" || isRuntimeProcSym(sym, "msSpawn"));
		if (!isSpawn || cd.arguments.length < 1) return node;

		let closureArg = cd.arguments[0];

		// Bare function reference (Identifier): wrap as msClosure {fn, env=null}
		// so codegen emits the struct literal expected by msSpawn/msSpawnTaskSubmit.
		if (closureArg.kind == NodeKind.Identifier) {
			const loc = closureArg.location;
			const pair = makeObjectLiteral(["fn", "env"], [closureArg, makeNull(loc)], loc);
			pair.flags = pair.flags.incl(NodeFlag.Closure);
			pair.nodeType = closureArg.nodeType;
			cd.arguments[0] = pair;
			closureArg = pair;
		}
		// Get return type from Promise<T> on the CallExpr (set by checker's Spawn inference)
		const boxTarget = spawnThunk(closureArg);
		let closureRetType: Type | null = null;
		if (node.nodeType != null && isAwaitable(node.nodeType)) {
			closureRetType = awaitedType(node.nodeType);
		} else if (closureArg.nodeType != null && closureArg.nodeType.kind == TypeKind.Function) {
			closureRetType = closureArg.nodeType.typeReturn;
		}

		if (closureRetType != null && needsBoxing(closureRetType)) {
			// Bare function reference (already wrapped as ObjectLiteral closure pair):
			// can't modify the function body. Wrap in an adapter arrow: () => box(fn())
			if (closureArg.kind == NodeKind.ObjectLiteral && closureArg.flags.has(NodeFlag.Closure)) {
				const loc = closureArg.location;
				const fnIdent = (closureArg.data as ObjectLiteralData).properties[0];
				const innerCall = makeCall(fnIdent, [], loc);
				innerCall.nodeType = closureRetType;
				const boxed = boxForType(innerCall, closureRetType, loc);
				const wrapper = createNode(NodeKind.ArrowFunction, {
					arrowParams: [] as string[],
					arrowParamTypes: [] as string[],
					arrowBody: boxed,
					arrowFlags: "",
					arrowReturnType: "",
					arrowDefaults: [] as Node[],
				}, syntheticToken(loc));
				wrapper.nodeType = createFunction([], [], createPtr(voidType()));
				wrapper.paramSyms = [];
				cd.arguments[0] = wrapper;
				return node;
			}
			// Box return values inside the closure body
			if (boxTarget.kind == NodeKind.ArrowFunction) {
				const ad = boxTarget.data as ArrowFunctionData;
				if (ad.arrowBody != null) {
					if (ad.arrowBody.kind == NodeKind.BlockStmt) {
						boxReturns(ad.arrowBody, closureRetType);
					} else {
						ad.arrowBody = boxForType(ad.arrowBody, closureRetType, ad.arrowBody.location);
					}
				}
			} else if (boxTarget.kind == NodeKind.FunctionExpr) {
				const fd = boxTarget.data as FunctionExprData;
				if (fd.funcExprBody != null) {
					boxReturns(fd.funcExprBody, closureRetType);
				}
			}
			// Update closure return type to void* (boxed) so codegen emits correct signature
			if (boxTarget != closureArg && boxTarget.nodeType != null && boxTarget.nodeType.kind == TypeKind.Function) {
				boxTarget.nodeType.typeReturn = createPtr(voidType());
			}
			if (closureArg.nodeType != null && closureArg.nodeType.kind == TypeKind.Function) {
				closureArg.nodeType.typeReturn = createPtr(voidType());
			}
		}
		disownResult(boxTarget, closureRetType, ctx);
		disownMovedCaptures(closureArg, ctx);

		return node;
	});
}

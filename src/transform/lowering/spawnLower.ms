// Spawn Lowering — box return values in spawn closures
//
// Runs BEFORE lambda lifting so closure bodies are still accessible.
// Walks AST for spawn(fn) calls where fn returns a primitive type.
// Wraps return values in msBoxDouble/msBoxBool/msBoxInt32 so the
// C runtime can store them as void* in msFuture.value.

import { Node, NodeKind, NodeFlag, SourceLocation, CallExprData, ArrowFunctionData, FunctionExprData, BlockStmtData, ReturnStmtData, IfStmtData, WhileStmtData, ForOfStmtData, TryCatchStmtData, SwitchStmtData, SwitchCaseData, ObjectLiteralData, Type, TypeKind, createNode } from "../../ast/node";
import { createPtr, voidType, isAwaitable, awaitedType } from "../../checker/types";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeIdent, makeCall, makeNull, makeObjectLiteral, syntheticToken } from "../util";

function needsBoxing(t: Type): boolean {
	if (t === null) return false;
	return match (t.kind) {
		TypeKind.Number | TypeKind.Float64 | TypeKind.Float32 => true,
		TypeKind.Boolean => true,
		TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 | TypeKind.Int64
			| TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 | TypeKind.Uint64 => true,
		TypeKind.String => true,
		TypeKind.Struct | TypeKind.GenericInstance | TypeKind.Tuple => true,
		TypeKind.Array => true,
		_ => false,
	};
}

// Build the boxing call for a given type (doesn't rely on retVal.nodeType)
export function boxForType(retVal: Node, retType: Type, loc: SourceLocation): Node {
	if (retVal === null || retType === null) return retVal;
	return match (retType.kind) {
		TypeKind.Number | TypeKind.Float64 | TypeKind.Float32 => makeCall(makeIdent("msBoxDouble", loc), [retVal], loc),
		TypeKind.Boolean => makeCall(makeIdent("msBoxBool", loc), [retVal], loc),
		TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 | TypeKind.Int64
			| TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 | TypeKind.Uint64 => makeCall(makeIdent("msBoxInt32", loc), [retVal], loc),
		TypeKind.String => {
			// Same sink contract as the struct case. msBoxString increfs the msString
			// payload, but strings are value types — the payload has NO refcount header
			// (msStrContentSize = cap + data only), so the incref writes into the heap
			// slot BEFORE the payload and corrupts it. msSinkBoxStruct memcpys the
			// 16-byte struct into the shell and memsets the source: payload ownership
			// transfers to the box, the source's scope-exit destroy becomes a no-op,
			// and readers (msUnboxString copy-out / worker inline memcpy) are unchanged.
			const call = makeCall(makeIdent("msSinkBoxStruct", loc), [retVal], loc);
			call.nodeType = retType;
			return call;
		},
		TypeKind.Struct | TypeKind.GenericInstance | TypeKind.Tuple | TypeKind.Array => {
			// msSinkBoxStruct: codegen expands to malloc+memcpy+wasMoved (DRC-aware)
			const call = makeCall(makeIdent("msSinkBoxStruct", loc), [retVal], loc);
			call.nodeType = retType;
			return call;
		},
		_ => retVal,
	};
}

// Recursively wrap ReturnStmt values in boxing calls.
// Stops at nested function boundaries. Covers all control flow.
export function boxReturns(node: Node, retType: Type): void {
	if (node === null) return;
	if (node.kind === NodeKind.FunctionDecl || node.kind === NodeKind.FunctionExpr || node.kind === NodeKind.ArrowFunction) return;
	match (node.kind) {
		NodeKind.ReturnStmt => {
			const d = node.data as ReturnStmtData;
			if (d.argument !== null) {
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

export function lowerSpawn(program: Node, ctx: TransformContext): Node {
	return walkNode(program, (node: Node): Node => {
		if (node.kind !== NodeKind.CallExpr) return node;
		const cd = node.data as CallExprData;
		// Check for spawn builtin (builtinKind or nativeName)
		let isSpawn = false;
		const sym = node.resolvedSym !== null ? node.resolvedSym : cd.callee.resolvedSym;
		if (sym !== null) {
			if (sym.builtinKind === "PromiseSpawn" || sym.nativeName === "msSpawn") {
				isSpawn = true;
			}
		}
		if (!isSpawn || cd.arguments.length < 1) return node;

		let closureArg = cd.arguments[0];

		// Bare function reference (Identifier): wrap as msClosure {fn, env=null}
		// so codegen emits the struct literal expected by msSpawn/msSpawnTaskSubmit.
		if (closureArg.kind === NodeKind.Identifier) {
			const loc = closureArg.location;
			const pair = makeObjectLiteral(["fn", "env"], [closureArg, makeNull(loc)], loc);
			pair.flags = pair.flags | NodeFlag.Closure;
			pair.nodeType = closureArg.nodeType;
			cd.arguments[0] = pair;
			closureArg = pair;
		}
		// Get return type from Promise<T> on the CallExpr (set by checker's Spawn inference)
		let closureRetType: Type | null = null;
		if (node.nodeType !== null && isAwaitable(node.nodeType)) {
			closureRetType = awaitedType(node.nodeType);
		} else if (closureArg.nodeType !== null && closureArg.nodeType.kind === TypeKind.Function) {
			closureRetType = closureArg.nodeType.typeReturn;
		}

		if (closureRetType !== null && needsBoxing(closureRetType)) {
			// Bare function reference (already wrapped as ObjectLiteral closure pair):
			// can't modify the function body. Wrap in an adapter arrow: () => box(fn())
			if (closureArg.kind === NodeKind.ObjectLiteral && (closureArg.flags & NodeFlag.Closure) !== 0) {
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
				}, syntheticToken(loc));
				wrapper.nodeType = closureArg.nodeType;
				if (wrapper.nodeType !== null && wrapper.nodeType.kind === TypeKind.Function) {
					wrapper.nodeType.typeReturn = createPtr(voidType());
				}
				cd.arguments[0] = wrapper;
				return node;
			}
			// Box return values inside the closure body
			if (closureArg.kind === NodeKind.ArrowFunction) {
				const ad = closureArg.data as ArrowFunctionData;
				if (ad.arrowBody !== null) {
					if (ad.arrowBody.kind === NodeKind.BlockStmt) {
						boxReturns(ad.arrowBody, closureRetType);
					} else {
						ad.arrowBody = boxForType(ad.arrowBody, closureRetType, ad.arrowBody.location);
					}
				}
			} else if (closureArg.kind === NodeKind.FunctionExpr) {
				const fd = closureArg.data as FunctionExprData;
				if (fd.funcExprBody !== null) {
					boxReturns(fd.funcExprBody, closureRetType);
				}
			}
			// Update closure return type to void* (boxed) so codegen emits correct signature
			if (closureArg.nodeType !== null && closureArg.nodeType.kind === TypeKind.Function) {
				closureArg.nodeType.typeReturn = createPtr(voidType());
			}
		}

		return node;
	});
}

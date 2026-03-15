// Spawn Lowering — box return values in spawn closures
//
// Runs BEFORE lambda lifting so closure bodies are still accessible.
// Walks AST for spawn(fn) calls where fn returns a primitive type.
// Wraps return values in msBoxDouble/msBoxBool/msBoxInt32 so the
// C runtime can store them as void* in msFuture.value.

import {
	Node, NodeKind, NodeFlag, SourceLocation,
	CallExprData, ArrowFunctionData, FunctionExprData,
	BlockStmtData, ReturnStmtData, IfStmtData,
	WhileStmtData, ForOfStmtData, TryCatchStmtData,
	SwitchStmtData, SwitchCaseData,
} from "../../ast/node";
import { Type, TypeKind, unknownType, isPromise, getPromiseInner } from "../../checker/types";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeIdent, makeCall } from "../util";

function needsBoxing(t: Type): boolean {
	if (t === null) return false;
	return match (t.kind) {
		TypeKind.Number | TypeKind.Float64 | TypeKind.Float32 => true,
		TypeKind.Boolean => true,
		TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 | TypeKind.Int64 => true,
		TypeKind.String => true,
		TypeKind.Struct | TypeKind.Result | TypeKind.Tuple => true,
		_ => false,
	};
}

// Build the boxing call for a given type (doesn't rely on retVal.nodeType)
function boxForType(retVal: Node, retType: Type, loc: SourceLocation): Node {
	if (retVal === null || retType === null) return retVal;
	return match (retType.kind) {
		TypeKind.Number | TypeKind.Float64 | TypeKind.Float32 => makeCall(makeIdent("msBoxDouble", loc), [retVal], loc),
		TypeKind.Boolean => makeCall(makeIdent("msBoxBool", loc), [retVal], loc),
		TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 | TypeKind.Int64 => makeCall(makeIdent("msBoxInt32", loc), [retVal], loc),
		TypeKind.String => makeCall(makeIdent("msBoxString", loc), [retVal], loc),
		TypeKind.Struct | TypeKind.Result | TypeKind.Tuple => {
			// msBoxStruct: codegen expands to msBoxStruct(&val, sizeof(TypeName))
			const call = makeCall(makeIdent("msBoxStruct", loc), [retVal], loc);
			call.nodeType = retType;
			return call;
		},
		_ => retVal,
	};
}

// Recursively wrap ReturnStmt values in boxing calls.
// Stops at nested function boundaries. Covers all control flow.
function boxReturns(node: Node, retType: Type): void {
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

		const closureArg = cd.arguments[0];
		// Get return type from Promise<T> on the CallExpr (set by checker's Spawn inference)
		let closureRetType: Type = null;
		if (node.nodeType !== null && isPromise(node.nodeType)) {
			closureRetType = getPromiseInner(node.nodeType);
		} else if (closureArg.nodeType !== null && closureArg.nodeType.kind === TypeKind.Function) {
			closureRetType = closureArg.nodeType.typeReturn;
		}

		if (closureRetType !== null && needsBoxing(closureRetType)) {
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
				closureArg.nodeType.typeReturn = unknownType();
			}
		}

		return node;
	});
}

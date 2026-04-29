// Span Parameter Expansion — openArray calling convention for C backend
//
// Expands Span<T> parameters into two C-level parameters: (T* name_data, int64_t name_len).
// This keeps the C codegen "dumb" — it sees normal scalar params, not Span structs.
//
// Pattern: standard reference expansion pattern for view/span parameters.
//
// Two passes:
//   Pass 1 (Declarations): For each FunctionDecl with Span<T> params:
//     - Replace Span<T> param with two params (T* name_data, int64_t name_len)
//     - Inject shadowing local: const name = { data: name_data, len: name_len }
//     - Body stays untouched — references name as a Span struct via the local
//
//   Pass 2 (Call Sites): For each CallExpr targeting an expanded function:
//     - If arg is ObjectLiteral (from spanLower): extract data/len fields into two args
//     - If arg is Span-typed expr: expand to (arg.data, arg.len)
//
// Runs AFTER spanLower (which lowers Array→Span coercions to ObjectLiterals),
// BEFORE nativeLower and builtinLower.
//
// V1 limitation: top-level FunctionDecl only. Span in closures/function-pointer types
// emits a diagnostic.

import { Node, NodeKind, DeclKind, FunctionDeclData, CallExprData, ObjectLiteralData, BlockStmtData, Type, TypeKind } from "../../ast/node";
import { createPtr, createSpan, getSysType } from "../../checker/types";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import {
	makeVarDecl, makeTypedIdent, makeObjectLiteral, makeMember,
} from "../util";

// Track which functions had Span params expanded (by function name → param indices)
interface ExpandedParam {
	originalIndex: number;
	paramName: string;
	elemType: Type;
}

interface ExpandedFunc {
	funcName: string;
	params: ExpandedParam[];
}

// ===== Main Entry Point =====

export function spanParamExpand(program: Node, ctx: TransformContext): Node {
	// Collect expanded function info during Pass 1
	const expandedFuncs: ExpandedFunc[] = [];

	// Pass 1: Rewrite FunctionDecl signatures
	walkNode(program, (node: Node): Node => {
		if (node.kind === NodeKind.FunctionDecl) {
			expandFunctionDecl(node, expandedFuncs, ctx);
		}
		// Diagnostic for Span params in closures
		if (node.kind === NodeKind.ArrowFunction || node.kind === NodeKind.FunctionExpr) {
			checkClosureSpanParams(node, ctx);
		}
		return node;
	});

	// Pass 2: Rewrite call sites for expanded functions
	if (expandedFuncs.length > 0) {
		walkNode(program, (node: Node): Node => {
			if (node.kind === NodeKind.CallExpr) {
				expandCallSite(node, expandedFuncs);
			}
			return node;
		});
	}

	return program;
}

// ===== Pass 1: Declaration Expansion =====

function expandFunctionDecl(node: Node, expandedFuncs: ExpandedFunc[], ctx: TransformContext): void {
	const d = node.data as FunctionDeclData;
	const fnType = node.nodeType;
	if (fnType === null) return;
	if (fnType.kind !== TypeKind.Function) return;
	if (d.params.length === 0) return;

	// Find Span params
	const spanParams: ExpandedParam[] = [];
	let i = 0;
	while (i < d.params.length) {
		if (i < fnType.typeChildren.length) {
			let pType = fnType.typeChildren[i];
			// Unwrap Var/out modifier — reference parity: var openArray → openArray
			if (pType !== null && (pType.kind === TypeKind.Var || pType.kind === TypeKind.Sink || pType.kind === TypeKind.Lent)) {
				pType = pType.typeReturn;
			}
			if (pType !== null && pType.kind === TypeKind.Span && pType.typeReturn !== null) {
				spanParams.push({
					originalIndex: i,
					paramName: d.params[i],
					elemType: pType.typeReturn,
				});
			}
		}
		i = i + 1;
	}

	if (spanParams.length === 0) return;

	// Build new param lists and type children
	const newParams: string[] = [];
	const newParamTypes: string[] = [];
	const newTypeChildren: Type[] = [];

	i = 0;
	while (i < d.params.length) {
		let isSpan = false;
		let si = 0;
		while (si < spanParams.length) {
			if (spanParams[si].originalIndex === i) {
				isSpan = true;
				si = spanParams.length; // break
			}
			si = si + 1;
		}

		if (isSpan) {
			// Find the matching ExpandedParam
			let ep: ExpandedParam = spanParams[0];
			let epi = 0;
			while (epi < spanParams.length) {
				if (spanParams[epi].originalIndex === i) {
					ep = spanParams[epi];
					epi = spanParams.length; // break
				}
				epi = epi + 1;
			}

			const name = ep.paramName;
			const elemType = ep.elemType;

			// Replace with two params: name_data (Ptr<T>) and name_len (int64)
			newParams.push(name + "_data");
			newParams.push(name + "_len");
			newParamTypes.push(""); // resolved via typeChildren
			newParamTypes.push("int64");
			newTypeChildren.push(createPtr(elemType));
			newTypeChildren.push(getSysType(TypeKind.Int64));
		} else {
			newParams.push(d.params[i]);
			if (i < d.fnParamTypes.length) {
				newParamTypes.push(d.fnParamTypes[i]);
			} else {
				newParamTypes.push("");
			}
			if (i < fnType.typeChildren.length) {
				newTypeChildren.push(fnType.typeChildren[i]);
			}
		}

		i = i + 1;
	}

	// Update params and type
	d.params = newParams;
	d.fnParamTypes = newParamTypes;
	fnType.typeChildren = newTypeChildren;

	// Inject shadowing locals at top of body
	if (d.fnBody !== null && d.fnBody.kind === NodeKind.BlockStmt) {
		const bd = d.fnBody.data as BlockStmtData;
		const loc = node.location;

		// Insert in reverse order so they appear in original param order
		let si = spanParams.length - 1;
		while (si >= 0) {
			const ep = spanParams[si];
			const spanType = createSpan(ep.elemType);

			// const name = { data: name_data, len: name_len }
			const dataRef = makeTypedIdent(ep.paramName + "_data", createPtr(ep.elemType), loc);
			const lenRef = makeTypedIdent(ep.paramName + "_len", getSysType(TypeKind.Int64), loc);
			const initObj = makeObjectLiteral(["data", "len"], [dataRef, lenRef], loc);
			initObj.nodeType = spanType;
			const shadowDecl = makeVarDecl(ep.paramName, initObj, DeclKind.Const, loc);
			shadowDecl.nodeType = spanType;

			// Prepend to body statements
			const newStmts: Node[] = [shadowDecl];
			let bi = 0;
			while (bi < bd.statements.length) {
				newStmts.push(bd.statements[bi]);
				bi = bi + 1;
			}
			bd.statements = newStmts;

			si = si - 1;
		}
	}

	// Record this function as expanded
	expandedFuncs.push({ funcName: d.fnName, params: spanParams });
}

// ===== Pass 2: Call Site Expansion =====

function expandCallSite(node: Node, expandedFuncs: ExpandedFunc[]): void {
	const d = node.data as CallExprData;

	// Find the expanded function info via resolvedSym or callee name
	let funcInfo: ExpandedFunc = null as unknown as ExpandedFunc;

	// Try resolvedSym first (most reliable)
	if (node.resolvedSym !== null && node.resolvedSym.symbolType !== null) {
		const symType = node.resolvedSym.symbolType;
		if (symType.kind === TypeKind.Function) {
			// Check if any param is Span — if the function was expanded, its params
			// are no longer Span, so we match by function name
			let fi = 0;
			while (fi < expandedFuncs.length) {
				if (expandedFuncs[fi].funcName === node.resolvedSym.name) {
					funcInfo = expandedFuncs[fi];
					fi = expandedFuncs.length; // break
				}
				fi = fi + 1;
			}
		}
	}

	// Fallback: check callee identifier name
	if (funcInfo === null && d.callee !== null && d.callee.kind === NodeKind.Identifier) {
		const calleeName = (d.callee.data as { name: string }).name;
		let fi = 0;
		while (fi < expandedFuncs.length) {
			if (expandedFuncs[fi].funcName === calleeName) {
				funcInfo = expandedFuncs[fi];
				fi = expandedFuncs.length; // break
			}
			fi = fi + 1;
		}
	}

	if (funcInfo === null) return;

	// Build new argument list, expanding Span args into two
	const newArgs: Node[] = [];
	const oldArgs = d.arguments;
	let ai = 0;
	let expandIdx = 0;

	while (ai < oldArgs.length) {
		// Check if this arg position corresponds to an expanded Span param
		let isExpandedPos = false;
		let ep: ExpandedParam = null as unknown as ExpandedParam;
		let epi = 0;
		while (epi < funcInfo.params.length) {
			if (funcInfo.params[epi].originalIndex === ai) {
				isExpandedPos = true;
				ep = funcInfo.params[epi];
				epi = funcInfo.params.length; // break
			}
			epi = epi + 1;
		}

		if (isExpandedPos) {
			const arg = oldArgs[ai];

			// Case 1: ObjectLiteral from spanLower with keys ["data", "len"]
			if (arg.kind === NodeKind.ObjectLiteral) {
				const od = arg.data as ObjectLiteralData;
				if (od.keys.length === 2 && od.keys[0] === "data" && od.keys[1] === "len") {
					// Extract the data and len expressions directly
					newArgs.push(od.properties[0]); // data expr
					newArgs.push(od.properties[1]); // len expr
					ai = ai + 1;
					continue;
				}
			}

			// Case 2: Span-typed expression — expand to (arg.data, arg.len)
			const loc = arg.location;
			newArgs.push(makeMember(arg, "data", loc));
			newArgs.push(makeMember(arg, "len", loc));
		} else {
			newArgs.push(oldArgs[ai]);
		}

		ai = ai + 1;
	}

	d.arguments = newArgs;
}

// ===== V1 Diagnostic: Span in Closures =====

function checkClosureSpanParams(node: Node, ctx: TransformContext): void {
	const fnType = node.nodeType;
	if (fnType === null) return;
	if (fnType.kind !== TypeKind.Function) return;

	let i = 0;
	while (i < fnType.typeChildren.length) {
		const pType = fnType.typeChildren[i];
		if (pType !== null && pType.kind === TypeKind.Span) {
			ctx.errors.push("Span parameters in closures are not yet supported in the C backend");
			return; // One diagnostic per closure is enough
		}
		i = i + 1;
	}
}

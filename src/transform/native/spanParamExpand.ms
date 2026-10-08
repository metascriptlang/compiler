// Span Parameter Expansion — openArray calling convention for C backend
//
// Expands Span<T> parameters of EXTERN functions into two C-level parameters
// (T* name_data, int64_t name_len) — the flat FFI ABI the C runtime is written
// against (e.g. msOsCpus). Non-extern functions keep the Span type end-to-end:
// codegen derives the by-pointer convention from the type, identically in every
// module — rewriting signatures here was module-local and split the C signature
// of one symbol across translation units.
//
// Pattern: standard reference expansion pattern for view/span parameters.
//
// Two passes:
//   Pass 1 (Declarations): For each FunctionDecl with Span<T> params:
//     - Replace Span<T> param with two params (T* name_data, int64_t name_len)
//     - Inject shadowing local: const name = { data: name_data, len: name_len }
//     - Body stays untouched — references name as a Span struct via the local
//
//   Pass 2 (Call Sites): For each call of an extern whose declared type has Span<T> params, in any module:
//     - If arg is ObjectLiteral (from spanLower): extract data/len fields into two args
//     - If arg is Span-typed expr: expand to (arg.data, arg.len)
//
// Runs AFTER spanLower (which lowers Array→Span coercions to ObjectLiterals),
// BEFORE nativeLower and builtinLower.
//
// V1 limitation: top-level FunctionDecl only. Span in closures/function-pointer types
// emits a diagnostic.

import { Node, NodeKind, DeclKind, FunctionDeclData, CallExprData, ObjectLiteralData, ArrayLiteralData, BlockStmtData, Type, TypeKind } from "../../ast/node";
import { createPtr, createSpan, getSysType, copyTypeShallow } from "../../checker/types";
import { SymbolFlag, hasFlag } from "../../checker/symbol";
import { secondRead } from "../lowering/spanLower";
import { TransformContext, reportTransformError } from "../context";
import { walkNode } from "../walker";
import {
	makeVarDecl, makeTypedIdent, makeObjectLiteral, makeMember,
	makeConditional, makeBinary, makeNumber, makeNull,
} from "../util";

// Track which functions had Span params expanded (by function name → param indices)
interface ExpandedParam {
	originalIndex: number;
	paramName: string;
	elemType: Type;
}

// ===== Main Entry Point =====

export function spanParamExpand(program: Node, ctx: TransformContext): Node {
	// Pass 1: Rewrite FunctionDecl signatures
	walkNode(program, (node: Node): Node => {
		if (node.kind == NodeKind.FunctionDecl) {
			expandFunctionDecl(node);
		}
		// Diagnostic for Span params in closures
		if (node.kind == NodeKind.ArrowFunction || node.kind == NodeKind.FunctionExpr) {
			checkClosureSpanParams(node, ctx);
		}
		return node;
	});

	// Pass 2: Rewrite call sites for expanded functions
	walkNode(program, (node: Node): Node => {
		if (node.kind == NodeKind.CallExpr) {
			expandCallSite(node);
		}
		return node;
	});

	return program;
}

// ===== Pass 1: Declaration Expansion =====

function spanParamsOf(fnType: Type, names: string[]): ExpandedParam[] {
	const spanParams: ExpandedParam[] = [];
	let i = 0;
	while (i < fnType.typeChildren.length) {
		let pType = fnType.typeChildren[i];
		// Unwrap Var/out modifier — reference parity: var openArray → openArray
		if (pType != null && (pType.kind == TypeKind.Var || pType.kind == TypeKind.Sink || pType.kind == TypeKind.Lent) && pType.typeReturn != null) {
			pType = pType.typeReturn;
		}
		if (pType != null && pType.kind == TypeKind.Span && pType.typeReturn != null) {
			spanParams.push({
				originalIndex: i,
				paramName: i < names.length ? names[i] : "",
				elemType: pType.typeReturn,
			});
		}
		i = i + 1;
	}
	return spanParams;
}

function expandFunctionDecl(node: Node): void {
	const d = node.data as FunctionDeclData;
	if (d.fnFlags.indexOf("extern", 0) < 0) return;
	const fnType = node.nodeType;
	if (fnType == null) return;
	if (fnType.kind != TypeKind.Function) return;
	if (d.params.length == 0) return;

	const spanParams = spanParamsOf(fnType, d.params);
	if (spanParams.length == 0) return;
	let i = 0;

	// Build new param lists and type children
	const newParams: string[] = [];
	const newParamTypes: string[] = [];
	const newTypeChildren: Type[] = [];

	i = 0;
	while (i < d.params.length) {
		let isSpan = false;
		let si = 0;
		while (si < spanParams.length) {
			if (spanParams[si].originalIndex == i) {
				isSpan = true;
				si = spanParams.length; // break
			}
			si = si + 1;
		}

		if (isSpan) {
			let ep: ExpandedParam = spanParams[0];
			let epi = 0;
			while (epi < spanParams.length) {
				if (spanParams[epi].originalIndex == i) {
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
	const flat = copyTypeShallow(fnType);
	flat.typeChildren = newTypeChildren;
	node.nodeType = flat;
	if (node.resolvedSym != null && node.resolvedSym.symbolType == fnType) node.resolvedSym.symbolType = flat;

	// Inject shadowing locals at top of body
	if (d.fnBody != null && d.fnBody.kind == NodeKind.BlockStmt) {
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

}

// ===== Pass 2: Call Site Expansion =====

function expandCallSite(node: Node): void {
	const d = node.data as CallExprData;
	const sym = node.resolvedSym != null ? node.resolvedSym : (d.callee != null ? d.callee.resolvedSym : null);
	if (sym == null || !hasFlag(sym, SymbolFlag.ImportC)) return;
	const declared = d.callee != null ? d.callee.nodeType : null;
	if (declared == null || declared.kind != TypeKind.Function) return;
	const spanParams = spanParamsOf(declared, []);
	if (spanParams.length == 0) return;

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
		while (epi < spanParams.length) {
			if (spanParams[epi].originalIndex == ai) {
				isExpandedPos = true;
				ep = spanParams[epi];
				epi = spanParams.length; // break
			}
			epi = epi + 1;
		}

		if (isExpandedPos) {
			const arg = oldArgs[ai];

			// Case 1: ObjectLiteral from spanLower with keys ["data", "len"]
			if (arg.kind == NodeKind.ObjectLiteral) {
				const od = arg.data as ObjectLiteralData;
				if (od.keys.length == 2 && od.keys[0] == "data" && od.keys[1] == "len") {
					// Extract the data and len expressions directly
					newArgs.push(od.properties[0]); // data expr
					newArgs.push(od.properties[1]); // len expr
					ai = ai + 1;
					continue;
				}
			}

			// Case 2: Span-typed expression — expand to (arg.data, arg.len).
			// An empty Array's payload pointer is NULL (no allocation), so a
			// direct arg.data dereferences NULL; p != NULL whenever len > 0, so
			// the len guard hands out null for the empty case. spanLower made
			// every span argument a pure path, so each read is its own copy.
			const loc = arg.location;

			if (arg.kind == NodeKind.ArrayLiteral && (arg.data as ArrayLiteralData).elements.length == 0) {
				const nullData = makeNull(loc);
				nullData.nodeType = createPtr(ep.elemType);
				newArgs.push(nullData);
				newArgs.push(makeNumber(0, loc));
				ai = ai + 1;
				continue;
			}

			// Reference parity (openArrayLoc, tyArray arm): a fixed-size array
			// hands over its inline buffer and a STATIC length. It has no `len`
			// field to read and its buffer is never null, so no guard.
			const argType = arg.nodeType;
			if (argType != null && argType.kind == TypeKind.SizedArray) {
				newArgs.push(makeMember(arg, "data", loc));
				newArgs.push(makeNumber(argType.typeValue, loc));
				ai = ai + 1;
				continue;
			}

			if (arg.kind == NodeKind.Identifier || arg.kind == NodeKind.MemberExpr) {
				const dataArg = makeConditional(
					makeBinary(makeMember(arg, "len", loc), ">", makeNumber(0, loc), loc),
					makeMember(secondRead(arg), "data", loc),
					makeNull(loc),
					loc,
				);
				dataArg.nodeType = createPtr(ep.elemType);
				newArgs.push(dataArg);
			} else {
				newArgs.push(makeMember(arg, "data", loc));
			}
			newArgs.push(makeMember(secondRead(arg), "len", loc));
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
	if (fnType == null) return;
	if (fnType.kind != TypeKind.Function) return;

	let i = 0;
	while (i < fnType.typeChildren.length) {
		const pType = fnType.typeChildren[i];
		if (pType != null && pType.kind == TypeKind.Span) {
			reportTransformError(ctx, "Span parameters in closures are not yet supported in the C backend", node.location);
			return; // One diagnostic per closure is enough
		}
		i = i + 1;
	}
}

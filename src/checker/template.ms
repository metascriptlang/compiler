// src/checker/template.ms
//
// Template expansion. A template's body is expanded at the call site with
// parameter substitution — no function call is emitted; the expanded AST is
// re-checked in the caller's context.
//
// Expansion forms:
//   - body `return <expr>;` or a single expression statement → expression
//     template, usable anywhere an expression is.
//   - any other body → statement template: statement position only, expanded
//     through SpliceMany (`return`/`break`/`continue` bind to the CALLER).
// A parameter referenced N times duplicates its argument expression N times.
// Body locals are gensym-renamed (declaration + references) for hygiene.

import {
	Node, NodeKind, IdentifierData, CallExprData,
	FunctionDeclData, BlockStmtData, ExprStmtData, ReturnStmtData, VariableDeclData,
	ForOfStmtData, ForInStmtData, TryCatchStmtData, ArrowFunctionData, FunctionExprData,
	MatchCaseData, SpliceManyData,
	Type, TypeKind, Symbol,
} from "../ast/node";
import { CheckerContext, addError, extractGenericNames } from "./context";
import { inferredType, errorType, voidType, typeDisplayName, hasGenericParams, isUnknownType, isUnresolvedType } from "./types";
import { isAssignable } from "./compat";
import { bindFromExplicitTypeArgs, checkExplicitTypeArgArity } from "./resolvePass";
import { cloneNodeForCheck, cloneNodeKeepSem } from "../monomorphize/clone";
import { callCheckExpr } from "./checkerCallbacks";
import { mapChildren } from "../transform/walker";
import { forEachChild } from "../ast/visitor";

// Check if a function symbol is a template (has "template" in fnFlags).
export function isTemplateSym(sym: Symbol): boolean {
	if (sym == null || sym.declNode == null) return false;
	if (sym.declNode.kind != NodeKind.FunctionDecl) return false;
	const flags = (sym.declNode.data as FunctionDeclData).fnFlags;
	return flags.indexOf("template", 0) >= 0;
}

let _templateGensymCounter: int32 = 0;
let _templateDepth: int32 = 0;
const TEMPLATE_DEPTH_LIMIT: int32 = 100;

export function expandTemplate(ctx: CheckerContext, sym: Symbol, callNode: Node, callData: CallExprData, expectedType: Type | null): Type {
	if (_templateDepth >= TEMPLATE_DEPTH_LIMIT) {
		addError(ctx, `Template '${sym.name}' instantiation too deep (limit ${TEMPLATE_DEPTH_LIMIT})`,
			callNode.location.line, callNode.location.column);
		return errorType();
	}
	_templateDepth = _templateDepth + 1;
	const result = expandTemplateInner(ctx, sym, callNode, callData, expectedType);
	_templateDepth = _templateDepth - 1;
	return result;
}

interface SubstState {
	ctx: CheckerContext;
	symName: string;
	paramNames: string[];
	args: Node[];
	used: boolean[];
	gsuffix: string;
	localNames: string[];
	rejectDestructuring: boolean;
}

function expandTemplateInner(ctx: CheckerContext, sym: Symbol, callNode: Node, callData: CallExprData, expectedType: Type | null): Type {
	const fnDecl = sym.declNode;
	if (fnDecl == null) return inferredType();
	const fd = fnDecl.data as FunctionDeclData;
	if (fd.fnBody == null) return inferredType();

	const paramNames: string[] = [];
	for (const p of fd.params) {
		if (p != "this") paramNames.push(p);
	}
	if (callData.arguments.length != paramNames.length) {
		addError(ctx, `Template '${sym.name}' expects ${paramNames.length} args, got ${callData.arguments.length}`,
			callNode.location.line, callNode.location.column);
		return errorType();
	}

	const args: Node[] = callData.arguments;
	for (const arg of args) {
		callCheckExpr(ctx, arg, null);
	}
	if (!templateArgsFit(ctx, sym, fd, paramNames, args, callNode)) {
		return errorType();
	}

	const cloned = cloneNodeForCheck(fd.fnBody);
	const bd = cloned.data as BlockStmtData;

	_templateGensymCounter = _templateGensymCounter + 1;
	const used: boolean[] = [];
	for (const p of paramNames) used.push(false);
	const localNames = collectBodyLocals(cloned);
	for (const nm of localNames) {
		if (nameIndex(paramNames, nm) >= 0) {
			addError(ctx, `Template '${sym.name}' declares local '${nm}' shadowing a parameter`,
				callNode.location.line, callNode.location.column);
			return errorType();
		}
	}
	const st: SubstState = {
		ctx, symName: sym.name, paramNames, args, used,
		gsuffix: "$t" + String(_templateGensymCounter), localNames,
		rejectDestructuring: true,
	};
	const rootMask: string[] = [];
	mapChildren(cloned, (c: Node): Node => substituteInto(c, st, rootMask));

	let expandedExpr: Node = null as unknown as Node;
	if (bd.statements.length == 1) {
		const stmt = bd.statements[0];
		if (stmt.kind == NodeKind.ReturnStmt) {
			const rd = stmt.data as ReturnStmtData;
			if (rd.argument != null) expandedExpr = rd.argument;
		} else if (stmt.kind == NodeKind.ExprStmt) {
			expandedExpr = (stmt.data as ExprStmtData).expr;
		}
	}
	if (expandedExpr == null) {
		if (ctx.stmtPosExpr != callNode) {
			addError(ctx, `Template '${sym.name}' expands to statements — call it as a standalone statement`,
				callNode.location.line, callNode.location.column);
			return errorType();
		}
		callNode.kind = NodeKind.SpliceMany;
		callNode.data = { spliceNodes: bd.statements } as SpliceManyData;
		callNode.nodeType = voidType();
		callNode.resolvedSym = null;
		return voidType();
	}

	// Check the expanded expression in the caller's context
	callCheckExpr(ctx, expandedExpr, expectedType);

	// Mutate the call node in place (same pattern as macro eager expansion)
	callNode.kind = expandedExpr.kind;
	callNode.data = expandedExpr.data;
	callNode.nodeType = expandedExpr.nodeType;
	callNode.resolvedSym = expandedExpr.resolvedSym;

	return expandedExpr.nodeType != null ? expandedExpr.nodeType : inferredType();
}

export function gensymSplicePrefix(ctx: CheckerContext, splice: Node): void {
	const d = splice.data as SpliceManyData;
	const localNames: string[] = [];
	for (let i = 0; i < d.spliceNodes.length - 1; i += 1) {
		const stmt = d.spliceNodes[i];
		if (stmt.kind == NodeKind.VariableDecl) localNames.push((stmt.data as VariableDeclData).declName);
	}
	if (localNames.length == 0) return;
	_templateGensymCounter = _templateGensymCounter + 1;
	const st: SubstState = {
		ctx, symName: "", paramNames: [], args: [], used: [],
		gsuffix: "$h" + String(_templateGensymCounter), localNames,
		rejectDestructuring: false,
	};
	const rootMask: string[] = [];
	mapChildren(splice, (c: Node): Node => substituteInto(c, st, rootMask));
}

// ===== Declared-type check =====
// Generic params bind from the first argument at that name; later arguments
// must be assignable to the binding. Concrete param types check directly.
// Unshaped/unresolved signatures skip the check (fail open — expansion
// re-checks the substituted body anyway).
function templateArgsFit(ctx: CheckerContext, sym: Symbol, fd: FunctionDeclData, paramNames: string[], args: Node[], callNode: Node): boolean {
	const symType = sym.symbolType;
	if (symType == null || symType.typeChildren == null) return true;
	let offset: int32 = 0;
	if (symType.typeChildren.length == paramNames.length + 1 && fd.params.length > 0 && fd.params[0] == "this") {
		offset = 1;
	} else if (symType.typeChildren.length != paramNames.length) {
		return true;
	}
	const genNames = extractGenericNames(fd.fnFlags);
	if (!checkExplicitTypeArgArity(ctx, callNode, genNames, sym.name)) return false;
	const boundNames: string[] = [];
	const boundTypes: Type[] = [];
	const boundFrom: int32[] = [];
	const explicit = bindFromExplicitTypeArgs(callNode, genNames, ctx);
	for (let ei = 0; ei < explicit.names.length; ei += 1) {
		boundNames.push(explicit.names[ei]);
		boundTypes.push(explicit.types[ei]);
		boundFrom.push(-1);
	}
	const candNames: string[] = [];
	const candTypes: Type[] = [];
	const candFrom: int32[] = [];
	for (let i: int32 = 0; i < args.length; i++) {
		const declared = symType.typeChildren[i + offset];
		const argT = args[i].nodeType;
		if (declared == null || argT == null) continue;
		const dn = declared.kind == TypeKind.GenericParam ? declared.typeName : "";
		if (dn != "" && nameIndex(genNames, dn) >= 0) {
			candNames.push(dn);
			candTypes.push(argT);
			candFrom.push(i);
			continue;
		}
		if (hasGenericParams(declared) || isUnknownType(declared) || isUnresolvedType(declared)) continue;
		if (!isAssignable(argT, declared)) {
			addError(ctx, `Template '${sym.name}': argument ${i + 1} expects ${typeDisplayName(declared)}, got ${typeDisplayName(argT)}`,
				callNode.location.line, callNode.location.column);
			return false;
		}
	}
	for (let ci = 0; ci < candNames.length; ci += 1) {
		const dn = candNames[ci];
		let bidx = nameIndex(boundNames, dn);
		if (bidx < 0) {
			boundNames.push(dn);
			boundTypes.push(candTypes[ci]);
			boundFrom.push(candFrom[ci]);
			bidx = boundNames.length - 1;
			for (let cj = ci + 1; cj < candNames.length; cj += 1) {
				if (candNames[cj] != dn) continue;
				if (isAssignable(boundTypes[bidx], candTypes[cj]) && !isAssignable(candTypes[cj], boundTypes[bidx])) {
					boundTypes[bidx] = candTypes[cj];
					boundFrom[bidx] = candFrom[cj];
				}
			}
		} else if (boundFrom[bidx] >= 0) {
			continue;
		}
		for (let cj = ci; cj < candNames.length; cj += 1) {
			if (candNames[cj] != dn || candFrom[cj] == boundFrom[bidx] || isAssignable(candTypes[cj], boundTypes[bidx])) continue;
			const origin = boundFrom[bidx] >= 0 ? ` — '${dn}' was bound by argument ${boundFrom[bidx]}` : "";
			addError(ctx, `Argument type mismatch in '${sym.name}' arg ${candFrom[cj]}: got ${typeDisplayName(candTypes[cj])}, expected ${typeDisplayName(boundTypes[bidx])}${origin}`,
				args[candFrom[cj]].location.line, args[candFrom[cj]].location.column);
			return false;
		}
	}
	return true;
}

// ===== Hygiene: body-local collection =====
// Nested function bodies keep their own locals (no escape into the caller);
// only names declared in the template body itself are gensym-renamed.
function collectBodyLocals(body: Node): string[] {
	const out: string[] = [];
	forEachChild(body, (c: Node): void => { collectLocalsWalk(c, out); });
	return out;
}

function collectLocalsWalk(n: Node, out: string[]): void {
	const k = n.kind;
	if (k == NodeKind.ArrowFunction || k == NodeKind.FunctionExpr || k == NodeKind.FunctionDecl) return;
	if (k == NodeKind.VariableDecl) {
		out.push((n.data as VariableDeclData).declName);
	} else if (k == NodeKind.ForOfStmt) {
		const d = n.data as ForOfStmtData;
		if (d.forOfBinding != "") out.push(d.forOfBinding);
	} else if (k == NodeKind.ForInStmt) {
		const d = n.data as ForInStmtData;
		if (d.forInBinding != "") out.push(d.forInBinding);
	} else if (k == NodeKind.TryCatchStmt) {
		const d = n.data as TryCatchStmtData;
		if (d.catchName != "") out.push(d.catchName);
	}
	forEachChild(n, (c: Node): void => { collectLocalsWalk(c, out); });
}

// ===== Substitution walker =====
// Universal traversal via mapChildren — every child slot of every NodeKind.
// `masked` holds names shadowed by nested function params or match bindings:
// those resolve to the inner binding, never to a template param or body local.
function substituteInto(n: Node, st: SubstState, masked: string[]): Node {
	if (n == null) return n;
	const k = n.kind;
	if (k == NodeKind.Identifier) {
		const idd = n.data as IdentifierData;
		const nm = idd.name;
		if (nameIndex(masked, nm) >= 0) return n;
		const pidx = nameIndex(st.paramNames, nm);
		if (pidx >= 0) {
			if (!st.used[pidx]) {
				st.used[pidx] = true;
				return st.args[pidx];
			}
			return cloneNodeKeepSem(st.args[pidx]);
		}
		if (nameIndex(st.localNames, nm) >= 0) {
			idd.name = nm + st.gsuffix;
		}
		return n;
	}
	if (k == NodeKind.VariableDecl) {
		const d = n.data as VariableDeclData;
		if (nameIndex(st.localNames, d.declName) >= 0) d.declName = d.declName + st.gsuffix;
	} else if (k == NodeKind.ForOfStmt) {
		const d = n.data as ForOfStmtData;
		if (nameIndex(st.localNames, d.forOfBinding) >= 0) d.forOfBinding = d.forOfBinding + st.gsuffix;
	} else if (k == NodeKind.ForInStmt) {
		const d = n.data as ForInStmtData;
		if (nameIndex(st.localNames, d.forInBinding) >= 0) d.forInBinding = d.forInBinding + st.gsuffix;
	} else if (k == NodeKind.TryCatchStmt) {
		const d = n.data as TryCatchStmtData;
		if (nameIndex(st.localNames, d.catchName) >= 0) d.catchName = d.catchName + st.gsuffix;
	} else if (k == NodeKind.DestructuringDecl && st.rejectDestructuring) {
		addError(st.ctx, `Template '${st.symName}': destructuring declarations in a template body are not supported yet`,
			n.location.line, n.location.column);
		return n;
	} else if (k == NodeKind.ArrowFunction) {
		const d = n.data as ArrowFunctionData;
		const ext = extendMask(masked, d.arrowParams, st);
		mapChildren(n, (c: Node): Node => substituteInto(c, st, ext));
		return n;
	} else if (k == NodeKind.FunctionExpr) {
		const d = n.data as FunctionExprData;
		const ext = extendMask(masked, d.funcExprParams, st);
		mapChildren(n, (c: Node): Node => substituteInto(c, st, ext));
		return n;
	} else if (k == NodeKind.FunctionDecl) {
		const d = n.data as FunctionDeclData;
		const ext = extendMask(masked, d.params, st);
		mapChildren(n, (c: Node): Node => substituteInto(c, st, ext));
		return n;
	} else if (k == NodeKind.MatchCase) {
		const d = n.data as MatchCaseData;
		const bindings: string[] = [];
		for (const pat of d.casePatterns) {
			if (pat != null && pat.kind == NodeKind.Identifier) {
				bindings.push((pat.data as IdentifierData).name);
			}
		}
		const ext = extendMask(masked, bindings, st);
		mapChildren(n, (c: Node): Node => substituteInto(c, st, ext));
		return n;
	}
	mapChildren(n, (c: Node): Node => substituteInto(c, st, masked));
	return n;
}

function extendMask(masked: string[], names: string[], st: SubstState): string[] {
	let ext: string[] = masked;
	let copied = false;
	for (const nm of names) {
		if (nameIndex(st.paramNames, nm) < 0 && nameIndex(st.localNames, nm) < 0) continue;
		if (!copied) {
			const c: string[] = [];
			for (const m of masked) c.push(m);
			ext = c;
			copied = true;
		}
		ext.push(nm);
	}
	return ext;
}

function nameIndex(list: string[], name: string): int32 {
	for (let i: int32 = 0; i < list.length; i++) {
		if (list[i] == name) return i;
	}
	return -1;
}

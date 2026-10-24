// Param Mutation Analysis — detect which function params are mutated in the body
//
// Runs in checker pipeline (after 3-pass + ownership inference).
// Sets Symbol.mutatedParams bitfield on function Symbols.
// Codegen reads this to gate const-ptr promotion (ccgIntroducedPtr).
//
// For struct (value type) params, aliasing doesn't matter because
// assignment creates a copy. Only direct mutations need detection:
//   - Direct assignment: param = expr
//   - Member mutation: param.field = expr
//   - Index mutation: param[i] = expr
//   - Compound assignment: param += expr
//   - Update expression: param++, param--
//   - Passed as ref/out: HiddenAddr(param)

import {
	Node, NodeKind,
	ProgramData, FunctionDeclData, BinaryExprData, MemberExprData,
	ArrayAccessData, UpdateExprData, ExportDeclData,
} from "../ast/node";
import { Type, TypeKind, TypeFlag, Symbol } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { CheckerContext, addError, isGenericFn } from "./context";
import { splitTopLevel, parseIntStr } from "../utils/string";

// ===== Public Entry Point =====

export function isMutatingArrayMethod(method: string): boolean {
	return method == "push" || method == "pop" || method == "shift" || method == "unshift"
		|| method == "splice" || method == "reverse" || method == "sort" || method == "fill"
		|| method == "copyWithin" || method == "append" || method == "setLength"
		|| method == "setSlice" || method == "stripInPlace" || method == "setLen";
}

export function analyzeParamMutations(ctx: CheckerContext, program: Node): void {
	if (program == null || program.kind != NodeKind.Program) return;
	const pd = program.data as ProgramData;
	for (const stmt of pd.programStmts) {
		let inner = stmt;
		if (inner.kind == NodeKind.ExportDecl) {
			inner = (inner.data as ExportDeclData).exportedDecl;
		}
		if (inner.kind == NodeKind.FunctionDecl) {
			analyzeFunctionParams(inner, ctx);
		}
	}
}

function analyzeFunctionParams(node: Node, ctx: CheckerContext): void {
	const d = node.data as FunctionDeclData;
	const sym = node.resolvedSym;
	if (sym == null || d.fnBody == null) return;
	if (d.fnFlags.indexOf("overload", 0) >= 0 || d.fnFlags.indexOf("extern", 0) >= 0) return;

	// Recurse into nested functions first
	scanNestedFunctions(d.fnBody, ctx);

	if (d.params.length == 0) return;
	const paramSyms = node.paramSyms;
	if (paramSyms == null || paramSyms.length != d.params.length) {
		if (isGenericFn(d.fnFlags)) return;
		addError(ctx, `internal: function '${d.fnName}' has no checked parameter symbols for mutation analysis`, node.location.line, node.location.column);
		return;
	}

	let bits: int32 = 0;
	const writes: (Node | null)[] = [];
	let i: int32 = 0;
	while (i < d.params.length && i < 31) {
		const w = firstWrite(d.fnBody, paramSyms[i]);
		writes.push(w);
		if (w != null) {
			bits = bits | (1 << i);
		}
		i = i + 1;
	}
	sym.mutatedParams = bits;

	// Cross-check: readonly params must not be mutated
	if (bits != 0 && d.fnFlags != "" && d.fnFlags.indexOf("rdonly:") >= 0) {
		const flagParts = splitTopLevel(d.fnFlags, "|");
		for (const fp of flagParts) {
			const trimFp = fp.trim();
			if (trimFp.length > 7 && trimFp.slice(0, 7) == "rdonly:") {
				const idxStr = trimFp.slice(7, trimFp.length);
				const idxParts = splitTopLevel(idxStr, ",");
				for (const ip of idxParts) {
					const idx = parseIntStr(ip.trim());
					if (idx >= 0 && idx < writes.length) {
						const w = writes[idx];
						if (w != null) {
							addError(ctx, `cannot mutate readonly parameter '${d.params[idx]}'`, w.location.line, w.location.column);
						}
					}
				}
			}
		}
	}
}

// Analyze every function declared anywhere inside a body.
function scanNestedFunctions(node: Node | null, ctx: CheckerContext): void {
	if (node == null) return;
	if (node.kind == NodeKind.FunctionDecl) {
		analyzeFunctionParams(node, ctx);
		return;
	}
	forEachChild(node, (c: Node): void => { scanNestedFunctions(c, ctx); });
}

// Value aggregates are the kinds whose params are C by-pointer views without RC:
// interior writes would reach the caller's storage. Interfaces arrive as Ref
// (collectStructLike wraps them), Span is a view by design, Union covers Ref|null.
export function isValueAggregateParam(t: Type | null): boolean {
	if (t == null) return false;
	return match (t.kind) {
		TypeKind.Array | TypeKind.SizedArray | TypeKind.Tuple | TypeKind.Struct => true,
		TypeKind.Union => t.typeFlags.has(TypeFlag.ValueUnion),
		TypeKind.GenericInstance => t.typeExtra != null && (t.typeExtra.kind == TypeKind.Struct || (t.typeExtra.kind == TypeKind.Union && t.typeExtra.typeFlags.has(TypeFlag.ValueUnion))),
		_ => false,
	};
}

// ===== Mutation Detection =====

function getRootSym(node: Node | null): Symbol | null {
	if (node == null) return null;
	return match (node.kind) {
		NodeKind.Identifier => node.resolvedSym,
		NodeKind.MemberExpr => getRootSym((node.data as MemberExprData).object),
		NodeKind.ArrayAccess => getRootSym((node.data as ArrayAccessData).array),
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => getRootSym((node.data as { expr: Node }).expr),
		_ => null,
	};
}

function isAssignOp(op: string): boolean {
	return match (op) {
		"=" | "+=" | "-=" | "*=" | "/=" | "%=" | "**=" | "&=" | "|=" | "^=" | "<<=" | ">>=" | ">>>=" => true,
		_ => false,
	};
}

function writesParam(node: Node, paramSym: Symbol): boolean {
	return match (node.kind) {
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			return isAssignOp(d.operator) && getRootSym(d.left) == paramSym;
		},
		NodeKind.UpdateExpr => getRootSym((node.data as UpdateExprData).updateArg) == paramSym,
		NodeKind.HiddenAddr => getRootSym((node.data as { expr: Node }).expr) == paramSym,
		_ => false,
	};
}

// The first node in source order that writes paramSym, or null. A nested function
// is searched too: it can write a captured parameter, and symbol identity keeps its
// own parameters apart.
function firstWrite(node: Node | null, paramSym: Symbol): Node | null {
	if (node == null) return null;
	if (writesParam(node, paramSym)) return node;
	let found: Node | null = null;
	forEachChild(node, (c: Node): void => {
		if (found == null) found = firstWrite(c, paramSym);
	});
	return found;
}

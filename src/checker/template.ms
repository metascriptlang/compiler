// src/checker/template.ms
//
// Template expansion. Templates are generic inline functions whose
// body is copy-pasted at the call site with parameter substitution. No
// function call is emitted — the expanded AST is type-checked in the caller's
// context. Hygienic: local variables are gensym'd to prevent name collisions.
//
// Usage:
//   template `!=`<T>(this a: T, b: T): boolean { return !(a == b); }
//   "hello" != "world"  →  substituted to  →  !("hello" == "world")

import {
	Node, NodeKind, NodeData,
	IdentifierData, BinaryExprData, UnaryExprData, CallExprData,
	FunctionDeclData, BlockStmtData, ExprStmtData, ReturnStmtData,
	VariableDeclData, ConditionalExprData, IfStmtData,
	MemberExprData, ArrayAccessData, ObjectLiteralData,
	Type, Symbol, SymbolKind,
} from "../ast/node";
import { CheckerContext, addError } from "./context";
import { unknownType } from "./types";
import { cloneNodeForCheck } from "../monomorphize/clone";
import { callCheckExpr } from "./checkerCallbacks";

// Check if a function symbol is a template (has "template" in fnFlags).
export function isTemplateSym(sym: Symbol): boolean {
	if (sym === null || sym.declNode === null) return false;
	if (sym.declNode.kind !== NodeKind.FunctionDecl) return false;
	const flags = (sym.declNode.data as FunctionDeclData).fnFlags;
	return flags.indexOf("template", 0) >= 0;
}

// Gensym counter for hygienic template local variable renaming.
let _templateGensymCounter: int32 = 0;
// Recursion depth guard — prevents infinite expansion if a template
// directly or indirectly references itself. Matches the reference evalTemplateLimit.
let _templateDepth: int32 = 0;
const TEMPLATE_DEPTH_LIMIT: int32 = 100;

export function expandTemplate(ctx: CheckerContext, sym: Symbol, callNode: Node, callData: CallExprData, expectedType: Type): Type {
	if (_templateDepth >= TEMPLATE_DEPTH_LIMIT) {
		addError(ctx, `Template '${sym.name}' instantiation too deep (limit ${TEMPLATE_DEPTH_LIMIT})`,
			callNode.location.line, callNode.location.column);
		return unknownType();
	}
	_templateDepth = _templateDepth + 1;
	const result = expandTemplateInner(ctx, sym, callNode, callData, expectedType);
	_templateDepth = _templateDepth - 1;
	return result;
}

function expandTemplateInner(ctx: CheckerContext, sym: Symbol, callNode: Node, callData: CallExprData, expectedType: Type): Type {
	const fnDecl = sym.declNode;
	if (fnDecl === null) return unknownType();
	const fd = fnDecl.data as FunctionDeclData;
	if (fd.fnBody === null) return unknownType();

	// Check arity (exclude 'this' param for extension methods)
	const paramNames: string[] = [];
	for (const p of fd.params) {
		if (p !== "this") paramNames.push(p);
	}
	if (callData.arguments.length !== paramNames.length) {
		addError(ctx, `Template '${sym.name}' expects ${paramNames.length} args, got ${callData.arguments.length}`,
			callNode.location.line, callNode.location.column);
		return unknownType();
	}

	// Check args first so they have nodeType set
	const args: Node[] = callData.arguments;
	for (const arg of args) {
		callCheckExpr(ctx, arg, null);
	}

	// Clone the template body (deep copy, clears Sem flag for re-checking)
	const cloned = cloneNodeForCheck(fd.fnBody);
	const bd = cloned.data as BlockStmtData;

	// Walk cloned body: substitute param references with cloned arg expressions.
	// Gensym local variable declarations for hygiene.
	_templateGensymCounter = _templateGensymCounter + 1;
	const gsuffix = "$t" + String(_templateGensymCounter);
	for (const stmt of bd.statements) {
		substituteInNode(stmt, paramNames, args, gsuffix);
	}

	// Unwrap single return/expr statement to expression
	let expandedExpr: Node = cloned;
	if (bd.statements.length === 1) {
		const stmt = bd.statements[0];
		if (stmt.kind === NodeKind.ReturnStmt) {
			expandedExpr = (stmt.data as ReturnStmtData).argument;
		} else if (stmt.kind === NodeKind.ExprStmt) {
			expandedExpr = (stmt.data as ExprStmtData).expr;
		}
	}

	// Check the expanded expression in the caller's context
	callCheckExpr(ctx, expandedExpr, expectedType);

	// Mutate the call node in place (same pattern as macro eager expansion)
	callNode.kind = expandedExpr.kind;
	callNode.data = expandedExpr.data;
	callNode.nodeType = expandedExpr.nodeType;
	callNode.resolvedSym = expandedExpr.resolvedSym;

	return expandedExpr.nodeType !== null ? expandedExpr.nodeType : unknownType();
}

// ===== Parameter substitution walker =====

// Check if a node is an Identifier referencing a template parameter.
function paramIndex(node: Node, paramNames: string[]): int32 {
	if (node === null || node.kind !== NodeKind.Identifier) return -1;
	const name = (node.data as IdentifierData).name;
	let i: int32 = 0;
	while (i < paramNames.length) {
		if (paramNames[i] === name) return i;
		i = i + 1;
	}
	return -1;
}

// Try to substitute a child node. If it's a param reference, replace with
// cloned arg. Otherwise recurse. Returns the (possibly replaced) node.
function trySubstitute(child: Node, paramNames: string[], args: Node[], gsuffix: string): Node {
	if (child === null) return child;
	const pidx = paramIndex(child, paramNames);
	if (pidx >= 0) return cloneNodeForCheck(args[pidx]);
	substituteInNode(child, paramNames, args, gsuffix);
	return child;
}

// Recursive walker: replace param references with cloned args, gensym locals.
function substituteInNode(node: Node, paramNames: string[], args: Node[], gsuffix: string): void {
	if (node === null) return;
	const k = node.kind;

	if (k === NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		d.declName = d.declName + gsuffix;
		d.initializer = trySubstitute(d.initializer, paramNames, args, gsuffix);
		return;
	}
	if (k === NodeKind.BlockStmt) {
		const d = node.data as BlockStmtData;
		for (const stmt of d.statements) {
			substituteInNode(stmt, paramNames, args, gsuffix);
		}
		return;
	}
	if (k === NodeKind.ReturnStmt) {
		const d = node.data as ReturnStmtData;
		d.argument = trySubstitute(d.argument, paramNames, args, gsuffix);
		return;
	}
	if (k === NodeKind.ExprStmt) {
		const d = node.data as ExprStmtData;
		d.expr = trySubstitute(d.expr, paramNames, args, gsuffix);
		return;
	}
	if (k === NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		d.left = trySubstitute(d.left, paramNames, args, gsuffix);
		d.right = trySubstitute(d.right, paramNames, args, gsuffix);
		return;
	}
	if (k === NodeKind.UnaryExpr) {
		const d = node.data as UnaryExprData;
		d.operand = trySubstitute(d.operand, paramNames, args, gsuffix);
		return;
	}
	if (k === NodeKind.CallExpr) {
		const d = node.data as CallExprData;
		d.callee = trySubstitute(d.callee, paramNames, args, gsuffix);
		let i = 0;
		while (i < d.arguments.length) {
			d.arguments[i] = trySubstitute(d.arguments[i], paramNames, args, gsuffix);
			i = i + 1;
		}
		return;
	}
	if (k === NodeKind.MemberExpr) {
		const d = node.data as MemberExprData;
		d.object = trySubstitute(d.object, paramNames, args, gsuffix);
		return;
	}
	if (k === NodeKind.ConditionalExpr) {
		const d = node.data as ConditionalExprData;
		d.ternaryCondition = trySubstitute(d.ternaryCondition, paramNames, args, gsuffix);
		d.ternaryConsequent = trySubstitute(d.ternaryConsequent, paramNames, args, gsuffix);
		d.ternaryAlternate = trySubstitute(d.ternaryAlternate, paramNames, args, gsuffix);
		return;
	}
	if (k === NodeKind.IfStmt) {
		const d = node.data as IfStmtData;
		d.condition = trySubstitute(d.condition, paramNames, args, gsuffix);
		substituteInNode(d.consequent, paramNames, args, gsuffix);
		substituteInNode(d.alternate, paramNames, args, gsuffix);
		return;
	}
	if (k === NodeKind.ArrayAccess) {
		const d = node.data as ArrayAccessData;
		d.array = trySubstitute(d.array, paramNames, args, gsuffix);
		d.index = trySubstitute(d.index, paramNames, args, gsuffix);
		return;
	}
	if (k === NodeKind.ObjectLiteral) {
		const d = node.data as ObjectLiteralData;
		let i = 0;
		while (i < d.properties.length) {
			d.properties[i] = trySubstitute(d.properties[i], paramNames, args, gsuffix);
			i = i + 1;
		}
		return;
	}
}

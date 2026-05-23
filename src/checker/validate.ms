// AST Validator — post-Pass-3 invariant enforcement
//
// Validates two contracts after Pass 3 completes:
//
//   1. Every non-type Identifier has nodeType set (catches checker bugs that
//      leave dangling expressions).
//
//   2. No `node.nodeType` contains TypeKind.GenericParam OUTSIDE template
//      (uninstantiated generic) decls. Violations are silent corruption:
//      lambda lifting / mono / codegen propagate them as link errors much
//      later. This is the BACKSTOP for the BUG #2 family of bugs — when a
//      generic-call entry point fails to substitute generic params before
//      checking closure arg bodies, the closure's nodeType inherits T.
//
// Violations of #2 are emitted as WARNINGS (severity=Warning) so existing
// tests don't break while Phase C/D fixes propagate. Once all known leaks
// are closed, severity can be promoted to Error.
//
// 3-pass parity: this validator runs AFTER Pass 3 (`validateTypedAST` is
// called from compile.ms after `checkProgramWithRegistry`). It does not
// re-check; only inspects the final nodeType state.

import { Node, NodeKind, IdentifierData, FunctionDeclData, MethodDeclData, Type, TypeKind } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { CheckerContext, addError, addWarning, isGenericFn } from "./context";

// Public entry point. Walks top-level for Invariant #1 (existing behavior),
// then runs a separate full-tree walk for Invariant #2 (GenericParam leak
// detection) that goes into function bodies.
export function validateTypedAST(ctx: CheckerContext, node: Node): void {
	// Invariant #1: top-level only (preserves existing behavior — function
	// bodies are validated by checkFunctionBody during Pass 3, not here).
	validateInvariant1TopLevel(ctx, node);

	// Invariant #2: full-tree walk for GenericParam leakage. Walks into
	// function/method bodies, exempts template scopes.
	validateInvariant2Full(ctx, node, false);
}

// ===== Invariant #1: top-level identifier nodeType =====
// Preserves the pre-Phase-B behavior: skip function/method/ctor/macro
// bodies; only check top-level identifiers.
function validateInvariant1TopLevel(ctx: CheckerContext, node: Node): void {
	if (node === null) return;
	if (node.kind === NodeKind.FunctionDecl) return;
	if (node.kind === NodeKind.MethodDecl) return;
	if (node.kind === NodeKind.ConstructorDecl) return;
	if (node.kind === NodeKind.MacroDecl) return;

	if (node.kind === NodeKind.Identifier && node.nodeType === null) {
		const d = node.data as IdentifierData;
		const first = d.name.length > 0 ? d.name.slice(0, 1) : "";
		if (first < "A" || first > "Z") {
			addError(ctx, `Internal Error: missing nodeType on Identifier '${d.name}' at line ${node.location.line}`, node.location.line, node.location.column);
		}
	}

	forEachChild(node, (child: Node): void => {
		validateInvariant1TopLevel(ctx, child);
	});
}

// ===== Invariant #2: GenericParam leakage =====
// Full-tree walker with template-scope tracking. Inside template decls
// (generic FunctionDecl/MethodDecl), GenericParam is the legitimate
// parametric placeholder and is exempt. Outside templates, any
// GenericParam in nodeType is silent corruption — emitted as warning so
// downstream sees a clear signal without breaking the build.
function validateInvariant2Full(ctx: CheckerContext, node: Node, inTemplate: boolean): void {
	if (node === null) return;

	// Macro bodies are handled by raiser VM, not regular Pass 3 — skip.
	if (node.kind === NodeKind.MacroDecl) return;

	// Determine template scope. Methods inside generic classes inherit
	// gen:... flag from class collection, so the methodFlags check covers
	// generic-class methods correctly without needing to inspect ClassDecl.
	let nextInTemplate = inTemplate;
	if (node.kind === NodeKind.FunctionDecl) {
		const fd = node.data as FunctionDeclData;
		if (isGenericFn(fd.fnFlags)) nextInTemplate = true;
	} else if (node.kind === NodeKind.MethodDecl) {
		const md = node.data as MethodDeclData;
		if (isGenericFn(md.methodFlags)) nextInTemplate = true;
	}

	// NARROWED to closure literals (ArrowFunction/FunctionExpr) — the
	// load-bearing shape for the BUG #2 family. Other node kinds (MemberExpr
	// to a generic method-as-value, Identifier to a parametric reference)
	// may legitimately carry GenericParam in nodeType because they represent
	// callable references whose instantiation happens at the call site, not
	// at the reference point. Mirrors src/test/checker3pass/invariant.ms.
	const isClosureLiteral = node.kind === NodeKind.ArrowFunction || node.kind === NodeKind.FunctionExpr;
	if (!nextInTemplate && isClosureLiteral && node.nodeType !== null) {
		const leak = findGenericParamInType(node.nodeType, "");
		if (leak.found) {
			addWarning(ctx,
				`GenericParam leakage: '${leak.name}' at ${leak.path} on node kind=${node.kind} (post-Pass-3 invariant violation — likely missing type substitution in checkCallExpr or related path)`,
				node.location !== null ? node.location.line : 0,
				node.location !== null ? node.location.column : 0);
		}
	}

	forEachChild(node, (child: Node): void => {
		validateInvariant2Full(ctx, child, nextInTemplate);
	});
}

interface LeakResult {
	found: boolean;
	path: string;
	name: string;
}

// Returns first GenericParam encountered with its dot-path location for
// diagnostics. See `Type Storage Schema` block in src/checker/types.ms for
// field semantics.
function findGenericParamInType(t: Type, path: string): LeakResult {
	if (t === null) return { found: false, path: "", name: "" };

	if (t.kind === TypeKind.GenericParam) {
		return { found: true, path: path === "" ? "<self>" : path, name: t.typeName };
	}

	// Nominal struct (typeName set): skip recursion. Inner generic params
	// are bound via typeChildren at the type's instantiation site, not at
	// this reference point. GenericInstance and unnamed Union/Tuple still
	// need recursion — their typeChildren ARE the type args / variants.
	if ((t.kind === TypeKind.Struct) && t.typeName !== "") {
		return { found: false, path: "", name: "" };
	}

	if (t.typeReturn !== null) {
		const r = findGenericParamInType(t.typeReturn, path === "" ? "typeReturn" : path + ".typeReturn");
		if (r.found) return r;
	}

	if (t.typeExtra !== null) {
		const r = findGenericParamInType(t.typeExtra, path === "" ? "typeExtra" : path + ".typeExtra");
		if (r.found) return r;
	}

	if (t.typeChildren !== null) {
		for (let i = 0; i < t.typeChildren.length; i = i + 1) {
			const child = t.typeChildren[i];
			const childPath = (path === "" ? "typeChildren[" : path + ".typeChildren[") + i.toString() + "]";
			const r = findGenericParamInType(child, childPath);
			if (r.found) return r;
		}
	}

	return { found: false, path: "", name: "" };
}

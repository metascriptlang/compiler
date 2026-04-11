// src/checker/speculate.ms
//
// Phase 5 helpers for two-pass overload resolution. See resolveOverloadCall
// in checkExprPass.ms for the algorithm. Reference: typescript-go
// `internal/checker/checker.go:8682-8903` (`chooseOverload`).
//
// Pass 1 of overload resolution checks each argument once with `null`
// expected type (anon structs for object literals, EnumLiteral narrow
// via resolvedSym for enum members). Scoring picks a winner.
//
// Pass 2 re-checks context-sensitive args (object literals, arrow
// functions) with the winning candidate's parameter types so they get
// precise variant typing and flag stamping for codegen.
//
// TypeScript does NOT do per-candidate snapshot/rewind — PR #57421 tried
// and was abandoned. Known leakage bugs #49820, #13430 are accepted.
// Our implementation matches that design.

import { Node, NodeKind, Symbol } from "../ast/node";

// Checker-written flag bits that must be cleared before re-checking a
// context-sensitive argument in Pass 2. Matches NodeFlag bits in
// std/meta/node.ms. Keep in sync if new checker flags are added.
//   Sem (1) | FirstWrite (16) | ExtCall (512) | ExtStatic (1024) = 1553
const CHECKER_FLAG_MASK: int32 = 1553;

// Prepare a context-sensitive argument for re-checking with a fresh
// contextual type. Clears the cached nodeType and the checker-written
// flag bits so `checkExpr` will re-run the expression case. Preserves
// resolvedSym, kind, and data: once `K.A` is rewritten to Identifier
// `K_A` with a synthetic EnumMember resolvedSym, that rewrite must
// stay — re-lookup of `K_A` in the scope would fail (synthetic sym is
// not registered). Only object literals and arrow functions need this
// reset (they carry contextual-type-dependent state).
export function resetArgForRecheck(arg: Node): void {
	if (arg === null) return;
	arg.nodeType = null;
	arg.flags = arg.flags & ~CHECKER_FLAG_MASK;
}

// "Context-sensitive" in the typescript-go sense: arguments whose inferred
// type depends on the parameter type they're being checked against. Pass 2
// re-checks these with the winning candidate's expected type.
//
// ObjectLiteral: contextually typed into a specific struct variant.
// ArrowFunction: parameter types inferred from the expected function type.
// Not yet handled (Phase 6+): ArrayLiteral, FunctionExpr, tagged templates.
export function isContextSensitive(arg: Node): boolean {
	if (arg === null) return false;
	return arg.kind === NodeKind.ObjectLiteral
		|| arg.kind === NodeKind.ArrowFunction;
}

// src/checker/speculate.ms
//
// Phase 5 helpers for two-pass overload resolution. See resolveOverloadCall
// in checkExprPass.ms for the algorithm. Reference: typescript-go
// `internal/checker/checker.go:8682-8903` (`chooseOverload`).
//
// Pass 1 skips context-sensitive args entirely (object literals, arrow
// functions). Scoring treats them as unconditional Subtype matches.
//
// Pass 2 checks context-sensitive args for the first time against the
// winning candidate's parameter types — they have no prior Sem flag or
// cached nodeType, so no reset is needed.
//
// TypeScript does NOT do per-candidate snapshot/rewind — PR #57421 tried
// and was abandoned. Known leakage bugs #49820, #13430 are accepted.
// Our implementation matches that design.

import { Node, NodeKind } from "../ast/node";

// "Context-sensitive" in the typescript-go sense: arguments whose inferred
// type depends on the parameter type they're being checked against. Pass 1
// skips these; Pass 2 checks them with the winning candidate's expected type.
//
// ObjectLiteral: contextually typed into a specific struct variant.
// ArrowFunction: parameter types inferred from the expected function type.
// Not yet handled (Phase 6+): ArrayLiteral, FunctionExpr, tagged templates.
export function isContextSensitive(arg: Node): boolean {
	if (arg === null) return false;
	return arg.kind === NodeKind.ObjectLiteral
		|| arg.kind === NodeKind.ArrowFunction;
}

// src/checker/speculate.ms
//
// Phase 5 helpers for two-pass overload resolution. See resolveOverloadCall
// in checkExprPass.ms for the algorithm. Ref parity: `chooseOverload`.
//
// Pass 1 skips context-sensitive args entirely (object literals, arrow
// functions). Scoring treats them as unconditional Subtype matches.
//
// Pass 2 checks context-sensitive args for the first time against the
// winning candidate's parameter types — they have no prior Sem flag or
// cached nodeType, so no reset is needed.
//
// Per-candidate snapshot/rewind is intentionally NOT done — the alternative
// approach was tried in the reference and abandoned. Known leakage edge
// cases are accepted as part of the design.

import { ArrayLiteralData, ArrowFunctionData, Node, NodeKind, UnaryExprData } from "../ast/node";

// "Context-sensitive" arguments: their inferred type depends on the parameter
// type they're being checked against. Pass 1
// skips these; Pass 2 checks them with the winning candidate's expected type.
//
// ObjectLiteral: contextually typed into a specific struct variant.
// ArrowFunction: parameter types inferred from the expected function type.
// Not yet handled (Phase 6+): ArrayLiteral, FunctionExpr, tagged templates.
export function isContextSensitive(arg: Node): boolean {
	if (arg == null) return false;
	return arg.kind == NodeKind.ObjectLiteral
		|| (arg.kind == NodeKind.ArrowFunction && !isFullyAnnotated(arg.data as ArrowFunctionData));
}

function isFullyAnnotated(arrow: ArrowFunctionData): boolean {
	if (arrow.arrowReturnType == "" || arrow.arrowParamTypes.length < arrow.arrowParams.length) return false;
	for (const t of arrow.arrowParamTypes) {
		if (t == "") return false;
	}
	return true;
}

export function isLiteralTree(arg: Node): boolean {
	if (arg == null) return false;
	return match (arg.kind) {
		NodeKind.NumberLiteral | NodeKind.StringLiteral | NodeKind.BooleanLiteral | NodeKind.NullLiteral => true,
		NodeKind.UnaryExpr => {
			const u = arg.data as UnaryExprData;
			return (u.unaryOp == "-" || u.unaryOp == "+") && u.operand.kind == NodeKind.NumberLiteral;
		},
		NodeKind.ArrayLiteral => {
			for (const e of (arg.data as ArrayLiteralData).elements) {
				if (!isLiteralTree(e)) return false;
			}
			return true;
		},
		_ => false,
	};
}

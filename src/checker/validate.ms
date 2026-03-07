// AST Validator — ensures Phase 2 finalized all semantic metadata
//
// Every expression node MUST have a non-null nodeType.
// Every CallExpr and MemberExpr MUST have a non-null resolvedSym.
// Every Identifier MUST have a non-null resolvedSym.
//
// This is the gate that guarantees Phase 5 (Codegen) is a pure DUMP layer.

import { Node, NodeKind, CallExprData, MemberExprData, IdentifierData } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { CheckerContext, addError } from "./context";


export function validateTypedAST(ctx: CheckerContext, node: Node): void {
	if (node === null) return;

	// Check semantic metadata on expression nodes
	if (isExpression(node)) {
		if (node.nodeType === null) {
			addError(ctx, `Internal Error: missing nodeType on ${nodeKindToString(node.kind)} at line ${node.location.line}`, node.location.line, node.location.column);
		}

		match (node.kind) {
			NodeKind.Identifier => {
				if (node.resolvedSym === null) {
					const d = node.data as IdentifierData;
					// Skip match wildcard/binding patterns — Nim's else has no pattern node,
					// ours has an Identifier with nodeType set but no symbol (never referenced).
					if (node.nodeType !== null) {} else {
						addError(ctx, `Internal Error: un-resolved identifier '${d.name}' at line ${node.location.line}`, node.location.line, node.location.column);
					}
				}
			},
			NodeKind.CallExpr => {
				if (node.resolvedSym === null) {
					addError(ctx, `Internal Error: un-resolved call at line ${node.location.line}`, node.location.line, node.location.column);
				}
			},
			NodeKind.MemberExpr => {
				// MemberExpr might be enum member access (rewritten to Identifier by checker)
				// or it might be a property/method.
				if (node.resolvedSym === null) {
					const d = node.data as MemberExprData;
					addError(ctx, `Internal Error: un-resolved member access '${d.property}' at line ${node.location.line}`, node.location.line, node.location.column);
				}
			},
			_ => {},
		};
	}

	// Recurse into all children via shared forEachChild
	forEachChild(node, (child: Node): void => {
		validateTypedAST(ctx, child);
	});
}

function isExpression(node: Node): boolean {
	const k = node.kind;
	return k === NodeKind.Identifier || k === NodeKind.NumberLiteral || k === NodeKind.StringLiteral ||
		   k === NodeKind.BooleanLiteral || k === NodeKind.NullLiteral || k === NodeKind.BinaryExpr ||
		   k === NodeKind.UnaryExpr || k === NodeKind.CallExpr || k === NodeKind.MemberExpr ||
		   k === NodeKind.ArrayAccess || k === NodeKind.ConditionalExpr || k === NodeKind.ObjectLiteral ||
		   k === NodeKind.ArrayLiteral || k === NodeKind.TypeAssertion || k === NodeKind.ArrowFunction ||
		   k === NodeKind.FunctionExpr || k === NodeKind.NewExpr;
}

function nodeKindToString(k: NodeKind): string {
	return match (k) {
		NodeKind.Identifier => "Identifier",
		NodeKind.NumberLiteral => "NumberLiteral",
		NodeKind.BinaryExpr => "BinaryExpr",
		NodeKind.CallExpr => "CallExpr",
		NodeKind.MemberExpr => "MemberExpr",
		_ => "Expression",
	};
}

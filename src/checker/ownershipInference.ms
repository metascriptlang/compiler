// Ownership Inference Pass — infers SF_SINK vs SF_LENT for parameters
//
// Follows Nim's sinkparameter_inference.nim pattern.

import { Node, NodeKind, ProgramData, FunctionDeclData, VariableDeclData, BinaryExprData, CallExprData, IdentifierData, ReturnStmtData, MemberExprData, ExprStmtData, IfStmtData, WhileStmtData, BlockStmtData } from "../ast/node";
import { Type, TypeKind } from "./types";
import { Symbol, SymbolKind, hasFlag, setFlag, SF_SINK, SF_LENT, SF_GLOBAL } from "./symbol";
import { CheckerContext } from "./context";
import { check } from "std/testing";

export function inferOwnership(ctx: CheckerContext, program: Node): void {
	if (program === null || program.kind !== NodeKind.Program) return;
	const pd = program.data as ProgramData;
	for (const stmt of pd.programStmts) {
		if (stmt.kind === NodeKind.FunctionDecl) {
			inferFunctionOwnership(ctx, stmt);
		}
	}
}

function inferFunctionOwnership(ctx: CheckerContext, node: Node): void {
	const d = node.data as FunctionDeclData;
	const sym = node.resolvedSym;
	if (sym === null || d.fnBody === null) return;

	const fnType = sym.symbolType;
	if (fnType.kind !== TypeKind.Function) return;

	// Reset/initialize ownership flags for this function's parameters
	const flags: number[] = [];
	for (let i = 0; i < d.params.length; i += 1) {
		const paramName = d.params[i];
		
		// DEFAULT: Borrow (LENT) for efficiency.
		// Only promote to SINK if analysis proves ownership transfer.
		let resultFlag = SF_LENT;

		if (isParamConsumed(paramName, d.fnBody, ctx)) {
			resultFlag = SF_SINK;
		}

		// 'this' / 'self' receivers: always LENT (Nim parity)
		if (paramName === "this" || (i === 0 && paramName === "self")) {
			resultFlag = SF_LENT;
		}

		flags.push(resultFlag);
	}
	
	fnType.typeChildrenFlags = flags;
}

// AST Walker to find if a parameter is used in a "Sink" position.
function isParamConsumed(paramName: string, node: Node, ctx: CheckerContext): boolean {
	if (node === null) return false;

	return match (node.kind) {
		NodeKind.Identifier => {
			// Bare identifier access is NOT a consumption (it's just a read)
			false;
		},
		NodeKind.ReturnStmt => {
			const d = node.data as ReturnStmtData;
			isExpressionParam(d.argument, paramName);
		},
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			if (d.operator === "=") {
				// Assignment RHS: if param is assigned to a field or global, it's consumed.
				if (isExpressionParam(d.right, paramName)) {
					isSinkLValue(d.left);
				} else {
					isParamConsumed(paramName, d.left, ctx) || isParamConsumed(paramName, d.right, ctx);
				}
			} else {
				isParamConsumed(paramName, d.left, ctx) || isParamConsumed(paramName, d.right, ctx);
			}
		},
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			// If param is passed to a SINK parameter of another function, it's consumed.
			// (Default: arguments are SINK unless receiver 'this'/'self')
			let i = 0;
			while (i < d.arguments.length) {
				if (isExpressionParam(d.arguments[i], paramName)) {
					// Is this a sink position in the callee?
					if (isSinkPosition(node, i)) return true;
				}
				if (isParamConsumed(paramName, d.arguments[i], ctx)) return true;
				i += 1;
			}
			false;
		},
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			for (const s of d.statements) {
				if (isParamConsumed(paramName, s, ctx)) return true;
			}
			false;
		},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			isParamConsumed(paramName, d.condition, ctx) ||
			isParamConsumed(paramName, d.consequent, ctx) ||
			isParamConsumed(paramName, d.alternate, ctx);
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			isParamConsumed(paramName, d.whileCondition, ctx) ||
			isParamConsumed(paramName, d.whileBody, ctx);
		},
		NodeKind.ExprStmt => {
			const d = node.data as ExprStmtData;
			isParamConsumed(paramName, d.expr, ctx);
		},
		_ => false,
	};
}

// Helper: is this expression exactly the parameter we are tracking?
function isExpressionParam(node: Node, paramName: string): boolean {
	if (node === null) return false;
	if (node.kind === NodeKind.Identifier) {
		const d = node.data as IdentifierData;
		return d.name === paramName;
	}
	return false;
}

// Helper: is this LValue a position that takes ownership? (Global or Field)
function isSinkLValue(node: Node): boolean {
	if (node === null) return false;
	// Assignments to members/fields consume the value
	if (node.kind === NodeKind.MemberExpr) return true;
	// Assignments to global identifiers consume the value
	if (node.kind === NodeKind.Identifier) {
		const sym = node.resolvedSym;
		if (sym !== null && sym.symbolKind === SymbolKind.Variable) {
			// (Checking if global via flags)
			return hasFlag(sym, SF_GLOBAL);
		}
		return false;
	}
	return false;
}

// Helper: is argument index `i` of this call a SINK position?
function isSinkPosition(callNode: Node, argIdx: number): boolean {
	const sym = callNode.resolvedSym;
	if (sym === null) return true; // Conservative default: assume Sink

	const fnType = sym.symbolType;
	if (fnType === null || fnType.typeNames === null) return true;

	if (argIdx < fnType.typeNames.length) {
		const pName = fnType.typeNames[argIdx];
		// 'this' / 'self' receivers are LENT
		if (pName === "this" || (argIdx === 0 && pName === "self")) return false;
	}
	
	return true;
}

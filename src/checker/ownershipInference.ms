// Ownership Inference Pass — reference parity: sink parameter inference
//
// Only wraps params that need cleanup (non-primitive types needing RC).
// Only infers sink modifiers. Default (no wrapper) = borrow.

import { Node, NodeKind, ProgramData, FunctionDeclData, VariableDeclData, BinaryExprData, CallExprData, IdentifierData, ReturnStmtData, MemberExprData, ExprStmtData, IfStmtData, WhileStmtData, BlockStmtData, ExportDeclData, Type, TypeKind, Symbol, SymbolKind } from "../ast/node";
import { wrapSink, isSinkType, isPrimitiveKind } from "./types";
import { hasFlag, setFlag, SymbolFlag } from "./symbol";
import { CheckerContext } from "./context";


export function inferOwnership(ctx: CheckerContext, program: Node): void {
	if (program === null || program.kind !== NodeKind.Program) return;
	const pd = program.data as ProgramData;
	// Reference parity: sink inference applies to ALL procs regardless of visibility.
	// The standard reference implementation processes every procedure — no exported flag gate.
	for (const stmt of pd.programStmts) {
		let inner = stmt;
		if (inner.kind === NodeKind.ExportDecl) {
			inner = (inner.data as ExportDeclData).exportedDecl;
		}
		if (inner.kind === NodeKind.FunctionDecl) {
			inferFunctionOwnership(ctx, inner);
		}
	}
}

function inferFunctionOwnership(ctx: CheckerContext, node: Node): void {
	const d = node.data as FunctionDeclData;
	const sym = node.resolvedSym;
	if (sym === null || d.fnBody === null) return;

	const fnType = sym.symbolType;
	if (fnType.kind !== TypeKind.Function) return;

	// Reference parity (sink parameter inference):
	// 1. Only wrap params that need destruction (non-primitive, non-enum)
	// 2. Only wrap to sink — never lent. Default = no wrapper = borrow.
	// 3. Skip params already wrapped, 'this'/'self', and forwarded procs
	for (let i = 0; i < d.params.length; i += 1) {
		if (i >= fnType.typeChildren.length) break;
		const paramType = fnType.typeChildren[i];
		if (paramType === null) continue;
		// Reference: parameter type kind must not be a modifier already
		if (isSinkType(paramType)) continue;
		// Reference: only RC types get wrapped.
		// isPrimitiveKind covers: Number, Boolean, Void, Null, Int*, Uint*, Float*, Enum, Char, CString, Never, Unknown, Error
		// Also skip GenericParam and Borrow — never real runtime param types
		if (isPrimitiveKind(paramType.kind)) continue;
		if (paramType.kind === TypeKind.GenericParam || paramType.kind === TypeKind.Borrow) continue;

		const paramName = d.params[i];
		// 'this' / 'self' receivers: never sink (reference parity)
		if (paramName === "this" || (i === 0 && paramName === "self")) continue;

		if (isParamConsumed(paramName, d.fnBody, ctx)) {
			fnType.typeChildren[i] = wrapSink(paramType);
		}
		// Reference: no else — non-sink params stay unwrapped (implicit borrow)
	}
}

// AST Walker to find if a parameter is used in a "Sink" position.
function isParamConsumed(paramName: string, node: Node, ctx: CheckerContext): boolean {
	if (node === null) return false;

	return match (node.kind) {
		NodeKind.Identifier => {
			// Bare identifier access is NOT a consumption (it's just a read)
			return false;
		},
		NodeKind.ReturnStmt => {
			const d = node.data as ReturnStmtData;
			return isExpressionParam(d.argument, paramName);
		},
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			if (d.operator === "=") {
				// Assignment RHS: if param is assigned to a field or global, it's consumed.
				if (isExpressionParam(d.right, paramName)) {
					return isSinkLValue(d.left);
				} else {
					return isParamConsumed(paramName, d.left, ctx) || isParamConsumed(paramName, d.right, ctx);
				}
			} else {
				return isParamConsumed(paramName, d.left, ctx) || isParamConsumed(paramName, d.right, ctx);
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
			return false;
		},
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			for (const s of d.statements) {
				if (isParamConsumed(paramName, s, ctx)) return true;
			}
			return false;
		},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			return isParamConsumed(paramName, d.condition, ctx) ||
			isParamConsumed(paramName, d.consequent, ctx) ||
			isParamConsumed(paramName, d.alternate, ctx);
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			return isParamConsumed(paramName, d.whileCondition, ctx) ||
			isParamConsumed(paramName, d.whileBody, ctx);
		},
		NodeKind.ExprStmt => {
			const d = node.data as ExprStmtData;
			return isParamConsumed(paramName, d.expr, ctx);
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
			return hasFlag(sym, SymbolFlag.Global);
		}
		return false;
	}
	return false;
}

// Helper: is argument index `i` of this call a SINK position?
// Reference parity: check callee's actual type signature for sink modifiers.
// Only return true if the callee's param at that index is ALREADY wrapped in Sink.
// Conservative default: assume borrow (return false), not sink.
// Rationale: assuming sink causes the caller's param to be wrapped in Sink too,
// which cascades through all call chains and causes incorrect DRC (premature wasMoved).
function isSinkPosition(callNode: Node, argIdx: number): boolean {
	const sym = callNode.resolvedSym;
	if (sym === null) return false;

	const fnType = sym.symbolType;
	if (fnType === null || fnType.kind !== TypeKind.Function) return false;

	// Check if param name is 'this'/'self' — always lent
	if (argIdx < fnType.typeNames.length) {
		const pName = fnType.typeNames[argIdx];
		if (pName === "this" || (argIdx === 0 && pName === "self")) return false;
	}

	// Check if the callee's param type is already marked sink
	if (argIdx < fnType.typeChildren.length) {
		return isSinkType(fnType.typeChildren[argIdx]);
	}

	return false;
}

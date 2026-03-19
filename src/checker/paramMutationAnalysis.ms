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
	ArrayAccessData, IdentifierData, CallExprData, BlockStmtData,
	IfStmtData, WhileStmtData, ForStmtData, ForOfStmtData,
	SwitchStmtData, SwitchCaseData, TryCatchStmtData, ReturnStmtData,
	ExprStmtData, VariableDeclData, UpdateExprData, UnaryExprData,
	ExportDeclData, DoWhileStmtData,
} from "../ast/node";
import { CheckerContext } from "./context";

// ===== Public Entry Point =====

export function analyzeParamMutations(ctx: CheckerContext, program: Node): void {
	if (program === null || program.kind !== NodeKind.Program) return;
	const pd = program.data as ProgramData;
	for (const stmt of pd.programStmts) {
		let inner = stmt;
		if (inner.kind === NodeKind.ExportDecl) {
			inner = (inner.data as ExportDeclData).exportedDecl;
		}
		if (inner.kind === NodeKind.FunctionDecl) {
			analyzeFunctionParams(inner);
		}
	}
}

function analyzeFunctionParams(node: Node): void {
	const d = node.data as FunctionDeclData;
	const sym = node.resolvedSym;
	if (sym === null || d.fnBody === null) return;

	// Recurse into nested functions first
	scanNestedFunctions(d.fnBody);

	if (d.params.length === 0) return;

	let bits: int32 = 0;
	let i: int32 = 0;
	while (i < d.params.length && i < 31) {
		if (scanForMutation(d.fnBody, d.params[i])) {
			bits = bits | (1 << i);
		}
		i = i + 1;
	}
	sym.mutatedParams = bits;
}

// Find and analyze nested function declarations within a body
function scanNestedFunctions(node: Node): void {
	if (node === null) return;
	if (node.kind === NodeKind.FunctionDecl) {
		analyzeFunctionParams(node);
		return;
	}
	if (node.kind === NodeKind.BlockStmt) {
		const d = node.data as BlockStmtData;
		for (const stmt of d.statements) { scanNestedFunctions(stmt); }
		return;
	}
	if (node.kind === NodeKind.ExportDecl) {
		scanNestedFunctions((node.data as ExportDeclData).exportedDecl);
		return;
	}
	if (node.kind === NodeKind.IfStmt) {
		const d = node.data as IfStmtData;
		scanNestedFunctions(d.consequent);
		scanNestedFunctions(d.alternate);
	}
}

// ===== Mutation Detection =====

// Get the root identifier name from an lvalue (e.g., obj.field[i] → "obj")
function getRootName(node: Node): string {
	if (node === null) return "";
	return match (node.kind) {
		NodeKind.Identifier => (node.data as IdentifierData).name,
		NodeKind.MemberExpr => getRootName((node.data as MemberExprData).object),
		NodeKind.ArrayAccess => getRootName((node.data as ArrayAccessData).array),
		_ => "",
	};
}

// Returns true if paramName is mutated anywhere in the subtree
function scanForMutation(node: Node, paramName: string): boolean {
	if (node === null) return false;

	return match (node.kind) {
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			if (d.operator === "=" || d.operator === "+=" || d.operator === "-="
				|| d.operator === "*=" || d.operator === "/=" || d.operator === "%=") {
				if (getRootName(d.left) === paramName) return true;
			}
			return scanForMutation(d.left, paramName) || scanForMutation(d.right, paramName);
		},

		NodeKind.UpdateExpr => {
			const d = node.data as UpdateExprData;
			if (getRootName(d.updateArg) === paramName) return true;
			return false;
		},

		NodeKind.HiddenAddr => {
			const inner = (node.data as { expr: Node }).expr;
			if (getRootName(inner) === paramName) return true;
			return scanForMutation(inner, paramName);
		},

		// Skip nested function bodies — own scope, own params
		NodeKind.FunctionDecl => false,

		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			let i = 0;
			while (i < d.statements.length) {
				if (scanForMutation(d.statements[i], paramName)) return true;
				i = i + 1;
			}
			return false;
		},
		NodeKind.ExprStmt => scanForMutation((node.data as ExprStmtData).expr, paramName),
		NodeKind.ReturnStmt => scanForMutation((node.data as ReturnStmtData).argument, paramName),
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			return scanForMutation(d.condition, paramName)
				|| scanForMutation(d.consequent, paramName)
				|| scanForMutation(d.alternate, paramName);
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			return scanForMutation(d.whileCondition, paramName) || scanForMutation(d.whileBody, paramName);
		},
		NodeKind.DoWhileStmt => {
			const d = node.data as DoWhileStmtData;
			return scanForMutation(d.doCondition, paramName) || scanForMutation(d.doBody, paramName);
		},
		NodeKind.ForStmt => {
			const d = node.data as ForStmtData;
			return scanForMutation(d.forInit, paramName)
				|| scanForMutation(d.forCondition, paramName)
				|| scanForMutation(d.forUpdate, paramName)
				|| scanForMutation(d.forBody, paramName);
		},
		NodeKind.ForOfStmt => {
			const d = node.data as ForOfStmtData;
			return scanForMutation(d.forOfIterable, paramName) || scanForMutation(d.forOfBody, paramName);
		},
		NodeKind.SwitchStmt => {
			const d = node.data as SwitchStmtData;
			if (scanForMutation(d.switchDisc, paramName)) return true;
			let i = 0;
			while (i < d.switchCases.length) {
				if (scanForMutation(d.switchCases[i], paramName)) return true;
				i = i + 1;
			}
			return false;
		},
		NodeKind.SwitchCase => {
			const d = node.data as SwitchCaseData;
			let i = 0;
			while (i < d.caseTests.length) {
				if (scanForMutation(d.caseTests[i], paramName)) return true;
				i = i + 1;
			}
			let j = 0;
			while (j < d.caseStmts.length) {
				if (scanForMutation(d.caseStmts[j], paramName)) return true;
				j = j + 1;
			}
			return false;
		},
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			return scanForMutation(d.tryBody, paramName)
				|| scanForMutation(d.catchBody, paramName)
				|| scanForMutation(d.finallyBody, paramName);
		},
		NodeKind.VariableDecl => scanForMutation((node.data as VariableDeclData).initializer, paramName),
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			if (scanForMutation(d.callee, paramName)) return true;
			let i = 0;
			while (i < d.arguments.length) {
				if (scanForMutation(d.arguments[i], paramName)) return true;
				i = i + 1;
			}
			return false;
		},
		NodeKind.MemberExpr => scanForMutation((node.data as MemberExprData).object, paramName),
		NodeKind.ArrayAccess => {
			const d = node.data as ArrayAccessData;
			return scanForMutation(d.array, paramName) || scanForMutation(d.index, paramName);
		},
		NodeKind.UnaryExpr => scanForMutation((node.data as UnaryExprData).operand, paramName),
		_ => false,
	};
}

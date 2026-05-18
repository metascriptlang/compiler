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
	Node, NodeKind, SourceLocation, makeLoc,
	ProgramData, FunctionDeclData, BinaryExprData, MemberExprData,
	ArrayAccessData, IdentifierData, CallExprData, BlockStmtData,
	IfStmtData, WhileStmtData, ForStmtData, ForOfStmtData,
	SwitchStmtData, SwitchCaseData, TryCatchStmtData, ReturnStmtData,
	ExprStmtData, VariableDeclData, UpdateExprData, UnaryExprData,
	ExportDeclData, DoWhileStmtData,
} from "../ast/node";
import { CheckerContext, addError } from "./context";
import { splitTopLevel, parseIntStr } from "../utils/string";

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
			analyzeFunctionParams(inner, ctx);
		}
	}
}

function analyzeFunctionParams(node: Node, ctx: CheckerContext): void {
	const d = node.data as FunctionDeclData;
	const sym = node.resolvedSym;
	if (sym === null || d.fnBody === null) return;

	// Recurse into nested functions first
	scanNestedFunctions(d.fnBody, ctx);

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

	// Cross-check: readonly params must not be mutated
	if (bits !== 0 && d.fnFlags !== "" && d.fnFlags.indexOf("rdonly:") >= 0) {
		const flagParts = splitTopLevel(d.fnFlags, "|");
		for (const fp of flagParts) {
			const trimFp = fp.trim();
			if (trimFp.length > 7 && trimFp.slice(0, 7) === "rdonly:") {
				const idxStr = trimFp.slice(7, trimFp.length);
				const idxParts = splitTopLevel(idxStr, ",");
				for (const ip of idxParts) {
					const idx = parseIntStr(ip.trim());
					if (idx >= 0 && idx < d.params.length && (bits & (1 << (idx as int32))) !== 0) {
						const mutLoc = findMutationLocation(d.fnBody, d.params[idx]);
						addError(ctx, `cannot mutate readonly parameter '${d.params[idx]}'`, mutLoc.line, mutLoc.column);
					}
				}
			}
		}
	}
}

// Find and analyze nested function declarations within a body
function scanNestedFunctions(node: Node, ctx: CheckerContext): void {
	if (node === null) return;
	match (node.kind) {
		NodeKind.FunctionDecl => { analyzeFunctionParams(node, ctx); },
		NodeKind.BlockStmt => {
			for (const stmt of (node.data as BlockStmtData).statements) { scanNestedFunctions(stmt, ctx); }
		},
		NodeKind.ExportDecl => { scanNestedFunctions((node.data as ExportDeclData).exportedDecl, ctx); },
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			scanNestedFunctions(d.consequent, ctx);
			scanNestedFunctions(d.alternate, ctx);
		},
		_ => {},
	};
}

// ===== Mutation Detection =====

// Get the root identifier name from an lvalue (e.g., obj.field[i] → "obj")
function getRootName(node: Node): string {
	if (node === null) return "";
	return match (node.kind) {
		NodeKind.Identifier => (node.data as IdentifierData).name,
		NodeKind.MemberExpr => getRootName((node.data as MemberExprData).object),
		NodeKind.ArrayAccess => getRootName((node.data as ArrayAccessData).array),
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => getRootName((node.data as { expr: Node }).expr),
		_ => "",
	};
}

// Find the source location of the first mutation of paramName in the subtree.
// Used for readonly error reporting — points to the actual mutation site.
function findMutationLocation(node: Node, paramName: string): SourceLocation {
	if (node === null) return makeLoc(0, 0);
	if (node.kind === NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		if (d.operator === "=" || d.operator === "+=" || d.operator === "-="
			|| d.operator === "*=" || d.operator === "/=" || d.operator === "%=") {
			if (getRootName(d.left) === paramName) return node.location;
		}
	}
	if (node.kind === NodeKind.UpdateExpr) {
		if (getRootName((node.data as UpdateExprData).updateArg) === paramName) return node.location;
	}
	if (node.kind === NodeKind.HiddenAddr) {
		if (getRootName((node.data as { expr: Node }).expr) === paramName) return node.location;
	}
	if (node.kind === NodeKind.FunctionDecl) return makeLoc(0, 0);
	if (node.kind === NodeKind.BlockStmt) {
		for (const stmt of (node.data as BlockStmtData).statements) {
			const loc = findMutationLocation(stmt, paramName);
			if (loc.line > 0) return loc;
		}
	}
	if (node.kind === NodeKind.ExprStmt) return findMutationLocation((node.data as ExprStmtData).expr, paramName);
	if (node.kind === NodeKind.IfStmt) {
		const d = node.data as IfStmtData;
		let loc = findMutationLocation(d.condition, paramName);
		if (loc.line > 0) return loc;
		loc = findMutationLocation(d.consequent, paramName);
		if (loc.line > 0) return loc;
		return findMutationLocation(d.alternate, paramName);
	}
	if (node.kind === NodeKind.WhileStmt) {
		const d = node.data as WhileStmtData;
		let loc = findMutationLocation(d.whileCondition, paramName);
		if (loc.line > 0) return loc;
		return findMutationLocation(d.whileBody, paramName);
	}
	if (node.kind === NodeKind.CallExpr) {
		const d = node.data as CallExprData;
		for (const arg of d.arguments) {
			const loc = findMutationLocation(arg, paramName);
			if (loc.line > 0) return loc;
		}
	}
	return makeLoc(0, 0);
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
			for (const stmt of d.statements) {
				if (scanForMutation(stmt, paramName)) return true;
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
			for (const c of d.switchCases) {
				if (scanForMutation(c, paramName)) return true;
			}
			return false;
		},
		NodeKind.SwitchCase => {
			const d = node.data as SwitchCaseData;
			for (const t of d.caseTests) {
				if (scanForMutation(t, paramName)) return true;
			}
			for (const s of d.caseStmts) {
				if (scanForMutation(s, paramName)) return true;
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
			for (const arg of d.arguments) {
				if (scanForMutation(arg, paramName)) return true;
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

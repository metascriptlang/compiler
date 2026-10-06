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
	ArrayAccessData, CallExprData, BlockStmtData,
	IfStmtData, WhileStmtData, ForStmtData, ForOfStmtData,
	SwitchStmtData, SwitchCaseData, TryCatchStmtData, ReturnStmtData,
	ExprStmtData, VariableDeclData, UpdateExprData, UnaryExprData,
	ExportDeclData, DoWhileStmtData,
} from "../ast/node";
import { Type, TypeKind, Symbol } from "../ast/node";
import { CheckerContext, addError, isGenericFn } from "./context";
import { splitTopLevel, parseIntStr } from "../utils/string";

// ===== Public Entry Point =====

export function isMutatingArrayMethod(method: string): boolean {
	return method == "push" || method == "pop" || method == "shift" || method == "unshift"
		|| method == "splice" || method == "reverse" || method == "sort" || method == "fill"
		|| method == "copyWithin" || method == "append" || method == "setLength"
		|| method == "setSlice" || method == "stripInPlace" || method == "setLen";
}

export function analyzeParamMutations(ctx: CheckerContext, program: Node): void {
	if (program == null || program.kind != NodeKind.Program) return;
	const pd = program.data as ProgramData;
	for (const stmt of pd.programStmts) {
		let inner = stmt;
		if (inner.kind == NodeKind.ExportDecl) {
			inner = (inner.data as ExportDeclData).exportedDecl;
		}
		if (inner.kind == NodeKind.FunctionDecl) {
			analyzeFunctionParams(inner, ctx);
		}
	}
}

function analyzeFunctionParams(node: Node, ctx: CheckerContext): void {
	const d = node.data as FunctionDeclData;
	const sym = node.resolvedSym;
	if (sym == null || d.fnBody == null) return;
	if (d.fnFlags.indexOf("overload", 0) >= 0 || d.fnFlags.indexOf("extern", 0) >= 0) return;

	// Recurse into nested functions first
	scanNestedFunctions(d.fnBody, ctx);

	if (d.params.length == 0) return;
	const paramSyms = node.paramSyms;
	if (paramSyms == null || paramSyms.length != d.params.length) {
		if (isGenericFn(d.fnFlags)) return;
		addError(ctx, `internal: function '${d.fnName}' has no checked parameter symbols for mutation analysis`, node.location.line, node.location.column);
		return;
	}

	let bits: int32 = 0;
	let i: int32 = 0;
	while (i < d.params.length && i < 31) {
		if (scanForMutation(d.fnBody, paramSyms[i])) {
			bits = bits | (1 << i);
		}
		i = i + 1;
	}
	sym.mutatedParams = bits;

	// Cross-check: readonly params must not be mutated
	if (bits != 0 && d.fnFlags != "" && d.fnFlags.indexOf("rdonly:") >= 0) {
		const flagParts = splitTopLevel(d.fnFlags, "|");
		for (const fp of flagParts) {
			const trimFp = fp.trim();
			if (trimFp.length > 7 && trimFp.slice(0, 7) == "rdonly:") {
				const idxStr = trimFp.slice(7, trimFp.length);
				const idxParts = splitTopLevel(idxStr, ",");
				for (const ip of idxParts) {
					const idx = parseIntStr(ip.trim());
					if (idx >= 0 && idx < d.params.length && (bits & (1 << (idx as int32))) != 0) {
						const mutLoc = findMutationLocation(d.fnBody, paramSyms[idx]);
						addError(ctx, `cannot mutate readonly parameter '${d.params[idx]}'`, mutLoc.line, mutLoc.column);
					}
				}
			}
		}
	}
}

// Find and analyze nested function declarations within a body
function scanNestedFunctions(node: Node, ctx: CheckerContext): void {
	if (node == null) return;
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

// Value aggregates are the kinds whose params are C by-pointer views without RC:
// interior writes would reach the caller's storage. Interfaces arrive as Ref
// (collectStructLike wraps them), Span is a view by design, Union covers Ref|null.
export function isValueAggregateParam(t: Type | null): boolean {
	if (t == null) return false;
	return match (t.kind) {
		TypeKind.Array | TypeKind.SizedArray | TypeKind.Tuple | TypeKind.Struct => true,
		TypeKind.GenericInstance => t.typeExtra != null && t.typeExtra.kind == TypeKind.Struct,
		_ => false,
	};
}

// ===== Mutation Detection =====

function getRootSym(node: Node | null): Symbol | null {
	if (node == null) return null;
	return match (node.kind) {
		NodeKind.Identifier => node.resolvedSym,
		NodeKind.MemberExpr => getRootSym((node.data as MemberExprData).object),
		NodeKind.ArrayAccess => getRootSym((node.data as ArrayAccessData).array),
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => getRootSym((node.data as { expr: Node }).expr),
		_ => null,
	};
}

function findMutationLocation(node: Node | null, paramSym: Symbol): SourceLocation {
	if (node == null) return makeLoc(0, 0);
	if (node.kind == NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		if (d.operator == "=" || d.operator == "+=" || d.operator == "-="
			|| d.operator == "*=" || d.operator == "/=" || d.operator == "%="
			|| d.operator == "&=" || d.operator == "|=" || d.operator == "^="
			|| d.operator == "<<=" || d.operator == ">>=" || d.operator == ">>>=") {
			if (getRootSym(d.left) == paramSym) return node.location;
		}
	}
	if (node.kind == NodeKind.UpdateExpr) {
		const ua = (node.data as UpdateExprData).updateArg;
		if (getRootSym(ua) == paramSym) return node.location;
	}
	if (node.kind == NodeKind.HiddenAddr) {
		if (getRootSym((node.data as { expr: Node }).expr) == paramSym) return node.location;
	}
	if (node.kind == NodeKind.FunctionDecl) return makeLoc(0, 0);
	if (node.kind == NodeKind.BlockStmt) {
		for (const stmt of (node.data as BlockStmtData).statements) {
			const loc = findMutationLocation(stmt, paramSym);
			if (loc.line > 0) return loc;
		}
	}
	if (node.kind == NodeKind.ExprStmt) return findMutationLocation((node.data as ExprStmtData).expr, paramSym);
	if (node.kind == NodeKind.IfStmt) {
		const d = node.data as IfStmtData;
		let loc = findMutationLocation(d.condition, paramSym);
		if (loc.line > 0) return loc;
		loc = findMutationLocation(d.consequent, paramSym);
		if (loc.line > 0) return loc;
		return findMutationLocation(d.alternate, paramSym);
	}
	if (node.kind == NodeKind.WhileStmt) {
		const d = node.data as WhileStmtData;
		let loc = findMutationLocation(d.whileCondition, paramSym);
		if (loc.line > 0) return loc;
		return findMutationLocation(d.whileBody, paramSym);
	}
	if (node.kind == NodeKind.CallExpr) {
		const d = node.data as CallExprData;
		const cloc = findMutationLocation(d.callee, paramSym);
		if (cloc.line > 0) return cloc;
		for (const arg of d.arguments) {
			const loc = findMutationLocation(arg, paramSym);
			if (loc.line > 0) return loc;
		}
	}
	if (node.kind == NodeKind.DoWhileStmt) {
		const d = node.data as DoWhileStmtData;
		const loc = findMutationLocation(d.doCondition, paramSym);
		if (loc.line > 0) return loc;
		return findMutationLocation(d.doBody, paramSym);
	}
	if (node.kind == NodeKind.ForStmt) {
		const d = node.data as ForStmtData;
		let loc = findMutationLocation(d.forInit, paramSym);
		if (loc.line > 0) return loc;
		loc = findMutationLocation(d.forCondition, paramSym);
		if (loc.line > 0) return loc;
		loc = findMutationLocation(d.forUpdate, paramSym);
		if (loc.line > 0) return loc;
		return findMutationLocation(d.forBody, paramSym);
	}
	if (node.kind == NodeKind.ForOfStmt) {
		const d = node.data as ForOfStmtData;
		const loc = findMutationLocation(d.forOfIterable, paramSym);
		if (loc.line > 0) return loc;
		return findMutationLocation(d.forOfBody, paramSym);
	}
	if (node.kind == NodeKind.SwitchStmt) {
		const d = node.data as SwitchStmtData;
		const loc = findMutationLocation(d.switchDisc, paramSym);
		if (loc.line > 0) return loc;
		for (const c of d.switchCases) {
			const cl = findMutationLocation(c, paramSym);
			if (cl.line > 0) return cl;
		}
	}
	if (node.kind == NodeKind.SwitchCase) {
		const d = node.data as SwitchCaseData;
		for (const t of d.caseTests) {
			const loc = findMutationLocation(t, paramSym);
			if (loc.line > 0) return loc;
		}
		for (const s of d.caseStmts) {
			const loc = findMutationLocation(s, paramSym);
			if (loc.line > 0) return loc;
		}
	}
	if (node.kind == NodeKind.TryCatchStmt) {
		const d = node.data as TryCatchStmtData;
		let loc = findMutationLocation(d.tryBody, paramSym);
		if (loc.line > 0) return loc;
		loc = findMutationLocation(d.catchBody, paramSym);
		if (loc.line > 0) return loc;
		return findMutationLocation(d.finallyBody, paramSym);
	}
	if (node.kind == NodeKind.ReturnStmt) return findMutationLocation((node.data as ReturnStmtData).argument, paramSym);
	if (node.kind == NodeKind.VariableDecl) return findMutationLocation((node.data as VariableDeclData).initializer, paramSym);
	if (node.kind == NodeKind.MemberExpr) return findMutationLocation((node.data as MemberExprData).object, paramSym);
	if (node.kind == NodeKind.ArrayAccess) {
		const d = node.data as ArrayAccessData;
		const loc = findMutationLocation(d.array, paramSym);
		if (loc.line > 0) return loc;
		return findMutationLocation(d.index, paramSym);
	}
	if (node.kind == NodeKind.UnaryExpr) return findMutationLocation((node.data as UnaryExprData).operand, paramSym);
	return makeLoc(0, 0);
}

function scanForMutation(node: Node | null, paramSym: Symbol): boolean {
	if (node == null) return false;

	return match (node.kind) {
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			if (d.operator == "=" || d.operator == "+=" || d.operator == "-="
				|| d.operator == "*=" || d.operator == "/=" || d.operator == "%="
			|| d.operator == "&=" || d.operator == "|=" || d.operator == "^="
			|| d.operator == "<<=" || d.operator == ">>=" || d.operator == ">>>=") {
				if (getRootSym(d.left) == paramSym) return true;
			}
			return scanForMutation(d.left, paramSym) || scanForMutation(d.right, paramSym);
		},

		NodeKind.UpdateExpr => {
			const d = node.data as UpdateExprData;
			if (getRootSym(d.updateArg) == paramSym) return true;
			return false;
		},

		NodeKind.HiddenAddr => {
			const inner = (node.data as { expr: Node }).expr;
			if (getRootSym(inner) == paramSym) return true;
			return scanForMutation(inner, paramSym);
		},

		// Skip nested function bodies — own scope, own params
		NodeKind.FunctionDecl => false,

		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			for (const stmt of d.statements) {
				if (scanForMutation(stmt, paramSym)) return true;
			}
			return false;
		},
		NodeKind.ExprStmt => scanForMutation((node.data as ExprStmtData).expr, paramSym),
		NodeKind.ReturnStmt => scanForMutation((node.data as ReturnStmtData).argument, paramSym),
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			return scanForMutation(d.condition, paramSym)
				|| scanForMutation(d.consequent, paramSym)
				|| scanForMutation(d.alternate, paramSym);
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			return scanForMutation(d.whileCondition, paramSym) || scanForMutation(d.whileBody, paramSym);
		},
		NodeKind.DoWhileStmt => {
			const d = node.data as DoWhileStmtData;
			return scanForMutation(d.doCondition, paramSym) || scanForMutation(d.doBody, paramSym);
		},
		NodeKind.ForStmt => {
			const d = node.data as ForStmtData;
			return scanForMutation(d.forInit, paramSym)
				|| scanForMutation(d.forCondition, paramSym)
				|| scanForMutation(d.forUpdate, paramSym)
				|| scanForMutation(d.forBody, paramSym);
		},
		NodeKind.ForOfStmt => {
			const d = node.data as ForOfStmtData;
			return scanForMutation(d.forOfIterable, paramSym) || scanForMutation(d.forOfBody, paramSym);
		},
		NodeKind.SwitchStmt => {
			const d = node.data as SwitchStmtData;
			if (scanForMutation(d.switchDisc, paramSym)) return true;
			for (const c of d.switchCases) {
				if (scanForMutation(c, paramSym)) return true;
			}
			return false;
		},
		NodeKind.SwitchCase => {
			const d = node.data as SwitchCaseData;
			for (const t of d.caseTests) {
				if (scanForMutation(t, paramSym)) return true;
			}
			for (const s of d.caseStmts) {
				if (scanForMutation(s, paramSym)) return true;
			}
			return false;
		},
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			return scanForMutation(d.tryBody, paramSym)
				|| scanForMutation(d.catchBody, paramSym)
				|| scanForMutation(d.finallyBody, paramSym);
		},
		NodeKind.VariableDecl => scanForMutation((node.data as VariableDeclData).initializer, paramSym),
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			if (scanForMutation(d.callee, paramSym)) return true;
			for (const arg of d.arguments) {
				if (scanForMutation(arg, paramSym)) return true;
			}
			return false;
		},
		NodeKind.MemberExpr => scanForMutation((node.data as MemberExprData).object, paramSym),
		NodeKind.ArrayAccess => {
			const d = node.data as ArrayAccessData;
			return scanForMutation(d.array, paramSym) || scanForMutation(d.index, paramSym);
		},
		NodeKind.UnaryExpr => scanForMutation((node.data as UnaryExprData).operand, paramSym),
		_ => false,
	};
}

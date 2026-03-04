// Closure Call Marker — identifies CallExpr nodes where callee is a closure
// Follows reference closure_call_marker.zig
//
// In C, closure calls use a different calling convention (ms_closure.fn + env pointer)
// vs direct function calls. This pass collects all FunctionDecl names so C codegen
// can distinguish direct calls from closure calls.
//
// Algorithm:
// 1. Pre-pass: collect all FunctionDecl names into ctx.fnDeclNames
// 2. C codegen checks: if callee identifier is NOT in fnDeclNames, use closure protocol

import {
	Node, NodeKind,
	ProgramData, FunctionDeclData, BlockStmtData,
	CallExprData, IdentifierData, ExprStmtData,
	VariableDeclData, IfStmtData, WhileStmtData,
	ReturnStmtData, TryCatchStmtData, DoWhileStmtData,
	SwitchStmtData, SwitchCaseData, ExportDeclData,
	DecoratedDeclData, ImportDeclData,
} from "../../ast/node";
import { TypeKind, CallingConvention } from "../../checker/types";
import { TransformContext, nameSetContains } from "../context";
import { check } from "std/testing";
import { stmtCountAfter, firstStmtKindAfter } from "../testUtil";

// ===== Main Entry Point =====

export function markClosureCalls(program: Node, ctx: TransformContext): Node {
	collectFunctionNames(program, ctx);
	markDirectCalls(program, ctx);
	return program;
}

// Recursively collect all FunctionDecl and ImportDecl names in the program
function collectFunctionNames(node: Node, ctx: TransformContext): void {
	if (node === null) return;
	if (node.kind === NodeKind.FunctionDecl) {
		const d = node.data as FunctionDeclData;
		if (d.fnName !== "") {
			ctx.fnDeclNames.push(d.fnName);
		}
		collectFunctionNames(d.fnBody, ctx);
	} else if (node.kind === NodeKind.Program) {
		const pd = node.data as ProgramData;
		let i = 0;
		while (i < pd.programStmts.length) {
			collectFunctionNames(pd.programStmts[i], ctx);
			i = i + 1;
		}
	} else if (node.kind === NodeKind.BlockStmt) {
		const bd = node.data as BlockStmtData;
		let i = 0;
		while (i < bd.statements.length) {
			collectFunctionNames(bd.statements[i], ctx);
			i = i + 1;
		}
	} else if (node.kind === NodeKind.ImportDecl) {
		const d = node.data as ImportDeclData;
		let i = 0;
		while (i < d.importNames.length) {
			ctx.fnDeclNames.push(d.importNames[i]);
			i = i + 1;
		}
	} else if (node.kind === NodeKind.ExportDecl) {
		const d = node.data as ExportDeclData;
		collectFunctionNames(d.exportedDecl, ctx);
	} else if (node.kind === NodeKind.DecoratedDecl) {
		const d = node.data as DecoratedDeclData;
		collectFunctionNames(d.decoratedNode, ctx);
	}
}

// Walk AST and set isDirectCall on every CallExpr whose callee is a known function name
// or a MemberExpr (always direct — method/extension call)
function markDirectCalls(node: Node, ctx: TransformContext): void {
	if (node === null) return;
	match (node.kind) {
		NodeKind.CallExpr => {
			const cd = node.data as CallExprData;
			// Default is true (set by parser). Mark as closure call only when
			// callee is an identifier NOT in the known function names set.
			if (cd.callee.kind === NodeKind.Identifier) {
				const id = cd.callee.data as IdentifierData;
				if (!nameSetContains(ctx.fnDeclNames, id.name)) {
					cd.isDirectCall = false;
					// Nim parity: set callConv on callee type (ccClosure)
					if (cd.callee.nodeType !== null && cd.callee.nodeType.kind === TypeKind.Function) {
						cd.callee.nodeType.callConv = CallingConvention.CcClosure;
					}
				}
			}
			// Walk callee and arguments
			markDirectCalls(cd.callee, ctx);
			let ai = 0;
			while (ai < cd.arguments.length) {
				markDirectCalls(cd.arguments[ai], ctx);
				ai = ai + 1;
			}
		},
		NodeKind.Program => {
			const pd = node.data as ProgramData;
			let i = 0;
			while (i < pd.programStmts.length) {
				markDirectCalls(pd.programStmts[i], ctx);
				i = i + 1;
			}
		},
		NodeKind.BlockStmt => {
			const bd = node.data as BlockStmtData;
			let i = 0;
			while (i < bd.statements.length) {
				markDirectCalls(bd.statements[i], ctx);
				i = i + 1;
			}
		},
		NodeKind.FunctionDecl => {
			const fd = node.data as FunctionDeclData;
			markDirectCalls(fd.fnBody, ctx);
		},
		NodeKind.ExprStmt => {
			const ed = node.data as ExprStmtData;
			markDirectCalls(ed.expr, ctx);
		},
		NodeKind.VariableDecl => {
			const vd = node.data as VariableDeclData;
			markDirectCalls(vd.initializer, ctx);
		},
		NodeKind.ReturnStmt => {
			const rd = node.data as ReturnStmtData;
			markDirectCalls(rd.argument, ctx);
		},
		NodeKind.IfStmt => {
			const id = node.data as IfStmtData;
			markDirectCalls(id.condition, ctx);
			markDirectCalls(id.consequent, ctx);
			markDirectCalls(id.alternate, ctx);
		},
		NodeKind.WhileStmt => {
			const wd = node.data as WhileStmtData;
			markDirectCalls(wd.whileCondition, ctx);
			markDirectCalls(wd.whileBody, ctx);
		},
		NodeKind.TryCatchStmt => {
			const td = node.data as TryCatchStmtData;
			markDirectCalls(td.tryBody, ctx);
			markDirectCalls(td.catchBody, ctx);
			markDirectCalls(td.finallyBody, ctx);
		},
		NodeKind.DoWhileStmt => {
			const dd = node.data as DoWhileStmtData;
			markDirectCalls(dd.doBody, ctx);
			markDirectCalls(dd.doCondition, ctx);
		},
		NodeKind.SwitchStmt => {
			const sd = node.data as SwitchStmtData;
			markDirectCalls(sd.switchDisc, ctx);
			let si = 0;
			while (si < sd.switchCases.length) {
				markDirectCalls(sd.switchCases[si], ctx);
				si = si + 1;
			}
		},
		NodeKind.SwitchCase => {
			const sc = node.data as SwitchCaseData;
			let ci = 0;
			while (ci < sc.caseStmts.length) {
				markDirectCalls(sc.caseStmts[ci], ctx);
				ci = ci + 1;
			}
		},
		NodeKind.ExportDecl => {
			const xd = node.data as ExportDeclData;
			markDirectCalls(xd.exportedDecl, ctx);
		},
		NodeKind.DecoratedDecl => {
			const dd = node.data as DecoratedDeclData;
			markDirectCalls(dd.decoratedNode, ctx);
		},
		_ => {},
	};
}

// ===== Tests =====
test "stmt passthrough" { check(stmtCountAfter("const x = 1;", markClosureCalls) === 1); }

test "function stays FunctionDecl" { check(firstStmtKindAfter("function foo() {}", markClosureCalls) === NodeKind.FunctionDecl); }

test "while unchanged" { check(firstStmtKindAfter("while (true) {}", markClosureCalls) === NodeKind.WhileStmt); }

test "preserves stmts" { check(stmtCountAfter("let a = 1; let b = 2;", markClosureCalls) === 2); }

test "if unchanged" { check(firstStmtKindAfter("if (x) {}", markClosureCalls) === NodeKind.IfStmt); }

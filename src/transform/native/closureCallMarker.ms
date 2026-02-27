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
} from "../../ast/node";
import { TransformContext } from "../context";
import { test, check, testGroup } from "std/testing";
import { stmtCountAfter, firstStmtKindAfter } from "../testUtil";

// ===== Main Entry Point =====

export function markClosureCalls(program: Node, ctx: TransformContext): Node {
	collectFunctionNames(program, ctx);
	return program;
}

// Recursively collect all FunctionDecl names in the program
function collectFunctionNames(node: Node, ctx: TransformContext): void {
	match (node.kind) {
		NodeKind.FunctionDecl => {
			const d = node.data as FunctionDeclData;
			if (d.fnName !== "") {
				ctx.fnDeclNames.push(d.fnName);
			}
			collectFunctionNames(d.fnBody, ctx);
		},
		NodeKind.Program => {
			// NOTE: for/for..of inside match arms crashes reference compiler — use while
			const pd = node.data as ProgramData;
			let i = 0;
			while (i < pd.programStmts.length) {
				collectFunctionNames(pd.programStmts[i], ctx);
				i += 1;
			}
		},
		NodeKind.BlockStmt => {
			const bd = node.data as BlockStmtData;
			let i = 0;
			while (i < bd.statements.length) {
				collectFunctionNames(bd.statements[i], ctx);
				i += 1;
			}
		},
		_ => {},
	};
}

// ===== Tests =====

testGroup("Closure Call Marker", () => {
	test("stmt passthrough", () => {
		check(stmtCountAfter("const x = 1;", markClosureCalls) === 1);
	});
	test("function stays FunctionDecl", () => {
		check(firstStmtKindAfter("function foo() {}", markClosureCalls) === NodeKind.FunctionDecl);
	});
	test("while unchanged", () => {
		check(firstStmtKindAfter("while (true) {}", markClosureCalls) === NodeKind.WhileStmt);
	});
	test("preserves stmts", () => {
		check(stmtCountAfter("let a = 1; let b = 2;", markClosureCalls) === 2);
	});
	test("if unchanged", () => {
		check(firstStmtKindAfter("if (x) {}", markClosureCalls) === NodeKind.IfStmt);
	});
});

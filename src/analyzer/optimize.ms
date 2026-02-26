// DRC Post-Optimizer — eliminate redundant RC operation pairs
//
// Pattern: wasMoved(x); destroy(x); → remove the destroy
// When a variable is marked as moved (wasMoved zeroes it), the subsequent
// destroy is a no-op on a zeroed value. Removing it saves a function call.
//
// Walks all blocks recursively, scanning consecutive statements.

import {
	Node, NodeKind, SourceLocation, ProgramData,
	BlockStmtData, ExprStmtData, CallExprData, IdentifierData,
	FunctionDeclData, IfStmtData, WhileStmtData, ForStmtData,
	TryCatchStmtData, SwitchStmtData, SwitchCaseData,
	ExportDeclData, ClassDeclData, MethodDeclData, ConstructorDeclData,
	ForOfStmtData, DoWhileStmtData, ReturnStmtData,
} from "../ast/node";
import { test, check, testGroup } from "std/testing";
import { TransformContext } from "../transform/context";
import {
	makeIdent, makeBlock, makeExprStmt, makeCall,
} from "../transform/util";

// ===== Known wasMoved / destroy function names =====

function isWasMovedFn(name: string): boolean {
	return name === "ms_string_was_moved"
		|| name === "ms_array_number_was_moved"
		|| name === "ms_array_string_was_moved"
		|| name === "MS_ARRAY_REF_WAS_MOVED"
		|| name === "ms_closure_was_moved"
		|| name === "ms_map_was_moved"
		|| name === "ms_ptr_was_moved"
		|| endsWith(name, "_wasMoved");
}

function isDestroyFn(name: string): boolean {
	return name === "ms_string_decref"
		|| name === "ms_decref"
		|| name === "ms_array_destroy"
		|| name === "ms_array_string_destroy"
		|| name === "MS_ARRAY_REF_DESTROY"
		|| name === "ms_closure_destroy"
		|| name === "ms_map_free"
		|| name === "ms_set_free"
		|| endsWith(name, "_destroy");
}

// Simple endsWith check (no string.includes in MetaScript)
function endsWith(s: string, suffix: string): boolean {
	if (s.length < suffix.length) return false;
	const start = s.length - suffix.length;
	return s.slice(start, s.length) === suffix;
}

// ===== Extract var name from wasMoved/destroy call =====

// Extract single argument name from a call expression statement
function extractSingleCallArg(stmt: Node): string {
	if (stmt === null || stmt.kind !== NodeKind.ExprStmt) return "";
	const ed = stmt.data as ExprStmtData;
	if (ed.expr === null || ed.expr.kind !== NodeKind.CallExpr) return "";
	const cd = ed.expr.data as CallExprData;
	if (cd.arguments.length !== 1) return "";
	// Access arguments[0] inline — avoid local Node variable (DRC use-after-free on return)
	if (cd.arguments[0] === null || cd.arguments[0].kind !== NodeKind.Identifier) return "";
	return (cd.arguments[0].data as IdentifierData).name;
}

// Extract callee name from ExprStmt(CallExpr(...))
function extractCalleeName(stmt: Node): string {
	if (stmt === null || stmt.kind !== NodeKind.ExprStmt) return "";
	const ed = stmt.data as ExprStmtData;
	if (ed.expr === null || ed.expr.kind !== NodeKind.CallExpr) return "";
	const cd = ed.expr.data as CallExprData;
	if (cd.callee === null || cd.callee.kind !== NodeKind.Identifier) return "";
	return (cd.callee.data as IdentifierData).name;
}

function getWasMovedVar(stmt: Node): string {
	const callee = extractCalleeName(stmt);
	if (callee === "") return "";
	if (!isWasMovedFn(callee)) return "";
	return extractSingleCallArg(stmt);
}

function getDestroyVar(stmt: Node): string {
	const callee = extractCalleeName(stmt);
	if (callee === "") return "";
	if (!isDestroyFn(callee)) return "";
	return extractSingleCallArg(stmt);
}

// ===== Block Optimization =====

function optimizeBlock(stmts: Node[]): Node[] {
	const result: Node[] = [];
	let i = 0;
	while (i < stmts.length) {
		// Check for wasMoved(x); destroy(x) pattern
		if (i + 1 < stmts.length) {
			const wmVar = getWasMovedVar(stmts[i]);
			if (wmVar !== "") {
				const destroyVar = getDestroyVar(stmts[i + 1]);
				if (wmVar === destroyVar) {
					// Eliminate the destroy — wasMoved already zeroed the var
					result.push(stmts[i]);  // keep wasMoved
					i += 2;  // skip destroy
					continue;
				}
			}
		}
		result.push(stmts[i]);
		i += 1;
	}
	return result;
}

// ===== Recursive Walker =====

function walkOptimize(node: Node): void {
	if (node === null) return;

	match (node.kind) {
		NodeKind.Program => {
			const d = node.data as ProgramData;
			d.programStmts = optimizeBlock(d.programStmts);
			let i = 0;
			while (i < d.programStmts.length) {
				walkOptimize(d.programStmts[i]);
				i += 1;
			}
		},
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			d.statements = optimizeBlock(d.statements);
			let i = 0;
			while (i < d.statements.length) {
				walkOptimize(d.statements[i]);
				i += 1;
			}
		},
		NodeKind.FunctionDecl => { walkOptimize((node.data as FunctionDeclData).fnBody); },
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			walkOptimize(d.consequent);
			walkOptimize(d.alternate);
		},
		NodeKind.WhileStmt => { walkOptimize((node.data as WhileStmtData).whileBody); },
		NodeKind.ForStmt => { walkOptimize((node.data as ForStmtData).forBody); },
		NodeKind.ForOfStmt => { walkOptimize((node.data as ForOfStmtData).forOfBody); },
		NodeKind.DoWhileStmt => { walkOptimize((node.data as DoWhileStmtData).doBody); },
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			walkOptimize(d.tryBody);
			walkOptimize(d.catchBody);
			walkOptimize(d.finallyBody);
		},
		NodeKind.SwitchStmt => {
			for (const c of (node.data as SwitchStmtData).switchCases) { walkOptimize(c); }
		},
		NodeKind.SwitchCase => { walkOptimizeSwitchCase(node); },
		NodeKind.ExportDecl => { walkOptimize((node.data as ExportDeclData).exportedDecl); },
		NodeKind.ClassDecl => {
			for (const member of (node.data as ClassDeclData).classBody) { walkOptimize(member); }
		},
		NodeKind.MethodDecl => { walkOptimizeMethod(node); },
		NodeKind.ConstructorDecl => { walkOptimizeCtor(node); },
		_ => {},
	};
}

// Extracted to functions for correct codegen (loop-var vs param — DRC gotcha)
function walkOptimizeSwitchCase(caseNode: Node): void {
	const d = caseNode.data as SwitchCaseData;
	d.caseStmts = optimizeBlock(d.caseStmts);
	let i = 0;
	while (i < d.caseStmts.length) {
		walkOptimize(d.caseStmts[i]);
		i += 1;
	}
}

function walkOptimizeMethod(member: Node): void {
	const md = member.data as MethodDeclData;
	walkOptimize(md.methodBody);
}

function walkOptimizeCtor(member: Node): void {
	const cd = member.data as ConstructorDeclData;
	walkOptimize(cd.ctorBody);
}

// ===== Public Entry Point =====

export function optimizeDrc(program: Node): Node {
	walkOptimize(program);
	return program;
}

// ===== Tests =====

function makeLoc(): SourceLocation {
	const loc: SourceLocation = { line: 0, column: 0 };
	return loc;
}

function makeWmCall(varName: string): Node {
	const loc = makeLoc();
	return makeExprStmt(
		makeCall(makeIdent("ms_string_was_moved", loc), [makeIdent(varName, loc)], loc), loc);
}

function makeDestroyCallForTest(varName: string): Node {
	const loc = makeLoc();
	return makeExprStmt(
		makeCall(makeIdent("ms_string_decref", loc), [makeIdent(varName, loc)], loc), loc);
}

function makeOtherStmt(): Node {
	const loc = makeLoc();
	return makeExprStmt(makeIdent("something", loc), loc);
}

testGroup("DRC Optimize wasMoved+destroy", () => {
	test("eliminates wasMoved+destroy pair", () => {
		const wm = makeWmCall("x");
		const destroy = makeDestroyCallForTest("x");
		const stmts: Node[] = [wm, destroy];
		const result = optimizeBlock(stmts);
		// destroy eliminated, only wasMoved remains
		check(result.length === 1);
	});
	test("preserves non-adjacent pair", () => {
		const wm = makeWmCall("x");
		const other = makeOtherStmt();
		const destroy = makeDestroyCallForTest("x");
		const stmts: Node[] = [wm, other, destroy];
		const result = optimizeBlock(stmts);
		// Not adjacent — both preserved
		check(result.length === 3);
	});
	test("preserves different vars", () => {
		const wm = makeWmCall("x");
		const destroy = makeDestroyCallForTest("y");
		const stmts: Node[] = [wm, destroy];
		const result = optimizeBlock(stmts);
		// Different vars — both preserved
		check(result.length === 2);
	});
	test("eliminates multiple pairs", () => {
		const wm1 = makeWmCall("a");
		const d1 = makeDestroyCallForTest("a");
		const wm2 = makeWmCall("b");
		const d2 = makeDestroyCallForTest("b");
		const stmts: Node[] = [wm1, d1, wm2, d2];
		const result = optimizeBlock(stmts);
		// Both destroy calls eliminated
		check(result.length === 2);
	});
	test("preserves standalone wasMoved", () => {
		const wm = makeWmCall("x");
		const other = makeOtherStmt();
		const stmts: Node[] = [wm, other];
		const result = optimizeBlock(stmts);
		check(result.length === 2);
	});
	test("preserves standalone destroy", () => {
		const destroy = makeDestroyCallForTest("x");
		const other = makeOtherStmt();
		const stmts: Node[] = [destroy, other];
		const result = optimizeBlock(stmts);
		check(result.length === 2);
	});
});

testGroup("DRC Optimize getWasMovedVar", () => {
	test("extracts var from wasMoved call", () => {
		const wm = makeWmCall("myVar");
		const name = getWasMovedVar(wm);
		check(name === "myVar");
	});
	test("returns empty for non-wasMoved", () => {
		const other = makeOtherStmt();
		const name = getWasMovedVar(other);
		check(name === "");
	});
});

testGroup("DRC Optimize endsWith", () => {
	test("matches suffix", () => {
		check(endsWith("Token_destroy", "_destroy"));
		check(endsWith("Token_wasMoved", "_wasMoved"));
	});
	test("no match", () => {
		check(!endsWith("Token_copy", "_destroy"));
		check(!endsWith("short", "_destroy"));
	});
});

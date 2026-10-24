// Dead code elimination, statement level: strips unreachable statements after
// terminators and never-returning calls, folds if(true)/if(false) and while(false).
// Hoisted declarations stay. lowerDCE then runs the symbol sweep (sweepDecls.ms).

import { Node, NodeKind, ProgramData, BlockStmtData, FunctionDeclData, ArrowFunctionData, FunctionExprData, MethodDeclData, ConstructorDeclData, TestDeclData, ExportDeclData, ClassDeclData, DecoratedDeclData, IfStmtData, WhileStmtData, ForStmtData, ForOfStmtData, ForInStmtData, DoWhileStmtData, SwitchStmtData, SwitchCaseData, TryCatchStmtData, BooleanLiteralData, ExprStmtData, CallExprData, VariableDeclData, ReturnStmtData, BinaryExprData, MemberExprData, TypeKind } from "../../ast/node";
import { TransformContext } from "../context";
import { makeBlock, makeExprStmt } from "../util";
import { sweepDeadDecls } from "./sweepDecls";
import { overloadWinner } from "../../checker/symbol";
import { stmtCountAfter, firstStmtKindAfter, checkedStmtCount } from "../testUtil";

// ===== Helpers =====

function isHoistedDecl(node: Node): boolean {
	return match (node.kind) {
		NodeKind.FunctionDecl | NodeKind.ClassDecl | NodeKind.EnumDecl
			| NodeKind.InterfaceDecl | NodeKind.StructDecl | NodeKind.TypeAliasDecl
			| NodeKind.ImportDecl | NodeKind.ExportDecl | NodeKind.ExternDecl => true,
		_ => false,
	};
}

function isTrueLiteral(node: Node): boolean {
	if (node.kind != NodeKind.BooleanLiteral) return false;
	const d = node.data as BooleanLiteralData;
	return d.boolValue == true;
}

function isFalseLiteral(node: Node): boolean {
	if (node.kind != NodeKind.BooleanLiteral) return false;
	const d = node.data as BooleanLiteralData;
	return d.boolValue == false;
}

// ===== Never-Returning Call Detection (Standard reference pattern) =====

function isNeverCall(node: Node): boolean {
	const d = node.data as CallExprData;
	if (d.callee.kind != NodeKind.Identifier || d.callee.resolvedSym == null) return false;
	const sym = overloadWinner(d.callee.resolvedSym, d.resolvedOverloadIdx);
	if (sym.symbolType == null || sym.symbolType.kind != TypeKind.Function) return false;
	const ret = sym.symbolType.typeReturn;
	return ret != null && ret.kind == TypeKind.Never;
}

// ===== endsInNoReturn — recursive path analysis =====
// Returns true if a node ALWAYS terminates control flow (never falls through).
// Standard reference equivalent: endsInNoReturn
//
// Direct terminators: return, throw, break, continue, unreachable
// Never-returning calls: ExprStmt wrapping CallExpr to `: never` function
// Compound terminators:
//   - BlockStmt: last statement endsInNoReturn
//   - IfStmt: ALL branches + else must endsInNoReturn
//   - SwitchStmt: ALL cases + default must endsInNoReturn
//   - TryCatchStmt: finally endsInNoReturn OR (try + all catches endsInNoReturn)

export function endsInNoReturn(node: Node, ctx: TransformContext): boolean {
	return match (node.kind) {
		// Direct terminators (Standard reference patterns)
		NodeKind.ReturnStmt | NodeKind.ThrowStmt | NodeKind.BreakStmt
			| NodeKind.ContinueStmt | NodeKind.UnreachableStmt => true,

		// ExprStmt: unwrap and check inner expression (e.g. fail() call)
		NodeKind.ExprStmt => {
			const ed = node.data as ExprStmtData;
			return endsInNoReturn(ed.expr, ctx);
		},

		// CallExpr: check if callee returns never (standard pattern)
		NodeKind.CallExpr => {
			return isNeverCall(node) || neverOrNull(node) != null;
		},

		// Block: check last statement
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			if (d.statements.length == 0) { return false; }
			else { return endsInNoReturn(d.statements[d.statements.length - 1], ctx); }
		},

		// If/else: ALL branches must terminate AND must have else
		// Standard reference pattern: only noReturn when hasElse && all branches noReturn
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			// Must have a non-empty alternate (else branch)
			if (d.alternate == null) { return false; }
			else if (d.alternate.kind == NodeKind.BlockStmt) {
				const altBlock = d.alternate.data as BlockStmtData;
				if (altBlock.statements.length == 0) { return false; }
				else {
					// Both branches must terminate
					return endsInNoReturn(d.consequent, ctx) && endsInNoReturn(d.alternate, ctx);
				}
			}
			else {
				// alternate is another IfStmt (else-if chain)
				return endsInNoReturn(d.consequent, ctx) && endsInNoReturn(d.alternate, ctx);
			}
		},

		// Switch: ALL cases must terminate AND must have default
		NodeKind.SwitchStmt => {
			const d = node.data as SwitchStmtData;
			if (d.switchCases.length == 0) { return false; }
			else { return switchEndsInNoReturn(d.switchCases, ctx); }
		},

		// Try/catch/finally:
		// - If finally endsInNoReturn → whole thing is noReturn (standard reference pattern)
		// - Otherwise: try body + ALL catch handlers must endsInNoReturn
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			// Finally override: if finally always terminates, entire try is noReturn
			if (d.finallyBody != null && endsInNoReturn(d.finallyBody, ctx)) { return true; }
			else {
				// Try body must terminate
				if (!endsInNoReturn(d.tryBody, ctx)) { return false; }
				// Catch body must terminate (if present)
				else if (d.catchBody != null) { return endsInNoReturn(d.catchBody, ctx); }
				// No catch: try body terminates but exceptions could escape
				else { return false; }
			}
		},

		_ => false,
	};
}

// Helper: check if all switch cases terminate AND has default
function switchEndsInNoReturn(cases: Node[], ctx: TransformContext): boolean {
	let hasDefault = false;
	for (let i = 0; i < cases.length; i += 1) {
		const c = cases[i];
		if (c.kind == NodeKind.SwitchCase) {
			const cd = c.data as SwitchCaseData;
			if (cd.isDefault) { hasDefault = true; }
			// Check if case body terminates
			if (cd.caseStmts.length == 0) return false;
			if (!endsInNoReturn(cd.caseStmts[cd.caseStmts.length - 1], ctx)) return false;
		}
	}
	// Only noReturn when we have a default case (exhaustive)
	return hasDefault;
}

// ===== Core: Strip Unreachable Statements =====
// Uses endsInNoReturn for compound terminator detection

function stripDead(stmts: Node[], ctx: TransformContext): Node[] {
	const result: Node[] = [];
	let terminated = false;
	for (let i = 0; i < stmts.length; i += 1) {
		const stmt = stmts[i];
		if (terminated) {
			// After terminator: only keep hoisted declarations
			if (isHoistedDecl(stmt)) {
				result.push(stmt);
			}
		} else {
			result.push(stmt);
			if (endsInNoReturn(stmt, ctx)) {
				terminated = true;
			}
		}
	}
	return result;
}

// ===== Core: Dead Branch Elimination =====

function eliminateDeadBranch(node: Node): Node {
	if (node.kind != NodeKind.IfStmt) return node;
	const d = node.data as IfStmtData;

	if (isTrueLiteral(d.condition)) {
		// if (true) A else B → A
		return d.consequent;
	}
	if (isFalseLiteral(d.condition)) {
		const alternate = d.alternate;
		return alternate != null ? alternate : makeBlock([], node.location);
	}
	return node;
}

// ===== Core: Dead While Elimination =====

function eliminateDeadWhile(node: Node): Node {
	if (node.kind != NodeKind.WhileStmt) return node;
	const d = node.data as WhileStmtData;

	if (isFalseLiteral(d.whileCondition)) {
		return makeBlock([], node.location);
	}
	return node;
}

function neverValueStmt(stmt: Node): Node {
	const value = neverValueOf(stmt);
	return value == null ? stmt : makeExprStmt(value, stmt.location);
}

function neverValueOf(stmt: Node): Node | null {
	return match (stmt.kind) {
		NodeKind.VariableDecl => neverOrNull((stmt.data as VariableDeclData).initializer),
		NodeKind.ReturnStmt => neverOrNull((stmt.data as ReturnStmtData).argument),
		NodeKind.ExprStmt => {
			const expr = (stmt.data as ExprStmtData).expr;
			if (expr.kind != NodeKind.BinaryExpr) return null;
			const assign = expr.data as BinaryExprData;
			if (assign.operator != "=" || !isPlainPlace(assign.left)) return null;
			return neverOrNull(assign.right);
		},
		_ => null,
	};
}

function neverOrNull(expr: Node | null): Node | null {
	return expr != null && expr.nodeType != null && expr.nodeType.kind == TypeKind.Never ? expr : null;
}

function isPlainPlace(node: Node): boolean {
	if (node.kind == NodeKind.Identifier) return true;
	return node.kind == NodeKind.MemberExpr && isPlainPlace((node.data as MemberExprData).object);
}

// ===== Statement List Walker =====
// Bottom-up: recurse into each stmt, then apply dead branch/while elimination

function walkStmtList(stmts: Node[], ctx: TransformContext): void {
	for (let i = 0; i < stmts.length; i += 1) {
		stmts[i] = neverValueStmt(stmts[i]);
		dceInNode(stmts[i], ctx);
		stmts[i] = eliminateDeadBranch(stmts[i]);
		stmts[i] = eliminateDeadWhile(stmts[i]);
	}
}

// ===== Recursive DCE Walker =====

function dceInNode(node: Node, ctx: TransformContext): void {
	if (node == null) return;
	match (node.kind) {
		NodeKind.Program => {
			const d = node.data as ProgramData;
			walkStmtList(d.programStmts, ctx);
			node.data = { programStmts: stripDead(d.programStmts, ctx) };
		},
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			walkStmtList(d.statements, ctx);
			node.data = { statements: stripDead(d.statements, ctx) };
		},
		NodeKind.FunctionDecl => {
			const d = node.data as FunctionDeclData;
			dceInNode(d.fnBody, ctx);
		},
		NodeKind.ArrowFunction => {
			const d = node.data as ArrowFunctionData;
			dceInNode(d.arrowBody, ctx);
		},
		NodeKind.FunctionExpr => {
			const d = node.data as FunctionExprData;
			dceInNode(d.funcExprBody, ctx);
		},
		NodeKind.MethodDecl => {
			const d = node.data as MethodDeclData;
			dceInNode(d.methodBody, ctx);
		},
		NodeKind.ConstructorDecl => {
			const d = node.data as ConstructorDeclData;
			dceInNode(d.ctorBody, ctx);
		},
		NodeKind.TestDecl => {
			const d = node.data as TestDeclData;
			dceInNode(d.testBody, ctx);
		},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			dceInNode(d.consequent, ctx);
			dceInNode(d.alternate, ctx);
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			dceInNode(d.whileBody, ctx);
		},
		NodeKind.ForStmt => {
			const d = node.data as ForStmtData;
			dceInNode(d.forBody, ctx);
		},
		NodeKind.ForOfStmt => {
			const d = node.data as ForOfStmtData;
			dceInNode(d.forOfBody, ctx);
		},
		NodeKind.ForInStmt => {
			const d = node.data as ForInStmtData;
			dceInNode(d.forInBody, ctx);
		},
		NodeKind.DoWhileStmt => {
			const d = node.data as DoWhileStmtData;
			dceInNode(d.doBody, ctx);
		},
		NodeKind.SwitchStmt => {
			const d = node.data as SwitchStmtData;
			for (const c of d.switchCases) {
				dceInNode(c, ctx);
			}
		},
		NodeKind.SwitchCase => {
			const d = node.data as SwitchCaseData;
			walkStmtList(d.caseStmts, ctx);
			node.data = { caseTests: d.caseTests, caseStmts: stripDead(d.caseStmts, ctx), isDefault: d.isDefault };
		},
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			dceInNode(d.tryBody, ctx);
			if (d.catchBody != null) {
				dceInNode(d.catchBody, ctx);
			}
			if (d.finallyBody != null) {
				dceInNode(d.finallyBody, ctx);
			}
		},
		NodeKind.ExportDecl => {
			const d = node.data as ExportDeclData;
			dceInNode(d.exportedDecl, ctx);
		},
		NodeKind.ClassDecl => {
			const d = node.data as ClassDeclData;
			for (const member of d.classBody) {
				dceInNode(member, ctx);
			}
		},
		NodeKind.DecoratedDecl => {
			const d = node.data as DecoratedDeclData;
			dceInNode(d.decoratedNode, ctx);
		},
		_ => {},
	};
}

// ===== Main Entry Point =====

export function lowerDCE(program: Node, ctx: TransformContext): Node {
	dceInNode(program, ctx);
	sweepDeadDecls(program, ctx);
	return program;
}

// ===== Tests =====
test "passthrough unchanged" { assert stmtCountAfter("const x = 1;", lowerDCE) == 1; }

test "strips after return" { assert stmtCountAfter("return 1; const x = 2; const y = 3;", lowerDCE) == 1; }

test "strips after throw" { assert stmtCountAfter("throw 1; const x = 2;", lowerDCE) == 1; }

test "hoisted function kept at transform level" {
	// Functions not eliminated by transform DCE — functionDeclIsAlive handles cross-module DCE.
	assert stmtCountAfter("return 1; function helper() { return 2; }", lowerDCE) == 2;
}

test "hoisted class kept at transform level" {
	assert stmtCountAfter("return 1; class Foo {}", lowerDCE) == 2;
}

test "function body dead code removed" {
	// foo() call keeps the function alive; the statement pass strips dead const inside body
	assert stmtCountAfter("function foo() { return 1; const dead = 2; } foo();", lowerDCE) == 2;
	assert firstStmtKindAfter("function foo() { return 1; const dead = 2; } foo();", lowerDCE) == NodeKind.FunctionDecl;
}

test "if true keeps consequent" {
	assert firstStmtKindAfter("if (true) { const x = 1; } else { const y = 2; }", lowerDCE) == NodeKind.BlockStmt;
	assert stmtCountAfter("if (true) { const x = 1; } else { const y = 2; }", lowerDCE) == 1;
}

test "if false keeps alternate" { assert firstStmtKindAfter("if (false) { const x = 1; } else { const y = 2; }", lowerDCE) == NodeKind.BlockStmt; }

test "if false no else becomes empty block" {
	assert firstStmtKindAfter("if (false) { const x = 1; }", lowerDCE) == NodeKind.BlockStmt;
	assert stmtCountAfter("if (false) { const x = 1; }", lowerDCE) == 1;
}

test "dynamic condition preserved" { assert firstStmtKindAfter("if (x) { const a = 1; }", lowerDCE) == NodeKind.IfStmt; }

test "while false removed" { assert firstStmtKindAfter("while (false) { doWork(); }", lowerDCE) == NodeKind.BlockStmt; }

test "while true preserved" { assert firstStmtKindAfter("while (true) { break; }", lowerDCE) == NodeKind.WhileStmt; }

test "if-else both return strips after" { assert stmtCountAfter("if (x) { return 1; } else { return 2; } const dead = 3;", lowerDCE) == 1; }

test "if-else one branch falls through keeps after" { assert stmtCountAfter("if (x) { return 1; } else { const y = 2; } const alive = 3;", lowerDCE) == 2; }

test "if without else keeps after" { assert stmtCountAfter("if (x) { return 1; } const alive = 2;", lowerDCE) == 2; }

test "nested if-else both return" {
	const code = "if (a) { if (b) { return 1; } else { return 2; } } else { return 3; } const dead = 4;";
	assert stmtCountAfter(code, lowerDCE) == 1;
}

test "block ending in return" { assert stmtCountAfter("{ return 1; } const dead = 2;", lowerDCE) == 1; }

test "block not ending in return" { assert stmtCountAfter("{ const x = 1; } const alive = 2;", lowerDCE) == 2; }

test "throw in both if branches" { assert stmtCountAfter("if (x) { throw 1; } else { throw 2; } const dead = 3;", lowerDCE) == 1; }

test "else-if chain all return" {
	const code = "if (a) { return 1; } else if (b) { return 2; } else { return 3; } const dead = 4;";
	assert stmtCountAfter(code, lowerDCE) == 1;
}

test "else-if chain missing else" {
	const code = "if (a) { return 1; } else if (b) { return 2; } const alive = 3;";
	assert stmtCountAfter(code, lowerDCE) == 2;
}

test "never call strips after" { assert checkedStmtCount("function fail(): never { throw 1; } fail(); const dead = 2;", lowerDCE) == 2; }

test "void call keeps after" { assert checkedStmtCount("function log(): void {} log(); const alive = 2;", lowerDCE) == 3; }

test "unknown function keeps after" { assert checkedStmtCount("mystery(); const alive = 2;", lowerDCE) == 2; }

test "null checker graceful" {
	// stmtCountAfter uses null checkerCtx — must not crash
	assert stmtCountAfter("foo(); const alive = 2;", lowerDCE) == 2;
}

test "unused function kept at transform level" { assert stmtCountAfter("function unused() {} const x = 1;", lowerDCE) == 2; }

test "used function kept" { assert stmtCountAfter("function add(a, b) { return 1; } add(1, 2);", lowerDCE) == 2; }

test "exported function always kept" { assert stmtCountAfter("export function api() { return 1; }", lowerDCE) == 1; }

test "mutual recursion kept at transform level" { assert stmtCountAfter("function a() { b(); } function b() { a(); }", lowerDCE) == 2; }

test "mutual recursion alive via call" { assert stmtCountAfter("function a() { b(); } function b() { a(); } a();", lowerDCE) == 3; }

test "unused class kept at transform level" { assert stmtCountAfter("class Dead {} const x = 1;", lowerDCE) == 2; }

test "used class kept" { assert stmtCountAfter("class Alive {} const x = Alive;", lowerDCE) == 2; }

test "transitive liveness" { assert stmtCountAfter("function helper() { return 1; } function api() { return helper(); } api();", lowerDCE) == 3; }

test "an unused enum is swept by the entry" { assert checkedStmtCount("enum Color { Red, Green } const x = 1;", lowerDCE) == 1; }

test "variable decl always kept" {
	// Variable declarations have side effects (initializer runs)
	assert stmtCountAfter("const x = 1;", lowerDCE) == 1;
}



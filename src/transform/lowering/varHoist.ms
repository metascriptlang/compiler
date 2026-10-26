// Var Hoist — hoist var declarations to function scope top (JS semantics)
//
// function f() {               function f() {
//     console.log(x);    →         let x = null;    // hoisted
//     if (c) {                     console.log(x);
//         var x = 5;               if (c) {
//     }                                x = 5;        // assignment
// }                                }
//                              }
//
// Only inside function bodies. Module-level var is NOT hoisted.
// One hoisted let per declared symbol; stops at nested function boundaries.

import {
	Node, NodeKind, DeclKind, SourceLocation,
	ProgramData, BlockStmtData, FunctionDeclData, FunctionExprData,
	ArrowFunctionData, MethodDeclData, ConstructorDeclData,
	VariableDeclData, IfStmtData, WhileStmtData, TryCatchStmtData,
	DoWhileStmtData, SwitchStmtData, SwitchCaseData,
	ExportDeclData, ClassDeclData, DecoratedDeclData, Symbol,
} from "../../ast/node";
import { TransformContext } from "../context";
import { forEachChild, isFuncBoundary } from "../../ast/visitor";
import { makeVarDecl, makeTypedIdentResolved, makeNull, makeAssign, makeExprStmt, makeBlock } from "../util";
import { stmtCountAfter, firstStmtKindAfter, fnBodyStmtCount, checkedFnBodyCount } from "../testUtil";

// ===== Conversion =====
// Replace var decls with assignments (or drop if no init). Recurse into nested blocks.

function varSymOf(decl: Node): Symbol {
	if (decl.resolvedSym == null) throw new Error(`internal: var '${(decl.data as VariableDeclData).declName}' reached hoisting without its symbol`);
	return decl.resolvedSym;
}

function collectVarDecls(node: Node | null, out: Node[]): void {
	if (node == null) return;
	if (isFuncBoundary(node)) return;
	if (node.kind == NodeKind.VariableDecl && (node.data as VariableDeclData).declKind == DeclKind.Var) out.push(node);
	forEachChild(node, (c: Node): void => { collectVarDecls(c, out); });
}

function convertVarsInStmts(stmts: Node[], loc: SourceLocation): void {
	for (let i = 0; i < stmts.length; i += 1) convertVarInNode(stmts, i, loc);
}

function convertVarInNode(stmts: Node[], idx: number, loc: SourceLocation): void {
	const stmt = stmts[idx];
	match (stmt.kind) {
		NodeKind.VariableDecl => {
			const d = stmt.data as VariableDeclData;
			if (d.declKind == DeclKind.Var) {
				if (d.initializer != null && d.initializer.kind != NodeKind.NullLiteral) {
					stmts[idx] = makeExprStmt(makeAssign(makeTypedIdentResolved(varSymOf(stmt), null, loc), d.initializer, loc), loc);
				} else {
					stmts[idx] = makeBlock([], loc);
				}
			}
		},
		NodeKind.BlockStmt => {
			const d = stmt.data as BlockStmtData;
			convertVarsInStmts(d.statements, loc);
		},
		NodeKind.IfStmt => {
			const d = stmt.data as IfStmtData;
			convertVarInBody(d.consequent, loc);
			convertVarInBody(d.alternate, loc);
		},
		NodeKind.WhileStmt => {
			const d = stmt.data as WhileStmtData;
			convertVarInBody(d.whileBody, loc);
		},
		NodeKind.TryCatchStmt => {
			const d = stmt.data as TryCatchStmtData;
			convertVarInBody(d.tryBody, loc);
			convertVarInBody(d.catchBody, loc);
			convertVarInBody(d.finallyBody, loc);
		},
		NodeKind.DoWhileStmt => {
			const d = stmt.data as DoWhileStmtData;
			convertVarInBody(d.doBody, loc);
		},
		NodeKind.SwitchStmt => {
			const d = stmt.data as SwitchStmtData;
			for (const switchCase of d.switchCases) convertVarsInStmts((switchCase.data as SwitchCaseData).caseStmts, loc);
		},
		_ => {},
	};
}

function convertVarInBody(body: Node, loc: SourceLocation): void {
	if (body.kind == NodeKind.BlockStmt) {
		const d = body.data as BlockStmtData;
		convertVarsInStmts(d.statements, loc);
	}
}

// ===== Per-Function Hoisting =====

function hoistVarsInBody(body: Node, loc: SourceLocation): void {
	const decls: Node[] = [];
	collectVarDecls(body, decls);

	if (decls.length == 0) return;
	for (const decl of decls) {
		if (decl.resolvedSym == null && decl.nodeType == null) return;
	}

	if (body.kind != NodeKind.BlockStmt) return;
	const bd = body.data as BlockStmtData;

	convertVarsInStmts(bd.statements, loc);

	const newStmts: Node[] = [];
	const hoisted: Symbol[] = [];
	for (const decl of decls) {
		const sym = varSymOf(decl);
		if (hoisted.includes(sym)) continue;
		hoisted.push(sym);
		const letDecl = makeVarDecl(sym.name, makeNull(loc), DeclKind.Let, loc);
		letDecl.resolvedSym = sym;
		letDecl.nodeType = decl.nodeType;
		newStmts.push(letDecl);
	}
	body.data = { statements: [...newStmts, ...bd.statements] };
}

// ===== Top-Down Walk =====

function walkVarHoist(node: Node): void {
	match (node.kind) {
		NodeKind.Program => {
			const d = node.data as ProgramData;
			for (const stmt of d.programStmts) walkVarHoist(stmt);
		},
		NodeKind.FunctionDecl => {
			const d = node.data as FunctionDeclData;
			walkVarHoist(d.fnBody);
			hoistVarsInBody(d.fnBody, node.location);
		},
		NodeKind.ArrowFunction => {
			const d = node.data as ArrowFunctionData;
			walkVarHoist(d.arrowBody);
			hoistVarsInBody(d.arrowBody, node.location);
		},
		NodeKind.FunctionExpr => {
			const d = node.data as FunctionExprData;
			walkVarHoist(d.funcExprBody);
			hoistVarsInBody(d.funcExprBody, node.location);
		},
		NodeKind.MethodDecl => {
			const d = node.data as MethodDeclData;
			walkVarHoist(d.methodBody);
			hoistVarsInBody(d.methodBody, node.location);
		},
		NodeKind.ConstructorDecl => {
			const d = node.data as ConstructorDeclData;
			walkVarHoist(d.ctorBody);
			hoistVarsInBody(d.ctorBody, node.location);
		},
		NodeKind.ClassDecl => {
			const d = node.data as ClassDeclData;
			for (const member of d.classBody) walkVarHoist(member);
		},
		NodeKind.ExportDecl => {
			const d = node.data as ExportDeclData;
			walkVarHoist(d.exportedDecl);
		},
		NodeKind.DecoratedDecl => {
			const d = node.data as DecoratedDeclData;
			walkVarHoist(d.decoratedNode);
		},
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			for (const stmt of d.statements) walkVarHoist(stmt);
		},
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			if (d.initializer != null) walkVarHoist(d.initializer);
		},
		_ => {},
	};
}

// ===== Entry Point =====

export function lowerVarHoist(program: Node, ctx: TransformContext): Node {
	walkVarHoist(program);
	return program;
}

// ===== Tests =====
test "const unchanged" { assert stmtCountAfter("const x = 1;", lowerVarHoist) == 1; }

test "let unchanged" { assert stmtCountAfter("let x = 1;", lowerVarHoist) == 1; }

test "module var stays" { assert firstStmtKindAfter("var x = 1;", lowerVarHoist) == NodeKind.VariableDecl; }

test "no var passthrough" { assert stmtCountAfter("function f() { let x = 1; }", lowerVarHoist) == 1; }

test "stmt count preserved" { assert stmtCountAfter("let a = 1; let b = 2;", lowerVarHoist) == 2; }

test "var hoisted adds let at top" {
	assert checkedFnBodyCount("function f() { var x = 1; }", lowerVarHoist) == 2;
}

test "two sibling vars hoist one let each" {
	assert checkedFnBodyCount("function f(c: boolean) { if (c) { var x = 1; } else { var y = 2; } }", lowerVarHoist) == 3;
}

test "nested fn var not hoisted to outer" {
	assert checkedFnBodyCount("function f() { function g() { var x = 1; } }", lowerVarHoist) == 1;
}

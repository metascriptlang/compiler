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
// Deduplicates: multiple var x → single let x = null at top.
// Stops at nested function boundaries.

import {
	Node, NodeKind, DeclKind, SourceLocation,
	ProgramData, BlockStmtData, FunctionDeclData, FunctionExprData,
	ArrowFunctionData, MethodDeclData, ConstructorDeclData,
	VariableDeclData, IfStmtData, WhileStmtData, TryCatchStmtData,
	DoWhileStmtData, SwitchStmtData, SwitchCaseData,
	ExportDeclData, ClassDeclData, DecoratedDeclData,
} from "../../ast/node";
import { TransformContext, NameSet } from "../context";
import { makeVarDecl, makeIdent, makeNull, makeAssign, makeExprStmt, makeBlock, collectDeclNames } from "../util";
import { stmtCountAfter, firstStmtKindAfter, fnBodyStmtCount } from "../testUtil";

// ===== Conversion =====
// Replace var decls with assignments (or drop if no init). Recurse into nested blocks.

function convertVarsInStmts(stmts: Node[], loc: SourceLocation): void {
	for (let i = 0; i < stmts.length; i += 1) {
		convertVarInNode(stmts, i, loc);
	}
}

function convertVarInNode(stmts: Node[], idx: number, loc: SourceLocation): void {
	const stmt = stmts[idx];
	match (stmt.kind) {
		NodeKind.VariableDecl => {
			const d = stmt.data as VariableDeclData;
			if (d.declKind === DeclKind.Var) {
				if (d.initializer.kind !== NodeKind.NullLiteral) {
					stmts[idx] = makeExprStmt(makeAssign(makeIdent(d.declName, loc), d.initializer, loc), loc);
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
			let si = 0;
			while (si < d.switchCases.length) {
				const sc = d.switchCases[si].data as SwitchCaseData;
				convertVarsInStmts(sc.caseStmts, loc);
				si += 1;
			}
		},
		_ => {},
	};
}

function convertVarInBody(body: Node, loc: SourceLocation): void {
	if (body.kind === NodeKind.BlockStmt) {
		const d = body.data as BlockStmtData;
		convertVarsInStmts(d.statements, loc);
	}
}

// ===== Per-Function Hoisting =====

function hoistVarsInBody(body: Node, loc: SourceLocation): void {
	const ns: NameSet = [];
	collectDeclNames(body, ns, true);

	if (ns.length === 0) return;

	if (body.kind !== NodeKind.BlockStmt) return;
	const bd = body.data as BlockStmtData;

	convertVarsInStmts(bd.statements, loc);

	// Build new stmt list: hoisted decls + original stmts
	const newStmts: Node[] = [];
	for (let ni = 0; ni < ns.length; ni += 1) {
		newStmts.push(makeVarDecl(ns[ni], makeNull(loc), DeclKind.Let, loc));
	}
	for (let oi = 0; oi < bd.statements.length; oi += 1) {
		newStmts.push(bd.statements[oi]);
	}
	body.data = { statements: newStmts };
}

// ===== Top-Down Walk =====

function walkVarHoist(node: Node): void {
	match (node.kind) {
		NodeKind.Program => {
			const d = node.data as ProgramData;
			let i = 0;
			while (i < d.programStmts.length) {
				walkVarHoist(d.programStmts[i]);
				i += 1;
			}
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
			let i = 0;
			while (i < d.classBody.length) {
				walkVarHoist(d.classBody[i]);
				i += 1;
			}
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
			let i = 0;
			while (i < d.statements.length) {
				walkVarHoist(d.statements[i]);
				i += 1;
			}
		},
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			walkVarHoist(d.initializer);
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
test "const unchanged" { assert stmtCountAfter("const x = 1;", lowerVarHoist) === 1; }

test "let unchanged" { assert stmtCountAfter("let x = 1;", lowerVarHoist) === 1; }

test "module var stays" { assert firstStmtKindAfter("var x = 1;", lowerVarHoist) === NodeKind.VariableDecl; }

test "function with var" { assert stmtCountAfter("function f() { var x = 1; }", lowerVarHoist) === 1; }

test "function with var is FunctionDecl" { assert firstStmtKindAfter("function f() { var x = 1; }", lowerVarHoist) === NodeKind.FunctionDecl; }

test "no var passthrough" { assert stmtCountAfter("function f() { let x = 1; }", lowerVarHoist) === 1; }

test "stmt count preserved" { assert stmtCountAfter("let a = 1; let b = 2;", lowerVarHoist) === 2; }

test "var hoisted adds let at top" {
	// function f() { var x = 1; } → body has 2 stmts: let x = null; x = 1;
	assert fnBodyStmtCount("function f() { var x = 1; }", lowerVarHoist) === 2;
}

test "nested fn var not hoisted to outer" {
	// function f() { function g() { var x = 1; } } → outer body still 1 stmt (nested fn)
	assert fnBodyStmtCount("function f() { function g() { var x = 1; } }", lowerVarHoist) === 1;
}

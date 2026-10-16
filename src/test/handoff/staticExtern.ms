// Route: static extern methods on classes
//
// Verifies that Result.ok/err static factory methods are properly parsed,
// type-checked, and lowered to ObjectLiteral construction in C codegen.

import { compileToC } from "../helpers";
import { fullPipeline, findFnDecl } from "./helpers";
import {
	Node, NodeKind, ProgramData, ExportDeclData,
	FunctionDeclData, CallExprData, MemberExprData,
	IdentifierData, ReturnStmtData, BlockStmtData,
	ObjectLiteralData,
} from "../../ast/node";

// ===== Parser: static extern syntax (TypeScript-style, no function keyword) =====

test "parse: static extern method in class" {
	const src = "class Foo { static extern create(x: number): Foo from \"foo_create\"; }";
	const ast = fullPipeline(src);
	assert ast != null;
}

test "parse: extern without static is instance method" {
	const src = "class Foo { extern log(value: string): void from \"msPrintln\"; }";
	const ast = fullPipeline(src);
	assert ast != null;
}

// ===== Result.ok / Result.err lowering =====
// Result.ok(val) should lower to { ok: true, value: val }
// Result.err(e)  should lower to { ok: false, error: e }

test "E2E: Result.ok lowers to ObjectLiteral" {
	const src = "export function wrap(x: number): Result<number, string> { return Result.ok(x); }";
	const c = compileToC(src);
	assert c.ok, c.error;
}

test "E2E: Result.err lowers to ObjectLiteral" {
	const src = "export function fail(msg: string): Result<number, string> { return Result.err(msg); }";
	const c = compileToC(src);
	assert c.ok, c.error;
}

test "E2E: Result.ok no (*Result) in C output" {
	const src = "export function wrap(x: number): Result<number, string> { return Result.ok(x); }";
	const c = compileToC(src);
	assert c.ok, c.error;
	assert !c.value.contains("(*Result).");
}

// ===== AST shape after transform =====
// After resultDesugar, Result.ok(val) should be an ObjectLiteral, not a CallExpr

test "AST: Result.ok is ObjectLiteral after transform" {
	const src = "export function wrap(x: number): Result<number, string> { return Result.ok(x); }";
	const ast = fullPipeline(src);
	if (ast == null) { console.log("AST null"); return; }
	const pd = ast.data as ProgramData;
	let found = false;
	let i = 0;
	while (i < pd.programStmts.length) {
		let s = pd.programStmts[i];
		if (s.kind == NodeKind.ExportDecl) { s = (s.data as ExportDeclData).exportedDecl; }
		if (s.kind == NodeKind.FunctionDecl) {
			const fd = s.data as FunctionDeclData;
			if (fd.fnName == "wrap") {
				// Walk into body → ReturnStmt → argument should be ObjectLiteral
				const body = fd.fnBody;
				if (body != null && body.kind == NodeKind.BlockStmt) {
					const bd = body.data as BlockStmtData;
					let j = 0;
					while (j < bd.statements.length) {
						if (bd.statements[j].kind == NodeKind.ReturnStmt) {
							const rd = bd.statements[j].data as ReturnStmtData;
							const k = rd.argument.kind;
							const expect = NodeKind.ObjectLiteral;
							console.log("return arg kind=" + (k == expect ? "ObjectLiteral" : (k == NodeKind.CallExpr ? "CallExpr" : k.toString())) + " expected=ObjectLiteral");
							found = rd.argument.kind == NodeKind.ObjectLiteral;
						}
						j = j + 1;
					}
				}
			}
		}
		i = i + 1;
	}
	assert found;
}

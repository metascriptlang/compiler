// Value equality and value text are std routines the checker binds by symbol.
//
// `a == b` over a value type, and the implicit and explicit string forms of one, leave the checker as
// calls to the prelude's generic routines; a routine the program declares for the type wins.

import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { checkProgramWithRegistry, preludeContextFor } from "../../checker/checkPass";
import { CheckerContext, ExportRegistry, hasErrors } from "../../checker/context";
import { Node, NodeKind, ProgramData, FunctionDeclData, BlockStmtData, ReturnStmtData, CallExprData, UnaryExprData, BinaryExprData, ExprStmtData } from "../../ast/node";
import { Module, ModuleGraph } from "../../module/graph";
import { resetBuildState } from "../../compiler/buildSession";

function checkedBody(source: string, fnName: string): Node[] {
	resetBuildState();
	const prelude = preludeContextFor("", ".cms");
	const pr = parseSource(source);
	if (!pr.ok) return [];
	const ctx: CheckerContext = checkProgramWithRegistry(pr.value, null as unknown as ExportRegistry, null as unknown as ModuleGraph, null as unknown as Module, prelude);
	if (hasErrors(ctx)) return [];
	const pd = pr.value.data as ProgramData;
	for (const stmt of pd.programStmts) {
		if (stmt.kind != NodeKind.FunctionDecl) continue;
		const fd = stmt.data as FunctionDeclData;
		if (fd.fnName == fnName) return (fd.fnBody.data as BlockStmtData).statements;
	}
	return [];
}

function returned(source: string): Node {
	const body = checkedBody(source, "f");
	if (body.length == 0) return null as unknown as Node;
	return (body[body.length - 1].data as ReturnStmtData).argument as Node;
}

function concatOperand(e: Node): Node {
	if (e.kind != NodeKind.BinaryExpr) return e;
	const d = e.data as BinaryExprData;
	return d.right.kind == NodeKind.CallExpr ? d.right : d.left;
}

function calleeName(call: Node): string {
	if (call == null || call.kind != NodeKind.CallExpr) return "";
	const sym = call.resolvedSym;
	return sym != null ? sym.name : "";
}

const POINT = "struct Point { x: int32; y: int32; }\n";

test "struct == is a call to the std equality" {
	const e = returned(POINT + "function f(a: Point, b: Point): boolean { return a == b; }");
	assert calleeName(e).startsWith("valueEquals");
}

test "struct != is the negation of the std equality" {
	const e = returned(POINT + "function f(a: Point, b: Point): boolean { return a != b; }");
	assert e.kind == NodeKind.UnaryExpr;
	assert calleeName((e.data as UnaryExprData).operand).startsWith("valueEquals");
}

test "tuple and fixed array == are calls to the std equality" {
	const t = returned("function f(a: [int32, string], b: [int32, string]): boolean { return a == b; }");
	assert calleeName(t).startsWith("valueEquals");
	const x = returned("function f(a: int32[3], b: int32[3]): boolean { return a == b; }");
	assert calleeName(x).startsWith("valueEquals");
}

test "Result == is a call to the std Result equality" {
	const e = returned("function f(a: Result<int32, string>, b: Result<int32, string>): boolean { return a == b; }");
	assert calleeName(e).startsWith("resultEquals");
}

test "a nullable value compared with a carrier or a payload is a call to the std nullable equality" {
	const both = returned(POINT + "function f(a: Point | null, b: Point | null): boolean { return a == b; }");
	assert calleeName(both).startsWith("nullableEquals");
	const mixed = returned("function f(a: int32 | null, b: int32): boolean { return a == b; }");
	assert calleeName(mixed).startsWith("nullableEquals");
}

test "a comparison with null stays a null test" {
	const e = returned(POINT + "function f(a: Point | null): boolean { return a == null; }");
	assert e.kind == NodeKind.BinaryExpr;
}

test "a declared == for the type wins over the std equality" {
	const e = returned(POINT + "function `==`(a: Point, b: Point): boolean { return a.x == b.x; }\nfunction f(a: Point, b: Point): boolean { return a == b; }");
	assert calleeName(e) == "==";
}

test "a class compares by identity, not through the std equality" {
	const e = returned("class Cell { n: int32 = 0; }\nfunction f(a: Cell, b: Cell): boolean { return a == b; }");
	assert e.kind == NodeKind.BinaryExpr;
}

test "interpolating a struct is the std dump" {
	const e = returned(POINT + "function f(a: Point): string { return `${a}`; }");
	assert calleeName(concatOperand(e)).startsWith("valueDump");
}

test "x.toString() on a struct is the std dump" {
	const e = returned(POINT + "function f(a: Point): string { return a.toString(); }");
	assert calleeName(e).startsWith("valueDump");
}

test "a declared toString for the type wins over the std dump" {
	const e = returned(POINT + "function toString(this p: Point): string { return \"p\"; }\nfunction f(a: Point): string { return a.toString(); }");
	assert calleeName(e) == "toString";
	const t = returned(POINT + "function toString(this p: Point): string { return \"p\"; }\nfunction f(a: Point): string { return `${a}`; }");
	assert calleeName(concatOperand(t)) == "toString";
}

test "console.log of a struct prints through the std debug text" {
	const body = checkedBody(POINT + "function f(a: Point): void { console.log(a); }", "f");
	assert body.length == 1;
	const call = (body[0].data as ExprStmtData).expr.data as CallExprData;
	assert calleeName(call.arguments[0]).startsWith("valueDebug");
}

import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { checkProgramWithRegistry, preludeContextFor } from "../../checker/checkPass";
import { ExportRegistry } from "../../checker/context";
import { transformProgram } from "../../transform/index";
import { Node, NodeKind, ProgramData, FunctionDeclData, IdentifierData, NewExprData } from "../../ast/node";
import { Module, ModuleGraph } from "../../module/graph";
import { forEachChild } from "../../ast/visitor";
import { resetBuildState } from "../../compiler/buildSession";
import { isGenericFn } from "../../checker/context";

function transformedProgram(source: string, jsBackend: boolean): Node {
	resetBuildState();
	const prelude = preludeContextFor("", jsBackend ? ".jms" : ".cms");
	const pr = parseSource(source);
	if (!pr.ok) throw new Error("internal: test source does not parse");
	const ctx = checkProgramWithRegistry(pr.value, null as unknown as ExportRegistry, null as unknown as ModuleGraph, null as unknown as Module, prelude);
	return transformProgram(pr.value, ctx, jsBackend);
}

function isExpression(n: Node): boolean {
	return n.kind == NodeKind.Identifier || n.kind == NodeKind.CallExpr || n.kind == NodeKind.MemberExpr
		|| n.kind == NodeKind.ArrayAccess || n.kind == NodeKind.BinaryExpr;
}

function collectUntyped(n: Node | null, out: string[]): void {
	if (n == null) return;
	if (n.kind == NodeKind.FunctionDecl && isGenericFn((n.data as FunctionDeclData).fnFlags)) return;
	if (isExpression(n) && n.nodeType == null && !(n.resolvedSym != null && n.resolvedSym.symbolType == null)) {
		out.push(n.kind == NodeKind.Identifier ? (n.data as IdentifierData).name : "expression");
	}
	forEachChild(n, (c: Node): void => { collectUntyped(c, out); });
}

function untypedInUserCode(source: string, jsBackend: boolean): string[] {
	const program = transformedProgram(source, jsBackend);
	const out: string[] = [];
	for (const stmt of (program.data as ProgramData).programStmts) {
		if (stmt.kind != NodeKind.FunctionDecl) continue;
		collectUntyped(stmt, out);
	}
	return out;
}

test "a lifted closure's references are typed when the lowering builds them" {
	const source = "function userCounter(): number { let n = 0; const bump = (): number => { n = n + 1; return n; }; bump(); return bump(); }";
	assert untypedInUserCode(source, false).length == 0;
}

test "a for-of loop's generated length and element reads are typed when the lowering builds them" {
	const source = "function userSum(xs: number[]): number { let t = 0; for (const x of xs) { t = t + x; } return t; }";
	assert untypedInUserCode(source, false).length == 0;
}

test "a ternary initializer's branch targets are typed when the lowering builds them" {
	const source = "function userPick(c: boolean, a: string, b: string): string { const z = c ? a + \"x\" : b; return z; }";
	assert untypedInUserCode(source, false).length == 0;
}

test "an extension call's callee is typed when the lowering builds it" {
	const source = "function userShout(this s: string): string { return s + \"!\"; } function userRun(s: string): string { return s.userShout(); }";
	assert untypedInUserCode(source, false).length == 0;
}

function newCalleeTyped(n: Node | null): boolean {
	if (n == null) return true;
	if (n.kind == NodeKind.NewExpr && (n.data as NewExprData).newCallee.nodeType == null) return false;
	let ok = true;
	forEachChild(n, (c: Node): void => { if (!newCalleeTyped(c)) ok = false; });
	return ok;
}

test "the callee of a new Array expression is typed by the checker" {
	const program = transformedProgram("function userMake(n: int32): number[] { const a: number[] = new Array(n); return a; }", false);
	assert newCalleeTyped(program);
}

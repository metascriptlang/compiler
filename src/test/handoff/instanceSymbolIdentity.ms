import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { checkProgramWithRegistry, preludeContextFor } from "../../checker/checkPass";
import { CheckerContext, ExportRegistry } from "../../checker/context";
import { monomorphizeProgram } from "../../monomorphize/collect";
import { Node, NodeKind, Symbol, NewExprData, ProgramData } from "../../ast/node";
import { Module, ModuleGraph } from "../../module/graph";
import { forEachChild } from "../../ast/visitor";
import { resetBuildState } from "../../compiler/buildSession";

function checkedUnit(source: string): { program: Node, ctx: CheckerContext } {
	resetBuildState();
	const prelude = preludeContextFor("", ".cms");
	const pr = parseSource(source);
	if (!pr.ok) throw new Error("internal: test source does not parse");
	const ctx = checkProgramWithRegistry(pr.value, null as unknown as ExportRegistry, null as unknown as ModuleGraph, null as unknown as Module, prelude);
	return { program: pr.value, ctx };
}

function checkedProgram(source: string): Node {
	return checkedUnit(source).program;
}

function instanceSyms(n: Node | null, out: Symbol[]): void {
	if (n == null) return;
	if (n.kind == NodeKind.NewExpr) {
		const callee = (n.data as NewExprData).newCallee;
		if (callee.resolvedSym != null && callee.resolvedSym.instantiatedFrom != null) out.push(callee.resolvedSym);
	}
	forEachChild(n, (c: Node): void => { instanceSyms(c, out); });
}

function callSyms(n: Node | null, out: Symbol[]): void {
	if (n == null) return;
	if (n.kind == NodeKind.CallExpr && n.resolvedSym != null) out.push(n.resolvedSym);
	forEachChild(n, (c: Node): void => { callSyms(c, out); });
}

test "instanceSymbolIdentity: the instance of a generic class carries its declaration and an item" {
	const sources = [
		"class UserBox<T> { v: T; constructor(v: T) { this.v = v; } }\nfunction userMake(): UserBox<number> { return new UserBox<number>(1); }",
		"class UserPair<A, B> { a: A; b: B; constructor(a: A, b: B) { this.a = a; this.b = b; } }\nfunction userMake(): UserPair<string, boolean> { return new UserPair<string, boolean>(\"s\", true); }",
	];
	for (const source of sources) {
		const found: Symbol[] = [];
		instanceSyms(checkedProgram(source), found);
		assert found.length == 1, `instance count ${found.length}: ${source}`;
		assert found[0].item > 0, `instance item ${found[0].item}: ${source}`;
		assert found[0].declNode != null && found[0].declNode.kind == NodeKind.ClassDecl, `instance declaration: ${source}`;
	}
}

test "instanceSymbolIdentity: toString on a class and on an interface binds the std dump instance, which carries an item and its declaration" {
	const sources = [
		"class UserPoint { x: number = 1; }\nfunction userShow(p: UserPoint): string { return p.toString(); }",
		"interface UserShape { w: number; }\nfunction userShow(s: UserShape): string { return s.toString(); }",
	];
	for (const source of sources) {
		const found: Symbol[] = [];
		callSyms(checkedProgram(source), found);
		assert found.length == 1, `call count ${found.length}: ${source}`;
		assert found[0].item > 0, `dump instance item ${found[0].item}: ${source}`;
		const generic = found[0].instantiatedFrom;
		assert generic != null && generic.declNode != null && generic.declNode.kind == NodeKind.FunctionDecl, `dump instance declaration: ${source}`;
	}
}

test "instanceSymbolIdentity: a generic type instance adds no declaration of its own to the program" {
	const source = "interface UserBox<T> { v: T }\nstruct UserPair<A, B> { a: A; b: B }\nfunction userMake(): UserBox<number> { const p: UserPair<number, string> = { a: 1, b: \"x\" }; const b: UserBox<string> = { v: \"s\" }; return { v: p.a }; }";
	const unit = checkedUnit(source);
	const before = (unit.program.data as ProgramData).programStmts.length;
	const mono = monomorphizeProgram(unit.program, unit.ctx);
	const stmts = (mono.data as ProgramData).programStmts;
	assert stmts.length == before, `statements ${before} -> ${stmts.length}`;
	for (const stmt of stmts) {
		if (stmt.kind == NodeKind.InterfaceDecl || stmt.kind == NodeKind.StructDecl) assert stmt.resolvedSym != null, "a declaration without a symbol";
	}
}

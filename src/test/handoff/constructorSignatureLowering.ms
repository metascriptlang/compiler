import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { checkProgramWithRegistry, preludeContextFor } from "../../checker/checkPass";
import { CheckerContext, ExportRegistry } from "../../checker/context";
import { hasFlag, SymbolFlag } from "../../checker/symbol";
import { transformProgram } from "../../transform/index";
import { Node, NodeKind, Symbol, ProgramData, ClassDeclData, ConstructorDeclData, FunctionDeclData, NewExprData, CallExprData } from "../../ast/node";
import { Module, ModuleGraph } from "../../module/graph";
import { resetBuildState } from "../../compiler/buildSession";
import { forEachChild } from "../../ast/visitor";

const SOURCE = `class C {
	v: string = "";
	constructor(a: string) {}
	constructor(a: number) {}
	constructor(a: string | number) { this.v = "x"; }
}
const a = new C("x");
const b = new C(7);
`;

function ctorMembers(program: Node): Node[] {
	const out: Node[] = [];
	for (const stmt of (program.data as ProgramData).programStmts) {
		if (stmt.kind != NodeKind.ClassDecl) continue;
		for (const member of (stmt.data as ClassDeclData).classBody) {
			if (member.kind == NodeKind.ConstructorDecl) out.push(member);
		}
	}
	return out;
}

function checkedWithSignatures(js: boolean): { program: Node, ctx: CheckerContext } {
	resetBuildState();
	const prelude = preludeContextFor("", js ? ".jms" : ".cms");
	const pr = parseSource(SOURCE);
	if (!pr.ok) throw new Error("internal: test source does not parse");
	const ctors = ctorMembers(pr.value);
	(ctors[0].data as ConstructorDeclData).ctorFlags = "overload";
	(ctors[1].data as ConstructorDeclData).ctorFlags = "overload";
	const ctx = checkProgramWithRegistry(pr.value, null as unknown as ExportRegistry, null as unknown as ModuleGraph, null as unknown as Module, prelude);
	if (ctx.errors.length > 0) throw new Error(`internal: ${ctx.errors[0].message}`);
	return { program: pr.value, ctx };
}

function constructSites(n: Node | null, out: Symbol[]): void {
	if (n == null) return;
	if (n.kind == NodeKind.NewExpr && n.resolvedSym != null) out.push(n.resolvedSym);
	if (n.kind == NodeKind.CallExpr) {
		const callee = (n.data as CallExprData).callee;
		if (callee.resolvedSym != null && callee.resolvedSym.name == "C_init") out.push(callee.resolvedSym);
	}
	forEachChild(n, (c: Node): void => { constructSites(c, out); });
}

function initFunctions(program: Node): number {
	let count = 0;
	for (const stmt of (program.data as ProgramData).programStmts) {
		if (stmt.kind == NodeKind.FunctionDecl && (stmt.data as FunctionDeclData).fnName == "C_init") count += 1;
	}
	return count;
}

test "constructorSignatureLowering: C keeps one init function and every new runs it" {
	const unit = checkedWithSignatures(false);
	const impl = ctorMembers(unit.program)[2].resolvedSym!;
	assert !hasFlag(impl, SymbolFlag.OverloadSig);
	const lowered = transformProgram(unit.program, unit.ctx, false);
	assert initFunctions(lowered) == 1;
	assert ctorMembers(lowered).length == 0;
	const sites: Symbol[] = [];
	constructSites(lowered, sites);
	assert sites.length == 2, `${sites.length}`;
	for (const s of sites) assert s == impl;
}

test "constructorSignatureLowering: JS keeps one constructor and every new names the implementation" {
	const unit = checkedWithSignatures(true);
	const impl = ctorMembers(unit.program)[2].resolvedSym!;
	const lowered = transformProgram(unit.program, unit.ctx, true);
	const left = ctorMembers(lowered);
	assert left.length == 1;
	assert left[0].resolvedSym == impl;
	const sites: Symbol[] = [];
	constructSites(lowered, sites);
	assert sites.length == 2, `${sites.length}`;
	for (const s of sites) assert s == impl;
}

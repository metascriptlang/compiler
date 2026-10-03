import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { checkProgramWithRegistry, preludeContextFor } from "../../checker/checkPass";
import { CheckerContext, ExportRegistry } from "../../checker/context";
import { monomorphizeProgram } from "../../monomorphize/collect";
import { transformProgram } from "../../transform/index";
import { Node, NodeKind, Symbol, SymbolKind, ProgramData, ClassDeclData, FunctionDeclData } from "../../ast/node";
import { Module, ModuleGraph } from "../../module/graph";
import { resetBuildState } from "../../compiler/buildSession";

function checkedUnit(source: string, jsBackend: boolean): { program: Node, ctx: CheckerContext } {
	resetBuildState();
	const prelude = preludeContextFor("", jsBackend ? ".jms" : ".cms");
	const pr = parseSource(source);
	if (!pr.ok) throw new Error("internal: test source does not parse");
	const ctx = checkProgramWithRegistry(pr.value, null as unknown as ExportRegistry, null as unknown as ModuleGraph, null as unknown as Module, prelude);
	return { program: pr.value, ctx };
}

function ctorOf(classNode: Node): Node | null {
	for (const member of (classNode.data as ClassDeclData).classBody) {
		if (member.kind == NodeKind.ConstructorDecl) return member;
	}
	return null;
}

function classNamed(program: Node, name: string): Node | null {
	for (const stmt of (program.data as ProgramData).programStmts) {
		if (stmt.kind == NodeKind.ClassDecl && (stmt.data as ClassDeclData).className == name) return stmt;
	}
	return null;
}

function liftedInit(program: Node, name: string): Node | null {
	for (const stmt of (program.data as ProgramData).programStmts) {
		if (stmt.kind == NodeKind.FunctionDecl && (stmt.data as FunctionDeclData).fnName == name) return stmt;
	}
	return null;
}

const SOURCES: string[] = [
	"class UserBox { n: number; constructor(n: number) { this.n = n; } }\nfunction userMake(): UserBox { return new UserBox(1); }",
	"class UserCell { n: number = 3; }\nfunction userMake(): UserCell { return new UserCell(); }",
];

test "constructorOrigin: a written constructor is a routine symbol of its own, with the module's identity" {
	const unit = checkedUnit(SOURCES[0], false);
	const ctor = ctorOf(classNamed(unit.program, "UserBox")!)!;
	const sym = ctor.resolvedSym;
	assert sym != null && sym.symbolKind == SymbolKind.Function;
	assert sym.name == "UserBox_init";
	assert sym.item > 0;
	assert sym.declNode == ctor;
}

test "constructorOrigin: the lifted init function keeps the constructor's own symbol on both backends" {
	for (const source of SOURCES) {
		for (const js of [false, true]) {
			const unit = checkedUnit(source, js);
			const className = source.startsWith("class UserBox") ? "UserBox" : "UserCell";
			const before = js ? null : ctorOf(classNamed(unit.program, className)!);
			const beforeSym: Symbol | null = before != null ? before.resolvedSym : null;
			const lowered = transformProgram(monomorphizeProgram(unit.program, unit.ctx), unit.ctx, js);
			const init = liftedInit(lowered, className + "_init");
			if (js) continue;
			assert init != null, className;
			assert init.resolvedSym != null && init.resolvedSym.item > 0, className;
			if (className == "UserBox") assert beforeSym != null && init.resolvedSym == beforeSym, className;
			assert init.resolvedSym.declNode == init, className;
		}
	}
}

test "constructorOrigin: the constructor of a generic class instance is a routine symbol of its own" {
	const unit = checkedUnit("class UserBox<T> { v: T; constructor(v: T) { this.v = v; } }\nfunction userMake(): UserBox<number> { return new UserBox<number>(1); }", false);
	let found: Node | null = null;
	for (const row of unit.ctx.generatedInstances) {
		if (row.kind == NodeKind.ClassDecl) found = ctorOf(row);
	}
	assert found != null && found.resolvedSym != null;
	assert found.resolvedSym.name.endsWith("_init") && found.resolvedSym.item > 0;
}

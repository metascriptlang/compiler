import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { checkProgramWithRegistry, preludeContextFor } from "../../checker/checkPass";
import { CheckerContext, ExportRegistry } from "../../checker/context";
import { transformProgram } from "../../transform/index";
import { Node, NodeKind, Symbol, SymbolKind, ProgramData, ClassDeclData, ActorDeclData, FunctionDeclData, NewExprData, CallExprData, IdentifierData } from "../../ast/node";
import { Module, ModuleGraph } from "../../module/graph";
import { resetBuildState } from "../../compiler/buildSession";
import { forEachChild } from "../../ast/visitor";
import { ctorFormalTypes } from "../../checker/ctorRoutine";
import { checkModuleGraph } from "../../checker/orchestrator";
import { lookupModuleProgram } from "../../checker/instantiate";
import { MapEntry, createMapProvider, loadModuleGraph, canonicalModulePath } from "../../module/loader";
import { TypeKind } from "../../ast/node";

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
			const lowered = transformProgram(unit.program, unit.ctx, js);
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

function newExprs(n: Node | null, out: Node[]): void {
	if (n == null) return;
	if (n.kind == NodeKind.NewExpr) out.push(n);
	forEachChild(n, (c: Node): void => { newExprs(c, out); });
}

function superCalls(n: Node | null, out: Node[]): void {
	if (n == null) return;
	if (n.kind == NodeKind.CallExpr) {
		const callee = (n.data as CallExprData).callee;
		if (callee.kind == NodeKind.Identifier && (callee.data as IdentifierData).name == "super") out.push(n);
	}
	forEachChild(n, (c: Node): void => { superCalls(c, out); });
}

function onlyNew(program: Node): Node {
	const found: Node[] = [];
	newExprs(program, found);
	if (found.length != 1) throw new Error(`internal: ${found.length} new expressions where the test source has one`);
	return found[0];
}

test "constructorOrigin: new of a class carries the constructor routine and its callee still names the class" {
	const unit = checkedUnit(SOURCES[0], false);
	const ne = onlyNew(unit.program);
	const ctor = ctorOf(classNamed(unit.program, "UserBox")!)!;
	assert ne.resolvedSym != null && ne.resolvedSym == ctor.resolvedSym;
	assert ne.resolvedSym.symbolKind == SymbolKind.Function;
	const callee = (ne.data as NewExprData).newCallee.resolvedSym;
	assert callee != null && callee.symbolKind == SymbolKind.Class;
	assert ne.nodeType != null;
}

test "constructorOrigin: super names the parent constructor routine" {
	const unit = checkedUnit("class UserBase { n: number; constructor(n: number) { this.n = n; } }\nclass UserLeaf extends UserBase { constructor(n: number) { super(n); } }", false);
	const calls: Node[] = [];
	superCalls(unit.program, calls);
	assert calls.length == 1;
	const callee = (calls[0].data as CallExprData).callee;
	const parentCtor = ctorOf(classNamed(unit.program, "UserBase")!)!;
	assert callee.resolvedSym != null && callee.resolvedSym == parentCtor.resolvedSym;
}

test "constructorOrigin: new of a generic class instance carries the instance's constructor routine with concrete parameters" {
	const unit = checkedUnit("class UserBox<T> { v: T; constructor(v: T) { this.v = v; } }\nfunction userMake(): UserBox<number> { return new UserBox<number>(1); }", false);
	const ne = onlyNew(unit.program);
	let instanceCtor: Node | null = null;
	for (const row of unit.ctx.generatedInstances) {
		if (row.kind == NodeKind.ClassDecl) instanceCtor = ctorOf(row);
	}
	assert instanceCtor != null && ne.resolvedSym != null && ne.resolvedSym == instanceCtor.resolvedSym;
	const formals = ctorFormalTypes(ne.resolvedSym);
	assert formals != null && formals.length == 1 && formals[0].kind == TypeKind.Number;
}

test "constructorOrigin: new of a class without a written constructor carries the routine its lifted init keeps" {
	for (const js of [false, true]) {
		const unit = checkedUnit(SOURCES[1], js);
		const ne = onlyNew(unit.program);
		const routine = ne.resolvedSym;
		assert routine != null && routine.symbolKind == SymbolKind.Function, `routine js=${js}`;
		assert routine.declNode == null, `written declaration js=${js}`;
		const lowered = transformProgram(unit.program, unit.ctx, js);
		if (js) {
			const ctor = ctorOf(classNamed(lowered, "UserCell")!)!;
			assert ctor.resolvedSym == routine, "js constructor";
		} else {
			const init = liftedInit(lowered, "UserCell_init");
			assert init != null && init.resolvedSym == routine, "c init";
		}
	}
}

test "constructorOrigin: new of an actor carries the actor's constructor routine" {
	const unit = checkedUnit("actor UserWorker { n: number = 0; constructor(n: number) { this.n = n; } }\nfunction userMake(): void { const w = new UserWorker(1); }", false);
	const ne = onlyNew(unit.program);
	let actorCtor: Node | null = null;
	for (const stmt of (unit.program.data as ProgramData).programStmts) {
		if (stmt.kind != NodeKind.ActorDecl) continue;
		for (const member of (stmt.data as ActorDeclData).actorBody) {
			if (member.kind == NodeKind.ConstructorDecl) actorCtor = member;
		}
	}
	assert actorCtor != null && ne.resolvedSym != null && ne.resolvedSym == actorCtor.resolvedSym;
	const callee = (ne.data as NewExprData).newCallee.resolvedSym;
	assert callee != null && callee.symbolKind == SymbolKind.Actor;
}

test "constructorOrigin: new of a class from another module carries that module's constructor routine" {
	resetBuildState();
	const shape = canonicalModulePath("/proj/shape.ms");
	const main = canonicalModulePath("/proj/main.ms");
	const entries: MapEntry[] = [
		{ entryPath: shape, entrySource: "export class Shape { n: number; constructor(n: number = 2) { this.n = n; } }" },
		{ entryPath: main, entrySource: "import { Shape } from \"./shape\";\nfunction userMake(): Shape { return new Shape(); }" },
	];
	const graph = loadModuleGraph(main, createMapProvider(entries));
	assert graph.errors.length == 0;
	checkModuleGraph(graph, "");
	const ne = onlyNew(lookupModuleProgram(main)!);
	assert ne.resolvedSym != null && ne.resolvedSym.symbolKind == SymbolKind.Function;
	assert ne.resolvedSym.modulePath == shape;
	assert ne.resolvedSym.declNode != null && ne.resolvedSym.declNode.kind == NodeKind.ConstructorDecl;
	assert (ne.data as NewExprData).newArguments.length == 1;
}

test "constructorOrigin: an actor without a constructor lowers with a routine of its own" {
	const unit = checkedUnit("actor UserIdle { n: number = 0; ping(): void { this.n = 1; } }\nfunction userMake(): void { const w = new UserIdle(); }", false);
	const ne = onlyNew(unit.program);
	assert ne.resolvedSym != null && ne.resolvedSym.symbolKind == SymbolKind.Function;
	const lowered = transformProgram(unit.program, unit.ctx, false);
	assert liftedInit(lowered, "UserIdle_init") != null;
}

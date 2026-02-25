import { Node, NodeKind, ProgramData, FunctionDeclData, ClassDeclData, InterfaceDeclData, EnumDeclData, TypeAliasDeclData, ExternDeclData, MacroDeclData, ImportDeclData, ExportDeclData } from "../ast/node";
import { Type, TypeKind, unknownType, createObject, createEnum } from "./types";
import { Symbol, SymbolKind, SymbolTable, ScopeKind, defineSymbol, makeSymbol } from "./symbol";
import { CheckerContext, addError } from "./context";
import { test, check, testGroup } from "std/testing";

// ===== Top-Level Collector =====

export function collectTopLevel(ctx: CheckerContext, program: Node): void {
	const stmts = program.data as ProgramData;
	for (const stmt of stmts.programStmts) {
		collectDecl(ctx, stmt);
	}
}

function collectDecl(ctx: CheckerContext, node: Node): void {
	match (node.kind) {
		NodeKind.FunctionDecl => collectFunction(ctx, node),
		NodeKind.ClassDecl => collectClass(ctx, node),
		NodeKind.InterfaceDecl => collectInterface(ctx, node),
		NodeKind.EnumDecl => collectEnumDecl(ctx, node),
		NodeKind.TypeAliasDecl => collectTypeAlias(ctx, node),
		NodeKind.ExternDecl => collectExtern(ctx, node),
		NodeKind.MacroDecl => collectMacro(ctx, node),
		NodeKind.ImportDecl => collectImport(ctx, node),
		NodeKind.ExportDecl => collectExport(ctx, node),
		_ => {},
	};
}

// ===== Define + Error Helper =====

export function defineOrError(ctx: CheckerContext, sym: Symbol, node: Node): void {
	sym.location = node.location;
	const result = defineSymbol(ctx.table, sym);
	if (!result.ok) {
		addError(ctx, result.error);
	}
}

// ===== Individual Collectors =====

function collectFunction(ctx: CheckerContext, node: Node): void {
	const d = node.data as FunctionDeclData;
	defineOrError(ctx, makeSymbol(d.fnName, SymbolKind.Function, unknownType(), false), node);
}

function collectClass(ctx: CheckerContext, node: Node): void {
	const d = node.data as ClassDeclData;
	defineOrError(ctx, makeSymbol(d.className, SymbolKind.Class, createObject(d.className, [], [], false), false), node);
}

function collectInterface(ctx: CheckerContext, node: Node): void {
	const d = node.data as InterfaceDeclData;
	defineOrError(ctx, makeSymbol(d.interfaceName, SymbolKind.Interface, createObject(d.interfaceName, [], [], true), false), node);
}

function collectEnumDecl(ctx: CheckerContext, node: Node): void {
	const d = node.data as EnumDeclData;
	defineOrError(ctx, makeSymbol(d.enumName, SymbolKind.Enum, createEnum(d.enumName, d.enumMembers), false), node);
}

function collectTypeAlias(ctx: CheckerContext, node: Node): void {
	const d = node.data as TypeAliasDeclData;
	defineOrError(ctx, makeSymbol(d.aliasName, SymbolKind.TypeAlias, unknownType(), false), node);
}

function collectExtern(ctx: CheckerContext, node: Node): void {
	const d = node.data as ExternDeclData;
	const kind = match (d.externKind) {
		"function" => SymbolKind.Function,
		"class" => SymbolKind.Class,
		"interface" => SymbolKind.Interface,
		"enum" => SymbolKind.Enum,
		"type" => SymbolKind.TypeAlias,
		_ => SymbolKind.Variable,
	};
	defineOrError(ctx, makeSymbol(d.externName, kind, unknownType(), false), node);
}

function collectMacro(ctx: CheckerContext, node: Node): void {
	const d = node.data as MacroDeclData;
	defineOrError(ctx, makeSymbol(d.macroDeclName, SymbolKind.Function, unknownType(), false), node);
}

function collectImport(ctx: CheckerContext, node: Node): void {
	const d = node.data as ImportDeclData;
	for (const name of d.importNames) {
		defineOrError(ctx, makeSymbol(name, SymbolKind.Variable, unknownType(), false), node);
	}
}

function collectExport(ctx: CheckerContext, node: Node): void {
	const d = node.data as ExportDeclData;
	collectDecl(ctx, d.exportedDecl);
}

// ===== Tests =====

import { parseSource } from "../parser/statements/validation";
import { lookupSymbol } from "./symbol";
import { createContext } from "./context";

function collectFromSource(input: string): CheckerContext {
	const ctx = createContext();
	const pr = parseSource(input);
	if (!pr.ok) return ctx;
	collectTopLevel(ctx, pr.value);
	return ctx;
}

function hasSymbol(input: string, name: string): boolean {
	const ctx = collectFromSource(input);
	return lookupSymbol(ctx.table, name) !== null;
}

function symbolKindOf(input: string, name: string): SymbolKind {
	const ctx = collectFromSource(input);
	const sym = lookupSymbol(ctx.table, name);
	if (sym === null) return SymbolKind.Variable;
	return sym.symbolKind;
}

testGroup("Collector", () => {
	test("collect function", () => {
		check(hasSymbol("function foo() { return 1; }", "foo"));
		check(symbolKindOf("function foo() { return 1; }", "foo") === SymbolKind.Function);
	});
	test("collect class", () => {
		check(hasSymbol("class Foo {}", "Foo"));
		check(symbolKindOf("class Foo {}", "Foo") === SymbolKind.Class);
	});
	test("collect interface", () => {
		check(hasSymbol("interface Bar {}", "Bar"));
		check(symbolKindOf("interface Bar {}", "Bar") === SymbolKind.Interface);
	});
	test("collect enum", () => {
		check(hasSymbol("enum Color { Red, Green }", "Color"));
		check(symbolKindOf("enum Color { Red, Green }", "Color") === SymbolKind.Enum);
	});
	test("collect type alias", () => {
		check(hasSymbol("type Id = number;", "Id"));
		check(symbolKindOf("type Id = number;", "Id") === SymbolKind.TypeAlias);
	});
	test("collect extern", () => {
		check(hasSymbol("extern function printf(): void;", "printf"));
		check(symbolKindOf("extern function printf(): void;", "printf") === SymbolKind.Function);
	});
	test("collect import", () => {
		const ctx = collectFromSource("import { foo, bar } from \"mod\";");
		check(lookupSymbol(ctx.table, "foo") !== null);
		check(lookupSymbol(ctx.table, "bar") !== null);
	});
	test("collect export", () => {
		check(hasSymbol("export function baz() { return 1; }", "baz"));
		check(symbolKindOf("export function baz() { return 1; }", "baz") === SymbolKind.Function);
	});
	test("skip variables", () => {
		check(!hasSymbol("const x = 1;", "x"));
		check(!hasSymbol("let y = 2;", "y"));
	});
	test("multiple decls", () => {
		const ctx = collectFromSource("function a() { return 1; } class B {} enum C { X }");
		check(lookupSymbol(ctx.table, "a") !== null);
		check(lookupSymbol(ctx.table, "B") !== null);
		check(lookupSymbol(ctx.table, "C") !== null);
	});
});

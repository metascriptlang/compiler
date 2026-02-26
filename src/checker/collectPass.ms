import { Node, NodeKind, ProgramData, FunctionDeclData, ClassDeclData, InterfaceDeclData, EnumDeclData, TypeAliasDeclData, ExternDeclData, MacroDeclData, ImportDeclData, ExportDeclData, VariableDeclData } from "../ast/node";
import { Type, TypeKind, unknownType, createObject, createEnum, createTypeRef } from "./types";
import { Symbol, SymbolKind, SymbolTable, ScopeKind, defineSymbol, makeSymbol, lookupSymbol } from "./symbol";
import { CheckerContext, addError, findExportedSymbol, ExtensionMethod, registerExtension } from "./context";
import { sliceStr, findChar } from "../utils/string";
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
	// Check for extension method: fnFlags contains "ext:receiverName:receiverType"
	if (d.fnFlags.length > 4 && sliceStr(d.fnFlags, 0, 4) === "ext:") {
		// Parse "ext:name:type" — find second colon
		const rest = sliceStr(d.fnFlags, 4, d.fnFlags.length);
		const colonPos = findChar(rest, ":");
		if (colonPos > 0 && ctx.extensionRegistry !== null) {
			const receiverName = sliceStr(rest, 0, colonPos);
			const receiverType = sliceStr(rest, colonPos + 1, rest.length);
			const extMethod: ExtensionMethod = {
				methodName: d.fnName,
				receiverTypeName: receiverType,
				sourcePath: "",
				fnType: unknownType(),
			};
			registerExtension(ctx.extensionRegistry, extMethod);
		}
	}
	// Always define as top-level symbol too (for direct calls)
	defineOrError(ctx, makeSymbol(d.fnName, SymbolKind.Function, unknownType(), false), node);
}

function collectClass(ctx: CheckerContext, node: Node): void {
	const d = node.data as ClassDeclData;
	const classType = createObject(d.className, [], [], false);
	// Store base class info for inheritance (used by destructor lifting)
	if (d.classExtends !== "") {
		classType.typeExtra = createTypeRef(d.classExtends);
	}
	const sym = makeSymbol(d.className, SymbolKind.Class, classType, false);
	defineOrError(ctx, sym, node);
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

// Look up resolved source path for an import specifier from the module's import entries
function resolveImportSourcePath(ctx: CheckerContext, specifier: string): string {
	if (ctx.currentModule === null) return "";
	for (const imp of ctx.currentModule.imports) {
		if (imp.sourceSpecifier === specifier) return imp.sourcePath;
	}
	return "";
}

function collectImport(ctx: CheckerContext, node: Node): void {
	const d = node.data as ImportDeclData;

	// Multi-module mode: resolve types from ExportRegistry
	if (ctx.exportRegistry !== null) {
		const sourcePath = resolveImportSourcePath(ctx, d.importSource);

		let i = 0;
		while (i < d.importNames.length) {
			const importName = d.importNames[i];
			const localAlias = d.importAliases[i];

			if (sourcePath !== "") {
				const exportInfo = findExportedSymbol(ctx.exportRegistry, sourcePath, importName);
				if (exportInfo !== null) {
					// Use actual type and kind from source module
					defineOrError(ctx, makeSymbol(localAlias, exportInfo.kind, exportInfo.symType, false), node);
				} else {
					// Name not found in source module's exports
					addError(ctx, "'" + importName + "' is not exported from '" + d.importSource + "'");
					defineOrError(ctx, makeSymbol(localAlias, SymbolKind.Variable, unknownType(), false), node);
				}
			} else {
				// std import or unresolvable — fallback to unknownType
				defineOrError(ctx, makeSymbol(localAlias, SymbolKind.Variable, unknownType(), false), node);
			}
			i += 1;
		}
		return;
	}

	// Single-module fallback: all imports get unknownType (use aliases for local names)
	for (const alias of d.importAliases) {
		defineOrError(ctx, makeSymbol(alias, SymbolKind.Variable, unknownType(), false), node);
	}
}

function collectExport(ctx: CheckerContext, node: Node): void {
	const d = node.data as ExportDeclData;
	collectDecl(ctx, d.exportedDecl);

	// Re-export case: export { X, Y } from "./mod" — exportedDecl is an ImportDecl
	if (d.exportedDecl.kind === NodeKind.ImportDecl) {
		const imp = d.exportedDecl.data as ImportDeclData;
		for (const alias of imp.importAliases) {
			const sym = lookupSymbol(ctx.table, alias);
			if (sym !== null) {
				sym.isExported = true;
			}
		}
		return;
	}

	// Regular export: single declaration
	const name = getDeclName(d.exportedDecl);
	if (name !== "") {
		const sym = lookupSymbol(ctx.table, name);
		if (sym !== null) {
			sym.isExported = true;
		}
	}
}

// Extract the name from any declaration node
export function getDeclName(node: Node): string {
	return match (node.kind) {
		NodeKind.FunctionDecl => { const d = node.data as FunctionDeclData; d.fnName; },
		NodeKind.ClassDecl => { const d = node.data as ClassDeclData; d.className; },
		NodeKind.InterfaceDecl => { const d = node.data as InterfaceDeclData; d.interfaceName; },
		NodeKind.EnumDecl => { const d = node.data as EnumDeclData; d.enumName; },
		NodeKind.TypeAliasDecl => { const d = node.data as TypeAliasDeclData; d.aliasName; },
		NodeKind.ExternDecl => { const d = node.data as ExternDeclData; d.externName; },
		NodeKind.MacroDecl => { const d = node.data as MacroDeclData; d.macroDeclName; },
		NodeKind.VariableDecl => { const d = node.data as VariableDeclData; d.declName; },
		_ => "",
	};
}

// ===== Tests =====

import { parseSource } from "../parser/statements/validation";
import { lookupSymbol } from "./symbol";
import { createContext, findExtension } from "./context";

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
	test("export marks isExported", () => {
		const ctx = collectFromSource("export function foo() { return 1; }");
		const sym = lookupSymbol(ctx.table, "foo");
		check(sym !== null);
		check(sym.isExported);
	});
	test("non-export not marked", () => {
		const ctx = collectFromSource("function bar() { return 1; }");
		const sym = lookupSymbol(ctx.table, "bar");
		check(sym !== null);
		check(!sym.isExported);
	});
	test("getDeclName function", () => {
		check(getDeclName({ kind: NodeKind.FunctionDecl, location: { line: 0, column: 0 }, data: { fnName: "test", params: [], fnParamTypes: [], fnBody: { kind: NodeKind.BlockStmt, location: { line: 0, column: 0 }, data: { statements: [] } }, fnFlags: "", fnReturnType: "" } }) === "test");
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
	test("re-export marks isExported", () => {
		const ctx = collectFromSource("export { foo, bar } from \"./other\";");
		const fooSym = lookupSymbol(ctx.table, "foo");
		if (fooSym !== null) {
			check(fooSym.isExported);
		} else {
			check(false); // foo should exist
		}
		const barSym = lookupSymbol(ctx.table, "bar");
		if (barSym !== null) {
			check(barSym.isExported);
		} else {
			check(false); // bar should exist
		}
	});
	test("collect extension method", () => {
		const ctx = collectFromSource("function trim(this s: string) { return s; }");
		// Should be registered as both a symbol and an extension
		check(lookupSymbol(ctx.table, "trim") !== null);
		const ext = findExtension(ctx.extensionRegistry, "string", "trim");
		check(ext !== null);
		if (ext !== null) {
			check(ext.methodName === "trim");
			check(ext.receiverTypeName === "string");
		}
	});
	test("non-extension not registered", () => {
		const ctx = collectFromSource("function foo() { return 1; }");
		const ext = findExtension(ctx.extensionRegistry, "", "foo");
		check(ext === null);
	});
	test("re-export with alias marks alias exported", () => {
		const ctx = collectFromSource("export { foo as bar } from \"./other\";");
		const sym = lookupSymbol(ctx.table, "bar");
		if (sym !== null) {
			check(sym.isExported);
		} else {
			check(false); // bar should exist
		}
	});
});

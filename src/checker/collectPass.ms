import { Node, NodeKind, SourceLocation, createNodeAt, ProgramData, FunctionDeclData, ClassDeclData, InterfaceDeclData, EnumDeclData, TypeAliasDeclData, ExternDeclData, MacroDeclData, ImportDeclData, ExportDeclData, VariableDeclData, DecoratedDeclData, PropertyDeclData, MethodDeclData, ExprStmtData, MacroInvocationData, StringLiteralData, DeclKind } from "../ast/node";
import { extractDecoratorInfo } from "./decoratorHelpers";
import { Type, TypeKind, unknownType, createObject, createEnum, createTypeRef, createFunction } from "./types";
import { Symbol, SymbolKind, SymbolTable, ScopeKind, defineSymbol, makeSymbol, lookupSymbol, lookupLocal, setFlag, hasFlag, SF_EXPORTED, SF_MUTABLE, SF_IMPORT_C } from "./symbol";
import { CheckerContext, addError, findExportedSymbol, ExtensionMethod, registerExtension, isStaticExtensionFlag, getExtTypeName } from "./context";
import { isGlobalImport } from "./prelude";
import { sliceStr, findChar } from "../utils/string";
import { check } from "std/testing";

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
		NodeKind.DecoratedDecl => collectDecorated(ctx, node),
		NodeKind.VariableDecl => collectVariable(ctx, node),
		NodeKind.TestDecl => {},
		_ => {},
	};
}

function collectVariable(ctx: CheckerContext, node: Node): void {
	const d = node.data as VariableDeclData;
	const mutable = d.declKind !== DeclKind.Const;
	defineOrError(ctx, makeSymbol(d.declName, SymbolKind.Variable, unknownType(), mutable), node);
}

// ===== Decorator Handling =====

function collectDecorated(ctx: CheckerContext, node: Node): void {
	const dd = node.data as DecoratedDeclData;
	collectDecl(ctx, dd.decoratedNode);
	const declName = getDeclName(dd.decoratedNode);
	if (declName === "") return;
	const sym = lookupSymbol(ctx.table, declName);
	if (sym === null) return;
	const info = extractDecoratorInfo(node);
	// For overloaded functions, the new function was just pushed as the last overload.
	// Set runtimeName/builtinKind on the correct symbol (not the primary).
	// CRITICAL: must write directly through array index — intermediate variable creates a clone (DRC #25).
	if (sym.overloads.length > 0) {
		const idx = sym.overloads.length - 1;
		if (info.runtimeName !== "") sym.overloads[idx].runtimeName = info.runtimeName;
		if (info.builtinKind !== "") sym.overloads[idx].builtinKind = info.builtinKind;
	} else {
		if (info.runtimeName !== "") sym.runtimeName = info.runtimeName;
		if (info.builtinKind !== "") sym.builtinKind = info.builtinKind;
	}
}

// ===== Define + Error Helper =====

export function defineOrError(ctx: CheckerContext, sym: Symbol, node: Node): void {
	sym.location = node.location;
	sym.declNode = node; // Discovery Commitment: link symbol to its declaration node
	const result = defineSymbol(ctx.table, sym);
	if (!result.ok) {
		addError(ctx, result.error);
	}
}

// ===== Individual Collectors =====

function collectFunction(ctx: CheckerContext, node: Node): void {
	const d = node.data as FunctionDeclData;
	// Register extension (instance or static) if applicable
	const extTypeName = getExtTypeName(d.fnFlags);
	if (extTypeName !== "" && ctx.extensionRegistry !== null) {
		const extMethod: ExtensionMethod = {
			methodName: d.fnName,
			receiverTypeName: extTypeName,
			sourcePath: "",
			fnType: unknownType(),
			isStatic: isStaticExtensionFlag(d.fnFlags),
		};
		registerExtension(ctx.extensionRegistry, extMethod);
	}
	// Always define as top-level symbol too (for direct calls)
	const sym = makeSymbol(d.fnName, SymbolKind.Function, unknownType(), false);
	// Extern functions are FFI bindings — implicitly exported for cross-module use
	if (d.fnFlags === "extern" || d.fnFlags.indexOf("extern") >= 0) {
		setFlag(sym, SF_EXPORTED);
		setFlag(sym, SF_IMPORT_C);
	}
	defineOrError(ctx, sym, node);
}

function collectClass(ctx: CheckerContext, node: Node): void {
	const d = node.data as ClassDeclData;
	// Collect member names and types inline, pass to createObject.
	const memberNames: string[] = [];
	const memberTypes: Type[] = [];
	for (let i = 0; i < d.classBody.length; i += 1) {
		const member = d.classBody[i];
		if (member.kind === NodeKind.PropertyDecl) {
			const pd = member.data as PropertyDeclData;
			memberNames.push(pd.propName);
			memberTypes.push(unknownType());
		} else if (member.kind === NodeKind.MethodDecl) {
			const md = member.data as MethodDeclData;
			memberNames.push(md.methodName);
			memberTypes.push(createFunction([], [], unknownType()));
		} else if (member.kind === NodeKind.DecoratedDecl) {
			const dd = member.data as DecoratedDeclData;
			if (dd.decoratedNode.kind === NodeKind.MethodDecl) {
				const md = dd.decoratedNode.data as MethodDeclData;
				const fnType = createFunction([], [], unknownType());
				const info = extractDecoratorInfo(member);
				if (info.runtimeName !== "") {
					fnType.typeName = info.runtimeName;
				}
				if (info.builtinKind !== "") {
					fnType.typeName = info.builtinKind;
				}
				memberNames.push(md.methodName);
				memberTypes.push(fnType);
			}
		}
	}
	const classType = createObject(d.className, memberNames, memberTypes, false);
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
	const enumType = createEnum(d.enumName, d.enumMembers);
	defineOrError(ctx, makeSymbol(d.enumName, SymbolKind.Enum, enumType, false), node);
	// Register each enum member as EnumName_MemberName (Nim parity: skEnumField)
	// Needed because checkMemberExpr rewrites Color.Red → Identifier "Color_Red"
	let mi = 0;
	while (mi < d.enumMembers.length) {
		const mangledName = d.enumName + "_" + d.enumMembers[mi];
		defineOrError(ctx, makeSymbol(mangledName, SymbolKind.Variable, enumType, false), node);
		mi = mi + 1;
	}
	node.nodeType = enumType;
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
	const sym = makeSymbol(d.externName, kind, unknownType(), false);
	// Extern declarations are FFI bindings — implicitly exported for cross-module use
	setFlag(sym, SF_EXPORTED);
	defineOrError(ctx, sym, node);
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

	// std/core is the prelude — already injected into Global scope, skip
	if (isGlobalImport(d.importSource)) return;

	// Multi-module mode: resolve types from ExportRegistry
	if (ctx.exportRegistry !== null) {
		const sourcePath = resolveImportSourcePath(ctx, d.importSource);

		for (let i = 0; i < d.importNames.length; i += 1) {
			const importName = d.importNames[i];
			const localAlias = d.importAliases[i];

			// Dedup: skip if already imported (same file may import same symbol twice, e.g. main + test section)
			if (lookupLocal(ctx.table, localAlias) !== null) continue;

			if (sourcePath !== "") {
				const exportInfo = findExportedSymbol(ctx.exportRegistry, sourcePath, importName);
				if (exportInfo !== null) {
					// Use actual type and kind from source module
					defineOrError(ctx, makeSymbol(localAlias, exportInfo.kind, exportInfo.symType, false), node);
					// Register overloads from source module
					if (exportInfo.overloadTypes.length > 0) {
						const primarySym = lookupLocal(ctx.table, localAlias);
						if (primarySym !== null) {
							let ovIdx = 0;
							while (ovIdx < exportInfo.overloadTypes.length) {
								const ovSym = makeSymbol(localAlias, exportInfo.kind, exportInfo.overloadTypes[ovIdx], false);
								primarySym.overloads.push(ovSym);
								ovIdx = ovIdx + 1;
							}
						}
					}
					// If imported symbol is an extension method, register it locally
					if (exportInfo.extReceiverType !== "" && ctx.extensionRegistry !== null) {
						const extMethod: ExtensionMethod = {
							methodName: localAlias,
							receiverTypeName: exportInfo.extReceiverType,
							sourcePath: sourcePath,
							fnType: exportInfo.symType,
							isStatic: exportInfo.extIsStatic,
						};
						registerExtension(ctx.extensionRegistry, extMethod);
					}
				} else {
					// Name not found in source module's exports
					addError(ctx, "'" + importName + "' is not exported from '" + d.importSource + "'");
					defineOrError(ctx, makeSymbol(localAlias, SymbolKind.Variable, unknownType(), false), node);
				}
			} else {
				// std import or unresolvable — fallback to unknownType
				defineOrError(ctx, makeSymbol(localAlias, SymbolKind.Variable, unknownType(), false), node);
			}
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

	// Re-export case: export { X, Y } from "./mod" — exportedDecl is an ImportDecl
	// When a hub module both imports and re-exports the same symbol, the direct import
	// already defined it. Skip re-import for existing symbols (dedup — same approach
	// as reference compilers using idempotent set-add for import deduplication).
	if (d.exportedDecl.kind === NodeKind.ImportDecl) {
		const imp = d.exportedDecl.data as ImportDeclData;

		if (!isGlobalImport(imp.importSource)) {
			// Import only symbols not already in scope
			for (let i = 0; i < imp.importAliases.length; i += 1) {
				const alias = imp.importAliases[i];
				if (lookupLocal(ctx.table, alias) === null) {
					// Not yet in scope — define it
					if (ctx.exportRegistry !== null) {
						const sourcePath = resolveImportSourcePath(ctx, imp.importSource);
						const importName = imp.importNames[i];
						if (sourcePath !== "") {
							const exportInfo = findExportedSymbol(ctx.exportRegistry, sourcePath, importName);
							if (exportInfo !== null) {
								defineOrError(ctx, makeSymbol(alias, exportInfo.kind, exportInfo.symType, false), node);
							} else {
								addError(ctx, "'" + importName + "' is not exported from '" + imp.importSource + "'");
								defineOrError(ctx, makeSymbol(alias, SymbolKind.Variable, unknownType(), false), node);
							}
						} else {
							defineOrError(ctx, makeSymbol(alias, SymbolKind.Variable, unknownType(), false), node);
						}
					} else {
						defineOrError(ctx, makeSymbol(alias, SymbolKind.Variable, unknownType(), false), node);
					}
				}
			}
		}

		// Mark all as exported (whether freshly imported or pre-existing)
		for (const alias of imp.importAliases) {
			const sym = lookupSymbol(ctx.table, alias);
			if (sym !== null) {
				setFlag(sym, SF_EXPORTED);
			}
		}
		return;
	}

	// Regular export: single declaration
	collectDecl(ctx, d.exportedDecl);
	const name = getDeclName(d.exportedDecl);
	if (name !== "") {
		const sym = lookupSymbol(ctx.table, name);
		if (sym !== null) {
			setFlag(sym, SF_EXPORTED);
		}
	}
}

// Extract the name from any declaration node
export function getDeclName(node: Node): string {
	if (node.kind === NodeKind.DecoratedDecl) {
		const dd = node.data as DecoratedDeclData;
		return getDeclName(dd.decoratedNode);
	}
	if (node.kind === NodeKind.ExportDecl) {
		const d = node.data as ExportDeclData;
		return getDeclName(d.exportedDecl);
	}
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

// ===== Directive Extraction =====

// Extract standalone directives (@name(...);) from program AST.
// Directives are ExprStmt { MacroInvocation } nodes in programStmts.
// Returns encoded strings: "name:arg" (e.g., "include:stdio.h", "passC:-Ifoo").
export function extractDirectives(program: Node): string[] {
	const directives: string[] = [];
	const stmts = (program.data as ProgramData).programStmts;
	for (let i = 0; i < stmts.length; i += 1) {
		const stmt = stmts[i];
		if (stmt.kind === NodeKind.ExprStmt) {
			const es = stmt.data as ExprStmtData;
			if (es.expr.kind === NodeKind.MacroInvocation) {
				const md = es.expr.data as MacroInvocationData;
				let dir = md.macroName;
				if (md.macroArgs.length > 0 && md.macroArgs[0].kind === NodeKind.StringLiteral) {
					dir = dir + ":" + (md.macroArgs[0].data as StringLiteralData).value;
				}
				directives.push(dir);
			}
		}
	}
	return directives;
}

// ===== Tests =====

import { parseSource } from "../parser/statements/validation";
import "../parser/statements/core"; // registers parser callback
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

test "collect function" {
	check(hasSymbol("function foo() { return 1; }", "foo"));
	check(symbolKindOf("function foo() { return 1; }", "foo") === SymbolKind.Function);
}

test "collect class" {
	check(hasSymbol("class Foo {}", "Foo"));
	check(symbolKindOf("class Foo {}", "Foo") === SymbolKind.Class);
}

test "collect interface" {
	check(hasSymbol("interface Bar {}", "Bar"));
	check(symbolKindOf("interface Bar {}", "Bar") === SymbolKind.Interface);
}

test "collect enum" {
	check(hasSymbol("enum Color { Red, Green }", "Color"));
	check(symbolKindOf("enum Color { Red, Green }", "Color") === SymbolKind.Enum);
}

test "collect enum members as symbols" {
	check(hasSymbol("enum Color { Red, Green, Blue }", "Color_Red"));
	check(hasSymbol("enum Color { Red, Green, Blue }", "Color_Green"));
	check(hasSymbol("enum Color { Red, Green, Blue }", "Color_Blue"));
}

test "collect type alias" {
	check(hasSymbol("type Id = number;", "Id"));
	check(symbolKindOf("type Id = number;", "Id") === SymbolKind.TypeAlias);
}

test "collect extern" {
	check(hasSymbol("extern function printf(): void;", "printf"));
	check(symbolKindOf("extern function printf(): void;", "printf") === SymbolKind.Function);
}

test "collect import" {
	const ctx = collectFromSource("import { foo, bar } from \"mod\";");
	check(lookupSymbol(ctx.table, "foo") !== null);
	check(lookupSymbol(ctx.table, "bar") !== null);
}

test "collect export" {
	check(hasSymbol("export function baz() { return 1; }", "baz"));
	check(symbolKindOf("export function baz() { return 1; }", "baz") === SymbolKind.Function);
}

test "export marks isExported" {
	const ctx = collectFromSource("export function foo() { return 1; }");
	const sym = lookupSymbol(ctx.table, "foo");
	check(sym !== null);
	check(hasFlag(sym, SF_EXPORTED));
}

test "non-export not marked" {
	const ctx = collectFromSource("function bar() { return 1; }");
	const sym = lookupSymbol(ctx.table, "bar");
	check(sym !== null);
	check(!hasFlag(sym, SF_EXPORTED));
}

test "getDeclName function" {
	const zl: SourceLocation = { line: 0, column: 0 };
	check(getDeclName(createNodeAt(NodeKind.FunctionDecl, { fnName: "test", params: [], fnParamTypes: [], fnBody: createNodeAt(NodeKind.BlockStmt, { statements: [] }, zl), fnFlags: "", fnReturnType: "" }, zl)) === "test");
}

test "collect variables in pass 1" {
	check(hasSymbol("const x = 1;", "x"));
	check(hasSymbol("let y = 2;", "y"));
}

test "multiple decls" {
	const ctx = collectFromSource("function a() { return 1; } class B {} enum C { X }");
	check(lookupSymbol(ctx.table, "a") !== null);
	check(lookupSymbol(ctx.table, "B") !== null);
	check(lookupSymbol(ctx.table, "C") !== null);
}

test "re-export marks isExported" {
	const ctx = collectFromSource("export { foo, bar } from \"./other\";");
	const fooSym = lookupSymbol(ctx.table, "foo");
	if (fooSym !== null) {
		check(hasFlag(fooSym, SF_EXPORTED));
	} else {
		check(false); // foo should exist
	}
	const barSym = lookupSymbol(ctx.table, "bar");
	if (barSym !== null) {
		check(hasFlag(barSym, SF_EXPORTED));
	} else {
		check(false); // bar should exist
	}
}

test "collect extension method" {
	const ctx = collectFromSource("function trim(this s: string) { return s; }");
	// Should be registered as both a symbol and an extension
	check(lookupSymbol(ctx.table, "trim") !== null);
	const ext = findExtension(ctx.extensionRegistry, "string", "trim");
	check(ext !== null);
	if (ext !== null) {
		check(ext.methodName === "trim");
		check(ext.receiverTypeName === "string");
	}
}

test "non-extension not registered" {
	const ctx = collectFromSource("function foo() { return 1; }");
	const ext = findExtension(ctx.extensionRegistry, "", "foo");
	check(ext === null);
}

test "re-export with alias marks alias exported" {
	const ctx = collectFromSource("export { foo as bar } from \"./other\";");
	const sym = lookupSymbol(ctx.table, "bar");
	if (sym !== null) {
		check(hasFlag(sym, SF_EXPORTED));
	} else {
		check(false); // bar should exist
	}
}

test "decorator @runtime sets runtimeName" {
	const ctx = collectFromSource("@runtime(\"msFloor\") function floor(x: number): number { return x; }");
	const sym = lookupSymbol(ctx.table, "floor");
	check(sym !== null);
	if (sym !== null) {
		check(sym.runtimeName === "msFloor");
	}
}

test "decorator @builtin sets builtinKind" {
	const ctx = collectFromSource("@builtin(\"LengthStr\") function len(s: string): number { return 0; }");
	const sym = lookupSymbol(ctx.table, "len");
	check(sym !== null);
	if (sym !== null) {
		check(sym.builtinKind === "LengthStr");
	}
}

test "overloaded @builtin routes to correct overload" {
	const ctx = collectFromSource("function len(s: string): number { return 0; }\n@builtin(\"LengthArr\") function len(arr: number[]): number { return 0; }");
	const sym = lookupSymbol(ctx.table, "len");
	check(sym !== null);
	if (sym !== null) {
		// Primary (first len) should NOT have builtinKind
		check(sym.builtinKind === "");
		// Overload (second len) should have builtinKind
		check(sym.overloads.length === 1);
		if (sym.overloads.length > 0) {
			check(sym.overloads[0].builtinKind === "LengthArr");
		}
	}
}

test "no decorator leaves fields empty" {
	const ctx = collectFromSource("function foo() { return 1; }");
	const sym = lookupSymbol(ctx.table, "foo");
	check(sym !== null);
	if (sym !== null) {
		check(sym.runtimeName === "");
		check(sym.builtinKind === "");
	}
}

test "decorated export parses" {
	// Full collect crashes (DRC heap-use-after-free on nested DecoratedDecl+ExportDecl)
	// Parse-level validation only for now
	const r = parseSource("@runtime(\"msF\") export function f(): number { return 0; }");
	check(r.ok);
}

test "standalone directive parses" {
	const r = parseSource("@emit(\"#include <stdio.h>\");");
	check(r.ok);
}

test "import + re-export dedup does not error" {
	// import { X } from "./mod" + export { X } from "./mod" should not produce duplicate error
	const ctx = collectFromSource("import { foo } from \"./other\";\nexport { foo } from \"./other\";");
	check(ctx.errors.length === 0);
	const sym = lookupSymbol(ctx.table, "foo");
	check(sym !== null);
	if (sym !== null) {
		check(hasFlag(sym, SF_EXPORTED));
	}
}

test "VariableDecl collected in pass 1" {
	const ctx = collectFromSource("export const x = 42;");
	const sym = lookupSymbol(ctx.table, "x");
	check(sym !== null);
	if (sym !== null) {
		check(hasFlag(sym, SF_EXPORTED));
	}
}

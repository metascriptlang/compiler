import { Node, NodeKind, SourceLocation, createNodeAt, makeLoc, ProgramData, FunctionDeclData, ClassDeclData, InterfaceDeclData, EnumDeclData, TypeAliasDeclData, ExternDeclData, ExternKind, MacroDeclData, ImportDeclData, ExportDeclData, VariableDeclData, DecoratedDeclData, PropertyDeclData, MethodDeclData, ExprStmtData, MacroInvocationData, StringLiteralData, DeclKind } from "../ast/node";
import { extractDecoratorInfo } from "./decoratorHelpers";
import { Type, TypeKind, unknownType, emptyType, createStruct, createEnum, createTypeRef, createFunction, createRef } from "./types";
import { Symbol, SymbolKind, SymbolTable, ScopeKind, defineSymbol, makeSymbol, lookupSymbol, lookupLocal, setFlag, hasFlag, SymbolFlag } from "./symbol";
import { CheckerContext, ExportedSymInfo, addError, findExportedSymbol, findModuleExports, ExtensionMethod, registerExtension, isStaticExtensionFlag, getExtTypeName, findExtension, sgRecordSym } from "./context";
import { isGlobalImport } from "./prelude";
import { ModuleGraph } from "../module/graph";
import { sliceStr, findChar, getModuleDir, appendFlag } from "../utils/string";

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
		NodeKind.VariableDecl => {
			collectVariable(ctx, node);
			// Reference parity: global flag on module-level variables
			const gSym = lookupLocal(ctx.table, (node.data as VariableDeclData).declName);
			if (gSym !== null) setFlag(gSym, SymbolFlag.Global);
		},
		NodeKind.TestDecl => {},
		_ => {},
	};
}

// ===== Local-Only Collector (Phase 1 — skips imports) =====
// Implementation parity: registers module's own declarations before cross-module import resolution.
// Used in two-phase checkModuleGraph to pre-populate ExportRegistry with names+kinds.

export function collectTopLevelLocal(ctx: CheckerContext, program: Node): void {
	const stmts = program.data as ProgramData;
	for (const stmt of stmts.programStmts) {
		collectDeclLocal(ctx, stmt);
	}
}

function collectDeclLocal(ctx: CheckerContext, node: Node): void {
	match (node.kind) {
		NodeKind.FunctionDecl => collectFunction(ctx, node),
		NodeKind.ClassDecl => collectClass(ctx, node),
		NodeKind.InterfaceDecl => collectInterface(ctx, node),
		NodeKind.EnumDecl => collectEnumDecl(ctx, node),
		NodeKind.TypeAliasDecl => collectTypeAlias(ctx, node),
		NodeKind.ExternDecl => collectExtern(ctx, node),
		NodeKind.MacroDecl => collectMacro(ctx, node),
		NodeKind.ImportDecl => {},  // skip — registry not ready yet
		NodeKind.ExportDecl => collectExportLocal(ctx, node),
		NodeKind.DecoratedDecl => {
			const dd = node.data as DecoratedDeclData;
			collectDeclLocal(ctx, dd.decoratedNode);
			const declName = getDeclName(dd.decoratedNode);
			if (declName !== "") {
				const sym = lookupSymbol(ctx.table, declName);
				if (sym !== null) {
					const info = extractDecoratorInfo(node);
					if (info.nativeName !== "") sym.nativeName = info.nativeName;
					if (info.builtinKind !== "") sym.builtinKind = info.builtinKind;
				}
			}
		},
		NodeKind.VariableDecl => {
			collectVariable(ctx, node);
			const gSym2 = lookupLocal(ctx.table, (node.data as VariableDeclData).declName);
			if (gSym2 !== null) setFlag(gSym2, SymbolFlag.Global);
		},
		NodeKind.TestDecl => {},
		_ => {},
	};
}

// Mark class method symbols as exported so they're injected cross-module via injectPrelude.
function markClassMethodsExported(ctx: CheckerContext, classNode: Node): void {
	const cd = classNode.data as ClassDeclData;
	for (let ci = 0; ci < cd.classBody.length; ci += 1) {
		// Use resolvedSym set by collectClassMethod — avoids overload ambiguity
		const methodSym = cd.classBody[ci].resolvedSym;
		if (methodSym !== null) {
			setFlag(methodSym, SymbolFlag.Exported);
		}
	}
}

function collectExportLocal(ctx: CheckerContext, node: Node): void {
	const d = node.data as ExportDeclData;
	// Re-export from import: skip in Phase 1 (registry not ready for cross-module)
	if (d.exportedDecl.kind === NodeKind.ImportDecl) return;
	// Regular export: collect the inner declaration and mark exported
	collectDeclLocal(ctx, d.exportedDecl);
	const name = getDeclName(d.exportedDecl);
	if (name !== "") {
		const sym = lookupSymbol(ctx.table, name);
		if (sym !== null) {
			setFlag(sym, SymbolFlag.Exported);
			// For overloaded functions (e.g. asString on uint8[] and JsonValue),
			// the just-defined symbol may be in overloads[]. Mark the latest overload
			// as exported — it's the one that was just defined by collectDeclLocal above.
			if (sym.overloads.length > 0) {
				setFlag(sym.overloads[sym.overloads.length - 1], SymbolFlag.Exported);
			}
		}
	}
	if (d.exportedDecl.kind === NodeKind.ClassDecl) {
		markClassMethodsExported(ctx, d.exportedDecl);
	}
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
	// Set builtinKind on the correct symbol (not the primary).
	// CRITICAL: must write directly through array index — intermediate variable creates a clone (DRC #25).
	if (sym.overloads.length > 0) {
		const idx = sym.overloads.length - 1;
		if (info.builtinKind !== "") sym.overloads[idx].builtinKind = info.builtinKind;
	} else {
		if (info.builtinKind !== "") sym.builtinKind = info.builtinKind;
	}
}

// ===== Define + Error Helper =====

export function defineOrError(ctx: CheckerContext, sym: Symbol, node: Node): void {
	sym.location = node.location;
	sym.declNode = node; // Discovery Commitment: link symbol to its declaration node
	// Implementation parity: stamp module ownership — set once at creation
	if (sym.modulePath === "") sym.modulePath = ctx.modulePath;
	const result = defineSymbol(ctx.table, sym);
	if (!result.ok) {
		addError(ctx, result.error, node.location.line, node.location.column);
	}
}

// ===== Individual Collectors =====

function collectFunction(ctx: CheckerContext, node: Node): void {
	const d = node.data as FunctionDeclData;
	// Define symbol first — needed so extension can link to it
	const sym = makeSymbol(d.fnName, SymbolKind.Function, unknownType(), false);
	// Extern functions are FFI bindings — implicitly exported for cross-module use
	if (d.fnFlags === "extern" || d.fnFlags.indexOf("extern", 0) >= 0) {
		setFlag(sym, SymbolFlag.Exported);
		setFlag(sym, SymbolFlag.ImportC);
		// Wire nativeName from AST 'from "c_name"' clause
		if (d.nativeName !== null && d.nativeName !== "") {
			sym.nativeName = d.nativeName;
		} else {
			// extern without 'from' — function name IS the C name (no module mangling)
			sym.nativeName = d.fnName;
		}
	}
	defineOrError(ctx, sym, node);
	// Register extension (instance or static) with direct sym link
	const extTypeName = getExtTypeName(d.fnFlags);
	if (extTypeName !== "" && ctx.extensionRegistry !== null) {
		const extMethod: ExtensionMethod = {
			methodName: d.fnName,
			receiverTypeName: extTypeName,
			sourcePath: "",
			fnType: unknownType(),
			isStatic: isStaticExtensionFlag(d.fnFlags),
			sym: sym,
			scopeDepth: 1,  // current module; injectPrelude resets to 0 for imported
		};
		registerExtension(ctx.extensionRegistry, extMethod);
	}
}

function collectClass(ctx: CheckerContext, node: Node): void {
	const d = node.data as ClassDeclData;
	// Reference parity: struct contains DATA fields only, never methods.
	// Methods are standalone procs resolved via extension registry.
	const memberNames: string[] = [];
	const memberTypes: Type[] = [];
	for (let i = 0; i < d.classBody.length; i += 1) {
		const member = d.classBody[i];
		if (member.kind === NodeKind.PropertyDecl) {
			const pd = member.data as PropertyDeclData;
			memberNames.push(pd.propName);
			memberTypes.push(unknownType());
		}
	}
	const innerType = createStruct(d.className, memberNames, memberTypes, true);
	if (d.classExtends !== "") {
		innerType.typeExtra = createTypeRef(d.classExtends);
	}
	const classType = createRef(innerType);
	const sym = makeSymbol(d.className, SymbolKind.Class, classType, false);
	defineOrError(ctx, sym, node);
	// Register methods as extensions — reference parity: procedures are separate from object types.
	// Static → static extension (typeof ClassName). Instance → instance extension.
	if (ctx.extensionRegistry !== null) {
		for (let si = 0; si < d.classBody.length; si += 1) {
			collectClassMethod(ctx, d.className, d.classBody[si]);
		}
	}
}

function collectClassMethod(ctx: CheckerContext, className: string, member: Node): void {
	let builtinKind = "";
	let methodNode: Node = null as unknown as Node;
	if (member.kind === NodeKind.MethodDecl) {
		methodNode = member;
	} else if (member.kind === NodeKind.DecoratedDecl) {
		const dd = member.data as DecoratedDeclData;
		if (dd.decoratedNode.kind === NodeKind.MethodDecl) {
			methodNode = dd.decoratedNode;
			const info = extractDecoratorInfo(member);
			builtinKind = info.builtinKind;
		}
	}
	if (methodNode === null) return;
	const md = methodNode.data as MethodDeclData;
	// Instance methods: prepend receiver as first param — same as standalone extensions.
	// After this, md.methodParams = ["this", ...userParams], md.methodParamTypes = [className, ...userTypes].
	// All downstream phases (resolve, check, codegen) read the same data — zero special cases.
	if (!md.methodIsStatic) {
		const newParams: string[] = ["this"];
		const newTypes: string[] = [className];
		for (let pi = 0; pi < md.methodParams.length; pi += 1) {
			newParams.push(md.methodParams[pi]);
		}
		for (let pi = 0; pi < md.methodParamTypes.length; pi += 1) {
			newTypes.push(md.methodParamTypes[pi]);
		}
		md.methodParams = newParams;
		md.methodParamTypes = newTypes;
	}
	const fnType = createFunction([], [], unknownType());
	if (md.nativeName !== null && md.nativeName !== "") {
		fnType.typeName = md.nativeName;
	}
	if (builtinKind !== "") {
		fnType.typeName = builtinKind;
	}
	const mangledName = className + "_" + md.methodName;
	const methodSym = makeSymbol(mangledName, SymbolKind.Function, fnType, false);
	if (md.nativeName !== null && md.nativeName !== "") {
		methodSym.nativeName = md.nativeName;
	}
	if (builtinKind !== "") {
		methodSym.builtinKind = builtinKind;
	}
	defineOrError(ctx, methodSym, member);
	// Link node → symbol so resolvePass finds the exact sym (not an overload)
	member.resolvedSym = methodSym;
	registerExtension(ctx.extensionRegistry, {
		methodName: mangledName,
		receiverTypeName: className,
		sourcePath: "",
		fnType: fnType,
		isStatic: md.methodIsStatic,
		sym: methodSym,
		scopeDepth: 1,
	});
}

function collectInterface(ctx: CheckerContext, node: Node): void {
	const d = node.data as InterfaceDeclData;
	defineOrError(ctx, makeSymbol(d.interfaceName, SymbolKind.Interface, createStruct(d.interfaceName, [], [], true), false), node);
}

function collectEnumDecl(ctx: CheckerContext, node: Node): void {
	const d = node.data as EnumDeclData;
	const enumValues = d.enumValues !== null ? d.enumValues : [] as number[];
	const enumType = createEnum(d.enumName, d.enumMembers, enumValues);
	const enumSym = makeSymbol(d.enumName, SymbolKind.Enum, enumType, false);
	defineOrError(ctx, enumSym, node);
	// Record enum type DEF for symbol graph
	sgRecordSym(ctx, d.nameLocation.line, d.nameLocation.column, d.nameLocation.column + d.enumName.length, enumSym, enumType, SymbolKind.Enum, d.enumName, "", true);
	// Register each enum member as EnumName_MemberName (standard implementation parity)
	// Needed because checkMemberExpr rewrites Color.Red → Identifier "Color_Red"
	let mi = 0;
	while (mi < d.enumMembers.length) {
		const mangledName = d.enumName + "_" + d.enumMembers[mi];
		const memberSym = makeSymbol(mangledName, SymbolKind.Variable, enumType, false);
		defineOrError(ctx, memberSym, node);
		// Record each enum member DEF for symbol graph
		// (no per-member location available; use enum node location as fallback)
		sgRecordSym(ctx, node.location.line, node.location.column, node.location.column + d.enumMembers[mi].length, memberSym, enumType, SymbolKind.EnumMember, d.enumMembers[mi], d.enumName, true);
		mi = mi + 1;
	}
	node.nodeType = enumType;
}

function collectTypeAlias(ctx: CheckerContext, node: Node): void {
	const d = node.data as TypeAliasDeclData;
	// Fresh type (not singleton unknownType) — resolvePass will assignType in-place (reference: tyForward)
	defineOrError(ctx, makeSymbol(d.aliasName, SymbolKind.TypeAlias, emptyType(), false), node);
}

function collectExtern(ctx: CheckerContext, node: Node): void {
	const d = node.data as ExternDeclData;
	const kind = match (d.externKind) {
		ExternKind.Function => SymbolKind.Function,
		ExternKind.Class => SymbolKind.Class,
		ExternKind.Interface => SymbolKind.Interface,
		ExternKind.Enum => SymbolKind.Enum,
		ExternKind.Type => SymbolKind.TypeAlias,
		_ => SymbolKind.Variable,
	};
	const sym = makeSymbol(d.externName, kind, unknownType(), false);
	// Extern declarations are FFI bindings — implicitly exported for cross-module use
	setFlag(sym, SymbolFlag.Exported);
	setFlag(sym, SymbolFlag.ImportC);
	// Wire nativeName from AST 'from "c_name"' clause
	if (d.nativeName !== null && d.nativeName !== "") {
		sym.nativeName = d.nativeName;
	} else {
		sym.nativeName = d.externName;
	}
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

// Check if a symbol name is an operator (all operator chars, or [] / []=).
// Used for auto-propagation of exported operator overloads.
function isOperatorSymName(name: string): boolean {
	if (name.length === 0) return false;
	if (name === "[]" || name === "[]=") return true;
	let i = 0;
	while (i < name.length) {
		const ch = name.charCodeAt(i);
		if (ch !== "|".code && ch !== ">".code && ch !== "<".code && ch !== "=".code
			&& ch !== "+".code && ch !== "-".code && ch !== "*".code && ch !== "/".code
			&& ch !== "%".code && ch !== "&".code && ch !== "^".code && ch !== "~".code
			&& ch !== "!".code && ch !== "?".code && ch !== ".".code && ch !== "\\".code) {
			return false;
		}
		i = i + 1;
	}
	return true;
}

// Resolve the original defining module path from ExportedSymInfo
function resolveDefiningModule(info: ExportedSymInfo, fallback: string): string {
	return info.definingModule !== "" ? info.definingModule : fallback;
}

// Resolve the original declared name from ExportedSymInfo
function resolveOriginalName(info: ExportedSymInfo, importName: string): string {
	return info.originalName !== "" ? info.originalName : importName;
}

function collectImport(ctx: CheckerContext, node: Node): void {
	const d = node.data as ImportDeclData;

	// std/core is the prelude — already injected into Global scope, skip
	if (isGlobalImport(d.importSource)) return;

	// Resolve types from ExportRegistry
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
				// Preserve original defining module (owner), not the re-exporting hub
				const importedSym = makeSymbol(localAlias, exportInfo.kind, exportInfo.symType, false);
				importedSym.modulePath = resolveDefiningModule(exportInfo, sourcePath);
				// Preserve original declared name for C mangling (chain re-exports handled)
				const origName = resolveOriginalName(exportInfo, importName);
				if (origName !== localAlias) importedSym.originalName = origName;
				defineOrError(ctx, importedSym, node);
				// Record imported symbol as usage (isDecl=false)
				sgRecordSym(ctx, node.location.line, node.location.column, node.location.column + localAlias.length, importedSym, exportInfo.symType, exportInfo.kind, localAlias, "", false);
				// Implementation parity: import enum members alongside enum type
				// (rawImportSymbol registers each skEnumField in the importing scope)
				if (exportInfo.kind === SymbolKind.Enum && exportInfo.symType.typeNames !== null) {
					const enumTypeName = exportInfo.symType.typeName;
					let mi = 0;
					while (mi < exportInfo.symType.typeNames.length) {
						const mangledName = enumTypeName + "_" + exportInfo.symType.typeNames[mi];
						if (lookupLocal(ctx.table, mangledName) === null) {
							defineOrError(ctx, makeSymbol(mangledName, SymbolKind.Variable, exportInfo.symType, false), node);
						}
						mi = mi + 1;
					}
				}
				const primarySym = lookupLocal(ctx.table, localAlias);
				// Restore cross-module metadata (nativeName, builtinKind, defaults)
				if (primarySym !== null) {
					if (exportInfo.nativeName !== "") primarySym.nativeName = exportInfo.nativeName;
					if (exportInfo.builtinKind !== "") primarySym.builtinKind = exportInfo.builtinKind;
					if (exportInfo.defaultParams !== null && exportInfo.defaultParams.length > 0) primarySym.defaultParams = exportInfo.defaultParams;
					if (exportInfo.headerPath !== "") primarySym.headerPath = exportInfo.headerPath;
				}
				// Propagate -iquote for header search path
				if (exportInfo.headerPath !== "" && exportInfo.definingModule !== "") {
					const searchDir = getModuleDir(exportInfo.definingModule);
					if (searchDir !== "") ctx.compilerFlags = appendFlag(ctx.compilerFlags, "-iquote" + searchDir);
				}
				// Register overloads from source module
				if (exportInfo.overloadTypes.length > 0 && primarySym !== null) {
					let ovIdx = 0;
					while (ovIdx < exportInfo.overloadTypes.length) {
						const ovSym = makeSymbol(localAlias, exportInfo.kind, exportInfo.overloadTypes[ovIdx], false);
						ovSym.modulePath = resolveDefiningModule(exportInfo, sourcePath);
						const ovOrigName = resolveOriginalName(exportInfo, importName);
						if (ovOrigName !== localAlias) ovSym.originalName = ovOrigName;
						// Restore per-overload cross-module metadata
						if (exportInfo.overloadNativeNames !== null && ovIdx < exportInfo.overloadNativeNames.length && exportInfo.overloadNativeNames[ovIdx] !== "") {
							ovSym.nativeName = exportInfo.overloadNativeNames[ovIdx];
						}
						if (exportInfo.overloadBuiltinKinds !== null && ovIdx < exportInfo.overloadBuiltinKinds.length && exportInfo.overloadBuiltinKinds[ovIdx] !== "") {
							ovSym.builtinKind = exportInfo.overloadBuiltinKinds[ovIdx];
						}
						if (exportInfo.overloadDefaultParamsFlat !== null && exportInfo.overloadDefaultParamsCounts !== null && ovIdx < exportInfo.overloadDefaultParamsCounts.length) {
							const cnt = exportInfo.overloadDefaultParamsCounts[ovIdx];
							if (cnt > 0) {
								let offset = 0;
								let ci = 0;
								while (ci < ovIdx) { offset = offset + exportInfo.overloadDefaultParamsCounts[ci]; ci = ci + 1; }
								const dps: Node[] = [];
								let di = 0;
								while (di < cnt) { dps.push(exportInfo.overloadDefaultParamsFlat[offset + di]); di = di + 1; }
								ovSym.defaultParams = dps;
							}
						}
						if (exportInfo.headerPath !== "") ovSym.headerPath = exportInfo.headerPath;
						primarySym.overloads.push(ovSym);
						// Register per-overload extension if it has one
						if (ctx.extensionRegistry !== null && exportInfo.overloadExtReceiverTypes !== null && ovIdx < exportInfo.overloadExtReceiverTypes.length && exportInfo.overloadExtReceiverTypes[ovIdx] !== "") {
							const ovExt: ExtensionMethod = {
								methodName: localAlias,
								receiverTypeName: exportInfo.overloadExtReceiverTypes[ovIdx],
								sourcePath: sourcePath,
								fnType: exportInfo.overloadTypes[ovIdx],
								isStatic: exportInfo.overloadExtIsStatic[ovIdx],
								sym: ovSym,
								scopeDepth: 1,  // explicit import into module scope
							};
							registerExtension(ctx.extensionRegistry, ovExt);
						}
						ovIdx = ovIdx + 1;
					}
				}
				// If imported symbol is an extension method, register primary locally
				if (exportInfo.extReceiverType !== "" && ctx.extensionRegistry !== null) {
					const extMethod: ExtensionMethod = {
						methodName: localAlias,
						receiverTypeName: exportInfo.extReceiverType,
						sourcePath: sourcePath,
						fnType: exportInfo.symType,
						isStatic: exportInfo.extIsStatic,
						sym: primarySym !== null ? primarySym : null as unknown as Symbol,
						scopeDepth: 1,  // explicit import into module scope
					};
					registerExtension(ctx.extensionRegistry, extMethod);
				}
			} else {
				// Name not found in source module's exports
				// Suppress error for circular back-edges (Phase 1 placeholders may lack this name)
				const isCircular = ctx.moduleGraph !== null
					&& ctx.currentModule !== null
					&& isCircularBackEdge(ctx.moduleGraph, ctx.currentModule.path, sourcePath);
				if (!isCircular) {
					addError(ctx, "'" + importName + "' is not exported from '" + d.importSource + "'", node.location.line, node.location.column);
				}
				defineOrError(ctx, makeSymbol(localAlias, SymbolKind.Variable, unknownType(), false), node);
			}
		} else {
			// std import or unresolvable — fallback to unknownType
			defineOrError(ctx, makeSymbol(localAlias, SymbolKind.Variable, unknownType(), false), node);
		}
	}

	// Auto-propagate exported operator overloads from imported module.
	// When you import anything from a module, all its exported operator functions
	// become available automatically — no need to import them by name.
	if (ctx.extensionRegistry !== null && sourcePath !== "") {
		const modExports = findModuleExports(ctx.exportRegistry, sourcePath);
		if (modExports !== null) {
			for (const sym of modExports.symbols) {
				if (sym.extReceiverType !== "" && isOperatorSymName(sym.name)) {
					// Only register if not already present
					if (findExtension(ctx.extensionRegistry, sym.extReceiverType, sym.name) === null) {
						const opExt: ExtensionMethod = {
							methodName: sym.name,
							receiverTypeName: sym.extReceiverType,
							sourcePath: sourcePath,
							fnType: sym.symType,
							isStatic: sym.extIsStatic,
							sym: null as unknown as Symbol,
							scopeDepth: 0,  // imported
						};
						registerExtension(ctx.extensionRegistry, opExt);
					}
				}
			}
		}
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
					const sourcePath = resolveImportSourcePath(ctx, imp.importSource);
					const importName = imp.importNames[i];
					if (sourcePath !== "") {
						const exportInfo = findExportedSymbol(ctx.exportRegistry, sourcePath, importName);
						if (exportInfo !== null) {
							const reExpSym = makeSymbol(alias, exportInfo.kind, exportInfo.symType, false);
							reExpSym.modulePath = resolveDefiningModule(exportInfo, sourcePath);
							const origN = resolveOriginalName(exportInfo, importName);
							if (origN !== alias) reExpSym.originalName = origN;
							if (exportInfo.nativeName !== "") reExpSym.nativeName = exportInfo.nativeName;
							if (exportInfo.headerPath !== "") reExpSym.headerPath = exportInfo.headerPath;
							defineOrError(ctx, reExpSym, node);
						} else {
							const isCirc = ctx.moduleGraph !== null
								&& ctx.currentModule !== null
								&& isCircularBackEdge(ctx.moduleGraph, ctx.currentModule.path, sourcePath);
							if (!isCirc) {
								addError(ctx, "'" + importName + "' is not exported from '" + imp.importSource + "'", node.location.line, node.location.column);
							}
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
				setFlag(sym, SymbolFlag.Exported);
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
			setFlag(sym, SymbolFlag.Exported);
			// For overloaded functions, also mark the latest overload as exported.
			// defineSymbol appends to overloads[], so last entry is the just-defined one.
			if (sym.overloads.length > 0) {
				setFlag(sym.overloads[sym.overloads.length - 1], SymbolFlag.Exported);
			}
		}
	}
	if (d.exportedDecl.kind === NodeKind.ClassDecl) {
		markClassMethodsExported(ctx, d.exportedDecl);
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
		NodeKind.FunctionDecl => { const d = node.data as FunctionDeclData; return d.fnName; },
		NodeKind.ClassDecl => { const d = node.data as ClassDeclData; return d.className; },
		NodeKind.InterfaceDecl => { const d = node.data as InterfaceDeclData; return d.interfaceName; },
		NodeKind.EnumDecl => { const d = node.data as EnumDeclData; return d.enumName; },
		NodeKind.TypeAliasDecl => { const d = node.data as TypeAliasDeclData; return d.aliasName; },
		NodeKind.ExternDecl => { const d = node.data as ExternDeclData; return d.externName; },
		NodeKind.MacroDecl => { const d = node.data as MacroDeclData; return d.macroDeclName; },
		NodeKind.VariableDecl => { const d = node.data as VariableDeclData; return d.declName; },
		_ => "",
	};
}

// ===== Circular Back-Edge Detection =====
// Checks if importing from sourcePath creates a circular dependency for the current module.
// Uses graph.circularDeps recorded by the loader.

function isCircularBackEdge(graph: ModuleGraph, currentPath: string, sourcePath: string): boolean {
	for (const dep of graph.circularDeps) {
		// fromPath is the module that tried to import toPath while toPath was loading
		if (dep.fromPath === currentPath && dep.toPath === sourcePath) return true;
		if (dep.toPath === currentPath && dep.fromPath === sourcePath) return true;
	}
	return false;
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
	assert hasSymbol("function foo() { return 1; }", "foo");
	assert symbolKindOf("function foo() { return 1; }", "foo") === SymbolKind.Function;
}

test "collect class" {
	assert hasSymbol("class Foo {}", "Foo");
	assert symbolKindOf("class Foo {}", "Foo") === SymbolKind.Class;
}

test "collect interface" {
	assert hasSymbol("interface Bar {}", "Bar");
	assert symbolKindOf("interface Bar {}", "Bar") === SymbolKind.Interface;
}

test "collect enum" {
	assert hasSymbol("enum Color { Red, Green }", "Color");
	assert symbolKindOf("enum Color { Red, Green }", "Color") === SymbolKind.Enum;
}

test "collect enum members as symbols" {
	assert hasSymbol("enum Color { Red, Green, Blue }", "Color_Red");
	assert hasSymbol("enum Color { Red, Green, Blue }", "Color_Green");
	assert hasSymbol("enum Color { Red, Green, Blue }", "Color_Blue");
}

test "collect type alias" {
	assert hasSymbol("type Id = number;", "Id");
	assert symbolKindOf("type Id = number;", "Id") === SymbolKind.TypeAlias;
}

test "collect extern" {
	assert hasSymbol("extern function printf(): void;", "printf");
	assert symbolKindOf("extern function printf(): void;", "printf") === SymbolKind.Function;
}

test "collect import" {
	const ctx = collectFromSource("import { foo, bar } from \"mod\";");
	assert lookupSymbol(ctx.table, "foo") !== null;
	assert lookupSymbol(ctx.table, "bar") !== null;
}

test "collect export" {
	assert hasSymbol("export function baz() { return 1; }", "baz");
	assert symbolKindOf("export function baz() { return 1; }", "baz") === SymbolKind.Function;
}

test "export marks isExported" {
	const ctx = collectFromSource("export function foo() { return 1; }");
	const sym = lookupSymbol(ctx.table, "foo");
	assert sym !== null;
	assert hasFlag(sym, SymbolFlag.Exported);
}

test "non-export not marked" {
	const ctx = collectFromSource("function bar() { return 1; }");
	const sym = lookupSymbol(ctx.table, "bar");
	assert sym !== null;
	assert !hasFlag(sym, SymbolFlag.Exported);
}

test "getDeclName function" {
	const zl = makeLoc(0, 0);
	assert getDeclName(createNodeAt(NodeKind.FunctionDecl, { fnName: "test", params: [], fnParamTypes: [], fnBody: createNodeAt(NodeKind.BlockStmt, { statements: [] }, zl), fnFlags: "", fnReturnType: "", fnDefaults: [], nameLocation: zl }, zl)) === "test";
}

test "collect variables in pass 1" {
	assert hasSymbol("const x = 1;", "x");
	assert hasSymbol("let y = 2;", "y");
}

test "multiple decls" {
	const ctx = collectFromSource("function a() { return 1; } class B {} enum C { X }");
	assert lookupSymbol(ctx.table, "a") !== null;
	assert lookupSymbol(ctx.table, "B") !== null;
	assert lookupSymbol(ctx.table, "C") !== null;
}

test "re-export marks isExported" {
	const ctx = collectFromSource("export { foo, bar } from \"./other\";");
	const fooSym = lookupSymbol(ctx.table, "foo");
	if (fooSym !== null) {
		assert hasFlag(fooSym, SymbolFlag.Exported);
	} else {
		assert false; // foo should exist
	}
	const barSym = lookupSymbol(ctx.table, "bar");
	if (barSym !== null) {
		assert hasFlag(barSym, SymbolFlag.Exported);
	} else {
		assert false; // bar should exist
	}
}

test "collect extension method" {
	const ctx = collectFromSource("function trim(this s: string) { return s; }");
	// Should be registered as both a symbol and an extension
	assert lookupSymbol(ctx.table, "trim") !== null;
	const ext = findExtension(ctx.extensionRegistry, "string", "trim");
	assert ext !== null;
	if (ext !== null) {
		assert ext.methodName === "trim";
		assert ext.receiverTypeName === "string";
	}
}

test "non-extension not registered" {
	const ctx = collectFromSource("function foo() { return 1; }");
	const ext = findExtension(ctx.extensionRegistry, "", "foo");
	assert ext === null;
}

test "re-export with alias marks alias exported" {
	const ctx = collectFromSource("export { foo as bar } from \"./other\";");
	const sym = lookupSymbol(ctx.table, "bar");
	if (sym !== null) {
		assert hasFlag(sym, SymbolFlag.Exported);
	} else {
		assert false; // bar should exist
	}
}

test "extern function from sets nativeName" {
	const ctx = collectFromSource("extern function floor(x: number): number from \"msFloor\";");
	const sym = lookupSymbol(ctx.table, "floor");
	assert sym !== null;
	if (sym !== null) {
		assert sym.nativeName === "msFloor";
		assert hasFlag(sym, SymbolFlag.ImportC);
	}
}

test "decorator @builtin sets builtinKind" {
	const ctx = collectFromSource("@builtin(\"LengthStr\") function len(s: string): number { return 0; }");
	const sym = lookupSymbol(ctx.table, "len");
	assert sym !== null;
	if (sym !== null) {
		assert sym.builtinKind === "LengthStr";
	}
}

test "overloaded @builtin routes to correct overload" {
	const ctx = collectFromSource("function len(s: string): number { return 0; }\n@builtin(\"LengthArr\") function len(arr: number[]): number { return 0; }");
	const sym = lookupSymbol(ctx.table, "len");
	assert sym !== null;
	if (sym !== null) {
		// Primary (first len) should NOT have builtinKind
		assert sym.builtinKind === "";
		// Overload (second len) should have builtinKind
		assert sym.overloads.length === 1;
		if (sym.overloads.length > 0) {
			assert sym.overloads[0].builtinKind === "LengthArr";
		}
	}
}

test "@builtin on extern function sets both builtinKind and nativeName" {
	const ctx = collectFromSource("@builtin(\"msResultOk\") extern function ok(val: number): number from \"msResultOk\";");
	const sym = lookupSymbol(ctx.table, "ok");
	assert sym !== null;
	if (sym !== null) {
		assert sym.builtinKind === "msResultOk";
		assert sym.nativeName === "msResultOk";
		assert hasFlag(sym, SymbolFlag.ImportC);
	}
}

test "@builtin on generic extern function" {
	const ctx = collectFromSource("@builtin(\"msResultOk\") extern function ok<T>(val: T): T;");
	const sym = lookupSymbol(ctx.table, "ok");
	assert sym !== null;
	if (sym !== null) {
		assert sym.builtinKind === "msResultOk";
		assert hasFlag(sym, SymbolFlag.ImportC);
	}
}

test "generic extern function with from clause" {
	const ctx = collectFromSource("extern function sort<T>(arr: T[]): T[] from \"msSort\";");
	const sym = lookupSymbol(ctx.table, "sort");
	assert sym !== null;
	if (sym !== null) {
		assert sym.nativeName === "msSort";
		assert hasFlag(sym, SymbolFlag.ImportC);
	}
}

test "no decorator leaves fields empty" {
	const ctx = collectFromSource("function foo() { return 1; }");
	const sym = lookupSymbol(ctx.table, "foo");
	assert sym !== null;
	if (sym !== null) {
		assert sym.nativeName === "";
		assert sym.builtinKind === "";
	}
}

test "decorated export parses" {
	// Full collect crashes (DRC heap-use-after-free on nested DecoratedDecl+ExportDecl)
	// Parse-level validation only for now
	const r = parseSource("@builtin(\"LenStr\") export function f(): number { return 0; }");
	assert r.ok;
}

test "standalone directive parses" {
	const r = parseSource("@emit(\"#include <stdio.h>\");");
	assert r.ok;
}

test "import + re-export dedup does not error" {
	// import { X } from "./mod" + export { X } from "./mod" should not produce duplicate error
	const ctx = collectFromSource("import { foo } from \"./other\";\nexport { foo } from \"./other\";");
	assert ctx.errors.length === 0;
	const sym = lookupSymbol(ctx.table, "foo");
	assert sym !== null;
	if (sym !== null) {
		assert hasFlag(sym, SymbolFlag.Exported);
	}
}

test "VariableDecl collected in pass 1" {
	const ctx = collectFromSource("export const x = 42;");
	const sym = lookupSymbol(ctx.table, "x");
	assert sym !== null;
	if (sym !== null) {
		assert hasFlag(sym, SymbolFlag.Exported);
	}
}

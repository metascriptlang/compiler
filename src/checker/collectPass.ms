import { Node, NodeKind, NodeFlag, SourceLocation, createNodeAt, makeLoc, ProgramData, FunctionDeclData, ClassDeclData, ActorDeclData, InterfaceDeclData, EnumDeclData, TypeAliasDeclData, ExternDeclData, ExternKind, MacroDeclData, ImportDeclData, ExportDeclData, VariableDeclData, DecoratedDeclData, PropertyDeclData, MethodDeclData, ExprStmtData, MacroInvocationData, StringLiteralData, DeclKind, Type, Symbol, SymbolKind, SymbolState } from "../ast/node";
import { extractDecoratorInfo } from "./decoratorHelpers";
import { unknownType, emptyType, createStruct, createEnum, createTypeRef, createFunction, createRef } from "./types";
import { defineSymbol, makeSymbol, lookupSymbol, lookupLocal, setFlag, hasFlag, SymbolFlag } from "./symbol";
import { CheckerContext, ExportedSymInfo, addError, addWarning, findExportedSymbol, findModuleExports, registerExtension, createExtMethod, isStaticExtensionFlag, getExtTypeName, findExtension, sgRecordSym } from "./context";
import { isGlobalImport } from "./prelude";
import { ModuleGraph } from "../module/graph";
import { isCHeaderPath } from "../module/loader";
import { getModuleDir, appendFlag } from "../utils/string";
import { getGenericDecl } from "../parser/context";

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
		NodeKind.ActorDecl => collectActor(ctx, node),
		NodeKind.InterfaceDecl => collectInterface(ctx, node),
		NodeKind.StructDecl => collectStruct(ctx, node),
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
// Registers module's own declarations without processing imports.
// Used by preRegisterStdModule for lightweight export pre-population.
// For full export registration (with field type resolution), use collectTopLevel instead.

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
		NodeKind.ActorDecl => collectActor(ctx, node),
		NodeKind.InterfaceDecl => collectInterface(ctx, node),
		NodeKind.StructDecl => collectStruct(ctx, node),
		NodeKind.EnumDecl => collectEnumDecl(ctx, node),
		NodeKind.TypeAliasDecl => collectTypeAlias(ctx, node),
		NodeKind.ExternDecl => collectExtern(ctx, node),
		NodeKind.MacroDecl => collectMacro(ctx, node),
		NodeKind.ImportDecl => {},  // skip — caller handles imports separately or not at all
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
	if (d.exportedDecl.kind === NodeKind.ActorDecl) {
		const ad = d.exportedDecl.data as ActorDeclData;
		for (let ai = 0; ai < ad.actorBody.length; ai += 1) {
			const methodSym = ad.actorBody[ai].resolvedSym;
			if (methodSym !== null) {
				setFlag(methodSym, SymbolFlag.Exported);
			}
		}
	}
}

function collectVariable(ctx: CheckerContext, node: Node): void {
	const d = node.data as VariableDeclData;
	const mutable = d.declKind !== DeclKind.Const;
	const sym = makeSymbol(d.declName, SymbolKind.Variable, unknownType(), mutable);
	sym.symbolType.sym = sym;
	defineOrError(ctx, sym, node);
	// Reference parity: attach symbol to VarDecl node (like FunctionDecl).
	// DRC uses this for unique naming (s.loc.snippet equivalent).
	// Note: checkPass overwrites this with the type-inferred symbol for checker-visited VarDecls.
	node.resolvedSym = sym;
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
	// REPROMISE T2 Stage C: @awaitable / @affineAwaitable on a class, interface,
	// struct, or type alias registers the name in the awaitable registry. Every
	// subsequent GenericInstance of that name will get the flag bits propagated
	// onto its typeFlags via createGenericInstance, and isAwaitable() will
	// recognize it via the registry.
	// Restrict to type-like declarations — @awaitable on a function or variable
	// makes no sense and would silently pollute the registry (audit finding #125).
	if (info.isAwaitableAnnotated) {
		const innerKind = dd.decoratedNode.kind;
		if (innerKind === NodeKind.ClassDecl || innerKind === NodeKind.InterfaceDecl
			|| innerKind === NodeKind.StructDecl || innerKind === NodeKind.TypeAliasDecl) {
			// registerAwaitableType removed during parallel/concurrency refactor
		} else {
			addWarning(ctx, "@awaitable / @affineAwaitable is only valid on class, interface, struct, or type alias declarations",
				node.location.line, node.location.column);
		}
	}
}

// ===== Define + Error Helper =====

export function defineOrError(ctx: CheckerContext, sym: Symbol, node: Node): void {
	// Only set location if not already preserved from defining module (import parity)
	if (sym.location === null || sym.location.line === 0) sym.location = node.location;
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
	sym.symbolType.sym = sym;
	// Tier 1: overload signature (body-less) — typecheck-only, codegen skips emission
	if (d.fnFlags.indexOf("overload", 0) >= 0) {
		setFlag(sym, SymbolFlag.OverloadSig);
	}
	// Extern functions: mark as C import (export requires explicit `export` keyword)
	if (d.fnFlags === "extern" || d.fnFlags.indexOf("extern", 0) >= 0) {
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
	// Reference parity: attach symbol to declaration node.
	// DRC uses this to get param types and check sfGeneratedOp without lookupSymbol.
	node.resolvedSym = sym;
	// Register extension (instance or static) with direct sym link
	const extTypeName = getExtTypeName(d.fnFlags);
	if (extTypeName !== "" && ctx.extensionRegistry !== null) {
		registerExtension(ctx.extensionRegistry, createExtMethod(d.fnName, extTypeName, "", unknownType(), isStaticExtensionFlag(d.fnFlags), sym, 1));
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
			if (!pd.propIsStatic) {
				memberNames.push(pd.propName);
				memberTypes.push(unknownType());
			}
		}
	}
	const innerType = createStruct(d.className, memberNames, memberTypes, true);
	if (d.classExtends !== "") {
		innerType.typeExtra = createTypeRef(d.classExtends);
	}
	const classType = createRef(innerType);
	const sym = makeSymbol(d.className, SymbolKind.Class, classType, false);
	classType.sym = sym;
	innerType.sym = sym;
	defineOrError(ctx, sym, node);
	// Check for constructor → set HasConstructor flag for codegen
	for (const member of d.classBody) {
		if (member.kind === NodeKind.ConstructorDecl) {
			setFlag(sym, SymbolFlag.HasConstructor);
		}
	}
	// Collect static properties into sym.staticFields
	for (const member of d.classBody) {
		if (member.kind === NodeKind.PropertyDecl) {
			const pd = member.data as PropertyDeclData;
			if (pd.propIsStatic) {
				const staticSym = makeSymbol(d.className + "." + pd.propName, SymbolKind.Variable, unknownType(), true);
				setFlag(staticSym, SymbolFlag.Static);
				staticSym.declNode = member;
				sym.staticFields.push(staticSym);
			}
		}
	}
	// Register methods as extensions — reference parity: procedures are separate from object types.
	// Static → static extension (typeof ClassName). Instance → instance extension.
	if (ctx.extensionRegistry !== null) {
		const classGenerics = getGenericDecl(d.className);
		const isExternClass = (node.flags & NodeFlag.ExternC) !== 0;
		for (let si = 0; si < d.classBody.length; si += 1) {
			collectClassMethod(ctx, d.className, classGenerics, d.classBody[si], isExternClass);
		}
	}
}

function collectActor(ctx: CheckerContext, node: Node): void {
	const d = node.data as ActorDeclData;
	const memberNames: string[] = [];
	const memberTypes: Type[] = [];
	for (const raw of d.actorBody) {
		let member = raw;
		if (member.kind === NodeKind.DecoratedDecl) {
			const dd = member.data as DecoratedDeclData;
			if (dd.decoratedNode !== null) member = dd.decoratedNode;
		}
		if (member.kind === NodeKind.PropertyDecl) {
			const pd = member.data as PropertyDeclData;
			if (!pd.propIsStatic) {
				memberNames.push(pd.propName);
				memberTypes.push(unknownType());
			}
		}
	}
	const innerType = createStruct(d.actorName, memberNames, memberTypes, true);
	const actorType = createRef(innerType);
	const sym = makeSymbol(d.actorName, SymbolKind.Actor, actorType, false);
	actorType.sym = sym;
	innerType.sym = sym;
	defineOrError(ctx, sym, node);
	// Check for constructor
	for (const member of d.actorBody) {
		if (member.kind === NodeKind.ConstructorDecl) {
			setFlag(sym, SymbolFlag.HasConstructor);
		}
	}
	// Register methods as extensions (reuse collectClassMethod)
	if (ctx.extensionRegistry !== null) {
		const actorGenerics = getGenericDecl(d.actorName);
		for (const member of d.actorBody) {
			collectClassMethod(ctx, d.actorName, actorGenerics, member, false);
		}
	}
}

function collectClassMethod(ctx: CheckerContext, className: string, classGenerics: string, member: Node, isExternClass: boolean): void {
	let builtinKind = "";
	let methodNode: Node = null as unknown as Node;
	if (member.kind === NodeKind.MethodDecl) {
		methodNode = member;
	} else if (member.kind === NodeKind.DecoratedDecl) {
		const dd = member.data as DecoratedDeclData;
		if (dd.decoratedNode !== null && dd.decoratedNode.kind === NodeKind.MethodDecl) {
			methodNode = dd.decoratedNode;
			const info = extractDecoratorInfo(member);
			builtinKind = info.builtinKind;
		}
	}
	if (methodNode === null) return;
	const md = methodNode.data as MethodDeclData;
	// Instance methods: prepend receiver as first param — same as standalone extensions.
	// For generic classes (e.g. Promise<T>), the receiver carries the generic params so
	// resolution creates GenericParam("T") and unification at the call site substitutes concrete types.
	if (!md.methodIsStatic) {
		const receiverType = classGenerics !== "" ? className + "<" + classGenerics + ">" : className;
		const newParams: string[] = ["this"];
		const newTypes: string[] = [receiverType];
		for (let pi = 0; pi < md.methodParams.length; pi += 1) {
			newParams.push(md.methodParams[pi]);
		}
		for (let pi = 0; pi < md.methodParamTypes.length; pi += 1) {
			newTypes.push(md.methodParamTypes[pi]);
		}
		md.methodParams = newParams;
		md.methodParamTypes = newTypes;
		// Shift paramLocations to match — prepend null for synthetic "this" receiver.
		// Without this, checkFunctionBody's param→location indexing is off-by-one
		// and LSP reports "Undefined variable" for method parameters.
		if (methodNode.paramLocations !== null) {
			const newLocs: SourceLocation[] = [null as unknown as SourceLocation];
			for (const loc of methodNode.paramLocations) { newLocs.push(loc); }
			methodNode.paramLocations = newLocs;
		}
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
	fnType.sym = methodSym;
	if (md.nativeName !== null && md.nativeName !== "") {
		methodSym.nativeName = md.nativeName;
	}
	if (builtinKind !== "") {
		methodSym.builtinKind = builtinKind;
	}
	// Extern class methods → NativeMethod flag (don't set ExtCall, keep as native member call)
	if (isExternClass) {
		setFlag(methodSym, SymbolFlag.NativeMethod);
	}
	// Link node → symbol for resolvePass + LSP go-to-definition
	methodSym.location = member.location;
	methodSym.modulePath = ctx.modulePath;
	methodSym.declNode = member;
	member.resolvedSym = methodSym;
	registerExtension(ctx.extensionRegistry, createExtMethod(md.methodName, className, "", fnType, md.methodIsStatic, methodSym, 1));
}

function collectStructLike(ctx: CheckerContext, node: Node, kind: SymbolKind, isRef: boolean): void {
	const d = node.data as InterfaceDeclData;
	const isExtern = (node.flags & NodeFlag.ExternC) !== 0;
	const innerType = createStruct(d.interfaceName, [], [], true);
	// Extern interfaces stay as value types (C header defines the struct layout)
	const symType = (isRef && !isExtern) ? createRef(innerType) : innerType;
	const sym = makeSymbol(d.interfaceName, kind, symType, false);
	symType.sym = sym;
	innerType.sym = sym;
	if (isExtern) {
		setFlag(sym, SymbolFlag.ImportC);
		sym.nativeName = d.interfaceName;
	}
	defineOrError(ctx, sym, node);
}

function collectInterface(ctx: CheckerContext, node: Node): void {
	collectStructLike(ctx, node, SymbolKind.Interface, true);
}

function collectStruct(ctx: CheckerContext, node: Node): void {
	collectStructLike(ctx, node, SymbolKind.Struct, false);
}

function collectEnumDecl(ctx: CheckerContext, node: Node): void {
	const d = node.data as EnumDeclData;
	const enumValues = d.enumValues !== null ? d.enumValues : [] as number[];
	const enumType = createEnum(d.enumName, d.enumMembers, enumValues);
	const enumSym = makeSymbol(d.enumName, SymbolKind.Enum, enumType, false);
	enumType.sym = enumSym;
	if ((node.flags & NodeFlag.ExternC) !== 0) {
		setFlag(enumSym, SymbolFlag.ImportC);
		enumSym.nativeName = d.enumName;
	}
	defineOrError(ctx, enumSym, node);
	// Record enum type DEF for symbol graph
	sgRecordSym(ctx, d.nameLocation.line, d.nameLocation.column, d.nameLocation.column + d.enumName.length, enumSym, enumType, SymbolKind.Enum, d.enumName, "", true);
	// Record each enum member for the symbol graph (DEF records for go-to-definition).
	// Enum member mangled names (Color_Red) are NOT registered in scope — they are
	// resolved at use site in checkMemberExpr via synthetic symbols.
	let mi = 0;
	while (mi < d.enumMembers.length) {
		const memberLoc = d.memberLocations !== null && mi < d.memberLocations.length ? d.memberLocations[mi] : node.location;
		const memberSym = makeSymbol(d.enumMembers[mi], SymbolKind.EnumMember, enumType, false);
		memberSym.location = memberLoc;
		sgRecordSym(ctx, memberLoc.line, memberLoc.column, memberLoc.column + d.enumMembers[mi].length, memberSym, enumType, SymbolKind.EnumMember, d.enumMembers[mi], d.enumName, true);
		mi = mi + 1;
	}
	node.nodeType = enumType;
}

function collectTypeAlias(ctx: CheckerContext, node: Node): void {
	const d = node.data as TypeAliasDeclData;
	const aliasType = emptyType();
	const sym = makeSymbol(d.aliasName, SymbolKind.TypeAlias, aliasType, false);
	aliasType.sym = sym;
	defineOrError(ctx, sym, node);
}

function collectExtern(ctx: CheckerContext, node: Node): void {
	const d = node.data as ExternDeclData;
	const kind = match (d.externKind) {
		ExternKind.Function => SymbolKind.Function,
		ExternKind.Class => SymbolKind.Class,
		ExternKind.Interface => SymbolKind.Interface,
		ExternKind.Struct => SymbolKind.Struct,
		ExternKind.Enum => SymbolKind.Enum,
		ExternKind.Type => SymbolKind.TypeAlias,
		_ => SymbolKind.Variable,
	};
	const sym = makeSymbol(d.externName, kind, unknownType(), false);
	sym.symbolType.sym = sym;
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
	// Phase B+: Use SymbolKind.Macro so checkCallExpr can detect macro calls
	// and rewrite them to MacroInvocation (enables bare-call invocation: foo(args)
	// instead of @foo(args)).
	const sym = makeSymbol(d.macroDeclName, SymbolKind.Macro, unknownType(), false);
	sym.symbolType.sym = sym;
	defineOrError(ctx, sym, node);
	ctx.macroBodyRegistry.set(d.macroDeclName, d.macroDeclBody);
	ctx.macroParamsRegistry.set(d.macroDeclName, d.macroDeclParams);
}

// Look up resolved source path for an import specifier from the module's import entries
function resolveImportSourcePath(ctx: CheckerContext, specifier: string): string {
	if (ctx.currentModule !== null) {
		for (const imp of ctx.currentModule.imports) {
			if (imp.sourceSpecifier === specifier) return imp.sourcePath;
		}
	}
	// Prelude context fallback: resolve relative specifier using modulePath
	if (specifier.length >= 2 && specifier.charAt(0) === "." && ctx.modulePath !== "") {
		const dir = getModuleDir(ctx.modulePath);
		if (dir !== "") {
			let rel = specifier;
			if (rel.length > 2 && rel.slice(0, 2) === "./") {
				rel = rel.slice(2, rel.length);
			}
			return dir + "/" + rel;
		}
	}
	return "";
}

// Check if a symbol name is an operator (all operator chars, or [] / []=).
// Used for auto-propagation of exported operator overloads.
function isOperatorSymName(name: string): boolean {
	if (name.byteLength === 0) return false;
	if (name === "[]" || name === "[]=") return true;
	let i = 0;
	while (i < name.byteLength) {
		const ch = name.byteAt(i);
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

// Shared helper: create a symbol from export registry info, define it, and record for LSP.
// Used by both collectImport and collectExport (re-export path) to avoid duplication.
export function importSymFromRegistry(
	ctx: CheckerContext, alias: string, importName: string,
	exportInfo: ExportedSymInfo, sourcePath: string,
	nameLoc: SourceLocation, defNode: Node
): Symbol {
	const sym = makeSymbol(alias, exportInfo.kind, exportInfo.symType, false);
	sym.modulePath = resolveDefiningModule(exportInfo, sourcePath);
	const origName = resolveOriginalName(exportInfo, importName);
	if (origName !== alias) sym.originalName = origName;
	if (exportInfo.nativeName !== "") sym.nativeName = exportInfo.nativeName;
	if (exportInfo.headerPath !== "") sym.headerPath = exportInfo.headerPath;
	if (exportInfo.hasConstructor) setFlag(sym, SymbolFlag.HasConstructor);
	if (exportInfo.location !== null && exportInfo.location.line > 0) {
		sym.location = exportInfo.location;
	}
	defineOrError(ctx, sym, defNode);
	sgRecordSym(ctx, nameLoc.line, nameLoc.column, nameLoc.column + alias.length, sym, exportInfo.symType, exportInfo.kind, alias, "", false);
	return sym;
}

function collectImport(ctx: CheckerContext, node: Node): void {
	const d = node.data as ImportDeclData;

	// .h imports: skip registry lookup and symbol creation. The extern decls
	// synthesized by inlineHeaderImports define the symbols locally. The
	// ImportDecl survives as metadata so Phase B can flag unused imports.
	if (isCHeaderPath(d.importSource)) return;

	// std/core is the prelude — symbols already in Global scope via injectPrelude.
	// But explicit imports promote them to Module scope (e.g., making extension methods
	// available as standalone functions in completion).
	if (isGlobalImport(d.importSource)) {
		for (let gi = 0; gi < d.importNames.length; gi += 1) {
			const name = d.importAliases[gi];
			if (lookupLocal(ctx.table, name) !== null) continue;
			const sym = lookupSymbol(ctx.table, d.importNames[gi]);
			if (sym !== null) {
				defineSymbol(ctx.table, sym);
			}
		}
		return;
	}

	// Resolve types from ExportRegistry
	const sourcePath = resolveImportSourcePath(ctx, d.importSource);

	// Namespace import: import * as ns from "path"
	// Create a Module symbol only. Individual exports are resolved on demand
	// in checkMemberExpr via ExportRegistry (qualified lookup).
	// No symbols imported into scope — avoids name clashes entirely.
	if (d.importNames.length === 1 && d.importNames[0] === "*") {
		const nsAlias = d.importAliases[0];
		if (lookupLocal(ctx.table, nsAlias) !== null) return;
		const nsSym = makeSymbol(nsAlias, SymbolKind.Module, unknownType(), false);
		nsSym.modulePath = sourcePath;
		nsSym.location = node.location;
		defineSymbol(ctx.table, nsSym);
		return;
	}

	for (let i = 0; i < d.importNames.length; i += 1) {
		const importName = d.importNames[i];
		const localAlias = d.importAliases[i];

		// Dedup: skip if already imported (same file may import same symbol twice, e.g. main + test section)
		if (lookupLocal(ctx.table, localAlias) !== null) continue;

		if (sourcePath !== "") {
			const exportInfo = findExportedSymbol(ctx.exportRegistry, sourcePath, importName);
			if (exportInfo !== null) {
				const nameLoc = d.nameLocations !== null && i < d.nameLocations.length ? d.nameLocations[i] : node.location;
				importSymFromRegistry(ctx, localAlias, importName, exportInfo, sourcePath, nameLoc, node);
				// Implementation parity: import enum members alongside enum type
				// (rawImportSymbol registers each skEnumField in the importing scope)
				if (exportInfo.kind === SymbolKind.Enum && exportInfo.symType.typeNames !== null) {
					const enumTypeName = exportInfo.symType.typeName;
					const enumDefModule = resolveDefiningModule(exportInfo, sourcePath);
					// Enum member mangled names NOT registered in scope — resolved at use site.
				// Skip: was defineOrError for Color_Red etc.
				}
				const primarySym = lookupLocal(ctx.table, localAlias);
				// Restore cross-module metadata not handled by importSymFromRegistry
				if (primarySym !== null) {
					if (exportInfo.builtinKind !== "") primarySym.builtinKind = exportInfo.builtinKind;
					if (exportInfo.defaultParams !== null && exportInfo.defaultParams.length > 0) primarySym.defaultParams = exportInfo.defaultParams;
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
							registerExtension(ctx.extensionRegistry, createExtMethod(localAlias, exportInfo.overloadExtReceiverTypes[ovIdx], sourcePath, exportInfo.overloadTypes[ovIdx], exportInfo.overloadExtIsStatic[ovIdx], ovSym, 1));
						}
						ovIdx = ovIdx + 1;
					}
				}
				// If imported symbol is an extension method, register primary locally.
				// Reference parity: sym is the single source of truth for the type.
				// When sym is available, fnType = unknownType() to avoid double-decref.
				if (exportInfo.extReceiverType !== "" && ctx.extensionRegistry !== null) {
					registerExtension(ctx.extensionRegistry, createExtMethod(localAlias, exportInfo.extReceiverType, sourcePath, exportInfo.symType, exportInfo.extIsStatic, primarySym !== null ? primarySym : null as unknown as Symbol, 1));
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

	// Auto-propagate exported extension methods from imported module.
	// When you import anything from a module, all its exported extension methods
	// (operators and named methods) become available automatically.
	if (ctx.extensionRegistry !== null && sourcePath !== "") {
		const modExports = findModuleExports(ctx.exportRegistry, sourcePath);
		if (modExports !== null) {
			for (const expInfo of modExports.symbols) {
				if (expInfo.extReceiverType !== "") {
					// Derive original method name: class methods have mangled names
					// (GPUInstance_release) but extensions use original names (release).
					let methName = expInfo.name;
					const prefix = expInfo.extReceiverType + "_";
					if (methName.length > prefix.length && methName.slice(0, prefix.length) === prefix) {
						methName = methName.slice(prefix.length, methName.length);
					}
					// Only register if not already present
					if (findExtension(ctx.extensionRegistry, expInfo.extReceiverType, methName) === null) {
						const methSym = makeSymbol(expInfo.name, SymbolKind.Function, expInfo.symType, false);
						methSym.modulePath = expInfo.definingModule !== "" ? expInfo.definingModule : sourcePath;
						if (expInfo.nativeName !== "") methSym.nativeName = expInfo.nativeName;
						if (expInfo.location !== null) methSym.location = expInfo.location;
						methSym.state = SymbolState.Shaped;
						registerExtension(ctx.extensionRegistry, createExtMethod(methName, expInfo.extReceiverType, sourcePath, expInfo.symType, expInfo.extIsStatic, methSym, 0));
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

		// .h re-exports: inlineHeaderImports emitted extern decls with the
		// re-export aliasing already baked in (buildReexportReplacement). Skip
		// the registry path; let the synthesized extern decls define the symbols.
		if (isCHeaderPath(imp.importSource)) return;

		if (!isGlobalImport(imp.importSource)) {
			// Star re-export: export * from "path" — re-export all symbols from source
			if (imp.importNames.length === 1 && imp.importNames[0] === "*") {
				const sourcePath = resolveImportSourcePath(ctx, imp.importSource);
				if (sourcePath !== "") {
					const modExports = findModuleExports(ctx.exportRegistry, sourcePath);
					if (modExports !== null) {
						for (let si = 0; si < modExports.symbols.length; si += 1) {
							const expInfo = modExports.symbols[si];
							if (lookupLocal(ctx.table, expInfo.name) !== null) continue;
							importSymFromRegistry(ctx, expInfo.name, expInfo.name, expInfo, sourcePath, node.location, node);
							const sym = lookupLocal(ctx.table, expInfo.name);
							if (sym !== null) {
								setFlag(sym, SymbolFlag.Exported);
							}
						}
					} else {
						const isCirc = ctx.moduleGraph !== null
							&& ctx.currentModule !== null
							&& isCircularBackEdge(ctx.moduleGraph, ctx.currentModule.path, sourcePath);
						if (isCirc) {
							addError(ctx, `Circular 'export *' is not supported: '${imp.importSource}' and this module form a cycle`, node.location.line, node.location.column);
						} else {
							addError(ctx, `No exports found in '${imp.importSource}' for export *`, node.location.line, node.location.column);
						}
					}
				}
				return;
			}
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
							const reNameLoc = imp.nameLocations !== null && i < imp.nameLocations.length ? imp.nameLocations[i] : d.exportedDecl.location;
							importSymFromRegistry(ctx, alias, importName, exportInfo, sourcePath, reNameLoc, node);
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
	if (d.exportedDecl.kind === NodeKind.ActorDecl) {
		const ad2 = d.exportedDecl.data as ActorDeclData;
		for (let ai2 = 0; ai2 < ad2.actorBody.length; ai2 += 1) {
			const mSym = ad2.actorBody[ai2].resolvedSym;
			if (mSym !== null) {
				setFlag(mSym, SymbolFlag.Exported);
			}
		}
	}
}

// Extract the name from any declaration node
export function getDeclName(node: Node): string {
	if (node === null) return "";
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
		NodeKind.ActorDecl => { const d = node.data as ActorDeclData; return d.actorName; },
		NodeKind.InterfaceDecl => { const d = node.data as InterfaceDeclData; return d.interfaceName; },
		NodeKind.StructDecl => { const d = node.data as InterfaceDeclData; return d.interfaceName; },
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
import { createContext, findExtension, registerModuleExports } from "./context";

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

test "collect enum type (members resolved at use site)" {
	assert hasSymbol("enum Color { Red, Green, Blue }", "Color");
	// Mangled members (Color_Red) no longer in scope — resolved in checkMemberExpr
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
	const ctx = collectFromSource("@builtin(\"ResultOk\") extern function ok(val: number): number from \"msResultOk\";");
	const sym = lookupSymbol(ctx.table, "ok");
	assert sym !== null;
	if (sym !== null) {
		assert sym.builtinKind === "ResultOk";
		assert sym.nativeName === "msResultOk";
		assert hasFlag(sym, SymbolFlag.ImportC);
	}
}

test "@builtin on generic extern function" {
	const ctx = collectFromSource("@builtin(\"ResultOk\") extern function ok<T>(val: T): T;");
	const sym = lookupSymbol(ctx.table, "ok");
	assert sym !== null;
	if (sym !== null) {
		assert sym.builtinKind === "ResultOk";
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

test "re-export preserves original location and records sgSymRecord" {
	// Set up: register a fake source module with an exported symbol at line 51
	const ctx = createContext();
	ctx.modulePath = "/test/hub/index.ms";
	const origLoc = makeLoc(51, 17);
	const fakeExport: ExportedSymInfo = {
		name: "get", kind: SymbolKind.Function, symType: unknownType(),
		overloadTypes: [], extReceiverType: "", extIsStatic: false,
		overloadExtReceiverTypes: [], overloadExtIsStatic: [],
		nativeName: "", builtinKind: "",
		overloadNativeNames: [], overloadBuiltinKinds: [],
		defaultParams: [], overloadDefaultParamsFlat: [], overloadDefaultParamsCounts: [],
		definingModule: "/test/hub/accessors", originalName: "", headerPath: "",
		location: origLoc, memberLocations: [],
	};
	registerModuleExports(ctx.exportRegistry, "/test/hub/accessors", [fakeExport]);

	// Parse a re-export statement and collect
	const pr = parseSource("export { get } from \"./accessors\";");
	assert pr.ok;
	collectTopLevel(ctx, pr.value);

	// Verify symbol has correct modulePath and preserved location
	const sym = lookupSymbol(ctx.table, "get");
	assert sym !== null;
	if (sym !== null) {
		assert hasFlag(sym, SymbolFlag.Exported);
		assert sym.modulePath === "/test/hub/accessors";
		assert sym.location.line === 51;
		assert sym.location.column === 17;
	}

	// Verify sgSymRecord was created for the re-export name
	assert ctx.symRecords.length > 0;
	let found = false;
	for (const rec of ctx.symRecords) {
		if (rec.name === "get") { found = true; }
	}
	assert found;
}

import { platform } from "std/process";
import { noneType, inferredType, isUnresolvedType, hasGenericParams, unifyType, createUnifyBindings, typeNameOf, createFunction, getMinArity, setMinArity } from "./types";
import { isAssignable, isReinterpretUnsafe, scoreCandidatePriority, cmpCandidates, isNoMatch, emptyCandidateScore } from "./compat";
import { SymbolTable, ScopeKind, SymbolFlag, createSymbolTable, hasFlag, lookupSymbol } from "./symbol";
import { IdentCache } from "./idents";
import { Module, ModuleGraph, createModuleGraph, createModule } from "../module/graph";
import { Node, NodeKind, SourceLocation, makeLoc, Type, TypeKind, Symbol, SymbolKind, EnumDeclData, FunctionDeclData, MethodDeclData } from "../ast/node";
import { findChar, splitTopLevel } from "../utils/string";
import { InitTracker, createInitTracker } from "./initTracker";
import { AffineTracker, createAffineTracker } from "./spawnAffinity";


// ===== Export Registry (cross-module type propagation) =====
// Lives only during checkModuleGraph execution — NOT on Module/ModuleGraph (DRC constraint).
// Reference implementation equivalent: per-module public symbol table.

// ===== JS Import Registry (for @import directive) =====
// Parallels @include for C: tells JS codegen which npm/node modules to import from.

export interface JsImportEntry {
	modulePath: string;    // e.g. "node:fs", "@solana/web3.js"
	names: string[];       // e.g. ["readFileSync", "existsSync"]
}

export interface ExportedSymInfo {
	name: string;
	kind: SymbolKind;
	symType: Type;
	overloadTypes: Type[];
	extReceiverType: string;
	extIsStatic: boolean;
	overloadExtReceiverTypes: string[];
	overloadExtIsStatic: boolean[];
	nativeName: string;
	builtinKind: string;
	overloadNativeNames: string[];
	overloadBuiltinKinds: string[];
	defaultParams: Node[];
	overloadDefaultParamsFlat: Node[];
	overloadDefaultParamsCounts: int32[];
	definingModule: string;  // Original defining module path (preserved through re-exports)
	originalName: string;    // Original declared name (used for C mangling, not import alias)
	headerPath: string;      // @include header path for this extern symbol
	jsModulePath: string;    // @import JS module path for this extern symbol
	hasConstructor: boolean; // class has ConstructorDecl → codegen calls ClassName_new()
	location: SourceLocation; // Original declaration location (line/col in defining module)
	memberLocations: SourceLocation[]; // Per-enum-member declaration locations (parallel to symType.typeNames)
	// Phase 5: preserve sym flags across module boundaries so overload signature
	// bits (OverloadSig) survive export/import — required for findOverloadImpl
	// to distinguish body-less sigs from the wide impl.
	primaryFlags: int32;
	overloadFlags: int32[];
	// Phase E: cross-module macros — carry body AST + param names through
	// the export pipeline so importing modules can register in macroBodyRegistry.
	macroBody: Node;
	converterTarget: string; // converter target type name ("" = not a converter)
	converterTargetType: Type; // resolved converter target (null when unresolved / not a converter)
	macroParams: string[];
	macroParamTypes: string[];
	// Cross-module generic mono — generic FunctionDecl / MethodDecl AST so
	// importing modules can instantiate the body with concrete type args.
	// Without this, `import { f } from "./lib"` + `f<Post>(...)` would keep
	// the original generic Result<unknown, _> shape at the call site (mono
	// skips because the imported sym has no declNode), producing codegen
	// type mismatches at link time. Populated only for generic FunctionDecl
	// / static generic MethodDecl in buildExportInfo; null otherwise.
	declNode: Node;
	// Parallel to overloadTypes: per-overload AST so cross-module mono works
	// for overloaded generic functions (`export function g<T>(...): ...; export function g(s: string): ...;`).
	// Entries are null for non-generic overloads.
	overloadDeclNodes: Node[];
}

export interface ModuleExports {
	modulePath: string;
	symbols: ExportedSymInfo[];
}

export interface ExportRegistry {
	entries: ModuleExports[];
	nameIndex: HashMap<string, ExportedSymInfo[]>;  // name → all exports with that name (cross-module)
	moduleIndex: HashMap<string, number>;  // modulePath → index in entries[]
}

export function createExportRegistry(): ExportRegistry {
	return { entries: [], nameIndex: new HashMap<string, ExportedSymInfo[]>(), moduleIndex: new HashMap<string, number>() };
}

function addToNameIndex(registry: ExportRegistry, exports: ExportedSymInfo[]): void {
	for (const sym of exports) {
		if (sym.name.length === 0) continue;
		const old = registry.nameIndex.get(sym.name);
		if (old !== null) {
			const updated: ExportedSymInfo[] = [];
			for (let ai = 0; ai < old.length; ai += 1) {
				updated.push(old[ai]);
			}
			updated.push(sym);
			registry.nameIndex.set(sym.name, updated);
		} else {
			registry.nameIndex.set(sym.name, [sym]);
		}
	}
}

export function removeFromNameIndex(registry: ExportRegistry, exports: ExportedSymInfo[]): void {
	for (const sym of exports) {
		if (sym.name.length === 0) continue;
		const arr = registry.nameIndex.get(sym.name);
		if (arr === null) continue;
		const kept: ExportedSymInfo[] = [];
		for (let ri = 0; ri < arr.length; ri += 1) {
			if (arr[ri] !== sym) kept.push(arr[ri]);
		}
		if (kept.length === 0) {
			registry.nameIndex.delete(sym.name);
		} else {
			registry.nameIndex.set(sym.name, kept);
		}
	}
}

export function registerModuleExports(registry: ExportRegistry, modulePath: string, exports: ExportedSymInfo[]): void {
	const entry: ModuleExports = { modulePath, symbols: exports };
	registry.moduleIndex.set(modulePath, registry.entries.length);
	registry.entries.push(entry);
	addToNameIndex(registry, exports);
}

// Replace existing module's exports (Phase 2 updates Phase 1 placeholders)
export function updateModuleExports(registry: ExportRegistry, modulePath: string, exports: ExportedSymInfo[]): void {
	const i = registry.moduleIndex.get(modulePath);
	if (i !== null) {
		const e = registry.entries[i];
		removeFromNameIndex(registry, e.symbols);
		e.symbols = exports;
		addToNameIndex(registry, exports);
		return;
	}
	registerModuleExports(registry, modulePath, exports);
}

export function findModuleExports(registry: ExportRegistry, modulePath: string): ModuleExports {
	const i = registry.moduleIndex.get(modulePath);
	if (i !== null) {
		return registry.entries[i];
	}
	return null as unknown as ModuleExports;
}

// O(1) cross-module lookup by name — returns all exports with that name across all modules.
export function findExportsByName(registry: ExportRegistry, name: string): ExportedSymInfo[] {
	const arr = registry.nameIndex.get(name);
	if (arr !== null) return arr;
	return [];
}

export function findExportedSymbol(registry: ExportRegistry, modulePath: string, name: string): ExportedSymInfo {
	const modExports = findModuleExports(registry, modulePath);
	if (modExports === null) return null as unknown as ExportedSymInfo;
	for (const sym of modExports.symbols) {
		if (sym.name === name) return sym;
	}
	return null as unknown as ExportedSymInfo;
}

// ===== Export Info Builder (shared by orchestrator + loadPreludeSubModules) =====

export function buildExportInfo(sym: Symbol, extensionRegistry: ExtensionRegistry, modulePath: string, ctx: CheckerContext): ExportedSymInfo {
	// Extension receiver metadata for primary symbol
	let extRecv = "";
	let extStatic = false;
	if (extensionRegistry !== null && sym.symbolKind === SymbolKind.Function) {
		const ext = findExtensionByType(extensionRegistry, sym.name, sym.symbolType);
		if (ext !== null) {
			extRecv = ext.receiverTypeName;
			extStatic = ext.isStatic;
		} else {
			// Class methods: mangled name (GPUInstance_release) doesn't match
			// extension entry (release). Fall back to symbol identity match.
			const extSym = findExtensionBySym(extensionRegistry, sym);
			if (extSym !== null) {
				extRecv = extSym.receiverTypeName;
				extStatic = extSym.isStatic;
			}
		}
	}

	// Collect overload types + per-overload metadata
	const ovTypes: Type[] = [];
	const ovExtRecvs: string[] = [];
	const ovExtStatics: boolean[] = [];
	const ovRtNames: string[] = [];
	const ovBiKinds: string[] = [];
	const ovDefParamsFlat: Node[] = [];
	const ovDefParamsCounts: int32[] = [];
	const ovFlags: int32[] = [];

	const ovDeclNodes: Node[] = [];

	let ovi = 0;
	while (ovi < sym.overloads.length) {
		ovTypes.push(sym.overloads[ovi].symbolType);
		ovRtNames.push(sym.overloads[ovi].nativeName);
		ovBiKinds.push(sym.overloads[ovi].builtinKind);
		ovFlags.push(sym.overloads[ovi].symFlags);
		// Cross-module mono — carry overload's declNode if it's a generic
		// FunctionDecl / static generic MethodDecl (same rule as primary).
		let ovDN: Node = null as unknown as Node;
		const ovDecl = sym.overloads[ovi].declNode;
		if (ovDecl !== null) {
			if (ovDecl.kind === NodeKind.FunctionDecl) {
				const fd = ovDecl.data as FunctionDeclData;
				if (isGenericFn(fd.fnFlags)) ovDN = ovDecl;
			} else if (ovDecl.kind === NodeKind.MethodDecl) {
				if (methodCarriesMonoBody(sym.overloads[ovi].symbolType)) ovDN = ovDecl;
			}
		}
		ovDeclNodes.push(ovDN);

		if (extensionRegistry !== null) {
			let ovExt = findExtensionByType(extensionRegistry, sym.name, sym.overloads[ovi].symbolType);
			if (ovExt === null && extRecv !== "") ovExt = findExtensionBySym(extensionRegistry, sym.overloads[ovi]);
			if (ovExt !== null) {
				ovExtRecvs.push(ovExt.receiverTypeName);
				ovExtStatics.push(ovExt.isStatic);
			} else {
				ovExtRecvs.push("");
				ovExtStatics.push(false);
			}
		} else {
			ovExtRecvs.push("");
			ovExtStatics.push(false);
		}

		const dps = sym.overloads[ovi].defaultParams;
		if (dps !== null) {
			ovDefParamsCounts.push(dps.length);
			for (const dp of dps) {
				ovDefParamsFlat.push(dp);
			}
		} else {
			ovDefParamsCounts.push(0);
		}
		ovi = ovi + 1;
	}

	// Enum member locations
	let memberLocs: SourceLocation[] = [];
	if (sym.declNode !== null && sym.declNode.kind === NodeKind.EnumDecl) {
		memberLocs = (sym.declNode.data as EnumDeclData).memberLocations;
	}

	// Phase E: carry macro body + params for cross-module macro import.
	let mBody: Node = null as unknown as Node;
	let mParams: string[] = [];
	let mParamTypes: string[] = [];
	let mConverterTarget = "";
	let mConverterTargetType: Type = null as unknown as Type;
	if (sym.symbolKind === SymbolKind.Macro && ctx !== null) {
		if (ctx.macroBodyRegistry.has(sym.name)) {
			mBody = ctx.macroBodyRegistry.get(sym.name);
		}
		const ct = ctx.converterTargetByName.get(sym.name);
		if (ct !== null) { mConverterTarget = ct; }
		const ctt = ctx.converterTargetTypes.get(sym.name);
		if (ctt !== null) { mConverterTargetType = ctt; }
		if (ctx.macroParamsRegistry.has(sym.name)) {
			mParams = ctx.macroParamsRegistry.get(sym.name);
		}
		if (ctx.macroParamTypesRegistry.has(sym.name)) {
			mParamTypes = ctx.macroParamTypesRegistry.get(sym.name);
		}
	}

	// Cross-module AST preservation:
	//   - Generic FunctionDecl / static generic MethodDecl: required for
	//     cross-module mono (importing modules clone + substitute type args).
	//   - Non-generic FunctionDecl: Raiser @comptime walker needs the body
	//     AST to compile cross-module fns into bytecode (Phase 8b). Safe
	//     because `ensureShaped → resolveFunction` is self-contained — it
	//     resolves the fn's own signature/body without cross-polluting the
	//     importer's type registry.
	//   - EnumDecl: Phase 8c walker injects enum decls for nested access
	//     (e.g., `r.error.kind` returns IoErrorKind). Safe because
	//     `ensureShaped` has no EnumDecl handler (falls to `_ => {}`).
	//
	// NOT preserved (intentionally): ClassDecl / ActorDecl / InterfaceDecl
	// / TypeAliasDecl. Their `ensureShaped` handlers (resolveClass /
	// resolveActor / resolveInterface / resolveTypeAlias) walk member
	// types and re-resolve foreign type references in the importer's
	// scope, polluting the type registry. For Phase 8c walker access to
	// Interface/TypeAlias decls, read `expInfo.symType.sym.declNode`
	// instead (Type.sym chain bridges across modules; verified empirically
	// for InterfaceDecl).
	let exportDeclNode: Node = null as unknown as Node;
	if (sym.declNode !== null) {
		if (sym.declNode.kind === NodeKind.FunctionDecl) {
			exportDeclNode = sym.declNode;
		} else if (sym.declNode.kind === NodeKind.MethodDecl) {
			if (methodCarriesMonoBody(sym.symbolType)) exportDeclNode = sym.declNode;
		} else if (sym.declNode.kind === NodeKind.EnumDecl) {
			exportDeclNode = sym.declNode;
		}
	}

	return {
		name: sym.name, kind: sym.symbolKind, symType: sym.symbolType,
		overloadTypes: ovTypes,
		extReceiverType: extRecv, extIsStatic: extStatic,
		overloadExtReceiverTypes: ovExtRecvs, overloadExtIsStatic: ovExtStatics,
		nativeName: sym.nativeName, builtinKind: sym.builtinKind,
		overloadNativeNames: ovRtNames, overloadBuiltinKinds: ovBiKinds,
		defaultParams: sym.defaultParams,
		overloadDefaultParamsFlat: ovDefParamsFlat, overloadDefaultParamsCounts: ovDefParamsCounts,
		definingModule: sym.modulePath !== "" ? sym.modulePath : modulePath,
		originalName: sym.originalName,
		headerPath: sym.headerPath,
		primaryFlags: sym.symFlags,
		overloadFlags: ovFlags,
		jsModulePath: sym.jsModulePath,
		hasConstructor: hasFlag(sym, SymbolFlag.HasConstructor),
		location: sym.location !== null ? sym.location : makeLoc(0, 0),
		memberLocations: memberLocs,
		macroBody: mBody,
		converterTarget: mConverterTarget,
		converterTargetType: mConverterTargetType,
		declNode: exportDeclNode,
		overloadDeclNodes: ovDeclNodes,
		macroParams: mParams,
		macroParamTypes: mParamTypes,
	};
}

// Collect all exported symbols: scope symbols + class method extensions.
// Single source of truth — used by orchestrator (multi-module) and TransAm (LSP).
export function collectExports(ctx: CheckerContext, modulePath: string): ExportedSymInfo[] {
	const exports: ExportedSymInfo[] = [];
	for (const sym of ctx.table.current.symbols.values()) {
		if (hasFlag(sym, SymbolFlag.Exported)) {
			exports.push(buildExportInfo(sym, ctx.extensionRegistry, modulePath, ctx));
		}
	}
	if (ctx.extensionRegistry !== null) {
		for (const ext of ctx.extensionRegistry.methods) {
			const extSym = ext.sym;
			if (extSym !== null && hasFlag(extSym, SymbolFlag.Exported)) {
				let alreadyExported = false;
				for (const e of exports) {
					if (e.name === extSym.name) { alreadyExported = true; break; }
				}
				if (!alreadyExported) {
					exports.push(buildExportInfo(extSym, ctx.extensionRegistry, modulePath, ctx));
				}
			}
		}
	}
	return exports;
}

// ===== Extension Registry (extension method tracking) =====
// Tracks "function f(this self: Type)" declarations for method resolution.

// fnType: registration-time cache — may be stale. Use getExtFnType() for reads.
// sym: AUTHORITATIVE source of type info (sym.symbolType = standard reference symbol type equivalent).
// class (not interface) — reference parity: symbol is a ref type. Lookup results must be
// nullable (null = not found), which requires pointer semantics.
//
// INVARIANT (reference parity: sym.type is the single type source):
//   sym is the authoritative type source. Use getExtFnType(ext) to read the type.
//   fnType is a FALLBACK for when sym is null (early collectPass, before symbol is available).
//   When sym is non-null, fnType MUST be noneType() — never the same Type as sym.symbolType.
//   Storing the same Type in both causes double-decref on destruction (DRC double ownership).
export class ExtensionMethod {
	methodName: string;
	receiverTypeName: string;
	sourcePath: string;
	fnType: Type;           // fallback only — use getExtFnType(ext), never read directly
	isStatic: boolean;
	sym: Symbol | null;            // authoritative type source (sym.symbolType)
	scopeDepth: number;     // 0 = imported/prelude, 1 = current module (for overload resolution)
}

export class ExtensionRegistry {
	methods: ExtensionMethod[];
	staticReceivers: string[];
}

export function createExtensionRegistry(): ExtensionRegistry {
	return { methods: [], staticReceivers: [] };
}

// Create an ExtensionMethod with proper ownership invariant enforced.
// When sym is provided, fnType is set to noneType() — sym.symbolType is authoritative.
// This prevents double-decref when both fnType and sym.symbolType reference the same Type.
export function createExtMethod(methodName: string, receiverTypeName: string, sourcePath: string, fnType: Type, isStatic: boolean, sym: Symbol, scopeDepth: number): ExtensionMethod {
	return {
		methodName, receiverTypeName, sourcePath,
		fnType: sym !== null ? noneType() : fnType,
		isStatic, sym, scopeDepth,
	};
}

export function registerExtension(registry: ExtensionRegistry, method: ExtensionMethod): void {
	// Dedup by sym identity first (cheap fast-path).
	if (method.sym !== null) {
		for (const existing of registry.methods) {
			if (existing.sym === method.sym) return;
		}
	}
	// Stronger dedup: same logical extension may register through multiple
	// import / re-export paths producing distinct Symbol instances for the
	// same definition (same name + modulePath + receiver + location). Without this,
	// `obj.asNumber()` reports "Ambiguous overloaded extension method" even
	// though only one definition exists. Fast path skips this loop when
	// the sym lacks a stable identity (modulePath empty).
	if (method.sym !== null && method.sym.modulePath !== "") {
		for (const other of registry.methods) {
			if (other.sym !== null
					&& other.sym.name === method.sym.name
					&& other.sym.modulePath === method.sym.modulePath
					&& other.receiverTypeName === method.receiverTypeName
					&& other.isStatic === method.isStatic
					&& other.sym.location.line === method.sym.location.line
					&& other.sym.location.column === method.sym.location.column) {
				return;
			}
		}
	}
	registry.methods.push(method);
	if (method.isStatic) {
		for (const known of registry.staticReceivers) {
			if (known === method.receiverTypeName) return;
		}
		registry.staticReceivers.push(method.receiverTypeName);
	}
}

export function findExtension(registry: ExtensionRegistry, receiverTypeName: string, methodName: string): ExtensionMethod {
	for (const m of registry.methods) {
		if (m.receiverTypeName === receiverTypeName && m.methodName === methodName) return m;
	}
	return null as unknown as ExtensionMethod;
}

// hasExtensionByName — check if ANY extension has this method name (any receiver)
export function hasExtensionByName(registry: ExtensionRegistry, methodName: string): boolean {
	for (const m of registry.methods) {
		if (m.methodName === methodName) return true;
	}
	return false;
}

// findExtensionByName — find first extension with this method name (any receiver)
export function findExtensionByName(registry: ExtensionRegistry, methodName: string): ExtensionMethod {
	for (const m of registry.methods) {
		if (m.methodName === methodName) return m;
	}
	return null as unknown as ExtensionMethod;
}

// findExtensionByType — find extension matching method name + fnType identity (for overload export)
export function findExtensionByType(registry: ExtensionRegistry, methodName: string, fnType: Type): ExtensionMethod {
	for (const m of registry.methods) {
		if (m.methodName === methodName && m.fnType === fnType) return m;
	}
	return null as unknown as ExtensionMethod;
}

// findExtensionBySym — match by symbol identity (not name).
// Class method symbols have mangled names (GPUInstance_release) but their extension
// registry entries use original names (release). Symbol identity bridges the mismatch.
export function findExtensionBySym(registry: ExtensionRegistry, sym: Symbol): ExtensionMethod {
	for (const m of registry.methods) {
		if (m.sym !== null && m.sym === sym) return m;
	}
	return null as unknown as ExtensionMethod;
}

// findAllExtensionsByName — find ALL extensions with a given method name (any receiver).
// Standard reference pattern: candidates are collected by name, then filtered by type compatibility
// at the call site using isAssignable (not string comparison on receiverTypeName).
let _faeCount: float64 = 0;
let _faeTime: float64 = 0;
export function findAllExtensionsByNameProfile(): float64[] { return [_faeCount, _faeTime]; }
export function findAllExtensionsByName(registry: ExtensionRegistry, methodName: string): ExtensionMethod[] {
	_faeCount = _faeCount + 1;
	const _e0 = performance.now();
	const r = findAllExtensionsByNameInner(registry, methodName);
	_faeTime = _faeTime + (performance.now() - _e0);
	return r;
}
function findAllExtensionsByNameInner(registry: ExtensionRegistry, methodName: string): ExtensionMethod[] {
	const results: ExtensionMethod[] = [];
	let i = 0;
	while (i < registry.methods.length) {
		const m = registry.methods[i];
		if (m.methodName === methodName) {
			results.push(m);
		}
		i = i + 1;
	}
	return results;
}

export function hasStaticExtForReceiver(registry: ExtensionRegistry, receiverName: string): boolean {
	if (receiverName === "") return false;
	for (const known of registry.staticReceivers) {
		if (known === receiverName) return true;
	}
	return false;
}

export function filterStaticExtsByReceiverName(exts: ExtensionMethod[], receiverName: string): ExtensionMethod[] {
	const results: ExtensionMethod[] = [];
	if (receiverName === "") return results;
	for (const e of exts) {
		if (e.isStatic && e.receiverTypeName === receiverName) results.push(e);
	}
	return results;
}

// ===== Canonical Extension Type (Standard reference symbol type equivalent) =====
// Standard reference: the symbol's type is the single source of truth.
// ext.fnType is a registration-time snapshot that may be stale (noneType from collectPass).
// Always use this helper instead of reading ext.fnType directly.

export function getExtFnType(ext: ExtensionMethod): Type {
	if (ext.sym !== null && ext.sym.symbolType !== null && ext.sym.symbolType.kind === TypeKind.Function) {
		return ext.sym.symbolType;
	}
	return ext.fnType;
}

// Reference parity: an infix/prefix operator is resolved exactly like a normal
// call (semexprs.nim nkInfix → semDirectOp → semOverloadedCall), over EVERY
// symbol bearing that name. A receiver-form (`this`) declaration and a plain
// `function \`op\`(a, b)` declaration are one candidate set, scored by one relation.
function isSelectableAfterMonomorphization(sym: Symbol): boolean {
	if (sym === null) return false;
	if (sym.symbolType === null || sym.symbolType.kind !== TypeKind.Function) return false;
	return !hasGenericParams(sym.symbolType);
}

function addPlainOperatorCandidate(cands: ExtensionMethod[], sym: Symbol): void {
	if (!isSelectableAfterMonomorphization(sym)) return;
	let i = 0;
	while (i < cands.length) {
		if (cands[i].sym === sym) return;
		i = i + 1;
	}
	cands.push(createExtMethod(sym.name, "", "", noneType(), false, sym, 1));
}

function pickBestOperatorCandidate(cands: ExtensionMethod[], argTypes: Type[]): ExtensionMethod {
	let best: ExtensionMethod = null as unknown as ExtensionMethod;
	let bestFt: Type = null as unknown as Type;
	let bestScore = emptyCandidateScore();
	let i = 0;
	while (i < cands.length) {
		const m = cands[i];
		i = i + 1;
		const ft = getExtFnType(m);
		if (ft === null || ft.kind !== TypeKind.Function) continue;
		if (ft.typeChildren.length !== argTypes.length) continue;
		const score = scoreCandidatePriority(ft.typeChildren, argTypes, getMinArity(ft));
		if (isNoMatch(score)) continue;
		score.calleeScope = m.scopeDepth;
		if (best === null || cmpCandidates(score, bestScore, ft, bestFt) > 0) {
			best = m; bestScore = score; bestFt = ft;
		}
	}
	return best;
}

export function resolveOperatorCall(table: SymbolTable, registry: ExtensionRegistry, methodName: string, argTypes: Type[]): ExtensionMethod {
	const cands: ExtensionMethod[] = [];
	if (registry !== null) {
		const exts = findAllExtensionsByName(registry, methodName);
		let i = 0;
		while (i < exts.length) {
			cands.push(exts[i]);
			i = i + 1;
		}
	}
	if (table !== null) {
		const sym = lookupSymbol(table, methodName);
		if (sym !== null) {
			addPlainOperatorCandidate(cands, sym);
			let j = 0;
			while (j < sym.overloads.length) {
				addPlainOperatorCandidate(cands, sym.overloads[j]);
				j = j + 1;
			}
		}
	}
	return pickBestOperatorCandidate(cands, argTypes);
}

// Strip receiver (param[0]) from an extension's function type for overload scoring.
// Preserves minArity so scoreCandidatePriority handles default params correctly.
export function stripReceiverParam(fnType: Type): Type {
	if (fnType.typeChildren.length === 0) return fnType;
	const params: Type[] = [];
	const names: string[] = [];
	let i = 1;
	while (i < fnType.typeChildren.length) {
		params.push(fnType.typeChildren[i]);
		i = i + 1;
	}
	i = 1;
	while (i < fnType.typeNames.length) {
		names.push(fnType.typeNames[i]);
		i = i + 1;
	}
	const stripped = createFunction(params, names, fnType.typeReturn);
	const origMin = getMinArity(fnType);
	if (origMin > 0) setMinArity(stripped, origMin - 1);
	return stripped;
}

// ===== Receiver Matching (shared by checker + LSP) =====
// Standard reference pattern: compare nominal types by identity using isAssignable,
// not string-based receiverTypeName comparison.

export function isReceiverMatch(ext: ExtensionMethod, objType: Type | null): boolean {
	// Static extensions: string-based matching (receiver not in typeChildren)
	if (ext.isStatic) {
		if (ext.receiverTypeName === typeNameOf(objType)) return true;
		// Type-alias fallback (mirrors the instance-branch fallback below): when
		// the receiver expression is `Buffer` (a `type Buffer = string` alias),
		// objType resolves to the underlying `string` and typeNameOf returns
		// "string", but objType.sym is the Buffer alias symbol (stamped by
		// collectTypeAlias). Without this, static extensions like Buffer.alloc()
		// fail to match, NodeFlag.ExtCall isn't set, extensionMethodLower skips
		// the rewrite, and codegen emits buggy closure dispatch.
		if (objType !== null && objType.sym !== null
				&& objType.sym.symbolKind === SymbolKind.TypeAlias
				&& ext.receiverTypeName === objType.sym.name) return true;
		return false;
	}
	if (objType === null) return false;
	// Instance extensions: type-based matching on first param (sym.typ is authoritative).
	const fnType = getExtFnType(ext);
	if (fnType.kind !== TypeKind.Function) return false;
	if (fnType.typeChildren.length === 0) return false;
	const receiverType = fnType.typeChildren[0];
	// Erased object (unknown) binds only the unknown catch-all, never a concrete
	// overload — Nim parity: an unresolved receiver isn't matchable by a concrete param.
	if (isUnresolvedType(objType) || objType.kind === TypeKind.Unknown) {
		return isUnresolvedType(receiverType) || receiverType.kind === TypeKind.Unknown;
	}
	// `unknown` receiver: the catch-all — matches any object
	if (isUnresolvedType(receiverType) || receiverType.kind === TypeKind.Unknown) return true;
	// Array methods are Ref-agnostic: T[] (Ref<Array>) and Vec<T> (value Array) share
	// one element-typed method set. Unwrap the Ref<Array> envelope on both sides so
	// matching compares element types; codegen dispatches &value vs ptr on the receiver.
	let recvT = receiverType;
	if (recvT.kind === TypeKind.Ref && recvT.typeReturn !== null && recvT.typeReturn.kind === TypeKind.Array) recvT = recvT.typeReturn;
	let objT = objType;
	if (objT.kind === TypeKind.Ref && objT.typeReturn !== null && objT.typeReturn.kind === TypeKind.Array) objT = objT.typeReturn;
	// Generic extensions: try unification on receiver param.
	// e.g. map<T>(this arr: T[]) should match number[] but NOT string.
	if (hasGenericParams(recvT)) {
		const eb = createUnifyBindings();
		unifyType(recvT, objT, eb);
		if (eb.names.length > 0) return true;
		// Unification failed (e.g., Array<T> class vs uint8[] array — different type kinds).
		// Fall through to name-based matching below.
	}
	// Concrete array extensions: element type compatibility is authoritative.
	// Don't fall through to name-based matching (which matches all "Array" extensions
	// regardless of element type — e.g., pop(number[]) would incorrectly match Bar[]).
	// Reference parity: sigmatch scores exact element match over generic, so concrete
	// overloads with wrong element types are rejected, not accepted via name fallback.
	if (recvT.kind === TypeKind.Array && objT.kind === TypeKind.Array) {
		const recvElem = recvT.typeReturn;
		const objElem = objT.typeReturn;
		if (recvElem === null || objElem === null) return false;
		if (isUnresolvedType(recvElem) || isUnresolvedType(objElem)
			|| recvElem.kind === TypeKind.Unknown || objElem.kind === TypeKind.Unknown) return false;
		if (isReinterpretUnsafe(objT, recvT)) return false;
		return isAssignable(objElem, recvElem);
	}
	// Name-based matching for well-known types and monomorphized generics.
	// Monomorphized types have names like "Map__string,string" — match base name "Map".
	if (ext.receiverTypeName !== "") {
		const objName = typeNameOf(objType);
		if (ext.receiverTypeName === objName) return true;
		// Check base name for monomorphized generics: "Map__string,string" → "Map"
		const sepPos = findChar(objName, "_");
		if (sepPos > 0 && sepPos + 1 < objName.length && objName.charAt(sepPos + 1) === "_") {
			const baseName = objName.slice(0, sepPos);
			if (ext.receiverTypeName === baseName) return true;
		}
		// Type-alias fallback: typeNameOf returns the canonical primitive name
		// (e.g. "string" for `type Buffer = string`), losing the alias. The alias
		// symbol is preserved on objType.sym (stamped by collectTypeAlias). Mirror
		// the static fallback in checkExprPass.ms so instance method dispatch
		// `s.method()` resolves extensions registered against the alias name.
		if (objType.sym !== null
				&& objType.sym.symbolKind === SymbolKind.TypeAlias
				&& ext.receiverTypeName === objType.sym.name) return true;
		// Nominal mismatch: both have names but they differ → not a match.
		// Prevents structural false positives (reference: sameObjectTypes uses a.id == b.id).
		if (objName !== "") return false;
	}
	return isAssignable(objType, receiverType);
}

export function filterExtsByReceiverType(exts: ExtensionMethod[], objType: Type | null): ExtensionMethod[] {
	const results: ExtensionMethod[] = [];
	let cur: Type | null = objType;
	let depth = 0;
	while (depth < 64) {
		let i = 0;
		while (i < exts.length) {
			if (isReceiverMatch(exts[i], cur)) {
				results.push(exts[i]);
			}
			i = i + 1;
		}
		if (results.length > 0 || cur === null) return results;
		cur = classBaseStruct(cur);
		if (cur === null) return results;
		depth += 1;
	}
	return results;
}

export function findFirstMatchingExt(exts: ExtensionMethod[], objType: Type): ExtensionMethod {
	let cur: Type | null = objType;
	let depth = 0;
	while (cur !== null && depth < 64) {
		let i = 0;
		while (i < exts.length) {
			if (isReceiverMatch(exts[i], cur)) return exts[i];
			i = i + 1;
		}
		cur = classBaseStruct(cur);
		depth += 1;
	}
	return null as unknown as ExtensionMethod;
}

function classBaseStruct(t: Type): Type | null {
	let s = t;
	if (s.kind === TypeKind.Ref && s.typeReturn !== null) s = s.typeReturn;
	if (s.kind !== TypeKind.Struct || s.typeExtra === null) return null;
	let inner = s.typeExtra;
	if (inner.kind === TypeKind.Ref && inner.typeReturn !== null) inner = inner.typeReturn;
	if (inner.kind === TypeKind.Struct) return inner;
	if (inner.sym !== null && inner.sym.symbolType !== null) {
		let bs = inner.sym.symbolType;
		if (bs.kind === TypeKind.Ref && bs.typeReturn !== null) bs = bs.typeReturn;
		if (bs.kind === TypeKind.Struct) return bs;
	}
	return null;
}

// ===== Method Dispatch Registry (Nim cgmeth methodDef/g.methods analog) =====
// Populated by collectPass for every class (parent edge) and every instance
// method (lifted `<Class>_<method>` sym). Whole-program by construction:
// collect runs for all modules before any transform/codegen. Codegen consults
// it at identifier-callee emission to route overridden methods through a
// msDisp_* if-chain dispatcher. A name declared twice on one class (overload)
// disables dispatch for that method name — conservative direct call.

export interface DispMethodEntry {
	className: string;
	methodName: string;
	sym: Symbol;
	overloaded: boolean;
}

let _dispParent: HashMap<string, string> = new HashMap<string, string>();
let _dispEntries: DispMethodEntry[] = [];
let _dispByLifted: HashMap<string, DispMethodEntry> = new HashMap<string, DispMethodEntry>();

export function dispatchRecordParent(className: string, baseName: string): void {
	if (className === "" || baseName === "") return;
	_dispParent.set(className, baseName);
}

export function dispatchRecordMethod(className: string, methodName: string, sym: Symbol): void {
	const lifted = sym.name;
	const prev = _dispByLifted.get(lifted);
	if (prev !== null) {
		const samePlace = prev.sym.modulePath === sym.modulePath
			&& prev.sym.location.line === sym.location.line
			&& prev.sym.location.column === sym.location.column;
		if (samePlace) {
			prev.sym = sym;
		} else {
			prev.overloaded = true;
		}
		return;
	}
	const e: DispMethodEntry = { className: className, methodName: methodName, sym: sym, overloaded: false };
	_dispEntries.push(e);
	_dispByLifted.set(lifted, e);
}

export function resetDispatchRegistry(): void {
	_dispParent = new HashMap<string, string>();
	_dispEntries = [];
	_dispByLifted = new HashMap<string, DispMethodEntry>();
}

export function dispatchEntryForLiftedName(liftedName: string): DispMethodEntry | null {
	if (!_dispByLifted.has(liftedName)) return null;
	return _dispByLifted.get(liftedName);
}

function dispDepthBelow(className: string, root: string): int32 {
	let cur = className;
	let d = 0;
	while (d < 64) {
		if (cur === root) return d;
		const nxt = _dispParent.get(cur);
		if (nxt === null) return -1;
		cur = nxt;
		d += 1;
	}
	return -1;
}

export function dispatchOverridesFor(className: string, methodName: string): DispMethodEntry[] {
	const ents: DispMethodEntry[] = [];
	const depths: int32[] = [];
	for (const e of _dispEntries) {
		if (e.methodName !== methodName) continue;
		if (e.overloaded) return [];
		if (e.className === className) continue;
		const dd = dispDepthBelow(e.className, className);
		if (dd <= 0) continue;
		ents.push(e);
		depths.push(dd);
	}
	let i = 1;
	while (i < ents.length) {
		let j = i;
		while (j > 0 && depths[j - 1] < depths[j]) {
			const td = depths[j - 1]; depths[j - 1] = depths[j]; depths[j] = td;
			const ts = ents[j - 1]; ents[j - 1] = ents[j]; ents[j] = ts;
			j -= 1;
		}
		i += 1;
	}
	return ents;
}

// ===== Extension Flag Helpers =====
// Parse "ext:receiverName:receiverType" and "sext:TypeName" from pipe-delimited fnFlags.
// Segment-aware: works for "async|ext:s:string", not just prefix-only.

function findFlagSegment(flags: string, prefix: string): string {
	if (flags === "") return "";
	const parts = splitTopLevel(flags, "|");
	for (let i = 0; i < parts.length; i += 1) {
		const p = parts[i].trim();
		if (p.length >= prefix.length && p.slice(0, prefix.length) === prefix) return p;
	}
	return "";
}

export function isExtensionFlag(flags: string): boolean {
	return findFlagSegment(flags, "ext:") !== "";
}

// True iff `flags` carries the `gen:T,U,...` segment. Single source of
// truth for "is this a generic decl?" — used by checker (mono dispatch),
// codegen (skip generic body emission), and extension resolution.
export function isGenericFn(flags: string): boolean {
	return findFlagSegment(flags, "gen:") !== "";
}

// Cross-module generic monomorphization: a method must carry its body (declNode)
// across module boundaries when its signature still mentions unresolved generic
// params — its own <T> (static generic) OR the enclosing generic class seen through
// the `this` receiver (instance method of Cell<T>). Without the body the importing
// module's call site can't monomorphize and falls back to the erased __unknown
// method (void* params). Nim has no method category: every generic routine body is
// globally reachable via the ModuleGraph (seminst.nim getBody), so instantiation
// fires at any site regardless of module. See NIM-REF.md §1 "Generic method
// cross-module monomorphization". The old `methodIsStatic && isGenericFn(flags)`
// test dropped instance methods of generic classes (genericity comes from the
// class T, not the method's own flags).
export function methodCarriesMonoBody(symType: Type): boolean {
	return hasGenericParams(symType);
}

export function isStaticExtensionFlag(flags: string): boolean {
	return findFlagSegment(flags, "sext:") !== "";
}

export function getExtReceiverName(flags: string): string {
	const seg = findFlagSegment(flags, "ext:");
	if (seg === "") return "";
	const rest = seg.slice(4, seg.length);
	const colonPos = findChar(rest, ":");
	if (colonPos <= 0) return "";
	return rest.slice(0, colonPos);
}

export function getExtReceiverType(flags: string): string {
	const seg = findFlagSegment(flags, "ext:");
	if (seg === "") return "";
	const rest = seg.slice(4, seg.length);
	const colonPos = findChar(rest, ":");
	if (colonPos <= 0) return "";
	const fullType = rest.slice(colonPos + 1, rest.length);
	// Strip generic params: "HashMap<K, V>" or "Map < K , V >" → "Map" for receiver matching
	const ltPos = findChar(fullType, "<");
	if (ltPos > 0) return fullType.slice(0, ltPos).trim();
	return fullType.trim();
}

export function getStaticExtTypeName(flags: string): string {
	const seg = findFlagSegment(flags, "sext:");
	if (seg === "") return "";
	return seg.slice(5, seg.length);
}

// Unified: returns receiver type name for either instance or static extensions, "" if not an extension.
export function getExtTypeName(flags: string): string {
	const instType = getExtReceiverType(flags);
	if (instType !== "") return instType;
	return getStaticExtTypeName(flags);
}

// ===== Generic Flag Helpers =====
// Parse "gen:T,U" from pipe-delimited fnFlags strings (shared by resolvePass + monomorphize)

export function extractGenericNames(flags: string): string[] {
	const result: string[] = [];
	if (flags === "") return result;
	const parts = splitTopLevel(flags, "|");
	for (let pi = 0; pi < parts.length; pi += 1) {
		const trimPart = parts[pi].trim();
		if (trimPart.length > 4) {
			const prefix = trimPart.slice(0, 4);
			if (prefix === "gen:") {
				const nameStr = trimPart.slice(4, trimPart.length);
				const names = splitTopLevel(nameStr, ",");
				for (let ni = 0; ni < names.length; ni += 1) {
					const trimName = names[ni].trim();
					if (trimName !== "") result.push(trimName);
				}
			}
		}
	}
	return result;
}

export function stripGenFlag(flags: string): string {
	if (flags === "") return "";
	const parts = splitTopLevel(flags, "|");
	const kept: string[] = [];
	for (let i = 0; i < parts.length; i += 1) {
		const trimPart = parts[i].trim();
		if (trimPart.length > 4) {
			const prefix = trimPart.slice(0, 4);
			if (prefix !== "gen:") kept.push(trimPart);
		} else {
			if (trimPart !== "") kept.push(trimPart);
		}
	}
	if (kept.length === 0) return "";
	let result = kept[0];
	for (let j = 1; j < kept.length; j += 1) {
		result = result + "|" + kept[j];
	}
	return result;
}

// ===== Attached Operations (lifecycle hooks per type) =====
// Detects onDestroy/onCopy/onMove extension methods for destructor lifting.

export interface AttachedOps {
	typeName: string;
	onDestroy: ExtensionMethod;    // null if not defined
	onCopy: ExtensionMethod;       // null if not defined
	onMove: ExtensionMethod;       // null if not defined
}

export function findAttachedOps(registry: ExtensionRegistry, typeName: string): AttachedOps {
	const ops: AttachedOps = {
		typeName,
		onDestroy: null as unknown as ExtensionMethod,
		onCopy: null as unknown as ExtensionMethod,
		onMove: null as unknown as ExtensionMethod,
	};
	for (const m of registry.methods) {
		if (m.receiverTypeName === typeName) {
			if (m.methodName === "onDestroy") { ops.onDestroy = m; }
			if (m.methodName === "onCopy") { ops.onCopy = m; }
			if (m.methodName === "onMove") { ops.onMove = m; }
		}
	}
	return ops;
}

export function hasAttachedOps(ops: AttachedOps): boolean {
	return ops.onDestroy !== null || ops.onCopy !== null || ops.onMove !== null;
}

// ===== Cancel Context =====
// Single source of truth for cancellation context type.
// transam/cancel.ms imports this (transam→checker dependency already established).

export class CancelCtx {
	version: number;
	cancelled: boolean;
}

export function isCancelled(cancel: CancelCtx, startVersion: number): boolean {
	if (cancel === null) return false;
	return cancel.version !== startVersion || cancel.cancelled;
}

// ===== Checker Context =====

// ===== Sym Records (check-time symbol recording for LSP) =====
// During type-checking, every use/def site records its position + resolved symbol.
// LSP queries binary-search this sorted array instead of walking the AST post-hoc.
// Reference-aligned: equivalent to SymInfoPair / suggestSym() / markUsed().

export interface SgSymRecord {
	line: int32;           // 1-based (parser convention)
	col: int32;            // 1-based (parser convention)
	colEnd: int32;         // col + token length
	sym: Symbol | null;    // resolved symbol; null for synthetic records
	symType: Type | null;  // type at this use site; null when not yet resolved
	kind: SymbolKind;      // may override sym.symbolKind (e.g. Method for class functions)
	name: string;          // display name (may differ from sym.name for mangled methods)
	containerName: string; // owning type name ("console" for console.log)
	isDecl: boolean;       // true = definition, false = usage
}

export function sgRecordSym(
	ctx: CheckerContext, line: int32, col: int32, colEnd: int32,
	sym: Symbol | null, symType: Type | null, kind: SymbolKind,
	name: string, containerName: string, isDecl: boolean
): void {
	if (ctx.symRecords === null) return;
	const rec: SgSymRecord = { line, col, colEnd, sym, symType, kind, name, containerName, isDecl };
	ctx.symRecords.push(rec);
}

// Insertion sort by (line, col) — called once after check completes.
export function sgSortRecords(records: SgSymRecord[]): void {
	let i = 1;
	while (i < records.length) {
		const rec = records[i];
		let j = i - 1;
		while (j >= 0) {
			const other = records[j];
			if (other.line < rec.line) break;
			if (other.line === rec.line && other.col <= rec.col) break;
			records[j + 1] = records[j];
			j = j - 1;
		}
		records[j + 1] = rec;
		i = i + 1;
	}
}

// LSP DiagnosticSeverity parity
export enum Severity {
	Error,    // 1 in LSP
	Warning,  // 2 in LSP
	Info,     // 3 in LSP
	Hint,     // 4 in LSP
}

// Structured error — standard reference messages always carry line info
export interface CheckerError {
	message: string;
	line: number;    // 1-based, 0 = unknown
	column: number;  // 1-based (parser convention), 0 = unknown
	endLine: number; // 1-based, 0 = same as line (single-line range)
	endColumn: number; // 1-based, 0 = use column+1 (single char)
	fatal: boolean;  // true = globalError (abort), false = localError (continue)
	severity: Severity;
	tags: number;    // LSP DiagnosticTag bitmask (1 = Unnecessary, 2 = Deprecated)
}

// ===== GC Mode =====
// GC mode — explicitly chosen, drives DRC and allocation behavior.
// Orc: default, ARC + cycle collector (malloc + refcount + ORC cycle detection).
// Drc: ARC only, no cycle collection (malloc + refcount, no ORC).
// None: no RC, use malloc, never free (debug/leak testing).
// Manual: no RC, freestanding — arena allocator, no malloc, no POSIX (see docs/BARE.md).

export enum GcMode {
	Drc,
	Orc,
	None,
	Manual,
}

export class CheckerContext {
	table: SymbolTable;
	errors: CheckerError[];
	gcMode: GcMode;                // Drc (ARC), Orc (ARC + cycle collector), None (malloc, no free), Manual (freestanding, arena)
	targetOs: string;              // Target OS. Always set; defaults to host platform.
	                               // Values: "linux"|"macos"|"windows"|"freebsd"|"bare"|"solana"|"wasm"|"emcc".
	                               // Cross-compile detected via `targetOs !== platform`.
	currentFunction: Symbol | null;   // innermost function (for return type validation)
	currentActorName: string;  // non-empty when inside an actor body (isolation checking)
	inLoop: boolean;           // break/continue validation
	inSwitch: boolean;         // break-inside-switch validation (TS: break may target a switch)
	inTestBlock: boolean;      // assert validation — only allowed inside test blocks
	moduleGraph: ModuleGraph;
	currentModule: Module;
	exportRegistry: ExportRegistry;
	extensionRegistry: ExtensionRegistry;
	macroBodyRegistry: HashMap<string, Node>;       // Phase B: macroName → macroDeclBody
	converterTargets: HashMap<string, string>;      // converter: target type name → converter name (in-scope pair table)
	converterTargetOrigin: HashMap<string, int32>;  // converter: target type name → 0 local decl | 1 import (shadowing + dup detection)
	converterTargetByName: HashMap<string, string>; // converter: converter name → target type name (export pipeline)
	converterTargetTypes: HashMap<string, Type>;    // converter: converter name → target type resolved in the DECLARING module
	converterTargetKeys: string[];                  // registration-ordered target keys (Nim c.converters seq analog)
	macroParamsRegistry: HashMap<string, string[]>; // Phase B: macroName → param names
	macroParamTypesRegistry: HashMap<string, string[]>;
	macroDeclModuleRegistry: HashMap<string, string>;
	macroExpansionDepth: int32;                  // Phase B+ eager: recursion limit for macros that produce macros
	jsxMacroArgDepth: int32;                     // JSX leak guard: >0 while checking a macro's args (JSX there is consumed, not leaked)
	inferredReturn: Type;  // tracks inferred return type during function body checking
	inferredReturnStmts: Node[];  // ReturnStmts pending refit once the joined inferred return is known
	includeDirectives: string; // accumulated @include args, newline-separated
	jsImportRegistry: JsImportEntry[]; // accumulated @import entries for JS backend
	compileDirectives: string; // accumulated @compile args, newline-separated
	compilerFlags: string;     // accumulated @passC/-iquote args, space-separated (compile-time)
	cancelCtx: CancelCtx;       // null in batch mode, set for LSP
	cancelVersion: number;       // version at check start
	modulePath: string;          // Implementation parity: source path for name mangling
	symRecords: SgSymRecord[];   // check-time symbol recordings for LSP (reference suggest parity)
	matchExprDepth: number;      // >0 when inside match expression block arm (return targets match, not function)
	initTracker: InitTracker;    // ref parity: TEffects.init — definite assignment tracking
	affineTracker: AffineTracker; // PARALOCK Phase 1 — affine-Promise consumption tracking
	strictDefs: boolean;         // ref parity: strictDefs — warn on all uninit var use
	strictNullChecks: boolean;   // ref parity: strictNotNil — warn on unguarded class deref
	inTryExpr: boolean;          // true when checking tryArg of TryExpr or body of TryCatchStmt (V2 await guard)
	genericInstDepth: int32;     // recursion depth for on-demand instantiation (limit 50)
	generatedInstances: Node[];  // on-demand instantiated function ASTs to inject into program
	pendingEnumToStrings: Type[]; // enum types whose _toString def must be injected in this module (recorded at lowering sites; enums reachable only via imported field types are not in module scope)
	pendingHoisted: Node[];      // statements an expression-position macro emitted ahead of its value; a stack — each statement-list walk takes a high-water mark on entry and drains only what was queued above it, so a block nested in the value cannot take the call site's prefix
	condEvalDepth: int32;        // >0 while checking a conditionally-evaluated position (&&/|| rhs, ternary arm, loop condition) — hoisting out of one would run it unconditionally
	inGenericContext: int32;     // >0 while checking members of a generic class pre-monomorphization — unbound-param diagnostics defer to instantiation
	stmtPosExpr: Node;           // the expression that IS a statement: a macro there emits statements outright, so the expression-position rules (last element is the value, empty is an error) must not apply
	localTypeNames: HashMap<string, boolean>; // names claimed by local (non-module-scope) type decls, module-wide — C keys struct emission and its include guard by bare name, so same-named locals in sibling scopes would silently merge into one definition
	pendingLocalTypeDecls: Node[]; // admitted local type decls, appended to programStmts after body checking — destructorLifting and codegen discover types by walking module statements only, so a body-only decl would never get DRC hooks or TypeInfo
	preludeCtx: CheckerContext;  // access private prelude symbols during instantiation
}

// ===== Constructors =====

export function createContext(): CheckerContext {
	const table = createSymbolTable();
	return {
		table,
		errors: [],
		gcMode: GcMode.Orc,
		targetOs: platform,
		currentFunction: null,
		currentActorName: "",
		inLoop: false,
		inSwitch: false,
		inTestBlock: false,
		moduleGraph: null as unknown as ModuleGraph,
		currentModule: null as unknown as Module,
		exportRegistry: createExportRegistry(),
		extensionRegistry: createExtensionRegistry(),
		macroBodyRegistry: new HashMap<string, Node>(),
		converterTargets: new HashMap<string, string>(),
		converterTargetOrigin: new HashMap<string, int32>(),
		converterTargetByName: new HashMap<string, string>(),
		converterTargetTypes: new HashMap<string, Type>(),
		converterTargetKeys: [],
		macroParamsRegistry: new HashMap<string, string[]>(),
		macroParamTypesRegistry: new HashMap<string, string[]>(),
		macroDeclModuleRegistry: new HashMap<string, string>(),
		macroExpansionDepth: 0,
		jsxMacroArgDepth: 0,
		inferredReturn: inferredType(),
		inferredReturnStmts: [],
		includeDirectives: "",
		jsImportRegistry: [],
		compileDirectives: "",
		compilerFlags: "",
		cancelCtx: null as unknown as CancelCtx,
		cancelVersion: 0,
		modulePath: "",
		symRecords: [],
		matchExprDepth: 0,
		initTracker: createInitTracker(),
		affineTracker: createAffineTracker(),
		strictDefs: false,
		strictNullChecks: false,
		inTryExpr: false,
		genericInstDepth: 0,
		generatedInstances: [],
		pendingEnumToStrings: [],
		pendingHoisted: [],
		localTypeNames: new HashMap<string, boolean>(),
		pendingLocalTypeDecls: [],
		condEvalDepth: 0,
		inGenericContext: 0,
		stmtPosExpr: null as unknown as Node,
		preludeCtx: null as unknown as CheckerContext,
	};
}

export function createModuleContext(graph: ModuleGraph, mod: Module): CheckerContext {
	const ctx = createContext();
	ctx.moduleGraph = graph;
	ctx.currentModule = mod;
	ctx.modulePath = mod.path;
	return ctx;
}

export function requestEnumToString(cc: CheckerContext, t: Type): void {
	if (cc === null || t === null || t.typeName === "") return;
	for (const e of cc.pendingEnumToStrings) {
		if (e.typeName === t.typeName) return;
	}
	cc.pendingEnumToStrings.push(t);
}

// Create context with a shared IdentCache (one cache per compilation).
// Eliminates cross-context nameId mismatch during generic instantiation.
export function createContextWithCache(cache: IdentCache): CheckerContext {
	const ctx = createContext();
	ctx.table.identCache = cache;
	return ctx;
}

export function createModuleContextWithCache(graph: ModuleGraph, mod: Module, cache: IdentCache): CheckerContext {
	const ctx = createModuleContext(graph, mod);
	ctx.table.identCache = cache;
	return ctx;
}

// ===== Error Collection =====

// localError — non-fatal, compilation continues
let _engineCheckMode = false;

export function setEngineCheckMode(on: boolean): boolean {
	const prev = _engineCheckMode;
	_engineCheckMode = on;
	return prev;
}

export function isEngineCheckMode(): boolean {
	return _engineCheckMode;
}

export function addError(ctx: CheckerContext, msg: string, line: number, col: number): void {
	ctx.errors.push({ message: msg, line, column: col, endLine: 0, endColumn: 0, fatal: false, severity: Severity.Error, tags: 0 });
}

// error with explicit end column — underlines a range (e.g., full identifier)
export function addErrorRange(ctx: CheckerContext, msg: string, line: number, col: number, endCol: number): void {
	ctx.errors.push({ message: msg, line, column: col, endLine: 0, endColumn: endCol, fatal: false, severity: Severity.Error, tags: 0 });
}

// error with full range (start line:col → end line:col) — for multi-line highlights
export function addErrorFullRange(ctx: CheckerContext, msg: string, line: number, col: number, endLine: number, endCol: number): void {
	ctx.errors.push({ message: msg, line, column: col, endLine, endColumn: endCol, fatal: false, severity: Severity.Error, tags: 0 });
}

// warning with full range
export function addWarningFullRange(ctx: CheckerContext, msg: string, line: number, col: number, endLine: number, endCol: number): void {
	ctx.errors.push({ message: msg, line, column: col, endLine, endColumn: endCol, fatal: false, severity: Severity.Warning, tags: 0 });
}

// warning — non-fatal, compilation continues, shown as warning in LSP
export function addWarning(ctx: CheckerContext, msg: string, line: number, col: number): void {
	ctx.errors.push({ message: msg, line, column: col, endLine: 0, endColumn: 0, fatal: false, severity: Severity.Warning, tags: 0 });
}

export function addWarningRange(ctx: CheckerContext, msg: string, line: number, col: number, endCol: number, tags: number): void {
	ctx.errors.push({ message: msg, line, column: col, endLine: 0, endColumn: endCol, fatal: false, severity: Severity.Warning, tags });
}

// globalError — fatal, compilation should abort
export function addFatalError(ctx: CheckerContext, msg: string, line: number, col: number): void {
	ctx.errors.push({ message: msg, line, column: col, endLine: 0, endColumn: 0, fatal: true, severity: Severity.Error, tags: 0 });
}

export function addFatalErrorRange(ctx: CheckerContext, msg: string, line: number, col: number, endCol: number): void {
	ctx.errors.push({ message: msg, line, column: col, endLine: 0, endColumn: endCol, fatal: true, severity: Severity.Error, tags: 0 });
}

// hint — non-fatal, shown as subtle hint in LSP (curly underline + faded when tag=1)
export function addHint(ctx: CheckerContext, msg: string, line: number, col: number, tags: number): void {
	ctx.errors.push({ message: msg, line, column: col, endLine: 0, endColumn: 0, fatal: false, severity: Severity.Hint, tags });
}

export function addHintRange(ctx: CheckerContext, msg: string, line: number, col: number, endCol: number, tags: number): void {
	ctx.errors.push({ message: msg, line, column: col, endLine: 0, endColumn: endCol, fatal: false, severity: Severity.Hint, tags });
}

export function hasErrors(ctx: CheckerContext): boolean {
	for (const err of ctx.errors) {
		if (err.severity === Severity.Error) return true;
	}
	return false;
}

export function hasFatalErrors(ctx: CheckerContext): boolean {
	for (let i = 0; i < ctx.errors.length; i += 1) {
		if (ctx.errors[i].fatal) return true;
	}
	return false;
}

export function errorCount(ctx: CheckerContext): int32 {
	let count = 0;
	for (let i = 0; i < ctx.errors.length; i += 1) {
		if (ctx.errors[i].severity === Severity.Error) count = count + 1;
	}
	return count;
}

export function errorMessage(err: CheckerError): string {
	return err.message;
}

// ===== Context Cache (DRC-safe: CheckerContext in struct fields ONLY here) =====

interface CtxCacheEntry {
	key: number;
	ctx: CheckerContext;
}

interface CtxCache {
	items: CtxCacheEntry[];
}

let _ctxCache: CtxCache = { items: [] };

export function ctxCacheStore(key: number, ctx: CheckerContext): void {
	for (let i = 0; i < _ctxCache.items.length; i = i + 1) {
		if (_ctxCache.items[i].key === key) {
			_ctxCache.items[i].ctx = ctx;
			return;
		}
	}
	const entry: CtxCacheEntry = { key: key, ctx: ctx };
	_ctxCache.items.push(entry);
}

export function ctxCacheGet(key: number): CheckerContext {
	for (let i = 0; i < _ctxCache.items.length; i = i + 1) {
		if (_ctxCache.items[i].key === key) return _ctxCache.items[i].ctx;
	}
	return null as unknown as CheckerContext;
}

export function ctxCacheClear(): void {
	const empty: CtxCacheEntry[] = [];
	_ctxCache.items = empty;
}

// ===== Tests =====
test "create context" {
	const ctx = createContext();
	assert !hasErrors(ctx);
	assert ctx.table.current.scopeKind === ScopeKind.Global;
	assert ctx.currentFunction === null;
	assert !ctx.inLoop;
	assert ctx.moduleGraph === null;
	assert ctx.currentModule === null;
	assert ctx.symRecords.length === 0;
}

test "sgSortRecords sorts by line then col" {
	const records: SgSymRecord[] = [];
	const dummySym = null as unknown as Symbol;
	const dummyType = noneType();
	records.push({ line: 3, col: 5, colEnd: 8, sym: dummySym, symType: dummyType, kind: SymbolKind.Variable, name: "c", containerName: "", isDecl: false });
	records.push({ line: 1, col: 10, colEnd: 13, sym: dummySym, symType: dummyType, kind: SymbolKind.Variable, name: "a", containerName: "", isDecl: false });
	records.push({ line: 1, col: 1, colEnd: 4, sym: dummySym, symType: dummyType, kind: SymbolKind.Variable, name: "b", containerName: "", isDecl: false });
	sgSortRecords(records);
	assert records[0].name === "b";
	assert records[1].name === "a";
	assert records[2].name === "c";
}

test "create module context" {
	const graph = createModuleGraph();
	const mod = createModule("/a/b.ms");
	const ctx = createModuleContext(graph, mod);
	assert !hasErrors(ctx);
	assert ctx.moduleGraph !== null;
	assert ctx.currentModule !== null;
	assert ctx.currentModule.path === "/a/b.ms";
	assert ctx.exportRegistry !== null;
}

test "error collection" {
	const ctx = createContext();
	assert errorCount(ctx) === 0;
	addError(ctx, "test error", 1, 0);
	assert hasErrors(ctx);
	assert errorCount(ctx) === 1;
	addError(ctx, "another error", 2, 5);
	assert errorCount(ctx) === 2;
	assert ctx.errors[0].message === "test error";
	assert ctx.errors[0].line === 1;
	assert ctx.errors[1].message === "another error";
	assert ctx.errors[1].line === 2;
}

test "create empty" {
	const r = createExtensionRegistry();
	assert r.methods.length === 0;
}

test "register and find" {
	const r = createExtensionRegistry();
	const m: ExtensionMethod = { methodName: "trim", receiverTypeName: "string", sourcePath: "/a.ms", fnType: noneType(), isStatic: false, sym: null };
	registerExtension(r, m);
	const found = findExtension(r, "string", "trim");
	assert found !== null;
	assert found.methodName === "trim";
}

test "not found" {
	const r = createExtensionRegistry();
	const found = findExtension(r, "string", "nope");
	assert found === null;
}

test "namespace receiver is name-keyed, not kind-keyed" {
	const r = createExtensionRegistry();
	const inst: ExtensionMethod = { methodName: "trim", receiverTypeName: "String", sourcePath: "/a.ms", fnType: noneType(), isStatic: false, sym: null };
	const stat: ExtensionMethod = { methodName: "fromCharCode", receiverTypeName: "String", sourcePath: "/a.ms", fnType: noneType(), isStatic: true, sym: null };
	registerExtension(r, inst);
	registerExtension(r, stat);
	assert hasStaticExtForReceiver(r, "String");
	assert !hasStaticExtForReceiver(r, "helper");
	assert !hasStaticExtForReceiver(r, "");
}

test "static ext filter keeps only statics of that receiver" {
	const stat: ExtensionMethod = { methodName: "m", receiverTypeName: "String", sourcePath: "/a.ms", fnType: noneType(), isStatic: true, sym: null };
	const otherRecv: ExtensionMethod = { methodName: "m", receiverTypeName: "Buffer", sourcePath: "/a.ms", fnType: noneType(), isStatic: true, sym: null };
	const inst: ExtensionMethod = { methodName: "m", receiverTypeName: "String", sourcePath: "/a.ms", fnType: noneType(), isStatic: false, sym: null };
	const all: ExtensionMethod[] = [stat, otherRecv, inst];
	const got = filterStaticExtsByReceiverName(all, "String");
	assert got.length === 1;
	assert got[0].receiverTypeName === "String";
	assert got[0].isStatic;
	assert filterStaticExtsByReceiverName(all, "").length === 0;
}

test "no attached ops" {
	const r = createExtensionRegistry();
	const ops = findAttachedOps(r, "Foo");
	assert !hasAttachedOps(ops);
}

test "detect onDestroy" {
	const r = createExtensionRegistry();
	const m: ExtensionMethod = { methodName: "onDestroy", receiverTypeName: "Foo", sourcePath: "/a.ms", fnType: noneType(), isStatic: false, sym: null };
	registerExtension(r, m);
	const ops = findAttachedOps(r, "Foo");
	assert hasAttachedOps(ops);
	assert ops.onDestroy !== null;
	assert ops.onCopy === null;
}

test "detect all lifecycle hooks" {
	const r = createExtensionRegistry();
	const d: ExtensionMethod = { methodName: "onDestroy", receiverTypeName: "Bar", sourcePath: "/a.ms", fnType: noneType(), isStatic: false, sym: null };
	registerExtension(r, d);
	const c: ExtensionMethod = { methodName: "onCopy", receiverTypeName: "Bar", sourcePath: "/a.ms", fnType: noneType(), isStatic: false, sym: null };
	registerExtension(r, c);
	const mv: ExtensionMethod = { methodName: "onMove", receiverTypeName: "Bar", sourcePath: "/a.ms", fnType: noneType(), isStatic: false, sym: null };
	registerExtension(r, mv);
	const ops = findAttachedOps(r, "Bar");
	assert hasAttachedOps(ops);
	assert ops.onDestroy !== null;
	assert ops.onCopy !== null;
	assert ops.onMove !== null;
}

test "wrong type no match" {
	const r = createExtensionRegistry();
	const m: ExtensionMethod = { methodName: "onDestroy", receiverTypeName: "Foo", sourcePath: "/a.ms", fnType: noneType(), isStatic: false, sym: null };
	registerExtension(r, m);
	const ops = findAttachedOps(r, "Bar");
	assert !hasAttachedOps(ops);
}

test "create empty registry" {
	const r = createExportRegistry();
	assert r.entries.length === 0;
}

test "register and find exports" {
	const r = createExportRegistry();
	const syms: ExportedSymInfo[] = [];
	const info: ExportedSymInfo = { name: "foo", kind: SymbolKind.Function, symType: noneType(), overloadTypes: [], extReceiverType: "", extIsStatic: false, overloadExtReceiverTypes: [], overloadExtIsStatic: [], nativeName: "", builtinKind: "", overloadNativeNames: [], overloadBuiltinKinds: [], defaultParams: [], overloadDefaultParamsFlat: [], overloadDefaultParamsCounts: [], location: makeLoc(0, 0), memberLocations: [], primaryFlags: 0, overloadFlags: [], macroBody: null as unknown as Node, macroParams: [], macroParamTypes: [], declNode: null as unknown as Node, overloadDeclNodes: [] };
	syms.push(info);
	registerModuleExports(r, "/src/b.ms", syms);
	const found = findExportedSymbol(r, "/src/b.ms", "foo");
	assert found !== null;
	assert found.name === "foo";
	assert found.kind === SymbolKind.Function;
}

test "missing module returns null" {
	const r = createExportRegistry();
	const found = findExportedSymbol(r, "/nope.ms", "x");
	assert found === null;
}

test "missing symbol returns null" {
	const r = createExportRegistry();
	const syms: ExportedSymInfo[] = [];
	const info: ExportedSymInfo = { name: "foo", kind: SymbolKind.Function, symType: noneType(), overloadTypes: [], extReceiverType: "", extIsStatic: false, overloadExtReceiverTypes: [], overloadExtIsStatic: [], nativeName: "", builtinKind: "", overloadNativeNames: [], overloadBuiltinKinds: [], defaultParams: [], overloadDefaultParamsFlat: [], overloadDefaultParamsCounts: [], location: makeLoc(0, 0), memberLocations: [], primaryFlags: 0, overloadFlags: [], macroBody: null as unknown as Node, macroParams: [], macroParamTypes: [], declNode: null as unknown as Node, overloadDeclNodes: [] };
	syms.push(info);
	registerModuleExports(r, "/src/b.ms", syms);
	const found = findExportedSymbol(r, "/src/b.ms", "bar");
	assert found === null;
}

test "extractGenericNames single" {
	const names = extractGenericNames("gen:T");
	assert names.length === 1;
	assert names[0] === "T";
}

test "extractGenericNames multiple" {
	const names = extractGenericNames("gen:T,U,V");
	assert names.length === 3;
	assert names[0] === "T";
	assert names[1] === "U";
	assert names[2] === "V";
}

test "extractGenericNames with async" {
	const names = extractGenericNames("async|gen:T");
	assert names.length === 1;
	assert names[0] === "T";
}

test "extractGenericNames empty" {
	const names = extractGenericNames("");
	assert names.length === 0;
}

test "extractGenericNames no gen" {
	const names = extractGenericNames("async");
	assert names.length === 0;
}

test "stripGenFlag simple" { assert stripGenFlag("gen:T") === ""; }

test "stripGenFlag with async" { assert stripGenFlag("async|gen:T") === "async"; }

test "stripGenFlag no gen" { assert stripGenFlag("async") === "async"; }

test "isExtensionFlag prefix" {
	assert isExtensionFlag("ext:s:string");
	assert !isExtensionFlag("");
	assert !isExtensionFlag("async");
}

test "isExtensionFlag pipe-delimited" {
	assert isExtensionFlag("async|ext:s:string");
	assert isExtensionFlag("gen:T|ext:self:Array");
}

test "getExtReceiverName" {
	assert getExtReceiverName("ext:s:string") === "s";
	assert getExtReceiverName("async|ext:self:Array") === "self";
	assert getExtReceiverName("") === "";
}

test "getExtReceiverType" {
	assert getExtReceiverType("ext:s:string") === "string";
	assert getExtReceiverType("async|ext:self:Array") === "Array";
	assert getExtReceiverType("") === "";
}

test "isStaticExtensionFlag" {
	assert isStaticExtensionFlag("sext:Math");
	assert isStaticExtensionFlag("async|sext:Promise");
	assert !isStaticExtensionFlag("ext:s:string");
	assert !isStaticExtensionFlag("");
}

test "getStaticExtTypeName" {
	assert getStaticExtTypeName("sext:Math") === "Math";
	assert getStaticExtTypeName("async|sext:Promise") === "Promise";
	assert getStaticExtTypeName("") === "";
}

test "static extension in registry" {
	const r = createExtensionRegistry();
	const m: ExtensionMethod = { methodName: "floor", receiverTypeName: "Math", sourcePath: "", fnType: noneType(), isStatic: true, sym: null };
	registerExtension(r, m);
	const found = findExtension(r, "Math", "floor");
	assert found !== null;
	assert found.isStatic;
}

test "instance extension isStatic false" {
	const r = createExtensionRegistry();
	const m: ExtensionMethod = { methodName: "trim", receiverTypeName: "string", sourcePath: "", fnType: noneType(), isStatic: false, sym: null };
	registerExtension(r, m);
	const found = findExtension(r, "string", "trim");
	assert found !== null;
	assert !found.isStatic;
}

// ===== Global type-owner registry (compilation-wide) =====
// bare type name → declaring modulePath, recorded at collect time for every
// module-level type decl. Codegen's mangledTypeName consults this when a Type
// lost its sym (macro-wire / mono round-trips are FLAT and drop identity) so
// the consumer still derives the owner's qualified C name. A name claimed by
// two different modules is ambiguous — resolution then keeps the bare name
// (pre-existing behavior for that corner).

const _globalTypeOwners: Map<string, string> = new Map<string, string>();

export function recordGlobalTypeOwner(name: string, modulePath: string): void {
	if (name === "" || modulePath === "") return;
	const prev = _globalTypeOwners.get(name);
	if (prev === null) {
		_globalTypeOwners.set(name, modulePath);
		return;
	}
	if (prev !== modulePath) {
		_globalTypeOwners.set(name, "\u0001AMBIGUOUS");
	}
}

export function getGlobalTypeOwner(name: string): string {
	const v = _globalTypeOwners.get(name);
	if (v === null || v === "AMBIGUOUS") return "";
	return v;
}

// Shape-keyed variant: two modules may declare the same type NAME with
// different fields (the coarse map goes ambiguous) — the field list usually
// still identifies the owner. Recorded at ensureShaped, when fields exist.

const _globalTypeShapes: Map<string, string> = new Map<string, string>();

export function recordGlobalTypeShape(name: string, shapeKey: string, modulePath: string): void {
	if (name === "" || shapeKey === "" || modulePath === "") return;
	const key = name + "|" + shapeKey;
	const prev = _globalTypeShapes.get(key);
	if (prev === null) {
		_globalTypeShapes.set(key, modulePath);
		return;
	}
	if (prev !== modulePath) {
		_globalTypeShapes.set(key, "AMBIGUOUS");
	}
}

export function getGlobalTypeOwnerByShape(name: string, shapeKey: string): string {
	const v = _globalTypeShapes.get(name + "|" + shapeKey);
	if (v === null || v === "AMBIGUOUS") return "";
	return v;
}

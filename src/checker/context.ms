import { unknownType, hasGenericParams, unifyType, createUnifyBindings, typeNameOf, createFunction, getMinArity, setMinArity, isPromiseResult } from "./types";
import { isAssignable } from "./compat";
import { SymbolTable, ScopeKind, SymbolFlag, createSymbolTable, createSymbolTableWithCache, hasFlag } from "./symbol";
import { IdentCache } from "./idents";
import { Module, ModuleGraph, createModuleGraph, createModule } from "../module/graph";
import { Node, NodeKind, SourceLocation, makeLoc, Type, TypeKind, Symbol, SymbolKind, EnumDeclData } from "../ast/node";
import { findChar, splitTopLevel } from "../utils/string";
import { InitTracker, createInitTracker } from "./initTracker";


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
	overloadDefaultParamsCounts: number[];
	definingModule: string;  // Original defining module path (preserved through re-exports)
	originalName: string;    // Original declared name (used for C mangling, not import alias)
	headerPath: string;      // @include header path for this extern symbol
	jsModulePath: string;    // @import JS module path for this extern symbol
	hasConstructor: boolean; // class has ConstructorDecl → codegen calls ClassName_new()
	location: SourceLocation; // Original declaration location (line/col in defining module)
	memberLocations: SourceLocation[]; // Per-enum-member declaration locations (parallel to symType.typeNames)
}

export interface ModuleExports {
	modulePath: string;
	symbols: ExportedSymInfo[];
}

export interface ExportRegistry {
	entries: ModuleExports[];
}

export function createExportRegistry(): ExportRegistry {
	return { entries: [] };
}

export function registerModuleExports(registry: ExportRegistry, modulePath: string, exports: ExportedSymInfo[]): void {
	const entry: ModuleExports = { modulePath, symbols: exports };
	registry.entries.push(entry);
}

// Replace existing module's exports (Phase 2 updates Phase 1 placeholders)
export function updateModuleExports(registry: ExportRegistry, modulePath: string, exports: ExportedSymInfo[]): void {
	for (let i = 0; i < registry.entries.length; i += 1) {
		if (registry.entries[i].modulePath === modulePath) {
			registry.entries[i].symbols = exports;
			return;
		}
	}
	// Not found — register fresh (defensive)
	registerModuleExports(registry, modulePath, exports);
}

export function findModuleExports(registry: ExportRegistry, modulePath: string): ModuleExports {
	for (const entry of registry.entries) {
		if (entry.modulePath === modulePath) return entry;
	}
	return null as unknown as ModuleExports;
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

export function buildExportInfo(sym: Symbol, extensionRegistry: ExtensionRegistry, modulePath: string): ExportedSymInfo {
	// Extension receiver metadata for primary symbol
	let extRecv = "";
	let extStatic = false;
	if (extensionRegistry !== null && sym.symbolKind === SymbolKind.Function) {
		const ext = findExtensionByType(extensionRegistry, sym.name, sym.symbolType);
		if (ext !== null) {
			extRecv = ext.receiverTypeName;
			extStatic = ext.isStatic;
		} else {
			const extFb = findExtensionByName(extensionRegistry, sym.name);
			if (extFb !== null) {
				extRecv = extFb.receiverTypeName;
				extStatic = extFb.isStatic;
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
	}

	// Collect overload types + per-overload metadata
	const ovTypes: Type[] = [];
	const ovExtRecvs: string[] = [];
	const ovExtStatics: boolean[] = [];
	const ovRtNames: string[] = [];
	const ovBiKinds: string[] = [];
	const ovDefParamsFlat: Node[] = [];
	const ovDefParamsCounts: number[] = [];

	let ovi = 0;
	while (ovi < sym.overloads.length) {
		ovTypes.push(sym.overloads[ovi].symbolType);
		ovRtNames.push(sym.overloads[ovi].nativeName);
		ovBiKinds.push(sym.overloads[ovi].builtinKind);

		if (extensionRegistry !== null) {
			const ovExt = findExtensionByType(extensionRegistry, sym.name, sym.overloads[ovi].symbolType);
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
		jsModulePath: sym.jsModulePath,
		hasConstructor: hasFlag(sym, SymbolFlag.HasConstructor),
		location: sym.location !== null ? sym.location : makeLoc(0, 0),
		memberLocations: memberLocs,
	};
}

// Collect all exported symbols: scope symbols + class method extensions.
// Single source of truth — used by orchestrator (multi-module) and TransAm (LSP).
export function collectExports(ctx: CheckerContext, modulePath: string): ExportedSymInfo[] {
	const exports: ExportedSymInfo[] = [];
	for (const sym of ctx.table.current.symbols) {
		if (hasFlag(sym, SymbolFlag.Exported)) {
			exports.push(buildExportInfo(sym, ctx.extensionRegistry, modulePath));
		}
	}
	if (ctx.extensionRegistry !== null) {
		for (const ext of ctx.extensionRegistry.methods) {
			if (ext.sym !== null && hasFlag(ext.sym, SymbolFlag.Exported)) {
				let alreadyExported = false;
				for (const e of exports) {
					if (e.name === ext.sym.name) { alreadyExported = true; break; }
				}
				if (!alreadyExported) {
					exports.push(buildExportInfo(ext.sym, ctx.extensionRegistry, modulePath));
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
// INVARIANT (reference parity: Nim PSym.typ is the single type source):
//   sym is the authoritative type source. Use getExtFnType(ext) to read the type.
//   fnType is a FALLBACK for when sym is null (early collectPass, before symbol is available).
//   When sym is non-null, fnType MUST be unknownType() — never the same Type as sym.symbolType.
//   Storing the same Type in both causes double-decref on destruction (DRC double ownership).
export class ExtensionMethod {
	methodName: string;
	receiverTypeName: string;
	sourcePath: string;
	fnType: Type;           // fallback only — use getExtFnType(ext), never read directly
	isStatic: boolean;
	sym: Symbol;            // authoritative type source (sym.symbolType)
	scopeDepth: number;     // 0 = imported/prelude, 1 = current module (for overload resolution)
}

export class ExtensionRegistry {
	methods: ExtensionMethod[];
}

export function createExtensionRegistry(): ExtensionRegistry {
	return { methods: [] };
}

// Create an ExtensionMethod with proper ownership invariant enforced.
// When sym is provided, fnType is set to unknownType() — sym.symbolType is authoritative.
// This prevents double-decref when both fnType and sym.symbolType reference the same Type.
export function createExtMethod(methodName: string, receiverTypeName: string, sourcePath: string, fnType: Type, isStatic: boolean, sym: Symbol, scopeDepth: number): ExtensionMethod {
	return {
		methodName, receiverTypeName, sourcePath,
		fnType: sym !== null ? unknownType() : fnType,
		isStatic, sym, scopeDepth,
	};
}

export function registerExtension(registry: ExtensionRegistry, method: ExtensionMethod): void {
	// Dedup by sym identity only (keeps all candidates, resolves via scoring + scope depth).
	if (method.sym !== null) {
		let i = 0;
		while (i < registry.methods.length) {
			if (registry.methods[i].sym === method.sym) return;
			i = i + 1;
		}
	}
	registry.methods.push(method);
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
export function findAllExtensionsByName(registry: ExtensionRegistry, methodName: string): ExtensionMethod[] {
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

// ===== Canonical Extension Type (Standard reference symbol type equivalent) =====
// Standard reference: the symbol's type is the single source of truth.
// ext.fnType is a registration-time snapshot that may be stale (unknownType from collectPass).
// Always use this helper instead of reading ext.fnType directly.

export function getExtFnType(ext: ExtensionMethod): Type {
	if (ext.sym !== null && ext.sym.symbolType !== null && ext.sym.symbolType.kind === TypeKind.Function) {
		return ext.sym.symbolType;
	}
	return ext.fnType;
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

export function isReceiverMatch(ext: ExtensionMethod, objType: Type): boolean {
	// Static extensions: string-based matching (receiver not in typeChildren)
	if (ext.isStatic) {
		return ext.receiverTypeName === typeNameOf(objType);
	}
	// Instance extensions: type-based matching on first param (sym.typ is authoritative).
	const fnType = getExtFnType(ext);
	if (fnType.kind !== TypeKind.Function) return false;
	if (fnType.typeChildren.length === 0) return false;
	const receiverType = fnType.typeChildren[0];
	// Unknown receiver: match any (conservative — unresolved type)
	if (receiverType.kind === TypeKind.Unknown) return true;
	// Generic extensions: try unification on receiver param.
	// e.g. map<T>(this arr: T[]) should match number[] but NOT string.
	if (hasGenericParams(receiverType)) {
		const eb = createUnifyBindings();
		unifyType(receiverType, objType, eb);
		if (eb.names.length > 0) return true;
		// Unification failed (e.g., Array<T> class vs uint8[] array — different type kinds).
		// Fall through to name-based matching below.
	}
	// Concrete array extensions: element type compatibility is authoritative.
	// Don't fall through to name-based matching (which matches all "Array" extensions
	// regardless of element type — e.g., pop(number[]) would incorrectly match Bar[]).
	// Reference parity: sigmatch scores exact element match over generic, so concrete
	// overloads with wrong element types are rejected, not accepted via name fallback.
	if (receiverType.kind === TypeKind.Array && objType.kind === TypeKind.Array) {
		const recvElem = receiverType.typeReturn;
		const objElem = objType.typeReturn;
		if (recvElem === null || objElem === null) return false;
		if (recvElem.kind === TypeKind.Unknown || objElem.kind === TypeKind.Unknown) return false;
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
		// Nominal mismatch: both have names but they differ → not a match.
		// Prevents structural false positives (reference: sameObjectTypes uses a.id == b.id).
		if (objName !== "") return false;
	}
	return isAssignable(objType, receiverType);
}

export function filterExtsByReceiverType(exts: ExtensionMethod[], objType: Type): ExtensionMethod[] {
	const results: ExtensionMethod[] = [];
	let i = 0;
	while (i < exts.length) {
		if (isReceiverMatch(exts[i], objType)) {
			results.push(exts[i]);
		}
		i = i + 1;
	}
	return results;
}

export function findFirstMatchingExt(exts: ExtensionMethod[], objType: Type): ExtensionMethod {
	let i = 0;
	while (i < exts.length) {
		if (isReceiverMatch(exts[i], objType)) return exts[i];
		i = i + 1;
	}
	return null as unknown as ExtensionMethod;
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
	// Strip generic params: "Map<K, V>" or "Map < K , V >" → "Map" for receiver matching
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
	line: number;          // 1-based (parser convention)
	col: number;           // 1-based (parser convention)
	colEnd: number;        // col + token length
	sym: Symbol;           // resolved symbol
	symType: Type;         // type at this use site
	kind: SymbolKind;      // may override sym.symbolKind (e.g. Method for class functions)
	name: string;          // display name (may differ from sym.name for mangled methods)
	containerName: string; // owning type name ("console" for console.log)
	isDecl: boolean;       // true = definition, false = usage
}

export function sgRecordSym(
	ctx: CheckerContext, line: number, col: number, colEnd: number,
	sym: Symbol, symType: Type, kind: SymbolKind,
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
	endColumn: number; // 1-based, 0 = use column+1 (single char)
	fatal: boolean;  // true = globalError (abort), false = localError (continue)
	severity: Severity;
}

// ===== GC Mode =====
// Controls DRC (Deterministic Reference Counting) behavior.
// Auto: compiler scans types, enables DRC only if RC types are found.
// Orc: always enable DRC (user-forced).
// None: never enable DRC (user-forced, compile error on RC types).

export enum GcMode {
	Auto,
	Orc,
	None,
}

export class CheckerContext {
	table: SymbolTable;
	errors: CheckerError[];
	gcMode: GcMode;                // DRC mode — Auto (default), Orc (forced on), None (forced off)
	currentFunction: Symbol;   // innermost function (for return type validation)
	inLoop: boolean;           // break/continue validation
	inTestBlock: boolean;      // assert validation — only allowed inside test blocks
	moduleGraph: ModuleGraph;
	currentModule: Module;
	exportRegistry: ExportRegistry;
	extensionRegistry: ExtensionRegistry;
	inferredReturn: Type;  // tracks inferred return type during function body checking
	includeDirectives: string; // accumulated @include args, newline-separated
	jsImportRegistry: JsImportEntry[]; // accumulated @import entries for JS backend
	compileDirectives: string; // accumulated @compile args, newline-separated
	compilerFlags: string;     // accumulated @passC/-iquote args, space-separated (compile-time)
	linkFlags: string;         // accumulated @link/@passL args, space-separated (link-time only)
	cancelCtx: CancelCtx;       // null in batch mode, set for LSP
	cancelVersion: number;       // version at check start
	modulePath: string;          // Implementation parity: source path for name mangling
	narrowFacts: Node[];         // fact-based null narrowing knowledge base (standard reference equivalent)
	symRecords: SgSymRecord[];   // check-time symbol recordings for LSP (reference suggest parity)
	matchExprDepth: number;      // >0 when inside match expression block arm (return targets match, not function)
	initTracker: InitTracker;    // ref parity: TEffects.init — definite assignment tracking
	strictDefs: boolean;         // ref parity: strictDefs — warn on all uninit var use
	strictNullChecks: boolean;   // ref parity: strictNotNil — warn on unguarded class deref
	inTryExpr: boolean;          // true when checking tryArg of TryExpr or body of TryCatchStmt (V2 await guard)
	genericInstDepth: int32;     // recursion depth for on-demand instantiation (limit 50)
	generatedInstances: Node[];  // on-demand instantiated function ASTs to inject into program
	preludeCtx: CheckerContext;  // access private prelude symbols during instantiation
}

// ===== Constructors =====

export function createContext(): CheckerContext {
	const table = createSymbolTable();
	return {
		table,
		errors: [],
		gcMode: GcMode.Auto,
		currentFunction: null as unknown as Symbol,
		inLoop: false,
		inTestBlock: false,
		moduleGraph: null as unknown as ModuleGraph,
		currentModule: null as unknown as Module,
		exportRegistry: createExportRegistry(),
		extensionRegistry: createExtensionRegistry(),
		inferredReturn: unknownType(),
		includeDirectives: "",
		jsImportRegistry: [],
		compileDirectives: "",
		compilerFlags: "",
		linkFlags: "",
		cancelCtx: null as unknown as CancelCtx,
		cancelVersion: 0,
		modulePath: "",
		narrowFacts: [],
		symRecords: [],
		matchExprDepth: 0,
		initTracker: createInitTracker(),
		strictDefs: false,
		strictNullChecks: false,
		inTryExpr: false,
		genericInstDepth: 0,
		generatedInstances: [],
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

// ===== Promise<Result<T,E>> Context Check =====

export function isInAsyncPromiseResult(ctx: CheckerContext): boolean {
	return ctx.currentFunction !== null
		&& hasFlag(ctx.currentFunction, SymbolFlag.Async)
		&& ctx.currentFunction.symbolType !== null
		&& ctx.currentFunction.symbolType.kind === TypeKind.Function
		&& isPromiseResult(ctx.currentFunction.symbolType.typeReturn);
}

// ===== Error Collection =====

// localError — non-fatal, compilation continues
export function addError(ctx: CheckerContext, msg: string, line: number, col: number): void {
	ctx.errors.push({ message: msg, line, column: col, endColumn: 0, fatal: false, severity: Severity.Error });
}

// error with explicit end column — underlines a range (e.g., full identifier)
export function addErrorRange(ctx: CheckerContext, msg: string, line: number, col: number, endCol: number): void {
	ctx.errors.push({ message: msg, line, column: col, endColumn: endCol, fatal: false, severity: Severity.Error });
}

// warning — non-fatal, compilation continues, shown as warning in LSP
export function addWarning(ctx: CheckerContext, msg: string, line: number, col: number): void {
	ctx.errors.push({ message: msg, line, column: col, endColumn: 0, fatal: false, severity: Severity.Warning });
}

export function addWarningRange(ctx: CheckerContext, msg: string, line: number, col: number, endCol: number): void {
	ctx.errors.push({ message: msg, line, column: col, endColumn: endCol, fatal: false, severity: Severity.Warning });
}

// globalError — fatal, compilation should abort
export function addFatalError(ctx: CheckerContext, msg: string, line: number, col: number): void {
	ctx.errors.push({ message: msg, line, column: col, endColumn: 0, fatal: true, severity: Severity.Error });
}

export function addFatalErrorRange(ctx: CheckerContext, msg: string, line: number, col: number, endCol: number): void {
	ctx.errors.push({ message: msg, line, column: col, endColumn: endCol, fatal: true, severity: Severity.Error });
}

export function hasErrors(ctx: CheckerContext): boolean {
	return ctx.errors.length > 0;
}

export function hasFatalErrors(ctx: CheckerContext): boolean {
	for (let i = 0; i < ctx.errors.length; i += 1) {
		if (ctx.errors[i].fatal) return true;
	}
	return false;
}

export function errorCount(ctx: CheckerContext): number {
	let count = 0;
	for (let i = 0; i < ctx.errors.length; i += 1) {
		if (ctx.errors[i].severity !== Severity.Warning) count = count + 1;
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
	const dummyType = unknownType();
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
	const m: ExtensionMethod = { methodName: "trim", receiverTypeName: "string", sourcePath: "/a.ms", fnType: unknownType(), isStatic: false, sym: null as unknown as Symbol };
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

test "no attached ops" {
	const r = createExtensionRegistry();
	const ops = findAttachedOps(r, "Foo");
	assert !hasAttachedOps(ops);
}

test "detect onDestroy" {
	const r = createExtensionRegistry();
	const m: ExtensionMethod = { methodName: "onDestroy", receiverTypeName: "Foo", sourcePath: "/a.ms", fnType: unknownType(), isStatic: false, sym: null as unknown as Symbol };
	registerExtension(r, m);
	const ops = findAttachedOps(r, "Foo");
	assert hasAttachedOps(ops);
	assert ops.onDestroy !== null;
	assert ops.onCopy === null;
}

test "detect all lifecycle hooks" {
	const r = createExtensionRegistry();
	const d: ExtensionMethod = { methodName: "onDestroy", receiverTypeName: "Bar", sourcePath: "/a.ms", fnType: unknownType(), isStatic: false, sym: null as unknown as Symbol };
	registerExtension(r, d);
	const c: ExtensionMethod = { methodName: "onCopy", receiverTypeName: "Bar", sourcePath: "/a.ms", fnType: unknownType(), isStatic: false, sym: null as unknown as Symbol };
	registerExtension(r, c);
	const mv: ExtensionMethod = { methodName: "onMove", receiverTypeName: "Bar", sourcePath: "/a.ms", fnType: unknownType(), isStatic: false, sym: null as unknown as Symbol };
	registerExtension(r, mv);
	const ops = findAttachedOps(r, "Bar");
	assert hasAttachedOps(ops);
	assert ops.onDestroy !== null;
	assert ops.onCopy !== null;
	assert ops.onMove !== null;
}

test "wrong type no match" {
	const r = createExtensionRegistry();
	const m: ExtensionMethod = { methodName: "onDestroy", receiverTypeName: "Foo", sourcePath: "/a.ms", fnType: unknownType(), isStatic: false, sym: null as unknown as Symbol };
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
	const info: ExportedSymInfo = { name: "foo", kind: SymbolKind.Function, symType: unknownType(), overloadTypes: [], extReceiverType: "", extIsStatic: false, overloadExtReceiverTypes: [], overloadExtIsStatic: [], nativeName: "", builtinKind: "", overloadNativeNames: [], overloadBuiltinKinds: [], defaultParams: [], overloadDefaultParamsFlat: [], overloadDefaultParamsCounts: [], location: makeLoc(0, 0), memberLocations: [] };
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
	const info: ExportedSymInfo = { name: "foo", kind: SymbolKind.Function, symType: unknownType(), overloadTypes: [], extReceiverType: "", extIsStatic: false, overloadExtReceiverTypes: [], overloadExtIsStatic: [], nativeName: "", builtinKind: "", overloadNativeNames: [], overloadBuiltinKinds: [], defaultParams: [], overloadDefaultParamsFlat: [], overloadDefaultParamsCounts: [], location: makeLoc(0, 0), memberLocations: [] };
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
	const m: ExtensionMethod = { methodName: "floor", receiverTypeName: "Math", sourcePath: "", fnType: unknownType(), isStatic: true, sym: null as unknown as Symbol };
	registerExtension(r, m);
	const found = findExtension(r, "Math", "floor");
	assert found !== null;
	assert found.isStatic;
}

test "instance extension isStatic false" {
	const r = createExtensionRegistry();
	const m: ExtensionMethod = { methodName: "trim", receiverTypeName: "string", sourcePath: "", fnType: unknownType(), isStatic: false, sym: null as unknown as Symbol };
	registerExtension(r, m);
	const found = findExtension(r, "string", "trim");
	assert found !== null;
	assert !found.isStatic;
}

import { Type, TypeKind, unknownType } from "./types";
import { Symbol, SymbolKind, SymbolTable, ScopeKind, createSymbolTable } from "./symbol";
import { Module, ModuleGraph, createModuleGraph, createModule } from "../module/graph";
import { sliceStr, findChar, trimStr, splitTopLevel } from "../utils/string";
import { check } from "std/testing";

// ===== Export Registry (cross-module type propagation) =====
// Lives only during checkModuleGraph execution — NOT on Module/ModuleGraph (DRC constraint).
// Nim parallel: g.ifaces[m.position].interf (per-module public symbol table)

export interface ExportedSymInfo {
	name: string;
	kind: SymbolKind;
	symType: Type;
	overloadTypes: Type[];
	extReceiverType: string;
	extIsStatic: boolean;
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

// ===== Extension Registry (extension method tracking) =====
// Tracks "function f(this self: Type)" declarations for method resolution.

export interface ExtensionMethod {
	methodName: string;
	receiverTypeName: string;
	sourcePath: string;
	fnType: Type;
	isStatic: boolean;
}

export interface ExtensionRegistry {
	methods: ExtensionMethod[];
}

export function createExtensionRegistry(): ExtensionRegistry {
	return { methods: [] };
}

export function registerExtension(registry: ExtensionRegistry, method: ExtensionMethod): void {
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

// findAllExtensions — find ALL extensions matching receiver type + method name.
// Returns array of matching ExtensionMethods for overload resolution.
export function findAllExtensions(registry: ExtensionRegistry, receiverTypeName: string, methodName: string): ExtensionMethod[] {
	const results: ExtensionMethod[] = [];
	let i = 0;
	while (i < registry.methods.length) {
		const m = registry.methods[i];
		if (m.receiverTypeName === receiverTypeName && m.methodName === methodName) {
			results.push(m);
		}
		i = i + 1;
	}
	return results;
}

// findAllExtensionsByName — find ALL extensions with a given method name (any receiver).
// Nim-aligned: candidates are collected by name, then filtered by type compatibility
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

// ===== Extension Flag Helpers =====
// Parse "ext:receiverName:receiverType" and "sext:TypeName" from pipe-delimited fnFlags.
// Segment-aware: works for "async|ext:s:string", not just prefix-only.

function findFlagSegment(flags: string, prefix: string): string {
	if (flags === "") return "";
	const parts = splitTopLevel(flags, "|");
	for (let i = 0; i < parts.length; i += 1) {
		const p = trimStr(parts[i]);
		if (p.length >= prefix.length && sliceStr(p, 0, prefix.length) === prefix) return p;
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
	const rest = sliceStr(seg, 4, seg.length);
	const colonPos = findChar(rest, ":");
	if (colonPos <= 0) return "";
	return sliceStr(rest, 0, colonPos);
}

export function getExtReceiverType(flags: string): string {
	const seg = findFlagSegment(flags, "ext:");
	if (seg === "") return "";
	const rest = sliceStr(seg, 4, seg.length);
	const colonPos = findChar(rest, ":");
	if (colonPos <= 0) return "";
	return sliceStr(rest, colonPos + 1, rest.length);
}

export function getStaticExtTypeName(flags: string): string {
	const seg = findFlagSegment(flags, "sext:");
	if (seg === "") return "";
	return sliceStr(seg, 5, seg.length);
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
		const trimPart = trimStr(parts[pi]);
		if (trimPart.length > 4) {
			const prefix = sliceStr(trimPart, 0, 4);
			if (prefix === "gen:") {
				const nameStr = sliceStr(trimPart, 4, trimPart.length);
				const names = splitTopLevel(nameStr, ",");
				for (let ni = 0; ni < names.length; ni += 1) {
					const trimName = trimStr(names[ni]);
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
		const trimPart = trimStr(parts[i]);
		if (trimPart.length > 4) {
			const prefix = sliceStr(trimPart, 0, 4);
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
// Matches TaCancelContext shape — avoids checker→transam circular dependency.
// LSP assigns db.cancelCtx to ctx.cancelCtx (structural compatibility under Bun).

export interface CancelCtx {
	version: number;
	cancelled: boolean;
}

export function isCancelled(cancel: CancelCtx, startVersion: number): boolean {
	if (cancel === null) return false;
	return cancel.version !== startVersion || cancel.cancelled;
}

// ===== Checker Context =====

export interface CheckerContext {
	table: SymbolTable;
	errors: string[];
	currentFunction: Symbol;   // innermost function (for return type validation)
	inLoop: boolean;           // break/continue validation
	moduleGraph: ModuleGraph;  // null for single-module mode
	currentModule: Module;     // null for single-module mode
	exportRegistry: ExportRegistry;  // null for single-module mode
	extensionRegistry: ExtensionRegistry;  // null for single-module mode
	inferredReturn: Type;  // tracks inferred return type during function body checking
	includeDirectives: string; // accumulated @include args, newline-separated
	compileDirectives: string; // accumulated @compile args, newline-separated
	compilerFlags: string;     // accumulated @link/@passC/@passL args, space-separated
	cancelCtx: CancelCtx;       // null in batch mode, set for LSP
	cancelVersion: number;       // version at check start
}

// ===== Constructors =====

export function createContext(): CheckerContext {
	const table = createSymbolTable();
	return {
		table,
		errors: [],
		currentFunction: null as unknown as Symbol,
		inLoop: false,
		moduleGraph: null as unknown as ModuleGraph,
		currentModule: null as unknown as Module,
		exportRegistry: null as unknown as ExportRegistry,
		extensionRegistry: createExtensionRegistry(),
		inferredReturn: unknownType(),
		includeDirectives: "",
		compileDirectives: "",
		compilerFlags: "",
		cancelCtx: null as unknown as CancelCtx,
		cancelVersion: 0,
	};
}

export function createModuleContext(graph: ModuleGraph, mod: Module): CheckerContext {
	const ctx = createContext();
	ctx.moduleGraph = graph;
	ctx.currentModule = mod;
	return ctx;
}

// ===== Error Collection =====

export function addError(ctx: CheckerContext, msg: string): void {
	ctx.errors.push(msg);
}

export function hasErrors(ctx: CheckerContext): boolean {
	return ctx.errors.length > 0;
}

export function errorCount(ctx: CheckerContext): number {
	return ctx.errors.length;
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
	check(!hasErrors(ctx));
	check(ctx.table.current.scopeKind === ScopeKind.Global);
	check(ctx.currentFunction === null);
	check(!ctx.inLoop);
	check(ctx.moduleGraph === null);
	check(ctx.currentModule === null);
}

test "create module context" {
	const graph = createModuleGraph();
	const mod = createModule("/a/b.ms");
	const ctx = createModuleContext(graph, mod);
	check(!hasErrors(ctx));
	check(ctx.moduleGraph !== null);
	check(ctx.currentModule !== null);
	check(ctx.currentModule.path === "/a/b.ms");
	check(ctx.exportRegistry === null);
}

test "error collection" {
	const ctx = createContext();
	check(errorCount(ctx) === 0);
	addError(ctx, "test error");
	check(hasErrors(ctx));
	check(errorCount(ctx) === 1);
	addError(ctx, "another error");
	check(errorCount(ctx) === 2);
}

test "create empty" {
	const r = createExtensionRegistry();
	check(r.methods.length === 0);
}

test "register and find" {
	const r = createExtensionRegistry();
	const m: ExtensionMethod = { methodName: "trim", receiverTypeName: "string", sourcePath: "/a.ms", fnType: unknownType(), isStatic: false };
	registerExtension(r, m);
	const found = findExtension(r, "string", "trim");
	check(found !== null);
	check(found.methodName === "trim");
}

test "not found" {
	const r = createExtensionRegistry();
	const found = findExtension(r, "string", "nope");
	check(found === null);
}

test "no attached ops" {
	const r = createExtensionRegistry();
	const ops = findAttachedOps(r, "Foo");
	check(!hasAttachedOps(ops));
}

test "detect onDestroy" {
	const r = createExtensionRegistry();
	const m: ExtensionMethod = { methodName: "onDestroy", receiverTypeName: "Foo", sourcePath: "/a.ms", fnType: unknownType(), isStatic: false };
	registerExtension(r, m);
	const ops = findAttachedOps(r, "Foo");
	check(hasAttachedOps(ops));
	check(ops.onDestroy !== null);
	check(ops.onCopy === null);
}

test "detect all lifecycle hooks" {
	const r = createExtensionRegistry();
	const d: ExtensionMethod = { methodName: "onDestroy", receiverTypeName: "Bar", sourcePath: "/a.ms", fnType: unknownType(), isStatic: false };
	registerExtension(r, d);
	const c: ExtensionMethod = { methodName: "onCopy", receiverTypeName: "Bar", sourcePath: "/a.ms", fnType: unknownType(), isStatic: false };
	registerExtension(r, c);
	const mv: ExtensionMethod = { methodName: "onMove", receiverTypeName: "Bar", sourcePath: "/a.ms", fnType: unknownType(), isStatic: false };
	registerExtension(r, mv);
	const ops = findAttachedOps(r, "Bar");
	check(hasAttachedOps(ops));
	check(ops.onDestroy !== null);
	check(ops.onCopy !== null);
	check(ops.onMove !== null);
}

test "wrong type no match" {
	const r = createExtensionRegistry();
	const m: ExtensionMethod = { methodName: "onDestroy", receiverTypeName: "Foo", sourcePath: "/a.ms", fnType: unknownType(), isStatic: false };
	registerExtension(r, m);
	const ops = findAttachedOps(r, "Bar");
	check(!hasAttachedOps(ops));
}

test "create empty registry" {
	const r = createExportRegistry();
	check(r.entries.length === 0);
}

test "register and find exports" {
	const r = createExportRegistry();
	const syms: ExportedSymInfo[] = [];
	const info: ExportedSymInfo = { name: "foo", kind: SymbolKind.Function, symType: unknownType(), extReceiverType: "", extIsStatic: false };
	syms.push(info);
	registerModuleExports(r, "/src/b.ms", syms);
	const found = findExportedSymbol(r, "/src/b.ms", "foo");
	check(found !== null);
	check(found.name === "foo");
	check(found.kind === SymbolKind.Function);
}

test "missing module returns null" {
	const r = createExportRegistry();
	const found = findExportedSymbol(r, "/nope.ms", "x");
	check(found === null);
}

test "missing symbol returns null" {
	const r = createExportRegistry();
	const syms: ExportedSymInfo[] = [];
	const info: ExportedSymInfo = { name: "foo", kind: SymbolKind.Function, symType: unknownType(), extReceiverType: "", extIsStatic: false };
	syms.push(info);
	registerModuleExports(r, "/src/b.ms", syms);
	const found = findExportedSymbol(r, "/src/b.ms", "bar");
	check(found === null);
}

test "extractGenericNames single" {
	const names = extractGenericNames("gen:T");
	check(names.length === 1);
	check(names[0] === "T");
}

test "extractGenericNames multiple" {
	const names = extractGenericNames("gen:T,U,V");
	check(names.length === 3);
	check(names[0] === "T");
	check(names[1] === "U");
	check(names[2] === "V");
}

test "extractGenericNames with async" {
	const names = extractGenericNames("async|gen:T");
	check(names.length === 1);
	check(names[0] === "T");
}

test "extractGenericNames empty" {
	const names = extractGenericNames("");
	check(names.length === 0);
}

test "extractGenericNames no gen" {
	const names = extractGenericNames("async");
	check(names.length === 0);
}

test "stripGenFlag simple" { check(stripGenFlag("gen:T") === ""); }

test "stripGenFlag with async" { check(stripGenFlag("async|gen:T") === "async"); }

test "stripGenFlag no gen" { check(stripGenFlag("async") === "async"); }

test "isExtensionFlag prefix" {
	check(isExtensionFlag("ext:s:string"));
	check(!isExtensionFlag(""));
	check(!isExtensionFlag("async"));
}

test "isExtensionFlag pipe-delimited" {
	check(isExtensionFlag("async|ext:s:string"));
	check(isExtensionFlag("gen:T|ext:self:Array"));
}

test "getExtReceiverName" {
	check(getExtReceiverName("ext:s:string") === "s");
	check(getExtReceiverName("async|ext:self:Array") === "self");
	check(getExtReceiverName("") === "");
}

test "getExtReceiverType" {
	check(getExtReceiverType("ext:s:string") === "string");
	check(getExtReceiverType("async|ext:self:Array") === "Array");
	check(getExtReceiverType("") === "");
}

test "isStaticExtensionFlag" {
	check(isStaticExtensionFlag("sext:Math"));
	check(isStaticExtensionFlag("async|sext:Promise"));
	check(!isStaticExtensionFlag("ext:s:string"));
	check(!isStaticExtensionFlag(""));
}

test "getStaticExtTypeName" {
	check(getStaticExtTypeName("sext:Math") === "Math");
	check(getStaticExtTypeName("async|sext:Promise") === "Promise");
	check(getStaticExtTypeName("") === "");
}

test "static extension in registry" {
	const r = createExtensionRegistry();
	const m: ExtensionMethod = { methodName: "floor", receiverTypeName: "Math", sourcePath: "", fnType: unknownType(), isStatic: true };
	registerExtension(r, m);
	const found = findExtension(r, "Math", "floor");
	check(found !== null);
	check(found.isStatic);
}

test "instance extension isStatic false" {
	const r = createExtensionRegistry();
	const m: ExtensionMethod = { methodName: "trim", receiverTypeName: "string", sourcePath: "", fnType: unknownType(), isStatic: false };
	registerExtension(r, m);
	const found = findExtension(r, "string", "trim");
	check(found !== null);
	check(!found.isStatic);
}

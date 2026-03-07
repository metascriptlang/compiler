import { Type, TypeKind, unknownType } from "./types";
import { Symbol, SymbolKind, SymbolTable, ScopeKind, createSymbolTable } from "./symbol";
import { Module, ModuleGraph, createModuleGraph, createModule } from "../module/graph";
import { sliceStr, findChar, trimStr, splitTopLevel } from "../utils/string";


// ===== Export Registry (cross-module type propagation) =====
// Lives only during checkModuleGraph execution — NOT on Module/ModuleGraph (DRC constraint).
// Reference implementation equivalent: per-module public symbol table.

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
	defaultTexts: string[];
	overloadDefaultTexts: string[][];
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

// ===== Extension Registry (extension method tracking) =====
// Tracks "function f(this self: Type)" declarations for method resolution.

export interface ExtensionMethod {
	methodName: string;
	receiverTypeName: string;
	sourcePath: string;
	fnType: Type;
	isStatic: boolean;
	sym: Symbol;
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

// findExtensionByType — find extension matching method name + fnType identity (for overload export)
export function findExtensionByType(registry: ExtensionRegistry, methodName: string, fnType: Type): ExtensionMethod {
	for (const m of registry.methods) {
		if (m.methodName === methodName && m.fnType === fnType) return m;
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

// Structured error — standard reference messages always carry line info
export interface CheckerError {
	message: string;
	line: number;    // 1-based, 0 = unknown
	column: number;  // 0-based, 0 = unknown
	fatal: boolean;  // true = globalError (abort), false = localError (continue)
}

export interface CheckerContext {
	table: SymbolTable;
	errors: CheckerError[];
	currentFunction: Symbol;   // innermost function (for return type validation)
	inLoop: boolean;           // break/continue validation
	inTestBlock: boolean;      // assert validation — only allowed inside test blocks
	moduleGraph: ModuleGraph;
	currentModule: Module;
	exportRegistry: ExportRegistry;
	extensionRegistry: ExtensionRegistry;
	inferredReturn: Type;  // tracks inferred return type during function body checking
	includeDirectives: string; // accumulated @include args, newline-separated
	compileDirectives: string; // accumulated @compile args, newline-separated
	compilerFlags: string;     // accumulated @link/@passC/@passL args, space-separated
	cancelCtx: CancelCtx;       // null in batch mode, set for LSP
	cancelVersion: number;       // version at check start
	modulePath: string;          // Implementation parity: source path for name mangling
}

// ===== Constructors =====

export function createContext(): CheckerContext {
	const table = createSymbolTable();
	return {
		table,
		errors: [],
		errorLines: [],
		errorColumns: [],
		currentFunction: null as unknown as Symbol,
		inLoop: false,
		inTestBlock: false,
		moduleGraph: null as unknown as ModuleGraph,
		currentModule: null as unknown as Module,
		exportRegistry: createExportRegistry(),
		extensionRegistry: createExtensionRegistry(),
		inferredReturn: unknownType(),
		includeDirectives: "",
		compileDirectives: "",
		compilerFlags: "",
		cancelCtx: null as unknown as CancelCtx,
		cancelVersion: 0,
		hasFatalError: false,
		modulePath: "",
	};
}

export function createModuleContext(graph: ModuleGraph, mod: Module): CheckerContext {
	const ctx = createContext();
	ctx.moduleGraph = graph;
	ctx.currentModule = mod;
	ctx.modulePath = mod.path;
	return ctx;
}

// ===== Error Collection =====

// localError — non-fatal, compilation continues
export function addError(ctx: CheckerContext, msg: string, line: number, col: number): void {
	ctx.errors.push({ message: msg, line, column: col, fatal: false });
}

// globalError — fatal, compilation should abort
export function addFatalError(ctx: CheckerContext, msg: string, line: number, col: number): void {
	ctx.errors.push({ message: msg, line, column: col, fatal: true });
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
	return ctx.errors.length;
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
	const info: ExportedSymInfo = { name: "foo", kind: SymbolKind.Function, symType: unknownType(), overloadTypes: [], extReceiverType: "", extIsStatic: false, overloadExtReceiverTypes: [], overloadExtIsStatic: [], nativeName: "", builtinKind: "", overloadNativeNames: [], overloadBuiltinKinds: [], defaultTexts: [], overloadDefaultTexts: [] };
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
	const info: ExportedSymInfo = { name: "foo", kind: SymbolKind.Function, symType: unknownType(), overloadTypes: [], extReceiverType: "", extIsStatic: false, overloadExtReceiverTypes: [], overloadExtIsStatic: [], nativeName: "", builtinKind: "", overloadNativeNames: [], overloadBuiltinKinds: [], defaultTexts: [], overloadDefaultTexts: [] };
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

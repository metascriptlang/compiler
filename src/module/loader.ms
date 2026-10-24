// Module Loader — recursive module loading with cycle detection
//
// Loads modules depth-first, building a ModuleGraph with topological loadOrder.
// Uses SourceProvider abstraction for testability (MapProvider for tests,
// FileProvider for real I/O).
//
// Supports backend-aware resolution via ResolverConfig:
//   - Backend-specific extensions (.cms, .jms, .rms, .ems, .wms)
//   - std/ library resolution against configurable stdPath
//   - Multiple search paths for bare imports
//   - Path alias rewriting
//
// NOTE: ASTs are NOT stored on Module (DRC lifecycle mangling bug prevents
// storing Node on interfaces defined outside ast/node.ms). The loader parses
// temporarily to extract import declarations, then discards the AST.
// The checker re-parses Module.source for each pass.

import {
	Module, ModuleGraph, ModuleState, createModuleGraph, createModule, createImportEntry,
	findModule, hasModule, addModule, pushImportStack, popImportStack, createModuleError, ModuleError, ErrorSeverity,
} from "./graph";
import {
	resolveImport,
	resolveImportWithConfig,
	isStdImport,
	ResolverConfig,
	Backend,
	createDefaultConfig,
} from "./resolver";
import { lex } from "../lexer/lexer";
import { createState, getParserDefines, setParserDefines } from "../parser/context";
import { definedValue, createDefineTable, initDefines } from "../compiler/defines";
import { callStateProgramParser } from "../parser/statements/callbacks";
import "../parser/statements/core";
import { Node, NodeKind, ProgramData, ImportDeclData, ExportDeclData, CallExprData, IdentifierData, StringLiteralData } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { readFile, writeFile, ensureDir, realpath, readDir } from "std/fs";
import { translateHeaderModule, HeaderTranslation, registerCompleteStruct, completeStructKey, registerHeaderIncludes } from "./cimport/emit";
import { Diagnostic, DiagSeverity } from "./cparse/error";
import { TargetInfo, targetFor, hostTarget } from "./cparse/target";
import { resolveRuntimeDir } from "../utils/path";
import { isAbsolute, dirname, join, normalize } from "std/fs/path";
import { cwd, env, platform } from "std/process";
import { djb2, fingerprint, hashToHex } from "std/hash";
// (utils/string imports removed — using native .slice)

// ===== Source Provider =====

export interface MapEntry {
	entryPath: string;
	entrySource: string;
}

// Custom read function for Trans-Am integration. When set, bypasses entries/useFileSystem
// and uses the callback (which can record deps in the caller's query frame).
type TaReadFn = (path: string) => string;

export class SourceProvider {
	entries: MapEntry[];
	useFileSystem: boolean;
	taReadFn: TaReadFn;  // null for map/filesystem providers; non-null for Trans-Am-backed
	readLog: string[] | null;   // set per-call by the header-inline cache wrapper to record every probe as "<path>\t<hash>" / "<path>\t-"
}

export function createMapProvider(entries: MapEntry[]): SourceProvider {
	return { entries, useFileSystem: false, taReadFn: null as unknown as TaReadFn, readLog: null };
}

export function createFileSystemProvider(): SourceProvider {
	return { entries: [], useFileSystem: true, taReadFn: null as unknown as TaReadFn, readLog: null };
}

// Trans-Am-backed provider. The callback MUST load the file into Trans-Am, record a
// FileText dependency on the current query frame, and return the raw source string.
// Constructed by transam/index.ms:createTaSourceProvider.
export function createTaReadProvider(readFn: TaReadFn): SourceProvider {
	return { entries: [], useFileSystem: false, taReadFn: readFn, readLog: null };
}

export function provideSource(provider: SourceProvider, path: string): Result<string, string> {
	if (provider.taReadFn != null) {
		const content = provider.taReadFn(path);
		if (content.length > 0) return Result.ok(content);
		return Result.err(`File not found: ${path}`);
	}
	for (const e of provider.entries) {
		if (e.entryPath == path) {
			if (provider.readLog != null) provider.readLog.push(`${path}\t${headerDepHash(e.entrySource)}`);
			return Result.ok(e.entrySource);
		}
	}
	if (provider.useFileSystem) {
		const content = try readFile(path) catch "";
		if (content.length > 0) {
			if (provider.readLog != null) provider.readLog.push(`${path}\t${headerDepHash(content)}`);
			const cached: MapEntry = { entryPath: path, entrySource: content };
			provider.entries.push(cached);
			return Result.ok(content);
		}
	}
	if (provider.readLog != null) provider.readLog.push(`${path}\t-`);
	return Result.err(`File not found: ${path}`);
}

// ===== C Header Modules =====
//
// A `.h` path loads as a module whose source is the translation of the declarations its own
// file writes (cimport translateHeaderModule): each C declaration is one declaration however
// many modules and headers reach it. Build-perf §1.2: how much of the loader half is header
// translation; read by graphLoadTiming.
let _headerMs: float64 = 0;
let _headerN: int32 = 0;
let _headerHits: int32 = 0;
export interface HeaderTimings {
	ms: float64;
	n: int32;
	hits: int32;
}
export function takeHeaderTimings(): HeaderTimings {
	const r: HeaderTimings = { ms: _headerMs, n: _headerN, hits: _headerHits };
	_headerMs = 0;
	_headerN = 0;
	_headerHits = 0;
	return r;
}

// ===== Header Disk Cache (build-perf Phase A0) =====
//
// Cache mechanics live in compiler/cache.ms (Layer 5) — loader.ms cannot
// import that module (checker/context → module/graph would make the module
// layer depend on the checker), so the implementations are injected at
// compile.ms module load, the same cycle-breaker pattern as
// parser/statements/callbacks.ms.

type HeaderCacheKeyFn = (source: string, headerPath: string, target: string) => string;
type HeaderCacheLookupFn = (key: string) => string;
type HeaderCacheStoreFn = (key: string, deps: string[], output: string) => void;

let _hcKeyFn: HeaderCacheKeyFn = null as unknown as HeaderCacheKeyFn;
let _hcLookupFn: HeaderCacheLookupFn = null as unknown as HeaderCacheLookupFn;
let _hcStoreFn: HeaderCacheStoreFn = null as unknown as HeaderCacheStoreFn;

export function registerHeaderCache(keyFn: HeaderCacheKeyFn, lookupFn: HeaderCacheLookupFn, storeFn: HeaderCacheStoreFn): void {
	_hcKeyFn = keyFn;
	_hcLookupFn = lookupFn;
	_hcStoreFn = storeFn;
}

// Same dual-hash as compiler/cache.ms hashContent — dep lines are keyed by it.
function headerDepHash(s: string): string {
	return `${hashToHex(djb2(s))}_${hashToHex(fingerprint(s))}`;
}

// "" when the disk cache does not apply: cache unregistered, MSC_NO_HEADER_CACHE=1, or a
// provider whose entries may not mirror disk (Trans-Am, map providers).
function headerCacheKey(source: string, headerPath: string, search: string[], provider: SourceProvider): string {
	if (_hcLookupFn == null) return "";
	if (provider.taReadFn != null || !provider.useFileSystem) return "";
	if (env.get("MSC_NO_HEADER_CACHE") != "") return "";
	const t = headerTarget();
	return _hcKeyFn(source, headerPath, `${t != null ? `${t.os}-${t.cpu}` : ""}\t${search.join("\t")}`);
}

export function headerTarget(): TargetInfo {
	const defs = getParserDefines();
	const os = definedValue(defs, "os");
	const cpu = definedValue(defs, "cpu");
	return os != "" && cpu != "" ? targetFor(os, cpu) : hostTarget();
}

function builtinIncludeDir(): string {
	const root = resolveRuntimeDir();
	return root != "" ? root + "/src/module/cparse/include" : "src/module/cparse/include";
}

// The real header goes to the C compiler with its companion `.c`; a builtin stub only stands
// in for a system header while cparse reads, so the C compiler never sees it.
function headerDirectives(path: string, provider: SourceProvider): string {
	if (path.startsWith(canonicalModulePath(builtinIncludeDir()) + "/")) return "";
	const companion = path.slice(0, path.length - 2) + ".c";
	const compile = provideSource(provider, companion).ok ? `@compile("${companion}");\n` : "";
	return `@include("${path}");\n${compile}`;
}

// A header another header includes is read with the search paths of the header that included it
// as well as its own, as one C translation unit reads every header it includes.
const _inheritedSearch = new HashMap<string, string[]>();

function headerSearchPaths(path: string): string[] {
	const headerDir = dirname(path);
	const root = resolveRuntimeDir();
	const search = root != ""
		? [builtinIncludeDir(), root, headerDir, dirname(headerDir)]
		: [builtinIncludeDir(), headerDir, dirname(headerDir)];
	for (const p of _inheritedSearch.get(path) ?? []) {
		if (!search.includes(p)) search.push(p);
	}
	return search;
}

// The module source of the header at `path` (canonical). `graph`, when given, holds what each
// header's declarations looked like to the first header that read it.
export function headerModuleSource(path: string, provider: SourceProvider, graph: ModuleGraph | null, outErrors: ModuleError[]): string {
	const t0 = performance.now();
	_headerN = _headerN + 1;
	const raw = provideSource(provider, path);
	if (!raw.ok) {
		outErrors.push(createModuleError(`cannot read C header '${path}'`, 0, 0, ErrorSeverity.Error));
		return "";
	}
	const target = headerTarget();
	if (target == null) {
		outErrors.push(createModuleError(`C header '${path}': no C target model for --os=${definedValue(getParserDefines(), "os")} --cpu=${definedValue(getParserDefines(), "cpu")}`, 0, 0, ErrorSeverity.Error));
		return "";
	}
	const search = headerSearchPaths(path);
	const key = headerCacheKey(raw.value, path, search, provider);
	let entry = key != "" ? _hcLookupFn(key) : "";
	if (entry != "") {
		_headerHits = _headerHits + 1;
	} else {
		const prevLog = provider.readLog;
		const probes: string[] = [];
		if (key != "") provider.readLog = probes;
		const diags: Diagnostic[] = [];
		const reads: string[] = [];
		const completeKeys: string[] = [];
		const translated = translateHeaderModule(raw.value, path, search, diags, reads, target, completeKeys, canonicalModulePath);
		entry = packHeaderEntry(completeKeys, translated, headerDirectives(path, provider) + translated.source);
		provider.readLog = prevLog;
		for (const d of diags) {
			const sev = d.severity == DiagSeverity.Error ? ErrorSeverity.Error : ErrorSeverity.Warning;
			outErrors.push(createModuleError(`C header ${d.file}:${d.line}:${d.col}: ${d.message}`, 0, 0, sev));
		}
		// A run that surfaced diagnostics recomputes next time so they surface again.
		if (key != "" && diags.length == 0) {
			const deps: string[] = [];
			const seen = new HashSet<string>();
			for (const d of probes.concat(reads)) {
				if (!seen.has(d)) { seen.add(d); deps.push(d); }
			}
			_hcStoreFn(key, deps, entry);
		}
	}
	const source = unpackHeaderEntry(entry, path, search, graph, outErrors);
	_headerMs = _headerMs + (performance.now() - t0);
	return source;
}

// Entry: the complete-struct keys, the own shape hash, one "<file>\t<hash>" line per included
// file, then the module source.
function packHeaderEntry(keys: string[], t: HeaderTranslation, source: string): string {
	let packed = `${keys.length}\n`;
	for (const k of keys) packed = packed + k + "\n";
	packed = packed + headerDepHash(t.ownShape) + "\n" + `${t.includedShapes.size}\n`;
	for (const [file, shape] of t.includedShapes) packed = packed + `${file}\t${headerDepHash(shape)}\n`;
	return packed + source;
}

function unpackHeaderEntry(entry: string, path: string, search: string[], graph: ModuleGraph | null, outErrors: ModuleError[]): string {
	const lines = entry.split("\n");
	let at = 0;
	const keyCount = lines[at].parseInt();
	at = at + 1;
	for (let i = 0; i < keyCount; i += 1) {
		registerCompleteStruct(lines[at]);
		at = at + 1;
	}
	if (graph != null) recordHeaderShape(graph, path, lines[at], path, outErrors);
	at = at + 1;
	const shapeCount = lines[at].parseInt();
	at = at + 1;
	const included: string[] = [];
	for (let i = 0; i < shapeCount; i += 1) {
		const tab = lines[at].indexOf("\t");
		included.push(lines[at].slice(0, tab));
		if (graph != null) recordHeaderShape(graph, lines[at].slice(0, tab), lines[at].slice(tab + 1, lines[at].length), path, outErrors);
		at = at + 1;
	}
	registerHeaderIncludes(path, included);
	for (const file of included) {
		if (!_inheritedSearch.has(file)) _inheritedSearch.set(file, search);
	}
	return lines.slice(at, lines.length).join("\n");
}

// A header whose declarations differ between two readers (a macro an includer defines before
// its #include) would be two different declarations under one name.
function recordHeaderShape(graph: ModuleGraph, file: string, hash: string, reader: string, outErrors: ModuleError[]): void {
	const seen = graph.headerShapes.get(file);
	if (seen == null) {
		graph.headerShapes.set(file, `${hash}\t${reader}`);
		return;
	}
	const tab = seen.indexOf("\t");
	if (seen.slice(0, tab) == hash) return;
	outErrors.push(createModuleError(`C header '${file}' declares something different when read from '${reader}' than from '${seen.slice(tab + 1, seen.length)}': a macro defined before its #include changes it`, 0, 0, ErrorSeverity.Error));
}

export function isCHeaderPath(path: string): boolean {
	if (path.length < 3) return false;
	return path.slice(path.length - 2, path.length) == ".h";
}

// ===== Module Loading =====

function finalizeModule(graph: ModuleGraph, mod: Module, path: string): void {
	popImportStack(graph);
	mod.state = ModuleState.Ready;
	graph.loadOrder.push(path);
}

// Helper: create module, add to graph, push import stack.
// Isolates Module* from caller's DRC scope (avoids premature msDecref).
function createAndAddModule(graph: ModuleGraph, path: string): void {
	const mod = createModule(path);
	mod.state = ModuleState.Loading;
	addModule(graph, mod);
	pushImportStack(graph, path);
}

// Load .ms source module — DRC-isolated (mod stays in this scope)
function loadSourceModule(graph: ModuleGraph, path: string, provider: SourceProvider, config: ResolverConfig, useConfig: int32): boolean {
	const mod = createModule(path);
	mod.state = ModuleState.Loading;
	addModule(graph, mod);
	pushImportStack(graph, path);

	if (isCHeaderPath(path)) {
		const headerErrors: ModuleError[] = [];
		mod.rawSource = headerModuleSource(path, provider, graph, headerErrors);
		for (const he of headerErrors) mod.errors.push(he);
	} else {
		const sourceResult = provideSource(provider, path);
		if (!sourceResult.ok) {
			mod.errors.push(createModuleError(sourceResult.error, 0, 0, ErrorSeverity.Error));
			finalizeModule(graph, mod, path);
			return false;
		}
		mod.rawSource = sourceResult.value;
	}
	mod.source = mod.rawSource;

	// Parse with recovery — always get partial AST, errors in state.errors
	const lr = lex(mod.source);
	if (!lr.ok) {
		mod.errors.push(createModuleError(`Lex: ${lr.error}`, 0, 0, ErrorSeverity.Error));
		finalizeModule(graph, mod, path);
		return false;
	}
	const parseState = createState(lr.value);
	const parseResult = callStateProgramParser(parseState);
	for (const parseErr of parseState.errors) {
		mod.errors.push(createModuleError(`Parse: ${parseErr}`, 0, 0, ErrorSeverity.Error));
	}
	// NOTE: keep state as Loading until imports are processed — cycle detection
	// in loadModule checks for Loading state to detect circular imports.

	// Walk AST for import declarations (works on partial ASTs)
	if (!parseResult.ok) {
		mod.errors.push(createModuleError(`Parse: ${parseResult.error}`, 0, 0, ErrorSeverity.Error));
		finalizeModule(graph, mod, path);
		return false;
	}
	const program = parseResult.value;
	const pd = program.data as ProgramData;
	for (const stmt of pd.programStmts) {
		if (stmt.kind == NodeKind.ImportDecl) {
			processImportDecl(graph, mod, stmt, provider, config, useConfig);
		} else if (stmt.kind == NodeKind.ExportDecl) {
			// Re-export: export { ... } from "./module" wraps ImportDecl in ExportDecl
			const ed = stmt.data as ExportDeclData;
			if (ed.exportedDecl != null && ed.exportedDecl.kind == NodeKind.ImportDecl) {
				processImportDecl(graph, mod, ed.exportedDecl, provider, config, useConfig);
			}
		}
	}
	if (parseState.sawImportCall) {
		for (const specifier of collectImportCalls(program)) processImport(graph, mod, specifier, [], [], 0, true, provider, config, useConfig);
	}

	// Done loading — mark ready, add to topological order
	finalizeModule(graph, mod, path);
	return true;
}

// Canonicalize a module path: relative paths get joined with cwd so the
// graph keys every file by its absolute path. Without this, a file resolved
// via different code paths (e.g. entry passed as `src/index.ms` vs prelude
// loaded via absolute stdPath) gets two distinct graph entries → two .o
// files emitted with overlapping global symbols → linker duplicate-symbol
// error. Map-provider test paths like `/src/a.ms` already absolute → pass
// through unchanged.
export function canonicalModulePath(path: string): string {
	const spelled = isAbsolute(path) ? normalize(path) : normalize(join(cwd(), path));
	const physical = realpath(spelled);
	return physical != "" ? normalize(physical) : spelled;
}

test "canonicalModulePath — two spellings of one directory share an identity" {
	if (platform == "darwin") assert canonicalModulePath("/tmp") == canonicalModulePath("/private/tmp");
	assert canonicalModulePath("/src/a.ms") == "/src/a.ms";
	assert canonicalModulePath("a/../b/c.ms") == normalize(join(cwd(), "b/c.ms"));
}

function canonicalizeStdModule(path: string, stdPath: string, provider: SourceProvider): string {
	if (stdPath.length == 0) return path;
	let dir = dirname(path);
	let stepsUp = 0;
	while (dir.length > 1 && stepsUp < 6) {
		const marker = join(dir, "std/core/system/index.ms");
		if (provideSource(provider, marker).ok) {
			const prefix = join(dir, "std") + "/";
			if (path.length > prefix.length && path.slice(0, prefix.length) == prefix) {
				const subpath = path.slice(prefix.length, path.length);
				const candidate = join(stdPath, subpath);
				if (provideSource(provider, candidate).ok) return candidate;
			}
			return path;
		}
		const parent = dirname(dir);
		if (parent == dir) return path;
		dir = parent;
		stepsUp = stepsUp + 1;
	}
	return path;
}

// useConfig: 0 = bare (skip std, .ms only), 1 = full (use ResolverConfig)
export function moduleIdentity(path: string, config: ResolverConfig, provider: SourceProvider): string {
	return canonicalizeStdModule(canonicalModulePath(path), config.stdPath, provider);
}

export function loadModule(graph: ModuleGraph, path: string, provider: SourceProvider, config: ResolverConfig, useConfig: int32): Result<boolean, string> {
	path = moduleIdentity(path, config, provider);
	// Already in graph — check if still loading (circular import)
	if (hasModule(graph, path)) {
		const existing = findModule(graph, path);
		if (existing != null) {
			if (existing.state == ModuleState.Loading) {
				// Implementation parity: record cycle info
				// Extract cycle path from importStack
				const cycle: string[] = [];
				let inCycle = false;
				for (const sp of graph.importStack) {
					if (sp == path) inCycle = true;
					if (inCycle) cycle.push(sp);
				}
				cycle.push(path); // close the cycle
				const fromPath = graph.importStack.length > 0
					? graph.importStack[graph.importStack.length - 1]
					: path;
				graph.circularDeps.push({ fromPath, toPath: path, cycle, importLine: 0, importNames: [] });
				// Not a hard error — two-phase checking handles circular deps gracefully
			}
		}
		return Result.ok(true);
	}

	// Regular source module
	const loaded = loadSourceModule(graph, path, provider, config, useConfig);
	return Result.ok(loaded);
}

// ===== Import Processing =====

function processImportDecl(graph: ModuleGraph, mod: Module, node: Node, provider: SourceProvider, config: ResolverConfig, useConfig: int32): void {
	const d = node.data as ImportDeclData;
	processImport(graph, mod, d.importSource, d.importNames, d.importAliases, node.location != null ? node.location.line : 0, false, provider, config, useConfig);
}

export function collectImportCalls(program: Node): string[] {
	const specifiers: string[] = [];
	const visit = (n: Node): void => {
		if (n.kind == NodeKind.CallExpr) {
			const d = n.data as CallExprData;
			if (isImportKeyword(d.callee) && d.arguments.length > 0 && d.arguments[0].kind == NodeKind.StringLiteral) {
				const specifier = (d.arguments[0].data as StringLiteralData).value;
				if (specifiers.indexOf(specifier) < 0) specifiers.push(specifier);
			}
		}
		forEachChild(n, visit);
	};
	visit(program);
	return specifiers;
}

export function isImportKeyword(callee: Node): boolean {
	return callee.kind == NodeKind.Identifier && (callee.data as IdentifierData).name == "import";
}

function processImport(graph: ModuleGraph, mod: Module, specifier: string, importNames: string[], importAliases: string[], line: int32, dynamic: boolean, provider: SourceProvider, config: ResolverConfig, useConfig: int32): void {

	if (useConfig == 0) {
		// Bare mode: skip std, resolve .ms only
		if (isStdImport(specifier)) return;

		const candidates = resolveImport(specifier, mod.path);
		let resolved = "";
		for (const candidate of candidates) {
			if (resolved == "") {
				const trySource = provideSource(provider, candidate);
				if (trySource.ok) {
					resolved = candidate;
				}
			}
		}

		if (resolved == "") {
			mod.errors.push(createModuleError(`Cannot resolve module '${specifier}'`, 0, 0, ErrorSeverity.Error));
			return;
		}
		resolved = moduleIdentity(resolved, config, provider);

		const entry = createImportEntry(importNames, importAliases, resolved, specifier, dynamic);
		mod.imports.push(entry);
		const preCircCount = graph.circularDeps.length;
		const _loadResult = loadModule(graph, resolved, provider, config, 0);
		// Enrich circular dep with import site info if a new cycle was just detected
		if (graph.circularDeps.length > preCircCount) {
			const lastDep = graph.circularDeps[graph.circularDeps.length - 1];
			lastDep.importLine = line;
			lastDep.importNames = importNames;
		}
	} else {
		// Config-aware mode: resolve all imports including std/
		const candidates = resolveImportWithConfig(specifier, mod.path, config);

		let resolved = "";
		for (const candidate of candidates) {
			if (resolved == "") {
				const trySource = provideSource(provider, candidate);
				if (trySource.ok) {
					resolved = candidate;
				}
			}
		}

		if (resolved == "") {
			// std/ with empty stdPath: silently skip (handled externally)
			if (isStdImport(specifier) && config.stdPath.length == 0) return;
			mod.errors.push(createModuleError(`Cannot resolve module '${specifier}'`, 0, 0, ErrorSeverity.Error));
			return;
		}
		resolved = moduleIdentity(resolved, config, provider);

		const entry = createImportEntry(importNames, importAliases, resolved, specifier, dynamic);
		mod.imports.push(entry);
		const preCircCount2 = graph.circularDeps.length;
		const _loadResult = loadModule(graph, resolved, provider, config, 1);
		if (graph.circularDeps.length > preCircCount2) {
			const lastDep2 = graph.circularDeps[graph.circularDeps.length - 1];
			lastDep2.importLine = line;
			lastDep2.importNames = importNames;
		}
	}
}

// ===== Convenience: Load from entry point =====

// Config-aware graph loading
export function loadModuleGraphWithConfig(entryPath: string, provider: SourceProvider, config: ResolverConfig): ModuleGraph {
	const graph = createModuleGraph();
	const _r = loadModule(graph, entryPath, provider, config, 1);
	return graph;
}

// Bare mode (no config) — skips std/, resolves .ms only
export function loadModuleGraph(entryPath: string, provider: SourceProvider): ModuleGraph {
	const graph = createModuleGraph();
	// Dummy config — not used in bare mode (useConfig=0)
	const dummyExts: string[] = [];
	const dummyCfg: ResolverConfig = { backend: Backend.C, stdPath: "", searchPaths: [], extensions: dummyExts, aliasKeys: [], aliasValues: [] };
	const _r = loadModule(graph, entryPath, provider, dummyCfg, 0);
	return graph;
}

// ===== Tests =====

function makeEntry(path: string, source: string): MapEntry {
	return { entryPath: path, entrySource: source };
}

test "single file graph" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/a.ms", "const x = 1;"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	assert graph.modules.length == 1;
	assert graph.loadOrder.length == 1;
	assert graph.loadOrder[0] == "/src/a.ms";
	const mod = findModule(graph, "/src/a.ms");
	assert mod != null;
	assert mod.state == ModuleState.Ready;
	assert mod.source == "const x = 1;";
}

test "a C header's diagnostics are its module's errors" {
	const errs: ModuleError[] = [];
	const source = headerModuleSource("/tmp/msdiagtest/bad.h", createMapProvider([makeEntry("/tmp/msdiagtest/bad.h", "#include <nope/nada.h>\nint diagOk(void);\n")]), null, errs);
	assert source.indexOf("export extern function diagOk") >= 0;
	assert errs.length > 0;
	assert errs[0].message.indexOf("nada.h") >= 0;
	assert errs[0].message.indexOf("file not found") >= 0;
}

test "an unreadable C header is an error of the module that imports it" {
	const graph = loadModuleGraph("/tmp/msmissing/main.ms", createMapProvider([makeEntry("/tmp/msmissing/main.ms", "import { ghost } from " + "\"./missing.h\";\n")]));
	const main = findModule(graph, "/tmp/msmissing/main.ms");
	assert main != null && main.errors.length == 1;
	assert main.errors[0].severity == ErrorSeverity.Error;
	assert main.errors[0].message.indexOf("missing.h") >= 0;
}

test "a bare C header specifier resolves beside the importing module" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/tmp/msbarespec/lib/api.h", "int bareOk(void);\n"));
	entries.push(makeEntry("/tmp/msbarespec/main.ms", "import { bareOk } from " + "\"lib/api.h\";\n"));
	const graph = loadModuleGraph("/tmp/msbarespec/main.ms", createMapProvider(entries));
	const header = findModule(graph, "/tmp/msbarespec/lib/api.h");
	assert header != null && header.source.indexOf("export extern function bareOk") >= 0;
}

test "a C header imported by two modules under two spellings is one module" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/tmp/msoneheader/foo.h", "typedef struct { int a; } Pair;\n"));
	entries.push(makeEntry("/tmp/msoneheader/main.ms", "import { Pair } from " + "\"./foo.h\";\nimport { x } from \"./sub/b\";\n"));
	entries.push(makeEntry("/tmp/msoneheader/sub/b.ms", "import { Pair } from " + "\"../foo.h\";\nexport const x = 1;\n"));
	const graph = loadModuleGraph("/tmp/msoneheader/main.ms", createMapProvider(entries));
	assert graph.modules.length == 3;
	const header = findModule(graph, "/tmp/msoneheader/foo.h");
	assert header != null && header.source.indexOf("@include(\"/tmp/msoneheader/foo.h\");") == 0;
}

test "a header two includers read differently is an error" {
	ensureDir("/tmp/msshape");
	writeFile("/tmp/msshape/cfg.h", "#ifndef CFG_H\n#define CFG_H\n#ifdef WIDE\ntypedef long N;\n#else\ntypedef int N;\n#endif\n#endif\n");
	writeFile("/tmp/msshape/wide.h", "#define WIDE\n#include \"cfg.h\"\nN wide(void);\n");
	writeFile("/tmp/msshape/main.ms", "import { N } from " + "\"./cfg.h\";\nimport { wide } from \"./wide.h\";\n");
	const dir = canonicalModulePath("/tmp/msshape");
	const graph = loadModuleGraph(dir + "/main.ms", createFileSystemProvider());
	const wide = findModule(graph, dir + "/wide.h");
	const cfg = findModule(graph, dir + "/cfg.h");
	assert wide != null && cfg != null;
	const all = wide.errors.concat(cfg.errors);
	assert all.length == 1, `${all.length}`;
	assert all[0].message.indexOf(`C header '${dir}/cfg.h' declares something different`) == 0, all[0].message;
}

test "a header another header includes is read with the search paths of its includer" {
	ensureDir("/tmp/mssearch/include/lib/sub");
	writeFile("/tmp/mssearch/include/lib/types.h", "#ifndef LT_H\n#define LT_H\ntypedef int Handle;\n#endif\n");
	writeFile("/tmp/mssearch/include/lib/sub/use.h", "#ifndef LU_H\n#define LU_H\n#include <lib/types.h>\nHandle useHandle(void);\n#endif\n");
	writeFile("/tmp/mssearch/include/lib/top.h", "#include <lib/types.h>\n#include <lib/sub/use.h>\n");
	writeFile("/tmp/mssearch/main.ms", "import { useHandle } from " + "\"./include/lib/top.h\";\n");
	const dir = canonicalModulePath("/tmp/mssearch");
	const graph = loadModuleGraph(dir + "/main.ms", createFileSystemProvider());
	const use = findModule(graph, dir + "/include/lib/sub/use.h");
	assert use != null && use.errors.length == 0, use != null ? use.errors[0].message : "use.h not loaded";
	assert use.source.indexOf("export extern function useHandle(): Handle;") >= 0, use.source;
}

function platHeaderFor(os: string, cpu: string, errs: ModuleError[]): string {
	const header = "#if defined(_WIN32)\nint platWin(void);\n#elif defined(__APPLE__)\nint platApple(void);\n#else\nint platOther(void);\n#endif\n";
	return headerFor(os, cpu, header, errs);
}

function headerFor(os: string, cpu: string, header: string, errs: ModuleError[]): string {
	const saved = getParserDefines();
	const defs = createDefineTable();
	initDefines(defs, "c", os, cpu, "drc", 0);
	setParserDefines(defs);
	try {
		return headerModuleSource("/tmp/mstarget/plat.h", createMapProvider([makeEntry("/tmp/mstarget/plat.h", header)]), null, errs);
	} finally {
		setParserDefines(saved);
	}
}

test "a C header takes the _WIN32 branch for a windows build" {
	const source = platHeaderFor("windows", "amd64", []);
	assert source.indexOf("extern function platWin") >= 0;
	assert source.indexOf("extern function platApple") < 0;
	assert source.indexOf("extern function platOther") < 0;
}

test "a C header takes neither the apple nor the windows branch for a linux build" {
	const source = platHeaderFor("linux", "arm64", []);
	assert source.indexOf("extern function platOther") >= 0;
	assert source.indexOf("extern function platApple") < 0;
	assert source.indexOf("extern function platWin") < 0;
}

test "a C header takes the __APPLE__ branch for a macos build" {
	const source = platHeaderFor("macos", "arm64", []);
	assert source.indexOf("extern function platApple") >= 0;
	assert source.indexOf("extern function platOther") < 0;
}

test "a C header reads a windows export macro that expands to __declspec" {
	const header = "#if defined(_WIN32)\n#define LIB_API __declspec(dllimport)\n#else\n#define LIB_API\n#endif\nLIB_API int addOne(int x);\n";
	const errs: ModuleError[] = [];
	const source = headerFor("windows", "amd64", header, errs);
	assert errs.length == 0;
	assert source.indexOf("extern function addOne") >= 0;
}

test "a C header reports a build target with no C model instead of guessing one" {
	const errs: ModuleError[] = [];
	const source = platHeaderFor("linux", "vax", errs);
	assert source.indexOf("extern function") < 0;
	assert errs.length == 1;
	assert errs[0].severity == ErrorSeverity.Error;
	assert errs[0].message.indexOf("--cpu=vax") >= 0;
}

function collectStdHeaderImports(dir: string, found: string[], scanned: int32[]): void {
	const fromQuote = "fr" + "om \"";
	const headerQuote = ".h" + "\"";
	for (const entry of readDir(dir)) {
		if (entry.endsWith("/")) {
			collectStdHeaderImports(dir + "/" + entry.slice(0, entry.length - 1), found, scanned);
			continue;
		}
		if (!(entry.endsWith(".ms") || entry.endsWith(".cms") || entry.endsWith(".jms") || entry.endsWith(".rms") || entry.endsWith(".wms"))) continue;
		scanned[0] = scanned[0] + 1;
		const src = try readFile(dir + "/" + entry) catch "";
		for (const line of src.split("\n")) {
			if (line.indexOf(fromQuote) >= 0 && line.indexOf(headerQuote) >= 0) found.push(`${dir}/${entry}: ${line}`);
		}
	}
}

test "no std module binds C by importing a header" {
	const root = resolveRuntimeDir();
	assert root != "";
	const found: string[] = [];
	const scanned: int32[] = [0];
	collectStdHeaderImports(root + "/std", found, scanned);
	assert scanned[0] > 100;
	assert found.length == 0;
}

test "A imports B chain" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/a.ms", "import { foo } from \"./b\";"));
	entries.push(makeEntry("/src/b.ms", "export function foo() { return 1; }"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	assert graph.modules.length == 2;
	// Topological: B before A (dependency loaded first)
	assert graph.loadOrder[0] == "/src/b.ms";
	assert graph.loadOrder[1] == "/src/a.ms";
	// A has import entry pointing to B
	const modA = findModule(graph, "/src/a.ms");
	assert modA != null;
	assert modA.imports.length == 1;
	assert modA.imports[0].sourcePath == "/src/b.ms";
}

test "circular import handled" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/a.ms", "import { b } from \"./b\";"));
	entries.push(makeEntry("/src/b.ms", "import { a } from \"./a\";"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	// Both modules loaded (circular doesn't crash)
	assert graph.modules.length == 2;
	// Both end up in Ready state
	const modA = findModule(graph, "/src/a.ms");
	const modB = findModule(graph, "/src/b.ms");
	assert modA != null;
	assert modB != null;
	assert modA.state == ModuleState.Ready;
	assert modB.state == ModuleState.Ready;
}

test "diamond dependency" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/a.ms", "import { b } from \"./b\"; import { c } from \"./c\";"));
	entries.push(makeEntry("/src/b.ms", "import { d } from \"./d\"; export const b = 1;"));
	entries.push(makeEntry("/src/c.ms", "import { d } from \"./d\"; export const c = 2;"));
	entries.push(makeEntry("/src/d.ms", "export const d = 3;"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	assert graph.modules.length == 4;
	// D should be loaded once (not duplicated)
	assert graph.loadOrder[0] == "/src/d.ms";
	assert graph.errors.length == 0;
}

test "missing module error" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/a.ms", "import { x } from \"./missing\";"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	const mod = findModule(graph, "/src/a.ms");
	assert mod != null;
	assert mod.errors.length > 0;
}

test "std import skipped" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/a.ms", "import { test } from \"std/testing\"; const x = 1;"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	assert graph.modules.length == 1;
	const mod = findModule(graph, "/src/a.ms");
	assert mod != null;
	assert mod.imports.length == 0;
}

test "no duplicate loading" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/a.ms", "import { x } from \"./b\"; import { y } from \"./b\";"));
	entries.push(makeEntry("/src/b.ms", "export const x = 1; export const y = 2;"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	assert graph.modules.length == 2;
}

test "an absolute import with an explicit extension loads the module it names" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry(
		"/src/a.ms",
		"import { x } from \"/vendor/m.ms\"; import { y } from \"/vendor/pkg/index.ms\";",
	));
	entries.push(makeEntry("/vendor/m.ms", "export const x = 1;"));
	entries.push(makeEntry("/vendor/pkg/index.ms", "export const y = 2;"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraphWithConfig("/src/a.ms", provider, createDefaultConfig(Backend.C, ""));
	assert graph.modules.length == 3;
	const mod = findModule(graph, "/src/a.ms");
	assert mod != null;
	assert mod.errors.length == 0;
	assert mod.imports[0].sourcePath == "/vendor/m.ms";
	assert mod.imports[1].sourcePath == "/vendor/pkg/index.ms";
}

function importsHeaderModule(appSource: string): boolean {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/app.ms", appSource));
	entries.push(makeEntry("/src/lib.h", "void foo(int x);"));
	const graph = loadModuleGraph("/src/app.ms", createMapProvider(entries));
	const app = findModule(graph, "/src/app.ms");
	const lib = findModule(graph, "/src/lib.h");
	return graph.errors.length == 0 && app != null && app.source == appSource && app.imports.length == 1
		&& app.imports[0].sourcePath == "/src/lib.h" && lib != null && lib.source.indexOf("export extern function foo") >= 0;
}

test "a C header imported in single quotes is a module" {
	assert importsHeaderModule("import { foo } from './lib.h';");
}

test "a C header imported with spaces and a tab before the specifier is a module" {
	assert importsHeaderModule("import { foo } from  \t\"./lib.h\";");
}

test "a module that imports a C header keeps its own source" {
	assert importsHeaderModule("// é — 👍 日本\nimport { foo } from \"./lib.h\";\nconst x = foo;");
}

test "parse error recorded" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/a.ms", "const x = ;"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	const mod = findModule(graph, "/src/a.ms");
	assert mod != null;
	assert mod.errors.length > 0;
	assert mod.state == ModuleState.Ready;
}

test "loadOrder is topological" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/main.ms", "import { a } from \"./a\";"));
	entries.push(makeEntry("/src/a.ms", "import { b } from \"./b\"; export const a = 1;"));
	entries.push(makeEntry("/src/b.ms", "export const b = 2;"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/main.ms", provider);
	assert graph.loadOrder[0] == "/src/b.ms";
	assert graph.loadOrder[1] == "/src/a.ms";
	assert graph.loadOrder[2] == "/src/main.ms";
}

test "module source stored" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/a.ms", "const x = 42;"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	const mod = findModule(graph, "/src/a.ms");
	assert mod != null;
	assert mod.source == "const x = 42;";
}

// ===== Header-Inline Cache Wrapper Tests =====
//
// These exercise the WRAPPER (engagement gating, hit short-circuit, dep
// harvest, store conditions) against an injected fake cache; the disk
// mechanics (entry format, dep verification, marker GC) live in
// compiler/cache.ms Layer 5 tests. Restore the null registration after each
// test so later tests in the binary run cache-neutral.

function unregisterHeaderCacheForTest(): void {
	registerHeaderCache(null as unknown as HeaderCacheKeyFn, null as unknown as HeaderCacheLookupFn, null as unknown as HeaderCacheStoreFn);
}

test "header cache wrapper: miss stores deps+output, hit short-circuits" {
	ensureDir("/tmp/mshcw");
	writeFile("/tmp/mshcw/a.h", "extern int hcwA(void);\n");
	let storedKey = "";
	let storedDeps: string[] = [];
	let storedOut = "";
	registerHeaderCache(
		(_s: string, _h: string, _t: string) => "KHCW",
		(k: string) => { return k == "KHCW" && storedOut != "" ? storedOut : ""; },
		(k: string, d: string[], o: string) => { storedKey = k; storedDeps = d; storedOut = o; }
	);
	takeHeaderTimings();
	const out1 = headerModuleSource("/tmp/mshcw/a.h", createFileSystemProvider(), null, []);
	assert storedKey == "KHCW";
	assert storedOut.endsWith("\n" + out1), storedOut;
	assert out1.indexOf("export extern function hcwA") >= 0;
	let sawCompanionProbe = false;
	for (const d of storedDeps) {
		if (d == "/tmp/mshcw/a.c\t-") sawCompanionProbe = true;
	}
	assert sawCompanionProbe, storedDeps.join(",");
	const out2 = headerModuleSource("/tmp/mshcw/a.h", createFileSystemProvider(), null, []);
	assert out2 == out1;
	const t = takeHeaderTimings();
	assert t.hits == 1;
	assert t.n == 2;
	unregisterHeaderCacheForTest();
}

test "header cache wrapper: an entry carries the complete structs of its header" {
	ensureDir("/tmp/mshcw");
	writeFile("/tmp/mshcw/s.h", "typedef struct { long size; int v; } HcwS;\n");
	let storedOut = "";
	registerHeaderCache(
		(_s: string, _h: string, _t: string) => "KHCWS",
		(k: string) => { return k == "KHCWS" && storedOut != "" ? storedOut : ""; },
		(_k: string, _d: string[], o: string) => { storedOut = o; }
	);
	const out1 = headerModuleSource("/tmp/mshcw/s.h", createFileSystemProvider(), null, []);
	const t = headerTarget();
	const key = completeStructKey(`${t.os}-${t.cpu}`, "HcwS", ["size", "v"], [t.longSize == 4 ? "int32" : "int64", "int32"]);
	assert storedOut.startsWith("1\n" + key + "\n"), storedOut;
	assert headerModuleSource("/tmp/mshcw/s.h", createFileSystemProvider(), null, []) == out1;
	unregisterHeaderCacheForTest();
}

test "header cache wrapper: diagnostics-producing runs are not stored" {
	ensureDir("/tmp/mshcw");
	writeFile("/tmp/mshcw/bad.h", "#include <nope/nada.h>\nint hcwBad(void);\n");
	let storeCalls = 0;
	registerHeaderCache(
		(_s: string, _h: string, _t: string) => "KERR",
		(_k: string) => "",
		(_k: string, _d: string[], _o: string) => { storeCalls = storeCalls + 1; }
	);
	const errs: ModuleError[] = [];
	headerModuleSource("/tmp/mshcw/bad.h", createFileSystemProvider(), null, errs);
	assert errs.length > 0;
	assert storeCalls == 0;
	unregisterHeaderCacheForTest();
}

test "header cache wrapper: map providers bypass the cache" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/virt/b.h", "extern int vB(void);\n"));
	registerHeaderCache(
		(_s: string, _h: string, _t: string) => "KMAP",
		(_k: string) => "SHOULD-NEVER-SERVE",
		(_k: string, _d: string[], _o: string) => {}
	);
	const out = headerModuleSource("/virt/b.h", createMapProvider(entries), null, []);
	assert out.indexOf("SHOULD-NEVER-SERVE") < 0;
	assert out.indexOf("extern function vB") >= 0;
	unregisterHeaderCacheForTest();
}

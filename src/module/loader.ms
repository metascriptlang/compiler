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
	Module, ModuleGraph, ModuleState, ImportEntry,
	createModuleGraph, createModule, createImportEntry,
	findModule, hasModule, addModule,
	isInImportStack, pushImportStack, popImportStack,
	createModuleError, ErrorSeverity,
} from "./graph";
import { resolveImport, resolveImportWithConfig, isStdImport, ResolverConfig } from "./resolver";
import { lex } from "../lexer/lexer";
import { createState } from "../parser/context";
import { callStateProgramParser } from "../parser/statements/callbacks";
import "../parser/statements/core";
import { Node, NodeKind, ProgramData, ImportDeclData, ExportDeclData } from "../ast/node";
import { readFile } from "std/process";
import { parseCHeader } from "./aro";
// (utils/string imports removed — using native .slice)

// ===== Source Provider =====

export interface MapEntry {
	entryPath: string;
	entrySource: string;
}

export class SourceProvider {
	entries: MapEntry[];
	useFileSystem: boolean;
}

export function createMapProvider(entries: MapEntry[]): SourceProvider {
	return { entries, useFileSystem: false };
}

export function createFileSystemProvider(): SourceProvider {
	return { entries: [], useFileSystem: true };
}

export function provideSource(provider: SourceProvider, path: string): Result<string, string> {
	for (const e of provider.entries) {
		if (e.entryPath === path) return Result.ok(e.entrySource);
	}
	if (provider.useFileSystem) {
		const content = readFile(path);
		if (content.length > 0) {
			const cached: MapEntry = { entryPath: path, entrySource: content };
			provider.entries.push(cached);
			return Result.ok(content);
		}
	}
	return Result.err(`File not found: ${path}`);
}

// ===== C Header Detection =====

// Inline .h imports: scan source for `import { ... } from "*.h"` lines,
// replace each with @include + extern declarations generated from the C header.
// reference parity: importc declarations live inline in the consuming module.
function inlineHeaderImports(source: string, modulePath: string, provider: SourceProvider): string {
	let result = source;
	let searchPos = 0;
	while (searchPos < result.length) {
		// Find next import statement
		const importIdx = result.indexOf("import ", searchPos);
		if (importIdx < 0) break;

		// Find the full import statement (may span multiple lines) — terminated by ;
		const stmtEnd = result.indexOf(";", importIdx);
		if (stmtEnd < 0) { searchPos = importIdx + 7; continue; }
		const stmt = result.slice(importIdx, stmtEnd + 1);

		// Check if it imports from a .h file
		const fromIdx = stmt.indexOf(" from ");
		if (fromIdx < 0) { searchPos = importIdx + 7; continue; }

		// Extract specifier (between quotes after "from")
		const afterFrom = stmt.slice(fromIdx + 6, stmt.length).trim();
		let specifier = "";
		if (afterFrom.startsWith("\"") || afterFrom.startsWith("'")) {
			const quote = afterFrom.charAt(0);
			const endQuote = afterFrom.indexOf(quote, 1);
			if (endQuote > 0) specifier = afterFrom.slice(1, endQuote);
		}

		if (!specifier.endsWith(".h")) { searchPos = importIdx + 7; continue; }

		// Resolve the .h file path relative to the consuming module
		let headerPath = specifier;
		if (specifier.startsWith("./") || specifier.startsWith("../")) {
			const moduleDir = modulePath.slice(0, modulePath.lastIndexOf("/"));
			headerPath = moduleDir + "/" + specifier.slice(specifier.startsWith("./") ? 2 : 0, specifier.length);
		}

		// Read the .h file
		const headerSource = provideSource(provider, headerPath);
		if (!headerSource.ok) { searchPos = importIdx + 7; continue; }

		// Extract import list: import { A, B, C } → ["A", "B", "C"]
		const importedNames: string[] = [];
		const braceOpen = stmt.indexOf("{");
		const braceClose = stmt.indexOf("}");
		if (braceOpen >= 0 && braceClose > braceOpen) {
			const importList = stmt.slice(braceOpen + 1, braceClose).split(",");
			for (const n of importList) {
				const trimmed = n.trim();
				if (trimmed.length > 0) importedNames.push(trimmed);
			}
		}

		// Generate extern declarations via ARO (real C parser)
		let translated = parseCHeader(headerPath);
		// Strip "export " prefix (inline declarations don't re-export from consuming module)
		translated = translated.split("export extern ").join("extern ");
		translated = translated.split("export enum ").join("enum ");
		translated = translated.split("export type ").join("type ");

		// Auto-compile companion .c file if it exists (e.g., native.h → native.c)
		const companionC = headerPath.slice(0, headerPath.length - 2) + ".c";
		const hasCompanionC = provideSource(provider, companionC).ok;
		let compileDirective = "";
		if (hasCompanionC) compileDirective = `@compile("${companionC}");\n`;

		// Build replacement: @include + @compile (if .c exists) + extern declarations
		const replacement = `@include("${headerPath}");\n${compileDirective}${translated}`;

		// Replace the import statement (may span multiple lines) with the inlined declarations
		const replaceStart = importIdx;
		const replaceEnd = stmtEnd + 1;
		// Skip trailing newline after semicolon if present
		const afterSemi = replaceEnd < result.length && result.charCodeAt(replaceEnd) === "\n".code ? replaceEnd + 1 : replaceEnd;
		result = result.slice(0, replaceStart) + replacement + result.slice(afterSemi, result.length);

		searchPos = replaceStart + replacement.length;
	}
	return result;
}

function isCHeaderPath(path: string): boolean {
	if (path.length < 3) return false;
	return path.slice(path.length - 2, path.length) === ".h";
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
function loadSourceModule(graph: ModuleGraph, path: string, provider: SourceProvider, config: ResolverConfig, useConfig: number): boolean {
	const mod = createModule(path);
	mod.state = ModuleState.Loading;
	addModule(graph, mod);
	pushImportStack(graph, path);

	// Read source
	const sourceResult = provideSource(provider, path);
	if (!sourceResult.ok) {
		mod.errors.push(createModuleError(sourceResult.error, 0, 0, ErrorSeverity.Error));
		finalizeModule(graph, mod, path);
		return false;
	}
	mod.source = sourceResult.value;

	// Inline .h imports: replace `import { ... } from "*.h"` with extern declarations.
	// reference parity: importc declarations live inline in the consuming module, no separate module.
	mod.source = inlineHeaderImports(mod.source, path, provider);

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
		if (stmt.kind === NodeKind.ImportDecl) {
			processImportDecl(graph, mod, stmt, provider, config, useConfig);
		} else if (stmt.kind === NodeKind.ExportDecl) {
			// Re-export: export { ... } from "./module" wraps ImportDecl in ExportDecl
			const ed = stmt.data as ExportDeclData;
			if (ed.exportedDecl !== null && ed.exportedDecl.kind === NodeKind.ImportDecl) {
				processImportDecl(graph, mod, ed.exportedDecl, provider, config, useConfig);
			}
		}
	}

	// Done loading — mark ready, add to topological order
	finalizeModule(graph, mod, path);
	return true;
}

// useConfig: 0 = bare (skip std, .ms only), 1 = full (use ResolverConfig)
export function loadModule(graph: ModuleGraph, path: string, provider: SourceProvider, config: ResolverConfig, useConfig: number): Result<boolean, string> {
	// Already in graph — check if still loading (circular import)
	if (hasModule(graph, path)) {
		const existing = findModule(graph, path);
		if (existing !== null) {
			if (existing.state === ModuleState.Loading) {
				// Implementation parity: record cycle info
				// Extract cycle path from importStack
				const cycle: string[] = [];
				let inCycle = false;
				for (const sp of graph.importStack) {
					if (sp === path) inCycle = true;
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

	// C header files: handled by inlineHeaderImports() in the consuming module.
	// No separate module needed — reference parity.
	if (isCHeaderPath(path)) {
		return Result.ok(true);
	}

	// Regular source module
	const loaded = loadSourceModule(graph, path, provider, config, useConfig);
	return Result.ok(loaded);
}

// ===== Import Processing =====

function processImportDecl(graph: ModuleGraph, mod: Module, node: Node, provider: SourceProvider, config: ResolverConfig, useConfig: number): void {
	const d = node.data as ImportDeclData;
	const specifier = d.importSource;

	if (useConfig === 0) {
		// Bare mode: skip std, resolve .ms only
		if (isStdImport(specifier)) return;

		const candidates = resolveImport(specifier, mod.path);
		let resolved = "";
		for (const candidate of candidates) {
			if (resolved === "") {
				const trySource = provideSource(provider, candidate);
				if (trySource.ok) {
					resolved = candidate;
				}
			}
		}

		if (resolved === "") {
			mod.errors.push(createModuleError(`Cannot resolve import '${specifier}'`, 0, 0, ErrorSeverity.Error));
			return;
		}

		const entry = createImportEntry(d.importNames, d.importAliases, resolved, specifier);
		mod.imports.push(entry);
		const preCircCount = graph.circularDeps.length;
		const _loadResult = loadModule(graph, resolved, provider, config, 0);
		// Enrich circular dep with import site info if a new cycle was just detected
		if (graph.circularDeps.length > preCircCount) {
			const lastDep = graph.circularDeps[graph.circularDeps.length - 1];
			lastDep.importLine = node.location !== null ? node.location.line : 0;
			lastDep.importNames = d.importNames;
		}
	} else {
		// Config-aware mode: resolve all imports including std/
		const candidates = resolveImportWithConfig(specifier, mod.path, config);

		let resolved = "";
		for (const candidate of candidates) {
			if (resolved === "") {
				const trySource = provideSource(provider, candidate);
				if (trySource.ok) {
					resolved = candidate;
				}
			}
		}

		if (resolved === "") {
			// std/ with empty stdPath: silently skip (handled externally)
			if (isStdImport(specifier) && config.stdPath.length === 0) return;
			mod.errors.push(createModuleError(`Cannot resolve import '${specifier}'`, 0, 0, ErrorSeverity.Error));
			return;
		}

		const entry = createImportEntry(d.importNames, d.importAliases, resolved, specifier);
		mod.imports.push(entry);
		const preCircCount2 = graph.circularDeps.length;
		const _loadResult = loadModule(graph, resolved, provider, config, 1);
		if (graph.circularDeps.length > preCircCount2) {
			const lastDep2 = graph.circularDeps[graph.circularDeps.length - 1];
			lastDep2.importLine = node.location !== null ? node.location.line : 0;
			lastDep2.importNames = d.importNames;
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
	const dummyCfg: ResolverConfig = { backend: 0, stdPath: "", searchPaths: [], extensions: dummyExts, aliasKeys: [], aliasValues: [] };
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
	assert graph.modules.length === 1;
	assert graph.loadOrder.length === 1;
	assert graph.loadOrder[0] === "/src/a.ms";
	const mod = findModule(graph, "/src/a.ms");
	assert mod !== null;
	assert mod.state === ModuleState.Ready;
	assert mod.source === "const x = 1;";
}

test "A imports B chain" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/a.ms", "import { foo } from \"./b\";"));
	entries.push(makeEntry("/src/b.ms", "export function foo() { return 1; }"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	assert graph.modules.length === 2;
	// Topological: B before A (dependency loaded first)
	assert graph.loadOrder[0] === "/src/b.ms";
	assert graph.loadOrder[1] === "/src/a.ms";
	// A has import entry pointing to B
	const modA = findModule(graph, "/src/a.ms");
	assert modA !== null;
	assert modA.imports.length === 1;
	assert modA.imports[0].sourcePath === "/src/b.ms";
}

test "circular import handled" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/a.ms", "import { b } from \"./b\";"));
	entries.push(makeEntry("/src/b.ms", "import { a } from \"./a\";"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	// Both modules loaded (circular doesn't crash)
	assert graph.modules.length === 2;
	// Both end up in Ready state
	const modA = findModule(graph, "/src/a.ms");
	const modB = findModule(graph, "/src/b.ms");
	assert modA !== null;
	assert modB !== null;
	assert modA.state === ModuleState.Ready;
	assert modB.state === ModuleState.Ready;
}

test "diamond dependency" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/a.ms", "import { b } from \"./b\"; import { c } from \"./c\";"));
	entries.push(makeEntry("/src/b.ms", "import { d } from \"./d\"; export const b = 1;"));
	entries.push(makeEntry("/src/c.ms", "import { d } from \"./d\"; export const c = 2;"));
	entries.push(makeEntry("/src/d.ms", "export const d = 3;"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	assert graph.modules.length === 4;
	// D should be loaded once (not duplicated)
	assert graph.loadOrder[0] === "/src/d.ms";
	assert graph.errors.length === 0;
}

test "missing module error" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/a.ms", "import { x } from \"./missing\";"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	const mod = findModule(graph, "/src/a.ms");
	assert mod !== null;
	assert mod.errors.length > 0;
}

test "std import skipped" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/a.ms", "import { test } from \"std/testing\"; const x = 1;"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	assert graph.modules.length === 1;
	const mod = findModule(graph, "/src/a.ms");
	assert mod !== null;
	assert mod.imports.length === 0;
}

test "no duplicate loading" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/a.ms", "import { x } from \"./b\"; import { y } from \"./b\";"));
	entries.push(makeEntry("/src/b.ms", "export const x = 1; export const y = 2;"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	assert graph.modules.length === 2;
}

test "C header import inlines declarations" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/app.ms", "import { foo } from \"./lib.h\";"));
	entries.push(makeEntry("/src/lib.h", "void foo(int x);"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/app.ms", provider);
	// .h imports are inlined — no separate module created (reference parity)
	assert graph.modules.length === 1;
	assert graph.errors.length === 0;
	const hAppMod = findModule(graph, "/src/app.ms");
	assert hAppMod !== null;
	// The consuming module's source should contain the inlined extern declaration
	assert hAppMod.source.indexOf("extern") >= 0;
	const appMod = findModule(graph, "/src/app.ms");
	assert appMod !== null;
	assert appMod.errors.length === 0;
}

test "parse error recorded" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/a.ms", "const x = ;"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	const mod = findModule(graph, "/src/a.ms");
	assert mod !== null;
	assert mod.errors.length > 0;
	assert mod.state === ModuleState.Ready;
}

test "loadOrder is topological" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/main.ms", "import { a } from \"./a\";"));
	entries.push(makeEntry("/src/a.ms", "import { b } from \"./b\"; export const a = 1;"));
	entries.push(makeEntry("/src/b.ms", "export const b = 2;"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/main.ms", provider);
	assert graph.loadOrder[0] === "/src/b.ms";
	assert graph.loadOrder[1] === "/src/a.ms";
	assert graph.loadOrder[2] === "/src/main.ms";
}

test "module source stored" {
	const entries: MapEntry[] = [];
	entries.push(makeEntry("/src/a.ms", "const x = 42;"));
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	const mod = findModule(graph, "/src/a.ms");
	assert mod !== null;
	assert mod.source === "const x = 42;";
}

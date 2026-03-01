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
	findModule, addModule,
	isInImportStack, pushImportStack, popImportStack,
} from "./graph";
import { resolveImport, resolveImportWithConfig, isStdImport, ResolverConfig } from "./resolver";
import { lex } from "../lexer/lexer";
import { createState } from "../parser/context";
import { callStateProgramParser } from "../parser/statements/callbacks";
import { Node, NodeKind, ProgramData, ImportDeclData } from "../ast/node";
import { readFile } from "std/process";
import { test, check, testGroup } from "std/testing";

// ===== Source Provider =====

export interface MapEntry {
	entryPath: string;
	entrySource: string;
}

export interface SourceProvider {
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
	return Result.err("File not found: " + path);
}

// ===== Module Loading =====

function finalizeModule(graph: ModuleGraph, mod: Module, path: string): void {
	popImportStack(graph);
	mod.state = ModuleState.Ready;
	graph.loadOrder.push(path);
}

// useConfig: 0 = legacy (skip std, .ms only), 1 = use ResolverConfig
export function loadModule(graph: ModuleGraph, path: string, provider: SourceProvider, config: ResolverConfig, useConfig: number): Result<boolean, string> {
	// Already in graph — check if still loading (circular import)
	const existing = findModule(graph, path);
	if (existing !== null) {
		if (existing.state === ModuleState.Loading) {
			graph.errors.push("Circular import detected: " + path);
		}
		return Result.ok(true);
	}

	// Create module, mark as loading, add to graph BEFORE recursion
	const mod = createModule(path);
	mod.state = ModuleState.Loading;
	addModule(graph, mod);
	pushImportStack(graph, path);

	// Read source
	const sourceResult = provideSource(provider, path);
	if (!sourceResult.ok) {
		mod.errors.push(sourceResult.error);
		finalizeModule(graph, mod, path);
		return Result.ok(false);
	}
	mod.source = sourceResult.value;

	// Parse with recovery — always get partial AST, errors in state.errors
	const lr = lex(mod.source);
	if (!lr.ok) {
		mod.errors.push("Lex: " + lr.error);
		finalizeModule(graph, mod, path);
		return Result.ok(false);
	}
	const parseState = createState(lr.value);
	const parseResult = callStateProgramParser(parseState);
	for (const parseErr of parseState.errors) {
		mod.errors.push("Parse: " + parseErr);
	}
	mod.state = ModuleState.Parsed;

	// Walk AST for import declarations (works on partial ASTs)
	if (!parseResult.ok) {
		mod.errors.push("Parse: " + parseResult.error);
		finalizeModule(graph, mod, path);
		return Result.ok(false);
	}
	const program = parseResult.value;
	const pd = program.data as ProgramData;
	for (const stmt of pd.programStmts) {
		if (stmt.kind === NodeKind.ImportDecl) {
			processImportDecl(graph, mod, stmt, provider, config, useConfig);
		}
	}

	// Done loading — mark ready, add to topological order
	finalizeModule(graph, mod, path);
	return Result.ok(true);
}

// ===== Import Processing =====

function processImportDecl(graph: ModuleGraph, mod: Module, node: Node, provider: SourceProvider, config: ResolverConfig, useConfig: number): void {
	const d = node.data as ImportDeclData;
	const specifier = d.importSource;

	if (useConfig === 0) {
		// Legacy mode: skip std, resolve .ms only
		if (isStdImport(specifier)) return;

		const candidates = resolveImport(specifier, mod.path);
		let resolved = "";
		for (const candidate of candidates.paths) {
			if (resolved === "") {
				const trySource = provideSource(provider, candidate);
				if (trySource.ok) {
					resolved = candidate;
				}
			}
		}

		if (resolved === "") {
			mod.errors.push("Cannot resolve import '" + specifier + "' from " + mod.path);
			return;
		}

		const entry = createImportEntry(d.importNames, d.importAliases, resolved, specifier);
		mod.imports.push(entry);
		const _loadResult = loadModule(graph, resolved, provider, config, 0);
	} else {
		// Config-aware mode: resolve all imports including std/
		const candidates = resolveImportWithConfig(specifier, mod.path, config);

		let resolved = "";
		let i = 0;
		while (i < candidates.paths.length) {
			if (resolved === "") {
				const trySource = provideSource(provider, candidates.paths[i]);
				if (trySource.ok) {
					resolved = candidates.paths[i];
				}
			}
			i = i + 1;
		}

		if (resolved === "") {
			// std/ with empty stdPath: silently skip (handled externally)
			if (isStdImport(specifier) && config.stdPath.length === 0) return;
			mod.errors.push("Cannot resolve import '" + specifier + "' from " + mod.path);
			return;
		}

		const entry = createImportEntry(d.importNames, d.importAliases, resolved, specifier);
		mod.imports.push(entry);
		const _loadResult = loadModule(graph, resolved, provider, config, 1);
	}
}

// ===== Convenience: Load from entry point =====

// Config-aware graph loading
export function loadModuleGraphWithConfig(entryPath: string, provider: SourceProvider, config: ResolverConfig): ModuleGraph {
	const graph = createModuleGraph();
	const _r = loadModule(graph, entryPath, provider, config, 1);
	return graph;
}

// Legacy (no config) — backward compat
export function loadModuleGraph(entryPath: string, provider: SourceProvider): ModuleGraph {
	const graph = createModuleGraph();
	// Create a dummy config — not used in legacy mode (useConfig=0)
	const dummyExts: string[] = [];
	const dummyCfg: ResolverConfig = { backend: 0, stdPath: "", searchPaths: [], extensions: dummyExts, aliasKeys: [], aliasValues: [] };
	const _r = loadModule(graph, entryPath, provider, dummyCfg, 0);
	return graph;
}

// ===== Tests =====

function makeEntry(path: string, source: string): MapEntry {
	return { entryPath: path, entrySource: source };
}

testGroup("ModuleLoader", () => {
	test("single module", () => {
		const entries: MapEntry[] = [];
		entries.push(makeEntry("/src/a.ms", "const x = 1;"));
		const provider = createMapProvider(entries);
		const graph = loadModuleGraph("/src/a.ms", provider);
		check(graph.modules.length === 1);
		check(graph.loadOrder.length === 1);
		check(graph.loadOrder[0] === "/src/a.ms");
		const mod = findModule(graph, "/src/a.ms");
		check(mod !== null);
		check(mod.state === ModuleState.Ready);
		check(mod.source === "const x = 1;");
	});
	test("A imports B chain", () => {
		const entries: MapEntry[] = [];
		entries.push(makeEntry("/src/a.ms", "import { foo } from \"./b\";"));
		entries.push(makeEntry("/src/b.ms", "export function foo() { return 1; }"));
		const provider = createMapProvider(entries);
		const graph = loadModuleGraph("/src/a.ms", provider);
		check(graph.modules.length === 2);
		// Topological: B before A (dependency loaded first)
		check(graph.loadOrder[0] === "/src/b.ms");
		check(graph.loadOrder[1] === "/src/a.ms");
		// A has import entry pointing to B
		const modA = findModule(graph, "/src/a.ms");
		check(modA !== null);
		check(modA.imports.length === 1);
		check(modA.imports[0].sourcePath === "/src/b.ms");
	});
	test("circular import handled", () => {
		const entries: MapEntry[] = [];
		entries.push(makeEntry("/src/a.ms", "import { b } from \"./b\";"));
		entries.push(makeEntry("/src/b.ms", "import { a } from \"./a\";"));
		const provider = createMapProvider(entries);
		const graph = loadModuleGraph("/src/a.ms", provider);
		// Both modules loaded (circular doesn't crash)
		check(graph.modules.length === 2);
		// Both end up in Ready state
		const modA = findModule(graph, "/src/a.ms");
		const modB = findModule(graph, "/src/b.ms");
		check(modA !== null);
		check(modB !== null);
		check(modA.state === ModuleState.Ready);
		check(modB.state === ModuleState.Ready);
	});
	test("diamond dependency", () => {
		const entries: MapEntry[] = [];
		entries.push(makeEntry("/src/a.ms", "import { b } from \"./b\"; import { c } from \"./c\";"));
		entries.push(makeEntry("/src/b.ms", "import { d } from \"./d\"; export const b = 1;"));
		entries.push(makeEntry("/src/c.ms", "import { d } from \"./d\"; export const c = 2;"));
		entries.push(makeEntry("/src/d.ms", "export const d = 3;"));
		const provider = createMapProvider(entries);
		const graph = loadModuleGraph("/src/a.ms", provider);
		check(graph.modules.length === 4);
		// D should be loaded once (not duplicated)
		check(graph.loadOrder[0] === "/src/d.ms");
		check(graph.errors.length === 0);
	});
	test("missing module error", () => {
		const entries: MapEntry[] = [];
		entries.push(makeEntry("/src/a.ms", "import { x } from \"./missing\";"));
		const provider = createMapProvider(entries);
		const graph = loadModuleGraph("/src/a.ms", provider);
		const mod = findModule(graph, "/src/a.ms");
		check(mod !== null);
		check(mod.errors.length > 0);
	});
	test("std import skipped", () => {
		const entries: MapEntry[] = [];
		entries.push(makeEntry("/src/a.ms", "import { test } from \"std/testing\"; const x = 1;"));
		const provider = createMapProvider(entries);
		const graph = loadModuleGraph("/src/a.ms", provider);
		check(graph.modules.length === 1);
		const mod = findModule(graph, "/src/a.ms");
		check(mod !== null);
		check(mod.imports.length === 0);
	});
	test("no duplicate loading", () => {
		const entries: MapEntry[] = [];
		entries.push(makeEntry("/src/a.ms", "import { x } from \"./b\"; import { y } from \"./b\";"));
		entries.push(makeEntry("/src/b.ms", "export const x = 1; export const y = 2;"));
		const provider = createMapProvider(entries);
		const graph = loadModuleGraph("/src/a.ms", provider);
		check(graph.modules.length === 2);
	});
	test("parse error recorded", () => {
		const entries: MapEntry[] = [];
		entries.push(makeEntry("/src/a.ms", "const x = ;"));
		const provider = createMapProvider(entries);
		const graph = loadModuleGraph("/src/a.ms", provider);
		const mod = findModule(graph, "/src/a.ms");
		check(mod !== null);
		check(mod.errors.length > 0);
		check(mod.state === ModuleState.Ready);
	});
	test("loadOrder is topological", () => {
		const entries: MapEntry[] = [];
		entries.push(makeEntry("/src/main.ms", "import { a } from \"./a\";"));
		entries.push(makeEntry("/src/a.ms", "import { b } from \"./b\"; export const a = 1;"));
		entries.push(makeEntry("/src/b.ms", "export const b = 2;"));
		const provider = createMapProvider(entries);
		const graph = loadModuleGraph("/src/main.ms", provider);
		check(graph.loadOrder[0] === "/src/b.ms");
		check(graph.loadOrder[1] === "/src/a.ms");
		check(graph.loadOrder[2] === "/src/main.ms");
	});
	test("module source stored", () => {
		const entries: MapEntry[] = [];
		entries.push(makeEntry("/src/a.ms", "const x = 42;"));
		const provider = createMapProvider(entries);
		const graph = loadModuleGraph("/src/a.ms", provider);
		const mod = findModule(graph, "/src/a.ms");
		check(mod !== null);
		check(mod.source === "const x = 42;");
	});
});

// Module Graph — core data structures for multi-module compilation
//
// Nim reference: modulegraphs.nim (ModuleGraph, Iface, indexed by FileIndex)
// Zig reference: module/loader.zig (Module struct, ModuleState, dependency graph)
//
// Arrays passed by pointer — bare T[] types (wrappers removed).
//
// IMPORTANT: No imports from ast/ or checker/ — DRC lifecycle mangling bug generates
// Node_destroy with wrong module path when Node appears as a field type here.
// AST, SymbolTable, and Symbol[] are managed separately by the loader/checker via
// parallel arrays indexed by module position in the graph.

import { check } from "std/testing";

// ===== Module State Machine =====

export enum ModuleState {
	Unloaded,   // not yet loaded
	Loading,    // in progress (for circular import detection)
	Parsed,     // AST available, imports not yet resolved
	Ready,      // fully loaded, imports resolved
}

// ===== Import Entry =====

export interface ImportEntry {
	names: string[];           // imported symbol names
	aliases: string[];         // local alias names (1:1 with names)
	sourcePath: string;        // resolved absolute path of source module
	sourceSpecifier: string;   // original import specifier (for diagnostics)
}

// ===== Module =====
// Lightweight — no ast/checker types. Complex data stored in parallel arrays.

export interface Module {
	path: string;              // absolute file path (canonical key)
	source: string;            // raw source text
	state: ModuleState;        // loading state machine
	exportNames: string[];     // names of exported symbols (for lookup)
	imports: ImportEntry[];    // resolved import dependencies
	errors: string[];          // per-module errors
	isCHeader: boolean;        // true if loaded from .h file (C header module)
}

// ===== Module Graph =====

export interface ModuleGraph {
	modules: Module[];         // all loaded modules
	modulePaths: string[];     // parallel: absolute paths (for lookup)
	loadOrder: string[];       // topological order for checking
	importStack: string[];     // current loading stack (cycle detection)
	errors: string[];          // graph-level errors
}

// ===== Constructors =====

export function createModuleGraph(): ModuleGraph {
	return {
		modules: [],
		modulePaths: [],
		loadOrder: [],
		importStack: [],
		errors: [],
	};
}

export function createModule(path: string): Module {
	return {
		path,
		source: "",
		state: ModuleState.Unloaded,
		exportNames: [],
		imports: [],
		errors: [],
		isCHeader: false,
	};
}

export function createImportEntry(names: string[], aliases: string[], sourcePath: string, sourceSpecifier: string): ImportEntry {
	return { names, aliases, sourcePath, sourceSpecifier };
}

// ===== Module Lookup =====

export function findModule(graph: ModuleGraph, path: string): Module {
	const idx = findModuleIndex(graph, path);
	if (idx >= 0) return graph.modules[idx];
	return null as unknown as Module;
}

export function findModuleIndex(graph: ModuleGraph, path: string): number {
	for (let i = 0; i < graph.modulePaths.length; i += 1) {
		if (graph.modulePaths[i] === path) return i;
	}
	return -1;
}

export function hasModule(graph: ModuleGraph, path: string): boolean {
	return findModuleIndex(graph, path) >= 0;
}

export function addModule(graph: ModuleGraph, mod: Module): void {
	graph.modules.push(mod);
	graph.modulePaths.push(mod.path);
}

// ===== Import Stack (cycle detection) =====

export function isInImportStack(graph: ModuleGraph, path: string): boolean {
	for (const p of graph.importStack) {
		if (p === path) return true;
	}
	return false;
}

export function pushImportStack(graph: ModuleGraph, path: string): void {
	graph.importStack.push(path);
}

export function popImportStack(graph: ModuleGraph): void {
	if (graph.importStack.length > 0) {
		graph.importStack.pop();
	}
}

// ===== Export Name Lookup =====

export function hasExportName(mod: Module, name: string): boolean {
	for (const n of mod.exportNames) {
		if (n === name) return true;
	}
	return false;
}

// ===== Tests =====
test "create empty graph" {
	const g = createModuleGraph();
	check(g.modules.length === 0);
	check(g.modulePaths.length === 0);
	check(g.loadOrder.length === 0);
	check(g.importStack.length === 0);
}

test "create module" {
	const m = createModule("/a/b.ms");
	check(m.path === "/a/b.ms");
	check(m.state === ModuleState.Unloaded);
	check(m.exportNames.length === 0);
	check(m.imports.length === 0);
}

test "add and find module" {
	const g = createModuleGraph();
	const m = createModule("/a/b.ms");
	addModule(g, m);
	check(g.modules.length === 1);
	const found = findModule(g, "/a/b.ms");
	check(found !== null);
	check(found.path === "/a/b.ms");
}

test "find returns null for missing" {
	const g = createModuleGraph();
	const found = findModule(g, "/nope.ms");
	check(found === null);
}

test "findModuleIndex" {
	const g = createModuleGraph();
	addModule(g, createModule("/a.ms"));
	addModule(g, createModule("/b.ms"));
	check(findModuleIndex(g, "/a.ms") === 0);
	check(findModuleIndex(g, "/b.ms") === 1);
	check(findModuleIndex(g, "/c.ms") === -1);
}

test "hasModule" {
	const g = createModuleGraph();
	const m = createModule("/x.ms");
	addModule(g, m);
	check(hasModule(g, "/x.ms"));
	check(!hasModule(g, "/y.ms"));
}

test "import stack push/pop" {
	const g = createModuleGraph();
	check(!isInImportStack(g, "/a.ms"));
	pushImportStack(g, "/a.ms");
	check(isInImportStack(g, "/a.ms"));
	check(!isInImportStack(g, "/b.ms"));
	pushImportStack(g, "/b.ms");
	check(isInImportStack(g, "/b.ms"));
	popImportStack(g);
	check(!isInImportStack(g, "/b.ms"));
	check(isInImportStack(g, "/a.ms"));
	popImportStack(g);
	check(!isInImportStack(g, "/a.ms"));
}

test "multiple modules" {
	const g = createModuleGraph();
	const m1 = createModule("/a.ms");
	const m2 = createModule("/b.ms");
	const m3 = createModule("/c.ms");
	addModule(g, m1);
	addModule(g, m2);
	addModule(g, m3);
	check(g.modules.length === 3);
	check(findModule(g, "/b.ms") !== null);
	check(findModule(g, "/d.ms") === null);
}

test "module state transitions" {
	const m = createModule("/x.ms");
	check(m.state === ModuleState.Unloaded);
	m.state = ModuleState.Loading;
	check(m.state === ModuleState.Loading);
	m.state = ModuleState.Parsed;
	check(m.state === ModuleState.Parsed);
	m.state = ModuleState.Ready;
	check(m.state === ModuleState.Ready);
}

test "hasExportName" {
	const m = createModule("/x.ms");
	m.exportNames.push("foo");
	m.exportNames.push("bar");
	check(hasExportName(m, "foo"));
	check(hasExportName(m, "bar"));
	check(!hasExportName(m, "baz"));
}

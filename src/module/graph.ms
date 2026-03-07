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

// ===== Circular Dependency Info =====
// Nim parallel: c.recursiveDep in importer.nim — records cycle for warnings

export interface CircularDep {
	fromPath: string;    // module that triggered the circular import
	toPath: string;      // module being imported (already on import stack)
	cycle: string[];     // full cycle path (for diagnostics)
	importLine: number;  // line of the import declaration (1-indexed, 0 if unknown)
	importNames: string[]; // names being imported
}

// ===== Module Graph =====

export interface ModuleGraph {
	modules: Module[];         // all loaded modules
	modulePaths: string[];     // parallel: absolute paths (for lookup)
	loadOrder: string[];       // topological order for checking
	importStack: string[];     // current loading stack (cycle detection)
	errors: string[];          // graph-level errors
	circularDeps: CircularDep[];  // detected circular imports (for LSP warnings)
}

// ===== Constructors =====

export function createModuleGraph(): ModuleGraph {
	return {
		modules: [],
		modulePaths: [],
		loadOrder: [],
		importStack: [],
		errors: [],
		circularDeps: [],
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

// ===== Circular Dependency Queries =====

export function isCircularImport(graph: ModuleGraph, path: string): boolean {
	for (const dep of graph.circularDeps) {
		if (dep.fromPath === path || dep.toPath === path) return true;
	}
	return false;
}

export function getCircularDepsFor(graph: ModuleGraph, path: string): CircularDep[] {
	const result: CircularDep[] = [];
	for (const dep of graph.circularDeps) {
		if (dep.fromPath === path || dep.toPath === path) {
			result.push(dep);
		}
	}
	return result;
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
	expect(g.modules.length === 0);
	expect(g.modulePaths.length === 0);
	expect(g.loadOrder.length === 0);
	expect(g.importStack.length === 0);
}

test "create module" {
	const m = createModule("/a/b.ms");
	expect(m.path === "/a/b.ms");
	expect(m.state === ModuleState.Unloaded);
	expect(m.exportNames.length === 0);
	expect(m.imports.length === 0);
}

test "add and find module" {
	const g = createModuleGraph();
	const m = createModule("/a/b.ms");
	addModule(g, m);
	expect(g.modules.length === 1);
	const found = findModule(g, "/a/b.ms");
	expect(found !== null);
	expect(found.path === "/a/b.ms");
}

test "find returns null for missing" {
	const g = createModuleGraph();
	const found = findModule(g, "/nope.ms");
	expect(found === null);
}

test "findModuleIndex" {
	const g = createModuleGraph();
	addModule(g, createModule("/a.ms"));
	addModule(g, createModule("/b.ms"));
	expect(findModuleIndex(g, "/a.ms") === 0);
	expect(findModuleIndex(g, "/b.ms") === 1);
	expect(findModuleIndex(g, "/c.ms") === -1);
}

test "hasModule" {
	const g = createModuleGraph();
	const m = createModule("/x.ms");
	addModule(g, m);
	expect(hasModule(g, "/x.ms"));
	expect(!hasModule(g, "/y.ms"));
}

test "import stack push/pop" {
	const g = createModuleGraph();
	expect(!isInImportStack(g, "/a.ms"));
	pushImportStack(g, "/a.ms");
	expect(isInImportStack(g, "/a.ms"));
	expect(!isInImportStack(g, "/b.ms"));
	pushImportStack(g, "/b.ms");
	expect(isInImportStack(g, "/b.ms"));
	popImportStack(g);
	expect(!isInImportStack(g, "/b.ms"));
	expect(isInImportStack(g, "/a.ms"));
	popImportStack(g);
	expect(!isInImportStack(g, "/a.ms"));
}

test "multiple modules" {
	const g = createModuleGraph();
	const m1 = createModule("/a.ms");
	const m2 = createModule("/b.ms");
	const m3 = createModule("/c.ms");
	addModule(g, m1);
	addModule(g, m2);
	addModule(g, m3);
	expect(g.modules.length === 3);
	expect(findModule(g, "/b.ms") !== null);
	expect(findModule(g, "/d.ms") === null);
}

test "module state transitions" {
	const m = createModule("/x.ms");
	expect(m.state === ModuleState.Unloaded);
	m.state = ModuleState.Loading;
	expect(m.state === ModuleState.Loading);
	m.state = ModuleState.Parsed;
	expect(m.state === ModuleState.Parsed);
	m.state = ModuleState.Ready;
	expect(m.state === ModuleState.Ready);
}

test "hasExportName" {
	const m = createModule("/x.ms");
	m.exportNames.push("foo");
	m.exportNames.push("bar");
	expect(hasExportName(m, "foo"));
	expect(hasExportName(m, "bar"));
	expect(!hasExportName(m, "baz"));
}

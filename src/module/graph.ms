// Module Graph — core data structures for compilation
//
// Reference implementation equivalent: the module graph structures.
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

// ===== Module Error (structured) =====
// Preserves line/col/severity from checker for rich error formatting.

export enum ErrorSeverity {
	Error,
	Warning,
}

export interface ModuleError {
	message: string;
	line: number;       // 1-based, 0 = unknown
	column: number;     // 0-based, 0 = unknown
	severity: ErrorSeverity;
}

export function createModuleError(message: string, line: number, column: number, severity: ErrorSeverity): ModuleError {
	return { message, line, column, severity };
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

export class Module {
	path: string;              // absolute file path (canonical key)
	source: string;            // raw source text
	state: ModuleState;        // loading state machine
	exportNames: string[];     // names of exported symbols (for lookup)
	imports: ImportEntry[];    // resolved import dependencies
	errors: ModuleError[];     // per-module errors (structured)
}

// ===== Circular Dependency Info =====
// Reference parallel implementation: records cycle for warnings.

export class CircularDep {
	fromPath: string;    // module that triggered the circular import
	toPath: string;      // module being imported (already on import stack)
	cycle: string[];     // full cycle path (for diagnostics)
	importLine: number;  // line of the import declaration (1-indexed, 0 if unknown)
	importNames: string[]; // names being imported
}

// ===== Module Graph =====

export class ModuleGraph {
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
	assert g.modules.length === 0;
	assert g.modulePaths.length === 0;
	assert g.loadOrder.length === 0;
	assert g.importStack.length === 0;
}

test "create module" {
	const m = createModule("/a/b.ms");
	assert m.path === "/a/b.ms";
	assert m.state === ModuleState.Unloaded;
	assert m.exportNames.length === 0;
	assert m.imports.length === 0;
}

test "add and find module" {
	const g = createModuleGraph();
	const m = createModule("/a/b.ms");
	addModule(g, m);
	assert g.modules.length === 1;
	const found = findModule(g, "/a/b.ms");
	assert found !== null;
	assert found.path === "/a/b.ms";
}

test "find returns null for missing" {
	const g = createModuleGraph();
	const found = findModule(g, "/nope.ms");
	assert found === null;
}

test "findModuleIndex" {
	const g = createModuleGraph();
	addModule(g, createModule("/a.ms"));
	addModule(g, createModule("/b.ms"));
	assert findModuleIndex(g, "/a.ms") === 0;
	assert findModuleIndex(g, "/b.ms") === 1;
	assert findModuleIndex(g, "/c.ms") === -1;
}

test "hasModule" {
	const g = createModuleGraph();
	const m = createModule("/x.ms");
	addModule(g, m);
	assert hasModule(g, "/x.ms");
	assert !hasModule(g, "/y.ms");
}

test "import stack push/pop" {
	const g = createModuleGraph();
	assert !isInImportStack(g, "/a.ms");
	pushImportStack(g, "/a.ms");
	assert isInImportStack(g, "/a.ms");
	assert !isInImportStack(g, "/b.ms");
	pushImportStack(g, "/b.ms");
	assert isInImportStack(g, "/b.ms");
	popImportStack(g);
	assert !isInImportStack(g, "/b.ms");
	assert isInImportStack(g, "/a.ms");
	popImportStack(g);
	assert !isInImportStack(g, "/a.ms");
}

test "multiple modules" {
	const g = createModuleGraph();
	const m1 = createModule("/a.ms");
	const m2 = createModule("/b.ms");
	const m3 = createModule("/c.ms");
	addModule(g, m1);
	addModule(g, m2);
	addModule(g, m3);
	assert g.modules.length === 3;
	assert findModule(g, "/b.ms") !== null;
	assert findModule(g, "/d.ms") === null;
}

test "module state transitions" {
	const m = createModule("/x.ms");
	assert m.state === ModuleState.Unloaded;
	m.state = ModuleState.Loading;
	assert m.state === ModuleState.Loading;
	m.state = ModuleState.Parsed;
	assert m.state === ModuleState.Parsed;
	m.state = ModuleState.Ready;
	assert m.state === ModuleState.Ready;
}

test "hasExportName" {
	const m = createModule("/x.ms");
	m.exportNames.push("foo");
	m.exportNames.push("bar");
	assert hasExportName(m, "foo");
	assert hasExportName(m, "bar");
	assert !hasExportName(m, "baz");
}

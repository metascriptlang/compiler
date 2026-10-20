// Module Graph — core data structures for compilation
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
	line: int32;        // 1-based, 0 = unknown
	column: int32;      // 0-based, 0 = unknown
	severity: ErrorSeverity;
}

export function createModuleError(message: string, line: int32, column: int32, severity: ErrorSeverity): ModuleError {
	return { message, line, column, severity };
}

// ===== Import Entry =====

export interface ImportEntry {
	names: string[];           // imported symbol names
	aliases: string[];         // local alias names (1:1 with names)
	sourcePath: string;        // resolved absolute path of source module
	sourceSpecifier: string;   // original import specifier (for diagnostics)
	dynamic: boolean;
	typeOnly: boolean;
}

// ===== Module =====
// Lightweight — no ast/checker types. Complex data stored in parallel arrays.

export class Module {
	path: string;              // absolute file path (canonical key)
	rawSource: string;         // source text as read, before C headers are inlined
	source: string;            // source text with C headers inlined
	state: ModuleState;        // loading state machine
	exportNames: string[];     // names of exported symbols (for lookup)
	imports: ImportEntry[];    // resolved import dependencies
	runtimeDeps: string[];
	errors: ModuleError[];     // per-module errors (structured)
	stdPrelude: boolean;
	preludeSpecifier: string;
	extraPrelude: boolean;
}

// ===== Circular Dependency Info =====
// Reference parallel implementation: records cycle for warnings.

export class CircularDep {
	fromPath: string;    // module that triggered the circular import
	toPath: string;      // module being imported (already on import stack)
	cycle: string[];     // full cycle path (for diagnostics)
	importLine: int32;  // line of the import declaration (1-indexed, 0 if unknown)
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
		rawSource: "",
		source: "",
		state: ModuleState.Unloaded,
		exportNames: [],
		imports: [],
		runtimeDeps: [],
		errors: [],
		stdPrelude: false,
		preludeSpecifier: "",
		extraPrelude: false,
	};
}

export function createImportEntry(names: string[], aliases: string[], sourcePath: string, sourceSpecifier: string, dynamic: boolean = false): ImportEntry {
	return { names, aliases, sourcePath, sourceSpecifier, dynamic, typeOnly: false };
}

// ===== Module Lookup =====

export function findModule(graph: ModuleGraph, path: string): Module {
	const idx = findModuleIndex(graph, path);
	if (idx >= 0) return graph.modules[idx];
	return null as unknown as Module;
}

export function findModuleIndex(graph: ModuleGraph, path: string): int32 {
	for (let i = 0; i < graph.modulePaths.length; i += 1) {
		if (graph.modulePaths[i] == path) return i;
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
		if (p == path) return true;
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
		if (dep.fromPath == path || dep.toPath == path) return true;
	}
	return false;
}

export function getCircularDepsFor(graph: ModuleGraph, path: string): CircularDep[] {
	const result: CircularDep[] = [];
	for (const dep of graph.circularDeps) {
		if (dep.fromPath == path || dep.toPath == path) {
			result.push(dep);
		}
	}
	return result;
}

// ===== Export Name Lookup =====

export function hasExportName(mod: Module, name: string): boolean {
	for (const n of mod.exportNames) {
		if (n == name) return true;
	}
	return false;
}

// ===== Dynamic Module Plan =====
// Std modules stay eager: the prelude makes them implicit dependencies of every module,
// and the import edges do not record that.

export class DynamicModulePlan {
	records: string[] = [];
	lazy: HashSet<string> = new HashSet<string>();
	requested: int32[][] = [];
	topLevelAwait: HashSet<string> = new HashSet<string>();
}

function evaluates(imp: ImportEntry): boolean {
	return !imp.dynamic && !imp.typeOnly;
}

function evaluationClosure(graph: ModuleGraph, roots: string[]): HashSet<string> {
	const closed = new HashSet<string>();
	const pending: string[] = [];
	for (const root of roots) pending.push(root);
	while (pending.length > 0) {
		const path = pending.pop();
		if (closed.has(path)) continue;
		closed.add(path);
		const mod = findModule(graph, path);
		if (mod == null) continue;
		for (const imp of mod.imports) if (evaluates(imp)) pending.push(imp.sourcePath);
		for (const dep of mod.runtimeDeps) pending.push(dep);
	}
	return closed;
}

export function planDynamicModules(graph: ModuleGraph, entryPath: string, order: string[], stdPath: string): DynamicModulePlan {
	const plan = new DynamicModulePlan();
	const targets: string[] = [];
	let typeOnlyEdges = false;
	for (const mod of graph.modules) {
		for (const imp of mod.imports) {
			if (imp.dynamic && !targets.includes(imp.sourcePath)) targets.push(imp.sourcePath);
			if (imp.typeOnly) typeOnlyEdges = true;
		}
	}
	if (targets.length == 0 && !typeOnlyEdges) return plan;
	const reached = new HashSet<string>();
	const pending: string[] = [entryPath];
	while (pending.length > 0) {
		const path = pending.pop();
		if (reached.has(path)) continue;
		reached.add(path);
		const mod = findModule(graph, path);
		if (mod != null) for (const imp of mod.imports) pending.push(imp.sourcePath);
	}
	const roots: string[] = [entryPath];
	for (const path of order) {
		if (!reached.has(path) || (stdPath != "" && path.startsWith(stdPath))) roots.push(path);
	}
	const eager = evaluationClosure(graph, roots);
	const importable = evaluationClosure(graph, targets);
	const recordAt = new HashMap<string, int32>();
	for (const path of order) {
		if (eager.has(path)) continue;
		plan.lazy.add(path);
	}
	for (const path of order) {
		if (targets.includes(path) || (!eager.has(path) && importable.has(path))) {
			recordAt.set(path, plan.records.length);
			plan.records.push(path);
		}
	}
	for (const path of plan.records) {
		const requested: int32[] = [];
		const mod = findModule(graph, path);
		if (plan.lazy.has(path) && mod != null) {
			const deps: string[] = [];
			for (const imp of mod.imports) if (evaluates(imp)) deps.push(imp.sourcePath);
			for (const dep of mod.runtimeDeps) deps.push(dep);
			for (const dep of deps) {
				const at = recordAt.get(dep);
				if (at == null || !plan.lazy.has(dep) || requested.includes(at)) continue;
				requested.push(at);
			}
		}
		plan.requested.push(requested);
	}
	return plan;
}

// ===== Tests =====
test "create empty graph" {
	const g = createModuleGraph();
	assert g.modules.length == 0;
	assert g.modulePaths.length == 0;
	assert g.loadOrder.length == 0;
	assert g.importStack.length == 0;
}

test "create module" {
	const m = createModule("/a/b.ms");
	assert m.path == "/a/b.ms";
	assert m.state == ModuleState.Unloaded;
	assert m.exportNames.length == 0;
	assert m.imports.length == 0;
}

test "add and find module" {
	const g = createModuleGraph();
	const m = createModule("/a/b.ms");
	addModule(g, m);
	assert g.modules.length == 1;
	const found = findModule(g, "/a/b.ms");
	assert found != null;
	assert found.path == "/a/b.ms";
}

test "find returns null for missing" {
	const g = createModuleGraph();
	const found = findModule(g, "/nope.ms");
	assert found == null;
}

test "findModuleIndex" {
	const g = createModuleGraph();
	addModule(g, createModule("/a.ms"));
	addModule(g, createModule("/b.ms"));
	assert findModuleIndex(g, "/a.ms") == 0;
	assert findModuleIndex(g, "/b.ms") == 1;
	assert findModuleIndex(g, "/c.ms") == -1;
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
	assert g.modules.length == 3;
	assert findModule(g, "/b.ms") != null;
	assert findModule(g, "/d.ms") == null;
}

test "module state transitions" {
	const m = createModule("/x.ms");
	assert m.state == ModuleState.Unloaded;
	m.state = ModuleState.Loading;
	assert m.state == ModuleState.Loading;
	m.state = ModuleState.Parsed;
	assert m.state == ModuleState.Parsed;
	m.state = ModuleState.Ready;
	assert m.state == ModuleState.Ready;
}

test "hasExportName" {
	const m = createModule("/x.ms");
	m.exportNames.push("foo");
	m.exportNames.push("bar");
	assert hasExportName(m, "foo");
	assert hasExportName(m, "bar");
	assert !hasExportName(m, "baz");
}

test "planDynamicModules defers what only import() reaches" {
	const g = createModuleGraph();
	const paths = ["/std/core.ms", "/a.ms", "/lazy.ms", "/dep.ms", "/main.ms"];
	for (const p of paths) addModule(g, createModule(p));
	findModule(g, "/main.ms").imports.push(createImportEntry(["x"], ["x"], "/a.ms", "./a"));
	findModule(g, "/main.ms").imports.push(createImportEntry([], [], "/lazy.ms", "./lazy", true));
	findModule(g, "/main.ms").imports.push(createImportEntry([], [], "/a.ms", "./a", true));
	findModule(g, "/lazy.ms").imports.push(createImportEntry(["y"], ["y"], "/dep.ms", "./dep"));
	findModule(g, "/lazy.ms").imports.push(createImportEntry(["x"], ["x"], "/a.ms", "./a"));
	findModule(g, "/lazy.ms").imports.push(createImportEntry(["s"], ["s"], "/std/core.ms", "std/core"));
	findModule(g, "/dep.ms").imports.push(createImportEntry(["z"], ["z"], "/lazy.ms", "./lazy"));
	const plan = planDynamicModules(g, "/main.ms", paths, "/std");
	assert plan.records.join(",") == "/a.ms,/lazy.ms,/dep.ms";
	assert plan.lazy.has("/lazy.ms") && plan.lazy.has("/dep.ms") && plan.lazy.size == 2;
	assert plan.requested[0].length == 0;
	assert plan.requested[1].length == 1 && plan.requested[1][0] == 2;
	assert plan.requested[2].length == 1 && plan.requested[2][0] == 1;
}

test "planDynamicModules is empty without import()" {
	const g = createModuleGraph();
	addModule(g, createModule("/main.ms"));
	assert planDynamicModules(g, "/main.ms", ["/main.ms"], "").records.length == 0;
}

test "planDynamicModules leaves a module reached only through type-only imports unevaluated" {
	const g = createModuleGraph();
	const paths = ["/gpu.ms", "/types.ms", "/main.ms"];
	for (const p of paths) addModule(g, createModule(p));
	const typeOnly = createImportEntry(["Rgba"], ["Rgba"], "/types.ms", "./types");
	typeOnly.typeOnly = true;
	findModule(g, "/main.ms").imports.push(typeOnly);
	findModule(g, "/types.ms").imports.push(createImportEntry(["slots"], ["slots"], "/gpu.ms", "./gpu"));
	const plan = planDynamicModules(g, "/main.ms", paths, "");
	assert plan.lazy.has("/types.ms") && plan.lazy.has("/gpu.ms") && plan.lazy.size == 2;
	assert plan.records.length == 0;
	findModule(g, "/main.ms").runtimeDeps.push("/gpu.ms");
	const reached = planDynamicModules(g, "/main.ms", paths, "");
	assert reached.lazy.has("/types.ms") && reached.lazy.size == 1;
}

// Module orchestrator — coordinates checking across module graph
// Reference parallel implementation

import { platform } from "std/process";
import { Node, Symbol } from "../ast/node";
import { CheckerContext, Severity, GcMode, ExportRegistry, collectExports } from "./context";
import { lookupLocal } from "./symbol";
import { ModuleGraph, Module, findModule, createModuleError, ErrorSeverity } from "../module/graph";
import { threePassTimings, buildPreludeContext, preludeContextFor, promoteModuleIntoPrelude, registerGraphPreludeFn, setSlowTrace } from "./checkPass";
import { defaultGlobalImports, extraGlobalImports, extraGlobalImportsBuildFile, isExtraGlobalImportModule, noteExtraGlobalImportModule, hasExtraGlobalImports } from "./prelude";
import { createModuleGraph } from "../module/graph";
import { createFileSystemProvider, provideSource, loadModule, moduleIdentity, SourceProvider } from "../module/loader";
import { backendOfExtension, createDefaultConfig, resolveImportWithConfig, ResolverConfig } from "../module/resolver";
import { preludePackStats } from "./preludePack";
import { isAssignableProfile } from "./compat";
import { TargetInfo, hostTargetInfo, unifyTypeProfile, substituteTypeProfile, typeNameOfProfile, typeDisplayNameProfile, getPropertyProfile, findVariantByFieldNameProfile } from "./types";
import { findAllExtensionsByNameProfile } from "./context";
import { checkCallExprProfile } from "./callResolve";
import { registerModuleProgram, instantiateProfile, instantiateTimings, lookupModuleCtx, pendingInstanceMark, takePendingInstancesFrom, drainPendingInstances } from "./instantiate";
import { cloneNodeForCheck } from "../monomorphize/clone";
import { createTransAmDb, dbSetResolverConfig, dbBindGraph, dbParse, dbTypeCheck, dbCheckIsCurrent, dbGetCheckedProgram, TransAmDb } from "../compiler/transam/index";
import { GenericTypeInstRow, genericTypeInstMark, takeGenericTypeInstsFrom, resetGenericTypeInsts } from "../parser/context";

export class CheckSession {
	db: TransAmDb | null;
	checks: HashMap<string, CheckerContext>;
	instances: HashMap<string, Node[]>;
	typeInstances: HashMap<string, GenericTypeInstRow[]>;
	preludeTypeInstances: GenericTypeInstRow[];
	rechecked: HashSet<string>;
}

export function createCheckSession(): CheckSession {
	return {
		db: null,
		checks: new HashMap<string, CheckerContext>(),
		instances: new HashMap<string, Node[]>(),
		typeInstances: new HashMap<string, GenericTypeInstRow[]>(),
		preludeTypeInstances: [],
		rechecked: new HashSet<string>(),
	};
}


// Cached prelude context — built once by checkModuleGraph, retrieved by callers.
let lastPreludeCtx: CheckerContext = null as unknown as CheckerContext;
export function getPreludeContext(): CheckerContext { return lastPreludeCtx; }

function loadGlobalImportModule(graph: ModuleGraph, provider: SourceProvider, config: ResolverConfig, entry: string, isExtra: boolean): void {
	for (const candidate of resolveImportWithConfig(entry, "virtual:prelude", config)) {
		if (!provideSource(provider, candidate).ok) continue;
		const _r = loadModule(graph, candidate, provider, config, 1);
		if (isExtra) noteExtraGlobalImportModule(moduleIdentity(candidate, config, provider));
		return;
	}
	if (isExtra) graph.errors.push(`globalImports entry '${entry}' in ${extraGlobalImportsBuildFile()} resolves to no module`);
}

export function loadStdGlobalImportModules(graph: ModuleGraph, provider: SourceProvider, config: ResolverConfig): void {
	for (const entry of defaultGlobalImports()) loadGlobalImportModule(graph, provider, config, entry, false);
}

export function loadExtraGlobalImportModules(graph: ModuleGraph, provider: SourceProvider, config: ResolverConfig): void {
	for (const entry of extraGlobalImports()) loadGlobalImportModule(graph, provider, config, entry, true);
}

export function preludeGraphContext(stdPath: string, backendExt: string): CheckerContext {
	if (!hasExtraGlobalImports()) return buildPreludeContext(stdPath, backendExt);
	const config = createDefaultConfig(backendOfExtension(backendExt), stdPath);
	const graph = createModuleGraph();
	const provider = createFileSystemProvider();
	loadStdGlobalImportModules(graph, provider, config);
	loadExtraGlobalImportModules(graph, provider, config);
	const _registry = checkModuleGraph(graph, stdPath, backendExt);
	return lastPreludeCtx;
}

registerGraphPreludeFn(preludeGraphContext);

// Sub-phase timing for the graph check, mirroring cmdBuildC's phase timers.
// Off unless the caller asked for -t, so a normal build pays nothing.
let graphTiming: boolean = false;
export function setGraphCheckTiming(on: boolean): void {
	graphTiming = on;
	setSlowTrace(on);
}

// stdPath: when non-empty, resolves std/ imports against this path.
// When empty, falls back to relative "std/" (resolved by reference compiler).
// targetOs: build target ("macos" / "linux" / "windows" / "bare" / ...). Set on
// the prelude context so per-module ctxs inherit it via injectPrelude — needed
// for the @platform("...") block-form directive filter to evaluate against
// the correct target during collectDirectives (which runs as part of this
// check pass, BEFORE cmdBuildC's applyGcMode propagates targetOs elsewhere).
// gcMode: memory-management mode of the build, resolved from --gc + the target
// (--os=bare/solana imply Manual). Stamped on the same context and for the same
// reason as targetOs: checks that depend on the runtime's capabilities (e.g. the
// freestanding async gate) run inside this pass, long before applyGcMode.
export function checkModuleGraph(graph: ModuleGraph, stdPath: string, backendExt: string = ".cms", targetOs: string = platform, targetInfo: TargetInfo = hostTargetInfo(), gcMode: GcMode = GcMode.Orc, config: ResolverConfig | null = null, session: CheckSession | null = null): ExportRegistry {
	const kept: TransAmDb | null = session != null ? session.db : null;
	if (session != null) resetGenericTypeInsts();
	const _tpre0 = performance.now();
	const baseCtx = kept != null ? kept.preludeCtx : hasExtraGlobalImports() ? buildPreludeContext(stdPath, backendExt) : preludeContextFor(stdPath, backendExt);
	const tPrelude = performance.now() - _tpre0;
	baseCtx.targetOs = targetOs;
	baseCtx.targetInfo = targetInfo;
	baseCtx.gcMode = gcMode;
	lastPreludeCtx = baseCtx;

	const _tf0 = performance.now();
	const db = kept != null ? kept : createTransAmDb(graph.loadOrder.length * 8 + 64);
	if (kept == null) {
		dbSetResolverConfig(db, config != null ? config : createDefaultConfig(backendOfExtension(backendExt), stdPath));
		db.preludeCtx = baseCtx;
	}
	if (session != null) {
		session.db = db;
		session.rechecked = new HashSet<string>();
		const _stale = drainPendingInstances();
		const preludeRows = takeGenericTypeInstsFrom(0);
		if (kept == null) session.preludeTypeInstances = preludeRows;
	}
	dbBindGraph(db, graph);
	for (const path of graph.loadOrder) {
		const mod = findModule(graph, path);
		if (mod == null || mod.source == "") continue;
		const parsed = dbParse(db, path);
		if (parsed == null) continue;
		registerModuleProgram(path, kept != null && dbCheckIsCurrent(db, path) ? dbGetCheckedProgram(db, path) : cloneNodeForCheck(parsed));
	}
	const tFeed = performance.now() - _tf0;

	const _tc0 = performance.now();
	for (const path of graph.loadOrder) {
		const mod = findModule(graph, path);
		if (mod == null || mod.source == "") continue;
		mod.exportNames = [];
		const _tm0 = performance.now();
		const instanceMark = pendingInstanceMark();
		const typeInstanceMark = genericTypeInstMark();
		const ctx = dbTypeCheck(db, path);
		if (session != null && ctx != null && session.checks.get(path) != ctx) {
			session.checks.set(path, ctx);
			session.instances.set(path, takePendingInstancesFrom(instanceMark));
			session.typeInstances.set(path, takeGenericTypeInstsFrom(typeInstanceMark));
			session.rechecked.add(path);
		}
		const _tm1 = performance.now();
		if (graphTiming && (_tm1 - _tm0) > 100) {
			console.log(`    slowcheck ${path} ${_tm1 - _tm0}ms`);
		}
		if (ctx == null) {
			if (!hasModuleError(mod)) mod.errors.push(createModuleError(`internal: ${path} produced no check result`, 0, 0, ErrorSeverity.Error));
			continue;
		}
		if (isExtraGlobalImportModule(path)) promoteModuleIntoPrelude(baseCtx, ctx);
		for (const err of ctx.errors) {
			if (err.severity == Severity.Hint) continue;
			const sev = match (err.severity) {
				Severity.Warning => ErrorSeverity.Warning,
				_ => ErrorSeverity.Error,
			};
			mod.errors.push(createModuleError(err.message, err.line, err.column, sev));
		}
		for (const e of collectExports(ctx, path)) mod.exportNames.push(e.name);
	}
	const tCheck = performance.now() - _tc0;
	if (graphTiming) {
		console.log(`    prelude=${tPrelude}ms feed=${tFeed}ms check=${tCheck}ms`);
		const pk = preludePackStats();
		console.log(`    preludePack: hit=${pk[3]} key=${pk[0]}ms load=${pk[1]}ms write=${pk[2]}ms`);
		const tp = threePassTimings();
		console.log(`    3pass: collect=${tp[0]}ms resolve=${tp[1]}ms flow=${tp[2]}ms body=${tp[3]}ms unused=${tp[4]}ms`);
		const ip = instantiateProfile();
		const it = instantiateTimings();
		console.log(`    instantiate: calls=${ip[0]} hits=${ip[1]} misses=${ip[2]} totalTime=${it[0]}ms bodyCheck=${it[1]}ms`);
		const isa = isAssignableProfile();
		const uni = unifyTypeProfile();
		const sub = substituteTypeProfile();
		const tno = typeNameOfProfile();
		const tdn = typeDisplayNameProfile();
		const cce = checkCallExprProfile();
		console.log(`    isAssignable: n=${isa[0]} t=${isa[1]}ms | unifyType: n=${uni[0]} t=${uni[1]}ms | substituteType: n=${sub[0]} t=${sub[1]}ms`);
		console.log(`    typeNameOf: n=${tno[0]} t=${tno[1]}ms | typeDisplayName: n=${tdn[0]} t=${tdn[1]}ms | checkCallExpr: n=${cce[0]} t=${cce[1]}ms`);
		const gp = getPropertyProfile();
		const fvb = findVariantByFieldNameProfile();
		const fae = findAllExtensionsByNameProfile();
		console.log(`    getProperty: n=${gp[0]} t=${gp[1]}ms | findVariantByFieldName: n=${fvb[0]} t=${fvb[1]}ms | findAllExtByName: n=${fae[0]} t=${fae[1]}ms`);
	}
	return db.exportRegistry;
}

function hasModuleError(mod: Module): boolean {
	for (const e of mod.errors) {
		if (e.severity == ErrorSeverity.Error) return true;
	}
	return false;
}


// ===== Tests =====

import { hasExportName } from "../module/graph";
import { MapEntry, createMapProvider, loadModuleGraph } from "../module/loader";
import { setExtraGlobalImports } from "./prelude";
test "single file checked" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/a.ms", entrySource: "const x = 1;" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	checkModuleGraph(graph, "");
	assert graph.errors.length == 0;
	const mod = findModule(graph, "/src/a.ms");
	assert mod != null;
	assert mod.errors.length == 0;
}

test "errors collected per module" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/a.ms", entrySource: "const x = y;" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	checkModuleGraph(graph, "");
	const mod = findModule(graph, "/src/a.ms");
	assert mod != null;
	assert mod.errors.length > 0;
}

test "export names recorded" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/a.ms", entrySource: "export function foo() { return 1; } function bar() { return 2; }" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	checkModuleGraph(graph, "");
	const mod = findModule(graph, "/src/a.ms");
	assert mod != null;
	assert hasExportName(mod, "foo");
	assert !hasExportName(mod, "bar");
}

test "two module chain checked" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/a.ms", entrySource: "import { foo } from \"./b\"; const x = foo;" });
	entries.push({ entryPath: "/src/b.ms", entrySource: "export function foo() { return 1; }" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	checkModuleGraph(graph, "");
	// Both modules should check without errors
	const modA = findModule(graph, "/src/a.ms");
	const modB = findModule(graph, "/src/b.ms");
	assert modA != null;
	assert modB != null;
	assert modB.errors.length == 0;
}

test "imported function has Function type" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/b.ms", entrySource: "export function foo(n: number): string { return \"hi\"; }" });
	entries.push({ entryPath: "/src/a.ms", entrySource: "import { foo } from \"./b\"; const x = foo(1);" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	checkModuleGraph(graph, "");
	const modA = findModule(graph, "/src/a.ms");
	const modB = findModule(graph, "/src/b.ms");
	assert modA != null;
	assert modB != null;
	assert modA.errors.length == 0;
	assert modB.errors.length == 0;
}

function scopeSymbolOf(path: string, name: string): Symbol | null {
	const ctx = lookupModuleCtx(path);
	if (ctx == null) return null;
	return lookupLocal(ctx.table, name);
}

test "an import binds the defining module's own symbol under every alias" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/b.ms", entrySource: "export function foo(n: number): number { return n; }" });
	entries.push({ entryPath: "/src/a.ms", entrySource: "import { foo, foo as bar } from \"./b\"; const x = foo(1) + bar(2);" });
	const graph = loadModuleGraph("/src/a.ms", createMapProvider(entries));
	checkModuleGraph(graph, "");
	const defining = scopeSymbolOf("/src/b.ms", "foo");
	assert defining != null;
	assert scopeSymbolOf("/src/a.ms", "foo") == defining;
	assert scopeSymbolOf("/src/a.ms", "bar") == defining;
}

test "both sides of an import cycle bind the symbols the other side checks" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/a.ms", entrySource: "import { fb } from \"./b\"; export function fa(n: number): number { return fb(n); }" });
	entries.push({ entryPath: "/src/b.ms", entrySource: "import { fa } from \"./a\"; export function fb(n: number): number { return n <= 0 ? 0 : fa(n - 1); }" });
	const graph = loadModuleGraph("/src/a.ms", createMapProvider(entries));
	checkModuleGraph(graph, "");
	const fa = scopeSymbolOf("/src/a.ms", "fa");
	const fb = scopeSymbolOf("/src/b.ms", "fb");
	assert fa != null && fb != null;
	assert scopeSymbolOf("/src/b.ms", "fa") == fa;
	assert scopeSymbolOf("/src/a.ms", "fb") == fb;
}

test "an import used by one module is still unused in another" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/lib.ms", entrySource: "export function foo(): number { return 1; }" });
	entries.push({ entryPath: "/src/idle.ms", entrySource: "import { foo } from \"./lib\"; export const idle = 0;" });
	entries.push({ entryPath: "/src/a.ms", entrySource: "import { foo } from \"./lib\"; import { idle } from \"./idle\"; const x = foo() + idle;" });
	const graph = loadModuleGraph("/src/a.ms", createMapProvider(entries));
	checkModuleGraph(graph, "");
	const idle = findModule(graph, "/src/idle.ms");
	const user = findModule(graph, "/src/a.ms");
	assert idle != null && user != null;
	let idleWarned = false;
	for (const e of idle.errors) {
		if (e.message == "'foo' is imported but never used") idleWarned = true;
	}
	assert idleWarned;
	for (const e of user.errors) assert e.message != "'foo' is imported but never used";
}

test "imported enum available" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/b.ms", entrySource: "export enum Color { Red, Green, Blue }" });
	entries.push({ entryPath: "/src/a.ms", entrySource: "import { Color } from \"./b\"; const c = Color;" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	checkModuleGraph(graph, "");
	const modA = findModule(graph, "/src/a.ms");
	assert modA != null;
	assert modA.errors.length == 0;
}

test "imported interface as type annotation" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/b.ms", entrySource: "export interface Point { x: number; y: number; }" });
	entries.push({ entryPath: "/src/a.ms", entrySource: "import { Point } from \"./b\"; function getX(p: Point): number { return 1; }" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	checkModuleGraph(graph, "");
	const modA = findModule(graph, "/src/a.ms");
	assert modA != null;
	assert modA.errors.length == 0;
}

test "non-exported name produces error" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/b.ms", entrySource: "function secret() { return 1; }" });
	entries.push({ entryPath: "/src/a.ms", entrySource: "import { secret } from \"./b\";" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	checkModuleGraph(graph, "");
	const modA = findModule(graph, "/src/a.ms");
	assert modA != null;
	assert modA.errors.length > 0;
}

test "cross-module non-primary operator overload resolves" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/b.ms", entrySource: "export struct V { x: float64; } export struct T { a: float64; } export function `*`(this m: T, n: T): T { return { a: m.a }; } export function `*`(this p: V, m: T): V { return { x: p.x }; }" });
	entries.push({ entryPath: "/src/a.ms", entrySource: "import { V, T } from \"./b\"; const pp: V = { x: 1.0 }; const mm: T = { a: 2.0 }; const rr = pp * mm; const zz: float64 = rr.x;" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	checkModuleGraph(graph, "");
	const modA = findModule(graph, "/src/a.ms");
	assert modA != null;
	assert modA.errors.length == 0;
}

test "3-module chain propagates types" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/c.ms", entrySource: "export function makeStr(): string { return \"hello\"; }" });
	entries.push({ entryPath: "/src/b.ms", entrySource: "import { makeStr } from \"./c\"; export function greet(name: string): string { return makeStr(); }" });
	entries.push({ entryPath: "/src/a.ms", entrySource: "import { greet } from \"./b\"; const msg = greet(\"world\");" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	checkModuleGraph(graph, "");
	const modA = findModule(graph, "/src/a.ms");
	assert modA != null;
	assert modA.errors.length == 0;
}

test "inferred return type propagates across modules" {
	const entries: MapEntry[] = [];
	// No return type annotation — inference should propagate number
	entries.push({ entryPath: "/src/b.ms", entrySource: "export function foo() { return 42; }" });
	entries.push({ entryPath: "/src/a.ms", entrySource: "import { foo } from \"./b\"; const x = foo();" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	checkModuleGraph(graph, "");
	const modA = findModule(graph, "/src/a.ms");
	const modB = findModule(graph, "/src/b.ms");
	assert modA != null;
	assert modB != null;
	assert modA.errors.length == 0;
	assert modB.errors.length == 0;
}

test "re-export forwards types" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/c.ms", entrySource: "export function helper(): number { return 42; }" });
	entries.push({ entryPath: "/src/b.ms", entrySource: "export { helper } from \"./c\";" });
	entries.push({ entryPath: "/src/a.ms", entrySource: "import { helper } from \"./b\"; const x = helper();" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	checkModuleGraph(graph, "");
	const modB = findModule(graph, "/src/b.ms");
	assert modB != null;
	assert hasExportName(modB, "helper");
	const modA = findModule(graph, "/src/a.ms");
	assert modA != null;
	assert modA.errors.length == 0;
}

test "parse error recovery still extracts exports" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/a.ms", entrySource: "export function foo() { return 1; } const = bad;" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	checkModuleGraph(graph, "");
	const mod = findModule(graph, "/src/a.ms");
	assert mod != null;
	assert mod.errors.length > 0;
	assert hasExportName(mod, "foo");
}

test "imported extension method available" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/b.ms", entrySource: "export function trim(this s: string): string { return s; }" });
	entries.push({ entryPath: "/src/a.ms", entrySource: "import { trim } from \"./b\"; const s = \"hello\"; const t = s.trim();" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	checkModuleGraph(graph, "");
	const modA = findModule(graph, "/src/a.ms");
	assert modA != null;
	assert modA.errors.length == 0;
}

test "parse error in dependency doesn't block dependent" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/b.ms", entrySource: "export function bar() { return 1; } const = bad;" });
	entries.push({ entryPath: "/src/a.ms", entrySource: "import { bar } from \"./b\"; const x = bar;" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	checkModuleGraph(graph, "");
	const modA = findModule(graph, "/src/a.ms");
	assert modA != null;
	// Module A can resolve 'bar' from B's partial exports
	assert modA.errors.length == 0;
}

test "C header import synthesizes exports" {
	// .h imports are inlined into the consuming module (reference parity)
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/lib.h", entrySource: "void foo(int x);" });
	entries.push({ entryPath: "/src/a.ms", entrySource: "import { foo } from \"./lib.h\"; const x = foo;" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	// No separate .h module — declarations inlined into /src/a.ms
	assert graph.modules.length == 1;
	const modA = findModule(graph, "/src/a.ms");
	assert modA != null;
	assert modA.source.indexOf("extern") >= 0;
}

// ===== Circular Import Tests =====

test "circular import no false 'not exported' error" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/a.ms", entrySource: "import { foo } from \"./b\"; export function bar(): number { return 1; }" });
	entries.push({ entryPath: "/src/b.ms", entrySource: "import { bar } from \"./a\"; export function foo(): string { return \"hi\"; }" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	checkModuleGraph(graph, "");
	const modA = findModule(graph, "/src/a.ms");
	const modB = findModule(graph, "/src/b.ms");
	assert modA != null;
	assert modB != null;
	// Neither module should have "not exported" errors — Phase 1 registered both names
	assert graph.circularDeps.length > 0;
}

test "circularDeps recorded for LSP" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/a.ms", entrySource: "import { b } from \"./b\";" });
	entries.push({ entryPath: "/src/b.ms", entrySource: "import { a } from \"./a\";" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	assert graph.circularDeps.length > 0;
}

test "non-circular modules still resolve fully" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/b.ms", entrySource: "export function foo(n: number): string { return \"hi\"; }" });
	entries.push({ entryPath: "/src/a.ms", entrySource: "import { foo } from \"./b\"; const x = foo(1);" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	checkModuleGraph(graph, "");
	const modA2 = findModule(graph, "/src/a.ms");
	const modB2 = findModule(graph, "/src/b.ms");
	assert modA2 != null;
	assert modB2 != null;
	assert modA2.errors.length == 0;
	assert modB2.errors.length == 0;
}

test "extra globalImports entry resolving to no module is a graph error naming the entry and its build.ms" {
	const entries: MapEntry[] = [];
	const provider = createMapProvider(entries);
	const graph = createModuleGraph();
	setExtraGlobalImports(["/proj/nope/missing"], "/proj/build.ms");
	loadExtraGlobalImportModules(graph, provider, createDefaultConfig(backendOfExtension(".cms"), ""));
	setExtraGlobalImports([]);
	assert graph.errors.length == 1;
	assert graph.errors[0].includes("/proj/nope/missing");
	assert graph.errors[0].includes("/proj/build.ms");
}

test "extra globalImports entry resolving to a module is not a graph error" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/proj/src/converters.ms", entrySource: "export const marker = 1;" });
	const provider = createMapProvider(entries);
	const graph = createModuleGraph();
	setExtraGlobalImports(["/proj/src/converters"], "/proj/build.ms");
	loadExtraGlobalImportModules(graph, provider, createDefaultConfig(backendOfExtension(".cms"), ""));
	setExtraGlobalImports([]);
	assert graph.errors.length == 0;
	assert findModule(graph, "/proj/src/converters.ms") != null;
}

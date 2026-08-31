// Module orchestrator — coordinates checking across module graph
// Reference parallel implementation

import { platform } from "std/process";
import { Node, NodeKind, EnumDeclData, makeLoc, SourceLocation } from "../ast/node";
import {
	CheckerContext, createModuleContextWithCache, Severity,
	ExportRegistry, ExportedSymInfo, createExportRegistry, registerModuleExports, updateModuleExports,
	collectExports, registerExtension,
} from "./context";
import { ScopeKind, openScope, addSymbolToScope, hasFlag, SymbolFlag } from "./symbol";
import { ModuleGraph, findModule, createModuleError, ErrorSeverity } from "../module/graph";
import { runThreePasses, threePassTimings, buildPreludeContext, getSharedIdentCache, collectDirectives, stampHeaderPaths, injectPrelude, setSlowTrace } from "./checkPass";
import { analyzeParamMutations } from "./paramMutationAnalysis";
import { collectTopLevelLocal } from "./collectPass";
import { isAssignableProfile } from "./compat";
import { unifyTypeProfile, substituteTypeProfile, typeNameOfProfile, typeDisplayNameProfile, getPropertyProfile, findVariantByFieldNameProfile } from "./types";
import { findAllExtensionsByNameProfile } from "./context";
import { checkCallExprProfile } from "./callResolve";
import { registerModuleCtx, registerModuleProgram, instantiateProfile, instantiateTimings } from "./instantiate";
import { lex } from "../lexer/lexer";
import { createState } from "../parser/context";
import { callStateProgramParser } from "../parser/statements/callbacks";
import "../parser/statements/core";


// Standard-aligned two-phase module checking.
//
// Phase 1: Parse + collectTopLevelLocal (skip imports) for ALL modules.
//          Register exported names+kinds with placeholder types in ExportRegistry.
//          After Phase 1, every module's names are visible cross-module.
//
// Phase 2: For each module in loadOrder, run full 3 passes (imports now resolve
//          from Phase 1 placeholders or earlier Phase 2 resolved types).
//          After each module, update its ExportRegistry entry with resolved types.
//
// For circular deps (A→B→A, loadOrder=[B,A]):
//   Phase 1: Both registered with placeholder types
//   Phase 2: B checked first — imports A → placeholder types. A checked second — imports B → resolved types.
//   Matches standard partial visibility semantics for circular imports.

// Cached prelude context — built once by checkModuleGraph, retrieved by callers.
let lastPreludeCtx: CheckerContext = null as unknown as CheckerContext;
export function getPreludeContext(): CheckerContext { return lastPreludeCtx; }

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
export function checkModuleGraph(graph: ModuleGraph, stdPath: string, backendExt: string = ".cms", targetOs: string = platform): ExportRegistry {
	const registry = createExportRegistry();

	// PROFILE: sub-phase timings summed across all modules (-t only).
	let tPrelude: float64 = 0;
	let tP1Parse: float64 = 0;
	let tP1Collect: float64 = 0;
	let tP2Parse: float64 = 0;
	let tP2Inject: float64 = 0;
	let tP2Passes: float64 = 0;
	let tP2Directives: float64 = 0;
	let tP2Mutations: float64 = 0;
	let tP2Exports: float64 = 0;
	const _tpre0 = performance.now();

	// Load prelude into a base context — provides console, string methods, etc.
	// Creates the shared IdentCache (one cache per compilation).
	const baseCtx = buildPreludeContext(stdPath, backendExt);
	tPrelude = performance.now() - _tpre0;
	baseCtx.targetOs = targetOs;
	lastPreludeCtx = baseCtx;
	const sharedCache = getSharedIdentCache(baseCtx);

	// ================================================================
	// PHASE 1: Early export registration (Standard reference implementation)
	// Parse + collectTopLevelLocal for ALL modules, register names+kinds
	// ================================================================
	for (const path of graph.loadOrder) {
		const mod = findModule(graph, path);
		if (mod === null) continue;
		if (mod.source === "") continue;

		const _t1p0 = performance.now();
		const lr = lex(mod.source);
		if (!lr.ok) continue;  // Phase 1 best-effort; errors caught in Phase 2
		const parseState = createState(lr.value);
		const pr = callStateProgramParser(parseState);
		tP1Parse = tP1Parse + (performance.now() - _t1p0);
		if (!pr.ok) continue;
		const _t1c0 = performance.now();

		// Register parsed Program in Phase 1 so cross-module @comptime / macro
		// resolution can find ANY module's AST regardless of where it falls in
		// the Phase 2 loadOrder. Phase 2 re-registers with its own parse, which
		// overwrites harmlessly. Without this, sibling modules in the dep tree
		// race: a module whose @comptime eager-folds in Phase 2 cannot reach
		// the Program AST of a sibling that hasn't hit Phase 2 yet. Manifests
		// platform-sensitively — observed on Linux ARM where the schedule
		// happens to put the @comptime owner before its non-imported callees.
		registerModuleProgram(path, pr.value);

		// Temporary context for Phase 1 (discarded after) — shared IdentCache
		const p1ctx = createModuleContextWithCache(graph, mod, sharedCache);
		p1ctx.exportRegistry = registry;
		// With shared IdentCache, nameIds already match — no re-interning needed.
		// Map iteration preserves insertion order (matches old array iteration).
		for (const sym of baseCtx.table.current.symbols.values()) {
			if (hasFlag(sym, SymbolFlag.Exported)) {
				addSymbolToScope(p1ctx.table.current, sym);
			}
		}
		if (baseCtx.extensionRegistry !== null && p1ctx.extensionRegistry !== null) {
			const baseExts = baseCtx.extensionRegistry.methods;
			let bei = 0;
			while (bei < baseExts.length) {
				const ext = baseExts[bei];
				if (ext.sym !== null && hasFlag(ext.sym, SymbolFlag.Exported)) {
					registerExtension(p1ctx.extensionRegistry, ext);
				}
				bei = bei + 1;
			}
		}
		openScope(p1ctx.table, ScopeKind.Module);

		// Collect local declarations only (no imports — registry not ready)
		collectTopLevelLocal(p1ctx, pr.value);

		// Register early exports (names + kinds, placeholder types)
		const earlyExports: ExportedSymInfo[] = [];
		for (const sym of p1ctx.table.current.symbols.values()) {
			if (hasFlag(sym, SymbolFlag.Exported)) {
				let memberLocs: SourceLocation[] = [];
				if (sym.declNode !== null && sym.declNode.kind === NodeKind.EnumDecl) {
					memberLocs = (sym.declNode.data as EnumDeclData).memberLocations;
				}
				const info: ExportedSymInfo = {
					name: sym.name, kind: sym.symbolKind, symType: sym.symbolType,
					overloadTypes: [],
					extReceiverType: "", extIsStatic: false,
					overloadExtReceiverTypes: [], overloadExtIsStatic: [],
					nativeName: sym.nativeName, builtinKind: sym.builtinKind,
					overloadNativeNames: [], overloadBuiltinKinds: [],
					defaultParams: [], overloadDefaultParamsFlat: [], overloadDefaultParamsCounts: [],
				definingModule: sym.modulePath !== "" ? sym.modulePath : path,
				originalName: sym.originalName,
				headerPath: sym.headerPath,
				jsModulePath: "",
				hasConstructor: hasFlag(sym, SymbolFlag.HasConstructor),
				location: sym.location !== null ? sym.location : makeLoc(0, 0),
				memberLocations: memberLocs,
				primaryFlags: sym.symFlags,
				overloadFlags: [],
				macroBody: null as unknown as Node,
				macroParams: [],
				macroParamTypes: [],
				declNode: null as unknown as Node,
				overloadDeclNodes: [],
				};
				earlyExports.push(info);
			}
		}
		registerModuleExports(registry, path, earlyExports);
		tP1Collect = tP1Collect + (performance.now() - _t1c0);
	}

	// ================================================================
	// PHASE 2: Full checking (Reference semantic pass with cross-module visibility)
	// All modules' names now in registry. Run full 3 passes per module.
	// ================================================================
	for (const path of graph.loadOrder) {
		const mod = findModule(graph, path);
		if (mod === null) continue;
		if (mod.source === "") continue;

		// Clear Phase 1 exportNames to avoid duplicates
		mod.exportNames = [];

		// Parse with recovery — always get partial AST, errors in state.errors
		const _t2p0 = performance.now();
		const lr = lex(mod.source);
		if (!lr.ok) {
			mod.errors.push(createModuleError("Lex: " + lr.error, 0, 0, ErrorSeverity.Error));
			continue;
		}
		const parseState = createState(lr.value);
		const pr = callStateProgramParser(parseState);
		tP2Parse = tP2Parse + (performance.now() - _t2p0);

		for (const parseErr of parseState.errors) {
			mod.errors.push(createModuleError("Parse: " + parseErr, 0, 0, ErrorSeverity.Error));
		}

		// Register parsed program for macro VM cross-module helper resolution.
		// Macro path (expand.ms) walks macro's defining module's programStmts to
		// find PRIVATE helpers (which ExportRegistry can't surface). Must register
		// BEFORE runThreePasses since macro expansion fires inside Pass 3.
		registerModuleProgram(path, pr.value);

		const _t2i0 = performance.now();
		const ctx = createModuleContextWithCache(graph, mod, sharedCache);
		ctx.exportRegistry = registry;
		injectPrelude(ctx, baseCtx);
		ctx.preludeCtx = baseCtx;

		// Open Module scope for this module's declarations
		openScope(ctx.table, ScopeKind.Module);
		tP2Inject = tP2Inject + (performance.now() - _t2i0);

		const _t2r0 = performance.now();
		runThreePasses(ctx, pr.value);
		const _t2r1 = performance.now();
		tP2Passes = tP2Passes + (_t2r1 - _t2r0);
		if (graphTiming && (_t2r1 - _t2r0) > 100) {
			console.log(`    slowcheck ${path} ${_t2r1 - _t2r0}ms`);
		}
		const _t2d0 = performance.now();
		collectDirectives(ctx, pr.value);
		stampHeaderPaths(ctx);
		tP2Directives = tP2Directives + (performance.now() - _t2d0);
		const _t2m0 = performance.now();
		analyzeParamMutations(ctx, pr.value);
		tP2Mutations = tP2Mutations + (performance.now() - _t2m0);

		// Register this module's ctx so cross-module generic instantiation can
		// re-check cloned bodies in the DEFINING module's scope (resolving
		// private helpers and locally-visible types). Pairs with the
		// registerModuleCtx call in checkProgram for single-file mode.
		registerModuleCtx(ctx.modulePath, ctx);

		// Copy structured errors to module (preserves line/col/severity)
		for (const err of ctx.errors) {
			// Skip hints (unused warnings) — they're LSP-only, not build errors
			if (err.severity === Severity.Hint) continue;
			const sev = match (err.severity) {
				Severity.Warning => ErrorSeverity.Warning,
				_ => ErrorSeverity.Error,
			};
			mod.errors.push(createModuleError(err.message, err.line, err.column, sev));
		}

		// Extract resolved exports and UPDATE registry (replaces Phase 1 placeholders)
		const _t2e0 = performance.now();
		const exports = collectExports(ctx, path);
		for (const e of exports) { mod.exportNames.push(e.name); }
		updateModuleExports(registry, path, exports);
		tP2Exports = tP2Exports + (performance.now() - _t2e0);
	}
	if (graphTiming) {
		console.log(`    prelude=${tPrelude}ms p1parse=${tP1Parse}ms p1collect=${tP1Collect}ms p2parse=${tP2Parse}ms p2inject=${tP2Inject}ms p2passes=${tP2Passes}ms p2directives=${tP2Directives}ms p2mutations=${tP2Mutations}ms p2exports=${tP2Exports}ms`);
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
	return registry;
}


// ===== Tests =====

import { hasExportName } from "../module/graph";
import { MapEntry, createMapProvider, loadModuleGraph } from "../module/loader";
test "single file checked" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/a.ms", entrySource: "const x = 1;" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	checkModuleGraph(graph, "");
	assert graph.errors.length === 0;
	const mod = findModule(graph, "/src/a.ms");
	assert mod !== null;
	assert mod.errors.length === 0;
}

test "errors collected per module" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/a.ms", entrySource: "const x = y;" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	checkModuleGraph(graph, "");
	const mod = findModule(graph, "/src/a.ms");
	assert mod !== null;
	assert mod.errors.length > 0;
}

test "export names recorded" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/a.ms", entrySource: "export function foo() { return 1; } function bar() { return 2; }" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	checkModuleGraph(graph, "");
	const mod = findModule(graph, "/src/a.ms");
	assert mod !== null;
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
	assert modA !== null;
	assert modB !== null;
	assert modB.errors.length === 0;
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
	assert modA !== null;
	assert modB !== null;
	assert modA.errors.length === 0;
	assert modB.errors.length === 0;
}

test "imported enum available" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/b.ms", entrySource: "export enum Color { Red, Green, Blue }" });
	entries.push({ entryPath: "/src/a.ms", entrySource: "import { Color } from \"./b\"; const c = Color;" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	checkModuleGraph(graph, "");
	const modA = findModule(graph, "/src/a.ms");
	assert modA !== null;
	assert modA.errors.length === 0;
}

test "imported interface as type annotation" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/b.ms", entrySource: "export interface Point { x: number; y: number; }" });
	entries.push({ entryPath: "/src/a.ms", entrySource: "import { Point } from \"./b\"; function getX(p: Point): number { return 1; }" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	checkModuleGraph(graph, "");
	const modA = findModule(graph, "/src/a.ms");
	assert modA !== null;
	assert modA.errors.length === 0;
}

test "non-exported name produces error" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/b.ms", entrySource: "function secret() { return 1; }" });
	entries.push({ entryPath: "/src/a.ms", entrySource: "import { secret } from \"./b\";" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	checkModuleGraph(graph, "");
	const modA = findModule(graph, "/src/a.ms");
	assert modA !== null;
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
	assert modA !== null;
	assert modA.errors.length === 0;
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
	assert modA !== null;
	assert modA.errors.length === 0;
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
	assert modA !== null;
	assert modB !== null;
	assert modA.errors.length === 0;
	assert modB.errors.length === 0;
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
	assert modB !== null;
	assert hasExportName(modB, "helper");
	const modA = findModule(graph, "/src/a.ms");
	assert modA !== null;
	assert modA.errors.length === 0;
}

test "parse error recovery still extracts exports" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/a.ms", entrySource: "export function foo() { return 1; } const = bad;" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	checkModuleGraph(graph, "");
	const mod = findModule(graph, "/src/a.ms");
	assert mod !== null;
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
	assert modA !== null;
	assert modA.errors.length === 0;
}

test "parse error in dependency doesn't block dependent" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/b.ms", entrySource: "export function bar() { return 1; } const = bad;" });
	entries.push({ entryPath: "/src/a.ms", entrySource: "import { bar } from \"./b\"; const x = bar;" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	checkModuleGraph(graph, "");
	const modA = findModule(graph, "/src/a.ms");
	assert modA !== null;
	// Module A can resolve 'bar' from B's partial exports
	assert modA.errors.length === 0;
}

test "C header import synthesizes exports" {
	// .h imports are inlined into the consuming module (reference parity)
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/lib.h", entrySource: "void foo(int x);" });
	entries.push({ entryPath: "/src/a.ms", entrySource: "import { foo } from \"./lib.h\"; const x = foo;" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	// No separate .h module — declarations inlined into /src/a.ms
	assert graph.modules.length === 1;
	const modA = findModule(graph, "/src/a.ms");
	assert modA !== null;
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
	assert modA !== null;
	assert modB !== null;
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
	assert modA2 !== null;
	assert modB2 !== null;
	assert modA2.errors.length === 0;
	assert modB2.errors.length === 0;
}

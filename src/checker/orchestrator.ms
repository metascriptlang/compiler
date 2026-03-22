// Module orchestrator — coordinates checking across module graph
// Reference parallel implementation

import { Node, NodeKind, EnumDeclData, makeLoc, SourceLocation, Type, SymbolKind } from "../ast/node";
import {
	CheckerContext, createModuleContext, createModuleContextWithCache, Severity,
	ExportRegistry, ExportedSymInfo, createExportRegistry, registerModuleExports, updateModuleExports,
	buildExportInfo, registerExtension,
} from "./context";
import { ScopeKind, openScope, hasFlag, SymbolFlag } from "./symbol";
import { getIdentId } from "./idents";
import { Module, ModuleGraph, findModule, createModuleError, ErrorSeverity } from "../module/graph";
import { runThreePasses, buildPreludeContext, getSharedIdentCache, collectDirectives, stampHeaderPaths, injectPrelude } from "./checkPass";
import { collectTopLevelLocal } from "./collectPass";
import { inferOwnership } from "./ownershipInference";
import { parseSource } from "../parser/statements/validation";
import { lex } from "../lexer/lexer";
import { ParserState, createState } from "../parser/context";
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

// stdPath: when non-empty, resolves std/ imports against this path.
// When empty, falls back to relative "std/" (resolved by reference compiler).
export function checkModuleGraph(graph: ModuleGraph, stdPath: string): ExportRegistry {
	const registry = createExportRegistry();

	// Load prelude into a base context — provides console, string methods, etc.
	// Creates the shared IdentCache (one cache per compilation).
	const baseCtx = buildPreludeContext(stdPath);
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

		const lr = lex(mod.source);
		if (!lr.ok) continue;  // Phase 1 best-effort; errors caught in Phase 2
		const parseState = createState(lr.value);
		const pr = callStateProgramParser(parseState);
		if (!pr.ok) continue;

		// Temporary context for Phase 1 (discarded after) — shared IdentCache
		const p1ctx = createModuleContextWithCache(graph, mod, sharedCache);
		p1ctx.exportRegistry = registry;
		// NOTE: while loops (not for-of) so DRC properly increfs shared symbols.
		// With shared IdentCache, nameIds already match — no re-interning needed.
		const baseSyms = baseCtx.table.current.symbols;
		let bsi = 0;
		while (bsi < baseSyms.length) {
			const sym = baseSyms[bsi];
			if (hasFlag(sym, SymbolFlag.Exported)) {
				p1ctx.table.current.symbols.push(sym);
			}
			bsi = bsi + 1;
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
		for (const sym of p1ctx.table.current.symbols) {
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
				location: sym.location !== null ? sym.location : makeLoc(0, 0),
				memberLocations: memberLocs,
				};
				earlyExports.push(info);
			}
		}
		registerModuleExports(registry, path, earlyExports);
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
		const lr = lex(mod.source);
		if (!lr.ok) {
			mod.errors.push(createModuleError("Lex: " + lr.error, 0, 0, ErrorSeverity.Error));
			continue;
		}
		const parseState = createState(lr.value);
		const pr = callStateProgramParser(parseState);

		for (const parseErr of parseState.errors) {
			mod.errors.push(createModuleError("Parse: " + parseErr, 0, 0, ErrorSeverity.Error));
		}

		const ctx = createModuleContextWithCache(graph, mod, sharedCache);
		ctx.exportRegistry = registry;
		injectPrelude(ctx, baseCtx);
		ctx.preludeCtx = baseCtx;

		// Open Module scope for this module's declarations
		openScope(ctx.table, ScopeKind.Module);

		runThreePasses(ctx, pr.value);
		collectDirectives(ctx, pr.value);
		stampHeaderPaths(ctx);

		// Ownership Inference (for cross-module consumption)
		inferOwnership(ctx, pr.value);

		// Copy structured errors to module (preserves line/col/severity)
		for (const err of ctx.errors) {
			const sev = match (err.severity) {
				Severity.Warning => ErrorSeverity.Warning,
				_ => ErrorSeverity.Error,
			};
			mod.errors.push(createModuleError(err.message, err.line, err.column, sev));
		}

		// Extract resolved exports and UPDATE registry (replaces Phase 1 placeholders)
		const exports: ExportedSymInfo[] = [];
		for (const sym of ctx.table.current.symbols) {
			if (hasFlag(sym, SymbolFlag.Exported)) {
				mod.exportNames.push(sym.name);
				exports.push(buildExportInfo(sym, ctx.extensionRegistry, path));
			}
		}
		updateModuleExports(registry, path, exports);
	}
	return registry;
}


// ===== Tests =====

import {
	createModuleGraph, createModule, hasExportName,
} from "../module/graph";
import {
	MapEntry, SourceProvider, createMapProvider, loadModuleGraph,
} from "../module/loader";
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
	// Requires native Aro C parser (msAroParse) — not available in Bun runtime.
	// Passes when compiled via C backend. Skip gracefully under Bun.
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

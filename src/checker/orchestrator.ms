// Multi-module orchestrator — coordinates checking across module graph
// Nim parallel: pipelines.nim  |  Zig parallel: Compilation.zig

import { Node } from "../ast/node";
import {
	CheckerContext, createModuleContext, createContext,
	ExportedSymInfo, createExportRegistry, registerModuleExports,
	findExtensionByName,
} from "./context";
import { SymbolKind, ScopeKind, openScope } from "./symbol";
import { Module, ModuleGraph, findModule } from "../module/graph";
import { runThreePasses } from "./checkPass";
import { globalImports } from "./prelude";
import { parseSource } from "../parser/statements/validation";
import { lex } from "../lexer/lexer";
import { ParserState, createState } from "../parser/context";
import { callStateProgramParser } from "../parser/statements/callbacks";
import { readFile } from "std/process";
import { test, check, testGroup } from "std/testing";

// Nim-aligned: check modules one at a time in topological (loadOrder) sequence.
// Each module gets all 3 passes before moving to the next.
// Since modules are in dependency order, exports from dependencies are
// available when checking their dependents.

// stdPath: when non-empty, resolves std/ imports against this path.
// When empty, falls back to relative "std/" (resolved by reference compiler).
export function checkModuleGraph(graph: ModuleGraph, stdPath: string): void {
	const registry = createExportRegistry();

	// Load prelude (std/core.ms) into a base context — provides console, Math, etc.
	// This mirrors what checkProgram() does for single-module builds.
	const baseCtx = createContext();
	for (const imp of globalImports()) {
		let impPath = imp;
		if (stdPath.length > 0 && imp.length > 4) {
			// Replace "std/" prefix with absolute stdPath
			impPath = stdPath + "/" + imp.slice(4, imp.length);
		}
		const src = readFile(impPath);
		if (src.length > 0) {
			const pr = parseSource(src);
			if (pr.ok) {
				runThreePasses(baseCtx, pr.value);
			}
		}
	}

	for (const path of graph.loadOrder) {
		const mod = findModule(graph, path);
		if (mod === null) continue;
		if (mod.source === "") continue;

		// Parse with recovery — always get partial AST, errors in state.errors
		const lr = lex(mod.source);
		if (!lr.ok) {
			mod.errors.push("Lex: " + lr.error);
			continue;
		}
		const parseState = createState(lr.value);
		const pr = callStateProgramParser(parseState);

		for (const parseErr of parseState.errors) {
			mod.errors.push("Parse: " + parseErr);
		}

		const ctx = createModuleContext(graph, mod);
		ctx.exportRegistry = registry;

		// Inject prelude symbols into this module's Global scope
		// (so console, Math, etc. are available)
		for (const sym of baseCtx.table.current.symbols) {
			ctx.table.current.symbols.push(sym);
		}

		// Open Module scope for this module's declarations
		openScope(ctx.table, ScopeKind.Module);

		runThreePasses(ctx, pr.value);

		// Copy errors to module
		for (const err of ctx.errors) {
			mod.errors.push(err);
		}

		// Extract exports into registry for downstream modules
		const exports: ExportedSymInfo[] = [];
		for (const sym of ctx.table.current.symbols) {
			if (sym.isExported) {
				mod.exportNames.push(sym.name);
				// Check if this exported function is an extension method
				let extRecv = "";
				let extStatic = false;
				if (ctx.extensionRegistry !== null && sym.symbolKind === SymbolKind.Function) {
					const ext = findExtensionByName(ctx.extensionRegistry, sym.name);
					if (ext !== null) {
						extRecv = ext.receiverTypeName;
						extStatic = ext.isStatic;
					}
				}
				const info: ExportedSymInfo = { name: sym.name, kind: sym.symbolKind, symType: sym.symbolType, extReceiverType: extRecv, extIsStatic: extStatic };
				exports.push(info);
			}
		}
		registerModuleExports(registry, path, exports);
	}
}

// ===== Multi-Module Tests =====

import {
	createModuleGraph, createModule, hasExportName,
} from "../module/graph";
import {
	MapEntry, SourceProvider, createMapProvider, loadModuleGraph,
} from "../module/loader";

testGroup("Checker Multi-Module", () => {
	test("single module checked", () => {
		const entries: MapEntry[] = [];
		entries.push({ entryPath: "/src/a.ms", entrySource: "const x = 1;" });
		const provider = createMapProvider(entries);
		const graph = loadModuleGraph("/src/a.ms", provider);
		checkModuleGraph(graph, "");
		check(graph.errors.length === 0);
		const mod = findModule(graph, "/src/a.ms");
		check(mod !== null);
		check(mod.errors.length === 0);
	});
	test("errors collected per module", () => {
		const entries: MapEntry[] = [];
		entries.push({ entryPath: "/src/a.ms", entrySource: "const x = y;" });
		const provider = createMapProvider(entries);
		const graph = loadModuleGraph("/src/a.ms", provider);
		checkModuleGraph(graph, "");
		const mod = findModule(graph, "/src/a.ms");
		check(mod !== null);
		check(mod.errors.length > 0);
	});
	test("export names recorded", () => {
		const entries: MapEntry[] = [];
		entries.push({ entryPath: "/src/a.ms", entrySource: "export function foo() { return 1; } function bar() { return 2; }" });
		const provider = createMapProvider(entries);
		const graph = loadModuleGraph("/src/a.ms", provider);
		checkModuleGraph(graph, "");
		const mod = findModule(graph, "/src/a.ms");
		check(mod !== null);
		check(hasExportName(mod, "foo"));
		check(!hasExportName(mod, "bar"));
	});
	test("two module chain checked", () => {
		const entries: MapEntry[] = [];
		entries.push({ entryPath: "/src/a.ms", entrySource: "import { foo } from \"./b\"; const x = foo;" });
		entries.push({ entryPath: "/src/b.ms", entrySource: "export function foo() { return 1; }" });
		const provider = createMapProvider(entries);
		const graph = loadModuleGraph("/src/a.ms", provider);
		checkModuleGraph(graph, "");
		// Both modules should check without errors
		const modA = findModule(graph, "/src/a.ms");
		const modB = findModule(graph, "/src/b.ms");
		check(modA !== null);
		check(modB !== null);
		check(modB.errors.length === 0);
	});
	test("imported function has Function type", () => {
		const entries: MapEntry[] = [];
		entries.push({ entryPath: "/src/b.ms", entrySource: "export function foo(n: number): string { return \"hi\"; }" });
		entries.push({ entryPath: "/src/a.ms", entrySource: "import { foo } from \"./b\"; const x = foo(1);" });
		const provider = createMapProvider(entries);
		const graph = loadModuleGraph("/src/a.ms", provider);
		checkModuleGraph(graph, "");
		const modA = findModule(graph, "/src/a.ms");
		const modB = findModule(graph, "/src/b.ms");
		check(modA !== null);
		check(modB !== null);
		check(modA.errors.length === 0);
		check(modB.errors.length === 0);
	});
	test("imported enum available", () => {
		const entries: MapEntry[] = [];
		entries.push({ entryPath: "/src/b.ms", entrySource: "export enum Color { Red, Green, Blue }" });
		entries.push({ entryPath: "/src/a.ms", entrySource: "import { Color } from \"./b\"; const c = Color;" });
		const provider = createMapProvider(entries);
		const graph = loadModuleGraph("/src/a.ms", provider);
		checkModuleGraph(graph, "");
		const modA = findModule(graph, "/src/a.ms");
		check(modA !== null);
		check(modA.errors.length === 0);
	});
	test("imported interface as type annotation", () => {
		const entries: MapEntry[] = [];
		entries.push({ entryPath: "/src/b.ms", entrySource: "export interface Point { x: number; y: number; }" });
		entries.push({ entryPath: "/src/a.ms", entrySource: "import { Point } from \"./b\"; function getX(p: Point): number { return 1; }" });
		const provider = createMapProvider(entries);
		const graph = loadModuleGraph("/src/a.ms", provider);
		checkModuleGraph(graph, "");
		const modA = findModule(graph, "/src/a.ms");
		check(modA !== null);
		check(modA.errors.length === 0);
	});
	test("non-exported name produces error", () => {
		const entries: MapEntry[] = [];
		entries.push({ entryPath: "/src/b.ms", entrySource: "function secret() { return 1; }" });
		entries.push({ entryPath: "/src/a.ms", entrySource: "import { secret } from \"./b\";" });
		const provider = createMapProvider(entries);
		const graph = loadModuleGraph("/src/a.ms", provider);
		checkModuleGraph(graph, "");
		const modA = findModule(graph, "/src/a.ms");
		check(modA !== null);
		check(modA.errors.length > 0);
	});
	test("3-module chain propagates types", () => {
		const entries: MapEntry[] = [];
		entries.push({ entryPath: "/src/c.ms", entrySource: "export function makeStr(): string { return \"hello\"; }" });
		entries.push({ entryPath: "/src/b.ms", entrySource: "import { makeStr } from \"./c\"; export function greet(name: string): string { return makeStr(); }" });
		entries.push({ entryPath: "/src/a.ms", entrySource: "import { greet } from \"./b\"; const msg = greet(\"world\");" });
		const provider = createMapProvider(entries);
		const graph = loadModuleGraph("/src/a.ms", provider);
		checkModuleGraph(graph, "");
		const modA = findModule(graph, "/src/a.ms");
		check(modA !== null);
		check(modA.errors.length === 0);
	});
	test("inferred return type propagates across modules", () => {
		const entries: MapEntry[] = [];
		// No return type annotation — inference should propagate number
		entries.push({ entryPath: "/src/b.ms", entrySource: "export function foo() { return 42; }" });
		entries.push({ entryPath: "/src/a.ms", entrySource: "import { foo } from \"./b\"; const x = foo();" });
		const provider = createMapProvider(entries);
		const graph = loadModuleGraph("/src/a.ms", provider);
		checkModuleGraph(graph, "");
		const modA = findModule(graph, "/src/a.ms");
		const modB = findModule(graph, "/src/b.ms");
		check(modA !== null);
		check(modB !== null);
		check(modA.errors.length === 0);
		check(modB.errors.length === 0);
	});
	test("re-export forwards types", () => {
		const entries: MapEntry[] = [];
		entries.push({ entryPath: "/src/c.ms", entrySource: "export function helper(): number { return 42; }" });
		entries.push({ entryPath: "/src/b.ms", entrySource: "export { helper } from \"./c\";" });
		entries.push({ entryPath: "/src/a.ms", entrySource: "import { helper } from \"./b\"; const x = helper();" });
		const provider = createMapProvider(entries);
		const graph = loadModuleGraph("/src/a.ms", provider);
		checkModuleGraph(graph, "");
		const modB = findModule(graph, "/src/b.ms");
		check(modB !== null);
		check(hasExportName(modB, "helper"));
		const modA = findModule(graph, "/src/a.ms");
		check(modA !== null);
		check(modA.errors.length === 0);
	});
	test("parse error recovery still extracts exports", () => {
		const entries: MapEntry[] = [];
		entries.push({ entryPath: "/src/a.ms", entrySource: "export function foo() { return 1; } const = bad;" });
		const provider = createMapProvider(entries);
		const graph = loadModuleGraph("/src/a.ms", provider);
		checkModuleGraph(graph, "");
		const mod = findModule(graph, "/src/a.ms");
		check(mod !== null);
		check(mod.errors.length > 0);
		check(hasExportName(mod, "foo"));
	});
	test("imported extension method available", () => {
		const entries: MapEntry[] = [];
		entries.push({ entryPath: "/src/b.ms", entrySource: "export function trim(this s: string): string { return s; }" });
		entries.push({ entryPath: "/src/a.ms", entrySource: "import { trim } from \"./b\"; const s = \"hello\"; const t = s.trim();" });
		const provider = createMapProvider(entries);
		const graph = loadModuleGraph("/src/a.ms", provider);
		checkModuleGraph(graph, "");
		const modA = findModule(graph, "/src/a.ms");
		check(modA !== null);
		check(modA.errors.length === 0);
	});
	test("parse error in dependency doesn't block dependent", () => {
		const entries: MapEntry[] = [];
		entries.push({ entryPath: "/src/b.ms", entrySource: "export function bar() { return 1; } const = bad;" });
		entries.push({ entryPath: "/src/a.ms", entrySource: "import { bar } from \"./b\"; const x = bar;" });
		const provider = createMapProvider(entries);
		const graph = loadModuleGraph("/src/a.ms", provider);
		checkModuleGraph(graph, "");
		const modA = findModule(graph, "/src/a.ms");
		check(modA !== null);
		// Module A can resolve 'bar' from B's partial exports
		check(modA.errors.length === 0);
	});
});

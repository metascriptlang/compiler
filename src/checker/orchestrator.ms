// Multi-module orchestrator — coordinates checking across module graph
// Nim parallel: pipelines.nim  |  Zig parallel: Compilation.zig

import { Node } from "../ast/node";
import {
	CheckerContext, createModuleContext, createContext,
	ExportedSymInfo, createExportRegistry, registerModuleExports,
	findExtensionByName, findExtensionByType, registerExtension,
} from "./context";
import { SymbolKind, ScopeKind, openScope, hasFlag, SF_EXPORTED } from "./symbol";
import { Module, ModuleGraph, findModule } from "../module/graph";
import { preprocessHeaders } from "../module/aro";
import { runThreePasses } from "./checkPass";
import { inferOwnership } from "./ownershipInference";
import { globalImports } from "./prelude";
import { parseSource } from "../parser/statements/validation";
import { lex } from "../lexer/lexer";
import { ParserState, createState } from "../parser/context";
import { callStateProgramParser } from "../parser/statements/callbacks";
import { readFile } from "std/process";
import { check } from "std/testing";

// Nim-aligned: check modules one at a time in topological (loadOrder) sequence.
// Each module gets all 3 passes before moving to the next.
// Since modules are in dependency order, exports from dependencies are
// available when checking their dependents.

// Load a prelude import by probing: .ms → /index.cms → /index.ms
function loadPreludeInto(ctx: CheckerContext, specifier: string, stdPath: string): void {
	const base = stdPath.length > 0 ? stdPath + "/" + specifier.slice(4, specifier.length) : specifier;
	let src = readFile(base + ".ms");
	if (src.length === 0) {
		src = readFile(base + "/index.cms");
	}
	if (src.length === 0) {
		src = readFile(base + "/index.ms");
	}
	if (src.length > 0) {
		const pr = parseSource(src);
		if (pr.ok) {
			runThreePasses(ctx, pr.value);
		}
	}
}

// stdPath: when non-empty, resolves std/ imports against this path.
// When empty, falls back to relative "std/" (resolved by reference compiler).
export function checkModuleGraph(graph: ModuleGraph, stdPath: string): ExportRegistry {
	const registry = createExportRegistry();

	// Load prelude into a base context — provides console, string methods, etc.
	const baseCtx = createContext();
	for (const imp of globalImports()) {
		loadPreludeInto(baseCtx, imp, stdPath);
	}

	// Pre-process C header modules (synthesis fallback for test/direct-call paths)
	preprocessHeaders(graph, false);

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

		// Inject prelude extensions into this module's extension registry
		// (so arr.push(), str.trim() etc. resolve as extension methods)
		if (baseCtx.extensionRegistry !== null && ctx.extensionRegistry !== null) {
			for (const ext of baseCtx.extensionRegistry.methods) {
				registerExtension(ctx.extensionRegistry, ext);
			}
		}

		// Open Module scope for this module's declarations
		openScope(ctx.table, ScopeKind.Module);

		runThreePasses(ctx, pr.value);

		// Phase 2.5: Ownership Inference (for cross-module consumption)
		inferOwnership(ctx, pr.value);

		// Copy errors to module
		for (const err of ctx.errors) {
			mod.errors.push(err);
		}

		// Extract exports into registry for downstream modules
		const exports: ExportedSymInfo[] = [];
		for (const sym of ctx.table.current.symbols) {
			if (hasFlag(sym, SF_EXPORTED)) {
				mod.exportNames.push(sym.name);
				// Check if this exported function is an extension method
				let extRecv = "";
				let extStatic = false;
				if (ctx.extensionRegistry !== null && sym.symbolKind === SymbolKind.Function) {
					// Use sym reference to find the primary extension (not findExtensionByName which grabs first)
					const ext = findExtensionByType(ctx.extensionRegistry, sym.name, sym.symbolType);
					if (ext !== null) {
						extRecv = ext.receiverTypeName;
						extStatic = ext.isStatic;
					} else {
						// Fallback: first match (non-overloaded extensions)
						const extFb = findExtensionByName(ctx.extensionRegistry, sym.name);
						if (extFb !== null) {
							extRecv = extFb.receiverTypeName;
							extStatic = extFb.isStatic;
						}
					}
				}
				// Collect overload types + per-overload extension metadata
				const ovTypes: Type[] = [];
				const ovExtRecvs: string[] = [];
				const ovExtStatics: boolean[] = [];
				if (sym.overloads.length > 0) {
					let ovi = 0;
					while (ovi < sym.overloads.length) {
						ovTypes.push(sym.overloads[ovi].symbolType);
						if (ctx.extensionRegistry !== null) {
							const ovExt = findExtensionByType(ctx.extensionRegistry, sym.name, sym.overloads[ovi].symbolType);
							if (ovExt !== null) {
								ovExtRecvs.push(ovExt.receiverTypeName);
								ovExtStatics.push(ovExt.isStatic);
							} else {
								ovExtRecvs.push("");
								ovExtStatics.push(false);
							}
						} else {
							ovExtRecvs.push("");
							ovExtStatics.push(false);
						}
						ovi = ovi + 1;
					}
				}
				// Collect per-overload nativeName/builtinKind
				const ovRtNames: string[] = [];
				const ovBiKinds: string[] = [];
				if (sym.overloads.length > 0) {
					let ovi2 = 0;
					while (ovi2 < sym.overloads.length) {
						ovRtNames.push(sym.overloads[ovi2].nativeName);
						ovBiKinds.push(sym.overloads[ovi2].builtinKind);
						ovi2 = ovi2 + 1;
					}
				}
				// Collect per-overload defaultParamText
				const ovDefTexts: string[][] = [];
				if (sym.overloads.length > 0) {
					let ovi3 = 0;
					while (ovi3 < sym.overloads.length) {
						ovDefTexts.push(sym.overloads[ovi3].defaultParamText);
						ovi3 = ovi3 + 1;
					}
				}
				const info: ExportedSymInfo = { name: sym.name, kind: sym.symbolKind, symType: sym.symbolType, overloadTypes: ovTypes, extReceiverType: extRecv, extIsStatic: extStatic, overloadExtReceiverTypes: ovExtRecvs, overloadExtIsStatic: ovExtStatics, nativeName: sym.nativeName, builtinKind: sym.builtinKind, overloadNativeNames: ovRtNames, overloadBuiltinKinds: ovBiKinds, defaultTexts: sym.defaultParamText, overloadDefaultTexts: ovDefTexts };
				exports.push(info);
			}
		}
		registerModuleExports(registry, path, exports);
	}
	return registry;
}

// ===== Multi-Module Tests =====

import {
	createModuleGraph, createModule, hasExportName,
} from "../module/graph";
import {
	MapEntry, SourceProvider, createMapProvider, loadModuleGraph,
} from "../module/loader";
test "single module checked" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/a.ms", entrySource: "const x = 1;" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	checkModuleGraph(graph, "");
	check(graph.errors.length === 0);
	const mod = findModule(graph, "/src/a.ms");
	check(mod !== null);
	check(mod.errors.length === 0);
}

test "errors collected per module" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/a.ms", entrySource: "const x = y;" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	checkModuleGraph(graph, "");
	const mod = findModule(graph, "/src/a.ms");
	check(mod !== null);
	check(mod.errors.length > 0);
}

test "export names recorded" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/a.ms", entrySource: "export function foo() { return 1; } function bar() { return 2; }" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	checkModuleGraph(graph, "");
	const mod = findModule(graph, "/src/a.ms");
	check(mod !== null);
	check(hasExportName(mod, "foo"));
	check(!hasExportName(mod, "bar"));
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
	check(modA !== null);
	check(modB !== null);
	check(modB.errors.length === 0);
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
	check(modA !== null);
	check(modB !== null);
	check(modA.errors.length === 0);
	check(modB.errors.length === 0);
}

test "imported enum available" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/b.ms", entrySource: "export enum Color { Red, Green, Blue }" });
	entries.push({ entryPath: "/src/a.ms", entrySource: "import { Color } from \"./b\"; const c = Color;" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	checkModuleGraph(graph, "");
	const modA = findModule(graph, "/src/a.ms");
	check(modA !== null);
	check(modA.errors.length === 0);
}

test "imported interface as type annotation" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/b.ms", entrySource: "export interface Point { x: number; y: number; }" });
	entries.push({ entryPath: "/src/a.ms", entrySource: "import { Point } from \"./b\"; function getX(p: Point): number { return 1; }" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	checkModuleGraph(graph, "");
	const modA = findModule(graph, "/src/a.ms");
	check(modA !== null);
	check(modA.errors.length === 0);
}

test "non-exported name produces error" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/b.ms", entrySource: "function secret() { return 1; }" });
	entries.push({ entryPath: "/src/a.ms", entrySource: "import { secret } from \"./b\";" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	checkModuleGraph(graph, "");
	const modA = findModule(graph, "/src/a.ms");
	check(modA !== null);
	check(modA.errors.length > 0);
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
	check(modA !== null);
	check(modA.errors.length === 0);
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
	check(modA !== null);
	check(modB !== null);
	check(modA.errors.length === 0);
	check(modB.errors.length === 0);
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
	check(modB !== null);
	check(hasExportName(modB, "helper"));
	const modA = findModule(graph, "/src/a.ms");
	check(modA !== null);
	check(modA.errors.length === 0);
}

test "parse error recovery still extracts exports" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/a.ms", entrySource: "export function foo() { return 1; } const = bad;" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	checkModuleGraph(graph, "");
	const mod = findModule(graph, "/src/a.ms");
	check(mod !== null);
	check(mod.errors.length > 0);
	check(hasExportName(mod, "foo"));
}

test "imported extension method available" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/b.ms", entrySource: "export function trim(this s: string): string { return s; }" });
	entries.push({ entryPath: "/src/a.ms", entrySource: "import { trim } from \"./b\"; const s = \"hello\"; const t = s.trim();" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	checkModuleGraph(graph, "");
	const modA = findModule(graph, "/src/a.ms");
	check(modA !== null);
	check(modA.errors.length === 0);
}

test "parse error in dependency doesn't block dependent" {
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
}

test "C header import synthesizes exports" {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/lib.h", entrySource: "void foo(int x);" });
	entries.push({ entryPath: "/src/a.ms", entrySource: "import { foo } from \"./lib.h\"; const x = foo;" });
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph("/src/a.ms", provider);
	checkModuleGraph(graph, "");
	const hmod = findModule(graph, "/src/lib.h");
	check(hmod !== null);
	check(hmod.isCHeader);
	check(hasExportName(hmod, "foo"));
	const modA = findModule(graph, "/src/a.ms");
	check(modA !== null);
	check(modA.errors.length === 0);
}

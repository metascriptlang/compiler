// E2E Test Helpers — full pipeline: MetaScript source → C/JS output
//
// All tests use the same graph-based pipeline as compile.ms.
// compileToC/compileToJS: single source (1-module graph internally).
// compileProjectToC/compileProjectToJS: multiple source files with imports.

import { parseSource } from "../parser/statements/validation";
import "../parser/statements/core";
import { resetAllSideChannels } from "../parser/context";
import { checkProgramWithRegistry } from "../checker/checkPass";
import { checkModuleGraph, getPreludeContext } from "../checker/orchestrator";
import { computeAliveSet } from "../checker/reachability";
import { hasErrors, CheckerError } from "../checker/context";
import { monomorphizeProgram } from "../monomorphize/collect";
import { expandMacros } from "../compiler/meta/expand";
import { validateTypedAST } from "../checker/validate";
import { transformProgram } from "../transform/index";
import { transformForNative } from "../transform/native/index";
import { createTransformContextWithChecker } from "../transform/context";
import { analyzeProgram } from "../analyzer/index";
import { generateCModule, genProjectDispatcher } from "../codegen/c/index";
import { AliveSet, createAliveSet } from "../codegen/c/context";
import { generateJS } from "../codegen/js/jsgen";
import { MapEntry, createMapProvider, loadModuleGraph, loadModuleGraphWithConfig, canonicalModulePath } from "../module/loader";
import { createDefaultConfig, Backend } from "../module/resolver";
import { resolveRuntimeDir } from "../utils/path";
import { join } from "std/fs/path";
import { Module, ModuleGraph, findModule } from "../module/graph";
import { Node } from "../ast/node";
// Side-effect import — registers the Raiser-VM-backed macro evaluator so
// macros encountered in compileToC sources actually expand. Without this,
// any macro invocation fails check with "evaluator unavailable".
import "../codegen/raiser/eval";

export { MapEntry } from "../module/loader";

type CompileResult = Result<string, string>;

function collectErrors(errors: CheckerError[], prefix: string): string {
	let msg = prefix;
	for (const err of errors) {
		msg = msg + " " + err.message;
	}
	return msg;
}

// ===== Single-source compilation (1-module graph) =====

// Full C pipeline: parse → check → monomorphize → validate → transform → native → analyze → codegen
export function compileToC(source: string): CompileResult {
	resetAllSideChannels();
	// loadModule canonicalizes the entry path to absolute (loader.ms:393) —
	// findModule uses string equality, so we must canonicalize here too.
	const modPath = canonicalModulePath("test/e2e.ms");
	const entries: MapEntry[] = [{ entryPath: modPath, entrySource: source }];
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph(modPath, provider);

	const registry = checkModuleGraph(graph, "");
	const preludeCtx = getPreludeContext();

	const mod = findModule(graph, modPath);
	if (mod === null) return Result.err("module not found");

	const pr = parseSource(mod.source);
	if (!pr.ok) return Result.err(`parse: ${pr.error}`);

	const checkerCtx = checkProgramWithRegistry(pr.value, registry, graph, mod, preludeCtx);
	if (hasErrors(checkerCtx)) return Result.err(collectErrors(checkerCtx.errors, "check:"));

	const monoed = monomorphizeProgram(pr.value, checkerCtx);

	validateTypedAST(checkerCtx, monoed);
	if (hasErrors(checkerCtx)) return Result.err(collectErrors(checkerCtx.errors, "validate:"));

	// SERIALIZE A2: program-wide macro expansion runs after mono in main pipeline
	// (compile.ms:934). Mirror it here so module-top SpliceMany splices fire.
	const macroExpanded = expandMacros(monoed, checkerCtx);

	const transformed = transformProgram(macroExpanded, checkerCtx, false);
	const nativeCtx = createTransformContextWithChecker(checkerCtx);
	const nativeTransformed = transformForNative(transformed, nativeCtx);
	const analyzed = analyzeProgram(nativeTransformed, checkerCtx);
	const aliveSet = createAliveSet();
	return Result.ok(generateCModule(analyzed, checkerCtx, modPath, aliveSet, false, false));
}

// Like compileToC but with std/ library resolution enabled (stdPath from the
// repo root), so sources may `import { Node } from "std/meta"` etc. The plain
// compileToC keeps stdPath empty — std imports resolve only via prelude there.
export function compileToCWithStd(source: string): CompileResult {
	resetAllSideChannels();
	const modPath = canonicalModulePath("test/e2e.ms");
	const entries: MapEntry[] = [{ entryPath: modPath, entrySource: source }];
	const provider = createMapProvider(entries);
	// Map provider alone never touches disk — std modules must load from the
	// real filesystem (entries win first, so the in-memory entry still shadows).
	provider.useFileSystem = true;
	const root = resolveRuntimeDir();
	const stdPath = root !== "" ? join(root, "std") : "std";
	const config = createDefaultConfig(Backend.C, stdPath);
	const graph = loadModuleGraphWithConfig(modPath, provider, config);

	const registry = checkModuleGraph(graph, stdPath);
	const preludeCtx = getPreludeContext();

	const mod = findModule(graph, modPath);
	if (mod === null) return Result.err("module not found");

	const pr = parseSource(mod.source);
	if (!pr.ok) return Result.err(`parse: ${pr.error}`);

	const checkerCtx = checkProgramWithRegistry(pr.value, registry, graph, mod, preludeCtx);
	if (hasErrors(checkerCtx)) return Result.err(collectErrors(checkerCtx.errors, "check:"));

	const monoed = monomorphizeProgram(pr.value, checkerCtx);

	validateTypedAST(checkerCtx, monoed);
	if (hasErrors(checkerCtx)) return Result.err(collectErrors(checkerCtx.errors, "validate:"));

	const macroExpanded = expandMacros(monoed, checkerCtx);

	const transformed = transformProgram(macroExpanded, checkerCtx, false);
	const nativeCtx = createTransformContextWithChecker(checkerCtx);
	const nativeTransformed = transformForNative(transformed, nativeCtx);
	const analyzed = analyzeProgram(nativeTransformed, checkerCtx);
	const aliveSet = createAliveSet();
	return Result.ok(generateCModule(analyzed, checkerCtx, modPath, aliveSet, false, false));
}

// Full JS pipeline: parse → check → transform(jsBackend=true) → codegen
export function compileToJS(source: string): CompileResult {
	resetAllSideChannels();
	const modPath = canonicalModulePath("test/e2e.ms");
	const entries: MapEntry[] = [{ entryPath: modPath, entrySource: source }];
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph(modPath, provider);

	const registry = checkModuleGraph(graph, "");
	const preludeCtx = getPreludeContext();

	const mod = findModule(graph, modPath);
	if (mod === null) return Result.err("module not found");

	const pr = parseSource(mod.source);
	if (!pr.ok) return Result.err(`parse: ${pr.error}`);

	const checkerCtx = checkProgramWithRegistry(pr.value, registry, graph, mod, preludeCtx);
	if (hasErrors(checkerCtx)) return Result.err(collectErrors(checkerCtx.errors, "check:"));

	const transformed = transformProgram(pr.value, checkerCtx, true);
	return Result.ok(generateJS(transformed, []));
}

// ===== Project compilation (multiple source files with imports) =====

// Compile project to C — same pipeline as compile.ms:
// checkModuleGraph (2-phase) → computeAliveSet (global DCE) → per-module codegen
export function compileProjectToC(entries: MapEntry[], entryPath: string): string {
	resetAllSideChannels();
	// Map-provider keys must be canonical: loadModule canonicalizes every path and
	// relative imports resolve to absolute, so a raw key like "src/doc.ms" never
	// matches the "/abs/.../src/doc.ms" lookup and the module silently fails to load
	// (its imports go unresolved, its decls get dropped). Canonicalizing here also
	// aligns entryPath with graph.loadOrder so DCE Root 5 (entry-module exports) fires.
	// Mirrors compileToC, which canonicalizes its single key the same way.
	const canonEntries: MapEntry[] = [];
	for (const e of entries) {
		canonEntries.push({ entryPath: canonicalModulePath(e.entryPath), entrySource: e.entrySource });
	}
	entryPath = canonicalModulePath(entryPath);
	const provider = createMapProvider(canonEntries);
	const graph = loadModuleGraph(entryPath, provider);
	if (graph.errors.length > 0) {
		let msg = "ERROR: graph:";
		for (const e of graph.errors) {
			msg = `${msg} ${e}`;
		}
		return msg;
	}

	const registry = checkModuleGraph(graph, "");
	const preludeCtx = getPreludeContext();

	// Compute global alive set for DCE (same as compile.ms:345)
	const monoed_programs: Node[] = [];
	const monoed_paths: string[] = [];
	for (const modPath of graph.loadOrder) {
		const mod = findModule(graph, modPath);
		if (mod === null) continue;
		const pr = parseSource(mod.source);
		if (!pr.ok) continue;
		const ctx = checkProgramWithRegistry(pr.value, registry, graph, mod, preludeCtx);
		ctx.errors = [];
		const monoed = monomorphizeProgram(pr.value, ctx);
		monoed_programs.push(monoed);
		monoed_paths.push(modPath);
	}
	const aliveSet = computeAliveSet(monoed_programs, monoed_paths, entryPath, false);

	// Full pipeline per module (same as compile.ms:358-411)
	let combined = "";
	for (const modPath of graph.loadOrder) {
		const mod = findModule(graph, modPath);
		if (mod === null) continue;

		const pr = parseSource(mod.source);
		if (!pr.ok) return `ERROR: parse [${modPath}]: ${pr.error}`;

		const ctx = checkProgramWithRegistry(pr.value, registry, graph, mod, preludeCtx);
		if (hasErrors(ctx)) {
			let msg = `ERROR: check [${modPath}]:`;
			for (const err of ctx.errors) {
				msg = `${msg} ${err.message}`;
			}
			return msg;
		}

		const monoed = monomorphizeProgram(pr.value, ctx);
		validateTypedAST(ctx, monoed);
		if (hasErrors(ctx)) {
			ctx.errors = [];
		}

		const transformed = transformProgram(monoed, ctx, false);
		const nativeCtx = createTransformContextWithChecker(ctx);
		const nativeTransformed = transformForNative(transformed, nativeCtx);
		const analyzed = analyzeProgram(nativeTransformed, ctx);
		combined = combined + generateCModule(analyzed, ctx, modPath, aliveSet, false, false);
	}

	const dispatcher = genProjectDispatcher(graph.loadOrder, entryPath, false, "void", "", false);
	return `${combined}\n${dispatcher}`;
}

// Compile project to JS
export function compileProjectToJS(entries: MapEntry[], entryPath: string): string {
	resetAllSideChannels();
	// Canonicalize map keys so relative imports resolve — see compileProjectToC.
	const canonEntries: MapEntry[] = [];
	for (const e of entries) {
		canonEntries.push({ entryPath: canonicalModulePath(e.entryPath), entrySource: e.entrySource });
	}
	entryPath = canonicalModulePath(entryPath);
	const provider = createMapProvider(canonEntries);
	const graph = loadModuleGraph(entryPath, provider);
	if (graph.errors.length > 0) {
		let msg = "ERROR: graph:";
		for (const e of graph.errors) {
			msg = `${msg} ${e}`;
		}
		return msg;
	}

	const registry = checkModuleGraph(graph, "");
	const preludeCtx = getPreludeContext();

	let combined = "";
	for (const modPath of graph.loadOrder) {
		const mod = findModule(graph, modPath);
		if (mod === null) continue;

		const pr = parseSource(mod.source);
		if (!pr.ok) return `ERROR: parse [${modPath}]: ${pr.error}`;

		const ctx = checkProgramWithRegistry(pr.value, registry, graph, mod, preludeCtx);
		if (hasErrors(ctx)) {
			let msg = `ERROR: check [${modPath}]:`;
			for (const err of ctx.errors) {
				msg = `${msg} ${err.message}`;
			}
			return msg;
		}

		const transformed = transformProgram(pr.value, ctx, true);
		combined = combined + generateJS(transformed, []);
	}

	return combined;
}

test "contains basic" {
	assert "hello world".contains("world");
	assert "hello world".contains("hello");
	assert !"hello".contains("world");
	assert "abc".contains("");
	assert !"".contains("abc");
}

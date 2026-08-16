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
import { hasErrors, CheckerError, CheckerContext, ExportRegistry } from "../checker/context";
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
import { Node, ProgramData } from "../ast/node";
import { drainPendingInstances } from "../checker/instantiate";
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
	const preAnErrors = checkerCtx.errors.length;
	const analyzed = analyzeProgram(nativeTransformed, checkerCtx);
	if (checkerCtx.errors.length > preAnErrors) return Result.err(collectErrors(checkerCtx.errors, "analyze:"));
	const aliveSet = createAliveSet();
	const preCgErrors = checkerCtx.errors.length;
	const cCode = generateCModule(analyzed, checkerCtx, modPath, aliveSet, false, false);
	if (checkerCtx.errors.length > preCgErrors) return Result.err(collectErrors(checkerCtx.errors, "codegen:"));
	return Result.ok(cCode);
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
	const preAnErrors = checkerCtx.errors.length;
	const analyzed = analyzeProgram(nativeTransformed, checkerCtx);
	if (checkerCtx.errors.length > preAnErrors) return Result.err(collectErrors(checkerCtx.errors, "analyze:"));
	const aliveSet = createAliveSet();
	const preCgErrors = checkerCtx.errors.length;
	const cCode = generateCModule(analyzed, checkerCtx, modPath, aliveSet, false, false);
	if (checkerCtx.errors.length > preCgErrors) return Result.err(collectErrors(checkerCtx.errors, "codegen:"));
	return Result.ok(cCode);
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

	const dispatcher = genProjectDispatcher(graph.loadOrder, entryPath, "", false);
	return `${combined}\n${dispatcher}`;
}

function isEntryPath(entries: MapEntry[], modPath: string): boolean {
	for (const e of entries) {
		if (e.entryPath === modPath) return true;
	}
	return false;
}

// Like compileProjectToC but with std/ resolution enabled (see compileToCWithStd).
// Codegen covers only the in-memory entry modules — std modules load for
// checking/macros but are not emitted, mirroring compileToCWithStd. expandMacros
// runs post-mono in BOTH loops so macro-emitted callees (e.g. bindSym targets)
// reach the alive set.
export function compileProjectToCWithStd(entries: MapEntry[], entryPath: string): string {
	resetAllSideChannels();
	const canonEntries: MapEntry[] = [];
	for (const e of entries) {
		canonEntries.push({ entryPath: canonicalModulePath(e.entryPath), entrySource: e.entrySource });
	}
	entryPath = canonicalModulePath(entryPath);
	const provider = createMapProvider(canonEntries);
	provider.useFileSystem = true;
	const root = resolveRuntimeDir();
	const stdPath = root !== "" ? join(root, "std") : "std";
	const config = createDefaultConfig(Backend.C, stdPath);
	const graph = loadModuleGraphWithConfig(entryPath, provider, config);
	if (graph.errors.length > 0) {
		let msg = "ERROR: graph:";
		for (const e of graph.errors) {
			msg = `${msg} ${e}`;
		}
		return msg;
	}

	const registry = checkModuleGraph(graph, stdPath);
	const preludeCtx = getPreludeContext();

	const monoed_programs: Node[] = [];
	const monoed_paths: string[] = [];
	for (const modPath of graph.loadOrder) {
		if (!isEntryPath(canonEntries, modPath)) continue;
		const mod = findModule(graph, modPath);
		if (mod === null) continue;
		const pr = parseSource(mod.source);
		if (!pr.ok) continue;
		const ctx = checkProgramWithRegistry(pr.value, registry, graph, mod, preludeCtx);
		ctx.errors = [];
		const monoed = monomorphizeProgram(pr.value, ctx);
		monoed_programs.push(expandMacros(monoed, ctx));
		monoed_paths.push(modPath);
	}
	const aliveSet = computeAliveSet(monoed_programs, monoed_paths, entryPath, false);

	let combined = "";
	for (const modPath of graph.loadOrder) {
		if (!isEntryPath(canonEntries, modPath)) continue;
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
		const macroExpanded = expandMacros(monoed, ctx);
		validateTypedAST(ctx, macroExpanded);
		if (hasErrors(ctx)) {
			ctx.errors = [];
		}

		const transformed = transformProgram(macroExpanded, ctx, false);
		const nativeCtx = createTransformContextWithChecker(ctx);
		const nativeTransformed = transformForNative(transformed, nativeCtx);
		const analyzed = analyzeProgram(nativeTransformed, ctx);
		combined = combined + generateCModule(analyzed, ctx, modPath, aliveSet, false, false);
	}

	const dispatcher = genProjectDispatcher(graph.loadOrder, entryPath, "", false);
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
	return emitJSTwoPhase(graph, registry, preludeCtx, null, canonEntries);
}

// Two-phase JS emission shared by compileProjectToJS / compileProjectToJSWithStd.
// Phase 1 checks + expands macros for EVERY module before phase 2 transforms any:
// transformProgram mutates the registered module AST in place, and a later
// module's macro expansion compiles helpers from the DECLARING module's AST —
// interleaving hands the macro engine a backend-lowered body (gen-20 root 1).
// Macro diagnostics are severity-Error but non-fatal (gen-20 root 2), so
// hasErrors after expandMacros is the loud-failure check.
function emitJSTwoPhase(graph: ModuleGraph, registry: ExportRegistry, preludeCtx: CheckerContext, entryFilter: MapEntry[] | null, canonEntries: MapEntry[]): string {
	const unitPaths: string[] = [];
	const unitPrograms: Node[] = [];
	const unitCtxs: CheckerContext[] = [];
	for (const modPath of graph.loadOrder) {
		if (entryFilter !== null && !isEntryPath(canonEntries, modPath)) continue;
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

		const expanded = expandMacros(pr.value, ctx);
		if (hasErrors(ctx)) {
			let msg = `ERROR: expand [${modPath}]:`;
			for (const err of ctx.errors) {
				msg = `${msg} ${err.message}`;
			}
			return msg;
		}

		unitPaths.push(modPath);
		unitPrograms.push(expanded);
		unitCtxs.push(ctx);
	}

	const pendingInsts = drainPendingInstances();
	for (const instNode of pendingInsts) {
		if (instNode.nodeType === null && instNode.resolvedSym !== null && instNode.resolvedSym.symbolType !== null) {
			instNode.nodeType = instNode.resolvedSym.symbolType;
		}
		let owner = "";
		if (instNode.resolvedSym !== null && instNode.resolvedSym.modulePath !== "") {
			owner = instNode.resolvedSym.modulePath;
		}
		let targetIdx: int32 = -1;
		for (let pi: int32 = 0; pi < unitPaths.length; pi += 1) {
			if (unitPaths[pi] === owner) { targetIdx = pi; }
		}
		if (targetIdx < 0) { targetIdx = unitPaths.length - 1; }
		if (targetIdx >= 0) {
			(unitPrograms[targetIdx].data as ProgramData).programStmts.push(instNode);
		}
	}

	let combined = "";
	for (let i = 0; i < unitPrograms.length; i += 1) {
		const transformed = transformProgram(unitPrograms[i], unitCtxs[i], true);
		combined = combined + generateJS(transformed, []);
	}
	return combined;
}

// JS twin of compileProjectToCWithStd: std resolves from disk, only the
// map-provided entry modules are emitted.
export function compileProjectToJSWithStd(entries: MapEntry[], entryPath: string): string {
	resetAllSideChannels();
	const canonEntries: MapEntry[] = [];
	for (const e of entries) {
		canonEntries.push({ entryPath: canonicalModulePath(e.entryPath), entrySource: e.entrySource });
	}
	entryPath = canonicalModulePath(entryPath);
	const provider = createMapProvider(canonEntries);
	provider.useFileSystem = true;
	const root = resolveRuntimeDir();
	const stdPath = root !== "" ? join(root, "std") : "std";
	const config = createDefaultConfig(Backend.JS, stdPath);
	const graph = loadModuleGraphWithConfig(entryPath, provider, config);
	if (graph.errors.length > 0) {
		let msg = "ERROR: graph:";
		for (const e of graph.errors) {
			msg = `${msg} ${e}`;
		}
		return msg;
	}

	const registry = checkModuleGraph(graph, stdPath, ".jms");
	const preludeCtx = getPreludeContext();
	return emitJSTwoPhase(graph, registry, preludeCtx, canonEntries, canonEntries);
}

test "contains basic" {
	assert "hello world".contains("world");
	assert "hello world".contains("hello");
	assert !"hello".contains("world");
	assert "abc".contains("");
	assert !"".contains("abc");
}

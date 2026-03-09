// E2E Test Helpers — full pipeline: MetaScript source → C/JS output
//
// All tests use the same graph-based pipeline as compile.ms.
// compileToC/compileToJS: single source (1-module graph internally).
// compileProjectToC/compileProjectToJS: multiple source files with imports.

import { parseSource } from "../parser/statements/validation";
import "../parser/statements/core";
import { checkProgramWithRegistry } from "../checker/checkPass";
import { checkModuleGraph, getPreludeContext } from "../checker/orchestrator";
import { computeAliveSet } from "../checker/reachability";
import { hasErrors } from "../checker/context";
import { monomorphizeProgram } from "../monomorphize/collect";
import { validateTypedAST } from "../checker/validate";
import { transformProgram } from "../transform/index";
import { transformForNative } from "../transform/native/index";
import { createTransformContextWithChecker } from "../transform/context";
import { analyzeProgram } from "../analyzer/index";
import { generateCModule, genProjectDispatcher } from "../codegen/c/index";
import { AliveSet, createAliveSet } from "../codegen/c/context";
import { generateJS } from "../codegen/js/index";
import { MapEntry, createMapProvider, loadModuleGraph } from "../module/loader";
import { Module, ModuleGraph, findModule } from "../module/graph";
import { Node } from "../ast/node";

export { MapEntry } from "../module/loader";

type CompileResult = Result<string, string>;

function collectErrors(errors: any[], prefix: string): string {
	let msg = prefix;
	let i = 0;
	while (i < errors.length) {
		msg = msg + " " + errors[i].message;
		i = i + 1;
	}
	return msg;
}

// ===== Single-source compilation (1-module graph) =====

// Full C pipeline: parse → check → monomorphize → validate → transform → native → analyze → codegen
export function compileToC(source: string): CompileResult {
	const modPath = "test/e2e.ms";
	const entries = [{ entryPath: modPath, entrySource: source }];
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph(modPath, provider);

	const registry = checkModuleGraph(graph, "");
	const preludeCtx = getPreludeContext();

	const mod = findModule(graph, modPath);
	if (mod === null) return Result.err("module not found");

	const pr = parseSource(mod.source);
	if (!pr.ok) return Result.err("parse: " + pr.error);

	const checkerCtx = checkProgramWithRegistry(pr.value, registry, graph, mod, preludeCtx);
	if (hasErrors(checkerCtx)) return Result.err(collectErrors(checkerCtx.errors, "check:"));

	const monoed = monomorphizeProgram(pr.value, checkerCtx);

	validateTypedAST(checkerCtx, monoed);
	if (hasErrors(checkerCtx)) return Result.err(collectErrors(checkerCtx.errors, "validate:"));

	const transformed = transformProgram(monoed, checkerCtx, false);
	const nativeCtx = createTransformContextWithChecker(checkerCtx);
	const nativeTransformed = transformForNative(transformed, nativeCtx);
	const analyzed = analyzeProgram(nativeTransformed, checkerCtx);
	const aliveSet = createAliveSet();
	return Result.ok(generateCModule(analyzed, checkerCtx, modPath, aliveSet, false, false));
}

// Full JS pipeline: parse → check → transform(jsBackend=true) → codegen
export function compileToJS(source: string): CompileResult {
	const modPath = "test/e2e.ms";
	const entries = [{ entryPath: modPath, entrySource: source }];
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph(modPath, provider);

	const registry = checkModuleGraph(graph, "");
	const preludeCtx = getPreludeContext();

	const mod = findModule(graph, modPath);
	if (mod === null) return Result.err("module not found");

	const pr = parseSource(mod.source);
	if (!pr.ok) return Result.err("parse: " + pr.error);

	const checkerCtx = checkProgramWithRegistry(pr.value, registry, graph, mod, preludeCtx);
	if (hasErrors(checkerCtx)) return Result.err(collectErrors(checkerCtx.errors, "check:"));

	const transformed = transformProgram(pr.value, checkerCtx, true);
	return Result.ok(generateJS(transformed));
}

// ===== Project compilation (multiple source files with imports) =====

// Compile project to C — same pipeline as compile.ms:
// checkModuleGraph (2-phase) → computeAliveSet (global DCE) → per-module codegen
export function compileProjectToC(entries: MapEntry[], entryPath: string): string {
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph(entryPath, provider);
	if (graph.errors.length > 0) {
		let msg = "ERROR: graph:";
		let i = 0;
		while (i < graph.errors.length) {
			msg = msg + " " + graph.errors[i];
			i = i + 1;
		}
		return msg;
	}

	const registry = checkModuleGraph(graph, "");
	const preludeCtx = getPreludeContext();

	// Compute global alive set for DCE (same as compile.ms:345)
	const monoed_programs: Node[] = [];
	const monoed_paths: string[] = [];
	let ai = 0;
	while (ai < graph.loadOrder.length) {
		const modPath = graph.loadOrder[ai];
		const mod = findModule(graph, modPath);
		if (mod === null || mod.isCHeader) { ai = ai + 1; continue; }
		const pr = parseSource(mod.source);
		if (!pr.ok) { ai = ai + 1; continue; }
		const ctx = checkProgramWithRegistry(pr.value, registry, graph, mod, preludeCtx);
		ctx.errors = [];
		const monoed = monomorphizeProgram(pr.value, ctx);
		monoed_programs.push(monoed);
		monoed_paths.push(modPath);
		ai = ai + 1;
	}
	const aliveSet = computeAliveSet(monoed_programs, monoed_paths, entryPath, false);

	// Full pipeline per module (same as compile.ms:358-411)
	let combined = "";
	let ci = 0;
	while (ci < graph.loadOrder.length) {
		const modPath = graph.loadOrder[ci];
		const mod = findModule(graph, modPath);
		if (mod === null || mod.isCHeader) { ci = ci + 1; continue; }

		const pr = parseSource(mod.source);
		if (!pr.ok) return "ERROR: parse [" + modPath + "]: " + pr.error;

		const ctx = checkProgramWithRegistry(pr.value, registry, graph, mod, preludeCtx);
		if (hasErrors(ctx)) {
			let msg = "ERROR: check [" + modPath + "]:";
			let ei = 0;
			while (ei < ctx.errors.length) {
				msg = msg + " " + ctx.errors[ei].message;
				ei = ei + 1;
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
		ci = ci + 1;
	}

	const dispatcher = genProjectDispatcher(graph.loadOrder, entryPath, false, "void");
	return combined + "\n" + dispatcher;
}

// Compile project to JS
export function compileProjectToJS(entries: MapEntry[], entryPath: string): string {
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph(entryPath, provider);
	if (graph.errors.length > 0) {
		let msg = "ERROR: graph:";
		let i = 0;
		while (i < graph.errors.length) {
			msg = msg + " " + graph.errors[i];
			i = i + 1;
		}
		return msg;
	}

	const registry = checkModuleGraph(graph, "");
	const preludeCtx = getPreludeContext();

	let combined = "";
	let ci = 0;
	while (ci < graph.loadOrder.length) {
		const modPath = graph.loadOrder[ci];
		const mod = findModule(graph, modPath);
		if (mod === null || mod.isCHeader) { ci = ci + 1; continue; }

		const pr = parseSource(mod.source);
		if (!pr.ok) return "ERROR: parse [" + modPath + "]: " + pr.error;

		const ctx = checkProgramWithRegistry(pr.value, registry, graph, mod, preludeCtx);
		if (hasErrors(ctx)) {
			let msg = "ERROR: check [" + modPath + "]:";
			let ei = 0;
			while (ei < ctx.errors.length) {
				msg = msg + " " + ctx.errors[ei].message;
				ei = ei + 1;
			}
			return msg;
		}

		const transformed = transformProgram(pr.value, ctx, true);
		combined = combined + generateJS(transformed);
		ci = ci + 1;
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

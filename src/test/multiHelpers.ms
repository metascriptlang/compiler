// Multi-Module E2E Test Helpers
//
// Uses MapProvider + loadModuleGraph for graph resolution, then
// single-module checkProgram for each module's codegen pass.
// NOTE: We skip checkModuleGraph (cross-module type check) because
// orchestrator.ms imports resolvePass.ms which has a Bun-incompatible line.
// This means imports resolve as unknownType, but codegen still runs correctly.

import { parseSource } from "../parser/statements/validation";
import "../parser/statements/core";
import { checkProgram } from "../checker/checkPass";
import { hasErrors } from "../checker/context";
import { monomorphizeProgram } from "../monomorphize/collect";
import { validateTypedAST } from "../checker/validate";
import { transformProgram } from "../transform/index";
import { transformForNative } from "../transform/native/index";
import { createTransformContextWithChecker } from "../transform/context";
import { analyzeProgram } from "../analyzer/index";
import { generateCModule, collectExportedPrototypes, genProjectDispatcher } from "../codegen/c/index";
import { generateJS } from "../codegen/js/index";
import { MapEntry, createMapProvider, loadModuleGraph } from "../module/loader";
import { findModule } from "../module/graph";
import { sliceStr } from "../utils/string";

export type { MapEntry } from "../module/loader";

// Re-export assertion helpers so module tests only need one import
export function assertContains(haystack: string, needle: string): boolean {
	if (needle.length === 0) return true;
	if (haystack.length < needle.length) return false;
	let i = 0;
	const limit = haystack.length - needle.length;
	while (i <= limit) {
		if (sliceStr(haystack, i, i + needle.length) === needle) return true;
		i = i + 1;
	}
	return false;
}

export function assertNoError(output: string): boolean {
	if (output.length >= 6 && sliceStr(output, 0, 6) === "ERROR:") return false;
	return true;
}

// Multi-module C pipeline: graph loading + two-pass separate compilation
// Uses single-module checkProgram per module (imports as unknownType).
export function compileManyToC(entries: MapEntry[], entryPath: string): string {
	// 1. Build module graph from in-memory sources
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

	// Pass 1: Collect exported prototypes from all modules
	let allProtos = "";
	let pi = 0;
	while (pi < graph.loadOrder.length) {
		const modPath = graph.loadOrder[pi];
		const mod = findModule(graph, modPath);
		if (mod !== null && !mod.isCHeader) {
			const pr = parseSource(mod.source);
			if (pr.ok) {
				const ctx = checkProgram(pr.value);
				const monoed = monomorphizeProgram(pr.value, ctx);
				allProtos = allProtos + collectExportedPrototypes(monoed);
			}
		}
		pi = pi + 1;
	}

	// Pass 2: Full pipeline per module -> concatenate C output
	let combined = "";
	let ci = 0;
	while (ci < graph.loadOrder.length) {
		const modPath = graph.loadOrder[ci];
		const mod = findModule(graph, modPath);
		if (mod === null || mod.isCHeader) { ci = ci + 1; continue; }

		const pr = parseSource(mod.source);
		if (!pr.ok) return "ERROR: parse [" + modPath + "]: " + pr.error;

		const ctx = checkProgram(pr.value);
		if (hasErrors(ctx)) {
			let msg = "ERROR: check [" + modPath + "]:";
			let ei = 0;
			while (ei < ctx.errors.length) {
				msg = msg + " " + ctx.errors[ei];
				ei = ei + 1;
			}
			return msg;
		}

		const monoed = monomorphizeProgram(pr.value, ctx);
		validateTypedAST(ctx, monoed);
		if (hasErrors(ctx)) {
			let msg = "ERROR: validate [" + modPath + "]:";
			let ei = 0;
			while (ei < ctx.errors.length) {
				msg = msg + " " + ctx.errors[ei];
				ei = ei + 1;
			}
			return msg;
		}

		const transformed = transformProgram(monoed, ctx, false);
		const nativeCtx = createTransformContextWithChecker(ctx);
		const nativeTransformed = transformForNative(transformed, nativeCtx);
		const analyzed = analyzeProgram(nativeTransformed, ctx);
		combined = combined + generateCModule(analyzed, ctx, modPath, allProtos);
		ci = ci + 1;
	}

	// Generate dispatcher
	const dispatcher = genProjectDispatcher(graph.loadOrder, entryPath, false);
	return combined + "\n" + dispatcher;
}

// Multi-module JS pipeline
export function compileManyToJS(entries: MapEntry[], entryPath: string): string {
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

	let combined = "";
	let ci = 0;
	while (ci < graph.loadOrder.length) {
		const modPath = graph.loadOrder[ci];
		const mod = findModule(graph, modPath);
		if (mod === null || mod.isCHeader) { ci = ci + 1; continue; }

		const pr = parseSource(mod.source);
		if (!pr.ok) return "ERROR: parse [" + modPath + "]: " + pr.error;

		const ctx = checkProgram(pr.value);
		if (hasErrors(ctx)) {
			let msg = "ERROR: check [" + modPath + "]:";
			let ei = 0;
			while (ei < ctx.errors.length) {
				msg = msg + " " + ctx.errors[ei];
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

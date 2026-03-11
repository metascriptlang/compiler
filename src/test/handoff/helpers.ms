// Phase Handoff Test Helpers
//
// Shared utilities for running the compiler pipeline up to specific phases.
// Uses the same graph-based pipeline as compile.ms (1-module graph internally).

import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { checkProgramWithRegistry } from "../../checker/checkPass";
import { checkModuleGraph, getPreludeContext } from "../../checker/orchestrator";
import { CheckerContext, Severity } from "../../checker/context";
import { monomorphizeProgram } from "../../monomorphize/collect";
import { validateTypedAST } from "../../checker/validate";
import { transformProgram } from "../../transform/index";
import { transformForNative } from "../../transform/native/index";
import { createTransformContextWithChecker } from "../../transform/context";
import { Node, NodeKind, ProgramData, FunctionDeclData } from "../../ast/node";
import { createMapProvider, loadModuleGraph } from "../../module/loader";
import { findModule } from "../../module/graph";
import { resetAllSideChannels } from "../../parser/context";

export function checkSource(source: string): CheckerContext {
	resetAllSideChannels();
	const modPath = "test/handoff.ms";
	const entries = [{ entryPath: modPath, entrySource: source }];
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph(modPath, provider);
	const registry = checkModuleGraph(graph, "");
	const preludeCtx = getPreludeContext();

	const mod = findModule(graph, modPath);
	if (mod === null) return null as unknown as CheckerContext;

	const pr = parseSource(mod.source);
	if (!pr.ok) return null as unknown as CheckerContext;

	return checkProgramWithRegistry(pr.value, registry, graph, mod, preludeCtx);
}

export function fullPipeline(source: string): Node {
	resetAllSideChannels();
	const modPath = "test/handoff.ms";
	const entries = [{ entryPath: modPath, entrySource: source }];
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph(modPath, provider);
	const registry = checkModuleGraph(graph, "");
	const preludeCtx = getPreludeContext();

	const mod = findModule(graph, modPath);
	if (mod === null) return null as unknown as Node;

	const pr = parseSource(mod.source);
	if (!pr.ok) return null as unknown as Node;

	const ctx = checkProgramWithRegistry(pr.value, registry, graph, mod, preludeCtx);
	const monoed = monomorphizeProgram(pr.value, ctx);
	validateTypedAST(ctx, monoed);
	const transformed = transformProgram(monoed, ctx, false);
	const nativeCtx = createTransformContextWithChecker(ctx);
	return transformForNative(transformed, nativeCtx);
}

// Find a FunctionDecl by name in the program's top-level statements
export function findFnDecl(program: Node, name: string): Node {
	if (program === null || program.kind !== NodeKind.Program) return null as unknown as Node;
	const pd = program.data as ProgramData;
	for (const stmt of pd.programStmts) {
		if (stmt.kind === NodeKind.FunctionDecl) {
			const fd = stmt.data as FunctionDeclData;
			if (fd.fnName === name) return stmt;
		}
	}
	return null as unknown as Node;
}

// ===== Diagnostic Helpers =====

export function errorCount(src: string): number {
	const ctx = checkSource(src);
	if (ctx === null) return -1;
	return ctx.errors.length;
}

export function strictErrorCount(src: string): number {
	const ctx = checkSource(src);
	if (ctx === null) return -1;
	let count = 0;
	for (const err of ctx.errors) {
		if (err.severity === Severity.Error) count = count + 1;
	}
	return count;
}

export function warningCount(src: string): number {
	const ctx = checkSource(src);
	if (ctx === null) return -1;
	let count = 0;
	for (const err of ctx.errors) {
		if (err.severity === Severity.Warning) count = count + 1;
	}
	return count;
}

export function hasError(src: string, needle: string): boolean {
	const ctx = checkSource(src);
	if (ctx === null) return false;
	for (const err of ctx.errors) {
		if (err.message.indexOf(needle) >= 0) return true;
	}
	return false;
}

export function hasWarning(src: string, needle: string): boolean {
	const ctx = checkSource(src);
	if (ctx === null) return false;
	for (const err of ctx.errors) {
		if (err.severity === Severity.Warning && err.message.indexOf(needle) >= 0) return true;
	}
	return false;
}

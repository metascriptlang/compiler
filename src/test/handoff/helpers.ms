// Phase Handoff Test Helpers
//
// Shared utilities for running the compiler pipeline up to specific phases.
// Uses the same graph-based pipeline as compile.ms (1-module graph internally).

import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { checkProgramWithRegistry, preludeContextFor } from "../../checker/checkPass";
import { CheckerContext, Severity, ExportRegistry } from "../../checker/context";
import { monomorphizeProgram } from "../../monomorphize/collect";
import { validateTypedAST } from "../../checker/validate";
import { transformProgram } from "../../transform/index";
import { transformForNative } from "../../transform/native/index";
import { createTransformContextWithChecker } from "../../transform/context";
import { Node, NodeKind, ProgramData, FunctionDeclData } from "../../ast/node";
import { Module, ModuleGraph } from "../../module/graph";
import { resetBuildState } from "../../compiler/buildSession";

export function checkSource(source: string): CheckerContext {
	resetBuildState();
	const prelude = preludeContextFor("", ".cms");
	// Single-source check: one pass with null graph/mod so top-level symbols land
	// in the returned ctx.table. The graph two-pass path registers them in the
	// export registry instead, leaving ctx.table empty for introspection.
	const pr = parseSource(source);
	if (!pr.ok) return null as unknown as CheckerContext;
	return checkProgramWithRegistry(pr.value, null as unknown as ExportRegistry, null as unknown as ModuleGraph, null as unknown as Module, prelude);
}

export function fullPipeline(source: string): Node {
	resetBuildState();
	const prelude = preludeContextFor("", ".cms");
	const pr = parseSource(source);
	if (!pr.ok) return null as unknown as Node;
	const ctx = checkProgramWithRegistry(pr.value, null as unknown as ExportRegistry, null as unknown as ModuleGraph, null as unknown as Module, prelude);
	const monoed = monomorphizeProgram(pr.value, ctx);
	validateTypedAST(ctx, monoed);
	const transformed = transformProgram(monoed, ctx, false);
	const nativeCtx = createTransformContextWithChecker(ctx);
	return transformForNative(transformed, nativeCtx);
}

// Find a FunctionDecl by name in the program's top-level statements
export function findFnDecl(program: Node, name: string): Node {
	if (program == null || program.kind != NodeKind.Program) return null as unknown as Node;
	const pd = program.data as ProgramData;
	for (const stmt of pd.programStmts) {
		if (stmt.kind == NodeKind.FunctionDecl) {
			const fd = stmt.data as FunctionDeclData;
			if (fd.fnName == name) return stmt;
		}
	}
	return null as unknown as Node;
}

// ===== Diagnostic Helpers =====

export function errorCount(src: string): number {
	const ctx = checkSource(src);
	if (ctx == null) return -1;
	return ctx.errors.length;
}

export function strictErrorCount(src: string): number {
	const ctx = checkSource(src);
	if (ctx == null) return -1;
	let count = 0;
	for (const err of ctx.errors) {
		if (err.severity == Severity.Error) count = count + 1;
	}
	return count;
}

export function warningCount(src: string): number {
	const ctx = checkSource(src);
	if (ctx == null) return -1;
	let count = 0;
	for (const err of ctx.errors) {
		if (err.severity == Severity.Warning) count = count + 1;
	}
	return count;
}

export function hasError(src: string, needle: string): boolean {
	const ctx = checkSource(src);
	if (ctx == null) return false;
	for (const err of ctx.errors) {
		if (err.message.indexOf(needle) >= 0) return true;
	}
	return false;
}

export function hasWarning(src: string, needle: string): boolean {
	const ctx = checkSource(src);
	if (ctx == null) return false;
	for (const err of ctx.errors) {
		if (err.severity == Severity.Warning && err.message.indexOf(needle) >= 0) return true;
	}
	return false;
}

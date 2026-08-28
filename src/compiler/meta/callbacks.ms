// Meta Callbacks — breaks circular dependency between expand.ms and eval.ms.
// Same pattern as checker/checkerCallbacks.ms.

import { Node } from "../../ast/node";
import { RaiserContext } from "../../raiser/context";
import { RaiserModule } from "../../raiser/module";
import { RaiserVM } from "../../raiser/vm";
import { CheckerContext, CheckerError, ExportRegistry } from "../../checker/context";
import { Module, ModuleGraph } from "../../module/graph";

type MacroEvaluatorFn = (program: Node) => RaiserContext | null;

let macroEvaluatorFn: MacroEvaluatorFn = (program: Node): RaiserContext | null => {
	return null;
};

export function callMacroEvaluator(program: Node): RaiserContext | null {
	return macroEvaluatorFn(program);
}

export function registerMacroEvaluator(fn: MacroEvaluatorFn): void {
	macroEvaluatorFn = fn;
}

type MacroCompilerFn = (program: Node) => RaiserModule | null;

let macroCompilerFn: MacroCompilerFn = (program: Node): RaiserModule | null => {
	return null;
};

export function callMacroCompiler(program: Node): RaiserModule | null {
	return macroCompilerFn(program);
}

export function registerMacroCompiler(fn: MacroCompilerFn): void {
	macroCompilerFn = fn;
}

// Comptime engine: compile a macro wrapper into the ONE shared project-wide image
// (Nim's graph.vm + PCtx.code) and return the persistent VM plus the absolute
// funcIdx of `macroFnName`. `token` scopes the engine to one compilation.
export interface EngineMacroResult {
	vm: RaiserVM;
	funcIdx: number;
	errors: CheckerError[];
}

type MacroEngineCompilerFn = (program: Node, token: CheckerContext, macroFnName: string) => EngineMacroResult | null;

let macroEngineCompilerFn: MacroEngineCompilerFn = (program: Node, token: CheckerContext, macroFnName: string): EngineMacroResult | null => {
	return null;
};

export function callMacroEngineCompiler(program: Node, token: CheckerContext, macroFnName: string): EngineMacroResult | null {
	return macroEngineCompilerFn(program, token, macroFnName);
}

export function registerMacroEngineCompiler(fn: MacroEngineCompilerFn): void {
	macroEngineCompilerFn = fn;
}

let _macroDeclModulePath = "";

export function setMacroDeclModulePath(path: string): void {
	_macroDeclModulePath = path;
}

export function getMacroDeclModulePath(): string {
	return _macroDeclModulePath;
}

// ===== Comptime outer context =====
// When the checker enters a module, it captures references to the outer
// compile state (the surrounding Program AST plus, in multi-module mode,
// the ExportRegistry/ModuleGraph/Module/PreludeCtx) and exposes them here
// for `evalComptimeBlock` and `evalASTFull` to consume. This is what makes
// cross-scope @comptime evaluation possible — without it, the synthetic
// Program built around the @comptime body would be evaluated in isolation
// with no access to outer functions or imports.
//
// FRAGILE — module-level state. The checker overwrites these per entry,
// so in normal compilation the slot is always fresh. If `evalComptimeBlock`
// is invoked WITHOUT first going through the checker (e.g., a test calling
// it directly), `outer` is whatever the previous run left behind, and
// `_resetComptimeOuterCtxForTests` should be used to clear it.
//
// Single struct (was 5 separate `let` vars in Phase 8a/Spike 2 — consolidated
// here for one source of truth). Threading the struct as a function parameter
// through `evalASTFull → evalComptimeBlock` would be cleaner, but the types
// transitively reach checker types which would create a circular import
// (checker → comptime → eval → checker). The slot pattern is the
// established workaround in this codebase (mirrors `registerMacroEvaluator`).

export interface ComptimeOuterCtx {
	program: Node | null;             // surrounding Program AST (single-file mode minimum)
	registry: ExportRegistry;         // null in single-file mode
	graph: ModuleGraph;               // null in single-file mode
	module: Module;                   // null in single-file mode
	preludeCtx: CheckerContext;       // null in single-file mode
}

let _comptimeOuter: ComptimeOuterCtx | null = null;

export function setComptimeOuterCtx(ctx: ComptimeOuterCtx): void {
	_comptimeOuter = ctx;
}

export function getComptimeOuterCtx(): ComptimeOuterCtx | null {
	return _comptimeOuter;
}

// Production sets all 5 fields together; this helper avoids the two-call
// pattern (setOuterProgramForComptime + setOuterCheckContext) that crept in
// across Phase 8a/Spike 2. Use `setComptimeOuterCtx` directly going forward.
// Callers read via `getComptimeOuterCtx()` and check `.program/.registry/...`
// fields directly — no per-field getters needed.

export function setOuterProgramForComptime(program: Node): void {
	if (_comptimeOuter === null) {
		_comptimeOuter = {
			program,
			registry: null as unknown as ExportRegistry,
			graph: null as unknown as ModuleGraph,
			module: null as unknown as Module,
			preludeCtx: null as unknown as CheckerContext,
		};
		return;
	}
	_comptimeOuter.program = program;
}

export function setOuterCheckContext(
	registry: ExportRegistry,
	graph: ModuleGraph,
	mod: Module,
	preludeCtx: CheckerContext,
): void {
	if (_comptimeOuter === null) {
		_comptimeOuter = {
			program: null,
			registry,
			graph,
			module: mod,
			preludeCtx,
		};
		return;
	}
	_comptimeOuter.registry = registry;
	_comptimeOuter.graph = graph;
	_comptimeOuter.module = mod;
	_comptimeOuter.preludeCtx = preludeCtx;
}

// Test-only resets.
export function _resetComptimeOuterCtxForTests(): void {
	_comptimeOuter = null;
}

export function _resetOuterProgramForComptimeForTests(): void {
	_resetComptimeOuterCtxForTests();
}

export function _resetOuterCheckContextForTests(): void {
	_resetComptimeOuterCtxForTests();
}

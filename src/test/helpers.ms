// E2E Test Helpers — full pipeline: MetaScript source → C/JS output
//
// All tests use the same graph-based pipeline as compile.ms.
// compileToC/compileToJS: single source (1-module graph internally).
// compileProjectToC/compileProjectToJS: multiple source files with imports.

import { parseSource } from "../parser/statements/validation";
import "../parser/statements/core";
import { resetBuildState } from "../compiler/buildSession";
import { checkModuleGraph } from "../checker/orchestrator";
import { TargetInfo, hostTargetInfo } from "../checker/types";
import { computeAliveSet } from "../checker/reachability";
import { hasErrors, CheckerError, CheckerContext } from "../checker/context";
import { monomorphizeProgram } from "../monomorphize/collect";
import { expandMacros } from "../compiler/meta/expand";
import { refuseSyncAwaitOnJs } from "../checker/syncAwait";
import { validateTypedAST } from "../checker/validate";
import { transformProgram } from "../transform/index";
import { transformForNative } from "../transform/native/index";
import { createTransformContextWithChecker } from "../transform/context";
import { analyzeProgram } from "../analyzer/index";
import { CModuleOutput, generateCModule, generateCModuleOutput, genProjectDispatcher, prepareCModuleEmission } from "../codegen/c/index";
import { AliveSet, createAliveSet, CEmissionFacts } from "../codegen/c/context";
import { generateJS, generateJSModule } from "../codegen/js/jsgen";
import { MapEntry, createMapProvider, loadModuleGraph, loadModuleGraphWithConfig, canonicalModulePath } from "../module/loader";
import { createDefaultConfig, Backend } from "../module/resolver";
import { resolveRuntimeDir } from "../utils/path";
import { join } from "std/fs/path";
import { ErrorSeverity, Module, ModuleGraph, findModule } from "../module/graph";
import { Node, ProgramData } from "../ast/node";
import { drainPendingInstances, lookupModuleCtx, lookupModuleProgram } from "../checker/instantiate";
import { platform } from "std/process";
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
interface CheckedUnit {
	path: string;
	program: Node;
	ctx: CheckerContext;
}

function checkedUnit(path: string): CheckedUnit | null {
	const program = lookupModuleProgram(path);
	const ctx = lookupModuleCtx(path);
	if (program == null || ctx == null) return null;
	return { path, program, ctx };
}

function loadFailure(mod: Module, where: string = ""): string {
	for (const e of mod.errors) {
		if (e.severity != ErrorSeverity.Error) continue;
		const pr = parseSource(mod.source);
		return pr.ok ? `load${where}: ${e.message}` : `parse${where}: ${pr.error}`;
	}
	return "";
}

function uncheckedError(mod: Module): string {
	const pr = parseSource(mod.source);
	return pr.ok ? `internal: ${mod.path} was not checked by the graph phase` : `parse: ${pr.error}`;
}

function placeOwnedInstances(units: CheckedUnit[]): void {
	const ctxs: CheckerContext[] = [];
	for (const u of units) ctxs.push(u.ctx);
	for (const inst of drainPendingInstances(ctxs)) {
		const sym = inst.resolvedSym;
		if (sym == null || sym.modulePath == "") throw new Error("internal: a generic instance has no owning module");
		if (inst.nodeType == null && sym.symbolType != null) inst.nodeType = sym.symbolType;
		for (const u of units) {
			if (u.path == sym.modulePath) {
				(u.program.data as ProgramData).programStmts.push(inst);
				break;
			}
		}
	}
}

export function compileToC(source: string, target: TargetInfo = hostTargetInfo()): CompileResult {
	resetBuildState();
	// loadModule canonicalizes the entry path to absolute (loader.ms:393) —
	// findModule uses string equality, so we must canonicalize here too.
	const modPath = canonicalModulePath("test/e2e.ms");
	const entries: MapEntry[] = [{ entryPath: modPath, entrySource: source }];
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph(modPath, provider);

	const mod = findModule(graph, modPath);
	if (mod == null) return Result.err("module not found");
	const loadErr = loadFailure(mod);
	if (loadErr != "") return Result.err(loadErr);

	checkModuleGraph(graph, "", ".cms", platform, target);

	const unit = checkedUnit(modPath);
	if (unit == null) return Result.err(uncheckedError(mod));
	const checkerCtx = unit.ctx;
	if (hasErrors(checkerCtx)) return Result.err(collectErrors(checkerCtx.errors, "check:"));
	placeOwnedInstances([unit]);

	const monoed = monomorphizeProgram(unit.program, checkerCtx);

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
	resetBuildState();
	const modPath = canonicalModulePath("test/e2e.ms");
	const entries: MapEntry[] = [{ entryPath: modPath, entrySource: source }];
	const provider = createMapProvider(entries);
	// Map provider alone never touches disk — std modules must load from the
	// real filesystem (entries win first, so the in-memory entry still shadows).
	provider.useFileSystem = true;
	const root = resolveRuntimeDir();
	const stdPath = root != "" ? join(root, "std") : "std";
	const config = createDefaultConfig(Backend.C, stdPath);
	const graph = loadModuleGraphWithConfig(modPath, provider, config);

	const mod = findModule(graph, modPath);
	if (mod == null) return Result.err("module not found");
	const loadErr = loadFailure(mod);
	if (loadErr != "") return Result.err(loadErr);

	checkModuleGraph(graph, stdPath);

	const unit = checkedUnit(modPath);
	if (unit == null) return Result.err(uncheckedError(mod));
	const checkerCtx = unit.ctx;
	if (hasErrors(checkerCtx)) return Result.err(collectErrors(checkerCtx.errors, "check:"));
	placeOwnedInstances([unit]);

	const monoed = monomorphizeProgram(unit.program, checkerCtx);

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
export function compileToJS(source: string, target: TargetInfo = hostTargetInfo()): CompileResult {
	resetBuildState();
	const modPath = canonicalModulePath("test/e2e.ms");
	const entries: MapEntry[] = [{ entryPath: modPath, entrySource: source }];
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph(modPath, provider);

	const mod = findModule(graph, modPath);
	if (mod == null) return Result.err("module not found");
	const loadErr = loadFailure(mod);
	if (loadErr != "") return Result.err(loadErr);

	checkModuleGraph(graph, "", ".cms", platform, target);

	const unit = checkedUnit(modPath);
	if (unit == null) return Result.err(uncheckedError(mod));
	const checkerCtx = unit.ctx;
	if (hasErrors(checkerCtx)) return Result.err(collectErrors(checkerCtx.errors, "check:"));
	placeOwnedInstances([unit]);

	const transformed = transformProgram(unit.program, checkerCtx, true);
	// Mirrors the drain compile.ms runs after the JS transform: a pass that
	// refuses a construct reports it here instead of emitting silently-wrong JS.
	if (hasErrors(checkerCtx)) return Result.err(collectErrors(checkerCtx.errors, "transform:"));
	return Result.ok(generateJS(transformed, []));
}

export function compileTestBuildToJS(source: string): CompileResult {
	resetBuildState();
	const modPath = canonicalModulePath("test/e2e.ms");
	const entries: MapEntry[] = [{ entryPath: modPath, entrySource: source }];
	const provider = createMapProvider(entries);
	provider.useFileSystem = true;
	const root = resolveRuntimeDir();
	const stdPath = root != "" ? join(root, "std") : "std";
	const config = createDefaultConfig(Backend.JS, stdPath);
	const graph = loadModuleGraphWithConfig(modPath, provider, config);

	const mod = findModule(graph, modPath);
	if (mod == null) return Result.err("module not found");
	const loadErr = loadFailure(mod);
	if (loadErr != "") return Result.err(loadErr);

	checkModuleGraph(graph, stdPath);

	const unit = checkedUnit(modPath);
	if (unit == null) return Result.err(uncheckedError(mod));
	const checkerCtx = unit.ctx;
	if (hasErrors(checkerCtx)) return Result.err(collectErrors(checkerCtx.errors, "check:"));
	placeOwnedInstances([unit]);

	const transformed = transformProgram(unit.program, checkerCtx, true);
	if (hasErrors(checkerCtx)) return Result.err(collectErrors(checkerCtx.errors, "transform:"));
	const res = generateJSModule(transformed, [], modPath, [], [], [], [], [], [], true, false);
	return Result.ok(res.code);
}

// ===== Project compilation (multiple source files with imports) =====

// Compile project to C — same pipeline as compile.ms:
// checkModuleGraph (2-phase) → computeAliveSet (global DCE) → per-module codegen
export function compileProjectToC(entries: MapEntry[], entryPath: string): string {
	resetBuildState();
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
	for (const modPath of graph.loadOrder) {
		const mod = findModule(graph, modPath);
		if (mod == null) continue;
		const loadErr = loadFailure(mod, ` [${modPath}]`);
		if (loadErr != "") return `ERROR: ${loadErr}`;
	}

	checkModuleGraph(graph, "");

	const units: CheckedUnit[] = [];
	for (const modPath of graph.loadOrder) {
		const mod = findModule(graph, modPath);
		if (mod == null) continue;
		const unit = checkedUnit(modPath);
		if (unit == null) return `ERROR: ${uncheckedError(mod)}`;
		if (hasErrors(unit.ctx)) return checkErrorMessage(unit);
		units.push(unit);
	}
	placeOwnedInstances(units);

	// Compute global alive set for DCE (same as compile.ms:345)
	const monoed_programs: Node[] = [];
	const monoed_paths: string[] = [];
	for (const unit of units) {
		monoed_programs.push(monomorphizeProgram(unit.program, unit.ctx));
		monoed_paths.push(unit.path);
	}
	const aliveSet = computeAliveSet(monoed_programs, monoed_paths, entryPath, false, graph);

	// Full pipeline per module (same as compile.ms:358-411)
	let combined = "";
	const moduleOutputs: CModuleOutput[] = [];
	const emissionPrograms: Node[] = [];
	const emissionContexts: CheckerContext[] = [];
	const emissionPaths: string[] = [];
	for (let ui = 0; ui < units.length; ui += 1) {
		const modPath = units[ui].path;
		const ctx = units[ui].ctx;
		const monoed = monoed_programs[ui];
		validateTypedAST(ctx, monoed);
		if (hasErrors(ctx)) {
			ctx.errors = [];
		}

		const transformed = transformProgram(monoed, ctx, false);
		const nativeCtx = createTransformContextWithChecker(ctx);
		const nativeTransformed = transformForNative(transformed, nativeCtx);
		const analyzed = analyzeProgram(nativeTransformed, ctx);
		emissionPrograms.push(analyzed);
		emissionContexts.push(ctx);
		emissionPaths.push(modPath);
	}
	const emissionFacts = new CEmissionFacts();
	for (let i = 0; i < emissionPrograms.length; i += 1) {
		prepareCModuleEmission(emissionPrograms[i], emissionContexts[i], emissionPaths[i], aliveSet, emissionFacts);
	}
	for (let i = 0; i < emissionPrograms.length; i += 1) {
		const output = generateCModuleOutput(emissionPrograms[i], emissionContexts[i], emissionPaths[i], aliveSet, false, false, emissionFacts);
		combined = combined + output.code;
		output.code = "";
		moduleOutputs.push(output);
	}

	const dispatcher = genProjectDispatcher(graph.loadOrder, entryPath, "", false, moduleOutputs);
	return `${combined}\n${dispatcher}`;
}

function checkErrorMessage(unit: CheckedUnit): string {
	let msg = `ERROR: check [${unit.path}]:`;
	for (const err of unit.ctx.errors) {
		msg = `${msg} ${err.message}`;
	}
	return msg;
}

function providerEntries(entries: MapEntry[]): MapEntry[] {
	const copy: MapEntry[] = [];
	for (const e of entries) copy.push(e);
	return copy;
}

function isEntryPath(entries: MapEntry[], modPath: string): boolean {
	for (const e of entries) {
		if (e.entryPath == modPath) return true;
	}
	return false;
}

// Like compileProjectToC but with std/ resolution enabled (see compileToCWithStd).
// Codegen covers only the in-memory entry modules — std modules load for
// checking/macros but are not emitted, mirroring compileToCWithStd. expandMacros
// runs post-mono in BOTH loops so macro-emitted callees (e.g. bindSym targets)
// reach the alive set.
export function checkProjectDiagnostics(entries: MapEntry[], entryPath: string): string[] {
	resetBuildState();
	const canonEntries: MapEntry[] = [];
	for (const e of entries) {
		canonEntries.push({ entryPath: canonicalModulePath(e.entryPath), entrySource: e.entrySource });
	}
	entryPath = canonicalModulePath(entryPath);
	const provider = createMapProvider(canonEntries);
	provider.useFileSystem = true;
	const root = resolveRuntimeDir();
	const stdPath = root != "" ? join(root, "std") : "std";
	const graph = loadModuleGraphWithConfig(entryPath, provider, createDefaultConfig(Backend.C, stdPath));
	const messages: string[] = [];
	for (const e of graph.errors) messages.push(`${e}`);
	if (messages.length > 0) return messages;
	const mod = findModule(graph, entryPath);
	if (mod == null) return messages;
	const loadErr = loadFailure(mod);
	if (loadErr != "") {
		const pr = parseSource(mod.source);
		messages.push(pr.ok ? loadErr : `${pr.error}`);
		return messages;
	}
	checkModuleGraph(graph, stdPath);
	const unit = checkedUnit(entryPath);
	if (unit == null) {
		const pr = parseSource(mod.source);
		messages.push(pr.ok ? `internal: ${entryPath} was not checked by the graph phase` : `${pr.error}`);
		return messages;
	}
	for (const err of unit.ctx.errors) messages.push(err.message);
	return messages;
}

export function compileProjectToCWithStd(entries: MapEntry[], entryPath: string): string {
	resetBuildState();
	const canonEntries: MapEntry[] = [];
	for (const e of entries) {
		canonEntries.push({ entryPath: canonicalModulePath(e.entryPath), entrySource: e.entrySource });
	}
	entryPath = canonicalModulePath(entryPath);
	const provider = createMapProvider(providerEntries(canonEntries));
	provider.useFileSystem = true;
	const root = resolveRuntimeDir();
	const stdPath = root != "" ? join(root, "std") : "std";
	const config = createDefaultConfig(Backend.C, stdPath);
	const graph = loadModuleGraphWithConfig(entryPath, provider, config);
	if (graph.errors.length > 0) {
		let msg = "ERROR: graph:";
		for (const e of graph.errors) {
			msg = `${msg} ${e}`;
		}
		return msg;
	}
	for (const modPath of graph.loadOrder) {
		if (!isEntryPath(canonEntries, modPath)) continue;
		const mod = findModule(graph, modPath);
		if (mod == null) continue;
		const loadErr = loadFailure(mod, ` [${modPath}]`);
		if (loadErr != "") return `ERROR: ${loadErr}`;
	}

	checkModuleGraph(graph, stdPath);

	const units: CheckedUnit[] = [];
	for (const modPath of graph.loadOrder) {
		if (!isEntryPath(canonEntries, modPath)) continue;
		const mod = findModule(graph, modPath);
		if (mod == null) continue;
		const unit = checkedUnit(modPath);
		if (unit == null) return `ERROR: ${uncheckedError(mod)}`;
		if (hasErrors(unit.ctx)) return checkErrorMessage(unit);
		units.push(unit);
	}
	placeOwnedInstances(units);

	const monoed_programs: Node[] = [];
	const monoed_paths: string[] = [];
	for (const unit of units) {
		monoed_programs.push(expandMacros(monomorphizeProgram(unit.program, unit.ctx), unit.ctx));
		monoed_paths.push(unit.path);
	}
	const aliveSet = computeAliveSet(monoed_programs, monoed_paths, entryPath, false, graph);

	let combined = "";
	const moduleOutputs: CModuleOutput[] = [];
	const emissionPrograms: Node[] = [];
	const emissionContexts: CheckerContext[] = [];
	const emissionPaths: string[] = [];
	for (let ui = 0; ui < units.length; ui += 1) {
		const modPath = units[ui].path;
		const ctx = units[ui].ctx;
		const macroExpanded = monoed_programs[ui];
		validateTypedAST(ctx, macroExpanded);
		if (hasErrors(ctx)) {
			ctx.errors = [];
		}

		const transformed = transformProgram(macroExpanded, ctx, false);
		const nativeCtx = createTransformContextWithChecker(ctx);
		const nativeTransformed = transformForNative(transformed, nativeCtx);
		const analyzed = analyzeProgram(nativeTransformed, ctx);
		emissionPrograms.push(analyzed);
		emissionContexts.push(ctx);
		emissionPaths.push(modPath);
	}
	const emissionFacts = new CEmissionFacts();
	for (let i = 0; i < emissionPrograms.length; i += 1) {
		prepareCModuleEmission(emissionPrograms[i], emissionContexts[i], emissionPaths[i], aliveSet, emissionFacts);
	}
	for (let i = 0; i < emissionPrograms.length; i += 1) {
		const output = generateCModuleOutput(emissionPrograms[i], emissionContexts[i], emissionPaths[i], aliveSet, false, false, emissionFacts);
		combined = combined + output.code;
		output.code = "";
		moduleOutputs.push(output);
	}

	const dispatcher = genProjectDispatcher(graph.loadOrder, entryPath, "", false, moduleOutputs);
	return `${combined}\n${dispatcher}`;
}

// Compile project to JS
export function compileProjectToJS(entries: MapEntry[], entryPath: string): string {
	resetBuildState();
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
	for (const modPath of graph.loadOrder) {
		const mod = findModule(graph, modPath);
		if (mod == null) continue;
		const loadErr = loadFailure(mod, ` [${modPath}]`);
		if (loadErr != "") return `ERROR: ${loadErr}`;
	}

	checkModuleGraph(graph, "");
	return emitJSTwoPhase(graph, null, canonEntries);
}

// Two-phase JS emission shared by compileProjectToJS / compileProjectToJSWithStd.
// Phase 1 checks + expands macros for EVERY module before phase 2 transforms any:
// transformProgram mutates the registered module AST in place, and a later
// module's macro expansion compiles helpers from the DECLARING module's AST —
// interleaving hands the macro engine a backend-lowered body (gen-20 root 1).
// Macro diagnostics are severity-Error but non-fatal (gen-20 root 2), so
// hasErrors after expandMacros is the loud-failure check.
function emitJSTwoPhase(graph: ModuleGraph, entryFilter: MapEntry[] | null, canonEntries: MapEntry[]): string {
	const unitPaths: string[] = [];
	const unitPrograms: Node[] = [];
	const unitCtxs: CheckerContext[] = [];
	for (const modPath of graph.loadOrder) {
		if (entryFilter != null && !isEntryPath(canonEntries, modPath)) continue;
		const mod = findModule(graph, modPath);
		if (mod == null) continue;

		const unit = checkedUnit(modPath);
		if (unit == null) return `ERROR: ${uncheckedError(mod)}`;
		const ctx = unit.ctx;
		if (hasErrors(ctx)) return checkErrorMessage(unit);

		const expanded = expandMacros(unit.program, ctx);
		if (hasErrors(ctx)) {
			let msg = `ERROR: expand [${modPath}]:`;
			for (const err of ctx.errors) {
				msg = `${msg} ${err.message}`;
			}
			return msg;
		}

		if (isEntryPath(canonEntries, modPath)) {
			refuseSyncAwaitOnJs(ctx, expanded);
			if (hasErrors(ctx)) {
				let msg = `ERROR: check [${modPath}]:`;
				for (const err of ctx.errors) {
					msg = `${msg} ${err.message}`;
				}
				return msg;
			}
		}

		unitPaths.push(modPath);
		unitPrograms.push(expanded);
		unitCtxs.push(ctx);
	}

	const pendingInsts = drainPendingInstances(unitCtxs);
	for (const instNode of pendingInsts) {
		if (instNode.nodeType == null && instNode.resolvedSym != null && instNode.resolvedSym.symbolType != null) {
			instNode.nodeType = instNode.resolvedSym.symbolType;
		}
		let owner = "";
		if (instNode.resolvedSym != null && instNode.resolvedSym.modulePath != "") {
			owner = instNode.resolvedSym.modulePath;
		}
		let targetIdx: int32 = -1;
		for (let pi: int32 = 0; pi < unitPaths.length; pi += 1) {
			if (unitPaths[pi] == owner) { targetIdx = pi; }
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
	resetBuildState();
	const canonEntries: MapEntry[] = [];
	for (const e of entries) {
		canonEntries.push({ entryPath: canonicalModulePath(e.entryPath), entrySource: e.entrySource });
	}
	entryPath = canonicalModulePath(entryPath);
	const provider = createMapProvider(providerEntries(canonEntries));
	provider.useFileSystem = true;
	const root = resolveRuntimeDir();
	const stdPath = root != "" ? join(root, "std") : "std";
	const config = createDefaultConfig(Backend.JS, stdPath);
	const graph = loadModuleGraphWithConfig(entryPath, provider, config);
	if (graph.errors.length > 0) {
		let msg = "ERROR: graph:";
		for (const e of graph.errors) {
			msg = `${msg} ${e}`;
		}
		return msg;
	}
	for (const modPath of graph.loadOrder) {
		if (!isEntryPath(canonEntries, modPath)) continue;
		const mod = findModule(graph, modPath);
		if (mod == null) continue;
		const loadErr = loadFailure(mod, ` [${modPath}]`);
		if (loadErr != "") return `ERROR: ${loadErr}`;
	}

	checkModuleGraph(graph, stdPath, ".jms");
	return emitJSTwoPhase(graph, canonEntries, canonEntries);
}

test "contains basic" {
	assert "hello world".contains("world");
	assert "hello world".contains("hello");
	assert !"hello".contains("world");
	assert "abc".contains("");
	assert !"".contains("abc");
}

test "a second compile in one process emits the hook bodies again" {
	const cls = "class C { s: string = \"\"; }\nconst c = new C();\nc.s = \"a\" + \"b\";\nconsole.log(c.s);\n";
	const rec = "struct S { s: string; }\nfunction run(): void { const a: S = { s: \"x\" + \"y\" }; console.log(a.s); }\nrun();\n";
	for (const src of [cls, rec, cls, rec]) {
		const c = compileToC(src);
		assert c.ok && c.value.contains("msStringDecref((*self).s);"), c.ok ? "hook body missing" : c.error;
	}
}

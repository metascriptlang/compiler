// MetaScript Compiler CLI — compile command

import { exit, exec, execFile, platform, cwd } from "std/process";
import { exists, readFile } from "std/fs";
import { writeStderr } from "std/io";
import { parseSource } from "../parser/statements/validation";
import { ClassDeclData, DecoratedDeclData, ExportDeclData, InterfaceDeclData, Node, NodeKind, ProgramData, StructDeclData, SymbolKind, Type } from "../ast/node";
import { exportedFunctionOf } from "../checker/decoratorHelpers";
import { CheckerContext, ExportedSymInfo, GcMode, hasErrors, hasFatalErrors, errorCount, findModuleExports, Severity } from "../checker/context";
import { checkProgramWithRegistry } from "../checker/checkPass";
import { checkModuleGraph, getPreludeContext, setGraphCheckTiming, loadStdGlobalImportModules, loadExtraGlobalImportModules } from "../checker/orchestrator";
import { ExportRegistry } from "../checker/context";
import { validateTypedAST } from "../checker/validate";
import { transformProgram } from "../transform/index";
import { analyzeProgram } from "../analyzer/index";
import { monomorphizeProgram } from "../monomorphize/collect";
import { generateJS, generateJSBundleModule, generateJSModule } from "../codegen/js/jsgen";
import { SourceInfo, createSourceInfo, appendInfo, toSourceMapJson, ignoredFileIndexes } from "../codegen/js/sourcemap";
import { escapeJSString } from "../codegen/js/emit";
import { generateRaiserProject, RaiserModuleInput } from "../codegen/raiser/rgen";
import { takeRaiserCompileErrors } from "../codegen/raiser/context";
import { createContext as createRaiserContext, load as raiserLoad, execute as raiserExecute } from "../raiser/context";
import { RaiserValueKind } from "../raiser/value";
import { CModuleOutput, generatePreparedCModuleOutput, genHcrCoreDispatcher, genHcrImageDispatcher, genProjectDispatcher, prepareCModuleEmission } from "../codegen/c/index";
import { mangleModuleName, mangleProcName, mangleQualified, safeName } from "../codegen/c/names";
import { aliveSetHasModule, createAliveSet, AliveSet, CEmissionFacts } from "../codegen/c/context";
import { genTestDispatcher } from "../codegen/c/test";
import { registerCoreParsers } from "../parser/statements/core";
import { computeAliveSet } from "../checker/reachability";
import { collectFreestandingAsync, freestandingAsyncLoc, FREESTANDING_ASYNC_MSG } from "../checker/freestanding";
import { getSimpleTypeDesc } from "../codegen/c/types";
import { TargetInfo, hostTargetInfo, hasGenericParams, isAwaitable, setConcurrentTypeQueries } from "../checker/types";
import { SymbolFlag, hasFlag } from "../checker/symbol";
import { transformForNative } from "../transform/native/index";
import { refineTypes } from "../transform/typeRefine";
import { transformForRaiser } from "../transform/raiserLowering";
import { lowerNativeAccess } from "../transform/native/nativeLower";
import { liftHcrState } from "../transform/native/hcrLift";
import { HcrImport, HcrIndirectModule, lowerHcrIndirection } from "../transform/native/hcrIndirect";
import { lookupModuleCtx, lookupModuleProgram } from "../checker/instantiate";
import { setOuterProgramForComptime, setOuterCheckContext } from "./meta/callbacks";
import { createTransformContextWithChecker, createNameSet } from "../transform/context";
import { setGlobalHookOwners, useHookOwners } from "../transform/lowering/destructorLifting";
import { createModuleGraph, findModule, addModule, ModuleGraph, Module, ModuleState, createModule, createImportEntry, ModuleError, ErrorSeverity } from "../module/graph";
import { canonicalModulePath, createFileSystemProvider, loadModule, provideSource, SourceProvider, takeInlineHeaderTimings, registerHeaderCache, inlineHeaderImports } from "../module/loader";
import { registerPreludeStampFn, preludePackKey, tryLoadPreludeDeps, setStdGraphDepsSnapshot, PreludeDepsSnapshot, DepsModuleRow, DepsImportRow, DepsCircularRow } from "../checker/preludePack";
import { ResolverConfig, createDefaultConfig, Backend } from "../module/resolver";
import { readLockfile, entryName } from "./package/lockfile";
import { registrySrcPath, gitSrcPath } from "./package/cache";
import { drainPendingInstances } from "../checker/instantiate";
import { ResolveSection, DepsSection, defaultResolveSection, defaultDepsSection, loadBuildConfig } from "./buildConfig";
import { evaluateComptimeBlocks } from "./meta/comptime";
import { expandMacros } from "./meta/expand";
import { ensureHostTableLoaded } from "./meta/hostTable";
import { CliOptions, Target, MODE_DANGER } from "./options";
import { atomicWriteFile, writeOutput, printTiming, verboseLog, replaceExt, ensureDir, exeSuffix, soSuffix, outDirForMode } from "./io";
import { compileCFile, linkObjects, archiveStatic, linkSolana, appendFlag, cliCompileFlags, cliLinkFlags, resolveBpfClang, resolveSbfLinker, markCppCompile, getCompilerName, resolveLto } from "./cc";
import { resolveCC } from "./toolchain";
import { linkFlags as globalLinkFlags, linkObjects as globalLinkObjects } from "../utils/linkState";
import { initCache, stableOFileFp, fullCompileCmd, isCompileCached, writeCompileCache, computeFingerprint, nativeDepFile, nativeDependenciesKnown, registerNativeDependencies, projectCacheChanged, writeProjectCache, stableCFileFp, isCCodeCached, writeCSource, moduleCompileFp, writeCompileFingerprintFp, invalidateCompileCache, isLinkCached, writeLinkCache, cacheDir, headerInlineKey, lookupHeaderInline, storeHeaderInline, hashContent, toolchainStamp } from "./cache";
import { splitCcFlags, quoteCcArg } from "../utils/commandLine";
import { error, success, bold, dim, green, red, yellow, cyan, blue } from "../utils/color";
import { resolveRuntimeDir } from "../utils/path";
import { join, isAbsolute, dirname, basename, relative, normalize } from "std/fs/path";
import { HcrAbiExport, HcrModuleAbi, HcrReloadDecision, HcrReloadKind, HcrReloadReason, buildHcrModuleAbi, classifyHcrReload, createHcrAbiExport, hcrAbiFingerprint, hcrExportKey, hcrLayoutKey, hcrReloadDiagnostic, hcrSignatureKey, parseHcrAbiBundle, serializeHcrAbiBundle } from "./hcrAbi";
import { VERSION } from "./usage";

// Header-inline disk cache injection (loader can't import ./cache directly —
// checker/context → module/graph layering; callbacks pattern). Registered at
// module load so every later build engages it without an init-order hazard.
registerHeaderCache(headerInlineKey, lookupHeaderInline, storeHeaderInline);
// Prelude pack shares the object cache's memoized toolchainStamp — one stamp
// computation per process instead of two (the pack's local fallback would
// re-hash the 30MB binary + runtime/ + vendor/ every process).
registerPreludeStampFn(toolchainStamp);

// ===== Build Helpers =====

// Build ResolverConfig from CLI target + optional build.ms resolve section.

function addFileDepRoots(deps: DepsSection, baseDir: string, roots: DepsSection, depth: number = 0): void {
	if (depth > 20) return; // prevent runaway on deep non-cyclic trees
	let i = 0;
	while (i < deps.keys.length) {
		const name = deps.keys[i];
		const ver = deps.values[i];
		if (ver.length > 5 && ver.slice(0, 5) == "file:") {
			const relPath = ver.slice(5, ver.length);
			const absPath = isAbsolute(relPath) ? relPath : join(baseDir, relPath);
			let alreadyVisited = false;
			for (const v of roots.values) { if (v == absPath) alreadyVisited = true; }
			if (!alreadyVisited) {
				roots.keys.push(name);
				roots.values.push(absPath);
				// Recursively read this dep's own build.ms for transitive file: deps
				const depBuildMs = join(absPath, "build.ms");
				if (exists(depBuildMs)) {
					const depCfg = loadBuildConfig(depBuildMs, false);
					if (depCfg.valid) {
						addFileDepRoots(depCfg.deps, absPath, roots, depth + 1);
						addFileDepRoots(depCfg.devDeps, absPath, roots, depth + 1);
					}
				}
			}
		}
		i = i + 1;
	}
}

export function depRoots(projectRoot: string): DepsSection {
	const roots = defaultDepsSection();
	if (projectRoot != "") {
		const cfg = loadBuildConfig(join(projectRoot, "build.ms"), false);
		if (cfg.valid) {
			addFileDepRoots(cfg.deps, projectRoot, roots);
			addFileDepRoots(cfg.devDeps, projectRoot, roots);
		}
	}
	const lockPath = projectRoot != "" ? join(projectRoot, "msc.lock") : "msc.lock";
	const lock = readLockfile(lockPath);
	if (lock.valid) {
		for (const entry of lock.entries) {
			const name = entryName(entry.key);
			let srcPath = "";
			if (entry.source == "git" && entry.url != "" && entry.commit != "") {
				srcPath = gitSrcPath(entry.url, entry.commit);
			} else if (entry.version != "") {
				srcPath = registrySrcPath(name, entry.version);
			}
			if (srcPath != "") {
				roots.keys.push(name);
				roots.values.push(srcPath);
			}
		}
	}
	return roots;
}

export function buildResolverConfig(target: Target, resolve: ResolveSection, targetOs: string = platform, projectRoot: string = ""): ResolverConfig {
	let backend = Backend.C;
	if (target == Target.JS) { backend = Backend.JS; }
	if (target == Target.Raiser) { backend = Backend.Raiser; }
	if (targetOs == "wasm" || targetOs == "emcc") { backend = Backend.Wasm; }
	// Resolve stdPath from project root.
	const root = resolveRuntimeDir();
	const stdPath = root != "" ? join(root, "std") : "std";
	const config = createDefaultConfig(backend, stdPath);
	// Override with build.ms settings if provided
	if (resolve.extensions.length > 0) {
		config.extensions = resolve.extensions;
	}
	if (resolve.searchPaths.length > 0) {
		config.searchPaths = resolve.searchPaths;
	}
	if (resolve.aliasKeys.length > 0) {
		config.aliasKeys = resolve.aliasKeys;
		config.aliasValues = resolve.aliasValues;
	}
	// projectRoot is found by walking up from CWD for build.ms (Go/Rust convention)
	// and passed in from the CLI entry point.
	const roots = depRoots(projectRoot);
	let ri = 0;
	while (ri < roots.keys.length) {
		config.aliasKeys.push(roots.keys[ri]);
		config.aliasValues.push(roots.values[ri]);
		ri = ri + 1;
	}
	return config;
}

// Report graph-level errors (e.g., missing entry) and circular dep warnings.
function reportGraphErrors(graph: ModuleGraph): void {
	for (const err of graph.errors) {
		printDiag(red("graph error: ") + err);
	}
	for (const dep of graph.circularDeps) {
		let circMsg = `circular import: ${dep.fromPath} <-> ${dep.toPath}`;
		if (dep.importLine > 0) {
			circMsg = circMsg + ` (line ${dep.importLine})`;
		}
		printDiag(yellow("warning: ") + circMsg);
	}
}

// Get a specific line from source text (1-based line number)
function getSourceLine(source: string, lineNum: number): string {
	if (source.byteLength == 0 || lineNum <= 0) return "";
	const lines = source.split("\n");
	const idx = (lineNum as int32) - 1;
	if (idx < 0 || idx >= lines.length) return "";
	return lines[idx];
}

function printDiag(line: string): void {
	writeStderr(line + "\n");
}

// Render a single structured error in Rust-style format
function renderModuleError(modPath: string, source: string, e: ModuleError): void {
	// Header: "error: message" or "warning: message"
	const isWarn = e.severity == ErrorSeverity.Warning;
	const levelStr = match (isWarn) {
		true => bold(yellow("warning")),
		false => bold(red("error")),
	};
	printDiag(levelStr + ": " + bold(e.message));

	// Location: "  --> file:line:col"
	if (e.line > 0) {
		let locStr = `  ${bold(cyan("-->"))} ${modPath}:${e.line}`;
		if (e.column > 0) {
			locStr = `${locStr}:${e.column}`;
		}
		printDiag(locStr);

		// Source line + caret
		const srcLine = getSourceLine(source, e.line);
		if (srcLine.byteLength > 0) {
			const lineNumStr = e.line.toString();
			const pad = "   ";
			// Separator: "   |"
			printDiag(blue(pad + " |"));
			// Source:    "42 | source code here"
			printDiag(blue(lineNumStr + " | ") + srcLine);
			// Caret:    "   |     ^^^"
			if (e.column > 0) {
				let caretPad = "";
				let ci = 0;
				while (ci < e.column - 1 && ci < 4096) {
					caretPad = caretPad + " ";
					ci = ci + 1;
				}
				printDiag(blue(pad + " | ") + caretPad + green("^"));
			}
		}
	} else {
		// No line info — show file only
		printDiag(`  ${bold(cyan("-->"))} ${modPath}`);
	}
	printDiag("");
}

// Report per-module errors without exiting (for non-fatal type errors).
let _renderErrorMax: int32 = 0;

function overErrorMax(rendered: int32): boolean {
	return _renderErrorMax > 0 && rendered >= _renderErrorMax;
}

function reportModuleErrors(graph: ModuleGraph, prefix: string): void {
	let rendered: int32 = 0;
	for (const mod of graph.modules) {
		if (mod.errors.length > 0) {
			for (const e of mod.errors) {
				if (overErrorMax(rendered)) return;
				renderModuleError(mod.path, mod.source, e);
				rendered = rendered + 1;
			}
		}
	}
}

// Abort build if checker found fatal errors (e.g. assert outside test block).
// Standard reference equivalent: globalError raises recoverable error.
function exitOnFatalCheckerErrors(ctx: CheckerContext, modPath: string, source: string): void {
	if (!hasFatalErrors(ctx)) return;
	for (const e of ctx.errors) {
		if (e.fatal) {
			renderModuleError(modPath, source, {
				message: e.message,
				line: e.line,
				column: e.column,
				severity: ErrorSeverity.Error,
			});
		}
	}
	exit(1);
}

// Macro-machinery diagnostics (body compile failures, evaluator unavailable) are
// severity-Error but never fatal — exitOnFatalCheckerErrors lets them through.
function exitOnCheckerErrors(ctx: CheckerContext, modPath: string, source: string): void {
	if (!hasErrors(ctx)) return;
	for (const e of ctx.errors) {
		if (e.severity != Severity.Error) continue;
		renderModuleError(modPath, source, {
			message: e.message,
			line: e.line,
			column: e.column,
			severity: ErrorSeverity.Error,
		});
	}
	exit(1);
}

// Report per-module ERRORS and exit if any found. Warning-severity entries
// (e.g. surfaced C-header diagnostics) are left for reportModuleErrors to
// render once — rendering them here too would double-print, and exiting on
// them would turn every warning fatal.
function exitOnModuleErrors(graph: ModuleGraph, prefix: string): void {
	let hasErr = false;
	let rendered: int32 = 0;
	for (const mod of graph.modules) {
		for (const e of mod.errors) {
			if (e.severity != ErrorSeverity.Error) continue;
			hasErr = true;
			if (overErrorMax(rendered)) continue;
			renderModuleError(mod.path, mod.source, e);
			rendered = rendered + 1;
		}
	}
	if (hasErr) exit(1);
}

// Load module graph, validate, and cross-module type check. Exits on errors.
// Always config-aware — uses ResolverConfig for backend extensions, std/, search paths.
// Commands without build.ms pass buildResolverConfig(target, defaultResolveSection()).
// Module-level ExportRegistry + PreludeContext — populated by loadAndCheckGraph, used by build loops
let graphRegistry: ExportRegistry = null as unknown as ExportRegistry;
let graphPreludeCtx: CheckerContext = null as unknown as CheckerContext;

// Global set of compiled .o file paths — deduplicates @compile directives across modules.
// Reference parity: @compile directive processes each unique file path exactly once.
let _compiledOFiles: HashSet<string> = new HashSet<string>();

function resetCompiledOFiles(): void {
	_compiledOFiles = new HashSet<string>();
}

// Resolve the gc mode the build will actually run with, BEFORE the graph is
// checked — the checker needs it (freestanding async gate) and it must agree
// with what codegen/cc see later. Freestanding targets carry no allocator of
// their own, so they imply --gc=manual; an explicit --gc= always wins for
// bare (the user asked for it), while solana keeps its older unconditional
// force because its SBF runtime cannot host DRC/ORC at all.
// Mutates opts so every later consumer reads one resolved value.
export function resolveTargetGcMode(opts: CliOptions): void {
	if (opts.targetOs == "solana") {
		if (opts.gcMode == "" || opts.gcMode == "drc" || opts.gcMode == "orc") opts.gcMode = "manual";
		return;
	}
	if (opts.targetOs == "bare" && !opts.gcExplicit) opts.gcMode = "manual";
}

// String gc mode → checker enum. Single spelling of the mapping that
// applyGcMode and the per-module stamping in cmdBuildC/cmdTest repeat.
export function gcModeOf(gc: string): GcMode {
	if (gc == "none") return GcMode.None;
	if (gc == "manual") return GcMode.Manual;
	if (gc == "drc") return GcMode.Drc;
	return GcMode.Orc;
}

// Apply --gc flag: set GcMode on the shared prelude context so all modules inherit it.
// analyzeProgram checks ctx.gcMode and skips DRC injection for None/Manual.
export function applyGcMode(opts: CliOptions): void {
	if (graphPreludeCtx == null) return;
	if (opts.gcMode == "none") graphPreludeCtx.gcMode = GcMode.None;
	else if (opts.gcMode == "manual") graphPreludeCtx.gcMode = GcMode.Manual;
	else if (opts.gcMode == "orc") graphPreludeCtx.gcMode = GcMode.Orc;
	graphPreludeCtx.targetOs = opts.targetOs;
	graphPreludeCtx.targetInfo = opts.targetInfo;
}

// Loader-half timing gate, twin of the orchestrator's setGraphCheckTiming —
// both fire under -t so one flag split stays observable in one place.
let graphLoadTiming: boolean = false;
export function setGraphLoadTiming(on: boolean): void {
	graphLoadTiming = on;
}

function loadAndCheckGraph(entryPath: string, verbose: boolean, config: ResolverConfig, targetOs: string = platform, targetInfo: TargetInfo = hostTargetInfo(), gcMode: GcMode = GcMode.Orc): ModuleGraph {
	if (verbose) verboseLog(`loading module graph from ${entryPath}`);
	const provider = createFileSystemProvider();

	// Load preludes FIRST so they end up at the start of graph.loadOrder.
	// loadOrder is the init order (see genProjectDispatcher in codegen/c/index.ms);
	// preludes are implicit deps of every user module, so their module-level
	// globals (e.g. INITIAL_CAPACITY in std/core/struct.ms) must be ready
	// before any user-module __Init000 touches them.
	const graph = createModuleGraph();
	// Split the "graph load+check" phase: this block is the LOADER half
	// (parse of every module in the closure — prelude tree included), the
	// orchestrator PROFILE line covers the check half. Build-perf §1.
	// Backend ext feeds the prelude pack KEY, so it must be known before the
	// prelude loads (A2 seeds the graph from a key-named deps file).
	const backendExt = config.extensions.length > 0 ? config.extensions[0] : ".cms";
	const _gl0 = performance.now();
	if (config.stdPath != "") {
		loadPreludeModules(graph, provider, config, backendExt);
	}
	const _pl0 = performance.now();
	const _r = loadModule(graph, entryPath, provider, config, 1);
	if (graphLoadTiming) {
		const ih = takeInlineHeaderTimings();
		console.log(`    graphLoad: preludeMods=${performance.now() - _gl0}ms entryTree=${performance.now() - _pl0}ms modules=${graph.loadOrder.length} seed=${_preludeSeedHit ? 1 : 0} inlineHeader=${ih.ms}ms/${ih.n}mods hits=${ih.hits}`);
	}

	reportGraphErrors(graph);
	if (graph.errors.length > 0) exit(1);
	exitOnModuleErrors(graph, "error");

	if (verbose) verboseLog("cross-module type check");
	// Pass targetOs through so @platform("...") directives are filtered against
	// the build target during collectDirectives. Without this, modules check
	// with stale ctx.targetOs → mac directives leak into a cross-compile
	// windows build's linkFlags().
	graphRegistry = checkModuleGraph(graph, config.stdPath, backendExt, targetOs, targetInfo, gcMode);
	graphPreludeCtx = getPreludeContext();
	reportModuleErrors(graph, "type error");
	// Standard reference parity (main.nim: `if conf.errorCounter > 0: return` before
	// cgenWriteModules): the gate lives in the shared funnel, so no command can reach
	// codegen with type errors. reportModuleErrors already rendered them — count only.
	let graphErrors = 0;
	for (const mod of graph.modules) {
		for (const e of mod.errors) {
			if (e.severity == ErrorSeverity.Error) graphErrors = graphErrors + 1;
		}
	}
	if (graphErrors > 0) {
		printDiag(`${error("error")}: ${graphErrors} type error(s) found, stopping before codegen`);
		exit(1);
	}
	return graph;
}

// Load prelude modules (globalImports) into the module graph.
// Extension resolved by the resolver based on target backend.
//
// BUILD-PERF Phase A2: on a warm key the graph is SEEDED from the deps pack
// (<key>.deps, written next to the prelude pack). provideSource and
// inlineHeaderImports still run per module — mod.source and header
// diagnostics must stay byte-identical to the fresh path — only the
// lex+parse+resolver-probe discovery of the std closure is skipped. Any
// doubt (pack off, no snapshot, a source gone missing) falls back to the
// fresh parse path below, which then re-captures the snapshot for the
// writer.
let _preludeSeedHit: boolean = false;

function loadPreludeModules(graph: ModuleGraph, provider: SourceProvider, config: ResolverConfig, backendExt: string): void {
	_preludeSeedHit = false;
	if (config.stdPath != "") {
		const deps = tryLoadPreludeDeps(preludePackKey(config.stdPath, backendExt));
		if (deps != null && seedPreludeModules(graph, provider, deps)) _preludeSeedHit = true;
	}
	if (!_preludeSeedHit) {
		loadStdGlobalImportModules(graph, provider, config);
		if (config.stdPath != "") captureStdGraphDeps(graph, preludePackKey(config.stdPath, backendExt));
	}
	loadExtraGlobalImportModules(graph, provider, config);
}

// Replay a deps snapshot into the graph. All sources are provided UP FRONT —
// the seed either builds the whole closure or leaves the graph untouched
// (a half-seeded graph would poison the fresh fallback: modules already in
// loadOrder). Header-inline runs exactly like the fresh path; module state
// jumps straight to Ready (no importStack walk — no recursion happens).
function seedPreludeModules(graph: ModuleGraph, provider: SourceProvider, deps: PreludeDepsSnapshot): boolean {
	const sources: string[] = [];
	let mi = 0;
	while (mi < deps.mods.length) {
		const raw = provideSource(provider, deps.mods[mi].path);
		if (!raw.ok) return false;
		sources.push(raw.value);
		mi = mi + 1;
	}
	mi = 0;
	while (mi < deps.mods.length) {
		const row = deps.mods[mi];
		const mod = createModule(row.path);
		const headerErrors: ModuleError[] = [];
		mod.source = inlineHeaderImports(sources[mi], row.path, provider, false, headerErrors);
		for (const he of headerErrors) mod.errors.push(he);
		let ii = 0;
		while (ii < row.imports.length) {
			const imp = row.imports[ii];
			mod.imports.push(createImportEntry(imp.names, imp.aliases, imp.sourcePath, imp.sourceSpecifier));
			ii = ii + 1;
		}
		mod.state = ModuleState.Ready;
		addModule(graph, mod);
		graph.loadOrder.push(mod.path);
		mi = mi + 1;
	}
	let ci = 0;
	while (ci < deps.circulars.length) {
		const c = deps.circulars[ci];
		graph.circularDeps.push({ fromPath: c.fromPath, toPath: c.toPath, cycle: c.cycle, importLine: c.importLine, importNames: c.importNames });
		ci = ci + 1;
	}
	return true;
}

// Capture the std closure (this graph's ENTIRE loadOrder — preludeModules
// runs before the entry tree, so it is exactly the prelude closure) for the
// deps writer. Element-wise copies: the graph outlives this function and
// the snapshot outlives the graph — sharing arrays would couple their DRC
// lifetimes for no gain.
function captureStdGraphDeps(graph: ModuleGraph, key: string): void {
	const mods: DepsModuleRow[] = [];
	for (const p of graph.loadOrder) {
		const m = findModule(graph, p);
		if (m == null) continue;
		const imports: DepsImportRow[] = [];
		let ii = 0;
		while (ii < m.imports.length) {
			const ie = m.imports[ii];
			const names: string[] = [];
			let ni = 0;
			while (ni < ie.names.length) { names.push(ie.names[ni]); ni = ni + 1; }
			const aliases: string[] = [];
			let ai = 0;
			while (ai < ie.aliases.length) { aliases.push(ie.aliases[ai]); ai = ai + 1; }
			imports.push({ names, aliases, sourcePath: ie.sourcePath, sourceSpecifier: ie.sourceSpecifier });
			ii = ii + 1;
		}
		mods.push({ path: p, imports });
	}
	const circulars: DepsCircularRow[] = [];
	let ci = 0;
	while (ci < graph.circularDeps.length) {
		const c = graph.circularDeps[ci];
		const cycle: string[] = [];
		let yi = 0;
		while (yi < c.cycle.length) { cycle.push(c.cycle[yi]); yi = yi + 1; }
		const importNames: string[] = [];
		let inmi = 0;
		while (inmi < c.importNames.length) { importNames.push(c.importNames[inmi]); inmi = inmi + 1; }
		circulars.push({ fromPath: c.fromPath, toPath: c.toPath, cycle, importLine: c.importLine as int32, importNames });
		ci = ci + 1;
	}
	setStdGraphDepsSnapshot({ mods, circulars }, key);
}

// Parse source or exit with error message.
function parseOrExit(source: string, modPath: string): Node {
	const pr = parseSource(source);
	if (!pr.ok) {
		printDiag(`${error("parse error")} [${modPath}]: ${pr.error}`);
		exit(1);
	}
	return pr.value;
}

// Stored result of Phase A (transform all modules) for Phase B (DCE) and Phase C (codegen).
interface ProcessedModule {
	program: Node;
	ctx: CheckerContext;
	modPath: string;
}

interface ModuleEmissionJob {
	slot: int32;
	program: Node;
	ctx: CheckerContext;
	modPath: string;
	weight: int32;
}

class ModuleEmissionResult {
	slot: int32 = 0;
	output: CModuleOutput = new CModuleOutput();
	failure: string = "";
	completed: boolean = false;
	started: float64 = 0;
	finished: float64 = 0;
}

type ModuleEmitter = (job: Readonly<ModuleEmissionJob>, aliveSet: Readonly<AliveSet>, facts: Readonly<CEmissionFacts>, isTestBuild: boolean, isHcr: boolean) => ModuleEmissionResult;

function emitModuleJob(job: Readonly<ModuleEmissionJob>, aliveSet: Readonly<AliveSet>, facts: Readonly<CEmissionFacts>, isTestBuild: boolean, isHcr: boolean): ModuleEmissionResult {
	const result = new ModuleEmissionResult();
	result.slot = job.slot;
	result.started = performance.now();
	try {
		result.output = generatePreparedCModuleOutput(job.program, job.ctx, job.modPath, aliveSet, isTestBuild, isHcr, facts);
	} catch (e) {
		result.failure = e.message;
	}
	result.finished = performance.now();
	result.completed = true;
	return result;
}

function emissionOverlapped(results: ModuleEmissionResult[]): boolean {
	for (let i = 0; i < results.length; i += 1) {
		if (!results[i].completed) continue;
		for (let j = i + 1; j < results.length; j += 1) {
			if (!results[j].completed) continue;
			if (results[i].started < results[j].finished && results[j].started < results[i].finished) return true;
		}
	}
	return false;
}

function emitModulesBounded(jobs: ModuleEmissionJob[], aliveSet: Readonly<AliveSet>, facts: Readonly<CEmissionFacts>, workers: int32, isTestBuild: boolean, hcrEntry: string, emitter: ModuleEmitter = emitModuleJob): ModuleEmissionResult[] {
	const results: ModuleEmissionResult[] = [];
	for (let i = 0; i < jobs.length; i += 1) results.push(new ModuleEmissionResult());
	const order = emissionOrder(jobs);
	const pending: Promise<ModuleEmissionResult>[] = [];
	let next = 0;
	let head = 0;
	let failed = false;
	while (true) {
		while (!failed && next < order.length && next - head < workers) {
			const job = jobs[order[next]];
			pending.push(spawn(() => emitter(job, aliveSet, facts, isTestBuild, hcrEntry != "" && job.modPath == hcrEntry)));
			next += 1;
		}
		if (head == next) break;
		const result = await pending[head];
		head += 1;
		results[result.slot] = result;
		if (result.failure != "" || result.output.errors.length > 0) failed = true;
	}
	return results;
}

function emissionOrder(jobs: ModuleEmissionJob[]): int32[] {
	const order: int32[] = [];
	const weights: int32[] = [];
	for (let i = 0; i < jobs.length; i += 1) {
		const weight = jobs[i].weight;
		let at = order.length;
		order.push(i);
		weights.push(weight);
		while (at > 0 && weights[at - 1] < weight) {
			order[at] = order[at - 1];
			weights[at] = weights[at - 1];
			at -= 1;
		}
		order[at] = i;
		weights[at] = weight;
	}
	return order;
}

function probeModuleEmission(job: Readonly<ModuleEmissionJob>, aliveSet: Readonly<AliveSet>, facts: Readonly<CEmissionFacts>, isTestBuild: boolean, isHcr: boolean): ModuleEmissionResult {
	const result = new ModuleEmissionResult();
	result.slot = job.slot;
	result.output.modulePath = job.modPath;
	result.started = performance.now();
	while (performance.now() - result.started < 10) {}
	result.finished = performance.now();
	result.completed = true;
	return result;
}

function probeFailedModuleEmission(job: Readonly<ModuleEmissionJob>, aliveSet: Readonly<AliveSet>, facts: Readonly<CEmissionFacts>, isTestBuild: boolean, isHcr: boolean): ModuleEmissionResult {
	const result = probeModuleEmission(job, aliveSet, facts, isTestBuild, isHcr);
	if (job.slot == 2) result.failure = "injected";
	return result;
}

function probeDiagnosticModuleEmission(job: Readonly<ModuleEmissionJob>, aliveSet: Readonly<AliveSet>, facts: Readonly<CEmissionFacts>, isTestBuild: boolean, isHcr: boolean): ModuleEmissionResult {
	const result = probeModuleEmission(job, aliveSet, facts, isTestBuild, isHcr);
	if (job.slot == 2) result.output.errors.push({ message: "injected", line: 0, column: 0, endLine: 0, endColumn: 0, fatal: false, severity: Severity.Error, tags: 0 });
	return result;
}

test "bounded module emission preserves slots and joins before stopping" {
	const jobs: ModuleEmissionJob[] = [];
	for (let slot = 0; slot < 12; slot += 1) {
		jobs.push({ slot, program: null as unknown as Node, ctx: null as unknown as CheckerContext, modPath: slot.toString(), weight: 0 });
	}
	const aliveSet = createAliveSet();
	const facts = new CEmissionFacts();
	for (const workers of [1, 2, 4, 8]) {
		const complete = emitModulesBounded(jobs, aliveSet, facts, workers, false, "", probeModuleEmission);
		assert complete.length == jobs.length;
		for (let slot = 0; slot < complete.length; slot += 1) {
			assert complete[slot].completed;
			assert complete[slot].slot == slot;
			assert complete[slot].output.modulePath == slot.toString();
		}
		if (workers > 1) assert emissionOverlapped(complete);
		for (const emitter of [probeFailedModuleEmission, probeDiagnosticModuleEmission]) {
			const failed = emitModulesBounded(jobs, aliveSet, facts, workers, false, "", emitter);
			let completed = 0;
			for (let slot = 0; slot < failed.length; slot += 1) {
				if (!failed[slot].completed) continue;
				assert failed[slot].slot == slot;
				assert failed[slot].output.modulePath == slot.toString();
				completed += 1;
			}
			assert completed <= 2 + workers;
		}
	}
}

// Build state for C compilation: flags + include path registry.
interface CBuildState {
	allFlags: string;
	includePaths: HashSet<string>;
}

function flagArgsOrExit(flags: string): string[] {
	const parsed = splitCcFlags(flags);
	if (parsed.ok) return parsed.value;
	printDiag(`${error("error")}: ${parsed.error}`);
	exit(1);
	return [];
}

// Dedupe on merge: many modules' @passC carry the same -I dirs (the crypto
// prelude chain repeats its 5 vendor dirs per importing module); appending
// them raw duplicated each dir hundreds of times until the cc command line
// crossed CreateProcessW's 32767-char ceiling — spawn then fails with a bare
// "fork/exec failed" (exit -1). Keep first occurrence, preserve order.
function mergeFlagsDeduped(base: string, add: string): string {
	if (add == "") return base;
	const seen: HashSet<string> = new HashSet<string>();
	for (const tok of flagArgsOrExit(base)) {
		if (tok != "") seen.add(tok);
	}
	let result = base;
	for (const tok of flagArgsOrExit(add)) {
		if (tok == "") continue;
		if (seen.has(tok)) continue;
		seen.add(tok);
		result = appendFlag(result, quoteCcArg(tok));
	}
	return result;
}

function initCBuildState(opts: CliOptions): CBuildState {
	let allFlags = cliCompileFlags(opts);
	const includePaths: HashSet<string> = new HashSet<string>();
	// Always register compiler root (std lib @compile paths resolve here).
	// Stable across projects — stdlib/runtime .c files compiled with the same
	// command text everywhere, so ccache's global store can deduplicate them.
	const compilerRoot = resolveRuntimeDir();
	if (compilerRoot != "") {
		includePaths.add(compilerRoot);
		allFlags = appendFlag(allFlags, quoteCcArg(`-I${compilerRoot}`));
	}
	// Project root is NOT added to global flags — it varies per project and
	// would invalidate ccache deduplication for stdlib compiles. Instead it is
	// passed as a per-module flag only for user-code modules (which actually
	// reference project-root-relative paths like `#include "src/foo.h"`). See
	// userProjectFlag() below and call sites in processCompileDirectives +
	// per-module .ms → .c compile.
	// --os=bare/solana: force-include manual.h before all .c files (runtime .c files need the defines)
	if ((opts.targetOs == "bare" || opts.targetOs == "solana") && compilerRoot != "") {
		let defines = "-DMSOS_BARE";
		if (opts.targetOs == "solana") defines = "-DMSOS_SOLANA -DMSOS_BARE";
		allFlags = appendFlag(allFlags, defines);
		allFlags = appendFlag(allFlags, "-include");
		allFlags = appendFlag(allFlags, quoteCcArg(`${compilerRoot}/runtime/manual.h`));
	}
	// --os=wasm/emcc: define MSOS_WASM/MSOS_EMCC for runtime @compile files (disables threading)
	if (opts.targetOs == "wasm") {
		allFlags = appendFlag(allFlags, "-DMSOS_WASM");
	}
	if (opts.targetOs == "emcc") {
		allFlags = appendFlag(allFlags, "-DMSOS_EMCC");
	}
	return { allFlags, includePaths };
}

// Returns "-I<projectRoot>" for user-code paths, empty for stdlib paths.
// Stdlib/runtime .c and .ms are referenced by absolute paths under
// compilerRoot — those never include project-root headers, so we drop the
// project-specific flag to keep the compile command stable across projects
// (ccache can then dedupe globally). Anything NOT under compilerRoot is
// user code (path may be absolute under projectRoot, or relative to cwd),
// which needs -I<projectRoot> to resolve `import {...} from "./foo.h"`.
function isUnder(path: string, dir: string): boolean {
	if (dir == "" || path == "") return false;
	if (path == dir) return true;
	if (!path.startsWith(dir)) return false;
	// Require separator after prefix to avoid `/foo/bar` matching `/foo/barbaz`.
	const next = path.charAt(dir.length);
	return next == "/" || next == "\\";
}

function userProjectFlag(path: string, projectRoot: string, compilerRoot: string): string {
	if (projectRoot == "" || projectRoot == compilerRoot) return "";
	if (path == "" || path == ".") return "";
	if (isUnder(path, compilerRoot)) return "";
	return quoteCcArg(`-I${projectRoot}`);
}

// Resolve a relative directory path against the include search list.
// Mirrors @compile path resolution (processCompileDirectives): try CWD first,
// then search registered include paths (which contain compilerRoot).
function resolveIncludeDir(dir: string, includePaths: HashSet<string>): string {
	if (dir == "" || isAbsolute(dir)) return dir;
	if (exists(dir)) return dir;
	for (const ip of includePaths) {
		const candidate = `${ip}/${dir}`;
		if (exists(candidate)) return candidate;
	}
	return dir;
}

// Resolve relative -I/-iquote/-isystem paths in a flags string using the
// same rule as @compile: try CWD, then search includePaths. Lets std @passC
// directives work from any CWD when the compiler is installed elsewhere.
function resolveIncludeFlags(flags: string, includePaths: HashSet<string>): string {
	if (flags == "") return flags;
	let result = "";
	for (const p of flagArgsOrExit(flags)) {
		let resolved = p;
		if (p.length > 2 && p.slice(0, 2) == "-I") {
			resolved = "-I" + resolveIncludeDir(p.slice(2, p.length), includePaths);
		} else if (p.length > 7 && p.slice(0, 7) == "-iquote") {
			resolved = "-iquote" + resolveIncludeDir(p.slice(7, p.length), includePaths);
		} else if (p.length > 8 && p.slice(0, 8) == "-isystem") {
			resolved = "-isystem" + resolveIncludeDir(p.slice(8, p.length), includePaths);
		}
		result = appendFlag(result, quoteCcArg(resolved));
	}
	return result;
}

// Register -I/-iquote paths from a module's compiler flags into the include path set.
function registerIncludePaths(flags: string, paths: HashSet<string>): void {
	if (flags == "") return;
	for (const p of flagArgsOrExit(flags)) {
		if (p.length > 2 && p.slice(0, 2) == "-I") paths.add(p.slice(2, p.length));
		else if (p.length > 7 && p.slice(0, 7) == "-iquote") paths.add(p.slice(7, p.length));
	}
}

// One work item for the parallel compile phase. All fields captured by the
// spawn closure via per-closure env snapshot (lambda lifting allocates a fresh
// env per iteration inside a loop — see project_lambda_lifting_loop_escape).
interface CompileJob {
	fullPath: string;
	oFile: string;
	cPath: string;         // original spec, used for error reporting
	fileFlags: string;
	fp: string;            // precomputed fingerprint; written post-compile
	dependencyFile: string;
}

// Process @compile("foo.c") directives: compile each .c file to .o relative to module dir.
//
// Parallel architecture:
//   1. GATHER (serial) — parse directives, dedup via _compiledOFiles, filter
//      cache hits, precompute fingerprints.
//   2. DISPATCH (parallel) — spawn one worker per cache miss. Each worker calls
//      compileCFile() on its own thread — real thread-level parallelism.
//   3. COLLECT (serial, main thread) — waitFor each future in input order, check
//      exit codes, publish cache entries, emit oFiles deterministically.
// --emit=c is emit-only: write generated C, compile/link nothing.
// Compiling @compile'd C here would (a) drop .o files beside the source, not in
// out/, and (b) fail for targets whose sysroot lives in the host build tool
// (e.g. --os=ios → Xcode owns the SDK). The host assembles those .c in its own
// project. Set by cmdBuildC.
let emitOnlyMode = false;

function processCompileDirectives(directives: string, moduleDir: string, includePaths: HashSet<string>, allFlags: string, mode: number, ccOption: number, ccBinary: string, verbose: boolean, targetOs: string, projectRoot: string, compilerRoot: string): string[] {
	if (emitOnlyMode) return [];
	if (directives == "") return [];
	// Per-call user-project flag: non-empty only when moduleDir is user code.
	// Applied to every @compile job this call emits (all share same moduleDir).
	const upFlag = userProjectFlag(moduleDir, projectRoot, compilerRoot);

	// === 1. GATHER ===
	const jobs: CompileJob[] = [];
	const hitOFiles: string[] = [];
	let start = 0;
	let idx = 0;
	while (idx <= directives.length) {
		let atEnd = idx == directives.length;
		let atNewline = false;
		if (!atEnd) {
			atNewline = directives.slice(idx, idx + 1) == "\n";
		}
		if (atEnd || atNewline) {
			if (idx > start) {
				const entry = directives.slice(start, idx);
				// Per-file custom flags: "file.c\t-O3" (tab-separated from collectOneDirective)
				let cPath = entry;
				let customFlags = "";
				const tabPos = entry.indexOf("\t");
				if (tabPos >= 0) {
					cPath = entry.slice(0, tabPos);
					customFlags = entry.slice(tabPos + 1, entry.length);
				}
				// ./ or ../ prefix: resolve relative to the declaring module's directory.
				// Bare paths: try CWD, then search registered include paths.
				let fullPath = cPath;
				if (cPath.slice(0, 2) == "./" || cPath.slice(0, 3) == "../") {
					fullPath = `${moduleDir}/${cPath}`;
				} else if (!exists(fullPath)) {
					for (const dir of includePaths) {
						const candidate = `${dir}/${cPath}`;
						if (exists(candidate)) { fullPath = candidate; break; }
					}
				}
				if (!exists(fullPath)) {
					printDiag(`${error("error")}: @compile cannot find: ${fullPath}`);
					exit(1);
				}
				// Mark C++ at directive-resolution time (main thread, sequential)
				// so the flag is set regardless of cache-hit / dedup / fresh-compile.
				// See cc.ms `markCppCompile` for the why.
				markCppCompile(fullPath);
				let probeFlags = allFlags;
				if (upFlag != "") probeFlags = appendFlag(probeFlags, upFlag);
				if (customFlags != "") probeFlags = appendFlag(probeFlags, customFlags);
				const probeKey = fullCompileCmd(ccOption, mode, probeFlags, ccBinary);
				const dependencyFile = nativeDepFile(fullPath, probeKey);
				const dependenciesKnown = nativeDependenciesKnown(fullPath, probeKey);
				const probeFp = computeFingerprint(fullPath, probeKey);
				const probeOFile = stableOFileFp(fullPath, probeFp);
				if (!_compiledOFiles.has(dependencyFile)) {
					_compiledOFiles.add(dependencyFile);
					const fileFlags = probeFlags;
					const fp = probeFp;
					const oFile = probeOFile;
					if (isCompileCached(oFile, fp, dependenciesKnown)) {
						if (verbose) verboseLog(`  @compile ${fullPath} → ${oFile} ${dim("(cached)")}`);
						hitOFiles.push(oFile);
					} else {
						jobs.push({ fullPath, oFile, cPath, fileFlags, fp, dependencyFile });
					}
				}
			}
			start = idx + 1;
		}
		idx = idx + 1;
	}

	// === 2. DISPATCH (parallel) ===
	if (verbose) {
		for (const j of jobs) {
			verboseLog(`  @compile ${j.fullPath} → ${j.oFile}`);
		}
	}
	// Parallel @compile path keeps a simple number future to avoid heavy generic
	// Result<void, ProcessError> wrapping across the spawn boundary. Stderr loss
	// at this boundary is acceptable: per-job stderr was already streamed to the
	// parent terminal by the spawn dispatcher in previous versions, and the
	// failure path here just exit(1)s after logging. Direct serial compile/link
	// paths (cmdBuildC body) preserve full Result + stderr display.
	const futures: Promise<number>[] = [];
	for (const j of jobs) {
		futures.push(spawn(() => {
			let r = compileCFile(j.fullPath, j.oFile, j.dependencyFile, j.fileFlags, mode, ccOption, ccBinary);
			if (!r.ok && r.error.exitCode == 0) {
				// exitCode 0 with !ok = the process never ran (posix_spawn failure,
				// e.g. transient EAGAIN under fork pressure from N parallel jobs).
				// One retry absorbs it; a real compile error has a nonzero exitCode
				// and is not retried.
				r = compileCFile(j.fullPath, j.oFile, j.dependencyFile, j.fileFlags, mode, ccOption, ccBinary);
			}
			if (r.ok) return 0;
			// Surface the failure reason — the parallel path otherwise discards
			// stderr and the join loop only reports the exit code.
			if (r.error.errorOutput != "") printDiag(r.error.errorOutput);
			return r.error.exitCode != 0 ? r.error.exitCode : -1;
		}));
	}
	const exitCodes: number[] = [];
	for (const f of futures) exitCodes.push(await f);

	// === 3. COLLECT (serial from main thread) ===
	const oFiles: string[] = [];
	for (const o of hitOFiles) oFiles.push(o);
	let ci = 0;
	while (ci < jobs.length) {
		const j = jobs[ci];
		const code = exitCodes[ci];
		if (code != 0) {
			// Freestanding targets carry no libc/socket layer, so a prelude @compile
			// naming a platform engine (std/net -> runtime/io/engineSelect.c) cannot
			// build there. The module itself is dead code on these targets; dropping
			// the object is the same call already made for BPF.
			if (targetOs == "solana" || targetOs == "bare") {
				const why = targetOs == "solana" ? "BPF unsupported" : "freestanding: no libc";
				console.log(`  ${dim("skip")} @compile ${j.cPath} ${dim(`(${why})`)}`);
				ci = ci + 1;
				continue;
			}
			printDiag(`${error("error")}: @compile failed for ${j.fullPath} ${dim(`(exit ${code})`)}`);
			exit(1);
		}
		registerNativeDependencies(j.fullPath, fullCompileCmd(ccOption, mode, j.fileFlags, ccBinary));
		writeCompileCache(j.oFile, j.fp);
		oFiles.push(j.oFile);
		ci = ci + 1;
	}
	return oFiles;
}

// One work item for the parallel per-module compile phase (Phase C).
// Same closure-capture rules as CompileJob. modPath "" = dispatcher job
// (no fingerprint, failure is fatal at the call site).
interface ModuleCompileJob {
	cFile: string;
	oFile: string;
	modPath: string;
	flags: string;
	fp: string;
	slot: number;
}

// DISPATCH+JOIN for Phase C module compiles — same architecture as
// processCompileDirectives: one spawn per job, number-typed futures (stderr
// printed by the worker), join in input order on the main thread.
function dispatchCompileJobs(jobs: ModuleCompileJob[], mode: number, ccOption: number, ccBinary: string): number[] {
	// Warm lazy cc detection globals on the main thread so workers only read.
	getCompilerName(ccOption, ccBinary);
	const futures: Promise<number>[] = [];
	for (const j of jobs) {
		futures.push(spawn(() => {
			let r = compileCFile(j.cFile, j.oFile, "", j.flags, mode, ccOption, ccBinary);
			if (!r.ok && r.error.exitCode == 0) {
				// exitCode 0 with !ok = the process never ran (posix_spawn EAGAIN
				// under fork pressure). One retry absorbs it; real compile errors
				// have a nonzero exitCode and are not retried.
				r = compileCFile(j.cFile, j.oFile, "", j.flags, mode, ccOption, ccBinary);
			}
			if (r.ok) return 0;
			if (r.error.errorOutput != "") printDiag(r.error.errorOutput);
			return r.error.exitCode != 0 ? r.error.exitCode : -1;
		}));
	}
	const codes: number[] = [];
	for (const f of futures) codes.push(await f);
	return codes;
}

// ===== Dependency File Output =====

function writeDepsFile(graph: ModuleGraph, entryPath: string, outDir: string): void {
	let depsContent = "";
	for (const modPath of graph.loadOrder) {
		depsContent = depsContent + modPath + "\n";
	}
	const depsPath = `${outDir}/${replaceExt(basename(entryPath), ".deps")}`;
	writeOutput(depsPath, depsContent);
	console.log(dim(`  wrote deps → ${depsPath}`));
}

// ===== Change Detection =====

// ===== JS Build =====

// `relative` bails out to an absolute path unless both sides are absolute, so
// an `--output` spelled relative to the cwd has to be resolved first.
function mapDirOf(outPath: string): string {
	const d = dirname(outPath);
	return isAbsolute(d) ? d : join(cwd(), d);
}

function countNewlines(s: string): int32 {
	let n: int32 = 0;
	for (let i: int32 = 0; i < s.byteLength; i += 1) {
		if (s.byteAt(i) == "\n".code) n += 1;
	}
	return n;
}

function readSourceText(path: string): string {
	const r = readFile(path);
	if (!r.ok) return "";
	return r.value;
}

export function cmdBuildJS(entryPath: string, outputDir: string, opts: CliOptions): void {
	// Split mode is what a bundler plugin consumes: one ES module per source
	// module, imports already relative inside the tree, nothing executed.
	if (opts.splitModules) {
		const splitRoot = opts.outputPath != "" ? opts.outputPath : (outputDir != "" ? outputDir : "out/esm");
		const t0 = performance.now();
		const entryCanon = canonicalModulePath(entryPath);
		const tree = emitJSModuleTree(entryCanon, opts, false, splitRoot);
		// The source→output mapping is the compiler's to state: a bundler
		// plugin that re-derives it has to replicate project-root discovery
		// exactly, and silently resolves nothing when the two disagree.
		let manifest = "{\n  \"entry\": \"" + escapeJSString(entryCanon) + "\",\n  \"modules\": [\n";
		for (let i = 0; i < tree.modulePaths.length; i += 1) {
			const sep = i + 1 < tree.modulePaths.length ? "," : "";
			manifest = `${manifest}    { "source": "${escapeJSString(tree.modulePaths[i])}", "out": "${escapeJSString(tree.moduleOutRels[i])}" }${sep}\n`;
		}
		manifest = `${manifest}  ]\n}\n`;
		writeOutput(`${splitRoot}/_manifest.json`, manifest);
		if (opts.showTime) printTiming("emitted", t0);
		console.log(success(`${tree.modulePaths.length} module(s) → ${bold(splitRoot)}`));
		return;
	}
	entryPath = canonicalModulePath(entryPath);
	registerCoreParsers();
	const config = buildResolverConfig(Target.JS, defaultResolveSection());
	const graph = loadAndCheckGraph(entryPath, opts.verbose, config, opts.targetOs, opts.targetInfo);
	const outDir = outputDir != "" ? outputDir : "out";
	// Project root for deriving module IDs
	const projectRoot = config.stdPath.length > 4 ? config.stdPath.slice(0, config.stdPath.length - 4) : dirname(entryPath);

	// Build import source → module ID mapping for all modules
	// This maps how modules reference each other (import specifier) to the __mod["id"] key
	const modIdValues: string[] = [];
	const modIdKeys: string[] = [];
	for (const modPath of graph.loadOrder) {
		const mod = findModule(graph, modPath);
		if (mod == null) continue;
		const moduleId = replaceExt(relative(projectRoot, modPath), "");
		modIdKeys.push(modPath);
		modIdValues.push(moduleId);
		// Also register the import specifier form (e.g., "std/process" for "std/process/index")
		for (const imp of mod.imports) {
			modIdKeys.push(imp.sourceSpecifier);
			modIdValues.push(moduleId);
		}
	}

	// Collect all external @import entries (from .jms files), dedup by modulePath
	const extImportKeys: string[] = [];
	const extImportNames: string[][] = [];

	// Single-file bundle: accumulate all module code
	let bundle = "";
	let compiled = 0;
	// Each module's map is recorded from its own line 0, so composing them into
	// one bundle map needs the line each module landed on.
	const moduleSmaps: SourceInfo[] = [];
	const moduleSmapLines: int32[] = [];
	let bundleLines: int32 = 0;

	// Phase 1 — check + expand + comptime for EVERY module before any backend
	// transform runs: transformProgram mutates the registered module AST in
	// place, and a later module's macro expansion compiles helpers from the
	// DECLARING module's AST — transforming first hands the macro engine a
	// backend-lowered body the raiser prelude cannot resolve (msStringConcat).
	const unitPaths: string[] = [];
	const unitPrograms: Node[] = [];
	const unitCtxs: CheckerContext[] = [];
	for (const modPath of graph.loadOrder) {
		const mod = findModule(graph, modPath);
		if (mod == null) continue;

		const program = parseOrExit(mod.source, modPath);
		const ctx = checkProgramWithRegistry(program, graphRegistry, graph, mod, graphPreludeCtx);
		ctx.strictDefs = opts.strictDefs;
		ctx.strictNullChecks = opts.strictNullChecks;
		exitOnFatalCheckerErrors(ctx, modPath, mod.source);
		ctx.errors = [];
		validateTypedAST(ctx, program);
		ctx.errors = [];

		// Collect external imports from @import registry
		for (const entry of ctx.jsImportRegistry) {
			let found = false;
			for (let ei = 0; ei < extImportKeys.length; ei += 1) {
				if (extImportKeys[ei] == entry.modulePath) {
					// Merge names
					for (const n of entry.names) {
						let dup = false;
						for (const existing of extImportNames[ei]) { if (existing == n) { dup = true; } }
						if (!dup) extImportNames[ei].push(n);
					}
					found = true;
				}
			}
			if (!found) {
				extImportKeys.push(entry.modulePath);
				const names: string[] = [];
				for (const n of entry.names) { names.push(n); }
				extImportNames.push(names);
			}
		}

		const macroExpanded = expandMacros(program, ctx);
		exitOnCheckerErrors(ctx, modPath, mod.source);
		unitPaths.push(modPath);
		unitPrograms.push(evaluateComptimeBlocks(macroExpanded));
		unitCtxs.push(ctx);
	}

	const pendingInsts = drainPendingInstances();
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
		if (targetIdx < 0) {
			for (let pi: int32 = 0; pi < unitPaths.length; pi += 1) {
				if (unitPaths[pi] == entryPath) { targetIdx = pi; }
			}
		}
		if (targetIdx >= 0) {
			(unitPrograms[targetIdx].data as ProgramData).programStmts.push(instNode);
		}
	}

	// Phase 2 — backend transform + codegen
	for (let ui = 0; ui < unitPaths.length; ui += 1) {
		const modPath = unitPaths[ui];
		const mod = findModule(graph, modPath);
		if (mod == null) continue;
		const transformed = transformProgram(unitPrograms[ui], unitCtxs[ui], true);
		exitOnCheckerErrors(unitCtxs[ui], modPath, mod.source);

		// Build per-module import specifier → module ID mapping
		const localMapKeys: string[] = [];
		const localMapValues: string[] = [];
		for (let gi = 0; gi < modIdKeys.length; gi += 1) {
			localMapKeys.push(modIdKeys[gi]);
			localMapValues.push(modIdValues[gi]);
		}
		for (const imp of mod.imports) {
			const resolvedId = replaceExt(relative(projectRoot, imp.sourcePath), "");
			localMapKeys.push(imp.sourceSpecifier);
			localMapValues.push(resolvedId);
		}

		const moduleId = replaceExt(relative(projectRoot, modPath), "");
		const isPrelude = moduleId.startsWith("std/core/");
		const result = generateJSBundleModule(transformed, localMapValues, localMapKeys, isPrelude, modPath, opts.sourcemap);

		const separator = `\n// --- Module: ${moduleId} ---\n`;
		bundle = bundle + separator;
		if (opts.sourcemap) {
			bundleLines += countNewlines(separator);
			moduleSmaps.push(result.smap);
			moduleSmapLines.push(bundleLines);
			bundleLines += countNewlines(result.code);
		}
		bundle = bundle + result.code;
		compiled = compiled + 1;
	}

	// Assemble final output: header + external imports + module registry + all modules
	let output = "// Generated by MetaScript Compiler (single-file bundle)\n";
	for (let ei = 0; ei < extImportKeys.length; ei += 1) {
		output = output + "import { ";
		for (let ni = 0; ni < extImportNames[ei].length; ni += 1) {
			if (ni > 0) output = output + ", ";
			output = output + extImportNames[ei][ni];
		}
		output = output + ` } from "${extImportKeys[ei]}";\n`;
	}
	const headerLines = opts.sourcemap ? countNewlines(output) : 0 as int32;
	output = output + bundle;

	// `--output` wins here exactly as it does for the C binary. Deriving the
	// name from the entry file alone collides for directory-style programs,
	// which are all spelled `main.ms`.
	const outPath = opts.outputPath != ""
		? opts.outputPath
		: `${outDir}/${replaceExt(basename(entryPath), ".js")}`;
	ensureDir(dirname(outPath));
	// The link comment goes after the map is built; it sits past every mapped
	// line, so it shifts nothing.
	if (opts.sourcemap) {
		const mapName = `${basename(outPath)}.map`;
		const combined = createSourceInfo();
		for (let mi = 0; mi < moduleSmaps.length; mi += 1) {
			appendInfo(combined, moduleSmaps[mi], (headerLines + moduleSmapLines[mi]) as int32);
		}
		const stdRootForMap = config.stdPath;
		const stdIgnored = ignoredFileIndexes(combined, (p: string): boolean => stdRootForMap != "" && p.startsWith(stdRootForMap));
		writeOutput(`${outPath}.map`, toSourceMapJson(combined, basename(outPath), mapDirOf(outPath), readSourceText, stdIgnored));
		output = `${output}\n//# sourceMappingURL=${mapName}\n`;
	}
	writeOutput(outPath, output);
	console.log(success(`${compiled} module(s) bundled → ${bold(outPath)}`));
}

// Platform-specific runtime compile — dispatch + selectors + pool + fs.
function compilePlatformRuntime(includePaths: HashSet<string>, allFlags: string, opts: CliOptions): string[] {
	if (opts.targetOs == "bare" || opts.targetOs == "solana") return [];

	let rtFiles = "";
	if (opts.targetOs == "emcc") {
		// Single-threaded: Asyncify-based async. spawn/Actor not yet supported.
		rtFiles = "runtime/promise/dispatchEmcc.c";
	} else if (opts.targetOs == "wasm") {
		rtFiles = "runtime/promise/dispatchWasm.c";
	} else {
		// Desktop: full dispatcher + thread pool + selectors
		rtFiles = "runtime/promise/dispatchFull.c";
		rtFiles = rtFiles + "\n" + "runtime/promise/pool.c";
		rtFiles = rtFiles + "\n" + "runtime/io/engineSelect.c";
		rtFiles = rtFiles + "\n" + "runtime/promise/awaitGroup.c";
		rtFiles = rtFiles + "\n" + "runtime/promise/selectorKqueue.c";
		rtFiles = rtFiles + "\n" + "runtime/promise/selectorEpoll.c";
		rtFiles = rtFiles + "\n" + "runtime/promise/selectorPoll.c";
		rtFiles = rtFiles + "\n" + "runtime/actor/actor.c";
		if (opts.targetOs == "windows") {
			rtFiles = rtFiles + "\n" + "runtime/fs/windows.c";
		} else {
			rtFiles = rtFiles + "\n" + "runtime/fs/posix.c";
		}
	}

	rtFiles = rtFiles + "\n" + "runtime/promise/drain.c";
	if (opts.isHcr) rtFiles = rtFiles + "\n" + "runtime/hcr.c";

	if (rtFiles == "") return [];
	return processCompileDirectives(rtFiles, ".", includePaths, allFlags, opts.mode, opts.ccCompiler, opts.ccBinary, opts.verbose, opts.targetOs, opts.projectRoot, resolveRuntimeDir());
}

// ===== Check =====
// Stop-after-check variant of the build driver: same module graph, same
// resolver config, same cross-module check pass — it simply returns instead of
// continuing into transform/analyze/codegen. loadAndCheckGraph reports and
// exits on any module or type error.

export function cmdCheckC(entryPath: string, opts: CliOptions, resolveSection: ResolveSection = defaultResolveSection()): void {
	entryPath = canonicalModulePath(entryPath);
	registerCoreParsers();
	_renderErrorMax = opts.errorMax;
	resolveTargetGcMode(opts);
	const config = buildResolverConfig(opts.target, resolveSection, opts.targetOs, opts.projectRoot);
	setGraphCheckTiming(opts.showTime);
	setGraphLoadTiming(opts.showTime);
	const graph = loadAndCheckGraph(entryPath, opts.verbose, config, opts.targetOs, opts.targetInfo, gcModeOf(opts.gcMode));
	console.log(`${success("OK")} ${dim(`no type errors in ${graph.loadOrder.length} module(s)`)}`);
}

interface HcrBuildAbi {
	bundlePath: string;
	hadCurrent: boolean;
	current: HcrModuleAbi[];
	candidate: HcrModuleAbi[];
	modulePaths: string[];
}

function hcrBuildRoot(entryPath: string, projectRoot: string): string {
	let root = projectRoot != "" ? normalize(projectRoot) : dirname(entryPath);
	if (!isUnder(entryPath, root)) root = dirname(entryPath);
	return root;
}

function hcrModuleId(modPath: string, root: string, stdPath: string): string {
	if (stdPath != "" && isUnder(modPath, stdPath)) return "";
	if (!isUnder(modPath, root)) return "";
	return replaceExt(relative(root, modPath), "");
}

function hcrFunctionSymbol(
	info: ExportedSymInfo,
	nativeName: string,
	exportName: string,
	flags: uint32,
	disamb: int32,
): string {
	if (info.name == "main") return safeName(info.name);
	if (exportName != "") return exportName;
	if (nativeName != "") return nativeName;
	const baseName = info.originalName != "" ? info.originalName : info.name;
	if ((flags as uint32 as BitSet<SymbolFlag>).has(SymbolFlag.ImportC)) return safeName(baseName);
	return mangleProcName(baseName, mangleModuleName(info.definingModule), disamb);
}
function hcrFunctionSlot(
	info: ExportedSymInfo,
	nativeName: string,
	exportName: string,
	flags: uint32,
	disamb: int32,
): string {
	if (info.name == "main") return safeName(info.name);
	if (exportName != "") return exportName;
	const baseName = info.originalName != "" ? info.originalName : info.name;
	if (nativeName != "") return nativeName;
	if ((flags as uint32 as BitSet<SymbolFlag>).has(SymbolFlag.ImportC)) return safeName(baseName);
	return `${baseName}#${disamb}`;
}


function appendHcrFunctionExport(
	exports: HcrAbiExport[],
	moduleId: string,
	info: ExportedSymInfo,
	t: Type,
	nativeName: string,
	exportName: string,
	flags: uint32,
	disamb: int32,
): Result<void, string> {
	if ((flags as uint32 as BitSet<SymbolFlag>).has(SymbolFlag.OverloadSig)) return Result.ok(null);
	if (hasGenericParams(t)) {
		return Result.err(`HCR ABI cannot represent generic export '${moduleId}::${info.name}'`);
	}
	const symbol = hcrFunctionSymbol(info, nativeName, exportName, flags, disamb);
	const slot = hcrFunctionSlot(info, nativeName, exportName, flags, disamb);
	exports.push(createHcrAbiExport(moduleId, symbol, hcrSignatureKey(t), slot));
	return Result.ok(null);
}

function hcrModuleExports(moduleId: string, modPath: string): Result<HcrAbiExport[], string> {
	const exports: HcrAbiExport[] = [];
	const moduleExports = findModuleExports(graphRegistry, modPath);
	if (moduleExports == null) return Result.ok(exports);
	for (const info of moduleExports.symbols) {
		if (info.definingModule != modPath || info.kind != SymbolKind.Function) continue;
		const primary = appendHcrFunctionExport(
			exports,
			moduleId,
			info,
			info.symType,
			info.nativeName,
			info.exportName,
			info.primaryFlags,
			info.disamb,
		);
		if (!primary.ok) return Result.err(primary.error);
		for (let i = 0; i < info.overloadTypes.length; i += 1) {
			const overload = appendHcrFunctionExport(
				exports,
				moduleId,
				info,
				info.overloadTypes[i],
				i < info.overloadNativeNames.length ? info.overloadNativeNames[i] : "",
				i < info.overloadExportNames.length ? info.overloadExportNames[i] : "",
				i < info.overloadFlags.length ? info.overloadFlags[i] : 0,
				i < info.overloadDisambs.length ? info.overloadDisambs[i] : i + 1,
			);
			if (!overload.ok) return Result.err(overload.error);
		}
	}
	return Result.ok(exports);
}

function prepareHcrBuildAbi(
	graph: ModuleGraph,
	entryPath: string,
	outBinary: string,
	opts: CliOptions,
	compileFlags: string,
	stdPath: string,
): Result<HcrBuildAbi, string> {
	const bundlePath = outBinary + ".hcrabi";
	const hadCurrent = exists(bundlePath);
	let current: HcrModuleAbi[] = [];
	if (hadCurrent) {
		const content = try readFile(bundlePath) catch "";
		if (content == "") return Result.err(`cannot read current HCR ABI bundle '${bundlePath}'`);
		const parsed = parseHcrAbiBundle(content);
		if (!parsed.ok) return Result.err(`invalid current HCR ABI bundle '${bundlePath}': ${parsed.error}`);
		current = parsed.value;
	}
	const built = buildHcrCandidateAbi(graph, entryPath, opts, compileFlags, stdPath);
	if (!built.ok) return Result.err(built.error);
	return Result.ok({
		bundlePath,
		hadCurrent,
		current,
		candidate: built.value.candidate,
		modulePaths: built.value.modulePaths,
	});
}

interface HcrCandidateAbi {
	candidate: HcrModuleAbi[];
	modulePaths: string[];
}

function buildHcrCandidateAbi(
	graph: ModuleGraph,
	entryPath: string,
	opts: CliOptions,
	compileFlags: string,
	stdPath: string,
): Result<HcrCandidateAbi, string> {
	const root = hcrBuildRoot(entryPath, opts.projectRoot);
	const cpu = opts.targetInfo.cpu != "" ? opts.targetInfo.cpu : "host";
	const targetKey = `${opts.targetOs}:${cpu}:${opts.targetInfo.ptrSize}:${opts.targetInfo.floatSize}`;
	const toolchainKey = `${VERSION}:${toolchainStamp()}:${getCompilerName(opts.ccCompiler, opts.ccBinary)}:${hashContent(compileFlags)}`;
	const candidate: HcrModuleAbi[] = [];
	const modulePaths: string[] = [];
	for (const modPath of graph.loadOrder) {
		const moduleId = hcrModuleId(modPath, root, stdPath);
		if (moduleId == "") continue;
		const mod = findModule(graph, modPath);
		if (mod == null) return Result.err(`HCR ABI module '${modPath}' is missing from the graph`);
		const dependencies: string[] = [];
		for (const imported of mod.imports) {
			const dependencyId = hcrModuleId(imported.sourcePath, root, stdPath);
			if (dependencyId == "") continue;
			dependencies.push(dependencyId);
			const shared = hcrSharedVariable(imported.sourcePath, imported.names);
			if (shared != "") {
				return Result.err(`HCR cannot share exported variable '${dependencyId}::${shared}' with module '${moduleId}' across module images; export a function that reads it instead`);
			}
		}
		const exports = hcrModuleExports(moduleId, modPath);
		if (!exports.ok) return Result.err(exports.error);
		const manifest = buildHcrModuleAbi(
			moduleId,
			targetKey,
			opts.gcMode,
			toolchainKey,
			dependencies,
			exports.value,
		);
		if (!manifest.ok) return Result.err(manifest.error);
		candidate.push(manifest.value);
		modulePaths.push(modPath);
	}
	return Result.ok({ candidate, modulePaths });
}

function hcrSharedVariable(sourcePath: string, names: string[]): string {
	const moduleExports = findModuleExports(graphRegistry, sourcePath);
	if (moduleExports == null) return "";
	for (const name of names) {
		for (const info of moduleExports.symbols) {
			if (info.name == name && info.definingModule == sourcePath && info.kind == SymbolKind.Variable) return name;
		}
	}
	return "";
}

function hcrForeignSymbols(modPath: string): HashSet<string> {
	const foreign = new HashSet<string>();
	const moduleExports = findModuleExports(graphRegistry, modPath);
	if (moduleExports == null) return foreign;
	for (const info of moduleExports.symbols) {
		if (info.definingModule != modPath || info.kind != SymbolKind.Function) continue;
		addHcrForeignSymbol(foreign, info, info.nativeName, info.exportName, info.primaryFlags, info.disamb);
		for (let i = 0; i < info.overloadTypes.length; i += 1) {
			addHcrForeignSymbol(
				foreign,
				info,
				i < info.overloadNativeNames.length ? info.overloadNativeNames[i] : "",
				i < info.overloadExportNames.length ? info.overloadExportNames[i] : "",
				i < info.overloadFlags.length ? info.overloadFlags[i] : 0,
				i < info.overloadDisambs.length ? info.overloadDisambs[i] : i + 1,
			);
		}
	}
	return foreign;
}

function addHcrForeignSymbol(
	foreign: HashSet<string>,
	info: ExportedSymInfo,
	nativeName: string,
	exportName: string,
	flags: uint32,
	disamb: int32,
): void {
	const isImportC = (flags as uint32 as BitSet<SymbolFlag>).has(SymbolFlag.ImportC);
	const isBinding = exportName == "" && (nativeName != "" || isImportC);
	if (info.name == "main" || isBinding) {
		foreign.add(hcrFunctionSymbol(info, nativeName, exportName, flags, disamb));
	}
}

function pushDispatcherJob(cJobs: ModuleCompileJob[], oSlots: string[][], key: string, source: string, flags: string, opts: CliOptions): void {
	const fp = moduleCompileFp(source, fullCompileCmd(opts.ccCompiler, opts.mode, flags, opts.ccBinary));
	writeCSource(key, fp, source);
	oSlots.push([]);
	cJobs.push({ cFile: stableCFileFp(key, fp), oFile: stableOFileFp(key, fp), modPath: "", flags, fp: "", slot: oSlots.length - 1 });
}

function moduleOutputFor(outputs: CModuleOutput[], modPath: string): CModuleOutput | null {
	for (const output of outputs) {
		if (output.modulePath == modPath) return output;
	}
	return null;
}

function hcrImageStem(outBinary: string): string {
	const slash = outBinary.lastIndexOf("/");
	const dot = outBinary.lastIndexOf(".");
	return dot > slash ? outBinary.substring(0, dot) : outBinary;
}

function hcrImageExt(outBinary: string): string {
	const slash = outBinary.lastIndexOf("/");
	const dot = outBinary.lastIndexOf(".");
	return dot > slash ? outBinary.substring(dot, outBinary.length) : "";
}

function hcrImagePath(outBinary: string, moduleId: string): string {
	return `${hcrImageStem(outBinary)}.${moduleId.replaceAll("/", ".")}${hcrImageExt(outBinary)}`;
}

function hcrCoreImagePath(outBinary: string, targetOs: string): string {
	const stem = `${hcrImageStem(outBinary)}.core`;
	if (targetOs == "windows") return `${stem}.dll`;
	if (targetOs == "linux") return `${stem}.so`;
	if (targetOs == "darwin" || targetOs == "macos") return `${stem}.dylib`;
	return "";
}

test "HCR core image takes the target's shared-library extension, not the output's" {
	assert hcrCoreImagePath("out/module.hcr", "macos") == "out/module.core.dylib";
	assert hcrCoreImagePath("out/module.hcr", "darwin") == "out/module.core.dylib";
	assert hcrCoreImagePath("out/module.hcr", "linux") == "out/module.core.so";
	assert hcrCoreImagePath("out/module.hcr", "windows") == "out/module.core.dll";
	assert hcrCoreImagePath("out/module.dll", "windows") == "out/module.core.dll";
	assert hcrCoreImagePath("out/app", "linux") == "out/app.core.so";
}

function linkHcrImage(objects: string[], externalInputs: string[], image: string, flags: string, opts: CliOptions): void {
	if (isLinkCached(objects, externalInputs, flags, image, image)) return;
	const linked = linkObjects(objects, image, flags, opts.mode, opts.ccCompiler, opts.ccBinary);
	if (!linked.ok) {
		console.log(`${error("error")}: link failed for HCR image ${image} ${dim(`(exit ${linked.error.exitCode})`)}`);
		if (linked.error.errorOutput != "") console.log(linked.error.errorOutput);
		exit(1);
	}
	writeLinkCache(objects, externalInputs, flags, image, image);
}

function linkHcrImages(
	oSlots: string[][],
	moduleSlots: int32[],
	jobPaths: string[],
	coreSlot: int32,
	imageSlots: int32[],
	hcrModulePaths: string[],
	hcrModules: HcrIndirectModule[],
	entryPath: string,
	outBinary: string,
	allFlags: string,
	opts: CliOptions,
): void {
	let linkFlags = cliLinkFlags(allFlags, opts);
	for (const flag of globalLinkFlags()) linkFlags = appendFlag(linkFlags, flag);
	const externalInputs: string[] = [];
	for (const obj of globalLinkObjects()) externalInputs.push(obj);

	const core = hcrCoreImagePath(outBinary, opts.targetOs);
	let coreFlags = linkFlags;
	let imageFlags = linkFlags;
	let coreInput = core;
	if (opts.targetOs == "windows") {
		coreInput = `${hcrImageStem(outBinary)}.core.lib`;
		coreFlags = appendFlag(coreFlags, "-Wl,--export-all-symbols");
		coreFlags = appendFlag(coreFlags, quoteCcArg(`-Wl,--out-implib,${coreInput}`));
	} else if (opts.targetOs == "linux") {
		coreFlags = appendFlag(coreFlags, quoteCcArg(`-Wl,-soname,${basename(core)}`));
		imageFlags = appendFlag(imageFlags, "-Wl,-rpath,$ORIGIN");
	} else if (opts.targetOs == "darwin" || opts.targetOs == "macos") {
		coreFlags = appendFlag(coreFlags, quoteCcArg(`-Wl,-install_name,@rpath/${basename(core)}`));
		imageFlags = appendFlag(imageFlags, "-Wl,-rpath,@loader_path");
	} else {
		console.log(`${error("error")}: --hcr has no per-module image adapter for target '${opts.targetOs}'`);
		exit(1);
	}

	const coreObjects: string[] = [];
	for (const oFile of oSlots[0]) coreObjects.push(oFile);
	for (let j = 0; j < jobPaths.length; j += 1) {
		if (hcrModulePaths.includes(jobPaths[j])) continue;
		for (const oFile of oSlots[moduleSlots[j]]) coreObjects.push(oFile);
		for (const oFile of oSlots[moduleSlots[j] + 1]) coreObjects.push(oFile);
	}
	for (const oFile of oSlots[coreSlot]) coreObjects.push(oFile);
	for (const obj of externalInputs) coreObjects.push(obj);
	linkHcrImage(coreObjects, externalInputs, core, coreFlags, opts);

	for (let i = 0; i < hcrModulePaths.length; i += 1) {
		const moduleId = hcrModules[i].moduleId;
		if (moduleId == "core") {
			console.log(`${error("error")}: HCR module id 'core' collides with the core image name; rename the module`);
			exit(1);
		}
		const j = jobPaths.indexOf(hcrModulePaths[i]);
		if (j < 0) {
			console.log(`${error("error")}: internal: HCR module '${hcrModulePaths[i]}' was not emitted`);
			exit(1);
		}
		const objects: string[] = [];
		for (const oFile of oSlots[moduleSlots[j]]) objects.push(oFile);
		for (const oFile of oSlots[moduleSlots[j] + 1]) objects.push(oFile);
		for (const oFile of oSlots[imageSlots[i]]) objects.push(oFile);
		objects.push(coreInput);
		const image = hcrModulePaths[i] == entryPath ? outBinary : hcrImagePath(outBinary, moduleId);
		let flags = imageFlags;
		if (opts.targetOs == "windows") flags = appendFlag(flags, quoteCcArg(`-Wl,--out-implib,${cacheDir()}/hcr-${hashContent(image)}.lib`));
		linkHcrImage(objects, externalInputs, image, flags, opts);
	}
}

function hcrTypeInfoNames(program: Node | null, modPath: string): string[] {
	const names: string[] = [];
	if (program == null) return names;
	const moduleName = mangleModuleName(modPath);
	for (const stmt of (program.data as ProgramData).programStmts) {
		let decl = stmt;
		if (decl.kind == NodeKind.DecoratedDecl) {
			const decorated = decl.data as DecoratedDeclData;
			if (decorated.decoratedNode != null) decl = decorated.decoratedNode;
		}
		if (decl.kind == NodeKind.ExportDecl) {
			const exported = decl.data as ExportDeclData;
			if (exported.exportedDecl != null) decl = exported.exportedDecl;
		}
		let name = "";
		if (decl.kind == NodeKind.ClassDecl) name = (decl.data as ClassDeclData).className;
		else if (decl.kind == NodeKind.InterfaceDecl) name = (decl.data as InterfaceDeclData).interfaceName;
		if (name == "" || name.startsWith("$") || name.indexOf("__", 0) >= 0) continue;
		names.push(mangleQualified(name, moduleName));
	}
	return names;
}

function hcrTypeLayoutKeys(program: Node | null): string[] {
	const pairs: string[] = [];
	if (program == null) return pairs;
	for (const stmt of (program.data as ProgramData).programStmts) {
		let decl = stmt;
		if (decl.kind == NodeKind.ExportDecl) {
			const exported = decl.data as ExportDeclData;
			if (exported.exportedDecl != null) decl = exported.exportedDecl;
		}
		let name = "";
		if (decl.kind == NodeKind.ClassDecl) name = (decl.data as ClassDeclData).className;
		else if (decl.kind == NodeKind.InterfaceDecl) name = (decl.data as InterfaceDeclData).interfaceName;
		else if (decl.kind == NodeKind.StructDecl) name = (decl.data as StructDeclData).interfaceName;
		if (name == "" || name.startsWith("$") || decl.resolvedSym == null) continue;
		pairs.push(name);
		pairs.push(hcrLayoutKey(decl.resolvedSym.symbolType));
	}
	return pairs;
}

function hcrReloadHandlers(program: Node | null, flag: SymbolFlag): string[] {
	const names: string[] = [];
	if (program == null) return names;
	for (const stmt of (program.data as ProgramData).programStmts) {
		const fn = exportedFunctionOf(stmt);
		if (fn == null || fn.resolvedSym == null || !hasFlag(fn.resolvedSym, flag)) continue;
		names.push(fn.resolvedSym.exportName);
	}
	return names;
}

function hcrRootFunctions(modulePaths: string[]): string[] {
	const roots: string[] = [];
	for (const modPath of modulePaths) {
		const moduleExports = findModuleExports(graphRegistry, modPath);
		if (moduleExports == null) continue;
		for (const info of moduleExports.symbols) {
			if (info.definingModule != modPath || info.kind != SymbolKind.Function) continue;
			roots.push(modPath + ":" + info.name);
		}
	}
	return roots;
}

function hcrIndirectModules(abi: HcrCandidateAbi): Result<HcrIndirectModule[], string> {
	const modules: HcrIndirectModule[] = [];
	for (let i = 0; i < abi.candidate.length; i += 1) {
		const manifest = abi.candidate[i];
		const foreign = hcrForeignSymbols(abi.modulePaths[i]);
		const symbols: string[] = [];
		for (const item of manifest.exports) symbols.push(foreign.has(item.symbol) ? "" : item.symbol);
		const imports: HcrImport[] = [];
		for (const dependency of manifest.dependencies) {
			const target = hcrManifestById(abi.candidate, dependency);
			if (target == null) return Result.err(`HCR module '${manifest.moduleId}' imports '${dependency}', which has no ABI manifest`);
			imports.push({ moduleId: dependency, abiKey: hcrExportKey(target) });
		}
		modules.push({
			moduleId: manifest.moduleId,
			symbols,
			typeInfos: [],
			typeKeys: [],
			abiKey: hcrExportKey(manifest),
			imports,
			beforeReload: [],
			afterReload: [],
		});
	}
	return Result.ok(modules);
}

function hcrManifestById(manifests: HcrModuleAbi[], moduleId: string): HcrModuleAbi {
	for (const manifest of manifests) {
		if (manifest.moduleId == moduleId) return manifest;
	}
	return null as unknown as HcrModuleAbi;
}
function hcrBundlesMatch(current: HcrModuleAbi[], candidate: HcrModuleAbi[]): boolean {
	if (current.length != candidate.length) return false;
	for (const manifest of candidate) {
		const previous = hcrManifestById(current, manifest.moduleId);
		if (previous == null || hcrAbiFingerprint(previous) != hcrAbiFingerprint(manifest)) return false;
	}
	return true;
}


function hcrPathChanged(paths: string[], path: string): boolean {
	for (const changed of paths) {
		if (changed == path) return true;
	}
	return false;
}

function publishHcrBuildAbi(state: HcrBuildAbi, changedPaths: string[]): void {
	const decisions: HcrReloadDecision[] = [];
	if (state.hadCurrent) {
		for (const current of state.current) {
			if (hcrManifestById(state.candidate, current.moduleId) == null) {
				decisions.push({
					kind: HcrReloadKind.ReloadDependents,
					reason: HcrReloadReason.ModuleRemoved,
					subject: current.moduleId,
				});
			}
		}
		for (let i = 0; i < state.candidate.length; i += 1) {
			const candidate = state.candidate[i];
			const current = hcrManifestById(state.current, candidate.moduleId);
			if (current == null) {
				decisions.push({
					kind: HcrReloadKind.ReloadModule,
					reason: HcrReloadReason.ModuleAdded,
					subject: candidate.moduleId,
				});
			} else if (hcrAbiFingerprint(current) != hcrAbiFingerprint(candidate)) {
				decisions.push(classifyHcrReload(current, candidate));
			} else if (hcrPathChanged(changedPaths, state.modulePaths[i])) {
				decisions.push(classifyHcrReload(current, candidate));
			}
		}
	}

	const encoded = serializeHcrAbiBundle(state.candidate);
	if (!encoded.ok) {
		printDiag(`${error("error")}: cannot serialize HCR ABI bundle: ${encoded.error}`);
		exit(1);
	}
	if (!atomicWriteFile(state.bundlePath, encoded.value)) {
		printDiag(`${error("error")}: cannot publish HCR ABI bundle '${state.bundlePath}'`);
		exit(1);
	}
	for (const decision of decisions) console.log(hcrReloadDiagnostic(decision));
	console.log(`${green("  Wrote")} ${bold(state.bundlePath)}`);
}

// ===== C Build =====
// Loads module graph, two-pass separate compilation:
//   Pass 1: Collect exported prototypes from all modules
//   Pass 2: Full pipeline + codegen + per-module compile to .o
//   Link all .o files into final binary

export function cmdBuildC(entryPath: string, opts: CliOptions, resolveSection: ResolveSection = defaultResolveSection()): void {
	entryPath = canonicalModulePath(entryPath);
	emitOnlyMode = opts.emitC;
	initCache(opts.mode, opts.forceRebuild);
	resetCompiledOFiles();
	registerCoreParsers();
	const t0 = performance.now();
	// Before ANY phase reads it: freestanding targets imply --gc=manual, and the
	// checker needs the resolved mode (freestanding async gate) — applyGcMode
	// below runs too late for that, it only re-stamps the prelude context.
	resolveTargetGcMode(opts);
	resolveCC(opts);
	resolveLto(opts);
	const config = buildResolverConfig(Target.C, resolveSection, opts.targetOs, opts.projectRoot);
	setGraphCheckTiming(opts.showTime);
	setGraphLoadTiming(opts.showTime);
	const graph = loadAndCheckGraph(entryPath, opts.verbose, config, opts.targetOs, opts.targetInfo, gcModeOf(opts.gcMode));
	applyGcMode(opts);

	// Solana: resolve the SBF toolchain, force release mode. The gc force lives
	// in resolveTargetGcMode (it has to happen before the check pass).
	// Both halves come from Anza's platform-tools bundle - a stock LLVM will not
	// do, so the diagnostic points at the bundle rather than at a package manager.
	if (opts.targetOs == "solana") {
		if (opts.mode == 0) opts.mode = 1;
		if (opts.ccBinary == "") {
			const sbfClang = resolveBpfClang();
			if (sbfClang == "") {
				printDiag(`${error("error")}: --os=solana requires a clang with the ${bold("sbf")} target registered`);
				console.log(`  System clang carries ${bold("bpf")}/${bold("bpfel")} (Linux kernel BPF) — a different ABI, not this.`);
				console.log(`  Install Anza platform-tools (${bold("cargo build-sbf")} fetches it to ~/.cache/solana),`);
				console.log(`  or point at one: ${bold("MSC_SBF_CLANG=/path/to/platform-tools/llvm/bin/clang")}`);
				exit(1);
			}
			opts.ccBinary = sbfClang;
		}
		if (resolveSbfLinker() == "") {
			printDiag(`${error("error")}: --os=solana requires ${bold("ld.lld")} beside the SBF clang`);
			console.log(`  Expected it in the same platform-tools ${bold("llvm/bin")} directory.`);
			exit(1);
		}
	}

	// WASM: force release mode, use zig cc with wasm32-wasi target
	if (opts.targetOs == "wasm") {
		if (opts.mode == 0) opts.mode = 1;  // Release (smaller .wasm)
	}

	// Emscripten (browser WASM): use emcc, 32-bit pointers
	if (opts.targetOs == "emcc") {
		if (opts.mode == 0) opts.mode = 1;  // Release (smaller .wasm)
		opts.ccBinary = "emcc";  // emcc for compile + link
	}

	// Compute output binary path early for change detection
	let outBinary = opts.outputPath;
	if (outBinary == "") {
		const outDir = outDirForMode(opts.mode);
		ensureDir(outDir);
		const dynLib = opts.isHcr || opts.appMode == "lib";
		let suffix = dynLib ? soSuffix() : exeSuffix();
		// Use target OS suffix (works for both native + cross since targetOs always set).
		if (opts.targetOs == "windows") suffix = dynLib ? ".dll" : ".exe";
		if (opts.appMode == "staticlib") suffix = ".a";
		if (opts.targetOs == "solana") suffix = ".so";
		if (opts.targetOs == "wasm") suffix = ".wasm";
		if (opts.targetOs == "emcc") suffix = ".js";  // emcc outputs .js + .wasm pair
		outBinary = outDir + "/" + replaceExt(basename(entryPath), "") + suffix;
	}
	outBinary = normalize(outBinary);

	// Project-level cache: skip entire pipeline if nothing changed.
	// Reference-aligned: changeDetectedViaJsonBuildInstructions — early return before codegen.
	const allFlags0 = cliCompileFlags(opts);
	const buildIdentityFlags = cliLinkFlags(allFlags0, opts);
	const projectDeps: string[] = [];
	for (const path of graph.loadOrder) projectDeps.push(path);
	for (const path of globalLinkObjects()) projectDeps.push(path);
	let hcrBuildAbi: HcrBuildAbi = null as unknown as HcrBuildAbi;
	if (opts.isHcr && !opts.emitC) {
		const prepared = prepareHcrBuildAbi(graph, entryPath, outBinary, opts, allFlags0, config.stdPath);
		if (!prepared.ok) {
			printDiag(`${error("error")}: ${prepared.error}`);
			exit(1);
		}
		hcrBuildAbi = prepared.value;
	}
	let hcrModules: HcrIndirectModule[] = [];
	const hcrModulePaths: string[] = [];
	if (opts.isHcr) {
		const abi: Result<HcrCandidateAbi, string> = hcrBuildAbi != null
			? Result.ok({ candidate: hcrBuildAbi.candidate, modulePaths: hcrBuildAbi.modulePaths })
			: buildHcrCandidateAbi(graph, entryPath, opts, allFlags0, config.stdPath);
		if (!abi.ok) {
			printDiag(`${error("error")}: ${abi.error}`);
			exit(1);
		}
		const indirect = hcrIndirectModules(abi.value);
		if (!indirect.ok) {
			printDiag(`${error("error")}: ${indirect.error}`);
			exit(1);
		}
		hcrModules = indirect.value;
		for (const path of abi.value.modulePaths) hcrModulePaths.push(path);
	}
	const projectChanged = projectCacheChanged(projectDeps, outBinary, opts.ccCompiler, opts.ccBinary, opts.mode, buildIdentityFlags);
	const hcrBundleCurrent = hcrBuildAbi == null
		|| (hcrBuildAbi.hadCurrent && hcrBundlesMatch(hcrBuildAbi.current, hcrBuildAbi.candidate));
	if (!projectChanged && hcrBundleCurrent) {
		console.log(success("Up to date") + " " + bold(outBinary));
		if (opts.genDeps) {
			const depsDir = outDirForMode(opts.mode);
			ensureDir(depsDir);
			writeDepsFile(graph, entryPath, depsDir);
		}
		return;
	}

	// Phase A: Parse → Check → Mono → Transform → Analyze all modules, store results
	if (opts.showTime) printTiming("graph load+check", t0);
	const tA = performance.now();
	const processed: ProcessedModule[] = [];
	let transformedPrograms: Node[] = [];
	let transformedPaths: string[] = [];
	const bs = initCBuildState(opts);
	let allFlags = bs.allFlags;
	const includePaths = bs.includePaths;
	let oFiles: string[] = [];
	let totalCheckerErrors = 0;
	// FREESTANDING E01 sites, collected pre-transform in A2, reported post-DCE.
	const fsAsyncHits: { modPath: string, source: string, line: int32, column: int32 }[] = [];

	// Reference parity: global hook ownership registry shared across all modules.
	// First module to need a type's DRC hooks generates them; others get extern protos.
	const sharedHookOwners = createNameSet();
	setGlobalHookOwners(sharedHookOwners);

	// PROFILE: sub-phase timings summed across all modules.
	let tParse: number = 0;
	let tCheck: number = 0;
	let tMono: number = 0;
	let tMacro: number = 0;
	let tXform: number = 0;
	let tRefine: number = 0;
	let tNative: number = 0;
	let tAnalyze: number = 0;
	let tLower: number = 0;

	// Phase A1 — parse + check every module FIRST (no instance drain yet). A generic instance
	// created during a later module's check is OWNED by its defining module (set in
	// instantiateGenericFunction). To emit it in that module's TU — so the generic body's
	// module-private static helpers are visible in the same translation unit — it must be
	// appended to that module's program BEFORE the module's transform/lower runs. Load order
	// is dependency-first, so the owner is already past transform by the time a dependent
	// instantiates it; hence we defer all transform to A2 and route instances by owner between.
	const checkedMods: { program: Node, ctx: CheckerContext, modPath: string, source: string }[] = [];
	const programByPath: HashMap<string, Node> = new HashMap<string, Node>();
	for (const modPath of graph.loadOrder) {
		const mod = findModule(graph, modPath);
		if (mod == null) {
			printDiag(`${error("error")}: internal: module '${modPath}' is in loadOrder but missing from the graph — its code will be skipped`);
			continue;
		}
		// The graph-checker phase (loadAndCheckGraph → checkModuleGraph) already
		// ran the full 3 passes on every module and registered program+ctx
		// (registerModuleProgram/registerModuleCtx). Re-parsing + re-checking here
		// duplicated ~half the build time and re-populated the exact same
		// diagnostics. Reuse the checked pair — reference parity: Nim checks each
		// module exactly once (sem results cached on the module). LSP-only
		// finalization (sgSortRecords, stampJsModulePaths) is skipped on this path.
		const reusedProgram = lookupModuleProgram(modPath);
		const reusedCtx = lookupModuleCtx(modPath);
		if (reusedProgram != null && reusedCtx != null) {
			setOuterProgramForComptime(reusedProgram);
			setOuterCheckContext(graphRegistry, graph, mod, graphPreludeCtx);
			reusedCtx.strictDefs = opts.strictDefs;
			reusedCtx.strictNullChecks = opts.strictNullChecks;
			exitOnFatalCheckerErrors(reusedCtx, modPath, mod.source);
			if (hasErrors(reusedCtx)) {
				totalCheckerErrors = totalCheckerErrors + errorCount(reusedCtx);
			}
			reusedCtx.errors = [];
			checkedMods.push({ program: reusedProgram, ctx: reusedCtx, modPath, source: mod.source });
			programByPath.set(modPath, reusedProgram);
			continue;
		}
		const _tp0 = performance.now();
		const program = parseOrExit(mod.source, modPath);
		tParse = tParse + (performance.now() - _tp0);
		const _tc0 = performance.now();
		const ctx = checkProgramWithRegistry(program, graphRegistry, graph, mod, graphPreludeCtx);
		tCheck = tCheck + (performance.now() - _tc0);
		ctx.strictDefs = opts.strictDefs;
		ctx.strictNullChecks = opts.strictNullChecks;
		exitOnFatalCheckerErrors(ctx, modPath, mod.source);
		// Errors and warnings were already rendered in the graph-checker phase
		// (loadAndCheckGraph → reportModuleErrors). Re-checking here re-populates
		// ctx.errors with the same diagnostics — only count them for the codegen
		// gate; do NOT render again, otherwise every error/warning prints twice.
		if (hasErrors(ctx)) {
			totalCheckerErrors = totalCheckerErrors + errorCount(ctx);
		}
		ctx.errors = [];
		checkedMods.push({ program, ctx, modPath, source: mod.source });
		programByPath.set(modPath, program);
	}

	// Dispatch pending generic instances into their OWNER module's program (the module that
	// defines the generic — `instNode.resolvedSym.modulePath`). Co-location makes the generic
	// body's module-private static helpers visible in the same TU. Owner-less nodes (e.g.
	// per-using-module synthesized helpers, modulePath="") fall back to the entry program so
	// none is dropped. Instances are only ever created during checking (callInstantiateGeneric
	// lives only in the checker), so this single drain after A1 catches them all.
	const pendingInsts = drainPendingInstances();
	for (let ii = 0; ii < pendingInsts.length; ii += 1) {
		const instNode = pendingInsts[ii];
		if (instNode.nodeType == null && instNode.resolvedSym != null && instNode.resolvedSym.symbolType != null) {
			instNode.nodeType = instNode.resolvedSym.symbolType;
		}
		let owner = "";
		if (instNode.resolvedSym != null && instNode.resolvedSym.modulePath != "") {
			owner = instNode.resolvedSym.modulePath;
		}
		let targetProgram: Node | null = null;
		if (owner != "" && programByPath.has(owner)) {
			targetProgram = programByPath.get(owner);
		} else if (programByPath.has(entryPath)) {
			targetProgram = programByPath.get(entryPath);
		}
		if (targetProgram != null) {
			(targetProgram.data as ProgramData).programStmts.push(instNode);
		}
	}

	// Phase A2 — mono → transform → analyze → lower, per module (instances now placed).
	for (let i = 0; i < hcrModulePaths.length; i += 1) {
		const path = hcrModulePaths[i];
		const program = programByPath.has(path) ? programByPath.get(path) : null;
		hcrModules[i].typeInfos = hcrTypeInfoNames(program, path);
		hcrModules[i].typeKeys = hcrTypeLayoutKeys(program);
		hcrModules[i].beforeReload = hcrReloadHandlers(program, SymbolFlag.BeforeReload);
		hcrModules[i].afterReload = hcrReloadHandlers(program, SymbolFlag.AfterReload);
	}
	for (const cm of checkedMods) {
		const program = cm.program;
		const ctx = cm.ctx;
		const modPath = cm.modPath;
		const modT0 = performance.now();
		if (opts.verbose) verboseLog(`transforming ${modPath}`);
		const _tm0 = performance.now();
		const monoed = monomorphizeProgram(program, ctx);
		validateTypedAST(ctx, monoed);
		tMono = tMono + (performance.now() - _tm0);
		if (hasErrors(ctx)) {
			for (const e of ctx.errors) {
				renderModuleError(modPath, cm.source, {
					message: e.message,
					line: e.line,
					column: e.column,
					severity: ErrorSeverity.Warning,
				});
			}
			ctx.errors = [];
		}

		const _tmc0 = performance.now();
		const macroExpanded = expandMacros(monoed, ctx);
		exitOnCheckerErrors(ctx, modPath, cm.source);
		const comptimeResolved = evaluateComptimeBlocks(macroExpanded);
		tMacro = tMacro + (performance.now() - _tmc0);
		// FREESTANDING E01 — the freestanding runtime carries no dispatcher, no
		// thread pool and no await slots, so an emitted await/spawn reaches clang
		// as a wall of undeclared msAwaitSlot* / msFuture* symbols. Collect the
		// sites HERE, before transformProgram: promiseLower erases every AwaitExpr,
		// so a post-transform scan finds nothing. Reporting is deferred to after
		// DCE (below) so async the program never reaches stays silent, and std/ is
		// skipped entirely — the prelude declares async surface for every build.
		if (opts.gcMode == "manual" && !(config.stdPath != "" && modPath.startsWith(config.stdPath))) {
			for (const hitNode of collectFreestandingAsync(comptimeResolved)) {
				const hitLoc = freestandingAsyncLoc(hitNode);
				fsAsyncHits.push({ modPath, source: cm.source, line: hitLoc.line, column: hitLoc.column });
			}
		}
		const hcrSlot = hcrModulePaths.indexOf(modPath);
		if (opts.isHcr) useHookOwners(hcrSlot >= 0 ? createNameSet() : sharedHookOwners);
		const _tx0 = performance.now();
		const transformed = transformProgram(comptimeResolved, ctx, false);
		tXform = tXform + (performance.now() - _tx0);
		const nativeCtx = createTransformContextWithChecker(ctx);
		nativeCtx.rangeChecks = opts.mode != MODE_DANGER;
		const _tr0 = performance.now();
		const typeRefined = refineTypes(transformed, nativeCtx, graphRegistry);
		tRefine = tRefine + (performance.now() - _tr0);
		const _tn0 = performance.now();
		const nativeTransformed = transformForNative(typeRefined, nativeCtx);
		tNative = tNative + (performance.now() - _tn0);
		const hcrLifted = hcrSlot >= 0 ? liftHcrState(nativeTransformed, nativeCtx) : nativeTransformed;
		const hcrResult = hcrSlot >= 0 ? lowerHcrIndirection(hcrLifted, hcrModules[hcrSlot], hcrModules) : hcrLifted;
		if (opts.gcMode == "none") ctx.gcMode = GcMode.None;
			else if (opts.gcMode == "manual") ctx.gcMode = GcMode.Manual;
			else if (opts.gcMode == "orc") ctx.gcMode = GcMode.Orc;
		ctx.targetOs = opts.targetOs;
		ctx.targetInfo = opts.targetInfo;
		const _ta0 = performance.now();
		const preAnErrors = ctx.errors.length;
		const analyzed = analyzeProgram(hcrResult, ctx);
		if (ctx.errors.length > preAnErrors) {
			for (let ei = preAnErrors; ei < ctx.errors.length; ei += 1) {
				printDiag(`${error("error")}: ${modPath}: ${ctx.errors[ei].message}`);
			}
			exit(1);
		}
		tAnalyze = tAnalyze + (performance.now() - _ta0);
		const _tl0 = performance.now();
		const nativeLowered = lowerNativeAccess(analyzed, nativeCtx);
		tLower = tLower + (performance.now() - _tl0);
		const modT1 = performance.now();
		if (opts.showTime && (modT1 - modT0) > 50) {
			printTiming(modPath, modT0);
		}

		processed.push({ program: nativeLowered, ctx, modPath });
		transformedPrograms.push(nativeLowered);
		transformedPaths.push(modPath);

		// Accumulate compiler flags (@passC). Relative -I paths resolved using same
		// rule as @compile (try CWD, then search includePaths which contains compilerRoot).
		const resolved = resolveIncludeFlags(ctx.compilerFlags, includePaths);
		allFlags = mergeFlagsDeduped(allFlags, resolved);
		// @passL/@link go directly to global linkState — no per-module merge
		registerIncludePaths(resolved, includePaths);

	}

	if (opts.showTime) printTiming("phase A (parse+check+transform)", tA);
	if (opts.showTime) {
		console.log(`    parse=${tParse}ms check=${tCheck}ms mono=${tMono}ms macro=${tMacro}ms xform=${tXform}ms refine=${tRefine}ms native=${tNative}ms analyze=${tAnalyze}ms lower=${tLower}ms`);
	}

	// Gate: stop before codegen if any type errors (standard compiler parity).
	// All three reference compilers NEVER proceed to codegen with type errors.
	if (totalCheckerErrors > 0) {
		printDiag(`${error("error")}: ${totalCheckerErrors} type error(s) found, stopping before codegen`);
		exit(1);
	}

	const tB = performance.now();

	// Phase B: Compute DCE alive set on post-transform ASTs (reference-aligned)
	if (opts.verbose) verboseLog("computing alive set (post-transform DCE)");
	const aliveSet = computeAliveSet(transformedPrograms, transformedPaths, entryPath, false, graph, hcrModulePaths, hcrRootFunctions(hcrModulePaths));
	// Release DCE input arrays - no longer needed after alive set computed.
	transformedPrograms = [];
	transformedPaths = [];

	// FREESTANDING E01 — report the async sites collected in A2, but only for
	// modules DCE kept: async in a module nothing reaches is never emitted, so
	// it is not an error. One diagnostic per site, then stop (matching the
	// type-error gate: never reach codegen with a known-unlinkable program).
	if (fsAsyncHits.length > 0) {
		let fsReported = 0;
		for (const h of fsAsyncHits) {
			if (!aliveSetHasModule(aliveSet, h.modPath)) continue;
			renderModuleError(h.modPath, h.source, {
				message: FREESTANDING_ASYNC_MSG,
				line: h.line,
				column: h.column,
				severity: ErrorSeverity.Error,
			});
			fsReported = fsReported + 1;
		}
		if (fsReported > 0) exit(1);
	}

	if (opts.showTime) printTiming("phase B (DCE)", tB);
	const tC = performance.now();

	// Compile prelude @compile directives — unconditional.
	// These are C runtime files, not application code. The linker strips unused sections.
	// For Solana, processCompileDirectives already skips BPF-unsupported .c files.
	const hcrImages = opts.isHcr && !opts.emitC;
	const coreFlags = hcrImages ? appendFlag(allFlags, "-DMS_HCR_CORE") : allFlags;
	const imageFlags = hcrImages ? appendFlag(allFlags, "-DMS_HCR_MODULE") : allFlags;
	if (graphPreludeCtx != null && graphPreludeCtx.compileDirectives != "") {
		const preludeObjs = processCompileDirectives(graphPreludeCtx.compileDirectives, ".", includePaths, coreFlags, opts.mode, opts.ccCompiler, opts.ccBinary, opts.verbose, opts.targetOs, opts.projectRoot, resolveRuntimeDir());
		for (const oFile of preludeObjs) oFiles.push(oFile);
	}

	const rtObjs = compilePlatformRuntime(includePaths, coreFlags, opts);
	for (const oFile of rtObjs) oFiles.push(oFile);

	// Phase C: Codegen + compile each module
	setConcurrentTypeQueries(true);
	const emissionFacts = new CEmissionFacts();
	for (const p of processed) {
		if (!aliveSetHasModule(aliveSet, p.modPath)) continue;
		prepareCModuleEmission(p.program, p.ctx, p.modPath, aliveSet, emissionFacts);
	}
	const emissionJobs: ModuleEmissionJob[] = [];
	for (const p of processed) {
		if (!aliveSetHasModule(aliveSet, p.modPath)) continue;
		emissionJobs.push({ slot: emissionJobs.length, program: p.program, ctx: p.ctx, modPath: p.modPath, weight: p.program.location.endLine });
	}
	const emitStart = performance.now();
	const emitWidth: int32 = opts.emitJobs < 1 ? emissionJobs.length : opts.emitJobs;
	const emissionResults = emitModulesBounded(emissionJobs, aliveSet, emissionFacts, emitWidth, false, opts.isHcr ? entryPath : "");
	let codegenTime: float64 = performance.now() - emitStart;
	if (opts.showTime) {
		console.log(`    emit workers=${emitWidth} overlap=${emissionOverlapped(emissionResults)}`);
		let emitWork: float64 = 0;
		let emitLongest: float64 = 0;
		let emitLongestPath = "";
		for (let eti = 0; eti < emissionResults.length; eti += 1) {
			const spent = emissionResults[eti].finished - emissionResults[eti].started;
			emitWork = emitWork + spent;
			if (spent > emitLongest) {
				emitLongest = spent;
				emitLongestPath = emissionJobs[eti].modPath;
			}
		}
		console.log(`    emit work=${emitWork}ms longest=${emitLongest}ms ${emitLongestPath}`);
	}
	let emissionFailed = false;
	for (let eri = 0; eri < emissionResults.length; eri += 1) {
		const result = emissionResults[eri];
		if (!result.completed) continue;
		const modPath = emissionJobs[eri].modPath;
		if (result.failure != "") {
			printDiag(`${error("error")}: ${modPath}: ${result.failure}`);
			emissionFailed = true;
		}
		for (const diagnostic of result.output.errors) {
			printDiag(`${error("error")}: ${modPath}: ${diagnostic.message}`);
			emissionFailed = true;
		}
	}
	if (emissionFailed) exit(1);
	for (const p of processed) {
		p.program = null as unknown as Node;
		p.ctx = null as unknown as CheckerContext;
	}
	let clangTime: float64 = 0;
	let compiled = 0;
	let modulesRecompiled = 0;
	const recompiledModulePaths: string[] = [];
	const moduleOutputs: CModuleOutput[] = [];
	const cd = cacheDir();
	const oSlots: string[][] = [];
	oSlots.push(oFiles);
	const cJobs: ModuleCompileJob[] = [];
	const moduleSlots: int32[] = [];
	for (let emitIndex = 0; emitIndex < emissionJobs.length; emitIndex += 1) {
		const p = emissionJobs[emitIndex];
		if (opts.verbose) verboseLog(`codegen ${p.modPath}`);

		const output = emissionResults[emitIndex].output;
		const cCode = output.code;
		output.code = "";
		moduleOutputs.push(output);

		const sideFlags = !hcrImages ? allFlags : hcrModulePaths.includes(p.modPath) ? imageFlags : coreFlags;
		// Process @compile("foo.c") directives
		const compileObjs = processCompileDirectives(p.ctx.compileDirectives, dirname(p.modPath), includePaths, sideFlags, opts.mode, opts.ccCompiler, opts.ccBinary, opts.verbose, opts.targetOs, opts.projectRoot, resolveRuntimeDir());
		moduleSlots.push(oSlots.length);
		oSlots.push(compileObjs);

		if (opts.emitC) {
			// Flat, mangled filename keeps every module's C inside out/ — a
			// path-relative name climbs `..` out of out/ for stdlib/runtime
			// modules and drops generated C beside the source tree. The C is
			// linked by symbol (dispatcher calls <mangled>__Init000), so the
			// filename is free to be flat.
			const emitDir = outDirForMode(opts.mode);
			ensureDir(emitDir);
			const emitPath = `${emitDir}/${mangleModuleName(p.modPath)}.c`;
			writeOutput(emitPath, cCode);
			console.log(`${green("  Wrote")} ${bold(emitPath)}`);
		} else {
			let modFlags = appendFlag(sideFlags, quoteCcArg(`-iquote${dirname(p.modPath)}`));
			modFlags = appendFlag(modFlags, quoteCcArg(`-iquote${cd}`));
			// Per-module MS→.c: add -I<projectRoot> only for user modules (paths
			// under projectRoot, not under compilerRoot). Stdlib modules get
			// stable command text so ccache can dedupe across projects.
			const upFlag = userProjectFlag(p.modPath, opts.projectRoot, resolveRuntimeDir());
			if (upFlag != "") modFlags = appendFlag(modFlags, upFlag);
			const compileCmd = fullCompileCmd(opts.ccCompiler, opts.mode, modFlags, opts.ccBinary);
			const modFp = moduleCompileFp(cCode, compileCmd);
			const oFile = stableOFileFp(p.modPath, modFp);

			if (isCCodeCached(p.modPath, modFp)) {
				oSlots.push([oFile]);
				if (opts.verbose) verboseLog(`  cached ${p.modPath}`);
			} else {
				// Write only .c source BEFORE compile (always — debuggable).
				// Defer fingerprint (.cfp) until after successful compile so a
				// failed zig cc doesn't leave a false cache hit for the next run.
				writeCSource(p.modPath, modFp, cCode);
				const cFile = stableCFileFp(p.modPath, modFp);
				if (opts.verbose) verboseLog(`  cc ${cFile} → ${oFile}`);
				oSlots.push([]);
				cJobs.push({ cFile, oFile, modPath: p.modPath, flags: modFlags, fp: modFp, slot: oSlots.length - 1 });
				modulesRecompiled = modulesRecompiled + 1;
				recompiledModulePaths.push(p.modPath);
			}
		}
		compiled = compiled + 1;
		// Release per-module AST + context after codegen so DRC can free memory.
		// Without this, all 250 module ASTs stay alive (~20GB for self-compile).
		p.program = null as unknown as Node;
		p.ctx = null as unknown as CheckerContext;
	}

	// Filter load order to alive modules only (module-level DCE).
	// Dead modules have no codegen output — dispatcher must not call their init functions.
	let aliveModules: string[] = [];
	for (const mp of graph.loadOrder) {
		if (aliveSetHasModule(aliveSet, mp)) {
			aliveModules.push(mp);
		}
	}

	// Skip link step if --emit=c (only writing C source files)
	if (opts.emitC && opts.isHcr) {
		const emitDir = outDirForMode(opts.mode);
		const coreModules: string[] = [];
		for (const mp of aliveModules) {
			if (!hcrModulePaths.includes(mp)) coreModules.push(mp);
		}
		writeOutput(`${emitDir}/_hcrcore.c`, genHcrCoreDispatcher(coreModules, moduleOutputs));
		console.log(`${green("  Wrote")} ${bold(`${emitDir}/_hcrcore.c`)}`);
		for (const mp of hcrModulePaths) {
			const output = moduleOutputFor(moduleOutputs, mp);
			if (output == null) continue;
			const imagePath = `${emitDir}/_hcrimage_${mangleModuleName(mp)}.c`;
			writeOutput(imagePath, genHcrImageDispatcher(output, mp == entryPath));
			console.log(`${green("  Wrote")} ${bold(imagePath)}`);
		}
		console.log(success(`Emitted ${compiled + 1 + hcrModulePaths.length} C module(s)`));
		if (opts.showTime) printTiming("emitted", t0);
		return;
	}
	if (opts.emitC) {
		// Also emit dispatcher (MsMain + entry point)
		const dispatcher = genProjectDispatcher(
			aliveModules,
			entryPath,
			opts.targetOs,
			opts.appMode == "lib" || opts.appMode == "staticlib",
			moduleOutputs,
		);
		const emitDir = outDirForMode(opts.mode);
		const dispPath = `${emitDir}/_dispatch.c`;
		writeOutput(dispPath, dispatcher);
		console.log(`${green("  Wrote")} ${bold(dispPath)}`);
		console.log(success(`Emitted ${compiled + 1} C module(s)`));
		if (opts.showTime) printTiming("emitted", t0);
		return;
	}

	// Its .o IS content-keyed though: two concurrent builds of different
	// configs (drc vs orc emit different teardown in the dispatcher TU) must
	// not rename over each other's object right before the other's link —
	// that linked an orc dispatcher into a drc build (undefined msOrcCollect).
	const hcrImageSlots: int32[] = [];
	let hcrCoreSlot: int32 = -1;
	if (hcrImages) {
		const coreModules: string[] = [];
		for (const mp of aliveModules) {
			if (!hcrModulePaths.includes(mp)) coreModules.push(mp);
		}
		pushDispatcherJob(cJobs, oSlots, "_hcrcore", genHcrCoreDispatcher(coreModules, moduleOutputs), coreFlags, opts);
		hcrCoreSlot = oSlots.length - 1;
		for (const mp of hcrModulePaths) {
			const output = moduleOutputFor(moduleOutputs, mp);
			if (output == null) {
				console.log(`${error("error")}: internal: HCR module '${mp}' produced no C output`);
				exit(1);
			}
			pushDispatcherJob(cJobs, oSlots, `_hcrimage_${mangleModuleName(mp)}`, genHcrImageDispatcher(output, mp == entryPath), imageFlags, opts);
			hcrImageSlots.push(oSlots.length - 1);
		}
	} else {
		if (opts.verbose) verboseLog("generating dispatcher");
		pushDispatcherJob(cJobs, oSlots, "_dispatch", genProjectDispatcher(
			aliveModules,
			entryPath,
			opts.targetOs,
			opts.appMode == "lib" || opts.appMode == "staticlib",
			moduleOutputs,
		), allFlags, opts);
	}

	// DISPATCH + COLLECT — parallel cc over the runtime thread pool, publish
	// results in input order from the main thread. Dispatcher failure is fatal
	// (as before); module failures print and fall through to the linker so the
	// serial path's behavior is preserved.
	const tCl = performance.now();
	const cCodes = dispatchCompileJobs(cJobs, opts.mode, opts.ccCompiler, opts.ccBinary);
	clangTime = performance.now() - tCl;
	let moduleCompileFailed = false;
	const skippableRoot = opts.targetOs == "solana" ? resolveRuntimeDir() : "";
	let cji = 0;
	while (cji < cJobs.length) {
		const cj = cJobs[cji];
		const code = cCodes[cji];
		if (code == 0) {
			if (cj.fp != "") writeCompileFingerprintFp(cj.modPath, cj.fp);
			oSlots[cj.slot] = [cj.oFile];
		} else if (cj.modPath == "") {
			printDiag(`${error("error")}: compile failed for dispatcher ${dim(`(exit ${code})`)}`);
			exit(1);
		} else {
			invalidateCompileCache(cj.modPath, cj.fp);
			if (skippableRoot != "" && isUnder(cj.modPath, skippableRoot)) {
				console.log(`  ${dim("skip")} ${cj.modPath} ${dim("(BPF unsupported)")}`);
			} else {
				printDiag(`${error("error")}: compile failed for ${cj.modPath} ${dim(`(exit ${code})`)}`);
				moduleCompileFailed = true;
			}
		}
		cji = cji + 1;
	}
	if (moduleCompileFailed) exit(1);
	if (hcrImages) {
		const jobPaths: string[] = [];
		for (const job of emissionJobs) jobPaths.push(job.modPath);
		const tLink = performance.now();
		linkHcrImages(oSlots, moduleSlots, jobPaths, hcrCoreSlot, hcrImageSlots, hcrModulePaths, hcrModules, entryPath, outBinary, allFlags, opts);
		if (hcrBuildAbi != null) publishHcrBuildAbi(hcrBuildAbi, recompiledModulePaths);
		writeProjectCache(projectDeps, outBinary, opts.ccCompiler, opts.ccBinary, opts.mode, buildIdentityFlags);
		if (opts.showTime) printTiming("phase D (link images)", tLink);
		console.log(success(`Built ${compiled} module(s) → ${bold(outBinary)}`) + dim(` (+${hcrModulePaths.length} HCR images)`));
		return;
	}
	oFiles = [];
	for (const slot of oSlots) {
		for (const oFile of slot) oFiles.push(oFile);
	}

	// Link all .o files into final binary (or shared library for HCR)
	// Build link flags from global linkState (Set = deduplicated)
	let allLink = cliLinkFlags(allFlags, opts);
	const externalLinkInputs: string[] = [];
	for (const obj of globalLinkObjects()) {
		oFiles.push(obj);
		externalLinkInputs.push(obj);
	}
	for (const flag of globalLinkFlags()) { allLink = appendFlag(allLink, flag); }
	let linkFlags = allLink;

	// Link cache: skip re-link if all modules hit .c cache and link flags unchanged
	if (modulesRecompiled == 0 && isLinkCached(oFiles, externalLinkInputs, linkFlags, outBinary)) {
		if (opts.genDeps) {
			const depsDir = outDirForMode(opts.mode);
			ensureDir(depsDir);
			writeDepsFile(graph, entryPath, depsDir);
		}
		if (hcrBuildAbi != null) publishHcrBuildAbi(hcrBuildAbi, recompiledModulePaths);
		writeProjectCache(projectDeps, outBinary, opts.ccCompiler, opts.ccBinary, opts.mode, buildIdentityFlags);
		console.log(success(`Built ${compiled} module(s) → ${bold(outBinary)}`) + dim(" (link cached)"));
		if (opts.showTime) printTiming("built", t0);
		return;
	}

	if (opts.showTime) {
		printTiming("phase C (codegen+compile)", tC);
		console.log(`    codegen: ${codegenTime}ms  clang: ${clangTime}ms`);
	}
	const tD = performance.now();

	// Emscripten: auto-enable Asyncify when DCE detects async code (promise module alive)
	if (opts.targetOs == "emcc" && aliveSet.entries.length > 0) {
		let hasAsync = false;
		for (const mp of aliveModules) {
			if (mp.endsWith("promise/index.cms")) { hasAsync = true; }
		}
		if (hasAsync) {
			linkFlags = appendFlag(linkFlags, "-sASYNCIFY");
			if (opts.verbose) verboseLog("  async detected → enabling Asyncify");
		}
	}

	if (opts.verbose) verboseLog("linking → " + outBinary);
	if (opts.appMode == "staticlib") {
		const arRes = archiveStatic(oFiles, outBinary);
		if (!arRes.ok) {
			printDiag(`${error("error")}: ar failed ${dim(`(exit ${arRes.error.exitCode})`)}`);
			if (arRes.error.errorOutput != "") printDiag(arRes.error.errorOutput);
			exit(1);
		}
	} else if (opts.targetOs == "solana") {
		const linkRes = linkSolana(oFiles, outBinary);
		if (!linkRes.ok) {
			printDiag(`${error("error")}: SBF link failed ${dim(`(exit ${linkRes.error.exitCode})`)}`);
			if (linkRes.error.errorOutput != "") printDiag(linkRes.error.errorOutput);
			exit(1);
		}
	} else {
		const linkRes = linkObjects(oFiles, outBinary, linkFlags, opts.mode, opts.ccCompiler, opts.ccBinary);
		if (!linkRes.ok) {
			printDiag(`${error("error")}: link failed ${dim(`(exit ${linkRes.error.exitCode})`)}`);
			if (linkRes.error.errorOutput != "") printDiag(linkRes.error.errorOutput);
			exit(1);
		}
	}
	if (hcrBuildAbi != null) publishHcrBuildAbi(hcrBuildAbi, recompiledModulePaths);

	// Persist link cache after successful link
	writeLinkCache(oFiles, externalLinkInputs, linkFlags, outBinary);

	if (opts.genDeps) {
		const depsDir = outDirForMode(opts.mode);
		writeDepsFile(graph, entryPath, depsDir);
	}

	// Reference-aligned: writeJsonBuildInstructions — persist project cache after successful build
	writeProjectCache(projectDeps, outBinary, opts.ccCompiler, opts.ccBinary, opts.mode, buildIdentityFlags);

	if (opts.showTime) printTiming("phase D (link)", tD);
	console.log(success(`Built ${compiled} module(s) → ${bold(outBinary)}`));
	if (opts.showTime) printTiming("total", t0);
}

// ===== Test (C backend) =====
// Compiles all modules, suppresses user's main(), executes test binary.

export function cmdTest(filePath: string, opts: CliOptions): void {
	filePath = canonicalModulePath(filePath);
	initCache(opts.mode, opts.forceRebuild);
	resetCompiledOFiles();
	registerCoreParsers();
	const t0 = performance.now();
	// Same compiler resolution as cmdBuildC: a test build emits and links C with
	// the same flags, so it needs the same --cc normalization and the same
	// LTO capability resolution once the compiler is known — and the same
	// target-implied gc resolution, so the checker sees the mode the test
	// binary will actually be built with.
	resolveTargetGcMode(opts);
	resolveCC(opts);
	resolveLto(opts);
	const config = buildResolverConfig(Target.C, defaultResolveSection());
	const graph = loadAndCheckGraph(filePath, opts.verbose, config, opts.targetOs, opts.targetInfo, gcModeOf(opts.gcMode));

	// Phase A: Parse → Check → Mono → Transform → Analyze all modules
	const processed: ProcessedModule[] = [];
	const transformedPrograms: Node[] = [];
	const transformedPaths: string[] = [];
	const bs = initCBuildState(opts);
	let allFlags = bs.allFlags;
	const includePaths = bs.includePaths;
	let oFiles: string[] = [];

	// Reference parity: global hook ownership registry shared across all modules.
	const sharedHookOwners = createNameSet();
	setGlobalHookOwners(sharedHookOwners);


	// Phase A1 — parse + check every module FIRST (no instance drain yet), so a generic
	// instance created while checking a dependent is routed to its OWNER module's program
	// (still untransformed) and re-checking its body fires generic-method monomorphization.
	// Per-module draining transforms the owner body before the dependent instantiates it,
	// losing the mono trigger (e.g. Signal_get<int32> never emitted → Signal_get void*).
	const checkedMods: { program: Node, ctx: CheckerContext, modPath: string, source: string }[] = [];
	const programByPath: HashMap<string, Node> = new HashMap<string, Node>();
	for (const modPath of graph.loadOrder) {
		const mod = findModule(graph, modPath);
		if (mod == null) continue;
		// Same reuse as cmdBuildC: the graph-checker phase already ran the full
		// 3 passes and registered program+ctx. Re-checking here not only doubled
		// the build time, it dropped cross-module generic instances — those are
		// created once (instantiation is memoized), attached to the graph-check
		// program, and the discarded re-check never recreates them, so the owner
		// module's TU emits none of them.
		const reusedProgram = lookupModuleProgram(modPath);
		const reusedCtx = lookupModuleCtx(modPath);
		if (reusedProgram != null && reusedCtx != null) {
			setOuterProgramForComptime(reusedProgram);
			setOuterCheckContext(graphRegistry, graph, mod, graphPreludeCtx);
			reusedCtx.strictDefs = opts.strictDefs;
			reusedCtx.strictNullChecks = opts.strictNullChecks;
			exitOnFatalCheckerErrors(reusedCtx, modPath, mod.source);
			reusedCtx.errors = [];
			checkedMods.push({ program: reusedProgram, ctx: reusedCtx, modPath, source: mod.source });
			programByPath.set(modPath, reusedProgram);
			continue;
		}
		const program = parseOrExit(mod.source, modPath);
		const ctx = checkProgramWithRegistry(program, graphRegistry, graph, mod, graphPreludeCtx);
		ctx.strictDefs = opts.strictDefs;
		ctx.strictNullChecks = opts.strictNullChecks;
		exitOnFatalCheckerErrors(ctx, modPath, mod.source);
		ctx.errors = [];
		checkedMods.push({ program, ctx, modPath, source: mod.source });
		programByPath.set(modPath, program);
	}

	// Single drain after A1 — route each pending generic instance to its OWNER module's
	// program so the generic body's module-private helpers are visible in the same TU.
	// Owner-less nodes fall back to the entry program.
	const pendingInsts = drainPendingInstances();
	for (let ii = 0; ii < pendingInsts.length; ii += 1) {
		const instNode = pendingInsts[ii];
		if (instNode.nodeType == null && instNode.resolvedSym != null && instNode.resolvedSym.symbolType != null) {
			instNode.nodeType = instNode.resolvedSym.symbolType;
		}
		let owner = "";
		if (instNode.resolvedSym != null && instNode.resolvedSym.modulePath != "") {
			owner = instNode.resolvedSym.modulePath;
		}
		let targetProgram: Node | null = null;
		if (owner != "" && programByPath.has(owner)) {
			targetProgram = programByPath.get(owner);
		} else if (programByPath.has(filePath)) {
			targetProgram = programByPath.get(filePath);
		}
		if (targetProgram != null) {
			(targetProgram.data as ProgramData).programStmts.push(instNode);
		}
	}

	// Phase A2 — mono → transform → analyze → lower, per module (instances now placed).
	for (const cm of checkedMods) {
		const program = cm.program;
		const ctx = cm.ctx;
		const modPath = cm.modPath;
		if (opts.verbose) verboseLog(`transforming ${modPath}`);

		const monoed = monomorphizeProgram(program, ctx);
		validateTypedAST(ctx, monoed);
		ctx.errors = [];

		const macroExpanded = expandMacros(monoed, ctx);
		exitOnCheckerErrors(ctx, modPath, cm.source);
		const comptimeResolved = evaluateComptimeBlocks(macroExpanded);
		const transformed = transformProgram(comptimeResolved, ctx, false);
		const nativeCtx = createTransformContextWithChecker(ctx);
		nativeCtx.rangeChecks = opts.mode != MODE_DANGER;
		const typeRefined = refineTypes(transformed, nativeCtx, graphRegistry);
		const nativeTransformed = transformForNative(typeRefined, nativeCtx);
		const hcrResult = opts.isHcr && modPath == filePath ? liftHcrState(nativeTransformed, nativeCtx) : nativeTransformed;
		if (opts.gcMode == "none") ctx.gcMode = GcMode.None;
			else if (opts.gcMode == "manual") ctx.gcMode = GcMode.Manual;
			else if (opts.gcMode == "orc") ctx.gcMode = GcMode.Orc;
		ctx.targetOs = opts.targetOs;
		ctx.targetInfo = opts.targetInfo;

		const preAnErrors = ctx.errors.length;
		const analyzed = analyzeProgram(hcrResult, ctx);
		if (ctx.errors.length > preAnErrors) {
			for (let ei = preAnErrors; ei < ctx.errors.length; ei += 1) {
				printDiag(`${error("error")}: ${modPath}: ${ctx.errors[ei].message}`);
			}
			exit(1);
		}
		const nativeLowered = lowerNativeAccess(analyzed, nativeCtx);

		processed.push({ program: nativeLowered, ctx, modPath });
		transformedPrograms.push(nativeLowered);
		transformedPaths.push(modPath);

		const resolved = resolveIncludeFlags(ctx.compilerFlags, includePaths);
		allFlags = mergeFlagsDeduped(allFlags, resolved);
		registerIncludePaths(resolved, includePaths);
	}

	// Phase B: Compute DCE alive set on post-transform ASTs (reference-aligned)
	if (opts.verbose) verboseLog("computing alive set (post-transform DCE)");
	const aliveSet = computeAliveSet(transformedPrograms, transformedPaths, filePath, true, graph);

	// Compile prelude @compile directives — unconditional (reference-aligned: all @compile are always built)
	if (graphPreludeCtx != null && graphPreludeCtx.compileDirectives != "") {
		const preludeObjs = processCompileDirectives(graphPreludeCtx.compileDirectives, ".", includePaths, allFlags, opts.mode, opts.ccCompiler, opts.ccBinary, opts.verbose, opts.targetOs, opts.projectRoot, resolveRuntimeDir());
		for (const oFile of preludeObjs) oFiles.push(oFile);
	}

	const rtObjs = compilePlatformRuntime(includePaths, allFlags, opts);
	for (const oFile of rtObjs) oFiles.push(oFile);

	// Phase C: Codegen + compile each module (per-module .c cache)
	setConcurrentTypeQueries(true);
	const emissionFacts = new CEmissionFacts();
	for (const p of processed) {
		prepareCModuleEmission(p.program, p.ctx, p.modPath, aliveSet, emissionFacts);
	}
	const emissionJobs: ModuleEmissionJob[] = [];
	for (const p of processed) emissionJobs.push({ slot: emissionJobs.length, program: p.program, ctx: p.ctx, modPath: p.modPath, weight: p.program.location.endLine });
	const emitWidth: int32 = opts.emitJobs < 1 ? emissionJobs.length : opts.emitJobs;
	const emissionResults = emitModulesBounded(emissionJobs, aliveSet, emissionFacts, emitWidth, true, opts.isHcr ? filePath : "");
	if (opts.showTime) console.log(`    emit workers=${emitWidth} overlap=${emissionOverlapped(emissionResults)}`);
	let emissionFailed = false;
	for (let eri = 0; eri < emissionResults.length; eri += 1) {
		const result = emissionResults[eri];
		if (!result.completed) continue;
		const modPath = emissionJobs[eri].modPath;
		if (result.failure != "") {
			printDiag(`${error("error")}: ${modPath}: ${result.failure}`);
			emissionFailed = true;
		}
		for (const diagnostic of result.output.errors) {
			printDiag(`${error("error")}: ${modPath}: ${diagnostic.message}`);
			emissionFailed = true;
		}
	}
	if (emissionFailed) exit(1);
	for (const p of processed) {
		p.program = null as unknown as Node;
		p.ctx = null as unknown as CheckerContext;
	}
	let compiled = 0;
	const tcd = cacheDir();
	const oSlots: string[][] = [];
	oSlots.push(oFiles);
	const cJobs: ModuleCompileJob[] = [];
	for (let emitIndex = 0; emitIndex < emissionJobs.length; emitIndex += 1) {
		const p = emissionJobs[emitIndex];
		if (opts.verbose) verboseLog(`codegen ${p.modPath}`);

		const output = emissionResults[emitIndex].output;
		const cCode = output.code;
		output.code = "";

		const compileObjs = processCompileDirectives(p.ctx.compileDirectives, dirname(p.modPath), includePaths, allFlags, opts.mode, opts.ccCompiler, opts.ccBinary, opts.verbose, opts.targetOs, opts.projectRoot, resolveRuntimeDir());
		oSlots.push(compileObjs);

		let testModFlags = appendFlag(allFlags, quoteCcArg(`-iquote${dirname(p.modPath)}`));
		testModFlags = appendFlag(testModFlags, quoteCcArg(`-iquote${tcd}`));
		const upFlag = userProjectFlag(p.modPath, opts.projectRoot, resolveRuntimeDir());
		if (upFlag != "") testModFlags = appendFlag(testModFlags, upFlag);
		const compileCmd = fullCompileCmd(opts.ccCompiler, opts.mode, testModFlags, opts.ccBinary);
		const modFp = moduleCompileFp(cCode, compileCmd);
		const oFile = stableOFileFp(p.modPath, modFp);

		if (isCCodeCached(p.modPath, modFp)) {
			oSlots.push([oFile]);
			if (opts.verbose) verboseLog(`  cached ${p.modPath}`);
		} else {
			// Same as main path — defer fingerprint until success.
			writeCSource(p.modPath, modFp, cCode);
			const cFile = stableCFileFp(p.modPath, modFp);
			if (opts.verbose) verboseLog(`  cc ${cFile} → ${oFile}`);
			oSlots.push([]);
			cJobs.push({ cFile, oFile, modPath: p.modPath, flags: testModFlags, fp: modFp, slot: oSlots.length - 1 });
		}
		compiled = compiled + 1;
		p.program = null as unknown as Node;
		p.ctx = null as unknown as CheckerContext;
	}

	// Generate test dispatcher (runs all module inits + test tables)
	if (opts.verbose) verboseLog("generating test dispatcher");
	const dispatcher = genTestDispatcher(graph.loadOrder, filePath);
	// Same concurrent-build rule as cmdBuildC's dispatcher: fp-keyed + atomic .c.
	const dispFp = moduleCompileFp(dispatcher, fullCompileCmd(opts.ccCompiler, opts.mode, allFlags, opts.ccBinary));
	writeCSource("_test_dispatch", dispFp, dispatcher);
	const dispFile = stableCFileFp("_test_dispatch", dispFp);
	oSlots.push([]);
	cJobs.push({ cFile: dispFile, oFile: stableOFileFp("_test_dispatch", dispFp), modPath: "", flags: allFlags, fp: "", slot: oSlots.length - 1 });

	const cCodes = dispatchCompileJobs(cJobs, opts.mode, opts.ccCompiler, opts.ccBinary);
	let testFailed = false;
	let cji = 0;
	while (cji < cJobs.length) {
		const cj = cJobs[cji];
		const code = cCodes[cji];
		if (code == 0) {
			if (cj.fp != "") writeCompileFingerprintFp(cj.modPath, cj.fp);
			oSlots[cj.slot] = [cj.oFile];
		} else if (cj.modPath == "") {
			printDiag(`${error("error")}: compile failed for test dispatcher ${dim(`(exit ${code})`)}`);
			testFailed = true;
		} else {
			invalidateCompileCache(cj.modPath, cj.fp);
			printDiag(`${error("error")}: compile failed for ${cj.modPath} ${dim(`(exit ${code})`)}`);
			testFailed = true;
		}
		cji = cji + 1;
	}
	if (testFailed) exit(1);
	oFiles = [];
	for (const slot of oSlots) {
		for (const oFile of slot) oFiles.push(oFile);
	}

	// Link and execute
	ensureDir("out/debug");
	const testBin = "out/debug/_test_" + replaceExt(basename(filePath), "");
	// Same link flags as cmdBuildC. cmdTest used to assemble its own and so
	// silently dropped everything cliLinkFlags contributes: the per-target
	// system libraries and --passL. On Windows that is fatal — without
	// -lws2_32 / -lmswsock / -lbcrypt every Winsock and BCrypt symbol is
	// undefined at link, so `msc test` could not link any graph reaching
	// std/net. macOS only loses -Wl,-dead_strip there, which is why the gap
	// went unnoticed. forceExe keeps --app=lib / --hcr from turning the test
	// binary into a shared library: execFile below has to run it.
	let testLink = cliLinkFlags(allFlags, opts, true);
	for (const obj of globalLinkObjects()) oFiles.push(obj);
	for (const flag of globalLinkFlags()) { testLink = appendFlag(testLink, flag); }
	const linkRes = linkObjects(oFiles, testBin, testLink, opts.mode, opts.ccCompiler, opts.ccBinary);
	if (!linkRes.ok) {
		printDiag(`${error("error")}: link failed ${dim(`(exit ${linkRes.error.exitCode})`)}`);
		if (linkRes.error.errorOutput != "") printDiag(linkRes.error.errorOutput);
		exit(1);
	}

	if (opts.showTime) printTiming("compiled", t0);
	if (opts.verbose) verboseLog("running tests");
	const runCode = execFile(testBin);
	if (runCode > 128) printDiag(`${error("error")}: test binary terminated by signal ${runCode - 128}`);
	exit(runCode);
}

// ===== Run JS =====

function outRelForModule(modPath: string, projectRoot: string, stdRoot: string): string {
	if (stdRoot != "" && modPath.startsWith(stdRoot)) {
		let rel = modPath.slice(stdRoot.length, modPath.length);
		if (rel.startsWith("/")) rel = rel.slice(1, rel.length);
		return replaceExt(`_std/${rel}`, ".js");
	}
	const rootPrefix = projectRoot.endsWith("/") ? projectRoot : `${projectRoot}/`;
	if (modPath.startsWith(rootPrefix)) {
		return replaceExt(modPath.slice(rootPrefix.length, modPath.length), ".js");
	}
	return `_ext/${mangleModuleName(modPath)}.js`;
}

function lookupOutRel(keys: string[], vals: string[], k: string): string {
	for (let i = 0; i < keys.length; i += 1) {
		if (keys[i] == k) return vals[i];
	}
	return "";
}

// Both arguments are '/'-separated paths relative to the same out root; the
// result is a node-resolvable specifier (always ./ or ../ prefixed).
function relSpecBetween(fromRel: string, toRel: string): string {
	const spec = relative(dirname(`/${fromRel}`), `/${toRel}`);
	if (spec.startsWith(".")) return spec;
	return `./${spec}`;
}

export interface JsTreeResult {
	outRoot: string;
	modulePaths: string[];
	moduleOutRels: string[];
	testNames: string[][];
	testFuncs: string[][];
}

function emitJSModuleTree(filePath: string, opts: CliOptions, isTestBuild: boolean, outRootOverride: string): JsTreeResult {
	registerCoreParsers();
	const config = buildResolverConfig(Target.JS, defaultResolveSection());
	const graph = loadAndCheckGraph(filePath, opts.verbose, config, opts.targetOs);

	// Self-contained out tree rooted at the PROJECT, not the CWD: user modules
	// mirror the source tree, std/runtime modules land under _std/, anything
	// outside both roots under _ext/. Every emitted import is relative inside
	// the tree, so plain node can execute the directory from anywhere.
	// findProjectRoot resolves through symlinks (/tmp → /private/tmp on macOS)
	// while graph module paths keep the spelling the entry was given, so the
	// configured root can fail to prefix its own entry. Anchor on the entry
	// when that happens, otherwise every module lands in the _ext fallback.
	let projectRoot = opts.projectRoot != "" ? opts.projectRoot : dirname(filePath);
	if (!filePath.startsWith(projectRoot.endsWith("/") ? projectRoot : `${projectRoot}/`)) {
		projectRoot = dirname(filePath);
	}
	const outRoot = outRootOverride != "" ? outRootOverride : `${projectRoot}/${outDirForMode(opts.mode)}`;
	const stdRoot = config.stdPath;

	const outRelKeys: string[] = [];
	const outRelVals: string[] = [];
	for (const modPath of graph.loadOrder) {
		outRelKeys.push(modPath);
		outRelVals.push(outRelForModule(modPath, projectRoot, stdRoot));
	}

	// Two phases for the same reason as cmdBuildJS: expand every module before
	// any backend transform mutates a declaring module's AST.
	const unitPaths: string[] = [];
	const unitPrograms: Node[] = [];
	const unitCtxs: CheckerContext[] = [];
	for (const modPath of graph.loadOrder) {
		const mod = findModule(graph, modPath);
		if (mod == null) continue;

		if (opts.verbose) verboseLog("compiling " + modPath);

		const program = parseOrExit(mod.source, modPath);
		const ctx = checkProgramWithRegistry(program, graphRegistry, graph, mod, graphPreludeCtx);
		exitOnFatalCheckerErrors(ctx, modPath, mod.source);
		ctx.errors = [];

		const macroExpanded = expandMacros(program, ctx);
		exitOnCheckerErrors(ctx, modPath, mod.source);

		unitPaths.push(modPath);
		unitPrograms.push(evaluateComptimeBlocks(macroExpanded));
		unitCtxs.push(ctx);
	}

	// A generic instance belongs to the module that DECLARED the generic, and
	// its emitted name says so. Placing the body anywhere else — e.g. in the
	// module that first asked for it — leaves the name pointing at one module
	// and the definition sitting in another, which on this backend becomes a
	// module importing a symbol from itself. Same routing as the bundle path.
	for (const instNode of drainPendingInstances()) {
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
		if (targetIdx < 0) {
			for (let pi: int32 = 0; pi < unitPaths.length; pi += 1) {
				if (unitPaths[pi] == filePath) { targetIdx = pi; }
			}
		}
		if (targetIdx >= 0) {
			(unitPrograms[targetIdx].data as ProgramData).programStmts.push(instNode);
		}
	}

	// Export-name surface per module — jsMultiFileName keys public naming off
	// this list on BOTH the declaring and the referencing side (symbol flags
	// don't survive the registry round-trip; mod.exportNames does).
	const modExportKeys: string[] = [];
	const modExportVals: string[][] = [];
	for (const modPath of unitPaths) {
		const mod = findModule(graph, modPath);
		if (mod == null) continue;
		modExportKeys.push(modPath);
		modExportVals.push(mod.exportNames);
	}

	const moduleCodes: string[] = [];
	const moduleSmaps: SourceInfo[] = [];
	const moduleNeededMods: string[][] = [];
	const moduleNeededNames: string[][][] = [];
	const moduleExported: string[][] = [];
	const moduleTestNames: string[][] = [];
	const moduleTestFuncs: string[][] = [];
	for (let ui = 0; ui < unitPaths.length; ui += 1) {
		const modPath = unitPaths[ui];
		const ctx = unitCtxs[ui];
		const mod = findModule(graph, modPath);
		const transformed = transformProgram(unitPrograms[ui], ctx, true);
		exitOnCheckerErrors(ctx, modPath, mod != null ? mod.source : "");

		const fromRel = lookupOutRel(outRelKeys, outRelVals, modPath);
		const importSpecKeys: string[] = [];
		const importSpecVals: string[] = [];
		if (mod != null) {
			for (const imp of mod.imports) {
				const toRel = lookupOutRel(outRelKeys, outRelVals, imp.sourcePath);
				if (toRel == "") continue;
				importSpecKeys.push(imp.sourceSpecifier);
				importSpecVals.push(relSpecBetween(fromRel, toRel));
			}
		}
		const moduleSpecKeys: string[] = [];
		const moduleSpecVals: string[] = [];
		for (let mi = 0; mi < outRelKeys.length; mi += 1) {
			moduleSpecKeys.push(outRelKeys[mi]);
			moduleSpecVals.push(relSpecBetween(fromRel, outRelVals[mi]));
		}

		const res = generateJSModule(transformed, ctx.jsImportRegistry, modPath, importSpecKeys, importSpecVals, moduleSpecKeys, moduleSpecVals, modExportKeys, modExportVals, isTestBuild, opts.sourcemap);
		moduleCodes.push(res.code);
		moduleSmaps.push(res.smap);
		moduleNeededMods.push(res.neededModules);
		moduleNeededNames.push(res.neededNames);
		moduleExported.push(res.exportedNames);
		moduleTestNames.push(res.testNames);
		moduleTestFuncs.push(res.testFuncs);
	}

	// Forced exports: names other modules reference that this module didn't
	// export (private helpers reachable from generic bodies, caller-side
	// instances reused by later modules). A name needed here but not defined
	// here is a compiler bug — node fails loudly at the gate, by design.
	for (let ui = 0; ui < unitPaths.length; ui += 1) {
		const forced: string[] = [];
		for (let vi = 0; vi < unitPaths.length; vi += 1) {
			if (vi == ui) continue;
			for (let mi = 0; mi < moduleNeededMods[vi].length; mi += 1) {
				if (moduleNeededMods[vi][mi] != unitPaths[ui]) continue;
				for (const n of moduleNeededNames[vi][mi]) {
					let already = false;
					for (const e of moduleExported[ui]) { if (e == n) { already = true; } }
					for (const f of forced) { if (f == n) { already = true; } }
					if (!already) forced.push(n);
				}
			}
		}
		let code = moduleCodes[ui];
		if (forced.length > 0) {
			let names = "";
			for (let fi = 0; fi < forced.length; fi += 1) {
				if (fi > 0) names = `${names}, `;
				names = names + forced[fi];
			}
			code = `${code}export { ${names} };\n`;
		}
		const outPath = `${outRoot}/${lookupOutRel(outRelKeys, outRelVals, unitPaths[ui])}`;
		ensureDir(dirname(outPath));
		if (opts.sourcemap) {
			const mapName = `${basename(outPath)}.map`;
			const stdIgnored = ignoredFileIndexes(moduleSmaps[ui], (p: string): boolean => stdRoot != "" && p.startsWith(stdRoot));
			writeOutput(`${outPath}.map`, toSourceMapJson(moduleSmaps[ui], basename(outPath), mapDirOf(outPath), readSourceText, stdIgnored));
			code = `${code}\n//# sourceMappingURL=${mapName}\n`;
		}
		writeOutput(outPath, code);
	}

	const outRels: string[] = [];
	for (const mp of unitPaths) { outRels.push(lookupOutRel(outRelKeys, outRelVals, mp)); }
	return { outRoot, modulePaths: unitPaths, moduleOutRels: outRels, testNames: moduleTestNames, testFuncs: moduleTestFuncs };
}

export function cmdRunJS(filePath: string, opts: CliOptions): void {
	filePath = canonicalModulePath(filePath);
	const t0 = performance.now();
	const tree = emitJSModuleTree(filePath, opts, false, "");

	if (opts.showTime) printTiming("compiled", t0);

	let entryRel = "";
	for (let i = 0; i < tree.modulePaths.length; i += 1) {
		if (tree.modulePaths[i] == filePath) entryRel = tree.moduleOutRels[i];
	}
	const entryJs = `${tree.outRoot}/${entryRel}`;
	if (opts.verbose) verboseLog(`exec node ${entryJs}`);
	const r = exec(`node ${entryJs}`);
	if (r.ok) {
		if (r.value != "") console.log(r.value);
		exit(0);
	}
	if (r.error.output != "") console.log(r.error.output);
	if (r.error.errorOutput != "") console.log(r.error.errorOutput);
	exit(r.error.exitCode != 0 ? r.error.exitCode : 1);
}

// ===== Test (JS backend) =====
// Same module tree as cmdRunJS plus a generated harness. The harness owns the
// reporting format so `msc test` reads identically on both targets; the
// assertion shims are installed on globalThis before the test modules are
// dynamically imported, because the emitted power-assert calls are bare
// identifiers with no import to bind them.

function jsTestHarnessSource(): string {
	const lines: string[] = [
		"const RESET = \"\\u001b[0m\", GREEN = \"\\u001b[32m\", RED = \"\\u001b[31m\", CYAN = \"\\u001b[36m\", DIM = \"\\u001b[2m\";",
		"let paSource = \"\", paEntries = [], paPending = null;",
		"globalThis.__paBegin = (src) => { paSource = src; paEntries = []; paPending = null; };",
		"globalThis.__paValueStr = (col, label, val) => { paEntries.push({ col, label, val: JSON.stringify(val) }); };",
		"globalThis.__paValueNum = (col, label, val) => { paEntries.push({ col, label, val: String(val) }); };",
		"globalThis.__paValueInt = (col, label, val) => { paEntries.push({ col, label, val: String(val) }); };",
		"globalThis.__paValueBool = (col, label, val) => { paEntries.push({ col, label, val: val ? \"true\" : \"false\" }); };",
		"globalThis.__paEnd = () => {",
		"  const sorted = paEntries.slice().sort((a, b) => b.col - a.col);",
		"  const out = [paSource];",
		"  for (const e of sorted) out.push(\"  \" + e.label + \" => \" + e.val);",
		"  paPending = out;",
		"};",
		"globalThis.__msAssertFail = (msg, file, line) => {",
		"  const err = new Error(msg);",
		"  err.msAssert = true; err.msFile = file; err.msLine = line; err.msDiag = paPending;",
		"  paPending = null;",
		"  throw err;",
		"};",
		"export async function run(modules) {",
		"  let filesPassed = 0, filesFailed = 0, testsPassed = 0, testsFailed = 0;",
		"  const failures = [];",
		"  const t0 = Date.now();",
		"  for (const mod of modules) {",
		"    const ns = await import(mod.spec);",
		"    const started = Date.now();",
		"    let modFailed = 0;",
		"    for (let i = 0; i < mod.funcs.length; i += 1) {",
		"      try { await ns[mod.funcs[i]](); testsPassed += 1; }",
		"      catch (e) { testsFailed += 1; modFailed += 1; failures.push({ file: mod.path, name: mod.names[i], err: e }); }",
		"    }",
		"    const ms = Date.now() - started;",
		"    if (modFailed > 0) { filesFailed += 1; console.log(RED + \"\\u00d7\" + RESET + \" \" + mod.path + \" (\" + mod.funcs.length + \") \" + DIM + ms + \"ms\" + RESET); }",
		"    else { filesPassed += 1; console.log(GREEN + \"\\u2713\" + RESET + \" \" + mod.path + \" (\" + mod.funcs.length + \") \" + DIM + ms + \"ms\" + RESET); }",
		"  }",
		"  let lastFile = null;",
		"  for (const f of failures) {",
		"    if (f.file !== lastFile) { console.log(\"\\n \" + RED + \"FAIL\" + RESET + \"  \" + f.file + \"\\n\"); lastFile = f.file; }",
		"    console.log(\"  \" + RED + \"\\u00d7 \" + f.name + RESET);",
		"    if (f.err && f.err.msDiag) { console.log(\"    AssertionError:\"); for (const l of f.err.msDiag) console.log(\"    \" + l); }",
		"    else { console.log(\"    AssertionError: \" + (f.err && f.err.message ? f.err.message : String(f.err))); }",
		"    if (f.err && f.err.msFile) console.log(\"\\n      \" + DIM + \"at \" + f.err.msFile + \":\" + f.err.msLine + RESET);",
		"    console.log(\"\");",
		"  }",
		"  const total = testsPassed + testsFailed;",
		"  console.log(\"\");",
		"  let filesLine = \" Test Files  \" + GREEN + filesPassed + \" passed\" + RESET;",
		"  if (filesFailed > 0) filesLine += \" | \" + RED + filesFailed + \" failed\" + RESET;",
		"  console.log(filesLine + \" (\" + (filesPassed + filesFailed) + \")\");",
		"  let testsLine = \"      Tests  \" + GREEN + testsPassed + \" passed\" + RESET;",
		"  if (testsFailed > 0) testsLine += \" | \" + RED + testsFailed + \" failed\" + RESET;",
		"  console.log(testsLine + \" (\" + total + \")\");",
		"  console.log(\"   Duration  \" + CYAN + (Date.now() - t0) + \"ms\" + RESET);",
		"  console.log(\"\");",
		"  if (testsFailed > 0) process.exitCode = 1;",
		"}",
	];
	let src = "";
	for (const line of lines) { src = `${src}${line}\n`; }
	return src;
}

export function cmdTestJS(filePath: string, opts: CliOptions): void {
	filePath = canonicalModulePath(filePath);
	const t0 = performance.now();
	const tree = emitJSModuleTree(filePath, opts, true, "");

	const harnessRel = "_test/harness.js";
	ensureDir(`${tree.outRoot}/_test`);
	writeOutput(`${tree.outRoot}/${harnessRel}`, jsTestHarnessSource());

	let entries = "";
	for (let i = 0; i < tree.modulePaths.length; i += 1) {
		if (tree.testFuncs[i].length == 0) continue;
		const spec = relSpecBetween(harnessRel, tree.moduleOutRels[i]);
		let funcs = "";
		let names = "";
		for (let ti = 0; ti < tree.testFuncs[i].length; ti += 1) {
			if (ti > 0) { funcs = `${funcs}, `; names = `${names}, `; }
			funcs = `${funcs}"${tree.testFuncs[i][ti]}"`;
			names = `${names}"${escapeJSString(tree.testNames[i][ti])}"`;
		}
		entries = `${entries}  { path: "${escapeJSString(tree.modulePaths[i])}", spec: "${spec}", funcs: [${funcs}], names: [${names}] },\n`;
	}
	const mainSrc = `import { run } from "./harness.js";\nawait run([\n${entries}]);\n`;
	writeOutput(`${tree.outRoot}/_test/main.js`, mainSrc);

	if (opts.showTime) printTiming("compiled", t0);

	const mainJs = `${tree.outRoot}/_test/main.js`;
	if (opts.verbose) verboseLog(`exec node ${mainJs}`);
	const r = exec(`node ${mainJs}`);
	if (r.ok) {
		if (r.value != "") console.log(r.value);
		exit(0);
	}
	if (r.error.output != "") console.log(r.error.output);
	if (r.error.errorOutput != "") console.log(r.error.errorOutput);
	exit(r.error.exitCode != 0 ? r.error.exitCode : 1);
}

// ===== Raiser (Bytecode VM) Run =====

export function cmdRunRaiser(filePath: string, opts: CliOptions): void {
	const t0 = performance.now();
	const config = buildResolverConfig(Target.Raiser, defaultResolveSection());
	const graph = loadAndCheckGraph(filePath, opts.verbose, config, opts.targetOs);

	const modules: RaiserModuleInput[] = [];
	const entryCanonical = canonicalModulePath(filePath);
	const unitPaths: string[] = [];
	const unitPrograms: Node[] = [];
	const unitCtxs: CheckerContext[] = [];
	for (const modPath of graph.loadOrder) {
		const mod = findModule(graph, modPath);
		if (mod == null) continue;

		if (opts.verbose) verboseLog("compiling " + modPath);
		const program = parseOrExit(mod.source, modPath);
		const modCtx = checkProgramWithRegistry(program, graphRegistry, graph, mod, graphPreludeCtx);
		exitOnFatalCheckerErrors(modCtx, modPath, mod.source);
		modCtx.errors = [];


		unitPaths.push(modPath);
		unitPrograms.push(program);
		unitCtxs.push(modCtx);
	}
	for (const instNode of drainPendingInstances()) {
		if (instNode.nodeType == null && instNode.resolvedSym != null) {
			instNode.nodeType = instNode.resolvedSym.symbolType;
		}
		const owner = instNode.resolvedSym != null ? instNode.resolvedSym.modulePath : "";
		let targetIdx: int32 = -1;
		for (let i = 0; i < unitPaths.length; i += 1) {
			if (unitPaths[i] == owner) targetIdx = i;
		}
		if (targetIdx < 0) {
			for (let i = 0; i < unitPaths.length; i += 1) {
				if (unitPaths[i] == entryCanonical) targetIdx = i;
			}
		}
		if (targetIdx >= 0) {
			(unitPrograms[targetIdx].data as ProgramData).programStmts.push(instNode);
		}
	}
	for (let i = 0; i < unitPrograms.length; i += 1) {
		const modCtx = unitCtxs[i];
		const monoed = monomorphizeProgram(unitPrograms[i], modCtx);
		const macroExpanded = expandMacros(monoed, modCtx);
		const mod = findModule(graph, unitPaths[i]);
		if (mod != null) exitOnCheckerErrors(modCtx, unitPaths[i], mod.source);
		const comptimeResolved = evaluateComptimeBlocks(macroExpanded);
		const txCtx = createTransformContextWithChecker(modCtx);
		txCtx.rangeChecks = opts.mode != MODE_DANGER;
		const refined = refineTypes(comptimeResolved, txCtx, graphRegistry);
		const transformed = transformForRaiser(refined, modCtx);

		const input: RaiserModuleInput = { modulePath: unitPaths[i], program: transformed };
		modules.push(input);
	}

	// Before bytecodegen: the coverage check inside generateRaiserProject
	// resolves every extern's bridge at the call site, and execution dispatches
	// through the same registry — load it first or both see an empty table.
	ensureHostTableLoaded();
	if (opts.verbose) verboseLog(`generating bytecode (${modules.length} modules)`);
	const raiserMod = generateRaiserProject(modules);
	// Comptime parity: queued bytecode-compile errors are collected and
	// reported, not fatal — std module bodies the program never calls can
	// contain unbridgeable externs or unresolved helpers. A nil that leaks
	// into live code is visible here as a "cannot evaluate" line.
	for (const e of takeRaiserCompileErrors()) {
		printDiag(`${yellow("raiser warning")}: ${e.message} at ${e.line}:${e.column}`);
	}

	if (opts.showTime) printTiming("compiled", t0);

	const ctx = createRaiserContext();
	ctx.gcMode = "orc";
	raiserLoad(ctx, raiserMod);
	const ranOk = raiserExecute(ctx);

	if (ctx.lastOutput.length > 0) {
		// Print captured output (strip trailing newline for clean display)
		const lastOut = ctx.lastOutput;
		if (lastOut.byteLength > 0 && lastOut.byteSlice(lastOut.byteLength - 1, lastOut.byteLength) == "\n") {
			console.log(lastOut.byteSlice(0, lastOut.byteLength - 1));
		} else {
			console.log(lastOut);
		}
	}

	if (!ranOk) {
		if (ctx.lastError != "") {
			printDiag(`${error("raiser runtime error")}: ${ctx.lastError}`);
		}
		exit(1);
	}

	// A spawned strand that threw with nobody awaiting it is an unhandled
	// rejection — same contract and exit code as msReportOrphanFailures on C.
	if (ctx.orphanFailures.length > 0) {
		for (const msg of ctx.orphanFailures) {
			console.log(`${error("Error")}: unhandled rejection: ${msg}`);
		}
		exit(1);
	}

	// C-target parity: the program's exit code becomes msc's own.
	if (ctx.lastResult.kind == RaiserValueKind.Int) {
		exit(ctx.lastResult.intVal);
	}
}

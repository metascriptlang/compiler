// MetaScript Compiler CLI — compile command

import { exit, exec, execFile, execFileCapture, findOnPath, argv, platform, cwd, env, ProcessError } from "std/process";
import { watch, nextChanges, msIoRunOnce, writeSettled, writerCloseObservable, FsWatch, FsChanges } from "std/fs/watch";
import { exists, readFile, writeFile, appendFile, remove } from "std/fs";
import { parseJson } from "std/serialize/json/parser";
import { getDynamicField, jsonToStringArray } from "std/serialize/json/accessors";
import { asString } from "std/serialize/json/types";
import { writeStderr, writeStdout, readLine, stdinHasData, stdinDisableBuffering } from "std/io";
import { spawn as spawnChild, ChildProcess, ChildStream, ExitStatus } from "std/process/child";
import { ProcessErrorKind } from "std/process/errors";
import { isAlphanumeric, isDigit } from "../lexer/chars";
import { BinaryExprData, ClassDeclData, DecoratedDeclData, EnumDeclData, ExportDeclData, IdentifierData, ImportDeclData, InterfaceDeclData, MacroInvocationData, FunctionDeclData, UpdateExprData, Node, NodeKind, ProgramData, StructDeclData, Symbol, SymbolKind, Type, VariableDeclData, createNodeAt } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { exportedFunctionOf } from "../checker/decoratorHelpers";
import { CheckerContext, ExportedSymInfo, GcMode, hasErrors, hasFatalErrors, errorCount, findModuleExports, isGenericFn, isStaticExtensionSym, Severity, ExportRegistry } from "../checker/context";
import { checkModuleGraph, getPreludeContext, setGraphCheckTiming, loadStdGlobalImportModules, loadExtraGlobalImportModules, noteStdGlobalImportModules, CheckSession } from "../checker/orchestrator";
import { validateTypedAST } from "../checker/validate";
import { transformProgram } from "../transform/index";
import { analyzeProgram } from "../analyzer/index";
import { WriteSummaries, contractClaims, createRoutineDecls, createWriteSummaries, restoreContracts, reuseClones } from "../analyzer/writeEffects";
import { monomorphizeProgram } from "../monomorphize/collect";
import { generateJS, generateJSBundleModule, generateJSModule, hasTopLevelAwait, bundleModuleEvaluator, JsModuleResult } from "../codegen/js/jsgen";
import { SourceInfo, createSourceInfo, appendInfo, toSourceMapJson, ignoredFileIndexes } from "../codegen/js/sourcemap";
import { stringify, jsonString } from "std/core/json";
import { createJSHelpers, escapeJSString, JsTreeLayout, createJsTreeLayout, relSpecBetween } from "../codegen/js/emit";
import { generateRaiserProject, RaiserModuleInput } from "../codegen/raiser/rgen";
import { takeRaiserCompileErrors } from "../codegen/raiser/context";
import { createContext as createRaiserContext, load as raiserLoad, execute as raiserExecute, RaiserContext } from "../raiser/context";
import { RaiserModule } from "../raiser/module";
import { RaiserPrintSink } from "../raiser/marshal";
import { RaiserValueKind } from "../raiser/value";
import { factInlineDecls } from "../codegen/c/forward";
import { CModuleOutput, generatePreparedCModuleOutput, genHcrCoreDispatcher, genHcrImageDispatcher, genProjectDispatcher, prepareCModuleEmission, replayCModuleEmission } from "../codegen/c/index";
import { isModuleGlobalVar, mangledFunctionName, mangledGlobalName, mangleModuleName, mangleProcName, mangleQualified, safeName, setModuleNameRoots, moduleDisplayPath, buildModuleNameRoots, registerModuleNames } from "../codegen/c/names";
import { aliveSetHasDecl, aliveSetHasModule, aliveSetHasNamed, aliveSetImportsC, createAliveSet, AliveSet, CEmissionFacts, aliveSetFingerprint, factCoreUnit } from "../codegen/c/context";
import { genTestDispatcher } from "../codegen/c/test";
import { registerCoreParsers } from "../parser/statements/core";
import { getParserDefines, setParserDefines } from "../parser/context";
import { computeAliveSet } from "../checker/reachability";
import { inferRaises, markEveryBodyMayRaise } from "../checker/raises";
import { collectFreestandingAsync, collectWritableModuleBindings, emptyTopLevelMessage, freestandingAsyncLoc, topLevelCallsAnything, writableModuleBindingMessage, FREESTANDING_ASYNC_MSG } from "../checker/freestanding";
import { refuseSyncAwaitOnJs } from "../checker/syncAwait";
import { refusePointerOpsOnJs } from "../checker/byteViews";
import { refuseBigIntOnRaiser } from "../checker/bigIntOnRaiser";
import { checkJsBundleExports, BundleExport } from "../checker/jsBundleExports";
import { jsBundleReferenceName } from "../codegen/js/expressions";
import { jsEnumObject } from "../codegen/js/declarations";
import { getSimpleTypeDesc, sealHookSyms, opCName, opMark, opsFrom, replayOps } from "../codegen/c/types";
import { sealRuntimeProcs, compilerFuncSym } from "../transform/util";
import { TargetInfo, hostTargetInfo, hasGenericParams, isAwaitable, setConcurrentTypeQueries } from "../checker/types";
import { SymbolFlag, hasFlag } from "../checker/symbol";
import { transformForNative } from "../transform/native/index";
import { transformForRaiser } from "../transform/raiserLowering";
import { lowerNativeAccess } from "../transform/native/nativeLower";
import { liftHcrState } from "../transform/native/hcrLift";
import { HcrIndirectModule, HcrTypeLayout, HcrStorageTable, hcrFunctions, lowerHcrIndirection, createHcrStorageTable, buildHcrStorage } from "../transform/native/hcrIndirect";
import { hcrTypeCounts } from "./hcrCount";
import { lookupModuleCtx, lookupModuleProgram, drainPendingInstances, distinctInstances, placeInstance, retainCheckedInstances } from "../checker/instantiate";
import { setOuterProgramForComptime, setOuterCheckContext } from "./meta/callbacks";
import { markTypeOnlyImports } from "../checker/importElision";
import { markVmOnlyRoutines } from "../checker/vmOnly";
import { createTransformContextWithChecker } from "../transform/context";
import { resetLiftedOps, setJsProgramScope } from "../transform/lowering/destructorLifting";
import { createModuleGraph, findModule, addModule, ModuleGraph, Module, ModuleState, createModule, createImportEntry, ModuleError, ErrorSeverity, planDynamicModules } from "../module/graph";
import { canonicalModulePath, createFileSystemProvider, loadModule, provideSource, SourceProvider, takeHeaderTimings, registerHeaderCache, headerModuleSource, isCHeaderPath } from "../module/loader";
import { registerPreludeStampFn, preludePackKey, preludePackStamp, packRoot, tryLoadPreludeDeps, writePreludeDeps, PreludeDepsSnapshot, DepsModuleRow, DepsImportRow, DepsCircularRow } from "../checker/preludePack";
import { modulePassIdentity } from "../checker/prelude";
import { ResolverConfig, createDefaultConfig, Backend } from "../module/resolver";
import { readLockfile, entryName } from "./package/lockfile";
import { SourceKind } from "./package/version";
import { registrySrcPath, gitSrcPath, cacheRoot } from "./package/cache";
import { BuildSession, BuildStatus, LowerClaims, createBuildSession, startSessionBuild, instancesFingerprint, hcrTypeRegistryFingerprint, projectTypesFingerprint, sameClaims } from "./buildSession";
import { dbLower } from "./transam/index";
import { cloneNodeKeepSem } from "../monomorphize/clone";
import { ResolveSection, DepsSection, defaultResolveSection, defaultDepsSection, loadBuildConfig, targetMemoryMode } from "./buildConfig";
import { evaluateComptimeBlocks } from "./meta/comptime";
import { expandMacros } from "./meta/expand";
import { ensureHostTableLoaded, closeHostChildren } from "./meta/hostTable";
import { CliOptions, Target, MODE_DANGER } from "./options";
import { flowStart, flowStop, flowAddMs, flowsEnabled, flowsWrite } from "./flows";
import { atomicWriteFile, writeOutput, printTiming, verboseLog, replaceExt, ensureDir, exeSuffix, soSuffix, outDirForMode, stopBuild, setRecoverableBuild, BUILD_STOPPED } from "./io";
import { compileCFile, objectCompileArgs, compilePlanFor, useDriverPlans, driverPlansOn, NO_PLAN, includePrefix, buildPch, linkObjects, warmLinkPlan, objectSearchDirs, archiveStatic, linkSolana, SBF_MAIN_NOINLINE_FLAG, reportsSbfFrameOverflow, appendFlag, cliCompileFlags, cliLinkFlags, resolveBpfClang, resolveSbfLinker, markCppCompile, isCppFile, getCompilerName, resolveLto, toolchainHeaderRoot, resolveSbfObjcopy } from "./cc";
import { defineIdentity, createDefineTable, initDefines, applyDefineSwitch, isDefined } from "./defines";
import { resolveCC } from "./toolchain";
import { linkFlags as globalLinkFlags, linkObjects as globalLinkObjects } from "../utils/linkState";
import { initCache, stableOFileFp, fullCompileCmd, isCompileCached, objectStoreKey, nativeStoreSource, moduleStoreSource, restoreNativeObject, restoreModuleObject, publishToStore, computeFingerprint, publishNativeObject, nativeDepFile, registerNativeDependencies, projectCacheChanged, projectRecordCurrent, writeProjectCache, stableCFileFp, isCCodeCached, writeCSource, writeCompileFingerprintFp, moduleCompileFp, moduleObjectFp, moduleDepFile, publishModuleObject, invalidateCompileCache, isLinkCached, writeLinkCache, cacheDir, headerModuleKey, lookupHeaderModule, storeHeaderModule, toolchainStamp, objectStamp, stdTreeStamp, writePchManifest, pchManifestCurrent, setToolchainHeaderRoot } from "./cache";
import { hashContent } from "../utils/contentHash";
import { splitCcFlags, quoteCcArg } from "../utils/commandLine";
import { error, success, bold, dim, green, red, yellow, cyan, blue } from "../utils/color";
import { resolveRuntimeDir, resolveArgv0 } from "../utils/path";
import { join, isAbsolute, dirname, basename, relative, normalize } from "std/fs/path";
import { HcrAbiExport, HcrModuleAbi, HcrReloadDecision, HcrReloadKind, HcrReloadReason, buildHcrModuleAbi, classifyHcrReload, createHcrAbiExport, hcrAbiFingerprint, hcrLayoutKey, hcrReloadDiagnostic, hcrSignatureKey, parseHcrAbiBundle, serializeHcrAbiBundle } from "./hcrAbi";
import { VERSION } from "./usage";

// Header-inline disk cache injection (loader can't import ./cache directly —
// checker/context → module/graph layering; callbacks pattern). Registered at
// module load so every later build engages it without an init-order hazard.
registerHeaderCache(headerModuleKey, lookupHeaderModule, storeHeaderModule);
// Prelude pack shares the object cache's memoized toolchainStamp — one stamp
// computation per process instead of two (the pack's local fallback would
// re-hash the 30MB binary + runtime/ + vendor/ every process).
registerPreludeStampFn(toolchainStamp, stdTreeStamp);

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

export function fileDepRoots(projectRoot: string): DepsSection {
	const roots = defaultDepsSection();
	if (projectRoot != "") {
		const cfg = loadBuildConfig(join(projectRoot, "build.ms"), false);
		if (cfg.valid) {
			addFileDepRoots(cfg.deps, projectRoot, roots);
			addFileDepRoots(cfg.devDeps, projectRoot, roots);
		}
	}
	return roots;
}

export function depRoots(projectRoot: string): DepsSection {
	const roots = fileDepRoots(projectRoot);
	const lockPath = projectRoot != "" ? join(projectRoot, "msc.lock") : "msc.lock";
	const lock = readLockfile(lockPath);
	if (lock.ok) {
		for (const entry of lock.value.entries) {
			const name = entryName(entry.key);
			let srcPath = "";
			if (entry.source == SourceKind.Git && entry.url != "" && entry.commit != "") {
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
	const hook = _diagnosticHook;
	for (const err of graph.errors) {
		if (hook != null) hook("", { message: err, line: 0, column: 0, severity: ErrorSeverity.Error });
		else printDiag(red("graph error: ") + err);
	}
	for (const dep of graph.circularDeps) {
		let circMsg = `circular import: ${dep.fromPath} <-> ${dep.toPath}`;
		if (hook != null) {
			hook(dep.fromPath, { message: circMsg, line: dep.importLine as int32, column: 0, severity: ErrorSeverity.Warning });
			continue;
		}
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
	const line = lines[idx];
	return line.endsWith("\r") ? line.slice(0, line.length - 1) : line;
}

function printDiag(line: string): void {
	writeStderr(line + "\n");
}

let eventsPath = "";
let eventDiagnostics: string[] = [];

function jsonText(s: string): string {
	return stringify(jsonString(s));
}

function jsonTexts(values: string[]): string {
	const items: string[] = [];
	for (const value of values) items.push(jsonText(value));
	return `[${items.join(",")}]`;
}

function diagnosticJson(file: string, line: int32, column: int32, severity: string, message: string): string {
	return `{"file":${jsonText(file)},"line":${line},"col":${column},"severity":"${severity}","message":${jsonText(message)}}`;
}

function appendEvent(path: string, name: string, commaFields: string): boolean {
	if (path == "") return true;
	const line = `{"v":1,"t":${Math.floor(Date.now()) as int64},"event":"${name}"${commaFields}}\n`;
	if (path == "-") {
		writeStdout(line);
		return true;
	}
	return appendFile(path, line).ok;
}

function emitEventTo(path: string, name: string, commaFields: string): void {
	if (appendEvent(path, name, commaFields)) return;
	printError(`cannot write the event to '${path}'`);
	exit(1);
}

function emitEvent(name: string, commaFields: string): void {
	emitEventTo(eventsPath, name, commaFields);
}

function plainText(s: string): string {
	let out = "";
	let i: int32 = 0;
	while (i < s.byteLength) {
		if (s.byteAt(i) == 27 && i + 1 < s.byteLength && s.byteAt(i + 1) == "[".code) {
			i += 2;
			while (i < s.byteLength && s.byteAt(i) != "m".code) i += 1;
			i += 1;
		} else {
			out = out + s.byteSlice(i, i + 1);
			i += 1;
		}
	}
	return out;
}

function recordError(message: string): void {
	if (eventsPath != "") eventDiagnostics.push(diagnosticJson("", 0, 0, "error", plainText(message)));
}

function printError(message: string): void {
	recordError(message);
	printDiag(`${error("error")}: ${message}`);
}

function printErrorOut(message: string): void {
	recordError(message);
	console.log(`${error("error")}: ${message}`);
}

let _diagnosticHook: ((file: string, e: ModuleError) => void) | null = null;

export function setDiagnosticHook(hook: ((file: string, e: ModuleError) => void) | null): void {
	_diagnosticHook = hook;
}

// Render a single structured error in Rust-style format
function renderModuleError(modPath: string, source: string, e: ModuleError): void {
	if (eventsPath != "") eventDiagnostics.push(diagnosticJson(modPath, e.line, e.column, e.severity == ErrorSeverity.Warning ? "warning" : "error", e.message));
	const hook = _diagnosticHook;
	if (hook != null) {
		hook(modPath, e);
		return;
	}
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
				renderModuleError(mod.path, mod.rawSource, e);
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
	stopBuild();
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
	stopBuild();
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
			renderModuleError(mod.path, mod.rawSource, e);
			rendered = rendered + 1;
		}
	}
	if (hasErr) stopBuild();
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

// Resolve the memory mode the build will actually run with, BEFORE the graph is
// checked — the checker needs it (freestanding async gate) and it must agree
// with what codegen/cc see later.
// Mutates opts so every later consumer reads one resolved value.
export function resolveTargetGcMode(opts: CliOptions): void {
	opts.gcMode = targetMemoryMode(opts.targetOs, opts.gcExplicit ? opts.gcMode : "");
}

// String memory mode → checker enum. Single spelling of the mapping that
// applyGcMode and the per-module stamping in cmdBuildC/cmdTest repeat.
export function gcModeOf(gc: string): GcMode {
	if (gc == "none") return GcMode.None;
	if (gc == "manual") return GcMode.Manual;
	return GcMode.Drc;
}

// Apply --mm flag: set GcMode on the shared prelude context so all modules inherit it.
// analyzeProgram checks ctx.gcMode and skips DRC injection for None/Manual.
export function applyGcMode(opts: CliOptions): void {
	if (graphPreludeCtx == null) return;
	graphPreludeCtx.gcMode = gcModeOf(opts.gcMode);
	graphPreludeCtx.targetOs = opts.targetOs;
	graphPreludeCtx.targetInfo = opts.targetInfo;
}

// Loader-half timing gate, twin of the orchestrator's setGraphCheckTiming —
// both fire under -t so one flag split stays observable in one place.
let graphLoadTiming: boolean = false;
export function setGraphLoadTiming(on: boolean): void {
	graphLoadTiming = on;
}

function moduleNameProjectRoot(entryPath: string, projectRoot: string): string {
	const entry = canonicalModulePath(entryPath);
	if (projectRoot != "" && exists(join(projectRoot, "build.ms"))) {
		const root = canonicalModulePath(projectRoot);
		if (entry.startsWith(`${root}/`)) return root;
	}
	return dirname(entry);
}

function loadAndCheckGraph(entryPath: string, config: ResolverConfig, opts: CliOptions, targetInfo: TargetInfo = hostTargetInfo(), gcMode: GcMode = GcMode.Drc, session: CheckSession | null = null): ModuleGraph {
	if (opts.verbose) verboseLog(`loading module graph from ${entryPath}`);
	const packages = cacheRoot();
	setModuleNameRoots({
		compiler: config.stdPath != "" ? dirname(config.stdPath) : "",
		packages: packages != "" ? `${packages}/extracted` : "",
		project: moduleNameProjectRoot(entryPath, opts.projectRoot),
		uniqueNames: new HashMap<string, string>(),
	});
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
	const backendExt = config.extensions.length > 0 ? config.extensions[0] : ".cms";
	const _gl0 = performance.now();
	if (config.stdPath != "") {
		loadPreludeModules(graph, provider, config);
	}
	const _pl0 = performance.now();
	const _r = loadModule(graph, entryPath, provider, config, 1);
	registerModuleNames(buildModuleNameRoots(), graph.loadOrder);
	if (graphLoadTiming) {
		const ht = takeHeaderTimings();
		console.log(`    graphLoad: preludeMods=${performance.now() - _gl0}ms entryTree=${performance.now() - _pl0}ms modules=${graph.loadOrder.length} seed=${_preludeSeedHit ? 1 : 0} headers=${ht.ms}ms/${ht.n} hits=${ht.hits}`);
	}

	reportGraphErrors(graph);
	if (graph.errors.length > 0) stopBuild();
	exitOnModuleErrors(graph, "error");

	if (opts.verbose) verboseLog("cross-module type check");
	// Pass targetOs through so @platform("...") directives are filtered against
	// the build target during collectDirectives. Without this, modules check
	// with stale ctx.targetOs → mac directives leak into a cross-compile
	// windows build's linkFlags().
	graphRegistry = checkModuleGraph(graph, config.stdPath, backendExt, opts.targetOs, targetInfo, gcMode, config, session, opts.strictNullChecks, opts.appMode);
	graphPreludeCtx = getPreludeContext();
	if (opts.isHcr) markVmOnlyRoutines(graph, config.stdPath);
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
		if (_diagnosticHook == null) printError(`${graphErrors} type error(s) found, stopping before codegen`);
		stopBuild();
	}
	markTypeOnlyImports(graph, config.stdPath);
	return graph;
}

// Load prelude modules (globalImports) into the module graph.
// Extension resolved by the resolver based on target backend.
//
// BUILD-PERF Phase A2: on a warm key the graph is SEEDED from the deps pack
// (<key>.deps, written next to the prelude pack). provideSource and the
// header translation still run per module — mod.source and header
// diagnostics must stay byte-identical to the fresh path — only the
// lex+parse+resolver-probe discovery of the std closure is skipped. Any
// doubt (pack off, no snapshot, a source gone missing) falls back to the
// fresh parse path below, which then re-captures the snapshot for the
// writer.
let _preludeSeedHit: boolean = false;

function preludeSeedKey(config: ResolverConfig): string {
	return preludePackKey(config.stdPath, config.extensions.join(","));
}

function loadPreludeModules(graph: ModuleGraph, provider: SourceProvider, config: ResolverConfig): void {
	_preludeSeedHit = false;
	if (config.stdPath != "") {
		const deps = tryLoadPreludeDeps(preludeSeedKey(config), preludePackStamp(config.stdPath));
		if (deps != null && seedPreludeModules(graph, provider, deps)) _preludeSeedHit = true;
	}
	if (_preludeSeedHit) noteStdGlobalImportModules(graph, provider, config);
	if (!_preludeSeedHit) {
		loadStdGlobalImportModules(graph, provider, config);
		if (config.stdPath != "") writeStdGraphDeps(graph, preludeSeedKey(config), preludePackStamp(config.stdPath));
	}
	loadExtraGlobalImportModules(graph, provider, config);
}

// Replay a deps snapshot into the graph. All sources are provided UP FRONT —
// the seed either builds the whole closure or leaves the graph untouched
// (a half-seeded graph would poison the fresh fallback: modules already in
// loadOrder). A header translates exactly like the fresh path; module state
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
		if (isCHeaderPath(row.path)) {
			const headerErrors: ModuleError[] = [];
			mod.rawSource = headerModuleSource(row.path, provider, graph, headerErrors);
			for (const he of headerErrors) mod.errors.push(he);
		} else {
			mod.rawSource = sources[mi];
		}
		mod.source = mod.rawSource;
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

// Write the std closure (this graph's ENTIRE loadOrder — preludeModules
// runs before the entry tree, so it is exactly the prelude closure) to the
// deps file the next build seeds from.
function writeStdGraphDeps(graph: ModuleGraph, key: string, stamp: string): void {
	const mods: DepsModuleRow[] = [];
	for (const p of graph.loadOrder) {
		const m = findModule(graph, p);
		if (m == null) continue;
		const imports: DepsImportRow[] = [];
		let ii = 0;
		while (ii < m.imports.length) {
			const ie = m.imports[ii];
			if (ie.dynamic) return;
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
	writePreludeDeps(key, stamp, { mods, circulars });
}

// Stored result of Phase A (transform all modules) for Phase B (DCE) and Phase C (codegen).
interface ProcessedModule {
	program: Node;
	ctx: CheckerContext;
	modPath: string;
}

interface FsAsyncHit {
	modPath: string;
	source: string;
	line: int32;
	column: int32;
}

interface A2Timers {
	mono: number;
	macro: number;
	xform: number;
	native: number;
	analyze: number;
	lower: number;
}

interface A2Job {
	modPath: string;
	source: string;
	opts: CliOptions;
	stdPath: string;
	hcrSlot: int32;
	hcrModules: HcrIndirectModule[];
	fsAsyncHits: FsAsyncHit[];
	timers: A2Timers;
	diagnostics: ModuleError[];
	instances: Node[];
	cloneInput: boolean;
	ran: boolean;
	claims: LowerClaims;
	asyncModuleBody: boolean;
	writeTables: WriteSummaries;
	liftTables: WriteSummaries;
}

function hasErrorsFrom(ctx: CheckerContext, base: int32): boolean {
	for (let i = base; i < ctx.errors.length; i += 1) {
		if (ctx.errors[i].severity == Severity.Error) return true;
	}
	return false;
}

function truncateErrors(ctx: CheckerContext, base: int32): void {
	while (ctx.errors.length > base) ctx.errors.pop();
}

function exitOnCheckerErrorsFrom(ctx: CheckerContext, base: int32, modPath: string, source: string): void {
	if (!hasErrorsFrom(ctx, base)) return;
	for (let i = base; i < ctx.errors.length; i += 1) {
		const e = ctx.errors[i];
		if (e.severity != Severity.Error) continue;
		renderModuleError(modPath, source, { message: e.message, line: e.line, column: e.column, severity: ErrorSeverity.Error });
	}
	throw new Error(BUILD_STOPPED);
}

function coreBeforeImages(paths: string[], imagePaths: string[]): int32[] {
	const order: int32[] = [];
	for (let at: int32 = 0; at < paths.length; at += 1) if (!imagePaths.includes(paths[at])) order.push(at);
	for (let at: int32 = 0; at < paths.length; at += 1) if (imagePaths.includes(paths[at])) order.push(at);
	return order;
}

function programWithInstances(program: Node, instances: Node[] | null): Node {
	if (instances == null || instances.length == 0) return program;
	const stmts: Node[] = [];
	for (const stmt of (program.data as ProgramData).programStmts) stmts.push(stmt);
	for (const inst of instances) stmts.push(inst);
	return createNodeAt(NodeKind.Program, { programStmts: stmts }, program.location);
}

function lowerModuleA2(checked: Node, ctx: CheckerContext, job: A2Job): Node {
	job.ran = true;
	const keyedOpMark = opMark();
	const opts = job.opts;
	const modPath = job.modPath;
	let program = checked;
	if (job.cloneInput) {
		program = cloneNodeKeepSem(checked);
		for (const inst of job.instances) (program.data as ProgramData).programStmts.push(cloneNodeKeepSem(inst));
	}
	const errBase = ctx.errors.length;
	if (opts.verbose) verboseLog(`transforming ${modPath}`);
	const _tm0 = performance.now();
	const _fm0 = flowStart();
	const monoed = monomorphizeProgram(program, ctx);
	validateTypedAST(ctx, monoed);
	job.timers.mono = job.timers.mono + (performance.now() - _tm0);
	flowStop("a2.mono", _fm0);
	if (hasErrorsFrom(ctx, errBase)) {
		for (let i = errBase; i < ctx.errors.length; i += 1) {
			const e = ctx.errors[i];
			const shown: ModuleError = { message: e.message, line: e.line, column: e.column, severity: ErrorSeverity.Warning };
			job.diagnostics.push(shown);
			renderModuleError(modPath, job.source, shown);
		}
		truncateErrors(ctx, errBase);
	}

	const _tmc0 = performance.now();
	const _fmc0 = flowStart();
	const macroExpanded = expandMacros(monoed, ctx);
	exitOnCheckerErrorsFrom(ctx, errBase, modPath, job.source);
	const comptimeResolved = evaluateComptimeBlocks(macroExpanded);
	job.timers.macro = job.timers.macro + (performance.now() - _tmc0);
	flowStop("a2.macro", _fmc0);
	if (opts.gcMode == "manual" && !(job.stdPath != "" && modPath.startsWith(job.stdPath))) {
		for (const hitNode of collectFreestandingAsync(comptimeResolved)) {
			const hitLoc = freestandingAsyncLoc(hitNode);
			job.fsAsyncHits.push({ modPath, source: job.source, line: hitLoc.line, column: hitLoc.column });
		}
	}
	const hcrSlot = job.hcrSlot;
	const _tx0 = performance.now();
	const _fx0 = flowStart();
	const reloadable: string[] = [];
	if (hcrSlot >= 0) for (const module of job.hcrModules) reloadable.push(module.modulePath);
	const transformed = transformProgram(comptimeResolved, ctx, false, reloadable, job.asyncModuleBody, job.liftTables);
	job.timers.xform = job.timers.xform + (performance.now() - _tx0);
	flowStop("a2.xform", _fx0);
	exitOnCheckerErrorsFrom(ctx, errBase, modPath, job.source);
	const nativeCtx = createTransformContextWithChecker(ctx);
	nativeCtx.rangeChecks = opts.mode != MODE_DANGER;
	nativeCtx.boundChecks = opts.mode != MODE_DANGER;
	nativeCtx.objChecks = opts.mode != MODE_DANGER;
	const _tn0 = performance.now();
	const _fn0 = flowStart();
	const nativeTransformed = transformForNative(transformed, nativeCtx);
	job.timers.native = job.timers.native + (performance.now() - _tn0);
	flowStop("a2.native", _fn0);
	const hcrLifted = hcrSlot >= 0 ? liftHcrState(nativeTransformed, nativeCtx, job.hcrModules[hcrSlot].moduleId) : nativeTransformed;
	exitOnCheckerErrorsFrom(ctx, errBase, modPath, job.source);
	ctx.gcMode = gcModeOf(opts.gcMode);
	ctx.targetOs = opts.targetOs;
	ctx.targetInfo = opts.targetInfo;
	const _ta0 = performance.now();
	const _fa0 = flowStart();
	const preAnErrors = ctx.errors.length;
	const analyzed = analyzeProgram(hcrLifted, ctx, job.writeTables);
	if (ctx.errors.length > preAnErrors) {
		for (let ei = preAnErrors; ei < ctx.errors.length; ei += 1) {
			const e = ctx.errors[ei];
			renderModuleError(modPath, job.source, { message: e.message, line: e.line, column: e.column, severity: ErrorSeverity.Error });
		}
		throw new Error(BUILD_STOPPED);
	}
	job.timers.analyze = job.timers.analyze + (performance.now() - _ta0);
	flowStop("a2.analyze", _fa0);
	const _tl0 = performance.now();
	const _fl0 = flowStart();
	const nativeLowered = lowerNativeAccess(analyzed, nativeCtx);
	job.timers.lower = job.timers.lower + (performance.now() - _tl0);
	flowStop("a2.lower", _fl0);
	truncateErrors(ctx, errBase);
	job.claims = { ops: opsFrom(keyedOpMark), contracts: contractClaims(job.writeTables) };
	return nativeLowered;
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

type ModuleEmitter = Sendable<(job: Readonly<ModuleEmissionJob>, aliveSet: Readonly<AliveSet>, facts: Readonly<CEmissionFacts>, isTestBuild: boolean, isHcr: boolean) => ModuleEmissionResult>;

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

function copyModuleOutput(output: Readonly<CModuleOutput>): CModuleOutput {
	const copy = new CModuleOutput();
	copy.code = output.code;
	copy.modulePath = output.modulePath;
	copy.hasDatInit = output.hasDatInit;
	copy.hasInit = output.hasInit;
	copy.hasDeinit = output.hasDeinit;
	return copy;
}

function emitModulesBounded(jobs: ModuleEmissionJob[], aliveSet: Readonly<AliveSet>, facts: Readonly<CEmissionFacts>, workers: int32, isTestBuild: boolean, hcrEntry: string, emitter: ModuleEmitter = emitModuleJob): ModuleEmissionResult[] {
	const results: ModuleEmissionResult[] = [];
	for (let i = 0; i < jobs.length; i += 1) results.push(new ModuleEmissionResult());
	const order = emissionOrder(jobs);
	const pending: Promise<ModuleEmissionResult>[] = [];
	let next = 0;
	let head = 0;
	let failed = false;
	sealRuntimeProcs(true);
	sealHookSyms(true);
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
	sealRuntimeProcs(false);
	sealHookSyms(false);
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
		const emitters: ModuleEmitter[] = [probeFailedModuleEmission, probeDiagnosticModuleEmission];
		for (const emitter of emitters) {
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
	printError(`${parsed.error}`);
	stopBuild();
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

function ownedBySupportRoot(dir: string, compilerRoot: string): boolean {
	return compilerRoot != "" && (dir == compilerRoot || isUnder(dir, `${compilerRoot}/std`));
}

// Resolve a relative directory path the way processCompileDirectives resolves
// a bare @compile path: the support tree for its own modules, else CWD, then
// the registered include paths (which contain compilerRoot).
function resolveIncludeDir(dir: string, includePaths: HashSet<string>, ownerDir: string, compilerRoot: string): string {
	if (dir == "" || isAbsolute(dir)) return dir;
	if (ownedBySupportRoot(ownerDir, compilerRoot)) return `${compilerRoot}/${dir}`;
	if (exists(dir)) return dir;
	for (const ip of includePaths) {
		const candidate = `${ip}/${dir}`;
		if (exists(candidate)) return candidate;
	}
	return dir;
}

// Resolve relative -I/-iquote/-isystem paths in a flags string using the
// same rule as @compile.
function resolveIncludeFlags(flags: string, includePaths: HashSet<string>, ownerDir: string, compilerRoot: string): string {
	if (flags == "") return flags;
	let result = "";
	for (const p of flagArgsOrExit(flags)) {
		let resolved = p;
		if (p.length > 2 && p.slice(0, 2) == "-I") {
			resolved = "-I" + resolveIncludeDir(p.slice(2, p.length), includePaths, ownerDir, compilerRoot);
		} else if (p.length > 7 && p.slice(0, 7) == "-iquote") {
			resolved = "-iquote" + resolveIncludeDir(p.slice(7, p.length), includePaths, ownerDir, compilerRoot);
		} else if (p.length > 8 && p.slice(0, 8) == "-isystem") {
			resolved = "-isystem" + resolveIncludeDir(p.slice(8, p.length), includePaths, ownerDir, compilerRoot);
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
	storeKey: string;
	slot: number;
}

// Process @compile("foo.c") directives: compile each .c file to .o relative to module dir.
//
// Parallel architecture:
//   1. GATHER (serial) — parse directives, dedup via _compiledOFiles, filter
//      cache hits, precompute fingerprints.
//   2. DISPATCH (parallel) — spawn one worker per cache miss. Each worker calls
//      compileCFile() on its own thread — real thread-level parallelism.
//   3. COLLECT (serial, main thread) — waitFor each future in input order, check
//      exit codes, publish cache entries, fill each job's slot so oFiles keep
//      directive order whichever files hit the cache.
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
	const oFiles: string[] = [];
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
				// Bare paths: the support tree for its own modules, else CWD, then
				// the registered include paths.
				let fullPath = cPath;
				if (cPath.slice(0, 2) == "./" || cPath.slice(0, 3) == "../") {
					fullPath = `${moduleDir}/${cPath}`;
				} else if (ownedBySupportRoot(moduleDir, compilerRoot)) {
					fullPath = `${compilerRoot}/${cPath}`;
				} else if (!exists(fullPath)) {
					for (const dir of includePaths) {
						const candidate = `${dir}/${cPath}`;
						if (exists(candidate)) { fullPath = candidate; break; }
					}
				}
				fullPath = normalize(fullPath);
				if (!exists(fullPath)) {
					printError(`@compile cannot find: ${fullPath}`);
					stopBuild();
				}
				// Mark C++ at directive-resolution time (main thread, sequential)
				// so the flag is set regardless of cache-hit / dedup / fresh-compile.
				// See cc.ms `markCppCompile` for the why.
				markCppCompile(fullPath);
				let probeFlags = allFlags;
				if (upFlag != "") probeFlags = appendFlag(probeFlags, upFlag);
				if (customFlags != "") probeFlags = appendFlag(probeFlags, customFlags);
				const probeKey = fullCompileCmd(ccOption, mode, probeFlags, ccBinary, isCppFile(fullPath));
				const dependencyFile = nativeDepFile(fullPath, probeKey);
				const probeFp = computeFingerprint(fullPath, probeKey);
				const probeOFile = stableOFileFp(fullPath, probeFp);
				if (!_compiledOFiles.has(dependencyFile)) {
					_compiledOFiles.add(dependencyFile);
					const fileFlags = probeFlags;
					const fp = probeFp;
					const oFile = probeOFile;
					if (isCompileCached(oFile, fp)) {
						if (verbose) verboseLog(`  @compile ${fullPath} → ${oFile} ${dim("(cached)")}`);
						oFiles.push(oFile);
					} else {
						const storeKey = objectStoreKey(nativeStoreSource(fullPath), ccOption, ccBinary, isCppFile(fullPath), mode, fileFlags);
						const stored = storeKey == "" ? "" : restoreNativeObject(fullPath, probeKey, storeKey, objectSearchDirs(ccOption, ccBinary, isCppFile(fullPath), mode, fileFlags));
						if (stored != "") {
							if (verbose) verboseLog(`  @compile ${fullPath} → ${stored} ${dim("(stored)")}`);
							oFiles.push(stored);
						} else {
							jobs.push({ fullPath, oFile, cPath, fileFlags, fp, dependencyFile, storeKey, slot: oFiles.length });
							oFiles.push("");
						}
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
	// failure path here just stopBuild()s after logging. Direct serial compile/link
	// paths (cmdBuildC body) preserve full Result + stderr display.
	const startedSeconds = Date.now() / 1000;
	const futures: Promise<number>[] = [];
	for (const j of jobs) {
		const parts = objectCompileArgs(ccOption, ccBinary, isCppFile(j.fullPath), mode, j.fileFlags);
		if (!parts.ok) {
			futures.push(spawn(() => unresolvedCompile(parts.error)));
			continue;
		}
		const args = parts.value;
		const plan = NO_PLAN;
		futures.push(spawn(() => {
			let r = compileCFile(j.fullPath, j.oFile, j.dependencyFile, args, plan);
			if (!r.ok && r.error.exitCode == 0) {
				// exitCode 0 with !ok = the process never ran (posix_spawn failure,
				// e.g. transient EAGAIN under fork pressure from N parallel jobs).
				// One retry absorbs it; a real compile error has a nonzero exitCode
				// and is not retried.
				r = compileCFile(j.fullPath, j.oFile, j.dependencyFile, args, plan);
			}
			if (r.ok) return 0;
			// Surface the failure reason — the parallel path otherwise discards
			// stderr and the join loop only reports the exit code.
			printDiag(r.error.errorOutput != "" ? r.error.errorOutput : `${r.error.command}: ${r.error.message}`);
			return r.error.exitCode != 0 ? r.error.exitCode : -1;
		}));
	}
	const exitCodes: number[] = [];
	for (const f of futures) exitCodes.push(await f);

	// === 3. COLLECT (serial from main thread) ===
	let ci = 0;
	while (ci < jobs.length) {
		const j = jobs[ci];
		const code = exitCodes[ci];
		if (code != 0) {

			printError(`@compile failed for ${j.fullPath} ${dim(`(exit ${code})`)}`);
			stopBuild();
		}
		const compileCmd = fullCompileCmd(ccOption, mode, j.fileFlags, ccBinary, isCppFile(j.fullPath));
		registerNativeDependencies(j.fullPath, compileCmd);
		const dirs = objectSearchDirs(ccOption, ccBinary, isCppFile(j.fullPath), mode, j.fileFlags);
		const published = publishNativeObject(j.fullPath, compileCmd, j.oFile, j.fp, startedSeconds);
		if (published.ok) {
			publishToStore(j.storeKey, published.value, j.dependencyFile, j.fullPath, dirs, [dirname(j.fullPath)]);
			oFiles[j.slot] = published.value;
		} else {
			printError(`@compile ${j.fullPath}: ${published.error}`);
			stopBuild();
		}
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
	baseFp: string;
	depFile: string;
	cacheKey: string;
	slot: number;
	storeKey: string;
}

// DISPATCH+JOIN for Phase C module compiles — same architecture as
// processCompileDirectives: one spawn per job, number-typed futures (stderr
// printed by the worker), join in input order on the main thread.
const PLANNED_COMPILE_JOBS = 4;

function pchFiles(cFile: string, flags: string, mode: number, ccOption: number, ccBinary: string): string[] {
	const text = readFile(cFile);
	if (!text.ok) return [];
	const prefix = includePrefix(text.value);
	if (prefix == "") return [];
	const key = hashContent(`${prefix}\n${fullCompileCmd(ccOption, mode, flags, ccBinary)}\n${objectStamp()}`);
	return [prefix, `${cacheDir()}/pch/${key}.h`, `${cacheDir()}/pch/${key}.pch`];
}

function currentPch(files: string[]): boolean {
	return files.length == 3 && exists(files[2]) && pchManifestCurrent(`${files[2]}.deps`);
}

function existingPch(cFile: string, flags: string, mode: number, ccOption: number, ccBinary: string): string {
	const files = pchFiles(cFile, flags, mode, ccOption, ccBinary);
	return currentPch(files) ? files[2] : "";
}

interface HcrWarmLink {
	image: string;
	flags: string;
}

let _hcrWarmJobs: ModuleCompileJob[] = [];
let _hcrWarmLinks: HcrWarmLink[] = [];

function warmHcrSession(opts: Readonly<CliOptions>): void {
	for (const j of _hcrWarmJobs) compilePlanFor(j.cFile, j.depFile != "", j.flags, opts.mode, opts.ccCompiler, opts.ccBinary);
	ensurePchs(_hcrWarmJobs, opts.mode, opts.ccCompiler, opts.ccBinary);
	for (const link of _hcrWarmLinks) warmLinkPlan(link.image, link.flags, opts.ccCompiler, opts.ccBinary, opts.targetOs);
	_hcrWarmJobs = [];
	_hcrWarmLinks = [];
}

function ensurePchs(jobs: ModuleCompileJob[], mode: number, ccOption: number, ccBinary: string): void {
	for (const j of jobs) {
		if (j.modPath == "") continue;
		const files = pchFiles(j.cFile, j.flags, mode, ccOption, ccBinary);
		if (files.length != 3 || currentPch(files)) continue;
		ensureDir(dirname(files[1]));
		if (!writeFile(files[1], files[0]).ok) continue;
		const depFile = `${files[2]}.${performance.now()}.d`;
		if (buildPch(files[1], files[2], depFile, j.flags, mode, ccOption, ccBinary)) writePchManifest(depFile, `${files[2]}.deps`);
		remove(depFile);
	}
}

function unresolvedCompile(e: Readonly<ProcessError>): number {
	printDiag(`${e.command}: ${e.message}`);
	return e.exitCode != 0 ? e.exitCode : -1;
}

function dispatchCompileJobs(jobs: ModuleCompileJob[], mode: number, ccOption: number, ccBinary: string, usePlans: boolean): number[] {
	const futures: Promise<number>[] = [];
	for (const j of jobs) {
		const parts = objectCompileArgs(ccOption, ccBinary, isCppFile(j.cFile), mode, j.flags);
		if (!parts.ok) {
			futures.push(spawn(() => unresolvedCompile(parts.error)));
			continue;
		}
		const args = parts.value;
		const plan = usePlans ? compilePlanFor(j.cFile, j.depFile != "", j.flags, mode, ccOption, ccBinary) : NO_PLAN;
		const pch = usePlans ? existingPch(j.cFile, j.flags, mode, ccOption, ccBinary) : "";
		futures.push(spawn(() => {
			let r = compileCFile(j.cFile, j.oFile, j.depFile, args, plan, pch);
			if (!r.ok && r.error.exitCode == 0) {
				// exitCode 0 with !ok = the process never ran (posix_spawn EAGAIN
				// under fork pressure). One retry absorbs it; real compile errors
				// have a nonzero exitCode and are not retried.
				r = compileCFile(j.cFile, j.oFile, j.depFile, args, plan, pch);
			}
			if (r.ok) return 0;
			printDiag(r.error.errorOutput != "" ? r.error.errorOutput : `${r.error.command}: ${r.error.message}`);
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
	printDiag(dim(`  wrote deps → ${depsPath}`));
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

function unitProgramAt(paths: string[], programs: Node[], path: string): Node | null {
	for (let i = 0; i < paths.length; i += 1) {
		if (paths[i] == path) return programs[i];
	}
	return null;
}

function routeInstances(order: Node[], programOf: (path: string) => Node | null, place: boolean, homes: HashMap<Node, string> | null, classesBesideGeneric: boolean = false): HashMap<string, Node[]> {
	const grouped = new HashMap<string, Node[]>();
	const homeOrder: string[] = [];
	for (const instNode of order) {
		const sym = instNode.resolvedSym;
		if (sym == null || sym.modulePath == "") throw new Error(`internal: a generic instance of this build has no owning module`);
		const home = (homes != null ? homes.get(instNode) : null) ?? sym.modulePath;
		let group = grouped.get(home);
		if (group == null) {
			group = [];
			grouped.set(home, group);
			homeOrder.push(home);
		}
		group.push(instNode);
	}
	const byHome = new HashMap<string, Node[]>();
	for (const home of homeOrder) {
		const program = programOf(home);
		if (program == null) throw new Error(`internal: generic instances are placed in ${home}, which is not a module of this build`);
		const placed = distinctInstances(grouped.get(home)!);
		for (const instNode of placed) {
			const sym = instNode.resolvedSym!;
			if (instNode.nodeType == null && sym.symbolType != null) instNode.nodeType = sym.symbolType;
			if (instNode.kind == NodeKind.FunctionDecl) sym.modulePath = home;
			if (place) placeInstance((program.data as ProgramData).programStmts, instNode, classesBesideGeneric);
		}
		byHome.set(home, placed);
	}
	return byHome;
}

function placePendingInstances(programOf: (path: string) => Node | null, moduleCtxs: CheckerContext[], classesBesideGeneric: boolean = false): void {
	retainCheckedInstances(moduleCtxs);
	const _placed = routeInstances(drainPendingInstances(moduleCtxs), programOf, true, null, classesBesideGeneric);
}

function graphCheckedModule(graph: ModuleGraph, modPath: string, mod: Module, opts: CliOptions): { program: Node, ctx: CheckerContext } {
	const program = lookupModuleProgram(modPath);
	const ctx = lookupModuleCtx(modPath);
	if (program == null || ctx == null) throw new Error(`internal: module ${modPath} was not checked by the graph phase`);
	setOuterProgramForComptime(program);
	setOuterCheckContext(graphRegistry, graph, mod, graphPreludeCtx);
	ctx.strictNullChecks = opts.strictNullChecks;
	exitOnFatalCheckerErrors(ctx, modPath, mod.rawSource);
	return { program, ctx };
}

function checkedModCtxs(mods: { program: Node, ctx: CheckerContext, modPath: string, source: string }[]): CheckerContext[] {
	const ctxs: CheckerContext[] = [];
	for (const m of mods) ctxs.push(m.ctx);
	return ctxs;
}

function bundleExportList(names: string[], locals: string[], extra: BundleExport[]): string {
	const specifiers: string[] = [];
	let enumObjects = "";
	const madeObjects = new Set<string>();
	for (let i = 0; i < names.length; i += 1) specifiers.push(exportSpecifier(locals[i], names[i]));
	for (const r of extra) {
		if (r.sym.symbolKind != SymbolKind.Enum) {
			specifiers.push(exportSpecifier(jsBundleReferenceName(r.sym, r.name), r.name));
			continue;
		}
		if (r.sym.declNode == null || r.sym.declNode.kind != NodeKind.EnumDecl) throw new Error(`internal: exported enum '${r.name}' has no declaration`);
		const local = mangledGlobalName(buildModuleNameRoots(), r.sym, r.sym.name);
		if (!madeObjects.has(local)) {
			madeObjects.add(local);
			enumObjects = enumObjects + jsEnumObject(local, r.sym.declNode.data as EnumDeclData);
		}
		specifiers.push(exportSpecifier(local, r.name));
	}
	return specifiers.length == 0 ? "" : `${enumObjects}export { ${specifiers.join(", ")} };\n`;
}

function exportSpecifier(local: string, name: string): string {
	const exported = isJsIdentifierName(name) ? name : `"${name}"`;
	return local == exported ? exported : `${local} as ${exported}`;
}

function isJsIdentifierName(name: string): boolean {
	if (name.length == 0 || isDigit(name.byteAt(0))) return false;
	for (let i = 0; i < name.length; i += 1) {
		const ch = name.byteAt(i);
		if (!isAlphanumeric(ch) && ch != "$".code) return false;
	}
	return true;
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
		manifest = `${manifest}  ],\n  "instances": [\n`;
		for (let i = 0; i < tree.instanceOutRels.length; i += 1) {
			const sep = i + 1 < tree.instanceOutRels.length ? "," : "";
			manifest = `${manifest}    { "source": "${escapeJSString(tree.instanceOwners[i])}", "out": "${escapeJSString(tree.instanceOutRels[i])}" }${sep}\n`;
		}
		manifest = `${manifest}  ]\n}\n`;
		writeOutput(`${splitRoot}/_manifest.json`, manifest);
		if (opts.showTime) printTiming("emitted", t0);
		printDiag(success(`${tree.modulePaths.length} module(s) → ${bold(splitRoot)}`));
		return;
	}
	entryPath = canonicalModulePath(entryPath);
	registerCoreParsers();
	const config = buildResolverConfig(Target.JS, defaultResolveSection());
	const graph = loadAndCheckGraph(entryPath, config, opts, opts.targetInfo);
	const outDir = outputDir != "" ? outputDir : "out";

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

		const checked = graphCheckedModule(graph, modPath, mod, opts);
		const program = checked.program;
		const ctx = checked.ctx;
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
		exitOnCheckerErrors(ctx, modPath, mod.rawSource);
		unitPaths.push(modPath);
		unitPrograms.push(evaluateComptimeBlocks(macroExpanded));
		unitCtxs.push(ctx);
	}

	placePendingInstances((path: string): Node | null => unitProgramAt(unitPaths, unitPrograms, path), unitCtxs, true);
	const dynamicPlan = planDynamicModules(graph, entryPath, unitPaths, config.stdPath);

	// Phase 2 — backend transform + codegen
	let anyTopLevelAwait = false;
	let entryExports = "";
	const helpers = createJSHelpers();
	setJsProgramScope(true);
	for (let ui = 0; ui < unitPaths.length; ui += 1) {
		const modPath = unitPaths[ui];
		const mod = findModule(graph, modPath);
		if (mod == null) continue;
		if (!(config.stdPath != "" && modPath.startsWith(config.stdPath))) {
			refuseSyncAwaitOnJs(unitCtxs[ui], unitPrograms[ui]);
			exitOnCheckerErrors(unitCtxs[ui], modPath, mod.rawSource);
		}
		refusePointerOpsOnJs(unitCtxs[ui], unitPrograms[ui]);
		const reexports = modPath == entryPath ? checkJsBundleExports(unitCtxs[ui], unitPrograms[ui]) : [];
		exitOnCheckerErrors(unitCtxs[ui], modPath, mod.rawSource);
		const transformed = transformProgram(unitPrograms[ui], unitCtxs[ui], true);
		exitOnCheckerErrors(unitCtxs[ui], modPath, mod.rawSource);

		const moduleId = replaceExt(moduleDisplayPath(modPath), "");
		const result = generateJSBundleModule(transformed, modPath, opts.sourcemap, helpers, dynamicPlan);
		if (hasTopLevelAwait(transformed)) {
			anyTopLevelAwait = true;
			if (dynamicPlan.lazy.has(modPath)) dynamicPlan.topLevelAwait.add(modPath);
		}
		if (modPath == entryPath) entryExports = bundleExportList(result.exportedNames, result.exportedLocals, reexports);

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

	setJsProgramScope(false);

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
	// Same reason as generateJSModule: node must meet module syntax before a top-level await.
	if (extImportKeys.length == 0 && anyTopLevelAwait) output = output + "export {};\n";
	output = output + bundleModuleEvaluator(dynamicPlan);
	const headerLines = opts.sourcemap ? countNewlines(output) : 0 as int32;
	output = output + bundle + entryExports;

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
	printDiag(success(`${compiled} module(s) bundled → ${bold(outPath)}`));
}

// Platform-specific runtime compile — dispatch + selectors + pool + fs.
function compilePlatformRuntime(includePaths: HashSet<string>, allFlags: string, opts: CliOptions): string[] {
	if (opts.targetOs == "bare" && opts.cpuTarget == "wasm32") {
		return processCompileDirectives(
			"runtime/freestanding/libc.c", resolveRuntimeDir(), includePaths, allFlags,
			opts.mode, opts.ccCompiler, opts.ccBinary, opts.verbose,
			opts.targetOs, opts.projectRoot, resolveRuntimeDir(),
		);
	}
	if (opts.targetOs == "solana") {
		return processCompileDirectives(
			"runtime/freestanding/musl/pow.c\nruntime/freestanding/musl/pow_data.c\nruntime/freestanding/musl/exp_data.c", resolveRuntimeDir(), includePaths, allFlags,
			opts.mode, opts.ccCompiler, opts.ccBinary, opts.verbose,
			opts.targetOs, opts.projectRoot, resolveRuntimeDir(),
		);
	}
	if (opts.targetOs == "bare") return [];

	let rtFiles = "";
	if (opts.targetOs == "emcc") {
		rtFiles = "runtime/promise/dispatchEmcc.c\nruntime/promise/pool.c\nruntime/promise/awaitGroup.c";
	} else if (opts.targetOs == "wasm") {
		rtFiles = "runtime/promise/dispatchWasm.c\nruntime/promise/pool.c\nruntime/promise/awaitGroup.c";
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
	}
	rtFiles = rtFiles + "\n" + (opts.targetOs == "windows" ? "runtime/fs/windows.c" : "runtime/fs/posix.c");

	rtFiles = rtFiles + "\n" + "runtime/promise/drain.c";
	rtFiles = rtFiles + "\n" + "runtime/promise/moduleEval.c";
	if (opts.isHcr) rtFiles = rtFiles + "\n" + "runtime/hcr.c";

	if (rtFiles == "") return [];
	return processCompileDirectives(rtFiles, resolveRuntimeDir(), includePaths, allFlags, opts.mode, opts.ccCompiler, opts.ccBinary, opts.verbose, opts.targetOs, opts.projectRoot, resolveRuntimeDir());
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
	const graph = loadAndCheckGraph(entryPath, config, opts, opts.targetInfo, gcModeOf(opts.gcMode));
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

function hcrModuleId(modPath: string, root: string, stdPath: string, deps: DepsSection): string {
	if (stdPath != "" && isUnder(modPath, stdPath)) return "";
	if (isUnder(modPath, root)) return replaceExt(relative(root, modPath), "");
	for (let i = 0; i < deps.keys.length; i += 1) {
		if (isUnder(modPath, deps.values[i])) return `${deps.keys[i]}/${replaceExt(relative(deps.values[i], modPath), "")}`;
	}
	return "";
}

function hcrFunctionSymbol(fn: Symbol): string {
	if (fn.exportName != "") return fn.exportName;
	if (fn.nativeName != "") return fn.nativeName;
	if (hasFlag(fn, SymbolFlag.ImportC)) return safeName(fn.name);
	return mangleProcName(fn.name, mangleModuleName(buildModuleNameRoots(), fn.modulePath), fn.disamb);
}
function hcrFunctionSlot(fn: Symbol): string {
	if (fn.exportName != "") return fn.exportName;
	if (fn.nativeName != "") return fn.nativeName;
	if (hasFlag(fn, SymbolFlag.ImportC)) return safeName(fn.name);
	return `${fn.name}#${fn.disamb}`;
}


function appendHcrFunctionExport(exports: HcrAbiExport[], moduleId: string, info: ExportedSymInfo, fn: Symbol): Result<void, string> {
	if (hasFlag(fn, SymbolFlag.OverloadSig) || hasFlag(fn, SymbolFlag.Borrow)) return Result.ok(null);
	if (hasGenericParams(fn.symbolType) || hasFlag(fn, SymbolFlag.CompileTime)) return Result.ok(null);
	if (fn.declNode != null && fn.declNode.kind == NodeKind.FunctionDecl && isGenericFn((fn.declNode.data as FunctionDeclData).fnFlags)) return Result.ok(null);
	exports.push(createHcrAbiExport(moduleId, hcrFunctionSymbol(fn), hcrSignatureKey(fn.symbolType), hcrFunctionSlot(fn)));
	return Result.ok(null);
}

function hcrModuleExports(moduleId: string, modPath: string): Result<HcrAbiExport[], string> {
	const exports: HcrAbiExport[] = [];
	const moduleExports = findModuleExports(graphRegistry, modPath);
	if (moduleExports == null) return Result.ok(exports);
	for (const info of moduleExports.symbols) {
		if (info.sym.modulePath != modPath || info.sym.symbolKind != SymbolKind.Function) continue;
		const primary = appendHcrFunctionExport(exports, moduleId, info, info.sym);
		if (!primary.ok) return Result.err(primary.error);
		for (const ov of info.sym.overloads) {
			const overload = appendHcrFunctionExport(exports, moduleId, info, ov);
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
	const deps = depRoots(opts.projectRoot != "" ? opts.projectRoot : root);
	const cpu = opts.targetInfo.cpu != "" ? opts.targetInfo.cpu : "host";
	const targetKey = `${opts.targetOs}:${cpu}:${opts.targetInfo.ptrSize}:${opts.targetInfo.floatSize}`;
	const toolchainKey = `${VERSION}:${toolchainStamp()}:${getCompilerName(opts.ccCompiler, opts.ccBinary)}:${hashContent(compileFlags)}`;
	const candidate: HcrModuleAbi[] = [];
	const modulePaths: string[] = [];
	const imageOwners = new HashMap<string, string>();
	const globalImportIds: string[] = [];
	for (const modPath of graph.loadOrder) {
		const mod = findModule(graph, modPath);
		if (mod == null || !mod.extraPrelude) continue;
		const moduleId = hcrModuleId(modPath, root, stdPath, deps);
		if (moduleId != "") globalImportIds.push(moduleId);
	}
	for (const modPath of graph.loadOrder) {
		const moduleId = hcrModuleId(modPath, root, stdPath, deps);
		if (moduleId == "") continue;
		const imageName = moduleId.replaceAll("/", ".");
		const owner = imageOwners.get(imageName);
		if (owner != null) {
			return Result.err(`HCR modules '${owner}' and '${modPath}' both build the image '${imageName}'; rename one of them`);
		}
		imageOwners.set(imageName, modPath);
		const mod = findModule(graph, modPath);
		if (mod == null) return Result.err(`HCR ABI module '${modPath}' is missing from the graph`);
		const dependencies: string[] = [];
		for (const imported of mod.imports) {
			const dependencyId = hcrModuleId(imported.sourcePath, root, stdPath, deps);
			if (dependencyId == "") continue;
			dependencies.push(dependencyId);
		}
		for (const globalId of globalImportIds) {
			if (globalId != moduleId && !dependencies.includes(globalId)) dependencies.push(globalId);
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



function pushDispatcherJob(cJobs: ModuleCompileJob[], oSlots: string[][], key: string, source: string, flags: string, opts: CliOptions): void {
	const fp = moduleCompileFp(source, fullCompileCmd(opts.ccCompiler, opts.mode, flags, opts.ccBinary));
	if (isCCodeCached(key, fp)) {
		oSlots.push([stableOFileFp(key, fp)]);
		return;
	}
	writeCSource(key, fp, source);
	oSlots.push([]);
	cJobs.push({ cFile: stableCFileFp(key, fp), oFile: stableOFileFp(key, fp), modPath: "", flags, fp: "", baseFp: fp, depFile: "", cacheKey: key, slot: oSlots.length - 1, storeKey: "" });
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
	if (targetOs == "linux" || targetOs == "android") return `${stem}.so`;
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
	assert hcrCoreImagePath("out/libapp.so", "android") == "out/libapp.core.so";
}

function linkHcrImage(objects: string[], coreInput: string, externalInputs: string[], image: string, flags: string, opts: CliOptions): boolean {
	if (isLinkCached(objects, externalInputs, flags, image, image)) {
		_hcrWarmLinks.push({ image, flags });
		return false;
	}
	const inputs: string[] = [];
	for (const oFile of objects) inputs.push(oFile);
	if (coreInput != "") inputs.push(coreInput);
	const linked = linkObjects(inputs, image, flags, opts.mode, opts.ccCompiler, opts.ccBinary, opts.targetOs);
	if (!linked.ok) {
		recordError(`link failed for HCR image ${image} (exit ${linked.error.exitCode})`);
		console.log(`${error("error")}: link failed for HCR image ${image} ${dim(`(exit ${linked.error.exitCode})`)}`);
		if (linked.error.errorOutput != "") console.log(linked.error.errorOutput);
		throw new Error(BUILD_STOPPED);
	}
	writeLinkCache(objects, externalInputs, flags, image, image);
	return true;
}

function linkInputs(opts: CliOptions): string[] {
	const inputs: string[] = [];
	for (const obj of globalLinkObjects()) inputs.push(obj);
	for (const obj of opts.link) {
		if (!inputs.includes(obj)) inputs.push(obj);
	}
	return inputs;
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
): string[] {
	let linkFlags = cliLinkFlags(allFlags, opts);
	for (const flag of globalLinkFlags()) linkFlags = appendFlag(linkFlags, flag);
	const externalInputs = linkInputs(opts);

	const core = hcrCoreImagePath(outBinary, opts.targetOs);
	let coreFlags = linkFlags;
	let imageFlags = linkFlags;
	let coreInput = core;
	if (opts.targetOs == "windows") {
		coreInput = `${hcrImageStem(outBinary)}.core.lib`;
		coreFlags = appendFlag(coreFlags, "-Wl,--export-all-symbols");
		coreFlags = appendFlag(coreFlags, quoteCcArg(`-Wl,--out-implib,${coreInput}`));
	} else if (opts.targetOs == "linux" || opts.targetOs == "android") {
		coreFlags = appendFlag(coreFlags, quoteCcArg(`-Wl,-soname,${basename(core)}`));
		imageFlags = appendFlag(imageFlags, "-Wl,-rpath,$ORIGIN");
	} else if (opts.targetOs == "darwin" || opts.targetOs == "macos") {
		coreFlags = appendFlag(coreFlags, quoteCcArg(`-Wl,-install_name,@rpath/${basename(core)}`));
		imageFlags = appendFlag(imageFlags, "-Wl,-rpath,@loader_path");
	} else {
		printErrorOut(`--hcr has no per-module image adapter for target '${opts.targetOs}'`);
		throw new Error(BUILD_STOPPED);
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
	linkHcrImage(coreObjects, "", externalInputs, core, coreFlags, opts);

	const relinked: string[] = [];
	for (let i = 0; i < hcrModulePaths.length; i += 1) {
		const moduleId = hcrModules[i].moduleId;
		if (moduleId == "core") {
			printErrorOut(`HCR module id 'core' collides with the core image name; rename the module`);
			throw new Error(BUILD_STOPPED);
		}
		const j = jobPaths.indexOf(hcrModulePaths[i]);
		if (j < 0) {
			printErrorOut(`internal: HCR module '${hcrModulePaths[i]}' was not emitted`);
			throw new Error(BUILD_STOPPED);
		}
		const objects: string[] = [];
		for (const oFile of oSlots[moduleSlots[j]]) objects.push(oFile);
		for (const oFile of oSlots[moduleSlots[j] + 1]) objects.push(oFile);
		for (const oFile of oSlots[imageSlots[i]]) objects.push(oFile);
		const image = hcrModulePaths[i] == entryPath ? outBinary : hcrImagePath(outBinary, moduleId);
		let flags = imageFlags;
		if (opts.targetOs == "windows") flags = appendFlag(flags, quoteCcArg(`-Wl,--out-implib,${cacheDir()}/hcr-${hashContent(image)}.lib`));
		if (linkHcrImage(objects, coreInput, externalInputs, image, flags, opts)) relinked.push(hcrModulePaths[i]);
	}
	return relinked;
}

function hcrTypeLayoutKeys(layouts: HcrTypeLayout[]): string[] {
	const pairs: string[] = [];
	for (const layout of layouts) {
		pairs.push(layout.name);
		pairs.push(hcrLayoutKey(layout.subject));
	}
	return pairs;
}

function hcrTypeLayouts(program: Node | null): HcrTypeLayout[] {
	const layouts: HcrTypeLayout[] = [];
	if (program == null) return layouts;
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
		if (name == "" || decl.resolvedSym == null || hasFlag(decl.resolvedSym, SymbolFlag.Anon)) continue;
		layouts.push({ name, subject: decl.resolvedSym.symbolType, byValue: decl.kind == NodeKind.StructDecl });
	}
	return layouts;
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

function hcrRootFunctions(modulePaths: string[]): Symbol[] {
	const roots: Symbol[] = [];
	for (const modPath of modulePaths) {
		const moduleExports = findModuleExports(graphRegistry, modPath);
		if (moduleExports == null) continue;
		for (const info of moduleExports.symbols) {
			if (info.sym.modulePath != modPath || info.sym.symbolKind != SymbolKind.Function) continue;
			roots.push(info.sym);
		}
	}
	const uninitialized = compilerFuncSym("msModuleBindingUninitialized");
	if (uninitialized != null) roots.push(uninitialized);
	return roots;
}

function refuseCoreCallsIntoImageOps(unit: ProcessedModule, imagePaths: string[], aliveSet: Readonly<AliveSet>): void {
	for (const stmt of (unit.program.data as ProgramData).programStmts) {
		const op = stmt.kind == NodeKind.FunctionDecl ? stmt.resolvedSym : null;
		if (op == null) continue;
		const users = aliveSet.foreignOps.readonlyGet(op);
		if (users == null) continue;
		for (const user of users) {
			if (imagePaths.includes(user)) continue;
			printError(`internal: HCR core module '${user}' calls '${op.name}', which module '${unit.modPath}' generates in its reloadable image`);
			throw new Error(BUILD_STOPPED);
		}
	}
}

function bindHcrUnits(modules: HcrIndirectModule[], processed: ProcessedModule[], aliveSet: Readonly<AliveSet>, facts: CEmissionFacts, counted: boolean, storage: HcrStorageTable): void {
	const imagePaths: string[] = [];
	for (const module of modules) {
		imagePaths.push(module.modulePath);
		facts.hcrModules.set(module.modulePath, module.moduleId);
	}
	for (const info of facts.typeInfoOrder) {
		for (const module of modules) {
			if (info.owner == module.modulePath && !module.typeInfos.includes(info.cName)) module.typeInfos.push(info.cName);
		}
	}
	for (const module of modules) {
		for (const name of module.typeInfos) {
			const claimed = facts.hcrTypeInfoOwners.readonlyGet(name);
			if (claimed != null && claimed != module.moduleId) {
				printError(`internal: HCR TypeInfo '${name}' is owned by both '${claimed}' and '${module.moduleId}'`);
				throw new Error(BUILD_STOPPED);
			}
			facts.hcrTypeInfoOwners.set(name, module.moduleId);
		}
	}
	for (let i = 0; i < modules.length; i += 1) modules[i].typeCounts = hcrTypeCounts(modules[i], modules, facts, counted);
	const owners = new HashMap<string, string>();
	for (const module of modules) {
		for (const unit of processed) {
			if (unit.modPath != module.modulePath) continue;
			refuseCoreCallsIntoImageOps(unit, imagePaths, aliveSet);
			for (const fn of hcrFunctions(unit.program, aliveSet, unit.modPath, facts)) {
				if (!owners.has(fn.symbol) || fn.sourcePath == unit.modPath) owners.set(fn.symbol, module.moduleId);
			}
		}
	}
	for (const module of modules) {
		for (const unit of processed) {
			if (unit.modPath != module.modulePath) continue;
			unit.program = lowerHcrIndirection(cloneNodeKeepSem(unit.program), module, modules, owners, aliveSet, facts, storage);
		}
	}
}

function hcrIndirectModules(abi: HcrCandidateAbi): Result<HcrIndirectModule[], string> {
	const modules: HcrIndirectModule[] = [];
	for (let i = 0; i < abi.candidate.length; i += 1) {
		const manifest = abi.candidate[i];
		const imports: string[] = [];
		for (const dependency of manifest.dependencies) {
			const target = hcrManifestById(abi.candidate, dependency);
			if (target == null) return Result.err(`HCR module '${manifest.moduleId}' imports '${dependency}', which has no ABI manifest`);
			imports.push(dependency);
		}
		modules.push({
			moduleId: manifest.moduleId,
			modulePath: abi.modulePaths[i],
			typeInfos: [],
			typeKeys: [],
			typeLayouts: [],
			typeCounts: [],
			imports,
			beforeReload: [],
			afterReload: [],
		});
	}
	return Result.ok(modules);
}

function hcrManifestById(manifests: HcrModuleAbi[], moduleId: string): HcrModuleAbi | null {
	for (const manifest of manifests) {
		if (manifest.moduleId == moduleId) return manifest;
	}
	return null;
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

let hcrRestartReason = "";

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
		printError(`cannot serialize HCR ABI bundle: ${encoded.error}`);
		throw new Error(BUILD_STOPPED);
	}
	if (!atomicWriteFile(state.bundlePath, encoded.value)) {
		printError(`cannot publish HCR ABI bundle '${state.bundlePath}'`);
		throw new Error(BUILD_STOPPED);
	}
	for (const decision of decisions) {
		console.log(hcrReloadDiagnostic(decision));
		const kind = decision.kind == HcrReloadKind.RestartRequired ? "restartRequired" : "pending";
		emitEvent("reload", `,"source":"build","kind":"${kind}","modules":${jsonTexts([decision.subject])},"reason":${jsonText(hcrReloadDiagnostic(decision))}`);
		if (decision.kind == HcrReloadKind.RestartRequired) hcrRestartReason = hcrReloadDiagnostic(decision);
	}
	printDiag(`${green("  Wrote")} ${bold(state.bundlePath)}`);
}

// ===== C Build =====
// Loads module graph, two-pass separate compilation:
//   Pass 1: Collect exported prototypes from all modules
//   Pass 2: Full pipeline + codegen + per-module compile to .o
//   Link all .o files into final binary

export function cmdBuildC(entryPath: string, opts: CliOptions, resolveSection: ResolveSection = defaultResolveSection()): void {
	const session = createBuildSession(false);
	let status = BuildStatus.Built;
	try {
		status = buildC(entryPath, opts, resolveSection, session);
	} catch (e) {
		if (e.message != BUILD_STOPPED) printError(`internal: the build threw '${e.message}'`);
		exit(1);
	}
	if (status == BuildStatus.Stale) {
		printError(`internal: a fresh build session reported stale state (${session.staleReason})`);
		exit(1);
	}
}

function emitDirOf(opts: CliOptions): string {
	const base = outDirForMode(opts.mode);
	return opts.emitSubdir != "" ? `${base}/${opts.emitSubdir}` : base;
}

interface WatchFeed {
	watchers: FsWatch[];
	armed: boolean[];
	batches: FsChanges[];
	batchRoots: string[];
	changed: string[];
}

function pumpFeed(feed: WatchFeed, timeoutMs: int32): void {
	for (let i = 0; i < feed.watchers.length; i += 1) {
		if (feed.armed[i]) continue;
		feed.armed[i] = true;
		const target = feed;
		const slot = i;
		nextChanges(target.watchers[slot]).then((changes: FsChanges): void => {
			target.batches.push(changes);
			target.batchRoots.push(target.watchers[slot].root);
			target.armed[slot] = false;
		});
	}
	msIoRunOnce(timeoutMs);
}

function isWatchedSource(path: string): boolean {
	const p = path.replaceAll("\\", "/");
	if (p.startsWith("out/") || p.indexOf("/out/", 0) >= 0 || p.startsWith(".hcr/") || p.indexOf("/.hcr/", 0) >= 0) return false;
	return p.endsWith(".ms") || p.endsWith(".cms") || p.endsWith(".h");
}

interface PendingWrites {
	shown: string[];
	open: string[];
	rescan: boolean;
	ended: boolean;
}

function absorbBatches(feed: WatchFeed, pending: PendingWrites): void {
	const queued = feed.batches;
	const roots = feed.batchRoots;
	feed.batches = [];
	feed.batchRoots = [];
	for (let i = 0; i < queued.length; i += 1) {
		const changes = queued[i];
		if (changes.ended) pending.ended = true;
		if (changes.rescan) pending.rescan = true;
		for (const path of changes.paths) {
			if (!isWatchedSource(path)) continue;
			if (!pending.shown.includes(path)) pending.shown.push(path);
			const full = join(roots[i], path);
			const at = pending.open.indexOf(full);
			if (changes.closed.includes(path)) {
				if (at >= 0) pending.open.splice(at, 1);
			} else if (at < 0) {
				pending.open.push(full);
			}
		}
	}
}

function writesSettled(pending: PendingWrites): boolean {
	const stillOpen: string[] = [];
	for (const path of pending.open) {
		if (!writeSettled(path)) stillOpen.push(path);
	}
	pending.open = stillOpen;
	return stillOpen.length == 0;
}

const RESCAN_SETTLE_MS = 60;
const WRITES_QUIET_MS = 20;
const WRITER_WAIT_LIMIT_MS = 500;

function waitForSourceChange(feed: WatchFeed, stopped: () => boolean): boolean {
	while (true) {
		while (feed.batches.length == 0) {
			if (stopped()) return false;
			pumpFeed(feed, 50);
		}
		const pending: PendingWrites = { shown: [], open: [], rescan: false, ended: false };
		absorbBatches(feed, pending);
		if (pending.ended) return false;
		if (!pending.rescan && pending.shown.length == 0) continue;
		console.log(pending.rescan ? "watch: changed (rescan)" : `watch: changed ${pending.shown.join(" ")}`);
		const start = performance.now();
		let lastBatch = start;
		while (true) {
			const now = performance.now();
			const waited = now - start;
			const quiet = !writerCloseObservable && now - lastBatch >= WRITES_QUIET_MS;
			const settled = pending.rescan ? waited >= RESCAN_SETTLE_MS : quiet || writesSettled(pending);
			if (settled) {
				pumpFeed(feed, 0);
				if (feed.batches.length == 0) break;
			} else if (waited >= WRITER_WAIT_LIMIT_MS) {
				console.log(`watch: ${pending.open.join(" ")} still open for writing after ${WRITER_WAIT_LIMIT_MS} ms, building anyway`);
				break;
			} else {
				pumpFeed(feed, pending.rescan ? 20 : 2);
			}
			if (feed.batches.length > 0) lastBatch = performance.now();
			absorbBatches(feed, pending);
			if (pending.ended) return false;
		}
		feed.changed = pending.shown;
		return true;
	}
}

function readReplay(path: string): string[][] {
	const text = readFile(path);
	if (!text.ok) {
		printError(`cannot read --watch-replay file '${path}'`);
		exit(1);
	}
	const steps: string[][] = [];
	for (const raw of text.value.split("\n")) {
		const line = raw.trim();
		if (line == "") continue;
		const parts = line.split(" ");
		if (parts.length != 2) {
			printError(`--watch-replay line '${line}' must be '<source> <target>'`);
			exit(1);
		}
		steps.push(parts);
	}
	return steps;
}

function copyForReplay(from: string, to: string): void {
	const text = readFile(from);
	if (!text.ok || !writeFile(to, text.value).ok) {
		printError(`--watch-replay cannot copy '${from}' to '${to}'`);
		exit(1);
	}
}

interface WatchRun {
	entryPath: string;
	opts: CliOptions;
	resolveSection: ResolveSection;
	session: BuildSession;
	feed: WatchFeed | null;
	replay: string[][];
	step: int32;
	changed: string[];
}

function openWatch(entryPath: string, opts: CliOptions, resolveSection: ResolveSection): WatchRun {
	if (!opts.isHcr) {
		printError(`--watch needs --hcr: warm rebuilds are verified against cold builds only for HCR module images`);
		exit(1);
	}
	const replay: string[][] = opts.watchReplay != "" ? readReplay(opts.watchReplay) : [];
	let feed: WatchFeed | null = null;
	if (opts.watchReplay == "") {
		const root = opts.projectRoot != "" ? opts.projectRoot : dirname(canonicalModulePath(entryPath));
		const roots: string[] = [root];
		for (const depRoot of fileDepRoots(root).values) {
			if (!isUnder(depRoot, root)) roots.push(depRoot);
		}
		const opened: WatchFeed = { watchers: [], armed: [], batches: [], batchRoots: [], changed: [] };
		for (const dir of roots) {
			const watcher = watch(dir, true);
			if (!watcher.ok) {
				printError(`--watch cannot watch ${dir}: ${watcher.error.message}`);
				exit(1);
			}
			opened.watchers.push(watcher.value);
			opened.armed.push(false);
			console.log(`watch: watching ${dir}`);
		}
		feed = opened;
	}
	setRecoverableBuild(true);
	return { entryPath, opts, resolveSection, session: createBuildSession(true), feed, replay, step: 0, changed: [] };
}

function watchBuild(run: WatchRun): boolean {
	const opts = run.opts;
	if (opts.emitC) opts.emitSubdir = `watch${run.step}`;
	const t0 = performance.now();
	eventDiagnostics = [];
	emitEvent("build.start", `,"build":${run.step},"changed":${jsonTexts(run.changed)}`);
	let status = BuildStatus.Built;
	let stopped = false;
	let internal = "";
	try {
		status = buildC(run.entryPath, opts, run.resolveSection, run.session);
	} catch (e) {
		if (e.message == BUILD_STOPPED) stopped = true;
		else internal = e.message;
	}
	let label = status == BuildStatus.UpToDate ? "up-to-date" : "built";
	if (!stopped && internal == "" && status == BuildStatus.Stale) {
		console.log(`watch: rebuilding from scratch: ${run.session.staleReason}`);
		run.session = createBuildSession(true);
		try {
			status = buildC(run.entryPath, opts, run.resolveSection, run.session);
		} catch (e) {
			if (e.message == BUILD_STOPPED) stopped = true;
			else internal = e.message;
		}
		label = "rebuilt";
	}
	if (stopped) label = "failed";
	if (internal != "") {
		printError(`internal: the build threw '${internal}'`);
		run.session = createBuildSession(true);
		label = "failed";
	}
	const session = run.session;
	const elapsed = Math.round(performance.now() - t0);
	console.log(`watch: build ${run.step} ${label} in ${elapsed} ms (checked ${session.check.rechecked.size}/${session.moduleCount}, lowered ${session.loweredCount})`);
	if (label == "failed") emitEvent("build.failed", `,"build":${run.step},"ms":${elapsed},"diagnostics":[${eventDiagnostics.join(",")}]`);
	else emitEvent("build.done", `,"build":${run.step},"ms":${elapsed},"checked":${session.check.rechecked.size},"lowered":${session.loweredCount}`);
	run.step = run.step + 1;
	return label != "failed";
}

function watchNext(run: WatchRun, stopped: () => boolean): boolean {
	if (run.feed == null) {
		if (run.step > run.replay.length) return false;
		copyForReplay(run.replay[run.step - 1][0], run.replay[run.step - 1][1]);
		run.changed = [run.replay[run.step - 1][1]];
		return true;
	}
	const changed = waitForSourceChange(run.feed!, stopped);
	if (changed) run.changed = run.feed!.changed;
	return changed;
}

export function cmdWatchC(entryPath: string, opts: CliOptions, resolveSection: ResolveSection = defaultResolveSection()): void {
	const run = openWatch(entryPath, opts, resolveSection);
	while (true) {
		watchBuild(run);
		if (run.step == 1) warmHcrSession(opts);
		if (!watchNext(run, (): boolean => false)) return;
	}
}

struct HostCtl {
	stop: boolean;
	done: boolean;
	code: int32;
}

function sayFlushed(line: string): void {
	writeStdout(`${line}\n`);
}

const HOST_DRAIN_MS = 50;

function hostStatusCode(status: ExitStatus): int32 {
	return status.signal != 0 ? 128 + status.signal : status.code;
}

function finishHost(ctl: Locked<HostCtl>, code: int32): int32 {
	lockedUpdate(ctl, (v: HostCtl): HostCtl => { return { stop: v.stop, done: true, code: code }; });
	return code;
}

// 0 data relayed, 1 stream ended, 2 nothing within the deadline.
function relayHostStream(child: ChildProcess, stream: ChildStream, timeoutMs: int32): int32 {
	const got = child.read(stream, timeoutMs);
	if (!got.ok) {
		if (got.error.kind == ProcessErrorKind.Timeout) return 2;
		sayFlushed(`watch: cannot read the program's output: ${got.error.message}`);
		return 1;
	}
	if (got.value.ended) return 1;
	if (stream == ChildStream.Stdout) writeStdout(got.value.data);
	else writeStderr(got.value.data);
	return 0;
}

interface VerdictTail {
	path: string;
	offset: int32;
	line: int32;
}

function relayVerdict(tail: VerdictTail, text: string, events: string, errorLabel: string): boolean {
	tail.line = tail.line + 1;
	const parsed = parseJson(text);
	if (!parsed.ok) {
		printDiag(`${errorLabel}: internal: ${tail.path} line ${tail.line} is not JSON: ${parsed.error}`);
		return false;
	}
	const kind = asString(getDynamicField(parsed.value, "kind"));
	const reason = asString(getDynamicField(parsed.value, "reason"));
	if (kind == "") {
		printDiag(`${errorLabel}: internal: ${tail.path} line ${tail.line} has no reload kind`);
		return false;
	}
	const modules = jsonToStringArray(getDynamicField(parsed.value, "modules"));
	if (!appendEvent(events, "reload", `,"source":"runtime","kind":${jsonText(kind)},"modules":${jsonTexts(modules)},"reason":${jsonText(reason)}`)) {
		printDiag(`${errorLabel}: cannot write the event to '${events}'`);
		return false;
	}
	if (kind == "restartRequired") sayFlushed(`watch: ${reason}; press R to restart`);
	return true;
}

function tailVerdicts(tail: VerdictTail, events: string, errorLabel: string): boolean {
	const read = readFile(tail.path);
	if (!read.ok) return true;
	const all = read.value;
	let start = tail.offset;
	for (let i = start; i < all.byteLength; i += 1) {
		if (all.byteAt(i) != 10) continue;
		if (!relayVerdict(tail, all.byteSlice(start, i), events, errorLabel)) return false;
		start = i + 1;
	}
	tail.offset = start;
	return true;
}

function runHost(host: string, dir: string, stem: string, ctl: Locked<HostCtl>, errorLabel: string, events: string): int32 {
	const tail: VerdictTail = { path: `${dir}/${stem}.reload.jsonl`, offset: 0, line: 0 };
	remove(tail.path);
	const started = spawnChild(host, [dir, stem]);
	if (!started.ok) {
		printDiag(`${errorLabel}: cannot start the HCR host ${host}: ${started.error.message}`);
		return finishHost(ctl, 1);
	}
	const child = started.value;
	let code: int32 = 1;
	while (true) {
		if (lockedRead(ctl, (v: HostCtl): boolean => v.stop)) {
			const killed = child.kill();
			if (killed.ok) code = hostStatusCode(killed.value);
			break;
		}
		const waited = child.wait(20);
		relayHostStream(child, ChildStream.Stdout, 0);
		relayHostStream(child, ChildStream.Stderr, 0);
		if (!tailVerdicts(tail, events, errorLabel)) {
			child.kill();
			code = 1;
			break;
		}
		if (waited.ok) {
			code = hostStatusCode(waited.value);
			while (relayHostStream(child, ChildStream.Stdout, HOST_DRAIN_MS) == 0) {}
			while (relayHostStream(child, ChildStream.Stderr, HOST_DRAIN_MS) == 0) {}
			if (!tailVerdicts(tail, events, errorLabel)) code = 1;
			break;
		}
		if (waited.error.kind != ProcessErrorKind.Timeout) {
			printDiag(`${errorLabel}: waiting for the HCR host failed: ${waited.error.message}`);
			child.kill();
			break;
		}
	}
	child.close();
	return finishHost(ctl, code);
}

function buildHcrHost(dir: string): string {
	const source = `${resolveRuntimeDir()}/std/hcr/host.cms`;
	const host = `${dir}/host${exeSuffix()}`;
	const built = execFileCapture(resolveArgv0(argv[0]), ["build", source, `--output=${host}`]);
	if (!built.ok) {
		printError(`cannot build the HCR host from ${source}`);
		printDiag(built.error.errorOutput != "" ? built.error.errorOutput : built.error.message);
		exit(1);
	}
	return host;
}

function hcrHostMissesEngine(graph: ModuleGraph, stdPath: string): boolean {
	return findModule(graph, canonicalModulePath(`${stdPath}/hcr/engine.cms`)) == null;
}

export function cmdRunHcr(entryPath: string, opts: CliOptions, resolveSection: ResolveSection = defaultResolveSection()): void {
	if (opts.watchReplay != "") {
		printError(`msc run --hcr watches the sources itself; --watch-replay belongs to msc build`);
		exit(1);
	}
	const dir = "out/hcr";
	const stem = replaceExt(basename(entryPath), "");
	ensureDir(dir);
	opts.outputPath = `${dir}/${stem}${soSuffix()}`;
	opts.hcrHost = true;
	const host = buildHcrHost(dir);
	const events = opts.eventsPath;
	eventsPath = events;
	if (events != "" && events != "-" && !writeFile(events, "").ok) {
		printError(`cannot create the events file '${events}'`);
		exit(1);
	}
	const run = openWatch(entryPath, opts, resolveSection);
	while (!watchBuild(run)) {
		if (!watchNext(run, (): boolean => false)) {
			emitEvent("exit", `,"code":1`);
			exit(1);
		}
	}
	stdinDisableBuffering();
	const ctl: Locked<HostCtl> = new Locked({ stop: false, done: false, code: 0 });
	const errorLabel = error("error");
	let running = spawn((): int32 => runHost(host, dir, stem, ctl, errorLabel, events));
	warmHcrSession(opts);
	const keys: string[] = [""];
	const idle = (): boolean => {
		if (lockedRead(ctl, (v: HostCtl): boolean => v.done)) return true;
		if (!stdinHasData()) return false;
		const key = readLine().trim();
		if (key == "R" || key == "r" || key == "q") {
			keys[0] = key;
			return true;
		}
		if (key != "") sayFlushed(`watch: unknown key '${key}': R restarts the program, r rebuilds, q quits`);
		return false;
	};
	const rebuild = (): void => {
		watchBuild(run);
		if (hcrRestartReason != "") sayFlushed(`watch: ${hcrRestartReason}; press R to restart`);
		hcrRestartReason = "";
	};
	while (true) {
		keys[0] = "";
		if (watchNext(run, idle)) {
			rebuild();
			continue;
		}
		if (lockedRead(ctl, (v: HostCtl): boolean => v.done)) break;
		if (keys[0] == "r") {
			rebuild();
			sayFlushed("watch: rebuilt on key r");
		} else if (keys[0] == "R") {
			lockedUpdate(ctl, (v: HostCtl): HostCtl => { return { stop: true, done: v.done, code: v.code }; });
			await running;
			sayFlushed("watch: restarting the program on the last build");
			lockedUpdate(ctl, (v: HostCtl): HostCtl => { return { stop: false, done: false, code: 0 }; });
			running = spawn((): int32 => runHost(host, dir, stem, ctl, errorLabel, events));
		} else {
			if (keys[0] == "q") sayFlushed("watch: quit");
			lockedUpdate(ctl, (v: HostCtl): HostCtl => { return { stop: true, done: v.done, code: v.code }; });
			break;
		}
	}
	const code = await running;
	emitEvent("exit", `,"code":${code}`);
	exit(code);
}

function frontendIdentity(entryPath: string, opts: CliOptions, config: ResolverConfig): string {
	const aliases: string[] = [];
	for (let i = 0; i < config.aliasKeys.length; i += 1) aliases.push(`${config.aliasKeys[i]}=${config.aliasValues[i]}`);
	return ` entry=${entryPath} app=${opts.appMode} strictNil=${opts.strictNullChecks} vmIterations=${opts.vmIterations}`
		+ ` std=${config.stdPath} ext=${config.extensions.join(",")} search=${config.searchPaths.join(",")} alias=${aliases.join(",")}`;
}

export function buildC(entryPath: string, opts: CliOptions, resolveSection: ResolveSection, session: BuildSession): BuildStatus {
	const fTotal = flowStart();
	const status = buildCPhases(entryPath, opts, resolveSection, session);
	flowStop("total", fTotal);
	flowsWrite();
	return status;
}

function buildCPhases(entryPath: string, opts: CliOptions, resolveSection: ResolveSection, session: BuildSession): BuildStatus {
	const fSetup = flowStart();
	startSessionBuild(session);
	_hcrWarmJobs = [];
	_hcrWarmLinks = [];
	const lastBuilt = session.lastBuilt;
	session.lastBuilt = false;
	entryPath = canonicalModulePath(entryPath);
	emitOnlyMode = opts.emitC;
	initCache(opts.mode, opts.forceRebuild);
	resetCompiledOFiles();
	registerCoreParsers();
	flowStop("phase.setup", fSetup);
	const t0 = performance.now();
	const fGraph = flowStart();
	// Before ANY phase reads it: freestanding targets imply --mm=manual, and the
	// checker needs the resolved mode (freestanding async gate) — applyGcMode
	// below runs too late for that, it only re-stamps the prelude context.
	resolveTargetGcMode(opts);
	resolveCC(opts);
	setToolchainHeaderRoot(toolchainHeaderRoot(opts.ccCompiler, opts.ccBinary));
	resolveLto(opts);
	useDriverPlans(session.keep && opts.isHcr);
	const config = buildResolverConfig(Target.C, resolveSection, opts.targetOs, opts.projectRoot);
	setGraphCheckTiming(opts.showTime);
	setGraphLoadTiming(opts.showTime);
	// Solana: resolve the SBF toolchain, force release mode. The gc force lives
	// in resolveTargetGcMode (it has to happen before the check pass).
	// Both halves come from Anza's platform-tools bundle - a stock LLVM will not
	// do, so the diagnostic points at the bundle rather than at a package manager.
	if (opts.targetOs == "solana" && opts.mode == 0) opts.mode = 1;
	if (opts.targetOs == "solana" && !opts.emitC) {
		if (opts.ccBinary == "") {
			const sbfClang = resolveBpfClang();
			if (sbfClang == "") {
				printError(`--os=solana requires a clang with the ${bold("sbf")} target registered`);
				console.log(`  System clang carries ${bold("bpf")}/${bold("bpfel")} (Linux kernel BPF) — a different ABI, not this.`);
				console.log(`  Install Anza platform-tools (${bold("cargo build-sbf")} fetches it to ~/.cache/solana),`);
				console.log(`  or point at one: ${bold("MSC_SBF_CLANG=/path/to/platform-tools/llvm/bin/clang")}`);
				throw new Error(BUILD_STOPPED);
			}
			opts.ccBinary = sbfClang;
		}
		if (resolveSbfLinker() == "") {
			printError(`--os=solana requires ${bold("ld.lld")} beside the SBF clang`);
			console.log(`  Expected it in the same platform-tools ${bold("llvm/bin")} directory.`);
			throw new Error(BUILD_STOPPED);
		}
		if (resolveSbfObjcopy() == "") {
			printError(`--os=solana requires ${bold("llvm-objcopy")} beside the SBF clang`);
			console.log(`  Expected it in the same platform-tools ${bold("llvm/bin")} directory.`);
			throw new Error(BUILD_STOPPED);
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
		if (opts.targetOs == "wasm" ||
			(opts.targetOs == "bare" && opts.cpuTarget == "wasm32" && opts.appMode != "staticlib")) {
			suffix = ".wasm";
		}
		if (opts.targetOs == "emcc") suffix = ".js";  // emcc outputs .js + .wasm pair
		outBinary = outDir + "/" + replaceExt(basename(entryPath), "") + suffix;
	}
	outBinary = normalize(outBinary);

	const allFlags0 = cliCompileFlags(opts);
	const buildIdentityFlags = cliLinkFlags(allFlags0, opts) + defineIdentity(opts.defines) + modulePassIdentity() + frontendIdentity(entryPath, opts, config);
	const recordDecides = !session.keep && !opts.emitC && !opts.isHcr && !opts.hcrHost && !opts.genDeps;
	if (recordDecides && projectRecordCurrent(outBinary, opts.ccCompiler, opts.ccBinary, opts.mode, buildIdentityFlags)) {
		printDiag(success("Up to date") + " " + bold(outBinary));
		session.lastBuilt = true;
		return BuildStatus.UpToDate;
	}

// Reference parity: global hook ownership registry shared across all modules.
// First module to need a type's DRC hooks generates them; others get extern protos.
// Before the graph check: enum toString ops register during checking, and this resets the op table.
resetLiftedOps();
	const graph = loadAndCheckGraph(entryPath, config, opts, opts.targetInfo, gcModeOf(opts.gcMode), session.check);
	applyGcMode(opts);
	session.moduleCount = graph.loadOrder.length as int32;
	if (opts.hcrHost && hcrHostMissesEngine(graph, config.stdPath)) {
		printDiag(`${error("error")}: ${basename(entryPath)} never imports std/hcr, so nothing calls reload() and an edit would never reach the running program; import { reload } from "std/hcr" and call reload() once per pass of the main loop`);
		stopBuild();
	}

	const projectDeps: string[] = [];
	for (const path of graph.loadOrder) projectDeps.push(path);
	for (const path of linkInputs(opts)) projectDeps.push(path);
	const buildFile = opts.projectRoot != "" ? join(opts.projectRoot, "build.ms") : "";
	if (buildFile != "" && exists(buildFile)) projectDeps.push(buildFile);
	let hcrBuildAbi: HcrBuildAbi = null as unknown as HcrBuildAbi;
	if (opts.isHcr && !opts.emitC) {
		const prepared = prepareHcrBuildAbi(graph, entryPath, outBinary, opts, allFlags0, config.stdPath);
		if (!prepared.ok) {
			printError(`${prepared.error}`);
			throw new Error(BUILD_STOPPED);
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
			printError(`${abi.error}`);
			throw new Error(BUILD_STOPPED);
		}
		const indirect = hcrIndirectModules(abi.value);
		if (!indirect.ok) {
			printError(`${indirect.error}`);
			throw new Error(BUILD_STOPPED);
		}
		hcrModules = indirect.value;
		for (const path of abi.value.modulePaths) hcrModulePaths.push(path);
	}
	const writeTables = createWriteSummaries(session.check.db != null ? session.check.db!.routineDecls : createRoutineDecls(), hcrModulePaths);
	const liftTables = createWriteSummaries(createRoutineDecls(), hcrModulePaths);
	const projectChanged = session.keep || projectCacheChanged(projectDeps, outBinary, opts.ccCompiler, opts.ccBinary, opts.mode, buildIdentityFlags);
	const hcrBundleCurrent = hcrBuildAbi == null
		|| (hcrBuildAbi.hadCurrent && hcrBundlesMatch(hcrBuildAbi.current, hcrBuildAbi.candidate));
	// The project cache vouches for the binary only; a request for the C asks for outputs it never recorded.
	const upToDate = !opts.emitC && (session.keep ? lastBuilt && session.check.rechecked.size == 0 && hcrBundleCurrent : !projectChanged && hcrBundleCurrent);
	if (upToDate) {
		printDiag(success("Up to date") + " " + bold(outBinary));
		if (opts.genDeps) {
			const depsDir = outDirForMode(opts.mode);
			ensureDir(depsDir);
			writeDepsFile(graph, entryPath, depsDir);
		}
		session.lastBuilt = true;
		return BuildStatus.UpToDate;
	}

	// Phase A: Parse → Check → Mono → Transform → Analyze all modules, store results
	if (opts.showTime) printTiming("graph load+check", t0);
	flowStop("phase.graph", fGraph);
	const tA = performance.now();
	const fA = flowStart();
	const processed: ProcessedModule[] = [];
	let transformedPrograms: Node[] = [];
	let transformedPaths: string[] = [];
	const bs = initCBuildState(opts);
	let allFlags = bs.allFlags;
	const includePaths = bs.includePaths;
	let oFiles: string[] = [];
	let totalCheckerErrors = 0;
	// FREESTANDING E01 sites, collected pre-transform in A2, reported post-DCE.
	const fsAsyncHits: FsAsyncHit[] = [];
	const fsWritableHits: { modPath: string, source: string, name: string, sym: Symbol | null, line: int32, column: int32, message: string }[] = [];


	// PROFILE: sub-phase timings summed across all modules.
	const a2t: A2Timers = { mono: 0, macro: 0, xform: 0, native: 0, analyze: 0, lower: 0 };

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
			printError(`internal: module '${modPath}' is in loadOrder but missing from the graph — its code will be skipped`);
			continue;
		}
		// The graph-checker phase (loadAndCheckGraph → checkModuleGraph) already
		// ran the full 3 passes on every module and registered program+ctx
		// (registerModuleProgram/registerModuleCtx). Re-parsing + re-checking here
		// duplicated ~half the build time and re-populated the exact same
		// diagnostics. Reuse the checked pair — reference parity: Nim checks each
		// module exactly once (sem results cached on the module). LSP-only
		// finalization (sgSortRecords, stampJsModulePaths) is skipped on this path.
		const checked = graphCheckedModule(graph, modPath, mod, opts);
		if (hasErrors(checked.ctx)) {
			totalCheckerErrors = totalCheckerErrors + errorCount(checked.ctx);
		}
		checkedMods.push({ program: checked.program, ctx: checked.ctx, modPath, source: mod.rawSource });
		programByPath.set(modPath, checked.program);
	}

	const reloadable: string[] = opts.isHcr ? hcrModulePaths : [];
	const routeOrder: Node[] = [];
	const homes = new HashMap<Node, string>();
	for (const modPath of graph.loadOrder) {
		const created = session.check.instances.get(modPath);
		if (created == null) continue;
		const keeps = reloadable.includes(modPath);
		for (const instNode of created) {
			routeOrder.push(instNode);
			if (keeps) homes.set(instNode, modPath);
		}
	}
	retainCheckedInstances(checkedModCtxs(checkedMods));
	const instancesByOwner = routeInstances(routeOrder, (path: string): Node | null => programByPath.has(path) ? programByPath.get(path) : null, !session.keep, homes);

	// Phase A2 — mono → transform → analyze → lower, per module (instances now placed).
	for (let i = 0; i < hcrModulePaths.length; i += 1) {
		const path = hcrModulePaths[i];
		const checkedProgram = programByPath.has(path) ? programByPath.get(path) : null;
		const program = session.keep && checkedProgram != null ? programWithInstances(checkedProgram, instancesByOwner.get(path)) : checkedProgram;
		hcrModules[i].typeLayouts = hcrTypeLayouts(program);
		hcrModules[i].typeKeys = hcrTypeLayoutKeys(hcrModules[i].typeLayouts);
		hcrModules[i].beforeReload = hcrReloadHandlers(program, SymbolFlag.BeforeReload);
		hcrModules[i].afterReload = hcrReloadHandlers(program, SymbolFlag.AfterReload);
	}
	const checkedPaths: string[] = [];
	for (const cm of checkedMods) checkedPaths.push(cm.modPath);
	const lowerOrder = coreBeforeImages(checkedPaths, reloadable);
	const lazyPlan = planDynamicModules(graph, entryPath, checkedPaths, config.stdPath);
	const asyncBodies = new HashSet<string>();
	for (const cm of checkedMods) if (lazyPlan.lazy.has(cm.modPath) && hasTopLevelAwait(cm.program)) asyncBodies.add(cm.modPath);
	const ownerFingerprints: HashMap<string, string> = new HashMap<string, string>();
	if (session.keep) {
		if (opts.isHcr) {
			const typesNow = hcrTypeRegistryFingerprint(hcrModules) + projectTypesFingerprint(session, hcrModulePaths);
			let greenHcrModule = false;
			for (const path of hcrModulePaths) {
				if (!session.check.rechecked.has(path)) greenHcrModule = true;
			}
			if (session.hcrTypeRegistryFingerprint != "" && session.hcrTypeRegistryFingerprint != typesNow && greenHcrModule) {
				session.staleReason = "the project type layouts changed";
				return BuildStatus.Stale;
			}
			session.hcrTypeRegistryFingerprint = typesNow;
		}
		for (const cm of checkedMods) {
			let fingerprint = instancesFingerprint(session, instancesByOwner.get(cm.modPath));
			if (asyncBodies.has(cm.modPath)) fingerprint = fingerprint + "#asyncBody";
			ownerFingerprints.set(cm.modPath, fingerprint);
			if (session.check.rechecked.has(cm.modPath) || !session.lowerFingerprints.has(cm.modPath)) continue;
			if (session.lowerFingerprints.get(cm.modPath) != fingerprint) {
				session.staleReason = `the generic instances emitted in ${cm.modPath} changed`;
				return BuildStatus.Stale;
			}
		}
	}
	const loweredByPath = new HashMap<string, Node>();
	for (const at of lowerOrder) {
		const cm = checkedMods[at];
		const program = cm.program;
		const ctx = cm.ctx;
		const modPath = cm.modPath;
		const modT0 = performance.now();
		const routed = instancesByOwner.get(modPath);
		const job: A2Job = {
			modPath,
			source: cm.source,
			opts,
			stdPath: config.stdPath,
			hcrSlot: hcrModulePaths.indexOf(modPath) as int32,
			hcrModules,
			fsAsyncHits,
			timers: a2t,
			diagnostics: [],
			instances: routed != null ? routed : [],

			cloneInput: session.keep,
			ran: false,
			claims: { ops: [], contracts: [] },
			asyncModuleBody: asyncBodies.has(modPath),
			writeTables,
			liftTables,
		};
		let nativeLowered: Node;
		if (session.keep) {
			const earlier = session.lowerClaims.get(modPath);
			if (earlier != null) reuseClones(writeTables, earlier.contracts);
			nativeLowered = dbLower(session.check.db!, modPath, lowerModuleA2, job);
			if (job.ran) {
				session.loweredCount = session.loweredCount + 1;
				const previous = session.lowerClaims.get(modPath);
				if (previous != null && !sameClaims(previous, job.claims)) {
					session.staleReason = `the operations lifted by ${modPath} changed`;
					return BuildStatus.Stale;
				}
				session.lowerClaims.set(modPath, job.claims);
				session.lowerDiagnostics.set(modPath, job.diagnostics);
				session.lowerFingerprints.set(modPath, ownerFingerprints.get(modPath) ?? "");
			} else {
				const claims = session.lowerClaims.get(modPath);
				if (claims != null) {
					replayOps(claims.ops);
					restoreContracts(writeTables, claims.contracts);
				}
				const replay = session.lowerDiagnostics.get(modPath);
				if (replay != null) for (const shown of replay) renderModuleError(modPath, cm.source, shown);
			}
		} else {
			nativeLowered = lowerModuleA2(program, ctx, job);
		}
		const modT1 = performance.now();
		if (opts.showTime && (modT1 - modT0) > 50) {
			printTiming(modPath, modT0);
		}
		loweredByPath.set(modPath, nativeLowered);
	}
	for (const cm of checkedMods) {
		const ctx = cm.ctx;
		const modPath = cm.modPath;
		const nativeLowered = loweredByPath.get(modPath)!;
		if (opts.targetOs == "solana") {
			for (const hitNode of collectWritableModuleBindings(nativeLowered)) {
				const d = hitNode.data as VariableDeclData;
				fsWritableHits.push({
					modPath,
					source: cm.source,
					name: d.declName,
					sym: hitNode.resolvedSym,
					line: d.nameLocation.line,
					column: d.nameLocation.column,
					message: writableModuleBindingMessage(hitNode),
				});
			}
		}
		processed.push({ program: nativeLowered, ctx, modPath });
		transformedPrograms.push(nativeLowered);
		transformedPaths.push(modPath);

		// Accumulate compiler flags (@passC). Relative -I paths resolved using same
		// rule as @compile.
		const resolved = resolveIncludeFlags(ctx.compilerFlags, includePaths, dirname(modPath), resolveRuntimeDir());
		allFlags = mergeFlagsDeduped(allFlags, resolved);
		// @passL/@link go directly to global linkState — no per-module merge
		registerIncludePaths(resolved, includePaths);

	}

	if (opts.showTime) printTiming("phase A (parse+check+transform)", tA);
	flowStop("phase.A", fA);
	if (opts.showTime) {
		console.log(`    mono=${a2t.mono}ms macro=${a2t.macro}ms xform=${a2t.xform}ms native=${a2t.native}ms analyze=${a2t.analyze}ms lower=${a2t.lower}ms`);
	}

	// Gate: stop before codegen if any type errors (standard compiler parity).
	// All three reference compilers NEVER proceed to codegen with type errors.
	if (totalCheckerErrors > 0) {
		printError(`${totalCheckerErrors} type error(s) found, stopping before codegen`);
		throw new Error(BUILD_STOPPED);
	}
	if (opts.targetOs == "solana" && !isDefined(opts.defines, "testBuild")) {
		for (const m of checkedMods) {
			if (m.modPath != entryPath || topLevelCallsAnything(m.program)) continue;
			renderModuleError(m.modPath, m.source, { message: emptyTopLevelMessage(basename(m.modPath)), line: 1, column: 1, severity: ErrorSeverity.Error });
			throw new Error(BUILD_STOPPED);
		}
	}


	const tB = performance.now();
	const fB = flowStart();

	// Phase B: Compute DCE alive set on post-transform ASTs (reference-aligned)
	if (opts.verbose) verboseLog("computing alive set (post-transform DCE)");
	const fRaises = flowStart();
	if (opts.isHcr) markEveryBodyMayRaise(transformedPrograms);
	else inferRaises(transformedPrograms);
	flowStop("b.raises", fRaises);
	const fAlive = flowStart();
	const aliveSet = computeAliveSet(transformedPrograms, transformedPaths, entryPath, false, graph, hcrModulePaths, hcrRootFunctions(hcrModulePaths), hcrModulePaths);
	flowStop("b.alive", fAlive);
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
		if (fsReported > 0) throw new Error(BUILD_STOPPED);
	}
	if (fsWritableHits.length > 0) {
		let fsReported = 0;
		for (const h of fsWritableHits) {
			if (!aliveSetHasDecl(aliveSet, h.sym, h.name)) continue;
			renderModuleError(h.modPath, h.source, {
				message: h.message,
				line: h.line,
				column: h.column,
				severity: ErrorSeverity.Error,
			});
			fsReported = fsReported + 1;
		}
		if (fsReported > 0) throw new Error(BUILD_STOPPED);
	}


	if (opts.showTime) printTiming("phase B (DCE)", tB);
	flowStop("phase.B", fB);
	const tC = performance.now();
	const fC = flowStart();

	// Compile prelude @compile directives — unconditional.
	// These are C runtime files, not application code. The linker strips unused sections.
	const hcrImages = opts.isHcr && !opts.emitC;
	const coreFlags = hcrImages ? appendFlag(allFlags, "-DMS_HCR_CORE") : allFlags;
	const imageFlags = hcrImages ? appendFlag(allFlags, "-DMS_HCR_MODULE") : allFlags;
	if (graphPreludeCtx != null && graphPreludeCtx.compileDirectives != "") {
		const preludeObjs = processCompileDirectives(graphPreludeCtx.compileDirectives, resolveRuntimeDir(), includePaths, coreFlags, opts.mode, opts.ccCompiler, opts.ccBinary, opts.verbose, opts.targetOs, opts.projectRoot, resolveRuntimeDir());
		for (const oFile of preludeObjs) oFiles.push(oFile);
	}

	const rtObjs = compilePlatformRuntime(includePaths, coreFlags, opts);
	for (const oFile of rtObjs) oFiles.push(oFile);

	// Phase C: Codegen + compile each module
	const emissionFacts = new CEmissionFacts();
	const aliveKey = session.keep ? aliveSetFingerprint(aliveSet) : "";
	const hcrStorage = createHcrStorageTable();
	if (opts.isHcr) {
		for (const module of hcrModules) {
			for (const p of processed) {
				if (p.modPath == module.modulePath) buildHcrStorage(hcrStorage, p.program, module, hcrModules);
			}
		}
	}
	for (const p of processed) factInlineDecls(emissionFacts, p.program);
	setConcurrentTypeQueries(true);
	try {
		for (const p of processed) {
			if (!aliveSetHasModule(aliveSet, p.modPath)) continue;
			const prepared = session.keep ? session.prepareMemos.get(p.modPath) : null;
			if (prepared != null && prepared.program == p.program && prepared.alive == aliveKey && prepared.before == emissionFacts.trace) {
				replayCModuleEmission(aliveSet, emissionFacts, prepared.writes);
			} else {
				const before = emissionFacts.trace;
				emissionFacts.writes = [];
				prepareCModuleEmission(p.program, p.ctx, p.modPath, aliveSet, emissionFacts);
				const recorded = emissionFacts.writes;
				const writes: string[] = recorded != null ? recorded : [];
				emissionFacts.writes = null;
				if (session.keep) session.prepareMemos.set(p.modPath, { program: p.program, alive: aliveKey, before, writes });
			}
			if (opts.isHcr && !hcrModulePaths.includes(p.modPath)) factCoreUnit(emissionFacts, p.modPath);
		}
		if (opts.isHcr) bindHcrUnits(hcrModules, processed, aliveSet, emissionFacts, gcModeOf(opts.gcMode) == GcMode.Drc, hcrStorage);
	} catch (e) {
		setConcurrentTypeQueries(false);
		throw e;
	}
	const emissionJobs: ModuleEmissionJob[] = [];
	for (const p of processed) {
		if (!aliveSetHasModule(aliveSet, p.modPath)) continue;
		emissionJobs.push({ slot: emissionJobs.length, program: p.program, ctx: p.ctx, modPath: p.modPath, weight: p.program.location.endLine });
	}
	const emitStart = performance.now();
	const emitWidth: int32 = opts.emitJobs < 1 ? emissionJobs.length : opts.emitJobs;
	const imagePaths: string[] = [];
	for (const module of hcrModules) imagePaths.push(module.modulePath);
	imagePaths.sort();
	const emitKey = `${aliveKey}|${emissionFacts.trace}|${imagePaths.join(",")}`;
	const freshJobs: ModuleEmissionJob[] = [];
	const freshSlots: int32[] = [];
	const reusedEmits = new HashSet<string>();
	for (const job of emissionJobs) {
		const memo = session.keep && emissionFacts.hcrCoreUnits.has(job.modPath) ? session.emitMemos.get(job.modPath) : null;
		if (memo != null && memo.program == job.program && memo.key == emitKey) {
			freshSlots.push(-1);
			continue;
		}
		freshSlots.push(freshJobs.length as int32);
		freshJobs.push({ slot: freshJobs.length as int32, program: job.program, ctx: job.ctx, modPath: job.modPath, weight: job.weight });
	}
	let freshResults: ModuleEmissionResult[] = [];
	try {
		freshResults = emitModulesBounded(freshJobs, aliveSet, emissionFacts, emitWidth, false, opts.isHcr ? entryPath : "");
	} finally {
		setConcurrentTypeQueries(false);
	}
	const emissionResults: ModuleEmissionResult[] = [];
	for (let ei = 0; ei < emissionJobs.length; ei += 1) {
		const job = emissionJobs[ei];
		if (freshSlots[ei] >= 0) {
			const fresh = freshResults[freshSlots[ei]];
			fresh.slot = ei as int32;
			emissionResults.push(fresh);
			if (session.keep && emissionFacts.hcrCoreUnits.has(job.modPath) && fresh.completed && fresh.failure == "" && fresh.output.errors.length == 0) {
				session.emitMemos.set(job.modPath, { program: job.program, key: emitKey, output: copyModuleOutput(fresh.output), compileCmd: "", baseFp: "" });
			}
			continue;
		}
		const reused = new ModuleEmissionResult();
		reused.slot = ei as int32;
		reused.output = copyModuleOutput(session.emitMemos.get(job.modPath)!.output);
		reused.completed = true;
		emissionResults.push(reused);
		reusedEmits.add(job.modPath);
	}
	let codegenTime: float64 = performance.now() - emitStart;
	if (flowsEnabled()) {
		let emitWorkMs: float64 = 0;
		for (const emitted of emissionResults) emitWorkMs = emitWorkMs + (emitted.finished - emitted.started);
		flowAddMs("emit.module", emitWorkMs);
	}
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
			printError(`${modPath}: ${result.failure}`);
			emissionFailed = true;
		}
		for (const diagnostic of result.output.errors) {
			printError(`${modPath}: ${diagnostic.message}`);
			emissionFailed = true;
		}
	}
	if (emissionFailed) throw new Error(BUILD_STOPPED);
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
			const emitDir = emitDirOf(opts);
			ensureDir(emitDir);
			const emitPath = `${emitDir}/${mangleModuleName(buildModuleNameRoots(), p.modPath)}.c`;
			writeOutput(emitPath, cCode);
			printDiag(`${green("  Wrote")} ${bold(emitPath)}`);
		} else {
			let modFlags = appendFlag(sideFlags, quoteCcArg(`-iquote${dirname(p.modPath)}`));
			modFlags = appendFlag(modFlags, quoteCcArg(`-iquote${cd}`));
			// Per-module MS→.c: add -I<projectRoot> only for user modules (paths
			// under projectRoot, not under compilerRoot). Stdlib modules get
			// stable command text so ccache can dedupe across projects.
			const upFlag = userProjectFlag(p.modPath, opts.projectRoot, resolveRuntimeDir());
			if (upFlag != "") modFlags = appendFlag(modFlags, upFlag);
			const compileCmd = fullCompileCmd(opts.ccCompiler, opts.mode, modFlags, opts.ccBinary);
			const emitMemo = session.keep ? session.emitMemos.get(p.modPath) : null;
			const reuseFp = emitMemo != null && reusedEmits.has(p.modPath) && emitMemo.compileCmd == compileCmd;
			const baseFp = reuseFp ? emitMemo!.baseFp : moduleCompileFp(cCode, compileCmd);
			if (emitMemo != null && !reuseFp && emitMemo.program == p.program) {
				emitMemo.compileCmd = compileCmd;
				emitMemo.baseFp = baseFp;
			}
			const modFp = moduleObjectFp(p.modPath, baseFp);
			const oFile = stableOFileFp(p.modPath, modFp);
			if (session.keep && opts.isHcr && hcrModulePaths.includes(p.modPath)) {
				_hcrWarmJobs.push({ cFile: stableCFileFp(p.modPath, baseFp), oFile, modPath: p.modPath, flags: modFlags, fp: modFp, baseFp, depFile: moduleDepFile(p.modPath, baseFp), cacheKey: "", slot: -1 });
			}

			const cached = isCCodeCached(p.modPath, modFp);
			const storeKey = cached ? "" : objectStoreKey(moduleStoreSource(cCode), opts.ccCompiler, opts.ccBinary, false, opts.mode, modFlags);
			const stored = storeKey == "" ? "" : restoreModuleObject(p.modPath, baseFp, storeKey, objectSearchDirs(opts.ccCompiler, opts.ccBinary, false, opts.mode, modFlags));
			if (cached) {
				oSlots.push([oFile]);
				if (opts.verbose) verboseLog(`  cached ${p.modPath}`);
			} else if (stored != "") {
				oSlots.push([stored]);
				if (opts.verbose) verboseLog(`  stored ${p.modPath}`);
			} else {
				// Write only .c source BEFORE compile (always — debuggable).
				// Defer fingerprint (.cfp) until after successful compile so a
				// failed zig cc doesn't leave a false cache hit for the next run.
				writeCSource(p.modPath, baseFp, cCode);
				const cFile = stableCFileFp(p.modPath, baseFp);
				if (opts.verbose) verboseLog(`  cc ${cFile} → ${oFile}`);
				oSlots.push([]);
				cJobs.push({ cFile, oFile, modPath: p.modPath, flags: modFlags, fp: modFp, baseFp, depFile: moduleDepFile(p.modPath, baseFp), cacheKey: "", slot: oSlots.length - 1, storeKey });
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
	const dynamicPlan = planDynamicModules(graph, entryPath, aliveModules, config.stdPath);
	for (const mp of asyncBodies) dynamicPlan.topLevelAwait.add(mp);

	// Skip link step if --emit=c (only writing C source files)
	if (opts.emitC) flowStop("phase.C", fC);
	if (opts.emitC && opts.isHcr) {
		const emitDir = emitDirOf(opts);
		const coreModules: string[] = [];
		for (const mp of aliveModules) {
			if (!hcrModulePaths.includes(mp)) coreModules.push(mp);
		}
		writeOutput(`${emitDir}/_hcrcore.c`, genHcrCoreDispatcher(coreModules, moduleOutputs, dynamicPlan));
		printDiag(`${green("  Wrote")} ${bold(`${emitDir}/_hcrcore.c`)}`);
		for (const mp of hcrModulePaths) {
			const output = moduleOutputFor(moduleOutputs, mp);
			if (output == null) continue;
			const imagePath = `${emitDir}/_hcrimage_${mangleModuleName(buildModuleNameRoots(), mp)}.c`;
			writeOutput(imagePath, genHcrImageDispatcher(output, mp == entryPath, dynamicPlan.lazy.has(mp)));
			printDiag(`${green("  Wrote")} ${bold(imagePath)}`);
		}
		printDiag(success(`Emitted ${compiled + 1 + hcrModulePaths.length} C module(s)`));
		if (opts.showTime) printTiming("emitted", t0);
		session.lastBuilt = true;
		return BuildStatus.Built;
	}
	if (opts.emitC) {
		// Also emit dispatcher (MsMain + entry point)
		const dispatcher = genProjectDispatcher(
			aliveModules,
			entryPath,
			opts.targetOs,
			opts.appMode == "lib" || opts.appMode == "staticlib",
			moduleOutputs,
			dynamicPlan,
		);
		const emitDir = emitDirOf(opts);
		const dispPath = `${emitDir}/_dispatch.c`;
		writeOutput(dispPath, dispatcher);
		printDiag(`${green("  Wrote")} ${bold(dispPath)}`);
		printDiag(success(`Emitted ${compiled + 1} C module(s)`));
		if (opts.genDeps) {
			const depsDir = outDirForMode(opts.mode);
			writeDepsFile(graph, entryPath, depsDir);
		}
		if (opts.showTime) printTiming("emitted", t0);
		session.lastBuilt = true;
		return BuildStatus.Built;
	}

	// Its .o IS content-keyed though: two concurrent builds of different
	// configs (drc vs orc emit different teardown in the dispatcher TU) must
	// not rename over each other's object right before the other's link —
	// that linked an orc dispatcher into a drc build (undefined msOrcCollect).
	const hcrImageSlots: int32[] = [];
	let hcrCoreSlot: int32 = -1;
	let dispatcherSource = "";
	let dispatcherSlot: int32 = -1;
	if (hcrImages) {
		const coreModules: string[] = [];
		for (const mp of aliveModules) {
			if (!hcrModulePaths.includes(mp)) coreModules.push(mp);
		}
		pushDispatcherJob(cJobs, oSlots, "_hcrcore", genHcrCoreDispatcher(coreModules, moduleOutputs, dynamicPlan), coreFlags, opts);
		hcrCoreSlot = oSlots.length - 1;
		for (const mp of hcrModulePaths) {
			const output = moduleOutputFor(moduleOutputs, mp);
			if (output == null) {
				printErrorOut(`internal: HCR module '${mp}' produced no C output`);
				throw new Error(BUILD_STOPPED);
			}
			pushDispatcherJob(cJobs, oSlots, `_hcrimage_${mangleModuleName(buildModuleNameRoots(), mp)}`, genHcrImageDispatcher(output, mp == entryPath, dynamicPlan.lazy.has(mp)), imageFlags, opts);
			hcrImageSlots.push(oSlots.length - 1);
		}
	} else {
		if (opts.verbose) verboseLog("generating dispatcher");
		dispatcherSource = genProjectDispatcher(
			aliveModules,
			entryPath,
			opts.targetOs,
			opts.appMode == "lib" || opts.appMode == "staticlib",
			moduleOutputs,
			dynamicPlan,
		);
		dispatcherSlot = oSlots.length;
		pushDispatcherJob(cJobs, oSlots, "_dispatch", dispatcherSource, allFlags, opts);
	}

	// DISPATCH + COLLECT — parallel cc over the runtime thread pool, publish
	// results in input order from the main thread. Dispatcher failure is fatal
	// (as before); module failures print and fall through to the linker so the
	// serial path's behavior is preserved.
	const tCl = performance.now();
	const cCodes = dispatchCompileJobs(cJobs, opts.mode, opts.ccCompiler, opts.ccBinary, cJobs.length <= PLANNED_COMPILE_JOBS);
	clangTime = performance.now() - tCl;
	flowAddMs("cc", clangTime);
	let moduleCompileFailed = false;
	let cji = 0;
	while (cji < cJobs.length) {
		const cj = cJobs[cji];
		const code = cCodes[cji];
		if (code == 0) {
			const published = cj.fp != "" ? publishModuleObject(cj.modPath, cj.baseFp, cj.oFile, cj.fp) : cj.oFile;
			if (cj.cacheKey != "") writeCompileFingerprintFp(cj.cacheKey, cj.baseFp);
			if (cj.storeKey != "" && !driverPlansOn()) {
				const dirs = objectSearchDirs(opts.ccCompiler, opts.ccBinary, false, opts.mode, cj.flags);
				publishToStore(cj.storeKey, published, cj.depFile, cj.cFile, dirs, []);
			}
			oSlots[cj.slot] = [published];
		} else if (cj.modPath == "") {
			printError(`compile failed for dispatcher ${dim(`(exit ${code})`)}`);
			throw new Error(BUILD_STOPPED);
		} else {
			invalidateCompileCache(cj.modPath, cj.fp);
			printError(`compile failed for ${cj.modPath} ${dim(`(exit ${code})`)}`);
			moduleCompileFailed = true;
		}
		cji = cji + 1;
	}
	if (moduleCompileFailed) throw new Error(BUILD_STOPPED);
	flowStop("phase.C", fC);
	if (opts.showTime) {
		printTiming("phase C (codegen+compile)", tC);
		console.log(`    codegen: ${codegenTime}ms  clang: ${clangTime}ms`);
	}
	if (hcrImages) {
		const jobPaths: string[] = [];
		for (const job of emissionJobs) jobPaths.push(job.modPath);
		const tLink = performance.now();
		const relinkedPaths = linkHcrImages(oSlots, moduleSlots, jobPaths, hcrCoreSlot, hcrImageSlots, hcrModulePaths, hcrModules, entryPath, outBinary, allFlags, opts);
		if (hcrBuildAbi != null) publishHcrBuildAbi(hcrBuildAbi, relinkedPaths);
		writeProjectCache(projectDeps, outBinary, opts.ccCompiler, opts.ccBinary, opts.mode, buildIdentityFlags);
		if (session.keep && cJobs.length <= PLANNED_COMPILE_JOBS) ensurePchs(cJobs, opts.mode, opts.ccCompiler, opts.ccBinary);
		if (opts.showTime) printTiming("phase D (link images)", tLink);
		printDiag(success(`Built ${compiled} module(s) → ${bold(outBinary)}`) + dim(` (+${hcrModulePaths.length} HCR images)`));
		session.lastBuilt = true;
		return BuildStatus.Built;
	}
	oFiles = [];
	for (const slot of oSlots) {
		for (const oFile of slot) oFiles.push(oFile);
	}

	// Link all .o files into final binary (or shared library for HCR)
	// Build link flags from global linkState (Set = deduplicated)
	let allLink = cliLinkFlags(allFlags, opts);
	const externalLinkInputs = linkInputs(opts);
	for (const obj of externalLinkInputs) oFiles.push(obj);
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
		printDiag(success(`Built ${compiled} module(s) → ${bold(outBinary)}`) + dim(" (link cached)"));
		if (opts.showTime) printTiming("built", t0);
		session.lastBuilt = true;
		return BuildStatus.Built;
	}

	const tD = performance.now();
	const fD = flowStart();

	// Emscripten: a wait from sync code suspends the wasm stack only through a sleep or a
	// pending timer (spawn runs inline here), so JSPI is linked exactly when one of those
	// runtime entries is reachable; a JSPI build does not load where the browser lacks JSPI.
	if (opts.targetOs == "emcc" && aliveSet.computed) {
		let suspends = false;
		for (const entry of ["msSleepMs", "msSleepAsync", "msSetTimeout", "msSetInterval"]) {
			if (aliveSetImportsC(aliveSet, entry)) suspends = true;
		}
		if (suspends) {
			linkFlags = appendFlag(linkFlags, "-sJSPI");
			if (opts.verbose) verboseLog("  sleep or timer reachable → enabling JSPI");
		}
	}

	if (opts.verbose) verboseLog("linking → " + outBinary);
	if (opts.appMode == "staticlib") {
		const arRes = archiveStatic(oFiles, outBinary);
		if (!arRes.ok) {
			printError(`ar failed ${dim(`(exit ${arRes.error.exitCode})`)}`);
			if (arRes.error.errorOutput != "") printDiag(arRes.error.errorOutput);
			throw new Error(BUILD_STOPPED);
		}
	} else if (opts.targetOs == "solana") {
		let linkRes = linkSolana(oFiles, outBinary, opts.ccBinary, opts.lto, opts.mode, opts.strip);
		if (!linkRes.ok && dispatcherSlot >= 0 && reportsSbfFrameOverflow(linkRes.error)) {
			printDiag(`${yellow("note")}: the entry frame overflowed with MsMain inlined; rebuilding MsMain out of line`);
			const retryJobs: ModuleCompileJob[] = [];
			const retrySlots: string[][] = [];
			pushDispatcherJob(retryJobs, retrySlots, "_dispatch", dispatcherSource, appendFlag(allFlags, SBF_MAIN_NOINLINE_FLAG), opts);
			const retryCodes = dispatchCompileJobs(retryJobs, opts.mode, opts.ccCompiler, opts.ccBinary, true);
			for (const code of retryCodes) {
				if (code != 0) {
					printError(`compile failed for dispatcher ${dim(`(exit ${code})`)}`);
					throw new Error(BUILD_STOPPED);
				}
			}
			const retried = retryJobs.length > 0 ? retryJobs[0].oFile : retrySlots[0][0];
			const stale = oSlots[dispatcherSlot][0];
			oFiles = oFiles.map((o: string): string => o == stale ? retried : o);
			linkRes = linkSolana(oFiles, outBinary, opts.ccBinary, opts.lto, opts.mode, opts.strip);
		}
		if (!linkRes.ok) {
			printError(`SBF link failed ${dim(`(exit ${linkRes.error.exitCode})`)}`);
			if (linkRes.error.errorOutput != "") printDiag(linkRes.error.errorOutput);
			throw new Error(BUILD_STOPPED);
		}
	} else {
		const linkRes = linkObjects(oFiles, outBinary, linkFlags, opts.mode, opts.ccCompiler, opts.ccBinary, opts.targetOs);
		if (!linkRes.ok) {
			printError(`link failed ${dim(`(exit ${linkRes.error.exitCode})`)}`);
			if (linkRes.error.errorOutput != "") printDiag(linkRes.error.errorOutput);
			throw new Error(BUILD_STOPPED);
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
	flowStop("phase.link", fD);
	printDiag(success(`Built ${compiled} module(s) → ${bold(outBinary)}`));
	if (opts.showTime) printTiming("total", t0);
	session.lastBuilt = true;
	return BuildStatus.Built;
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
	setToolchainHeaderRoot(toolchainHeaderRoot(opts.ccCompiler, opts.ccBinary));
	resolveLto(opts);
	const config = buildResolverConfig(Target.C, defaultResolveSection());
// Reference parity: global hook ownership registry shared across all modules.
// Before the graph check: enum toString ops register during checking, and this resets the op table.
resetLiftedOps();
	const graph = loadAndCheckGraph(filePath, config, opts, opts.targetInfo, gcModeOf(opts.gcMode));

	// Phase A: Parse → Check → Mono → Transform → Analyze all modules
	const processed: ProcessedModule[] = [];
	const transformedPrograms: Node[] = [];
	const transformedPaths: string[] = [];
	const bs = initCBuildState(opts);
	let allFlags = bs.allFlags;
	const includePaths = bs.includePaths;
	let oFiles: string[] = [];



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
		const checked = graphCheckedModule(graph, modPath, mod, opts);
		checked.ctx.errors = [];
		checkedMods.push({ program: checked.program, ctx: checked.ctx, modPath, source: mod.rawSource });
		programByPath.set(modPath, checked.program);
	}

	// Single drain after A1 — route each pending generic instance to its OWNER module's
	// program so the generic body's module-private helpers are visible in the same TU.
	// Owner-less nodes fall back to the entry program.
	placePendingInstances((path: string): Node | null => programByPath.has(path) ? programByPath.get(path) : null, checkedModCtxs(checkedMods));

	// Phase A2 — mono → transform → analyze → lower, per module (instances now placed).
	const writeTables = createWriteSummaries(createRoutineDecls(), opts.isHcr ? [filePath] : []);
	const liftTables = createWriteSummaries(createRoutineDecls(), opts.isHcr ? [filePath] : []);
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
		const transformed = transformProgram(comptimeResolved, ctx, false, opts.isHcr && modPath == filePath ? [filePath] : [], false, liftTables);
		exitOnCheckerErrors(ctx, modPath, cm.source);
		const nativeCtx = createTransformContextWithChecker(ctx);
		nativeCtx.rangeChecks = opts.mode != MODE_DANGER;
		nativeCtx.boundChecks = opts.mode != MODE_DANGER;
		nativeCtx.objChecks = opts.mode != MODE_DANGER;
		const nativeTransformed = transformForNative(transformed, nativeCtx);
		const hcrResult = opts.isHcr && modPath == filePath ? liftHcrState(nativeTransformed, nativeCtx, replaceExt(entryName(filePath), "")) : nativeTransformed;
		exitOnCheckerErrors(ctx, modPath, cm.source);
		ctx.gcMode = gcModeOf(opts.gcMode);
		ctx.targetOs = opts.targetOs;
		ctx.targetInfo = opts.targetInfo;

		const preAnErrors = ctx.errors.length;
		const analyzed = analyzeProgram(hcrResult, ctx, writeTables);
		if (ctx.errors.length > preAnErrors) {
			for (let ei = preAnErrors; ei < ctx.errors.length; ei += 1) {
				const e = ctx.errors[ei];
				renderModuleError(modPath, cm.source, { message: e.message, line: e.line, column: e.column, severity: ErrorSeverity.Error });
			}
			exit(1);
		}
		const nativeLowered = lowerNativeAccess(analyzed, nativeCtx);

		processed.push({ program: nativeLowered, ctx, modPath });
		transformedPrograms.push(nativeLowered);
		transformedPaths.push(modPath);

		const resolved = resolveIncludeFlags(ctx.compilerFlags, includePaths, dirname(modPath), resolveRuntimeDir());
		allFlags = mergeFlagsDeduped(allFlags, resolved);
		registerIncludePaths(resolved, includePaths);
	}

	// Phase B: Compute DCE alive set on post-transform ASTs (reference-aligned)
	if (opts.verbose) verboseLog("computing alive set (post-transform DCE)");
	inferRaises(transformedPrograms);
	const aliveSet = computeAliveSet(transformedPrograms, transformedPaths, filePath, true, graph);

	// Compile prelude @compile directives — unconditional (reference-aligned: all @compile are always built)
	if (graphPreludeCtx != null && graphPreludeCtx.compileDirectives != "") {
		const preludeObjs = processCompileDirectives(graphPreludeCtx.compileDirectives, resolveRuntimeDir(), includePaths, allFlags, opts.mode, opts.ccCompiler, opts.ccBinary, opts.verbose, opts.targetOs, opts.projectRoot, resolveRuntimeDir());
		for (const oFile of preludeObjs) oFiles.push(oFile);
	}

	const rtObjs = compilePlatformRuntime(includePaths, allFlags, opts);
	for (const oFile of rtObjs) oFiles.push(oFile);

	// Phase C: Codegen + compile each module (per-module .c cache)
	const emissionFacts = new CEmissionFacts();
	const emissionJobs: ModuleEmissionJob[] = [];
	for (const p of processed) emissionJobs.push({ slot: emissionJobs.length, program: p.program, ctx: p.ctx, modPath: p.modPath, weight: p.program.location.endLine });
	const emitWidth: int32 = opts.emitJobs < 1 ? emissionJobs.length : opts.emitJobs;
	let emissionResults: ModuleEmissionResult[] = [];
	for (const p of processed) factInlineDecls(emissionFacts, p.program);
	setConcurrentTypeQueries(true);
	try {
		for (const p of processed) {
			prepareCModuleEmission(p.program, p.ctx, p.modPath, aliveSet, emissionFacts);
		}
		emissionResults = emitModulesBounded(emissionJobs, aliveSet, emissionFacts, emitWidth, true, opts.isHcr ? filePath : "");
	} finally {
		setConcurrentTypeQueries(false);
	}
	if (opts.showTime) console.log(`    emit workers=${emitWidth} overlap=${emissionOverlapped(emissionResults)}`);
	let emissionFailed = false;
	for (let eri = 0; eri < emissionResults.length; eri += 1) {
		const result = emissionResults[eri];
		if (!result.completed) continue;
		const modPath = emissionJobs[eri].modPath;
		if (result.failure != "") {
			printError(`${modPath}: ${result.failure}`);
			emissionFailed = true;
		}
		for (const diagnostic of result.output.errors) {
			printError(`${modPath}: ${diagnostic.message}`);
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
		const baseFp = moduleCompileFp(cCode, compileCmd);
		const modFp = moduleObjectFp(p.modPath, baseFp);
		const oFile = stableOFileFp(p.modPath, modFp);

		if (isCCodeCached(p.modPath, modFp)) {
			oSlots.push([oFile]);
			if (opts.verbose) verboseLog(`  cached ${p.modPath}`);
		} else {
			// Same as main path — defer fingerprint until success.
			writeCSource(p.modPath, baseFp, cCode);
			const cFile = stableCFileFp(p.modPath, baseFp);
			if (opts.verbose) verboseLog(`  cc ${cFile} → ${oFile}`);
			oSlots.push([]);
			cJobs.push({ cFile, oFile, modPath: p.modPath, flags: testModFlags, fp: modFp, baseFp, depFile: moduleDepFile(p.modPath, baseFp), cacheKey: "", slot: oSlots.length - 1, storeKey: "" });
		}
		compiled = compiled + 1;
		p.program = null as unknown as Node;
		p.ctx = null as unknown as CheckerContext;
	}

	// Generate test dispatcher (runs all module inits + test tables)
	if (opts.verbose) verboseLog("generating test dispatcher");
	const entryDir = `${dirname(filePath)}/`;
	const tested: string[] = [];
	let candidates = 0;
	for (const p of graph.loadOrder) {
		if (opts.testsInDir && !p.startsWith(entryDir)) continue;
		if (candidates % opts.testsShards == opts.testsShard) tested.push(p);
		candidates += 1;
	}
	const dispatcher = genTestDispatcher(graph.loadOrder, tested, filePath);
	// Same concurrent-build rule as cmdBuildC's dispatcher: fp-keyed + atomic .c.
	const dispFp = moduleCompileFp(dispatcher, fullCompileCmd(opts.ccCompiler, opts.mode, allFlags, opts.ccBinary));
	writeCSource("_test_dispatch", dispFp, dispatcher);
	const dispFile = stableCFileFp("_test_dispatch", dispFp);
	oSlots.push([]);
	cJobs.push({ cFile: dispFile, oFile: stableOFileFp("_test_dispatch", dispFp), modPath: "", flags: allFlags, fp: "", baseFp: "", depFile: "", cacheKey: "", slot: oSlots.length - 1, storeKey: "" });

	const cCodes = dispatchCompileJobs(cJobs, opts.mode, opts.ccCompiler, opts.ccBinary, cJobs.length <= PLANNED_COMPILE_JOBS);
	let testFailed = false;
	let cji = 0;
	while (cji < cJobs.length) {
		const cj = cJobs[cji];
		const code = cCodes[cji];
		if (code == 0) {
			oSlots[cj.slot] = [cj.fp != "" ? publishModuleObject(cj.modPath, cj.baseFp, cj.oFile, cj.fp) : cj.oFile];
		} else if (cj.modPath == "") {
			printError(`compile failed for test dispatcher ${dim(`(exit ${code})`)}`);
			testFailed = true;
		} else {
			invalidateCompileCache(cj.modPath, cj.fp);
			printError(`compile failed for ${cj.modPath} ${dim(`(exit ${code})`)}`);
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
	const shardTag = opts.testsShards > 1 ? `_s${opts.testsShard}of${opts.testsShards}` : "";
	const testBin = `out/debug/${testRootName(filePath)}${shardTag}`;
	// Same link flags as cmdBuildC. cmdTest used to assemble its own and so
	// silently dropped everything cliLinkFlags contributes: the per-target
	// system libraries and --passL. On Windows that is fatal — without
	// -lws2_32 / -lmswsock / -lbcrypt every Winsock and BCrypt symbol is
	// undefined at link, so `msc test` could not link any graph reaching
	// std/net. macOS only loses -Wl,-dead_strip there, which is why the gap
	// went unnoticed. forceExe keeps --app=lib / --hcr from turning the test
	// binary into a shared library: execFile below has to run it.
	let testLink = cliLinkFlags(allFlags, opts, true);
	for (const obj of linkInputs(opts)) oFiles.push(obj);
	for (const flag of globalLinkFlags()) { testLink = appendFlag(testLink, flag); }
	const linkRes = linkObjects(oFiles, testBin, testLink, opts.mode, opts.ccCompiler, opts.ccBinary, opts.targetOs);
	if (!linkRes.ok) {
		printError(`link failed ${dim(`(exit ${linkRes.error.exitCode})`)}`);
		if (linkRes.error.errorOutput != "") printDiag(linkRes.error.errorOutput);
		exit(1);
	}

	if (opts.showTime) printTiming("compiled", t0);
	if (opts.verbose) verboseLog("running tests");
	const runCode = execFile(testBin);
	if (platform == "windows" && runCode >= 0xC0000000) {
		printError(`test binary terminated with status 0x${runCode.toString(16).toUpperCase()}`);
		exit(1);
	}
	if (runCode > 128) printError(`test binary terminated by signal ${runCode - 128}`);
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
	return `_ext/${mangleModuleName(buildModuleNameRoots(), modPath)}.js`;
}

interface JsInstanceFile {
	name: string;      // the binding every module emits for the instance
	declName: string;
	owner: string;     // the module that declares the generic
}

function jsInstanceBindingName(node: Node): string {
	const sym = node.resolvedSym;
	if (sym == null || sym.instantiatedFrom == null || sym.modulePath == "") return "";
	if (node.kind == NodeKind.FunctionDecl) {
		return mangledFunctionName(buildModuleNameRoots(), sym, (node.data as FunctionDeclData).fnName, sym.overloadIdx);
	}
	if (node.kind == NodeKind.ClassDecl) return mangledGlobalName(buildModuleNameRoots(), sym, (node.data as ClassDeclData).className);
	return "";
}

function isAssignment(operator: string): boolean {
	if (!operator.endsWith("=")) return false;
	return match (operator) {
		"==" | "!=" | "<=" | ">=" | "===" | "!==" => false,
		_ => true,
	};
}

function namesModuleBinding(target: Node): boolean {
	if (target.kind == NodeKind.Identifier) return isModuleGlobalVar(target.resolvedSym);
	if (target.kind == NodeKind.MemberExpr || target.kind == NodeKind.ArrayAccess) return false;
	let found = false;
	forEachChild(target, (child: Node): void => {
		if (!found) found = namesModuleBinding(child);
	});
	return found;
}

// ECMA-262 makes an imported binding immutable in the importing module, so a
// body that assigns a module-level variable can only run in the file declaring it.
function assignsModuleBinding(node: Node): boolean {
	if (node.kind == NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		if (isAssignment(d.operator) && namesModuleBinding(d.left)) return true;
	}
	if (node.kind == NodeKind.UpdateExpr && namesModuleBinding((node.data as UpdateExprData).updateArg)) return true;
	let found = false;
	forEachChild(node, (child: Node): void => {
		if (!found) found = assignsModuleBinding(child);
	});
	return found;
}

function emitsRawText(node: Node): boolean {
	if (node.kind == NodeKind.MacroInvocation && (node.data as MacroInvocationData).macroName == "emit") return true;
	let found = false;
	forEachChild(node, (child: Node): void => {
		if (!found) found = emitsRawText(child);
	});
	return found;
}

// An instance the declaring module's own check asked for stays in that module:
// its code needs the instance while the module is still being evaluated.
function jsInstanceFiles(modulePaths: string[], moduleCtxs: CheckerContext[]): JsInstanceFile[] {
	const ctxOf = new HashMap<string, CheckerContext>();
	for (let i = 0; i < modulePaths.length; i += 1) ctxOf.set(modulePaths[i], moduleCtxs[i]);
	const kept = new HashSet<string>();
	const asked: Node[] = [];
	const hosts = new HashSet<CheckerContext>();
	for (const host of moduleCtxs) {
		if (hosts.has(host)) continue;
		hosts.add(host);
		for (const node of host.generatedInstances) {
			const name = jsInstanceBindingName(node);
			if (name == "") continue;
			if (ctxOf.get(node.resolvedSym!.modulePath) == host || assignsModuleBinding(node) || emitsRawText(node)) {
				kept.add(name);
			} else {
				asked.push(node);
			}
		}
	}
	const files: JsInstanceFile[] = [];
	const given = new HashSet<string>();
	for (const node of asked) {
		const name = jsInstanceBindingName(node);
		if (kept.has(name) || given.has(name)) continue;
		given.add(name);
		const declName = node.kind == NodeKind.ClassDecl ? (node.data as ClassDeclData).className : (node.data as FunctionDeclData).fnName;
		files.push({ name, declName, owner: node.resolvedSym!.modulePath });
	}
	return files;
}

function writtenFunction(stmt: Node): Node | null {
	let n = stmt;
	if (n.kind == NodeKind.ExportDecl) n = (n.data as ExportDeclData).exportedDecl;
	if (n != null && n.kind == NodeKind.DecoratedDecl) n = (n.data as DecoratedDeclData).decoratedNode;
	return n != null && n.kind == NodeKind.FunctionDecl ? n : null;
}

// A function the lowerings add at module scope on demand (a struct's
// equality, an enum's toString) is made once per module that calls it, so
// each file that calls it carries its own copy and none depends on another's.
function collectLoweringFunctions(node: Node, added: HashMap<string, Node>, seen: HashSet<string>, into: Node[]): void {
	if (node.kind == NodeKind.Identifier) {
		const name = (node.data as IdentifierData).name;
		const decl = added.get(name);
		if (decl != null && !seen.has(name)) {
			seen.add(name);
			into.push(decl);
			collectLoweringFunctions(decl, added, seen, into);
		}
	}
	forEachChild(node, (child: Node): void => { collectLoweringFunctions(child, added, seen, into); });
}

function isNamespaceImport(stmt: Node): boolean {
	if (stmt.kind != NodeKind.ImportDecl) return false;
	const names = (stmt.data as ImportDeclData).importNames;
	return names.length == 1 && names[0] == "*";
}

function importSpecsFrom(layout: JsTreeLayout, mod: Module | null, file: string): { keys: string[], vals: string[] } {
	const keys: string[] = [];
	const vals: string[] = [];
	const fromRel = layout.outRelOf.get(file) ?? "";
	if (mod == null) return { keys, vals };
	for (const imp of mod.imports) {
		const toRel = layout.outRelOf.get(imp.sourcePath);
		if (toRel == null) continue;
		keys.push(imp.sourceSpecifier);
		vals.push(relSpecBetween(fromRel, toRel));
	}
	return { keys, vals };
}

export interface JsTreeResult {
	outRoot: string;
	modulePaths: string[];
	moduleOutRels: string[];
	instanceOwners: string[];
	instanceOutRels: string[];
	testNames: string[][];
	testFuncs: string[][];
}

function testRootName(entryPath: string): string {
	const key = hashContent(entryPath);
	return `_test_${replaceExt(basename(entryPath), "")}_${key.slice(0, key.indexOf("_"))}`;
}

function emitJSModuleTree(filePath: string, opts: CliOptions, isTestBuild: boolean, outRootOverride: string): JsTreeResult {
	registerCoreParsers();
	const config = buildResolverConfig(Target.JS, defaultResolveSection());
	const graph = loadAndCheckGraph(filePath, config, opts);

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
	const modeRoot = `${projectRoot}/${outDirForMode(opts.mode)}`;
	const outRoot = outRootOverride != "" ? outRootOverride : (isTestBuild ? `${modeRoot}/${testRootName(filePath)}_js` : modeRoot);
	const stdRoot = config.stdPath;

	const layout = createJsTreeLayout();
	for (const modPath of graph.loadOrder) {
		layout.outRelOf.set(modPath, outRelForModule(modPath, projectRoot, stdRoot));
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

		const checked = graphCheckedModule(graph, modPath, mod, opts);
		const ctx = checked.ctx;
		ctx.errors = [];

		const macroExpanded = expandMacros(checked.program, ctx);
		exitOnCheckerErrors(ctx, modPath, mod.rawSource);

		unitPaths.push(modPath);
		unitPrograms.push(evaluateComptimeBlocks(macroExpanded));
		unitCtxs.push(ctx);
	}

	// A generic instance belongs to the module that DECLARED the generic, and
	// its emitted name says so: it is placed and transformed with that module,
	// same routing as the bundle path. Vite reloads the page when the file of a
	// module without an HMR boundary changes, so an instance only other modules
	// asked for is written to a file of its own instead of the declaring one.
	const instanceFiles = jsInstanceFiles(unitPaths, unitCtxs);
	placePendingInstances((path: string): Node | null => unitProgramAt(unitPaths, unitPrograms, path), unitCtxs, true);
	const instanceOutRelTaken = new HashSet<string>();
	for (const inst of instanceFiles) {
		const file = `${inst.owner}#${inst.name}`;
		const outRel = `_inst/${safeName(inst.declName).slice(0, 40)}.${hashContent(file)}.js`;
		if (instanceOutRelTaken.has(outRel)) throw new Error(`internal: two generic instances are written to ${outRel}`);
		instanceOutRelTaken.add(outRel);
		layout.instanceFileOf.set(inst.name, file);
		layout.outRelOf.set(file, outRel);
	}

	// Export-name surface per module — jsMultiFileName keys public naming off
	// this list on BOTH the declaring and the referencing side (symbol flags
	// don't survive the registry round-trip; mod.exportNames does).
	const modExportKeys: string[] = [];
	const modExportVals: string[][] = [];
	const modFunctionOwnerNames: string[][] = [];
	for (let ui = 0; ui < unitPaths.length; ui += 1) {
		const modPath = unitPaths[ui];
		const mod = findModule(graph, modPath);
		if (mod == null) continue;
		modExportKeys.push(modPath);
		modExportVals.push(mod.exportNames);
		const names: string[] = [];
		const exports = findModuleExports(unitCtxs[ui].exportRegistry, modPath);
		if (exports != null) {
			for (const info of exports.symbols) {
				if (info.sym.symbolKind == SymbolKind.Function && info.sym.modulePath == modPath && !isStaticExtensionSym(info.sym)) {
					names.push(info.name);
					for (const ov of info.sym.overloads) {
						if (ov.modulePath == modPath) names.push(info.name);
					}
				}
			}
		}
		modFunctionOwnerNames.push(names);
	}

	const fileKeys: string[] = [];
	const fileIndexOf = new HashMap<string, int32>();
	const fileResults: JsModuleResult[] = [];
	const fileForced: string[][] = [];
	const instanceOwners: string[] = [];
	const instanceOutRels: string[] = [];
	const moduleTestNames: string[][] = [];
	const moduleTestFuncs: string[][] = [];
	for (let ui = 0; ui < unitPaths.length; ui += 1) {
		const modPath = unitPaths[ui];
		const ctx = unitCtxs[ui];
		const mod = findModule(graph, modPath);
		if (!(stdRoot != "" && modPath.startsWith(stdRoot))) {
			refuseSyncAwaitOnJs(ctx, unitPrograms[ui]);
			exitOnCheckerErrors(ctx, modPath, mod != null ? mod.rawSource : "");
		}
		refusePointerOpsOnJs(ctx, unitPrograms[ui]);
		exitOnCheckerErrors(ctx, modPath, mod != null ? mod.rawSource : "");
		const written = new HashSet<Symbol>();
		const writtenUnresolved = new HashSet<string>();
		for (const stmt of (unitPrograms[ui].data as ProgramData).programStmts) {
			const fn = writtenFunction(stmt);
			if (fn == null) continue;
			if (fn.resolvedSym != null) written.add(fn.resolvedSym);
			else writtenUnresolved.add((fn.data as FunctionDeclData).fnName);
		}
		const transformed = transformProgram(unitPrograms[ui], ctx, true);
		exitOnCheckerErrors(ctx, modPath, mod != null ? mod.rawSource : "");

		const own: Node[] = [];
		const namespaceImports: Node[] = [];
		const moved: Node[] = [];
		for (const stmt of (transformed.data as ProgramData).programStmts) {
			if (layout.instanceFileOf.has(jsInstanceBindingName(stmt))) {
				moved.push(stmt);
				continue;
			}
			own.push(stmt);
			if (isNamespaceImport(stmt)) namespaceImports.push(stmt);
		}
		const added = new HashMap<string, Node>();
		const addedDecls = new HashSet<Node>();
		if (moved.length > 0) {
			for (const stmt of own) {
				if (stmt.kind != NodeKind.FunctionDecl) continue;
				const fnName = (stmt.data as FunctionDeclData).fnName;
				if (stmt.resolvedSym != null ? written.has(stmt.resolvedSym) : writtenUnresolved.has(fnName)) continue;
				added.set(fnName, stmt);
				addedDecls.add(stmt);
			}
		}
		for (const stmt of moved) {
			const name = jsInstanceBindingName(stmt);
			const file = layout.instanceFileOf.get(name)!;
			if (fileIndexOf.has(file)) throw new Error(`internal: generic instance ${name} is declared twice in ${modPath}`);
			const scope: Node[] = [];
			for (const imp of namespaceImports) scope.push(imp);
			collectLoweringFunctions(stmt, added, new HashSet<string>(), scope);
			scope.push(stmt);
			const specs = importSpecsFrom(layout, mod, file);
			const program = createNodeAt(NodeKind.Program, { programStmts: scope }, transformed.location);
			fileIndexOf.set(file, fileKeys.length as int32);
			fileKeys.push(file);
			fileResults.push(generateJSModule(program, ctx.jsImportRegistry, modPath, file, layout, specs.keys, specs.vals, modExportKeys, modExportVals, modFunctionOwnerNames, isTestBuild, opts.sourcemap));
			fileForced.push([name]);
			instanceOwners.push(modPath);
			instanceOutRels.push(layout.outRelOf.get(file)!);
		}

		const kept: Node[] = [];
		if (moved.length > 0) {
			const called: Node[] = [];
			const seen = new HashSet<string>();
			for (const stmt of own) {
				if (!addedDecls.has(stmt)) collectLoweringFunctions(stmt, added, seen, called);
			}
			for (const stmt of own) {
				if (!addedDecls.has(stmt) || called.includes(stmt)) kept.push(stmt);
			}
		}
		const specs = importSpecsFrom(layout, mod, modPath);
		const program = moved.length == 0 ? transformed : createNodeAt(NodeKind.Program, { programStmts: kept }, transformed.location);
		const res = generateJSModule(program, ctx.jsImportRegistry, modPath, modPath, layout, specs.keys, specs.vals, modExportKeys, modExportVals, modFunctionOwnerNames, isTestBuild, opts.sourcemap);
		fileIndexOf.set(modPath, fileKeys.length as int32);
		fileKeys.push(modPath);
		fileResults.push(res);
		fileForced.push([]);
		moduleTestNames.push(res.testNames);
		moduleTestFuncs.push(res.testFuncs);
	}

	// Forced exports: every module-level binding a file declares without
	// exporting it, so its text does not depend on which of them a generic
	// body or a macro expansion in another module came to reference. A name
	// needed here but not defined here is a compiler bug — node fails loudly
	// at the gate, by design.
	for (let vi = 0; vi < fileKeys.length; vi += 1) {
		const needed = fileResults[vi];
		for (const n of needed.declaredNames) {
			if (!needed.exportedNames.includes(n) && !fileForced[vi].includes(n)) fileForced[vi].push(n);
		}
	}
	const fileReexports: string[][] = [];
	for (let vi = 0; vi < fileKeys.length; vi += 1) fileReexports.push([]);
	for (let vi = 0; vi < fileKeys.length; vi += 1) {
		const needed = fileResults[vi];
		for (let mi = 0; mi < needed.neededModules.length; mi += 1) {
			const target = needed.neededModules[mi];
			const ti = fileIndexOf.get(target);
			if (ti == null) {
				if (layout.outRelOf.has(target)) throw new Error(`internal: ${fileKeys[vi]} imports from ${target}, which was not emitted`);
				continue;
			}
			if (ti == vi) continue;
			for (const n of needed.neededNames[mi]) {
				if (!fileResults[ti].exportedNames.includes(n) && !fileForced[ti].includes(n)) fileForced[ti].push(n);
			}
		}
		for (let mi = 0; mi < needed.namespaceModules.length; mi += 1) {
			const ti = fileIndexOf.get(needed.namespaceModules[mi]);
			if (ti == null) continue;
			for (const n of needed.namespaceNames[mi]) {
				const instFile = layout.instanceFileOf.get(n);
				if (instFile != null && instFile != fileKeys[ti]) {
					const line = `export { ${n} } from "${relSpecBetween(layout.outRelOf.get(fileKeys[ti])!, layout.outRelOf.get(instFile)!)}";\n`;
					if (!fileReexports[ti].includes(line)) fileReexports[ti].push(line);
					continue;
				}
				if (!fileResults[ti].exportedNames.includes(n) && !fileForced[ti].includes(n)) fileForced[ti].push(n);
			}
		}
	}
	for (let fi = 0; fi < fileKeys.length; fi += 1) {
		let code = fileResults[fi].code;
		const forced = fileForced[fi];
		if (forced.length > 0) {
			forced.sort();
			code = `${code}export { ${forced.join(", ")} };\n`;
		}
		for (const line of fileReexports[fi]) code = `${code}${line}`;
		const outPath = `${outRoot}/${layout.outRelOf.get(fileKeys[fi])!}`;
		ensureDir(dirname(outPath));
		if (opts.sourcemap) {
			const mapName = `${basename(outPath)}.map`;
			const smap = fileResults[fi].smap;
			const stdIgnored = ignoredFileIndexes(smap, (p: string): boolean => stdRoot != "" && p.startsWith(stdRoot));
			writeOutput(`${outPath}.map`, toSourceMapJson(smap, basename(outPath), mapDirOf(outPath), readSourceText, stdIgnored));
			code = `${code}\n//# sourceMappingURL=${mapName}\n`;
		}
		writeOutput(outPath, code);
	}

	const outRels: string[] = [];
	for (const mp of unitPaths) { outRels.push(layout.outRelOf.get(mp) ?? ""); }
	return { outRoot, modulePaths: unitPaths, moduleOutRels: outRels, instanceOwners, instanceOutRels, testNames: moduleTestNames, testFuncs: moduleTestFuncs };
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
	const node = findOnPath("node");
	if (node == "") {
		console.log(`${error("error")}: msc run --target=js needs node on PATH`);
		exit(1);
	}
	const forwarded: string[] = [entryJs];
	for (const arg of opts.extraArgs) { forwarded.push(arg); }
	exit(execFile(node, forwarded));
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
		"  err.msAssert = true; err.msDefect = true; err.msFile = file; err.msLine = line; err.msDiag = paPending;",
		"  paPending = null;",
		"  throw err;",
		"};",
		"export async function run(modules) {",
		"  let filesPassed = 0, filesFailed = 0, testsPassed = 0, testsFailed = 0;",
		"  const failures = [];",
		"  const t0 = Date.now();",
		"  const namespaces = [];",
		"  for (const mod of modules) namespaces.push(await import(mod.spec));",
		"  for (let mi = 0; mi < modules.length; mi += 1) {",
		"    const mod = modules[mi], ns = namespaces[mi];",
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

export function compileRaiser(filePath: string, opts: CliOptions, resolveSection: ResolveSection = defaultResolveSection(), session: BuildSession | null = null, exportRoutines: boolean = false): RaiserModule {
	if (session != null) startSessionBuild(session);
	const config = buildResolverConfig(Target.Raiser, resolveSection, platform, opts.projectRoot);
	const graph = loadAndCheckGraph(filePath, config, opts, hostTargetInfo(), GcMode.Drc, session != null ? session.check : null);

	const modules: RaiserModuleInput[] = [];
	const entryCanonical = canonicalModulePath(filePath);
	const unitPaths: string[] = [];
	const unitPrograms: Node[] = [];
	const unitCtxs: CheckerContext[] = [];
	for (const modPath of graph.loadOrder) {
		const mod = findModule(graph, modPath);
		if (mod == null) continue;

		if (opts.verbose) verboseLog("compiling " + modPath);
		const checked = graphCheckedModule(graph, modPath, mod, opts);
		checked.ctx.errors = [];
		if (!(config.stdPath != "" && modPath.startsWith(config.stdPath))) {
			refuseBigIntOnRaiser(checked.ctx, checked.program);
			exitOnCheckerErrors(checked.ctx, modPath, mod.rawSource);
		}
		unitPaths.push(modPath);
		unitPrograms.push(checked.program);
		unitCtxs.push(checked.ctx);
	}
	const kept = session != null && session.keep ? session : null;
	if (kept != null) {
		const routeOrder: Node[] = [];
		for (const modPath of unitPaths) {
			const created = kept.check.instances.get(modPath);
			if (created != null) for (const instNode of created) routeOrder.push(instNode);
		}
		retainCheckedInstances(unitCtxs);
		const byOwner = routeInstances(routeOrder, (path: string): Node | null => unitProgramAt(unitPaths, unitPrograms, path), false, null);
		for (let i = 0; i < unitPrograms.length; i += 1) {
			const program = cloneNodeKeepSem(unitPrograms[i]);
			const routed = byOwner.get(unitPaths[i]);
			if (routed != null) for (const inst of routed) (program.data as ProgramData).programStmts.push(cloneNodeKeepSem(inst));
			unitPrograms[i] = program;
		}
	} else {
		placePendingInstances((path: string): Node | null => unitProgramAt(unitPaths, unitPrograms, path), unitCtxs);
	}
	for (let i = 0; i < unitPrograms.length; i += 1) {
		const modCtx = unitCtxs[i];
		const monoed = monomorphizeProgram(unitPrograms[i], modCtx);
		const macroExpanded = expandMacros(monoed, modCtx);
		const mod = findModule(graph, unitPaths[i]);
		if (mod != null) exitOnCheckerErrors(modCtx, unitPaths[i], mod.rawSource);
		const comptimeResolved = evaluateComptimeBlocks(macroExpanded);
		const txCtx = createTransformContextWithChecker(modCtx);
		txCtx.rangeChecks = opts.mode != MODE_DANGER;
		const transformed = transformForRaiser(comptimeResolved, modCtx);
		if (mod != null) exitOnCheckerErrors(modCtx, unitPaths[i], mod.rawSource);

		const input: RaiserModuleInput = { modulePath: unitPaths[i], program: transformed };
		modules.push(input);
	}

	// Before bytecodegen: the coverage check inside generateRaiserProject
	// resolves every extern's bridge at the call site, and execution dispatches
	// through the same registry — load it first or both see an empty table.
	ensureHostTableLoaded();
	if (opts.verbose) verboseLog(`generating bytecode (${modules.length} modules)`);
	const raiserMod = generateRaiserProject(modules, planDynamicModules(graph, entryCanonical, unitPaths, config.stdPath), exportRoutines ? entryCanonical : "");
	// Comptime parity: queued bytecode-compile errors are collected and
	// reported, not fatal — std module bodies the program never calls can
	// contain unbridgeable externs or unresolved helpers. A nil that leaks
	// into live code is visible here as a "cannot evaluate" line.
	const hook = _diagnosticHook;
	for (const e of takeRaiserCompileErrors()) {
		if (hook != null) hook("", { message: e.message, line: e.line, column: e.column, severity: ErrorSeverity.Warning });
		else printDiag(`${yellow("raiser warning")}: ${e.message} at ${e.line}:${e.column}`);
	}
	return raiserMod;
}

export function runRaiser(mod: RaiserModule, programArgv: string[], printSink: RaiserPrintSink): RaiserContext {
	const ctx = createRaiserContext();
	ctx.gcMode = "orc";
	ctx.programArgv = programArgv;
	ctx.printSink = printSink;
	raiserLoad(ctx, mod);
	raiserExecute(ctx);
	closeHostChildren();
	return ctx;
}

export function cmdRunRaiser(filePath: string, opts: CliOptions, resolveSection: ResolveSection = defaultResolveSection(), argv0: string = ""): void {
	const t0 = performance.now();
	const raiserMod = compileRaiser(filePath, opts, resolveSection);
	if (opts.showTime) printTiming("compiled", t0);

	const programArgv: string[] = [argv0 != "" ? argv0 : filePath];
	for (const a of opts.extraArgs) programArgv.push(a);
	const ctx = runRaiser(raiserMod, programArgv, (text: string): void => { console.log(text); });

	if (ctx.lastError != "") {
		printDiag(`${error("raiser runtime error")}: ${ctx.lastError}`);
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
		exit(ctx.lastResult.intVal as int32);
	}
}

test "msc run --hcr needs the std/hcr engine in the program's graph" {
	const graph = createModuleGraph();
	assert hcrHostMissesEngine(graph, "/std");
	addModule(graph, createModule(canonicalModulePath("/std/hcr/engine.cms")));
	assert !hcrHostMissesEngine(graph, "/std");
}

test "a prelude load seeds the std graph from the deps file the previous load wrote" {
	const prevHome = env.get("HOME");
	env.set("HOME", "out/test/preludeDepsHome");
	try {
		const config = createDefaultConfig(Backend.C, join(resolveRuntimeDir(), "std"));
		remove(`${packRoot()}/${preludeSeedKey(config)}.deps`);
		const fresh = createModuleGraph();
		loadPreludeModules(fresh, createFileSystemProvider(), config);
		assert !_preludeSeedHit;
		const seeded = createModuleGraph();
		loadPreludeModules(seeded, createFileSystemProvider(), config);
		assert _preludeSeedHit;
		assert seeded.loadOrder.join("\n") == fresh.loadOrder.join("\n");
		for (const path of fresh.loadOrder) {
			const a = findModule(fresh, path)!;
			const b = findModule(seeded, path)!;
			assert b.source == a.source;
			assert b.imports.map((ie) => ie.sourcePath).join(",") == a.imports.map((ie) => ie.sourcePath).join(",");
			assert b.preludeSpecifier == a.preludeSpecifier;
			assert b.stdPrelude == a.stdPrelude;
		}
	} finally {
		if (prevHome == "") env.delete("HOME");
		else env.set("HOME", prevHome);
	}
}

test "the prelude pack key names every define a std when-block can read" {
	const prevDefines = getParserDefines();
	try {
		const onChain = createDefineTable();
		initDefines(onChain, "c", "solana", "sbf", "manual", 0);
		const onHost = createDefineTable();
		initDefines(onHost, "c", "linux", "amd64", "drc", 0);
		const onHostFlagged = createDefineTable();
		initDefines(onHostFlagged, "c", "linux", "amd64", "drc", 0);
		applyDefineSwitch(onHostFlagged, "-d:probeFlag");
		const onBare = createDefineTable();
		initDefines(onBare, "c", "bare", "amd64", "manual", 0);

		setParserDefines(onChain);
		const chainKey = preludePackKey("/key/std", ".rms");
		setParserDefines(onHost);
		const hostKey = preludePackKey("/key/std", ".rms");
		setParserDefines(onHostFlagged);
		const flaggedKey = preludePackKey("/key/std", ".rms");
		setParserDefines(onBare);
		const bareKey = preludePackKey("/key/std", ".rms");
		setParserDefines(onChain);
		assert preludePackKey("/key/std", ".rms") == chainKey;

		assert chainKey != hostKey;
		assert hostKey != flaggedKey;
		assert bareKey != hostKey;
		assert bareKey != chainKey;
	} finally {
		setParserDefines(prevDefines);
	}
}

test "a prelude load never seeds the std graph from a deps file written for another target" {
	const prevHome = env.get("HOME");
	const prevDefines = getParserDefines();
	env.set("HOME", "out/test/preludeDepsHome");
	try {
		const config = createDefaultConfig(Backend.C, join(resolveRuntimeDir(), "std"));
		const onChain = createDefineTable();
		initDefines(onChain, "c", "solana", "sbf", "manual", 0);
		const onHost = createDefineTable();
		initDefines(onHost, "c", "linux", "amd64", "drc", 0);

		setParserDefines(onHost);
		remove(`${packRoot()}/${preludeSeedKey(config)}.deps`);
		setParserDefines(onChain);
		remove(`${packRoot()}/${preludeSeedKey(config)}.deps`);
		const chainFresh = createModuleGraph();
		loadPreludeModules(chainFresh, createFileSystemProvider(), config);
		assert !_preludeSeedHit;

		setParserDefines(onHost);
		const hostFresh = createModuleGraph();
		loadPreludeModules(hostFresh, createFileSystemProvider(), config);
		assert !_preludeSeedHit;
		assert hostFresh.loadOrder.length > chainFresh.loadOrder.length;

		setParserDefines(onChain);
		const chainSeeded = createModuleGraph();
		loadPreludeModules(chainSeeded, createFileSystemProvider(), config);
		assert _preludeSeedHit;
		assert chainSeeded.loadOrder.join("\n") == chainFresh.loadOrder.join("\n");

		setParserDefines(onHost);
		const hostSeeded = createModuleGraph();
		loadPreludeModules(hostSeeded, createFileSystemProvider(), config);
		assert _preludeSeedHit;
		assert hostSeeded.loadOrder.join("\n") == hostFresh.loadOrder.join("\n");
	} finally {
		setParserDefines(prevDefines);
		if (prevHome == "") env.delete("HOME");
		else env.set("HOME", prevHome);
	}
}

test "a test run gets an out root of its own per test file" {
	assert testRootName("/p/src/a.test.ms") != testRootName("/p/src/b.test.ms");
	assert testRootName("/p/x/a.test.ms") != testRootName("/p/y/a.test.ms");
	assert testRootName("/p/src/a.test.ms") == testRootName("/p/src/a.test.ms");
}

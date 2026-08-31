// MetaScript Compiler CLI — compile command

import { exit, exec, execFile, platform, cwd } from "std/process";
import { exists, readFile } from "std/fs";
import { parseSource } from "../parser/statements/validation";
import { Node, ProgramData } from "../ast/node";
import { CheckerContext, GcMode, hasErrors, hasFatalErrors, errorCount, Severity } from "../checker/context";
import { checkProgramWithRegistry } from "../checker/checkPass";
import { checkModuleGraph, getPreludeContext, setGraphCheckTiming } from "../checker/orchestrator";
import { ExportRegistry } from "../checker/context";
import { validateTypedAST } from "../checker/validate";
import { transformProgram } from "../transform/index";
import { analyzeProgram } from "../analyzer/index";
import { monomorphizeProgram } from "../monomorphize/collect";
import { generateJS, generateJSBundleModule, generateJSModule } from "../codegen/js/jsgen";
import { SourceInfo, createSourceInfo, appendInfo, toSourceMapJson, ignoredFileIndexes } from "../codegen/js/sourcemap";
import { escapeJSString } from "../codegen/js/emit";
import { generateRaiserProject, RaiserModuleInput } from "../codegen/raiser/rgen";
import { createContext as createRaiserContext, load as raiserLoad, execute as raiserExecute } from "../raiser/context";
import { generateCModule, genProjectDispatcher } from "../codegen/c/index";
import { mangleModuleName } from "../codegen/c/names";
import { resetEmittedInstances } from "../codegen/c/declarations";
import { aliveSetHasModule, clearSkippedTypeInfos } from "../codegen/c/context";
import { genTestDispatcher } from "../codegen/c/test";
import { registerCoreParsers } from "../parser/statements/core";
import { computeAliveSet } from "../checker/reachability";
import { getSimpleTypeDesc } from "../codegen/c/types";
import { setTargetSizes, isAwaitable } from "../checker/types";
import { lookupSymbol, SymbolFlag } from "../checker/symbol";
import { transformForNative } from "../transform/native/index";
import { refineTypes } from "../transform/typeRefine";
import { transformForRaiser } from "../transform/raiserLowering";
import { lowerNativeAccess } from "../transform/native/nativeLower";
import { liftHcrState } from "../transform/native/hcrLift";
import { lookupModuleCtx, lookupModuleProgram } from "../checker/instantiate";
import { setOuterProgramForComptime, setOuterCheckContext } from "./meta/callbacks";
import { createTransformContextWithChecker, createNameSet } from "../transform/context";
import { setGlobalHookOwners } from "../transform/lowering/destructorLifting";
import { createModuleGraph, findModule, hasModule, ModuleGraph, ModuleError, ErrorSeverity } from "../module/graph";
import { canonicalModulePath, createFileSystemProvider, loadModule, provideSource, SourceProvider } from "../module/loader";
import { ResolverConfig, createDefaultConfig, Backend, resolveImportWithConfig } from "../module/resolver";
import { readLockfile, entryName } from "./package/lockfile";
import { registrySrcPath, gitSrcPath } from "./package/cache";
import { globalImports } from "../checker/prelude";
import { drainPendingInstances } from "../checker/instantiate";
import { ResolveSection, DepsSection, defaultResolveSection, loadBuildConfig } from "./buildConfig";
import { evaluateComptimeBlocks } from "./meta/comptime";
import { expandMacros } from "./meta/expand";
import { CliOptions, Target } from "./options";
import { writeOutput, printTiming, verboseLog, replaceExt, ensureDir, exeSuffix, soSuffix, outDirForMode } from "./io";
import { compileCFile, linkObjects, archiveStatic, linkSolana, appendFlag, cliCompileFlags, cliLinkFlags, resolveBpfClang, resolveSbfLinker, markCppCompile, getCompilerName, resolveLto } from "./cc";
import { resolveCC } from "./toolchain";
import { linkFlags as globalLinkFlags, linkObjects as globalLinkObjects } from "../utils/linkState";
import { initCache, stableOFileFp, fullCompileCmd, isCompileCached, writeCompileCache, computeFingerprint, projectCacheChanged, writeProjectCache, stableCFileFp, isCCodeCached, writeCSource, moduleCompileFp, writeCompileFingerprintFp, invalidateCompileCache, isLinkCached, writeLinkCache, cacheDir, hashContent } from "./cache";
import { error, success, bold, dim, green, red, yellow, cyan, blue } from "../utils/color";
import { resolveRuntimeDir } from "../utils/path";
import { join, isAbsolute, dirname, basename, relative, normalize } from "std/fs/path";

// ===== Build Helpers =====

// Build ResolverConfig from CLI target + optional build.ms resolve section.

// Scan a DepsSection for file: entries, add as aliases, and recursively
// walk each dep's own build.ms to discover transitive file: deps.
// This handles A → B → C chains where each package's build.ms declares
// its own file: deps. The `visited` set prevents infinite loops on cycles.
function addFileDepAliases(deps: DepsSection, baseDir: string, config: ResolverConfig, visited: string[], depth: number = 0): void {
	if (depth > 20) return; // prevent runaway on deep non-cyclic trees
	let i = 0;
	while (i < deps.keys.length) {
		const name = deps.keys[i];
		const ver = deps.values[i];
		if (ver.length > 5 && ver.slice(0, 5) === "file:") {
			const relPath = ver.slice(5, ver.length);
			const absPath = isAbsolute(relPath) ? relPath : join(baseDir, relPath);
			// Skip if already registered (cycle prevention)
			let alreadyVisited = false;
			for (const v of visited) { if (v === absPath) alreadyVisited = true; }
			if (!alreadyVisited) {
				config.aliasKeys.push(name);
				config.aliasValues.push(absPath);
				visited.push(absPath);
				// Recursively read this dep's own build.ms for transitive file: deps
				const depBuildMs = join(absPath, "build.ms");
				if (exists(depBuildMs)) {
					const depCfg = loadBuildConfig(depBuildMs, false);
					if (depCfg.valid) {
						addFileDepAliases(depCfg.deps, absPath, config, visited, depth + 1);
						addFileDepAliases(depCfg.devDeps, absPath, config, visited, depth + 1);
					}
				}
			}
		}
		i = i + 1;
	}
}

export function buildResolverConfig(target: Target, resolve: ResolveSection, targetOs: string = platform, projectRoot: string = ""): ResolverConfig {
	let backend = Backend.C;
	if (target === Target.JS) { backend = Backend.JS; }
	if (target === Target.Raiser) { backend = Backend.Raiser; }
	if (targetOs === "wasm" || targetOs === "emcc") { backend = Backend.Wasm; }
	// Resolve stdPath from project root.
	const root = resolveRuntimeDir();
	const stdPath = root !== "" ? join(root, "std") : "std";
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
	// Package manager: if msc.lock exists in the project root, push cache paths
	// as aliases so bare imports resolve to cached packages.
	// projectRoot is found by walking up from CWD for build.ms (Go/Rust convention)
	// and passed in from the CLI entry point.
	// file: deps — resolve directly from build.ms without lockfile.
	// These are local folder references: "my-lib": "file:../my-lib"
	// Resolved relative to projectRoot. No cache, no download.
	if (projectRoot !== "") {
		const cfg = loadBuildConfig(join(projectRoot, "build.ms"), false);
		if (cfg.valid) {
			const visited: string[] = [];
			addFileDepAliases(cfg.deps, projectRoot, config, visited);
			addFileDepAliases(cfg.devDeps, projectRoot, config, visited);
		}
	}

	// Registry/git deps — resolve via lockfile → cache paths.
	const lockPath = projectRoot !== "" ? join(projectRoot, "msc.lock") : "msc.lock";
	const lock = readLockfile(lockPath);
	if (lock.valid) {
		for (const entry of lock.entries) {
			const name = entryName(entry.key);
			let srcPath = "";
			if (entry.source === "git" && entry.url !== "" && entry.commit !== "") {
				srcPath = gitSrcPath(entry.url, entry.commit);
			} else if (entry.version !== "") {
				srcPath = registrySrcPath(name, entry.version);
			}
			if (srcPath !== "") {
				config.aliasKeys.push(name);
				config.aliasValues.push(srcPath);
			}
		}
	}
	return config;
}

// Report graph-level errors (e.g., missing entry) and circular dep warnings.
function reportGraphErrors(graph: ModuleGraph): void {
	for (const err of graph.errors) {
		console.log(red("graph error: ") + err);
	}
	for (const dep of graph.circularDeps) {
		let circMsg = `circular import: ${dep.fromPath} <-> ${dep.toPath}`;
		if (dep.importLine > 0) {
			circMsg = circMsg + ` (line ${dep.importLine})`;
		}
		console.log(yellow("warning: ") + circMsg);
	}
}

// Get a specific line from source text (1-based line number)
function getSourceLine(source: string, lineNum: number): string {
	if (source.byteLength === 0 || lineNum <= 0) return "";
	const lines = source.split("\n");
	const idx = (lineNum as int32) - 1;
	if (idx < 0 || idx >= lines.length) return "";
	return lines[idx];
}

// Render a single structured error in Rust-style format
function renderModuleError(modPath: string, source: string, e: ModuleError): void {
	// Header: "error: message" or "warning: message"
	const isWarn = e.severity === ErrorSeverity.Warning;
	const levelStr = match (isWarn) {
		true => bold(yellow("warning")),
		false => bold(red("error")),
	};
	console.log(levelStr + ": " + bold(e.message));

	// Location: "  --> file:line:col"
	if (e.line > 0) {
		let locStr = `  ${bold(cyan("-->"))} ${modPath}:${e.line}`;
		if (e.column > 0) {
			locStr = `${locStr}:${e.column}`;
		}
		console.log(locStr);

		// Source line + caret
		const srcLine = getSourceLine(source, e.line);
		if (srcLine.byteLength > 0) {
			const lineNumStr = e.line.toString();
			const pad = "   ";
			// Separator: "   |"
			console.log(blue(pad + " |"));
			// Source:    "42 | source code here"
			console.log(blue(lineNumStr + " | ") + srcLine);
			// Caret:    "   |     ^^^"
			if (e.column > 0) {
				let caretPad = "";
				let ci = 0;
				while (ci < e.column - 1 && ci < 4096) {
					caretPad = caretPad + " ";
					ci = ci + 1;
				}
				console.log(blue(pad + " | ") + caretPad + green("^"));
			}
		}
	} else {
		// No line info — show file only
		console.log(`  ${bold(cyan("-->"))} ${modPath}`);
	}
	console.log("");
}

// Report per-module errors without exiting (for non-fatal type errors).
function reportModuleErrors(graph: ModuleGraph, prefix: string): void {
	for (const mod of graph.modules) {
		if (mod.errors.length > 0) {
			for (const e of mod.errors) {
				renderModuleError(mod.path, mod.source, e);
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
		if (e.severity !== Severity.Error) continue;
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
	for (const mod of graph.modules) {
		for (const e of mod.errors) {
			if (e.severity !== ErrorSeverity.Error) continue;
			hasErr = true;
			renderModuleError(mod.path, mod.source, e);
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

// Apply --gc flag: set GcMode on the shared prelude context so all modules inherit it.
// analyzeProgram checks ctx.gcMode and skips DRC injection for None/Manual.
export function applyGcMode(opts: CliOptions): void {
	if (graphPreludeCtx === null) return;
	if (opts.gcMode === "none") graphPreludeCtx.gcMode = GcMode.None;
	else if (opts.gcMode === "manual") graphPreludeCtx.gcMode = GcMode.Manual;
	else if (opts.gcMode === "orc") graphPreludeCtx.gcMode = GcMode.Orc;
	graphPreludeCtx.targetOs = opts.targetOs;
}

function loadAndCheckGraph(entryPath: string, verbose: boolean, config: ResolverConfig, targetOs: string = platform): ModuleGraph {
	if (verbose) verboseLog(`loading module graph from ${entryPath}`);
	const provider = createFileSystemProvider();

	// Load preludes FIRST so they end up at the start of graph.loadOrder.
	// loadOrder is the init order (see genProjectDispatcher in codegen/c/index.ms);
	// preludes are implicit deps of every user module, so their module-level
	// globals (e.g. INITIAL_CAPACITY in std/core/struct.ms) must be ready
	// before any user-module __Init000 touches them.
	const graph = createModuleGraph();
	if (config.stdPath !== "") {
		loadPreludeModules(graph, provider, config);
	}
	const _r = loadModule(graph, entryPath, provider, config, 1);

	reportGraphErrors(graph);
	exitOnModuleErrors(graph, "error");

	if (verbose) verboseLog("cross-module type check");
	const backendExt = config.extensions.length > 0 ? config.extensions[0] : ".cms";
	// Pass targetOs through so @platform("...") directives are filtered against
	// the build target during collectDirectives. Without this, modules check
	// with stale ctx.targetOs → mac directives leak into a cross-compile
	// windows build's linkFlags().
	graphRegistry = checkModuleGraph(graph, config.stdPath, backendExt, targetOs);
	graphPreludeCtx = getPreludeContext();
	reportModuleErrors(graph, "type error");
	// Standard reference parity (main.nim: `if conf.errorCounter > 0: return` before
	// cgenWriteModules): the gate lives in the shared funnel, so no command can reach
	// codegen with type errors. reportModuleErrors already rendered them — count only.
	let graphErrors = 0;
	for (const mod of graph.modules) {
		for (const e of mod.errors) {
			if (e.severity === ErrorSeverity.Error) graphErrors = graphErrors + 1;
		}
	}
	if (graphErrors > 0) {
		console.log(`${error("error")}: ${graphErrors} type error(s) found, stopping before codegen`);
		exit(1);
	}
	return graph;
}

// Load prelude modules (globalImports) into the module graph.
// Extension resolved by the resolver based on target backend.
function loadPreludeModules(graph: ModuleGraph, provider: SourceProvider, config: ResolverConfig): void {
	for (const imp of globalImports()) {
		const candidates = resolveImportWithConfig(imp, "virtual:prelude", config);
		for (const candidate of candidates) {
			if (provideSource(provider, candidate).ok) {
				if (!hasModule(graph, candidate)) {
					const _r = loadModule(graph, candidate, provider, config, 1);
				}
				break;
			}
		}
	}
}

// Parse source or exit with error message.
function parseOrExit(source: string, modPath: string): Node {
	const pr = parseSource(source);
	if (!pr.ok) {
		console.log(`${error("parse error")} [${modPath}]: ${pr.error}`);
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

// Build state for C compilation: flags + include path registry.
interface CBuildState {
	allFlags: string;
	includePaths: HashSet<string>;
}

// Dedupe on merge: many modules' @passC carry the same -I dirs (the crypto
// prelude chain repeats its 5 vendor dirs per importing module); appending
// them raw duplicated each dir hundreds of times until the cc command line
// crossed CreateProcessW's 32767-char ceiling — spawn then fails with a bare
// "fork/exec failed" (exit -1). Keep first occurrence, preserve order.
function mergeFlagsDeduped(base: string, add: string): string {
	if (add === "") return base;
	const seen: HashSet<string> = new HashSet<string>();
	for (const tok of base.split(" ")) {
		if (tok !== "") seen.add(tok);
	}
	let result = base;
	for (const tok of add.split(" ")) {
		if (tok === "") continue;
		if (seen.has(tok)) continue;
		seen.add(tok);
		result = appendFlag(result, tok);
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
	if (compilerRoot !== "") {
		includePaths.add(compilerRoot);
		allFlags = appendFlag(allFlags, `-I${compilerRoot}`);
	}
	// Project root is NOT added to global flags — it varies per project and
	// would invalidate ccache deduplication for stdlib compiles. Instead it is
	// passed as a per-module flag only for user-code modules (which actually
	// reference project-root-relative paths like `#include "src/foo.h"`). See
	// userProjectFlag() below and call sites in processCompileDirectives +
	// per-module .ms → .c compile.
	// --os=bare/solana: force-include manual.h before all .c files (runtime .c files need the defines)
	if ((opts.targetOs === "bare" || opts.targetOs === "solana") && compilerRoot !== "") {
		let defines = "-DMSOS_BARE";
		if (opts.targetOs === "solana") defines = "-DMSOS_SOLANA -DMSOS_BARE";
		allFlags = appendFlag(allFlags, `${defines} -include ${compilerRoot}/runtime/manual.h`);
	}
	// --os=wasm/emcc: define MSOS_WASM/MSOS_EMCC for runtime @compile files (disables threading)
	if (opts.targetOs === "wasm") {
		allFlags = appendFlag(allFlags, "-DMSOS_WASM");
	}
	if (opts.targetOs === "emcc") {
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
	if (dir === "" || path === "") return false;
	if (path === dir) return true;
	if (!path.startsWith(dir)) return false;
	// Require separator after prefix to avoid `/foo/bar` matching `/foo/barbaz`.
	const next = path.charAt(dir.length);
	return next === "/" || next === "\\";
}

function userProjectFlag(path: string, projectRoot: string, compilerRoot: string): string {
	if (projectRoot === "" || projectRoot === compilerRoot) return "";
	if (path === "" || path === ".") return "";
	if (isUnder(path, compilerRoot)) return "";
	return `-I${projectRoot}`;
}

// Resolve a relative directory path against the include search list.
// Mirrors @compile path resolution (processCompileDirectives): try CWD first,
// then search registered include paths (which contain compilerRoot).
function resolveIncludeDir(dir: string, includePaths: HashSet<string>): string {
	if (dir === "" || isAbsolute(dir)) return dir;
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
	if (flags === "") return flags;
	const parts = flags.split(" ");
	let result = "";
	for (const p of parts) {
		let resolved = p;
		if (p.length > 2 && p.slice(0, 2) === "-I") {
			resolved = "-I" + resolveIncludeDir(p.slice(2, p.length), includePaths);
		} else if (p.length > 7 && p.slice(0, 7) === "-iquote") {
			resolved = "-iquote" + resolveIncludeDir(p.slice(7, p.length), includePaths);
		} else if (p.length > 8 && p.slice(0, 8) === "-isystem") {
			resolved = "-isystem" + resolveIncludeDir(p.slice(8, p.length), includePaths);
		}
		result = result === "" ? resolved : `${result} ${resolved}`;
	}
	return result;
}

// Register -I/-iquote paths from a module's compiler flags into the include path set.
function registerIncludePaths(flags: string, paths: HashSet<string>): void {
	if (flags === "") return;
	const parts = flags.split(" ");
	for (const p of parts) {
		if (p.length > 2 && p.slice(0, 2) === "-I") paths.add(p.slice(2, p.length));
		else if (p.length > 7 && p.slice(0, 7) === "-iquote") paths.add(p.slice(7, p.length));
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
}

// Process @compile("foo.c") directives: compile each .c file to .o relative to module dir.
// Returns space-separated .o file paths to add to the link list.
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

function processCompileDirectives(directives: string, moduleDir: string, includePaths: HashSet<string>, allFlags: string, mode: number, ccOption: number, ccBinary: string, verbose: boolean, targetOs: string, projectRoot: string, compilerRoot: string): string {
	if (emitOnlyMode) return "";
	if (directives === "") return "";
	// Per-call user-project flag: non-empty only when moduleDir is user code.
	// Applied to every @compile job this call emits (all share same moduleDir).
	const upFlag = userProjectFlag(moduleDir, projectRoot, compilerRoot);

	// === 1. GATHER ===
	const jobs: CompileJob[] = [];
	const hitOFiles: string[] = [];
	let start = 0;
	let idx = 0;
	while (idx <= directives.length) {
		let atEnd = idx === directives.length;
		let atNewline = false;
		if (!atEnd) {
			atNewline = directives.slice(idx, idx + 1) === "\n";
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
				if (cPath.slice(0, 2) === "./" || cPath.slice(0, 3) === "../") {
					fullPath = `${moduleDir}/${cPath}`;
				} else if (!exists(fullPath)) {
					for (const dir of includePaths) {
						const candidate = `${dir}/${cPath}`;
						if (exists(candidate)) { fullPath = candidate; break; }
					}
				}
				if (!exists(fullPath)) {
					console.log(`${error("error")}: @compile cannot find: ${fullPath}`);
					exit(1);
				}
				// Mark C++ at directive-resolution time (main thread, sequential)
				// so the flag is set regardless of cache-hit / dedup / fresh-compile.
				// See cc.ms `markCppCompile` for the why.
				markCppCompile(fullPath);
				let probeFlags = allFlags;
				if (upFlag !== "") probeFlags = appendFlag(probeFlags, upFlag);
				if (customFlags !== "") probeFlags = appendFlag(probeFlags, customFlags);
				const probeKey = fullCompileCmd(ccOption, mode, probeFlags);
				const probeFp = computeFingerprint(fullPath, probeKey);
				const probeOFile = stableOFileFp(fullPath, probeFp);
				if (!_compiledOFiles.has(probeOFile)) {
					_compiledOFiles.add(probeOFile);
					const fileFlags = probeFlags;
					const cmdKey = probeKey;
					const fp = probeFp;
					const oFile = probeOFile;
					if (isCompileCached(oFile, fp)) {
						if (verbose) verboseLog(`  @compile ${fullPath} → ${oFile} ${dim("(cached)")}`);
						hitOFiles.push(oFile);
					} else {
						jobs.push({ fullPath, oFile, cPath, fileFlags, fp });
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
			let r = compileCFile(j.fullPath, j.oFile, j.fileFlags, mode, ccOption, ccBinary);
			if (!r.ok && r.error.exitCode === 0) {
				// exitCode 0 with !ok = the process never ran (posix_spawn failure,
				// e.g. transient EAGAIN under fork pressure from N parallel jobs).
				// One retry absorbs it; a real compile error has a nonzero exitCode
				// and is not retried.
				r = compileCFile(j.fullPath, j.oFile, j.fileFlags, mode, ccOption, ccBinary);
			}
			if (r.ok) return 0;
			// Surface the failure reason — the parallel path otherwise discards
			// stderr and the join loop only reports the exit code.
			if (r.error.errorOutput !== "") console.log(r.error.errorOutput);
			return r.error.exitCode !== 0 ? r.error.exitCode : -1;
		}));
	}
	const exitCodes: number[] = [];
	for (const f of futures) exitCodes.push(waitFor(f));

	// === 3. COLLECT (serial from main thread) ===
	let oFiles = "";
	for (const o of hitOFiles) oFiles = appendFlag(oFiles, o);
	let ci = 0;
	while (ci < jobs.length) {
		const j = jobs[ci];
		const code = exitCodes[ci];
		if (code !== 0) {
			if (targetOs === "solana") {
				console.log(`  ${dim("skip")} @compile ${j.cPath} ${dim("(BPF unsupported)")}`);
				ci = ci + 1;
				continue;
			}
			console.log(`${error("error")}: @compile failed for ${j.fullPath} ${dim(`(exit ${code})`)}`);
			exit(1);
		}
		writeCompileCache(j.oFile, j.fp);
		oFiles = appendFlag(oFiles, j.oFile);
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
			let r = compileCFile(j.cFile, j.oFile, j.flags, mode, ccOption, ccBinary);
			if (!r.ok && r.error.exitCode === 0) {
				// exitCode 0 with !ok = the process never ran (posix_spawn EAGAIN
				// under fork pressure). One retry absorbs it; real compile errors
				// have a nonzero exitCode and are not retried.
				r = compileCFile(j.cFile, j.oFile, j.flags, mode, ccOption, ccBinary);
			}
			if (r.ok) return 0;
			if (r.error.errorOutput !== "") console.log(r.error.errorOutput);
			return r.error.exitCode !== 0 ? r.error.exitCode : -1;
		}));
	}
	const codes: number[] = [];
	for (const f of futures) codes.push(waitFor(f));
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
		if (s.byteAt(i) === "\n".code) n += 1;
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
		const splitRoot = opts.outputPath !== "" ? opts.outputPath : (outputDir !== "" ? outputDir : "out/esm");
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
	setTargetSizes(8, 8);
	const config = buildResolverConfig(Target.JS, defaultResolveSection());
	const graph = loadAndCheckGraph(entryPath, opts.verbose, config, opts.targetOs);
	const outDir = outputDir !== "" ? outputDir : "out";
	// Project root for deriving module IDs
	const projectRoot = config.stdPath.length > 4 ? config.stdPath.slice(0, config.stdPath.length - 4) : dirname(entryPath);

	// Build import source → module ID mapping for all modules
	// This maps how modules reference each other (import specifier) to the __mod["id"] key
	const modIdValues: string[] = [];
	const modIdKeys: string[] = [];
	for (const modPath of graph.loadOrder) {
		const mod = findModule(graph, modPath);
		if (mod === null) continue;
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
		if (mod === null) continue;

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
				if (extImportKeys[ei] === entry.modulePath) {
					// Merge names
					for (const n of entry.names) {
						let dup = false;
						for (const existing of extImportNames[ei]) { if (existing === n) { dup = true; } }
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
		if (targetIdx < 0) {
			for (let pi: int32 = 0; pi < unitPaths.length; pi += 1) {
				if (unitPaths[pi] === entryPath) { targetIdx = pi; }
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
		if (mod === null) continue;
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
	const outPath = opts.outputPath !== ""
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
		const stdIgnored = ignoredFileIndexes(combined, (p: string): boolean => stdRootForMap !== "" && p.startsWith(stdRootForMap));
		writeOutput(`${outPath}.map`, toSourceMapJson(combined, basename(outPath), mapDirOf(outPath), readSourceText, stdIgnored));
		output = `${output}\n//# sourceMappingURL=${mapName}\n`;
	}
	writeOutput(outPath, output);
	console.log(success(`${compiled} module(s) bundled → ${bold(outPath)}`));
}

// Platform-specific runtime compile — dispatch + selectors + pool + fs.
// Returns the .o paths to append via appendFlag, or "" for bare / Solana.
// Shared by cmdBuildC and cmdTestC so test binaries link the same runtime.
function compilePlatformRuntime(includePaths: HashSet<string>, allFlags: string, opts: CliOptions): string {
	if (opts.targetOs === "bare" || opts.targetOs === "solana") return "";

	let rtFiles = "";
	if (opts.targetOs === "emcc") {
		// Single-threaded: Asyncify-based async. spawn/Actor not yet supported.
		rtFiles = "runtime/promise/dispatchEmcc.c";
	} else if (opts.targetOs === "wasm") {
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
		if (opts.targetOs === "windows") {
			rtFiles = rtFiles + "\n" + "runtime/fs/windows.c";
		} else {
			rtFiles = rtFiles + "\n" + "runtime/fs/posix.c";
		}
	}

	rtFiles = rtFiles + "\n" + "runtime/promise/drain.c";

	if (rtFiles === "") return "";
	return processCompileDirectives(rtFiles, ".", includePaths, allFlags, opts.mode, opts.ccCompiler, opts.ccBinary, opts.verbose, opts.targetOs, opts.projectRoot, resolveRuntimeDir());
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
	setTargetSizes(8, 8);
	const t0 = performance.now();
	resolveCC(opts);
	resolveLto(opts);
	const config = buildResolverConfig(Target.C, resolveSection, opts.targetOs, opts.projectRoot);
	setGraphCheckTiming(opts.showTime);
	const graph = loadAndCheckGraph(entryPath, opts.verbose, config, opts.targetOs);
	applyGcMode(opts);

	// Solana: resolve the SBF toolchain, force --gc=manual, force release mode.
	// Both halves come from Anza's platform-tools bundle — a stock LLVM will not
	// do, so the diagnostic points at the bundle rather than at a package manager.
	if (opts.targetOs === "solana") {
		if (opts.gcMode === "" || opts.gcMode === "drc" || opts.gcMode === "orc") opts.gcMode = "manual";
		if (opts.mode === 0) opts.mode = 1;
		if (opts.ccBinary === "") {
			const sbfClang = resolveBpfClang();
			if (sbfClang === "") {
				console.log(`${error("error")}: --os=solana requires a clang with the ${bold("sbf")} target registered`);
				console.log(`  System clang carries ${bold("bpf")}/${bold("bpfel")} (Linux kernel BPF) — a different ABI, not this.`);
				console.log(`  Install Anza platform-tools (${bold("cargo build-sbf")} fetches it to ~/.cache/solana),`);
				console.log(`  or point at one: ${bold("MSC_SBF_CLANG=/path/to/platform-tools/llvm/bin/clang")}`);
				exit(1);
			}
			opts.ccBinary = sbfClang;
		}
		if (resolveSbfLinker() === "") {
			console.log(`${error("error")}: --os=solana requires ${bold("ld.lld")} beside the SBF clang`);
			console.log(`  Expected it in the same platform-tools ${bold("llvm/bin")} directory.`);
			exit(1);
		}
	}

	// WASM: force release mode, use zig cc with wasm32-wasi target
	if (opts.targetOs === "wasm") {
		if (opts.mode === 0) opts.mode = 1;  // Release (smaller .wasm)
		setTargetSizes(4, 4);  // WASM32: 32-bit pointers and ints
	}

	// Emscripten (browser WASM): use emcc, 32-bit pointers
	if (opts.targetOs === "emcc") {
		if (opts.mode === 0) opts.mode = 1;  // Release (smaller .wasm)
		setTargetSizes(4, 4);  // WASM32: 32-bit pointers and ints
		opts.ccBinary = "emcc";  // emcc for compile + link
	}

	// Compute output binary path early for change detection
	let outBinary = opts.outputPath;
	if (outBinary === "") {
		const outDir = outDirForMode(opts.mode);
		ensureDir(outDir);
		const dynLib = opts.isHcr || opts.appMode === "lib";
		let suffix = dynLib ? soSuffix() : exeSuffix();
		// Use target OS suffix (works for both native + cross since targetOs always set).
		if (opts.targetOs === "windows") suffix = dynLib ? ".dll" : ".exe";
		if (opts.appMode === "staticlib") suffix = ".a";
		if (opts.targetOs === "solana") suffix = ".so";
		if (opts.targetOs === "wasm") suffix = ".wasm";
		if (opts.targetOs === "emcc") suffix = ".js";  // emcc outputs .js + .wasm pair
		outBinary = outDir + "/" + replaceExt(basename(entryPath), "") + suffix;
	}
	outBinary = normalize(outBinary);

	// Project-level cache: skip entire pipeline if nothing changed.
	// Reference-aligned: changeDetectedViaJsonBuildInstructions — early return before codegen.
	const allFlags0 = cliCompileFlags(opts);
	if (!projectCacheChanged(graph.loadOrder, outBinary, opts.ccCompiler, opts.mode, allFlags0)) {
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
	let oFiles = "";
	let totalCheckerErrors = 0;

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
		if (mod === null) {
			console.log(`${error("error")}: internal: module '${modPath}' is in loadOrder but missing from the graph — its code will be skipped`);
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
		if (reusedProgram !== null && reusedCtx !== null) {
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
		if (instNode.nodeType === null && instNode.resolvedSym !== null && instNode.resolvedSym.symbolType !== null) {
			instNode.nodeType = instNode.resolvedSym.symbolType;
		}
		let owner = "";
		if (instNode.resolvedSym !== null && instNode.resolvedSym.modulePath !== "") {
			owner = instNode.resolvedSym.modulePath;
		}
		let targetProgram: Node | null = null;
		if (owner !== "" && programByPath.has(owner)) {
			targetProgram = programByPath.get(owner);
		} else if (programByPath.has(entryPath)) {
			targetProgram = programByPath.get(entryPath);
		}
		if (targetProgram !== null) {
			(targetProgram.data as ProgramData).programStmts.push(instNode);
		}
	}

	// Phase A2 — mono → transform → analyze → lower, per module (instances now placed).
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
		const _tx0 = performance.now();
		const transformed = transformProgram(comptimeResolved, ctx, false);
		tXform = tXform + (performance.now() - _tx0);
		const nativeCtx = createTransformContextWithChecker(ctx);
		const _tr0 = performance.now();
		const typeRefined = refineTypes(transformed, nativeCtx, graphRegistry);
		tRefine = tRefine + (performance.now() - _tr0);
		const _tn0 = performance.now();
		const nativeTransformed = transformForNative(typeRefined, nativeCtx);
		tNative = tNative + (performance.now() - _tn0);
		const hcrResult = opts.isHcr ? liftHcrState(nativeTransformed, nativeCtx) : nativeTransformed;
		if (opts.gcMode === "none") ctx.gcMode = GcMode.None;
			else if (opts.gcMode === "manual") ctx.gcMode = GcMode.Manual;
			else if (opts.gcMode === "orc") ctx.gcMode = GcMode.Orc;
		ctx.targetOs = opts.targetOs;
		const _ta0 = performance.now();
		const preAnErrors = ctx.errors.length;
		const analyzed = analyzeProgram(hcrResult, ctx);
		if (ctx.errors.length > preAnErrors) {
			for (let ei = preAnErrors; ei < ctx.errors.length; ei += 1) {
				console.log(`${error("error")}: ${modPath}: ${ctx.errors[ei].message}`);
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
		console.log(`${error("error")}: ${totalCheckerErrors} type error(s) found, stopping before codegen`);
		exit(1);
	}

	const tB = performance.now();

	// Phase B: Compute DCE alive set on post-transform ASTs (reference-aligned)
	if (opts.verbose) verboseLog("computing alive set (post-transform DCE)");
	const aliveSet = computeAliveSet(transformedPrograms, transformedPaths, entryPath, false);
	// Release DCE input arrays — no longer needed after alive set computed.
	transformedPrograms = [];
	transformedPaths = [];

	if (opts.showTime) printTiming("phase B (DCE)", tB);
	const tC = performance.now();

	// Compile prelude @compile directives — unconditional.
	// These are C runtime files, not application code. The linker strips unused sections.
	// For Solana, processCompileDirectives already skips BPF-unsupported .c files.
	if (graphPreludeCtx !== null && graphPreludeCtx.compileDirectives !== "") {
		const preludeObjs = processCompileDirectives(graphPreludeCtx.compileDirectives, ".", includePaths, allFlags, opts.mode, opts.ccCompiler, opts.ccBinary, opts.verbose, opts.targetOs, opts.projectRoot, resolveRuntimeDir());
		oFiles = appendFlag(oFiles, preludeObjs);
	}

	// Platform-specific runtime: dispatch + selectors + pool + fs.
	const rtObjs = compilePlatformRuntime(includePaths, allFlags, opts);
	if (rtObjs !== "") oFiles = appendFlag(oFiles, rtObjs);

	// Phase C: Codegen + compile each module
	// Reset generic instance deduplication (first module to codegen wins).
	resetEmittedInstances();
	clearSkippedTypeInfos();
	let codegenTime = 0;
	let clangTime = 0;
	let compiled = 0;
	let modulesRecompiled = 0;
	const cd = cacheDir();
	// GATHER — codegen stays serial (emitted-instance dedup + hook ownership are
	// global codegen state); cache misses become parallel compile jobs. oSlots
	// preserves the serial path's .o link order: cache hits fill their slot
	// immediately, misses fill on compile success in COLLECT (failure leaves the
	// slot empty — the serial path also only appended on success).
	const oSlots: string[] = [];
	oSlots.push(oFiles);
	const cJobs: ModuleCompileJob[] = [];
	for (const p of processed) {
		// Module-level DCE: skip modules with zero alive symbols.
		// This prevents dead TypeInfo globals, init guards, and DatInit/Init functions
		// from being emitted — critical for BPF/contract targets where mutable globals are illegal.
		if (!aliveSetHasModule(aliveSet, p.modPath)) {
			if (opts.verbose) verboseLog(`  skip (dead) ${p.modPath}`);
			continue;
		}
		if (opts.verbose) verboseLog(`codegen ${p.modPath}`);

		const tCg = performance.now();
		const preCgErrors = p.ctx.errors.length;
		const cCode = generateCModule(p.program, p.ctx, p.modPath, aliveSet, false, opts.isHcr);
		codegenTime = codegenTime + (performance.now() - tCg);

		if (p.ctx.errors.length > preCgErrors) {
			for (let ei = preCgErrors; ei < p.ctx.errors.length; ei += 1) {
				console.log(`${error("error")}: ${p.modPath}: ${p.ctx.errors[ei].message}`);
			}
			exit(1);
		}

		// Process @compile("foo.c") directives
		const compileObjs = processCompileDirectives(p.ctx.compileDirectives, dirname(p.modPath), includePaths, allFlags, opts.mode, opts.ccCompiler, opts.ccBinary, opts.verbose, opts.targetOs, opts.projectRoot, resolveRuntimeDir());
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
			let modFlags = appendFlag(allFlags, `-iquote${dirname(p.modPath)}`);
			modFlags = appendFlag(modFlags, `-iquote${cd}`);
			// Per-module MS→.c: add -I<projectRoot> only for user modules (paths
			// under projectRoot, not under compilerRoot). Stdlib modules get
			// stable command text so ccache can dedupe across projects.
			const upFlag = userProjectFlag(p.modPath, opts.projectRoot, resolveRuntimeDir());
			if (upFlag !== "") modFlags = appendFlag(modFlags, upFlag);
			const compileCmd = fullCompileCmd(opts.ccCompiler, opts.mode, modFlags);
			const modFp = moduleCompileFp(cCode, compileCmd);
			const oFile = stableOFileFp(p.modPath, modFp);

			if (isCCodeCached(p.modPath, modFp)) {
				oSlots.push(oFile);
				if (opts.verbose) verboseLog(`  cached ${p.modPath}`);
			} else {
				// Write only .c source BEFORE compile (always — debuggable).
				// Defer fingerprint (.cfp) until after successful compile so a
				// failed zig cc doesn't leave a false cache hit for the next run.
				writeCSource(p.modPath, modFp, cCode);
				const cFile = stableCFileFp(p.modPath, modFp);
				if (opts.verbose) verboseLog(`  cc ${cFile} → ${oFile}`);
				oSlots.push("");
				cJobs.push({ cFile, oFile, modPath: p.modPath, flags: modFlags, fp: modFp, slot: oSlots.length - 1 });
				modulesRecompiled = modulesRecompiled + 1;
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
	if (opts.emitC) {
		// Also emit dispatcher (MsMain + entry point)
		const dispatcher = genProjectDispatcher(aliveModules, entryPath, opts.targetOs, opts.appMode === "lib" || opts.appMode === "staticlib");
		const emitDir = outDirForMode(opts.mode);
		const dispPath = `${emitDir}/_dispatch.c`;
		writeOutput(dispPath, dispatcher);
		console.log(`${green("  Wrote")} ${bold(dispPath)}`);
		console.log(success(`Emitted ${compiled + 1} C module(s)`));
		if (opts.showTime) printTiming("emitted", t0);
		return;
	}

	// Generate global init dispatcher and add it to the parallel batch (skip for
	// HCR — .so has no main). No .c cache for the dispatcher; it always compiles.
	// Its .o IS content-keyed though: two concurrent builds of different
	// configs (drc vs orc emit different teardown in the dispatcher TU) must
	// not rename over each other's object right before the other's link —
	// that linked an orc dispatcher into a drc build (undefined msOrcCollect).
	if (!opts.isHcr) {
		if (opts.verbose) verboseLog("generating dispatcher");
		const dispatcher = genProjectDispatcher(aliveModules, entryPath, opts.targetOs, opts.appMode === "lib" || opts.appMode === "staticlib");
		// The dispatcher TU is a fixed input to its compile job — its .c must be
		// fp-keyed and published atomically like any module's: two concurrent
		// builds with different entries/configs write different dispatcher C to
		// one fixed path otherwise, and the loser compiles the winner's dispatcher.
		const dispFp = moduleCompileFp(dispatcher, fullCompileCmd(opts.ccCompiler, opts.mode, allFlags));
		writeCSource("_dispatch", dispFp, dispatcher);
		const dispFile = stableCFileFp("_dispatch", dispFp);
		oSlots.push("");
		cJobs.push({ cFile: dispFile, oFile: stableOFileFp("_dispatch", dispFp), modPath: "", flags: allFlags, fp: "", slot: oSlots.length - 1 });
	}

	// DISPATCH + COLLECT — parallel cc over the runtime thread pool, publish
	// results in input order from the main thread. Dispatcher failure is fatal
	// (as before); module failures print and fall through to the linker so the
	// serial path's behavior is preserved.
	const tCl = performance.now();
	const cCodes = dispatchCompileJobs(cJobs, opts.mode, opts.ccCompiler, opts.ccBinary);
	clangTime = performance.now() - tCl;
	let moduleCompileFailed = false;
	let cji = 0;
	while (cji < cJobs.length) {
		const cj = cJobs[cji];
		const code = cCodes[cji];
		if (code === 0) {
			if (cj.fp !== "") writeCompileFingerprintFp(cj.modPath, cj.fp);
			oSlots[cj.slot] = cj.oFile;
		} else if (cj.modPath === "") {
			console.log(`${error("error")}: compile failed for dispatcher ${dim(`(exit ${code})`)}`);
			exit(1);
		} else {
			invalidateCompileCache(cj.modPath, cj.fp);
			if (opts.targetOs !== "solana") {
				console.log(`${error("error")}: compile failed for ${cj.modPath} ${dim(`(exit ${code})`)}`);
				moduleCompileFailed = true;
			}
		}
		cji = cji + 1;
	}
	if (moduleCompileFailed) exit(1);
	oFiles = "";
	for (const slot of oSlots) {
		if (slot !== "") oFiles = appendFlag(oFiles, slot);
	}

	// Link all .o files into final binary (or shared library for HCR)
	// Build link flags from global linkState (Set = deduplicated)
	let allLink = cliLinkFlags(allFlags, opts);
	for (const obj of globalLinkObjects()) { allLink = appendFlag(allLink, obj); }
	for (const flag of globalLinkFlags()) { allLink = appendFlag(allLink, flag); }
	let linkFlags = allLink;

	// Link cache: skip re-link if all modules hit .c cache and link flags unchanged
	if (modulesRecompiled === 0 && isLinkCached(oFiles, linkFlags, outBinary)) {
		if (opts.genDeps) {
			const depsDir = outDirForMode(opts.mode);
			ensureDir(depsDir);
			writeDepsFile(graph, entryPath, depsDir);
		}
		writeProjectCache(graph.loadOrder, outBinary, opts.ccCompiler, opts.mode, allFlags0);
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
	if (opts.targetOs === "emcc" && aliveSet.entries.length > 0) {
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
	if (opts.appMode === "staticlib") {
		const arRes = archiveStatic(oFiles, outBinary);
		if (!arRes.ok) {
			console.log(`${error("error")}: ar failed ${dim(`(exit ${arRes.error.exitCode})`)}`);
			if (arRes.error.errorOutput !== "") console.log(arRes.error.errorOutput);
			exit(1);
		}
	} else if (opts.targetOs === "solana") {
		const linkRes = linkSolana(oFiles, outBinary);
		if (!linkRes.ok) {
			console.log(`${error("error")}: SBF link failed ${dim(`(exit ${linkRes.error.exitCode})`)}`);
			if (linkRes.error.errorOutput !== "") console.log(linkRes.error.errorOutput);
			exit(1);
		}
	} else {
		const linkRes = linkObjects(oFiles, outBinary, linkFlags, opts.mode, opts.ccCompiler, opts.ccBinary);
		if (!linkRes.ok) {
			console.log(`${error("error")}: link failed ${dim(`(exit ${linkRes.error.exitCode})`)}`);
			if (linkRes.error.errorOutput !== "") console.log(linkRes.error.errorOutput);
			exit(1);
		}
	}

	// Persist link cache after successful link
	writeLinkCache(oFiles, linkFlags, outBinary);

	if (opts.genDeps) {
		const depsDir = outDirForMode(opts.mode);
		writeDepsFile(graph, entryPath, depsDir);
	}

	// Reference-aligned: writeJsonBuildInstructions — persist project cache after successful build
	writeProjectCache(graph.loadOrder, outBinary, opts.ccCompiler, opts.mode, allFlags0);

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
	setTargetSizes(8, 8);
	const t0 = performance.now();
	// Same compiler resolution as cmdBuildC: a test build emits and links C with
	// the same flags, so it needs the same --cc normalization and the same
	// LTO capability resolution once the compiler is known.
	resolveCC(opts);
	resolveLto(opts);
	const config = buildResolverConfig(Target.C, defaultResolveSection());
	const graph = loadAndCheckGraph(filePath, opts.verbose, config, opts.targetOs);

	// Phase A: Parse → Check → Mono → Transform → Analyze all modules
	const processed: ProcessedModule[] = [];
	const transformedPrograms: Node[] = [];
	const transformedPaths: string[] = [];
	const bs = initCBuildState(opts);
	let allFlags = bs.allFlags;
	const includePaths = bs.includePaths;
	let oFiles = "";

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
		if (mod === null) continue;
		// Same reuse as cmdBuildC: the graph-checker phase already ran the full
		// 3 passes and registered program+ctx. Re-checking here not only doubled
		// the build time, it dropped cross-module generic instances — those are
		// created once (instantiation is memoized), attached to the graph-check
		// program, and the discarded re-check never recreates them, so the owner
		// module's TU emits none of them.
		const reusedProgram = lookupModuleProgram(modPath);
		const reusedCtx = lookupModuleCtx(modPath);
		if (reusedProgram !== null && reusedCtx !== null) {
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
		if (instNode.nodeType === null && instNode.resolvedSym !== null && instNode.resolvedSym.symbolType !== null) {
			instNode.nodeType = instNode.resolvedSym.symbolType;
		}
		let owner = "";
		if (instNode.resolvedSym !== null && instNode.resolvedSym.modulePath !== "") {
			owner = instNode.resolvedSym.modulePath;
		}
		let targetProgram: Node | null = null;
		if (owner !== "" && programByPath.has(owner)) {
			targetProgram = programByPath.get(owner);
		} else if (programByPath.has(filePath)) {
			targetProgram = programByPath.get(filePath);
		}
		if (targetProgram !== null) {
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
		const typeRefined = refineTypes(transformed, nativeCtx, graphRegistry);
		const nativeTransformed = transformForNative(typeRefined, nativeCtx);
		const hcrResult = opts.isHcr ? liftHcrState(nativeTransformed, nativeCtx) : nativeTransformed;
		if (opts.gcMode === "none") ctx.gcMode = GcMode.None;
			else if (opts.gcMode === "manual") ctx.gcMode = GcMode.Manual;
			else if (opts.gcMode === "orc") ctx.gcMode = GcMode.Orc;
		ctx.targetOs = opts.targetOs;

		const preAnErrors = ctx.errors.length;
		const analyzed = analyzeProgram(hcrResult, ctx);
		if (ctx.errors.length > preAnErrors) {
			for (let ei = preAnErrors; ei < ctx.errors.length; ei += 1) {
				console.log(`${error("error")}: ${modPath}: ${ctx.errors[ei].message}`);
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
	const aliveSet = computeAliveSet(transformedPrograms, transformedPaths, filePath, true);

	// Compile prelude @compile directives — unconditional (reference-aligned: all @compile are always built)
	if (graphPreludeCtx !== null && graphPreludeCtx.compileDirectives !== "") {
		const preludeObjs = processCompileDirectives(graphPreludeCtx.compileDirectives, ".", includePaths, allFlags, opts.mode, opts.ccCompiler, opts.ccBinary, opts.verbose, opts.targetOs, opts.projectRoot, resolveRuntimeDir());
		oFiles = appendFlag(oFiles, preludeObjs);
	}

	// Platform-specific runtime: same set as cmdBuildC, shared via helper.
	const rtObjs = compilePlatformRuntime(includePaths, allFlags, opts);
	if (rtObjs !== "") oFiles = appendFlag(oFiles, rtObjs);

	// Phase C: Codegen + compile each module (per-module .c cache)
	// GATHER → DISPATCH → COLLECT, same shape as cmdBuildC. Test dispatcher
	// joins the batch; any failure exits after the batch is fully collected.
	resetEmittedInstances();
	clearSkippedTypeInfos();
	let compiled = 0;
	const tcd = cacheDir();
	const oSlots: string[] = [];
	oSlots.push(oFiles);
	const cJobs: ModuleCompileJob[] = [];
	for (const p of processed) {
		if (opts.verbose) verboseLog(`codegen ${p.modPath}`);

		const preCgErrors = p.ctx.errors.length;
		const cCode = generateCModule(p.program, p.ctx, p.modPath, aliveSet, true, opts.isHcr);

		if (p.ctx.errors.length > preCgErrors) {
			for (let ei = preCgErrors; ei < p.ctx.errors.length; ei += 1) {
				console.log(`${error("error")}: ${p.modPath}: ${p.ctx.errors[ei].message}`);
			}
			exit(1);
		}

		const compileObjs = processCompileDirectives(p.ctx.compileDirectives, dirname(p.modPath), includePaths, allFlags, opts.mode, opts.ccCompiler, opts.ccBinary, opts.verbose, opts.targetOs, opts.projectRoot, resolveRuntimeDir());
		oSlots.push(compileObjs);

		let testModFlags = appendFlag(allFlags, `-iquote${dirname(p.modPath)}`);
		testModFlags = appendFlag(testModFlags, `-iquote${tcd}`);
		const upFlag = userProjectFlag(p.modPath, opts.projectRoot, resolveRuntimeDir());
		if (upFlag !== "") testModFlags = appendFlag(testModFlags, upFlag);
		const compileCmd = fullCompileCmd(opts.ccCompiler, opts.mode, testModFlags);
		const modFp = moduleCompileFp(cCode, compileCmd);
		const oFile = stableOFileFp(p.modPath, modFp);

		if (isCCodeCached(p.modPath, modFp)) {
			oSlots.push(oFile);
			if (opts.verbose) verboseLog(`  cached ${p.modPath}`);
		} else {
			// Same as main path — defer fingerprint until success.
			writeCSource(p.modPath, modFp, cCode);
			const cFile = stableCFileFp(p.modPath, modFp);
			if (opts.verbose) verboseLog(`  cc ${cFile} → ${oFile}`);
			oSlots.push("");
			cJobs.push({ cFile, oFile, modPath: p.modPath, flags: testModFlags, fp: modFp, slot: oSlots.length - 1 });
		}
		compiled = compiled + 1;
	}

	// Generate test dispatcher (runs all module inits + test tables)
	if (opts.verbose) verboseLog("generating test dispatcher");
	const dispatcher = genTestDispatcher(graph.loadOrder, filePath);
	// Same concurrent-build rule as cmdBuildC's dispatcher: fp-keyed + atomic .c.
	const dispFp = moduleCompileFp(dispatcher, fullCompileCmd(opts.ccCompiler, opts.mode, allFlags));
	writeCSource("_test_dispatch", dispFp, dispatcher);
	const dispFile = stableCFileFp("_test_dispatch", dispFp);
	oSlots.push("");
	cJobs.push({ cFile: dispFile, oFile: stableOFileFp("_test_dispatch", dispFp), modPath: "", flags: allFlags, fp: "", slot: oSlots.length - 1 });

	const cCodes = dispatchCompileJobs(cJobs, opts.mode, opts.ccCompiler, opts.ccBinary);
	let testFailed = false;
	let cji = 0;
	while (cji < cJobs.length) {
		const cj = cJobs[cji];
		const code = cCodes[cji];
		if (code === 0) {
			if (cj.fp !== "") writeCompileFingerprintFp(cj.modPath, cj.fp);
			oSlots[cj.slot] = cj.oFile;
		} else if (cj.modPath === "") {
			console.log(`${error("error")}: compile failed for test dispatcher ${dim(`(exit ${code})`)}`);
			testFailed = true;
		} else {
			invalidateCompileCache(cj.modPath, cj.fp);
			console.log(`${error("error")}: compile failed for ${cj.modPath} ${dim(`(exit ${code})`)}`);
			testFailed = true;
		}
		cji = cji + 1;
	}
	if (testFailed) exit(1);
	oFiles = "";
	for (const slot of oSlots) {
		if (slot !== "") oFiles = appendFlag(oFiles, slot);
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
	for (const obj of globalLinkObjects()) { testLink = appendFlag(testLink, obj); }
	for (const flag of globalLinkFlags()) { testLink = appendFlag(testLink, flag); }
	const linkRes = linkObjects(oFiles, testBin, testLink, opts.mode, opts.ccCompiler, opts.ccBinary);
	if (!linkRes.ok) {
		console.log(`${error("error")}: link failed ${dim(`(exit ${linkRes.error.exitCode})`)}`);
		if (linkRes.error.errorOutput !== "") console.log(linkRes.error.errorOutput);
		exit(1);
	}

	if (opts.showTime) printTiming("compiled", t0);
	if (opts.verbose) verboseLog("running tests");
	const runCode = execFile(testBin);
	exit(runCode);
}

// ===== Run JS =====

function outRelForModule(modPath: string, projectRoot: string, stdRoot: string): string {
	if (stdRoot !== "" && modPath.startsWith(stdRoot)) {
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
		if (keys[i] === k) return vals[i];
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
	setTargetSizes(8, 8);
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
	let projectRoot = opts.projectRoot !== "" ? opts.projectRoot : dirname(filePath);
	if (!filePath.startsWith(projectRoot.endsWith("/") ? projectRoot : `${projectRoot}/`)) {
		projectRoot = dirname(filePath);
	}
	const outRoot = outRootOverride !== "" ? outRootOverride : `${projectRoot}/${outDirForMode(opts.mode)}`;
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
		if (mod === null) continue;

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
		if (targetIdx < 0) {
			for (let pi: int32 = 0; pi < unitPaths.length; pi += 1) {
				if (unitPaths[pi] === filePath) { targetIdx = pi; }
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
		if (mod === null) continue;
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
		exitOnCheckerErrors(ctx, modPath, mod !== null ? mod.source : "");

		const fromRel = lookupOutRel(outRelKeys, outRelVals, modPath);
		const importSpecKeys: string[] = [];
		const importSpecVals: string[] = [];
		if (mod !== null) {
			for (const imp of mod.imports) {
				const toRel = lookupOutRel(outRelKeys, outRelVals, imp.sourcePath);
				if (toRel === "") continue;
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
			if (vi === ui) continue;
			for (let mi = 0; mi < moduleNeededMods[vi].length; mi += 1) {
				if (moduleNeededMods[vi][mi] !== unitPaths[ui]) continue;
				for (const n of moduleNeededNames[vi][mi]) {
					let already = false;
					for (const e of moduleExported[ui]) { if (e === n) { already = true; } }
					for (const f of forced) { if (f === n) { already = true; } }
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
			const stdIgnored = ignoredFileIndexes(moduleSmaps[ui], (p: string): boolean => stdRoot !== "" && p.startsWith(stdRoot));
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
		if (tree.modulePaths[i] === filePath) entryRel = tree.moduleOutRels[i];
	}
	const entryJs = `${tree.outRoot}/${entryRel}`;
	if (opts.verbose) verboseLog(`exec node ${entryJs}`);
	const r = exec(`node ${entryJs}`);
	if (r.ok) {
		if (r.value !== "") console.log(r.value);
		exit(0);
	}
	if (r.error.output !== "") console.log(r.error.output);
	if (r.error.errorOutput !== "") console.log(r.error.errorOutput);
	exit(r.error.exitCode !== 0 ? r.error.exitCode : 1);
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
		"      try { ns[mod.funcs[i]](); testsPassed += 1; }",
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
		if (tree.testFuncs[i].length === 0) continue;
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
		if (r.value !== "") console.log(r.value);
		exit(0);
	}
	if (r.error.output !== "") console.log(r.error.output);
	if (r.error.errorOutput !== "") console.log(r.error.errorOutput);
	exit(r.error.exitCode !== 0 ? r.error.exitCode : 1);
}

// ===== Raiser (Bytecode VM) Run =====

export function cmdRunRaiser(filePath: string, opts: CliOptions): void {
	setTargetSizes(8, 8);
	const t0 = performance.now();
	const config = buildResolverConfig(Target.Raiser, defaultResolveSection());
	const graph = loadAndCheckGraph(filePath, opts.verbose, config, opts.targetOs);

	const modules: RaiserModuleInput[] = [];
	const entryCanonical = canonicalModulePath(filePath);
	for (const modPath of graph.loadOrder) {
		const mod = findModule(graph, modPath);
		if (mod === null) continue;

		if (opts.verbose) verboseLog("compiling " + modPath);
		const program = parseOrExit(mod.source, modPath);
		const modCtx = checkProgramWithRegistry(program, graphRegistry, graph, mod, graphPreludeCtx);
		exitOnFatalCheckerErrors(modCtx, modPath, mod.source);
		modCtx.errors = [];


		const macroExpanded = expandMacros(program, modCtx);
		exitOnCheckerErrors(modCtx, modPath, mod.source);
		const comptimeResolved = evaluateComptimeBlocks(macroExpanded);
		const txCtx = createTransformContextWithChecker(modCtx);
		const refined = refineTypes(comptimeResolved, txCtx, graphRegistry);
		const transformed = transformForRaiser(refined, modCtx);

		const input: RaiserModuleInput = { modulePath: modPath, program: transformed };
		modules.push(input);
	}

	if (opts.verbose) verboseLog(`generating bytecode (${modules.length} modules)`);
	const raiserMod = generateRaiserProject(modules);

	if (opts.showTime) printTiming("compiled", t0);

	const ctx = createRaiserContext();
	ctx.gcMode = "orc";
	raiserLoad(ctx, raiserMod);
	const ranOk = raiserExecute(ctx);

	if (ctx.lastOutput.length > 0) {
		// Print captured output (strip trailing newline for clean display)
		const lastOut = ctx.lastOutput;
		if (lastOut.byteLength > 0 && lastOut.slice(lastOut.byteLength - 1, lastOut.byteLength) === "\n") {
			console.log(lastOut.slice(0, lastOut.byteLength - 1));
		} else {
			console.log(lastOut);
		}
	}

	if (!ranOk && ctx.lastError !== "") {
		console.log(`${error("raiser runtime error")}: ${ctx.lastError}`);
	}
}

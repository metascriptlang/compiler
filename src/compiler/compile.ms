// MetaScript Compiler CLI — compile command

import { exit, exec, cmdExists, execFile } from "std/process";
import { exists } from "std/fs";
import { parseSource } from "../parser/statements/validation";
import { Node, ProgramData } from "../ast/node";
import { CheckerContext, GcMode, hasErrors, hasFatalErrors, errorCount } from "../checker/context";
import { checkProgramWithRegistry } from "../checker/checkPass";
import { checkModuleGraph, getPreludeContext } from "../checker/orchestrator";
import { ExportRegistry } from "../checker/context";
import { validateTypedAST } from "../checker/validate";
import { transformProgram } from "../transform/index";
import { analyzeProgram } from "../analyzer/index";
import { monomorphizeProgram } from "../monomorphize/collect";
import { generateJS, generateJSBundleModule } from "../codegen/js/jsgen";
import { generateRaiserProject, RaiserModuleInput } from "../codegen/raiser/rgen";
import { createContext as createRaiserContext, load as raiserLoad, execute as raiserExecute } from "../raiser/context";
import { generateCModule, genProjectDispatcher } from "../codegen/c/index";
import { resetEmittedInstances } from "../codegen/c/declarations";
import { aliveSetHasModule } from "../codegen/c/context";
import { genTestDispatcher } from "../codegen/c/test";
import { registerCoreParsers } from "../parser/statements/core";
import { computeAliveSet } from "../checker/reachability";
import { getSimpleTypeDesc } from "../codegen/c/types";
import { setTargetSizes, isAwaitable } from "../checker/types";
import { lookupSymbol } from "../checker/symbol";
import { transformForNative } from "../transform/native/index";
import { refineTypes } from "../transform/typeRefine";
import { lowerNativeAccess } from "../transform/native/nativeLower";
import { liftHcrState } from "../transform/native/hcrLift";
import { createTransformContextWithChecker, createNameSet } from "../transform/context";
import { setGlobalHookOwners } from "../transform/lowering/destructorLifting";
import { createModuleGraph, findModule, hasModule, ModuleGraph, ModuleError, ErrorSeverity } from "../module/graph";
import { createFileSystemProvider, loadModule, provideSource, SourceProvider } from "../module/loader";
import { ResolverConfig, createDefaultConfig, Backend, resolveImportWithConfig } from "../module/resolver";
import { readLockfile, entryName } from "./package/lockfile";
import { registrySrcPath, gitSrcPath } from "./package/cache";
import { globalImports } from "../checker/prelude";
import { drainPendingInstances } from "../checker/instantiate";
import { ResolveSection, DepsSection, defaultResolveSection, defaultCcSection, resolveCcForTarget, loadBuildConfig } from "./buildConfig";
import { evaluateComptimeBlocks } from "./meta/comptime";
import { expandMacros } from "./meta/expand";
import { CliOptions, Target } from "./options";
import { writeOutput, printTiming, verboseLog, replaceExt, ensureDir, getJSRuntime, exeSuffix, soSuffix, outDirForMode } from "./io";
import { compileCFile, linkObjects, linkSolana, appendFlag, cliCompileFlags, cliLinkFlags, resolveBpfClang, resolveSbpfLinker, effectiveOsTarget } from "./cc";
import { linkFlags as globalLinkFlags, linkObjects as globalLinkObjects } from "../utils/linkState";
import { initCache, stableOFile, fullCompileCmd, isCompileCached, writeCompileCache, computeFingerprint, projectCacheChanged, writeProjectCache, stableCFile, isCCodeCached, writeCCodeCache, isLinkCached, writeLinkCache, cacheDir } from "./cache";
import { error, success, bold, dim, green, red, yellow, cyan, blue } from "../utils/color";
import { resolveRuntimeDir } from "../utils/path";
import { join, isAbsolute, dirname, basename, relative } from "std/fs/path";

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

export function buildResolverConfig(target: Target, resolve: ResolveSection, osTarget: string = "", projectRoot: string = ""): ResolverConfig {
	let backend = Backend.C;
	if (target === Target.JS) { backend = Backend.JS; }
	if (target === Target.Raiser) { backend = Backend.Raiser; }
	if (osTarget === "wasm" || osTarget === "emcc") { backend = Backend.Wasm; }
	// Resolve stdPath from project root (handles both binary and Bun execution).
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
	let currentLine = 1;
	let lineStart = 0;
	let i = 0;
	while (i < source.byteLength) {
		if (currentLine === lineNum) {
			// Find end of this line
			let lineEnd = i;
			while (lineEnd < source.byteLength && source.slice(lineEnd, lineEnd + 1) !== "\n") {
				lineEnd = lineEnd + 1;
			}
			return source.slice(i, lineEnd);
		}
		if (source.slice(i, i + 1) === "\n") {
			currentLine = currentLine + 1;
		}
		i = i + 1;
	}
	return "";
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
				while (ci < e.column - 1) {
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

// Report per-module errors and exit if any found.
function exitOnModuleErrors(graph: ModuleGraph, prefix: string): void {
	let hasErr = false;
	for (const mod of graph.modules) {
		if (mod.errors.length > 0) {
			hasErr = true;
			for (const e of mod.errors) {
				renderModuleError(mod.path, mod.source, e);
			}
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
	if (opts.osTarget !== "") graphPreludeCtx.osTarget = opts.osTarget;
}

function loadAndCheckGraph(entryPath: string, verbose: boolean, config: ResolverConfig): ModuleGraph {
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
	graphRegistry = checkModuleGraph(graph, config.stdPath, backendExt);
	graphPreludeCtx = getPreludeContext();
	// Report type errors but continue — allows codegen to proceed past non-fatal checker issues
	reportModuleErrors(graph, "type error");
	// Per-module phase (line 476) skips warnings via Severity check — no clearing needed
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
	if ((opts.osTarget === "bare" || opts.osTarget === "solana") && compilerRoot !== "") {
		let defines = "-DMSOS_BARE";
		if (opts.osTarget === "solana") defines = "-DMSOS_SOLANA -DMSOS_BARE";
		allFlags = appendFlag(allFlags, `${defines} -include ${compilerRoot}/runtime/manual.h`);
	}
	// --os=wasm/emcc: define MSOS_WASM/MSOS_EMCC for runtime @compile files (disables threading)
	if (opts.osTarget === "wasm") {
		allFlags = appendFlag(allFlags, "-DMSOS_WASM");
	}
	if (opts.osTarget === "emcc") {
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
//      compileCFile() on its own thread. Under C backend this is real thread-
//      level parallelism; under Bun-hosted bootstrap the spawn polyfill
//      serializes (no speedup, still correct).
//   3. COLLECT (serial, main thread) — waitFor each future in input order, check
//      exit codes, publish cache entries, emit oFiles deterministically.
function processCompileDirectives(directives: string, moduleDir: string, includePaths: HashSet<string>, allFlags: string, mode: number, ccOption: number, ccBinary: string, verbose: boolean, osTarget: string, projectRoot: string, compilerRoot: string): string {
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
				const oFile = stableOFile(fullPath);
				if (!_compiledOFiles.has(oFile)) {
					_compiledOFiles.add(oFile);
					let fileFlags = allFlags;
					if (upFlag !== "") fileFlags = appendFlag(fileFlags, upFlag);
					if (customFlags !== "") fileFlags = appendFlag(fileFlags, customFlags);
					const cmdKey = fullCompileCmd(ccOption, mode, fileFlags);
					const fp = computeFingerprint(fullPath, cmdKey);
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
	const futures: Promise<number>[] = [];
	for (const j of jobs) {
		futures.push(spawn(() => {
			return compileCFile(j.fullPath, j.oFile, j.fileFlags, mode, ccOption, ccBinary);
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
			if (osTarget === "solana") {
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

export function cmdBuildJS(entryPath: string, outputDir: string, opts: CliOptions): void {
	registerCoreParsers();
	setTargetSizes(8, 8);
	const config = buildResolverConfig(Target.JS, defaultResolveSection());
	const graph = loadAndCheckGraph(entryPath, opts.verbose, config);
	const outDir = outputDir !== "" ? outputDir : "out";
	ensureDir(outDir);
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
		const comptimeResolved = evaluateComptimeBlocks(macroExpanded);
		const transformed = transformProgram(comptimeResolved, ctx, true);

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
		const result = generateJSBundleModule(transformed, localMapValues, localMapKeys, isPrelude);

		bundle = bundle + `\n// --- Module: ${moduleId} ---\n`;
		bundle = bundle + result.code;
		if (result.exportedNames.length > 0) {
			bundle = bundle + `__mod["${moduleId}"] = { `;
			for (let ei = 0; ei < result.exportedNames.length; ei += 1) {
				if (ei > 0) bundle = bundle + ", ";
				bundle = bundle + result.exportedNames[ei];
			}
			bundle = bundle + " };\n";
		}
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
	output = output + "const __mod = {};\n";
	output = output + bundle;

	const outPath = `${outDir}/${replaceExt(basename(entryPath), ".js")}`;
	writeOutput(outPath, output);
	console.log(success(`${compiled} module(s) bundled → ${bold(outPath)}`));
}

// Platform-specific runtime compile — dispatch + selectors + pool + fs.
// Returns the .o paths to append via appendFlag, or "" for bare / Solana.
// Shared by cmdBuildC and cmdTestC so test binaries link the same runtime.
function compilePlatformRuntime(includePaths: HashSet<string>, allFlags: string, opts: CliOptions): string {
	if (opts.osTarget === "bare" || opts.osTarget === "solana") return "";

	let rtFiles = "";
	if (opts.osTarget === "emcc") {
		// Single-threaded: Asyncify-based async. spawn/Actor not yet supported.
		rtFiles = "runtime/promise/dispatchEmcc.c";
	} else if (opts.osTarget === "wasm") {
		rtFiles = "runtime/promise/dispatchWasm.c";
	} else {
		// Desktop: full dispatcher + thread pool + selectors
		rtFiles = "runtime/promise/dispatchFull.c";
		rtFiles = rtFiles + "\n" + "runtime/promise/pool.c";
		rtFiles = rtFiles + "\n" + "runtime/promise/awaitGroup.c";
		rtFiles = rtFiles + "\n" + "runtime/promise/selectorKqueue.c";
		rtFiles = rtFiles + "\n" + "runtime/promise/selectorEpoll.c";
		rtFiles = rtFiles + "\n" + "runtime/promise/selectorPoll.c";
		if (effectiveOsTarget(opts.osTarget) === "windows") {
			rtFiles = rtFiles + "\n" + "runtime/fs/windows.c";
		} else {
			rtFiles = rtFiles + "\n" + "runtime/fs/posix.c";
		}
	}

	if (rtFiles === "") return "";
	return processCompileDirectives(rtFiles, ".", includePaths, allFlags, opts.mode, opts.ccCompiler, opts.ccBinary, opts.verbose, opts.osTarget, opts.projectRoot, resolveRuntimeDir());
}

// ===== C Build =====
// Loads module graph, two-pass separate compilation:
//   Pass 1: Collect exported prototypes from all modules
//   Pass 2: Full pipeline + codegen + per-module compile to .o
//   Link all .o files into final binary

export function cmdBuildC(entryPath: string, opts: CliOptions): void {
	initCache(opts.mode, opts.forceRebuild);
	resetCompiledOFiles();
	registerCoreParsers();
	setTargetSizes(8, 8);
	const t0 = performance.now();
	const config = buildResolverConfig(Target.C, defaultResolveSection(), opts.osTarget, opts.projectRoot);
	const graph = loadAndCheckGraph(entryPath, opts.verbose, config);
	applyGcMode(opts);

	// Solana: resolve BPF toolchain, force --gc=manual, force release mode
	if (opts.osTarget === "solana") {
		if (opts.gcMode === "" || opts.gcMode === "drc" || opts.gcMode === "orc") opts.gcMode = "manual";
		if (opts.mode === 0) opts.mode = 1;
		if (opts.ccBinary === "") {
			const bpfClang = resolveBpfClang();
			if (bpfClang === "") {
				console.log(`${error("error")}: --os=solana requires clang with BPF target support`);
				console.log(`  Install LLVM: ${bold("brew install llvm")} (macOS) or ${bold("apt install llvm")} (Linux)`);
				exit(1);
			}
			opts.ccBinary = bpfClang;
		}
		const sbpfLinker = resolveSbpfLinker();
		if (sbpfLinker === "") {
			console.log(`${error("error")}: --os=solana requires sbpf-linker`);
			console.log(`  Install: ${bold("cargo install sbpf-linker")}`);
			exit(1);
		}
	}

	// WASM: force release mode, use zig cc with wasm32-wasi target
	if (opts.osTarget === "wasm") {
		if (opts.mode === 0) opts.mode = 1;  // Release (smaller .wasm)
		setTargetSizes(4, 4);  // WASM32: 32-bit pointers and ints
	}

	// Emscripten (browser WASM): use emcc, 32-bit pointers
	if (opts.osTarget === "emcc") {
		if (opts.mode === 0) opts.mode = 1;  // Release (smaller .wasm)
		setTargetSizes(4, 4);  // WASM32: 32-bit pointers and ints
		opts.ccBinary = "emcc";  // emcc for compile + link
	}

	// Cross-compile: resolve compiler binary.
	// Default: "zig cc" (modern cross-compiler, bundled sysroots, no external deps).
	// Fallback: platform-specific cross-gcc (e.g. x86_64-w64-mingw32-gcc).
	// Override: --cc=<binary>
	if (opts.osTarget !== "" && opts.osTarget !== "bare" && opts.osTarget !== "solana" && opts.osTarget !== "emcc" && opts.ccBinary === "") {
		if (cmdExists("zig")) {
			opts.ccBinary = "zig cc";
		} else {
			const resolved = resolveCcForTarget(defaultCcSection(), opts.osTarget, opts.cpuTarget !== "" ? opts.cpuTarget : "amd64");
			if (resolved.compiler !== "") {
				opts.ccBinary = resolved.compiler;
			}
		}
	}

	// Compute output binary path early for change detection
	let outBinary = opts.outputPath;
	if (outBinary === "") {
		const outDir = outDirForMode(opts.mode);
		ensureDir(outDir);
		let suffix = opts.isHcr ? soSuffix() : exeSuffix();
		// Cross-compile: use target OS suffix, not host
		if (opts.osTarget === "windows") suffix = opts.isHcr ? ".dll" : ".exe";
		if (opts.osTarget === "solana") suffix = ".so";
		if (opts.osTarget === "wasm") suffix = ".wasm";
		if (opts.osTarget === "emcc") suffix = ".js";  // emcc outputs .js + .wasm pair
		outBinary = outDir + "/" + replaceExt(basename(entryPath), "") + suffix;
	}

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
	let hasUserMain = false;
	let mainRetType = "void";
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

	for (const modPath of graph.loadOrder) {
		const mod = findModule(graph, modPath);
		if (mod === null) continue;

		const modT0 = performance.now();
		if (opts.verbose) verboseLog(`transforming ${modPath}`);

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

		// Drain pending instances (reference parity: addCodeForGenerics at module close).
		const pendingInsts = drainPendingInstances();
		if (pendingInsts.length > 0) {
			const instPd = program.data as ProgramData;
			for (let ii = 0; ii < pendingInsts.length; ii += 1) {
				const instNode = pendingInsts[ii];
				if (instNode.nodeType === null && instNode.resolvedSym !== null && instNode.resolvedSym.symbolType !== null) {
					instNode.nodeType = instNode.resolvedSym.symbolType;
				}
				instPd.programStmts.push(instNode);
			}
		}
		const _tm0 = performance.now();
		const monoed = monomorphizeProgram(program, ctx);
		validateTypedAST(ctx, monoed);
		tMono = tMono + (performance.now() - _tm0);
		if (hasErrors(ctx)) {
			for (const e of ctx.errors) {
				renderModuleError(modPath, mod.source, {
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
		if (opts.osTarget !== "") ctx.osTarget = opts.osTarget;
		const _ta0 = performance.now();
		const analyzed = analyzeProgram(hcrResult, ctx);
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
		allFlags = appendFlag(allFlags, resolved);
		// @passL/@link go directly to global linkState — no per-module merge
		registerIncludePaths(resolved, includePaths);

		// Check for user main() in entry module
		if (modPath === entryPath && ctx !== null && ctx.table !== null) {
			const mainSym = lookupSymbol(ctx.table, "main");
			hasUserMain = mainSym !== null;
			if (mainSym !== null && mainSym.symbolType !== null && mainSym.symbolType.typeReturn !== null) {
				const retT = mainSym.symbolType.typeReturn;
				if (isAwaitable(retT)) {
					mainRetType = "msFuture_void*";
				} else {
					const ret = getSimpleTypeDesc(retT);
					if (ret !== "") mainRetType = ret;
				}
			}
		}
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
		const preludeObjs = processCompileDirectives(graphPreludeCtx.compileDirectives, ".", includePaths, allFlags, opts.mode, opts.ccCompiler, opts.ccBinary, opts.verbose, opts.osTarget, opts.projectRoot, resolveRuntimeDir());
		oFiles = appendFlag(oFiles, preludeObjs);
	}

	// Platform-specific runtime: dispatch + selectors + pool + fs.
	const rtObjs = compilePlatformRuntime(includePaths, allFlags, opts);
	if (rtObjs !== "") oFiles = appendFlag(oFiles, rtObjs);

	// Phase C: Codegen + compile each module
	// Reset generic instance deduplication (first module to codegen wins).
	resetEmittedInstances();
	let codegenTime = 0;
	let clangTime = 0;
	let compiled = 0;
	let modulesRecompiled = 0;
	const cd = cacheDir();
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
		const cCode = generateCModule(p.program, p.ctx, p.modPath, aliveSet, false, opts.isHcr);
		codegenTime = codegenTime + (performance.now() - tCg);

		// Process @compile("foo.c") directives
		const compileObjs = processCompileDirectives(p.ctx.compileDirectives, dirname(p.modPath), includePaths, allFlags, opts.mode, opts.ccCompiler, opts.ccBinary, opts.verbose, opts.osTarget, opts.projectRoot, resolveRuntimeDir());
		oFiles = appendFlag(oFiles, compileObjs);

		if (opts.emitC) {
			const emitDir = outDirForMode(opts.mode);
			ensureDir(emitDir);
			const relPath = relative(dirname(entryPath), p.modPath);
			const emitPath = `${emitDir}/${replaceExt(relPath, ".c")}`;
			ensureDir(dirname(emitPath));
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
			const oFile = stableOFile(p.modPath);

			if (isCCodeCached(p.modPath, cCode, compileCmd)) {
				oFiles = appendFlag(oFiles, oFile);
				if (opts.verbose) verboseLog(`  cached ${p.modPath}`);
			} else {
				writeCCodeCache(p.modPath, cCode, compileCmd);
				const cFile = stableCFile(p.modPath);
				if (opts.verbose) verboseLog(`  cc ${cFile} → ${oFile}`);
				const tCl = performance.now();
				const ccCode = compileCFile(cFile, oFile, modFlags, opts.mode, opts.ccCompiler, opts.ccBinary);
				clangTime = clangTime + (performance.now() - tCl);
				if (ccCode !== 0) {
					if (opts.osTarget !== "solana") {
						console.log(`${error("error")}: compile failed for ${p.modPath} ${dim(`(exit ${ccCode})`)}`);
					}
				} else {
					oFiles = appendFlag(oFiles, oFile);
				}
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
		const dispatcher = genProjectDispatcher(aliveModules, entryPath, hasUserMain, mainRetType, opts.osTarget);
		const emitDir = outDirForMode(opts.mode);
		const dispPath = `${emitDir}/_dispatch.c`;
		writeOutput(dispPath, dispatcher);
		console.log(`${green("  Wrote")} ${bold(dispPath)}`);
		console.log(success(`Emitted ${compiled + 1} C module(s)`));
		if (opts.showTime) printTiming("emitted", t0);
		return;
	}

	// Generate global init dispatcher and compile to .o (skip for HCR — .so has no main)
	if (!opts.isHcr) {
		if (opts.verbose) verboseLog("generating dispatcher");
		const dispatcher = genProjectDispatcher(aliveModules, entryPath, hasUserMain, mainRetType, opts.osTarget);
		const dispFile = `${cd}/_dispatch.c`;
		const dispObj = `${cd}/_dispatch.o`;
		writeOutput(dispFile, dispatcher);
		const dispCode = compileCFile(dispFile, dispObj, allFlags, opts.mode, opts.ccCompiler, opts.ccBinary);
		if (dispCode !== 0) {
			console.log(`${error("error")}: compile failed for dispatcher ${dim(`(exit ${dispCode})`)}`);

			exit(1);
		}
		oFiles = appendFlag(oFiles, dispObj);
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
	if (opts.osTarget === "emcc" && aliveSet.entries.length > 0) {
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
	if (opts.osTarget === "solana") {
		const linkCode = linkSolana(oFiles, outBinary);
		if (linkCode !== 0) {
			console.log(`${error("error")}: sbpf-linker failed ${dim(`(exit ${linkCode})`)}`);
			exit(1);
		}
	} else {
		const linkCode = linkObjects(oFiles, outBinary, linkFlags, opts.mode, opts.ccCompiler, opts.ccBinary);
		if (linkCode !== 0) {
			console.log(`${error("error")}: link failed ${dim(`(exit ${linkCode})`)}`);
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
	initCache(opts.mode, opts.forceRebuild);
	resetCompiledOFiles();
	registerCoreParsers();
	setTargetSizes(8, 8);
	const t0 = performance.now();
	const config = buildResolverConfig(Target.C, defaultResolveSection());
	const graph = loadAndCheckGraph(filePath, opts.verbose, config);

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


	for (const modPath of graph.loadOrder) {
		const mod = findModule(graph, modPath);
		if (mod === null) continue;

		if (opts.verbose) verboseLog(`transforming ${modPath}`);

		const program = parseOrExit(mod.source, modPath);
		const ctx = checkProgramWithRegistry(program, graphRegistry, graph, mod, graphPreludeCtx);
		ctx.strictDefs = opts.strictDefs;
		ctx.strictNullChecks = opts.strictNullChecks;
		exitOnFatalCheckerErrors(ctx, modPath, mod.source);
		ctx.errors = [];

		// Drain pending instances BEFORE monomorphize/transform — matches cmdBuildC
		// (line ~906). On-demand monomorphized methods (e.g. `hashMapRawGet<string,T>`)
		// must flow through monomorphize → expandMacros → transformProgram →
		// transformForNative just like static decls. Draining after transforms means
		// generic-instance bodies skip extensionMethodLower (UFCS `key.hash()` →
		// `hash(key)`) and operatorLower (string `==` → msStringEquals), producing
		// broken C with raw method calls and pointer comparisons.
		const pendingInsts = drainPendingInstances();
		if (pendingInsts.length > 0) {
			const instPd = program.data as ProgramData;
			for (const inst of pendingInsts) {
				if (inst.nodeType === null && inst.resolvedSym !== null && inst.resolvedSym.symbolType !== null) {
					inst.nodeType = inst.resolvedSym.symbolType;
				}
				instPd.programStmts.push(inst);
			}
		}

		const monoed = monomorphizeProgram(program, ctx);
		validateTypedAST(ctx, monoed);
		ctx.errors = [];

		const macroExpanded = expandMacros(monoed, ctx);
		const comptimeResolved = evaluateComptimeBlocks(macroExpanded);
		const transformed = transformProgram(comptimeResolved, ctx, false);
		const nativeCtx = createTransformContextWithChecker(ctx);
		const typeRefined = refineTypes(transformed, nativeCtx, graphRegistry);
		const nativeTransformed = transformForNative(typeRefined, nativeCtx);
		const hcrResult = opts.isHcr ? liftHcrState(nativeTransformed, nativeCtx) : nativeTransformed;
		if (opts.gcMode === "none") ctx.gcMode = GcMode.None;
			else if (opts.gcMode === "manual") ctx.gcMode = GcMode.Manual;
			else if (opts.gcMode === "orc") ctx.gcMode = GcMode.Orc;
		if (opts.osTarget !== "") ctx.osTarget = opts.osTarget;

		const analyzed = analyzeProgram(hcrResult, ctx);
		const nativeLowered = lowerNativeAccess(analyzed, nativeCtx);

		processed.push({ program: nativeLowered, ctx, modPath });
		transformedPrograms.push(nativeLowered);
		transformedPaths.push(modPath);

		const resolved = resolveIncludeFlags(ctx.compilerFlags, includePaths);
		allFlags = appendFlag(allFlags, resolved);
		// @passL/@link go directly to global linkState — no per-module merge
		registerIncludePaths(resolved, includePaths);
	}

	// Phase B: Compute DCE alive set on post-transform ASTs (reference-aligned)
	if (opts.verbose) verboseLog("computing alive set (post-transform DCE)");
	const aliveSet = computeAliveSet(transformedPrograms, transformedPaths, filePath, true);

	// Compile prelude @compile directives — unconditional (reference-aligned: all @compile are always built)
	if (graphPreludeCtx !== null && graphPreludeCtx.compileDirectives !== "") {
		const preludeObjs = processCompileDirectives(graphPreludeCtx.compileDirectives, ".", includePaths, allFlags, opts.mode, opts.ccCompiler, opts.ccBinary, opts.verbose, opts.osTarget, opts.projectRoot, resolveRuntimeDir());
		oFiles = appendFlag(oFiles, preludeObjs);
	}

	// Platform-specific runtime: same set as cmdBuildC, shared via helper.
	const rtObjs = compilePlatformRuntime(includePaths, allFlags, opts);
	if (rtObjs !== "") oFiles = appendFlag(oFiles, rtObjs);

	// Phase C: Codegen + compile each module (per-module .c cache)
	let compiled = 0;
	const tcd = cacheDir();
	for (const p of processed) {
		if (opts.verbose) verboseLog(`codegen ${p.modPath}`);

		const cCode = generateCModule(p.program, p.ctx, p.modPath, aliveSet, true, opts.isHcr);

		const compileObjs = processCompileDirectives(p.ctx.compileDirectives, dirname(p.modPath), includePaths, allFlags, opts.mode, opts.ccCompiler, opts.ccBinary, opts.verbose, opts.osTarget, opts.projectRoot, resolveRuntimeDir());
		oFiles = appendFlag(oFiles, compileObjs);

		let testModFlags = appendFlag(allFlags, `-iquote${dirname(p.modPath)}`);
		testModFlags = appendFlag(testModFlags, `-iquote${tcd}`);
		const upFlag = userProjectFlag(p.modPath, opts.projectRoot, resolveRuntimeDir());
		if (upFlag !== "") testModFlags = appendFlag(testModFlags, upFlag);
		const compileCmd = fullCompileCmd(opts.ccCompiler, opts.mode, testModFlags);
		const oFile = stableOFile(p.modPath);

		if (isCCodeCached(p.modPath, cCode, compileCmd)) {
			oFiles = appendFlag(oFiles, oFile);
			if (opts.verbose) verboseLog(`  cached ${p.modPath}`);
		} else {
			writeCCodeCache(p.modPath, cCode, compileCmd);
			const cFile = stableCFile(p.modPath);
			if (opts.verbose) verboseLog(`  cc ${cFile} → ${oFile}`);
			const ccCode = compileCFile(cFile, oFile, testModFlags, opts.mode, opts.ccCompiler, opts.ccBinary);
			if (ccCode !== 0) {
				console.log(`${error("error")}: compile failed for ${p.modPath} ${dim(`(exit ${ccCode})`)}`);
				exit(1);
			}
			oFiles = appendFlag(oFiles, oFile);
		}
		compiled = compiled + 1;
	}

	// Generate test dispatcher (runs all module inits + test tables)
	if (opts.verbose) verboseLog("generating test dispatcher");
	const dispatcher = genTestDispatcher(graph.loadOrder, filePath);
	const dispFile = `${tcd}/_test_dispatch.c`;
	const dispObj = `${tcd}/_test_dispatch.o`;
	writeOutput(dispFile, dispatcher);
	const dispCode = compileCFile(dispFile, dispObj, allFlags, opts.mode, opts.ccCompiler, opts.ccBinary);
	if (dispCode !== 0) {
		console.log(`${error("error")}: compile failed for test dispatcher ${dim(`(exit ${dispCode})`)}`);

		exit(1);
	}
	oFiles = appendFlag(oFiles, dispObj);

	// Link and execute
	ensureDir("out/debug");
	const testBin = "out/debug/_test_" + replaceExt(basename(filePath), "");
	let testLink = allFlags;
	for (const obj of globalLinkObjects()) { testLink = appendFlag(testLink, obj); }
	for (const flag of globalLinkFlags()) { testLink = appendFlag(testLink, flag); }
	const linkCode = linkObjects(oFiles, testBin, testLink, opts.mode, opts.ccCompiler, opts.ccBinary);
	if (linkCode !== 0) {
		console.log(`${error("error")}: link failed ${dim(`(exit ${linkCode})`)}`);

		exit(1);
	}

	if (opts.showTime) printTiming("compiled", t0);
	if (opts.verbose) verboseLog("running tests");
	const runCode = execFile(testBin);
	exit(runCode);
}

// ===== Run JS =====

export function cmdRunJS(filePath: string, opts: CliOptions): void {
	setTargetSizes(8, 8);
	const t0 = performance.now();
	const config = buildResolverConfig(Target.JS, defaultResolveSection());
	const graph = loadAndCheckGraph(filePath, opts.verbose, config);

	const outDir = "out/debug";
	ensureDir(outDir);
	const baseDir = dirname(filePath);

	// Compile each module to JS in out/debug/
	for (const modPath of graph.loadOrder) {
		const mod = findModule(graph, modPath);
		if (mod === null) continue;

		if (opts.verbose) verboseLog("compiling " + modPath);

		const program = parseOrExit(mod.source, modPath);
		const ctx = checkProgramWithRegistry(program, graphRegistry, graph, mod, graphPreludeCtx);
		exitOnFatalCheckerErrors(ctx, modPath, mod.source);
		ctx.errors = [];

		const macroExpanded = expandMacros(program, ctx);
		const comptimeResolved = evaluateComptimeBlocks(macroExpanded);
		const transformed = transformProgram(comptimeResolved, ctx, true);
		const jsCode = generateJS(transformed, ctx.jsImportRegistry);

		const relPath = relative(baseDir, modPath);
		const outPath = outDir + "/" + replaceExt(relPath, ".js");
		ensureDir(dirname(outPath));
		writeOutput(outPath, jsCode);
	}

	if (opts.showTime) printTiming("compiled", t0);

	// Execute entry module
	const entryRel = relative(baseDir, filePath);
	const entryJs = `${outDir}/${replaceExt(entryRel, ".js")}`;
	if (opts.verbose) verboseLog(`exec ${getJSRuntime()} ${entryJs}`);
	const code = exec(`${getJSRuntime()} ${entryJs}`);
	exit(code);
}

// ===== Raiser (Bytecode VM) Run =====
// Loads module graph, parse-only per module (no checker/transforms — Raiser VM is dynamically typed),
// compiles to bytecode via generateRaiserProject, executes in-process.

export function cmdRunRaiser(filePath: string, opts: CliOptions): void {
	setTargetSizes(8, 8);
	const t0 = performance.now();
	const config = buildResolverConfig(Target.Raiser, defaultResolveSection());
	const graph = loadAndCheckGraph(filePath, opts.verbose, config);

	// Parse each module → RaiserModuleInput (topological order)
	const modules: RaiserModuleInput[] = [];
	for (const modPath of graph.loadOrder) {
		const mod = findModule(graph, modPath);
		if (mod === null) continue;

		if (opts.verbose) verboseLog("parsing " + modPath);
		const program = parseOrExit(mod.source, modPath);
		const input: RaiserModuleInput = { modulePath: modPath, program };
		modules.push(input);
	}

	if (opts.verbose) verboseLog(`generating bytecode (${modules.length} modules)`);
	const raiserMod = generateRaiserProject(modules, null as unknown as CheckerContext);

	if (opts.showTime) printTiming("compiled", t0);

	const ctx = createRaiserContext();
	raiserLoad(ctx, raiserMod);
	raiserExecute(ctx);

	if (ctx.lastOutput.length > 0) {
		// Print captured output (strip trailing newline for clean display)
		const lastOut = ctx.lastOutput;
		if (lastOut.byteLength > 0 && lastOut.slice(lastOut.byteLength - 1, lastOut.byteLength) === "\n") {
			console.log(lastOut.slice(0, lastOut.byteLength - 1));
		} else {
			console.log(lastOut);
		}
	}
}

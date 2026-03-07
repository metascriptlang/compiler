// MetaScript Compiler CLI — compile command

import { exit, exec } from "std/process";
import { parseSource } from "../parser/statements/validation";
import { Node, NodeKind, ProgramData } from "../ast/node";
import { CheckerContext, hasErrors, hasFatalErrors, errorCount } from "../checker/context";
import { checkProgramWithRegistry } from "../checker/checkPass";
import { checkModuleGraph, getPreludeContext } from "../checker/index";
import { ExportRegistry } from "../checker/context";
import { validateTypedAST } from "../checker/validate";
import { transformProgram } from "../transform/index";
import { analyzeProgram } from "../analyzer/index";
import { monomorphizeProgram } from "../monomorphize/collect";
import { generateJS } from "../codegen/js/index";
import { generateRaiserProject, RaiserModuleInput } from "../codegen/raiser/rgen";
import { RaiserContext, createContext as createRaiserContext, load as raiserLoad, execute as raiserExecute } from "../raiser/context";
import { generateCModule, genProjectDispatcher } from "../codegen/c/index";
import { genTestDispatcher } from "../codegen/c/test";
import { registerCoreParsers } from "../parser/statements/core";
import { AliveSet, createAliveSet } from "../codegen/c/context";
import { computeAliveSet } from "../checker/reachability";
import { getSimpleTypeDesc } from "../codegen/c/types";
import { setTargetSizes } from "../checker/types";
import { lookupSymbol } from "../checker/symbol";
import { transformForNative } from "../transform/native/index";
import { refineTypes } from "../transform/typeRefine";
import { lowerNativeAccess } from "../transform/native/nativeLower";
import { liftHcrState } from "../transform/native/hcrLift";
import { createTransformContextWithChecker } from "../transform/context";
import { findModule, ModuleGraph } from "../module/graph";
import { createFileSystemProvider, loadModuleGraphWithConfig } from "../module/loader";
import { ResolverConfig, createDefaultConfig, BACKEND_C, BACKEND_JS, BACKEND_RAISER } from "../module/resolver";
import { ResolveSection, defaultResolveSection } from "./buildConfig";
import { evaluateComptimeBlocks } from "./comptime";
import { CliOptions, Target, MODE_DEBUG, MODE_RELEASE } from "./options";
import { readSource, writeOutput, printErrorsAndExit, printTiming, verboseLog, replaceExt, dirName, baseName, stripBase, ensureDir, getJSRuntime, exeSuffix, soSuffix, outDirForMode } from "./io";
import { compileC, compileCFile, linkObjects, appendFlag, cliCompileFlags, cliLinkFlags } from "./cc";
import { preprocessHeaders } from "../module/aro";
import { error, success, bold, dim, green, red, yellow, cyan } from "../utils/color";
import { clockMs } from "std/process";

// ===== Multi-Module Helpers =====

// Build ResolverConfig from CLI target + optional build.ms resolve section.
export function buildResolverConfig(target: Target, resolve: ResolveSection): ResolverConfig {
	let backend = BACKEND_C;
	if (target === Target.JS) { backend = BACKEND_JS; }
	if (target === Target.Raiser) { backend = BACKEND_RAISER; }
	// Default stdPath to "std" (relative to CWD). Future: MSC_STD_PATH env var.
	const config = createDefaultConfig(backend, "std");
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
	return config;
}

// Report graph-level errors (e.g., missing entry) and circular dep warnings.
function reportGraphErrors(graph: ModuleGraph): void {
	for (const err of graph.errors) {
		console.log(red("graph error: ") + err);
	}
	for (const dep of graph.circularDeps) {
		let circMsg = "circular import: " + dep.fromPath + " <-> " + dep.toPath;
		if (dep.importLine > 0) {
			circMsg = circMsg + " (line " + dep.importLine.toString() + ")";
		}
		console.log(yellow("warning: ") + circMsg);
	}
}

// Report per-module errors without exiting (for non-fatal type errors).
function reportModuleErrors(graph: ModuleGraph, prefix: string): void {
	for (let i = 0; i < graph.modules.length; i += 1) {
		const mod = graph.modules[i];
		if (mod.errors.length > 0) {
			for (const e of mod.errors) {
				console.log(red(prefix) + " [" + mod.path + "]: " + e);
			}
		}
	}
}

// Abort build if checker found fatal errors (e.g. assert outside test block).
// Standard reference equivalent: globalError raises recoverable error.
function exitOnFatalCheckerErrors(ctx: CheckerContext, modPath: string): void {
	if (!hasFatalErrors(ctx)) return;
	for (const e of ctx.errors) {
		if (e.fatal) {
			const loc = e.line > 0 ? ":" + e.line + ":" + e.column : "";
			console.log(red("fatal error") + " [" + modPath + loc + "]: " + e.message);
		}
	}
	exit(1);
}

// Report per-module errors and exit if any found.
function exitOnModuleErrors(graph: ModuleGraph, prefix: string): void {
	let hasErr = false;
	for (let i = 0; i < graph.modules.length; i += 1) {
		const mod = graph.modules[i];
		if (mod.errors.length > 0) {
			hasErr = true;
			for (const e of mod.errors) {
				console.log(red(prefix) + " [" + mod.path + "]: " + e);
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

function loadAndCheckGraph(entryPath: string, verbose: boolean, config: ResolverConfig): ModuleGraph {
	if (verbose) verboseLog("loading module graph from " + entryPath);
	const provider = createFileSystemProvider();
	const graph = loadModuleGraphWithConfig(entryPath, provider, config);
	reportGraphErrors(graph);
	exitOnModuleErrors(graph, "error");

	// Pre-process C header modules (ARO parse with import-name synthesis fallback)
	preprocessHeaders(graph, verbose);

	if (verbose) verboseLog("cross-module type check");
	graphRegistry = checkModuleGraph(graph, config.stdPath);
	graphPreludeCtx = getPreludeContext();
	// Report type errors but continue — allows codegen to proceed past non-fatal checker issues
	reportModuleErrors(graph, "type error");
	return graph;
}

// Global alive set for DCE — computed by computeProjectAliveSet, passed to each module's CGen.
let protoAliveSet: AliveSet = createAliveSet();

// Lightweight pass: parse + check + monomorphize all modules, then compute global DCE alive set.
// No type emission or proto header — each module is self-contained (reference parity).
function computeProjectAliveSet(graph: ModuleGraph, entryPath: string, isTest: boolean): AliveSet {
	const monoed_programs: Node[] = [];
	const monoed_paths: string[] = [];
	for (const modPath of graph.loadOrder) {
		const mod = findModule(graph, modPath);
		if (mod === null) continue;
		if (mod.isCHeader) continue;
		const pr = parseSource(mod.source);
		if (!pr.ok) continue;
		const ctx = checkProgramWithRegistry(pr.value, graphRegistry, graph, mod, graphPreludeCtx);
		exitOnFatalCheckerErrors(ctx, modPath);
		ctx.errors = [];
		const monoed = monomorphizeProgram(pr.value, ctx);
		monoed_programs.push(monoed);
		monoed_paths.push(modPath);
	}
	return computeAliveSet(monoed_programs, monoed_paths, entryPath, isTest);
}

// Counter for unique @compile .o filenames across modules.
let compileObjCount = 0;

// Process @compile("foo.c") directives: compile each .c file to .o relative to module dir.
// Returns space-separated .o file paths to add to the link list.
function processCompileDirectives(directives: string, moduleDir: string, allFlags: string, mode: number, ccOption: number, verbose: boolean): string {
	if (directives === "") return "";
	let oFiles = "";
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
				const cPath = directives.slice(start, idx);
				// Resolve relative to the declaring module's directory
				const fullPath = moduleDir + "/" + cPath;
				const oFile = "/tmp/_msc_compile_" + compileObjCount + ".o";
				compileObjCount = compileObjCount + 1;
				if (verbose) verboseLog("  @compile " + fullPath + " → " + oFile);
				const ccCode = compileCFile(fullPath, oFile, allFlags, mode, ccOption);
				if (ccCode !== 0) {
					console.log(error("error") + ": @compile failed for " + fullPath + " " + dim("(exit " + ccCode + ")"));
					exit(1);
				}
				oFiles = appendFlag(oFiles, oFile);
			}
			start = idx + 1;
		}
		idx = idx + 1;
	}
	return oFiles;
}

// Auto-compile companion .c files for .h imports.
// For each .h module in the graph, checks if a .c file exists at the same path.
// If so, compiles it to .o and returns accumulated object file paths.
function compileHeaderCompanions(graph: ModuleGraph, allFlags: string, mode: number, ccOption: number, verbose: boolean): string {
	let oFiles = "";
	for (let i = 0; i < graph.loadOrder.length; i += 1) {
		const modPath = graph.loadOrder[i];
		const mod = findModule(graph, modPath);
		if (mod === null || !mod.isCHeader) continue;
		// lib.h → lib.c
		const cPath = mod.path.slice(0, mod.path.length - 2) + ".c";
		if (exec("test -f " + cPath) === 0) {
			const oFile = "/tmp/_msc_hcompanion_" + i + ".o";
			if (verbose) verboseLog("  companion " + cPath + " → " + oFile);
			const ccCode = compileCFile(cPath, oFile, allFlags, mode, ccOption);
			if (ccCode !== 0) {
				console.log(error("error") + ": companion compile failed for " + cPath + " " + dim("(exit " + ccCode + ")"));
				exit(1);
			}
			oFiles = appendFlag(oFiles, oFile);
		}
	}
	return oFiles;
}

// ===== Dependency File Output =====

function writeDepsFile(graph: ModuleGraph, entryPath: string, outDir: string): void {
	let depsContent = "";
	for (const modPath of graph.loadOrder) {
		depsContent = depsContent + modPath + "\n";
	}
	const depsPath = outDir + "/" + replaceExt(baseName(entryPath), ".deps");
	writeOutput(depsPath, depsContent);
	console.log(dim("  wrote deps → " + depsPath));
}

// ===== Change Detection =====

function needsRebuild(graph: ModuleGraph, outputBinary: string): boolean {
	if (exec("test -f " + outputBinary) !== 0) return true;
	for (let i = 0; i < graph.loadOrder.length; i += 1) {
		if (exec("test " + graph.loadOrder[i] + " -nt " + outputBinary) === 0) return true;
	}
	return false;
}

// ===== Multi-Module JS Build =====

export function cmdBuildJS(entryPath: string, outputDir: string, opts: CliOptions): void {
	registerCoreParsers();
	setTargetSizes(8, 8);
	const config = buildResolverConfig(Target.JS, defaultResolveSection());
	const graph = loadAndCheckGraph(entryPath, opts.verbose, config);
	const outDir = outputDir !== "" ? outputDir : "out/debug";
	ensureDir(outDir);
	const baseDir = dirName(entryPath);

	// Compile each module to JS
	let compiled = 0;
	for (let i = 0; i < graph.loadOrder.length; i += 1) {
		const modPath = graph.loadOrder[i];
		const mod = findModule(graph, modPath);
		if (mod === null) continue;
		if (mod.isCHeader) continue;

		// Parse
		const pr = parseSource(mod.source);
		if (!pr.ok) {
			console.log(error("parse error") + " [" + modPath + "]: " + pr.error);
			exit(1);
		}

		// Check (cross-module registry for proper import type resolution)
		const ctx = checkProgramWithRegistry(pr.value, graphRegistry, graph, mod, graphPreludeCtx);
		exitOnFatalCheckerErrors(ctx, modPath);
		ctx.errors = [];

		// Validate metadata before transform
		validateTypedAST(ctx, pr.value);
		ctx.errors = [];

		// Evaluate @comptime blocks before transforms
		const comptimeResolved = evaluateComptimeBlocks(pr.value);

		// Transform (JS backend — skip C-specific transforms, no monomorphize needed)
		const transformed = transformProgram(comptimeResolved, ctx, true);

		// Generate JS
		const jsCode = generateJS(transformed);

		// Write output to out/debug/ preserving relative structure
		const relPath = stripBase(modPath, baseDir);
		const outPath = outDir + "/" + replaceExt(relPath, ".js");
		ensureDir(dirName(outPath));
		writeOutput(outPath, jsCode);
		console.log(green("  Wrote") + " " + bold(outPath));
		compiled = compiled + 1;
	}

	if (opts.genDeps) writeDepsFile(graph, entryPath, outDir);
	console.log(success(compiled + " module(s) compiled to JS"));
}

// ===== Multi-Module C Build =====
// Loads module graph, two-pass separate compilation:
//   Pass 1: Collect exported prototypes from all modules
//   Pass 2: Full pipeline + codegen + per-module compile to .o
//   Link all .o files into final binary

export function cmdBuildC(entryPath: string, opts: CliOptions): void {
	registerCoreParsers();
	setTargetSizes(8, 8);
	const t0 = clockMs();
	const config = buildResolverConfig(Target.C, defaultResolveSection());
	const graph = loadAndCheckGraph(entryPath, opts.verbose, config);

	// Compute output binary path early for change detection
	let outBinary = opts.outputPath;
	if (outBinary === "") {
		const outDir = outDirForMode(opts.mode);
		ensureDir(outDir);
		const suffix = opts.isHcr ? soSuffix() : exeSuffix();
		outBinary = outDir + "/" + replaceExt(baseName(entryPath), "") + suffix;
	}

	// Change detection: skip if all sources are older than binary
	if (!opts.forceRebuild && !needsRebuild(graph, outBinary)) {
		console.log(success("Up to date") + " " + bold(outBinary));
		if (opts.genDeps) {
			const depsDir = outDirForMode(opts.mode);
			ensureDir(depsDir);
			writeDepsFile(graph, entryPath, depsDir);
		}
		return;
	}

	// Pass 1: Compute global DCE alive set (lightweight parse+check+mono pass)
	if (opts.verbose) verboseLog("computing alive set for DCE");
	protoAliveSet = computeProjectAliveSet(graph, entryPath, false);

	// Pass 2: Full pipeline + codegen + per-module compile to .o
	let hasUserMain = false;
	let mainRetType = "void";
	let allFlags = cliCompileFlags(opts);
	let oFiles = "";
	let compiled = 0;

	// Auto-compile companion .c files for .h imports
	const companionObjs = compileHeaderCompanions(graph, allFlags, opts.mode, opts.ccCompiler, opts.verbose);
	oFiles = appendFlag(oFiles, companionObjs);

	for (let i = 0; i < graph.loadOrder.length; i += 1) {
		const modPath = graph.loadOrder[i];
		const mod = findModule(graph, modPath);
		if (mod === null) continue;
		// Skip C header modules — prototypes come from @include, symbols from @link
		if (mod.isCHeader) continue;

		if (opts.verbose) verboseLog("compiling " + modPath);

		// Parse
		const pr = parseSource(mod.source);
		if (!pr.ok) {
			console.log(error("parse error") + " [" + modPath + "]: " + pr.error);
			exit(1);
		}

		// Check (cross-module registry for proper import type resolution)
		const ctx = checkProgramWithRegistry(pr.value, graphRegistry, graph, mod, graphPreludeCtx);
		exitOnFatalCheckerErrors(ctx, modPath);
		ctx.errors = [];

		// Monomorphize
		const monoed = monomorphizeProgram(pr.value, ctx);

		// Validate metadata (warn but continue — some builtins lack resolvedSym)
		validateTypedAST(ctx, monoed);
		if (hasErrors(ctx)) {
			for (const e of ctx.errors) {
				console.log(dim("metadata warning [" + modPath + "]: " + e.message));
			}
			ctx.errors = [];
		}

		// Evaluate @comptime blocks before transforms
		const comptimeResolved = evaluateComptimeBlocks(monoed);

		// Transform (C target)
		const transformed = transformProgram(comptimeResolved, ctx, false);

		// Type refinement + native transform (C-specific lowering)
		const nativeCtx = createTransformContextWithChecker(ctx);
		const typeRefined = refineTypes(transformed, nativeCtx, graphRegistry);
		const nativeTransformed = transformForNative(typeRefined, nativeCtx);

		// HCR state lifting (--hcr only)
		const hcrResult = opts.isHcr ? liftHcrState(nativeTransformed, nativeCtx) : nativeTransformed;

		// Analyze (DRC injection)
		const analyzed = analyzeProgram(hcrResult, ctx);

		const nativeLowered = lowerNativeAccess(analyzed, nativeCtx);

		// Codegen — each module is self-contained (reference parity, no shared proto header)
		const cCode = generateCModule(nativeLowered, ctx, modPath, protoAliveSet, false, opts.isHcr);

		// Accumulate compiler flags from @passC/@passL directives
		allFlags = appendFlag(allFlags, ctx.compilerFlags);

		// Process @compile("foo.c") directives — compile extra C sources
		const compileObjs = processCompileDirectives(ctx.compileDirectives, dirName(modPath), allFlags, opts.mode, opts.ccCompiler, opts.verbose);
		oFiles = appendFlag(oFiles, compileObjs);

		// Check for user main() in entry module
		if (modPath === entryPath && ctx !== null && ctx.table !== null) {
			const mainSym = lookupSymbol(ctx.table, "main");
			hasUserMain = mainSym !== null;
			if (mainSym !== null && mainSym.symbolType !== null && mainSym.symbolType.typeReturn !== null) {
				const ret = getSimpleTypeDesc(mainSym.symbolType.typeReturn);
				if (ret !== "") mainRetType = ret;
			}
		}

		if (opts.emitC) {
			// --emit=c: write .c files to output dir, skip compilation
			const emitDir = outDirForMode(opts.mode);
			ensureDir(emitDir);
			const relPath = stripBase(modPath, dirName(entryPath));
			const emitPath = emitDir + "/" + replaceExt(relPath, ".c");
			ensureDir(dirName(emitPath));
			writeOutput(emitPath, cCode);
			console.log(green("  Wrote") + " " + bold(emitPath));
		} else {
			// Normal: write to /tmp and compile to .o
			const cFile = "/tmp/_msc_mod_" + compiled + ".c";
			const oFile = "/tmp/_msc_mod_" + compiled + ".o";
			writeOutput(cFile, cCode);
			if (opts.verbose) verboseLog("  cc " + cFile + " → " + oFile);
			// Add module's source directory + std/ + /tmp as include paths
			let modFlags = appendFlag(allFlags, "-iquote" + dirName(modPath));
			modFlags = appendFlag(modFlags, "-iquotestd");
			modFlags = appendFlag(modFlags, "-iquote/tmp");
			const ccCode = compileCFile(cFile, oFile, modFlags, opts.mode, opts.ccCompiler);
			if (ccCode !== 0) {
				console.log(error("error") + ": compile failed for " + modPath + " " + dim("(exit " + ccCode + ")"));
				// Continue to next module — collect all errors
			} else {
				oFiles = appendFlag(oFiles, oFile);
			}
		}
		compiled = compiled + 1;
	}

	// Skip link step if --emit=c (only writing C source files)
	if (opts.emitC) {
		console.log(success("Emitted " + compiled + " C module(s)"));
		if (opts.showTime) printTiming("emitted", t0);
		return;
	}

	// Generate global init dispatcher and compile to .o (skip for HCR — .so has no main)
	if (!opts.isHcr) {
		if (opts.verbose) verboseLog("generating dispatcher");
		const dispatcher = genProjectDispatcher(graph.loadOrder, entryPath, hasUserMain, mainRetType);
		const dispFile = "/tmp/_msc_dispatch.c";
		const dispObj = "/tmp/_msc_dispatch.o";
		writeOutput(dispFile, dispatcher);
		const dispCode = compileCFile(dispFile, dispObj, "", opts.mode, opts.ccCompiler);
		if (dispCode !== 0) {
			console.log(error("error") + ": compile failed for dispatcher " + dim("(exit " + dispCode + ")"));
			exit(1);
		}
		oFiles = appendFlag(oFiles, dispObj);
	}

	// Link all .o files into final binary (or shared library for HCR)
	const linkFlags = cliLinkFlags(allFlags, opts);
	if (opts.verbose) verboseLog("linking → " + outBinary);
	const linkCode = linkObjects(oFiles, outBinary, linkFlags, opts.mode, opts.ccCompiler);
	if (linkCode !== 0) {
		console.log(error("error") + ": link failed " + dim("(exit " + linkCode + ")"));
		exit(1);
	}

	if (opts.genDeps) {
		const depsDir = outDirForMode(opts.mode);
		writeDepsFile(graph, entryPath, depsDir);
	}
	console.log(success("Built " + compiled + " module(s) → " + bold(outBinary)));
	if (opts.showTime) printTiming("built", t0);
}

// ===== Test (multi-module, C backend) =====
// Compiles all modules, suppresses user's main(), executes test binary.
// Inline tests (testGroup/test/check) run during module initialization.

export function cmdTest(filePath: string, opts: CliOptions): void {
	registerCoreParsers();
	setTargetSizes(8, 8);
	const t0 = clockMs();
	const config = buildResolverConfig(Target.C, defaultResolveSection());
	const graph = loadAndCheckGraph(filePath, opts.verbose, config);

	// Pass 1: Compute global DCE alive set (lightweight parse+check+mono pass)
	if (opts.verbose) verboseLog("computing alive set for DCE");
	protoAliveSet = computeProjectAliveSet(graph, filePath, true);

	// Pass 2: Full pipeline + codegen + compile each module
	let allFlags = cliCompileFlags(opts);
	let oFiles = "";
	let compiled = 0;

	// Auto-compile companion .c files for .h imports
	const companionObjs = compileHeaderCompanions(graph, allFlags, opts.mode, opts.ccCompiler, opts.verbose);
	oFiles = appendFlag(oFiles, companionObjs);

	for (let i = 0; i < graph.loadOrder.length; i += 1) {
		const modPath = graph.loadOrder[i];
		const mod = findModule(graph, modPath);
		if (mod === null) continue;
		// Skip C header modules — prototypes come from @include, symbols from @link
		if (mod.isCHeader) continue;

		if (opts.verbose) verboseLog("compiling " + modPath);

		const pr = parseSource(mod.source);
		if (!pr.ok) {
			console.log(error("parse error") + " [" + modPath + "]: " + pr.error);
			exit(1);
		}

		const ctx = checkProgramWithRegistry(pr.value, graphRegistry, graph, mod, graphPreludeCtx);
		exitOnFatalCheckerErrors(ctx, modPath);
		ctx.errors = [];

		const monoed = monomorphizeProgram(pr.value, ctx);

		// Validate metadata
		validateTypedAST(ctx, monoed);
		ctx.errors = [];

		const comptimeResolved = evaluateComptimeBlocks(monoed);
		const transformed = transformProgram(comptimeResolved, ctx, false);
		const nativeCtx = createTransformContextWithChecker(ctx);
		const typeRefined = refineTypes(transformed, nativeCtx, graphRegistry);
		const nativeTransformed = transformForNative(typeRefined, nativeCtx);
		const hcrResult = opts.isHcr ? liftHcrState(nativeTransformed, nativeCtx) : nativeTransformed;
		const analyzed = analyzeProgram(hcrResult, ctx);
		const nativeLowered = lowerNativeAccess(analyzed, nativeCtx);
		const cCode = generateCModule(nativeLowered, ctx, modPath, protoAliveSet, true, opts.isHcr);

		allFlags = appendFlag(allFlags, ctx.compilerFlags);

		// Process @compile("foo.c") directives
		const compileObjs = processCompileDirectives(ctx.compileDirectives, dirName(modPath), allFlags, opts.mode, opts.ccCompiler, opts.verbose);
		oFiles = appendFlag(oFiles, compileObjs);

		const cFile = "/tmp/_msc_test_" + compiled + ".c";
		const oFile = "/tmp/_msc_test_" + compiled + ".o";
		writeOutput(cFile, cCode);
		let testModFlags = appendFlag(allFlags, "-iquote/tmp");
		const ccCode = compileCFile(cFile, oFile, testModFlags, opts.mode, opts.ccCompiler);
		if (ccCode !== 0) {
			console.log(error("error") + ": compile failed for " + modPath + " " + dim("(exit " + ccCode + ")"));
			exit(1);
		}
		oFiles = appendFlag(oFiles, oFile);
		compiled = compiled + 1;
	}

	// Generate test dispatcher (runs all module inits + test tables)
	if (opts.verbose) verboseLog("generating test dispatcher");
	const dispatcher = genTestDispatcher(graph.loadOrder, filePath);
	const dispFile = "/tmp/_msc_test_dispatch.c";
	const dispObj = "/tmp/_msc_test_dispatch.o";
	writeOutput(dispFile, dispatcher);
	const dispCode = compileCFile(dispFile, dispObj, "", opts.mode, opts.ccCompiler);
	if (dispCode !== 0) {
		console.log(error("error") + ": compile failed for test dispatcher " + dim("(exit " + dispCode + ")"));
		exit(1);
	}
	oFiles = appendFlag(oFiles, dispObj);

	// Link and execute
	ensureDir("out/debug");
	const testBin = "out/debug/_test_" + replaceExt(baseName(filePath), "");
	const linkCode = linkObjects(oFiles, testBin, allFlags, opts.mode, opts.ccCompiler);
	if (linkCode !== 0) {
		console.log(error("error") + ": link failed " + dim("(exit " + linkCode + ")"));
		exit(1);
	}

	if (opts.showTime) printTiming("compiled", t0);
	if (opts.verbose) verboseLog("running tests");
	const runCode = exec(testBin);
	exit(runCode);
}

// ===== Run JS (multi-module aware) =====

export function cmdRunJS(filePath: string, opts: CliOptions): void {
	setTargetSizes(8, 8);
	const t0 = clockMs();
	const config = buildResolverConfig(Target.JS, defaultResolveSection());
	const graph = loadAndCheckGraph(filePath, opts.verbose, config);

	const outDir = "out/debug";
	ensureDir(outDir);
	const baseDir = dirName(filePath);

	// Compile each module to JS in out/debug/
	for (let i = 0; i < graph.loadOrder.length; i += 1) {
		const modPath = graph.loadOrder[i];
		const mod = findModule(graph, modPath);
		if (mod === null) continue;
		if (mod.isCHeader) continue;

		if (opts.verbose) verboseLog("compiling " + modPath);

		const pr = parseSource(mod.source);
		if (!pr.ok) {
			console.log(error("parse error") + " [" + modPath + "]: " + pr.error);
			exit(1);
		}

		const ctx = checkProgramWithRegistry(pr.value, graphRegistry, graph, mod, graphPreludeCtx);
		exitOnFatalCheckerErrors(ctx, modPath);
		ctx.errors = [];

		const comptimeResolved = evaluateComptimeBlocks(pr.value);
		const transformed = transformProgram(comptimeResolved, ctx, true);
		const jsCode = generateJS(transformed);

		const relPath = stripBase(modPath, baseDir);
		const outPath = outDir + "/" + replaceExt(relPath, ".js");
		ensureDir(dirName(outPath));
		writeOutput(outPath, jsCode);
	}

	if (opts.showTime) printTiming("compiled", t0);

	// Execute entry module
	const entryRel = stripBase(filePath, baseDir);
	const entryJs = outDir + "/" + replaceExt(entryRel, ".js");
	if (opts.verbose) verboseLog("exec " + getJSRuntime() + " " + entryJs);
	const code = exec(getJSRuntime() + " " + entryJs);
	exit(code);
}

// ===== Raiser (Bytecode VM) Run =====
// Loads module graph, parse-only per module (no checker/transforms — Raiser VM is dynamically typed),
// compiles to bytecode via generateRaiserProject, executes in-process.

export function cmdRunRaiser(filePath: string, opts: CliOptions): void {
	setTargetSizes(8, 8);
	const t0 = clockMs();
	const config = buildResolverConfig(Target.Raiser, defaultResolveSection());
	const graph = loadAndCheckGraph(filePath, opts.verbose, config);

	// Parse each module → RaiserModuleInput (topological order)
	const modules: RaiserModuleInput[] = [];
	for (let i = 0; i < graph.loadOrder.length; i += 1) {
		const modPath = graph.loadOrder[i];
		const mod = findModule(graph, modPath);
		if (mod === null) continue;
		if (mod.isCHeader) continue;

		if (opts.verbose) verboseLog("parsing " + modPath);
		const pr = parseSource(mod.source);
		if (!pr.ok) {
			console.log(error("parse error") + " [" + modPath + "]: " + pr.error);
			exit(1);
		}

		const input: RaiserModuleInput = { modulePath: modPath, program: pr.value };
		modules.push(input);
	}

	if (opts.verbose) verboseLog("generating bytecode (" + modules.length + " modules)");
	const raiserMod = generateRaiserProject(modules, null as unknown as CheckerContext);

	if (opts.showTime) printTiming("compiled", t0);

	const ctx = createRaiserContext();
	raiserLoad(ctx, raiserMod);
	raiserExecute(ctx);

	if (ctx.lastOutput.length > 0) {
		// Print captured output (strip trailing newline for clean display)
		const lastOut = ctx.lastOutput;
		if (lastOut.length > 0 && lastOut.slice(lastOut.length - 1, lastOut.length) === "\n") {
			console.log(lastOut.slice(0, lastOut.length - 1));
		} else {
			console.log(lastOut);
		}
	}
}

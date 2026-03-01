// MetaScript Compiler CLI — compile command

import { exit, exec } from "std/process";
import { parseSource } from "../parser/statements/validation";
import { Node, NodeKind, ProgramData } from "../ast/node";
import { CheckerContext, hasErrors, errorCount } from "../checker/context";
import { checkProgram } from "../checker/checkPass";
import { checkModuleGraph } from "../checker/index";
import { transformProgram } from "../transform/index";
import { analyzeProgram } from "../analyzer/index";
import { monomorphizeProgram } from "../monomorphize/collect";
import { generateJS } from "../codegen/js/index";
import { generateRaiserProject, RaiserModuleInput } from "../codegen/raiser/rgen";
import { RaiserContext, createContext as createRaiserContext, load as raiserLoad, execute as raiserExecute } from "../raiser/context";
import { generateC, generateCModule, genProjectDispatcher, programHasMain, collectExportedPrototypes } from "../codegen/c/index";
import { transformForNative } from "../transform/native/index";
import { createTransformContextWithChecker } from "../transform/context";
import { findModule, ModuleGraph } from "../module/graph";
import { createFileSystemProvider, loadModuleGraph, loadModuleGraphWithConfig } from "../module/loader";
import { ResolverConfig, createDefaultConfig, BACKEND_C, BACKEND_JS, BACKEND_RAISER } from "../module/resolver";
import { ResolveSection } from "./buildConfig";
import { evaluateComptimeBlocks } from "./comptime";
import { CliOptions, Target, MODE_DEBUG, MODE_RELEASE } from "./options";
import { readSource, writeOutput, printErrorsAndExit, emitOutput, printTiming, verboseLog, replaceExt, dirName, baseName, stripBase, ensureDir, getJSRuntime, exeSuffix, outDirForMode } from "./io";
import { compileC, compileCFile, linkObjects, appendFlag, cliCompileFlags, cliLinkFlags } from "./cc";
import { error, success, bold, dim, green, red, cyan } from "../utils/color";
import { clockMs } from "std/process";

export function cmdCompile(filePath: string, opts: CliOptions, outputPath: string): void {
	const t0 = clockMs();
	const source = readSource(filePath);

	if (opts.verbose) verboseLog("parse " + filePath);
	const parseResult = parseSource(source);
	if (!parseResult.ok) {
		console.log(error("parse error") + ": " + parseResult.error);
		exit(1);
	}
	const program = parseResult.value;

	if (opts.verbose) verboseLog("check");
	const checkerCtx = checkProgram(program);
	if (hasErrors(checkerCtx)) {
		printErrorsAndExit(checkerCtx, "type error: ", opts.errorMax);
	}

	if (opts.verbose) verboseLog("monomorphize");
	const monoed = monomorphizeProgram(program, checkerCtx);

	if (opts.verbose) verboseLog("transform");
	const transformed = transformProgram(monoed, checkerCtx, opts.target === Target.JS);

	// Evaluate @comptime blocks
	const comptimeResolved = evaluateComptimeBlocks(transformed);

	if (opts.target === Target.JS) {
		if (opts.verbose) verboseLog("codegen js");
		const jsCode = generateJS(comptimeResolved);
		emitOutput(jsCode, filePath, outputPath, ".js");
	} else {
		if (opts.verbose) verboseLog("transform (native)");
		const nativeCtx = createTransformContextWithChecker(checkerCtx);
		const nativeTransformed = transformForNative(comptimeResolved, nativeCtx);
		if (opts.verbose) verboseLog("analyze (DRC)");
		const analyzed = analyzeProgram(nativeTransformed, checkerCtx);
		if (opts.verbose) verboseLog("codegen c");
		const cCode = generateC(analyzed, checkerCtx, filePath);
		emitOutput(cCode, filePath, outputPath, ".c");
	}

	if (opts.showTime) printTiming("compiled", t0);
}

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

// Report graph-level errors (e.g., circular deps, missing entry).
function reportGraphErrors(graph: ModuleGraph): void {
	for (const err of graph.errors) {
		console.log(red("graph error: ") + err);
	}
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

// Legacy load — backward compat for commands that don't have build.ms config.
function loadAndCheckGraphLegacy(entryPath: string, verbose: boolean): ModuleGraph {
	const dummyExts: string[] = [];
	const dummyCfg: ResolverConfig = { backend: 0, stdPath: "", searchPaths: [], extensions: dummyExts, aliasKeys: [], aliasValues: [] };
	return loadAndCheckGraph(entryPath, verbose, dummyCfg, 0);
}

// Load module graph, validate, and cross-module type check. Exits on errors.
// When useConfig=1, uses config-aware resolution (backend extensions, std/, search paths).
// When useConfig=0, falls back to legacy .ms-only resolution.
function loadAndCheckGraph(entryPath: string, verbose: boolean, config: ResolverConfig, useConfig: number): ModuleGraph {
	if (verbose) verboseLog("loading module graph from " + entryPath);
	const provider = createFileSystemProvider();
	let graph: ModuleGraph;
	if (useConfig === 1) {
		graph = loadModuleGraphWithConfig(entryPath, provider, config);
	} else {
		graph = loadModuleGraph(entryPath, provider);
	}
	reportGraphErrors(graph);
	exitOnModuleErrors(graph, "error");
	if (verbose) verboseLog("cross-module type check");
	let stdPath = "";
	if (useConfig === 1) { stdPath = config.stdPath; }
	checkModuleGraph(graph, stdPath);
	exitOnModuleErrors(graph, "type error");
	return graph;
}

// Collect exported C prototypes from all modules (Pass 1 for C builds).
function collectAllPrototypes(graph: ModuleGraph): string {
	let allProtos = "";
	for (const modPath of graph.loadOrder) {
		const mod = findModule(graph, modPath);
		if (mod === null) continue;
		const pr = parseSource(mod.source);
		if (!pr.ok) continue;
		const ctx = checkProgram(pr.value);
		const monoed = monomorphizeProgram(pr.value, ctx);
		allProtos = allProtos + collectExportedPrototypes(monoed);
	}
	return allProtos;
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
	const graph = loadAndCheckGraphLegacy(entryPath, opts.verbose);
	const outDir = outputDir !== "" ? outputDir : "out/debug";
	ensureDir(outDir);
	const baseDir = dirName(entryPath);

	// Compile each module to JS
	let compiled = 0;
	for (let i = 0; i < graph.loadOrder.length; i += 1) {
		const modPath = graph.loadOrder[i];
		const mod = findModule(graph, modPath);
		if (mod === null) continue;

		// Parse
		const pr = parseSource(mod.source);
		if (!pr.ok) {
			console.log(error("parse error") + " [" + modPath + "]: " + pr.error);
			exit(1);
		}

		// Check (single-module — cross-module already validated above)
		const ctx = checkProgram(pr.value);
		if (hasErrors(ctx)) {
			printErrorsAndExit(ctx, "type error [" + modPath + "]: ", 0);
		}

		// Transform (JS backend — skip C-specific transforms, no monomorphize needed)
		const transformed = transformProgram(pr.value, ctx, true);
		const comptimeResolved = evaluateComptimeBlocks(transformed);

		// Generate JS
		const jsCode = generateJS(comptimeResolved);

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
	const t0 = clockMs();
	const graph = loadAndCheckGraphLegacy(entryPath, opts.verbose);

	// Compute output binary path early for change detection
	let outBinary = opts.outputPath;
	if (outBinary === "") {
		const outDir = outDirForMode(opts.mode);
		ensureDir(outDir);
		outBinary = outDir + "/" + replaceExt(baseName(entryPath), "") + exeSuffix();
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

	// Pass 1: Collect exported prototypes from all modules
	if (opts.verbose) verboseLog("collecting cross-module prototypes");
	const allProtos = collectAllPrototypes(graph);

	// Pass 2: Full pipeline + codegen + per-module compile to .o
	let hasUserMain = false;
	let allFlags = cliCompileFlags(opts);
	let oFiles = "";
	let compiled = 0;

	for (let i = 0; i < graph.loadOrder.length; i += 1) {
		const modPath = graph.loadOrder[i];
		const mod = findModule(graph, modPath);
		if (mod === null) continue;

		if (opts.verbose) verboseLog("compiling " + modPath);

		// Parse
		const pr = parseSource(mod.source);
		if (!pr.ok) {
			console.log(error("parse error") + " [" + modPath + "]: " + pr.error);
			exit(1);
		}

		// Check (single-module — cross-module already validated above)
		const ctx = checkProgram(pr.value);
		if (hasErrors(ctx)) {
			printErrorsAndExit(ctx, "type error [" + modPath + "]: ", opts.errorMax);
		}

		// Monomorphize
		const monoed = monomorphizeProgram(pr.value, ctx);

		// Transform (C target)
		const transformed = transformProgram(monoed, ctx, false);
		const comptimeResolved = evaluateComptimeBlocks(transformed);

		// Native transform (C-specific lowering)
		const nativeCtx = createTransformContextWithChecker(ctx);
		const nativeTransformed = transformForNative(comptimeResolved, nativeCtx);

		// Analyze (DRC injection)
		const analyzed = analyzeProgram(nativeTransformed, ctx);

		// Codegen — module only, with cross-module prototypes
		const cCode = generateCModule(analyzed, ctx, modPath, allProtos);

		// Accumulate compiler flags from @passC/@passL directives
		allFlags = appendFlag(allFlags, ctx.compilerFlags);

		// Check for user main() in entry module
		if (modPath === entryPath) {
			hasUserMain = programHasMain(pr.value);
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
			const ccCode = compileCFile(cFile, oFile, allFlags, opts.mode, opts.ccCompiler);
			if (ccCode !== 0) {
				console.log(error("error") + ": compile failed for " + modPath + " " + dim("(exit " + ccCode + ")"));
				exit(1);
			}
			oFiles = appendFlag(oFiles, oFile);
		}
		compiled = compiled + 1;
	}

	// Skip link step if --emit=c (only writing C source files)
	if (opts.emitC) {
		console.log(success("Emitted " + compiled + " C module(s)"));
		if (opts.showTime) printTiming("emitted", t0);
		return;
	}

	// Generate global init dispatcher and compile to .o
	if (opts.verbose) verboseLog("generating dispatcher");
	const dispatcher = genProjectDispatcher(graph.loadOrder, entryPath, hasUserMain);
	const dispFile = "/tmp/_msc_dispatch.c";
	const dispObj = "/tmp/_msc_dispatch.o";
	writeOutput(dispFile, dispatcher);
	const dispCode = compileCFile(dispFile, dispObj, "", opts.mode, opts.ccCompiler);
	if (dispCode !== 0) {
		console.log(error("error") + ": compile failed for dispatcher " + dim("(exit " + dispCode + ")"));
		exit(1);
	}
	oFiles = appendFlag(oFiles, dispObj);

	// Link all .o files into final binary
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
	const t0 = clockMs();
	const graph = loadAndCheckGraphLegacy(filePath, opts.verbose);

	// Pass 1: Collect exported prototypes
	if (opts.verbose) verboseLog("collecting cross-module prototypes");
	const allProtos = collectAllPrototypes(graph);

	// Pass 2: Full pipeline + codegen + compile each module
	let allFlags = cliCompileFlags(opts);
	let oFiles = "";
	let compiled = 0;

	for (let i = 0; i < graph.loadOrder.length; i += 1) {
		const modPath = graph.loadOrder[i];
		const mod = findModule(graph, modPath);
		if (mod === null) continue;

		if (opts.verbose) verboseLog("compiling " + modPath);

		const pr = parseSource(mod.source);
		if (!pr.ok) {
			console.log(error("parse error") + " [" + modPath + "]: " + pr.error);
			exit(1);
		}

		const ctx = checkProgram(pr.value);
		if (hasErrors(ctx)) {
			printErrorsAndExit(ctx, "type error [" + modPath + "]: ", opts.errorMax);
		}

		const monoed = monomorphizeProgram(pr.value, ctx);
		const transformed = transformProgram(monoed, ctx, false);
		const comptimeResolved = evaluateComptimeBlocks(transformed);
		const nativeCtx = createTransformContextWithChecker(ctx);
		const nativeTransformed = transformForNative(comptimeResolved, nativeCtx);
		const analyzed = analyzeProgram(nativeTransformed, ctx);
		const cCode = generateCModule(analyzed, ctx, modPath, allProtos);

		allFlags = appendFlag(allFlags, ctx.compilerFlags);

		const cFile = "/tmp/_msc_test_" + compiled + ".c";
		const oFile = "/tmp/_msc_test_" + compiled + ".o";
		writeOutput(cFile, cCode);
		const ccCode = compileCFile(cFile, oFile, allFlags, opts.mode, opts.ccCompiler);
		if (ccCode !== 0) {
			console.log(error("error") + ": compile failed for " + modPath + " " + dim("(exit " + ccCode + ")"));
			exit(1);
		}
		oFiles = appendFlag(oFiles, oFile);
		compiled = compiled + 1;
	}

	// Generate dispatcher with hasUserMain=false (suppress user's main)
	if (opts.verbose) verboseLog("generating test dispatcher");
	const dispatcher = genProjectDispatcher(graph.loadOrder, filePath, false);
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
	const t0 = clockMs();
	const graph = loadAndCheckGraphLegacy(filePath, opts.verbose);

	const outDir = "out/debug";
	ensureDir(outDir);
	const baseDir = dirName(filePath);

	// Compile each module to JS in out/debug/
	for (let i = 0; i < graph.loadOrder.length; i += 1) {
		const modPath = graph.loadOrder[i];
		const mod = findModule(graph, modPath);
		if (mod === null) continue;

		if (opts.verbose) verboseLog("compiling " + modPath);

		const pr = parseSource(mod.source);
		if (!pr.ok) {
			console.log(error("parse error") + " [" + modPath + "]: " + pr.error);
			exit(1);
		}

		const ctx = checkProgram(pr.value);
		if (hasErrors(ctx)) {
			printErrorsAndExit(ctx, "type error [" + modPath + "]: ", opts.errorMax);
		}

		const transformed = transformProgram(pr.value, ctx, true);
		const comptimeResolved = evaluateComptimeBlocks(transformed);
		const jsCode = generateJS(comptimeResolved);

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
	const t0 = clockMs();
	const graph = loadAndCheckGraphLegacy(filePath, opts.verbose);

	// Parse each module → RaiserModuleInput (topological order)
	const modules: RaiserModuleInput[] = [];
	for (let i = 0; i < graph.loadOrder.length; i += 1) {
		const modPath = graph.loadOrder[i];
		const mod = findModule(graph, modPath);
		if (mod === null) continue;

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
	const raiserMod = generateRaiserProject(modules);

	if (opts.showTime) printTiming("compiled", t0);

	const ctx = createRaiserContext();
	raiserLoad(ctx, raiserMod);
	raiserExecute(ctx);

	if (ctx.lastOutput.length > 0) {
		// Print captured output (strip trailing newline for clean display)
		const out = ctx.lastOutput;
		if (out.length > 0 && out.slice(out.length - 1, out.length) === "\n") {
			console.log(out.slice(0, out.length - 1));
		} else {
			console.log(out);
		}
	}
}

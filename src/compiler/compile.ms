// MetaScript Compiler CLI — compile command

import { exit } from "std/process";
import { parseSource } from "../parser/statements/validation";
import { Node, NodeKind, ProgramData } from "../ast/node";
import { CheckerContext, hasErrors, errorCount } from "../checker/context";
import { checkProgram } from "../checker/checkPass";
import { checkModuleGraph } from "../checker/index";
import { transformProgram } from "../transform/index";
import { analyzeProgram } from "../analyzer/index";
import { monomorphizeProgram } from "../monomorphize/collect";
import { generateJS } from "../codegen/js/index";
import { generateC, generateCModule, genProjectDispatcher, programHasMain } from "../codegen/c/index";
import { transformForNative } from "../transform/native/index";
import { createTransformContextWithChecker } from "../transform/context";
import { findModule, ModuleGraph } from "../module/graph";
import { createFileSystemProvider, loadModuleGraph } from "../module/loader";
import { CliOptions, Target } from "./options";
import { readSource, writeOutput, printErrorsAndExit, emitOutput, printTiming, verboseLog, replaceExt } from "./io";
import { compileC } from "./cc";
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

	if (opts.target === Target.JS) {
		if (opts.verbose) verboseLog("codegen js");
		const jsCode = generateJS(transformed);
		emitOutput(jsCode, filePath, outputPath, ".js");
	} else {
		if (opts.verbose) verboseLog("transform (native)");
		const nativeCtx = createTransformContextWithChecker(checkerCtx);
		const nativeTransformed = transformForNative(transformed, nativeCtx);
		if (opts.verbose) verboseLog("analyze (DRC)");
		const analyzed = analyzeProgram(nativeTransformed, checkerCtx);
		if (opts.verbose) verboseLog("codegen c");
		const cCode = generateC(analyzed, checkerCtx, filePath);
		emitOutput(cCode, filePath, outputPath, ".c");
	}

	if (opts.showTime) printTiming("compiled", t0);
}

// ===== Multi-Module Helpers =====

// Report graph-level errors (e.g., circular deps, missing entry).
function reportGraphErrors(graph: ModuleGraph): void {
	if (graph.errors.length > 0) {
		for (let i = 0; i < graph.errors.length; i += 1) {
			console.log(red("graph error: ") + graph.errors[i]);
		}
	}
}

// Report per-module errors and exit if any found.
function exitOnModuleErrors(graph: ModuleGraph, prefix: string): void {
	let hasErr = false;
	for (let i = 0; i < graph.modules.length; i += 1) {
		const mod = graph.modules[i];
		if (mod.errors.length > 0) {
			hasErr = true;
			for (let j = 0; j < mod.errors.length; j += 1) {
				console.log(red(prefix) + " [" + mod.path + "]: " + mod.errors[j]);
			}
		}
	}
	if (hasErr) exit(1);
}

// ===== Multi-Module JS Build =====

export function cmdBuildJS(entryPath: string, outputDir: string): void {
	const provider = createFileSystemProvider();
	const graph = loadModuleGraph(entryPath, provider);

	reportGraphErrors(graph);
	exitOnModuleErrors(graph, "error");

	checkModuleGraph(graph);
	exitOnModuleErrors(graph, "type error");

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
			continue;
		}

		// Check (single-module — cross-module already validated above)
		const ctx = checkProgram(pr.value);

		// Transform (JS backend — skip C-specific transforms, no monomorphize needed)
		const transformed = transformProgram(pr.value, ctx, true);

		// Generate JS
		const jsCode = generateJS(transformed);

		// Write output
		const outPath = replaceExt(modPath, ".js");
		writeOutput(outPath, jsCode);
		console.log(green("  Wrote") + " " + bold(outPath));
		compiled = compiled + 1;
	}

	console.log(success(compiled + " module(s) compiled to JS"));
}

// ===== Multi-Module C Build =====
// Loads module graph, compiles each module to C, combines via unity build, links to native binary.

export function cmdBuildC(entryPath: string, opts: CliOptions): void {
	const t0 = clockMs();

	if (opts.verbose) verboseLog("loading module graph from " + entryPath);
	const provider = createFileSystemProvider();
	const graph = loadModuleGraph(entryPath, provider);

	reportGraphErrors(graph);
	exitOnModuleErrors(graph, "error");

	if (opts.verbose) verboseLog("cross-module type check");
	checkModuleGraph(graph);
	exitOnModuleErrors(graph, "type error");

	// Compile each module through full pipeline → .c file
	let unityContent = "";
	let hasUserMain = false;
	let allFlags = "";
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

		// Native transform (C-specific lowering)
		const nativeCtx = createTransformContextWithChecker(ctx);
		const nativeTransformed = transformForNative(transformed, nativeCtx);

		// Analyze (DRC injection)
		const analyzed = analyzeProgram(nativeTransformed, ctx);

		// Codegen — module only, no dispatcher
		const cCode = generateCModule(analyzed, ctx, modPath);

		// Accumulate compiler flags from @passC/@passL directives
		if (ctx.compilerFlags !== "") {
			if (allFlags.length > 0) allFlags = allFlags + " ";
			allFlags = allFlags + ctx.compilerFlags;
		}

		// Check for user main() in entry module
		if (modPath === entryPath) {
			hasUserMain = programHasMain(pr.value);
		}

		// Write module .c file
		const cFile = "/tmp/_msc_mod_" + compiled + ".c";
		writeOutput(cFile, cCode);
		unityContent = unityContent + "#include \"" + cFile + "\"\n";
		compiled = compiled + 1;
	}

	// 4. Generate global init dispatcher
	if (opts.verbose) verboseLog("generating dispatcher");
	const dispatcher = genProjectDispatcher(graph.loadOrder, entryPath, hasUserMain);
	const dispFile = "/tmp/_msc_dispatch.c";
	writeOutput(dispFile, dispatcher);
	unityContent = unityContent + "#include \"" + dispFile + "\"\n";

	// 5. Unity build — combine all .c files and compile
	const unityFile = "/tmp/_msc_unity.c";
	writeOutput(unityFile, unityContent);

	let outBinary = opts.outputPath;
	if (outBinary === "") {
		outBinary = replaceExt(entryPath, "");
	}

	if (opts.verbose) verboseLog("clang (unity build)");
	const buildCode = compileC(unityFile, outBinary, allFlags);
	if (buildCode !== 0) {
		console.log(error("error") + ": compilation failed " + dim("(exit " + buildCode + ")"));
		exit(1);
	}

	console.log(success("Built " + compiled + " module(s) → " + bold(outBinary)));
	if (opts.showTime) printTiming("built", t0);
}

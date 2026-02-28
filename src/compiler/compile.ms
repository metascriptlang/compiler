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
import { generateC } from "../codegen/c/index";
import { transformForNative } from "../transform/native/index";
import { createTransformContextWithChecker } from "../transform/context";
import { findModule, ModuleGraph } from "../module/graph";
import { createFileSystemProvider, loadModuleGraph } from "../module/loader";
import { Target } from "./options";
import { readSource, writeOutput, printErrorsAndExit, emitOutput } from "./io";
import { error, success, bold, dim, green, red } from "../utils/color";

export function cmdCompile(filePath: string, target: Target, outputPath: string): void {
	const source = readSource(filePath);

	const parseResult = parseSource(source);
	if (!parseResult.ok) {
		console.log(error("parse error") + ": " + parseResult.error);
		exit(1);
	}
	const program = parseResult.value;

	const checkerCtx = checkProgram(program);
	if (hasErrors(checkerCtx)) {
		printErrorsAndExit(checkerCtx, "Type error: ");
	}

	const monoed = monomorphizeProgram(program, checkerCtx);
	const transformed = transformProgram(monoed, checkerCtx, target === Target.JS);

	if (target === Target.JS) {
		const jsCode = generateJS(transformed);
		emitOutput(jsCode, filePath, outputPath, ".js");
	} else {
		const nativeCtx = createTransformContextWithChecker(checkerCtx);
		const nativeTransformed = transformForNative(transformed, nativeCtx);
		const analyzed = analyzeProgram(nativeTransformed, checkerCtx);
		const cCode = generateC(analyzed, checkerCtx, filePath);
		emitOutput(cCode, filePath, outputPath, ".c");
	}
}

// ===== Multi-Module JS Build =====
// Loads module graph from entry point, compiles each module to .js with ES module imports/exports.

function msToJs(filePath: string): string {
	if (filePath.length >= 3) {
		const suffix = filePath.slice(filePath.length - 3, filePath.length);
		if (suffix === ".ms") {
			return filePath.slice(0, filePath.length - 3) + ".js";
		}
	}
	return filePath + ".js";
}

export function cmdBuildJS(entryPath: string, outputDir: string): void {
	// 1. Load module graph from file system
	const provider = createFileSystemProvider();
	const graph = loadModuleGraph(entryPath, provider);

	// Report graph errors
	if (graph.errors.length > 0) {
		for (let i = 0; i < graph.errors.length; i += 1) {
			console.log(red("graph error: ") + graph.errors[i]);
		}
	}

	// Report per-module load errors
	let hasModuleErrors = false;
	for (let i = 0; i < graph.modules.length; i += 1) {
		const mod = graph.modules[i];
		if (mod.errors.length > 0) {
			hasModuleErrors = true;
			for (let j = 0; j < mod.errors.length; j += 1) {
				console.log(red("error") + " [" + mod.path + "]: " + mod.errors[j]);
			}
		}
	}
	if (hasModuleErrors) {
		exit(1);
	}

	// 2. Type-check module graph (validates cross-module imports)
	checkModuleGraph(graph);

	// Check for type errors across modules
	for (let i = 0; i < graph.modules.length; i += 1) {
		const mod = graph.modules[i];
		if (mod.errors.length > 0) {
			for (let j = 0; j < mod.errors.length; j += 1) {
				console.log(red("type error") + " [" + mod.path + "]: " + mod.errors[j]);
			}
			hasModuleErrors = true;
		}
	}
	if (hasModuleErrors) {
		exit(1);
	}

	// 3. Compile each module to JS
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

		// Transform (JS backend — skip C-specific transforms)
		const transformed = transformProgram(pr.value, ctx, true);

		// Generate JS
		const jsCode = generateJS(transformed);

		// Write output
		const outPath = msToJs(modPath);
		writeOutput(outPath, jsCode);
		console.log(green("  Wrote") + " " + bold(outPath));
		compiled = compiled + 1;
	}

	console.log(success(compiled + " module(s) compiled to JS"));
}

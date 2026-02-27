// MetaScript Compiler CLI — Individual commands (check, dump-*, pipeline, run, test, fmt)

import { exit, exec, fileExists } from "std/process";
import { lex } from "../lexer/index";
import { formatToken } from "../lexer/token";
import { parseSource } from "../parser/statements/validation";
import { Node, NodeKind, ProgramData } from "../ast/node";
import { printNode } from "../ast/index";
import { CheckerContext, hasErrors, errorCount } from "../checker/context";
import { checkProgram } from "../checker/checkPass";
import { transformProgram } from "../transform/index";
import { analyzeProgram } from "../analyzer/index";
import { generateJS } from "../codegen/js/index";
import { Target } from "./options";
import { startsWith, endsWith } from "./options";
import { readSource, writeOutput } from "./io";

// -- dump-tokens --

export function cmdDumpTokens(filePath: string): void {
	const source = readSource(filePath);
	const result = lex(source);
	if (!result.ok) {
		console.log("Lex error: " + result.error);
		exit(1);
	}
	const tokens = result.value;
	let i = 0;
	while (i < tokens.length) {
		console.log(formatToken(tokens[i]));
		i += 1;
	}
}

// -- dump-ast --

export function cmdDumpAst(filePath: string): void {
	const source = readSource(filePath);
	const result = parseSource(source);
	if (!result.ok) {
		console.log("Parse error: " + result.error);
		exit(1);
	}
	const program = result.value;
	const pd = program.data as ProgramData;
	let i = 0;
	while (i < pd.programStmts.length) {
		printNode(pd.programStmts[i], 0);
		i += 1;
	}
}

// -- check --

export function cmdCheck(filePath: string): void {
	const source = readSource(filePath);
	const parseResult = parseSource(source);
	if (!parseResult.ok) {
		console.log("Parse error: " + parseResult.error);
		exit(1);
	}
	const program = parseResult.value;
	const ctx = checkProgram(program);
	if (!hasErrors(ctx)) {
		console.log("OK - no type errors");
	} else {
		const count = errorCount(ctx);
		console.log("Found " + count + " type error(s):");
		let i = 0;
		while (i < ctx.errors.length) {
			console.log("  " + ctx.errors[i]);
			i += 1;
		}
		exit(1);
	}
}

// -- pipeline --

export function cmdPipeline(filePath: string): void {
	const source = readSource(filePath);
	console.log("=== Pipeline: " + filePath + " ===");

	// Phase 1: Parse
	console.log("\n[1/5] Parse...");
	const parseResult = parseSource(source);
	if (!parseResult.ok) {
		console.log("  FAILED: " + parseResult.error);
		exit(1);
	}
	const program = parseResult.value;
	const pd = program.data as ProgramData;
	console.log("  OK - " + pd.programStmts.length + " top-level statements");

	// Phase 2: Type Check
	console.log("\n[2/5] Type Check...");
	const checkerCtx = checkProgram(program);
	if (hasErrors(checkerCtx)) {
		const count = errorCount(checkerCtx);
		console.log("  " + count + " error(s):");
		let i = 0;
		while (i < checkerCtx.errors.length) {
			console.log("    " + checkerCtx.errors[i]);
			i += 1;
		}
	} else {
		console.log("  OK - no errors");
	}

	// Phase 3: Transform
	console.log("\n[3/5] Transform (27 passes)...");
	const transformed = transformProgram(program, checkerCtx);
	console.log("  OK");

	// Phase 4: Analyze (DRC)
	console.log("\n[4/5] Analyze (DRC injection)...");
	const analyzed = analyzeProgram(transformed, checkerCtx);
	console.log("  OK");

	// Phase 5: Codegen
	console.log("\n[5/5] Codegen...");
	console.log("  C backend: not yet implemented");
	console.log("  JS backend: available (--target=js)");

	console.log("\nPipeline complete.");
}

// -- run --

export function cmdRun(filePath: string, target: Target): void {
	const source = readSource(filePath);

	// Parse
	const parseResult = parseSource(source);
	if (!parseResult.ok) {
		console.log("Parse error: " + parseResult.error);
		exit(1);
	}
	const program = parseResult.value;

	// Type check
	const checkerCtx = checkProgram(program);
	if (hasErrors(checkerCtx)) {
		let i = 0;
		while (i < checkerCtx.errors.length) {
			console.log("Type error: " + checkerCtx.errors[i]);
			i += 1;
		}
		exit(1);
	}

	// Transform
	const transformed = transformProgram(program, checkerCtx);

	if (target === Target.JS) {
		// JS: compile to temp .js, run with node
		const jsCode = generateJS(transformed);
		const tmpFile = "/tmp/_msc_run.js";
		writeOutput(tmpFile, jsCode);
		const code = exec("node " + tmpFile);
		exit(code);
	} else {
		// C: compile to temp .c, build with clang, run binary
		const analyzed = analyzeProgram(transformed, checkerCtx);
		// TODO: generateC(analyzed) once C codegen lands
		// For now: fall back to JS if possible
		console.log("Error: C backend run not yet available (C codegen in progress)");
		console.log("Use --target=js to run via JavaScript:");
		console.log("  msc run --target=js " + filePath);
		exit(1);
	}
}

// -- test --

export function cmdTest(filePath: string): void {
	console.log("Error: 'test' command not yet implemented in self-hosted compiler");
	console.log("Use the reference compiler: msc test " + filePath);
	exit(1);
}

// -- fmt --

export function cmdFmt(filePath: string): void {
	console.log("Error: 'fmt' command not yet implemented");
	exit(1);
}

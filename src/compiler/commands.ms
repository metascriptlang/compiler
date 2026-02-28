// MetaScript Compiler CLI — Individual commands (check, dump-*, pipeline, run, test, fmt)

import { exit, exec } from "std/process";
import { lex } from "../lexer/index";
import { formatToken } from "../lexer/token";
import { parseSource } from "../parser/statements/validation";
import { Node, NodeKind, ProgramData } from "../ast/node";
import { printNode } from "../ast/index";
import { CheckerContext, hasErrors, errorCount } from "../checker/context";
import { checkProgram } from "../checker/checkPass";
import { transformProgram } from "../transform/index";
import { analyzeProgram } from "../analyzer/index";
// import { monomorphizeProgram } from "../monomorphize/collect";
import { generateJS } from "../codegen/js/index";
import { generateC } from "../codegen/c/index";
import { transformForNative } from "../transform/native/index";
import { createTransformContextWithChecker } from "../transform/context";
import { Target } from "./options";
import { readSource, writeOutput, printErrorsAndExit } from "./io";
import { compileC } from "./cc";
import { error, success, bold, cyan, dim, green, red, yellow, path } from "../utils/color";

// -- dump-tokens --

export function cmdDumpTokens(filePath: string): void {
	const source = readSource(filePath);
	const result = lex(source);
	if (!result.ok) {
		console.log(error("lex error") + ": " + result.error);
		exit(1);
	}
	const tokens = result.value;
	for (let i = 0; i < tokens.length; i += 1) {
		console.log(formatToken(tokens[i]));
	}
}

// -- dump-ast --

export function cmdDumpAst(filePath: string): void {
	const source = readSource(filePath);
	const result = parseSource(source);
	if (!result.ok) {
		console.log(error("parse error") + ": " + result.error);
		exit(1);
	}
	const program = result.value;
	const pd = program.data as ProgramData;
	for (let i = 0; i < pd.programStmts.length; i += 1) {
		printNode(pd.programStmts[i], 0);
	}
}

// -- check --

export function cmdCheck(filePath: string): void {
	const source = readSource(filePath);
	const parseResult = parseSource(source);
	if (!parseResult.ok) {
		console.log(error("parse error") + ": " + parseResult.error);
		exit(1);
	}
	const program = parseResult.value;
	const ctx = checkProgram(program);
	if (!hasErrors(ctx)) {
		console.log(success("OK") + " " + dim("no type errors"));
	} else {
		const count = errorCount(ctx);
		console.log(error("Found " + count + " type error(s)") + ":");
		printErrorsAndExit(ctx, "  ");
	}
}

// -- pipeline --

export function cmdPipeline(filePath: string): void {
	const source = readSource(filePath);
	console.log(bold("Pipeline") + " " + path(filePath));

	// Phase 1: Parse
	console.log("\n" + cyan("[1/5]") + " Parse...");
	const parseResult = parseSource(source);
	if (!parseResult.ok) {
		console.log("  " + error("FAILED") + ": " + parseResult.error);
		exit(1);
	}
	const program = parseResult.value;
	const pd = program.data as ProgramData;
	console.log("  " + green("OK") + " " + dim(pd.programStmts.length + " top-level statements"));

	// Phase 2: Type Check
	console.log("\n" + cyan("[2/5]") + " Type Check...");
	const checkerCtx = checkProgram(program);
	if (hasErrors(checkerCtx)) {
		const count = errorCount(checkerCtx);
		console.log("  " + red(count + " error(s)") + ":");
		for (let i = 0; i < checkerCtx.errors.length; i += 1) {
			console.log("    " + checkerCtx.errors[i]);
		}
	} else {
		console.log("  " + green("OK") + " " + dim("no errors"));
	}

	// Phase 3: Transform
	console.log("\n" + cyan("[3/5]") + " Transform...");
	const transformed = transformProgram(program, checkerCtx, false);
	console.log("  " + green("OK"));

	// Phase 4: Analyze (DRC)
	console.log("\n" + cyan("[4/5]") + " Analyze " + dim("(DRC injection)") + "...");
	const analyzed = analyzeProgram(transformed, checkerCtx);
	console.log("  " + green("OK"));

	// Phase 5: Codegen
	console.log("\n" + cyan("[5/5]") + " Codegen...");
	console.log("  C backend:  " + green("available") + " " + dim("(--target=c)"));
	console.log("  JS backend: " + green("available") + " " + dim("(--target=js)"));

	console.log("\n" + success("Pipeline complete."));
}

// -- run --

export function cmdRun(filePath: string, target: Target): void {
	const source = readSource(filePath);

	const parseResult = parseSource(source);
	if (!parseResult.ok) {
		console.log(error("parse error") + ": " + parseResult.error);
		exit(1);
	}
	const program = parseResult.value;

	const checkerCtx = checkProgram(program);
	if (hasErrors(checkerCtx)) {
		printErrorsAndExit(checkerCtx, "type error: ");
	}

	const transformed = transformProgram(program, checkerCtx, target === Target.JS);

	if (target === Target.JS) {
		const jsCode = generateJS(transformed);
		const tmpFile = "/tmp/_msc_run.js";
		writeOutput(tmpFile, jsCode);
		const code = exec("node " + tmpFile);

		exit(code);
	} else {
		const nativeCtx = createTransformContextWithChecker(checkerCtx);
		const nativeTransformed = transformForNative(transformed, nativeCtx);
		const analyzed = analyzeProgram(nativeTransformed, checkerCtx);
		const cCode = generateC(analyzed, checkerCtx, filePath);
		const tmpC = "/tmp/_msc_run.c";
		const tmpBin = "/tmp/_msc_run";
		writeOutput(tmpC, cCode);

		const buildCode = compileC(tmpC, tmpBin, checkerCtx.compilerFlags);
		if (buildCode !== 0) {
			console.log(error("error") + ": clang compilation failed " + dim("(exit " + buildCode + ")"));
	
			exit(1);
		}

		const runCode = exec(tmpBin);

		exit(runCode);
	}
}

// -- test --

export function cmdTest(filePath: string): void {
	console.log(error("error") + ": " + cyan("test") + " command not yet implemented in self-hosted compiler");
	console.log(dim("Use the reference compiler: msc test " + filePath));
	exit(1);
}

// -- fmt --

export function cmdFmt(filePath: string): void {
	console.log(error("error") + ": " + cyan("fmt") + " command not yet implemented");
	exit(1);
}

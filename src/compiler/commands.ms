// MetaScript Compiler CLI — Individual commands (check, dump-*, pipeline, run, test, fmt)

import { exit, exec, clockMs } from "std/process";
import { lex } from "../lexer/index";
import { formatToken } from "../lexer/token";
import { parseSource } from "../parser/statements/validation";
import { registerCoreParsers } from "../parser/statements/core"; // Moved to top
import { Node, NodeKind, ProgramData } from "../ast/node";
import { printNode as printAstNode } from "../ast/index";
import { CheckerContext, hasErrors, errorCount } from "../checker/context";
import { checkProgram } from "../checker/checkPass";
import { transformProgram } from "../transform/index";
import { analyzeProgram } from "../analyzer/index";
import { CliOptions, Target } from "./options";
import { readSource, writeOutput, printErrorsAndExit, printTiming, verboseLog, replaceExt, baseName, ensureDir } from "./io";
import { cmdBuildC } from "./compile";
import { error, success, bold, cyan, dim, green, red, yellow, path } from "../utils/color";

// Formatter imports
import { defaultFormatOptions, applyFmtSection } from "./fmt/options";
import { formatDoc } from "./fmt/layout";
import { printNode as printFormattedNode } from "./fmt/printer/index";
import { FmtSection, defaultFmtSection } from "./buildConfig";

// -- dump-tokens --

export function cmdDumpTokens(filePath: string): void {
	const source = readSource(filePath);
	const result = lex(source);
	if (!result.ok) {
		console.log(error("lex error") + ": " + result.error);
		exit(1);
	}
	const tokens = result.value;
	for (const tok of tokens) {
		console.log(formatToken(tok));
	}
}

// -- dump-ast --

export function cmdDumpAst(filePath: string): void {
	registerCoreParsers();
	const source = readSource(filePath);
	const result = parseSource(source);
	if (!result.ok) {
		console.log(error("parse error") + ": " + result.error);
		exit(1);
	}
	const program = result.value;
	const pd = program.data as ProgramData;
	for (const stmt of pd.programStmts) {
		printAstNode(stmt, 0);
	}
}

// -- check --

export function cmdCheck(filePath: string, opts: CliOptions): void {
	const t0 = clockMs();
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
		printErrorsAndExit(ctx, "  ", opts.errorMax);
	}
	if (opts.showTime) printTiming("checked", t0);
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
		for (const err of checkerCtx.errors) {
			const loc = err.line > 0 ? ":" + err.line + ":" + err.column + " " : " ";
			console.log("    " + loc + err.message);
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
// Delegates to cmdBuildC so imports resolve correctly,
// then executes the resulting binary.

export function cmdRun(filePath: string, opts: CliOptions): void {
	const t0 = clockMs();
	// Build to out/debug/<name> via the full pipeline
	ensureDir("out/debug");
	const binName = replaceExt(baseName(filePath), "");
	const tmpBin = "out/debug/" + binName;
	opts.outputPath = tmpBin;
	opts.forceRebuild = true;
	cmdBuildC(filePath, opts);

	if (opts.showTime) printTiming("compiled", t0);
	const runCode = exec(tmpBin);
	exit(runCode);
}

// -- fmt --

export function cmdFmt(filePath: string, opts: CliOptions, fmtCfg: FmtSection): void {
	registerCoreParsers();
	const source = readSource(filePath);
	const result = parseSource(source);
	if (!result.ok) {
		console.log(error("parse error") + ": " + result.error);
		exit(1);
	}
	const program = result.value;
	const options = applyFmtSection(defaultFormatOptions(), fmtCfg);
	options.source = source;

	const doc = printFormattedNode(program, options);
	const formatted = formatDoc(doc, options);

	if (formatted !== source) {
		if (opts.fmtCheck) {
			console.log(red("Unformatted") + " " + path(filePath));
			exit(1);
		}
		writeOutput(filePath, formatted);
		console.log(success("Formatted") + " " + path(filePath));
	} else {
		console.log(dim("Unchanged") + " " + path(filePath));
	}
}

// -- init --

export function cmdInit(name: string): void {
	if (name === "") name = ".";
	if (name !== ".") {
		exec("mkdir -p " + name + "/src");
	} else {
		exec("mkdir -p src");
	}
	const buildPath = name + "/build.ms";
	const srcPath = name + "/src/index.ms";
	const buildContent = "import { BuildConfig } from \"std/build\";\n\nconst config: BuildConfig = {\n\troot: \"src/index.ms\",\n\tfmt: {\n\t\tuseTabs: true,\n\t},\n};\n\nexport default config;\n";
	const srcContent = "function main(): number {\n\tconsole.log(\"hello, metascript!\");\n\treturn 0;\n}\n";
	writeOutput(buildPath, buildContent);
	writeOutput(srcPath, srcContent);
	console.log(success("Created") + " project in " + bold(name));
	console.log(dim("  " + buildPath));
	console.log(dim("  " + srcPath));
}

// -- clean --

export function cmdClean(): void {
	exec("rm -rf out");
	exec("rm -f /tmp/_msc_*.c /tmp/_msc_*.o");
	console.log(success("Cleaned") + " build artifacts");
}

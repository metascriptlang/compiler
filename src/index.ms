// MetaScript Compiler CLI — Entry point (dispatch only)

import { exit } from "std/process";
import { CliOptions, Target, parseArgs } from "./compiler/options";
import { VERSION, printUsage } from "./compiler/usage";
import { cmdCompile } from "./compiler/compile";
import { cmdCheck, cmdDumpTokens, cmdDumpAst, cmdPipeline, cmdRun, cmdTest, cmdFmt } from "./compiler/commands";
import { lspRunServer } from "./compiler/lsp/server";
import { error, bold, green, cyan } from "./utils/color";

function requireFile(opts: CliOptions): void {
	if (opts.inputFile === "") {
		console.log(error("error") + ": " + cyan(opts.command) + " requires an input file");
		printUsage();
		exit(1);
	}
}

function main(): number {
	const opts = parseArgs();
	const cmd = opts.command;

	if (cmd === "" || cmd === "help") {
		printUsage();
	} else if (cmd === "version") {
		console.log(bold("Metascript") + " " + green("v" + VERSION));
	} else if (cmd === "compile") {
		requireFile(opts);
		cmdCompile(opts.inputFile, opts.target, opts.outputPath);
	} else if (cmd === "run") {
		requireFile(opts);
		cmdRun(opts.inputFile, opts.target);
	} else if (cmd === "test") {
		requireFile(opts);
		cmdTest(opts.inputFile);
	} else if (cmd === "check") {
		requireFile(opts);
		cmdCheck(opts.inputFile);
	} else if (cmd === "dump-tokens") {
		requireFile(opts);
		cmdDumpTokens(opts.inputFile);
	} else if (cmd === "dump-ast") {
		requireFile(opts);
		cmdDumpAst(opts.inputFile);
	} else if (cmd === "pipeline") {
		requireFile(opts);
		cmdPipeline(opts.inputFile);
	} else if (cmd === "fmt") {
		requireFile(opts);
		cmdFmt(opts.inputFile);
	} else if (cmd === "lsp") {
		lspRunServer();
	} else if (cmd === "build") {
		console.log(error("error") + ": " + cyan("build") + " command not yet implemented");
		exit(1);
	} else {
		console.log(error("error") + ": unknown command '" + bold(cmd) + "'");
		printUsage();
		exit(1);
	}

	return 0;
}

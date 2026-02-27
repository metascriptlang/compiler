// MetaScript Compiler CLI — Entry point (dispatch only)

import { exit } from "std/process";
import { CliOptions, Target, parseArgs } from "./options";
import { VERSION, printUsage } from "./usage";
import { cmdCompile } from "./compile";
import { cmdCheck, cmdDumpTokens, cmdDumpAst, cmdPipeline, cmdRun, cmdTest, cmdFmt } from "./commands";
import { lspRunServer } from "./lsp/server";

function requireFile(opts: CliOptions): void {
	if (opts.inputFile === "") {
		console.log("Error: " + opts.command + " requires an input file");
		printUsage();
		exit(1);
	}
}

function main(): void {
	const opts = parseArgs();

	if (opts.command === "") {
		printUsage();
		return;
	}

	if (opts.command === "help") {
		printUsage();
		return;
	}

	if (opts.command === "version") {
		console.log("Metascript v" + VERSION);
		return;
	}

	if (opts.command === "compile") {
		requireFile(opts);
		cmdCompile(opts.inputFile, opts.target, opts.outputPath);
		return;
	}

	if (opts.command === "run") {
		requireFile(opts);
		cmdRun(opts.inputFile, opts.target);
		return;
	}

	if (opts.command === "test") {
		requireFile(opts);
		cmdTest(opts.inputFile);
		return;
	}

	if (opts.command === "check") {
		requireFile(opts);
		cmdCheck(opts.inputFile);
		return;
	}

	if (opts.command === "dump-tokens") {
		requireFile(opts);
		cmdDumpTokens(opts.inputFile);
		return;
	}

	if (opts.command === "dump-ast") {
		requireFile(opts);
		cmdDumpAst(opts.inputFile);
		return;
	}

	if (opts.command === "pipeline") {
		requireFile(opts);
		cmdPipeline(opts.inputFile);
		return;
	}

	if (opts.command === "fmt") {
		requireFile(opts);
		cmdFmt(opts.inputFile);
		return;
	}

	if (opts.command === "lsp") {
		lspRunServer();
		return;
	}

	if (opts.command === "build") {
		console.log("Error: 'build' command not yet implemented");
		exit(1);
	}

	console.log("Error: unknown command '" + opts.command + "'");
	printUsage();
	exit(1);
}

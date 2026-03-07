// MetaScript Compiler CLI — Entry point (dispatch only)

import { exit } from "std/process";
import { CliOptions, Target, parseArgs, MODE_DEBUG, MODE_RELEASE, MODE_DANGER } from "./compiler/options";
import { VERSION, printUsage } from "./compiler/usage";
import { cmdBuildJS, cmdBuildC, cmdRunJS, cmdRunRaiser, cmdTest } from "./compiler/compile";
import { cmdCheck, cmdDumpTokens, cmdDumpAst, cmdPipeline, cmdRun, cmdFmt, cmdInit, cmdClean } from "./compiler/commands";
import { lspRunServer } from "./compiler/lsp/server";
import { loadBuildConfig, BuildConfig } from "./compiler/buildConfig";
import { verboseLog } from "./compiler/io";
import { error, bold, green, cyan } from "./utils/color";

function requireFile(opts: CliOptions): void {
	if (opts.inputFile === "") {
		console.log(error("error") + ": " + cyan(opts.command) + " requires an input file");
		printUsage();
		exit(1);
	}
}

export function main(): number {
	const opts = parseArgs();
	const cmd = opts.command;

	if (cmd === "" || cmd === "help") {
		printUsage();
	} else if (cmd === "version") {
		console.log(bold("Metascript") + " " + green("v" + VERSION));
	} else if (cmd === "run") {
		if (opts.inputFile === "") {
			const cfg = loadBuildConfig("build.ms", opts.showTime);
			if (cfg.valid) { opts.inputFile = cfg.root; }
		}
		requireFile(opts);
		if (opts.target === Target.JS) {
			cmdRunJS(opts.inputFile, opts);
		} else if (opts.target === Target.Raiser) {
			cmdRunRaiser(opts.inputFile, opts);
		} else {
			cmdRun(opts.inputFile, opts);
		}
	} else if (cmd === "test") {
		requireFile(opts);
		if (opts.target === Target.JS) {
			cmdRunJS(opts.inputFile, opts);
		} else {
			cmdTest(opts.inputFile, opts);
		}
	} else if (cmd === "check") {
		requireFile(opts);
		cmdCheck(opts.inputFile, opts);
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
		cmdFmt(opts.inputFile, opts);
	} else if (cmd === "init") {
		cmdInit(opts.inputFile);
	} else if (cmd === "clean") {
		cmdClean();
	} else if (cmd === "lsp") {
		lspRunServer();
	} else if (cmd === "build") {
		if (opts.inputFile !== "") {
			if (opts.target === Target.JS) {
				cmdBuildJS(opts.inputFile, opts.outputPath, opts);
			} else {
				cmdBuildC(opts.inputFile, opts);
			}
		} else {
			const cfg = loadBuildConfig("build.ms", opts.showTime);
			if (!cfg.valid) {
				console.log(error("error") + ": no build.ms found or missing 'root' field");
				printUsage();
				exit(1);
			}
			if (opts.verbose) {
				verboseLog("build.ms: root=" + cfg.root + " target=" + cfg.build.target);
			}
			if (opts.mode === MODE_DEBUG && cfg.build.optimize === "release") {
				opts.mode = MODE_RELEASE;
			}
			if (cfg.build.target === "js" || opts.target === Target.JS) {
				const outDir = cfg.build.outDir !== "" ? cfg.build.outDir : opts.outputPath;
				cmdBuildJS(cfg.root, outDir, opts);
			} else {
				if (opts.outputPath === "" && cfg.build.outFile !== "") {
					opts.outputPath = cfg.build.outFile;
				}
				cmdBuildC(cfg.root, opts);
			}
		}
	} else {
		console.log(error("error") + ": unknown command '" + bold(cmd) + "'");
		printUsage();
		exit(1);
	}

	return 0;
}

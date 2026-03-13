// MetaScript Compiler CLI — Entry point (dispatch only)

import { exit } from "std/process";
import { CliOptions, Target, parseArgs, MODE_DEBUG, MODE_RELEASE, MODE_DANGER } from "./compiler/options";
import { VERSION, printUsage } from "./compiler/usage";
import { cmdBuildJS, cmdBuildC, cmdRunJS, cmdRunRaiser, cmdTest } from "./compiler/compile";
import { cmdCheck, cmdDumpTokens, cmdDumpAst, cmdPipeline, cmdRun, cmdFmt, cmdInit, cmdClean } from "./compiler/commands";
import { lspRunServer } from "./compiler/lsp/server";
import { loadBuildConfig, loadFmtSection, BuildConfig } from "./compiler/buildConfig";
import { verboseLog } from "./compiler/io";
import { error, bold, green, cyan } from "./utils/color";

function requireFile(opts: CliOptions): void {
	if (opts.inputFile === "") {
		console.log(`${error("error")}: ${cyan(opts.command)} requires an input file`);
		printUsage();
		exit(1);
	}
}

export function main(): number {
	const opts = parseArgs();
	const cmd = opts.command;

	match (cmd) {
		"" | "help" => printUsage(),
		"clean" => cmdClean(),
		"lsp" => lspRunServer(),
		"init" => cmdInit(opts.inputFile),
		"version" => console.log(`${bold("Metascript")} ${green(`v${VERSION}`)}`),
		"check" => { requireFile(opts); cmdCheck(opts.inputFile, opts); },
		"dump-tokens" => { requireFile(opts); cmdDumpTokens(opts.inputFile); },
		"dump-ast" => { requireFile(opts); cmdDumpAst(opts.inputFile); },
		"pipeline" => { requireFile(opts); cmdPipeline(opts.inputFile); },
		"fmt" => { requireFile(opts); cmdFmt(opts.inputFile, opts, loadFmtSection(".")); },
		"run" => {
			// argv path overrides build.ms root; fallback to build.ms when no argv
			if (opts.inputFile === "") {
				const cfg = loadBuildConfig("build.ms", opts.showTime);
				if (cfg.valid && cfg.root.length > 0) { opts.inputFile = cfg.root; }
			}
			requireFile(opts);
			if (opts.target === Target.JS) {
				cmdRunJS(opts.inputFile, opts);
			} else if (opts.target === Target.Raiser) {
				cmdRunRaiser(opts.inputFile, opts);
			} else {
				cmdRun(opts.inputFile, opts);
			}
		},
		"test" => {
			requireFile(opts);
			if (opts.target === Target.JS) {
				cmdRunJS(opts.inputFile, opts);
			} else {
				cmdTest(opts.inputFile, opts);
			}
		},
		"build" => {
			// Load build.ms for config (target, optimize, outDir, etc.)
			const cfg = loadBuildConfig("build.ms", opts.showTime);
			// argv path overrides build.ms root
			if (opts.inputFile === "" && cfg.valid && cfg.root.length > 0) {
				opts.inputFile = cfg.root;
			}
			requireFile(opts);
			// Apply build section settings from build.ms
			if (cfg.valid) {
				if (opts.verbose) {
					verboseLog(`build.ms: root=${cfg.root} target=${cfg.build.target}`);
				}
				if (opts.mode === MODE_DEBUG && cfg.build.optimize === "release") {
					opts.mode = MODE_RELEASE;
				}
			}
			if ((cfg.valid && cfg.build.target === "js") || opts.target === Target.JS) {
				const outDir = (cfg.valid && cfg.build.outDir !== "") ? cfg.build.outDir : opts.outputPath;
				cmdBuildJS(opts.inputFile, outDir, opts);
			} else {
				if (cfg.valid && opts.outputPath === "" && cfg.build.outFile !== "") {
					opts.outputPath = cfg.build.outFile;
				}
				cmdBuildC(opts.inputFile, opts);
			}
		},
		_ => {
			console.log(`${error("error")}: unknown command '${bold(cmd)}'`);
			printUsage();
			exit(1);
		},
	};

	return 0;
}

// MetaScript Compiler CLI — Entry point (dispatch only)

import { exit, exec } from "std/process";
import { CliOptions, Target, parseArgs, MODE_DEBUG, MODE_RELEASE } from "./compiler/options";
import { VERSION, printUsage } from "./compiler/usage";
import { cmdBuildJS, cmdBuildC, cmdRunJS, cmdRunRaiser, cmdTest } from "./compiler/compile";
import { cmdCheck, cmdDumpTokens, cmdDumpAst, cmdPipeline, cmdRun, cmdFmt, cmdInit, cmdClean } from "./compiler/commands";
import { lspRunServer } from "./compiler/lsp/server";
import { loadBuildConfig, loadFmtSection, resolveCcForTarget } from "./compiler/buildConfig";
import { verboseLog } from "./compiler/io";
import { error, bold, green, cyan } from "./utils/color";
import { findProjectRoot } from "./utils/path";
import { join } from "std/fs/path";
// Import the package manager hub for test discovery. Individual commands
// (msc add, install, publish, ...) are wired up from this module as they land.
// NOTE: imported for Bun test runner (finds inline tests). The C build path
// (msc build/run src/index.ms) also compiles these modules; any link errors
// from OTHER files in the working tree are pre-existing, not caused by this import.
import { cmdAdd, cmdRemove, cmdInstall, cmdLogin, cmdLogout, cmdWhoami, cmdPublish } from "./compiler/package/index";

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

	// Find project root by walking up from the entry file (or CWD) looking for
	// build.ms. Go/Rust convention: the manifest defines the project root.
	// All manifest operations (build.ms, msc.lock) are relative to this directory.
	const projectRoot = findProjectRoot(opts.inputFile);
	const buildMsPath = join(projectRoot, "build.ms");
	opts.projectRoot = projectRoot;

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
				const cfg = loadBuildConfig(buildMsPath, opts.showTime);
				if (cfg.valid && cfg.entry.length > 0) { opts.inputFile = cfg.entry; }
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
			const cfg = loadBuildConfig(buildMsPath, opts.showTime);
			// argv path overrides build.ms root
			if (opts.inputFile === "" && cfg.valid && cfg.entry.length > 0) {
				opts.inputFile = cfg.entry;
			}
			requireFile(opts);
			// Apply build section settings from build.ms
			if (cfg.valid) {
				if (opts.verbose) {
					verboseLog(`build.ms: root=${cfg.entry} target=${cfg.build.target}`);
				}
				if (opts.mode === MODE_DEBUG && cfg.build.optimize === "release") {
					opts.mode = MODE_RELEASE;
				}
			}
			// Apply cc section from build.ms: resolve per-target config, CLI flags override
			if (cfg.valid) {
				const resolved = resolveCcForTarget(cfg.cc, opts.osTarget, opts.cpuTarget);
				if (resolved.entry !== "" && opts.inputFile === "") opts.inputFile = resolved.entry;
				if (opts.ccBinary === "" && resolved.compiler !== "") opts.ccBinary = resolved.compiler;
				if (opts.passC === "" && resolved.flags.length > 0) opts.passC = resolved.flags.join(" ");
				if (opts.passL === "" && resolved.linkFlags.length > 0) opts.passL = resolved.linkFlags.join(" ");
			}
			// Cross-compile default: prefer zig cc over platform-specific cross-gcc.
			// zig cc bundles clang + lld + sysroots for all targets — no external deps.
			// Skip for bare/solana — they resolve their own toolchains.
			if (opts.osTarget !== "" && opts.osTarget !== "bare" && opts.osTarget !== "solana" && exec("which zig > /dev/null 2>&1") === 0) {
				opts.ccBinary = "zig cc";
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
		"add" => {
			const addArgs: string[] = [];
			if (opts.inputFile !== "") addArgs.push(opts.inputFile);
			for (const ea of opts.extraArgs) { addArgs.push(ea); }
			if (!cmdAdd(projectRoot, addArgs)) exit(1);
		},
		"remove" => {
			const rmArgs: string[] = [];
			if (opts.inputFile !== "") rmArgs.push(opts.inputFile);
			if (!cmdRemove(projectRoot, rmArgs)) exit(1);
		},
		"install" => {
			if (!cmdInstall(projectRoot)) exit(1);
		},
		"login" => {
			if (!cmdLogin(projectRoot)) exit(1);
		},
		"logout" => {
			if (!cmdLogout()) exit(1);
		},
		"whoami" => {
			const whoArgs: string[] = [];
			for (const ea of opts.extraArgs) { whoArgs.push(ea); }
			if (!cmdWhoami(whoArgs)) exit(1);
		},
		"publish" => {
			const pubArgs: string[] = [];
			for (const ea of opts.extraArgs) { pubArgs.push(ea); }
			if (!cmdPublish(projectRoot, pubArgs)) exit(1);
		},
		"org" => {
			const orgArgs: string[] = [];
			if (opts.inputFile !== "") orgArgs.push(opts.inputFile);
			for (const ea of opts.extraArgs) { orgArgs.push(ea); }
			console.log("org: not available"); exit(1);
		},
		_ => {
			console.log(`${error("error")}: unknown command '${bold(cmd)}'`);
			printUsage();
			exit(1);
		},
	};

	return 0;
}

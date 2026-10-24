// MetaScript Compiler CLI — Entry point (dispatch only)

import { platform } from "std/process";
import { CliOptions, Target, parseArgs, applyProjectConfig } from "./compiler/options";
import { defineSymbol, formatDefines } from "./compiler/defines";
import { VERSION, printUsage } from "./compiler/usage";
import { cmdBuildJS, cmdBuildC, cmdWatchC, cmdRunHcr, cmdRunJS, cmdRunRaiser, cmdTest, cmdTestJS } from "./compiler/compile";
import { cmdCheck, cmdDumpTokens, cmdDumpAst, cmdPipeline, cmdRun, cmdFmt, cmdInit, cmdClean } from "./compiler/commands";
import { lspRunServer } from "./compiler/lsp/server";
import { loadBuildConfig, loadFmtSection, resolveCcForTarget } from "./compiler/buildConfig";
import { verboseLog } from "./compiler/io";
import { error, bold, green, cyan } from "./utils/color";
import { findProjectRoot } from "./utils/path";
import "./ast/childTableGuard";
import "./ast/childSlotGuard";
import { join } from "std/fs/path";
import { exists } from "std/fs";
// Import the package manager hub for test discovery. Individual commands
// (msc add, install, publish, ...) are wired up from this module as they land.
// NOTE: imported so test discovery finds these modules' inline tests; any link
// errors from OTHER files in the working tree are pre-existing, not caused by
// this import.
import { cmdAdd, cmdRemove, cmdInstall, cmdLogin, cmdLogout, cmdWhoami, cmdPublish, cmdOrg } from "./compiler/package/index";
import { cmdX, syncShims, projectShimDir, cmdInstallGlobal, globalManifestRoot, globalShimDir } from "./compiler/x";
import { maybeShowUpdateNotice, cmdUpgrade, sweepUpgradeBackups } from "./compiler/upgrade";
import { collectGlobalCache } from "./compiler/cache";

function requireFile(opts: CliOptions): void {
	if (opts.inputFile == "") {
		console.log(`${error("error")}: ${cyan(opts.command)} requires an input file`);
		printUsage();
		process.exit(1);
	}
}

export function main(): int32 {
	// Windows-only: delete stale msc.exe.bak-* files left by previous upgrades.
	// No-op on Unix. Must run before any network/heavy work.
	sweepUpgradeBackups();

	collectGlobalCache();

	const opts = parseArgs();
	const cmd = opts.command;
	if (opts.eventsPath != "" && !(cmd == "run" && opts.isHcr && opts.target != Target.JS && opts.target != Target.Raiser)) {
		console.log(`${error("error")}: --events works only with msc run --hcr`);
		process.exit(1);
	}

	// Find project root by walking up from the entry file (or CWD) looking for
	// build.ms. Go/Rust convention: the manifest defines the project root.
	// All manifest operations (build.ms, msc.lock) are relative to this directory.
	const projectRoot = findProjectRoot(opts.inputFile);
	const buildMsPath = join(projectRoot, "build.ms");
	const applied = applyProjectConfig(opts, projectRoot);
	if (!applied.ok) {
		console.log(`${error("error")}: ${applied.error}`);
		process.exit(1);
	}
	if (opts.showDefines) {
		console.log(formatDefines(opts.defines));
		process.exit(0);
	}

	match (cmd) {
		"" | "help" => printUsage(),
		"clean" => cmdClean(),
		"lsp" => lspRunServer(),
		"init" => cmdInit(opts.inputFile),
		"version" => console.log(`${bold("Metascript")} ${green(`v${VERSION}`)}`),
		"check" => {
			requireFile(opts);
			cmdCheck(opts.inputFile, opts, loadBuildConfig(buildMsPath, opts.showTime).resolve);
		},
		"dump-tokens" => { requireFile(opts); cmdDumpTokens(opts.inputFile); },
		"dump-ast" => { requireFile(opts); cmdDumpAst(opts.inputFile); },
		"pipeline" => { requireFile(opts); cmdPipeline(opts.inputFile); },
		"fmt" => { requireFile(opts); cmdFmt(opts.inputFile, opts, loadFmtSection(".")); },
		"run" => {
			// argv path overrides build.ms root; fallback to build.ms when no argv
			if (opts.inputFile == "") {
				const cfg = loadBuildConfig(buildMsPath, opts.showTime);
				if (cfg.valid && cfg.entry.length > 0) { opts.inputFile = cfg.entry; }
			}
			requireFile(opts);
			if (opts.target == Target.JS) {
				cmdRunJS(opts.inputFile, opts);
			} else if (opts.target == Target.Raiser) {
				cmdRunRaiser(opts.inputFile, opts);
			} else if (opts.isHcr) {
				cmdRunHcr(opts.inputFile, opts);
			} else {
				cmdRun(opts.inputFile, opts);
			}
		},
		"test" => {
			defineSymbol(opts.defines, "testBuild", "true");
			requireFile(opts);
			if (opts.target == Target.JS) {
				cmdTestJS(opts.inputFile, opts);
			} else {
				cmdTest(opts.inputFile, opts);
			}
		},
		"build" => {
			// Load build.ms for config (target, optimize, outDir, etc.)
			const cfg = loadBuildConfig(buildMsPath, opts.showTime);
			// argv path overrides build.ms root
			if (opts.inputFile == "" && cfg.valid && cfg.entry.length > 0) {
				opts.inputFile = cfg.entry;
			}
			requireFile(opts);
			if (cfg.valid && opts.verbose) {
				verboseLog(`build.ms: root=${cfg.entry} target=${cfg.build.target}`);
			}
			// Apply cc section from build.ms: resolve per-target config, CLI flags override
			if (cfg.valid) {
				const resolved = resolveCcForTarget(cfg.cc, opts.targetOs, opts.cpuTarget);
				if (resolved.entry != "" && opts.inputFile == "") opts.inputFile = resolved.entry;
				if (opts.ccBinary == "" && resolved.compiler != "") opts.ccBinary = resolved.compiler;
				if (opts.passC == "" && resolved.flags.length > 0) opts.passC = resolved.flags.join(" ");
				if (opts.passL == "" && resolved.linkFlags.length > 0) opts.passL = resolved.linkFlags.join(" ");
			}
			if (opts.target == Target.JS) {
				const outDir = (cfg.valid && cfg.build.outDir != "") ? cfg.build.outDir : opts.outputPath;
				cmdBuildJS(opts.inputFile, outDir, opts);
			} else {
				if (cfg.valid && opts.outputPath == "" && cfg.build.outFile != "") {
					opts.outputPath = cfg.build.outFile;
				}
				if (opts.watch) cmdWatchC(opts.inputFile, opts, cfg.resolve);
				else cmdBuildC(opts.inputFile, opts, cfg.resolve);
			}
		},
		"add" => {
			const addArgs: string[] = [];
			if (opts.inputFile != "") addArgs.push(opts.inputFile);
			for (const ea of opts.extraArgs) { addArgs.push(ea); }
			if (!cmdAdd(projectRoot, addArgs)) process.exit(1);
			if (!syncShims(projectRoot, projectShimDir(projectRoot))) process.exit(1);
		},
		"remove" => {
			let globalRemove = false;
			for (const ea of opts.extraArgs) {
				if (ea == "-g" || ea == "--global") globalRemove = true;
			}
			if (globalRemove) {
				const root = globalManifestRoot();
				if (root == "" || !exists(join(root, "build.ms"))) {
					console.log(`${error("error")}: no global manifest — nothing was installed with ${cyan("install -g")}`);
					process.exit(1);
				}
				const grArgs: string[] = [];
				if (opts.inputFile != "") grArgs.push(opts.inputFile);
				if (!cmdRemove(root, grArgs)) process.exit(1);
				if (!syncShims(root, globalShimDir())) process.exit(1);
			} else {
				const rmArgs: string[] = [];
				if (opts.inputFile != "") rmArgs.push(opts.inputFile);
				if (!cmdRemove(projectRoot, rmArgs)) process.exit(1);
				if (!syncShims(projectRoot, projectShimDir(projectRoot))) process.exit(1);
			}
		},
		"install" => {
			let globalInstall = false;
			for (const ea of opts.extraArgs) {
				if (ea == "-g" || ea == "--global") globalInstall = true;
			}
			if (globalInstall) {
				if (!cmdInstallGlobal(opts.inputFile)) process.exit(1);
			} else {
				if (!cmdInstall(projectRoot)) process.exit(1);
				if (!syncShims(projectRoot, projectShimDir(projectRoot))) process.exit(1);
			}
		},
		"login" => {
			if (!cmdLogin(projectRoot)) process.exit(1);
		},
		"logout" => {
			if (!cmdLogout()) process.exit(1);
		},
		"whoami" => {
			const whoArgs: string[] = [];
			for (const ea of opts.extraArgs) { whoArgs.push(ea); }
			if (!cmdWhoami(whoArgs)) process.exit(1);
		},
		"publish" => {
			const pubArgs: string[] = [];
			for (const ea of opts.extraArgs) { pubArgs.push(ea); }
			if (!cmdPublish(projectRoot, pubArgs)) process.exit(1);
		},
		"org" => {
			const orgArgs: string[] = [];
			if (opts.inputFile != "") orgArgs.push(opts.inputFile);
			for (const ea of opts.extraArgs) { orgArgs.push(ea); }
			if (!cmdOrg(orgArgs)) process.exit(1);
		},
		"x" => {
			const xArgs: string[] = [];
			if (opts.inputFile != "") xArgs.push(opts.inputFile);
			for (const ea of opts.extraArgs) { xArgs.push(ea); }
			if (!cmdX(projectRoot, xArgs, opts)) process.exit(1);
		},
		"upgrade" => { process.exit(cmdUpgrade(opts)); },
		_ => {
			console.log(`${error("error")}: unknown command '${bold(cmd)}'`);
			printUsage();
			process.exit(1);
		},
	};

	// Update-check hook — fires only for user-facing commands (not lsp/fmt/check
	// or developer tooling). Cached for 24h, silent on failure, opt-out via
	// MSC_NO_UPDATE_CHECK / CI. Runs AFTER the command so user output comes first.
	match (cmd) {
		"build" | "run" | "test" | "version"
			| "add" | "install" | "publish" | "login" | "whoami"
			=> { maybeShowUpdateNotice(); },
		_ => {},
	};

	return 0;
}

when (!testBuild) {
	process.exit(main());
}

// MetaScript Compiler CLI — Entry point (dispatch only)

import { CliOptions, Target, parseArgs, applyProjectConfig } from "./compiler/options";
import { defineSymbol, formatDefines } from "./compiler/defines";
import { VERSION, printUsage } from "./compiler/usage";
import { cmdBuildJS, cmdBuildC, cmdWatchC, cmdRunHcr, cmdRunJS, cmdRunRaiser, cmdTest, cmdTestJS } from "./compiler/compile";
import { cmdCheck, cmdDumpTokens, cmdDumpAst, cmdPipeline, cmdRun, cmdFmt, cmdInit, cmdClean } from "./compiler/commands";
import { lspRunServer } from "./compiler/lsp/server";
import { resolveCcForTarget } from "./compiler/buildConfig";
import { verboseLog } from "./compiler/io";
import { error, bold, green, cyan } from "./utils/color";
import { findProjectRoot } from "./utils/path";
import "./ast/childTableGuard";
import "./ast/childSlotGuard";
import "./compiler/lsp/handlers/positionsTest";
import { exists } from "std/fs";
import { join } from "std/fs/path";
import { runPackageCommand } from "./compiler/package/index";
import { cmdAdd } from "./compiler/package/add";
import { cmdRemove } from "./compiler/package/remove";
import { cmdInstall } from "./compiler/package/install";
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

// add, remove and install re-sync the command shims; -g moves remove and install to the global manifest.
function commandArgs(opts: CliOptions): string[] {
	const args: string[] = [];
	if (opts.inputFile != "") args.push(opts.inputFile);
	for (const arg of opts.extraArgs) args.push(arg);
	return args;
}

function runShimCommand(cmd: string, opts: CliOptions, projectRoot: string): boolean {
	const global = opts.extraArgs.includes("-g") || opts.extraArgs.includes("--global");
	if (cmd == "install" && global) return cmdInstallGlobal(opts.inputFile);
	let root = projectRoot;
	let shimDir = projectShimDir(projectRoot);
	if (cmd == "remove" && global) {
		root = globalManifestRoot();
		if (root == "" || !exists(join(root, "build.ms"))) {
			console.log(`${error("error")}: no global manifest — nothing was installed with ${cyan("install -g")}`);
			return false;
		}
		shimDir = globalShimDir();
	}
	const ok = match (cmd) {
		"add" => cmdAdd(root, commandArgs(opts)),
		"remove" => cmdRemove(root, opts.inputFile != "" ? [opts.inputFile] : []),
		_ => cmdInstall(root),
	};
	return ok && syncShims(root, shimDir);
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
	const applied = applyProjectConfig(opts, projectRoot);
	if (!applied.ok) {
		console.log(`${error("error")}: ${applied.error}`);
		process.exit(1);
	}
	const cfg = applied.value;
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
			cmdCheck(opts.inputFile, opts, cfg.resolve);
		},
		"dump-tokens" => { requireFile(opts); cmdDumpTokens(opts.inputFile); },
		"dump-ast" => { requireFile(opts); cmdDumpAst(opts.inputFile); },
		"pipeline" => { requireFile(opts); cmdPipeline(opts.inputFile); },
		"fmt" => { requireFile(opts); cmdFmt(opts.inputFile, opts, cfg.fmt); },
		"run" => {
			// argv path overrides build.ms root; fallback to build.ms when no argv
			if (opts.inputFile == "" && cfg.valid && cfg.entry.length > 0) { opts.inputFile = cfg.entry; }
			requireFile(opts);
			if (opts.target == Target.JS) {
				cmdRunJS(opts.inputFile, opts);
			} else if (opts.target == Target.Raiser) {
				cmdRunRaiser(opts.inputFile, opts, cfg.resolve);
			} else if (opts.isHcr) {
				cmdRunHcr(opts.inputFile, opts, cfg.resolve);
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
		"add" | "remove" | "install" => {
			if (!runShimCommand(cmd, opts, projectRoot)) process.exit(1);
		},
		"login" | "logout" | "whoami" | "publish" | "org" => {
			if (!await runPackageCommand(cmd, opts.inputFile, opts.extraArgs, projectRoot)) process.exit(1);
		},
		"x" => {
			if (!cmdX(projectRoot, commandArgs(opts), opts)) process.exit(1);
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

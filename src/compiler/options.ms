// MetaScript Compiler CLI — Argument parsing and option types

import { argv, cwd, exit, platform, arch, env } from "std/process";
import { ensureDir, writeFile, removeAll } from "std/fs";
import { isAbsolute, join, normalize } from "std/fs/path";
import { error, bold, cyan, setColorEnabled } from "../utils/color";
import { parseIntStr } from "../utils/string";
import {
	DefineTable,
	createDefineTable,
	applyDefineSwitch,
	initDefines,
	defineSymbol,
	applyConfigDefines,
	seedProjectDir,
} from "./defines";
import {
	BuildConfig, BuildSection, defaultBuildSection, loadBuildConfig, validateCacheDirectory,
} from "./buildConfig";
import { getParserDefines, setParserDefines } from "../parser/context";
import { setExtraGlobalImports, setModulePasses } from "../checker/prelude";
import { setDefaultLoopLimit } from "../raiser/vm";
import { TargetInfo, hostTargetInfo, floatInt64Align } from "../checker/types";

// -- Types --

export enum Target {
	C,
	JS,
	Raiser,
}

// Build mode: 0=debug, 1=release, 2=danger
export const MODE_DEBUG = 0;
export const MODE_RELEASE = 1;
export const MODE_DANGER = 2;
export const CC_PREPARED = 3;

export interface CliOptions {
	command: string;
	inputFile: string;
	target: Target;
	targetExplicit: boolean;   // --target= was passed, so build.ms `build.target` yields to it
	outputPath: string;
	showTime: boolean;
	verbose: boolean;
	errorMax: int32;
	vmIterations: number;    // --max-vm-iterations=<n>: Raiser VM loop budget (0 = VM default, 10M iterations)
	mode: number;
	ccCompiler: number;
	ccBinary: string;          // --cc=<path>: explicit C compiler binary (cross-compile)
	targetOs: string;          // Target OS. Always set; defaults to host platform.
	                           // Values: "linux"|"macos"|"windows"|"freebsd"|"bare"|"solana"|"wasm"|"emcc".
	                           // Cross-compile detected by callsites via `targetOs !== platform`.
	cpuTarget: string;         // --cpu=<x86_64|arm64|...>: target CPU (cross-compile)
	targetInfo: TargetInfo;
	genDeps: boolean;
	forceRebuild: boolean;
	cacheDir: string;
	globalCacheDir: string;
	globalCache: boolean;
	globalCacheExplicit: boolean;
	trimpath: boolean;
	trimpathExplicit: boolean;
	strip: boolean;
	sanitize: string;
	passC: string;
	passL: string;
	link: string[];
	emitC: boolean;
	emitJobs: int32;
	splitModules: boolean;     // --split: js target emits one ES module per source module instead of a bundle
	sourcemap: boolean;        // --sourcemap: js target writes a .map beside each output and links it
	fmtCheck: boolean;
	isHcr: boolean;
	hcrHost: boolean;          // msc run --hcr: the std host starts the program, so it must import std/hcr
	watch: boolean;
	watchReplay: string;
	eventsPath: string;        // msc run --hcr --events=<path>|-: JSON Lines of the watch session
	emitSubdir: string;
	appMode: string;           // --app=console|lib|staticlib: executable vs shared/static library
	strictNullChecks: boolean; // --strict-nil: warn on unguarded class deref
	testsInDir: boolean;       // --tests-in-dir: test runs only modules under the entry's directory
	testsShard: int32;         // --tests-shard=<i>/<n>: test runs the tested modules whose position mod n is i
	testsShards: int32;
	gcMode: string;            // --mm=drc|manual|none: memory management mode
	gcExplicit: boolean;       // true when --mm= was passed. Distinguishes an explicit
	                           // --mm=drc from the default, so target-implied modes
	                           // (--os=bare/solana => manual) never override the user.
	lto: string;               // --lto=off|thin|full: link-time optimization strategy (empty = mode default)
	autoYes: boolean;          // --yes: auto-accept managed toolchain install (also MSC_AUTO_INSTALL_CC=1)
	defines: DefineTable;      // -d:name[=value] conditional symbols (Nim condsyms.nim)
	showDefines: boolean;      // --help-defines: list every define, then exit
	projectRoot: string;       // set by CLI main from findProjectRoot() — dir containing build.ms
	extraArgs: string[];       // remaining args passed through for package manager commands (add, remove, etc.)
}

// -- Argument parsing --

function cpuPointerBytes(cpu: string): int32 {
	if (cpu == "amd64" || cpu == "x86_64" || cpu == "arm64" || cpu == "aarch64"
			|| cpu == "riscv64" || cpu == "mips64" || cpu == "mips64el"
			|| cpu == "powerpc64" || cpu == "powerpc64el" || cpu == "sparc64"
			|| cpu == "s390x" || cpu == "ia64" || cpu == "alpha" || cpu == "e2k"
			|| cpu == "loongarch64") return 8;
	if (cpu == "i386" || cpu == "386" || cpu == "arm" || cpu == "wasm32"
			|| cpu == "riscv32" || cpu == "mips" || cpu == "mipsel"
			|| cpu == "powerpc" || cpu == "sparc" || cpu == "hppa"
			|| cpu == "m68k" || cpu == "esp") return 4;
	if (cpu == "avr" || cpu == "msp430") return 2;
	return 0;
}

function cpuFloatBytes(cpu: string): int32 {
	if (cpu == "avr" || cpu == "msp430") return 4;
	return 8;
}

export function buildCpu(targetOs: string, cpuTarget: string): string {
	if (cpuTarget != "") return cpuTarget;
	if (targetOs == "wasm" || targetOs == "emcc") return "wasm32";
	if (targetOs == "solana") return "sbf";
	if (targetOs == platform || targetOs == "bare") return arch;
	return "amd64";
}

function targetCpuName(targetOs: string, cpuTarget: string): string {
	if (cpuTarget != "") return cpuTarget;
	if (targetOs == "wasm" || targetOs == "emcc") return "wasm32";
	return "";
}

export function resolveTargetSizes(targetOs: string, cpuTarget: string): TargetInfo {
	const cpu = targetCpuName(targetOs, cpuTarget);
	if (cpu == "") return hostTargetInfo();
	const bytes = cpuPointerBytes(cpu);
	if (bytes == 0) {
		console.log(`${error("error")}: unknown --cpu target: ${bold(cpu)}`);
		console.log(`  Valid: amd64, arm64, i386, arm, wasm32, riscv32, riscv64, mips, mips64, powerpc, powerpc64, sparc, sparc64, s390x, loongarch64, avr, msp430`);
		exit(1);
	}
	const t: TargetInfo = { ptrSize: bytes, floatSize: cpuFloatBytes(cpu), cpu: cpu, os: targetOs };
	return t;
}

export function newCliOptions(): CliOptions {
	return {
		command: "",
		inputFile: "",
		target: Target.C,
		targetExplicit: false,
		outputPath: "",
		showTime: false,
		verbose: false,
		errorMax: 0,
		vmIterations: 0,
		mode: MODE_DEBUG,
		ccCompiler: 0,
		ccBinary: "",
		targetOs: platform,
		cpuTarget: "",
		targetInfo: hostTargetInfo(),
		genDeps: false,
		forceRebuild: false,
		cacheDir: "",
		globalCacheDir: "",
		globalCache: true,
		globalCacheExplicit: false,
		trimpath: false,
		trimpathExplicit: false,
		strip: false,
		sanitize: "",
		passC: "",
		passL: "",
		link: [],
		emitC: false,
		emitJobs: 0,
		splitModules: false,
		sourcemap: false,
		fmtCheck: false,
		isHcr: false,
		hcrHost: false,
		watch: false,
		watchReplay: "",
		eventsPath: "",
		emitSubdir: "",
		appMode: "console",
		strictNullChecks: false,
		testsInDir: false,
		testsShard: 0,
		testsShards: 1,
		gcMode: "drc",
		gcExplicit: false,
		lto: "",
		autoYes: false,
		defines: createDefineTable(),
		showDefines: false,
		projectRoot: "",
		extraArgs: [],
	};
}

export function parseArgs(): CliOptions {
	// argv[0] = executable, argv[1] = script (or command when self-hosted binary)
	// When run via `msc run src/compiler/main.ms compile foo.ms`:
	//   argv[0]=msc, argv[1]=src/compiler/main.ms, argv[2]=compile, argv[3]=foo.ms
	// When compiled to binary `msc compile foo.ms`:
	//   argv[0]=msc, argv[1]=compile, argv[2]=foo.ms

	const opts = newCliOptions();

	if (argv.length < 2) return opts;

	// Determine argument offset: if argv[1] ends with .ms, it's the script path
	let argStart = 1;
	if (argv.length > 1 && argv[1].endsWith(".ms")) {
		argStart = 2;
	}

	if (argv.length <= argStart) return opts;

	const parsed = applyArgs(opts, argv, argStart);
	if (!parsed.ok) {
		console.log(error("error") + ": " + parsed.error);
		exit(1);
	}

	// opts.lto stays "" here when no --lto= was given: the default depends on
	// which compiler resolves (LTO capability is a compiler/target property),
	// and the compiler is not known until resolveCC runs. resolveLto (cc.ms),
	// called right after resolveCC, turns "" into thin/off per capability.

	opts.targetInfo = resolveTargetSizes(opts.targetOs, opts.cpuTarget);

	return opts;
}

function targetNamed(name: string): Result<Target, string> {
	return match (name) {
		"c" => Result.ok(Target.C),
		"js" | "javascript" => Result.ok(Target.JS),
		"raiser" | "vm" => Result.ok(Target.Raiser),
		_ => Result.err("unknown target '" + bold(name) + "'. Valid: " + cyan("c") + ", " + cyan("js") + ", " + cyan("raiser")),
	};
}

export function applyBuildTarget(opts: CliOptions, name: string): Result<void, string> {
	if (opts.targetExplicit) return Result.ok(null);
	opts.target = try targetNamed(name);
	return Result.ok(null);
}

export function seedOptionDefines(opts: CliOptions): void {
	const backendName = opts.target == Target.JS ? "js" : (opts.target == Target.Raiser ? "raiser" : "c");
	initDefines(opts.defines, backendName, opts.targetOs, buildCpu(opts.targetOs, opts.cpuTarget), opts.gcMode, opts.mode);
}

function globalImportEntry(projectRoot: string, gi: string): string {
	if (gi.length > 4 && gi.slice(0, 4) == "std/") return gi;
	if (isAbsolute(gi)) return normalize(gi);
	return normalize(join(projectRoot, gi));
}

function selectedCacheDirectory(
	cli: string,
	envName: string,
	manifest: string,
	projectRoot: string,
): Result<string, string> {
	let path = cli;
	let base = cwd();
	if (path == "") path = env.get(envName);
	if (path == "") {
		path = manifest;
		base = isAbsolute(projectRoot) ? projectRoot : join(cwd(), projectRoot);
	}
	if (path == "") return Result.ok("");
	const checked = validateCacheDirectory(path);
	if (!checked.ok) return Result.err(`${envName}: ${checked.error}`);
	return Result.ok(normalize(isAbsolute(path) ? path : join(base, path)));
}

function applyCacheConfig(
	opts: CliOptions,
	build: BuildSection,
	projectRoot: string,
): Result<void, string> {
	if (build.cacheError != "") {
		return Result.err(`${join(projectRoot, "build.ms")}: ${build.cacheError}`);
	}
	opts.cacheDir = try selectedCacheDirectory(
		opts.cacheDir, "MSC_CACHE_DIR", build.cacheDir, projectRoot,
	);
	opts.globalCacheDir = try selectedCacheDirectory(
		opts.globalCacheDir, "MSC_GLOBAL_CACHE_DIR", build.globalCacheDir, projectRoot,
	);
	if (!opts.globalCacheExplicit) opts.globalCache = build.globalCache;
	if (env.get("MSC_NO_GLOBAL_CACHE") != "") opts.globalCache = false;
	if (!opts.trimpathExplicit) opts.trimpath = env.get("MSC_TRIMPATH") != "" || build.trimpath;
	return Result.ok(null);
}

// The project's build.ms goes in before any source is parsed: target, defines under the
// command line's -d: switches, then globalImports and their module passes.
export function applyProjectConfig(opts: CliOptions, projectRoot: string): Result<BuildConfig, string> {
	setParserDefines(opts.defines);
	opts.projectRoot = projectRoot;
	const buildMsPath = join(projectRoot, "build.ms");
	const config = loadBuildConfig(projectRoot != "" ? buildMsPath : "", false);
	try applyCacheConfig(opts, config.build, projectRoot);
	if (config.valid) {
		const targeted = applyBuildTarget(opts, config.build.target);
		if (!targeted.ok) return Result.err(`${buildMsPath}: build.target: ${targeted.error}`);
		if (opts.command == "build" && opts.mode == MODE_DEBUG && config.build.optimize == "release") opts.mode = MODE_RELEASE;
	}
	seedOptionDefines(opts);
	if (config.valid) {
		seedProjectDir(opts.defines, projectRoot);
		if (config.defines.refused.length > 0) {
			return Result.err(`${buildMsPath}: define '${config.defines.refused[0]}' must be a string, a number or a boolean`);
		}
		const reserved = applyConfigDefines(opts.defines, config.defines.keys, config.defines.values);
		if (reserved != "") {
			return Result.err(`${buildMsPath}: define '${reserved}' is a name msc sets from its own options (backend, --os, --cpu, --mm, the build mode); give the project's define another name`);
		}
	}
	setExtraGlobalImports([]);
	setModulePasses([], []);
	const giCfg = loadBuildConfig(projectRoot != "" ? buildMsPath : "", false);
	if (giCfg.valid && giCfg.globalImports.length > 0) {
		const extras: string[] = [];
		for (const gi of giCfg.globalImports) extras.push(globalImportEntry(projectRoot, gi));
		setExtraGlobalImports(extras, buildMsPath);
		const passFrom: string[] = [];
		for (const from of giCfg.modulePassFrom) passFrom.push(globalImportEntry(projectRoot, from));
		setModulePasses(passFrom, giCfg.modulePassMacro);
	}
	return Result.ok(config);
}

function isPackageCommand(command: string): boolean {
	return command == "add" || command == "remove" || command == "install" || command == "update" || command == "publish" || command == "login" || command == "logout" || command == "whoami" || command == "org";
}

export function applyArgs(opts: CliOptions, args: string[], argStart: int32): Result<void, string> {
	let positionalIdx = 0;
	let i = argStart;
	while (i < args.length) {
		const arg = args[i];
		if (opts.command == "run" && opts.inputFile != "") {
			if (opts.extraArgs.length == 0 && arg.startsWith("-")) {
				const own = applyArgs(newCliOptions(), [arg], 0);
				if (own.ok) return Result.err(`'${arg}' after ${opts.inputFile} is an msc option; put it before the file: msc run ${arg} ${opts.inputFile}`);
				if (own.error != `unknown option '${arg}'`) return own;
			}
			opts.extraArgs.push(arg);
			i += 1;
			continue;
		}
		if (opts.command == "x" && positionalIdx >= 1) {
			if (opts.inputFile == "") {
				opts.inputFile = arg;
			} else {
				opts.extraArgs.push(arg);
			}
			positionalIdx += 1;
			i += 1;
			continue;
		}
		if (arg == "--help" || arg == "-h") {
			opts.command = "help";
		} else if (arg == "--version" || arg == "-v") {
			opts.command = "version";
		} else if (arg.startsWith("--target=")) {
			const named = targetNamed(arg.slice(9, arg.length));
			if (!named.ok) {
				console.log(error("error") + ": " + named.error);
				exit(1);
			}
			opts.target = named.value;
			opts.targetExplicit = true;
		} else if (arg.startsWith("--output=")) {
			opts.outputPath = arg.slice(9, arg.length);
		} else if (arg.startsWith("-o=")) {
			opts.outputPath = arg.slice(3, arg.length);
		} else if (arg == "--time" || arg == "-t") {
			opts.showTime = true;
		} else if (arg == "--verbose") {
			opts.verbose = true;
		} else if (arg.startsWith("--error-max=")) {
			opts.errorMax = parseIntStr(arg.slice(12, arg.length));
		} else if (arg.startsWith("--max-vm-iterations=")) {
			opts.vmIterations = parseIntStr(arg.slice(20, arg.length));
			// Applied at parse time: the comptime engine builds its VM lazily
			// long after parsing, and createVM reads this default.
			setDefaultLoopLimit(opts.vmIterations);
		} else if (arg == "--release") {
			opts.mode = MODE_RELEASE;
		} else if (arg == "--danger") {
			opts.mode = MODE_DANGER;
		} else if (arg.startsWith("--cc=")) {
			const ccVal = arg.slice(5, arg.length);
			if (ccVal == "clang") { opts.ccCompiler = 1; }
			else if (ccVal == "gcc") { opts.ccCompiler = 2; }
			else { opts.ccBinary = ccVal; }
		} else if (arg.startsWith("--os=")) {
			const osVal = arg.slice(5, arg.length);
			if (osVal != "bare" && osVal != "solana" && osVal != "wasm" && osVal != "emcc" && osVal != "linux" && osVal != "macos" && osVal != "windows" && osVal != "darwin" && osVal != "freebsd" && osVal != "ios" && osVal != "android") {
				return Result.err(`unknown --os target: "${osVal}"\n  Valid targets: bare, solana, wasm, emcc, linux, macos, windows, ios, android`);
			}
			opts.targetOs = osVal;
		} else if (arg.startsWith("--cpu=")) {
			opts.cpuTarget = arg.slice(6, arg.length);
		} else if (arg == "--gendeps") {
			opts.genDeps = true;
		} else if (arg == "--force" || arg == "-f") {
			opts.forceRebuild = true;
		} else if (arg == "--cache-dir" || arg.startsWith("--cache-dir=") ||
			arg == "--global-cache-dir" || arg.startsWith("--global-cache-dir=")) {
			const local = arg == "--cache-dir" || arg.startsWith("--cache-dir=");
			const flag = local ? "--cache-dir" : "--global-cache-dir";
			let value = "";
			if (arg == flag) {
				if (i + 1 >= args.length || args[i + 1].startsWith("-")) {
					return Result.err(`${flag}: expected a non-empty path`);
				}
				i += 1;
				value = args[i];
			} else {
				value = arg.slice(flag.length + 1);
			}
			const checked = validateCacheDirectory(value);
			if (!checked.ok) return Result.err(`${flag}: ${checked.error}`);
			if (local) opts.cacheDir = value;
			else opts.globalCacheDir = value;
		} else if (arg == "--global-cache" || arg == "--no-global-cache") {
			opts.globalCache = arg == "--global-cache";
			opts.globalCacheExplicit = true;
		} else if (arg == "--trimpath" || arg == "--no-trimpath") {
			opts.trimpath = arg == "--trimpath";
			opts.trimpathExplicit = true;
		} else if (arg == "--strip") {
			opts.strip = true;
		} else if (arg.startsWith("--sanitize=")) {
			opts.sanitize = arg.slice(11, arg.length);
		} else if (arg.startsWith("--passC=")) {
			if (opts.passC.length > 0) opts.passC = opts.passC + " ";
			opts.passC = opts.passC + arg.slice(8, arg.length);
		} else if (arg.startsWith("--passL=")) {
			if (opts.passL.length > 0) opts.passL = opts.passL + " ";
			opts.passL = opts.passL + arg.slice(8, arg.length);
		} else if (arg.startsWith("--link=")) {
			const file = arg.slice(7, arg.length);
			opts.link.push(isAbsolute(file) ? normalize(file) : normalize(join(cwd(), file)));
		} else if (arg == "--check") {
			opts.fmtCheck = true;
		} else if (arg == "--hcr") {
			opts.isHcr = true;
			defineSymbol(opts.defines, "hcr", "true");
		} else if (arg == "--watch") {
			opts.watch = true;
		} else if (arg.startsWith("--watch-replay=")) {
			opts.watch = true;
			opts.watchReplay = arg.slice(15, arg.length);
		} else if (arg.startsWith("--events=")) {
			opts.eventsPath = arg.slice(9, arg.length);
		} else if (arg.startsWith("--app=")) {
			const appVal = arg.slice(6, arg.length);
			if (appVal == "console" || appVal == "lib" || appVal == "staticlib") {
				opts.appMode = appVal;
			} else {
				console.log(error("error") + ": unknown --app mode '" + bold(appVal) + "'. Valid: " + cyan("console") + ", " + cyan("lib") + ", " + cyan("staticlib"));
				exit(1);
			}
		} else if (arg == "--strict-nil") {
			opts.strictNullChecks = true;
		} else if (arg == "--tests-in-dir") {
			opts.testsInDir = true;
		} else if (arg.startsWith("--tests-shard=")) {
			const spec = arg.slice(14, arg.length);
			const shard = testsShardOf(spec);
			if (shard.length == 0) {
				console.log(error("error") + ": --tests-shard wants <index>/<count> with 0 <= index < count, got '" + bold(spec) + "'");
				exit(1);
			}
			opts.testsShard = shard[0];
			opts.testsShards = shard[1];
		} else if (arg.startsWith("--mm=")) {
			const mm = arg.slice(5, arg.length);
			if (mm != "drc" && mm != "manual" && mm != "none") return Result.err(`unknown memory management '${mm}'. Valid: --mm=drc|manual|none`);
			opts.gcMode = mm;
			opts.gcExplicit = true;
		} else if (arg == "--gc" || arg.startsWith("--gc=")) {
			return Result.err(`'${arg}' is gone: memory management is --mm=drc|manual|none, and drc always collects cycles`);
		} else if (arg.startsWith("--lto=")) {
			const ltoVal = arg.slice(6, arg.length);
			if (ltoVal == "off" || ltoVal == "thin" || ltoVal == "full") {
				opts.lto = ltoVal;
			} else {
				console.log(error("error") + ": unknown --lto strategy '" + bold(ltoVal) + "'. Valid: " + cyan("off") + ", " + cyan("thin") + ", " + cyan("full"));
				exit(1);
			}
		} else if (arg == "--yes" || arg == "-y") {
			opts.autoYes = true;
		} else if (arg == "--emit=c") {
			opts.emitC = true;
		} else if (arg.startsWith("--emit-jobs=")) {
			opts.emitJobs = parseIntStr(arg.slice(12, arg.length));
			if (opts.emitJobs < 1) {
				console.log(error("error") + ": --emit-jobs must be at least 1");
				exit(1);
			}
		} else if (arg == "--split") {
			opts.splitModules = true;
		} else if (arg == "--sourcemap") {
			opts.sourcemap = true;
		} else if (arg.startsWith("-d:") || arg.startsWith("-d=") || arg.startsWith("--define:") || arg.startsWith("--define=")) {
			applyDefineSwitch(opts.defines, arg);
		} else if (arg == "--help-defines") {
			opts.showDefines = true;
		} else if (arg == "--colors=on") {
			setColorEnabled(true);
		} else if (arg == "--colors=off" || arg == "--no-color") {
			setColorEnabled(false);
		} else if (!arg.startsWith("-")) {
			if (positionalIdx == 0) {
				opts.command = arg;
			} else if (positionalIdx == 1) {
				opts.inputFile = arg;
			} else if (isPackageCommand(opts.command)) {
				opts.extraArgs.push(arg);
			} else {
				return Result.err(`unexpected argument '${arg}' after ${opts.inputFile}: msc ${opts.command} takes one file`);
			}
			positionalIdx += 1;
		} else if (isPackageCommand(opts.command)) {
			// Package manager commands: pass unknown flags through
			opts.extraArgs.push(arg);
		} else {
			return Result.err(`unknown option '${arg}'`);
		}
		i += 1;
	}
	if (opts.targetOs == "solana" && opts.mode == MODE_DANGER) {
		return Result.err("--danger is refused on --os=solana: it drops the bound, range, object and division checks that guard a program fed adversarial input\n  → use --release, which links with LTO on this target");
	}
	if (opts.target == Target.Raiser && (opts.command == "build" || opts.command == "test")) {
		return Result.err(`msc ${opts.command} has no Raiser output; --target=raiser runs a program: msc run --target=raiser ${opts.inputFile}`);
	}
	if (opts.target == Target.Raiser && opts.gcMode != "drc") {
		return Result.err(`--mm=${opts.gcMode} has no Raiser memory model; --target=raiser runs drc only`);
	}
	return Result.ok(null);
}

export function testsShardOf(spec: string): int32[] {
	const parts = spec.split("/");
	if (parts.length != 2) return [];
	const shard = parts[0].parseInt();
	const shards = parts[1].parseInt();
	if (shard.toString() != parts[0] || shards.toString() != parts[1]) return [];
	if (shards < 1 || shard < 0 || shard >= shards) return [];
	return [shard as int32, shards as int32];
}

// ===== Tests =====

test "a tests shard is <index>/<count> with the index below the count" {
	const ok = testsShardOf("2/3");
	assert ok.length == 2 && ok[0] == 2 && ok[1] == 3;
	assert testsShardOf("0/1").length == 2;
	for (const bad of ["3/3", "x/2", "1", "-1/2", "01/2", "0/0", "1/2/3", "/2", "1/"]) {
		assert testsShardOf(bad).length == 0;
	}
}

test "pointer width follows the target cpu, not the host" {
	assert resolveTargetSizes("macos", "").ptrSize == 8;
	assert resolveTargetSizes("wasm", "").ptrSize == 4;
	assert resolveTargetSizes("emcc", "").ptrSize == 4;
	assert resolveTargetSizes("bare", "i386").ptrSize == 4;
	assert resolveTargetSizes("linux", "arm64").ptrSize == 8;
}

test "float width follows the target cpu too" {
	assert resolveTargetSizes("macos", "").floatSize == 8;
	assert resolveTargetSizes("wasm", "").floatSize == 8;
	assert resolveTargetSizes("bare", "avr").floatSize == 4;
	assert resolveTargetSizes("bare", "msp430").floatSize == 4;
}

test "an explicit cpu outranks the os-implied one" {
	assert resolveTargetSizes("wasm", "amd64").ptrSize == 8;
}

test "int64 alignment packs to 4 only on i386 outside windows" {
	assert floatInt64Align(resolveTargetSizes("linux", "i386")) == 4;
	assert floatInt64Align(resolveTargetSizes("windows", "i386")) == 8;
	assert floatInt64Align(resolveTargetSizes("wasm", "")) == 8;
	assert floatInt64Align(resolveTargetSizes("bare", "arm")) == 8;
	assert floatInt64Align(resolveTargetSizes("macos", "")) == 8;
}

test "buildCpu: a host build and a bare build take the compiler's own cpu" {
	assert buildCpu(platform, "") == arch;
	assert buildCpu("bare", "") == arch;
}

test "buildCpu: a cross build without --cpu takes amd64, as the C compiler is told" {
	assert buildCpu(platform == "linux" ? "windows" : "linux", "") == "amd64";
}

test "buildCpu: --cpu wins, wasm and emcc are wasm32, solana is sbf" {
	assert buildCpu("linux", "arm64") == "arm64";
	assert buildCpu(platform, "i386") == "i386";
	assert buildCpu("wasm", "") == "wasm32";
	assert buildCpu("emcc", "") == "wasm32";
	assert buildCpu("solana", "") == "sbf";
}

function parseForTest(args: string[]): CliOptions {
	const opts = newCliOptions();
	applyArgs(opts, args, 0);
	return opts;
}

test "run: positionals after the file are the program's arguments" {
	const opts = parseForTest(["run", "cli.ms", "a", "b c"]);
	assert opts.command == "run";
	assert opts.inputFile == "cli.ms";
	assert opts.extraArgs.length == 2;
	assert opts.extraArgs[0] == "a" && opts.extraArgs[1] == "b c";
}

test "run: msc options go before the file and stay msc's" {
	const opts = parseForTest(["run", "--target=js", "--release", "cli.ms", "a"]);
	assert opts.target == Target.JS;
	assert opts.mode == MODE_RELEASE;
	assert opts.extraArgs.length == 1 && opts.extraArgs[0] == "a";
}

test "run: everything after the first program argument is the program's, flags and -- included" {
	const opts = parseForTest(["run", "cli.ms", "a", "--release", "--target=js", "--", "-x"]);
	assert opts.target == Target.C;
	assert opts.mode != MODE_RELEASE;
	assert opts.extraArgs.length == 5;
	assert opts.extraArgs[1] == "--release" && opts.extraArgs[2] == "--target=js";
	assert opts.extraArgs[3] == "--" && opts.extraArgs[4] == "-x";
}

test "run: a flag msc does not know goes to the program even right after the file" {
	const opts = parseForTest(["run", "cli.ms", "--foo", "b"]);
	assert opts.extraArgs.length == 2 && opts.extraArgs[0] == "--foo";
}

test "run: an msc option right after the file is an error that says to move it before the file" {
	const opts = newCliOptions();
	const r = applyArgs(opts, ["run", "cli.ms", "--target=raiser", "a"], 0);
	assert !r.ok;
	if (!r.ok) {
		assert r.error == "'--target=raiser' after cli.ms is an msc option; put it before the file: msc run --target=raiser cli.ms";
	}
	assert opts.target == Target.C;
	assert opts.extraArgs.length == 0;
}

test "build and test refuse --target=raiser instead of building C, whichever order the flags come in" {
	for (const command of ["build", "test"]) {
		const r = applyArgs(newCliOptions(), [command, "--target=raiser", "a.ms"], 0);
		assert !r.ok;
		if (!r.ok) { assert r.error == `msc ${command} has no Raiser output; --target=raiser runs a program: msc run --target=raiser a.ms`; }
		assert !applyArgs(newCliOptions(), ["--target=vm", command, "a.ms"], 0).ok;
	}
	assert applyArgs(newCliOptions(), ["run", "--target=raiser", "a.ms"], 0).ok;
	assert applyArgs(newCliOptions(), ["check", "--target=raiser", "a.ms"], 0).ok;
}

test "run: a refused msc option right after the file reports its own error instead of reaching the program" {
	const opts = newCliOptions();
	const r = applyArgs(opts, ["run", "cli.ms", "--gc=drc"], 0);
	assert !r.ok;
	if (!r.ok) { assert r.error == "'--gc=drc' is gone: memory management is --mm=drc|manual|none, and drc always collects cycles"; }
	assert opts.extraArgs.length == 0;
	assert applyArgs(newCliOptions(), ["run", "cli.ms", "--foo"], 0).ok;
}

test "run: -d: right after the file is an msc option too" {
	const r = applyArgs(newCliOptions(), ["run", "cli.ms", "-d:foo"], 0);
	assert !r.ok;
}

test "--mm picks the memory management, and --gc is refused with the --mm spelling" {
	for (const mm of ["drc", "manual", "none"]) {
		const opts = newCliOptions();
		assert applyArgs(opts, ["build", "a.ms", "--mm=" + mm], 0).ok;
		assert opts.gcMode == mm;
		assert opts.gcExplicit;
	}
	assert newCliOptions().gcMode == "drc";
	const orc = applyArgs(newCliOptions(), ["build", "a.ms", "--mm=orc"], 0);
	assert !orc.ok;
	if (!orc.ok) { assert orc.error == "unknown memory management 'orc'. Valid: --mm=drc|manual|none"; }
	for (const old of ["--gc=drc", "--gc=orc", "--gc=manual", "--gc"]) {
		const r = applyArgs(newCliOptions(), ["build", "a.ms", old], 0);
		assert !r.ok;
		if (!r.ok) { assert r.error == `'${old}' is gone: memory management is --mm=drc|manual|none, and drc always collects cycles`; }
	}
}

test "an unknown flag outside run is an error" {
	const opts = newCliOptions();
	const r = applyArgs(opts, ["build", "cli.ms", "--foo"], 0);
	assert !r.ok;
	if (!r.ok) { assert r.error == "unknown option '--foo'"; }
}

test "an argument after the file is an error for a command that takes one file" {
	const opts = newCliOptions();
	const r = applyArgs(opts, ["build", "a.ms", "--os=solana", " --danger"], 0);
	assert !r.ok;
	if (!r.ok) { assert r.error == "unexpected argument ' --danger' after a.ms: msc build takes one file"; }
	assert opts.mode != MODE_DANGER;
	for (const command of ["build", "test", "check", "fmt"]) {
		assert !applyArgs(newCliOptions(), [command, "a.ms", "b.ms"], 0).ok;
		assert !applyArgs(newCliOptions(), ["--release", command, "a.ms", "--danger", "b.ms"], 0).ok;
	}
}

test "--danger is an error on --os=solana whichever order the flags come in" {
	assert !applyArgs(newCliOptions(), ["build", "a.ms", "--os=solana", "--danger"], 0).ok;
	assert !applyArgs(newCliOptions(), ["build", "a.ms", "--danger", "--os=solana"], 0).ok;
	assert applyArgs(newCliOptions(), ["build", "a.ms", "--os=solana", "--release"], 0).ok;
	assert applyArgs(newCliOptions(), ["build", "a.ms", "--os=bare", "--danger"], 0).ok;
}

test "a package command still takes flags through" {
	const opts = parseForTest(["add", "pkg", "--dev", "x"]);
	assert opts.extraArgs.length == 2 && opts.extraArgs[0] == "--dev";
}

test "x forwards everything after the tool name, flags included" {
	const opts = parseForTest(["x", "tool", "--foo", "a", "--"]);
	assert opts.inputFile == "tool";
	assert opts.extraArgs.length == 3 && opts.extraArgs[0] == "--foo" && opts.extraArgs[2] == "--";
}

test "an unknown --os target is an error result, not a silent stop" {
	const opts = newCliOptions();
	const r = applyArgs(opts, ["build", "a.ms", "--os=plan9"], 0);
	assert !r.ok;
}

test "cache directory switches accept equals and separate path forms" {
	for (const args of [
		["build", "--cache-dir=local", "--global-cache-dir=shared"],
		["build", "--cache-dir", "local", "--global-cache-dir", "shared"],
	]) {
		const opts = newCliOptions();
		assert applyArgs(opts, args, 0).ok;
		assert opts.cacheDir == "local";
		assert opts.globalCacheDir == "shared";
	}
}

test "cache directory switches refuse missing empty and flag arguments" {
	for (const flag of ["--cache-dir", "--global-cache-dir"]) {
		for (const args of [[flag], [flag + "="], [flag, ""], [flag, "--release"]]) {
			const parsed = applyArgs(newCliOptions(), args, 0);
			assert !parsed.ok;
			if (!parsed.ok) assert parsed.error.startsWith(flag + ":");
		}
		for (const path of ["a\0b", "a\nb", "a\rb", "a\tb"]) {
			assert !applyArgs(newCliOptions(), [flag + "=" + path], 0).ok;
		}
	}
}

test "the last explicit global cache toggle wins" {
	const opts = newCliOptions();
	assert opts.globalCache && !opts.globalCacheExplicit;
	assert applyArgs(opts, ["--no-global-cache", "--global-cache"], 0).ok;
	assert opts.globalCache && opts.globalCacheExplicit;
	assert applyArgs(opts, ["--global-cache", "--no-global-cache"], 0).ok;
	assert !opts.globalCache && opts.globalCacheExplicit;
}

test "the last explicit trimpath toggle wins and is off by default" {
	const opts = newCliOptions();
	assert !opts.trimpath && !opts.trimpathExplicit;
	assert applyArgs(opts, ["--trimpath", "--no-trimpath"], 0).ok;
	assert !opts.trimpath && opts.trimpathExplicit;
	assert applyArgs(opts, ["--trimpath"], 0).ok;
	assert opts.trimpath;
}

test "trimpath takes the command line, then the environment, then build.ms" {
	withCacheEnvironment(() => {
		const saved = env.get("MSC_TRIMPATH");
		const build = defaultBuildSection();
		env.delete("MSC_TRIMPATH");
		const off = newCliOptions();
		assert applyCacheConfig(off, build, "").ok && !off.trimpath;
		build.trimpath = true;
		const manifest = newCliOptions();
		assert applyCacheConfig(manifest, build, "").ok && manifest.trimpath;
		build.trimpath = false;
		env.set("MSC_TRIMPATH", "1");
		const fromEnv = newCliOptions();
		assert applyCacheConfig(fromEnv, build, "").ok && fromEnv.trimpath;
		const cli = newCliOptions();
		assert applyArgs(cli, ["--no-trimpath"], 0).ok;
		assert applyCacheConfig(cli, build, "").ok && !cli.trimpath;
		if (saved == "") env.delete("MSC_TRIMPATH"); else env.set("MSC_TRIMPATH", saved);
	});
}

test "run cache options obey the existing file argument boundary" {
	for (const flag of ["--cache-dir=local", "--global-cache-dir=shared", "--no-global-cache"]) {
		assert !applyArgs(newCliOptions(), ["run", "app.ms", flag], 0).ok;
		const opts = newCliOptions();
		assert applyArgs(opts, ["run", "app.ms", "argument", flag], 0).ok;
		assert opts.extraArgs[1] == flag;
		assert opts.cacheDir == "" && opts.globalCacheDir == "" && opts.globalCache;
	}
	const before = newCliOptions();
	assert applyArgs(before, ["run", "--cache-dir", "local", "app.ms"], 0).ok;
	assert before.cacheDir == "local" && before.inputFile == "app.ms";
}

function withCacheEnvironment(run: () => void): void {
	const names = ["MSC_CACHE_DIR", "MSC_GLOBAL_CACHE_DIR", "MSC_NO_GLOBAL_CACHE"];
	const saved: string[] = [];
	for (const name of names) saved.push(env.get(name));
	try {
		for (const name of names) env.delete(name);
		run();
	} finally {
		for (let i: int32 = 0; i < names.length; i += 1) {
			if (saved[i] == "") env.delete(names[i]);
			else env.set(names[i], saved[i]);
		}
	}
}

test "cache paths use CLI then environment then manifest with their respective bases" {
	withCacheEnvironment(() => {
		const project = normalize(join(cwd(), "out/test/cacheProject"));
		const build = defaultBuildSection();
		build.cacheDir = "manifest/../local";
		build.globalCacheDir = "manifest/../shared";
		const manifest = newCliOptions();
		assert applyCacheConfig(manifest, build, project).ok;
		assert manifest.cacheDir == normalize(join(project, "local"));
		assert manifest.globalCacheDir == normalize(join(project, "shared"));
		env.set("MSC_CACHE_DIR", "environment/../envLocal");
		env.set("MSC_GLOBAL_CACHE_DIR", "environment/../envShared");
		const environment = newCliOptions();
		assert applyCacheConfig(environment, build, project).ok;
		assert environment.cacheDir == normalize(join(cwd(), "envLocal"));
		assert environment.globalCacheDir == normalize(join(cwd(), "envShared"));
		const cli = newCliOptions();
		cli.cacheDir = "command/../cliLocal";
		cli.globalCacheDir = "command/../cliShared";
		assert applyCacheConfig(cli, build, project).ok;
		assert cli.cacheDir == normalize(join(cwd(), "cliLocal"));
		assert cli.globalCacheDir == normalize(join(cwd(), "cliShared"));
		assert env.get("MSC_CACHE_DIR") == "environment/../envLocal";
		assert env.get("MSC_GLOBAL_CACHE_DIR") == "environment/../envShared";
	});
}

test "absolute cache paths stay absolute for every source" {
	withCacheEnvironment(() => {
		const project = normalize(join(cwd(), "out/test/cacheProject"));
		const local = normalize(join(cwd(), "absoluteLocal"));
		const shared = normalize(join(cwd(), "absoluteShared"));
		const build = defaultBuildSection();
		build.cacheDir = local;
		build.globalCacheDir = shared;
		for (let source: int32 = 0; source < 3; source += 1) {
			const opts = newCliOptions();
			if (source == 1) {
				env.set("MSC_CACHE_DIR", local);
				env.set("MSC_GLOBAL_CACHE_DIR", shared);
			}
			if (source == 2) {
				opts.cacheDir = local;
				opts.globalCacheDir = shared;
			}
			assert applyCacheConfig(opts, build, project).ok;
			assert opts.cacheDir == local && opts.globalCacheDir == shared;
		}
	});
}

test "unset and empty environment cache paths preserve provider defaults" {
	withCacheEnvironment(() => {
		for (let source: int32 = 0; source < 2; source += 1) {
			if (source == 1) {
				env.set("MSC_CACHE_DIR", "");
				env.set("MSC_GLOBAL_CACHE_DIR", "");
			}
			const opts = newCliOptions();
			assert applyCacheConfig(opts, defaultBuildSection(), "").ok;
			assert opts.cacheDir == "" && opts.globalCacheDir == "";
			assert opts.globalCache;
		}
	});
}

test "cache path selection does not interpolate tilde or environment references" {
	withCacheEnvironment(() => {
		const opts = newCliOptions();
		opts.cacheDir = "~/local";
		opts.globalCacheDir = "$HOME/shared";
		assert applyCacheConfig(opts, defaultBuildSection(), "").ok;
		assert opts.cacheDir == normalize(join(cwd(), "~/local"));
		assert opts.globalCacheDir == normalize(join(cwd(), "$HOME/shared"));
	});
}

test "global cache sharing policy is independent of every directory source" {
	withCacheEnvironment(() => {
		const build = defaultBuildSection();
		build.globalCacheDir = "manifestShared";
		build.globalCache = false;
		for (let source: int32 = 0; source < 3; source += 1) {
			const opts = newCliOptions();
			if (source == 1) env.set("MSC_GLOBAL_CACHE_DIR", "envShared");
			if (source == 2) opts.globalCacheDir = "cliShared";
			assert applyCacheConfig(opts, build, cwd()).ok;
			assert opts.globalCacheDir != "";
			assert !opts.globalCache;
		}
		const enabled = newCliOptions();
		assert applyArgs(enabled, ["--global-cache"], 0).ok;
		assert applyCacheConfig(enabled, build, cwd()).ok;
		assert enabled.globalCache;
		build.globalCache = true;
		const disabled = newCliOptions();
		assert applyArgs(disabled, ["--no-global-cache"], 0).ok;
		assert applyCacheConfig(disabled, build, cwd()).ok;
		assert !disabled.globalCache;
		env.set("MSC_NO_GLOBAL_CACHE", "1");
		assert applyCacheConfig(enabled, build, cwd()).ok;
		assert !enabled.globalCache && enabled.globalCacheDir != "";
	});
}

test "unsafe selected environment cache paths fail with the variable name" {
	withCacheEnvironment(() => {
		for (const name of ["MSC_CACHE_DIR", "MSC_GLOBAL_CACHE_DIR"]) {
			env.set(name, "unsafe\npath");
			const resolved = applyCacheConfig(newCliOptions(), defaultBuildSection(), "");
			assert !resolved.ok;
			if (!resolved.ok) assert resolved.error.startsWith(name + ":");
			env.delete(name);
		}
	});
}

test "invalid project cache declarations fail even under CLI and environment overrides" {
	withCacheEnvironment(() => {
		const project = normalize(join(cwd(), `out/test/cacheConfig${Date.now()}`));
		const parserDefines = getParserDefines();
		try {
			const made = ensureDir(project);
			assert made.ok;
			env.set("MSC_CACHE_DIR", "envLocal");
			env.set("MSC_GLOBAL_CACHE_DIR", "envShared");
			const declarations = ['cacheDir: ""', "globalCacheDir: path", 'globalCache: "no"'];
			for (const declaration of declarations) {
				const written = writeFile(
					join(project, "build.ms"), `const config = { build: { ${declaration} } };`,
				);
				assert written.ok;
				const opts = newCliOptions();
				opts.cacheDir = "cliLocal";
				opts.globalCacheDir = "cliShared";
				assert applyArgs(opts, ["--global-cache"], 0).ok;
				const configured = applyProjectConfig(opts, project);
				assert !configured.ok;
				if (!configured.ok) {
					assert configured.error.startsWith(join(project, "build.ms") + ": build.");
				}
			}
		} finally {
			setParserDefines(parserDefines);
			removeAll(project);
		}
	});
}

test "a relative project root still produces absolute manifest cache paths" {
	withCacheEnvironment(() => {
		const build = defaultBuildSection();
		build.cacheDir = "local";
		build.globalCacheDir = "shared";
		const opts = newCliOptions();
		assert applyCacheConfig(opts, build, "out/test/cacheProject").ok;
		assert opts.cacheDir == normalize(join(cwd(), "out/test/cacheProject/local"));
		assert opts.globalCacheDir == normalize(join(cwd(), "out/test/cacheProject/shared"));
	});
}

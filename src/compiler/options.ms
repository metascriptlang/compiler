// MetaScript Compiler CLI — Argument parsing and option types

import { argv, exit, platform, arch } from "std/process";
import { error, bold, cyan, setColorEnabled } from "../utils/color";
import { parseIntStr } from "../utils/string";
import { DefineTable, createDefineTable, applyDefineSwitch, initDefines, formatDefines } from "./defines";
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

export interface CliOptions {
	command: string;
	inputFile: string;
	target: Target;
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
	strip: boolean;
	sanitize: string;
	passC: string;
	passL: string;
	emitC: boolean;
	emitJobs: int32;
	splitModules: boolean;     // --split: js target emits one ES module per source module instead of a bundle
	sourcemap: boolean;        // --sourcemap: js target writes a .map beside each output and links it
	fmtCheck: boolean;
	isHcr: boolean;
	watch: boolean;
	watchReplay: string;
	emitSubdir: string;
	appMode: string;           // --app=console|lib|staticlib: executable vs shared/static library
	strictDefs: boolean;       // --strict-defs: warn on all uninit var use
	strictNullChecks: boolean; // --strict-nil: warn on unguarded class deref
	testsInDir: boolean;       // --tests-in-dir: test runs only modules under the entry's directory
	testsShard: int32;         // --tests-shard=<i>/<n>: test runs the tested modules whose position mod n is i
	testsShards: int32;
	gcMode: string;            // --gc=drc|none|manual: memory management mode
	gcExplicit: boolean;       // true when --gc= was passed. Distinguishes an explicit
	                           // --gc=orc from the default, so target-implied modes
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

function newCliOptions(): CliOptions {
	return {
		command: "",
		inputFile: "",
		target: Target.C,
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
		strip: false,
		sanitize: "",
		passC: "",
		passL: "",
		emitC: false,
		emitJobs: 0,
		splitModules: false,
		sourcemap: false,
		fmtCheck: false,
		isHcr: false,
		watch: false,
		watchReplay: "",
		emitSubdir: "",
		appMode: "console",
		strictDefs: false,
		strictNullChecks: false,
		testsInDir: false,
		testsShard: 0,
		testsShards: 1,
		gcMode: "orc",
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

	// Seeded last because backend/os/gc/mode are only final once every switch has
	// been read; `seed` skips names the user already set, so -d: still wins
	// (Nim reaches the same precedence by seeding first — condsyms.nim:34 before
	// commands.nim:703).
	const backendName = opts.target == Target.JS ? "js" : (opts.target == Target.Raiser ? "raiser" : "c");
	initDefines(opts.defines, backendName, opts.targetOs, buildCpu(opts.targetOs, opts.cpuTarget), opts.gcMode, opts.mode);
	if (opts.showDefines) {
		console.log(formatDefines(opts.defines));
		exit(0);
	}

	opts.targetInfo = resolveTargetSizes(opts.targetOs, opts.cpuTarget);

	return opts;
}

export function applyArgs(opts: CliOptions, args: string[], argStart: int32): Result<void, string> {
	let positionalIdx = 0;
	let i = argStart;
	while (i < args.length) {
		const arg = args[i];
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
		if (arg == "--" && opts.command == "run") {
			for (let j = i + 1; j < args.length; j += 1) { opts.extraArgs.push(args[j]); }
			break;
		}
		if (arg == "--help" || arg == "-h") {
			opts.command = "help";
		} else if (arg == "--version" || arg == "-v") {
			opts.command = "version";
		} else if (arg.startsWith("--target=")) {
			const targetStr = arg.slice(9, arg.length);
			if (targetStr == "js" || targetStr == "javascript") {
				opts.target = Target.JS;
			} else if (targetStr == "c") {
				opts.target = Target.C;
			} else if (targetStr == "raiser" || targetStr == "vm") {
				opts.target = Target.Raiser;
			} else {
				console.log(error("error") + ": unknown target '" + bold(targetStr) + "'. Valid: " + cyan("c") + ", " + cyan("js") + ", " + cyan("raiser"));
				exit(1);
			}
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
		} else if (arg == "--check") {
			opts.fmtCheck = true;
		} else if (arg == "--hcr") {
			opts.isHcr = true;
		} else if (arg == "--watch") {
			opts.watch = true;
		} else if (arg.startsWith("--watch-replay=")) {
			opts.watch = true;
			opts.watchReplay = arg.slice(15, arg.length);
		} else if (arg.startsWith("--app=")) {
			const appVal = arg.slice(6, arg.length);
			if (appVal == "console" || appVal == "lib" || appVal == "staticlib") {
				opts.appMode = appVal;
			} else {
				console.log(error("error") + ": unknown --app mode '" + bold(appVal) + "'. Valid: " + cyan("console") + ", " + cyan("lib") + ", " + cyan("staticlib"));
				exit(1);
			}
		} else if (arg == "--strict-defs") {
			opts.strictDefs = true;
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
		} else if (arg == "--gc=none") {
			opts.gcMode = "none";
			opts.gcExplicit = true;
		} else if (arg == "--gc=manual") {
			opts.gcMode = "manual";
			opts.gcExplicit = true;
		} else if (arg == "--gc=drc") {
			opts.gcMode = "drc";
			opts.gcExplicit = true;
		} else if (arg == "--gc=orc") {
			opts.gcMode = "orc";
			opts.gcExplicit = true;
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
			} else {
				opts.extraArgs.push(arg);
			}
			positionalIdx += 1;
		} else if (opts.command == "add" || opts.command == "remove" || opts.command == "install" || opts.command == "update" || opts.command == "publish" || opts.command == "login" || opts.command == "logout" || opts.command == "whoami" || opts.command == "org") {
			// Package manager commands: pass unknown flags through
			opts.extraArgs.push(arg);
		} else {
			const hint = opts.command == "run" && opts.inputFile != ""
				? `; to pass it to the program write: msc run <file> -- ${arg}` : "";
			return Result.err(`unknown option '${arg}'${hint}`);
		}
		i += 1;
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

test "run: a known msc flag after the file stays msc's" {
	const opts = parseForTest(["run", "cli.ms", "--target=js", "a", "--release"]);
	assert opts.target == Target.JS;
	assert opts.mode == MODE_RELEASE;
	assert opts.extraArgs.length == 1 && opts.extraArgs[0] == "a";
}

test "run: -- hands everything after it to the program verbatim" {
	const opts = parseForTest(["run", "cli.ms", "--release", "--", "--foo", "--release", "--", "-x", "y"]);
	assert opts.mode == MODE_RELEASE;
	assert opts.extraArgs.length == 5;
	assert opts.extraArgs[0] == "--foo" && opts.extraArgs[1] == "--release";
	assert opts.extraArgs[2] == "--" && opts.extraArgs[3] == "-x" && opts.extraArgs[4] == "y";
}

test "run: -- before any file leaves the file to build.ms" {
	const opts = parseForTest(["run", "--", "a"]);
	assert opts.inputFile == "";
	assert opts.extraArgs.length == 1 && opts.extraArgs[0] == "a";
}

test "run: an unknown flag after the file is an error that names --" {
	const opts = newCliOptions();
	const r = applyArgs(opts, ["run", "cli.ms", "--foo"], 0);
	assert !r.ok;
	if (!r.ok) {
		assert r.error == "unknown option '--foo'; to pass it to the program write: msc run <file> -- --foo";
	}
	assert opts.extraArgs.length == 0;
}

test "an unknown flag outside run is an error without the -- hint" {
	const opts = newCliOptions();
	const r = applyArgs(opts, ["build", "cli.ms", "--foo"], 0);
	assert !r.ok;
	if (!r.ok) { assert r.error == "unknown option '--foo'"; }
}

test "-- does not change other commands: a package command still takes flags through" {
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

// MetaScript Compiler CLI — Argument parsing and option types

import { argv, exit, platform } from "std/process";
import { error, bold, cyan, setColorEnabled } from "../utils/color";
import { parseIntStr } from "../utils/string";
import { DefineTable, createDefineTable, applyDefineSwitch, initDefines, formatDefines } from "./defines";

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
	errorMax: number;
	mode: number;
	ccCompiler: number;
	ccBinary: string;          // --cc=<path>: explicit C compiler binary (cross-compile)
	targetOs: string;          // Target OS. Always set; defaults to host platform.
	                           // Values: "linux"|"macos"|"windows"|"freebsd"|"bare"|"solana"|"wasm"|"emcc".
	                           // Cross-compile detected by callsites via `targetOs !== platform`.
	cpuTarget: string;         // --cpu=<x86_64|arm64|...>: target CPU (cross-compile)
	genDeps: boolean;
	forceRebuild: boolean;
	strip: boolean;
	sanitize: string;
	passC: string;
	passL: string;
	emitC: boolean;
	splitModules: boolean;     // --split: js target emits one ES module per source module instead of a bundle
	sourcemap: boolean;        // --sourcemap: js target writes a .map beside each output and links it
	fmtCheck: boolean;
	isHcr: boolean;
	appMode: string;           // --app=console|lib|staticlib: executable vs shared/static library
	strictDefs: boolean;       // --strict-defs: warn on all uninit var use
	strictNullChecks: boolean; // --strict-nil: warn on unguarded class deref
	gcMode: string;            // --gc=drc|none|manual: memory management mode
	lto: string;               // --lto=off|thin|full: link-time optimization strategy (empty = mode default)
	autoYes: boolean;          // --yes: auto-accept managed toolchain install (also MSC_AUTO_INSTALL_CC=1)
	defines: DefineTable;      // -d:name[=value] conditional symbols (Nim condsyms.nim)
	showDefines: boolean;      // --help-defines: list every define, then exit
	projectRoot: string;       // set by CLI main from findProjectRoot() — dir containing build.ms
	extraArgs: string[];       // remaining args passed through for package manager commands (add, remove, etc.)
}

// -- Argument parsing --

export function parseArgs(): CliOptions {
	// argv[0] = executable, argv[1] = script (or command when self-hosted binary)
	// When run via `msc run src/compiler/main.ms compile foo.ms`:
	//   argv[0]=msc, argv[1]=src/compiler/main.ms, argv[2]=compile, argv[3]=foo.ms
	// When compiled to binary `msc compile foo.ms`:
	//   argv[0]=msc, argv[1]=compile, argv[2]=foo.ms

	const opts: CliOptions = {
		command: "",
		inputFile: "",
		target: Target.C,
		outputPath: "",
		showTime: false,
		verbose: false,
		errorMax: 0,
		mode: MODE_DEBUG,
		ccCompiler: 0,
		ccBinary: "",
		targetOs: platform,
		cpuTarget: "",
		genDeps: false,
		forceRebuild: false,
		strip: false,
		sanitize: "",
		passC: "",
		passL: "",
		emitC: false,
		splitModules: false,
		sourcemap: false,
		fmtCheck: false,
		isHcr: false,
		appMode: "console",
		strictDefs: false,
		strictNullChecks: false,
		gcMode: "orc",
		lto: "",
		autoYes: false,
		defines: createDefineTable(),
		showDefines: false,
		projectRoot: "",
		extraArgs: [],
	};

	if (argv.length < 2) return opts;

	// Determine argument offset: if argv[1] ends with .ms, it's the script path
	let argStart = 1;
	if (argv.length > 1 && argv[1].endsWith(".ms")) {
		argStart = 2;
	}

	if (argv.length <= argStart) return opts;

	// Parse all args — positional args become command then inputFile
	let positionalIdx = 0;
	let i = argStart;
	while (i < argv.length) {
		const arg = argv[i];
		if (arg === "--help" || arg === "-h") {
			opts.command = "help";
		} else if (arg === "--version" || arg === "-v") {
			opts.command = "version";
		} else if (arg.startsWith("--target=")) {
			const targetStr = arg.slice(9, arg.length);
			if (targetStr === "js" || targetStr === "javascript") {
				opts.target = Target.JS;
			} else if (targetStr === "c") {
				opts.target = Target.C;
			} else if (targetStr === "raiser" || targetStr === "vm") {
				opts.target = Target.Raiser;
			} else {
				console.log(error("error") + ": unknown target '" + bold(targetStr) + "'. Valid: " + cyan("c") + ", " + cyan("js") + ", " + cyan("raiser"));
				exit(1);
			}
		} else if (arg.startsWith("--output=")) {
			opts.outputPath = arg.slice(9, arg.length);
		} else if (arg.startsWith("-o=")) {
			opts.outputPath = arg.slice(3, arg.length);
		} else if (arg === "--time" || arg === "-t") {
			opts.showTime = true;
		} else if (arg === "--verbose") {
			opts.verbose = true;
		} else if (arg.startsWith("--error-max=")) {
			opts.errorMax = parseIntStr(arg.slice(12, arg.length));
		} else if (arg === "--release") {
			opts.mode = MODE_RELEASE;
		} else if (arg === "--danger") {
			opts.mode = MODE_DANGER;
		} else if (arg.startsWith("--cc=")) {
			const ccVal = arg.slice(5, arg.length);
			if (ccVal === "clang") { opts.ccCompiler = 1; }
			else if (ccVal === "gcc") { opts.ccCompiler = 2; }
			else { opts.ccBinary = ccVal; }
		} else if (arg.startsWith("--os=")) {
			const osVal = arg.slice(5, arg.length);
			if (osVal !== "bare" && osVal !== "solana" && osVal !== "wasm" && osVal !== "emcc" && osVal !== "linux" && osVal !== "macos" && osVal !== "windows" && osVal !== "darwin" && osVal !== "freebsd" && osVal !== "ios" && osVal !== "android") {
				console.log(`error: unknown --os target: "${osVal}"`);
				console.log(`  Valid targets: bare, solana, wasm, emcc, linux, macos, windows, ios, android`);
				return opts;
			}
			opts.targetOs = osVal;
		} else if (arg.startsWith("--cpu=")) {
			opts.cpuTarget = arg.slice(6, arg.length);
		} else if (arg === "--gendeps") {
			opts.genDeps = true;
		} else if (arg === "--force" || arg === "-f") {
			opts.forceRebuild = true;
		} else if (arg === "--strip") {
			opts.strip = true;
		} else if (arg.startsWith("--sanitize=")) {
			opts.sanitize = arg.slice(11, arg.length);
		} else if (arg.startsWith("--passC=")) {
			if (opts.passC.length > 0) opts.passC = opts.passC + " ";
			opts.passC = opts.passC + arg.slice(8, arg.length);
		} else if (arg.startsWith("--passL=")) {
			if (opts.passL.length > 0) opts.passL = opts.passL + " ";
			opts.passL = opts.passL + arg.slice(8, arg.length);
		} else if (arg === "--check") {
			opts.fmtCheck = true;
		} else if (arg === "--hcr") {
			opts.isHcr = true;
		} else if (arg.startsWith("--app=")) {
			const appVal = arg.slice(6, arg.length);
			if (appVal === "console" || appVal === "lib" || appVal === "staticlib") {
				opts.appMode = appVal;
			} else {
				console.log(error("error") + ": unknown --app mode '" + bold(appVal) + "'. Valid: " + cyan("console") + ", " + cyan("lib") + ", " + cyan("staticlib"));
				exit(1);
			}
		} else if (arg === "--strict-defs") {
			opts.strictDefs = true;
		} else if (arg === "--strict-nil") {
			opts.strictNullChecks = true;
		} else if (arg === "--gc=none") {
			opts.gcMode = "none";
		} else if (arg === "--gc=manual") {
			opts.gcMode = "manual";
		} else if (arg === "--gc=drc") {
			opts.gcMode = "drc";
		} else if (arg === "--gc=orc") {
			opts.gcMode = "orc";
		} else if (arg.startsWith("--lto=")) {
			const ltoVal = arg.slice(6, arg.length);
			if (ltoVal === "off" || ltoVal === "thin" || ltoVal === "full") {
				opts.lto = ltoVal;
			} else {
				console.log(error("error") + ": unknown --lto strategy '" + bold(ltoVal) + "'. Valid: " + cyan("off") + ", " + cyan("thin") + ", " + cyan("full"));
				exit(1);
			}
		} else if (arg === "--yes" || arg === "-y") {
			opts.autoYes = true;
		} else if (arg === "--emit=c") {
			opts.emitC = true;
		} else if (arg === "--split") {
			opts.splitModules = true;
		} else if (arg === "--sourcemap") {
			opts.sourcemap = true;
		} else if (arg.startsWith("-d:") || arg.startsWith("-d=") || arg.startsWith("--define:") || arg.startsWith("--define=")) {
			applyDefineSwitch(opts.defines, arg);
		} else if (arg === "--help-defines") {
			opts.showDefines = true;
		} else if (arg === "--colors=on") {
			setColorEnabled(true);
		} else if (arg === "--colors=off" || arg === "--no-color") {
			setColorEnabled(false);
		} else if (!arg.startsWith("-")) {
			if (positionalIdx === 0) {
				opts.command = arg;
			} else if (positionalIdx === 1) {
				opts.inputFile = arg;
			} else {
				opts.extraArgs.push(arg);
			}
			positionalIdx += 1;
		} else if (opts.command === "add" || opts.command === "remove" || opts.command === "install" || opts.command === "update" || opts.command === "publish" || opts.command === "login" || opts.command === "logout" || opts.command === "whoami" || opts.command === "org") {
			// Package manager commands: pass unknown flags through
			opts.extraArgs.push(arg);
		} else {
			console.log(error("error") + ": unknown option '" + bold(arg) + "'");
			exit(1);
		}
		i += 1;
	}

	// opts.lto stays "" here when no --lto= was given: the default depends on
	// which compiler resolves (LTO capability is a compiler/target property),
	// and the compiler is not known until resolveCC runs. resolveLto (cc.ms),
	// called right after resolveCC, turns "" into thin/off per capability.

	// Seeded last because backend/os/gc/mode are only final once every switch has
	// been read; `seed` skips names the user already set, so -d: still wins
	// (Nim reaches the same precedence by seeding first — condsyms.nim:34 before
	// commands.nim:703).
	const backendName = opts.target === Target.JS ? "js" : (opts.target === Target.Raiser ? "raiser" : "c");
	initDefines(opts.defines, backendName, opts.targetOs, opts.gcMode, opts.mode);
	if (opts.showDefines) {
		console.log(formatDefines(opts.defines));
		exit(0);
	}

	return opts;
}

// MetaScript Compiler CLI — Argument parsing and option types

import { argv, exit } from "std/process";
import { error, bold, cyan, setColorEnabled } from "../utils/color";
import { parseIntStr } from "../utils/string";

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
	genDeps: boolean;
	forceRebuild: boolean;
	strip: boolean;
	sanitize: string;
	passC: string;
	passL: string;
	emitC: boolean;
	fmtCheck: boolean;
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
		genDeps: false,
		forceRebuild: false,
		strip: false,
		sanitize: "",
		passC: "",
		passL: "",
		emitC: false,
		fmtCheck: false,
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
		} else if (arg === "--cc=clang") {
			opts.ccCompiler = 1;
		} else if (arg === "--cc=gcc") {
			opts.ccCompiler = 2;
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
		} else if (arg === "--emit=c") {
			opts.emitC = true;
		} else if (arg === "--colors=on") {
			setColorEnabled(true);
		} else if (arg === "--colors=off" || arg === "--no-color") {
			setColorEnabled(false);
		} else if (!arg.startsWith("-")) {
			if (positionalIdx === 0) {
				opts.command = arg;
			} else {
				opts.inputFile = arg;
			}
			positionalIdx += 1;
		} else {
			console.log(error("error") + ": unknown option '" + bold(arg) + "'");
			exit(1);
		}
		i += 1;
	}

	return opts;
}

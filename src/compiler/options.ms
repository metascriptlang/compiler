// MetaScript Compiler CLI — Argument parsing and option types

import { argv, exit } from "std/process";
import { error, bold, cyan, setColorEnabled } from "../utils/color";

// -- Types --

export enum Target {
	C,
	JS,
}

export interface CliOptions {
	command: string;
	inputFile: string;
	target: Target;
	outputPath: string;
	showTime: boolean;
	verbose: boolean;
	errorMax: number;
}

// -- Helpers --

function parseIntStr(s: string): number {
	let result = 0;
	let i = 0;
	while (i < s.length) {
		const code = s.charCodeAt(i);
		if (code >= "0".code && code <= "9".code) {
			result = result * 10 + (code - "0".code);
		}
		i += 1;
	}
	return result;
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
			} else {
				console.log(error("error") + ": unknown target '" + bold(targetStr) + "'. Valid: " + cyan("c") + ", " + cyan("js"));
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

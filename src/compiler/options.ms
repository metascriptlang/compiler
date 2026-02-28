// MetaScript Compiler CLI — Argument parsing and option types

import { argv, exit } from "std/process";

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
	};

	if (argv.length < 2) return opts;

	// Determine argument offset: if argv[1] ends with .ms, it's the script path
	let argStart = 1;
	if (argv.length > 1 && argv[1].endsWith(".ms")) {
		argStart = 2;
	}

	if (argv.length <= argStart) return opts;

	const command = argv[argStart];

	// Check for flags first
	if (command === "--help" || command === "-h") {
		opts.command = "help";
		return opts;
	}
	if (command === "--version" || command === "-v") {
		opts.command = "version";
		return opts;
	}
	opts.command = command;

	// Parse remaining args
	let i = argStart + 1;
	while (i < argv.length) {
		const arg = argv[i];
		if (arg.startsWith("--target=")) {
			const targetStr = arg.slice(9, arg.length);
			if (targetStr === "js" || targetStr === "javascript") {
				opts.target = Target.JS;
			} else if (targetStr === "c") {
				opts.target = Target.C;
			} else {
				console.log("Error: unknown target '" + targetStr + "'. Valid: c, js");
				exit(1);
			}
		} else if (arg.startsWith("--output=")) {
			opts.outputPath = arg.slice(9, arg.length);
		} else if (arg.startsWith("-o=")) {
			opts.outputPath = arg.slice(3, arg.length);
		} else if (!arg.startsWith("-")) {
			opts.inputFile = arg;
		} else {
			console.log("Error: unknown option '" + arg + "'");
			exit(1);
		}
		i += 1;
	}

	return opts;
}

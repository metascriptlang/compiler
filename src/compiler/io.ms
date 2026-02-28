// MetaScript Compiler CLI — File I/O and shared error helpers

import { exit, readFile, writeFile } from "std/process";
import { CheckerContext, hasErrors, errorCount } from "../checker/context";
import { error, red, green, bold, path } from "../utils/color";

export function readSource(filePath: string): string {
	const source = readFile(filePath);
	if (source.length === 0) {
		console.log(error("error") + ": could not read file (or file is empty): " + path(filePath));
		exit(1);
	}
	return source;
}

export function writeOutput(filePath: string, content: string): void {
	const ok = writeFile(filePath, content);
	if (!ok) {
		console.log(error("error") + ": could not write file: " + path(filePath));
		exit(1);
	}
}

// Print checker errors and exit. Used by compile, run, check commands.
export function printErrorsAndExit(ctx: CheckerContext, prefix: string): void {
	let i = 0;
	while (i < ctx.errors.length) {
		console.log(red(prefix) + ctx.errors[i]);
		i += 1;
	}
	exit(1);
}

// Write generated code to outputPath or derive from filePath.
export function emitOutput(code: string, filePath: string, outputPath: string, ext: string): void {
	if (outputPath !== "") {
		writeOutput(outputPath, code);
		console.log(green("Wrote") + " " + bold(outputPath));
	} else {
		// Replace .ms with target extension
		const outFile = filePath.slice(0, filePath.length - 3) + ext;
		writeOutput(outFile, code);
		console.log(green("Wrote") + " " + bold(outFile));
	}
}

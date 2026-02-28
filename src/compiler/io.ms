// MetaScript Compiler CLI — File I/O and shared error helpers

import { exit, readFile, writeFile, clockMs } from "std/process";
import { CheckerContext, hasErrors, errorCount } from "../checker/context";
import { error, red, green, bold, dim, path } from "../utils/color";

// -- Shared timing + verbose helpers --
// Extracted to separate functions to avoid DRC discard-variable bugs
// inside conditional string concatenation (DRC workaround #21)

export function printTiming(label: string, t0: number): void {
	const elapsed = clockMs() - t0;
	const ms = "" + elapsed;
	const display = ms.slice(0, ms.length < 6 ? ms.length : 6);
	console.log(dim("  " + label + " in " + display + "ms"));
}

export function verboseLog(msg: string): void {
	console.log(dim("  " + msg));
}

// -- Path utilities --

// Replace .ms extension with newExt (or append if not .ms).
// replaceExt("foo.ms", ".c") → "foo.c"
// replaceExt("foo.ms", "") → "foo"
export function replaceExt(inputFile: string, newExt: string): string {
	if (inputFile.endsWith(".ms")) {
		return inputFile.slice(0, inputFile.length - 3) + newExt;
	}
	return inputFile + newExt;
}

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
// maxErrors=0 means show all.
export function printErrorsAndExit(ctx: CheckerContext, prefix: string, maxErrors: number): void {
	let limit = ctx.errors.length;
	if (maxErrors > 0 && maxErrors < limit) {
		limit = maxErrors;
	}
	for (let i = 0; i < limit; i += 1) {
		console.log(red(prefix) + ctx.errors[i]);
	}
	if (limit < ctx.errors.length) {
		const remaining = ctx.errors.length - limit;
		console.log(dim("... and " + remaining + " more error(s)"));
	}
	exit(1);
}

// Write generated code to outputPath or derive from filePath.
export function emitOutput(code: string, filePath: string, outputPath: string, ext: string): void {
	const outFile = outputPath !== "" ? outputPath : replaceExt(filePath, ext);
	writeOutput(outFile, code);
	console.log(green("Wrote") + " " + bold(outFile));
}

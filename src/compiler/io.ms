// MetaScript Compiler CLI — File I/O and shared error helpers

import { exit, exec, readFile, writeFile, clockMs } from "std/process";
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
	if (inputFile.endsWith(".jms") || inputFile.endsWith(".cms")) {
		return inputFile.slice(0, inputFile.length - 4) + newExt;
	}
	if (inputFile.endsWith(".ms")) {
		return inputFile.slice(0, inputFile.length - 3) + newExt;
	}
	return inputFile + newExt;
}

// Get directory name from path. dirName("a/b/c.ms") → "a/b", dirName("c.ms") → "."
export function dirName(filePath: string): string {
	let lastSlash = -1;
	for (let i = 0; i < filePath.length; i += 1) {
		if (filePath.charCodeAt(i) === "/".code) {
			lastSlash = i;
		}
	}
	if (lastSlash < 0) return ".";
	return filePath.slice(0, lastSlash);
}

// Get filename from path. baseName("a/b/c.ms") → "c.ms", baseName("c.ms") → "c.ms"
export function baseName(filePath: string): string {
	let lastSlash = -1;
	for (let i = 0; i < filePath.length; i += 1) {
		if (filePath.charCodeAt(i) === "/".code) {
			lastSlash = i;
		}
	}
	if (lastSlash < 0) return filePath;
	return filePath.slice(lastSlash + 1, filePath.length);
}

// Strip base directory prefix from path. stripBase("a/b/c.ms", "a/b") → "c.ms"
export function stripBase(fullPath: string, baseDir: string): string {
	if (baseDir === ".") return fullPath;
	if (fullPath.startsWith(baseDir)) {
		const after = baseDir.length;
		if (after < fullPath.length && fullPath.charCodeAt(after) === "/".code) {
			return fullPath.slice(after + 1, fullPath.length);
		}
	}
	return fullPath;
}

// Ensure directory exists (creates parent directories as needed).
export function ensureDir(dir: string): void {
	exec("mkdir -p " + dir);
}

// -- JS runtime detection (bun preferred, node fallback) --

let jsRuntime = "";
let jsRuntimeChecked = false;

export function getJSRuntime(): string {
	if (!jsRuntimeChecked) {
		jsRuntimeChecked = true;
		if (exec("which bun > /dev/null 2>&1") === 0) {
			jsRuntime = "bun";
		} else {
			jsRuntime = "node";
		}
	}
	return jsRuntime;
}

// -- Platform detection --
// -1=unchecked, 0=unix, 1=windows
let platformIsWindows = -1;

export function exeSuffix(): string {
	if (platformIsWindows < 0) {
		if (exec("test -f /bin/sh") !== 0) {
			platformIsWindows = 1;
		} else {
			platformIsWindows = 0;
		}
	}
	if (platformIsWindows === 1) return ".exe";
	return "";
}

export function soSuffix(): string {
	if (platformIsWindows < 0) {
		if (exec("test -f /bin/sh") !== 0) {
			platformIsWindows = 1;
		} else {
			platformIsWindows = 0;
		}
	}
	if (platformIsWindows === 1) return ".dll";
	if (exec("test $(uname) = Darwin") === 0) return ".dylib";
	return ".so";
}

// -- Output directory based on build mode --

export function outDirForMode(mode: number): string {
	if (mode > 0) return "out/release";
	return "out/debug";
}

// -- File I/O --

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
		const err = ctx.errors[i];
		const loc = err.line > 0 ? ":" + err.line + ":" + err.column + " " : " ";
		console.log(red(prefix) + loc + err.message);
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

// ===== Tests =====
test "replaceExt .ms to .js" { assert replaceExt("foo.ms", ".js") === "foo.js"; }

test "replaceExt .ms to empty" { assert replaceExt("foo.ms", "") === "foo"; }

test "replaceExt no .ms" { assert replaceExt("foo", ".js") === "foo.js"; }

test "dirName with slashes" { assert dirName("a/b/c.ms") === "a/b"; }

test "dirName no slash" { assert dirName("c.ms") === "."; }

test "dirName deep path" { assert dirName("src/compiler/io.ms") === "src/compiler"; }

test "baseName with slashes" { assert baseName("a/b/c.ms") === "c.ms"; }

test "baseName no slash" { assert baseName("c.ms") === "c.ms"; }

test "stripBase removes prefix" { assert stripBase("a/b/c.ms", "a/b") === "c.ms"; }

test "stripBase dot passthrough" { assert stripBase("c.ms", ".") === "c.ms"; }

test "stripBase no match" { assert stripBase("x/y.ms", "a/b") === "x/y.ms"; }

test "stripBase partial prefix no match" { assert stripBase("a/bc/d.ms", "a/b") === "a/bc/d.ms"; }

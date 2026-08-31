// MetaScript Compiler CLI — File I/O and shared error helpers

import { exit, platform } from "std/process";
import { readFile, writeFile, ensureDir as fsEnsureDir, rename, remove } from "std/fs";
import { CheckerContext } from "../checker/context";
import { error, red, green, bold, dim } from "../utils/color";


// -- Shared timing + verbose helpers --
// Extracted to separate functions to avoid DRC discard-variable bugs
// inside conditional string concatenation.

export function printTiming(label: string, t0: number): void {
	const elapsed = performance.now() - t0;
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

// Path utilities live in std/fs/path — import there. This module keeps only
// msc-specific file-IO helpers (replaceExt, ensureDir, readSource, etc.).

// Ensure directory exists (creates parent directories as needed).
// Delegates to std/fs - cross-platform (no shell dependency).
export function ensureDir(dir: string): void {
	fsEnsureDir(dir);
}

// -- Atomic file publish (concurrent-build safety) --

// POSIX-semantics rename with a bounded retry. The swap itself is atomic
// (msFsRename replaces an existing target on every OS); the retry only
// covers the Windows window where a concurrent reader — e.g. a linker
// reading this very .o — holds the target open without FILE_SHARE_DELETE,
// making MoveFileExW fail until the reader closes. std has no sync sleep,
// so the backoff is a short bounded busy pause; the common case succeeds
// on the first attempt and never pauses.
export function renameReplace(src: string, dst: string): boolean {
	const deadline = performance.now() + 250;
	while (true) {
		const r = rename(src, dst);
		if (r.ok) return true;
		if (performance.now() >= deadline) return false;
		const until = performance.now() + 20;
		while (performance.now() < until) {}
	}
}

// Write a file by publishing atomically: content goes to a per-invocation
// tmp sibling, then renames over the final path. Concurrent readers never
// observe a torn or missing file — the previous content stays intact until
// the swap. Returns false only if the rename never landed (tmp is removed).
export function atomicWriteFile(path: string, content: string): boolean {
	const tmp = `${path}.tmp.${performance.now()}`;
	const w = writeFile(tmp, content);
	if (!w.ok) return false;
	if (renameReplace(tmp, path)) return true;
	remove(tmp);
	return false;
}

// -- Platform-dependent file suffixes --

export function exeSuffix(): string {
	return platform === "windows" ? ".exe" : "";
}

export function soSuffix(): string {
	return match (platform) {
		"windows" => ".dll",
		"darwin" => ".dylib",
		_ => ".so",
	};
}

// -- Output directory based on build mode --

export function outDirForMode(mode: number): string {
	if (mode > 0) return "out/release";
	return "out/debug";
}

// -- File I/O --

export function readSource(filePath: string): string {
	const result = readFile(filePath);
	if (!result.ok) {
		console.log(error("error") + ": " + result.error.message);
		exit(1);
	}
	return result.value;
}

export function writeOutput(filePath: string, content: string): void {
	const result = writeFile(filePath, content);
	if (!result.ok) {
		console.log(error("error") + ": " + result.error.message);
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

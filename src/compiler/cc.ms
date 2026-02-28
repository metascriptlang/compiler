// MetaScript Compiler CLI — C compiler wrapper
//
// Invokes clang to compile generated C source into native binaries.
// Mirrors the reference compiler's cc.zig: dynamic path resolution via
// argv[0] + candidate search, with hardcoded fallback.

import { argv, exec, fileExists } from "std/process";
import { dirname, join, resolve1 } from "std/fs/path";

// -- Dynamic project root resolution --

// Wrap in interface to avoid DRC module-level let string reassignment bug
interface CachedPath {
	value: string;
	resolved: boolean;
}

const projectRoot: CachedPath = { value: "", resolved: false };

// Find the MetaScript project root by searching for src/runtime/orc.h
// relative to the binary's location (argv[0]).
function resolveProjectRoot(): string {
	if (projectRoot.resolved) return projectRoot.value;
	projectRoot.resolved = true;

	// Resolve binary dir to absolute path
	const binDir = resolve1(dirname(argv[0]));

	// Search candidate paths: walk up from binary dir looking for src/runtime/orc.h
	let base = binDir;
	let i = 0;
	while (i < 5) {
		const candidate = join(base, "src/runtime");
		const marker = join(candidate, "orc.h");
		if (fileExists(marker)) {
			projectRoot.value = base;
			return base;
		}
		base = dirname(base);
		i = i + 1;
	}

	// Fallback: hardcoded path
	projectRoot.value = "/Users/le/projects/metascript";
	return projectRoot.value;
}

// -- ccache detection --

let hasCcache = false;
let ccacheChecked = false;

function getCcachePrefix(): string {
	if (!ccacheChecked) {
		ccacheChecked = true;
		hasCcache = exec("which ccache > /dev/null 2>&1") === 0;
	}
	if (hasCcache) return "ccache ";
	return "";
}

// -- Clang invocation --

// Build a clang command string with dynamically resolved include paths.
function buildClangCommand(cFile: string, outBinary: string): string {
	const root = resolveProjectRoot();

	let cmd = getCcachePrefix() + "clang";
	cmd = cmd + " -std=c11 -O2 -w";

	// Core runtime (orc.h, ms_string.h, ms_array.h, etc.)
	cmd = cmd + " -I" + join(root, "src/runtime");

	// Standard library modules with C headers
	cmd = cmd + " -I" + join(root, "std/process");
	cmd = cmd + " -I" + join(root, "std/fs");
	cmd = cmd + " -I" + join(root, "std/io");
	cmd = cmd + " -I" + join(root, "std");

	cmd = cmd + " " + cFile;
	cmd = cmd + " -o " + outBinary;
	cmd = cmd + " -lm";
	return cmd;
}

// Compile a .c file to a native binary via clang.
// Returns 0 on success, non-zero on failure.
export function compileC(cFile: string, outBinary: string): number {
	const cmd = buildClangCommand(cFile, outBinary);
	return exec(cmd);
}

// Remove temp files created during `msc run`.
export function cleanupTempFiles(): void {
	exec("rm -f /tmp/_msc_run.c /tmp/_msc_run.js /tmp/_msc_run");
}

// Derive default output path from input .ms file path.
// replaceExt("foo.ms", ".c") → "foo.c"
// replaceExt("foo.ms", "") → "foo"
export function replaceExt(inputFile: string, newExt: string): string {
	if (inputFile.endsWith(".ms")) {
		return inputFile.slice(0, inputFile.length - 3) + newExt;
	}
	return inputFile + newExt;
}

// MetaScript Compiler CLI — C compiler wrapper
//
// Invokes clang to compile generated C source into native binaries.

import { argv, exec, fileExists } from "std/process";
import { dirname, join, resolve1 } from "std/fs/path";

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

// -- Runtime resolution --

// Find the compiler's runtime/ directory by walking up from argv[0].
function resolveRuntime(): string {
	const binDir = resolve1(dirname(argv[0]));
	let base = binDir;
	for (let i = 0; i < 5; i += 1) {
		const candidate = join(base, "runtime");
		const marker = join(candidate, "runtime.h");
		if (fileExists(marker)) return candidate;
		base = dirname(base);
	}
	return "";
}

// -- Clang invocation --

function buildClangCommand(cFile: string, outBinary: string, extraFlags: string): string {
	let cmd = getCcachePrefix() + "clang";
	cmd = cmd + " -std=c11 -O2 -w";

	// MetaScript runtime (io, etc.)
	const rtDir = resolveRuntime();
	if (rtDir !== "") {
		cmd = cmd + " -I" + rtDir;
		cmd = cmd + " " + join(rtDir, "io.c");
	}

	cmd = cmd + " " + cFile;
	cmd = cmd + " -o " + outBinary;
	cmd = cmd + " -lm";
	if (extraFlags !== "") cmd = cmd + " " + extraFlags;
	return cmd;
}

// Compile a .c file to a native binary via clang.
// Returns 0 on success, non-zero on failure.
export function compileC(cFile: string, outBinary: string, extraFlags: string): number {
	const cmd = buildClangCommand(cFile, outBinary, extraFlags);
	return exec(cmd);
}

// Compile a .c file to an object file only (-c flag, no linking).
// Returns 0 on success, non-zero on failure.
export function compileCFile(cFile: string, oFile: string, extraFlags: string): number {
	let cmd = getCcachePrefix() + "clang";
	cmd = cmd + " -std=c11 -O2 -w";

	const rtDir = resolveRuntime();
	if (rtDir !== "") {
		cmd = cmd + " -I" + rtDir;
	}

	cmd = cmd + " -c " + cFile + " -o " + oFile;
	if (extraFlags !== "") cmd = cmd + " " + extraFlags;
	return exec(cmd);
}

// Link object files + runtime into a binary.
// oFileList: space-separated list of .o file paths
// Returns 0 on success, non-zero on failure.
export function linkObjects(oFileList: string, outBinary: string, extraFlags: string): number {
	let cmd = getCcachePrefix() + "clang";

	const rtDir = resolveRuntime();
	if (rtDir !== "") {
		cmd = cmd + " " + join(rtDir, "io.c");
	}

	cmd = cmd + " " + oFileList;
	cmd = cmd + " -o " + outBinary;
	cmd = cmd + " -lm";
	if (extraFlags !== "") cmd = cmd + " " + extraFlags;
	return exec(cmd);
}

// Get the runtime directory path (for -I include path).
export function getRuntimeDir(): string {
	return resolveRuntime();
}

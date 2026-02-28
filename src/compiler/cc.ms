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
	let i = 0;
	while (i < 5) {
		const candidate = join(base, "runtime");
		const marker = join(candidate, "runtime.h");
		if (fileExists(marker)) return candidate;
		base = dirname(base);
		i = i + 1;
	}
	return "";
}

// -- Clang invocation --

function buildClangCommand(cFile: string, outBinary: string): string {
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
	return cmd;
}

// Compile a .c file to a native binary via clang.
// Returns 0 on success, non-zero on failure.
export function compileC(cFile: string, outBinary: string): number {
	const cmd = buildClangCommand(cFile, outBinary);
	return exec(cmd);
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

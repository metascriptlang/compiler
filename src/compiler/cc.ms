// MetaScript Compiler CLI — C compiler wrapper
//
// Invokes clang to compile generated C source into native binaries.

import { argv, exec, fileExists } from "std/process";
import { dirname, join, resolve } from "std/fs/path";
import { CliOptions } from "./options";

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
	const binDir = resolve(dirname(argv[0]));
	let base = binDir;
	for (let i = 0; i < 5; i += 1) {
		const candidate = join(base, "runtime");
		const marker = join(candidate, "system.h");
		if (fileExists(marker)) return candidate;
		base = dirname(base);
	}
	return "";
}

// -- C compiler detection --
// 0=undetected, 1=clang, 2=gcc, 3=cc (fallback)
let detectedCC = 0;

function getCompilerName(ccOption: number): string {
	if (ccOption === 1) return "clang";
	if (ccOption === 2) return "gcc";
	// auto-detect
	if (detectedCC === 0) {
		if (exec("which clang > /dev/null 2>&1") === 0) {
			detectedCC = 1;
		} else if (exec("which gcc > /dev/null 2>&1") === 0) {
			detectedCC = 2;
		} else {
			detectedCC = 3;
		}
	}
	if (detectedCC === 1) return "clang";
	if (detectedCC === 2) return "gcc";
	return "cc";
}

// -- Build mode flags --
// mode: 0=debug, 1=release, 2=danger

function modeFlags(mode: number): string {
	if (mode === 2) return " -O3 -flto -w -DNDEBUG";
	if (mode === 1) return " -O2 -w -DNDEBUG";
	return " -O0 -g";
}

// -- Flag accumulation helpers --

// Append a flag to a space-separated flag string. No-op if flag is empty.
export function appendFlag(base: string, flag: string): string {
	if (flag === "") return base;
	if (base.length > 0) return base + " " + flag;
	return flag;
}

// Build compile-phase flags from CLI options (sanitize + passC).
export function cliCompileFlags(opts: CliOptions): string {
	let flags = "";
	if (opts.sanitize !== "") flags = appendFlag(flags, "-fsanitize=" + opts.sanitize);
	// Linker DCE: place each function/data in its own section so the linker can strip unused ones
	flags = appendFlag(flags, "-fdata-sections");
	flags = appendFlag(flags, "-ffunction-sections");
	if (opts.isHcr) flags = appendFlag(flags, "-fPIC");
	flags = appendFlag(flags, opts.passC);
	return flags;
}

// Build link-phase flags (adds passL + strip on top of compile flags).
export function cliLinkFlags(base: string, opts: CliOptions): string {
	let flags = base;
	flags = appendFlag(flags, opts.passL);
	if (opts.strip) flags = appendFlag(flags, "-s");
	if (opts.isHcr) {
		flags = appendFlag(flags, "-shared");
	} else {
		flags = appendFlag(flags, "-Wl,-dead_strip");
	}
	return flags;
}

// Build all flags for single-file compile+link (cmdRun).
export function cliAllFlags(opts: CliOptions): string {
	return cliLinkFlags(cliCompileFlags(opts), opts);
}

// -- Build command construction --

function buildCompileCommand(cFile: string, outBinary: string, extraFlags: string, mode: number, ccOption: number): string {
	let cmd = getCcachePrefix() + getCompilerName(ccOption);
	cmd = cmd + " -std=c11" + modeFlags(mode);

	const rtDir = resolveRuntime();
	if (rtDir !== "") {
		cmd = cmd + " -iquote" + rtDir;
		cmd = cmd + " " + join(rtDir, "system.c");
		cmd = cmd + " " + join(rtDir, "core/string.c");
		cmd = cmd + " " + join(rtDir, "core/array.c");
		cmd = cmd + " " + join(rtDir, "core/map.c");
		cmd = cmd + " " + join(rtDir, "mem/orc.c");
	}

	cmd = cmd + " " + cFile;
	cmd = cmd + " -o " + outBinary;
	cmd = cmd + " -lm";
	if (extraFlags !== "") cmd = cmd + " " + extraFlags;
	return cmd;
}

// Compile a .c file to a native binary.
// Returns 0 on success, non-zero on failure.
export function compileC(cFile: string, outBinary: string, extraFlags: string, mode: number, ccOption: number): number {
	const cmd = buildCompileCommand(cFile, outBinary, extraFlags, mode, ccOption);
	return exec(cmd);
}

// Compile a .c file to an object file only (-c flag, no linking).
// Returns 0 on success, non-zero on failure.
export function compileCFile(cFile: string, oFile: string, extraFlags: string, mode: number, ccOption: number): number {
	let cmd = getCcachePrefix() + getCompilerName(ccOption);
	cmd = cmd + " -std=c11" + modeFlags(mode);

	const rtDir = resolveRuntime();
	if (rtDir !== "") {
		cmd = cmd + " -iquote" + rtDir;
	}

	cmd = cmd + " -c " + cFile + " -o " + oFile;
	if (extraFlags !== "") cmd = cmd + " " + extraFlags;
	return exec(cmd);
}

// Link object files + runtime into a binary.
// oFileList: space-separated list of .o file paths
// Returns 0 on success, non-zero on failure.
export function linkObjects(oFileList: string, outBinary: string, extraFlags: string, mode: number, ccOption: number): number {
	let cmd = getCcachePrefix() + getCompilerName(ccOption);

	const rtDir = resolveRuntime();
	if (rtDir !== "") {
		cmd = cmd + " -iquote" + rtDir;
		cmd = cmd + " " + join(rtDir, "system.c");
		cmd = cmd + " " + join(rtDir, "core/string.c");
		cmd = cmd + " " + join(rtDir, "core/array.c");
		cmd = cmd + " " + join(rtDir, "core/map.c");
		cmd = cmd + " " + join(rtDir, "mem/orc.c");
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

// MetaScript Compiler CLI — C compiler wrapper
//
// Invokes clang to compile generated C source into native binaries.

import { argv, exec, fileExists, cwd } from "std/process";
import { dirname, join, resolve } from "std/fs/path";
import { CliOptions } from "./options";

// -- Runtime resolution --

// Find the compiler's std/runtime/ directory by walking up from argv[0],
// then fallback to cwd() (needed when running under Bun where argv[0] is the bun binary).
function resolveRuntime(): string {
	const binDir = dirname(argv[0]);
	let base = binDir;
	for (let i = 0; i < 5; i += 1) {
		const candidate = join(base, "std/runtime");
		const marker = join(candidate, "arc.h");
		if (fileExists(marker)) return candidate;
		base = dirname(base);
	}
	// Fallback: try cwd and walk up
	base = cwd();
	for (let i = 0; i < 3; i += 1) {
		const candidate = join(base, "std/runtime");
		const marker = join(candidate, "arc.h");
		if (fileExists(marker)) return candidate;
		base = dirname(base);
	}
	return "";
}

// -- C compiler detection --
// 0=undetected, 1=clang, 2=gcc, 3=cc (fallback)
let detectedCC = 0;

export function getCompilerName(ccOption: number): string {
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

export function modeFlags(mode: number): string {
	return match (mode) {
		2 => " -O3 -flto -w -DNDEBUG",
		1 => " -O2 -w -DNDEBUG",
		_ => " -O0 -g",
	};
}

// -- Flag accumulation helpers --

// Append a flag to a space-separated flag string. No-op if flag is empty.
export function appendFlag(base: string, flag: string): string {
	if (flag === "") return base;
	if (base.length > 0) return `${base} ${flag}`;
	return flag;
}

// Build compile-phase flags from CLI options (sanitize + passC).
export function cliCompileFlags(opts: CliOptions): string {
	let flags = "";
	if (opts.sanitize !== "") flags = appendFlag(flags, `-fsanitize=${opts.sanitize}`);
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
	let cmd = `${getCompilerName(ccOption)} -std=c11${modeFlags(mode)}`;

	const rtDir = resolveRuntime();
	if (rtDir !== "") {
		cmd = `${cmd} -iquote${dirname(dirname(rtDir))}`;
	}

	cmd = `${cmd} ${cFile} -o ${outBinary} -lm`;
	if (extraFlags !== "") cmd = `${cmd} ${extraFlags}`;
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
	let cmd = `${getCompilerName(ccOption)} -std=c11${modeFlags(mode)}`;

	const rtDir = resolveRuntime();
	if (rtDir !== "") {
		cmd = `${cmd} -iquote${dirname(dirname(rtDir))}`;
	}

	cmd = `${cmd} -c ${cFile} -o ${oFile}`;
	if (extraFlags !== "") cmd = `${cmd} ${extraFlags}`;
	return exec(cmd);
}

// Link object files + runtime into a binary.
// oFileList: space-separated list of .o file paths
// Returns 0 on success, non-zero on failure.
export function linkObjects(oFileList: string, outBinary: string, extraFlags: string, mode: number, ccOption: number): number {
	let cmd = getCompilerName(ccOption);

	const rtDir = resolveRuntime();
	if (rtDir !== "") {
		cmd = `${cmd} -iquote${dirname(dirname(rtDir))}`;
	}

	cmd = `${cmd} ${oFileList} -o ${outBinary} -lm`;
	if (extraFlags !== "") cmd = `${cmd} ${extraFlags}`;
	return exec(cmd);
}

// Get the runtime directory path (for -I include path).
export function getRuntimeDir(): string {
	return resolveRuntime();
}

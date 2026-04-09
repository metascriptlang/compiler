// MetaScript Compiler CLI — C compiler wrapper
//
// Invokes clang to compile generated C source into native binaries.

import { exec, getEnv } from "std/process";
import { join, dirname } from "std/fs/path";
import { CliOptions } from "./options";
import { resolveRuntimeDir } from "../utils/path";

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

function resolveRuntime(): string {
	const root = resolveRuntimeDir();
	if (root.length > 0) return join(root, "runtime");
	return "";
}

// -- C compiler detection --
// 0=undetected, 1=clang, 2=gcc, 3=cc (fallback), 4=zig cc
let detectedCC = 0;
let hasZigCC = false;
let zigCCChecked = false;

function checkZigCC(): boolean {
	if (!zigCCChecked) {
		zigCCChecked = true;
		hasZigCC = exec("which zig > /dev/null 2>&1") === 0;
	}
	return hasZigCC;
}

// -- Solana BPF toolchain detection --

let _bpfClang = "";
let _bpfClangChecked = false;

function testBpfClang(binary: string): boolean {
	// Check if clang supports BPF target (Apple clang doesn't)
	return exec(`"${binary}" --print-targets 2>/dev/null | grep -q bpf`) === 0;
}

export function resolveBpfClang(): string {
	if (_bpfClangChecked) return _bpfClang;
	_bpfClangChecked = true;
	const candidates = [
		"/opt/homebrew/opt/llvm/bin/clang",  // macOS Apple Silicon
		"/usr/local/opt/llvm/bin/clang",     // macOS Intel
		"clang",                              // System clang (Linux)
	];
	for (const c of candidates) {
		if (testBpfClang(c)) {
			_bpfClang = c;
			return _bpfClang;
		}
	}
	return "";
}

let _sbpfLinker = "";
let _sbpfLinkerChecked = false;

export function resolveSbpfLinker(): string {
	if (_sbpfLinkerChecked) return _sbpfLinker;
	_sbpfLinkerChecked = true;
	if (exec("which sbpf-linker > /dev/null 2>&1") === 0) {
		_sbpfLinker = "sbpf-linker";
	} else {
		// Try cargo default install location
		const home = getEnv("HOME");
		if (home !== "") {
			const cargoPath = `${home}/.cargo/bin/sbpf-linker`;
			if (exec(`test -x "${cargoPath}"`) === 0) {
				_sbpfLinker = cargoPath;
			}
		}
	}
	return _sbpfLinker;
}

// Validate a .bc file is BPF-compatible (no floats, no aggregate returns).
// Returns true if valid, false if llc rejects it.
export function validateBpfBitcode(bcFile: string): boolean {
	const llc = _bpfClang.length > 5 ? `"${_bpfClang.slice(0, _bpfClang.length - 5)}llc"` : "llc";
	return exec(`${llc} -march=bpfel -filetype=null "${bcFile}" 2>/dev/null`) === 0;
}

export function linkSolana(oFileList: string, outBinary: string): number {
	// Derive llvm-link path from BPF clang binary
	const llvmDir = _bpfClang.length > 5 ? _bpfClang.slice(0, _bpfClang.length - 5) : "";
	const llvmLink = llvmDir !== "" ? `"${llvmDir}llvm-link"` : "llvm-link";
	// Step 1: filter to only BPF-valid .bc files (reject float ops, aggregate returns)
	let validFiles = "";
	const parts = oFileList.split(" ");
	for (const f of parts) {
		if (f !== "" && validateBpfBitcode(f)) {
			if (validFiles !== "") validFiles = `${validFiles} `;
			validFiles = `${validFiles}${f}`;
		}
	}
	if (validFiles === "") return 1;
	// Step 2: merge valid .bc files into one
	const combined = `${outBinary}.bc`;
	const linkCode = exec(`${llvmLink} ${validFiles} -o "${combined}" 2>/dev/null`);
	if (linkCode !== 0) return linkCode;
	// Step 3: sbpf-linker converts bitcode to Solana-compatible ELF (DYN type)
	const linker = resolveSbpfLinker();
	if (linker === "") return 1;
	return exec(`${linker} "${combined}" --export entrypoint -o "${outBinary}" 2>/dev/null`);
}

export function getCompilerName(ccOption: number, ccBinary: string): string {
	// Explicit binary overrides everything (--cc=x86_64-linux-gnu-gcc)
	if (ccBinary !== "") return ccBinary;
	if (ccOption === 1) return "clang";
	if (ccOption === 2) return "gcc";
	// auto-detect: zig cc > clang > gcc > cc
	// zig cc preferred: unified experience, cross-compile ready, bundled sysroots.
	// Override with --cc=clang or --cc=gcc if needed.
	if (detectedCC === 0) {
		if (checkZigCC()) {
			detectedCC = 4;
		} else if (exec("which clang > /dev/null 2>&1") === 0) {
			detectedCC = 1;
		} else if (exec("which gcc > /dev/null 2>&1") === 0) {
			detectedCC = 2;
		} else {
			detectedCC = 3;
		}
	}
	if (detectedCC === 4) return "zig cc";
	if (detectedCC === 1) return "clang";
	if (detectedCC === 2) return "gcc";
	return "cc";
}

// Cross-compiler: zig cc is the default for cross-compilation.
// Returns "zig cc" if available, falls back to platform-specific cross-gcc.
export function getCrossCompilerName(ccOption: number, ccBinary: string, osTarget: string, cpuTarget: string): string {
	if (ccBinary !== "") return ccBinary;
	// zig cc: modern cross-compiler (clang + lld + all sysroots bundled)
	if (checkZigCC()) return "zig cc";
	// Fallback: platform-specific cross-gcc
	return getCompilerName(ccOption, ccBinary);
}

// -- Cross-compilation target triple --
// Builds clang --target flag from os + cpu (e.g. "x86_64-unknown-linux-gnu").
// Returns "" if no cross-compilation is configured.

// Normalize Go-style CPU name to clang triple format.
function normalizeCpu(cpu: string): string {
	if (cpu === "amd64") return "x86_64";
	if (cpu === "arm64") return "aarch64";
	if (cpu === "386") return "i386";
	return cpu;  // riscv64, mips64, etc. pass through
}

// Build cross-compilation target flag.
// zig cc uses "-target x86_64-windows-gnu" (no --target= prefix, no -pc-/-unknown- infixes).
// clang/gcc uses "--target=x86_64-pc-windows-gnu".
export function crossTargetFlag(osTarget: string, cpuTarget: string, useZig: boolean): string {
	if (osTarget === "" && cpuTarget === "") return "";
	const cpu = normalizeCpu(cpuTarget !== "" ? cpuTarget : "amd64");
	if (useZig) {
		// zig cc target format: cpu-os[-abi]
		let zigOs = osTarget;
		if (osTarget === "macos" || osTarget === "darwin") zigOs = "macos";
		if (osTarget === "windows") return `-target ${cpu}-windows-gnu`;
		if (osTarget === "linux") return `-target ${cpu}-linux-gnu`;
		if (zigOs !== "") return `-target ${cpu}-${zigOs}`;
		return `-target ${cpu}-native`;
	}
	// clang/gcc target format: cpu-vendor-os[-abi]
	let triple = cpu;
	if (osTarget === "linux") {
		triple = `${cpu}-unknown-linux-gnu`;
	} else if (osTarget === "macos" || osTarget === "darwin") {
		triple = `${cpu}-apple-darwin`;
	} else if (osTarget === "windows") {
		triple = `${cpu}-pc-windows-gnu`;
	} else if (osTarget === "freebsd") {
		triple = `${cpu}-unknown-freebsd`;
	} else if (osTarget !== "") {
		triple = `${cpu}-unknown-${osTarget}`;
	}
	return `--target=${triple}`;
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

// Build compile-phase flags from CLI options (sanitize + passC + cross-compile target).
// Is this a cross-compilation using zig cc?
function isCrossZig(opts: CliOptions): boolean {
	return opts.osTarget !== "" && opts.ccBinary === "" && checkZigCC();
}

export function cliCompileFlags(opts: CliOptions): string {
	let flags = "";
	// Solana/BPF: completely different flag set, skip everything else
	if (opts.osTarget === "solana") {
		flags = appendFlag(flags, "-target bpfel");
		flags = appendFlag(flags, "-fno-builtin");
		flags = appendFlag(flags, "-emit-llvm");
		const rtDir = resolveRuntimeDir();
		if (rtDir !== "") flags = appendFlag(flags, `-isystem ${rtDir}/runtime/freestanding`);
		if (opts.passC !== "") flags = appendFlag(flags, opts.passC);
		return flags;
	}
	// Cross-compilation target triple
	// zig cc: -target cpu-os-abi (bundled sysroot, no --target= prefix)
	// clang/gcc: --target=cpu-vendor-os-abi
	if ((opts.osTarget !== "" && opts.osTarget !== "bare" && opts.osTarget !== "solana") || opts.cpuTarget !== "") {
		const useZig = opts.ccBinary === "zig cc";
		const ct = crossTargetFlag(opts.osTarget, opts.cpuTarget, useZig);
		if (ct !== "") flags = appendFlag(flags, ct);
	}
	// Linux requires _GNU_SOURCE for POSIX APIs (clock_gettime, getaddrinfo, etc.)
	if (opts.osTarget === "linux") {
		flags = appendFlag(flags, "-D_GNU_SOURCE");
	}
	if (opts.osTarget === "windows" && opts.ccBinary !== "zig cc") {
		flags = appendFlag(flags, "-D_WIN32_WINNT=0x0600");
	}
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
	// Solana: sbpf-linker handles everything, no extra link flags
	if (opts.osTarget === "solana") return appendFlag(base, opts.passL);
	let flags = base;
	flags = appendFlag(flags, opts.passL);
	if (opts.strip) flags = appendFlag(flags, "-s");
	if (opts.isHcr) {
		flags = appendFlag(flags, "-shared");
	} else if (opts.osTarget === "linux") {
		flags = appendFlag(flags, "-Wl,--gc-sections");
		flags = appendFlag(flags, "-lpthread");
	} else if (opts.osTarget === "windows") {
		flags = appendFlag(flags, "-Wl,--gc-sections");
		flags = appendFlag(flags, "-lws2_32");
		flags = appendFlag(flags, "-lmswsock");
		flags = appendFlag(flags, "-lbcrypt");
	} else if (opts.osTarget === "" || opts.osTarget === "darwin") {
		flags = appendFlag(flags, "-Wl,-dead_strip");
	}
	return flags;
}

// Build all flags for single-file compile+link (cmdRun).
export function cliAllFlags(opts: CliOptions): string {
	return cliLinkFlags(cliCompileFlags(opts), opts);
}

// -- Build command construction --

function buildCompileCommand(cFile: string, outBinary: string, extraFlags: string, mode: number, ccOption: number, ccBinary: string): string {
	let cmd = `${getCcachePrefix()}${getCompilerName(ccOption, ccBinary)} -std=c11${modeFlags(mode)}`;

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
export function compileC(cFile: string, outBinary: string, extraFlags: string, mode: number, ccOption: number, ccBinary: string): number {
	const cmd = buildCompileCommand(cFile, outBinary, extraFlags, mode, ccOption, ccBinary);
	return exec(cmd);
}

// Compile a .c file to an object file only (-c flag, no linking).
// Returns 0 on success, non-zero on failure.
export function compileCFile(cFile: string, oFile: string, extraFlags: string, mode: number, ccOption: number, ccBinary: string): number {
	let cmd = `${getCcachePrefix()}${getCompilerName(ccOption, ccBinary)} -std=c11${modeFlags(mode)}`;

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
export function linkObjects(oFileList: string, outBinary: string, extraFlags: string, mode: number, ccOption: number, ccBinary: string): number {
	let cmd = getCompilerName(ccOption, ccBinary);

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

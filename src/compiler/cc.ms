// MetaScript Compiler CLI — C compiler wrapper
//
// Invokes clang to compile generated C source into native binaries.

import { exec, env, cmdExists, platform, ProcessError, ProcessErrorKind } from "std/process";
import { writeFile } from "std/fs";
import { join, dirname } from "std/fs/path";
import { CliOptions } from "./options";
import { resolveRuntimeDir } from "../utils/path";

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
		hasZigCC = cmdExists("zig");
	}
	return hasZigCC;
}

// -- Solana BPF toolchain detection --

let _bpfClang = "";
let _bpfClangChecked = false;

function testBpfClang(binary: string): boolean {
	// Check if clang supports BPF target (Apple clang doesn't)
	return exec(`"${binary}" --print-targets 2>/dev/null | grep -q bpf`).ok;
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
	if (exec("which sbpf-linker > /dev/null 2>&1").ok) {
		_sbpfLinker = "sbpf-linker";
	} else {
		// Try cargo default install location
		const home = env.get("HOME");
		if (home !== "") {
			const cargoPath = `${home}/.cargo/bin/sbpf-linker`;
			if (exec(`test -x "${cargoPath}"`).ok) {
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
	return exec(`${llc} -march=bpfel -filetype=null "${bcFile}" 2>/dev/null`).ok;
}

export function linkSolana(oFileList: string, outBinary: string): Result<void, ProcessError> {
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
	if (validFiles === "") {
		return Result.err({
			kind: ProcessErrorKind.SpawnFailed,
			command: "linkSolana",
			exitCode: 1,
			signal: 0,
			output: "",
			errorOutput: "",
			message: "no BPF-valid bitcode files to link",
		});
	}
	// Step 2: merge valid .bc files into one
	const combined = `${outBinary}.bc`;
	const linkRes = exec(`${llvmLink} ${validFiles} -o "${combined}" 2>/dev/null`);
	if (!linkRes.ok) return Result.err(linkRes.error);
	// Step 3: sbpf-linker converts bitcode to Solana-compatible ELF (DYN type)
	const linker = resolveSbpfLinker();
	if (linker === "") {
		return Result.err({
			kind: ProcessErrorKind.NotFound,
			command: "sbpf-linker",
			exitCode: 0,
			signal: 0,
			output: "",
			errorOutput: "",
			message: "sbpf-linker not found on PATH",
		});
	}
	const sbpfRes = exec(`${linker} "${combined}" --export entrypoint -o "${outBinary}" 2>/dev/null`);
	if (!sbpfRes.ok) return Result.err(sbpfRes.error);
	return Result.ok(null);
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
		} else if (cmdExists("clang")) {
			detectedCC = 1;
		} else if (cmdExists("gcc")) {
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

// -- C++ source support: per-file extension detection drives compiler + std-flag
// switch; a sticky flag drives the link-step driver switch so libc++ / libstdc++
// is linked automatically when needed.
//
// IMPORTANT — flag set timing: `_hasCppCompile` MUST be set at directive-
// resolution time (call `markCppCompile` from processCompileDirectives'
// main-thread loop), not just at compile time. Reason: the global content-
// addressed .o cache (cache.ms `tryRestoreFromGlobal`) restores byte-
// identical .o files without invoking compileCFile, so a compile-time-only
// flag-set would miss cache-hit .cpp paths and the linker would default to
// the C driver, losing libc++.

let _hasCppCompile = false;

function isCppFile(path: string): boolean {
	if (path.endsWith(".cpp")) return true;
	if (path.endsWith(".cxx")) return true;
	if (path.endsWith(".cc"))  return true;
	if (path.endsWith(".c++")) return true;
	if (path.endsWith(".cp"))  return true;
	if (path.endsWith(".C"))   return true;
	if (path.endsWith(".CPP")) return true;
	return false;
}

// Public: mark a source path as needing the C++ link driver. Idempotent +
// monotone (once true, stays true). Called from compile.ms at directive
// resolution time so it covers all paths (fresh compile + local cache hit
// + global cache hit + per-build dedup skip).
export function markCppCompile(path: string): void {
	if (isCppFile(path)) _hasCppCompile = true;
}

// Map a C-compiler invocation to its C++ counterpart.
// "zig cc" → "zig c++", "clang" → "clang++", "gcc" → "g++", "cc" → "c++".
// Explicit binaries (e.g. "x86_64-linux-gnu-gcc") get best-effort suffix swap.
function toCppCompiler(cName: string): string {
	if (cName === "zig cc") return "zig c++";
	if (cName === "clang")  return "clang++";
	if (cName === "gcc")    return "g++";
	if (cName === "cc")     return "c++";
	if (cName.endsWith("-gcc"))   return cName.slice(0, cName.length - 4) + "-g++";
	if (cName.endsWith("-clang")) return cName + "++";
	return cName;
}

// Cross-compiler: zig cc is the default for cross-compilation.
// Returns "zig cc" if available, falls back to platform-specific cross-gcc.
export function getCrossCompilerName(ccOption: number, ccBinary: string, targetOs: string, cpuTarget: string): string {
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
// Caller is responsible for only invoking when actually cross-compiling
// (targetOs !== platform || cpuTarget !== "").
export function crossTargetFlag(targetOs: string, cpuTarget: string, useZig: boolean): string {
	const cpu = normalizeCpu(cpuTarget !== "" ? cpuTarget : "amd64");
	if (useZig) {
		// zig cc target format: cpu-os[-abi]
		let zigOs = targetOs;
		if (targetOs === "macos" || targetOs === "darwin") zigOs = "macos";
		if (targetOs === "windows") return `-target ${cpu}-windows-gnu`;
		if (targetOs === "linux") return `-target ${cpu}-linux-gnu`;
		if (targetOs === "android") return `-target ${cpu}-linux-android`;
		return `-target ${cpu}-${zigOs}`;
	}
	// Android/iOS: the toolchain owns the triple + sysroot (NDK API-specific clang
	// wrapper, or Xcode -isysroot). Emitting our own --target shadows the wrapper's
	// API level and breaks libc-header/sysroot resolution.
	if (targetOs === "android" || targetOs === "ios") return "";
	// clang/gcc target format: cpu-vendor-os[-abi]
	let triple = cpu;
	if (targetOs === "linux") {
		triple = `${cpu}-unknown-linux-gnu`;
	} else if (targetOs === "macos" || targetOs === "darwin") {
		triple = `${cpu}-apple-darwin`;
	} else if (targetOs === "windows") {
		triple = `${cpu}-pc-windows-gnu`;
	} else if (targetOs === "freebsd") {
		triple = `${cpu}-unknown-freebsd`;
	} else {
		triple = `${cpu}-unknown-${targetOs}`;
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
	return opts.targetOs !== platform && opts.ccBinary === "" && checkZigCC();
}

export function cliCompileFlags(opts: CliOptions): string {
	let flags = "";
	// Solana/BPF: completely different flag set, skip everything else
	if (opts.targetOs === "solana") {
		flags = appendFlag(flags, "-target bpfel");
		flags = appendFlag(flags, "-fno-builtin");
		flags = appendFlag(flags, "-emit-llvm");
		const rtDir = resolveRuntimeDir();
		if (rtDir !== "") flags = appendFlag(flags, `-isystem ${rtDir}/runtime/freestanding`);
		if (opts.passC !== "") flags = appendFlag(flags, opts.passC);
		return flags;
	}
	// Emscripten (browser WASM): emcc handles everything
	if (opts.targetOs === "emcc") {
		if (opts.passC !== "") flags = appendFlag(flags, opts.passC);
		return flags;
	}
	// WASM32-WASI: zig cc handles sysroot + libc automatically
	if (opts.targetOs === "wasm") {
		flags = appendFlag(flags, "-target wasm32-wasi");
		flags = appendFlag(flags, "-fdata-sections -ffunction-sections");
		if (opts.passC !== "") flags = appendFlag(flags, opts.passC);
		return flags;
	}
	// Cross-compilation target triple
	// zig cc: -target cpu-os-abi (bundled sysroot, no --target= prefix)
	// clang/gcc: --target=cpu-vendor-os-abi
	// Trigger when actually crossing (target differs from host OS, or CPU explicit).
	// "bare" is freestanding (no OS) — needs target flag only if CPU is set.
	if ((opts.targetOs !== platform && opts.targetOs !== "bare") || opts.cpuTarget !== "") {
		const useZig = opts.ccBinary === "zig cc";
		const ct = crossTargetFlag(opts.targetOs, opts.cpuTarget, useZig);
		if (ct !== "") flags = appendFlag(flags, ct);
	}
	// Linux requires _GNU_SOURCE for POSIX APIs (clock_gettime, getaddrinfo, etc.)
	if (opts.targetOs === "linux") {
		flags = appendFlag(flags, "-D_GNU_SOURCE");
	}
	if (opts.targetOs === "windows" && opts.ccBinary !== "zig cc") {
		flags = appendFlag(flags, "-D_WIN32_WINNT=0x0600");
	}
	if (opts.gcMode === "orc") flags = appendFlag(flags, "-DMSGC_ORC");
	if (opts.sanitize !== "") flags = appendFlag(flags, `-fsanitize=${opts.sanitize}`);
	// Linker DCE: place each function/data in its own section so the linker can strip unused ones
	flags = appendFlag(flags, "-fdata-sections");
	flags = appendFlag(flags, "-ffunction-sections");
	if (opts.isHcr || opts.appMode === "lib" || opts.appMode === "staticlib") flags = appendFlag(flags, "-fPIC");
	flags = appendFlag(flags, opts.passC);
	return flags;
}

// Build link-phase flags (adds passL + strip on top of compile flags).
export function cliLinkFlags(base: string, opts: CliOptions): string {
	// Solana: sbpf-linker handles everything, no extra link flags
	if (opts.targetOs === "solana") return appendFlag(base, opts.passL);
	// Emscripten: emcc links to .js + .wasm bundle
	if (opts.targetOs === "emcc") {
		let eflags = appendFlag(base, "-sWASM=1 -sALLOW_MEMORY_GROWTH=1");
		eflags = appendFlag(eflags, opts.passL);
		return eflags;
	}
	// WASM: zig cc links with -target wasm32-wasi, strip dead sections + debug info
	if (opts.targetOs === "wasm") {
		let wflags = appendFlag(base, "-target wasm32-wasi");
		wflags = appendFlag(wflags, "-Wl,--gc-sections -Wl,--strip-all");
		wflags = appendFlag(wflags, opts.passL);
		return wflags;
	}
	let flags = base;
	flags = appendFlag(flags, opts.passL);
	if (opts.strip) flags = appendFlag(flags, "-s");
	if (opts.isHcr || opts.appMode === "lib") {
		flags = appendFlag(flags, "-shared");
	} else {
		if (opts.targetOs === "linux") {
			flags = appendFlag(flags, "-Wl,--gc-sections");
			flags = appendFlag(flags, "-lpthread");
		} else if (opts.targetOs === "windows") {
			flags = appendFlag(flags, "-Wl,--gc-sections");
			flags = appendFlag(flags, "-lws2_32");
			flags = appendFlag(flags, "-lmswsock");
			flags = appendFlag(flags, "-lbcrypt");
		} else if (opts.targetOs === "darwin" || opts.targetOs === "macos") {
			flags = appendFlag(flags, "-Wl,-dead_strip");
		}
	}
	return flags;
}

// Build all flags for single-file compile+link (cmdRun).
export function cliAllFlags(opts: CliOptions): string {
	return cliLinkFlags(cliCompileFlags(opts), opts);
}

// -- Build command construction --

function buildCompileCommand(cFile: string, outBinary: string, extraFlags: string, mode: number, ccOption: number, ccBinary: string): string {
	const isCpp = isCppFile(cFile);
	// Single-file path (compileC) doesn't go through processCompileDirectives,
	// so the flag-set lives here too. For the multi-file @compile pipeline,
	// the canonical set is markCppCompile called from compile.ms.
	if (isCpp) _hasCppCompile = true;
	const baseCompiler = getCompilerName(ccOption, ccBinary);
	const compiler = isCpp ? toCppCompiler(baseCompiler) : baseCompiler;
	const stdFlag = isCpp ? "-std=c++17" : "-std=gnu11";
	let cmd = `${compiler} ${stdFlag}${modeFlags(mode)}`;

	const rtDir = resolveRuntime();
	if (rtDir !== "") {
		cmd = `${cmd} -iquote${dirname(dirname(rtDir))}`;
	}

	cmd = `${cmd} ${cFile} -o ${outBinary} -lm`;
	if (extraFlags !== "") cmd = `${cmd} ${extraFlags}`;
	return cmd;
}

// Compile a .c file to a native binary.
// Returns Result.ok on exit-code 0; Result.err carries gcc/clang stderr.
export function compileC(cFile: string, outBinary: string, extraFlags: string, mode: number, ccOption: number, ccBinary: string): Result<void, ProcessError> {
	const cmd = buildCompileCommand(cFile, outBinary, extraFlags, mode, ccOption, ccBinary);
	const r = exec(cmd);
	if (!r.ok) return Result.err(r.error);
	return Result.ok(null);
}

// Compile a .c file to an object file only (-c flag, no linking).
// Returns Result.ok on exit-code 0; Result.err carries gcc/clang stderr.
export function compileCFile(cFile: string, oFile: string, extraFlags: string, mode: number, ccOption: number, ccBinary: string): Result<void, ProcessError> {
	const isCpp = isCppFile(cFile);
	const baseCompiler = getCompilerName(ccOption, ccBinary);
	const compiler = isCpp ? toCppCompiler(baseCompiler) : baseCompiler;
	const stdFlag = isCpp ? "-std=c++17" : "-std=gnu11";
	let cmd = `${compiler} ${stdFlag}${modeFlags(mode)}`;

	const rtDir = resolveRuntime();
	if (rtDir !== "") {
		cmd = `${cmd} -iquote${dirname(dirname(rtDir))}`;
	}

	cmd = `${cmd} -c ${cFile} -o ${oFile}`;
	if (extraFlags !== "") cmd = `${cmd} ${extraFlags}`;
	const r = exec(cmd);
	if (!r.ok) return Result.err(r.error);
	return Result.ok(null);
}

// Windows cmd.exe caps command lines at 8191 chars. Link commands with hundreds
// of .o files exceed that. GCC/clang/zig cc accept `@file` response files —
// spill the bulky middle (.o list + extraFlags) there and pass one `@path` on
// the CLI. Windows cmd.exe caps the line at 8191; 7800 leaves headroom.
const LINK_CMD_LIMIT = 7800;

// Link object files + runtime into a binary.
// oFileList: space-separated list of .o file paths
// Returns Result.ok on exit-code 0; Result.err carries linker stderr.
export function linkObjects(oFileList: string, outBinary: string, extraFlags: string, mode: number, ccOption: number, ccBinary: string): Result<void, ProcessError> {
	const baseCompiler = getCompilerName(ccOption, ccBinary);
	// Sticky flag: any .cpp file compiled in this build → use C++ driver for
	// the final link so libc++ / libstdc++ is pulled automatically. Pure-C
	// builds keep the existing C-driver behavior (no behavior change).
	const compiler = _hasCppCompile ? toCppCompiler(baseCompiler) : baseCompiler;
	const rtDir = resolveRuntime();
	const rtFlag = rtDir !== "" ? ` -iquote${dirname(dirname(rtDir))}` : "";
	const bulk = extraFlags !== "" ? `${oFileList} ${extraFlags}` : oFileList;
	const cmd = `${compiler}${rtFlag} ${bulk} -o ${outBinary} -lm`;

	let r: Result<string, ProcessError>;
	if (cmd.length <= LINK_CMD_LIMIT) {
		r = exec(cmd);
	} else {
		// Overflow: bulk args go to a per-binary response file. The path is keyed to
		// outBinary (not its dir) so concurrent builds in a shared dir don't clobber it.
		const rspPath = `${outBinary}_link.rsp`;
		writeFile(rspPath, bulk);
		r = exec(`${compiler}${rtFlag} @${rspPath} -o ${outBinary} -lm`);
	}
	if (!r.ok) return Result.err(r.error);
	return Result.ok(null);
}

// Archive object files into a static library for --app=staticlib. Remove the stale
// archive first: `ar rcs` appends, so a leftover would keep already-dropped members.
export function archiveStatic(oFileList: string, outArchive: string): Result<void, ProcessError> {
	exec(`rm -f ${outArchive}`);
	const r = exec(`ar rcs ${outArchive} ${oFileList}`);
	if (!r.ok) return Result.err(r.error);
	return Result.ok(null);
}

// Get the runtime directory path (for -I include path).
export function getRuntimeDir(): string {
	return resolveRuntime();
}

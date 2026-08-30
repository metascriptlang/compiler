// MetaScript Compiler CLI — C compiler wrapper
//
// Invokes clang to compile generated C source into native binaries.

import { exec, env, cmdExists, findOnPath, platform, exit, ProcessError, ProcessErrorKind } from "std/process";
import { writeFile, ensureDir, exists, readDir } from "std/fs";
import { join, dirname } from "std/fs/path";
import { writeStderr } from "std/io";
import { CliOptions, MODE_DANGER } from "./options";
import { resolveRuntimeDir } from "../utils/path";
import { managedZigCompiler } from "./toolchain";

// -- Runtime resolution --

function resolveRuntime(): string {
	const root = resolveRuntimeDir();
	if (root.length > 0) return join(root, "runtime");
	return "";
}

// -- C compiler detection --
// 0=undetected, 1=clang, 2=gcc, 3=cc (fallback), 4=zig cc
let detectedCC = 0;
let managedCC = "";
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
		const mz = managedZigCompiler();
		if (mz !== "") {
			managedCC = mz;
			detectedCC = 4;
		} else if (checkZigCC()) {
			detectedCC = 4;
		} else if (cmdExists("clang")) {
			detectedCC = 1;
		} else if (cmdExists("gcc")) {
			detectedCC = 2;
		} else {
			detectedCC = 3;
		}
	}
	if (detectedCC === 4) return managedCC !== "" ? managedCC : "zig cc";
	if (detectedCC === 1) return "clang";
	if (detectedCC === 2) return "gcc";
	return "cc";
}

function isZigCC(cc: string): boolean {
	return cc === "zig cc" || cc.endsWith(" cc");
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
	if (path.endsWith(".mm"))  return true;
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
	if (cName.endsWith(" cc")) return cName.slice(0, cName.length - 2) + "c++";
	if (cName === "clang")  return "clang++";
	if (cName === "gcc")    return "g++";
	if (cName === "cc")     return "c++";
	if (cName.endsWith("-gcc"))   return cName.slice(0, cName.length - 4) + "-g++";
	if (cName.endsWith("-clang")) return cName + "++";
	return cName;
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
// Opt-level only. LTO strategy is a separate axis — see ltoFlags/opts.lto.

export function modeFlags(mode: number): string {
	return match (mode) {
		2 => " -O3 -w -DNDEBUG",
		1 => " -O2 -w -DNDEBUG",
		_ => " -O0 -g",
	};
}

// -- LTO capability + strategy --
// One table, one place: which compiler/target pairs can link with LTO, and
// which should reach for it by default. Both halves of the decision live with
// the compiler, so resolveLto below must run right AFTER resolveCC — parseArgs
// cannot decide this (it runs before the compiler is known).

// GNU gcc (resolved names: "gcc", "x86_64-linux-gnu-gcc", "g++", …). macOS's
// /usr/bin/gcc is a clang shim, but auto-detection never resolves to the name
// "gcc" unless clang and zig are both absent, so this stays accurate.
function isGnuGcc(cc: string): boolean {
	return cc === "gcc" || cc.endsWith("-gcc") || cc.endsWith("g++");
}

// Proven-broken pairs — an LTO link can NEVER succeed here, so even an
// explicit --lto= fails loud:
// - zig → Mach-O: zig replaced LLD with its own Mach-O linker, which has no
//   LTO path; `-fuse-ld=` is silently ignored, so there is no escape hatch.
//   Target-scoped: the linker is picked by object format, not by host.
// - zig → windows-gnu: the LTO link pulls in zigc.lib, whose MinGW math-shim
//   exports (__INF, __QNAN, __SNANL, nanl, …) are weak+hidden in bitcode and
//   get dropped during LTO internalization. A 3-line hello.c reproduces it at
//   every opt level. (Zig 0.16.0.)
export function ltoBroken(cc: string, targetOs: string): boolean {
	if (!isZigCC(cc)) return false;
	if (targetOs === "windows") return true;
	return targetOs === "darwin" || targetOs === "macos";
}

// Should --danger reach for LTO by default? Practicality on top of
// possibility: GNU gcc links -flto, but a whole-program link of this tree ran
// 40+ minutes without finishing — never a sane default, still allowed
// explicitly (informed choice, e.g. an overnight CI build).
function ltoDefaultOn(cc: string, targetOs: string): boolean {
	if (ltoBroken(cc, targetOs)) return false;
	if (isGnuGcc(cc)) return false;
	return true;
}

// Resolve opts.lto once the compiler is known. Empty = no explicit --lto=:
// --danger means "the fastest binary this toolchain can produce on this
// target", so it takes thin LTO where that links and drops it (with a notice)
// where it cannot. An explicit --lto= against a proven-broken pair fails loud.
export function resolveLto(opts: CliOptions): void {
	const cc = getCompilerName(opts.ccCompiler, opts.ccBinary);
	const ccName = isZigCC(cc) ? "zig cc" : cc;
	if (opts.lto === "") {
		if (opts.mode === MODE_DANGER && ltoDefaultOn(cc, opts.targetOs)) {
			opts.lto = "thin";
		} else {
			opts.lto = "off";
			if (opts.mode === MODE_DANGER) {
				writeStderr(`note: --danger builds without LTO for ${ccName} targeting ${opts.targetOs}.\n`);
			}
		}
		return;
	}
	if (opts.lto !== "off" && ltoBroken(cc, opts.targetOs)) {
		const mac = opts.targetOs === "darwin" || opts.targetOs === "macos";
		const hint = mac ? "re-run with --cc=clang, or drop --lto" : "drop --lto";
		writeStderr(`error: ${ccName} cannot link with LTO targeting ${opts.targetOs}.\n`);
		writeStderr(`  → ${hint}.\n`);
		exit(1);
	}
}

// -- LTO strategy flags --
// Orthogonal to opt-level. Thin = parallel per-function LTO (fast link, ~full
// runtime); full = monolithic whole-program LTO (slow serial link). Rides the
// compile-flag string, which already flows to both compile and link commands.
// Spelling is per-compiler: -flto=thin is an LLVM spelling; GNU gcc calls its
// parallel variant -flto=auto and rejects "thin" outright.
export function ltoFlags(lto: string, cc: string): string {
	if (lto === "thin") return isGnuGcc(cc) ? " -flto=auto" : " -flto=thin";
	if (lto === "full") return " -flto";
	return "";
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
		const useZig = isZigCC(getCompilerName(opts.ccCompiler, opts.ccBinary));
		const ct = crossTargetFlag(opts.targetOs, opts.cpuTarget, useZig);
		if (ct !== "") flags = appendFlag(flags, ct);
	}
	// Linux requires _GNU_SOURCE for POSIX APIs (clock_gettime, getaddrinfo, etc.)
	if (opts.targetOs === "linux") {
		flags = appendFlag(flags, "-D_GNU_SOURCE");
	}
	if (opts.targetOs === "windows" && !isZigCC(getCompilerName(opts.ccCompiler, opts.ccBinary))) {
		flags = appendFlag(flags, "-D_WIN32_WINNT=0x0600");
	}
	if (opts.gcMode === "orc") flags = appendFlag(flags, "-DMSGC_ORC");
	if (opts.sanitize !== "") flags = appendFlag(flags, `-fsanitize=${opts.sanitize}`);
	// Linker DCE: place each function/data in its own section so the linker can strip unused ones
	flags = appendFlag(flags, "-fdata-sections");
	flags = appendFlag(flags, "-ffunction-sections");
	// LTO strategy — emitted into the compile flags, which also flow to the link
	// command (allLink = cliLinkFlags(allFlags)); thin bitcode + -flto=thin at
	// link enables the parallel ThinLTO backend. opts.lto is final here:
	// resolveLto ran right after resolveCC.
	flags = appendFlag(flags, ltoFlags(opts.lto, getCompilerName(opts.ccCompiler, opts.ccBinary)));
	if (opts.isHcr || opts.appMode === "lib" || opts.appMode === "staticlib") flags = appendFlag(flags, "-fPIC");
	flags = appendFlag(flags, opts.passC);
	return flags;
}

// Build link-phase flags (adds passL + strip on top of compile flags).
//
// forceExe: the caller needs an executable whatever --app / --hcr say. Only
// cmdTest passes it — the test binary is run via execFile, so a `-shared` link
// would hand it an artifact it cannot execute, and that branch also skips the
// per-target system libraries the test binary still has to resolve against.
export function cliLinkFlags(base: string, opts: CliOptions, forceExe: boolean = false): string {
	// Solana: linkSolana drives ld.lld with its own flag set (linker script,
	// entry symbol, gc-sections) — none of the cc-driver flags apply.
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
	if (!forceExe && (opts.isHcr || opts.appMode === "lib")) {
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
	ensureDir(dirname(outBinary));
	const cmd = buildCompileCommand(cFile, outBinary, extraFlags, mode, ccOption, ccBinary);
	const r = exec(cmd);
	if (!r.ok) return Result.err(r.error);
	return Result.ok(null);
}

// Compile a .c file to an object file only (-c flag, no linking).
// Returns Result.ok on exit-code 0; Result.err carries gcc/clang stderr.
export function compileCFile(cFile: string, oFile: string, extraFlags: string, mode: number, ccOption: number, ccBinary: string): Result<void, ProcessError> {
	ensureDir(dirname(oFile));
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
	ensureDir(dirname(outBinary));
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
	ensureDir(dirname(outArchive));
	exec(`rm -f ${outArchive}`);
	const r = exec(`ar rcs ${outArchive} ${oFileList}`);
	if (!r.ok) return Result.err(r.error);
	return Result.ok(null);
}

// Get the runtime directory path (for -I include path).
export function getRuntimeDir(): string {
	return resolveRuntime();
}

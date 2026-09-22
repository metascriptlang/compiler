// MetaScript Compiler CLI — C compiler wrapper
//
// Invokes clang to compile generated C source into native binaries.

import { exec, env, cmdExists, findOnPath, platform, exit, execFileCapture, processError, ProcessError, ProcessErrorKind } from "std/process";
import { writeFile, ensureDir, exists, readDir, remove } from "std/fs";
import { join, dirname } from "std/fs/path";
import { writeStderr } from "std/io";
import { CliOptions, MODE_DANGER } from "./options";
import { renameReplace, atomicWriteFile } from "./io";
import { resolveRuntimeDir } from "../utils/path";
import { managedZigCompiler } from "./toolchain";
import { splitCcFlags, quoteCcArg } from "../utils/commandLine";

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

// -- Solana SBF toolchain detection --
//
// The toolchain is Anza's platform-tools bundle: an LLVM whose clang has the
// `sbf` target registered, plus the `ld.lld` shipped beside it. Stock system
// clang does NOT qualify: it carries `bpf`/`bpfel` (Linux kernel BPF), which is
// a different ABI — no static syscalls, different call convention, different
// memory map. Linking a kernel-BPF object as a Solana program produces an ELF
// the VM rejects, so the probe below matches the `sbf` target by name.
//
// Resolution order: $MSC_SBF_CLANG (escape hatch) → ~/.cache/solana/<ver>/
// platform-tools (where `cargo build-sbf` installs it) → PATH clang.

const SBF_TARGET = "sbpfv3-solana-solana";

let _sbfClang = "";
let _sbfClangChecked = false;

function exeSuffix(): string {
	return platform == "windows" ? ".exe" : "";
}

function homeDir(): string {
	const h = env.get("HOME");
	if (h != "") return h;
	return env.get("USERPROFILE");
}

// True when this clang has the Solana `sbf` backend registered. Reads the
// --print-targets table in-process rather than shelling out to a pipeline:
// `grep` does not exist on Windows and `2>/dev/null` is not cmd.exe syntax, so
// the old probe returned false on every Windows host.
function hasSbfTarget(binary: string): boolean {
	const r = exec(`"${binary}" --print-targets`);
	if (!r.ok) return false;
	for (const line of r.value.split("\n")) {
		// Rows read "    sbf        - SBF new (little endian)". Match the name
		// column exactly so `bpf` and `bpfel` are not mistaken for a hit.
		const name = line.trim().split(" ")[0];
		if (name == "sbf") return true;
	}
	return false;
}

// Ordering for the version dirs below. Plain string comparison ranks "v1.9"
// above "v1.57"; comparing equal-position digit runs by length first restores
// numeric order without parsing.
function isNewerVersionDir(a: string, b: string): boolean {
	const ap = a.split(".");
	const bp = b.split(".");
	const shared = ap.length < bp.length ? ap.length : bp.length;
	for (let i = 0; i < shared; i++) {
		const x = ap[i];
		const y = bp[i];
		if (x.length != y.length) return x.length > y.length;
		if (x != y) return x > y;
	}
	return ap.length > bp.length;
}

// Newest platform-tools under ~/.cache/solana. Entries are version dirs
// ("v1.57"); readDir marks directories with a trailing "/". Any of them that
// passes hasSbfTarget can build; the ordering only picks a recent one.
function cachedPlatformToolsClang(): string {
	const home = homeDir();
	if (home == "") return "";
	const cacheRoot = join(home, ".cache/solana");
	if (!exists(cacheRoot)) return "";
	let best = "";
	let bestName = "";
	for (const entry of readDir(cacheRoot)) {
		let name = entry;
		if (name.endsWith("/")) name = name.slice(0, name.length - 1);
		if (name == "") continue;
		const candidate = join(cacheRoot, `${name}/platform-tools/llvm/bin/clang${exeSuffix()}`);
		if (!exists(candidate)) continue;
		if (bestName == "" || isNewerVersionDir(name, bestName)) {
			best = candidate;
			bestName = name;
		}
	}
	return best;
}

export function resolveBpfClang(): string {
	if (_sbfClangChecked) return _sbfClang;
	_sbfClangChecked = true;

	const override = env.get("MSC_SBF_CLANG");
	if (override != "" && hasSbfTarget(override)) {
		_sbfClang = override;
		return _sbfClang;
	}

	const cached = cachedPlatformToolsClang();
	if (cached != "" && hasSbfTarget(cached)) {
		_sbfClang = cached;
		return _sbfClang;
	}

	const onPath = findOnPath("clang");
	if (onPath != "" && hasSbfTarget(onPath)) {
		_sbfClang = onPath;
		return _sbfClang;
	}
	return "";
}

// `ld.lld` from the same LLVM bin/ as the resolved clang. Deliberately not a
// PATH lookup: a system ld.lld is a different LLVM version than the clang that
// produced the objects, and platform-tools always ships the pair together.
export function resolveSbfLinker(): string {
	const clang = resolveBpfClang();
	if (clang == "") return "";
	const lld = join(dirname(clang), `ld.lld${exeSuffix()}`);
	if (exists(lld)) return lld;
	return "";
}

// Linker script for SBPFv3, verbatim from the `link-script` field of
//   rustc --target=sbpfv3-solana-solana --print target-spec-json
// This is the authoritative layout, and it is NOT the same as the `sbf.ld` in
// agave's C SDK — that one is the v0 legacy layout (.text at 0, live .dynamic/
// .dynsym/.rel.dyn) and solana-sbpf rejects it with InvalidProgramHeader. The
// loader expects exactly two PT_LOAD headers: PF_R .rodata at 0x0 and PF_X
// .text at 0x1_0000_0000 (see solana-sbpf src/elf.rs, EXPECTED_PROGRAM_HEADERS).
//
// The /DISCARD/ of .data*/.bss* is what makes "no mutable globals" a hard
// requirement rather than advice: a program that keeps one fails the link with
// "relocation refers to a symbol in a discarded section" (verified) — loud, not
// silent, but still a wall until module-level DCE lands (docs/BARE.md Phase 3b).
const SBPF_LINK_SCRIPT = `PHDRS
{
  rodata PT_LOAD FLAGS(4);
  text PT_LOAD FLAGS(1);
  other PT_NULL FLAGS(0);
}

SECTIONS
{
  .rodata 0x000000000 : SUBALIGN(8) {
    BYTE(0);
    *(.rodata*)
    *(.data.rel.ro*)
    . = ALIGN(8);
  } :rodata
  .text 0x100000000 : {
     *(.text*)
  } :text
  /DISCARD/ : {
      *(.comment*)
      *(.eh_frame*)
      *(*hash*)
      *(.bss*)
      *(.data*)
      *(.rel.dyn*)
      *(.dynamic)
      *(.dynsym)
      *(.dynstr)
    }
}
`;

function sbfCompilerBuiltins(): string {
	const clang = resolveBpfClang();
	if (clang == "") return "";
	const libDir = join(dirname(dirname(dirname(clang))), `rust/lib/rustlib/${SBF_TARGET}/lib`);
	if (!exists(libDir)) return "";
	for (const entry of readDir(libDir)) {
		if (entry.startsWith("libcompiler_builtins-") && entry.endsWith(".rlib")) return join(libDir, entry);
	}
	return "";
}

// Link SBF objects into a deployable Solana program (.so).
//
// One `ld.lld` invocation — no bitcode round-trip and no third-party linker.
// The previous pipeline (clang -emit-llvm → llvm-link → `sbpf-linker` installed
// via cargo) is gone: objects compiled for the real `sbf` target link directly,
// and ld.lld ships inside platform-tools. --gc-sections drops unreferenced
// functions (verified: strips a dead function, 952 → 880 bytes), rooted at the
// `entrypoint` symbol via --entry.
export function linkSolana(oFiles: string[], outBinary: string): Result<void, ProcessError> {
	const lld = resolveSbfLinker();
	if (lld == "") {
		return Result.err({
			kind: ProcessErrorKind.NotFound,
			command: "ld.lld",
			exitCode: 0,
			signal: 0,
			output: "",
			errorOutput: "",
			message: "ld.lld not found next to the SBF clang (platform-tools llvm/bin)",
		});
	}
	ensureDir(dirname(outBinary));
	const scriptPath = `${outBinary}.ld`;
	const w = writeFile(scriptPath, SBPF_LINK_SCRIPT);
	if (!w.ok) {
		return Result.err({
			kind: ProcessErrorKind.SpawnFailed,
			command: "linkSolana",
			exitCode: 1,
			signal: 0,
			output: "",
			errorOutput: "",
			message: `cannot write linker script ${scriptPath}`,
		});
	}
	const args = [
		"--threads=1",
		"-z",
		"notext",
		"--Bdynamic",
		"-shared",
		"--script",
		scriptPath,
		"--entry",
		"entrypoint",
		"--gc-sections",
		"--no-undefined",
		"-o",
		outBinary,
	];
	for (const oFile of oFiles) args.push(oFile);
	const builtins = sbfCompilerBuiltins();
	if (builtins != "") args.push(builtins);
	const r = execFileCapture(lld, args);
	if (!r.ok) return Result.err(r.error);
	return Result.ok(null);
}

export function getCompilerName(ccOption: number, ccBinary: string): string {
	// Explicit binary overrides everything (--cc=x86_64-linux-gnu-gcc)
	if (ccBinary != "") return ccBinary;
	if (ccOption == 1) return "clang";
	if (ccOption == 2) return "gcc";
	// auto-detect: zig cc > clang > gcc > cc
	// zig cc preferred: unified experience, cross-compile ready, bundled sysroots.
	// Override with --cc=clang or --cc=gcc if needed.
	if (detectedCC == 0) {
		const mz = managedZigCompiler();
		if (mz != "") {
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
	if (detectedCC == 4) return managedCC != "" ? managedCC : "zig cc";
	if (detectedCC == 1) return "clang";
	if (detectedCC == 2) return "gcc";
	return "cc";
}

function isZigCC(cc: string): boolean {
	return cc == "zig cc" || cc.endsWith(" cc");
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
	if (cName == "clang")  return "clang++";
	if (cName == "gcc")    return "g++";
	if (cName == "cc")     return "c++";
	if (cName.endsWith("-gcc"))   return cName.slice(0, cName.length - 4) + "-g++";
	if (cName.endsWith("-clang")) return cName + "++";
	return cName;
}

// -- Cross-compilation target triple --
// Builds clang --target flag from os + cpu (e.g. "x86_64-unknown-linux-gnu").
// Returns "" if no cross-compilation is configured.

// Normalize Go-style CPU name to clang triple format.
function normalizeCpu(cpu: string): string {
	if (cpu == "amd64") return "x86_64";
	if (cpu == "arm64") return "aarch64";
	if (cpu == "386") return "i386";
	return cpu;  // riscv64, mips64, etc. pass through
}

// Build cross-compilation target flag.
// zig cc uses "-target x86_64-windows-gnu" (no --target= prefix, no -pc-/-unknown- infixes).
// clang/gcc uses "--target=x86_64-pc-windows-gnu".
// Caller is responsible for only invoking when actually cross-compiling
// (targetOs !== platform || cpuTarget !== "").
export function crossTargetFlag(targetOs: string, cpuTarget: string, useZig: boolean): string {
	const cpu = normalizeCpu(cpuTarget != "" ? cpuTarget : "amd64");
	if (useZig) {
		// zig cc target format: cpu-os[-abi]
		let zigOs = targetOs;
		if (targetOs == "macos" || targetOs == "darwin") zigOs = "macos";
		if (targetOs == "windows") return `-target ${cpu}-windows-gnu`;
		if (targetOs == "linux") return `-target ${cpu}-linux-gnu`;
		if (targetOs == "android") return `-target ${cpu}-linux-android`;
		return `-target ${cpu}-${zigOs}`;
	}
	// Android/iOS: the toolchain owns the triple + sysroot (NDK API-specific clang
	// wrapper, or Xcode -isysroot). Emitting our own --target shadows the wrapper's
	// API level and breaks libc-header/sysroot resolution.
	if (targetOs == "android" || targetOs == "ios") return "";
	// clang/gcc target format: cpu-vendor-os[-abi]
	let triple = cpu;
	if (targetOs == "linux") {
		triple = `${cpu}-unknown-linux-gnu`;
	} else if (targetOs == "macos" || targetOs == "darwin") {
		triple = `${cpu}-apple-darwin`;
	} else if (targetOs == "windows") {
		triple = `${cpu}-pc-windows-gnu`;
	} else if (targetOs == "freebsd") {
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
	return cc == "gcc" || cc == "g++" || cc.endsWith("-gcc") || cc.endsWith("-g++");
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
	if (targetOs == "windows") return true;
	return targetOs == "darwin" || targetOs == "macos";
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
	if (opts.lto == "") {
		if (opts.mode == MODE_DANGER && ltoDefaultOn(cc, opts.targetOs)) {
			opts.lto = "thin";
		} else {
			opts.lto = "off";
			if (opts.mode == MODE_DANGER) {
				writeStderr(`note: --danger builds without LTO for ${ccName} targeting ${opts.targetOs}.\n`);
			}
		}
		return;
	}
	if (opts.lto != "off" && ltoBroken(cc, opts.targetOs)) {
		const mac = opts.targetOs == "darwin" || opts.targetOs == "macos";
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
	if (lto == "thin") return isGnuGcc(cc) ? " -flto=auto" : " -flto=thin";
	if (lto == "full") return " -flto";
	return "";
}

// -- Flag accumulation helpers --

// Append a flag to a space-separated flag string. No-op if flag is empty.
export function appendFlag(base: string, flag: string): string {
	if (flag == "") return base;
	if (base.length > 0) return `${base} ${flag}`;
	return flag;
}

// Build compile-phase flags from CLI options (sanitize + passC + cross-compile target).
// Is this a cross-compilation using zig cc?
function isCrossZig(opts: CliOptions): boolean {
	return opts.targetOs != platform && opts.ccBinary == "" && checkZigCC();
}

export function cliCompileFlags(opts: CliOptions): string {
	let flags = "";
	// Solana/SBF: completely different flag set, skip everything else.
	// The triple is the Solana one, NOT `bpfel`: bpfel is Linux kernel BPF, a
	// different ABI the Solana VM will not run. `sbpfv3-solana-solana` is the
	// current network target (platform-tools >= v1.53 — earlier releases shipped
	// the name with a different LLVM definition; see the platform-tools README).
	if (opts.targetOs == "solana") {
		flags = appendFlag(flags, `-target ${SBF_TARGET}`);
		flags = appendFlag(flags, "-fno-builtin");
		flags = appendFlag(flags, "-fPIC");
		flags = appendFlag(flags, "-fvisibility=hidden");
		// Per-symbol sections so the --gc-sections at link time can strip what
		// the program does not reach.
		flags = appendFlag(flags, "-fdata-sections -ffunction-sections");
		const rtDir = resolveRuntimeDir();
		if (rtDir != "") flags = appendFlag(appendFlag(flags, "-isystem"), quoteCcArg(`${rtDir}/runtime/freestanding`));
		if (opts.passC != "") flags = appendFlag(flags, opts.passC);
		return flags;
	}
	// Emscripten (browser WASM): emcc handles everything
	if (opts.targetOs == "emcc") {
		if (opts.passC != "") flags = appendFlag(flags, opts.passC);
		return flags;
	}
	// WASM32-WASI: zig cc handles sysroot + libc automatically
	if (opts.targetOs == "wasm") {
		flags = appendFlag(flags, "-target wasm32-wasi");
		flags = appendFlag(flags, "-fdata-sections -ffunction-sections");
		if (opts.passC != "") flags = appendFlag(flags, opts.passC);
		return flags;
	}
	// Cross-compilation target triple
	// zig cc: -target cpu-os-abi (bundled sysroot, no --target= prefix)
	// clang/gcc: --target=cpu-vendor-os-abi
	// Trigger when actually crossing (target differs from host OS, or CPU explicit).
	// "bare" is freestanding (no OS) — needs target flag only if CPU is set.
	if ((opts.targetOs != platform && opts.targetOs != "bare") || opts.cpuTarget != "") {
		const useZig = isZigCC(getCompilerName(opts.ccCompiler, opts.ccBinary));
		const ct = crossTargetFlag(opts.targetOs, opts.cpuTarget, useZig);
		if (ct != "") flags = appendFlag(flags, ct);
	}
	// Linux requires _GNU_SOURCE for POSIX APIs (clock_gettime, getaddrinfo, etc.)
	if (opts.targetOs == "linux") {
		flags = appendFlag(flags, "-D_GNU_SOURCE");
	}
	if (opts.targetOs == "windows" && !isZigCC(getCompilerName(opts.ccCompiler, opts.ccBinary))) {
		flags = appendFlag(flags, "-D_WIN32_WINNT=0x0600");
	}
	if (opts.gcMode == "orc") flags = appendFlag(flags, "-DMSGC_ORC");
	if (opts.sanitize != "") flags = appendFlag(flags, `-fsanitize=${opts.sanitize}`);
	// Linker DCE: place each function/data in its own section so the linker can strip unused ones
	flags = appendFlag(flags, "-fdata-sections");
	flags = appendFlag(flags, "-ffunction-sections");
	// LTO strategy — emitted into the compile flags, which also flow to the link
	// command (allLink = cliLinkFlags(allFlags)); thin bitcode + -flto=thin at
	// link enables the parallel ThinLTO backend. opts.lto is final here:
	// resolveLto ran right after resolveCC.
	flags = appendFlag(flags, ltoFlags(opts.lto, getCompilerName(opts.ccCompiler, opts.ccBinary)));
	if (opts.isHcr || opts.appMode == "lib" || opts.appMode == "staticlib") flags = appendFlag(flags, "-fPIC");
	flags = appendFlag(flags, opts.passC);
	return flags;
}

// Build link-phase flags (adds passL + strip on top of compile flags).
//
// forceExe: the caller needs an executable whatever --app / --hcr say. Only
// cmdTest passes it — the test binary is run via execFile.
export function cliLinkFlags(base: string, opts: CliOptions, forceExe: boolean = false): string {
	// Solana: linkSolana drives ld.lld with its own flag set (linker script,
	// entry symbol, gc-sections) — none of the cc-driver flags apply.
	if (opts.targetOs == "solana") return appendFlag(base, opts.passL);
	// Emscripten: emcc links to .js + .wasm bundle
	if (opts.targetOs == "emcc") {
		let eflags = appendFlag(base, "-sWASM=1 -sALLOW_MEMORY_GROWTH=1");
		eflags = appendFlag(eflags, opts.passL);
		return eflags;
	}
	// WASM: zig cc links with -target wasm32-wasi, strip dead sections + debug info
	if (opts.targetOs == "wasm") {
		let wflags = appendFlag(base, "-target wasm32-wasi");
		wflags = appendFlag(wflags, "-Wl,--gc-sections -Wl,--strip-all");
		wflags = appendFlag(wflags, opts.passL);
		return wflags;
	}
	let flags = base;
	flags = appendFlag(flags, opts.passL);
	if (opts.strip) flags = appendFlag(flags, "-s");
	if (!forceExe && (opts.isHcr || opts.appMode == "lib")) {
		flags = appendFlag(flags, "-shared");
	}
	if (opts.targetOs == "linux") {
		flags = appendFlag(flags, "-Wl,--gc-sections");
		flags = appendFlag(flags, "-lpthread");
	} else if (opts.targetOs == "windows") {
		flags = appendFlag(flags, "-Wl,--gc-sections");
		flags = appendFlag(flags, "-lws2_32");
		flags = appendFlag(flags, "-lmswsock");
		flags = appendFlag(flags, "-lbcrypt");
	} else if (opts.targetOs == "darwin" || opts.targetOs == "macos") {
		flags = appendFlag(flags, "-Wl,-dead_strip");
	}
	return flags;
}

// Build all flags for single-file compile+link (cmdRun).
export function cliAllFlags(opts: CliOptions): string {
	return cliLinkFlags(cliCompileFlags(opts), opts);
}

// -- Build command construction --

struct ToolCommand {
	path: string;
	args: string[];
}

function compilerCommand(ccOption: number, ccBinary: string, isCpp: boolean): ToolCommand {
	const base = getCompilerName(ccOption, ccBinary);
	if (ccBinary != "") {
		return { path: isCpp ? toCppCompiler(base) : base, args: [] };
	}
	if (isZigCC(base)) {
		return {
			path: base.slice(0, base.length - 3),
			args: [isCpp ? "c++" : "cc"],
		};
	}
	return { path: isCpp ? toCppCompiler(base) : base, args: [] };
}


function appendParsedFlags(command: string, args: string[], flags: string): Result<void, ProcessError> {
	const parsed = splitCcFlags(flags);
	if (!parsed.ok) {
		return Result.err(processError(ProcessErrorKind.Unknown, command, parsed.error));
	}
	for (const arg of parsed.value) args.push(arg);
	return Result.ok(null);
}

function runCc(command: ToolCommand, args: string[]): Result<string, ProcessError> {
	return execFileCapture(command.path, args);
}

// Compile a .c file to a native binary.
// Returns Result.ok on exit-code 0; Result.err carries gcc/clang stderr.
export function compileC(cFile: string, outBinary: string, extraFlags: string, mode: number, ccOption: number, ccBinary: string): Result<void, ProcessError> {
	ensureDir(dirname(outBinary));
	const isCpp = isCppFile(cFile);
	if (isCpp) _hasCppCompile = true;
	const command = compilerCommand(ccOption, ccBinary, isCpp);
	const args = command.args;
	args.push(isCpp ? "-std=c++17" : "-std=gnu11");
	const modeArgs = appendParsedFlags(command.path, args, modeFlags(mode));
	if (!modeArgs.ok) return Result.err(modeArgs.error);
	const rtDir = resolveRuntime();
	if (rtDir != "") args.push(`-iquote${dirname(dirname(rtDir))}`);
	args.push(cFile);
	args.push("-o");
	args.push(outBinary);
	args.push("-lm");
	const flags = appendParsedFlags(command.path, args, extraFlags);
	if (!flags.ok) return Result.err(flags.error);
	const r = runCc(command, args);
	if (!r.ok) return Result.err(r.error);
	return Result.ok(null);
}

// Compile a .c file to an object file only (-c flag, no linking).
// Returns Result.ok on exit-code 0; Result.err carries gcc/clang stderr.
export function compileCFile(cFile: string, oFile: string, dependencyFile: string, extraFlags: string, mode: number, ccOption: number, ccBinary: string): Result<void, ProcessError> {
	ensureDir(dirname(oFile));
	const isCpp = isCppFile(cFile);
	const command = compilerCommand(ccOption, ccBinary, isCpp);
	const args = command.args;
	args.push(isCpp ? "-std=c++17" : "-std=gnu11");
	const modeArgs = appendParsedFlags(command.path, args, modeFlags(mode));
	if (!modeArgs.ok) return Result.err(modeArgs.error);
	const rtDir = resolveRuntime();
	if (rtDir != "") args.push(`-iquote${dirname(dirname(rtDir))}`);
	const tmp = `${oFile}.tmp.${performance.now()}`;
	let depTmp = "";
	if (dependencyFile != "") {
		ensureDir(dirname(dependencyFile));
		depTmp = `${dependencyFile}.tmp.${performance.now()}`;
		args.push("-MMD");
		args.push("-MF");
		args.push(depTmp);
		args.push("-MT");
		args.push("native");
	}
	args.push("-c");
	args.push(cFile);
	args.push("-o");
	args.push(tmp);
	const flags = appendParsedFlags(command.path, args, extraFlags);
	if (!flags.ok) return Result.err(flags.error);
	const r = runCc(command, args);
	if (!r.ok) {
		remove(tmp);
		if (depTmp != "") remove(depTmp);
		if (env.get("MSC_DEBUG_CC") != "") {
			console.log(`[cc-fail] kind=${r.error.kind} exit=${r.error.exitCode} msg=${r.error.message}`);
			console.log(`[cc-fail] ${command.path} ${args.join(" ")}`);
		}
		return Result.err(r.error);
	}
	if (!renameReplace(tmp, oFile)) {
		remove(tmp);
		if (depTmp != "") remove(depTmp);
		if (exists(oFile)) return Result.ok(null);
		return Result.err(processError(
			ProcessErrorKind.Unknown,
			command.path,
			`failed to publish object ${oFile} (target locked by a concurrent reader?)`
		));
	}
	if (depTmp != "" && !renameReplace(depTmp, dependencyFile)) {
		remove(depTmp);
		return Result.err(processError(ProcessErrorKind.Unknown, command.path, `failed to publish dependencies ${dependencyFile}`));
	}
	return Result.ok(null);
}

const LINK_CMD_LIMIT = 30000;

function commandLength(command: ToolCommand, args: string[]): int32 {
	let length = command.path.length;
	for (const arg of args) length = length + arg.length + 1;
	return length;
}

function responseFileBody(args: string[]): string {
	let body = "";
	for (const arg of args) body = body + quoteCcArg(arg) + "\n";
	return body;
}

export function linkObjects(oFiles: string[], outBinary: string, extraFlags: string, mode: number, ccOption: number, ccBinary: string): Result<void, ProcessError> {
	ensureDir(dirname(outBinary));
	const command = compilerCommand(ccOption, ccBinary, _hasCppCompile);
	const prefix = command.args;
	const rtDir = resolveRuntime();
	if (rtDir != "") prefix.push(`-iquote${dirname(dirname(rtDir))}`);
	const bulk: string[] = [];
	for (const oFile of oFiles) bulk.push(oFile);
	const flags = appendParsedFlags(command.path, bulk, extraFlags);
	if (!flags.ok) return Result.err(flags.error);
	const direct: string[] = [];
	for (const arg of prefix) direct.push(arg);
	for (const arg of bulk) direct.push(arg);
	direct.push("-o");
	direct.push(outBinary);
	direct.push("-lm");

	let r: Result<string, ProcessError>;
	if (commandLength(command, direct) <= LINK_CMD_LIMIT) {
		r = runCc(command, direct);
	} else {
		const rspPath = `${outBinary}_link.rsp`;
		atomicWriteFile(rspPath, responseFileBody(bulk));
		const responseArgs: string[] = [];
		for (const arg of prefix) responseArgs.push(arg);
		responseArgs.push(`@${rspPath}`);
		responseArgs.push("-o");
		responseArgs.push(outBinary);
		responseArgs.push("-lm");
		r = runCc(command, responseArgs);
	}
	if (!r.ok) return Result.err(r.error);
	return Result.ok(null);
}

export function archiveStatic(oFiles: string[], outArchive: string): Result<void, ProcessError> {
	ensureDir(dirname(outArchive));
	if (exists(outArchive)) remove(outArchive);
	const args = ["rcs", outArchive];
	for (const oFile of oFiles) args.push(oFile);
	const r = execFileCapture("ar", args);
	if (!r.ok) return Result.err(r.error);
	return Result.ok(null);
}

// Get the runtime directory path (for -I include path).
export function getRuntimeDir(): string {
	return resolveRuntime();
}

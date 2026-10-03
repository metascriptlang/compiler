// MetaScript Compiler CLI — C compiler wrapper
//
// Invokes clang to compile generated C source into native binaries.

import {
	exec,
	env,
	cmdExists,
	findOnPath,
	platform,
	exit,
	execFileCapture,
	execFileResult,
	nonZeroExit,
	pipeError,
	processError,
	signalTerminated,
	spawnFailed,
	ProcessError,
	ProcessErrorKind,
} from "std/process";
import { writeFile, ensureDir, exists, readDir, remove } from "std/fs";
import { join, dirname, basename } from "std/fs/path";
import { writeStderr } from "std/io";
import { CliOptions, MODE_DANGER, buildCpu } from "./options";
import { renameReplace, atomicWriteFile, stopBuild } from "./io";
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

export function isCppFile(path: string): boolean {
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
	const cpu = normalizeCpu(buildCpu(targetOs, cpuTarget));
	if (targetOs == "bare" && cpu == "wasm32") {
		return useZig ? "-target wasm32-freestanding" : "--target=wasm32-unknown-unknown";
	}
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
		2 => " -O3 -w -DNDEBUG -ffp-contract=off",
		1 => " -O2 -w -DNDEBUG -ffp-contract=off",
		_ => " -O0 -g -ffp-contract=off",
	};
}

test "every build mode keeps a*b+c as two roundings" {
	for (const mode of [0, 1, 2]) assert modeFlags(mode).indexOf("-ffp-contract=off") >= 0;
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
		stopBuild();
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
	if (opts.targetOs == "bare" && opts.cpuTarget == "wasm32") {
		const useZig = isZigCC(getCompilerName(opts.ccCompiler, opts.ccBinary));
		flags = appendFlag(flags, crossTargetFlag(opts.targetOs, opts.cpuTarget, useZig));
		flags = appendFlag(flags, "-ffreestanding -fno-builtin -DMS_FREESTANDING_LIBC");
		flags = appendFlag(flags, "-fdata-sections -ffunction-sections");
		const rtDir = resolveRuntimeDir();
		if (rtDir != "") {
			flags = appendFlag(flags, "-isystem");
			flags = appendFlag(flags, quoteCcArg(`${rtDir}/runtime/freestanding/wasm`));
		}
		return appendFlag(flags, opts.passC);
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
	if (opts.targetOs == "bare" && opts.cpuTarget == "wasm32") {
		let flags = appendFlag(base, "-nostdlib -Wl,--gc-sections");
		if (!forceExe && (opts.appMode == "lib" || opts.appMode == "staticlib")) {
			flags = appendFlag(flags, "-Wl,--no-entry");
		}
		if (opts.strip) flags = appendFlag(flags, "-Wl,--strip-all");
		return appendFlag(flags, opts.passL);
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

export struct ToolCommand {
	path: string;
	args: string[];
}

export function compilerInvocation(ccOption: number, ccBinary: string): Result<ToolCommand, ProcessError> {
	const base = getCompilerName(ccOption, ccBinary);
	if (ccBinary == "") {
		if (isZigCC(base)) return Result.ok({ path: base.slice(0, base.length - 3), args: ["cc"] });
		return Result.ok({ path: base, args: [] });
	}
	const words = splitCcFlags(ccBinary);
	if (!words.ok) return Result.err(processError(ProcessErrorKind.Unknown, ccBinary, `--cc: ${words.error}`));
	if (words.value.length == 0) return Result.err(processError(ProcessErrorKind.Unknown, ccBinary, "--cc names no compiler"));
	const args: string[] = [];
	for (let i = 1; i < words.value.length; i++) args.push(words.value[i]);
	return Result.ok({ path: words.value[0], args });
}

function compilerCommand(ccOption: number, ccBinary: string, isCpp: boolean): Result<ToolCommand, ProcessError> {
	const r = compilerInvocation(ccOption, ccBinary);
	if (!r.ok || !isCpp) return r;
	const command = r.value;
	if (command.args.length > 0 && command.args[0] == "cc") {
		command.args[0] = "c++";
		return Result.ok(command);
	}
	return Result.ok({ path: toCppCompiler(command.path), args: command.args });
}


function appendParsedFlags(command: string, args: string[], flags: string): Result<void, ProcessError> {
	const parsed = splitCcFlags(flags);
	if (!parsed.ok) {
		return Result.err(processError(ProcessErrorKind.Unknown, command, parsed.error));
	}
	for (const arg of parsed.value) args.push(arg);
	return Result.ok(null);
}

// Solana platform-tools LLVM prints a frame over 4,096 bytes as "Error: ..." on stderr and
// exits 0; the program then overwrites the next frame at run time.
function reportsSbfError(errorOutput: string): boolean {
	for (const line of errorOutput.split("\n")) {
		if (line.startsWith("Error: ")) return true;
	}
	return false;
}

function runCc(command: ToolCommand, args: string[]): Result<string, ProcessError> {
	if (!args.includes(SBF_TARGET)) return execFileCapture(command.path, args);
	const run = execFileResult(command.path, args);
	if (!run.started) return Result.err(spawnFailed(command.path, "fork/exec failed"));
	if (!run.pipeOk) {
		return Result.err(pipeError(command.path, "failed to drain stdout/stderr from child"));
	}
	if (run.signal != 0) {
		return Result.err(signalTerminated(command.path, run.signal, run.output, run.errorOutput));
	}
	if (run.exitCode != 0) {
		return Result.err(nonZeroExit(command.path, run.exitCode, run.output, run.errorOutput));
	}
	if (reportsSbfError(run.errorOutput)) {
		return Result.err(nonZeroExit(command.path, 1, run.output, run.errorOutput));
	}
	return Result.ok(run.output);
}

// zig cc's own cache pass costs more than clang/lld on a small input: its `-###` plan run
// directly gives the same output faster (WSL 2026-10-03: compile 64→40 ms, link 39→10 ms).
export struct CcPlan {
	exe: string;
	args: string[];
	input: string;
	output: string;
	outputStem: string;
	deps: string;
}

export const NO_PLAN: CcPlan = { exe: "", args: [], input: "", output: "", outputStem: "", deps: "" };

const PLAN_TAG = "msc-plan-";
let _planDir = "";
const _plans = new HashMap<string, CcPlan>();
let _plansOn = false;

export function driverPlansOn(): boolean {
	return _plansOn;
}

export function useDriverPlans(on: boolean): void {
	_plansOn = on;
}

function planDir(): string {
	if (_planDir != "") return _planDir;
	const temp = env.get("TEMP") != "" ? env.get("TEMP") : env.get("TMPDIR") != "" ? env.get("TMPDIR") : "/tmp";
	_planDir = join(temp, "msc-plan");
	ensureDir(_planDir);
	return _planDir;
}

function isZigDriver(command: ToolCommand): boolean {
	const name = basename(command.path).toLowerCase();
	return (name == "zig" || name == "zig.exe") && command.args.length > 0 && (command.args[0] == "cc" || command.args[0] == "c++");
}

function withoutExtension(path: string): string {
	const slash = Math.max(path.lastIndexOf("/"), path.lastIndexOf("\\"));
	const dot = path.lastIndexOf(".");
	return dot > slash ? path.substring(0, dot) : path;
}

function planTokens(line: string): string[] {
	const tokens: string[] = [];
	const n = line.length;
	let i = 0;
	while (i < n) {
		while (i < n && (line.charCodeAt(i) == 32 || line.charCodeAt(i) == 9 || line.charCodeAt(i) == 13)) i += 1;
		if (i >= n) break;
		if (line.charCodeAt(i) != 34) {
			const start = i;
			while (i < n && line.charCodeAt(i) != 32 && line.charCodeAt(i) != 9 && line.charCodeAt(i) != 13) i += 1;
			tokens.push(line.substring(start, i));
			continue;
		}
		i += 1;
		const pieces: string[] = [];
		let start = i;
		while (i < n && line.charCodeAt(i) != 34) {
			if (line.charCodeAt(i) == 92 && i + 1 < n) {
				pieces.push(line.substring(start, i));
				start = i + 1;
				i += 2;
				continue;
			}
			i += 1;
		}
		pieces.push(line.substring(start, i));
		tokens.push(pieces.join(""));
		i += 1;
	}
	return tokens;
}

function adoptDriverObject(tokens: string[], input: string, output: string): void {
	const stem = withoutExtension(basename(input));
	for (let k = 0; k < tokens.length; k += 1) {
		const token = tokens[k];
		if (token == output || token.indexOf(stem, 0) < 0) continue;
		if (token.startsWith("-object-file-name=")) tokens[k] = `-object-file-name=${output}`;
		else if (token.endsWith(`${stem}.obj`) || token.endsWith(`${stem}.o`)) tokens[k] = output;
	}
}

function capturePlan(command: ToolCommand, argv: string[], isLink: boolean, input: string, output: string, outputStem: string, deps: string): CcPlan {
	const r = execFileResult(command.path, argv);
	if (!r.started || r.signal != 0) return NO_PLAN;
	const lines: string[] = [];
	for (const raw of `${r.errorOutput}\n${r.output}`.split("\n")) {
		const line = raw.trim();
		const isPlanLine = isLink
			? line.startsWith("ld.lld ") || line.startsWith("lld-link ")
			: line.indexOf("\"-cc1\"", 0) >= 0;
		if (isPlanLine) lines.push(line);
	}
	if (lines.length != 1) return NO_PLAN;
	const tokens = planTokens(lines[0]);
	if (tokens.length < 2) return NO_PLAN;
	if (!isLink) adoptDriverObject(tokens, input, output);
	let inputs = 0;
	let outputs = 0;
	let depFiles = 0;
	for (const token of tokens) {
		if (token.indexOf(PLAN_TAG, 0) < 0) continue;
		if (token == input) inputs += 1;
		else if (token == output) outputs += 1;
		else if (!isLink && token == `-object-file-name=${output}`) continue;
		else if (deps != "" && token == deps) depFiles += 1;
		else if (!isLink && token == basename(input)) continue;
		else if (outputStem != "" && token.indexOf(basename(outputStem), 0) >= 0) continue;
		else return NO_PLAN;
	}
	if (inputs != 1 || (!isLink && outputs != 1) || depFiles != (deps != "" ? 1 : 0)) return NO_PLAN;
	const args: string[] = [];
	for (let k = isLink ? 0 : 1; k < tokens.length; k += 1) args.push(tokens[k]);
	return { exe: isLink ? command.path : tokens[0], args, input, output, outputStem, deps };
}

function planArgs(plan: Readonly<CcPlan>, inputs: string[], output: string, deps: string): string[] {
	const args: string[] = [];
	const realStem = withoutExtension(output);
	for (const token of plan.args) {
		if (token == plan.input) {
			for (const input of inputs) args.push(input);
		} else if (token == plan.output) {
			args.push(output);
		} else if (plan.outputStem == "" && token == `-object-file-name=${plan.output}`) {
			args.push(`-object-file-name=${output}`);
		} else if (plan.deps != "" && token == plan.deps) {
			args.push(deps);
		} else if (plan.outputStem == "" && token == basename(plan.input)) {
			args.push(basename(inputs[0]));
		} else if (plan.outputStem != "" && token.indexOf(basename(plan.outputStem), 0) >= 0) {
			args.push(token.replaceAll(plan.outputStem, realStem).replaceAll(basename(plan.outputStem), basename(realStem)));
		} else {
			args.push(token);
		}
	}
	return args;
}

export function compilePlanFor(cFile: string, hasDeps: boolean, extraFlags: string, mode: number, ccOption: number, ccBinary: string): CcPlan {
	const isCpp = isCppFile(cFile);
	const parts = objectCompileArgs(ccOption, ccBinary, isCpp, mode, extraFlags);
	if (!_plansOn || !parts.ok || !isZigDriver(parts.value.command)) return NO_PLAN;
	const dir = planDir();
	const input = join(dir, `${PLAN_TAG}input${isCpp ? ".cpp" : ".c"}`);
	const output = join(dir, `${PLAN_TAG}output.o`);
	const deps = hasDeps ? join(dir, `${PLAN_TAG}deps.d`) : "";
	const argv = objectCompileArgv(parts.value, input, output, deps);
	const key = `${parts.value.command.path}\n${argv.join("\n")}`;
	const known = _plans.get(key);
	if (known != null) return known;
	if (!exists(input)) writeFile(input, "");
	argv.push("-###");
	const plan = capturePlan(parts.value.command, argv, false, input, output, "", deps);
	_plans.set(key, plan);
	return plan;
}

function linkPlanFor(command: ToolCommand, prefix: string[], flagArgs: string[], outBinary: string): CcPlan {
	if (!_plansOn || !isZigDriver(command)) return NO_PLAN;
	const dir = planDir();
	const input = join(dir, `${PLAN_TAG}input.o`);
	const stem = join(dir, `${PLAN_TAG}output`);
	const output = `${stem}${outBinary.substring(withoutExtension(outBinary).length, outBinary.length)}`;
	const argv: string[] = [];
	for (const arg of prefix) argv.push(arg);
	argv.push(input);
	for (const arg of flagArgs) argv.push(arg);
	argv.push("-o");
	argv.push(output);
	const key = `${command.path}\n${argv.join("\n")}`;
	const known = _plans.get(key);
	if (known != null) return known;
	if (!exists(input)) writeFile(input, "");
	argv.push("-###");
	const plan = capturePlan(command, argv, true, input, output, stem, "");
	_plans.set(key, plan);
	return plan;
}

export function includePrefix(source: string): string {
	let end = 0;
	while (source.indexOf("#include", end) == end) {
		const next = source.indexOf("\n", end);
		if (next < 0) return source.substring(0, source.length);
		end = next + 1;
	}
	return source.substring(0, end);
}

export function buildPch(header: string, pch: string, extraFlags: string, mode: number, ccOption: number, ccBinary: string): boolean {
	const parts = objectCompileArgs(ccOption, ccBinary, false, mode, extraFlags);
	if (!parts.ok || !isZigDriver(parts.value.command)) return false;
	const args: string[] = [];
	for (const arg of parts.value.lead) args.push(arg);
	const rtDir = resolveRuntime();
	if (rtDir != "") args.push(`-iquote${dirname(dirname(rtDir))}`);
	const tmp = `${pch}.tmp.${performance.now()}`;
	args.push("-Xclang");
	args.push("-fno-pch-timestamp");
	args.push("-x");
	args.push("c-header");
	args.push(header);
	args.push("-o");
	args.push(tmp);
	for (const arg of parts.value.trail) args.push(arg);
	if (!runCc(parts.value.command, args).ok) {
		remove(tmp);
		return false;
	}
	if (renameReplace(tmp, pch)) return true;
	remove(tmp);
	return false;
}

export struct ObjectCompileArgs {
	command: ToolCommand;
	lead: string[];
	trail: string[];
}

export function objectCompileArgs(ccOption: number, ccBinary: string, isCpp: boolean, mode: number, extraFlags: string): Result<ObjectCompileArgs, ProcessError> {
	const resolved = compilerCommand(ccOption, ccBinary, isCpp);
	if (!resolved.ok) return Result.err(resolved.error);
	const command = resolved.value;
	const lead: string[] = [];
	for (const arg of command.args) lead.push(arg);
	lead.push(isCpp ? "-std=c++17" : "-std=gnu11");
	const modeArgs = appendParsedFlags(command.path, lead, modeFlags(mode));
	if (!modeArgs.ok) return Result.err(modeArgs.error);
	const trail: string[] = [];
	const flags = appendParsedFlags(command.path, trail, extraFlags);
	if (!flags.ok) return Result.err(flags.error);
	return Result.ok({ command, lead, trail });
}

export function objectCompileKey(ccOption: number, ccBinary: string, isCpp: boolean, mode: number, extraFlags: string): string {
	const parts = objectCompileArgs(ccOption, ccBinary, isCpp, mode, extraFlags);
	if (!parts.ok) return `unresolved ${parts.error.message} ${extraFlags}`;
	return `${quoteCcArg(parts.value.command.path)} ${objectArgsText(parts.value)}`;
}

export function objectCompileArgsKey(ccOption: number, ccBinary: string, isCpp: boolean, mode: number, extraFlags: string): string {
	const parts = objectCompileArgs(ccOption, ccBinary, isCpp, mode, extraFlags);
	if (!parts.ok) return `unresolved ${parts.error.message} ${extraFlags}`;
	return `${withoutIncludeDirs(parts.value.lead).join(" ")} | ${withoutIncludeDirs(parts.value.trail).join(" ")}`;
}

function includeDirKind(arg: string): string {
	for (const kind of ["-iquote", "-isystem", "-idirafter", "-I"]) {
		if (arg.startsWith(kind)) return kind;
	}
	return "";
}

function withoutIncludeDirs(args: string[]): string[] {
	const kept: string[] = [];
	for (let i = 0; i < args.length; i++) {
		const kind = includeDirKind(args[i]);
		if (kind == "") {
			kept.push(quoteCcArg(args[i]));
		} else if (args[i] == kind) {
			i = i + 1;
		}
	}
	return kept;
}

function objectArgsText(parts: ObjectCompileArgs): string {
	let text = "";
	for (const arg of parts.lead) text = `${text}${quoteCcArg(arg)} `;
	text = `${text}|`;
	for (const arg of parts.trail) text = `${text} ${quoteCcArg(arg)}`;
	return text;
}

function runtimeQuoteDir(): string {
	const rtDir = resolveRuntime();
	return rtDir != "" ? dirname(dirname(rtDir)) : "";
}

export function objectSearchDirs(ccOption: number, ccBinary: string, isCpp: boolean, mode: number, extraFlags: string): string[] {
	const parts = objectCompileArgs(ccOption, ccBinary, isCpp, mode, extraFlags);
	const quote: string[] = [];
	const angle: string[] = [];
	const system: string[] = [];
	if (!parts.ok) return quote;
	const args: string[] = [];
	for (const arg of parts.value.lead) args.push(arg);
	if (runtimeQuoteDir() != "") args.push(`-iquote${runtimeQuoteDir()}`);
	for (const arg of parts.value.trail) args.push(arg);
	for (let i = 0; i < args.length; i++) {
		const kind = includeDirKind(args[i]);
		if (kind == "") continue;
		let dir = args[i].slice(kind.length, args[i].length);
		if (dir == "" && i + 1 < args.length) {
			i = i + 1;
			dir = args[i];
		}
		dir = dir.replaceAll("\\", "/");
		while (dir.length > 1 && dir.endsWith("/")) dir = dir.slice(0, dir.length - 1);
		match (kind) {
			"-iquote" => quote.push(dir),
			"-I" => angle.push(dir),
			_ => system.push(dir),
		}
	}
	for (const dir of angle) quote.push(dir);
	for (const dir of system) quote.push(dir);
	return quote;
}

// Compile a .c file to a native binary.
// Returns Result.ok on exit-code 0; Result.err carries gcc/clang stderr.
export function compileC(cFile: string, outBinary: string, extraFlags: string, mode: number, ccOption: number, ccBinary: string): Result<void, ProcessError> {
	ensureDir(dirname(outBinary));
	const isCpp = isCppFile(cFile);
	if (isCpp) _hasCppCompile = true;
	const resolved = compilerCommand(ccOption, ccBinary, isCpp);
	if (!resolved.ok) return Result.err(resolved.error);
	const command = resolved.value;
	const args = command.args;
	args.push(isCpp ? "-std=c++17" : "-std=gnu11");
	const modeArgs = appendParsedFlags(command.path, args, modeFlags(mode));
	if (!modeArgs.ok) return Result.err(modeArgs.error);
	const rtDir = resolveRuntime();
	if (rtDir != "") args.push(`-iquote${dirname(dirname(rtDir))}`);
	args.push(cFile);
	args.push("-o");
	args.push(outBinary);
	const flags = appendParsedFlags(command.path, args, extraFlags);
	if (!flags.ok) return Result.err(flags.error);
	if (!args.includes("-nostdlib") && !args.includes("-nodefaultlibs")) args.push("-lm");
	const r = runCc(command, args);
	if (!r.ok) return Result.err(r.error);
	return Result.ok(null);
}

// Compile a .c file to an object file only (-c flag, no linking).
// Returns Result.ok on exit-code 0; Result.err carries gcc/clang stderr.
function objectCompileArgv(parts: ObjectCompileArgs, cFile: string, oFile: string, depFile: string): string[] {
	const args: string[] = [];
	for (const arg of parts.lead) args.push(arg);
	if (runtimeQuoteDir() != "") args.push(`-iquote${runtimeQuoteDir()}`);
	if (depFile != "") {
		args.push("-MD");
		args.push("-MF");
		args.push(depFile);
		args.push("-MT");
		args.push("native");
	}
	args.push("-c");
	args.push(cFile);
	args.push("-o");
	args.push(oFile);
	for (const arg of parts.trail) args.push(arg);
	return args;
}

export function compileCFile(cFile: string, oFile: string, dependencyFile: string, extraFlags: string, mode: number, ccOption: number, ccBinary: string, plan: Readonly<CcPlan> = NO_PLAN, pch: string = ""): Result<void, ProcessError> {
	ensureDir(dirname(oFile));
	const parts = objectCompileArgs(ccOption, ccBinary, isCppFile(cFile), mode, extraFlags);
	if (!parts.ok) return Result.err(parts.error);
	const command = parts.value.command;
	const tmp = `${oFile}.tmp.${performance.now()}`;
	let depTmp = "";
	if (dependencyFile != "") {
		ensureDir(dirname(dependencyFile));
		depTmp = `${dependencyFile}.tmp.${performance.now()}`;
	}
	const args = objectCompileArgv(parts.value, cFile, tmp, depTmp);
	let r: Result<string, ProcessError> = Result.err(processError(ProcessErrorKind.Unknown, command.path, "not run"));
	let planned = false;
	if (plan.exe != "") {
		const direct = planArgs(plan, [cFile], tmp, depTmp);
		if (pch != "") {
			const withPch: string[] = [direct[0], "-include-pch", pch];
			for (let k = 1; k < direct.length; k += 1) withPch.push(direct[k]);
			r = runCc({ path: plan.exe, args: [] }, withPch);
			planned = r.ok;
		}
		if (!planned) {
			r = runCc({ path: plan.exe, args: [] }, direct);
			planned = r.ok;
		}
	}
	if (!planned) r = runCc(command, args);
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
	const resolved = compilerCommand(ccOption, ccBinary, _hasCppCompile);
	if (!resolved.ok) return Result.err(resolved.error);
	const command = resolved.value;
	const prefix = command.args;
	const rtDir = resolveRuntime();
	if (rtDir != "") prefix.push(`-iquote${dirname(dirname(rtDir))}`);
	const flagArgs: string[] = [];
	const flags = appendParsedFlags(command.path, flagArgs, extraFlags);
	if (!flags.ok) return Result.err(flags.error);
	if (!flagArgs.includes("-nostdlib") && !flagArgs.includes("-nodefaultlibs")) flagArgs.push("-lm");
	const bulk: string[] = [];
	for (const oFile of oFiles) bulk.push(oFile);
	for (const arg of flagArgs) bulk.push(arg);
	const direct: string[] = [];
	for (const arg of prefix) direct.push(arg);
	for (const arg of bulk) direct.push(arg);
	direct.push("-o");
	direct.push(outBinary);

	let r: Result<string, ProcessError>;
	if (commandLength(command, direct) <= LINK_CMD_LIMIT) {
		const plan = linkPlanFor(command, prefix, flagArgs, outBinary);
		if (plan.exe != "" && runCc({ path: plan.exe, args: [] }, planArgs(plan, oFiles, outBinary, "")).ok) return Result.ok(null);
		r = runCc(command, direct);
	} else {
		const rspPath = `${outBinary}_link.rsp`;
		atomicWriteFile(rspPath, responseFileBody(bulk));
		const responseArgs: string[] = [];
		for (const arg of prefix) responseArgs.push(arg);
		responseArgs.push(`@${rspPath}`);
		responseArgs.push("-o");
		responseArgs.push(outBinary);
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

test "a cross build without --cpu targets x86_64, --cpu names the triple's cpu" {
	const other = platform == "linux" ? "windows" : "linux";
	const abi = other == "linux" ? "linux-gnu" : "windows-gnu";
	assert crossTargetFlag(other, "", true) == `-target x86_64-${abi}`;
	assert crossTargetFlag(other, "arm64", true) == `-target aarch64-${abi}`;
}

test "the object cache key names every argument compileCFile passes but the file names" {
	const parts = objectCompileArgs(0, "clang -fno-pie", true, 2, "-DVALUE=\"a b\" -Ivendor");
	assert parts.ok;
	const key = objectCompileKey(0, "clang -fno-pie", true, 2, "-DVALUE=\"a b\" -Ivendor");
	assert key.startsWith(quoteCcArg(parts.value.command.path));
	for (const arg of parts.value.lead) assert key.indexOf(quoteCcArg(arg), 0) >= 0;
	for (const arg of parts.value.trail) assert key.indexOf(quoteCcArg(arg), 0) >= 0;
	assert key.indexOf("-std=c++17", 0) >= 0;
	assert key != objectCompileKey(0, "clang -fno-pie", false, 2, "-DVALUE=\"a b\" -Ivendor");
	assert key != objectCompileKey(0, "clang -fno-pie", true, 2, "-DVALUE=a b -Ivendor");
}

test "a driver plan line splits into quoted, escaped and bare arguments" {
	const quoted = planTokens(" \"/opt/zig/zig\" \"-cc1\" \"-DQ=\\\"x y\\\"\" \"C:\\dir\\a.c\"\r");
	assert quoted.length == 4;
	assert quoted[0] == "/opt/zig/zig";
	assert quoted[2] == "-DQ=\"x y\"";
	assert quoted[3] == "C:\dir\a.c";
	const bare = planTokens("ld.lld --eh-frame-hdr -shared -o /t/msc-plan-output.so /t/msc-plan-input.o -lc");
	assert bare.length == 7;
	assert bare[5] == "/t/msc-plan-input.o";
}

test "a link plan takes every object at the input's place and the output's stem in derived names" {
	const plan: CcPlan = {
		exe: "zig",
		args: ["lld-link", "-OUT:/t/msc-plan-output.dll", "-PDB:/t/msc-plan-output.pdb", "-PDBALTPATH:msc-plan-output.pdb", "/t/msc-plan-input.o", "-lc"],
		input: "/t/msc-plan-input.o",
		output: "/t/msc-plan-output.dll",
		outputStem: "/t/msc-plan-output",
		deps: "",
	};
	const args = planArgs(plan, ["a.o", "b.o"], "out/app.logic.dll", "");
	assert args.join(" ") == "lld-link -OUT:out/app.logic.dll -PDB:out/app.logic.pdb -PDBALTPATH:app.logic.pdb a.o b.o -lc";
}

test "a compile plan renames the input, its main-file name, the object and the dependency file" {
	const plan: CcPlan = {
		exe: "/opt/zig/zig",
		args: ["-cc1", "-main-file-name", "msc-plan-input.c", "-dependency-file", "/t/msc-plan-deps.d", "-o", "/t/msc-plan-output.o", "-x", "c", "/t/msc-plan-input.c"],
		input: "/t/msc-plan-input.c",
		output: "/t/msc-plan-output.o",
		outputStem: "",
		deps: "/t/msc-plan-deps.d",
	};
	const args = planArgs(plan, ["cache/logic.c"], "cache/logic.o.tmp.1", "cache/logic.d.tmp.1");
	assert args.join(" ") == "-cc1 -main-file-name logic.c -dependency-file cache/logic.d.tmp.1 -o cache/logic.o.tmp.1 -x c cache/logic.c";
}

test "a Windows compile plan writes the object zig would have staged in its own temp directory" {
	const tokens = ["-cc1", "-object-file-name=C:/zig/tmp/7a1d-msc-plan-input.obj", "-o", "C:\\zig\\tmp\\7a1d-msc-plan-input.obj", "-x", "c", "C:/t/msc-plan-input.c"];
	adoptDriverObject(tokens, "C:/t/msc-plan-input.c", "C:/t/msc-plan-output.o");
	assert tokens.join(" ") == "-cc1 -object-file-name=C:/t/msc-plan-output.o -o C:/t/msc-plan-output.o -x c C:/t/msc-plan-input.c";
}

test "a precompiled header zig serves from its cache after the header is rewritten still loads" {
	const base = env.get("TEMP") != "" ? env.get("TEMP") : "/tmp";
	const dir = `${base}/msc-pch-${performance.now()}`;
	ensureDir(dir);
	const header = `${dir}/prefix.h`;
	const source = `${dir}/use.c`;
	writeFile(header, "#include <string.h>\n");
	writeFile(source, "int size(void) { return (int)strlen(\"abc\"); }\n");
	assert buildPch(header, `${dir}/first.pch`, "", 0, 0, "");
	const nextSecond = (Math.floor(Date.now() / 1000) + 1) * 1000;
	while (Date.now() < nextSecond) {}
	writeFile(header, "#include <string.h>\n");
	assert buildPch(header, `${dir}/second.pch`, "", 0, 0, "");
	const parts = objectCompileArgs(0, "", false, 0, "");
	assert parts.ok;
	const args = objectCompileArgv(parts.value, source, `${dir}/use.o`, "");
	args.push("-include-pch");
	args.push(`${dir}/second.pch`);
	assert runCc(parts.value.command, args).ok;
	for (const name of ["prefix.h", "use.c", "first.pch", "second.pch", "use.o"]) remove(`${dir}/${name}`);
	remove(dir);
}

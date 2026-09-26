// cparse — Target model and predefined macros

import { env, exec, platform } from "std/process";

// All size/align values in bytes. Covers primitive C types whose sizes vary
// across targets. Types with fixed sizes (int32_t, etc.) aren't in this table.
export interface TargetInfo {
	os: string;
	cpu: string;
	pointerSize: int32;
	pointerAlign: int32;
	shortSize: int32;
	intSize: int32;
	longSize: int32;           // 4 on Windows LLP64 and on 32-bit CPUs, 8 on LP64
	longLongSize: int32;
	floatSize: int32;
	doubleSize: int32;
	longDoubleSize: int32;
	sizeTSigned: boolean;
	charSigned: boolean;        // default signedness of bare `char`
}

function normalizeCpu(cpu: string): string {
	if (cpu == "amd64" || cpu == "x64") return "x86_64";
	if (cpu == "arm64") return "aarch64";
	if (cpu == "386") return "i386";
	return cpu;
}

function cpuPointerSize(cpu: string): int32 {
	return match (cpu) {
		"x86_64" | "aarch64" | "riscv64" | "mips64" | "powerpc64" | "sparc64" | "s390x" | "loongarch64" | "sbf" => 8,
		"i386" | "arm" | "wasm32" | "riscv32" | "mips" | "powerpc" | "sparc" => 4,
		"avr" | "msp430" => 2,
		_ => 0,
	};
}

function isApple(os: string): boolean {
	return os == "macos" || os == "ios";
}

function charIsSigned(os: string, cpu: string): boolean {
	if (isApple(os) || os == "windows") return true;
	return !(cpu == "aarch64" || cpu == "arm" || cpu == "riscv32" || cpu == "riscv64" ||
		cpu == "powerpc" || cpu == "powerpc64" || cpu == "s390x");
}

function longDoubleSize(os: string, cpu: string): int32 {
	if (cpu == "x86_64") return 16;
	if (cpu == "i386") return 12;
	if (cpu == "aarch64") return isApple(os) || os == "windows" ? 8 : 16;
	if (cpu == "riscv64" || cpu == "loongarch64" || cpu == "s390x") return 16;
	return 8;
}

export function targetFor(os: string, cpu: string): TargetInfo {
	const o = os == "darwin" ? "macos" : os;
	const c = normalizeCpu(cpu);
	const ptr = cpuPointerSize(c);
	if (ptr == 0) return null as unknown as TargetInfo;
	return {
		os: o,
		cpu: c,
		pointerSize: ptr, pointerAlign: ptr,
		shortSize: 2,
		intSize: ptr == 2 ? 2 : 4,
		longSize: o == "windows" || ptr < 8 ? 4 : 8,
		longLongSize: 8,
		floatSize: 4, doubleSize: 8, longDoubleSize: longDoubleSize(o, c),
		sizeTSigned: false, charSigned: charIsSigned(o, c),
	};
}

function hostOs(): string {
	return platform == "darwin" ? "macos" : platform;
}

function hostCpu(): string {
	if (platform == "windows") {
		return env.get("PROCESSOR_ARCHITECTURE") == "ARM64" ? "aarch64" : "x86_64";
	}
	const r = exec("uname -m");
	const m = r.ok ? r.value : "";
	if (m.indexOf("arm64") >= 0 || m.indexOf("aarch64") >= 0) return "aarch64";
	return "x86_64";
}

// Keep the no --cpu default equal to src/compiler/cc.ms crossTargetFlag: the host
// CPU for a host build, x86_64 for a cross build.
export function buildTarget(os: string, cpu: string): TargetInfo {
	const o = os == "darwin" ? "macos" : os;
	if (cpu != "") return targetFor(o, cpu);
	if (o == "wasm" || o == "emcc") return targetFor(o, "wasm32");
	if (o == "solana") return targetFor(o, "sbf");
	if (o == hostOs()) return targetFor(o, hostCpu());
	return targetFor(o, "x86_64");
}

export function hostTarget(): TargetInfo {
	return buildTarget(hostOs(), "");
}

// Predefined macro as a (name, value) pair. The preprocessor ingests these
// before reading any source file so #if branches take the correct path.
export interface MacroDef {
	name: string;
	value: string;
}

function m(name: string, value: string): MacroDef {
	return { name, value };
}

export function predefinedMacros(t: TargetInfo): MacroDef[] {
	const result: MacroDef[] = [
		m("__STDC__", "1"),
		m("__STDC_HOSTED__", "1"),
		m("__STDC_VERSION__", "201112L"),
		m("__GNUC__", "4"),
		m("__GNUC_MINOR__", "2"),
	];
	match (t.cpu) {
		"x86_64" => { result.push(m("__x86_64__", "1")); result.push(m("__x86_64", "1")); result.push(m("__amd64__", "1")); result.push(m("__amd64", "1")); },
		"aarch64" => { result.push(m("__aarch64__", "1")); if (isApple(t.os)) result.push(m("__arm64__", "1")); },
		"i386" => { result.push(m("__i386__", "1")); result.push(m("__i386", "1")); },
		"arm" => { result.push(m("__arm__", "1")); },
		"wasm32" => { result.push(m("__wasm__", "1")); result.push(m("__wasm32__", "1")); },
		"riscv32" | "riscv64" => { result.push(m("__riscv", "1")); },
		_ => {},
	};
	if (t.pointerSize == 8 && t.longSize == 8) { result.push(m("__LP64__", "1")); result.push(m("_LP64", "1")); }
	if (!t.charSigned) result.push(m("__CHAR_UNSIGNED__", "1"));
	match (t.os) {
		"linux" => {
			result.push(m("__linux__", "1")); result.push(m("__linux", "1")); result.push(m("__gnu_linux__", "1"));
			result.push(m("__unix__", "1")); result.push(m("__unix", "1"));
		},
		"android" => {
			result.push(m("__linux__", "1")); result.push(m("__linux", "1")); result.push(m("__ANDROID__", "1"));
			result.push(m("__unix__", "1")); result.push(m("__unix", "1"));
		},
		"macos" | "ios" => { result.push(m("__APPLE__", "1")); result.push(m("__MACH__", "1")); },
		"freebsd" => { result.push(m("__FreeBSD__", "14")); result.push(m("__unix__", "1")); result.push(m("__unix", "1")); },
		"windows" => {
			result.push(m("_WIN32", "1")); result.push(m("WIN32", "1")); result.push(m("__WIN32__", "1")); result.push(m("__MINGW32__", "1"));
			if (t.pointerSize == 8) { result.push(m("_WIN64", "1")); result.push(m("WIN64", "1")); result.push(m("__WIN64__", "1")); result.push(m("__MINGW64__", "1")); }
		},
		"emcc" => { result.push(m("__EMSCRIPTEN__", "1")); },
		_ => {},
	};
	return result;
}

function hasMacro(t: TargetInfo, name: string): boolean {
	for (const md of predefinedMacros(t)) {
		if (md.name == name) return true;
	}
	return false;
}

test "host target is populated" {
	const t = hostTarget();
	assert t != null;
	assert t.pointerSize == 8;
	assert t.intSize == 4;
}

test "windows x64 is LLP64 on the MinGW ABI" {
	const t = targetFor("windows", "amd64");
	assert t.longSize == 4;
	assert t.pointerSize == 8;
	assert hasMacro(t, "_WIN32");
	assert hasMacro(t, "_WIN64");
	assert hasMacro(t, "__MINGW64__");
	assert !hasMacro(t, "_MSC_VER");
	assert !hasMacro(t, "__APPLE__");
	assert !hasMacro(t, "__LP64__");
}

test "linux x86_64 is LP64 and takes no apple or windows branch" {
	const t = targetFor("linux", "x86_64");
	assert t.longSize == 8;
	assert hasMacro(t, "__linux__");
	assert hasMacro(t, "__LP64__");
	assert !hasMacro(t, "__APPLE__");
	assert !hasMacro(t, "_WIN32");
}

test "aarch64 char is unsigned on linux and android, signed on apple" {
	assert targetFor("linux", "arm64").charSigned == false;
	assert targetFor("android", "aarch64").charSigned == false;
	assert hasMacro(targetFor("android", "aarch64"), "__ANDROID__");
	assert targetFor("macos", "arm64").charSigned == true;
	assert targetFor("ios", "arm64").charSigned == true;
}

test "darwin is an alias of macos" {
	const t = targetFor("darwin", "aarch64");
	assert t.os == "macos";
	assert hasMacro(t, "__APPLE__");
	assert hasMacro(t, "__arm64__");
	assert t.longDoubleSize == 8;
}

test "wasm and emcc are ILP32, emcc names itself" {
	const w = buildTarget("wasm", "");
	assert w.cpu == "wasm32";
	assert w.pointerSize == 4;
	assert w.longSize == 4;
	assert !hasMacro(w, "__EMSCRIPTEN__");
	assert hasMacro(buildTarget("emcc", ""), "__EMSCRIPTEN__");
}

test "a cross build without --cpu gets x86_64, --cpu wins" {
	const cross = buildTarget(platform == "windows" ? "linux" : "windows", "");
	assert cross.cpu == "x86_64";
	assert buildTarget("linux", "arm64").cpu == "aarch64";
	assert buildTarget("bare", "i386").longDoubleSize == 12;
	assert buildTarget("solana", "").cpu == "sbf";
}

test "a cpu with no model is null" {
	assert targetFor("linux", "vax") == null;
}

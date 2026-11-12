import { join, exists, isDir, isFile, readDir, ensureDir, symlink } from "std/fs";
import { IoError } from "std/io/errors";
import { readUtf8File } from "./textFile";
import { WindowsTarget, windowsClangTriple } from "./windowsConfig";

export const BUILTINS_DISABLED = [
	"SANITIZERS", "CRT", "LIBFUZZER", "PROFILE", "MEMPROF", "XRAY", "ORC",
	"GWP_ASAN", "CTX_PROFILE",
];
export const SANITIZERS_DISABLED = [
	"BUILTINS", "CRT", "LIBFUZZER", "PROFILE", "MEMPROF", "XRAY", "ORC",
	"GWP_ASAN", "CTX_PROFILE",
];
export const WINDOWS_SANITIZERS = ["ubsan_standalone", "ubsan_standalone_cxx"];
function io(result: Result<void, IoError>): Result<void, string> {
	return result.ok ? Result.ok(null) : Result.err(result.error.message);
}

export function decimal(text: string): int32 | null {
	if (text == "" || text.length > 6) { return null; }
	let value: int32 = 0;
	for (let i: int32 = 0; i < text.length; i += 1) {
		const code = text.charCodeAt(i);
		if (code < 48 || code > 57) { return null; }
		value = value * 10 + (code - 48);
	}
	return value;
}

// `#define NAME 13` and `set(NAME 13)` lines: the value of each name, in order.
function definedNumbers(
	text: string, names: string[], prefix: string, suffix: string,
): Result<string, string> {
	const found: string[] = [];
	for (const name of names) {
		for (const raw of text.split("\n")) {
			const line = raw.trim();
			const head = prefix + name + " ";
			if (!line.startsWith(head) || !line.endsWith(suffix)) { continue; }
			const value = line.slice(head.length, line.length - suffix.length).trim();
			if (decimal(value) != null) { found.push(value); break; }
		}
	}
	if (found.length != names.length) {
		return Result.err("names no version " + names.join(", "));
	}
	return Result.ok(found.join("."));
}

export function mingwVersion(source: string): Result<string, string> {
	for (const part of ["mingw-w64-headers", "mingw-w64-crt"]) {
		if (!isFile(join(source, part + "/configure"))) {
			return Result.err(source + " is not an extracted mingw-w64 release: no " +
				part + "/configure");
		}
	}
	const header = join(source, "mingw-w64-headers/crt/_mingw_mac.h");
	const version = definedNumbers(try readUtf8File(header),
		["MAJOR", "MINOR", "BUGFIX"], "#define __MINGW64_VERSION_", "");
	if (!version.ok) { return Result.err(header + " " + version.error); }
	return version;
}

export function llvmSourceVersion(source: string): Result<string, string> {
	const path = join(source, "cmake/Modules/LLVMVersion.cmake");
	if (!isFile(path)) {
		return Result.err(source + " is not an extracted llvm-project tree: no " +
			"cmake/Modules/LLVMVersion.cmake");
	}
	const version = definedNumbers(try readUtf8File(path),
		["MAJOR", "MINOR", "PATCH"], "set(LLVM_VERSION_", ")");
	if (!version.ok) { return Result.err(path + " " + version.error); }
	return version;
}

export function builtWindowsTarget(name: string): Result<WindowsTarget, string> {
	if (name == "aarch64-windows-gnu") {
		return Result.err("aarch64-windows-gnu is deferred until a Windows arm64 " +
			"host consumes it; only x86_64-windows-gnu is built");
	}
	if (name != "x86_64-windows-gnu") {
		return Result.err("unsupported Windows target: " + name);
	}
	return Result.ok(WindowsTarget.X64);
}

export function builtinsDirectory(target: WindowsTarget, major: string): string {
	return "lib/clang/" + major + "/lib/" + windowsClangTriple(target);
}

export function builtinsCmakeArguments(
	target: WindowsTarget, source: string, stage: string, config: string,
	build: string, ninja: string, prefixMaps: string[],
): string[] {
	return compilerRtCmakeArguments(target, source, stage, config, build, ninja, prefixMaps,
		BUILTINS_DISABLED);
}

export function sanitizerCmakeArguments(
	target: WindowsTarget, source: string, stage: string, config: string,
	build: string, ninja: string, prefixMaps: string[],
): string[] {
	return [
		...compilerRtCmakeArguments(target, source, stage, config, build, ninja, prefixMaps,
			SANITIZERS_DISABLED),
		"-DCOMPILER_RT_SANITIZERS_TO_BUILD=ubsan_minimal",
	];
}

export function sanitizerArchives(target: WindowsTarget): string[] {
	return WINDOWS_SANITIZERS.map((name: string): string =>
		"compiler-rt/lib/" + windowsClangTriple(target) + "/libclang_rt." + name + ".a");
}

function compilerRtCmakeArguments(
	target: WindowsTarget, source: string, stage: string, config: string,
	build: string, ninja: string, prefixMaps: string[], disabled: string[],
): string[] {
	const flags = ["--no-default-config", "--config=" + config, "-gcodeview", "-gno-codeview-command-line", "-fdebug-compilation-dir=.", ...prefixMaps].join(" ");
	const triple = windowsClangTriple(target);
	const tool = (name: string): string => join(stage, "bin/" + name);
	const args = [
		"-S", join(source, "runtimes"), "-B", build, "-G", "Ninja",
		"-DCMAKE_MAKE_PROGRAM=" + ninja, "-DCMAKE_BUILD_TYPE=Release",
		"-DCMAKE_SYSTEM_NAME=Windows",
		"-DCMAKE_SYSTEM_PROCESSOR=" + (target == WindowsTarget.X64 ? "AMD64" : "ARM64"),
		"-DCMAKE_C_COMPILER=" + tool("clang"), "-DCMAKE_CXX_COMPILER=" + tool("clang++"),
		"-DCMAKE_ASM_COMPILER=" + tool("clang"),
		"-DCMAKE_C_FLAGS=" + flags, "-DCMAKE_CXX_FLAGS=" + flags,
		"-DCMAKE_ASM_FLAGS=" + flags,
		"-DCMAKE_AR=" + tool("llvm-ar"), "-DCMAKE_RANLIB=" + tool("llvm-ranlib"),
		"-DCMAKE_NM=" + tool("llvm-nm"),
		"-DCMAKE_C_COMPILER_WORKS=ON", "-DCMAKE_CXX_COMPILER_WORKS=ON",
		"-DCMAKE_ASM_COMPILER_WORKS=ON", "-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY",
		"-DLLVM_ENABLE_RUNTIMES=compiler-rt", "-DLLVM_DEFAULT_TARGET_TRIPLE=" + triple,
		"-DLLVM_RUNTIME_TARGETS=", "-DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON",
		"-DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON",
		"-DCMAKE_C_COMPILER_TARGET=" + triple, "-DCMAKE_CXX_COMPILER_TARGET=" + triple,
		"-DCMAKE_ASM_COMPILER_TARGET=" + triple,
		"-DCOMPILER_RT_INCLUDE_TESTS=OFF", "-DLLVM_INCLUDE_TESTS=OFF",
	];
	for (const name of disabled) {
		args.push("-DCOMPILER_RT_BUILD_" + name + "=OFF");
	}
	return args;
}

// Make stage reach every engine entry through a symlink, with the directories of `relative` real so files can be
// added there without writing into the engine. The engine must not have `relative` itself.
export function linkEngineAround(
	engine: string, stage: string, relative: string,
): Result<string, string> {
	if (exists(join(engine, relative))) {
		return Result.err("engine " + engine + " already has " + relative);
	}
	let here = stage;
	let there = engine;
	for (const part of relative.split("/")) {
		try io(ensureDir(here));
		if (isDir(there)) {
			for (const entry of readDir(there)) {
				const name = entry.endsWith("/") ? entry.slice(0, entry.length - 1) : entry;
				if (name != part) {
					try io(symlink(join(there, name), join(here, name)));
				}
			}
		}
		here = join(here, part);
		there = join(there, part);
	}
	try io(ensureDir(here));
	return Result.ok(here);
}


import { join, ensureDir, writeFile, removeAll, isFile } from "std/fs";
import { argv, cwd } from "std/process";
import { resolve } from "std/fs/path";
import { WindowsTarget } from "./windowsConfig";
import {
	mingwVersion, llvmSourceVersion, builtWindowsTarget, builtinsDirectory,
	builtinsCmakeArguments, linkEngineAround,
} from "./windowsRuntimePlan";

let checks: int32 = 0;
function check(ok: boolean, label: string): void {
	if (!ok) { throw new Error(label); }
	checks += 1;
}
function must<T>(result: Result<T, string>): T {
	if (!result.ok) { throw new Error(result.error); }
	return result.value;
}
function write(path: string, text: string): void {
	const made = ensureDir(path.slice(0, path.lastIndexOf("/")));
	if (!made.ok) { throw new Error(made.error.message); }
	const done = writeFile(path, text);
	if (!done.ok) { throw new Error(done.error.message); }
}

function main(): void {
	if (argv.length != 2) { throw new Error("usage: windowsRuntimeTest NEW_SCRATCH_DIR"); }
	const root = resolve(argv[1], cwd());

	const mingw = join(root, "mingw");
	check(!mingwVersion(mingw).ok, "a tree without configure is no mingw-w64 release");
	write(join(mingw, "mingw-w64-headers/configure"), "#!/bin/sh\n");
	write(join(mingw, "mingw-w64-crt/configure"), "#!/bin/sh\n");
	write(join(mingw, "mingw-w64-headers/crt/_mingw_mac.h"),
		"#define __MINGW64_VERSION_MAJOR 13\n#define __MINGW64_VERSION_MINOR 0\n" +
		"#define __MINGW64_VERSION_BUGFIX 0\n");
	check(must(mingwVersion(mingw)) == "13.0.0", "mingw-w64 version from _mingw_mac.h");
	write(join(mingw, "mingw-w64-headers/crt/_mingw_mac.h"), "#define __MINGW64_VERSION_MAJOR 13\n");
	check(!mingwVersion(mingw).ok, "a header without the minor and bugfix names no version");

	const llvm = join(root, "llvm");
	check(!llvmSourceVersion(llvm).ok, "a tree without LLVMVersion.cmake is no llvm-project");
	write(join(llvm, "cmake/Modules/LLVMVersion.cmake"),
		"if(NOT DEFINED LLVM_VERSION_MAJOR)\n  set(LLVM_VERSION_MAJOR 23)\nendif()\n" +
		"  set(LLVM_VERSION_MINOR 1)\n  set(LLVM_VERSION_PATCH 4)\n");
	check(must(llvmSourceVersion(llvm)) == "23.1.4", "LLVM version from LLVMVersion.cmake");

	check(must(builtWindowsTarget("x86_64-windows-gnu")) == WindowsTarget.X64, "x86_64 is built");
	const arm = builtWindowsTarget("aarch64-windows-gnu");
	check(!arm.ok && arm.error.indexOf("deferred") >= 0, "arm64 is refused as deferred");
	check(!builtWindowsTarget("x86_64-linux-gnu").ok, "a non-Windows target is refused");
	check(builtinsDirectory(WindowsTarget.X64, "23") == "lib/clang/23/lib/x86_64-w64-windows-gnu",
		"builtins sit where --rtlib=compiler-rt looks for the triple");

	const args = builtinsCmakeArguments(WindowsTarget.X64, "/s", "/stage", "/stage/runtime/windows/x.cfg",
		"/b", "/n");
	check(args.indexOf("-DCMAKE_C_FLAGS=--no-default-config --config=/stage/runtime/windows/x.cfg -gcodeview") >= 0,
		"compiler-rt compiles through the shipped config");
	check(args.indexOf("-DCOMPILER_RT_BUILD_SANITIZERS=OFF") >= 0, "sanitizers are not built");
	check(args.indexOf("-DCOMPILER_RT_BUILD_BUILTINS=OFF") < 0, "builtins are built");
	check(args.indexOf("-DCMAKE_C_COMPILER=/stage/bin/clang") >= 0, "the stage's clang compiles");

	const engine = join(root, "engine");
	write(join(engine, "bin/clang"), "");
	write(join(engine, "lib/clang/23/include/stddef.h"), "");
	write(join(engine, "lib/clang/23/lib/windows/a.lib"), "");
	const stage = join(root, "stage");
	const made = must(linkEngineAround(engine, stage, "lib/clang/23/lib/x86_64-w64-windows-gnu"));
	check(made == join(stage, "lib/clang/23/lib/x86_64-w64-windows-gnu"), "the new directory is returned");
	write(join(made, "libclang_rt.builtins.a"), "!<arch>\n");
	check(isFile(join(stage, "lib/clang/23/include/stddef.h")), "engine headers reached through links");
	check(isFile(join(stage, "lib/clang/23/lib/windows/a.lib")), "engine siblings reached through links");
	check(isFile(join(stage, "bin/clang")), "engine bin reached through a link");
	check(!isFile(join(engine, "lib/clang/23/lib/x86_64-w64-windows-gnu/libclang_rt.builtins.a")),
		"the added file is not written into the engine");
	check(!linkEngineAround(engine, join(root, "stage2"), "lib/clang/23/lib/windows").ok,
		"a directory the engine already has is refused");

	removeAll(root);
	console.log("windows runtime: " + String(checks) + " checks OK");
}

when (!testBuild) { main(); }

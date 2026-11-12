import { cwd, platform } from "std/process";
import { ensureDir, exists, join, removeAll, writeFile } from "std/fs";
import { randomUUIDSync } from "std/crypto";
import {
	TargetRuntimeRequest, compilerFlags, hostNeutral, muslConfigureCommand, muslCxxCommand, prepareTargetRuntime,
	shellWord, targetConfigs, targetRecipe, wasiBuiltinsCommand, wasiLibcCommand,
} from "./targetRuntime";

let cases: int32 = 0;

function expect(condition: boolean, what: string): void {
	cases += 1;
	if (!condition) { throw new Error("failed: " + what); }
}

function expectRefusal<T>(result: Result<T, string>, needle: string, what: string): void {
	cases += 1;
	if (result.ok) { throw new Error("accepted: " + what); }
	if (!result.error.contains(needle)) {
		throw new Error(what + ": " + result.error + " lacks " + needle);
	}
}

function recipeCases(): void {
	const wasi = targetRecipe("wasm32-wasi");
	if (!wasi.ok) { throw new Error(wasi.error); }
	expect(wasi.value.config == "runtime/wasm32-wasi.cfg" &&
		wasi.value.sysroot == "runtime/wasm32-wasip1" &&
		wasi.value.runtimeTriple == "wasm32-unknown-wasip1",
		"the wasi recipe keeps msc's config name and clang's directory names");
	const wasiConfigs = targetConfigs(wasi.value);
	expect(wasiConfigs.length == 1 && wasiConfigs[0].path == "runtime/wasm32-wasi.cfg" &&
		wasiConfigs[0].text == "-target wasm32-wasip1\n--sysroot=<CFGDIR>/wasm32-wasip1\n",
		"the config names the target and a sysroot beside itself");
	expectRefusal(targetRecipe("riscv64-linux-musl"), "the built targets are", "a target without a recipe");
	const musl = targetRecipe("aarch64-linux-musl");
	if (!musl.ok) { throw new Error(musl.error); }
	const configs = targetConfigs(musl.value);
	expect(configs.length == 4 && configs[0].path == "runtime/aarch64-linux-musl.cfg" &&
		configs[0].text == "-target aarch64-unknown-linux-musl\n--sysroot=<CFGDIR>/aarch64-linux-musl\n" +
		"--rtlib=compiler-rt\n--ld-path=<CFGDIR>/../bin/ld.lld\n-static\n" &&
		configs[1].path == "runtime/aarch64-linux-musl.so.cfg" && configs[1].text.endsWith("-shared\n") &&
		!configs[1].text.contains("-static") &&
		configs[2].path == "runtime/aarch64-linux-musl.cxx.cfg" &&
		configs[3].path == "runtime/aarch64-linux-musl.so.cxx.cfg" &&
		configs[2].text == "-stdlib=libc++\n--unwindlib=libunwind\n" && configs[3].text == configs[2].text,
		"a musl target has the executable, shared and C++ configs msc asks for, and only C++ links the unwinder");
	const configure = muslConfigureCommand("/e", "/w/src/musl-1.2.5", "/w", musl.value, "/o/runtime/aarch64-linux-musl", "/w/b.a");
	expect(configure.ok && configure.value.file == "sh" &&
		configure.value.args[1].startsWith("cd '/w/musl' && CC='/e/bin/clang" +
			(platform == "windows" ? ".exe" : "") + " --no-default-config") &&
		configure.value.args[1].contains("--target=aarch64-unknown-linux-musl --sysroot=/o/runtime/aarch64-linux-musl") &&
		configure.value.args[1].contains(" LIBCC='/w/b.a' '/w/src/musl-1.2.5/configure' --prefix=/usr --syslibdir=/lib"),
		"musl is configured out of tree for the target with the engine's tools and the builtins just built");
	expectRefusal(muslConfigureCommand("/e", "/w/src/musl", "/my work", musl.value, "/o/s", ""),
		"which split it", "a work path sh and make would split");
	expectRefusal(shellWord("/it's"), "which split it", "a path with a quote");
	const cxx = muslCxxCommand("cmake", "ninja", "/e", "/w/src/llvm", "/w", musl.value, "/o/runtime/aarch64-linux-musl");
	expect(cxx.args.includes("-DLIBCXXABI_HAS_CXA_THREAD_ATEXIT_IMPL=OFF") &&
		cxx.args.includes("-DLIBCXX_HAS_MUSL_LIBC=ON") &&
		cxx.args.includes("-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY") &&
		cxx.args.includes("-DCMAKE_SYSROOT=/o/runtime/aarch64-linux-musl"),
		"libc++abi is told musl has no __cxa_thread_atexit_impl, which a static try-compile cannot find out");
	const builtins = wasiBuiltinsCommand("cmake", "ninja", "/e", "/w/src/llvm", "/w", wasi.value, "/o/runtime/wasm32-wasip1");
	expect(builtins.file == "cmake" && builtins.args.includes("-S") &&
		builtins.args.includes("/w/src/llvm/compiler-rt") &&
		builtins.args.includes("-DCOMPILER_RT_BAREMETAL_BUILD=ON") &&
		builtins.args.includes("-DCMAKE_C_COMPILER_TARGET=wasm32-wasip1") &&
		builtins.args.includes("-DCOMPILER_RT_BUILD_SANITIZERS=OFF") &&
		builtins.args.includes("-DCMAKE_INSTALL_PREFIX=/w/builtins-install"),
		"the builtins are a bare-metal compiler-rt for the target, installed in the work directory");
	const libc = wasiLibcCommand("cmake", "ninja", "/e", "/w/src/wasi-libc", "/w", wasi.value,
		"/o/runtime/wasm32-wasip1", "/w/b/libclang_rt.builtins.a");
	expect(libc.args.includes("-DTARGET_TRIPLE=wasm32-wasip1") &&
		libc.args.includes("-DBUILTINS_LIB=/w/b/libclang_rt.builtins.a") &&
		libc.args.includes("-DBUILD_SHARED=OFF") &&
		libc.args.includes("-DCMAKE_INSTALL_PREFIX=/o/runtime/wasm32-wasip1"),
		"wasi-libc installs into the sysroot against the builtins just built, so nothing is downloaded");
	for (const command of [builtins, libc]) {
		expect(command.args.includes("-DCMAKE_C_FLAGS=" + compilerFlags("/w")) &&
			compilerFlags("/w") == "--no-default-config -ffile-prefix-map=/w=.",
			"every compile ignores host configs and keeps the work path out of its output");
	}
}

function receiptCases(): void {
	const windows = [["C:\\w\\work", "<work>"], ["C:\\e\\bundle", "<engine>"], ["C:/tools/cmake.exe", "<cmake>"]];
	const posix = [["/w/work", "<work>"], ["/e/bundle", "<engine>"], ["/usr/bin/cmake", "<cmake>"]];
	expect(hostNeutral("-DCMAKE_C_COMPILER=C:/e/bundle/bin/clang.exe", windows) ==
		hostNeutral("-DCMAKE_C_COMPILER=/e/bundle/bin/clang", posix) &&
		hostNeutral("C:/w/work/builtins", windows) == "<work>/builtins" &&
		hostNeutral("C:/tools/cmake.exe", windows) == hostNeutral("/usr/bin/cmake", posix),
		"a receipt records the same command on a Windows and a POSIX host");
}

function refusalCases(dir: string): void {
	const made = ensureDir(dir);
	if (!made.ok) { throw new Error(made.error.message); }
	const file = join(dir, "llvm-project-1.2.3.src.tar.xz");
	if (!writeFile(file, "not a tarball").ok) { throw new Error("write"); }
	const request: TargetRuntimeRequest = {
		engine: dir, target: "wasm32-wasi", llvmTarball: file, llvmSha256: "0".repeat(64),
		sources: dir, cmake: file, ninja: file, work: join(dir, "work"),
		output: join(dir, "overlay"), jobs: 4,
	};
	expectRefusal(prepareTargetRuntime({ ...request, target: "riscv64-linux-gnu" }),
		"no source runtime for riscv64-linux-gnu", "an unknown target");
	expectRefusal(prepareTargetRuntime({ ...request, llvmSha256: "ABC" }),
		"64 lowercase hex digits", "a malformed digest");
	expectRefusal(prepareTargetRuntime({ ...request, jobs: 0 }), "--jobs", "no jobs");
	expectRefusal(prepareTargetRuntime(request), "HOST", "an engine without its contract");
	expect(!exists(join(dir, "work")) && !exists(join(dir, "overlay")),
		"a refused request extracts and publishes nothing");
}

function run(): void {
	recipeCases();
	receiptCases();
	const token = randomUUIDSync();
	if (!token.ok) { throw new Error(token.error.message); }
	const dir = join(join(cwd(), "out"), "targetRuntimeTest-" + token.value);
	refusalCases(dir);
	if (!removeAll(dir).ok) { throw new Error("cannot remove " + dir); }
	console.log("targetRuntime: " + String(cases) + " cases OK");
}

when (!testBuild) { run(); }

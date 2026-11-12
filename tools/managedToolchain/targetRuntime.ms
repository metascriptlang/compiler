import { env, platform } from "std/process";
import { dirname, ensureDir, isDir, isFile, join, readDirNames, remove, removeAll } from "std/fs";
import { jsonValueOf } from "std/serialize/json";
import { stringifyPretty } from "std/serialize/json/stringify";
import { sha256File } from "./fileDigest";
import { containsExistingRoot } from "./nativePath";
import { renameNoReplace } from "./nativePublication";
import { asciiEngineJson, claimPartial } from "./windowsEngine";
import { copyBundleTree } from "./bundleAssembly";
import { captureToolUtf8 } from "./processCapture";
import {
	EngineCommand, existingFile, extractLlvmSource, extractTarball, hostTool, isSha256Hex,
	llvmSourceVersion, pathWithToolDir, refuseExisting, runCommand,
} from "./sourceEngine";
import {
	absoluteEnginePath, copyEngineFile, engineIo, listEngineFiles, verifyEngineContract,
	writeEngineText,
} from "./engineFiles";
import { readUtf8File } from "./textFile";

export const TARGET_RECEIPT_KIND = "local-source-target-runtime";

export struct PinnedSource {
	name: string;
	version: string;
	file: string;
	url: string;
	sha256: string;
	root: string;
	licenses: string[];
}

export struct TargetRecipe {
	target: string;
	config: string;
	sysroot: string;
	clangTarget: string;
	runtimeTriple: string;
	arch: string;
	libc: PinnedSource;
	kernel: PinnedSource | null;
}

export struct TargetRuntimeRequest {
	engine: string;
	target: string;
	llvmTarball: string;
	llvmSha256: string;
	sources: string;
	cmake: string;
	ninja: string;
	work: string;
	output: string;
	jobs: int32;
}

export struct TargetSourceRecord {
	name: string;
	version: string;
	file: string;
	url: string;
	sha256: string;
}

export struct TargetRuntimeReceipt {
	kind: string;
	target: string;
	engineVersion: string;
	statement: string;
	sources: TargetSourceRecord[];
	commands: string[][];
	notices: string[];
	redistributionCertified: boolean;
}

export const WASI_LIBC: PinnedSource = {
	name: "wasi-libc",
	version: "wasi-sdk-34",
	file: "wasi-libc-wasi-sdk-34.tar.gz",
	url: "https://github.com/WebAssembly/wasi-libc/archive/refs/tags/wasi-sdk-34.tar.gz",
	sha256: "21bc47f96cf0eb535e532697dce4cdfdbc91f59223bdc00d8495d191888c5fe8",
	root: "wasi-libc-wasi-sdk-34",
	licenses: ["LICENSE", "LICENSE-APACHE", "LICENSE-APACHE-LLVM", "LICENSE-MIT"],
};

export const MUSL: PinnedSource = {
	name: "musl",
	version: "1.2.5",
	file: "musl-1.2.5.tar.gz",
	url: "https://musl.libc.org/releases/musl-1.2.5.tar.gz",
	sha256: "a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4",
	root: "musl-1.2.5",
	licenses: ["COPYRIGHT"],
};

export const LINUX_HEADERS: PinnedSource = {
	name: "linux",
	version: "6.19",
	file: "linux-6.19.tar.xz",
	url: "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.19.tar.xz",
	sha256: "303079a8250b8f381f82b03f90463d12ac98d4f6b149b761ea75af1323521357",
	root: "linux-6.19",
	licenses: ["COPYING", "LICENSES/preferred/GPL-2.0", "LICENSES/exceptions/Linux-syscall-note"],
};

const SOURCE_TARGETS = "wasm32-wasi, x86_64-linux-musl, aarch64-linux-musl";

export function targetRecipe(target: string): Result<TargetRecipe, string> {
	if (target == "wasm32-wasi") {
		return Result.ok({
			target,
			config: "runtime/wasm32-wasi.cfg",
			sysroot: "runtime/wasm32-wasip1",
			clangTarget: "wasm32-wasip1",
			runtimeTriple: "wasm32-unknown-wasip1",
			arch: "wasm32",
			libc: WASI_LIBC,
			kernel: null,
		});
	}
	if (target == "x86_64-linux-musl" || target == "aarch64-linux-musl") {
		const arch = target.slice(0, target.indexOf("-"));
		return Result.ok({
			target,
			config: "runtime/" + target + ".cfg",
			sysroot: "runtime/" + target,
			clangTarget: arch + "-unknown-linux-musl",
			runtimeTriple: arch + "-unknown-linux-musl",
			arch,
			libc: MUSL,
			kernel: LINUX_HEADERS,
		});
	}
	return Result.err("no source runtime for " + target + ": the built targets are " + SOURCE_TARGETS);
}

export struct TargetConfig {
	path: string;
	text: string;
}

export function targetConfigs(recipe: TargetRecipe): TargetConfig[] {
	const directory = recipe.sysroot.slice(dirname(recipe.config).length + 1);
	const base = "-target " + recipe.clangTarget + "\n--sysroot=<CFGDIR>/" + directory + "\n";
	if (recipe.kernel == null) { return [{ path: recipe.config, text: base }]; }
	const stem = recipe.config.slice(0, recipe.config.length - 4);
	const linux = base + "--rtlib=compiler-rt\n--ld-path=<CFGDIR>/../bin/ld.lld\n";
	const cxx = "-stdlib=libc++\n--unwindlib=libunwind\n";
	return [
		{ path: recipe.config, text: linux + "-static\n" },
		{ path: stem + ".so.cfg", text: linux + "-shared\n" },
		{ path: stem + ".cxx.cfg", text: cxx },
		{ path: stem + ".so.cxx.cfg", text: cxx },
	];
}

function tool(engine: string, name: string): string {
	return join(engine, "bin/" + name + (platform == "windows" ? ".exe" : ""));
}

function crossCmake(
	cmake: string, ninja: string, engine: string, source: string, build: string,
	flags: string,
): string[] {
	return [
		"-G", "Ninja", "-DCMAKE_MAKE_PROGRAM=" + ninja, "-S", source, "-B", build,
		"-DCMAKE_BUILD_TYPE=Release",
		"-DCMAKE_C_COMPILER=" + tool(engine, "clang"),
		"-DCMAKE_CXX_COMPILER=" + tool(engine, "clang++"),
		"-DCMAKE_AR=" + tool(engine, "llvm-ar"),
		"-DCMAKE_RANLIB=" + tool(engine, "llvm-ranlib"),
		"-DCMAKE_NM=" + tool(engine, "llvm-nm"),
		"-DCMAKE_C_COMPILER_WORKS=ON", "-DCMAKE_CXX_COMPILER_WORKS=ON",
		"-DCMAKE_C_FLAGS=" + flags, "-DCMAKE_CXX_FLAGS=" + flags, "-DCMAKE_ASM_FLAGS=" + flags,
	];
}

const WASI_SYSTEM: string[] = [
	"-DCMAKE_SYSTEM_NAME=WASI", "-DCMAKE_SYSTEM_VERSION=1", "-DCMAKE_SYSTEM_PROCESSOR=wasm32",
	"-DCMAKE_C_LINKER_DEPFILE_SUPPORTED=OFF", "-DCMAKE_CXX_LINKER_DEPFILE_SUPPORTED=OFF",
];

export function compilerFlags(work: string): string {
	return "--no-default-config -ffile-prefix-map=" + work + "=.";
}

export function wasiBuiltinsCommand(
	cmake: string, ninja: string, engine: string, llvm: string, work: string,
	recipe: TargetRecipe, sysroot: string,
): EngineCommand {
	const args = crossCmake(cmake, ninja, engine, join(llvm, "compiler-rt"),
		join(work, "builtins"), compilerFlags(work));
	for (const name of WASI_SYSTEM) { args.push(name); }
	for (const name of [
		"SANITIZERS", "XRAY", "LIBFUZZER", "PROFILE", "CTX_PROFILE", "MEMPROF", "ORC", "GWP_ASAN",
	]) {
		args.push("-DCOMPILER_RT_BUILD_" + name + "=OFF");
	}
	return {
		file: cmake,
		args: [
			...args,
			"-DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON", "-DCOMPILER_RT_BAREMETAL_BUILD=ON",
			"-DCOMPILER_RT_INCLUDE_TESTS=OFF", "-DCOMPILER_RT_HAS_FPIC_FLAG=OFF",
			"-DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON",
			"-DCMAKE_C_COMPILER_TARGET=" + recipe.clangTarget,
			"-DCMAKE_INSTALL_PREFIX=" + join(work, "builtins-install"),
			"-DCMAKE_SYSROOT=" + sysroot,
		],
	};
}

export function wasiLibcCommand(
	cmake: string, ninja: string, engine: string, libc: string, work: string,
	recipe: TargetRecipe, sysroot: string, builtins: string,
): EngineCommand {
	const args = crossCmake(cmake, ninja, engine, libc, join(work, "libc"), compilerFlags(work));
	for (const name of WASI_SYSTEM) { args.push(name); }
	return {
		file: cmake,
		args: [
			...args,
			"-DTARGET_TRIPLE=" + recipe.clangTarget, "-DBUILD_SHARED=OFF", "-DBUILD_TESTS=OFF",
			"-DUSE_WASM_COMPONENT_LD=OFF", "-DBUILTINS_LIB=" + builtins,
			"-DCMAKE_INSTALL_PREFIX=" + sysroot, "-DCMAKE_SYSROOT=" + sysroot,
		],
	};
}

function ninjaInstall(ninja: string, build: string, jobs: int32): EngineCommand {
	return { file: ninja, args: ["-C", build, "-j" + String(jobs), "install"] };
}

function extractPinned(pinned: PinnedSource, sources: string, work: string): Result<string, string> {
	const tarball = try existingFile("the " + pinned.name + " source", join(sources, pinned.file));
	const actual = try sha256File(tarball);
	if (actual != pinned.sha256) {
		return Result.err(tarball + ": sha256 " + actual + ", expected " + pinned.sha256);
	}
	const extracted = join(work, "src");
	try extractTarball(tarball, extracted);
	const root = join(extracted, pinned.root);
	if (!isDir(root)) { return Result.err(tarball + " did not extract to " + root); }
	return Result.ok(root);
}

export const EMPTY_ARCHIVE = "!<arch>\n";

function writeEmptyArchivesAlike(engine: string, directory: string): Result<void, string> {
	const names = readDirNames(directory);
	if (!names.ok) { return Result.err(names.error.message); }
	for (const name of names.value) {
		const path = join(directory, name);
		if (!name.endsWith(".a") || !isFile(path)) { continue; }
		const listed = try captureToolUtf8(tool(engine, "llvm-ar"), ["t", path]);
		if (listed.returnCode != 0) {
			return Result.err("llvm-ar cannot list " + path + ": " + listed.errorOutput);
		}
		if (listed.output.trim() == "") { try writeEngineText(path, EMPTY_ARCHIVE); }
	}
	return Result.ok(null);
}

function writeHeadersWithUnixNewlines(include: string): Result<void, string> {
	for (const header of try listEngineFiles(include)) {
		const text = try readUtf8File(join(include, header));
		if (text.indexOf("\r\n") >= 0) {
			try writeEngineText(join(include, header), text.replaceAll("\r\n", "\n"));
		}
	}
	return Result.ok(null);
}

function buildWasi(
	request: TargetRuntimeRequest, recipe: TargetRecipe, engine: string, llvm: string,
	libc: string, work: string, stage: string, receipt: TargetRuntimeReceipt,
): Result<void, string> {
	const sysroot = join(stage, recipe.sysroot);
	try engineIo(ensureDir(sysroot));
	const builtins = join(work, "builtins-install/lib/" + recipe.runtimeTriple +
		"/libclang_rt.builtins.a");
	const steps: EngineCommand[] = [
		wasiBuiltinsCommand(request.cmake, request.ninja, engine, llvm, work, recipe, sysroot),
		ninjaInstall(request.ninja, join(work, "builtins"), request.jobs),
		wasiLibcCommand(request.cmake, request.ninja, engine, libc, work, recipe, sysroot, builtins),
		ninjaInstall(request.ninja, join(work, "libc"), request.jobs),
	];
	for (const step of steps) {
		try runCommand(step);
		receipt.commands.push([step.file, ...step.args]);
	}
	if (!isFile(builtins)) { return Result.err("the compiler-rt build installed no " + builtins); }
	try writeEmptyArchivesAlike(engine, join(sysroot, "lib/" + recipe.clangTarget));
	try writeHeadersWithUnixNewlines(join(sysroot, "include"));
	return copyEngineFile(builtins, join(stage, "lib/clang/" +
		receipt.engineVersion.split(".")[0] + "/lib/" + recipe.runtimeTriple +
		"/libclang_rt.builtins.a"));
}

const LINUX_RUNTIME_OFF: string[] = [
	"LIBFUZZER", "PROFILE", "MEMPROF", "XRAY", "ORC", "GWP_ASAN", "CTX_PROFILE",
];
const MUSL_SANITIZERS: string[] = ["ubsan_standalone", "ubsan_standalone_cxx", "ubsan_minimal"];
// Each has a lower-case twin in its directory; a host whose file system folds case keeps one file of the two.
const CASE_TWIN_LINUX_HEADERS: string[] = [
	"linux/netfilter/xt_CONNMARK.h", "linux/netfilter/xt_DSCP.h", "linux/netfilter/xt_MARK.h",
	"linux/netfilter/xt_RATEEST.h", "linux/netfilter/xt_TCPMSS.h",
	"linux/netfilter_ipv4/ipt_ECN.h", "linux/netfilter_ipv4/ipt_TTL.h",
	"linux/netfilter_ipv6/ip6t_HL.h",
];
const CXX_COMPONENTS: string[] = ["libunwind", "libcxxabi", "libcxx"];

function linuxCmake(
	cmake: string, ninja: string, engine: string, llvm: string, build: string,
	recipe: TargetRecipe, sysroot: string, flags: string, cxxFlags: string,
): string[] {
	const args = crossCmake(cmake, ninja, engine, join(llvm, "runtimes"), build, flags);
	return [
		...args,
		"-DCMAKE_CXX_FLAGS=" + cxxFlags,
		"-DCMAKE_SYSTEM_NAME=Linux", "-DCMAKE_SYSTEM_PROCESSOR=" + recipe.arch,
		"-DCMAKE_SYSROOT=" + sysroot,
		"-DCMAKE_ASM_COMPILER=" + tool(engine, "clang"), "-DCMAKE_ASM_COMPILER_WORKS=ON",
		"-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY",
		"-DCMAKE_C_COMPILER_TARGET=" + recipe.clangTarget,
		"-DCMAKE_CXX_COMPILER_TARGET=" + recipe.clangTarget,
		"-DCMAKE_ASM_COMPILER_TARGET=" + recipe.clangTarget,
		"-DLLVM_DEFAULT_TARGET_TRIPLE=" + recipe.clangTarget,
		"-DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON", "-DLLVM_INCLUDE_TESTS=OFF",
	];
}

export function linuxBuiltinsCommand(
	cmake: string, ninja: string, engine: string, llvm: string, work: string,
	recipe: TargetRecipe, sysroot: string,
): EngineCommand {
	const flags = compilerFlags(work);
	const args = linuxCmake(cmake, ninja, engine, llvm, join(work, "builtins"), recipe, sysroot,
		flags, flags);
	for (const name of LINUX_RUNTIME_OFF) { args.push("-DCOMPILER_RT_BUILD_" + name + "=OFF"); }
	return {
		file: cmake,
		args: [
			...args,
			"-DLLVM_ENABLE_RUNTIMES=compiler-rt", "-DLLVM_RUNTIME_TARGETS=",
			"-DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON", "-DCOMPILER_RT_INCLUDE_TESTS=OFF",
			"-DCOMPILER_RT_BUILD_SANITIZERS=OFF", "-DCOMPILER_RT_BUILD_CRT=ON",
		],
	};
}

export function muslCxxCommand(
	cmake: string, ninja: string, engine: string, llvm: string, work: string,
	recipe: TargetRecipe, sysroot: string,
): EngineCommand {
	const flags = compilerFlags(work) + " --rtlib=compiler-rt";
	return {
		file: cmake,
		args: [
			...linuxCmake(cmake, ninja, engine, llvm, join(work, "cxx"), recipe, sysroot, flags, flags),
			"-DCMAKE_INSTALL_PREFIX=" + join(work, "cxx-install"),
			"-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
			"-DLLVM_ENABLE_RUNTIMES=libunwind;libcxxabi;libcxx",
			"-DLIBUNWIND_USE_COMPILER_RT=ON", "-DLIBUNWIND_ENABLE_SHARED=OFF",
			"-DLIBUNWIND_ENABLE_STATIC=ON",
			"-DLIBCXXABI_USE_COMPILER_RT=ON", "-DLIBCXXABI_USE_LLVM_UNWINDER=ON",
			"-DLIBCXXABI_ENABLE_SHARED=OFF", "-DLIBCXXABI_HAS_CXA_THREAD_ATEXIT_IMPL=OFF",
			"-DLIBCXX_USE_COMPILER_RT=ON", "-DLIBCXX_ENABLE_SHARED=OFF", "-DLIBCXX_ENABLE_STATIC=ON",
			"-DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=ON", "-DLIBCXX_CXX_ABI=libcxxabi",
			"-DLIBCXX_HAS_MUSL_LIBC=ON", "-DLIBCXX_INCLUDE_TESTS=OFF",
			"-DLIBCXX_INCLUDE_BENCHMARKS=OFF",
		],
	};
}

export function muslSanitizerCommand(
	cmake: string, ninja: string, engine: string, llvm: string, work: string,
	recipe: TargetRecipe, sysroot: string,
): EngineCommand {
	const flags = compilerFlags(work) + " --rtlib=compiler-rt";
	const headers = join(work, "cxx-install/include");
	const cxxFlags = flags + " -isystem " + join(headers, recipe.runtimeTriple + "/c++/v1") +
		" -isystem " + join(headers, "c++/v1");
	const args = linuxCmake(cmake, ninja, engine, llvm, join(work, "sanitizers"), recipe, sysroot,
		flags, cxxFlags);
	for (const name of ["BUILTINS", "CRT", ...LINUX_RUNTIME_OFF]) {
		args.push("-DCOMPILER_RT_BUILD_" + name + "=OFF");
	}
	return {
		file: cmake,
		args: [
			...args,
			"-DLLVM_ENABLE_RUNTIMES=compiler-rt", "-DLLVM_RUNTIME_TARGETS=",
			"-DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON", "-DCOMPILER_RT_INCLUDE_TESTS=OFF",
			"-DCOMPILER_RT_SANITIZERS_TO_BUILD=ubsan_minimal",
		],
	};
}

export function shellWord(text: string): Result<string, string> {
	if (text.indexOf("'") >= 0 || text.indexOf(" ") >= 0 || text.indexOf("\n") >= 0) {
		return Result.err("the musl build passes this path through sh and make, which split it: " + text);
	}
	return Result.ok("'" + text + "'");
}

export function muslConfigureCommand(
	engine: string, musl: string, work: string, recipe: TargetRecipe, sysroot: string,
	builtins: string,
): Result<EngineCommand, string> {
	for (const path of [engine, musl, work, sysroot]) { try shellWord(path); }
	const cc = tool(engine, "clang") + " " + compilerFlags(work) + " --target=" +
		recipe.clangTarget + " --sysroot=" + sysroot + " --rtlib=compiler-rt --ld-path=" +
		tool(engine, "ld.lld");
	let script = "cd " + (try shellWord(join(work, "musl"))) + " && CC='" + cc + "' AR=" +
		(try shellWord(tool(engine, "llvm-ar"))) + " RANLIB=" +
		(try shellWord(tool(engine, "llvm-ranlib")));
	if (builtins != "") { script += " LIBCC=" + (try shellWord(builtins)); }
	script += " " + (try shellWord(join(musl, "configure"))) +
		" --prefix=/usr --syslibdir=/lib --target=" + recipe.clangTarget;
	return Result.ok({ file: "sh", args: ["-c", script] });
}

function ninjaBuild(ninja: string, build: string, jobs: int32, targets: string[]): EngineCommand {
	return { file: ninja, args: ["-C", build, "-j" + String(jobs), ...targets] };
}

function copyNamed(from: string, to: string, names: string[]): Result<void, string> {
	for (const name of names) {
		if (!isFile(join(from, name))) { return Result.err("the build made no " + join(from, name)); }
		try copyEngineFile(join(from, name), join(to, name));
	}
	return Result.ok(null);
}

function buildMusl(
	request: TargetRuntimeRequest, recipe: TargetRecipe, engine: string, llvm: string,
	musl: string, linux: string, work: string, stage: string, receipt: TargetRuntimeReceipt,
): Result<void, string> {
	if (platform == "windows") {
		return Result.err(recipe.target + " is built on a POSIX host: musl and the Linux headers " +
			"build with make and sh; its overlay then goes into every host's bundle");
	}
	const make = try hostTool("make");
	const sysroot = join(stage, recipe.sysroot);
	const muslBuild = join(work, "musl");
	const resource = "lib/clang/" + receipt.engineVersion.split(".")[0] + "/lib/" + recipe.runtimeTriple;
	const builtRuntime = join(work, "builtins/compiler-rt/lib/" + recipe.runtimeTriple);
	const builtins = join(builtRuntime, "libclang_rt.builtins.a");
	const jobs = "-j" + String(request.jobs);
	try engineIo(ensureDir(sysroot));
	try engineIo(ensureDir(muslBuild));
	const arch = recipe.arch == "x86_64" ? "x86" : "arm64";
	const run = (step: EngineCommand): Result<void, string> => {
		try runCommand(step);
		receipt.commands.push([step.file, ...step.args]);
		return Result.ok(null);
	};
	try run({ file: make, args: [
		"-s", "-C", linux, "O=" + join(work, "linux"), "ARCH=" + arch,
		"INSTALL_HDR_PATH=" + join(sysroot, "usr"), "headers_install",
	] });
	for (const header of CASE_TWIN_LINUX_HEADERS) {
		try engineIo(remove(join(sysroot, "usr/include/" + header)));
	}
	try run(try muslConfigureCommand(engine, musl, work, recipe, sysroot, ""));
	try run({ file: make, args: ["-s", "-C", muslBuild, "install-headers", "DESTDIR=" + sysroot] });
	try run(linuxBuiltinsCommand(request.cmake, request.ninja, engine, llvm, work, recipe, sysroot));
	try run(ninjaBuild(request.ninja, join(work, "builtins"), request.jobs, []));
	try run(try muslConfigureCommand(engine, musl, work, recipe, sysroot, builtins));
	try run({ file: make, args: ["-s", "-C", muslBuild, jobs] });
	try run({ file: make, args: ["-s", "-C", muslBuild, "install", "DESTDIR=" + sysroot] });
	try engineIo(removeAll(join(sysroot, "lib")));
	try run(muslCxxCommand(request.cmake, request.ninja, engine, llvm, work, recipe, sysroot));
	try run(ninjaBuild(request.ninja, join(work, "cxx"), request.jobs, ["install"]));
	try run(muslSanitizerCommand(request.cmake, request.ninja, engine, llvm, work, recipe, sysroot));
	const sanitizerTargets: string[] = [];
	const sanitizerFiles: string[] = [];
	for (const name of MUSL_SANITIZERS) {
		sanitizerTargets.push("clang_rt." + name + "-" + recipe.arch);
		sanitizerTargets.push("clang_rt." + name + "-" + recipe.arch + "-symbols");
		sanitizerFiles.push("libclang_rt." + name + ".a");
		sanitizerFiles.push("libclang_rt." + name + ".a.syms");
	}
	try run(ninjaBuild(request.ninja, join(work, "sanitizers"), request.jobs, sanitizerTargets));
	try copyNamed(builtRuntime, join(stage, resource),
		["libclang_rt.builtins.a", "clang_rt.crtbegin.o", "clang_rt.crtend.o"]);
	try copyNamed(join(work, "sanitizers/compiler-rt/lib/" + recipe.runtimeTriple),
		join(stage, resource), sanitizerFiles);
	const installed = join(work, "cxx-install");
	try copyNamed(join(installed, "lib/" + recipe.runtimeTriple),
		join(stage, "lib/" + recipe.runtimeTriple), ["libc++.a", "libc++abi.a", "libunwind.a"]);
	try engineIo(ensureDir(join(stage, "include/c++")));
	try copyBundleTree(join(installed, "include"), join(stage, "include"), "c++", []);
	try engineIo(ensureDir(join(stage, "include/" + recipe.runtimeTriple)));
	return copyBundleTree(join(installed, "include"), join(stage, "include"), recipe.runtimeTriple, []);
}

export function hostNeutral(token: string, places: string[][]): string {
	let text = token.replaceAll("\\", "/");
	for (const place of places) { text = text.replaceAll(place[0].replaceAll("\\", "/"), place[1]); }
	const tools = text.indexOf("<engine>/bin/");
	return tools >= 0 && text.endsWith(".exe") ? text.slice(0, text.length - 4) : text;
}

function addNotices(
	stage: string, root: string, component: string, licenses: string[], target: string,
	receipt: TargetRuntimeReceipt,
): Result<void, string> {
	for (const license of licenses) {
		const copy = "runtime/notices/" + target + "/" + component + "/" + license;
		try copyEngineFile(join(root, license), join(stage, copy));
		receipt.notices.push(copy);
	}
	return Result.ok(null);
}

function stageTarget(
	request: TargetRuntimeRequest, recipe: TargetRecipe, engine: string, version: string,
	llvmTarball: string, work: string, stage: string,
): Result<void, string> {
	const llvm = try extractLlvmSource(llvmTarball, version, work);
	const libc = try extractPinned(recipe.libc, request.sources, work);
	const receipt: TargetRuntimeReceipt = {
		kind: TARGET_RECEIPT_KIND,
		target: recipe.target,
		engineVersion: version,
		statement: "The runtime of " + recipe.target +
			" built from the named upstream sources by the engine's own clang; no Zig. " +
			"Not an upstream-published build.",
		sources: [
			{ name: "llvm-project", version, file: llvmTarball.slice(dirname(llvmTarball).length + 1),
				url: "", sha256: request.llvmSha256 },
			{ name: recipe.libc.name, version: recipe.libc.version, file: recipe.libc.file,
				url: recipe.libc.url, sha256: recipe.libc.sha256 },
		],
		commands: [],
		notices: [],
		redistributionCertified: false,
	};
	const kernel = recipe.kernel;
	if (kernel == null) {
		try buildWasi(request, recipe, engine, llvm, libc, work, stage, receipt);
	} else {
		const linux = try extractPinned(kernel, request.sources, work);
		receipt.sources.push({ name: kernel.name, version: kernel.version, file: kernel.file,
			url: kernel.url, sha256: kernel.sha256 });
		try buildMusl(request, recipe, engine, llvm, libc, linux, work, stage, receipt);
		try addNotices(stage, linux, kernel.name, kernel.licenses, recipe.target, receipt);
		for (const component of CXX_COMPONENTS) {
			try addNotices(stage, join(llvm, component), component, ["LICENSE.TXT"], recipe.target, receipt);
		}
	}
	for (const config of targetConfigs(recipe)) {
		try writeEngineText(join(stage, config.path), config.text);
	}
	try addNotices(stage, libc, recipe.libc.name, recipe.libc.licenses, recipe.target, receipt);
	try addNotices(stage, join(llvm, "compiler-rt"), "compiler-rt", ["LICENSE.TXT"], recipe.target, receipt);
	const places: string[][] = [
		[stage, "<overlay>"], [work, "<work>"], [engine, "<engine>"],
		[request.cmake, "<cmake>"], [request.ninja, "<ninja>"],
	];
	for (const command of receipt.commands) {
		for (let i: int32 = 0; i < command.length; i += 1) {
			command[i] = hostNeutral(command[i], places);
		}
		if (command[0].endsWith("/make")) { command[0] = "<make>"; }
	}
	return writeEngineText(join(stage, "runtime/notices/" + recipe.target + "/provenance.json"),
		asciiEngineJson(stringifyPretty(jsonValueOf(receipt), 2)) + "\n");
}

export function prepareTargetRuntime(request: TargetRuntimeRequest): Result<string, string> {
	const recipe = try targetRecipe(request.target);
	const engine = try absoluteEnginePath(request.engine);
	const llvmTarball = try existingFile("--llvm-tarball", request.llvmTarball);
	try existingFile("--cmake", request.cmake);
	try existingFile("--ninja", request.ninja);
	const work = try absoluteEnginePath(request.work);
	const output = try absoluteEnginePath(request.output);
	const version = try llvmSourceVersion(llvmTarball);
	if (!isSha256Hex(request.llvmSha256)) {
		return Result.err("--llvm-sha256 must be 64 lowercase hex digits");
	}
	if (request.jobs < 1) { return Result.err("--jobs must be at least 1"); }
	const contract = try verifyEngineContract(engine);
	if (contract.version != version) {
		return Result.err(engine + " is LLVM " + contract.version + ", the source is " + version);
	}
	try refuseExisting(output);
	const inside = containsExistingRoot(engine, dirname(output));
	if (!inside.ok) { return Result.err(inside.error.message); }
	if (inside.value) { return Result.err("output must not be inside " + engine); }
	const actual = try sha256File(llvmTarball);
	if (actual != request.llvmSha256) {
		return Result.err(llvmTarball + ": sha256 " + actual + ", expected " + request.llvmSha256);
	}
	env.set("PATH", pathWithToolDir(request.ninja, env.get("PATH") ?? "", platform));
	for (const stale of [
		"builtins", "builtins-install", "libc", "linux", "musl", "cxx", "cxx-install", "sanitizers",
	]) {
		try engineIo(removeAll(join(work, stale)));
	}
	const partial = try claimPartial(output);
	const staged = stageTarget(request, recipe, engine, version, llvmTarball, work, partial);
	if (!staged.ok) {
		const cleaned = removeAll(partial);
		return Result.err(staged.error + (cleaned.ok ? "" :
			"; partial cleanup failed: " + cleaned.error.message));
	}
	const published = renameNoReplace(partial, output);
	if (!published.ok) {
		const cleaned = removeAll(partial);
		return Result.err(published.error.message + (cleaned.ok ? "" :
			"; partial cleanup failed: " + cleaned.error.message));
	}
	return Result.ok(output);
}

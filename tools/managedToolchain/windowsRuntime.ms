import {
	basename, dirname, join, isDir, isFile, isLinkLike, readDirNames,
	ensureDir, removeAll, copyFile, chmod, readFileBytes,
} from "std/fs";
import { platform, env } from "std/process";
import { IoErrorKind } from "std/io/errors";
import { jsonValueOf } from "std/serialize/json";
import { stringifyPretty } from "std/serialize/json/stringify";
import { sha256File } from "./fileDigest";
import { readUtf8File } from "./textFile";
import { captureToolUtf8 } from "./processCapture";
import { parsePe, PeInfo } from "./peImage";
import { renameNoReplace } from "./nativePublication";
import {
	absoluteEnginePath, engineIo, writeEngineText, verifyEngineContract,
} from "./engineFiles";
import { claimPartial, asciiEngineJson } from "./windowsEngine";
import {
	BUILTINS_DISABLED, WINDOWS_SANITIZERS, decimal, mingwVersion, llvmSourceVersion,
	builtinsDirectory, builtinsCmakeArguments, linkEngineAround, sanitizerArchives,
	sanitizerCmakeArguments,
} from "./windowsRuntimePlan";
import {
	WindowsTarget, WindowsVariant, windowsTargetName, windowsClangTriple,
	windowsAutoconfHost, windowsVariantDirectory, renderWindowsSourceConfig,
} from "./windowsConfig";
import {
	CxxRecord, cxxCmakeArguments, cxxConfigureArguments, cxxLayout, installCxxRuntime,
} from "./cxxRuntime";

export const WINDOWS_RUNTIME_KIND = "local-source-windows-runtime";
export const WINDOWS_RUNTIME_RECEIPT = "runtime/windows/notices/windows-provenance.json";
const ENGINE_RELATIVE = "../..";
const COMPILER_RT_LICENSE = "notices/compiler-rt/LICENSE.TXT";
const MACHINE_X64: uint16 = 0x8664;
const DLL_CHARACTERISTIC: uint16 = 0x2000;
const SUBSYSTEM_CONSOLE: uint16 = 3;
const HEADER_OPTIONS = ["--with-default-msvcrt=ucrt", "--with-default-win32-winnt=0x0a00"];
const CRT_OPTIONS = [
	"--with-default-msvcrt=ucrt", "--enable-lib64", "--disable-lib32",
	"--disable-libarm32", "--disable-libarm64",
];
// [source in the mingw-w64 tree, name under notices/mingw-w64]
const MINGW_NOTICES: string[][] = [
	["COPYING", "COPYING"], ["COPYING.MinGW-w64/COPYING.MinGW-w64.txt", "COPYING.MinGW-w64.txt"],
	["COPYING.MinGW-w64-runtime/COPYING.MinGW-w64-runtime.txt", "COPYING.MinGW-w64-runtime.txt"],
	["DISCLAIMER", "DISCLAIMER"], ["DISCLAIMER.PD", "DISCLAIMER.PD"],
	["mingw-w64-libraries/winpthreads/COPYING", "COPYING.winpthreads"],
];
const WINPTHREADS_OPTIONS = ["--disable-shared", "--enable-static"];
// The files the clang MinGW driver names on a link, besides the caller's.
const DRIVER_FILES = [
	"crt2.o", "dllcrt2.o", "crtbegin.o", "crtend.o", "libmingw32.a",
	"libmingwex.a", "libmoldname.a", "libmsvcrt.a", "libkernel32.a",
	"libadvapi32.a", "libshell32.a", "libuser32.a", "libpthread.a", "libwinpthread.a",
	"libssp.a", "libssp_nonshared.a",
];
// clang's MinGW driver links these two for a protected frame. mingw-w64 keeps the guard and its failure routine
// in libmingwex, so both are empty archives, as a clang-based mingw-w64 toolchain installs them.
const SSP_ARCHIVES = ["libssp.a", "libssp_nonshared.a"];
const DRIVER_ARCHIVES = ["libmingw32.a", "libmingwex.a", "libmoldname.a", "libmsvcrt.a"];
// Symbols the zig runtime defined in its own archives; an archive the driver links must define each.
const MOVED_SYMBOLS = [
	"mempcpy", "strtok_r", "sinl", "expl", "sqrtl", "frexpl", "strnlen", "nanl",
	"___chkstk_ms", "__udivti3", "__floattidf", "__divxc3",
];
const USER_LIBRARIES = ["-lws2_32", "-lbcrypt", "-lmswsock"];
const MINGW_LIBRARIES = [
	"-lgdi32", "-ld3d11", "-ldxgi", "-ldwmapi", "-lole32", "-lshlwapi",
	"-luuid", "-ldxguid", "-lsynchronization",
];
const LIMITS = [
	"the producer links and inspects; executing the runtime is the bundle's proof on a Windows host",
	"the archives are a local build of the release sources with the engine's clang, not upstream binaries; two runs on one host gave identical bytes, other hosts are not compared",
	"aarch64-windows-gnu is not built: no Windows arm64 host consumes it",
	"of the sanitizers only the standalone UBSan is built: compiler-rt has no mingw ASan or TSan",
	"libc++, libc++abi and libunwind are static archives only",
];

export struct WindowsRuntimeInputs {
	engine: string;
	mingwSource: string;
	mingwSha256: string;
	llvmSource: string;
	llvmSha256: string;
	cmake: string;
	ninja: string;
	output: string;
	jobs: int32;
}

struct SourceReceipt {
	archiveSha256: string;
	options: string[];
	version: string;
}

struct BuiltFile {
	bytes: int64;
	name: string;
	sha256: string;
}

struct VariantReceipt {
	config: string;
	directory: string;
	files: BuiltFile[];
	variant: string;
}

struct ToolReceipt {
	cmake: string;
	ninja: string;
}

export struct WindowsRuntimeReceipt {
	builtins: string;
	builtinsSha256: string;
	compilerRtLicenseSha256: string;
	cxx: CxxRecord;
	engineRelative: string;
	engineVersion: string;
	kind: string;
	limits: string[];
	llvm: SourceReceipt;
	mingw: SourceReceipt;
	notices: string[];
	producerHost: string;
	redistributionCertified: boolean;
	sanitizers: string[];
	statement: string;
	targets: string[];
	tools: ToolReceipt;
	variants: VariantReceipt[];
}

function failureText(text: string): string {
	const errors = text.split("\n").filter((line: string): boolean => line.indexOf("error") >= 0).slice(0, 15);
	const end = text.length > 1500 ? text.slice(text.length - 1500, text.length) : text;
	return (errors.length > 0 ? errors.join("\n") + "\n...\n" : "") + end;
}

function runStep(
	file: string, args: string[], cwd: string, environment: Record<string, string>,
): Result<string, string> {
	const done = captureToolUtf8(file, args, { cwd, env: environment, mergeStderr: true });
	if (!done.ok) { return Result.err(basename(file) + ": " + done.error); }
	if (done.value.returnCode != 0) {
		return Result.err(basename(file) + " " + args.slice(0, 2).join(" ") +
			" failed (" + String(done.value.returnCode) + ") in " + cwd + ":\n" +
			failureText(done.value.output));
	}
	return Result.ok(done.value.output);
}

function toolEnvironment(work: string, tools: string[]): Record<string, string> {
	const path: string[] = [];
	for (const tool of tools) {
		if (path.indexOf(dirname(tool)) < 0) { path.push(dirname(tool)); }
	}
	path.push("/usr/bin");
	path.push("/bin");
	return { PATH: path.join(":"), HOME: "/nonexistent", TMPDIR: work, LC_ALL: "C" };
}

function definedSymbols(nm: string, archive: string): Result<string[], string> {
	const done = captureToolUtf8(nm, ["--defined-only", "--extern-only",
		"--format=just-symbols", archive]);
	if (!done.ok) { return Result.err(done.error); }
	if (done.value.returnCode != 0) {
		return Result.err("llvm-nm " + archive + ": " + done.value.errorOutput);
	}
	const symbols: string[] = [];
	for (const line of done.value.output.split("\n")) {
		if (line != "" && !line.endsWith(":")) { symbols.push(line); }
	}
	return Result.ok(symbols);
}

// A DWARF section in an archive every sanitized program links hides that program's PDB from debuggers.
function refuseDwarf(readobj: string, archive: string): Result<void, string> {
	const done = captureToolUtf8(readobj, ["--sections", archive]);
	if (!done.ok) { return Result.err(done.error); }
	if (done.value.returnCode != 0) {
		return Result.err("llvm-readobj " + archive + ": " + done.value.errorOutput);
	}
	if (done.value.output.contains(".debug_info")) {
		return Result.err(basename(archive) + " carries DWARF");
	}
	return Result.ok(null);
}

export function checkMovedSymbols(
	nm: string, libraries: string, builtins: string,
): Result<void, string> {
	const archives = new Map<string, string[]>();
	for (const name of DRIVER_ARCHIVES) {
		archives.set(name, try definedSymbols(nm, join(libraries, name)));
	}
	archives.set("libclang_rt.builtins.a", try definedSymbols(nm, builtins));
	const missing: string[] = [];
	for (const symbol of MOVED_SYMBOLS) {
		let found = false;
		for (const name of archives) {
			if ((archives.get(name) ?? []).indexOf(symbol) >= 0) { found = true; }
		}
		if (!found) { missing.push(symbol); }
	}
	if (missing.length > 0) {
		return Result.err("no archive the driver links defines " + missing.join(", "));
	}
	const owners: string[] = [];
	for (const name of archives) {
		if ((archives.get(name) ?? []).indexOf("memset") >= 0) { owners.push(name); }
	}
	if (owners.length != 1 || owners[0] != "libmsvcrt.a") {
		return Result.err("memset is defined by [" + owners.join(", ") +
			"], not the UCRT import library alone");
	}
	return Result.ok(null);
}

function copyRegularFiles(source: string, target: string): Result<BuiltFile[], string> {
	try engineIo(ensureDir(target));
	const names = readDirNames(source);
	if (!names.ok) { return Result.err(names.error.message); }
	const files: BuiltFile[] = [];
	for (const name of names.value) {
		if (name.endsWith(".la")) { continue; }
		const path = join(source, name);
		const linked = isLinkLike(path);
		if (!linked.ok) { return Result.err(linked.error.message); }
		if (linked.value || !isFile(path)) {
			return Result.err(path + " is not a regular file");
		}
		const copy = join(target, name);
		try engineIo(copyFile(path, copy));
		try engineIo(chmod(copy, 0o644));
		const data = readFileBytes(copy);
		if (!data.ok) { return Result.err(data.error.message); }
		files.push({ bytes: data.value.length as int64, name, sha256: try sha256File(copy) });
	}
	files.sort((a: BuiltFile, b: BuiltFile): number => a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
	return Result.ok(files);
}

export function copyTree(source: string, target: string): Result<void, string> {
	try engineIo(ensureDir(target));
	const names = readDirNames(source);
	if (!names.ok) { return Result.err(names.error.message); }
	for (const name of names.value) {
		const path = join(source, name);
		const linked = isLinkLike(path);
		if (!linked.ok) { return Result.err(linked.error.message); }
		if (linked.value) { return Result.err(path + " is a symlink"); }
		if (isDir(path)) {
			try copyTree(path, join(target, name));
		} else {
			try engineIo(copyFile(path, join(target, name)));
		}
	}
	return Result.ok(null);
}

// The environment of a clang or test child: no PATH entry that could supply another toolchain.
export function childEnvironment(work: string): Record<string, string> {
	if (platform != "windows") {
		return { PATH: "/usr/bin:/bin", HOME: "/nonexistent", TMPDIR: work };
	}
	const root = env.get("SystemRoot") ?? "C:\\Windows";
	return { SystemRoot: root, PATH: root + "\\System32", TEMP: work, TMP: work };
}

function fileStartsWith(path: string, text: string): Result<boolean, string> {
	const data = readFileBytes(path);
	if (!data.ok) { return Result.err(data.error.message); }
	const head = text.asBytes();
	if (data.value.length < head.length) { return Result.ok(false); }
	for (let i: int64 = 0; i < head.length; i += 1) {
		if (data.value[i] != head[i]) { return Result.ok(false); }
	}
	return Result.ok(true);
}

function peProblem(variant: WindowsVariant, info: PeInfo): string | null {
	if (info.machine != MACHINE_X64) { return "machine is not AMD64"; }
	const isDll = (info.characteristics & DLL_CHARACTERISTIC) != 0;
	if (isDll != (variant == WindowsVariant.Dll)) {
		return "characteristics do not match the variant";
	}
	if (variant == WindowsVariant.Exe && info.subsystem != SUBSYSTEM_CONSOLE) {
		return "subsystem " + String(info.subsystem) + " is not console";
	}
	if (variant == WindowsVariant.Dll && info.exports.indexOf("addNumbers") < 0) {
		return "exports lack addNumbers";
	}
	const imports: string[] = [];
	let crt = false;
	for (const entry of info.imports) {
		const name = entry.dll.toLowerCase();
		imports.push(name);
		if (name.startsWith("api-ms-win-crt-")) { crt = true; }
	}
	for (const needed of ["ws2_32.dll", "bcrypt.dll", "kernel32.dll"]) {
		if (imports.indexOf(needed) < 0) { return "imports lack " + needed; }
	}
	return crt ? null : "imports lack the UCRT";
}

// Compile and link both fixtures through their configs with the caller's -lws2_32 -lmswsock -lbcrypt, with the
// mingw import libraries, a DLL with an import library and an executable with a PDB. Any failure or stderr is an
// error. Returns the linked files.
export function checkWindowsRuntime(
	clang: string, windows: string, fixtures: string, work: string,
): Result<string[], string> {
	const linked: string[] = [];
	const environment = childEnvironment(work);
	for (const variant of [WindowsVariant.Exe, WindowsVariant.Dll]) {
		const dll = variant == WindowsVariant.Dll;
		const name = dll ? "dll" : "exe";
		const config = ["--no-default-config", "--config",
			join(windows, windowsVariantDirectory(WindowsTarget.X64, variant) + ".cfg")];
		const fixture = join(fixtures, dll ? "runtimeWindowsDll.c" : "runtimeWindows.c");
		const object = join(work, name + ".o");
		const output = join(work, name + (dll ? ".dll" : ".exe"));
		const mingw = join(work, name + "Mingw" + (dll ? ".dll" : ".exe"));
		const steps: string[][] = [
			[...config, "-O2", "-c", fixture, "-o", object],
			[...config, object, ...USER_LIBRARIES, "-o", output],
			[...config, object, ...USER_LIBRARIES, ...MINGW_LIBRARIES, "-o", mingw],
			[...config, "-O2", "-fsanitize=undefined", fixture, ...USER_LIBRARIES,
				"-o", join(work, name + "Ubsan" + (dll ? ".dll" : ".exe"))],
			[...config, "-O0", "-fstack-protector-strong", fixture, ...USER_LIBRARIES,
				"-o", join(work, name + "Protected" + (dll ? ".dll" : ".exe"))],
		];
		if (dll) {
			steps.push([...config, object, ...USER_LIBRARIES,
				"-Wl,--out-implib," + join(work, "dll.lib"), "-o", join(work, "dllImplib.dll")]);
		} else {
			steps.push([...config, "-O2", "-g", "-gcodeview", "-c", fixture, "-o", join(work, "exeDebug.o")]);
			steps.push([...config, join(work, "exeDebug.o"), ...USER_LIBRARIES,
				"-Wl,--pdb=" + join(work, "exe.pdb"), "-o", join(work, "exePdb.exe")]);
		}
		for (const args of steps) {
			const done = captureToolUtf8(clang, args, { env: environment });
			if (!done.ok) { return Result.err(done.error); }
			if (done.value.returnCode != 0 || done.value.errorOutput.trim() != "") {
				return Result.err(name + ": clang " + args.slice(3).join(" ") +
					" exited " + String(done.value.returnCode) + ": " + done.value.errorOutput.trim());
			}
		}
		const bytes = readFileBytes(object);
		if (!bytes.ok) { return Result.err(bytes.error.message); }
		const stamp = (bytes.value[4] as uint32) | ((bytes.value[5] as uint32) << 8) |
			((bytes.value[6] as uint32) << 16) | ((bytes.value[7] as uint32) << 24);
		if (stamp != 0) { return Result.err(name + " object carries a COFF TimeDateStamp"); }
		for (const path of [output, mingw]) {
			const data = readFileBytes(path);
			if (!data.ok) { return Result.err(data.error.message); }
			const info = try parsePe(data.value);
			const problem = peProblem(variant, info);
			if (problem != null) { return Result.err(path + ": " + problem); }
			linked.push(path);
		}
	}
	const thread = join(work, "thread.exe");
	const threadArgs = ["--no-default-config", "--config",
		join(windows, windowsVariantDirectory(WindowsTarget.X64, WindowsVariant.Exe) + ".cfg"), "-O2",
		join(fixtures, "runtimeWindowsThread.c"), "-Wl,-Bstatic", "-lpthread", "-o", thread];
	const threaded = captureToolUtf8(clang, threadArgs, { env: environment });
	if (!threaded.ok) { return Result.err(threaded.error); }
	if (threaded.value.returnCode != 0 || threaded.value.errorOutput.trim() != "") {
		return Result.err("thread: clang exited " + String(threaded.value.returnCode) + ": " +
			threaded.value.errorOutput.trim());
	}
	linked.push(thread);
	if (!(try fileStartsWith(join(work, "exe.pdb"), "Microsoft C/C++ MSF 7.00"))) {
		return Result.err("exe.pdb is not a PDB");
	}
	if (!(try fileStartsWith(join(work, "dll.lib"), "!<arch>\n"))) {
		return Result.err("dll.lib is not an import archive");
	}
	return Result.ok(linked);
}

// Link an executable and a DLL from the C++ fixtures through the C++ config ahead of the C one, the order msc
// gives them. Any failure or stderr is an error. Returns the executable.
export function checkCxxRuntime(
	clangxx: string, windows: string, fixtures: string, work: string,
): Result<string, string> {
	const program = join(work, "cpp.exe");
	for (const variant of [WindowsVariant.Exe, WindowsVariant.Dll]) {
		const dll = variant == WindowsVariant.Dll;
		const stem = join(windows, windowsVariantDirectory(WindowsTarget.X64, variant));
		const args = ["--no-default-config", "--config", stem + ".cxx.cfg", "--config", stem + ".cfg",
			"-std=c++20", "-O2", join(fixtures, dll ? "runtimeCppDll.cpp" : "runtimeCpp.cpp"),
			"-o", dll ? join(work, "cpp.dll") : program];
		const done = captureToolUtf8(clangxx, args, { env: childEnvironment(work) });
		if (!done.ok) { return Result.err(done.error); }
		if (done.value.returnCode != 0 || done.value.errorOutput.trim() != "") {
			return Result.err("C++ " + (dll ? "dll" : "exe") + ": clang++ exited " +
				String(done.value.returnCode) + ": " + done.value.errorOutput.trim());
		}
	}
	return Result.ok(program);
}

function toolVersion(tool: string): Result<string, string> {
	const done = captureToolUtf8(tool, ["--version"]);
	if (!done.ok) { return Result.err(done.error); }
	return Result.ok(done.value.output.split("\n")[0].trim());
}

function produce(
	inputs: WindowsRuntimeInputs, engine: string, host: string, major: string, version: string,
	stage: string, work: string,
): Result<WindowsRuntimeReceipt, string> {
	const target = WindowsTarget.X64;
	const majorNumber = decimal(major);
	if (majorNumber == null) { return Result.err("engine major " + major + " is not a number"); }
	const windows = join(stage, "runtime/windows");
	const variants: VariantReceipt[] = [];
	try engineIo(ensureDir(windows));
	for (const variant of [WindowsVariant.Exe, WindowsVariant.Dll]) {
		const directory = windowsVariantDirectory(target, variant);
		try writeEngineText(join(windows, directory + ".cfg"),
			try renderWindowsSourceConfig(target, variant, majorNumber));
	}
	const config = join(windows, windowsVariantDirectory(target, WindowsVariant.Exe) + ".cfg");
	const environment = toolEnvironment(work, []);
	const prefixMaps = [
		"-ffile-prefix-map=" + inputs.mingwSource + "=/mingw-w64",
		"-ffile-prefix-map=" + inputs.llvmSource + "=/llvm-project",
		"-ffile-prefix-map=" + work + "=/build",
	];
	const autoconfHost = windowsAutoconfHost(target);
	const headersBuild = join(work, "headers-build");
	const headersPrefix = join(work, "headers-prefix");
	try engineIo(ensureDir(headersBuild));
	try runStep(join(inputs.mingwSource, "mingw-w64-headers/configure"),
		["--host=" + autoconfHost, "--prefix=" + headersPrefix, ...HEADER_OPTIONS], headersBuild, environment);
	try runStep("/usr/bin/make", ["install"], headersBuild, environment);
	try copyTree(join(headersPrefix, "include"), join(windows, "include/libc/mingw-w64"));
	const crtBuild = join(work, "crt-build");
	const crtPrefix = join(work, "crt-prefix");
	try engineIo(ensureDir(crtBuild));
	const tool = (name: string): string => join(engine, "bin/" + name);
	try runStep(join(inputs.mingwSource, "mingw-w64-crt/configure"), [
		"--host=" + autoconfHost, "--prefix=" + crtPrefix, ...CRT_OPTIONS,
		"CC=" + [join(stage, "bin/clang"), "--no-default-config", "--config=" + config, ...prefixMaps].join(" "),
		"AR=" + tool("llvm-ar"), "RANLIB=" + tool("llvm-ranlib"), "DLLTOOL=" + tool("llvm-dlltool"),
	], crtBuild, environment);
	try runStep("/usr/bin/make", ["-j" + String(inputs.jobs)], crtBuild, environment);
	try runStep("/usr/bin/make", ["install"], crtBuild, environment);
	// winpthreads goes in after the headers and the CRT and its headers replace the headers' pthread stubs, the
	// order a mingw-w64 toolchain installs them in.
	const threadsBuild = join(work, "winpthreads-build");
	try engineIo(ensureDir(threadsBuild));
	try runStep(join(inputs.mingwSource, "mingw-w64-libraries/winpthreads/configure"), [
		"--host=" + autoconfHost, "--prefix=" + crtPrefix, ...WINPTHREADS_OPTIONS,
		"CC=" + [join(stage, "bin/clang"), "--no-default-config", "--config=" + config, ...prefixMaps].join(" "),
		"AR=" + tool("llvm-ar"), "RANLIB=" + tool("llvm-ranlib"), "DLLTOOL=" + tool("llvm-dlltool"),
		"RC=" + tool("llvm-windres") + " --target=pe-x86-64 --preprocessor-arg=-nostdinc -I" +
			join(windows, "include/libc/mingw-w64"),
	], threadsBuild, environment);
	try runStep("/usr/bin/make", ["-j" + String(inputs.jobs)], threadsBuild, environment);
	try runStep("/usr/bin/make", ["install"], threadsBuild, environment);
	try copyTree(join(crtPrefix, "include"), join(windows, "include/libc/mingw-w64"));
	const libraries = join(crtPrefix, "lib");
	for (const name of SSP_ARCHIVES) {
		try runStep(tool("llvm-ar"), ["rcs", join(libraries, name)], crtBuild, environment);
	}
	for (const name of DRIVER_FILES) {
		if (!isFile(join(libraries, name))) {
			return Result.err("the mingw-w64 build made no " + name);
		}
	}
	const build = join(work, "builtins");
	const cmakeEnvironment = toolEnvironment(work, [inputs.cmake, inputs.ninja]);
	try runStep(inputs.cmake, builtinsCmakeArguments(target, inputs.llvmSource, stage, config,
		build, inputs.ninja, prefixMaps), work, cmakeEnvironment);
	const triple = windowsClangTriple(target);
	const archive = "compiler-rt/lib/" + triple + "/libclang_rt.builtins.a";
	try runStep(inputs.ninja, ["-C", build, "-j", String(inputs.jobs), archive], work, cmakeEnvironment);
	const builtins = join(build, archive);
	if (!isFile(builtins)) { return Result.err("the build made no libclang_rt.builtins.a"); }
	try checkMovedSymbols(tool("llvm-nm"), libraries, builtins);
	const sanitizerBuild = join(work, "sanitizers");
	try runStep(inputs.cmake, sanitizerCmakeArguments(target, inputs.llvmSource, stage, config,
		sanitizerBuild, inputs.ninja, prefixMaps), work, cmakeEnvironment);
	try runStep(inputs.ninja, ["-C", sanitizerBuild, "-j", String(inputs.jobs),
		...sanitizerArchives(target)], work, cmakeEnvironment);
	for (const archive of sanitizerArchives(target)) {
		const built = join(sanitizerBuild, archive);
		if (!isFile(built)) { return Result.err("the build made no " + basename(archive)); }
		try refuseDwarf(tool("llvm-readobj"), built);
		try engineIo(copyFile(built, join(libraries, basename(archive))));
	}
	for (const variant of [WindowsVariant.Exe, WindowsVariant.Dll]) {
		const directory = windowsVariantDirectory(target, variant);
		variants.push({
			config: directory + ".cfg", directory,
			files: try copyRegularFiles(libraries, join(windows, directory)),
			variant: variant == WindowsVariant.Dll ? "dll" : "exe",
		});
	}
	const builtinsPath = builtinsDirectory(target, major) + "/libclang_rt.builtins.a";
	try engineIo(copyFile(builtins, join(stage, builtinsPath)));
	// The C++ runtime goes in last: its configure links against the finished C runtime of the stage.
	const cxxBuild = join(work, "cxx");
	const cxxInstall = join(work, "cxx-install");
	try runStep(inputs.cmake, cxxConfigureArguments(inputs.ninja, inputs.llvmSource, cxxBuild, cxxInstall,
		stage, config, triple, prefixMaps), work, cmakeEnvironment);
	try runStep(inputs.ninja, ["-C", cxxBuild, "-j", String(inputs.jobs), "install"], work, cmakeEnvironment);
	const cxx = try installCxxRuntime(cxxInstall, inputs.llvmSource, windows,
		cxxLayout(windowsTargetName(target)), cxxCmakeArguments(triple));
	const notices: string[] = [...cxx.notices];
	for (const notice of MINGW_NOTICES) {
		const source = join(inputs.mingwSource, notice[0]);
		if (!isFile(source)) { return Result.err("mingw-w64 notice " + notice[0] + " is missing"); }
		const copy = "notices/mingw-w64/" + notice[1];
		try engineIo(ensureDir(join(windows, "notices/mingw-w64")));
		try engineIo(copyFile(source, join(windows, copy)));
		notices.push(copy);
	}
	const license = join(inputs.llvmSource, "compiler-rt/LICENSE.TXT");
	return Result.ok({
		builtins: builtinsPath, builtinsSha256: try sha256File(builtins),
		compilerRtLicenseSha256: try sha256File(license),
		cxx, engineRelative: ENGINE_RELATIVE, engineVersion: version, kind: WINDOWS_RUNTIME_KIND,
		limits: LIMITS,
		llvm: { archiveSha256: inputs.llvmSha256, options: BUILTINS_DISABLED,
			version: try llvmSourceVersion(inputs.llvmSource) },
		mingw: { archiveSha256: inputs.mingwSha256, options: [...HEADER_OPTIONS, ...CRT_OPTIONS, ...WINPTHREADS_OPTIONS],
			version: try mingwVersion(inputs.mingwSource) },
		notices, producerHost: host, redistributionCertified: false,
		sanitizers: WINDOWS_SANITIZERS,
		statement: "Built with the engine's clang from the named mingw-w64 and llvm-project release " +
			"sources; no Zig and no prebuilt runtime. Not an upstream-published binary.",
		targets: [windowsTargetName(target)],
		tools: { cmake: try toolVersion(inputs.cmake), ninja: try toolVersion(inputs.ninja) },
		variants,
	});
}

function isDigest(text: string): boolean {
	if (text.length != 64) { return false; }
	for (let i: int32 = 0; i < 64; i += 1) {
		const code = text.charCodeAt(i);
		if (!((code >= 48 && code <= 57) || (code >= 97 && code <= 102))) { return false; }
	}
	return true;
}

function publish(
	stage: string, partial: string, receipt: WindowsRuntimeReceipt, inputs: WindowsRuntimeInputs,
): Result<void, string> {
	try copyTree(join(stage, "runtime"), join(partial, "runtime"));
	const builtins = join(partial, receipt.builtins);
	try engineIo(ensureDir(dirname(builtins)));
	try engineIo(copyFile(join(stage, receipt.builtins), builtins));
	try engineIo(ensureDir(join(partial, "notices/compiler-rt")));
	try engineIo(copyFile(join(inputs.llvmSource, "compiler-rt/LICENSE.TXT"),
		join(partial, COMPILER_RT_LICENSE)));
	const text = asciiEngineJson(stringifyPretty(jsonValueOf(receipt), 2)) + "\n";
	return writeEngineText(join(partial, WINDOWS_RUNTIME_RECEIPT), text);
}

// No file of the overlay may name a path of the producer's machine: it would reach every program's debug info.
function refuseLeakedPaths(overlay: string, paths: string[]): Result<void, string> {
	const args = ["-roaF"];
	for (const path of paths) { args.push("-e"); args.push(path); }
	args.push(overlay);
	const done = captureToolUtf8("/usr/bin/grep", args);
	if (!done.ok) { return Result.err(done.error); }
	if (done.value.returnCode == 1) { return Result.ok(null); }
	if (done.value.returnCode == 0) {
		return Result.err("overlay files name producer paths: " + done.value.output.split("\n").slice(0, 5).join(", "));
	}
	return Result.err("grep failed: " + done.value.errorOutput);
}

function buildOverlay(
	inputs: WindowsRuntimeInputs, engine: string, host: string, major: string, version: string,
	work: string, partial: string, fixtures: string,
): Result<WindowsRuntimeReceipt, string> {
	const stage = join(work, "stage");
	try linkEngineAround(engine, stage, builtinsDirectory(WindowsTarget.X64, major));
	const receipt = try produce(inputs, engine, host, major, version, stage, work);
	const verify = join(work, "verify");
	try engineIo(ensureDir(verify));
	try checkWindowsRuntime(join(stage, "bin/clang"), join(stage, "runtime/windows"), fixtures, verify);
	try checkCxxRuntime(join(stage, "bin/clang++"), join(stage, "runtime/windows"), fixtures, verify);
	try publish(stage, partial, receipt, inputs);
	try refuseLeakedPaths(partial, [inputs.mingwSource, inputs.llvmSource, work, engine]);
	return Result.ok(receipt);
}

// Write the bundle-root overlay of the x86_64-windows-gnu runtime to the new directory inputs.output.
export function prepareWindowsRuntime(
	given: WindowsRuntimeInputs, fixtures: string,
): Result<WindowsRuntimeReceipt, string> {
	const inputs: WindowsRuntimeInputs = {
		...given,
		mingwSource: try absoluteEnginePath(given.mingwSource),
		llvmSource: try absoluteEnginePath(given.llvmSource),
	};
	if (platform == "windows") {
		return Result.err("the mingw-w64 build needs sh and make; run the producer on Linux or macOS");
	}
	if (!isDigest(inputs.mingwSha256) || !isDigest(inputs.llvmSha256)) {
		return Result.err("--mingw-sha256 and --llvm-sha256 must be sha256 digests");
	}
	const engine = try absoluteEnginePath(inputs.engine);
	const output = try absoluteEnginePath(inputs.output);
	if (isLinkLike(output).ok) {
		return Result.err("output " + output + " exists; it is never replaced");
	}
	if (isLinkLike(join(engine, "runtime")).ok) {
		return Result.err("engine " + engine + " already has a runtime entry; --engine takes the component alone");
	}
	const contract = try verifyEngineContract(engine);
	const major = contract.version.split(".")[0];
	const source = try llvmSourceVersion(inputs.llvmSource);
	if (source != contract.version) {
		return Result.err("source " + inputs.llvmSource + " is LLVM " + source +
			", the engine is " + contract.version);
	}
	try mingwVersion(inputs.mingwSource);
	const work = try claimPartial(join(dirname(output), "." + basename(output) + "-work"));
	const partial = claimPartial(output);
	if (!partial.ok) {
		removeAll(work);
		return Result.err(partial.error);
	}
	const done = buildOverlay(inputs, engine, contract.host, major, contract.version, work,
		partial.value, fixtures);
	removeAll(work);
	if (!done.ok) {
		removeAll(partial.value);
		return done;
	}
	const published = renameNoReplace(partial.value, output);
	if (!published.ok) {
		removeAll(partial.value);
		return Result.err(published.error.kind == IoErrorKind.AlreadyExists ?
			"output " + output + " exists; it is never replaced" : published.error.message);
	}
	return done;
}

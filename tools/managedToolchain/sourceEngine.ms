import { arch, env, execFile, findOnPath, platform } from "std/process";
import {
	basename, dirname, ensureDir, isDir, isFile, isLinkLike, join, normalize, readDirNames, remove,
} from "std/fs";
import { IoErrorKind } from "std/io/errors";
import { jsonValueOf } from "std/serialize/json";
import { stringifyPretty } from "std/serialize/json/stringify";
import { sha256File } from "./fileDigest";
import { absoluteEnginePath, engineIo, readEngineHeader, writeEngineText } from "./engineFiles";
import { MINIMUM_MACOS_VERSION } from "./darwinConfig";
import { captureToolUtf8 } from "./processCapture";
import { readUtf8File } from "./textFile";
import {
	WindowsTarget, WindowsVariant, windowsClangTriple, windowsConfigPath,
} from "./windowsConfig";

const SOURCE_PREFIX = "llvm-project-";
const SOURCE_SUFFIX = ".src.tar.xz";
const DARWIN_SANITIZERS = "asan;tsan;ubsan_minimal";
const INSTRUMENTED_STAGE = "BOOTSTRAP_";
const ENGINE_STAGE = "BOOTSTRAP_BOOTSTRAP_";
const ENGINE_TARGET = "stage2-install-distribution-stripped";
const WINDOWS_ENGINE_TARGET = "install-distribution-stripped";
const WINDOWS_STAGE_FLAGS: string[] = [
	"-DCMAKE_BUILD_TYPE=Release", "-DLLVM_TARGETS_TO_BUILD=Native", "-DLLVM_INCLUDE_TESTS=OFF",
	"-DLLVM_INCLUDE_BENCHMARKS=OFF", "-DLLVM_INCLUDE_EXAMPLES=OFF", "-DLLVM_ENABLE_ZLIB=OFF",
	"-DLLVM_ENABLE_ZSTD=OFF", "-DLLVM_ENABLE_LIBXML2=OFF", "-DLLVM_ENABLE_ASSERTIONS=OFF",
];
const STAGE0_RUNTIME_OFF: string[] = [
	"BUILD_SANITIZERS", "BUILD_XRAY", "BUILD_LIBFUZZER", "BUILD_MEMPROF", "BUILD_ORC",
	"BUILD_CTX_PROFILE", "BUILD_GWP_ASAN", "INCLUDE_TESTS",
];
const STAGE0_TOOLS: string[] = ["clang", "lld", "llvm-profdata", "llvm-ar", "llvm-ranlib", "llvm-rc"];
const BUNDLE_TOOLS: string[] = ["clang.exe", "clang++.exe", "llvm-rc.exe", "llvm-ar.exe", "llvm-ranlib.exe"];
const TRAINING_OBJECT = "tools/clang/lib/Sema/CMakeFiles/obj.clangSema.dir/Sema.cpp.obj";
const UNTRAINED_FUNCTIONS_QUIET = "-Wno-backend-plugin";
const PROFILE_SUFFIX = ".profraw";

export struct SourceTools {
	cc: string;
	cxx: string;
	linker: string;
}

export struct EngineCommand {
	file: string;
	args: string[];
}

export struct SourceEngineRequest {
	tarball: string;
	sha256: string;
	cache: string;
	cmake: string;
	ninja: string;
	work: string;
	output: string;
	jobs: int32;
	tools: SourceTools;
	bundle: string;
}

export struct WindowsStages {
	cmake: string;
	ninja: string;
	source: string;
	work: string;
	bundle: string;
	bundleMajor: string;
	target: WindowsTarget;
	jobs: int32;
}

export struct WindowsStagePlan {
	stage0: EngineCommand[];
	stage0Runtimes: EngineCommand;
	instrument: EngineCommand[];
	trainConfigure: EngineCommand;
	train: EngineCommand;
	engine: EngineCommand[];
}

export struct StageConfig {
	name: string;
	text: string;
}

export struct SourceEdit {
	file: string;
	reason: string;
	before: string;
	after: string;
}

export struct SourceEditRecord {
	file: string;
	reason: string;
	sha256: string;
}

export struct SourceProvenance {
	cacheFile: string;
	cacheSha256: string;
	llvmVersion: string;
	sourceEdits: SourceEditRecord[];
	sourceSha256: string;
	sourceTarball: string;
}

export const LLVM_SOURCE_EDITS: SourceEdit[] = [{
	file: "clang/tools/driver/driver.cpp",
	reason: "In a multicall build a hard link or a copy named clang resolves to itself, and clang " +
		"prepended its own name when it ran itself again, so the child read that name as an input " +
		"file and refused -cc1 and -cc1as. The name is now prepended only when the resolved " +
		"executable is not the one invoked.",
	before: "  // If -canonical-prefixes is set, GetExecutablePath will have resolved Path\n" +
		"  // to the llvm driver binary, not clang. In this case, we need to use\n" +
		"  // PrependArg which should be clang-*. Checking just CanonicalPrefixes is\n" +
		"  // safe even in the normal case because PrependArg will be null so\n" +
		"  // setPrependArg will be a no-op.\n" +
		"  if (ToolContext.NeedsPrependArg || CanonicalPrefixes)\n" +
		"    TheDriver.setPrependArg(ToolContext.PrependArg);\n",
	after: "  // If -canonical-prefixes is set, GetExecutablePath resolves a symbolic link\n" +
		"  // named clang-* to the llvm driver binary, which needs PrependArg to run\n" +
		"  // clang again. A hard link or a copy named clang-* resolves to itself and\n" +
		"  // must not get it: the llvm driver would read it as an input file.\n" +
		"  if (ToolContext.NeedsPrependArg ||\n" +
		"      (CanonicalPrefixes && ToolContext.PrependArg &&\n" +
		"       !llvm::sys::path::stem(Path).equals_insensitive(\n" +
		"           llvm::sys::path::stem(ToolContext.Path))))\n" +
		"    TheDriver.setPrependArg(ToolContext.PrependArg);\n",
}, {
	file: "clang/CMakeLists.txt",
	reason: "Darwin bootstrap stages use lld, but CMake kept the system linker " +
		"in CMAKE_LINKER and baked its version into clang. Pass the built " +
		"ld64.lld path to the next stage as for the other bootstrap linkers.",
	before: "    if((WIN32 AND NOT BOOTSTRAP_CMAKE_SYSTEM_NAME) OR " +
		"BOOTSTRAP_CMAKE_SYSTEM_NAME STREQUAL \"Windows\")\n" +
		"      set(${CLANG_STAGE}_LINKER " +
		"-DCMAKE_LINKER=${LLVM_RUNTIME_OUTPUT_INTDIR}/lld-link" +
		"${CMAKE_EXECUTABLE_SUFFIX})\n" +
		"    endif()\n",
	after: "    if((WIN32 AND NOT BOOTSTRAP_CMAKE_SYSTEM_NAME) OR " +
		"BOOTSTRAP_CMAKE_SYSTEM_NAME STREQUAL \"Windows\")\n" +
		"      set(${CLANG_STAGE}_LINKER " +
		"-DCMAKE_LINKER=${LLVM_RUNTIME_OUTPUT_INTDIR}/lld-link" +
		"${CMAKE_EXECUTABLE_SUFFIX})\n" +
		"    elseif(APPLE)\n" +
		"      set(${CLANG_STAGE}_LINKER " +
		"-DCMAKE_LINKER=${LLVM_RUNTIME_OUTPUT_INTDIR}/ld64.lld)\n" +
		"    endif()\n",
}, {
	file: "clang/lib/Driver/Driver.cpp",
	reason: "Record every file read while expanding configurations, including " +
		"nested response and config files, through the expansion's existing VFS.",
	before: "bool Driver::loadConfigFiles() {\n" +
		"  llvm::cl::ExpansionContext ExpCtx(Saver.getAllocator(),\n" +
		"                                    llvm::cl::tokenizeConfigFile, &getVFS());\n",
	after: `class ConfigFileDependencyFS final : public llvm::vfs::ProxyFileSystem {
  std::vector<std::string> FilesRead;

public:
  explicit ConfigFileDependencyFS(
      llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem> FS)
      : ProxyFileSystem(std::move(FS)) {}

  llvm::ErrorOr<std::unique_ptr<llvm::vfs::File>>
  openFileForRead(const llvm::Twine &Path) override {
    auto File = ProxyFileSystem::openFileForRead(Path);
    if (File && *File) {
      llvm::SmallString<128> Name(Path.str());
      llvm::sys::path::native(Name);
      FilesRead.push_back(Name.str().str());
    }
    return File;
  }

  llvm::ArrayRef<std::string> filesRead() const { return FilesRead; }
};

bool Driver::loadConfigFiles() {
  auto ConfigFS = llvm::makeIntrusiveRefCnt<ConfigFileDependencyFS>(VFS);
  llvm::cl::ExpansionContext ExpCtx(Saver.getAllocator(),
                                    llvm::cl::tokenizeConfigFile, ConfigFS.get());
`,
}, {
	file: "clang/lib/Driver/Driver.cpp",
	reason: "Expose all expanded configuration dependencies through the driver's " +
		"existing config-file report without adding duplicate paths.",
	before: "  // No error occurred.\n  return false;\n",
	after: "  // No error occurred.\n" +
		"  for (const auto &File : ConfigFS->filesRead())\n" +
		"    if (!llvm::is_contained(ConfigFiles, File))\n" +
		"      ConfigFiles.push_back(File);\n" +
		"  return false;\n",
}, {
	file: "llvm/lib/Support/CommandLine.cpp",
	reason: "Keep absolute included config paths absolute after CFGDIR expansion " +
		"instead of prefixing the including file's directory again.",
	before: "      ResponseFile.append(FilePath);\n" +
		"    } else {\n" +
		"      ResponseFile.append(BasePath);\n" +
		"      llvm::sys::path::append(ResponseFile, FileName);\n" +
		"    }\n",
	after: "      ResponseFile.append(FilePath);\n" +
		"    } else if (llvm::sys::path::is_absolute(FileName)) {\n" +
		"      ResponseFile.append(FileName);\n" +
		"    } else {\n" +
		"      ResponseFile.append(BasePath);\n" +
		"      llvm::sys::path::append(ResponseFile, FileName);\n" +
		"    }\n",
}];

export function digitsOnly(text: string): boolean {
	if (text == "") { return false; }
	for (let i: int32 = 0; i < text.length; i += 1) {
		const code = text.charCodeAt(i);
		if (code < 48 || code > 57) { return false; }
	}
	return true;
}

export function llvmSourceVersion(tarball: string): Result<string, string> {
	const name = basename(tarball);
	const refused: Result<string, string> = Result.err(tarball +
		": not an llvm-project-X.Y.Z.src.tar.xz source tarball");
	if (!name.startsWith(SOURCE_PREFIX) || !name.endsWith(SOURCE_SUFFIX)) {
		return refused;
	}
	const version = name.slice(SOURCE_PREFIX.length,
		name.length - SOURCE_SUFFIX.length);
	const parts = version.split(".");
	if (parts.length != 3) { return refused; }
	for (const part of parts) {
		if (!digitsOnly(part)) { return refused; }
	}
	return Result.ok(version);
}

export function isSha256Hex(text: string): boolean {
	if (text.length != 64) { return false; }
	for (let i: int32 = 0; i < text.length; i += 1) {
		const code = text.charCodeAt(i);
		const digit = code >= 48 && code <= 57;
		const lower = code >= 97 && code <= 102;
		if (!digit && !lower) { return false; }
	}
	return true;
}

export function configureCommand(
	hostOs: string,
	hostArch: string,
	cmake: string,
	ninja: string,
	source: string,
	build: string,
	prefix: string,
	cache: string,
	tools: SourceTools,
): EngineCommand {
	const args = [
		"-G", "Ninja", "-DCMAKE_MAKE_PROGRAM=" + ninja,
		"-S", join(source, "llvm"), "-B", build, "-C", cache,
		"-DCMAKE_C_COMPILER=" + tools.cc,
		"-DCMAKE_CXX_COMPILER=" + tools.cxx,
		"-D" + ENGINE_STAGE + "CMAKE_INSTALL_PREFIX=" + prefix,
	];
	if (tools.linker != "") { args.push("-DLLVM_USE_LINKER=" + tools.linker); }
	if (hostOs == "darwin" || hostOs == "macos") {
		args.push("-D" + ENGINE_STAGE + "LLVM_BUILD_STATIC=OFF");
		for (const stage of ["", INSTRUMENTED_STAGE, ENGINE_STAGE]) {
			args.push("-D" + stage + "CMAKE_OSX_DEPLOYMENT_TARGET=" + MINIMUM_MACOS_VERSION);
		}
		args.push("-D" + ENGINE_STAGE + "COMPILER_RT_SANITIZERS_TO_BUILD=" + DARWIN_SANITIZERS);
		if (hostArch == "arm64" || hostArch == "aarch64") {
			args.push("-D" + ENGINE_STAGE + "DARWIN_osx_ARCHS=arm64");
			args.push("-D" + ENGINE_STAGE + "DARWIN_osx_BUILTIN_ARCHS=arm64");
		}
	}
	return { file: cmake, args };
}

export function buildCommand(
	ninja: string,
	build: string,
	jobs: int32,
	nice: string | null,
): Result<EngineCommand, string> {
	if (jobs < 1) {
		return Result.err("--jobs must be at least 1, got " + String(jobs));
	}
	const args = ["-C", build, "-j" + String(jobs), ENGINE_TARGET];
	if (nice == null) { return Result.ok({ file: ninja, args }); }
	return Result.ok({ file: nice, args: ["-n", "10", ninja, ...args] });
}

export function pathWithToolDir(tool: string, path: string, hostOs: string): string {
	const separator = hostOs == "windows" ? ";" : ":";
	return path == "" ? dirname(tool) : dirname(tool) + separator + path;
}

export function hostTool(name: string): Result<string, string> {
	const path = findOnPath(name);
	if (path == "") { return Result.err(name + " is not on PATH"); }
	return Result.ok(path);
}

export function runCommand(command: EngineCommand): Result<void, string> {
	const code = execFile(command.file, command.args);
	if (code != 0) {
		return Result.err(command.file + " " + command.args.join(" ") +
			" failed (rc=" + String(code) + ")");
	}
	return Result.ok(null);
}

export function existingFile(label: string, path: string): Result<string, string> {
	const absolute = try absoluteEnginePath(path);
	if (!isFile(absolute)) {
		return Result.err(label + " " + absolute + " is not a file");
	}
	return Result.ok(absolute);
}

export function refuseExisting(output: string): Result<void, string> {
	const existing = isLinkLike(output);
	if (existing.ok) {
		return Result.err(output + " exists; --output names a new directory");
	}
	if (existing.error.kind != IoErrorKind.NotFound &&
		existing.error.kind != IoErrorKind.NotDirectory) {
		return Result.err(existing.error.message);
	}
	return Result.ok(null);
}

// tar on Windows cannot create the symbolic links the source carries; they are test inputs and
// mlgo-utils scripts the build never reads, which the release bat skips the same way by extracting with 7z.
export function onlySymlinkFailures(errorOutput: string): boolean {
	let failed = false;
	for (const line of errorOutput.split("\n")) {
		if (line == "" || line.endsWith("tar: Exiting with failure status due to previous errors")) { continue; }
		if (!line.contains("tar: ") || !line.contains(": Cannot create symlink to ")) { return false; }
		failed = true;
	}
	return failed;
}

export function tarExtractArgs(tarball: string, dest: string, hostOs: string, gnu: boolean): string[] {
	const args = ["xf", tarball, "-C", dest];
	if (hostOs == "windows" && gnu) { args.push("--force-local"); }
	return args;
}

export function applySourceEdits(source: string, edits: SourceEdit[]): Result<void, string> {
	for (const edit of edits) {
		const path = join(source, edit.file);
		const parts = (try readUtf8File(path)).split(edit.before);
		if (parts.length != 2) {
			return Result.err(path + " has the text of its source edit " +
				String(parts.length - 1) + " times, expected once");
		}
		try writeEngineText(path, parts[0] + edit.after + parts[1]);
	}
	return Result.ok(null);
}

export function sourceEditRecords(
	source: string, edits: SourceEdit[],
): Result<SourceEditRecord[], string> {
	const records: SourceEditRecord[] = [];
	for (const edit of edits) {
		records.push({
			file: edit.file, reason: edit.reason,
			sha256: try sha256File(join(source, edit.file)),
		});
	}
	return Result.ok(records);
}

export function extractTarball(tarball: string, extracted: string): Result<void, string> {
	try engineIo(ensureDir(extracted));
	const tar = try hostTool("tar");
	let gnu = false;
	if (platform == "windows") {
		const version = try captureToolUtf8(tar, ["--version"]);
		gnu = version.output.contains("GNU tar");
	}
	const args = tarExtractArgs(tarball, extracted, platform, gnu);
	if (platform == "windows") {
		const ran = try captureToolUtf8(tar, args);
		if (ran.returnCode != 0 && !onlySymlinkFailures(ran.errorOutput)) {
			return Result.err(tar + " " + args.join(" ") + " failed (rc=" +
				String(ran.returnCode) + "): " + ran.errorOutput);
		}
		return Result.ok(null);
	}
	return runCommand({ file: tar, args });
}

export function extractLlvmSource(
	tarball: string, version: string, work: string,
): Result<string, string> {
	const extracted = join(work, "src");
	try extractTarball(tarball, extracted);
	const source = join(extracted, SOURCE_PREFIX + version + ".src");
	if (!isDir(source)) {
		return Result.err(tarball + " did not extract to " + source);
	}
	try applySourceEdits(source, LLVM_SOURCE_EDITS);
	return Result.ok(source);
}

function windowsConfigure(stages: WindowsStages, stage: string, settings: string[]): EngineCommand {
	return { file: stages.cmake, args: [
		"-G", "Ninja", "-DCMAKE_MAKE_PROGRAM=" + stages.ninja,
		"-S", join(stages.source, "llvm"), "-B", join(stages.work, stage), ...settings,
	] };
}

function windowsNinja(stages: WindowsStages, stage: string, targets: string[]): EngineCommand {
	return { file: stages.ninja, args: [
		"-C", join(stages.work, stage), "-j" + String(stages.jobs), ...targets,
	] };
}

function builtWith(compilers: string, tools: string): string[] {
	return [
		"-DCMAKE_C_COMPILER=" + join(compilers, "clang.exe"),
		"-DCMAKE_CXX_COMPILER=" + join(compilers, "clang++.exe"),
		"-DCMAKE_RC_COMPILER=" + join(tools, "llvm-rc.exe"),
		"-DCMAKE_AR=" + join(tools, "llvm-ar.exe"),
		"-DCMAKE_RANLIB=" + join(tools, "llvm-ranlib.exe"),
	];
}

function bundleConfig(stages: WindowsStages, cpp: boolean): string {
	return join(join(stages.bundle, "runtime"),
		windowsConfigPath(stages.target, WindowsVariant.Exe, cpp));
}

export function windowsProfile(stages: WindowsStages): string {
	return join(stages.work, "profile.profdata");
}

export function windowsStagePlan(
	stages: WindowsStages, cache: string, output: string,
): WindowsStagePlan {
	const triple = windowsClangTriple(stages.target);
	const bundleBin = join(stages.bundle, "bin");
	const stage0Bin = join(stages.work, "stage0/bin");
	const c = "--no-default-config --config=" + bundleConfig(stages, false);
	const cxx = "--no-default-config --config=" + bundleConfig(stages, true) +
		" --config=" + bundleConfig(stages, false);
	return {
		stage0: [
			windowsConfigure(stages, "stage0", [
				...WINDOWS_STAGE_FLAGS, "-DLLVM_ENABLE_PROJECTS=clang;lld",
				"-DLLVM_ENABLE_RUNTIMES=compiler-rt",
				"-DLLVM_BUILTIN_TARGETS=" + triple, "-DLLVM_RUNTIME_TARGETS=" + triple,
				...STAGE0_RUNTIME_OFF.map((part: string): string =>
					"-DRUNTIMES_" + triple + "_COMPILER_RT_" + part + "=OFF"),
				...builtWith(bundleBin, bundleBin), "-DCMAKE_C_FLAGS=" + c,
				"-DCMAKE_CXX_FLAGS=" + cxx, "-DCMAKE_ASM_FLAGS=" + c, "-DLLVM_USE_LINKER=lld",
			]),
			windowsNinja(stages, "stage0", STAGE0_TOOLS),
		],
		stage0Runtimes: windowsNinja(stages, "stage0", ["runtimes"]),
		instrument: [
			windowsConfigure(stages, "instrument", [
				...WINDOWS_STAGE_FLAGS, ...builtWith(stage0Bin, stage0Bin), "-DLLVM_ENABLE_LLD=ON",
				"-DLLVM_ENABLE_PROJECTS=clang", "-DLLVM_BUILD_INSTRUMENTED=IR",
			]),
			windowsNinja(stages, "instrument", ["clang"]),
		],
		trainConfigure: windowsConfigure(stages, "train", [
			...WINDOWS_STAGE_FLAGS, ...builtWith(join(stages.work, "instrument/bin"), stage0Bin),
			"-DLLVM_ENABLE_PROJECTS=clang",
		]),
		train: { file: stages.ninja, args: ["-C", join(stages.work, "train"), TRAINING_OBJECT] },
		engine: [
			windowsConfigure(stages, "final", [
				"-C", cache, ...builtWith(stage0Bin, stage0Bin),
				"-DCMAKE_INSTALL_PREFIX=" + output,
				"-DCMAKE_C_FLAGS=" + UNTRAINED_FUNCTIONS_QUIET,
				"-DCMAKE_CXX_FLAGS=" + UNTRAINED_FUNCTIONS_QUIET,
				"-DLLVM_PROFDATA_FILE=" + windowsProfile(stages),
			]),
			windowsNinja(stages, "final", [WINDOWS_ENGINE_TARGET]),
		],
	};
}

export function mergeProfilesCommand(stages: WindowsStages, profiles: string[]): EngineCommand {
	return { file: join(stages.work, "stage0/bin/llvm-profdata.exe"), args: [
		"merge", "-output=" + windowsProfile(stages), ...profiles,
	] };
}

export function windowsStageConfig(
	bundleText: string, bundleMajor: string, runtime: string, stage0: string, major: string,
): Result<string, string> {
	const bundleResource = "<CFGDIR>/../../lib/clang/" + bundleMajor;
	const bundleLinker = "<CFGDIR>/../../bin/ld.lld";
	for (const named of [bundleResource, bundleLinker]) {
		if (!bundleText.contains(named)) {
			return Result.err("the bundle's Windows config names no " + named);
		}
	}
	return Result.ok(bundleText
		.replaceAll(bundleResource, join(stage0, "lib/clang/" + major))
		.replaceAll(bundleLinker, join(stage0, "bin/ld.lld"))
		.replaceAll("<CFGDIR>", runtime));
}

export function windowsStageConfigs(
	stages: WindowsStages, bundleText: string, major: string,
): Result<StageConfig[], string> {
	const triple = windowsClangTriple(stages.target);
	const text = try windowsStageConfig(bundleText, stages.bundleMajor,
		dirname(bundleConfig(stages, false)), join(stages.work, "stage0"), major);
	return Result.ok([
		{ name: triple + ".cfg", text },
		{ name: triple + "-clang++.cfg",
			text: "@" + bundleConfig(stages, true) + "\n@" + triple + ".cfg\n" },
	]);
}

export function windowsStagesOf(
	hostArch: string, cmake: string, ninja: string, work: string, bundlePath: string, jobs: int32,
): Result<WindowsStages, string> {
	if (hostArch != "amd64" && hostArch != "x86_64") {
		return Result.err("the Windows engine stages are written for an x64 host, not " + hostArch);
	}
	if (bundlePath == "") {
		return Result.err("--bundle is required on Windows: its clang and mingw runtime " +
			"build the first stage");
	}
	const bundle = normalize(try absoluteEnginePath(bundlePath));
	if (bundle.contains(" ")) {
		return Result.err("--bundle " + bundle + " has a space, which CMAKE_C_FLAGS cannot carry");
	}
	const stages: WindowsStages = {
		cmake: normalize(cmake), ninja: normalize(ninja), source: "", work: normalize(work),
		bundle, bundleMajor: (try readEngineHeader(bundle)).version.split(".")[0],
		target: WindowsTarget.X64, jobs,
	};
	for (const tool of BUNDLE_TOOLS) {
		try existingFile("--bundle tool", join(bundle, "bin/" + tool));
	}
	try existingFile("--bundle config", bundleConfig(stages, false));
	try existingFile("--bundle config", bundleConfig(stages, true));
	return Result.ok(stages);
}

function profileFiles(directory: string): Result<string[], string> {
	const names = readDirNames(directory);
	if (!names.ok) { return Result.err(names.error.message); }
	const profiles: string[] = [];
	for (const name of names.value) {
		if (name.endsWith(PROFILE_SUFFIX)) { profiles.push(join(directory, name)); }
	}
	profiles.sort();
	return Result.ok(profiles);
}

function writeStageConfigs(bin: string, configs: StageConfig[]): Result<void, string> {
	for (const config of configs) {
		try writeEngineText(join(bin, config.name), config.text);
	}
	return Result.ok(null);
}

// Stages after llvm/utils/release/build_llvm_release.bat. The profiles cmake's own compiler
// checks write are dropped before the training compile, as there: they are not representative.
function runWindowsStages(
	stages: WindowsStages, cache: string, output: string, version: string,
): Result<void, string> {
	const plan = windowsStagePlan(stages, normalize(cache), normalize(output));
	const configs = try windowsStageConfigs(stages,
		try readUtf8File(bundleConfig(stages, false)), version.split(".")[0]);
	for (const command of plan.stage0) { try runCommand(command); }
	try writeStageConfigs(join(stages.work, "stage0/bin"), configs);
	try runCommand(plan.stage0Runtimes);
	for (const command of plan.instrument) { try runCommand(command); }
	try writeStageConfigs(join(stages.work, "instrument/bin"), configs);
	try runCommand(plan.trainConfigure);
	const profileDirectory = join(stages.work, "instrument/profiles");
	for (const stale of try profileFiles(profileDirectory)) { try engineIo(remove(stale)); }
	try runCommand(plan.train);
	const profiles = try profileFiles(profileDirectory);
	if (profiles.length == 0) {
		return Result.err("the training compile wrote no profile into " + profileDirectory);
	}
	try runCommand(mergeProfilesCommand(stages, profiles));
	for (const command of plan.engine) { try runCommand(command); }
	return Result.ok(null);
}

export function prepareSourceEngine(
	request: SourceEngineRequest,
): Result<SourceProvenance, string> {
	const tarball = try existingFile("--source-tarball", request.tarball);
	const cache = try existingFile("--cache", request.cache);
	const cmake = try existingFile("--cmake", request.cmake);
	const ninja = try existingFile("--ninja", request.ninja);
	const work = try absoluteEnginePath(request.work);
	const output = try absoluteEnginePath(request.output);
	const version = try llvmSourceVersion(tarball);
	if (!isSha256Hex(request.sha256)) {
		return Result.err("--source-sha256 must be 64 lowercase hex digits");
	}
	const actual = try sha256File(tarball);
	if (actual != request.sha256) {
		return Result.err(tarball + ": sha256 " + actual +
			", expected " + request.sha256);
	}
	try refuseExisting(output);
	const windows = platform == "windows";
	if (!windows && request.bundle != "") {
		return Result.err("--bundle builds the first stage on Windows only; here --cc and --cxx do");
	}
	const nice = windows ? null : try hostTool("nice");
	const build = join(work, "build");
	const install = try buildCommand(ninja, build, request.jobs, nice);
	const stages = windows ?
		try windowsStagesOf(arch, cmake, ninja, work, request.bundle, request.jobs) : null;
	const source = try extractLlvmSource(tarball, version, work);
	env.set("PATH", pathWithToolDir(ninja, env.get("PATH") ?? "", platform));
	if (stages != null) {
		try runWindowsStages({ ...stages, source: normalize(source) }, cache, output, version);
	} else {
		try runCommand(configureCommand(platform, arch, cmake, ninja, source, build,
			output, cache, request.tools));
		try runCommand(install);
	}
	const record: SourceProvenance = {
		cacheFile: basename(cache),
		cacheSha256: try sha256File(cache),
		llvmVersion: version,
		sourceEdits: try sourceEditRecords(source, LLVM_SOURCE_EDITS),
		sourceSha256: request.sha256,
		sourceTarball: basename(tarball),
	};
	try writeEngineText(join(output, "PROVENANCE.json"),
		stringifyPretty(jsonValueOf(record), 2) + "\n");
	return Result.ok(record);
}

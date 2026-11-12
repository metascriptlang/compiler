import { arch, env, execFile, findOnPath, platform } from "std/process";
import { basename, dirname, ensureDir, isDir, isFile, isLinkLike, join } from "std/fs";
import { IoErrorKind } from "std/io/errors";
import { jsonValueOf } from "std/serialize/json";
import { stringifyPretty } from "std/serialize/json/stringify";
import { sha256File } from "./fileDigest";
import { absoluteEnginePath, engineIo, writeEngineText } from "./engineFiles";
import { MINIMUM_MACOS_VERSION } from "./darwinConfig";
import { captureToolUtf8 } from "./processCapture";
import { readUtf8File } from "./textFile";

const SOURCE_PREFIX = "llvm-project-";
const SOURCE_SUFFIX = ".src.tar.xz";
const DARWIN_SANITIZERS = "asan;tsan;ubsan_minimal";
const INSTRUMENTED_STAGE = "BOOTSTRAP_";
const ENGINE_STAGE = "BOOTSTRAP_BOOTSTRAP_";
const ENGINE_TARGET = "stage2-install-distribution-stripped";

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

export function extractLlvmSource(
	tarball: string, version: string, work: string,
): Result<string, string> {
	const extracted = join(work, "src");
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
	} else {
		try runCommand({ file: tar, args });
	}
	const source = join(extracted, SOURCE_PREFIX + version + ".src");
	if (!isDir(source)) {
		return Result.err(tarball + " did not extract to " + source);
	}
	try applySourceEdits(source, LLVM_SOURCE_EDITS);
	return Result.ok(source);
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
	const nice = platform == "windows" ? null : try hostTool("nice");
	const build = join(work, "build");
	const install = try buildCommand(ninja, build, request.jobs, nice);
	const source = try extractLlvmSource(tarball, version, work);
	env.set("PATH", pathWithToolDir(ninja, env.get("PATH") ?? "", platform));
	try runCommand(configureCommand(platform, arch, cmake, ninja, source, build,
		output, cache, request.tools));
	try runCommand(install);
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

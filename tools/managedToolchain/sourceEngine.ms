import { env, execFile, findOnPath, platform } from "std/process";
import { basename, dirname, ensureDir, isDir, isFile, isLinkLike, join } from "std/fs";
import { IoErrorKind } from "std/io/errors";
import { jsonValueOf } from "std/serialize/json";
import { stringifyPretty } from "std/serialize/json/stringify";
import { sha256File } from "./fileDigest";
import { absoluteEnginePath, engineIo, writeEngineText } from "./engineFiles";
import { MINIMUM_MACOS_VERSION } from "./darwinConfig";

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

export struct SourceProvenance {
	cacheFile: string;
	cacheSha256: string;
	llvmVersion: string;
	sourceSha256: string;
	sourceTarball: string;
}

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

function hostTool(name: string): Result<string, string> {
	const path = findOnPath(name);
	if (path == "") { return Result.err(name + " is not on PATH"); }
	return Result.ok(path);
}

function runCommand(command: EngineCommand): Result<void, string> {
	const code = execFile(command.file, command.args);
	if (code != 0) {
		return Result.err(command.file + " " + command.args.join(" ") +
			" failed (rc=" + String(code) + ")");
	}
	return Result.ok(null);
}

function existingFile(label: string, path: string): Result<string, string> {
	const absolute = try absoluteEnginePath(path);
	if (!isFile(absolute)) {
		return Result.err(label + " " + absolute + " is not a file");
	}
	return Result.ok(absolute);
}

function refuseExisting(output: string): Result<void, string> {
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
	const extracted = join(work, "src");
	try engineIo(ensureDir(extracted));
	try runCommand({
		file: try hostTool("tar"),
		args: ["xf", tarball, "-C", extracted],
	});
	const source = join(extracted, SOURCE_PREFIX + version + ".src");
	if (!isDir(source)) {
		return Result.err(tarball + " did not extract to " + source);
	}
	env.set("PATH", pathWithToolDir(ninja, env.get("PATH") ?? "", platform));
	try runCommand(configureCommand(platform, cmake, ninja, source, build,
		output, cache, request.tools));
	try runCommand(install);
	const record: SourceProvenance = {
		cacheFile: basename(cache),
		cacheSha256: try sha256File(cache),
		llvmVersion: version,
		sourceSha256: request.sha256,
		sourceTarball: basename(tarball),
	};
	try writeEngineText(join(output, "PROVENANCE.json"),
		stringifyPretty(jsonValueOf(record), 2) + "\n");
	return Result.ok(record);
}

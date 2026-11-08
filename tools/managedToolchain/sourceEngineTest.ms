import { cwd } from "std/process";
import { ensureDir, exists, join, removeAll, writeFile } from "std/fs";
import { randomUUIDSync } from "std/crypto";
import { sha256File } from "./fileDigest";
import {
	SourceEngineRequest, SourceTools,
	buildCommand, configureCommand, isSha256Hex, llvmSourceVersion,
	prepareSourceEngine,
} from "./sourceEngine";

const TOOLS: SourceTools = { cc: "clang", cxx: "clang++", linker: "lld" };
let cases: int32 = 0;

function expect(condition: boolean, what: string): void {
	cases += 1;
	if (!condition) { throw new Error("failed: " + what); }
}

function expectRefusal<T>(
	result: Result<T, string>,
	needle: string,
	what: string,
): void {
	cases += 1;
	if (result.ok) { throw new Error("accepted: " + what); }
	if (!result.error.contains(needle)) {
		throw new Error(what + ": " + result.error + " lacks " + needle);
	}
}

function versionCases(): void {
	const version = llvmSourceVersion("/w/llvm-project-23.1.4.src.tar.xz");
	expect(version.ok && version.value == "23.1.4", "official tarball name");
	for (const name of [
		"/w/llvm-23.1.4.tar.xz", "/w/llvm-project-23.1.src.tar.xz",
		"/w/llvm-project-23.1.x.src.tar.xz", "/w/llvm-project-.src.tar.xz",
	]) {
		expectRefusal(llvmSourceVersion(name), "not an llvm-project", name);
	}
	expect(isSha256Hex("0123456789abcdef".repeat(4)), "lowercase digest");
	expect(!isSha256Hex("0123456789ABCDEF".repeat(4)), "uppercase digest");
	expect(!isSha256Hex("0123456789abcdef".repeat(3)), "short digest");
	expect(!isSha256Hex("0123456789abcdeg".repeat(4)), "non-hex digest");
}

function commandCases(): void {
	const configure = configureCommand("linux", "/u/cmake", "/u/ninja",
		"/w/src/llvm-project-23.1.4.src", "/w/build", "/w/out",
		"/t/llvmEngine.cmake", TOOLS);
	const args = configure.args.join(" ");
	expect(configure.file == "/u/cmake", "configure runs the given cmake");
	expect(args.contains("-G Ninja -DCMAKE_MAKE_PROGRAM=/u/ninja"),
		"configure generates for the ninja the build runs");
	expect(args.contains("-S /w/src/llvm-project-23.1.4.src/llvm"),
		"configure names the llvm source tree");
	expect(args.contains("-B /w/build -C /t/llvmEngine.cmake"),
		"configure names the build tree and the cache file");
	expect(args.contains("-DLLVM_USE_LINKER=lld") &&
		args.contains("-DCMAKE_INSTALL_PREFIX=/w/out"),
		"configure names the linker and the install prefix");
	expect(!args.contains("LLVM_BUILD_STATIC"),
		"a Linux host keeps the cache's static engine");
	const darwin = configureCommand("darwin", "/u/cmake", "/u/ninja", "/s",
		"/b", "/o", "/c", { ...TOOLS, linker: "" }).args.join(" ");
	expect(!darwin.contains("LLVM_USE_LINKER"),
		"an empty linker leaves the system linker in place");
	expect(darwin.contains("-DLLVM_BUILD_STATIC=OFF") &&
		darwin.contains("-DCMAKE_OSX_DEPLOYMENT_TARGET=11.0"),
		"a macOS host links against the system libraries from macOS 11");
	const posix = buildCommand("/u/ninja", "/w/build", 16, "/usr/bin/nice");
	expect(posix.ok && posix.value.file == "/usr/bin/nice" &&
		posix.value.args.join(" ") ==
		"-n 10 /u/ninja -C /w/build -j16 install-distribution",
		"a POSIX build installs the distribution under nice");
	const windows = buildCommand("C:/t/ninja.exe", "C:/w/build", 8, null);
	expect(windows.ok && windows.value.file == "C:/t/ninja.exe",
		"a build without nice runs ninja itself");
	expect(!buildCommand("/u/ninja", "/w/build", 0, null).ok,
		"zero jobs are refused");
}

function scratch(): string {
	const token = randomUUIDSync();
	if (!token.ok) { throw new Error(token.error.message); }
	const dir = join(join(cwd(), "out"), "sourceEngineTest-" + token.value);
	const made = ensureDir(dir);
	if (!made.ok) { throw new Error(made.error.message); }
	return dir;
}

function written(path: string, text: string): string {
	const done = writeFile(path, text);
	if (!done.ok) { throw new Error(done.error.message); }
	return path;
}

function refusalCases(dir: string): void {
	const tarball = written(join(dir, "llvm-project-1.2.3.src.tar.xz"),
		"not a tarball");
	const cache = written(join(dir, "llvmEngine.cmake"), "set(X 1)\n");
	const digest = sha256File(tarball);
	if (!digest.ok) { throw new Error(digest.error); }
	const work = join(dir, "work");
	const output = join(dir, "engine");
	const request: SourceEngineRequest = {
		tarball, sha256: "0".repeat(64), cache, cmake: cache, ninja: cache,
		work, output, jobs: 4, tools: TOOLS,
	};
	const mismatch = prepareSourceEngine(request);
	expectRefusal(mismatch,
		"expected " + "0".repeat(64), "a digest mismatch");
	expect(!exists(join(work, "src")),
		"a digest mismatch is refused before extraction");
	const malformed = prepareSourceEngine({ ...request, sha256: "ABC" });
	expectRefusal(malformed,
		"64 lowercase hex digits", "a malformed digest");
	const made = ensureDir(output);
	if (!made.ok) { throw new Error(made.error.message); }
	const existing = prepareSourceEngine({ ...request, sha256: digest.value });
	expectRefusal(existing,
		"exists; --output names a new directory", "an existing output");
	expect(!exists(join(work, "src")),
		"an existing output is refused before extraction");
	const missing = prepareSourceEngine({
		...request, cmake: join(dir, "absent"),
	});
	expectRefusal(missing,
		"--cmake", "a missing cmake");
}

function run(): void {
	versionCases();
	commandCases();
	const dir = scratch();
	refusalCases(dir);
	const cleaned = removeAll(dir);
	if (!cleaned.ok) { throw new Error(cleaned.error.message); }
	console.log("sourceEngine: " + String(cases) + " cases OK");
}

when (!testBuild) { run(); }

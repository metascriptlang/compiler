import { cwd, platform } from "std/process";
import { ensureDir, exists, join, removeAll, writeFile } from "std/fs";
import { randomUUIDSync } from "std/crypto";
import { sha256File } from "./fileDigest";
import {
	LLVM_SOURCE_EDITS, SourceEdit, SourceEngineRequest, SourceTools, WindowsStages,
	applySourceEdits, buildCommand, configureCommand, isSha256Hex, llvmSourceVersion, onlySymlinkFailures,
	mergeProfilesCommand, pathWithToolDir, tarExtractArgs, prepareSourceEngine, sourceEditRecords,
	windowsStageConfig, windowsStageConfigs, windowsStagePlan, windowsStagesOf,
} from "./sourceEngine";
import { readUtf8File } from "./textFile";
import { WindowsTarget, WindowsVariant, renderWindowsSourceConfig } from "./windowsConfig";

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
	const configure = configureCommand("linux", "amd64", "/u/cmake", "/u/ninja",
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
		args.contains("-DBOOTSTRAP_BOOTSTRAP_CMAKE_INSTALL_PREFIX=/w/out"),
		"configure names the stage1 linker and the engine stage's install prefix");
	expect(!args.contains("LLVM_BUILD_STATIC"),
		"a Linux host keeps the cache's static engine");
	const darwin = configureCommand("darwin", "arm64", "/u/cmake", "/u/ninja", "/s",
		"/b", "/o", "/c", { ...TOOLS, linker: "" }).args.join(" ");
	expect(!darwin.contains("LLVM_USE_LINKER"),
		"an empty linker leaves the system linker in place");
	expect(darwin.contains("-DBOOTSTRAP_BOOTSTRAP_LLVM_BUILD_STATIC=OFF") &&
		darwin.contains("-DCMAKE_OSX_DEPLOYMENT_TARGET=11.0") &&
		darwin.contains("-DBOOTSTRAP_CMAKE_OSX_DEPLOYMENT_TARGET=11.0") &&
		darwin.contains("-DBOOTSTRAP_BOOTSTRAP_CMAKE_OSX_DEPLOYMENT_TARGET=11.0"),
		"every macOS stage targets macOS 11 and the engine links the system libraries");
	expect(darwin.contains("-DBOOTSTRAP_BOOTSTRAP_COMPILER_RT_SANITIZERS_TO_BUILD=asan;tsan;ubsan_minimal") &&
		!args.contains("COMPILER_RT_SANITIZERS_TO_BUILD"),
		"only macOS builds the sanitizers its SDK builds link from the engine");
	expect(darwin.contains("-DBOOTSTRAP_BOOTSTRAP_DARWIN_osx_ARCHS=arm64") &&
		darwin.contains("-DBOOTSTRAP_BOOTSTRAP_DARWIN_osx_BUILTIN_ARCHS=arm64") &&
		!args.contains("DARWIN_osx_ARCHS"),
		"an arm64 Mac builds its compiler-rt for arm64 alone, as the LLVM release workflow does");
	const intelMac = configureCommand("darwin", "amd64", "/u/cmake", "/u/ninja", "/s",
		"/b", "/o", "/c", { ...TOOLS, linker: "" }).args.join(" ");
	expect(!intelMac.contains("DARWIN_osx_ARCHS"), "an Intel Mac keeps compiler-rt's own arch list");
	const posix = buildCommand("/u/ninja", "/w/build", 16, "/usr/bin/nice");
	expect(posix.ok && posix.value.file == "/usr/bin/nice" &&
		posix.value.args.join(" ") ==
		"-n 10 /u/ninja -C /w/build -j16 stage2-install-distribution-stripped",
		"a POSIX build installs the PGO stage's stripped distribution under nice");
	const windows = buildCommand("C:/t/ninja.exe", "C:/w/build", 8, null);
	expect(windows.ok && windows.value.file == "C:/t/ninja.exe",
		"a build without nice runs ninja itself");
	expect(!buildCommand("/u/ninja", "/w/build", 0, null).ok,
		"zero jobs are refused");
	expect(pathWithToolDir("/p/bin/ninja", "/usr/bin:/bin", "linux") == "/p/bin:/usr/bin:/bin",
		"the build's PATH starts with the given ninja's directory, as perf-training's cmake looks it up there");
	expect(pathWithToolDir("C:/t/ninja.exe", "C:/w", "windows") == "C:/t;C:/w",
		"a Windows PATH joins with a semicolon");
	const symlinkOnly = "tar: llvm-project-23.1.4.src/llvm/utils/mlgo-utils/extract_ir.py: " +
		"Cannot create symlink to ‘mlgo/corpus/extract_ir.py’: No such file or directory\n" +
		"tar: Exiting with failure status due to previous errors\n";
	expect(onlySymlinkFailures(symlinkOnly), "symbolic links tar cannot make on Windows are skipped");
	expect(onlySymlinkFailures("/usr/bin/" + symlinkOnly.replaceAll("\ntar: ", "\n/usr/bin/tar: ")),
		"Git's tar names itself by its path");
	expect(!onlySymlinkFailures("tar: Exiting with failure status due to previous errors\n"),
		"a failure that names no symbolic link is not");
	expect(!onlySymlinkFailures(symlinkOnly + "tar: x.c: Cannot write: No space left on device\n"),
		"any other tar error refuses the extraction");
	expect(tarExtractArgs("C:/w/s.tar.xz", "C:/w/src", "windows", true).join(" ") ==
		"xf C:/w/s.tar.xz -C C:/w/src --force-local",
		"GNU tar on Windows reads C:/ as a local path, not a remote host");
	expect(!tarExtractArgs("C:/w/s.tar.xz", "C:/w/src", "windows", false).includes("--force-local") &&
		!tarExtractArgs("/w/s.tar.xz", "/w/src", "linux", true).includes("--force-local"),
		"bsdtar and POSIX hosts take the plain line");
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
		work, output, jobs: 4, tools: TOOLS, bundle: "",
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

const STAGES: WindowsStages = {
	cmake: "C:/t/cmake.exe", ninja: "C:/t/ninja.exe", source: "C:/w/src/llvm-project-23.1.4.src",
	work: "C:/w", bundle: "C:/b", bundleMajor: "22", target: WindowsTarget.X64, jobs: 8,
};

function windowsPlanCases(): void {
	const plan = windowsStagePlan(STAGES, "C:/t/llvmEngine.cmake", "C:/o");
	const stage0 = plan.stage0[0].args.join(" ");
	expect(plan.stage0[0].file == "C:/t/cmake.exe" &&
		stage0.contains("-S C:/w/src/llvm-project-23.1.4.src/llvm -B C:/w/stage0") &&
		stage0.contains("-DCMAKE_MAKE_PROGRAM=C:/t/ninja.exe"),
		"the first Windows stage is its own build of the extracted source");
	expect(stage0.contains("-DCMAKE_C_COMPILER=C:/b/bin/clang.exe") &&
		stage0.contains("-DCMAKE_CXX_COMPILER=C:/b/bin/clang++.exe") &&
		stage0.contains("-DCMAKE_RC_COMPILER=C:/b/bin/llvm-rc.exe") &&
		stage0.contains("-DCMAKE_AR=C:/b/bin/llvm-ar.exe"),
		"the bundle's tools build the first stage");
	expect(plan.stage0[0].args.includes("-DCMAKE_C_FLAGS=--no-default-config " +
		"--config=C:/b/runtime/windows/x86_64-windows-gnu.cfg") &&
		plan.stage0[0].args.includes("-DCMAKE_CXX_FLAGS=--no-default-config " +
		"--config=C:/b/runtime/windows/x86_64-windows-gnu.cxx.cfg " +
		"--config=C:/b/runtime/windows/x86_64-windows-gnu.cfg"),
		"the bundle's clang compiles against the bundle's mingw and C++ runtime configs");
	expect(stage0.contains("-DLLVM_BUILTIN_TARGETS=x86_64-w64-windows-gnu") &&
		stage0.contains("-DLLVM_RUNTIME_TARGETS=x86_64-w64-windows-gnu") &&
		stage0.contains("-DRUNTIMES_x86_64-w64-windows-gnu_COMPILER_RT_BUILD_SANITIZERS=OFF"),
		"the first stage builds its builtins and profile runtime for the mingw triple, no sanitizer");
	expect(plan.stage0[1].args.join(" ") ==
		"-C C:/w/stage0 -j8 clang lld llvm-profdata llvm-ar llvm-ranlib llvm-rc" &&
		plan.stage0Runtimes.args.join(" ") == "-C C:/w/stage0 -j8 runtimes",
		"the first stage's tools are built before its runtimes, which its own clang compiles");
	const instrument = plan.instrument[0].args.join(" ");
	expect(instrument.contains("-B C:/w/instrument") &&
		instrument.contains("-DCMAKE_C_COMPILER=C:/w/stage0/bin/clang.exe") &&
		instrument.contains("-DLLVM_BUILD_INSTRUMENTED=IR") &&
		instrument.contains("-DLLVM_ENABLE_PROJECTS=clang") &&
		plan.instrument[1].args.join(" ") == "-C C:/w/instrument -j8 clang",
		"the first stage builds an instrumented clang");
	const train = plan.trainConfigure.args.join(" ");
	expect(train.contains("-DCMAKE_CXX_COMPILER=C:/w/instrument/bin/clang++.exe") &&
		train.contains("-DCMAKE_AR=C:/w/stage0/bin/llvm-ar.exe") &&
		plan.train.args.join(" ") ==
		"-C C:/w/train tools/clang/lib/Sema/CMakeFiles/obj.clangSema.dir/Sema.cpp.obj",
		"the instrumented clang compiles Sema.cpp as its training");
	const engine = plan.engine[0].args.join(" ");
	expect(engine.contains("-B C:/w/final -C C:/t/llvmEngine.cmake") &&
		engine.contains("-DCMAKE_C_COMPILER=C:/w/stage0/bin/clang.exe") &&
		engine.contains("-DCMAKE_INSTALL_PREFIX=C:/o") &&
		engine.contains("-DLLVM_PROFDATA_FILE=C:/w/profile.profdata") &&
		!engine.contains("BOOTSTRAP") &&
		plan.engine[1].args.join(" ") == "-C C:/w/final -j8 install-distribution-stripped",
		"the first stage builds the engine from the cache file with the merged profile");
	const merge = mergeProfilesCommand(STAGES, ["C:/w/instrument/profiles/a.profraw"]);
	expect(merge.file == "C:/w/stage0/bin/llvm-profdata.exe" && merge.args.join(" ") ==
		"merge -output=C:/w/profile.profdata C:/w/instrument/profiles/a.profraw",
		"the first stage's llvm-profdata merges the training profiles");
}

function windowsConfigCases(dir: string): void {
	const rendered = renderWindowsSourceConfig(WindowsTarget.X64, WindowsVariant.Exe, 22);
	if (!rendered.ok) { throw new Error(rendered.error); }
	const config = windowsStageConfig(rendered.value, "22", "C:/b/runtime/windows", "C:/w/stage0", "23");
	expect(config.ok && config.value.contains("-resource-dir C:/w/stage0/lib/clang/23\n") &&
		config.value.contains("-isystem C:/w/stage0/lib/clang/23/include\n") &&
		config.value.contains("--ld-path=C:/w/stage0/bin/ld.lld\n") &&
		config.value.contains("--sysroot=C:/b/runtime/windows/x86_64-windows-gnu\n") &&
		!config.value.contains("<CFGDIR>") && !config.value.contains("clang/22"),
		"a stage's clang keeps the bundle's mingw runtime and takes its own headers, runtime and linker");
	expectRefusal(windowsStageConfig(rendered.value, "21", "C:/r", "C:/s", "23"),
		"names no <CFGDIR>/../../lib/clang/21", "a config of another LLVM major than the bundle's");
	expectRefusal(windowsStageConfig("-target x\n-resource-dir <CFGDIR>/../../lib/clang/22\n",
		"22", "C:/r", "C:/s", "23"),
		"names no <CFGDIR>/../../bin/ld.lld", "a config that names no bundle linker");
	const configs = windowsStageConfigs(STAGES, rendered.value, "23");
	expect(configs.ok && configs.value.length == 2 &&
		configs.value[0].name == "x86_64-w64-windows-gnu.cfg" &&
		configs.value[1].name == "x86_64-w64-windows-gnu-clang++.cfg" &&
		configs.value[1].text == "@C:/b/runtime/windows/x86_64-windows-gnu.cxx.cfg\n" +
		"@x86_64-w64-windows-gnu.cfg\n",
		"a stage's bin holds the default configs clang and clang++ look up by triple");
	expectRefusal(windowsStagesOf("arm64", "c", "n", dir, dir, 4), "x64 host", "an arm64 Windows host");
	expectRefusal(windowsStagesOf("amd64", "c", "n", dir, "", 4), "--bundle is required",
		"a Windows build without a bundle");
	const bundle = join(dir, "bundle");
	for (const sub of ["bin", "runtime/windows"]) {
		const made = ensureDir(join(bundle, sub));
		if (!made.ok) { throw new Error(made.error.message); }
	}
	written(join(bundle, "HOST"), "x86_64-windows\n");
	written(join(bundle, "VERSION"), "22.1.0\n");
	written(join(bundle, "runtime/windows/x86_64-windows-gnu.cfg"), rendered.value);
	written(join(bundle, "runtime/windows/x86_64-windows-gnu.cxx.cfg"), "-stdlib=libc++\n");
	for (const tool of ["clang.exe", "clang++.exe", "llvm-rc.exe", "llvm-ar.exe"]) {
		written(join(bundle, "bin/" + tool), "tool");
	}
	expectRefusal(windowsStagesOf("amd64", "c", "n", dir, bundle, 4), "llvm-ranlib.exe is not a file",
		"a bundle without a tool the first stage needs");
	written(join(bundle, "bin/llvm-ranlib.exe"), "tool");
	const stages = windowsStagesOf("amd64", "c", "n", dir, bundle, 4);
	expect(stages.ok && stages.value.bundleMajor == "22" && stages.value.jobs == 4 &&
		stages.value.bundle.endsWith("/bundle"),
		"a bundle with its tools and Windows configs carries its LLVM major");
	if (platform != "windows") {
		const tarball = written(join(dir, "llvm-project-1.2.3.src.tar.xz"), "not a tarball");
		const digest = sha256File(tarball);
		if (!digest.ok) { throw new Error(digest.error); }
		expectRefusal(prepareSourceEngine({
			tarball, sha256: digest.value, cache: tarball, cmake: tarball, ninja: tarball,
			work: join(dir, "bundleWork"), output: join(dir, "bundleEngine"), jobs: 4, tools: TOOLS,
			bundle,
		}), "--bundle builds the first stage on Windows only", "a bundle on a host that bootstraps");
	}
}

function editCases(dir: string): void {
	const edit: SourceEdit = { file: "a/driver.cpp", reason: "r", before: "old line\n", after: "new line\n" };
	const made = ensureDir(join(dir, "a"));
	if (!made.ok) { throw new Error(made.error.message); }
	const path = written(join(dir, "a/driver.cpp"), "head\nold line\ntail\n");
	expect(applySourceEdits(dir, [edit]).ok, "a text present once is replaced");
	const edited = readUtf8File(path);
	expect(edited.ok && edited.value == "head\nnew line\ntail\n", "only that text changes");
	const digest = sha256File(path);
	const records = sourceEditRecords(dir, [edit]);
	expect(digest.ok && records.ok && records.value.length == 1 &&
		records.value[0].sha256 == digest.value && records.value[0].reason == "r",
		"the record carries the edited file's digest and the reason");
	expectRefusal(applySourceEdits(dir, [edit]), "0 times, expected once", "a second application");
	written(path, "old line\nold line\n");
	expectRefusal(applySourceEdits(dir, [edit]), "2 times, expected once", "an ambiguous text");
	for (const shipped of LLVM_SOURCE_EDITS) {
		expect(shipped.before != shipped.after && shipped.reason != "" &&
			!shipped.after.contains(shipped.before), "a shipped edit changes its text for a stated reason");
	}
	expect(LLVM_SOURCE_EDITS.some((edit: SourceEdit): boolean =>
		edit.file == "clang/CMakeLists.txt" && edit.after.contains(
			"    elseif(APPLE)\n" +
			"      set(${CLANG_STAGE}_LINKER " +
			"-DCMAKE_LINKER=${LLVM_RUNTIME_OUTPUT_INTDIR}/ld64.lld)\n")),
		"a Darwin bootstrap passes the selected lld path to the next stage");
}

function run(): void {
	versionCases();
	commandCases();
	windowsPlanCases();
	const dir = scratch();
	refusalCases(dir);
	windowsConfigCases(dir);
	editCases(dir);
	const cleaned = removeAll(dir);
	if (!cleaned.ok) { throw new Error(cleaned.error.message); }
	console.log("sourceEngine: " + String(cases) + " cases OK");
}

when (!testBuild) { run(); }

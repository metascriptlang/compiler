import { arch, cwd, platform } from "std/process";
import { chmod, ensureDir, exists, isFile, join, removeAll, symlink, writeFile } from "std/fs";
import { randomUUIDSync } from "std/crypto";
import { readUtf8File } from "./textFile";
import {
	engineHostKey, llvmTreeVersion, packageSourceEngine, requiredResources,
	requiredTools, toolVersionLine,
} from "./sourceEnginePackage";

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

function pureCases(): void {
	const mac = engineHostKey("darwin", "arm64");
	expect(mac.ok && mac.value == "aarch64-macos", "an arm64 Mac");
	const linux = engineHostKey("linux", "amd64");
	expect(linux.ok && linux.value == "x86_64-linux", "an x86_64 Linux host");
	expectRefusal(engineHostKey("windows", "amd64"), "no source engine packaging",
		"Windows packs through its own producer");
	expectRefusal(engineHostKey("linux", "riscv64"), "no source engine packaging",
		"an unknown machine");
	const darwin = requiredResources("aarch64-macos", "23").join(" ");
	expect(darwin.contains("lib/clang/23/lib/darwin/libclang_rt.osx.a") &&
		darwin.contains("libclang_rt.ubsan_minimal_osx_dynamic.dylib") &&
		darwin.contains("libclang_rt.tsan_osx_dynamic.dylib"),
		"darwin needs the builtins and the shared sanitizers");
	const elf = requiredResources("x86_64-linux", "23").join(" ");
	expect(elf.contains("lib/clang/23/lib/x86_64-unknown-linux-gnu/libclang_rt.builtins.a") &&
		elf.contains("x86_64-unknown-linux-gnu/libclang_rt.ubsan_minimal.a.syms"),
		"Linux needs the per-target builtins and the minimal UBSan dynamic list");
	expect(!elf.contains("asan"), "Linux sanitizers come from the runtime");
	expect(requiredTools("x86_64-linux").includes("ld.lld") &&
		requiredTools("aarch64-macos").includes("ld64.lld"), "each host's linker");
	const tree = llvmTreeVersion("if(1)\n  set(LLVM_VERSION_MAJOR 23)\nendif()\n" +
		"set(LLVM_VERSION_MINOR 1)\nset(LLVM_VERSION_PATCH 4)\n");
	expect(tree.ok && tree.value == "23.1.4", "the source tree's version");
	expectRefusal(llvmTreeVersion("set(LLVM_VERSION_MAJOR 23)\nset(LLVM_VERSION_MINOR x)\n"),
		"LLVM_VERSION_MINOR", "a non-numeric minor");
	const lld = toolVersionLine("LLD 23.1.4 (compatible with GNU linkers)\n", "LLD ");
	expect(lld.ok && lld.value == "23.1.4", "lld's version line");
	expectRefusal(toolVersionLine("Homebrew clang version 23.1.4", "LLD "), "no 'LLD '",
		"another tool's output");
}

function written(path: string, text: string): void {
	if (!ensureDir(path.slice(0, path.lastIndexOf("/"))).ok || !writeFile(path, text).ok) {
		throw new Error("cannot write " + path);
	}
}

function fixture(dir: string, host: string, aliasTarget: string): string[] {
	const install = join(dir, "install");
	const source = join(dir, "llvm-project-1.2.3.src");
	written(join(install, "bin/llvm"), "#!/bin/sh\ncase \"$(basename \"$0\")\" in\n" +
		"clang*) echo 'clang version 1.2.3 (fixture)';;\n*) echo 'LLD 1.2.3 (fixture)';;\nesac\n");
	if (!chmod(join(install, "bin/llvm"), 0o755).ok) { throw new Error("chmod"); }
	for (const tool of requiredTools(host)) {
		if (!symlink(aliasTarget, join(install, "bin/" + tool)).ok) { throw new Error("symlink"); }
	}
	for (const rel of requiredResources(host, "1")) { written(join(install, rel), rel); }
	const libraries = requiredResources(host, "1")[1];
	written(join(install, libraries.slice(0, libraries.lastIndexOf("/")) + "/libclang_rt.lsan.a"), "lsan");
	written(join(install, "PROVENANCE.json"), "{\"cacheFile\": \"llvmEngine.cmake\", " +
		"\"cacheSha256\": \"" + "a".repeat(64) + "\", \"llvmVersion\": \"1.2.3\", " +
		"\"sourceSha256\": \"" + "b".repeat(64) + "\", " +
		"\"sourceTarball\": \"llvm-project-1.2.3.src.tar.xz\"}\n");
	written(join(source, "cmake/Modules/LLVMVersion.cmake"),
		"set(LLVM_VERSION_MAJOR 1)\nset(LLVM_VERSION_MINOR 2)\nset(LLVM_VERSION_PATCH 3)\n");
	for (const component of ["llvm", "clang", "lld", "compiler-rt"]) {
		written(join(source, component + "/LICENSE.TXT"), component + " license\n");
	}
	return [install, source];
}

function packagingCases(dir: string, host: string): void {
	const [install, source] = fixture(join(dir, "good"), host, "llvm");
	const output = join(dir, "engine");
	const packaged = packageSourceEngine(install, source, output);
	if (!packaged.ok) { throw new Error("packaging refused: " + packaged.error); }
	expect(packaged.value.contract.host == host &&
		packaged.value.contract.version == "1.2.3", "the contract names host and version");
	const receipt = readUtf8File(join(output, "notices/provenance.json"));
	expect(receipt.ok && receipt.value.contains("\"local-source-engine-proof\"") &&
		receipt.value.contains("\"redistributionCertified\": false") &&
		receipt.value.contains("notices/compiler-rt/LICENSE.TXT"),
		"the receipt names its kind, its licenses and no redistribution claim");
	expect(isFile(join(output, "notices/lld/LICENSE.TXT")), "each component's license ships");
	const shipped = requiredResources(host, "1")[1];
	expect(isFile(join(output, shipped)) && !exists(join(output,
		shipped.slice(0, shipped.lastIndexOf("/")) + "/libclang_rt.lsan.a")),
		"only the host's resource libraries ship");
	expectRefusal(packageSourceEngine(install, source, output), "exists",
		"an existing output is never replaced");
	const [strayInstall, straySource] = fixture(join(dir, "stray"), host, "../outside");
	expectRefusal(packageSourceEngine(strayInstall, straySource, join(dir, "strayEngine")),
		"is not an alias of bin/llvm", "an alias that leaves the multicall binary");
	expect(!exists(join(dir, "strayEngine")), "a refused package publishes nothing");
	const [oldInstall, oldSource] = fixture(join(dir, "old"), host, "llvm");
	written(join(oldSource, "cmake/Modules/LLVMVersion.cmake"),
		"set(LLVM_VERSION_MAJOR 1)\nset(LLVM_VERSION_MINOR 2)\nset(LLVM_VERSION_PATCH 4)\n");
	expectRefusal(packageSourceEngine(oldInstall, oldSource, join(dir, "oldEngine")),
		"source tree is LLVM 1.2.4", "a source tree of another release");
	const [bareInstall, bareSource] = fixture(join(dir, "bare"), host, "llvm");
	const missing = requiredResources(host, "1")[1];
	if (!removeAll(join(bareInstall, missing)).ok) { throw new Error("remove"); }
	expectRefusal(packageSourceEngine(bareInstall, bareSource, join(dir, "bareEngine")),
		"install lacks " + missing, "an install without the host's compiler-rt");
}

function run(): void {
	pureCases();
	const host = engineHostKey(platform, arch);
	if (host.ok) {
		const token = randomUUIDSync();
		if (!token.ok) { throw new Error(token.error.message); }
		const dir = join(join(cwd(), "out"), "sourceEnginePackageTest-" + token.value);
		packagingCases(dir, host.value);
		if (!removeAll(dir).ok) { throw new Error("cannot remove " + dir); }
	}
	console.log("sourceEnginePackage: " + String(cases) + " cases OK");
}

when (!testBuild) { run(); }

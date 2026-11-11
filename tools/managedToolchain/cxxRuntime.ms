import { env, platform } from "std/process";
import {
	basename, dirname, ensureDir, isDir, isFile, join, readDirNames, removeAll,
} from "std/fs";
import { parseJson, jsonValueOf, JsonKind } from "std/serialize/json";
import { getDynamicField } from "std/serialize/json/accessors";
import { stringifyPretty } from "std/serialize/json/stringify";
import { sha256File } from "./fileDigest";
import { readUtf8File } from "./textFile";
import { containsExistingRoot } from "./nativePath";
import { renameNoReplace } from "./nativePublication";
import { asciiEngineJson, claimPartial } from "./windowsEngine";
import { copyBundleTree } from "./bundleAssembly";
import {
	EngineCommand, existingFile, extractLlvmSource, isSha256Hex, llvmSourceVersion,
	pathWithToolDir, refuseExisting, runCommand,
} from "./sourceEngine";
import {
	EngineContract, absoluteEnginePath, copyEngineFile, engineFileSize, engineIo,
	verifyEngineContract, writeEngineContract, writeEngineText,
} from "./engineFiles";

const CONTRACT: string[] = ["HOST", "VERSION", "FILES.sha256", "IDENTITY"];
export const CXX_RECEIPT = "runtime/notices/cpp-provenance.json";
export const CXX_RECEIPT_KIND = "local-source-cxx-runtime";
const ZIG_NOTICE = "runtime/notices/zig";
const COMPONENTS: string[] = ["libcxx", "libcxxabi", "libunwind"];
const RECEIPT_ROOTS: string[] = ["notices", "runtime/notices", "runtime/windows/notices", "runtime/darwin/notices"];

export struct CxxAlias {
	alias: string;
	target: string;
}

export struct CxxArchive {
	name: string;
	built: string;
}

export struct CxxLayout {
	configDir: string;
	directory: string;
	configs: string[];
	archives: CxxArchive[];
	aliases: CxxAlias[];
}

export struct CxxInput {
	name: string;
	bytes: int64;
	sha256: string;
}

export struct CxxTargetRecord {
	directory: string;
	aliases: CxxAlias[];
	inputs: CxxInput[];
}

export struct CxxSource {
	llvmVersion: string;
	sourceSha256: string;
	sourceTarball: string;
}

export struct CxxReceipt {
	kind: string;
	engineVersion: string;
	target: string;
	statement: string;
	source: CxxSource;
	cmakeArguments: string[];
	archives: Map<string, CxxTargetRecord>;
	notices: string[];
	redistributionCertified: boolean;
}

export struct CxxRuntimeRequest {
	bundle: string;
	tarball: string;
	sha256: string;
	cmake: string;
	ninja: string;
	work: string;
	output: string;
	jobs: int32;
	target: string;
}

export struct CxxRuntimeResult {
	output: string;
	contract: EngineContract;
	removedZigNotice: boolean;
}

export function cxxLayout(target: string): Result<CxxLayout, string> {
	if (target != "x86_64-windows-gnu") {
		return Result.err("no source C++ runtime for " + target +
			": only x86_64-windows-gnu has a C runtime built from source");
	}
	return Result.ok({
		configDir: "runtime/windows",
		directory: target + ".cxx",
		configs: [target + ".cxx.cfg", target + ".dll.cxx.cfg"],
		archives: [
			{ name: "c++.lib", built: "lib/libc++.a" },
			{ name: "c++abi.lib", built: "lib/libc++abi.a" },
			{ name: "unwind.lib", built: "lib/libunwind.a" },
		],
		aliases: [
			{ alias: "stdc++.lib", target: "c++.lib" },
			{ alias: "supc++.lib", target: "c++abi.lib" },
			{ alias: "gcc_eh.lib", target: "unwind.lib" },
			{ alias: "gcc_s.lib", target: "unwind.lib" },
		],
	});
}

export function cxxConfigText(layout: CxxLayout): string {
	return "-isystem <CFGDIR>/" + layout.directory + "/include/c++/v1\n" +
		"-Xlinker -L -Xlinker <CFGDIR>/" + layout.directory + "\n" +
		"$-lc++\n$-lc++abi\n$-lunwind\n";
}

// The flags llvm-mingw's build-libcxx.sh gives LLVM's runtimes/ for a static mingw libc++.
export function cxxCmakeArguments(target: string, triple: string): string[] {
	return [
		"-DCMAKE_BUILD_TYPE=Release",
		"-DCMAKE_SYSTEM_NAME=Windows",
		"-DCMAKE_C_COMPILER_TARGET=" + triple,
		"-DCMAKE_CXX_COMPILER_TARGET=" + triple,
		"-DCMAKE_C_COMPILER_WORKS=TRUE",
		"-DCMAKE_CXX_COMPILER_WORKS=TRUE",
		"-DLLVM_ENABLE_RUNTIMES=libunwind;libcxxabi;libcxx",
		"-DLIBUNWIND_USE_COMPILER_RT=TRUE",
		"-DLIBUNWIND_ENABLE_SHARED=OFF",
		"-DLIBUNWIND_ENABLE_STATIC=ON",
		"-DLIBCXX_USE_COMPILER_RT=ON",
		"-DLIBCXX_ENABLE_SHARED=OFF",
		"-DLIBCXX_ENABLE_STATIC=ON",
		"-DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=TRUE",
		"-DLIBCXX_CXX_ABI=libcxxabi",
		"-DLIBCXX_LIBDIR_SUFFIX=",
		"-DLIBCXX_INCLUDE_TESTS=FALSE",
		"-DLIBCXX_INCLUDE_BENCHMARKS=FALSE",
		"-DLIBCXX_ENABLE_ABI_LINKER_SCRIPT=FALSE",
		"-DLIBCXXABI_USE_COMPILER_RT=ON",
		"-DLIBCXXABI_USE_LLVM_UNWINDER=ON",
		"-DLIBCXXABI_ENABLE_SHARED=OFF",
		"-DLIBCXXABI_LIBDIR_SUFFIX=",
	];
}

export function cxxConfigureCommand(
	cmake: string, ninja: string, source: string, build: string, install: string,
	bundle: string, layout: CxxLayout, target: string, triple: string,
): EngineCommand {
	const cConfig = "--no-default-config --config=" +
		join(join(bundle, layout.configDir), target + ".cfg");
	const bin = join(bundle, "bin");
	return {
		file: cmake,
		args: [
			"-G", "Ninja", "-DCMAKE_MAKE_PROGRAM=" + ninja,
			"-S", join(source, "runtimes"), "-B", build,
			"-DCMAKE_INSTALL_PREFIX=" + install,
			"-DCMAKE_C_COMPILER=" + join(bin, "clang" + exeSuffix()),
			"-DCMAKE_CXX_COMPILER=" + join(bin, "clang++" + exeSuffix()),
			"-DCMAKE_AR=" + join(bin, "llvm-ar" + exeSuffix()),
			"-DCMAKE_RANLIB=" + join(bin, "llvm-ranlib" + exeSuffix()),
			"-DCMAKE_C_FLAGS=" + cConfig,
			"-DCMAKE_CXX_FLAGS=" + cConfig,
			"-DCMAKE_ASM_FLAGS=" + cConfig,
			...cxxCmakeArguments(target, triple),
		],
	};
}

function exeSuffix(): string {
	return platform == "windows" ? ".exe" : "";
}

export function configTriple(configText: string): Result<string, string> {
	for (const line of configText.split("\n")) {
		const words = line.trim().split(" ");
		if (words.length == 2 && (words[0] == "-target" || words[0] == "--target")) {
			return Result.ok(words[1]);
		}
	}
	return Result.err("the C config names no -target");
}

export function zigReceiptKinds(kinds: string[]): string[] {
	const zig: string[] = [];
	for (const kind of kinds) {
		if (kind.startsWith("local-zig-")) { zig.push(kind); }
	}
	return zig;
}

function receiptKinds(root: string): Result<string[], string> {
	const kinds: string[] = [];
	for (const notices of RECEIPT_ROOTS) {
		const dir = join(root, notices);
		if (!isDir(dir)) { continue; }
		const names = readDirNames(dir);
		if (!names.ok) { return Result.err(names.error.message); }
		for (const name of names.value) {
			if (!name.endsWith(".json")) { continue; }
			const parsed = parseJson(try readUtf8File(join(dir, name)));
			if (!parsed.ok) { return Result.err(join(dir, name) + ": " + parsed.error); }
			const kind = getDynamicField(parsed.value, "kind");
			if (kind.kind == JsonKind.String) { kinds.push(kind.strVal); }
		}
	}
	return Result.ok(kinds);
}

function replaceCxx(
	partial: string, install: string, source: string, layout: CxxLayout,
	receipt: CxxReceipt,
): Result<boolean, string> {
	const configDir = join(partial, layout.configDir);
	const directory = join(configDir, layout.directory);
	try engineIo(removeAll(directory));
	try engineIo(removeAll(join(configDir, "include/cxx")));
	try engineIo(ensureDir(join(directory, "include")));
	try copyBundleTree(join(install, "include"), join(directory, "include"), "c++", []);
	const inputs: CxxInput[] = [];
	for (const archive of layout.archives) {
		const built = join(install, archive.built);
		if (!isFile(built)) { return Result.err("the runtimes build installed no " + archive.built); }
		const to = join(directory, archive.name);
		try copyEngineFile(built, to);
		inputs.push({ name: archive.name, bytes: try engineFileSize(to), sha256: try sha256File(to) });
	}
	for (const alias of layout.aliases) {
		try copyEngineFile(join(directory, alias.target), join(directory, alias.alias));
	}
	for (const config of layout.configs) {
		try writeEngineText(join(configDir, config), cxxConfigText(layout));
	}
	for (const component of COMPONENTS) {
		const notice = "runtime/notices/" + component + "/LICENSE.TXT";
		try engineIo(ensureDir(join(partial, dirname(notice))));
		try copyEngineFile(join(join(source, component), "LICENSE.TXT"), join(partial, notice));
		receipt.notices.push(notice);
	}
	receipt.archives.set(receipt.target, {
		directory: layout.configDir.slice("runtime/".length) + "/" + layout.directory,
		aliases: layout.aliases, inputs,
	});
	try writeEngineText(join(partial, CXX_RECEIPT),
		asciiEngineJson(stringifyPretty(jsonValueOf(receipt), 2)) + "\n");
	const zig = zigReceiptKinds(try receiptKinds(partial));
	if (zig.length == 0 && isDir(join(partial, ZIG_NOTICE))) {
		try engineIo(removeAll(join(partial, ZIG_NOTICE)));
		return Result.ok(true);
	}
	return Result.ok(false);
}

export function prepareCxxRuntime(request: CxxRuntimeRequest): Result<CxxRuntimeResult, string> {
	const bundle = try absoluteEnginePath(request.bundle);
	const tarball = try existingFile("--source-tarball", request.tarball);
	const cmake = try existingFile("--cmake", request.cmake);
	const ninja = try existingFile("--ninja", request.ninja);
	const work = try absoluteEnginePath(request.work);
	const output = try absoluteEnginePath(request.output);
	const version = try llvmSourceVersion(tarball);
	if (!isSha256Hex(request.sha256)) {
		return Result.err("--source-sha256 must be 64 lowercase hex digits");
	}
	if (request.jobs < 1) { return Result.err("--jobs must be at least 1"); }
	const layout = try cxxLayout(request.target);
	const contract = try verifyEngineContract(bundle);
	if (contract.version != version) {
		return Result.err(bundle + " is LLVM " + contract.version + ", the source is " + version);
	}
	try refuseExisting(output);
	const inside = containsExistingRoot(bundle, dirname(output));
	if (!inside.ok) { return Result.err(inside.error.message); }
	if (inside.value) { return Result.err("output must not be inside " + bundle); }
	const cConfig = join(join(bundle, layout.configDir), request.target + ".cfg");
	const triple = try configTriple(try readUtf8File(cConfig));
	const actual = try sha256File(tarball);
	if (actual != request.sha256) {
		return Result.err(tarball + ": sha256 " + actual + ", expected " + request.sha256);
	}
	env.set("PATH", pathWithToolDir(ninja, env.get("PATH") ?? "", platform));
	const source = try extractLlvmSource(tarball, version, work);
	const build = join(work, "cxx-build-" + request.target);
	const install = join(work, "cxx-install-" + request.target);
	try engineIo(removeAll(build));
	try engineIo(removeAll(install));
	const configure = cxxConfigureCommand(cmake, ninja, source, build, install, bundle,
		layout, request.target, triple);
	try runCommand(configure);
	try runCommand({ file: ninja, args: ["-C", build, "-j" + String(request.jobs), "install"] });
	const receipt: CxxReceipt = {
		kind: CXX_RECEIPT_KIND,
		engineVersion: version,
		target: request.target,
		statement: "libc++, libc++abi and libunwind built from the named llvm-project release source " +
			"by the bundle's own clang against its " + request.target + " C runtime; no Zig. " +
			"Not an upstream-published build.",
		source: { llvmVersion: version, sourceSha256: request.sha256, sourceTarball: basename(tarball) },
		cmakeArguments: cxxCmakeArguments(request.target, triple),
		archives: new Map<string, CxxTargetRecord>(),
		notices: [],
		redistributionCertified: false,
	};
	const partial = try claimPartial(output);
	const staged = stage(bundle, partial, install, source, layout, receipt, contract);
	if (!staged.ok) {
		const cleaned = removeAll(partial);
		return Result.err(staged.error + (cleaned.ok ? "" : "; partial cleanup failed: " + cleaned.error.message));
	}
	const published = renameNoReplace(partial, output);
	if (!published.ok) {
		const cleaned = removeAll(partial);
		return Result.err(published.error.message + (cleaned.ok ? "" :
			"; partial cleanup failed: " + cleaned.error.message));
	}
	return Result.ok({ ...staged.value, output });
}

function stage(
	bundle: string, partial: string, install: string, source: string, layout: CxxLayout,
	receipt: CxxReceipt, contract: EngineContract,
): Result<CxxRuntimeResult, string> {
	try copyBundleTree(bundle, partial, "", CONTRACT);
	const removedZigNotice = try replaceCxx(partial, install, source, layout, receipt);
	try writeEngineContract(partial, contract.host, contract.version);
	return Result.ok({ output: "", contract: try verifyEngineContract(partial), removedZigNotice });
}

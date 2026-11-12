import { arch, platform } from "std/process";
import {
	chmod, dirname, ensureDir, isDir, isExecutable, isFile, isLinkLike, join,
	readDirNames, removeAll, symlink,
} from "std/fs";
import { IoErrorKind } from "std/io/errors";
import { jsonValueOf } from "std/serialize/json";
import { stringifyPretty } from "std/serialize/json/stringify";
import { sha256File } from "./fileDigest";
import { readUtf8File } from "./textFile";
import { captureToolUtf8 } from "./processCapture";
import { containsExistingRoot } from "./nativePath";
import { isSymbolicLink, verifyStoredRelativeTarget } from "./nativeAlias";
import { renameNoReplace } from "./nativePublication";
import { auditWindowsBinaries, claimPartial, windowsTools } from "./windowsEngine";
import { SourceProvenance, digitsOnly } from "./sourceEngine";
import {
	EngineContract, absoluteEnginePath, copyEngineFile, copyOnceByContent, engineFileSize,
	engineIo, verifyEngineContract, writeEngineContract, writeEngineText,
} from "./engineFiles";

const MULTICALL = "llvm";
const LICENSED: string[4] = ["llvm", "clang", "lld", "compiler-rt"];
const RECEIPT = "notices/provenance.json";
const GAPS = [
	"The engine links the host's C/C++ runtime and system libraries; their " +
	"redistribution audit is not completed.",
	"Third-party code under each component's LICENSE.TXT is listed there, " +
	"not audited file by file.",
];

export struct EngineNotice {
	component: string;
	copy: string;
	sha256: string;
}

export struct SourceEngineReceipt {
	clangVersion: string;
	host: string;
	kind: string;
	licenses: EngineNotice[];
	lldVersion: string;
	noticeGaps: string[];
	redistributionCertified: boolean;
	source: SourceProvenance;
}

export struct PackagedEngine {
	output: string;
	contract: EngineContract;
}

export function engineHostKey(os: string, cpu: string): Result<string, string> {
	const system = match (os) {
		"darwin" => "macos",
		"macos" => "macos",
		"linux" => "linux",
		"windows" => "windows",
		_ => "",
	};
	const machine = match (cpu) {
		"arm64" => "aarch64",
		"aarch64" => "aarch64",
		"amd64" => "x86_64",
		"x86_64" => "x86_64",
		_ => "",
	};
	if (system == "" || machine == "") {
		return Result.err("no source engine packaging for " + os + "/" + cpu);
	}
	return Result.ok(machine + "-" + system);
}

// macOS builds link sanitizers from the engine (always shared, so each has its dylib); Linux
// builds take them from the runtime's glibc 2.31 sysroot, and these per-target copies would win.
// On ELF a sanitized link without the archive's .syms exports every symbol.
export function resourceLibraries(host: string, major: string): string[] {
	if (host.endsWith("-windows")) { return []; }
	if (host.endsWith("-macos")) {
		const darwin = "lib/clang/" + major + "/lib/darwin/libclang_rt.";
		return ["osx.a", "ubsan_minimal_osx_dynamic.dylib", "ubsan_osx_dynamic.dylib",
			"asan_osx_dynamic.dylib", "tsan_osx_dynamic.dylib"].map(
			(name: string): string => darwin + name);
	}
	const triple = "lib/clang/" + major + "/lib/" + host.slice(0, host.indexOf("-")) +
		"-unknown-linux-gnu/libclang_rt.";
	return ["builtins.a", "ubsan_minimal.a", "ubsan_minimal.a.syms"].map(
		(name: string): string => triple + name);
}

export function requiredResources(host: string, major: string): string[] {
	return ["lib/clang/" + major + "/include/stddef.h", ...resourceLibraries(host, major)];
}

function toolFile(host: string, tool: string): string {
	return host.endsWith("-windows") ? tool + ".exe" : tool;
}

export function linkerTool(host: string): string {
	return toolFile(host, host.endsWith("-macos") ? "ld64.lld" : "ld.lld");
}

export function requiredTools(host: string): string[] {
	if (host.endsWith("-windows")) { return windowsTools(); }
	return ["clang", "clang++", "llvm-ar", "llvm-nm", "llvm-objcopy", linkerTool(host)];
}

export function llvmTreeVersion(cmakeText: string): Result<string, string> {
	const parts: string[] = [];
	for (const name of ["MAJOR", "MINOR", "PATCH"]) {
		const marker = "set(LLVM_VERSION_" + name + " ";
		const at = cmakeText.indexOf(marker);
		const end = at < 0 ? -1 : cmakeText.indexOf(")", at);
		const digits = end < 0 ? "" :
			cmakeText.slice(at + marker.length, end).trim();
		if (!digitsOnly(digits)) {
			return Result.err("LLVMVersion.cmake names no LLVM_VERSION_" + name);
		}
		parts.push(digits);
	}
	return Result.ok(parts.join("."));
}

export function toolVersionLine(
	output: string, prefix: string,
): Result<string, string> {
	const at = output.indexOf(prefix);
	if (at < 0) { return Result.err("no '" + prefix + "' in: " + output.trim()); }
	let end = at + prefix.length;
	while (end < output.length) {
		const c = output.charAt(end);
		if ((c < "0" || c > "9") && c != ".") { break; }
		end += 1;
	}
	const version = output.slice(at + prefix.length, end);
	return version == "" ? Result.err("no version after '" + prefix + "'") :
		Result.ok(version);
}

function toolVersion(
	path: string, prefix: string,
): Result<string, string> {
	const done = try captureToolUtf8(path, ["--version"]);
	if (done.returnCode != 0) {
		return Result.err(path + " --version failed (rc=" +
			String(done.returnCode) + "): " + done.errorOutput.trim());
	}
	return toolVersionLine(done.output, prefix);
}

function copyInstall(
	install: string, partial: string, rel: string, libraryDir: string,
	libraries: string[],
): Result<void, string> {
	const source = rel == "" ? install : join(install, rel);
	const names = readDirNames(source);
	if (!names.ok) { return Result.err(names.error.message); }
	const stored = new Map<string, string>();
	const digests = new Map<string, string>();
	for (const name of names.value) {
		const child = rel == "" ? name : rel + "/" + name;
		const from = join(install, child);
		const to = join(partial, child);
		const linked = isLinkLike(from);
		if (!linked.ok) { return Result.err(linked.error.message); }
		if (linked.value) {
			const symbolic = isSymbolicLink(from);
			if (!symbolic.ok || !symbolic.value || dirname(child) != "bin") {
				return Result.err("install link outside bin/: " + child);
			}
			const stored = verifyStoredRelativeTarget(from, MULTICALL);
			if (!stored.ok) {
				return Result.err(child + " is not an alias of bin/" + MULTICALL);
			}
			try engineIo(symlink(MULTICALL, to));
			continue;
		}
		if (isDir(from)) {
			try engineIo(ensureDir(to));
			try copyInstall(install, partial, child, libraryDir, libraries);
			continue;
		}
		if (!isFile(from)) { return Result.err("not a regular file: " + child); }
		if (child.startsWith(libraryDir) && !libraries.includes(child)) {
			continue;
		}
		if (rel == "bin") { try copyOnceByContent(from, to, stored, digests); }
		else { try copyEngineFile(from, to); }
		try engineIo(chmod(to, isExecutable(from) ? 0o755 : 0o644));
	}
	return Result.ok(null);
}

function copyNotices(
	source: string, partial: string,
): Result<EngineNotice[], string> {
	const notices: EngineNotice[] = [];
	for (const component of LICENSED) {
		const license = join(join(source, component), "LICENSE.TXT");
		const bytes = isFile(license) ? try engineFileSize(license) : 0;
		if (bytes == 0) {
			return Result.err("source tree has no " + component + "/LICENSE.TXT");
		}
		const copy = "notices/" + component + "/LICENSE.TXT";
		try copyEngineFile(license, join(partial, copy));
		notices.push({ component, copy, sha256: try sha256File(license) });
	}
	return Result.ok(notices);
}

function stage(
	install: string, source: string, partial: string, host: string,
	provenance: SourceProvenance,
): Result<EngineContract, string> {
	const version = provenance.llvmVersion;
	const major = version.split(".")[0];
	try copyInstall(install, partial, "", "lib/clang/" + major + "/lib/",
		resourceLibraries(host, major));
	for (const tool of requiredTools(host)) {
		const path = join(partial, "bin/" + tool);
		if (!isFile(path) || !isExecutable(path)) {
			return Result.err("install lacks executable bin/" + tool);
		}
	}
	for (const rel of requiredResources(host, major)) {
		if (!isFile(join(partial, rel))) {
			return Result.err("install lacks " + rel);
		}
	}
	if (host.endsWith("-windows")) {
		try auditWindowsBinaries(partial, host, join(partial, "bin/llvm-readobj.exe"));
	}
	const clang = try toolVersion(join(partial, "bin/" + toolFile(host, "clang")),
		"clang version ");
	const lld = try toolVersion(join(partial, "bin/" + linkerTool(host)), "LLD ");
	if (clang != version || lld != version) {
		return Result.err("engine reports clang " + clang + " and lld " + lld +
			", its provenance LLVM " + version);
	}
	const receipt: SourceEngineReceipt = {
		clangVersion: clang, host, kind: "local-source-engine-proof",
		licenses: try copyNotices(source, partial), lldVersion: lld,
		noticeGaps: GAPS, redistributionCertified: false, source: provenance,
	};
	try writeEngineText(join(partial, RECEIPT),
		stringifyPretty(jsonValueOf(receipt), 2) + "\n");
	try writeEngineContract(partial, host, version);
	return verifyEngineContract(partial);
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

export function packageSourceEngine(
	installPath: string, sourcePath: string, outputPath: string,
): Result<PackagedEngine, string> {
	const host = try engineHostKey(platform, arch);
	const install = try absoluteEnginePath(installPath);
	const source = try absoluteEnginePath(sourcePath);
	const output = try absoluteEnginePath(outputPath);
	try refuseExisting(output);
	const inside = containsExistingRoot(install, dirname(output));
	if (!inside.ok) { return Result.err(inside.error.message); }
	if (inside.value) { return Result.err("output must not be inside the install"); }
	const provenance = try JSON.parse<SourceProvenance>(
		try readUtf8File(join(install, "PROVENANCE.json")));
	const treeVersion = try llvmTreeVersion(try readUtf8File(
		join(source, "cmake/Modules/LLVMVersion.cmake")));
	if (treeVersion != provenance.llvmVersion) {
		return Result.err("source tree is LLVM " + treeVersion +
			", the install was built from " + provenance.llvmVersion);
	}
	for (const edit of provenance.sourceEdits) {
		const actual = try sha256File(join(source, edit.file));
		if (actual != edit.sha256) {
			return Result.err(join(source, edit.file) + " is not the edited file the install " +
				"was built from: sha256 " + actual + ", expected " + edit.sha256);
		}
	}
	const partial = try claimPartial(output);
	const staged = stage(install, source, partial, host, provenance);
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
	return Result.ok({ output, contract: staged.value });
}

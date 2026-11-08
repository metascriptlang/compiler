import {
	join, dirname, isDir, isFile, isLinkLike, readDirNames, ensureDir, remove,
	removeAll, copyFile, symlink,
} from "std/fs";
import { platform } from "std/process";
import { IoErrorKind } from "std/io/errors";
import { parseJson, JsonValue, JsonKind } from "std/serialize/json";
import { jsonString, jsonObject, jsonArray, jsonInt } from "std/serialize/json/builder";
import { getDynamicField, setDynamicField, at, length } from "std/serialize/json/accessors";
import { stringifyPretty } from "std/serialize/json/stringify";
import { sha256File } from "./fileDigest";
import { readUtf8File } from "./textFile";
import { captureToolUtf8 } from "./processCapture";
import { renameNoReplace } from "./nativePublication";
import { verifyStoredRelativeTarget } from "./nativeAlias";
import {
	FileLinks, absoluteEnginePath, engineIo, inventoryTree, writeEngineText,
	writeEngineContract, verifyEngineContract,
} from "./engineFiles";
import { claimPartial, asciiEngineJson } from "./windowsEngine";
import {
	WINDOWS_RUNTIME_KIND, WINDOWS_RUNTIME_RECEIPT, childEnvironment,
	checkWindowsRuntime,
} from "./windowsRuntime";

const WINDOWS = "runtime/windows/";
const SANITIZER_RECEIPT = "notices/sanitizer-provenance.json";
const BUNDLE_RECEIPT = "notices/bundle-provenance.json";
const CPP_RECEIPT = "runtime/notices/cpp-provenance.json";

export struct SupersededFile {
	path: string;
	previousSha256: string;
	sha256: string;
}

export struct WindowsRuntimeReplaced {
	output: string;
	identity: string;
	kept: int32;
	removed: int32;
	added: int32;
	superseded: SupersededFile[];
}

function readJson(path: string): Result<JsonValue, string> {
	const parsed = parseJson(try readUtf8File(path));
	if (!parsed.ok) { return Result.err(path + ": " + parsed.error); }
	return Result.ok(parsed.value);
}

function field(value: JsonValue, key: string): string {
	return getDynamicField(value, key).asString("");
}

// {bundle path of an alias: its sibling target} from the C++ receipt, the only links a bundle holds.
function cppAliases(bundle: string): Result<Map<string, string>, string> {
	const aliases = new Map<string, string>();
	if (!isFile(join(bundle, CPP_RECEIPT))) { return Result.ok(aliases); }
	const archives = getDynamicField(try readJson(join(bundle, CPP_RECEIPT)), "archives");
	if (archives.kind != JsonKind.Object) { return Result.ok(aliases); }
	for (const target of archives.values) {
		const directory = "runtime/" + field(target, "directory").replaceAll("\\", "/");
		const listed = getDynamicField(target, "aliases");
		for (let i: int32 = 0; i < length(listed); i += 1) {
			const alias = at(listed, i);
			aliases.set(directory + "/" + field(alias, "alias"), field(alias, "target"));
		}
	}
	return Result.ok(aliases);
}

// Copy the bundle file by file; a link is made again from its C++ receipt record after its stored target is
// checked, so the clone holds the same links and no copy of a link's target.
function copyBundle(
	source: string, target: string, aliases: Map<string, string>,
): Result<void, string> {
	for (const rel of try inventoryTree(source, FileLinks.ContainedFiles)) {
		const from = join(source, rel);
		const to = join(target, rel);
		try engineIo(ensureDir(dirname(to)));
		const linked = isLinkLike(from);
		if (!linked.ok) { return Result.err(linked.error.message); }
		if (!linked.value) {
			try engineIo(copyFile(from, to));
			continue;
		}
		const alias = aliases.get(rel);
		if (alias == null) { return Result.err(rel + " is a link no receipt records"); }
		try engineIo(verifyStoredRelativeTarget(from, alias));
		try engineIo(symlink(alias, to));
	}
	return Result.ok(null);
}

// The runtime/windows files another receipt owns: the C++ runtime's `.cxx` directories and configs, and the files
// the sanitizer receipt names for a Windows target. They outlive a replacement of the C runtime.
function keptFiles(bundle: string, files: string[]): Result<string[], string> {
	const kept: string[] = [];
	for (const rel of files) {
		const top = rel.split("/")[0];
		if (top.endsWith(".cxx") || top.endsWith(".cxx.cfg")) { kept.push(rel); }
	}
	const receipt = join(bundle, SANITIZER_RECEIPT);
	if (!isFile(receipt)) { return Result.ok(kept); }
	const targets = getDynamicField(try readJson(receipt), "targets");
	for (let i: int32 = 0; i < length(targets); i += 1) {
		const target = at(targets, i);
		if (!field(target, "triple").endsWith("-windows-gnu")) { continue; }
		const directories = getDynamicField(target, "directories");
		const owned = getDynamicField(target, "files");
		for (let d: int32 = 0; d < length(directories); d += 1) {
			const directory = at(directories, d).asString("").replaceAll("\\", "/");
			if (!directory.startsWith(WINDOWS)) {
				return Result.err(SANITIZER_RECEIPT + " names " + directory + " outside " + WINDOWS);
			}
			for (let f: int32 = 0; f < length(owned); f += 1) {
				const rel = directory.slice(WINDOWS.length, directory.length) + "/" +
					field(at(owned, f), "name");
				if (files.indexOf(rel) < 0) {
					return Result.err(SANITIZER_RECEIPT + " names " + WINDOWS + rel + ", which the bundle lacks");
				}
				kept.push(rel);
			}
		}
	}
	return Result.ok(kept);
}

// Remove every runtime/windows file that is not kept, and each directory left empty.
function removeOwned(windows: string, kept: string[]): Result<int32, string> {
	let removed: int32 = 0;
	const names = readDirNames(windows);
	if (!names.ok) { return Result.err(names.error.message); }
	for (const name of names.value) {
		const path = join(windows, name);
		const keepsAny = kept.some((rel: string): boolean => rel == name || rel.startsWith(name + "/"));
		if (!keepsAny) {
			removed += isDir(path) ? (try inventoryTree(path, FileLinks.Refuse)).length : 1;
			try engineIo(removeAll(path));
			continue;
		}
		if (!isDir(path) || name.endsWith(".cxx")) { continue; }
		for (const rel of try inventoryTree(path, FileLinks.Refuse)) {
			if (kept.indexOf(name + "/" + rel) < 0) {
				try engineIo(remove(join(path, rel)));
				removed += 1;
			}
		}
	}
	return Result.ok(removed);
}

function definedSymbols(nm: string, archive: string): Result<string[], string> {
	const done = captureToolUtf8(nm, ["--defined-only", "--extern-only", "--format=just-symbols", archive]);
	if (!done.ok) { return Result.err(done.error); }
	if (done.value.returnCode != 0) { return Result.err("llvm-nm " + archive + ": " + done.value.errorOutput); }
	return Result.ok(done.value.output.split("\n").filter((l: string): boolean => l != "" && !l.endsWith(":")));
}

// A kept file the new runtime also ships is replaced by the runtime's only when the runtime's archive defines every
// symbol the kept one did; any other collision is refused.
function supersede(
	nm: string, rel: string, kept: string, incoming: string,
): Result<SupersededFile, string> {
	const old = try definedSymbols(nm, kept);
	const fresh = try definedSymbols(nm, incoming);
	const missing = old.filter((s: string): boolean => fresh.indexOf(s) < 0);
	if (old.length == 0 || missing.length > 0) {
		return Result.err(rel + " differs from the file another receipt owns and lacks " +
			(missing.length > 0 ? missing.join(", ") : "any symbol"));
	}
	return Result.ok({ path: rel, previousSha256: try sha256File(kept), sha256: try sha256File(incoming) });
}

function mergeOverlay(
	overlay: string, partial: string, keptPaths: string[], nm: string,
): Result<SupersededFile[], string> {
	const superseded: SupersededFile[] = [];
	for (const rel of try inventoryTree(overlay, FileLinks.Refuse)) {
		const source = join(overlay, rel);
		const target = join(partial, rel);
		if (isLinkLike(target).ok) {
			if ((try sha256File(source)) == (try sha256File(target))) { continue; }
			if (!rel.startsWith(WINDOWS) || keptPaths.indexOf(rel.slice(WINDOWS.length, rel.length)) < 0) {
				return Result.err("the bundle already has a different " + rel);
			}
			superseded.push(try supersede(nm, rel, target, source));
		}
		try engineIo(ensureDir(dirname(target)));
		try engineIo(copyFile(source, target));
	}
	return Result.ok(superseded);
}

function recordReplacement(
	partial: string, previousIdentity: string, previousKind: string, previousSha256: string,
	overlayReceipt: string, superseded: SupersededFile[],
): Result<void, string> {
	const path = join(partial, BUNDLE_RECEIPT);
	const receipt = try readJson(path);
	if (receipt.kind != JsonKind.Object) { return Result.err(BUNDLE_RECEIPT + " is not an object"); }
	const records: JsonValue[] = [];
	for (const file of superseded) {
		records.push(jsonObject(["path", "previousSha256", "sha256"],
			[jsonString(file.path), jsonString(file.previousSha256), jsonString(file.sha256)]));
	}
	setDynamicField(receipt, "baseBundleIdentity", jsonString(previousIdentity));
	setDynamicField(receipt, "windowsRuntimeProvenance", jsonString(WINDOWS_RUNTIME_RECEIPT));
	setDynamicField(receipt, "windowsRuntimeReplaced", jsonObject(
		["previousKind", "previousReceiptSha256", "receiptSha256", "superseded", "supersededCount"],
		[jsonString(previousKind), jsonString(previousSha256), jsonString(try sha256File(overlayReceipt)),
			jsonArray(records), jsonInt(superseded.length as int64)]));
	return writeEngineText(path, asciiEngineJson(stringifyPretty(receipt, 2)) + "\n");
}

function assemble(
	bundle: string, overlay: string, partial: string, host: string, version: string, identity: string,
): Result<WindowsRuntimeReplaced, string> {
	const previous = join(bundle, WINDOWS_RUNTIME_RECEIPT);
	const previousKind = field(try readJson(previous), "kind");
	const files = try inventoryTree(join(bundle, "runtime/windows"), FileLinks.ContainedFiles);
	const kept = try keptFiles(bundle, files);
	try copyBundle(bundle, partial, try cppAliases(bundle));
	const removed = try removeOwned(join(partial, "runtime/windows"), kept);
	const nm = join(bundle, platform == "windows" ? "bin/llvm-nm.exe" : "bin/llvm-nm");
	const superseded = try mergeOverlay(overlay, partial, kept, nm);
	try recordReplacement(partial, identity, previousKind, try sha256File(previous),
		join(overlay, WINDOWS_RUNTIME_RECEIPT), superseded);
	try writeEngineContract(partial, host, version);
	const contract = try verifyEngineContract(partial);
	return Result.ok({
		output: "", identity: contract.identity, kept: kept.length, removed,
		added: (try inventoryTree(overlay, FileLinks.Refuse)).length, superseded,
	});
}

// Clone the verified bundle with its Windows C runtime replaced by the overlay of prepareWindowsRuntime. The C++
// runtime's files and the sanitizer's Windows archives stay; the contract is rewritten over every file.
export function replaceWindowsRuntime(
	bundlePath: string, overlayPath: string, outputPath: string,
): Result<WindowsRuntimeReplaced, string> {
	const bundle = try absoluteEnginePath(bundlePath);
	const overlay = try absoluteEnginePath(overlayPath);
	const output = try absoluteEnginePath(outputPath);
	if (isLinkLike(output).ok) { return Result.err("output " + output + " exists; it is never replaced"); }
	const contract = try verifyEngineContract(bundle);
	if (!isFile(join(bundle, WINDOWS_RUNTIME_RECEIPT))) {
		return Result.err("bundle " + bundle + " has no Windows runtime to replace");
	}
	const incoming = try readJson(join(overlay, WINDOWS_RUNTIME_RECEIPT));
	if (field(incoming, "kind") != WINDOWS_RUNTIME_KIND) {
		return Result.err("overlay " + overlay + " is a " + field(incoming, "kind") + ", not a " + WINDOWS_RUNTIME_KIND);
	}
	if (field(incoming, "engineVersion") != contract.version) {
		return Result.err("overlay is for LLVM " + field(incoming, "engineVersion") + ", the bundle is " + contract.version);
	}
	const partial = try claimPartial(output);
	const done = assemble(bundle, overlay, partial, contract.host, contract.version, contract.identity);
	if (!done.ok) {
		removeAll(partial);
		return done;
	}
	const published = renameNoReplace(partial, output);
	if (!published.ok) {
		removeAll(partial);
		return Result.err(published.error.kind == IoErrorKind.AlreadyExists ?
			"output " + output + " exists; it is never replaced" : published.error.message);
	}
	return Result.ok({ ...done.value, output });
}

function runProgram(path: string, work: string): Result<string, string> {
	const done = captureToolUtf8(path, [], { env: childEnvironment(work), mergeStderr: true });
	if (!done.ok) { return Result.err(path + ": " + done.error); }
	return Result.ok("rc=" + String(done.value.returnCode) + " " + done.value.output.trim());
}

// On a Windows host: link through the bundle's configs and run a C program, a DLL consumer's C++ program and a UBSan
// fault. Returns one line per program.
export function runWindowsBundle(bundle: string, fixtures: string, work: string): Result<string[], string> {
	if (platform != "windows") { return Result.err("running the Windows runtime needs a Windows host"); }
	const clang = join(bundle, "bin/clang.exe");
	const windows = join(bundle, "runtime/windows");
	const lines: string[] = [];
	for (const path of try checkWindowsRuntime(clang, windows, fixtures, work)) {
		if (path.endsWith(".exe")) {
			const ran = try runProgram(path, work);
			if (!ran.startsWith("rc=0 ok status=0 started=0")) { return Result.err(path + " " + ran); }
			lines.push("C " + ran);
		}
	}
	const base = ["--no-default-config", "--config", join(windows, "x86_64-windows-gnu.cfg")];
	const cpp = join(work, "cpp.exe");
	const cppArgs = ["--no-default-config", "--config", join(windows, "x86_64-windows-gnu.cxx.cfg"),
		"--config", join(windows, "x86_64-windows-gnu.cfg"), "-std=c++20", "-O2",
		join(fixtures, "runtimeCpp.cpp"), "-o", cpp];
	const cppBuilt = captureToolUtf8(join(bundle, "bin/clang++.exe"), cppArgs, { env: childEnvironment(work) });
	if (!cppBuilt.ok || cppBuilt.value.returnCode != 0) {
		return Result.err("C++ link: " + (cppBuilt.ok ? cppBuilt.value.errorOutput : cppBuilt.error));
	}
	const cppRan = try runProgram(cpp, work);
	if (!cppRan.startsWith("rc=0 cpp sum=")) { return Result.err("C++ program " + cppRan); }
	lines.push("C++ " + cppRan);
	const ubsan = join(work, "ubsan.exe");
	const ubsanBuilt = captureToolUtf8(clang, [...base, "-fsanitize=undefined", "-g", "-O1",
		join(fixtures, "sanitizerSignedOverflow.c"), "-o", ubsan], { env: childEnvironment(work) });
	if (!ubsanBuilt.ok || ubsanBuilt.value.returnCode != 0) {
		return Result.err("UBSan link: " + (ubsanBuilt.ok ? ubsanBuilt.value.errorOutput : ubsanBuilt.error));
	}
	const ubsanRan = try runProgram(ubsan, work);
	if (ubsanRan.indexOf("runtime error: signed integer overflow") < 0) { return Result.err("UBSan " + ubsanRan); }
	lines.push("UBSan reported: " + ubsanRan.split("\n")[0]);
	return Result.ok(lines);
}

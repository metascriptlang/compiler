import { arch, platform } from "std/process";
import {
	chmod, dirname, ensureDir, isDir, isExecutable, isFile, isLinkLike, join,
	readDirNames, removeAll, symlink,
} from "std/fs";
import { parseJson, JsonValue, JsonKind } from "std/serialize/json";
import { getDynamicField, setDynamicField } from "std/serialize/json/accessors";
import { jsonArrayOfStrings, jsonString } from "std/serialize/json/builder";
import { stringifyPretty } from "std/serialize/json/stringify";
import { sha256File } from "./fileDigest";
import { readUtf8File } from "./textFile";
import { containsExistingRoot } from "./nativePath";
import { isSymbolicLink, readStoredSiblingName } from "./nativeAlias";
import { renameNoReplace } from "./nativePublication";
import { asciiEngineJson, claimPartial } from "./windowsEngine";
import { engineHostKey } from "./sourceEnginePackage";
import { runtimeLibrariesLast } from "./runtimeConfig";
import {
	EngineContract, absoluteEnginePath, copyEngineFile, copyOnceByContent, engineIo,
	verifyEngineContract, writeEngineContract, writeEngineText,
} from "./engineFiles";

const RECEIPT = "notices/bundle-provenance.json";
const CONTRACT: string[] = ["HOST", "VERSION", "FILES.sha256", "IDENTITY"];

export struct AssembledBundle {
	output: string;
	contract: EngineContract;
	targetRuntimeDirectories: string[];
}

// The -target triples the runtime's top-level configs name for Linux, the spelling clang
// looks up its per-target runtime directory by.
export function linuxConfigTriples(configTexts: string[]): string[] {
	const triples: string[] = [];
	for (const text of configTexts) {
		for (const line of text.split("\n")) {
			const words = line.trim().split(" ");
			if (words.length != 2 || (words[0] != "-target" && words[0] != "--target")) {
				continue;
			}
			if (words[1].indexOf("-linux") > 0 && !triples.includes(words[1])) {
				triples.push(words[1]);
			}
		}
	}
	triples.sort();
	return triples;
}

export function copyBundleTree(
	source: string, target: string, rel: string, skipTop: string[],
): Result<void, string> {
	const names = readDirNames(rel == "" ? source : join(source, rel));
	if (!names.ok) { return Result.err(names.error.message); }
	const stored = new Map<string, string>();
	for (const name of names.value) {
		if (rel == "" && skipTop.includes(name)) { continue; }
		const child = rel == "" ? name : rel + "/" + name;
		const from = join(source, child);
		const to = join(target, child);
		const linked = isLinkLike(from);
		if (!linked.ok) { return Result.err(linked.error.message); }
		if (linked.value) {
			const symbolic = isSymbolicLink(from);
			if (!symbolic.ok || !symbolic.value) {
				return Result.err("not a symbolic link: " + child);
			}
			const sibling = readStoredSiblingName(from);
			if (!sibling.ok) { return Result.err(sibling.error.message); }
			try engineIo(symlink(sibling.value, to));
			continue;
		}
		if (isDir(from)) {
			try engineIo(ensureDir(to));
			try copyBundleTree(source, target, child, skipTop);
			continue;
		}
		if (!isFile(from)) { return Result.err("not a regular file: " + child); }
		if (rel == "bin") { try copyOnceByContent(from, to, stored); }
		else { try copyEngineFile(from, to); }
		try engineIo(chmod(to, isExecutable(from) ? 0o755 : 0o644));
	}
	return Result.ok(null);
}

function readJson(path: string): Result<JsonValue, string> {
	const parsed = parseJson(try readUtf8File(path));
	if (!parsed.ok) { return Result.err(path + ": " + parsed.error); }
	if (parsed.value.kind != JsonKind.Object) { return Result.err(path + " is not an object"); }
	return Result.ok(parsed.value);
}

function addTargetRuntimeDirectories(
	partial: string, host: string, major: string,
): Result<string[], string> {
	if (!host.endsWith("-linux")) { return Result.ok([]); }
	const texts: string[] = [];
	const runtime = join(partial, "runtime");
	const names = readDirNames(runtime);
	if (!names.ok) { return Result.err(names.error.message); }
	for (const name of names.value) {
		if (name.endsWith(".cfg") && isFile(join(runtime, name))) {
			texts.push(try readUtf8File(join(runtime, name)));
		}
	}
	const libraries = "lib/clang/" + major + "/lib/";
	const engineTriple = host.slice(0, host.indexOf("-")) + "-unknown-linux-gnu";
	const made: string[] = [];
	for (const triple of linuxConfigTriples(texts)) {
		if (triple == engineTriple) { continue; }
		const directory = libraries + triple;
		try copyBundleTree(join(partial, libraries + engineTriple), join(partial, directory), "", []);
		made.push(directory);
	}
	return Result.ok(made);
}

function firstDiffering(source: string, target: string, rel: string): Result<string, string> {
	const names = readDirNames(rel == "" ? source : join(source, rel));
	if (!names.ok) { return Result.err(names.error.message); }
	for (const name of names.value) {
		const child = rel == "" ? name : rel + "/" + name;
		if (isDir(join(source, child))) {
			const found = try firstDiffering(source, target, child);
			if (found != "") { return Result.ok(found); }
		} else if (isLinkLike(join(target, child)).ok) {
			if (!isFile(join(target, child)) ||
				(try sha256File(join(target, child))) != (try sha256File(join(source, child)))) {
				return Result.ok(child);
			}
		}
	}
	return Result.ok("");
}

function addOverlays(partial: string, overlays: string[]): Result<void, string> {
	for (const overlay of overlays) {
		if (!isDir(join(overlay, "runtime"))) { return Result.err(overlay + " has no runtime/"); }
		const taken = try firstDiffering(overlay, partial, "");
		if (taken != "") {
			return Result.err("overlay " + overlay + " would replace " + taken);
		}
		try copyBundleTree(overlay, partial, "", []);
	}
	return Result.ok(null);
}

function orderRuntimeLibraries(partial: string): Result<void, string> {
	const runtime = join(partial, "runtime");
	const names = readDirNames(runtime);
	if (!names.ok) { return Result.err(names.error.message); }
	for (const name of names.value) {
		const path = join(runtime, name);
		if (!name.endsWith(".cfg") || !isFile(path)) { continue; }
		const text = try readUtf8File(path);
		const ordered = runtimeLibrariesLast(text);
		if (ordered != text) { try writeEngineText(path, ordered); }
	}
	return Result.ok(null);
}

function writeReceipt(
	partial: string, runtimeBundle: string, engineIdentity: string,
	runtimeIdentity: string, host: string, version: string, directories: string[],
): Result<void, string> {
	const receipt = try readJson(join(runtimeBundle, RECEIPT));
	if (getDynamicField(receipt, "overlays").kind != JsonKind.Null) {
		return Result.err(RECEIPT + " of " + runtimeBundle +
			" lists bundle overlays, which an engine swap does not carry");
	}
	setDynamicField(receipt, "statement", jsonString("Engine copied unchanged, " +
		"runtime/ copied from the runtime bundle, with the libraries its top-level configs " +
		"name moved behind the inputs of the build; the contract files were rewritten " +
		"over the whole bundle. Not an upstream-controlled build."));
	setDynamicField(receipt, "host", jsonString(host));
	setDynamicField(receipt, "engineVersion", jsonString(version));
	setDynamicField(receipt, "sourceEngineIdentity", jsonString(engineIdentity));
	setDynamicField(receipt, "engineProvenanceSha256",
		jsonString(try sha256File(join(partial, "notices/provenance.json"))));
	setDynamicField(receipt, "runtimeBundleIdentity", jsonString(runtimeIdentity));
	setDynamicField(receipt, "targetRuntimeDirectories", jsonArrayOfStrings(directories));
	return writeEngineText(join(partial, RECEIPT),
		asciiEngineJson(stringifyPretty(receipt, 2)) + "\n");
}

function stage(
	engine: string, runtimeBundle: string, partial: string,
	engineContract: EngineContract, runtimeContract: EngineContract, overlays: string[],
): Result<AssembledBundle, string> {
	try copyBundleTree(engine, partial, "", CONTRACT);
	if (!isDir(join(runtimeBundle, "runtime"))) {
		return Result.err(runtimeBundle + " has no runtime/");
	}
	try engineIo(ensureDir(join(partial, "runtime")));
	try copyBundleTree(join(runtimeBundle, "runtime"), join(partial, "runtime"), "", []);
	try orderRuntimeLibraries(partial);
	const host = engineContract.host;
	const version = engineContract.version;
	const directories = try addTargetRuntimeDirectories(partial, host,
		version.split(".")[0]);
	try addOverlays(partial, overlays);
	try writeReceipt(partial, runtimeBundle, engineContract.identity,
		runtimeContract.identity, host, version, directories);
	try writeEngineContract(partial, host, version);
	return Result.ok({
		output: "", contract: try verifyEngineContract(partial),
		targetRuntimeDirectories: directories,
	});
}

export function assembleBundle(
	enginePath: string, runtimeBundlePath: string, outputPath: string, overlayPaths: string[] = [],
): Result<AssembledBundle, string> {
	const host = try engineHostKey(platform, arch);
	const engine = try absoluteEnginePath(enginePath);
	const runtimeBundle = try absoluteEnginePath(runtimeBundlePath);
	const output = try absoluteEnginePath(outputPath);
	if (isLinkLike(output).ok) {
		return Result.err(output + " exists; --output names a new directory");
	}
	for (const root of [engine, runtimeBundle]) {
		const inside = containsExistingRoot(root, dirname(output));
		if (!inside.ok) { return Result.err(inside.error.message); }
		if (inside.value) { return Result.err("output must not be inside " + root); }
	}
	if (isLinkLike(join(engine, "runtime")).ok) {
		return Result.err(engine + " already has runtime/; --engine takes the engine alone");
	}
	const engineContract = try verifyEngineContract(engine);
	const runtimeContract = try verifyEngineContract(runtimeBundle);
	if (engineContract.host != host || runtimeContract.host != host) {
		return Result.err("engine is " + engineContract.host + ", runtime bundle " +
			runtimeContract.host + ", this host " + host);
	}
	if (engineContract.version != runtimeContract.version) {
		return Result.err("engine is LLVM " + engineContract.version +
			", the runtime was prepared for " + runtimeContract.version);
	}
	const overlays: string[] = [];
	for (const path of overlayPaths) { overlays.push(try absoluteEnginePath(path)); }
	const partial = try claimPartial(output);
	const staged = stage(engine, runtimeBundle, partial, engineContract, runtimeContract, overlays);
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
	return Result.ok({ ...staged.value, output });
}

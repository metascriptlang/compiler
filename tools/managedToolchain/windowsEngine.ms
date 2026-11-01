import {
	basename, dirname, join, isDir, isFile, isExecutable, isLinkLike,
	readDirNames, readFileBytes, ensureDir, removeAll, realpath,
} from "std/fs";
import { platform } from "std/process";
import { randomUUID } from "std/crypto";
import { IoErrorKind } from "std/io/errors";
import { jsonValueOf } from "std/serialize/json";
import { stringifyPretty } from "std/serialize/json/stringify";
import { sha256File } from "./fileDigest";
import { foldFileName } from "./fileCaseFold";
import { captureToolUtf8 } from "./processCapture";
import { containsExistingRoot } from "./nativePath";
import { isSymbolicLink } from "./nativeAlias";
import { nativeWindowsMachine } from "./windowsHost";
import { createDirectoryExclusive, renameNoReplace } from "./nativePublication";
import {
	EngineContract, FileLinks, absoluteEnginePath, sortEnginePaths,
	inventoryTree, listEngineFiles, engineFileSize, engineIo,
	copyEngineFile, writeEngineText, writeEngineContract, verifyEngineContract,
} from "./engineFiles";

const WINDOWS_X64 = "x86_64-windows";
const WINDOWS_ARM64 = "aarch64-windows";
const INSPECTOR = "llvm-readobj.exe";
const RESOURCE_PREFIX = "lib/clang/";
const LICENSE = "notices/LICENSE.TXT";
const TOOLS: string[16] = [
	"clang.exe", "clang++.exe", "lld.exe", "ld.lld.exe", "ld64.lld.exe",
	"lld-link.exe", "wasm-ld.exe", "llvm-ar.exe", "llvm-ranlib.exe",
	"llvm-strip.exe", "llvm-objcopy.exe", "llvm-nm.exe", "llvm-dlltool.exe",
	"llvm-symbolizer.exe", "llvm-rc.exe", INSPECTOR,
];
const SYSTEM_DLLS: string[10] = [
	"advapi32.dll", "crypt32.dll", "kernel32.dll", "ntdll.dll", "ole32.dll",
	"oleaut32.dll", "shell32.dll", "user32.dll", "version.dll", "winhttp.dll",
];

export struct WindowsHostSpec {
	machine: uint32;
	name: string;
	builtins: string;
}
export struct WindowsPe {
	machine: uint32;
	characteristics: uint32;
	magic: uint32;
	imports: string[];
	delayImports: string[];
}
struct InspectorBlock {
	name: string;
	lines: string[];
}
export struct EngineLicense {
	bytes: int64;
	copy: string;
	sha256: string;
	source: string;
	statement: string;
}
struct InspectorReceipt {
	sha256: string;
	version: string;
}
struct ProvenanceFile {
	imports: string[];
	path: string;
	source: string;
	sourceSha256: string;
}
struct WindowsReceipt {
	clangVersion: string;
	files: ProvenanceFile[];
	host: string;
	inspector: InspectorReceipt;
	kind: string;
	license: EngineLicense;
	lldVersion: string;
	redistributionCertified: boolean;
	statement: string;
	systemDlls: string[];
}
export struct WindowsEngineAudit {
	contract: EngineContract;
	peFiles: int32;
}
export struct WindowsEnginePrepared {
	output: string;
	audit: WindowsEngineAudit;
	plan: Map<string, string>;
	license: EngineLicense;
}

export function windowsTools(): string[] {
	const names: string[] = [];
	for (const name of TOOLS) { names.push(name); }
	return names;
}
export function windowsSystemDlls(): string[] {
	const names: string[] = [];
	for (const name of SYSTEM_DLLS) { names.push(name); }
	return names;
}
export function windowsHostSpec(
	host: string,
): Result<WindowsHostSpec, string> {
	return match (host) {
		WINDOWS_X64 => Result.ok({
			machine: 0x8664 as uint32, name: "AMD64",
			builtins: "clang_rt.builtins-x86_64.lib",
		}),
		WINDOWS_ARM64 => Result.ok({
			machine: 0xaa64 as uint32, name: "ARM64",
			builtins: "clang_rt.builtins-aarch64.lib",
		}),
		_ => Result.err("unsupported Windows engine host " + host),
	};
}
function nativeWindowsHost(): Result<string, string> {
	if (platform != "windows") {
		return Result.err("unsupported host " + platform +
			": only native Windows x64 or ARM64 is implemented");
	}
	const machine = try nativeWindowsMachine();
	if (machine == 0x8664) { return Result.ok(WINDOWS_X64); }
	if (machine == 0xaa64) { return Result.ok(WINDOWS_ARM64); }
	return Result.err("unsupported host windows machine 0x" +
		machine.toString(16));
}
function systemDll(folded: string): boolean {
	for (const name of SYSTEM_DLLS) { if (folded == name) { return true; } }
	return false;
}
function whitespace(code: int32): boolean {
	return (code >= 9 && code <= 13) || (code >= 28 && code <= 32) ||
		code == 0x85 || code == 0xa0 || code == 0x1680 ||
		(code >= 0x2000 && code <= 0x200a) || code == 0x2028 ||
		code == 0x2029 || code == 0x202f || code == 0x205f || code == 0x3000;
}
function stripped(text: string): string {
	let start: int32 = 0;
	let end = text.length;
	while (start < end && whitespace(text.charCodeAt(start))) { start += 1; }
	while (end > start && whitespace(text.charCodeAt(end - 1))) { end -= 1; }
	return text.slice(start, end);
}
function inspectorLines(text: string): string[] {
	const lines: string[] = [];
	let start: int32 = 0;
	for (let i: int32 = 0; i < text.length; i += 1) {
		const code = text.charCodeAt(i);
		const boundary = (code >= 10 && code <= 13) ||
			(code >= 28 && code <= 30) || code == 0x85 ||
			code == 0x2028 || code == 0x2029;
		if (!boundary) { continue; }
		lines.push(text.slice(start, i));
		if (code == 13 && i + 1 < text.length &&
			text.charCodeAt(i + 1) == 10) { i += 1; }
		start = i + 1;
	}
	if (start < text.length) { lines.push(text.slice(start, text.length)); }
	return lines;
}
function blockStart(line: string): string | null {
	if (!line.endsWith(" {")) { return null; }
	const name = line.slice(0, line.length - 2);
	if (name == "") { return null; }
	for (let i: int32 = 0; i < name.length; i += 1) {
		const code = name.charCodeAt(i);
		if (!((code >= 65 && code <= 90) || (code >= 97 && code <= 122))) {
			return null;
		}
	}
	return name;
}
function readBlocks(
	path: string, text: string,
): Result<InspectorBlock[], string> {
	const blocks: InspectorBlock[] = [];
	let current = "";
	let lines: string[] = [];
	for (const line of inspectorLines(text)) {
		const start = blockStart(line);
		if (current == "") {
			if (start != null) { current = start; lines = []; }
		} else if (line == "}") {
			blocks.push({ name: current, lines });
			current = "";
		} else if (start != null) {
			return Result.err(path + ": inspector block " + start +
				" starts inside block " + current);
		} else { lines.push(line); }
	}
	if (current != "") {
		return Result.err(path + ": inspector output ends inside block " + current);
	}
	return Result.ok(blocks);
}
function hexText(text: string): uint32 | null {
	if (text == "") { return null; }
	let value: uint32 = 0;
	for (let i: int32 = 0; i < text.length; i += 1) {
		const code = text.charCodeAt(i);
		let digit: int32 = -1;
		if (code >= 48 && code <= 57) { digit = code - 48; }
		if (code >= 65 && code <= 70) { digit = code - 65 + 10; }
		if (code >= 97 && code <= 102) { digit = code - 97 + 10; }
		if (digit < 0) { return null; }
		const next = (value as uint64) * 16 + (digit as uint64);
		if (next > (0xffffffff as uint64)) { return null; }
		value = next as uint32;
	}
	return value;
}
function hexField(
	path: string, lines: string[], prefix: string, suffix: string,
	what: string, machine: boolean = false,
): Result<uint32, string> {
	let count: int32 = 0;
	let value: uint32 = 0;
	for (const line of lines) {
		if (!line.startsWith(prefix) || !line.endsWith(suffix)) { continue; }
		let from = prefix.length;
		if (machine) {
			const marker = line.lastIndexOf("(0x");
			if (marker < from) { continue; }
			from = marker + 3;
		}
		const end = line.length - suffix.length;
		const parsed = hexText(line.slice(from, end));
		if (parsed == null) { continue; }
		value = parsed;
		count += 1;
	}
	if (count != 1) {
		return Result.err(path + ": inspector output has " + String(count) +
			" " + what + " lines, not one");
	}
	return Result.ok(value);
}
export function readWindowsPeText(
	path: string, text: string,
): Result<WindowsPe, string> {
	const blocks = try readBlocks(path, text);
	const fileHeaders: InspectorBlock[] = [];
	const optionalHeaders: InspectorBlock[] = [];
	const imports: string[] = [];
	const delayImports: string[] = [];
	for (const block of blocks) {
		if (block.name == "ImageFileHeader") { fileHeaders.push(block); }
		if (block.name == "ImageOptionalHeader") { optionalHeaders.push(block); }
	}
	for (const pair of [
		{ name: "ImageFileHeader", count: fileHeaders.length },
		{ name: "ImageOptionalHeader", count: optionalHeaders.length },
	]) {
		if (pair.count != 1) {
			return Result.err(path + ": inspector output has " +
				String(pair.count) + " " + pair.name + " blocks, not one");
		}
	}
	for (const block of blocks) {
		if (block.name != "Import" && block.name != "DelayImport") { continue; }
		const first = block.lines.length > 0 ? block.lines[0] : "";
		const prefix = "  Name: ";
		const name = first.startsWith(prefix) ?
			first.slice(prefix.length, first.length) : "";
		if (name == "" || whitespace(name.charCodeAt(0)) ||
			whitespace(name.charCodeAt(name.length - 1))) {
			return Result.err(path + ": " + block.name +
				" block has no Name line first");
		}
		if (block.name == "Import") { imports.push(name); }
		else { delayImports.push(name); }
	}
	return Result.ok({
		machine: try hexField(path, fileHeaders[0].lines,
			"  Machine: ", ")", "ImageFileHeader Machine", true),
		characteristics: try hexField(path, fileHeaders[0].lines,
			"  Characteristics [ (0x", ")", "ImageFileHeader Characteristics"),
		magic: try hexField(path, optionalHeaders[0].lines,
			"  Magic: 0x", "", "ImageOptionalHeader Magic"),
		imports, delayImports,
	});
}
export function windowsRoleProblem(
	rel: string, info: WindowsPe, host: string,
): Result<void, string> {
	const spec = try windowsHostSpec(host);
	if (info.machine != spec.machine) {
		return Result.err("machine 0x" + info.machine.toString(16) +
			", not " + spec.name + " (0x" + spec.machine.toString(16) + ")");
	}
	if (info.magic != 0x20b) {
		return Result.err("optional header magic 0x" + info.magic.toString(16) +
			", not PE32+ (0x20b)");
	}
	if ((info.characteristics & (2 as uint32)) == 0) {
		return Result.err("is not an executable image (characteristics 0x" +
			info.characteristics.toString(16) + ")");
	}
	const dll = (info.characteristics & (0x2000 as uint32)) != 0;
	const folded = try foldFileName(rel);
	if (folded.endsWith(".exe") && dll) {
		return Result.err("is a DLL image, required to be an executable of " + rel);
	}
	if (folded.endsWith(".dll") && !dll) {
		return Result.err("is an executable image, required to be a DLL of " + rel);
	}
	return Result.ok(null);
}
export function checkWindowsDllName(
	owner: string, name: string,
): Result<void, string> {
	if (name == "" || name == "." || name == ".." ||
		name.indexOf("/") >= 0 || name.indexOf("\\") >= 0 ||
		name.indexOf(":") >= 0 || name.indexOf("\0") >= 0) {
		return Result.err(owner + ": imports " + name +
			", which is not a file basename");
	}
	if (!(try foldFileName(name)).endsWith(".dll")) {
		return Result.err(owner + ": imports " + name +
			", which is not a .dll file name");
	}
	return Result.ok(null);
}
function importedNames(info: WindowsPe): string[] {
	const names: string[] = [];
	for (const name of info.imports) { names.push(name); }
	for (const name of info.delayImports) { names.push(name); }
	return names;
}
function readPe(
	path: string, inspector: string,
): Result<WindowsPe, string> {
	const read = readFileBytes(path);
	if (!read.ok) { return Result.err(read.error.message); }
	const data: Readonly<Span<uint8>> = read.value;
	if (data.length < 2 || data[0] != 77 || data[1] != 90) {
		return Result.err(path + ": not a PE image");
	}
	const result = captureToolUtf8(inspector,
		["--file-headers", "--coff-imports", path]);
	if (!result.ok) { return Result.err(path + ": " + result.error); }
	const done = result.value;
	if (done.returnCode != 0) {
		return Result.err(path + ": " + basename(inspector) + " failed (" +
			String(done.returnCode) + "): " + stripped(done.errorOutput));
	}
	if (stripped(done.errorOutput) != "") {
		return Result.err(path + ": " + basename(inspector) + " warned: " +
			stripped(done.errorOutput));
	}
	return readWindowsPeText(path, done.output);
}
export function parseWindowsToolVersion(
	text: string, prefix: string,
): Result<string, string> {
	let search: int32 = 0;
	while (search < text.length) {
		const marker = text.indexOf(prefix, search);
		if (marker < 0) { break; }
		const start = marker + prefix.length;
		let at = start;
		let valid = true;
		for (let group: int32 = 0; group < 3; group += 1) {
			const before = at;
			while (at < text.length && text.charCodeAt(at) >= 48 &&
				text.charCodeAt(at) <= 57) { at += 1; }
			if (at == before) { valid = false; break; }
			if (group < 2) {
				if (text.charAt(at) != ".") { valid = false; break; }
				at += 1;
			}
		}
		if (valid) { return Result.ok(text.slice(start, at)); }
		search = marker + 1;
	}
	return Result.err("version not recognized");
}
function toolVersion(path: string, prefix: string): Result<string, string> {
	const result = captureToolUtf8(path, ["--version"]);
	if (!result.ok) { return Result.err(path + ": " + result.error); }
	if (result.value.returnCode != 0) {
		return Result.err(path + " failed (" +
			String(result.value.returnCode) + "): " +
			stripped(result.value.errorOutput));
	}
	const version = parseWindowsToolVersion(result.value.output, prefix);
	if (!version.ok) { return Result.err(path + ": " + version.error); }
	return version;
}
function sourceListing(binDir: string): Result<Map<string, string[]>, string> {
	const names = readDirNames(binDir);
	if (!names.ok) { return Result.err(names.error.message); }
	const listing = new Map<string, string[]>();
	for (const name of names.value) {
		const folded = try foldFileName(name);
		const found = listing.get(folded);
		if (found == null) { listing.set(folded, [name]); }
		else { found.push(name); }
	}
	return Result.ok(listing);
}
function sourceFile(
	binDir: string, listing: Map<string, string[]>, name: string,
	owner: string, exact: boolean = false,
): Result<string, string> {
	const found = listing.get(try foldFileName(name));
	if (found == null || found.length == 0) {
		return Result.err(owner + ": needs " + name + ", which is not in " +
			binDir + " and is not a system library of " +
			windowsSystemDlls().join(", "));
	}
	if (found.length > 1) {
		sortEnginePaths(found);
		return Result.err(owner + ": " + name + " matches " +
			String(found.length) + " files of " + binDir +
			" differing only by case: " + found.join(", "));
	}
	if (exact && found[0] != name) {
		return Result.err(binDir + " holds " + found[0] +
			", but the tool must be named exactly " + name);
	}
	const path = try absoluteEnginePath(join(binDir, found[0]));
	const linked = isLinkLike(path);
	if (!linked.ok) { return Result.err(linked.error.message); }
	if (linked.value || !isFile(path)) {
		return Result.err(path + " is not a regular file");
	}
	return Result.ok(path);
}
export function addWindowsPlanned(
	plan: Map<string, string>, folds: Map<string, string>,
	dest: string, source: string,
): Result<void, string> {
	const key = try foldFileName(dest);
	const held = folds.get(key);
	if (held != null && held != dest) {
		return Result.err(held + " and " + dest + " differ only by case");
	}
	const previous = plan.get(dest);
	if (previous != null && previous != source) {
		return Result.err(dest + " collides: " + previous + " and " + source);
	}
	folds.set(key, dest);
	plan.set(dest, source);
	return Result.ok(null);
}
function planPaths(plan: Map<string, string>): string[] {
	const paths: string[] = [];
	for (const path of plan) { paths.push(path); }
	sortEnginePaths(paths);
	return paths;
}
function refuseOutside(
	root: string, plan: Map<string, string>,
): Result<void, string> {
	for (const dest of planPaths(plan)) {
		const source = plan.get(dest);
		if (source == null) {
			return Result.err("plan source disappeared: " + dest);
		}
		const inside = containsExistingRoot(root, source);
		if (!inside.ok) { return Result.err(inside.error.message); }
		if (!inside.value) {
			return Result.err(dest + ": source " + source +
				" is outside the LLVM root " + root);
		}
	}
	return Result.ok(null);
}
function planClosure(
	plan: Map<string, string>, folds: Map<string, string>, binDir: string,
	listing: Map<string, string[]>, inspector: string, host: string,
): Result<Map<string, WindowsPe>, string> {
	const infos = new Map<string, WindowsPe>();
	const queue: string[] = [];
	for (const path of planPaths(plan)) {
		if (path.startsWith("bin/")) { queue.push(path); }
	}
	while (queue.length > 0) {
		const dest = queue.pop();
		const source = plan.get(dest);
		if (source == null) {
			return Result.err("plan source disappeared: " + dest);
		}
		const info = try readPe(source, inspector);
		const role = windowsRoleProblem(dest, info, host);
		if (!role.ok) { return Result.err(source + ": " + role.error); }
		infos.set(dest, info);
		for (const name of importedNames(info)) {
			try checkWindowsDllName(source, name);
			if (systemDll(try foldFileName(name))) { continue; }
			const path = try sourceFile(binDir, listing, name, source);
			const wanted = "bin/" + basename(path);
			if (!plan.has(wanted)) { queue.push(wanted); }
			try addWindowsPlanned(plan, folds, wanted, path);
		}
	}
	return Result.ok(infos);
}
function requiredResource(major: string, spec: WindowsHostSpec): string[] {
	return [RESOURCE_PREFIX + major + "/include/stddef.h",
		RESOURCE_PREFIX + major + "/lib/windows/" + spec.builtins];
}
function verifyLayout(
	root: string, host: string, version: string,
): Result<void, string> {
	const spec = try windowsHostSpec(host);
	const required = requiredResource(version.split(".")[0], spec);
	for (const tool of TOOLS) { required.push("bin/" + tool); }
	required.push("notices/provenance.json");
	required.push(LICENSE);
	for (const rel of required) {
		if (!isFile(join(root, rel))) {
			return Result.err("layout: missing " + rel);
		}
	}
	if ((try engineFileSize(join(root, LICENSE))) == 0) {
		return Result.err("layout: " + LICENSE + " is empty");
	}
	return Result.ok(null);
}
function bundledInspector(root: string, host: string): Result<string, string> {
	const native = nativeWindowsHost();
	if (!native.ok || native.value != host) {
		return Result.err(root + ": cannot run the bundle's own bin/" +
			INSPECTOR + " here; pass --inspector");
	}
	return Result.ok(join(root, "bin/" + INSPECTOR));
}
export function verifyWindowsEngine(
	root: string, inspector: string | null = null,
): Result<WindowsEngineAudit, string> {
	const contract = try verifyEngineContract(root);
	try windowsHostSpec(contract.host);
	try verifyLayout(root, contract.host, contract.version);
	if (inspector != null && !isExecutable(inspector)) {
		return Result.err("--inspector " + inspector +
			" is not an executable file");
	}
	const reader = inspector != null ? inspector :
		try bundledInspector(root, contract.host);
	const folds = new Map<string, string>();
	const files: string[] = [];
	for (const rel of try listEngineFiles(root)) {
		if (!rel.startsWith("bin/")) { continue; }
		const name = rel.slice(4, rel.length);
		const folded = try foldFileName(name);
		if (name.indexOf("/") >= 0 ||
			!(folded.endsWith(".exe") || folded.endsWith(".dll"))) {
			return Result.err(rel + ": bin/ holds only .exe and .dll files directly");
		}
		const held = folds.get(folded);
		if (held != null && held != rel) {
			return Result.err(held + " and " + rel + " differ only by case");
		}
		if (systemDll(folded)) {
			return Result.err(rel + " would shadow the system library " + name);
		}
		const linked = isLinkLike(join(root, rel));
		if (!linked.ok) { return Result.err(linked.error.message); }
		if (linked.value) {
			return Result.err(rel + " is a symlink or reparse point");
		}
		folds.set(folded, rel);
		files.push(rel);
	}
	const infos = new Map<string, WindowsPe>();
	for (const rel of files) {
		const info = try readPe(join(root, rel), reader);
		const role = windowsRoleProblem(rel, info, contract.host);
		if (!role.ok) { return Result.err(rel + ": " + role.error); }
		infos.set(rel, info);
	}
	for (const rel of files) {
		const info = infos.get(rel);
		if (info == null) { return Result.err("PE facts disappeared: " + rel); }
		for (const name of importedNames(info)) {
			try checkWindowsDllName(rel, name);
			const folded = try foldFileName(name);
			if (!systemDll(folded) && !folds.has(folded)) {
				return Result.err(rel + ": imports " + name +
					", which is not in bin/ and is not a system library of " +
					windowsSystemDlls().join(", "));
			}
		}
	}
	return Result.ok({ contract, peFiles: files.length });
}
function refuseResourceLinks(root: string): Result<void, string> {
	const lib = join(root, "lib");
	const clang = join(lib, "clang");
	for (const path of [lib, clang]) {
		const linked = isLinkLike(path);
		if (!linked.ok) {
			if (linked.error.kind == IoErrorKind.NotFound) { continue; }
			return Result.err(linked.error.message);
		}
		if (linked.value) {
			return Result.err("symlink in resource directory: " + basename(path));
		}
	}
	if (isDir(clang)) { try inventoryTree(clang, FileLinks.Refuse); }
	return Result.ok(null);
}
function countBytes(
	data: Readonly<Span<uint8>>, needle: Readonly<Span<uint8>>,
): int64 {
	if (needle.length == 0) { return 0; }
	let count: int64 = 0;
	let at: int64 = 0;
	while (needle.length <= data.length - at) {
		let matched: int64 = 0;
		while (matched < needle.length && data[at + matched] == needle[matched]) {
			matched += 1;
		}
		if (matched == needle.length) { count += 1; at += needle.length; }
		else { at += 1; }
	}
	return count;
}
export function windowsSourcePathLiterals(
	root: string, source: string,
): Result<Map<string, int64>, string> {
	const sources = new Set<string>();
	sources.add(try absoluteEnginePath(source));
	const physical = realpath(source);
	if (physical == "") {
		return Result.err("cannot resolve source root: " + source);
	}
	sources.add(try absoluteEnginePath(physical));
	const counts = new Map<string, int64>();
	for (const rel of try listEngineFiles(root)) {
		const path = join(root, rel);
		const linked = isSymbolicLink(path);
		if (!linked.ok) { return Result.err(linked.error.message); }
		if (linked.value) { continue; }
		const read = readFileBytes(path);
		if (!read.ok) { return Result.err(read.error.message); }
		const data: Readonly<Span<uint8>> = read.value;
		if (data.length < 2 || data[0] != 77 || data[1] != 90) { continue; }
		let total: int64 = 0;
		for (const needle of sources) {
			total += countBytes(data, needle.asBytes());
		}
		if (total > 0) { counts.set(rel, total); }
	}
	return Result.ok(counts);
}

function readLicense(path: string | null): Result<EngineLicense, string> {
	if (path == null || path == "") {
		return Result.err("--license is required: " +
			"the upstream LLVM payload ships no license file");
	}
	const source = try absoluteEnginePath(path);
	const linked = isSymbolicLink(source);
	if (!linked.ok || linked.value || !isFile(source)) {
		return Result.err("--license " + source + " is not a regular file");
	}
	const bytes = try engineFileSize(source);
	if (bytes == 0) { return Result.err("--license " + source + " is empty"); }
	return Result.ok({
		bytes, copy: LICENSE, sha256: try sha256File(source), source,
		statement: "supplied by the operator and not checked against the release",
	});
}
function claimPartial(output: string): Result<string, string> {
	const parent = dirname(output);
	try engineIo(ensureDir(parent));
	for (let i: int32 = 0; i < 100; i += 1) {
		const token = randomUUID();
		if (!token.ok) { return Result.err(token.error.message); }
		const path = join(parent, basename(output) + ".partial-" + token.value);
		const claimed = createDirectoryExclusive(path);
		if (claimed.ok) { return Result.ok(path); }
		if (claimed.error.kind != IoErrorKind.AlreadyExists) {
			return Result.err(claimed.error.message);
		}
	}
	return Result.err("cannot claim a fresh partial directory for " + output);
}
export function asciiEngineJson(text: string): string {
	let output = "";
	for (let i: int32 = 0; i < text.length; i += 1) {
		const code = text.charCodeAt(i);
		output += code >= 127 ? "\\u" + code.toString(16).padStart(4, "0") :
			text.charAt(i);
	}
	return output;
}
function stageEngine(
	partial: string, host: string, version: string, lldVersion: string,
	inspector: string, inspectorReceipt: InspectorReceipt,
	license: EngineLicense, plan: Map<string, string>,
	infos: Map<string, WindowsPe>,
): Result<WindowsEngineAudit, string> {
	const files: ProvenanceFile[] = [];
	for (const dest of planPaths(plan)) {
		const source = plan.get(dest);
		if (source == null) {
			return Result.err("plan source disappeared: " + dest);
		}
		try copyEngineFile(source, join(partial, dest));
		if (!dest.startsWith(RESOURCE_PREFIX)) {
			const info = infos.get(dest);
			if (info == null) { return Result.err("PE facts disappeared: " + dest); }
			files.push({ imports: importedNames(info), path: dest,
				source, sourceSha256: try sha256File(source) });
		}
	}
	try copyEngineFile(license.source, join(partial, LICENSE));
	const receipt: WindowsReceipt = {
		clangVersion: version, files, host, inspector: inspectorReceipt,
		kind: "local-windows-llvm-proof", license, lldVersion,
		redistributionCertified: false,
		statement: "Prepared from a locally installed LLVM and an " +
			"operator-supplied license file. Not an upstream-controlled build.",
		systemDlls: windowsSystemDlls(),
	};
	const text = asciiEngineJson(stringifyPretty(jsonValueOf(receipt), 2)) + "\n";
	try writeEngineText(join(partial, "notices/provenance.json"), text);
	try writeEngineContract(partial, host, version);
	return verifyWindowsEngine(partial, inspector);
}
export function prepareWindowsEngine(
	llvmRoot: string, licensePath: string | null, outputPath: string,
): Result<WindowsEnginePrepared, string> {
	const host = try nativeWindowsHost();
	const spec = try windowsHostSpec(host);
	const root = try absoluteEnginePath(llvmRoot);
	const output = try absoluteEnginePath(outputPath);
	if (!isDir(root)) {
		return Result.err("--llvm-root " + root + " is not a directory");
	}
	const license = try readLicense(licensePath);
	const existing = isLinkLike(output);
	if (existing.ok) {
		return Result.err("output " + output + " exists; it is never replaced");
	}
	if (existing.error.kind != IoErrorKind.NotFound &&
		existing.error.kind != IoErrorKind.NotDirectory) {
		return Result.err(existing.error.message);
	}
	const inside = containsExistingRoot(root, dirname(output));
	if (!inside.ok) { return Result.err(inside.error.message); }
	if (inside.value) {
		return Result.err("output must not be inside the source root");
	}
	const binDir = try absoluteEnginePath(join(root, "bin"));
	if (!isDir(binDir)) { return Result.err(root + " has no bin directory"); }
	const linkedBin = isLinkLike(binDir);
	if (!linkedBin.ok) { return Result.err(linkedBin.error.message); }
	if (linkedBin.value) {
		return Result.err(binDir + " is a symlink or reparse point");
	}
	try refuseResourceLinks(root);
	const listing = try sourceListing(binDir);
	for (const key of listing) {
		if (systemDll(key)) {
			return Result.err(binDir + " holds " + key +
				", which would shadow the system library");
		}
	}
	const plan = new Map<string, string>();
	const folds = new Map<string, string>();
	for (const tool of TOOLS) {
		const source = try sourceFile(binDir, listing, tool, root, true);
		try addWindowsPlanned(plan, folds, "bin/" + tool, source);
	}
	try refuseOutside(root, plan);
	const inspector = try sourceFile(binDir, listing, INSPECTOR, root, true);
	const inspectorReceipt: InspectorReceipt = {
		sha256: try sha256File(inspector),
		version: try toolVersion(inspector, "LLVM version "),
	};
	const clang = try sourceFile(binDir, listing, "clang.exe", root, true);
	const lld = try sourceFile(binDir, listing, "ld.lld.exe", root, true);
	const version = try toolVersion(clang, "clang version ");
	const lldVersion = try toolVersion(lld, "LLD ");
	if (lldVersion != version) {
		return Result.err("lld " + lldVersion + " does not match clang " + version);
	}
	const major = version.split(".")[0];
	const resource = join(root, RESOURCE_PREFIX + major);
	if (!isDir(resource)) {
		return Result.err("missing resource directory " + resource);
	}
	for (const rel of try inventoryTree(resource, FileLinks.Refuse)) {
		try addWindowsPlanned(plan, folds, RESOURCE_PREFIX + major + "/" + rel,
			try absoluteEnginePath(join(resource, rel)));
	}
	for (const rel of requiredResource(major, spec)) {
		if (!plan.has(rel)) { return Result.err("missing " + rel + " in " + root); }
	}
	const infos = try planClosure(plan, folds, binDir, listing, inspector, host);
	try refuseOutside(root, plan);
	const partial = try claimPartial(output);
	const staged = stageEngine(partial, host, version, lldVersion,
		inspector, inspectorReceipt, license, plan, infos);
	if (!staged.ok) {
		const cleaned = removeAll(partial);
		return Result.err(staged.error + (cleaned.ok ? "" :
			"; partial cleanup failed: " + cleaned.error.message));
	}
	const published = renameNoReplace(partial, output);
	if (!published.ok) {
		const collision = isLinkLike(output);
		const cleaned = removeAll(partial);
		const error = published.error.kind == IoErrorKind.AlreadyExists ||
			collision.ok ? "output " + output + " exists; it is never replaced" :
			published.error.message;
		return Result.err(error + (cleaned.ok ? "" :
			"; partial cleanup failed: " + cleaned.error.message));
	}
	return Result.ok({ output, audit: staged.value, plan, license });
}

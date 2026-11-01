import {
	argv, execPath, exit, env, execFileResult, arch, cwd,
} from "std/process";
import {
	basename, dirname, join, exists, readFileBytes, writeFile, appendFile,
	copyFile, ensureDir, remove, removeAll, rename, symlink, readDirNames,
	isLinkLike, resolve,
} from "std/fs";
import { IoError } from "std/io/errors";
import { wellFormedString } from "std/core/string/bytes";
import { wellFormedPrefix } from "std/core/string/utf8Repair";
import { sha256File } from "./fileDigest";
import { readUtf8File } from "./textFile";
import { createDirectoryExclusive } from "./nativePublication";
import { isSymbolicLink } from "./nativeAlias";
import { nativeWindowsMachine } from "./windowsHost";
import {
	FileLinks, absoluteEnginePath, inventoryTree, writeEngineContract,
	sortEnginePaths,
} from "./engineFiles";
import {
	WindowsEnginePrepared, WindowsEngineAudit,
	prepareWindowsEngine, verifyWindowsEngine, windowsTools, windowsSystemDlls,
} from "./windowsEngine";

struct FixtureFacts {
	machine: uint32;
	magic: uint32;
	flags: uint32;
	imports: string[];
	delay: string[];
	version: string;
	warning: string;
	code: int32;
	copiesFail: boolean;
	claimOutput: string;
	log: string;
}
struct World {
	root: string;
	llvm: string;
	bin: string;
	license: string;
	log: string;
	host: string;
	builtins: string;
	facts: Map<string, FixtureFacts>;
}
struct ReceiptFile {
	path: string;
	source: string;
	sourceSha256: string;
	imports: string[];
}
struct ReceiptInspector {
	sha256: string;
	version: string;
}
struct ReceiptLicense {
	bytes: int64;
	copy: string;
	sha256: string;
	source: string;
	statement: string;
}
struct Receipt {
	kind: string;
	host: string;
	clangVersion: string;
	lldVersion: string;
	redistributionCertified: boolean;
	statement: string;
	files: ReceiptFile[];
	inspector: ReceiptInspector;
	license: ReceiptLicense;
	systemDlls: string[];
}
const MARKER = "\nMS_ENGINE_FIXTURE_FACTS\n";
const DLL_INIT_FAILED_STATUS: int32 = -1073741502;
const DLL_INIT_FAILED_DECIMAL = "3221225794";
let checks: int32 = 0;
let skipped: int32 = 0;

function check(ok: boolean, label: string): void {
	if (!ok) { throw new Error(label); }
	checks += 1;
}
function completed(result: Result<void, IoError>): void {
	if (!result.ok) { throw new Error(result.error.message); }
}
function finished(result: Result<void, string>): void {
	if (!result.ok) { throw new Error(result.error); }
}
function text(path: string): string {
	const read = readUtf8File(path);
	if (!read.ok) { throw new Error(read.error); }
	return read.value;
}
function absolute(path: string): string {
	if (argv.length > 1 && argv[1] == "--legacy-abspath") {
		return resolve(path, cwd()).replaceAll("/", "\\");
	}
	const result = absoluteEnginePath(path);
	if (!result.ok) { throw new Error(result.error); }
	return result.value;
}
function digest(path: string): string {
	const result = sha256File(path);
	if (!result.ok) { throw new Error(result.error); }
	return result.value;
}
function prepared(
	result: Result<WindowsEnginePrepared, string>,
): WindowsEnginePrepared {
	if (!result.ok) { throw new Error(result.error); }
	return result.value;
}
function audited(
	result: Result<WindowsEngineAudit, string>,
): WindowsEngineAudit {
	if (!result.ok) { throw new Error(result.error); }
	return result.value;
}
function markerFacts(path: string): FixtureFacts {
	const read = readFileBytes(path);
	if (!read.ok) { throw new Error(read.error.message); }
	const data: Readonly<Span<uint8>> = read.value;
	const marker = MARKER.asBytes();
	let found: int64 = -1;
	for (let at = data.length - marker.length; at >= 0; at -= 1) {
		let same = true;
		for (let i: int64 = 0; i < marker.length; i += 1) {
			if (data[at + i] != marker[i]) { same = false; break; }
		}
		if (same) { found = at + marker.length; break; }
	}
	if (found < 0 || wellFormedPrefix(data, found, false) != data.length) {
		throw new Error("missing or non-UTF8 controlled fixture facts: " + path);
	}
	const decoded = JSON.parse<FixtureFacts>(
		wellFormedString(data[found..data.length]));
	if (!decoded.ok) { throw new Error("invalid controlled fixture facts"); }
	return decoded.value;
}
function inspection(this facts: FixtureFacts): string {
	let output = "ImageFileHeader {\n  Machine: FIXTURE (0x" +
		facts.machine.toString(16) + ")\n  Characteristics [ (0x" +
		facts.flags.toString(16) + ")\n}\nImageOptionalHeader {\n  Magic: 0x" +
		facts.magic.toString(16) + "\n}\n";
	for (const name of facts.imports) {
		output += "Import {\n  Name: " + name + "\n}\n";
	}
	for (const name of facts.delay) {
		output += "DelayImport {\n  Name: " + name +
			"\n  Import {\n    Address: 1\n  }\n}\n";
	}
	return output;
}
function spy(): void {
	if (argv.length == 2 && argv[1] == "--version") {
		const facts = markerFacts(execPath);
		completed(appendFile(facts.log, "version:" + basename(execPath) + "\n"));
		const name = basename(execPath);
		const prefix = name == "clang.exe" ? "clang version " :
			name == "ld.lld.exe" ? "LLD " : "LLVM version ";
		console.log(prefix + facts.version);
		return;
	}
	if (argv.length != 4 || argv[1] != "--file-headers" ||
		argv[2] != "--coff-imports") {
		throw new Error("controlled inspector received unexpected argv");
	}
	const facts = markerFacts(argv[3]);
	completed(appendFile(facts.log, "inspect:" + argv[3] + "\n"));
	const copy = argv[3].indexOf(".partial-") >= 0;
	if (facts.copiesFail && copy) {
		console.error("controlled copy verification failure");
		exit(3);
	}
	if (facts.claimOutput != "" && copy) {
		completed(createDirectoryExclusive(facts.claimOutput));
		completed(writeFile(join(facts.claimOutput, "sentinel"), "claimed\n"));
	}
	if (facts.warning != "") { console.error(facts.warning); }
	console.log(facts.inspection());
	if (facts.code != 0) { exit(facts.code); }
}
function fixtureMachine(): uint32 {
	const result = nativeWindowsMachine();
	if (!result.ok) { throw new Error(result.error); }
	if (result.value != 0x8664 && result.value != 0xaa64) {
		throw new Error("controlled fixture requires native x64 or ARM64");
	}
	return result.value as uint32;
}
function freshFacts(log: string, dll: boolean = false): FixtureFacts {
	return {
		machine: fixtureMachine(), magic: 0x20b, flags: dll ? 0x2022 : 0x22,
		imports: ["KERNEL32.dll", "ntdll.dll"], delay: ["ole32.dll"],
		version: "23.1.0", warning: "", code: 0, copiesFail: false,
		claimOutput: "", log,
	};
}
function writeSpy(path: string, facts: FixtureFacts): void {
	completed(ensureDir(dirname(path)));
	if (path.endsWith(".exe")) { completed(copyFile(execPath, path)); }
	else { completed(writeFile(path, "MZ")); }
	completed(appendFile(path, MARKER + JSON.stringify(facts)));
}
function baseFacts(this world: World, name: string): FixtureFacts {
	const facts = world.facts.get(name);
	if (facts == null) { throw new Error("no base facts for " + name); }
	return facts;
}
function restore(this world: World, name: string): void {
	writeSpy(join(world.bin, name), world.baseFacts(name));
}
function clearCalls(this world: World): void {
	if (exists(world.log)) { completed(remove(world.log)); }
}
function calls(this world: World): string {
	return exists(world.log) ? text(world.log) : "";
}
function makeWorld(root: string): World {
	completed(createDirectoryExclusive(root));
	const llvm = join(root, "LLVM root đệ");
	const bin = join(llvm, "bin");
	completed(ensureDir(bin));
	const log = join(root, "calls.log");
	const x64 = fixtureMachine() == 0x8664;
	const host = x64 ? "x86_64-windows" : "aarch64-windows";
	const builtins = "lib/clang/23/lib/windows/clang_rt.builtins-" +
		(x64 ? "x86_64.lib" : "aarch64.lib");
	const facts = new Map<string, FixtureFacts>();
	for (const tool of windowsTools()) { facts.set(tool, freshFacts(log)); }
	let nm = freshFacts(log);
	nm.imports = ["LIBFOO.dll"];
	nm.delay = ["libbar.dll", "SHELL32.dll"];
	facts.set("llvm-nm.exe", nm);
	let symbolizer = freshFacts(log);
	symbolizer.imports = ["CRYPT32.dll", "WINHTTP.dll", "STRASSE.dll"];
	facts.set("llvm-symbolizer.exe", symbolizer);
	let foo = freshFacts(log, true);
	foo.imports = ["libbaz.dll"];
	facts.set("LibFoo.dll", foo);
	facts.set("libbar.dll", freshFacts(log, true));
	facts.set("libbaz.DLL", freshFacts(log, true));
	facts.set("Straße.dll", freshFacts(log, true));
	for (const name of facts) {
		const item = facts.get(name);
		if (item == null) { throw new Error("fixture facts disappeared"); }
		writeSpy(join(bin, name), item);
	}
	const include = join(llvm, "lib/clang/23/include");
	const libraries = join(llvm, "lib/clang/23/lib/windows");
	completed(ensureDir(include));
	completed(ensureDir(libraries));
	completed(writeFile(join(include, "stddef.h"), "stddef\n"));
	completed(writeFile(join(llvm, builtins), "!<arch>\n"));
	const license = join(root, "LLVM license đệ.txt");
	completed(writeFile(license, "Apache-2.0 WITH LLVM-exception\n" +
		"Giấy phép đệ 🚀\n"));
	return { root, llvm, bin, license, log, host, builtins, facts };
}
function snapshot(root: string): Map<string, string> {
	const listing = inventoryTree(root, FileLinks.Refuse);
	if (!listing.ok) { throw new Error(listing.error); }
	const hashes = new Map<string, string>();
	for (const rel of listing.value) { hashes.set(rel, digest(join(root, rel))); }
	return hashes;
}
function unchanged(root: string, before: Map<string, string>): boolean {
	const after = snapshot(root);
	if (after.size != before.size) { return false; }
	for (const path of before) {
		if (before.get(path) != after.get(path)) { return false; }
	}
	return true;
}
function refusal(
	this world: World,
	label: string,
	pattern: string,
	license: string | null,
): void {
	const output = join(world.root, label);
	const result = prepareWindowsEngine(world.llvm, license, output);
	check(!result.ok && result.error.indexOf(pattern) >= 0 && !exists(output),
		"producer must refuse " + label + ": " +
		(result.ok ? "unexpected success" : result.error));
}
function noPartials(this world: World, prefix: string): boolean {
	const listed = readDirNames(world.root);
	if (!listed.ok) { throw new Error(listed.error.message); }
	for (const name of listed.value) {
		if (name.startsWith(prefix + ".partial-")) { return false; }
	}
	return true;
}
function linkRefusal(
	this world: World,
	name: string,
	original: string,
	pattern: string,
): void {
	const held = join(world.root, "held-" + name);
	completed(rename(original, held));
	const made = symlink(held, original);
	if (!made.ok) {
		skipped += 1;
		console.log("SKIP " + name + ": fixture symlink refused; 1 check: " +
			made.error.message);
	} else {
		world.clearCalls();
		const output = join(world.root, "link-" + name);
		const result = prepareWindowsEngine(world.llvm, world.license, output);
		check(!result.ok && result.error.indexOf(pattern) >= 0 &&
			!exists(output) && world.calls() == "", "early link refusal: " + name);
		completed(removeAll(original));
	}
	completed(rename(held, original));
}
function run(): void {
	when (!windows) { throw new Error("controlled producer test needs Windows"); }
	const native = fixtureMachine();
	check((native == 0x8664 && arch == "amd64") ||
		(native == 0xaa64 && arch == "arm64"),
		"matching native CPU required; emulation is not host proof");
	const current = cwd().replaceAll("/", "\\");
	const prefix = current.endsWith("\\") ? current : current + "\\";
	check(absolute("") == current, "empty path resolves to actual cwd");
	check(absolute(current.slice(0, 2) + "absent-leaf") ==
		prefix + "absent-leaf", "drive-relative path uses the drive cwd");
	check(absolute("\\absent-leaf") == current.slice(0, 2) + "\\absent-leaf",
		"single-rooted path keeps the current drive");
	check(absolute(".\\parent\\.\\..\\leaf") == prefix + "leaf",
		"absolute spelling collapses dot segments");
	check(!absoluteEnginePath("bad\0path").ok,
		"absolute path conversion must not truncate NUL");
	const longPath = prefix + "segment\\".repeat(40) + "leaf";
	check(absolute(longPath) == longPath,
		"absolute path buffer grows past MAX_PATH without filesystem writes");
	const root = absolute(argv.length > 1 ? argv[1] :
		"out/windows-engine-producer-root");
	completed(createDirectoryExclusive(root));
	const world = makeWorld(join(root, "world"));
	const before = snapshot(world.llvm);
	const output = join(world.root, "engine");
	const result = prepared(prepareWindowsEngine(world.llvm, world.license,
		output));
	check(result.audit.peFiles == 20, "16 tools plus four dependency DLLs");
	check(result.audit.contract.files == 26, "complete engine inventory");
	check(result.audit.contract.host == world.host &&
		result.audit.contract.version == "23.1.0", "native host/version receipt");
	check(audited(verifyWindowsEngine(output)).peFiles == 20,
		"copied inspector verifies the complete bundle");
	check(audited(verifyWindowsEngine(output,
		join(world.bin, "llvm-readobj.exe"))).peFiles == 20,
		"explicit source inspector verifies copies");
	check(unchanged(world.llvm, before), "producer must not modify source LLVM");
	for (const name of windowsTools()) {
		check(digest(join(output, "bin/" + name)) == digest(join(world.bin, name)),
			"exact copied executable: " + name);
	}
	check(digest(join(output, "notices/LICENSE.TXT")) == digest(world.license),
		"license byte identity");
	const dependencies = [
		"LibFoo.dll", "libbar.dll", "libbaz.DLL", "Straße.dll",
	];
	for (const name of dependencies) {
		check(digest(join(output, "bin/" + name)) == digest(join(world.bin, name)),
			"exact-case recursive dependency: " + name);
	}
	const receiptText = text(join(output, "notices/provenance.json"));
	const decoded = JSON.parse<Receipt>(receiptText);
	if (!decoded.ok) { throw new Error("receipt did not decode"); }
	const receipt = decoded.value;
	check(receipt.kind == "local-windows-llvm-proof" &&
		!receipt.redistributionCertified && receipt.host == world.host &&
		receipt.clangVersion == "23.1.0" && receipt.lldVersion == "23.1.0",
		"receipt is local proof, never redistribution certification");
	check(receiptText.indexOf("\\u0111\\u1ec7") >= 0 &&
		receiptText.indexOf("\\u00df") >= 0 &&
		receiptText.startsWith("{\n  \"clangVersion\":") &&
		receiptText.endsWith("}\n"), "canonical ASCII receipt formatting");
	const licenseBytes = readFileBytes(world.license);
	if (!licenseBytes.ok) { throw new Error(licenseBytes.error.message); }
	check(receipt.license.bytes == licenseBytes.value.length &&
		receipt.license.copy == "notices/LICENSE.TXT" &&
		receipt.license.source == absolute(world.license) &&
		receipt.license.sha256 == digest(world.license) &&
		receipt.license.statement ==
			"supplied by the operator and not checked against the release",
		"license receipt stores bytes, exact source and operator disclaimer");
	check(receipt.inspector.version == "23.1.0" &&
		receipt.inspector.sha256 == digest(join(world.bin, "llvm-readobj.exe")),
		"inspector version and source identity");
	check(receipt.systemDlls.join(",") == windowsSystemDlls().join(",") &&
		receipt.statement == "Prepared from a locally installed LLVM and an " +
			"operator-supplied license file. Not an upstream-controlled build.",
		"receipt preserves exact allowlist and local-proof statement");
	check(receipt.files.length == 20, "receipt covers every non-resource source");
	const expectedPaths: string[] = [];
	for (const name of world.facts) { expectedPaths.push("bin/" + name); }
	sortEnginePaths(expectedPaths);
	for (let i: int32 = 0; i < receipt.files.length; i += 1) {
		const entry = receipt.files[i];
		const name = basename(entry.path);
		const original = world.baseFacts(name);
		const expectedImports: string[] = [];
		for (const imported of original.imports) { expectedImports.push(imported); }
		for (const imported of original.delay) { expectedImports.push(imported); }
		if (entry.path != expectedPaths[i] ||
			entry.source != absolute(join(world.bin, name)) ||
			entry.sourceSha256 != digest(entry.source) ||
			entry.imports.join(",") != expectedImports.join(",")) {
			throw new Error("wrong source/import receipt: " + entry.path);
		}
	}
	check(true, "all source receipt hashes, exact paths and ordered imports");
	check(text(join(output, "lib/clang/23/include/stddef.h")) == "stddef\n",
		"resource paths and bytes");
	completed(appendFile(join(output, "bin/clang.exe"), "changed"));
	world.clearCalls();
	const corrupt = verifyWindowsEngine(output);
	check(!corrupt.ok &&
		corrupt.error.indexOf("hash mismatch: bin/clang.exe") >= 0 &&
		world.calls() == "", "contract checked before executing any inspector");
	completed(copyFile(join(world.bin, "clang.exe"),
		join(output, "bin/clang.exe")));
	finished(writeEngineContract(output, world.host, "23.1.0"));
	check(audited(verifyWindowsEngine(output)).peFiles == 20,
		"restored byte-identical file verifies");
	let bad = world.baseFacts("LibFoo.dll");
	bad.flags = 0x22;
	writeSpy(join(output, "bin/LibFoo.dll"), bad);
	finished(writeEngineContract(output, world.host, "23.1.0"));
	const role = verifyWindowsEngine(output);
	check(!role.ok && role.error.indexOf("required to be a DLL") >= 0,
		"valid rehashed contract does not bypass image roles");
	completed(copyFile(join(world.bin, "LibFoo.dll"),
		join(output, "bin/LibFoo.dll")));
	completed(writeFile(join(output, "bin/notes.txt"), "notes"));
	finished(writeEngineContract(output, world.host, "23.1.0"));
	const nested = verifyWindowsEngine(output);
	check(!nested.ok && nested.error.indexOf("bin/ holds only") >= 0,
		"bin is not an arbitrary payload directory");
	completed(remove(join(output, "bin/notes.txt")));
	bad = world.baseFacts("LibFoo.dll");
	bad.imports = ["absent.dll"];
	writeSpy(join(output, "bin/LibFoo.dll"), bad);
	finished(writeEngineContract(output, world.host, "23.1.0"));
	const missing = verifyWindowsEngine(output);
	check(!missing.ok && missing.error.indexOf("imports absent.dll") >= 0,
		"rehashed dependency closure must still be complete");
	world.refusal("no-license", "--license is required", null);
	world.refusal("missing-license", "not a regular file",
		join(world.root, "absent-license"));
	const empty = join(world.root, "empty-license");
	completed(writeFile(empty, ""));
	world.refusal("empty-license-out", "is empty", empty);
	const existing = join(world.root, "existing");
	completed(createDirectoryExclusive(existing));
	completed(writeFile(join(existing, "sentinel"), "held\n"));
	const held = prepareWindowsEngine(world.llvm, world.license, existing);
	check(!held.ok && held.error.indexOf("never replaced") >= 0 &&
		text(join(existing, "sentinel")) == "held\n",
		"existing output is untouched");
	const inside = prepareWindowsEngine(world.llvm, world.license,
		join(world.llvm, "must-not-create"));
	check(!inside.ok && inside.error.indexOf("must not be inside") >= 0,
		"output must not mutate source tree");
	const ar = join(world.bin, "llvm-ar.exe");
	const savedAr = join(world.root, "held-ar");
	completed(rename(ar, savedAr));
	world.refusal("missing-tool", "needs llvm-ar.exe", world.license);
	completed(rename(savedAr, ar));
	writeSpy(join(world.bin, "Kernel32.dll"), freshFacts(world.log, true));
	world.clearCalls();
	world.refusal("shadowed-system", "shadow the system library", world.license);
	if (world.calls() != "") { throw new Error("system shadow ran a tool"); }
	completed(remove(join(world.bin, "Kernel32.dll")));
	writeSpy(join(world.bin, "STRASSE.dll"), freshFacts(world.log, true));
	world.refusal("fold-collision", "matches 2 files", world.license);
	completed(remove(join(world.bin, "STRASSE.dll")));
	for (const delayed of [false, true]) {
		bad = world.baseFacts("llvm-nm.exe");
		bad.imports = delayed ? [] : ["absent.dll"];
		bad.delay = delayed ? ["absent.dll"] : [];
		writeSpy(join(world.bin, "llvm-nm.exe"), bad);
		world.refusal(delayed ? "missing-delay" : "missing-import",
			"needs absent.dll", world.license);
	}
	bad = world.baseFacts("llvm-nm.exe");
	bad.imports = ["C:evil.dll"];
	writeSpy(join(world.bin, "llvm-nm.exe"), bad);
	world.refusal("bad-basename", "not a file basename", world.license);
	world.restore("llvm-nm.exe");
	bad = world.baseFacts("llvm-ar.exe");
	bad.flags = 0x2022;
	writeSpy(ar, bad);
	world.refusal("source-role", "is a DLL image", world.license);
	world.restore("llvm-ar.exe");
	bad = world.baseFacts("ld.lld.exe");
	bad.version = "23.1.1";
	writeSpy(join(world.bin, "ld.lld.exe"), bad);
	world.refusal("version-mismatch", "does not match clang", world.license);
	world.restore("ld.lld.exe");
	const builtins = join(world.llvm, world.builtins);
	const savedBuiltins = join(world.root, "held-builtins");
	completed(rename(builtins, savedBuiltins));
	world.refusal("missing-resource", "missing lib/clang/23/lib/windows/",
		world.license);
	completed(rename(savedBuiltins, builtins));
	world.linkRefusal("license", world.license, "not a regular file");
	world.linkRefusal("lib", join(world.llvm, "lib"), "symlink in resource");
	world.linkRefusal("bin", world.bin, "symlink or reparse point");
	world.linkRefusal("tool", ar, "is not a regular file");
	world.linkRefusal("header", join(world.llvm,
		"lib/clang/23/include/stddef.h"), "symlink in resource");
	const alias = join(world.root, "alias-root");
	const madeAlias = symlink(world.llvm, alias);
	if (!madeAlias.ok) {
		skipped += 1;
		console.log("SKIP root-alias: fixture symlink refused; 1 check: " +
			madeAlias.error.message);
	} else {
		const aliased = prepared(prepareWindowsEngine(alias, world.license,
			join(world.root, "alias-engine")));
		check(aliased.audit.peFiles == 20, "explicit physical root alias accepted");
	}
	const junction = join(world.root, "junction");
	const system = env.get("SystemRoot");
	if (system == "") { throw new Error("SystemRoot unavailable for junction"); }
	const command = (system + "\\System32\\cmd.exe").replaceAll("/", "\\");
	const joined = execFileResult(command, [
		"/d", "/c", "mklink", "/J", junction.replaceAll("/", "\\"),
		world.llvm.replaceAll("/", "\\"),
	]);
	if (joined.exitCode == DLL_INIT_FAILED_STATUS ||
		joined.errorOutput.indexOf("0xC0000142") >= 0 ||
		joined.output.indexOf(DLL_INIT_FAILED_DECIMAL) >= 0) {
		throw new Error("0xC0000142: junction fixture process STOP");
	}
	if (!joined.started || !joined.pipeOk || joined.exitCode != 0) {
		skipped += 1;
		console.log("SKIP junction-tag: junction fixture refused; 1 check: " +
			joined.errorOutput);
	} else {
		const reparse = isLinkLike(junction);
		const symbolic = isSymbolicLink(junction);
		check(reparse.ok && reparse.value && symbolic.ok && !symbolic.value,
			"reparse point is not always a symbolic link");
	}
	bad = world.baseFacts("llvm-ar.exe");
	bad.warning = "warning: controlled malformed input";
	writeSpy(ar, bad);
	world.refusal("inspector-warning", "warned: warning:", world.license);
	world.restore("llvm-ar.exe");
	bad = world.baseFacts("llvm-ar.exe");
	bad.copiesFail = true;
	writeSpy(ar, bad);
	world.refusal("bad-copy", "controlled copy verification failure",
		world.license);
	if (!world.noPartials("bad-copy")) {
		throw new Error("failed staging leaked");
	}
	world.restore("llvm-ar.exe");
	const raced = join(world.root, "raced-engine");
	bad = world.baseFacts("clang.exe");
	bad.claimOutput = raced;
	writeSpy(join(world.bin, "clang.exe"), bad);
	const race = prepareWindowsEngine(world.llvm, world.license, raced);
	check(!race.ok && race.error.indexOf("never replaced") >= 0 &&
		text(join(raced, "sentinel")) == "claimed\n" &&
		world.noPartials("raced-engine"), "late output claim is never replaced");
	world.restore("clang.exe");
	check(unchanged(world.llvm, before),
		"all controlled source mutations restored");
	if (checks + skipped != 72) {
		throw new Error("controlled producer case count changed: " +
			String(checks) + " passed, " + String(skipped) + " skipped");
	}
	console.log("Windows engine producer: " + String(checks) +
		" checks OK; " + String(skipped) + " skipped");
	completed(removeAll(root));
}
when (!testBuild) {
	if (argv.length > 1 &&
		(argv[1] == "--version" || argv[1] == "--file-headers")) {
		spy();
	} else {
		run();
	}
}

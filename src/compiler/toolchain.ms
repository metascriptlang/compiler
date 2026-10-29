// MetaScript Compiler — managed C toolchain provisioning (locate + install Zig).

import { stopBuild, atomicWriteFile } from "./io";
import { exec, execFileCapture, env, platform, arch, exit, cwd } from "std/process";
import { exists, ensureDir, remove, readFile, readDir, realpath, isDir, isExecutable, rmdir, rename, changeStamp, changedTime, modifiedTime, writeFile, removeAll, symlink } from "std/fs";
import { quoteCcArg } from "../utils/commandLine";
import { sha256, toHex } from "std/crypto/sha256";
import { nowSeconds, markUsed } from "../utils/stampDirs";
import { metascriptHome, resolveRuntimeDir } from "../utils/path";
import { join } from "std/fs/path";
import { readLine, writeStderr } from "std/io";
import { CliOptions, CC_PREPARED, buildCpu, newCliOptions } from "./options";

function eprintln(msg: string): void {
	writeStderr(msg + "\n");
}

const ZIG_VERSION = "0.16.0";
const ZIG_BASE = "https://ziglang.org/download/0.16.0/";

function managedZigDir(): string {
	const home = metascriptHome();
	if (home == "") return "";
	return join(home, "zig");
}

function zigBinaryIn(dir: string): string {
	return join(dir, platform == "windows" ? "zig.exe" : "zig");
}

function managedZigBinary(): string {
	const dir = managedZigDir();
	if (dir == "") return "";
	return zigBinaryIn(dir);
}

function hasManagedZig(): boolean {
	const b = managedZigBinary();
	return b != "" && exists(b);
}

export function managedZigCompiler(): string {
	if (!hasManagedZig()) return "";
	return `${managedZigBinary()} cc`;
}

function hostArch(): string {
	return arch == "arm64" ? "aarch64" : "x86_64";
}

function hostOs(): string {
	return match (platform) {
		"darwin" => "macos",
		"linux" => "linux",
		"windows" => "windows",
		_ => "",
	};
}

function hostKey(): string {
	const os = hostOs();
	if (os == "") return "";
	return `${hostArch()}-${os}`;
}

function zigTarball(key: string): string {
	return match (key) {
		"aarch64-macos" => "zig-aarch64-macos-0.16.0.tar.xz",
		"x86_64-macos" => "zig-x86_64-macos-0.16.0.tar.xz",
		"x86_64-linux" => "zig-x86_64-linux-0.16.0.tar.xz",
		"aarch64-linux" => "zig-aarch64-linux-0.16.0.tar.xz",
		"x86_64-windows" => "zig-x86_64-windows-0.16.0.zip",
		"aarch64-windows" => "zig-aarch64-windows-0.16.0.zip",
		_ => "",
	};
}

function zigSha256(key: string): string {
	return match (key) {
		"aarch64-macos" => "b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489",
		"x86_64-macos" => "0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7",
		"x86_64-linux" => "70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00",
		"aarch64-linux" => "ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17",
		"x86_64-windows" => "68659eb5f1e4eb1437a722f1dd889c5a322c9954607f5edcf337bc3684a75a7e",
		"aarch64-windows" => "aee38316ee4111717900f45dd3130145c39289e105541d737eb8c5ed653c78ef",
		_ => "",
	};
}

function verifySha256(file: string, want: string): boolean {
	if (want == "") return true;
	let out = "";
	if (platform == "windows") {
		const r = exec(`certutil -hashfile "${file}" SHA256`);
		out = r.ok ? r.value.toLowerCase() : "";
	} else {
		let r = exec(`shasum -a 256 "${file}"`);
		if (!r.ok) r = exec(`sha256sum "${file}"`);
		out = r.ok ? r.value.toLowerCase() : "";
	}
	if (out == "") return false;
	return out.indexOf(want.toLowerCase()) >= 0;
}

function autoInstallAllowed(assumeYes: boolean): boolean {
	if (assumeYes) return true;
	return env.get("MSC_AUTO_INSTALL_CC") == "1";
}

function promptInstall(dir: string): boolean {
	writeStderr(`msc compiles C with Zig ${ZIG_VERSION} by default. Download it to ${dir}? ` +
		`(--cc=clang uses your own) [y/N] `);
	const ans = readLine();
	return ans == "y" || ans == "Y" || ans == "yes";
}

function ensureZig(assumeYes: boolean): string {
	if (hasManagedZig()) return managedZigBinary();

	const key = hostKey();
	const tarball = zigTarball(key);
	if (tarball == "") {
		eprintln(`error: no managed Zig build for host '${key}'.`);
		eprintln(`  → install a C compiler and pass --cc=clang.`);
		return "";
	}

	const dir = managedZigDir();
	if (!autoInstallAllowed(assumeYes) && !promptInstall(dir)) {
		eprintln(`error: no C compiler available.`);
		eprintln(`  → install one, re-run and accept the Zig download, or set MSC_AUTO_INSTALL_CC=1.`);
		return "";
	}

	ensureDir(metascriptHome());
	const url = `${ZIG_BASE}${tarball}`;
	const stage = `${dir}.install.${performance.now()}`;
	const archive = `${stage}.${tarball}`;

	eprintln(`Downloading Zig ${ZIG_VERSION} (${key})…`);
	const dl = exec(`curl -fL --retry 3 -o "${archive}" "${url}"`);
	if (!dl.ok) {
		remove(archive);
		eprintln(`error: failed to download Zig from ${url}`);
		return "";
	}
	if (!verifySha256(archive, zigSha256(key))) {
		eprintln(`error: Zig download checksum mismatch (corrupt or tampered) — aborting.`);
		remove(archive);
		return "";
	}
	if (!ensureDir(stage).ok) {
		remove(archive);
		eprintln(`error: cannot create ${stage}.`);
		return "";
	}
	const ex = exec(`tar xf "${archive}" -C "${stage}" --strip-components=1`);
	remove(archive);
	if (!ex.ok || !exists(zigBinaryIn(stage))) {
		removeAll(stage);
		eprintln(`error: failed to extract Zig archive.`);
		return "";
	}
	if (!publishZig(stage, dir) && !hasManagedZig()) {
		eprintln(`error: cannot install Zig at ${dir}; it exists without a zig binary.`);
		eprintln(`  → remove ${dir} and re-run.`);
		return "";
	}
	return managedZigBinary();
}

// Moving a directory onto a non-empty one fails on every OS, so a published
// install is never replaced; an empty leftover from an earlier failed run goes.
function publishZig(staged: string, dir: string): boolean {
	rmdir(dir);
	if (rename(staged, dir).ok) return true;
	removeAll(staged);
	return false;
}

function zigProbe(): string {
	const root = join(cwd(), `out/zigPublishProbe-${performance.now()}`);
	return ensureDir(root).ok ? root : "";
}

function zigStage(root: string, name: string, tag: string): string {
	const stage = join(root, name);
	if (!ensureDir(join(stage, "lib")).ok) return "";
	if (!writeFile(zigBinaryIn(stage), tag).ok || !writeFile(join(stage, "lib/std"), tag).ok) return "";
	return stage;
}

test "two zig installs publish one winner and the loser discards its copy" {
	const root = zigProbe();
	assert root != "";
	const final = join(root, "zig");
	const first = zigStage(root, "zig.install.1", "first");
	const second = zigStage(root, "zig.install.2", "second");
	assert first != "" && second != "";
	assert !exists(zigBinaryIn(final));
	assert publishZig(first, final);
	assert !exists(first);
	assert !publishZig(second, final);
	assert !exists(second);
	assert (try readFile(zigBinaryIn(final)) catch "") == "first";
	assert (try readFile(join(final, "lib/std")) catch "") == "first";
	assert removeAll(root).ok;
}

test "an empty leftover zig directory gives way to a published install" {
	const root = zigProbe();
	assert root != "";
	const final = join(root, "zig");
	assert ensureDir(final).ok;
	const staged = zigStage(root, "zig.install.1", "only");
	assert staged != "";
	assert publishZig(staged, final);
	assert (try readFile(zigBinaryIn(final)) catch "") == "only";
	assert removeAll(root).ok;
}

export struct NativeToolchain {
	root: string;
	version: string;
	identity: string;
}

function isSha256(value: string): boolean {
	if (value.length != 64) return false;
	for (let i = 0; i < value.length; i++) {
		if ("0123456789abcdef".indexOf(value.charAt(i)) < 0) return false;
	}
	return true;
}

function bundlePathSafe(path: string): boolean {
	if (path == "" || path.indexOf(":") >= 0 || path.indexOf("\\") >= 0) return false;
	for (let i = 0; i < path.length; i++) {
		if (path.charCodeAt(i) < 32 || path.charCodeAt(i) == 127) return false;
	}
	for (const part of path.split("/")) {
		if (part == "" || part == "." || part == "..") return false;
	}
	return true;
}

function bundleText(root: string, name: string): Result<string, string> {
	const path = join(root, name);
	if (realpath(path).replaceAll("\\", "/") != path) return Result.err(`native toolchain: missing or symlinked metadata ${name}`);
	const text = readFile(path);
	if (!text.ok) return Result.err(`native toolchain: cannot read ${path}`);
	return Result.ok(text.value);
}

function fileSha256(path: string): Result<string, string> {
	const command = platform == "windows" ? "certutil" : platform == "darwin" ? "shasum" : "sha256sum";
	const args = platform == "windows" ? ["-hashfile", path, "SHA256"] : platform == "darwin" ? ["-a", "256", path] : [path];
	const hash = execFileCapture(command, args);
	if (!hash.ok) return Result.err(`native toolchain: cannot hash ${path}: ${hash.error.message}`);
	for (const line of hash.value.split("\n")) {
		const digest = line.trim().slice(0, 64).toLowerCase();
		if (isSha256(digest)) return Result.ok(digest);
	}
	return Result.err(`native toolchain: invalid SHA256 output for ${path}`);
}

function validateBundleTree(root: string, directory: string, names: HashSet<string>): Result<void, string> {
	for (const entry of readDir(join(root, directory))) {
		const name = entry.endsWith("/") ? entry.slice(0, entry.length - 1) : entry;
		const relative = directory == "" ? name : `${directory}/${name}`;
		if (!bundlePathSafe(relative)) return Result.err(`native toolchain: unsafe payload path ${relative}`);
		const full = join(root, relative);
		if (isDir(full)) {
			if (realpath(full).replaceAll("\\", "/") != full) return Result.err(`native toolchain: directory symlink ${relative}`);
			const children = try validateBundleTree(root, relative, names);
		} else if (relative != "FILES.sha256" && relative != "IDENTITY" && !names.has(relative)) {
			return Result.err(`native toolchain: unlisted payload ${relative}`);
		}
	}
	return Result.ok(null);
}

function readNativeToolchain(path: string): Result<NativeToolchain, string> {
	const root = realpath(path).replaceAll("\\", "/");
	if (root == "") return Result.err(`native toolchain: missing bundle ${path}`);
	const hostText = try bundleText(root, "HOST");
	const versionText = try bundleText(root, "VERSION");
	const identityText = try bundleText(root, "IDENTITY");
	if (arch != "arm64" && arch != "amd64" && arch != "aarch64" && arch != "x86_64") {
		return Result.err(`native toolchain: unsupported host architecture ${arch}`);
	}
	if (hostText != `${hostKey()}\n`) return Result.err(`native toolchain: bundle host ${hostText.trim()} does not match ${hostKey()}`);
	const version = versionText.trim();
	const components = version.split(".");
	if (components.length != 3 || versionText != `${version}\n`) return Result.err("native toolchain: invalid VERSION");
	for (const component of components) {
		if (component == "") return Result.err("native toolchain: invalid VERSION");
		for (let i = 0; i < component.length; i++) {
			if ("0123456789".indexOf(component.charAt(i)) < 0) return Result.err("native toolchain: invalid VERSION");
		}
	}
	const identity = identityText.trim();
	if (!isSha256(identity) || identityText != `${identity}\n`) return Result.err("native toolchain: invalid IDENTITY");
	return Result.ok({ root, version, identity });
}

function validateNativeToolchain(path: string, stampRoot: string): Result<NativeToolchain, string> {
	const bundle = try readNativeToolchain(path);
	const root = bundle.root;
	const identity = bundle.identity;
	const version = bundle.version;
	const components = version.split(".");
	const manifest = try bundleText(root, "FILES.sha256");
	if (!manifest.endsWith("\n")) return Result.err("native toolchain: unterminated FILES.sha256");
	const names = new HashSet<string>();
	const lines = manifest.split("\n");
	for (let i = 0; i < lines.length - 1; i++) {
		const line = lines[i];
		const name = line.slice(66);
		if (line.length < 67 || line.slice(64, 66) != "  " || !isSha256(line.slice(0, 64)) || !bundlePathSafe(name)) {
			return Result.err(`native toolchain: invalid manifest entry ${line}`);
		}
		if (name == "FILES.sha256" || name == "IDENTITY" || names.has(name)) return Result.err(`native toolchain: duplicate or reserved manifest entry ${name}`);
		names.add(name);
		const resolved = realpath(join(root, name)).replaceAll("\\", "/");
		if (!resolved.startsWith(`${root}/`)) return Result.err(`native toolchain: missing or escaping payload ${name}`);
	}
	const tree = try validateBundleTree(root, "", names);
	const suffix = platform == "windows" ? ".exe" : "";
	for (const name of ["HOST", "VERSION", `bin/clang${suffix}`, `bin/clang++${suffix}`, `bin/llvm-ar${suffix}`, `lib/clang/${components[0]}/include/stddef.h`]) {
		if (!names.has(name)) return Result.err(`native toolchain: unlisted required payload ${name}`);
	}
	for (const tool of ["clang", "clang++", "llvm-ar", platform == "darwin" ? "ld64.lld" : platform == "windows" ? "lld-link" : "ld.lld"]) {
		const name = `bin/${tool}${suffix}`;
		if (!names.has(name) || !isExecutable(join(root, name))) return Result.err(`native toolchain: missing executable ${name}`);
	}
	const memo = stampRoot == "" ? "" : `${stampRoot}/${bundleDigest(root)}.bundle`;
	const seal = bundleSeal(root, identity, lines);
	if (!bundleMemoHit(memo, seal)) {
		const verified = try verifyBundlePayload(root, identity, version, lines);
		if (seal != "" && memo != "" && ensureDir(stampRoot).ok) atomicWriteFile(memo, seal);
	}
	return Result.ok({ root, version, identity });
}

function bundleMemoHit(memo: string, seal: string): boolean {
	if (seal == "" || memo == "" || (try readFile(memo) catch "") != seal) return false;
	markUsed(memo, nowSeconds());
	return true;
}

function bundleDigest(text: string): string {
	return sha256(text.asBytes()).toHex();
}

// Taken before verification, so a file that changes while it is hashed fails
// the next comparison instead of sealing content nobody checked. A file written
// within the settle window of its change time seals nothing: a coarse-clock
// filesystem can give a second same-size write in that window the same change
// stamp, and only the change time is out of a writer's reach (mtime is settable).
function bundleSeal(root: string, identity: string, lines: string[]): string {
	const names = ["IDENTITY", "FILES.sha256"];
	for (let i = 0; i < lines.length - 1; i++) names.push(lines[i].slice(66));
	const settledBefore = nowSeconds() - BUNDLE_SETTLED_SECONDS;
	const stamps: string[] = [identity];
	for (const name of names) {
		const path = join(root, name);
		const stamp = changeStamp(path);
		const changed = changedTime(path);
		if (stamp == "" || changed < 0 || changed > settledBefore) return "";
		stamps.push(`${name}\t${stamp}`);
	}
	return bundleDigest(stamps.join("\n"));
}

const BUNDLE_SETTLED_SECONDS = 2;

const SEAL_PAYLOAD = ["IDENTITY", "FILES.sha256", "bin/clang"];

function sealProbe(): string {
	const root = join(cwd(), `out/bundleSealProbe-${performance.now()}`);
	if (!ensureDir(join(root, "bin")).ok) return "";
	for (const name of SEAL_PAYLOAD) {
		if (!writeFile(join(root, name), "first").ok) return "";
	}
	return root;
}

function backdate(root: string, names: string[]): boolean {
	for (const name of names) {
		if (!execFileCapture("touch", ["-t", "202001010000", join(root, name)]).ok) return false;
	}
	return true;
}

const SEAL_LINES = ["0000000000000000000000000000000000000000000000000000000000000000  bin/clang", ""];

function settle(root: string, names: string[]): void {
	const deadline = nowSeconds() + 10;
	for (const name of names) {
		const path = join(root, name);
		while (changedTime(path) > nowSeconds() - BUNDLE_SETTLED_SECONDS) {
			if (nowSeconds() > deadline) throw new Error(`${path} did not settle`);
			execFileCapture("sleep", ["0.2"]);
		}
	}
}

test "a bundle seal is withheld for a payload changed within the settle window, whatever its mtime says" {
	if (platform == "windows") return;
	const root = sealProbe();
	assert root != "";
	assert backdate(root, SEAL_PAYLOAD);
	assert bundleSeal(root, "id", SEAL_LINES) == "";
	assert removeAll(root).ok;
}

test "a bundle seal moves when a payload is rewritten to the same size under a preserved mtime" {
	if (platform == "windows") return;
	const root = sealProbe();
	assert root != "";
	assert backdate(root, SEAL_PAYLOAD);
	settle(root, SEAL_PAYLOAD);
	const before = bundleSeal(root, "id", SEAL_LINES);
	assert before != "";
	assert bundleSeal(root, "id", SEAL_LINES) == before;
	assert bundleSeal(root, "other", SEAL_LINES) != before;
	assert writeFile(join(root, "bin/clang"), "other").ok;
	assert backdate(root, ["bin/clang"]);
	assert bundleSeal(root, "id", SEAL_LINES) == "";
	assert removeAll(root).ok;
}

test "a matching bundle seal never skips payload containment" {
	if (platform == "windows") return;
	const root = sealProbe();
	assert root != "";
	const real = realpath(root).replaceAll("\\", "/");
	const identity = SEAL_LINES[0].slice(0, 64);
	const outside = `${root}-outside`;
	const stamps = `${root}-stamps`;
	assert writeFile(join(root, "HOST"), `${hostKey()}\n`).ok;
	assert writeFile(join(root, "VERSION"), "1.2.3\n").ok;
	assert writeFile(join(root, "IDENTITY"), `${identity}\n`).ok;
	assert writeFile(join(root, "FILES.sha256"), SEAL_LINES.join("\n")).ok;
	assert writeFile(outside, "first").ok;
	assert remove(join(root, "bin/clang")).ok;
	assert symlink(outside, join(root, "bin/clang")).ok;
	assert backdate(root, ["HOST", "VERSION", "IDENTITY", "FILES.sha256", "bin/clang"]);
	settle(root, SEAL_PAYLOAD);
	const seal = bundleSeal(real, identity, SEAL_LINES);
	assert seal != "";
	assert ensureDir(stamps).ok;
	assert writeFile(`${stamps}/${bundleDigest(real)}.bundle`, seal).ok;
	const validated = validateNativeToolchain(root, stamps);
	assert !validated.ok;
	assert validated.error.contains("escaping payload bin/clang");
	assert removeAll(root).ok;
	assert removeAll(stamps).ok;
	assert remove(outside).ok;
}

test "a bundle memo that answers is refreshed, so the stale-entry collector keeps a memo used every day" {
	if (platform == "windows") return;
	const stamps = join(cwd(), `out/bundleMemoProbe-${performance.now()}`);
	assert ensureDir(stamps).ok;
	const memo = join(stamps, "digest.bundle");
	assert writeFile(memo, "seal").ok;
	assert backdate(stamps, ["digest.bundle"]);
	assert !bundleMemoHit(memo, "other");
	assert modifiedTime(memo) < nowSeconds() - 3600;
	assert bundleMemoHit(memo, "seal");
	assert modifiedTime(memo) > nowSeconds() - 60;
	assert (try readFile(memo) catch "") == "seal";
	assert removeAll(stamps).ok;
}

test "a bundle with a missing or freshly written payload seals nothing" {
	if (platform == "windows") return;
	const root = sealProbe();
	assert root != "";
	assert bundleSeal(root, "id", SEAL_LINES) == "";
	assert backdate(root, SEAL_PAYLOAD);
	settle(root, SEAL_PAYLOAD);
	assert bundleSeal(root, "id", SEAL_LINES) != "";
	assert remove(join(root, "bin/clang")).ok;
	assert bundleSeal(root, "id", SEAL_LINES) == "";
	assert removeAll(root).ok;
}

function verifyBundlePayload(root: string, identity: string, version: string, lines: string[]): Result<void, string> {
	const actualIdentity = try fileSha256(join(root, "FILES.sha256"));
	if (actualIdentity != identity) return Result.err("native toolchain: FILES.sha256 identity mismatch");
	if (platform == "windows") {
		for (let i = 0; i < lines.length - 1; i++) {
			const name = lines[i].slice(66);
			const digest = try fileSha256(join(root, name));
			if (digest != lines[i].slice(0, 64)) return Result.err(`native toolchain: checksum mismatch for ${name}`);
		}
	} else {
		const checked = platform == "darwin"
			? execFileCapture("shasum", ["-a", "256", "-c", "FILES.sha256"], root)
			: execFileCapture("sha256sum", ["-c", "FILES.sha256"], root);
		if (!checked.ok) return Result.err(`native toolchain: payload checksum verification failed: ${checked.error.output}${checked.error.errorOutput}`);
	}
	const suffix = platform == "windows" ? ".exe" : "";
	const compiler = execFileCapture(join(root, `bin/clang${suffix}`), ["--version"]);
	if (!compiler.ok) return Result.err("native toolchain: cannot execute bundled clang");
	const firstLine = compiler.value.split("\n")[0];
	if (!firstLine.endsWith(`clang version ${version}`) && !firstLine.contains(`clang version ${version} `)) {
		return Result.err(`native toolchain: compiler version does not match ${version}`);
	}
	return Result.ok(null);
}

function nativeRuntimeConfig(targetOs: string, cpu: string): string {
	if (targetOs == "wasm" && cpu == "wasm32") return "wasm32-wasi.cfg";
	if (targetOs == "linux" && (cpu == "amd64" || cpu == "x86_64")) return "x86_64-linux-gnu.2.31.cfg";
	if (targetOs == "linux" && (cpu == "arm64" || cpu == "aarch64")) return "aarch64-linux-gnu.2.31.cfg";
	if (targetOs == "windows" && (cpu == "amd64" || cpu == "x86_64")) return "windows/x86_64-windows-gnu.cfg";
	if (targetOs == "windows" && (cpu == "arm64" || cpu == "aarch64")) return "windows/aarch64-windows-gnu.cfg";
	return "";
}

let pendingBundle: NativeToolchain | null = null;
let pendingPath = "";
let pendingStampRoot = "";
let selectedBundle: NativeToolchain | null = null;

export function selectedNativeToolchain(): NativeToolchain | null {
	return selectedBundle;
}

function verifySelectedToolchain(): string {
	const selected = pendingBundle;
	if (selected == null) return "";
	pendingBundle = null;
	const verified = validateNativeToolchain(pendingPath, pendingStampRoot);
	if (!verified.ok) return verified.error;
	if (verified.value.root != selected.root || verified.value.identity != selected.identity) return `native toolchain: ${pendingPath} changed after the build selected it`;
	return "";
}

export function requirePreparedToolchain(): void {
	const error = verifySelectedToolchain();
	if (error != "") {
		eprintln(`error: ${error}`);
		stopBuild();
	}
}

function macosSdkPath(stampRoot: string): string {
	const key = `${env.get("DEVELOPER_DIR")}\n${realpath("/var/db/xcode_select_link")}\n`;
	const memo = stampRoot == "" ? "" : `${stampRoot}/macos-sdk`;
	if (memo != "") {
		const text = readFile(memo);
		if (text.ok && text.value.startsWith(key)) {
			const sdk = text.value.slice(key.length);
			if (sdk != "" && isDir(sdk)) return sdk;
		}
	}
	const found = execFileCapture("xcrun", ["--sdk", "macosx", "--show-sdk-path"]);
	if (!found.ok) return "";
	const sdk = found.value.trim();
	if (sdk != "" && memo != "" && ensureDir(stampRoot).ok) atomicWriteFile(memo, `${key}${sdk}`);
	return sdk;
}

function selectNativeToolchain(opts: CliOptions, path: string, stampRoot: string): Result<void, string> {
	selectedBundle = null;
	const bundle = try readNativeToolchain(path);
	selectedBundle = bundle;
	pendingBundle = bundle;
	pendingPath = path;
	pendingStampRoot = stampRoot;
	opts.ccBinary = `${quoteCcArg(join(bundle.root, "bin/clang"))} --no-default-config`;
	opts.passC = `-DMSC_NATIVE_TOOLCHAIN_${bundle.identity}=1 ${opts.passC}`;
	if (opts.targetOs == "darwin" || opts.targetOs == "macos") {
		const sdk = macosSdkPath(stampRoot);
		if (sdk == "") return Result.err("native toolchain: macOS builds require an installed Xcode SDK");
		opts.passC = `-isysroot ${quoteCcArg(sdk)} -resource-dir ${quoteCcArg(join(bundle.root, `lib/clang/${bundle.version.split(".")[0]}`))} ${opts.passC}`;
		opts.passL = `--ld-path=${quoteCcArg(join(bundle.root, "bin/ld64.lld"))} ${opts.passL}`;
		return Result.ok(null);
	}
	const cpu = buildCpu(opts.targetOs, opts.cpuTarget);
	const name = nativeRuntimeConfig(opts.targetOs, cpu);
	const config = join(bundle.root, `runtime/${name}`);
	if (name == "" || !exists(config)) return Result.err(`native toolchain: prepared runtime for ${opts.targetOs}/${cpu} is not installed in ${bundle.root}`);
	if (opts.isHcr && opts.targetOs != "linux" && opts.targetOs != "windows") return Result.err(`native toolchain: ${name} does not supply HCR startup`);
	opts.ccBinary = `${opts.ccBinary} --config=${quoteCcArg(config)}`;
	return Result.ok(null);
}

function selectionProbe(manifest: boolean): string {
	const root = sealProbe();
	if (root == "") return "";
	const identity = SEAL_LINES[0].slice(0, 64);
	if (!writeFile(join(root, "HOST"), `${hostKey()}\n`).ok) return "";
	if (!writeFile(join(root, "VERSION"), "1.2.3\n").ok) return "";
	if (!writeFile(join(root, "IDENTITY"), `${identity}\n`).ok) return "";
	if (manifest && !writeFile(join(root, "FILES.sha256"), "not a manifest\n").ok) return "";
	if (!ensureDir(join(root, "runtime")).ok || !writeFile(join(root, "runtime/x86_64-linux-gnu.2.31.cfg"), "").ok) return "";
	return root;
}

function linuxOptions(): CliOptions {
	const opts = newCliOptions();
	opts.targetOs = "linux";
	opts.cpuTarget = "x86_64";
	return opts;
}

test "selecting a bundle reads its identity and leaves payload verification to the first compile" {
	for (const manifest of [true, false]) {
		const root = selectionProbe(manifest);
		assert root != "";
		const opts = linuxOptions();
		assert selectNativeToolchain(opts, root, "").ok;
		assert opts.passC.contains(`-DMSC_NATIVE_TOOLCHAIN_${SEAL_LINES[0].slice(0, 64)}=1`);
		const error = verifySelectedToolchain();
		assert error.contains(manifest ? "invalid manifest entry not a manifest" : "FILES.sha256");
		assert verifySelectedToolchain() == "";
		const selected = selectedNativeToolchain();
		assert selected != null && selected.root == root && selected.identity == SEAL_LINES[0].slice(0, 64);
		assert removeAll(root).ok;
	}
}

test "a wasm bundle build keeps the console startup for every app mode and refuses only HCR" {
	const root = selectionProbe(true);
	assert root != "";
	assert writeFile(join(root, "runtime/wasm32-wasi.cfg"), "").ok;
	for (const appMode of ["console", "lib", "staticlib"]) {
		const opts = newCliOptions();
		opts.targetOs = "wasm";
		opts.appMode = appMode;
		assert selectNativeToolchain(opts, root, "").ok;
		assert opts.ccBinary.contains("--config=");
	}
	const hcr = newCliOptions();
	hcr.targetOs = "wasm";
	hcr.isHcr = true;
	const refused = selectNativeToolchain(hcr, root, "");
	assert !refused.ok;
	assert refused.error.contains("wasm32-wasi.cfg does not supply HCR startup");
	verifySelectedToolchain();
	assert removeAll(root).ok;
}

test "a bundle with an unreadable identity is refused at selection" {
	const root = selectionProbe(true);
	assert root != "";
	assert writeFile(join(root, "IDENTITY"), "short\n").ok;
	const selected = selectNativeToolchain(linuxOptions(), root, "");
	assert !selected.ok;
	assert selected.error.contains("invalid IDENTITY");
	assert selectedNativeToolchain() == null;
	assert removeAll(root).ok;
}

test "the macOS SDK memo answers only for the developer directory it was taken under" {
	if (platform != "darwin") return;
	const stamps = join(cwd(), `out/sdkMemoProbe-${performance.now()}`);
	const sdk = join(stamps, "Fake.sdk");
	assert ensureDir(sdk).ok;
	const key = `${env.get("DEVELOPER_DIR")}\n${realpath("/var/db/xcode_select_link")}\n`;
	assert writeFile(join(stamps, "macos-sdk"), `${key}${sdk}`).ok;
	assert macosSdkPath(stamps) == sdk;
	assert writeFile(join(stamps, "macos-sdk"), `other\n${key}${sdk}`).ok;
	const real = macosSdkPath(stamps);
	assert real != sdk && isDir(real);
	assert (try readFile(join(stamps, "macos-sdk")) catch "") == `${key}${real}`;
	assert removeAll(stamps).ok;
}

test "prepared runtimes are selected by both OS and CPU" {
	assert nativeRuntimeConfig("wasm", "wasm32") == "wasm32-wasi.cfg";
	assert nativeRuntimeConfig("linux", "amd64") == "x86_64-linux-gnu.2.31.cfg";
	assert nativeRuntimeConfig("linux", "x86_64") == "x86_64-linux-gnu.2.31.cfg";
	assert nativeRuntimeConfig("linux", "arm64") == "aarch64-linux-gnu.2.31.cfg";
	assert nativeRuntimeConfig("linux", "aarch64") == "aarch64-linux-gnu.2.31.cfg";
	assert nativeRuntimeConfig("linux", "arm") == "";
	assert nativeRuntimeConfig("windows", "amd64") == "windows/x86_64-windows-gnu.cfg";
	assert nativeRuntimeConfig("windows", "arm64") == "windows/aarch64-windows-gnu.cfg";
	assert nativeRuntimeConfig("windows", "arm") == "";
	assert nativeRuntimeConfig("wasm", "arm64") == "";
}

test "bundle checksums require a complete lowercase SHA256" {
	assert isSha256("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
	assert !isSha256("");
	assert !isSha256("0123456789abcdef");
	assert !isSha256("G123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
}

test "bundle manifest paths cannot escape or inject checksum records" {
	assert bundlePathSafe("bin/clang++");
	assert bundlePathSafe("notices/source provenance.json");
	for (const path of ["", "/bin/clang", "../clang", "bin/../clang", "bin//clang", "./bin/clang", "C:/clang", "bin\\clang", "bin/clang\nextra", "bin/clang\t"]) {
		assert !bundlePathSafe(path);
	}
}

function nativeToolchainPath(compilerRoot: string, explicit: string): string {
	if (explicit != "") return explicit;
	if (compilerRoot == "") return "";
	for (const entry of readDir(compilerRoot)) {
		if (entry == "msc-toolchain" || entry == "msc-toolchain/") return join(compilerRoot, "msc-toolchain");
	}
	return "";
}

test "native bundle discovery preserves explicit selection and notices an incomplete adjacent bundle" {
	const root = join(cwd(), `out/nativeToolchainProbe-${performance.now()}`);
	assert ensureDir(root).ok;
	assert nativeToolchainPath(root, "") == "";
	const bundle = join(root, "msc-toolchain");
	assert ensureDir(bundle).ok;
	assert nativeToolchainPath(root, "") == bundle;
	assert nativeToolchainPath(root, "/explicit/bundle") == "/explicit/bundle";
	assert nativeToolchainPath("", "") == "";
	assert rmdir(bundle).ok;
	assert rmdir(root).ok;
}

// Normalize the --cc alias and resolve (installing if needed) the compiler to
// use. Every command that emits C must call this — cmdBuildC and cmdTest both
// do; cmdRun reaches it through cmdBuildC. LTO capability checks live in
// cc.ms (ltoBroken/resolveLto) and run right after this, once the compiler is
// known.
export function resolveCC(opts: CliOptions, stampRoot: string): void {
	if (opts.ccBinary == "zig") opts.ccBinary = "zig cc";

	if (opts.ccBinary != "" || opts.ccCompiler != 0) return;
	if (opts.targetOs == "solana" || opts.targetOs == "bare" || opts.targetOs == "emcc") return;

	const native = nativeToolchainPath(resolveRuntimeDir(), env.get("MSC_NATIVE_TOOLCHAIN"));
	if (native != "") {
		const selected = selectNativeToolchain(opts, native, stampRoot);
		if (!selected.ok) {
			eprintln(`error: ${selected.error}`);
			stopBuild();
		}
		opts.ccCompiler = CC_PREPARED;
		return;
	}
	if (ensureZig(opts.autoYes) == "") stopBuild();
	// Leave ccBinary empty: getCompilerName resolves managed zig from its warmed
	// global, which workers read read-only. Stuffing the heap path string into
	// ccBinary would capture it into the parallel-compile spawn closures.
}

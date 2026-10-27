// MetaScript Compiler — managed C toolchain provisioning (locate + install Zig).

import { stopBuild, atomicWriteFile } from "./io";
import { exec, execFileCapture, env, platform, arch, exit, cwd } from "std/process";
import { exists, ensureDir, remove, readFile, readDir, realpath, isDir, isExecutable, rmdir, changeStamp, modifiedTime, writeFile, removeAll, symlink } from "std/fs";
import { quoteCcArg } from "../utils/commandLine";
import { sha256, toHex } from "std/crypto/sha256";
import { nowSeconds } from "../utils/stampDirs";
import { metascriptHome, resolveRuntimeDir } from "../utils/path";
import { join } from "std/fs/path";
import { readLine, writeStderr } from "std/io";
import { CliOptions, CC_PREPARED, buildCpu } from "./options";

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

function managedZigBinary(): string {
	const dir = managedZigDir();
	if (dir == "") return "";
	return join(dir, platform == "windows" ? "zig.exe" : "zig");
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

	ensureDir(dir);
	const url = `${ZIG_BASE}${tarball}`;
	const archive = join(dir, tarball);

	eprintln(`Downloading Zig ${ZIG_VERSION} (${key})…`);
	const dl = exec(`curl -fL --retry 3 -o "${archive}" "${url}"`);
	if (!dl.ok) {
		eprintln(`error: failed to download Zig from ${url}`);
		return "";
	}
	if (!verifySha256(archive, zigSha256(key))) {
		eprintln(`error: Zig download checksum mismatch (corrupt or tampered) — aborting.`);
		remove(archive);
		return "";
	}
	const ex = exec(`tar xf "${archive}" -C "${dir}" --strip-components=1`);
	remove(archive);
	if (!ex.ok || !hasManagedZig()) {
		eprintln(`error: failed to extract Zig archive.`);
		return "";
	}
	return managedZigBinary();
}

struct NativeToolchain {
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

function validateNativeToolchain(path: string, stampRoot: string): Result<NativeToolchain, string> {
	const root = realpath(path).replaceAll("\\", "/");
	if (root == "") return Result.err(`native toolchain: missing bundle ${path}`);
	const hostText = try bundleText(root, "HOST");
	const versionText = try bundleText(root, "VERSION");
	const identityText = try bundleText(root, "IDENTITY");
	const manifest = try bundleText(root, "FILES.sha256");
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
	if (seal == "" || memo == "" || (try readFile(memo) catch "") != seal) {
		const verified = try verifyBundlePayload(root, identity, version, lines);
		if (seal != "" && memo != "" && ensureDir(stampRoot).ok) atomicWriteFile(memo, seal);
	}
	return Result.ok({ root, version, identity });
}

function bundleDigest(text: string): string {
	return sha256(text.asBytes()).toHex();
}

// Taken before verification, so a file that changes while it is hashed fails
// the next comparison instead of sealing content nobody checked. A file written
// within the settle window seals nothing: a coarse-clock filesystem can give a
// second same-size write in that window the same change stamp.
function bundleSeal(root: string, identity: string, lines: string[]): string {
	const names = ["IDENTITY", "FILES.sha256"];
	for (let i = 0; i < lines.length - 1; i++) names.push(lines[i].slice(66));
	const settledBefore = nowSeconds() - BUNDLE_SETTLED_SECONDS;
	const stamps: string[] = [identity];
	for (const name of names) {
		const path = join(root, name);
		const stamp = changeStamp(path);
		const modified = modifiedTime(path);
		if (stamp == "" || modified < 0 || modified > settledBefore) return "";
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

test "a bundle seal moves when a payload is rewritten to the same size under a preserved mtime" {
	if (platform == "windows") return;
	const root = sealProbe();
	assert root != "";
	assert backdate(root, SEAL_PAYLOAD);
	const before = bundleSeal(root, "id", SEAL_LINES);
	assert before != "";
	assert bundleSeal(root, "id", SEAL_LINES) == before;
	assert bundleSeal(root, "other", SEAL_LINES) != before;
	assert writeFile(join(root, "bin/clang"), "other").ok;
	assert backdate(root, ["bin/clang"]);
	assert bundleSeal(root, "id", SEAL_LINES) != before;
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

test "a bundle with a missing or freshly written payload seals nothing" {
	if (platform == "windows") return;
	const root = sealProbe();
	assert root != "";
	assert bundleSeal(root, "id", SEAL_LINES) == "";
	assert backdate(root, SEAL_PAYLOAD);
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

function selectNativeToolchain(opts: CliOptions, path: string, stampRoot: string): Result<void, string> {
	const bundle = try validateNativeToolchain(path, stampRoot);
	opts.ccBinary = `${quoteCcArg(join(bundle.root, "bin/clang"))} --no-default-config`;
	opts.passC = `-DMSC_NATIVE_TOOLCHAIN_${bundle.identity}=1 ${opts.passC}`;
	if (opts.targetOs == "darwin" || opts.targetOs == "macos") {
		const sdk = execFileCapture("xcrun", ["--sdk", "macosx", "--show-sdk-path"]);
		if (!sdk.ok || sdk.value.trim() == "") return Result.err("native toolchain: macOS builds require an installed Xcode SDK");
		opts.passC = `-isysroot ${quoteCcArg(sdk.value.trim())} -resource-dir ${quoteCcArg(join(bundle.root, `lib/clang/${bundle.version.split(".")[0]}`))} ${opts.passC}`;
		opts.passL = `--ld-path=${quoteCcArg(join(bundle.root, "bin/ld64.lld"))} ${opts.passL}`;
		return Result.ok(null);
	}
	const cpu = buildCpu(opts.targetOs, opts.cpuTarget);
	const name = nativeRuntimeConfig(opts.targetOs, cpu);
	const config = join(bundle.root, `runtime/${name}`);
	if (name == "" || !exists(config)) return Result.err(`native toolchain: prepared runtime for ${opts.targetOs}/${cpu} is not installed in ${bundle.root}`);
	if ((opts.isHcr || opts.appMode != "console") && opts.targetOs != "linux" && opts.targetOs != "windows") return Result.err(`native toolchain: ${name} does not supply ${opts.isHcr ? "HCR" : opts.appMode} startup`);
	opts.ccBinary = `${opts.ccBinary} --config=${quoteCcArg(config)}`;
	return Result.ok(null);
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

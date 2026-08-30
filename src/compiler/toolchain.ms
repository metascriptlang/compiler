// MetaScript Compiler — managed C toolchain provisioning (locate + install Zig).

import { exec, env, platform, exit } from "std/process";
import { exists, ensureDir, remove } from "std/fs";
import { join } from "std/fs/path";
import { readLine, writeStderr } from "std/io";
import { CliOptions } from "./options";

function eprintln(msg: string): void {
	writeStderr(msg + "\n");
}

const ZIG_VERSION = "0.16.0";
const ZIG_BASE = "https://ziglang.org/download/0.16.0/";

function metascriptHome(): string {
	let h = env.get("HOME");
	if (h === "") h = env.get("USERPROFILE");
	if (h === "") return "";
	return join(h, ".metascript");
}

function managedZigDir(): string {
	const home = metascriptHome();
	if (home === "") return "";
	return join(home, "zig");
}

function managedZigBinary(): string {
	const dir = managedZigDir();
	if (dir === "") return "";
	return join(dir, platform === "windows" ? "zig.exe" : "zig");
}

function hasManagedZig(): boolean {
	const b = managedZigBinary();
	return b !== "" && exists(b);
}

export function managedZigCompiler(): string {
	if (!hasManagedZig()) return "";
	// Unquoted: the consumer tokenizes this string into argv (runCc →
	// execFileCapture), and quoting is the spawn layer's job (_msAppendWinArg /
	// execvp), not the name's. The tokenizer keeps a quoted token whole, so a
	// managed dir with spaces still lands as one argv element.
	return `${managedZigBinary()} cc`;
}

function hostArch(): string {
	if (platform === "windows") {
		return env.get("PROCESSOR_ARCHITECTURE") === "ARM64" ? "aarch64" : "x86_64";
	}
	const r = exec("uname -m");
	const m = r.ok ? r.value : "";
	if (m.indexOf("arm64") >= 0 || m.indexOf("aarch64") >= 0) return "aarch64";
	return "x86_64";
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
	if (os === "") return "";
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
	if (want === "") return true;
	let out = "";
	if (platform === "windows") {
		const r = exec(`certutil -hashfile "${file}" SHA256`);
		out = r.ok ? r.value.toLowerCase() : "";
	} else {
		let r = exec(`shasum -a 256 "${file}"`);
		if (!r.ok) r = exec(`sha256sum "${file}"`);
		out = r.ok ? r.value.toLowerCase() : "";
	}
	if (out === "") return false;
	return out.indexOf(want.toLowerCase()) >= 0;
}

function autoInstallAllowed(assumeYes: boolean): boolean {
	if (assumeYes) return true;
	return env.get("MSC_AUTO_INSTALL_CC") === "1";
}

function promptInstall(dir: string): boolean {
	writeStderr(`No C compiler configured. Download Zig ${ZIG_VERSION} to ${dir}? [y/N] `);
	const ans = readLine();
	return ans === "y" || ans === "Y" || ans === "yes";
}

function ensureZig(assumeYes: boolean): string {
	if (hasManagedZig()) return managedZigBinary();

	const key = hostKey();
	const tarball = zigTarball(key);
	if (tarball === "") {
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

// Normalize the --cc alias and resolve (installing if needed) the compiler to
// use. Every command that emits C must call this — cmdBuildC and cmdTest both
// do; cmdRun reaches it through cmdBuildC. LTO capability checks live in
// cc.ms (ltoBroken/resolveLto) and run right after this, once the compiler is
// known.
export function resolveCC(opts: CliOptions): void {
	if (opts.ccBinary === "zig") opts.ccBinary = "zig cc";

	if (opts.ccBinary !== "" || opts.ccCompiler !== 0) return;
	if (opts.targetOs === "solana" || opts.targetOs === "bare" || opts.targetOs === "emcc") return;

	if (ensureZig(opts.autoYes) === "") exit(1);
	// Leave ccBinary empty: getCompilerName resolves managed zig from its warmed
	// global, which workers read read-only. Stuffing the heap path string into
	// ccBinary would capture it into the parallel-compile spawn closures.
}

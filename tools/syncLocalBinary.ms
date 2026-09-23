// Sync a locally built msc and its support trees to ~/.metascript/ so downstream
// projects pick them up via $PATH.
//
// Run from a clean worktree of main, with the msc you just built:
//   ./msc run tools/syncLocalBinary.ms --target=raiser [check] [no-binary]
// check prints what would change; no-binary syncs the support trees only.
// Env: MSC_INSTALL_DIR overrides the destination.
import { argv, cwd, env, execFileResult, exit, platform } from "std/process";
import { chmod, copyFile, ensureDir, exists, fileSize, isDir, modifiedTime, readDir, readFile, removeAll, rename, writeFile } from "std/fs";

const windows = platform == "windows";

function slashes(p: string): string {
	return p.replaceAll("\\", "/");
}

function die(msg: string): void {
	console.log(`error: ${msg}`);
	exit(1);
}

function scriptRoot(): string {
	for (const a of argv) {
		const s = slashes(a);
		if (s.endsWith("tools/syncLocalBinary.ms")) {
			const abs = s.startsWith("/") || s.indexOf(":") >= 0 ? s : `${slashes(cwd())}/${s}`;
			const tools = abs.slice(0, abs.length - "/syncLocalBinary.ms".length);
			return tools.slice(0, tools.length - "/tools".length);
		}
	}
	return slashes(cwd());
}

let check = false;
let syncBinary = true;
for (const a of argv) {
	if (a == "check") check = true;
	if (a == "no-binary") syncBinary = false;
}

const SRC = scriptRoot();
const home = env.get("HOME") != "" ? env.get("HOME") : env.get("USERPROFILE");
const DEST = slashes(env.get("MSC_INSTALL_DIR") != "" ? env.get("MSC_INSTALL_DIR") : `${home}/.metascript`);
const EXE = windows ? ".exe" : "";

function git(args: string[]): string {
	const r = execFileResult("git", args, SRC);
	if (!r.started || r.exitCode != 0) die(`git ${args.join(" ")} failed: ${r.errorOutput}`);
	return r.output.trim();
}

// Deployed trees must match a commit: BUILD records which one.
const dirty = git(["status", "--porcelain", "--", "src", "std", "runtime"]);
if (dirty != "") {
	die(`${SRC} holds uncommitted work under: src std runtime\n${dirty}\nsync from a clean worktree of main: tools/wt.sh new <name>`);
}

let changes = 0;

function sameFile(a: string, b: string): boolean {
	if (!exists(b) || fileSize(a) != fileSize(b)) return false;
	const x = readFile(a);
	const y = readFile(b);
	return x.ok && y.ok && x.value == y.value;
}

function put(from: string, to: string): void {
	if (sameFile(from, to)) return;
	changes = changes + 1;
	if (check) {
		console.log(`  would copy ${to}`);
		return;
	}
	if (!copyFile(from, to).ok) die(`cannot copy ${from} -> ${to}`);
}

// The destination becomes an exact copy of the source: entries missing from the
// source are deleted, as `rsync -a --delete` did.
function mirror(from: string, to: string): void {
	if (!check) ensureDir(to);
	const keep: string[] = [];
	for (const e of readDir(from)) {
		const name = e.endsWith("/") ? e.slice(0, e.length - 1) : e;
		keep.push(name);
		if (isDir(`${from}/${name}`)) {
			mirror(`${from}/${name}`, `${to}/${name}`);
		} else {
			put(`${from}/${name}`, `${to}/${name}`);
		}
	}
	if (!exists(to)) return;
	for (const e of readDir(to)) {
		const name = e.endsWith("/") ? e.slice(0, e.length - 1) : e;
		if (keep.includes(name)) continue;
		changes = changes + 1;
		if (check) {
			console.log(`  would delete ${to}/${name}`);
		} else if (!removeAll(`${to}/${name}`).ok) {
			die(`cannot delete ${to}/${name}`);
		}
	}
}

function syncTree(rel: string): void {
	changes = 0;
	mirror(`${SRC}/${rel}`, `${DEST}/${rel}`);
	console.log(check ? `${rel}/: ${changes} file(s) would change` : `synced ${rel}/ → ${DEST}/${rel}/ (${changes} changed)`);
}

if (!check) {
	ensureDir(`${DEST}/bin`);
}

if (syncBinary) {
	const built = exists(`${SRC}/msc${EXE}`) ? `${SRC}/msc${EXE}` : `${SRC}/msc`;
	if (!exists(built)) die(`${SRC}/msc not found. Build it first:\n  msc build src/index.ms --gc=drc --danger --output=msc`);
	const srcCommitTime = git(["log", "-1", "--format=%ct", "--", "src"]).parseFloat();
	if (modifiedTime(built) < srcCommitTime) die(`${built} is older than the last commit under src/. Rebuild it first.`);
	const installed = `${DEST}/bin/msc${EXE}`;
	if (check) {
		console.log(`would: copy ${built} → ${installed}`);
	} else {
		const backup = `${installed}.bak-${modifiedTime(installed)}`;
		if (exists(installed) && !rename(installed, backup).ok) die(`cannot move ${installed} aside to ${backup}`);
		if (!copyFile(built, installed).ok) {
			if (exists(backup)) rename(backup, installed);
			die(`cannot install ${installed}`);
		}
		if (!windows) chmod(installed, 493);
		// A second, extension-less binary beside msc.exe shadows it in POSIX shells.
		if (windows && exists(`${DEST}/bin/msc`)) removeAll(`${DEST}/bin/msc`);
		console.log(`synced binary → ${installed}`);
	}
}

syncTree("src/module/cparse/include");
syncTree("std");
syncTree("runtime");
for (const lib of ["argon2", "mbedtls", "miniz", "monocypher"]) {
	const dir = `${SRC}/vendor/${lib}`;
	if (!isDir(dir)) continue;
	if (readDir(dir).length == 0) die(`${dir} is empty; syncing it would delete the installed copy`);
	syncTree(`vendor/${lib}`);
}

function recordBuild(key: string): void {
	const stamp = git(["log", "-1", "--format=%h %cI"]);
	const path = `${DEST}/BUILD`;
	const old = readFile(path);
	let text = "";
	if (old.ok) {
		for (const line of old.value.split("\n")) {
			if (line != "" && !line.startsWith(`${key} `)) text = text + line + "\n";
		}
	}
	writeFile(path, `${text}${key} ${stamp}\n`);
}

if (!check) {
	if (syncBinary) recordBuild("binary");
	recordBuild("support");
	const version = execFileResult(`${DEST}/bin/msc${EXE}`, ["--version"]);
	console.log("");
	console.log(version.output.trim());
	const build = readFile(`${DEST}/BUILD`);
	if (build.ok) console.log(build.value.trim());
}

// Sync a locally built msc and its support trees to ~/.metascript/ so downstream
// projects pick them up via $PATH.
//
// Run from a clean worktree of main, with the msc you just built:
//   ./msc run --target=raiser tools/syncLocalBinary.ms [check] [no-binary | web]
// check prints what would change; no-binary syncs the support trees only;
// web builds only the browser compiler (msc.js, msc.wasm, msc.data with std) into web/.
// A session whose work runs on the installed msc holds the destination meanwhile:
//   msc run --target=raiser tools/syncLocalBinary.ms hold <owner> <minutes> [pid]
//   msc run --target=raiser tools/syncLocalBinary.ms release <owner>
// A hold refuses every sync until released, expired, or its pid (bash's $$) has exited.
// Env: MSC_INSTALL_DIR overrides the destination; MSC_SYNC_BREAK_HOLD=<owner> breaks a hold.
import { argv, cwd, env, execFileResult, exit, platform } from "std/process";
import { chmod, copyFile, ensureDir, exists, fileSize, isDir, modifiedTime, readDir, readFile, realpath, removeAll, rename, writeFile } from "std/fs";

const windows = platform == "windows";

function slashes(p: string): string {
	return p.replaceAll("\\", "/");
}

function die(msg: string): never {
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
let web = false;
for (const a of argv) {
	if (a == "check") check = true;
	if (a == "no-binary") syncBinary = false;
	if (a == "web") web = true;
}

const SRC = scriptRoot();
const home = env.get("HOME") != "" ? env.get("HOME") : env.get("USERPROFILE");
const DEST = slashes(env.get("MSC_INSTALL_DIR") != "" ? env.get("MSC_INSTALL_DIR") : `${home}/.metascript`);
const EXE = windows ? ".exe" : "";

const VENDOR_LIBS = ["argon2", "mbedtls", "miniz", "monocypher"];

const HOLD = `${DEST}/HOLD`;
const BREAK_HOLD = env.get("MSC_SYNC_BREAK_HOLD");

interface Hold {
	owner: string;
	pid: string;
	until: number;
}

function argAfter(word: string, n: number): string {
	const i = argv.indexOf(word);
	const k = i + n;
	return i >= 0 && k < argv.length ? argv[k] : "";
}

function nowFromFileMtime(): number {
	const probe = `${DEST}/.clock`;
	ensureDir(DEST);
	if (!writeFile(probe, "").ok) die(`cannot write ${probe}`);
	const now = modifiedTime(probe);
	removeAll(probe);
	return now;
}

function isPid(p: string): boolean {
	return p == "" || `${Math.floor(p.parseFloat())}` == p;
}

function readHold(): Hold | null {
	if (!exists(HOLD)) return null;
	const text = readFile(HOLD);
	if (!text.ok) die(`cannot read ${HOLD}`);
	let owner = "";
	let pid = "";
	let until: number = 0;
	for (const line of text.value.split("\n")) {
		const sp = line.indexOf(" ");
		if (sp < 0) continue;
		const key = line.slice(0, sp);
		const value = line.slice(sp + 1).trim();
		if (key == "owner") owner = value;
		if (key == "pid") pid = value;
		if (key == "until") until = value.parseFloat();
	}
	if (owner == "" || until == 0 || !isPid(pid)) {
		die(`${HOLD} is malformed (needs owner and until lines, pid a number):\n${text.value}`);
	}
	return { owner, pid, until };
}

function pidAlive(pid: string): boolean {
	if (pid == "") return true;
	const r = execFileResult("bash", ["-c", `kill -0 ${pid}`]);
	return !r.started || r.exitCode == 0;
}

function staleReason(h: Hold, now: number): string {
	if (now >= h.until) return `expired ${Math.floor((now - h.until) / 60)} min ago`;
	if (!pidAlive(h.pid)) return `pid ${h.pid} is gone`;
	return "";
}

function describe(h: Hold, now: number): string {
	const pid = h.pid == "" ? "" : `, pid ${h.pid}`;
	return `held by ${h.owner}${pid}, ${Math.ceil((h.until - now) / 60)} min left`;
}

if (argv.includes("hold")) {
	const owner = argAfter("hold", 1);
	const minutes = argAfter("hold", 2).parseFloat();
	const pid = argAfter("hold", 3);
	if (owner == "" || !(minutes > 0) || !isPid(pid)) die("usage: syncLocalBinary.ms hold <owner> <minutes> [pid]");
	const now = nowFromFileMtime();
	const held = readHold();
	if (held != null && held.owner != owner && staleReason(held, now) == "" && BREAK_HOLD != held.owner) {
		die(`${DEST} is ${describe(held, now)}; ask ${held.owner} to release it`);
	}
	if (!writeFile(HOLD, `owner ${owner}\npid ${pid}\nuntil ${now + minutes * 60}\n`).ok) die(`cannot write ${HOLD}`);
	console.log(`${DEST} ${describe(readHold()!, now)}; release: syncLocalBinary.ms release ${owner}`);
	exit(0);
}

if (argv.includes("release")) {
	const owner = argAfter("release", 1);
	if (owner == "") die("usage: syncLocalBinary.ms release <owner>");
	const held = readHold();
	if (held == null) {
		console.log(`${DEST} holds no HOLD`);
		exit(0);
	}
	if (held.owner != owner && BREAK_HOLD != held.owner) die(`${HOLD} belongs to ${held.owner}, not ${owner}`);
	if (!removeAll(HOLD).ok) die(`cannot remove ${HOLD}`);
	console.log(`released ${DEST} (was held by ${held.owner})`);
	exit(0);
}

const held = readHold();
if (held != null) {
	const now = nowFromFileMtime();
	const stale = staleReason(held, now);
	if (stale != "") {
		console.log(`warning: ignoring the stale ${HOLD} of ${held.owner}: ${stale}`);
		if (!check) removeAll(HOLD);
	} else if (BREAK_HOLD == held.owner) {
		console.log(`warning: breaking the hold of ${held.owner} (MSC_SYNC_BREAK_HOLD); ${describe(held, now)}`);
		if (!check) removeAll(HOLD);
	} else if (check) {
		console.log(`note: ${DEST} is ${describe(held, now)}; a sync now would refuse`);
	} else {
		die(`${DEST} is ${describe(held, now)}.\nwait for its release, or ask ${held.owner}; only the person may set MSC_SYNC_BREAK_HOLD=${held.owner} to break it`);
	}
}

function gitIn(dir: string, args: string[]): string {
	const r = execFileResult("git", args, dir);
	if (!r.started || r.exitCode != 0) die(`git ${args.join(" ")} failed in ${dir}: ${r.errorOutput}`);
	return r.output.trim();
}

function git(args: string[]): string {
	return gitIn(SRC, args);
}

// Deployed trees must match a commit: BUILD records which one.
const dirty = git(["status", "--porcelain", "--", "src", "std", "runtime"]);
if (dirty != "") {
	die(`${SRC} holds uncommitted work under: src std runtime\n${dirty}\nsync from a clean worktree of main: tools/wt.sh new <name>`);
}

// Ignored files pass: mbedtls builds from driver wrappers its upstream generates and ignores.
let vendorDirt = "";
for (const lib of VENDOR_LIBS) {
	if (git(["status", "--porcelain", "--", `vendor/${lib}`]) == "") continue;
	vendorDirt = `${vendorDirt}vendor/${lib}:\n${gitIn(`${SRC}/vendor/${lib}`, ["status", "--porcelain"])}\n`;
}
if (vendorDirt != "") {
	die(`${SRC} holds vendor files their pinned submodule commits do not track:\n${vendorDirt}deploy only the pinned commits: remove these files, or pin a commit that tracks them. A header the build needs lives under runtime/ (miniz_export.h: runtime/compress/).`);
}

function builder(): string {
	const built = exists(`${SRC}/msc${EXE}`) ? `${SRC}/msc${EXE}` : `${SRC}/msc`;
	if (!exists(built)) die(`${SRC}/msc not found. Build it first:\n  msc build src/index.ms --danger --output=msc`);
	const srcCommitTime = git(["log", "-1", "--format=%ct", "--", "src"]).parseFloat();
	if (modifiedTime(built) < srcCommitTime) die(`${built} is older than the last commit under src/. Rebuild it first.`);
	return built;
}

const LINK_WINDOW_SECONDS = 900;

function unquote(arg: string): string {
	return arg.length >= 2 && arg.startsWith("\"") && arg.endsWith("\"") ? arg.slice(1, arg.length - 1) : arg;
}

function samePath(a: string, b: string): boolean {
	return windows ? a.toLowerCase() == b.toLowerCase() : a == b;
}

function foreignBuildRoot(built: string): string {
	const rsp = `${built}_link.rsp`;
	if (!exists(rsp)) return `${rsp} is missing, so nothing shows which std/ and runtime/ ${built} was compiled against`;
	const age = modifiedTime(built) - modifiedTime(rsp);
	if (age < 0) return `${rsp} was written ${Math.round(-age)} s after ${built}, by a later build that did not produce this binary`;
	if (age > LINK_WINDOW_SECONDS) {
		return `${rsp} was written ${Math.round(age)} s before ${built}, longer than the ${LINK_WINDOW_SECONDS} s a link takes, so it describes another build`;
	}
	const text = readFile(rsp);
	if (!text.ok) return `cannot read ${rsp}`;
	const own = slashes(realpath(SRC));
	const roots: string[] = [];
	for (const line of text.value.split("\n")) {
		const arg = slashes(unquote(line.trim()));
		if (!arg.startsWith("-iquote")) continue;
		const at = arg.indexOf("/std/");
		if (at < 0) continue;
		const root = arg.slice("-iquote".length, at);
		if (!roots.includes(root)) roots.push(root);
	}
	if (roots.length == 0) return `${rsp} names no -iquote <root>/std/ flag, so nothing shows which std/ and runtime/ ${built} was compiled against`;
	for (const root of roots) {
		if (!samePath(root, own)) return `${built} was compiled against the std/ and runtime/ of ${root}, not of ${own} that this sync publishes`;
	}
	return "";
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

function wanted(roots: string[], path: string): boolean {
	for (const root of roots) {
		if (path == root || path.startsWith(`${root}/`) || root.startsWith(`${path}/`)) return true;
	}
	return false;
}

// The destination becomes an exact copy of the source without its `.git`: entries missing
// from the source or outside `roots` are deleted, as `rsync -a --delete` did.
function mirror(from: string, to: string, roots: string[]): void {
	if (!check) ensureDir(to);
	const keep: string[] = [];
	for (const e of readDir(from)) {
		const name = e.endsWith("/") ? e.slice(0, e.length - 1) : e;
		if (name == ".git" || !wanted(roots, `${from}/${name}`)) continue;
		keep.push(name);
		if (isDir(`${from}/${name}`)) {
			mirror(`${from}/${name}`, `${to}/${name}`, roots);
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

function syncRoots(rel: string, roots: string[]): void {
	changes = 0;
	mirror(`${SRC}/${rel}`, `${DEST}/${rel}`, roots);
	console.log(check ? `${rel}/: ${changes} file(s) would change` : `synced ${rel}/ → ${DEST}/${rel}/ (${changes} changed)`);
}

function syncTree(rel: string): void {
	syncRoots(rel, [`${SRC}/${rel}`]);
}

function embedImportClosure(): string[] {
	const work = `${SRC}/out/syncEmbed`;
	removeAll(work);
	ensureDir(work);
	const r = execFileResult(builder(), ["build", `${SRC}/src/embed/index.ms`, "--emit=c", "--gendeps", "--no-color"], work);
	const deps = readFile(`${work}/out/debug/index.deps`);
	removeAll(work);
	if (!r.started || r.exitCode != 0 || !deps.ok) die(`cannot list the modules src/embed imports:\n${r.output}${r.errorOutput}`);
	const root = slashes(realpath(SRC));
	const files: string[] = [];
	for (const line of deps.value.split("\n")) {
		const path = slashes(line.trim());
		if (path == "" || path.startsWith(`${root}/std/`)) continue;
		if (!path.startsWith(`${root}/src/`)) die(`src/embed imports ${path}, outside the src and std trees the sync installs`);
		files.push(`${SRC}/${path.slice(root.length + 1)}`);
	}
	return files;
}

if (web) {
	const out = `${DEST}/web`;
	if (check) {
		console.log(`would: build the browser compiler → ${out}/`);
		exit(0);
	}
	const next = `${out}.next`;
	removeAll(next);
	ensureDir(next);
	const link = `-sSTACK_SIZE=8MB -sMODULARIZE=1 -sEXPORT_NAME=createMsc -sINVOKE_RUN=0 -sEXPORTED_RUNTIME_METHODS=FS,callMain --preload-file ${SRC}/std@/std --exclude-file=*.md`;
	const r = execFileResult(builder(), ["build", "src/index.ms", "--os=emcc", "--release", `--passL=${link}`, `--output=${next}/msc.js`, "--no-color"], SRC);
	if (!r.started || r.exitCode != 0) die(`the browser compiler did not build:\n${r.output}${r.errorOutput}`);
	removeAll(`${next}/msc.js_link.rsp`);
	removeAll(out);
	if (!rename(next, out).ok) die(`cannot move ${next} to ${out}`);
	recordBuild("web");
	console.log(`synced browser compiler → ${out}/`);
	exit(0);
}

const srcRoots = embedImportClosure();
srcRoots.push(`${SRC}/src/module/cparse/include`);

if (!check) {
	ensureDir(`${DEST}/bin`);
}

if (syncBinary) {
	const built = builder();
	const installed = `${DEST}/bin/msc${EXE}`;
	const foreign = foreignBuildRoot(built);
	if (foreign != "") {
		const fix = `rebuild it from this checkout: cd ${SRC} && ./msc build src/index.ms --gc=drc --danger --cc=clang --output=msc`;
		if (check) {
			console.log(`note: a sync now would refuse: ${foreign}\n${fix}`);
		} else {
			die(`${foreign}\n${fix}`);
		}
	}
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

syncRoots("src", srcRoots);
syncTree("std");
syncTree("runtime");
for (const lib of VENDOR_LIBS) {
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

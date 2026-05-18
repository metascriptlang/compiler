// Update-check + `msc upgrade` command.
//
// Subtle notice (two lines on stdout) when a newer release is on GitHub.
// Cache result for 24h in ~/.metascript/.update-check so we don't hammer the API.
// Opt-out via MSC_NO_UPDATE_CHECK / CI / GITHUB_ACTIONS env vars.
//
// `msc upgrade` re-runs install.sh / install.ps1 — single source of truth
// for install logic.

import { FetchOptions } from "std/http/types";
import { createHeaders, setHeader } from "std/http/headers";
import { readFile, writeFile, readDir, remove } from "std/fs";
import { env, exec } from "std/process";
import { VERSION } from "./usage";
import { compareVersionStrings } from "./package/version";
import { CliOptions } from "./options";
import { resolveRuntimeDir } from "../utils/path";
import { yellow, dim, bold, cyan } from "../utils/color";

// ===== Constants =====

const RELEASES_API = "https://api.github.com/repos/metascriptlang/compiler/releases/latest";
const CACHE_TTL_MS: number = 24 * 60 * 60 * 1000;  // 24 hours
const HTTP_TIMEOUT_MS: int32 = 1500;               // snappy; slow network → silent skip
const INSTALL_SH_URL  = "https://metascriptlang.org/install.sh";
const INSTALL_PS1_URL = "https://metascriptlang.org/install.ps1";

// ===== Cache =====

interface UpdateCache {
	lastCheckMs: number;
	latestVersion: string;  // "" when unknown
}

function emptyCache(): UpdateCache {
	return { lastCheckMs: 0, latestVersion: "" };
}

function cacheFilePath(): string {
	const home = env.get("HOME");
	// Windows fallback — HOME isn't set by default there.
	const base = home !== "" ? home : env.get("USERPROFILE");
	if (base === "") return "";
	return base + "/.metascript/.update-check";
}

function readCache(): UpdateCache {
	const path = cacheFilePath();
	if (path === "") return emptyCache();
	// readFile returns Err for missing/unreadable — no need to pre-check exists.
	const r = readFile(path);
	if (!r.ok) return emptyCache();
	const lines = r.value.split("\n");
	if (lines.length < 2) return emptyCache();
	const ts = parseFloat(lines[0].trim());
	const ver = lines[1].trim();
	// parseFloat on a non-number returns NaN; NaN comparisons are always false,
	// so ts !== ts is true iff ts is NaN. Avoids isNaN (not in the prelude).
	if (ts !== ts) return emptyCache();
	return { lastCheckMs: ts, latestVersion: ver };
}

function writeCache(c: UpdateCache): void {
	const path = cacheFilePath();
	if (path === "") return;
	writeFile(path, `${c.lastCheckMs}\n${c.latestVersion}\n`);  // silent on failure
}

// ===== HTTP =====

// GitHub release response is large (JSON with body, assets, etc.) — we only need
// "tag_name":"v0.2.5". A focused string search is cheaper and avoids the JSON parser.
function extractTagName(body: string): string {
	const key = "\"tag_name\"";
	const keyIdx = body.indexOf(key, 0);
	if (keyIdx < 0) return "";
	// Find the value string: : "<value>"
	let i = keyIdx + key.length;
	while (i < body.length && body.charAt(i) !== "\"") { i = i + 1; }
	if (i >= body.length) return "";
	const start = i + 1;
	let end = start;
	while (end < body.length && body.charAt(end) !== "\"") { end = end + 1; }
	if (end >= body.length) return "";
	let tag = body.slice(start, end);
	if (tag.length > 0 && tag.charAt(0) === "v") tag = tag.slice(1, tag.length);
	return tag;
}

function fetchLatestVersion(): string {
	const hdrs = createHeaders();
	setHeader(hdrs, "user-agent", `msc/${VERSION}`);
	setHeader(hdrs, "accept", "application/vnd.github+json");
	const opts: FetchOptions = {
		method: "GET", body: "", headers: hdrs,
		timeout: HTTP_TIMEOUT_MS, maxRedirects: 3,
	};
	const r = fetch(RELEASES_API, opts);
	if (!r.ok) return "";
	if (r.value.status !== 200) return "";
	return extractTagName(r.value.body);
}

// ===== Opt-out =====

function shouldSkipCheck(): boolean {
	if (env.get("MSC_NO_UPDATE_CHECK") !== "") return true;
	if (env.get("CI") !== "") return true;
	if (env.get("GITHUB_ACTIONS") !== "") return true;
	return false;
}

// ===== Public API =====

// Called at end of allowlisted commands. Silent on any failure.
export function maybeShowUpdateNotice(): void {
	if (shouldSkipCheck()) return;

	const now = performance.now();
	let cache = readCache();
	const age = now - cache.lastCheckMs;

	// Stale or never checked → refresh. Clock skew (negative age) → treat as fresh.
	if (age < 0 || age > CACHE_TTL_MS) {
		const latest = fetchLatestVersion();
		if (latest !== "") {
			cache = { lastCheckMs: now, latestVersion: latest };
			writeCache(cache);
		}
	}

	if (cache.latestVersion === "") return;
	if (compareVersionStrings(cache.latestVersion, VERSION) <= 0) return;

	// Notice: one line, indented, yellow. Goes to stdout (same stream as command
	// output) so it shows in `msc run ... | cat`. If that bothers users, they
	// set MSC_NO_UPDATE_CHECK=1.
	console.log("");
	console.log(`  ${yellow("→")} ${bold("msc")} ${cache.latestVersion} is available ${dim(`(you have ${VERSION})`)}`);
	console.log(`    Run: ${cyan("msc upgrade")}`);
}

// ===== Upgrade command =====

// Windows detection via env vars (no std/os dependency — avoids Bun transpiler
// parse errors on export-extern syntax during stage-1 hosting).
function isWindows(): boolean {
	return env.get("OS") === "Windows_NT" || env.get("SystemRoot") !== "";
}

export function cmdUpgrade(opts: CliOptions): number {
	const cmd = isWindows()
		? `powershell -ExecutionPolicy Bypass -NoProfile -Command "irm ${INSTALL_PS1_URL} | iex"`
		: `curl -fsSL ${INSTALL_SH_URL} | sh`;
	console.log("Running installer...");
	const r = exec(cmd);
	if (r.ok) {
		if (r.value !== "") console.log(r.value);
		return 0;
	}
	if (r.error.output !== "") console.log(r.error.output);
	if (r.error.errorOutput !== "") console.log(r.error.errorOutput);
	console.log(`${yellow("warn")}: installer exited with code ${r.error.exitCode}`);
	return r.error.exitCode !== 0 ? r.error.exitCode : 1;
}

// Windows only: delete stale msc.exe.bak-* files left by previous upgrades.
// install.ps1 renames the running msc.exe to msc.exe.bak-<ts> before writing
// the new one (Windows can't overwrite a locked EXE's content, but rename IS
// allowed). Once the old msc exits, Windows releases the handle and the next
// msc invocation can delete the stale backup. Silent on any failure.
export function sweepUpgradeBackups(): void {
	if (!isWindows()) return;
	const root = resolveRuntimeDir();
	if (root === "") return;
	const binDir = `${root}/bin`;
	const entries = readDir(binDir);
	for (const e of entries) {
		// readDir marks directories with trailing "/" — skip those.
		if (e.length > 0 && e.charAt(e.length - 1) === "/") continue;
		if (!e.startsWith("msc.exe.bak-")) continue;
		remove(`${binDir}/${e}`);  // Result discarded: if still locked, try next time.
	}
}

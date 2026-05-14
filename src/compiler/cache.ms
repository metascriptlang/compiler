// Fingerprint-based compilation cache (reference-aligned).
//
// Two layers:
//   1. Per-file cache: fingerprint each @compile/.c file, skip recompilation if unchanged
//   2. Project-level cache: hash all source deps + flags, skip entire pipeline if unchanged
//
// Reference alignment:
//   externalFileChanged          → isCompileCached + computeFingerprint
//   addExternalFileToCompile     → isCompileCached (tryRemoveFile on miss)
//   cacheSuffix               → initCache mode suffix (_d/_r)
//   optForceFullMake             → initCache forceRebuild flag
//   changeDetectedViaJsonBuild   → projectCacheChanged
//   writeJsonBuildInstructions   → writeProjectCache
//   BuildCache                   → project cache file (key=value format)

import { exec, env, platform } from "std/process";
import { exists, readFile, writeFile, rename, copyFile, fileSize, remove, readDir } from "std/fs";
import { ensureDir } from "./io";
import { getCompilerName, modeFlags } from "./cc";
import { djb2, fingerprint, hashToHex } from "std/hash";
import { VERSION } from "./usage";

// ===== Hash Functions =====

// Dual hash of string content → "hexHash_hexFingerprint" (stable, 64-bit effective).
export function hashContent(s: string): string {
	return `${hashToHex(djb2(s))}_${hashToHex(fingerprint(s))}`;
}

// Hash a file's content. Returns "hash:byteLength" string.
function hashFile(path: string): string {
	const src = try readFile(path) catch "";
	return `${hashContent(src)}:${src.byteLength}`;
}

// ===== Cache State =====

let _cacheDir = "";
let _forceRebuild = false;

// Initialize cache with build mode and force flag. Must be called before any cache operations.
// Reference-aligned: cacheSuffix (_d/_r), optForceFullMake (force bypass).
export function initCache(mode: number, forceRebuild: boolean): void {
	const modeDir = mode >= 1 ? "release" : "debug";
	_cacheDir = `out/${modeDir}/.cache`;
	ensureDir(_cacheDir);
	_forceRebuild = forceRebuild;
}

function getCacheDir(): string {
	if (_cacheDir !== "") return _cacheDir;
	_cacheDir = "out/debug/.cache";
	ensureDir(_cacheDir);
	return _cacheDir;
}

// ===== Per-File Cache (Layer 1) =====

// Sanitize a file path to a safe flat filename.
// Must handle every char that's illegal on ANY target filesystem because the
// same cache layout is shared across OSes (macOS, Linux, Windows).
//
// Distinct multi-char escapes avoid collisions across substitutions:
//   / \ → _d_  (directory separator; same mapping since both mean "dir")
//   . → _x_   (extension / dotted segment)
//   space → _s_
//   : → _c_   (Windows drive letter / alt data stream separator)
//   < > " | ? * → _e_  (Windows reserved path chars — any collapses to same
//                      escape since they should never appear in real module paths)
function sanitizePath(path: string): string {
	let result = "";
	let i = 0;
	while (i < path.length) {
		const ch = path.charAt(i);
		result = result + match (ch) {
			"/" | "\\" => "_d_",
			"." => "_x_",
			" " => "_s_",
			":" => "_c_",
			"<" | ">" | "\"" | "|" | "?" | "*" => "_e_",
			_ => ch,
		};
		i = i + 1;
	}
	return result;
}

// Stable .o path keyed by sanitized source path (unique, readable).
export function stableOFile(srcPath: string): string {
	return `${getCacheDir()}/${sanitizePath(srcPath)}.o`;
}

// Full compile command for fingerprint — includes compiler, -std, mode flags.
export function fullCompileCmd(ccOption: number, mode: number, extraFlags: string): string {
	return `${getCompilerName(ccOption, "")} -std=c11${modeFlags(mode)} ${extraFlags}`;
}

// Fingerprint folds in VERSION so that any msc release that changes runtime/*.h
// (but not the .c bytes) still invalidates every entry — otherwise stale .o with
// old header layout would be served. Also makes the global cache safe across upgrades.
// Folds in host `platform` too: host-native builds don't pass an explicit -target,
// so without this a macOS Mach-O and a Windows PE object would share the same
// fingerprint and collide in the global content-addressed cache (`~/.metascript/cache/objects/`).
// Exported so parallel compile workers can compute per-item fingerprints explicitly
// (avoids any shared module-state read-after-write races).
export function computeFingerprint(srcPath: string, compileCmd: string): string {
	const src = try readFile(srcPath) catch "";
	return `${hashContent(src)}:${src.byteLength}:${compileCmd}:${VERSION}:${platform}`;
}

// ===== Global Content-Addressed Cache =====
//
// Stores .o files keyed by fingerprint under ~/.metascript/cache/objects/.
// Transparent wrapper around the local cache: second-chance lookup on local miss,
// publish on successful compile. Safe across concurrent msc instances because
// .o content is deterministic for a given fingerprint (tmp+rename atomic publish).

// Return global cache dir, or "" if disabled (opt-out) or HOME unknown.
function globalObjectsDir(): string {
	if (env.get("MSC_NO_GLOBAL_CACHE") !== "") return "";
	const home = env.get("HOME");
	const base = home !== "" ? home : env.get("USERPROFILE");
	if (base === "") return "";
	return `${base}/.metascript/cache/objects`;
}

// Convert a fingerprint string into a flat filename hash (stable, collision-safe).
function fingerprintKey(fp: string): string {
	return hashContent(fp);
}

// Path for an entry in the global cache. Empty string means "cache disabled".
function globalOPath(fp: string): string {
	const dir = globalObjectsDir();
	if (dir === "") return "";
	return `${dir}/${fingerprintKey(fp)}.o`;
}

// On local miss, try to restore from global. Returns true if a valid entry was copied in.
// Best-effort: any failure (permission, corrupt entry, disk error) falls through silently.
function tryRestoreFromGlobal(oFile: string, fp: string): boolean {
	const src = globalOPath(fp);
	if (src === "" || !exists(src)) return false;
	// Size sanity: any real .o is >100 bytes. Truncated or empty = corrupt.
	const size = fileSize(src);
	if (size < 100) {
		// Best-effort cleanup; ignore failure.
		remove(src);
		return false;
	}
	const copied = copyFile(src, oFile);
	if (!copied.ok) return false;
	// Verify local size matches what we copied from.
	if (fileSize(oFile) !== size) {
		remove(oFile);
		return false;
	}
	// Write the local .fp sentinel so future runs hit the fast path.
	writeFile(oFile + ".fp", fp);
	return true;
}

// After a successful local compile, publish the .o to the global cache.
// Atomic: write to a per-process tmp path + rename. The tmp suffix includes
// performance.now() so two concurrent msc invocations compiling the same file never
// share a tmp file (which would interleave bytes under "wb" truncate+write).
// Best-effort: failures don't propagate; local cache still works.
function populateGlobal(oFile: string, fp: string): void {
	const dir = globalObjectsDir();
	if (dir === "") return;
	const dst = `${dir}/${fingerprintKey(fp)}.o`;
	// If already populated by another process, skip.
	if (exists(dst)) return;
	ensureDir(dir);
	const tmp = `${dst}.tmp.${performance.now()}`;
	const copied = copyFile(oFile, tmp);
	if (!copied.ok) return;
	// Atomic swap. If it fails, clean up tmp.
	const renamed = rename(tmp, dst);
	if (!renamed.ok) remove(tmp);
}

// Called at msc startup: if the cache was populated by a different VERSION,
// wipe the dir. Guards against stale entries after any upgrade path (msc upgrade,
// brew, manual cp, downgrade). Also sweeps orphan .tmp.<ts> files left by
// populateGlobal if an msc process was killed mid-copy. Idempotent, ~1ms.
export function ensureVersionMarker(): void {
	const dir = globalObjectsDir();
	if (dir === "") return;
	ensureDir(dir);
	const marker = `${dir}/.version`;
	const stored = try readFile(marker) catch "";
	const entries = readDir(dir);
	if (stored !== VERSION) {
		// Mismatch — wipe .o entries and any orphan tmp files. Preserve .version
		// itself so we don't need a second write; it will be overwritten below.
		for (const e of entries) {
			if (e.length === 0) continue;
			if (e === ".version") continue;
			if (e.charAt(e.length - 1) === "/") continue;
			remove(`${dir}/${e}`);
		}
		writeFile(marker, VERSION);
		return;
	}
	// Version matches — still sweep orphan .tmp.<ts> leftovers from crashed runs.
	for (const e of entries) {
		if (e.length === 0) continue;
		// Match "<hash>.o.tmp.<ts>" — contains ".tmp." substring.
		if (e.indexOf(".tmp.", 0) < 0) continue;
		remove(`${dir}/${e}`);
	}
}

// Remove a file if it exists (reference-aligned: tryRemoveFile).
function tryRemoveFile(path: string): void {
	if (exists(path)) {
		remove(path);
	}
}

// Check if cached .o is up-to-date.
// Reference-aligned: addExternalFileToCompile — force bypass + tryRemoveFile on miss.
// Second-chance lookup in the global content-addressed cache on local miss.
// The global cache is content-addressed (hermetic fingerprint), so it's safe to
// consult even under _forceRebuild — reading a byte-identical .o out of the
// global cache is semantically equivalent to recompiling. Users who want a
// truly-from-scratch clang run can set MSC_NO_GLOBAL_CACHE=1.
// Caller is responsible for passing the exact same fingerprint to writeCompileCache
// on the miss path — compute it once via computeFingerprint and thread it through.
export function isCompileCached(oFile: string, fp: string): boolean {
	const fpFile = oFile + ".fp";
	if (!_forceRebuild && exists(oFile) && exists(fpFile)) {
		const stored = try readFile(fpFile) catch "";
		if (stored === fp) return true;
	}
	// Local miss (or forceRebuild bypass of local) — try the global cache.
	if (tryRestoreFromGlobal(oFile, fp)) return true;
	tryRemoveFile(oFile);
	return false;
}

// Write the fingerprint for a compiled .o. Also publishes to the global cache
// (best-effort, silent on failure). Takes fingerprint explicitly so it's safe
// to call from parallel workers without shared module state.
export function writeCompileCache(oFile: string, fp: string): void {
	writeFile(oFile + ".fp", fp);
	populateGlobal(oFile, fp);
}

// ===== Project-Level Cache (Layer 2) =====
//
// Reference-aligned: changeDetectedViaJsonBuildInstructions / writeJsonBuildInstructions.
// Reference BuildCache tracks: cacheVersion, outputFile, outputLastModificationTime,
// compile cmds, link files, linkcmd, configFiles, currentDir, cmdline, depfiles (hash each),
// compiler binary hash.
//
// We track: cacheVersion, outputFile, cmdline (compile+link flags+mode+compiler), depfiles (hash each).
// Stored as simple key=value lines in out/.cache_{d|r}/project.cache.

const CACHE_VERSION = "v2";

// Build the project cache file path.
function projectCacheFile(): string {
	return `${getCacheDir()}/project.cache`;
}

// Build command line fingerprint — everything that affects the build output.
// Cache compiler identity hash (once per build session).
// Captures `clang --version` output to detect version upgrades.
// Reference parity: hashes the compiler binary to detect upgrades.
// Link flags are tracked separately in link.cache.
let _compilerHash = "";
function getCompilerHash(ccOption: number): string {
	if (_compilerHash !== "") return _compilerHash;
	const name = getCompilerName(ccOption, "");
	// New exec() captures stdout; no more tmp-file shell redirect needed.
	const r = exec(`${name} --version 2>&1`);
	const version = r.ok ? r.value : (r.error.stdout !== "" ? r.error.stdout : r.error.stderr);
	if (version.length > 0) {
		_compilerHash = hashContent(version);
	} else {
		_compilerHash = name;
	}
	return _compilerHash;
}

function buildCmdFingerprint(ccOption: number, mode: number, compileFlags: string): string {
	return `${getCompilerHash(ccOption)}:${mode}:${compileFlags}`;
}

// Prefix constants for cache line parsing — avoids magic offset numbers.
const PRE_VERSION = "version:";
const PRE_OUTPUT = "output:";
const PRE_CMDLINE = "cmdline:";
const PRE_OUTHASH = "outputHash:";
const PRE_DEP = "dep:";

// Parse a line from the cache file. Returns value after prefix, or "" if no match.
function parseLineValue(line: string, prefix: string): string {
	if (line.length > prefix.length && line.slice(0, prefix.length) === prefix) {
		return line.slice(prefix.length, line.length);
	}
	return "";
}

// Split stored cache into lines.
function splitLines(s: string): string[] {
	const lines: string[] = [];
	let start = 0;
	let i = 0;
	while (i <= s.length) {
		if (i === s.length || s.charAt(i) === "\n") {
			if (i > start) {
				lines.push(s.slice(start, i));
			}
			start = i + 1;
		}
		i = i + 1;
	}
	return lines;
}

// Cached dep hashes from last projectCacheChanged call — reused by writeProjectCache
// to avoid hashing every source file twice on successful builds.
let _cachedDepHashes: string[] = [];

// Check if the project needs rebuilding.
// Reference-aligned: changeDetectedViaJsonBuildInstructions.
// Returns true if anything changed (= must rebuild). Returns false if up-to-date.
export function projectCacheChanged(
	depPaths: string[],
	outputFile: string,
	ccOption: number,
	mode: number,
	flags: string
): boolean {
	_cachedDepHashes = [];
	if (_forceRebuild) return true;

	const cacheFile = projectCacheFile();
	if (!exists(cacheFile) || !exists(outputFile)) return true;

	const cacheResult = readFile(cacheFile);
	if (!cacheResult.ok) return true;
	const lines = splitLines(cacheResult.value);

	// Parse header fields
	let storedVersion = "";
	let storedOutput = "";
	let storedCmd = "";
	let storedOutputHash = "";
	const storedDeps: string[] = [];

	for (const line of lines) {
		let val = parseLineValue(line, PRE_VERSION);
		if (val !== "") { storedVersion = val; continue; }
		val = parseLineValue(line, PRE_OUTPUT);
		if (val !== "") { storedOutput = val; continue; }
		val = parseLineValue(line, PRE_CMDLINE);
		if (val !== "") { storedCmd = val; continue; }
		val = parseLineValue(line, PRE_OUTHASH);
		if (val !== "") { storedOutputHash = val; continue; }
		val = parseLineValue(line, PRE_DEP);
		if (val !== "") { storedDeps.push(val); }
	}

	const currentCmd = buildCmdFingerprint(ccOption, mode, flags);

	// Reference-aligned: check cacheVersion, outputFile, cmdline
	if (storedVersion !== CACHE_VERSION) return true;
	if (storedOutput !== outputFile) return true;
	if (storedCmd !== currentCmd) return true;

	// Reference-aligned: check output binary modification (detect external tampering)
	const currentOutputHash = hashFile(outputFile);
	if (storedOutputHash !== currentOutputHash) return true;

	// Reference-aligned: check depfiles — hash every source file
	if (storedDeps.length !== depPaths.length) return true;
	let di = 0;
	while (di < depPaths.length) {
		const path = depPaths[di];
		const h = hashFile(path);
		const currentEntry = `${path}=${h}`;
		if (storedDeps[di] !== currentEntry) return true;
		// Cache for writeProjectCache reuse (avoid double-read)
		_cachedDepHashes.push(currentEntry);
		di = di + 1;
	}

	return false;
}

// Write the project cache after a successful build.
// Reference-aligned: writeJsonBuildInstructions.
// Reuses dep hashes from projectCacheChanged when available (avoids re-reading all sources).
export function writeProjectCache(
	depPaths: string[],
	outputFile: string,
	ccOption: number,
	mode: number,
	flags: string
): void {
	let content = `${PRE_VERSION}${CACHE_VERSION}\n`;
	content = content + `${PRE_OUTPUT}${outputFile}\n`;
	content = content + `${PRE_CMDLINE}${buildCmdFingerprint(ccOption, mode, flags)}\n`;
	content = content + `${PRE_OUTHASH}${hashFile(outputFile)}\n`;

	if (_cachedDepHashes.length === depPaths.length) {
		// Reuse hashes from projectCacheChanged — no double-read
		for (const entry of _cachedDepHashes) {
			content = content + `${PRE_DEP}${entry}\n`;
		}
	} else {
		// Fresh computation (first build, or force rebuild skipped projectCacheChanged)
		for (const path of depPaths) {
			content = content + `${PRE_DEP}${path}=${hashFile(path)}\n`;
		}
	}
	writeFile(projectCacheFile(), content);
}

// ===== Per-Module C Code Cache (Layer 3) =====
//
// Caches generated C code per module. Only re-invokes clang if the generated .c
// content or compile command changed. Biggest incremental build win: changing 1
// of 31 modules only recompiles that 1 module.

// Stable .c path for a module, keyed by sanitized module path.
export function stableCFile(modPath: string): string {
	return `${getCacheDir()}/${sanitizePath(modPath)}.c`;
}

// Check if generated C code matches cached version. If match, .o is up to date.
export function isCCodeCached(modPath: string, cCode: string, compileCmd: string): boolean {
	const oFile = stableOFile(modPath);
	const fpFile = oFile + ".cfp";
	const fp = `${hashContent(cCode)}:${compileCmd}`;
	if (_forceRebuild) {
		tryRemoveFile(oFile);
		return false;
	}
	if (!exists(oFile) || !exists(fpFile)) return false;
	const storedFp = try readFile(fpFile) catch "";
	if (storedFp === fp) return true;
	tryRemoveFile(oFile);
	return false;
}

// Write C code cache after successful compilation of a module.
// PREFER `writeCSource` + `writeCompileFingerprint` (split form) for new
// callers — split form prevents Bug 6 (writing fingerprint before compile
// confirms success).
export function writeCCodeCache(modPath: string, cCode: string, compileCmd: string): void {
	writeCSource(modPath, cCode);
	writeCompileFingerprint(modPath, cCode, compileCmd);
}

// Bug 6 fix: write only the .c source. Always safe — .c is debug-friendly
// (lets user inspect generated C even when zig cc fails).
export function writeCSource(modPath: string, cCode: string): void {
	writeFile(stableCFile(modPath), cCode);
}

// Bug 6 fix: write the compile-success fingerprint (.cfp). Call ONLY after
// `compileCFile` returns 0. Cache lookup uses this to skip recompilation —
// writing it on failure causes future runs to false-claim cache hit and try
// to link a partial/empty .o.
export function writeCompileFingerprint(modPath: string, cCode: string, compileCmd: string): void {
	const fp = `${hashContent(cCode)}:${compileCmd}`;
	writeFile(stableOFile(modPath) + ".cfp", fp);
}

// Bug 6 fix: remove cache artifacts after a failed compile so the next run
// triggers a clean retry. Removes .o (potentially partial/empty from failed
// zig cc) + .cfp (defensive — should never be written on failure path post-fix,
// but harmless if accidentally present from older runs).
export function invalidateCompileCache(modPath: string): void {
	tryRemoveFile(stableOFile(modPath));
	tryRemoveFile(stableOFile(modPath) + ".cfp");
}

// ===== Link Cache (Layer 4) =====
//
// Tracks link command + .o file list. When all modules hit .c cache (no recompile)
// and link flags are unchanged and output binary exists, skip re-linking entirely.

const PRE_LINKCMD = "linkcmd:";
const PRE_OFILES = "ofiles:";

function linkCacheFile(): string {
	return `${getCacheDir()}/link.cache`;
}

// Check if link step can be skipped.
export function isLinkCached(oFileList: string, linkFlags: string, outputFile: string): boolean {
	if (_forceRebuild) return false;
	const cFile = linkCacheFile();
	if (!exists(cFile) || !exists(outputFile)) return false;

	const linkResult = readFile(cFile);
	if (!linkResult.ok) return false;
	const lines = splitLines(linkResult.value);

	let storedCmd = "";
	let storedOFiles = "";
	let storedOutputHash = "";

	for (const line of lines) {
		let val = parseLineValue(line, PRE_LINKCMD);
		if (val !== "") { storedCmd = val; continue; }
		val = parseLineValue(line, PRE_OFILES);
		if (val !== "") { storedOFiles = val; continue; }
		val = parseLineValue(line, PRE_OUTHASH);
		if (val !== "") { storedOutputHash = val; continue; }
	}

	if (storedCmd !== linkFlags) return false;
	if (storedOFiles !== oFileList) return false;
	const currentOutputHash = hashFile(outputFile);
	if (storedOutputHash !== currentOutputHash) return false;
	return true;
}

// Write link cache after successful link step.
export function writeLinkCache(oFileList: string, linkFlags: string, outputFile: string): void {
	let content = `${PRE_LINKCMD}${linkFlags}\n`;
	content = content + `${PRE_OFILES}${oFileList}\n`;
	content = content + `${PRE_OUTHASH}${hashFile(outputFile)}\n`;
	writeFile(linkCacheFile(), content);
}

// Export getCacheDir for compile.ms to use in -iquote paths.
export function cacheDir(): string {
	return getCacheDir();
}

// ===== Bug 6 regression tests =====
// Compile-failure invariant: a failed `zig cc` (or any cc) must NOT leave a
// fingerprint behind, otherwise the next run sees a false cache hit and
// tries to link an empty/partial .o. Symptom was a cryptic
// "failed to parse TBD file: NotLibStub" link error masking the real
// compile error. Fix split writeCCodeCache → writeCSource (always) +
// writeCompileFingerprint (only after cc returns 0) + invalidateCompileCache
// (called on cc failure path).

function bug6_clearArtifacts(modPath: string): void {
	tryRemoveFile(stableCFile(modPath));
	tryRemoveFile(stableOFile(modPath));
	tryRemoveFile(stableOFile(modPath) + ".cfp");
}

test "bug6: writeCSource alone does not produce a cache hit" {
	// Split form: source written before compile, but no fingerprint until cc OK.
	// isCCodeCached must stay false so the next run still attempts to compile.
	const modPath = "test/bug6/probe_source_only.ms";
	bug6_clearArtifacts(modPath);
	writeCSource(modPath, "int main(){return 0;}");
	assert exists(stableCFile(modPath));
	assert !exists(stableOFile(modPath) + ".cfp");
	assert !isCCodeCached(modPath, "int main(){return 0;}", "cc -O0");
	bug6_clearArtifacts(modPath);
}

test "bug6: writeCompileFingerprint after writeCSource produces a cache hit" {
	// Happy path: cc returned 0, both .c and .cfp present, .o present →
	// isCCodeCached true so the next run reuses the object.
	const modPath = "test/bug6/probe_happy.ms";
	bug6_clearArtifacts(modPath);
	const cCode = "int main(){return 0;}";
	const cmd = "cc -O0";
	writeCSource(modPath, cCode);
	// Simulate the .o that compileCFile would have produced.
	writeFile(stableOFile(modPath), "");
	writeCompileFingerprint(modPath, cCode, cmd);
	assert exists(stableOFile(modPath) + ".cfp");
	assert isCCodeCached(modPath, cCode, cmd);
	bug6_clearArtifacts(modPath);
}

test "bug6: invalidateCompileCache removes both .o and .cfp" {
	// Failure path: cc returned non-zero. invalidateCompileCache must clean
	// both .o (which may be partial/empty from failed cc) and .cfp (defensive
	// — never written on failure post-fix, but old runs may leave one).
	const modPath = "test/bug6/probe_invalidate.ms";
	bug6_clearArtifacts(modPath);
	writeFile(stableOFile(modPath), "");
	writeFile(stableOFile(modPath) + ".cfp", "stale_fp:cc -O0");
	assert exists(stableOFile(modPath));
	assert exists(stableOFile(modPath) + ".cfp");
	invalidateCompileCache(modPath);
	assert !exists(stableOFile(modPath));
	assert !exists(stableOFile(modPath) + ".cfp");
	bug6_clearArtifacts(modPath);
}

test "bug6: failed-compile sequence yields no cache hit on retry" {
	// End-to-end invariant: simulate the cmdBuildC sequence on cc failure.
	//   1. writeCSource (always)
	//   2. compileCFile fails → invalidateCompileCache, NO writeCompileFingerprint
	// Result must be: next isCCodeCached call returns false → retry compiles.
	const modPath = "test/bug6/probe_fail_seq.ms";
	bug6_clearArtifacts(modPath);
	const cCode = "broken c source";
	const cmd = "cc -O0";
	writeCSource(modPath, cCode);
	// (compileCFile would fail here — skip writeCompileFingerprint)
	invalidateCompileCache(modPath);
	assert !isCCodeCached(modPath, cCode, cmd);
	bug6_clearArtifacts(modPath);
}

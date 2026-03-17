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

import { fileExists, writeFile, exec } from "std/process";
import { readFile } from "std/fs";
import { ensureDir } from "./io";
import { getCompilerName, modeFlags } from "./cc";

// ===== Hash Functions =====

// Byte-level hashing — uses byteLength/byteAt for correct handling of both
// text files (source code) and binary files (compiled output).
// int32 type ensures 32-bit overflow wrapping (enforced by Bun transpiler via | 0).
function djb2(s: string): int32 {
	let h: int32 = 5381;
	let i = 0;
	while (i < s.byteLength) {
		h = h * 33 + s.byteAt(i);
		i = i + 1;
	}
	return h;
}

function fnv1a(s: string): int32 {
	let h: int32 = -2128831035;  // 0x811C9DC5 as int32
	let i = 0;
	while (i < s.byteLength) {
		h = (h ^ s.byteAt(i)) * 16777619;
		i = i + 1;
	}
	return h;
}

// Hex encode int32 as unsigned (0x00000000..0xFFFFFFFF). Preserves full 32-bit range.
function hexHash(n: number): string {
	let v = n;
	if (v < 0) v = v + 4294967296;
	if (v === 0) return "0";
	let result = "";
	while (v > 0) {
		const digit = v % 16;
		if (digit < 10) { result = digit.toString() + result; }
		else {
			let ch = "";
			match (digit) {
				10 => { ch = "a"; },
				11 => { ch = "b"; },
				12 => { ch = "c"; },
				13 => { ch = "d"; },
				14 => { ch = "e"; },
				_ => { ch = "f"; },
			};
			result = ch + result;
		}
		v = (v - digit) / 16;
	}
	return result;
}

// Dual hash of string content → "hexDjb2_hexFnv1a" (stable, 64-bit effective).
export function hashContent(s: string): string {
	return `${hexHash(djb2(s))}_${hexHash(fnv1a(s))}`;
}

// Hash a file's content. Returns "hash:byteLength" string.
function hashFile(path: string): string {
	const src = readFile(path);
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
// Uses distinct separators to avoid collisions:
//   / → _d_  (directory)
//   . → _x_  (extension)
//   space → _s_
function sanitizePath(path: string): string {
	let result = "";
	let i = 0;
	while (i < path.length) {
		const ch = path.charAt(i);
		if (ch === "/") { result = result + "_d_"; }
		else if (ch === ".") { result = result + "_x_"; }
		else if (ch === " ") { result = result + "_s_"; }
		else { result = result + ch; }
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
	return `${getCompilerName(ccOption)} -std=c11${modeFlags(mode)} ${extraFlags}`;
}

function computeFingerprint(srcPath: string, compileCmd: string): string {
	const src = readFile(srcPath);
	return `${hashContent(src)}:${src.byteLength}:${compileCmd}`;
}

let _lastFingerprint = "";

// Remove a file if it exists (reference-aligned: tryRemoveFile).
function tryRemoveFile(path: string): void {
	if (fileExists(path)) {
		exec(`rm -f "${path}"`);
	}
}

// Check if cached .o is up-to-date.
// Reference-aligned: addExternalFileToCompile — force bypass + tryRemoveFile on miss.
export function isCompileCached(srcPath: string, oFile: string, compileCmd: string): boolean {
	_lastFingerprint = computeFingerprint(srcPath, compileCmd);
	if (_forceRebuild) {
		tryRemoveFile(oFile);
		return false;
	}
	const fpFile = oFile + ".fp";
	if (!fileExists(oFile) || !fileExists(fpFile)) return false;
	const stored = readFile(fpFile);
	if (stored === _lastFingerprint) return true;
	tryRemoveFile(oFile);
	return false;
}

// Write the fingerprint computed by the last isCompileCached call.
export function writeCompileCache(oFile: string): void {
	writeFile(oFile + ".fp", _lastFingerprint);
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
// Hashes compiler binary (not just name) to detect version upgrades.
// Reference parity: hashes the compiler binary itself.
// Link flags are tracked separately in link.cache.
// Cache compiler identity hash (once per build session).
// Captures `clang --version` output to detect version upgrades.
// Reference parity: hashes the compiler binary to detect version changes.
let _compilerHash = "";
function getCompilerHash(ccOption: number): string {
	if (_compilerHash !== "") return _compilerHash;
	const name = getCompilerName(ccOption);
	const tmpFile = getCacheDir() + "/_cc_version";
	exec(name + " --version > " + tmpFile + " 2>&1");
	const version = readFile(tmpFile);
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
	if (!fileExists(cacheFile) || !fileExists(outputFile)) return true;

	const stored = readFile(cacheFile);
	const lines = splitLines(stored);

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
	if (!fileExists(oFile) || !fileExists(fpFile)) return false;
	const stored = readFile(fpFile);
	if (stored === fp) return true;
	tryRemoveFile(oFile);
	return false;
}

// Write C code cache after successful compilation of a module.
export function writeCCodeCache(modPath: string, cCode: string, compileCmd: string): void {
	writeFile(stableCFile(modPath), cCode);
	const fp = `${hashContent(cCode)}:${compileCmd}`;
	writeFile(stableOFile(modPath) + ".cfp", fp);
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
	if (!fileExists(cFile) || !fileExists(outputFile)) return false;

	const stored = readFile(cFile);
	const lines = splitLines(stored);

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

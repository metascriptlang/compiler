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

import { env, platform, argv, cwd, execFileCapture, execFileResult, findOnPath } from "std/process";
import { exists, isDir, readFile, writeFile, rename, copyFile, fileSize, modifiedTime, changedTime, changeStamp, remove, removeAll, readDir, realpath } from "std/fs";
import { join, dirname, basename, normalize, isAbsolute } from "std/fs/path";
import { resolveRuntimeDir, resolveArgv0 } from "../utils/path";
import { localCacheDir, globalCacheRoot, stampMemoRoot } from "../utils/cachePaths";
import { collectStaleEntries, collectStaleFlatEntries, markUsed, nowSeconds } from "../utils/stampDirs";
import { ensureDir, atomicWriteFile, renameReplace, stopBuild } from "./io";
import { getCompilerName, compilerInvocation, objectCompileKey, objectCompileArgsKey, objectCompileArgs, objectSearchDirs, buildPch, prefixMapsByToken } from "./cc";
import { hashContent, collectFilesSorted } from "../utils/contentHash";
import { headerQueries, type HeaderQueries } from "./headerQueries";
import { VERSION } from "./usage";
import { selectedNativeToolchain } from "./toolchain";

// ===== Hash Functions =====

// Hash a file's content. Returns "hash:byteLength" string.
function hashFileContent(path: string): string {
	if (!exists(path)) return "absent";
	const src = try readFile(path) catch "";
	return `${hashContent(src)}:${src.byteLength}`;
}

const _hashByStamp = new HashMap<string, string>();

const SETTLED_SECONDS = 2;

function settled(path: string): boolean {
	const changed = changedTime(path);
	return changed >= 0 && changed <= nowSeconds() - SETTLED_SECONDS;
}

function changedSinceBuild(path: string, startedSeconds: number): boolean {
	const changed = changedTime(path);
	return changed < 0 || changed >= Math.floor(startedSeconds);
}

function hashFile(path: string): string {
	const stamp = changeStamp(path);
	if (stamp == "") return hashFileContent(path);
	const known = _hashByStamp.get(path);
	const prefix = `${stamp}|`;
	if (known != null && known.startsWith(prefix)) return known.substring(prefix.length, known.length);
	const hash = hashFileContent(path);
	if (settled(path)) {
		_hashByStamp.set(path, `${prefix}${hash}`);
		_hashMemoWrites += 1;
	}
	return hash;
}

// ===== Toolchain Stamp =====

// Identity of the compiling toolchain beyond VERSION: content hash of the msc
// binary plus every file under the resolved runtime/ AND vendor/ trees. VERSION
// only moves on release, but WIP trees change codegen, runtime/*.h and vendor
// headers while reporting the same version — two such builds must never share
// cache entries of msc's own output (pack, header translations, project cache), and an
// on-disk runtime/vendor header edit must invalidate .o files even when their
// generated C is byte-identical. vendor/ is a real compile input: runtime TUs
// include vendor headers (zip/inflate/deflate → miniz.h, blake2b/chacha20/
// x25519 → monocypher.h) and std modules @compile vendor .c directly.
let _toolchainStamp = "";
let _objectStamp = "";

// Content-hash every file under one support tree into the stamp accumulator.
// Keys are prefixed with the tree name so runtime/x.h and vendor/x.h can never
// collide. A missing tree contributes nothing.
function collectTreeFiles(dir: string, prefix: string, paths: string[], names: string[]): void {
	if (!exists(dir)) return;
	const files: string[] = [];
	collectFilesSorted(dir, "", files);
	for (const f of files) {
		paths.push(join(dir, f));
		names.push(`${prefix}${f}`);
	}
}

const HASH_MEMO_MAGIC = "MSHM1";
let _hashMemoWrites = 0;

function hashMemoPath(subject: string, kind: string): string {
	const root = stampMemoRoot();
	if (root == "") return "";
	return `${root}/${hashContent(subject)}.${kind}`;
}

function readSealed(path: string): string[] {
	if (path == "" || !exists(path)) return [];
	const lines = (try readFile(path) catch "").split("\n");
	if (lines.length < 2 || lines[0] != HASH_MEMO_MAGIC) return [];
	const body = lines.slice(1, lines.length - 1);
	if (lines[lines.length - 1] != hashContent(body.join("\n"))) return [];
	return body;
}

function writeSealed(path: string, body: string[]): void {
	if (path == "") return;
	ensureDir(dirname(path));
	const text = body.join("\n");
	atomicWriteFile(path, `${HASH_MEMO_MAGIC}\n${text}\n${hashContent(text)}`);
}

function loadHashMemo(path: string): void {
	for (const line of readSealed(path)) {
		const tab = line.indexOf("\t");
		if (tab <= 0) continue;
		const file = line.substring(0, tab);
		if (_hashByStamp.get(file) == null) _hashByStamp.set(file, line.substring(tab + 1, line.length));
	}
}

function saveHashMemo(path: string, files: string[]): void {
	const body: string[] = [];
	for (const file of files) {
		const known = _hashByStamp.get(file);
		if (known != null) body.push(`${file}\t${known}`);
	}
	writeSealed(path, body);
}

// Memoized; initCache computes it once on the main thread so parallel compile
// workers only ever read the settled value.
export function toolchainStamp(): string {
	if (_toolchainStamp != "") return _toolchainStamp;
	const exe = resolveArgv0(argv[0]);
	const memo = hashMemoPath(exe, "exe");
	loadHashMemo(memo);
	const writes = _hashMemoWrites;
	const exeHash = hashFile(exe);
	if (_hashMemoWrites != writes) saveHashMemo(memo, [exe]);
	_toolchainStamp = hashContent(`${exeHash}\n${objectStamp()}`);
	return _toolchainStamp;
}

export function objectStamp(): string {
	if (_objectStamp == "") _objectStamp = supportTreesStamp(resolveRuntimeDir());
	return _objectStamp;
}

export function supportTreesStamp(root: string): string {
	if (root == "") return hashContent("");
	return treesStamp(root, [join(root, "runtime"), join(root, "vendor")], ["runtime/", "vendor/"]);
}

// Content stamp of the std tree the prelude pack is built from, remembered by the files'
// change stamps exactly as the support trees are.
export function stdTreeStamp(stdPath: string): string {
	if (stdPath == "") return hashContent("");
	return treesStamp(`std:${stdPath}`, [stdPath], ["std/"]);
}

function treesStamp(subject: string, dirs: string[], prefixes: string[]): string {
	const paths: string[] = [];
	const names: string[] = [];
	for (let t: int32 = 0; t < dirs.length; t += 1) collectTreeFiles(dirs[t], prefixes[t], paths, names);
	const stamps: string[] = [];
	const listed: string[] = [];
	let stamped = true;
	for (let i: int32 = 0; i < paths.length; i += 1) {
		const stamp = changeStamp(paths[i]);
		if (stamp == "") stamped = false;
		stamps.push(stamp);
		listed.push(`${names[i]}\t${stamp}`);
	}
	const listing = hashContent(listed.join("\n"));
	const sumPath = hashMemoPath(subject, "sum");
	const sum = readSealed(sumPath);
	if (stamped && sum.length == 2 && sum[0] == listing) return sum[1];
	const memo = hashMemoPath(subject, "files");
	loadHashMemo(memo);
	const writes = _hashMemoWrites;
	const parts: string[] = [""];
	let remembered = stamped;
	for (let i: int32 = 0; i < paths.length; i += 1) {
		parts.push(`${names[i]}:${hashFile(paths[i])}`);
		const known = _hashByStamp.get(paths[i]);
		if (known == null || !known.startsWith(`${stamps[i]}|`)) remembered = false;
	}
	const stamp = hashContent(parts.join("\n"));
	if (_hashMemoWrites != writes) saveHashMemo(memo, paths);
	if (remembered) writeSealed(sumPath, [listing, stamp]);
	return stamp;
}

// ===== Cache State =====

let _cacheDir = "";
let _forceRebuild = false;
let _nativeProjectDeps: string[] = [];
let _nativeProjectDepSet: HashSet<string> = new HashSet<string>();
let _buildStartedSeconds: number = 0;
let _projectInputKey = "";
let _projectInputHashes: string[] = [];
let _queryRecordDeps: string[] = [];
let _queryRecordDepSet: HashSet<string> = new HashSet<string>();

// Initialize cache with build mode and force flag. Must be called before any cache operations.
// Reference-aligned: cacheSuffix (_d/_r), optForceFullMake (force bypass).
export function initCache(mode: number, forceRebuild: boolean, trimRoots: string[] = []): void {
	_stemRoots = stemRootsOf(trimRoots);
	_projectInputKey = "";
	_projectInputHashes = [];
	_cacheDir = localCacheDir(mode >= 1);
	ensureDir(_cacheDir);
	ensureLocalSchema();
	_forceRebuild = forceRebuild;
	_nativeProjectDeps = [];
	_nativeProjectDepSet = new HashSet<string>();
	_queryRecordDeps = [];
	_queryRecordDepSet = new HashSet<string>();
	_dirNames = new HashMap<string, HashSet<string>>();
	_presenceByRecord = new HashMap<string, string>();
	_subdirs = new HashMap<string, boolean>();
	_dirEntries = new HashMap<string, string[]>();
	_dirFolds = new HashMap<string, HashMap<string, string[]>>();
	_dirUnfoldable = new HashMap<string, string[]>();
	_dirStamps = new HashMap<string, string>();
	_cacheListing = null;
	_buildStartedSeconds = Date.now() / 1000;
	toolchainStamp();
}

function getCacheDir(): string {
	if (_cacheDir != "") return _cacheDir;
	_cacheDir = localCacheDir();
	ensureDir(_cacheDir);
	ensureLocalSchema();
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
// Long absolute paths are shortened below: the readable tail identifies the
// source while a full-path hash preserves uniqueness across roots.
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

const CACHE_STEM_MAX = 64;

let _stemRoots: string[][] = [];

const STEM_ROOT_MARKS = ["@p", "@s", "@k"];

function stemRootsOf(roots: string[]): string[][] {
	const pairs: string[][] = [];
	for (let i = 0; i < roots.length; i++) {
		if (roots[i] != "") pairs.push([roots[i].replaceAll("\\", "/"), STEM_ROOT_MARKS[i]]);
	}
	pairs.sort((a: string[], b: string[]): number => b[0].length - a[0].length);
	return pairs;
}

function stemPath(path: string): string {
	const slashed = path.replaceAll("\\", "/");
	for (const pair of _stemRoots) {
		if (slashed.startsWith(`${pair[0]}/`)) return `${pair[1]}/${slashed.slice(pair[0].length + 1, slashed.length)}`;
	}
	return path;
}

function cacheStem(fullPath: string): string {
	const path = stemPath(fullPath);
	const safe = sanitizePath(path);
	if (safe.length <= CACHE_STEM_MAX) return safe;
	const key = hashContent(path);
	const tailLength = CACHE_STEM_MAX - key.length - 1;
	return safe.slice(safe.length - tailLength, safe.length) + "." + key;
}

// Stable .o path keyed by sanitized source path (unique, readable).
export function stableOFile(srcPath: string): string {
	return `${getCacheDir()}/${cacheStem(srcPath)}.o`;
}

// Short filename-safe key for a fingerprint.
function fpKey(fp: string): string {
	return hashContent(fp).slice(0, 18);
}

export function nativeDepFile(srcPath: string, compileCmd: string): string {
	return `${getCacheDir()}/${cacheStem(srcPath)}.${fpKey(compileCmd)}.d`;
}

function nativeDependencyPaths(srcPath: string, compileCmd: string): string[] {
	return dependencyPathsIn(nativeDepFile(srcPath, compileCmd));
}

const _dependenciesByStamp = new HashMap<string, string>();
let _ownedHeaderPrefix = "";

export function setToolchainHeaderRoot(root: string): void {
	_ownedHeaderPrefix = root == "" ? "" : foldedPath(`${root}/`);
}

function foldedPath(path: string): string {
	const slashed = path.replaceAll("\\", "/");
	return platform == "windows" ? slashed.toLowerCase() : slashed;
}

function dependencyPathsIn(path: string): string[] {
	const stamp = changeStamp(path);
	if (stamp == "") return parseDependencyFile(path);
	const known = _dependenciesByStamp.get(path);
	const prefix = `${stamp}|${_ownedHeaderPrefix}|`;
	if (known != null && known.startsWith(prefix)) {
		const listed = known.substring(prefix.length, known.length);
		return listed == "" ? [] : listed.split("\n");
	}
	const paths = parseDependencyFile(path);
	if (settled(path)) _dependenciesByStamp.set(path, `${prefix}${paths.join("\n")}`);
	return paths;
}

function parseDependencyFile(path: string): string[] {
	const result: string[] = [];
	if (!exists(path)) return result;
	const content = try readFile(path) catch "";
	const n = content.byteLength;
	const colon = content.byteIndexOf(":");
	if (colon < 0) return result;
	let start = -1;
	let escaped = false;
	let i = colon + 1;
	while (i < n) {
		const b = content.byteAt(i);
		if (b == "\\".code && i + 1 < n) {
			const next = content.byteAt(i + 1);
			if (next == "\n".code || next == "\r".code) {
				if (start >= 0) pushDependency(result, dependencyToken(content.byteSlice(start, i), escaped));
				start = -1;
				escaped = false;
				i = next == "\r".code && i + 2 < n && content.byteAt(i + 2) == "\n".code ? i + 3 : i + 2;
				continue;
			}
			if (start < 0) start = i;
			escaped = true;
			i = i + 2;
			continue;
		}
		if (b == " ".code || b == "\t".code || b == "\n".code || b == "\r".code) {
			if (start >= 0) pushDependency(result, dependencyToken(content.byteSlice(start, i), escaped));
			start = -1;
			escaped = false;
		} else if (start < 0) {
			start = i;
		}
		i = i + 1;
	}
	if (start >= 0) pushDependency(result, dependencyToken(content.byteSlice(start, n), escaped));
	return result;
}

export function writePchManifest(depFile: string, manifest: string): boolean {
	const tokens = parseDependencyFile(depFile);
	let first = 0;
	while (first < tokens.length && !tokens[first].endsWith(":")) first += 1;
	if (first == tokens.length) first = -1;
	let body = "";
	for (let i = first + 1; i < tokens.length; i += 1) {
		const path = isAbsolute(tokens[i]) ? tokens[i] : join(cwd(), tokens[i]);
		body = body + `${path}\t${hashFile(path)}\n`;
	}
	if (body == "") return false;
	return atomicWriteFile(manifest, body);
}

export function pchManifestCurrent(manifest: string): boolean {
	const body = try readFile(manifest) catch "";
	if (body == "") return false;
	for (const line of body.split("\n")) {
		if (line == "") continue;
		const tab = line.indexOf("\t", 0);
		if (tab <= 0 || hashFile(line.slice(0, tab)) != line.slice(tab + 1, line.length)) return false;
	}
	return true;
}

function pushDependency(result: string[], path: string): void {
	if (_ownedHeaderPrefix != "" && foldedPath(path).startsWith(_ownedHeaderPrefix)) return;
	result.push(path);
}

function dependencyToken(raw: string, escaped: boolean): string {
	if (!escaped) return raw;
	let out = "";
	let from = 0;
	let i = 0;
	while (i < raw.byteLength) {
		if (raw.byteAt(i) == "\\".code && i + 1 < raw.byteLength) {
			out = out + raw.byteSlice(from, i);
			from = i + 1;
			i = i + 2;
		} else {
			i = i + 1;
		}
	}
	return out + raw.byteSlice(from, raw.byteLength);
}

export function registerNativeDependencies(srcPath: string, compileCmd: string): void {
	registerNativeProjectDep(srcPath);
	for (const path of nativeDependencyPaths(srcPath, compileCmd)) registerNativeProjectDep(path);
}

export function registerCompileTimeRead(path: string): void {
	registerNativeProjectDep(path);
}

function registerNativeProjectDep(path: string): void {
	if (_nativeProjectDepSet.has(path)) return;
	_nativeProjectDepSet.add(path);
	_nativeProjectDeps.push(path);
}

// Local object path keyed by source path AND fingerprint: builds with
// different flags / gc mode / emitted C write DIFFERENT physical files and
// never rename over each other. The old shared-by-srcPath scheme let a drc
// link pick up an orc-published object (undefined msOrcTeardownDepth /
// msUnregisterCycle in the concurrent-build repro) — the atomic publish made
// each file whole, but "whole and wrong config" still fails the link.
export function stableOFileFp(srcPath: string, fp: string): string {
	return `${getCacheDir()}/${cacheStem(srcPath)}.${fpKey(fp)}.o`;
}

// Generated-C path. Generated C is keyed by its content: the emitted C is
// config-dependent too (drc vs orc teardown), so another config writes another
// file, while a change of compile flags alone keeps the name, and with it the
// object bytes the debug info records.
export function stableCFileFp(modPath: string, fp: string): string {
	return `${getCacheDir()}/${cacheStem(modPath)}.${fpKey(fp)}.c`;
}

function ensureLocalSchema(): void {
	const marker = `${getCacheDir()}/.schema-fpkey`;
	if (exists(marker)) return;
	if (!atomicWriteFile(marker, "v1")) {
		console.log(`error: cannot initialize local cache marker: ${marker}`);
		stopBuild();
	}
}

export function fullCompileCmd(ccOption: number, mode: number, extraFlags: string, ccBinary: string, isCpp: boolean = false): string {
	return `${getCompilerHash(ccOption, ccBinary)} ${objectCompileKey(ccOption, ccBinary, isCpp, mode, extraFlags)} ${implicitSearchKey(ccOption, ccBinary, isCpp, mode, extraFlags)}`;
}

// Fingerprint folds in VERSION and objectStamp(): the stamp content-hashes
// every file under runtime/ and vendor/, so a header edit
// that leaves the .c bytes identical still invalidates every entry — a stale
// .o built against an old header layout is never served. VERSION stays folded
// as a belt-and-braces release barrier — redundant with the stamp, but safe.
// Folds in host `platform` too: host-native builds don't pass an explicit -target,
// so without this a macOS Mach-O and a Windows PE object would share the same
// fingerprint and collide in the global content-addressed cache (`~/.metascript/cache/objects/`).
// Exported so parallel compile workers can compute per-item fingerprints explicitly
// (avoids any shared module-state read-after-write races).
const _sourceIdentityByStamp = new HashMap<string, string>();

function sourceIdentity(path: string): string {
	const stamp = changeStamp(path);
	if (stamp == "") return readSourceIdentity(path);
	const known = _sourceIdentityByStamp.get(path);
	const prefix = `${stamp}|`;
	if (known != null && known.startsWith(prefix)) return known.substring(prefix.length, known.length);
	const identity = readSourceIdentity(path);
	if (settled(path)) _sourceIdentityByStamp.set(path, `${prefix}${identity}`);
	return identity;
}

function readSourceIdentity(path: string): string {
	const src = try readFile(path) catch "";
	return `${hashContent(src)}:${src.byteLength}`;
}

export function computeFingerprint(srcPath: string, compileCmd: string): string {
	registerNativeProjectDep(srcPath);
	let result = `${sourceIdentity(srcPath)}:${compileCmd}:${VERSION}:${platform}:${objectStamp()}`;
	const deps = nativeDependencyPaths(srcPath, compileCmd);
	if (deps.length == 0) return result + `:dependencies-unresolved:${srcPath}`;
	for (const path of deps) {
		registerNativeProjectDep(path);
		result = result + `:${path}=${hashFile(path)}`;
	}
	return `${result}:${trackedQueryPresence(nativeDepFile(srcPath, compileCmd))}`;
}

export function publishNativeObject(srcPath: string, compileCmd: string, oFile: string, fp: string, startedSeconds: number, search: HeaderSearch): Result<string, string> {
	const dependencies = nativeDependencyPaths(srcPath, compileCmd);
	const queries = recordQueries(nativeDepFile(srcPath, compileCmd), [srcPath], dependencies, search, [dirname(srcPath)], startedSeconds);
	let settled = dependencies.length > 0 && queries;
	// cc read these before they are hashed here: one written since the compile started may
	// not be what cc read (ccache's include-file-too-new rule), so it keeps the first name.
	for (const path of dependencies) {
		if (changedSinceBuild(path, startedSeconds)) settled = false;
	}
	const settledFp = settled ? computeFingerprint(srcPath, compileCmd) : fp;
	const resolvedFp = presenceTrusted(settledFp) ? settledFp : `${settledFp}:${hashFile(oFile)}`;
	if (resolvedFp == fp) {
		writeCompileCache(oFile, fp);
		return Result.ok(oFile);
	}
	const resolved = stableOFileFp(srcPath, resolvedFp);
	const tmp = `${resolved}.tmp.${performance.now()}`;
	if (!copyFile(oFile, tmp).ok || !renameReplace(tmp, resolved)) {
		tryRemoveFile(tmp);
		if (!exists(resolved)) return Result.err(`failed to publish object ${resolved}`);
	}
	writeCompileCache(resolved, resolvedFp);
	return Result.ok(resolved);
}

// ===== Global Object Store =====

const STORE_FORMAT = "store5";

struct StoreHit {
	object: string;
	deps: string[];
	queries: QueryRecord;
}

let _ccIdentity = "";
let _ccIdentityName = "";
let _dirNames: HashMap<string, HashSet<string>> = new HashMap<string, HashSet<string>>();
let _presenceByRecord: HashMap<string, string> = new HashMap<string, string>();
let _subdirs: HashMap<string, boolean> = new HashMap<string, boolean>();
let _dirEntries: HashMap<string, string[]> = new HashMap<string, string[]>();
let _dirFolds: HashMap<string, HashMap<string, string[]>> = new HashMap<string, HashMap<string, string[]>>();
let _dirUnfoldable: HashMap<string, string[]> = new HashMap<string, string[]>();
let _dirStamps: HashMap<string, string> = new HashMap<string, string>();

function storeRoot(): string {
	const root = globalCacheRoot();
	if (root == "") return "";
	return `${root}/store`;
}

function ccContentIdentity(ccOption: number, ccBinary: string): string {
	const name = getCompilerName(ccOption, ccBinary);
	if (_ccIdentityName == name) return _ccIdentity;
	const command = compilerInvocation(ccOption, ccBinary);
	if (!command.ok) return `unresolved:${name}:${command.error.message}`;
	let path = command.value.path;
	const found = findOnPath(path);
	if (found != "") path = found;
	const root = globalCacheRoot();
	const changed = changedTime(path);
	const memo = root == "" ? "" : `${root}/cc/${hashContent(`${path}:${fileSize(path)}:${changed}${developerToolchain()}`)}`;
	let identity = "";
	if (memo != "" && exists(memo) && modifiedTime(memo) > changed) identity = try readFile(memo) catch "";
	if (identity == "") {
		const args = command.value.args;
		args.push("--version");
		const r = execFileCapture(path, args);
		const version = r.ok ? r.value : r.error.errorOutput;
		identity = hashContent(`${name}:${hashFile(path)}:${version}`);
		if (memo != "" && settled(path)) {
			ensureDir(`${root}/cc`);
			atomicWriteFile(memo, identity);
		}
	}
	_ccIdentityName = name;
	_ccIdentity = identity;
	return identity;
}

function developerToolchain(): string {
	if (platform != "darwin") return "";
	const selected = env.get("DEVELOPER_DIR") != "" ? env.get("DEVELOPER_DIR") : realpath("/var/db/xcode_select_link");
	let text = `\n${selected}\n${env.get("TOOLCHAINS")}\n${env.get("SDKROOT")}`;
	for (const tool of ["usr/bin/clang", "Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"]) {
		const path = `${selected}/${tool}`;
		text = `${text}\n${exists(path) ? changeStamp(path) : "absent"}`;
	}
	return text;
}

export function objectStoreKey(source: string, ccOption: number, ccBinary: string, isCpp: boolean, mode: number, extraFlags: string): string {
	if (storeRoot() == "") return "";
	const args = objectCompileArgsKey(ccOption, ccBinary, isCpp, mode, extraFlags);
	return hashContent(`${STORE_FORMAT}\n${platform}\n${source}\n${ccContentIdentity(ccOption, ccBinary)}\n${args}\n${implicitSearchKey(ccOption, ccBinary, isCpp, mode, extraFlags)}`);
}

export function nativeStoreSource(srcPath: string): string {
	return `${stemPath(absoluteSlashed(srcPath))}\n${hashFile(srcPath)}`;
}

export function moduleStoreSource(cCode: string): string {
	return `${hashContent(cCode)}:${cCode.byteLength}`;
}

function absoluteSlashed(path: string): string {
	const slashed = path.replaceAll("\\", "/");
	const rooted = slashed.startsWith("/") || (slashed.length > 2 && slashed.charAt(1) == ":");
	return normalize(rooted ? slashed : `${cwd()}/${slashed}`).replaceAll("\\", "/");
}

function foldName(name: string): string {
	for (let i = 0; i < name.length; i++) {
		const code = name.charCodeAt(i);
		if ((code >= 65 && code <= 90) || code > 127) return name.toLowerCase();
	}
	return name;
}

function dirNames(dir: string): HashSet<string> {
	const known = _dirNames.get(dir);
	if (known != null) return known;
	dirStamp(dir);
	const names = new HashSet<string>();
	const entries: string[] = [];
	const folds = new HashMap<string, string[]>();
	const unfoldable: string[] = [];
	if (exists(dir)) {
		for (const entry of readDir(dir)) {
			const name = entry.endsWith("/") ? entry.slice(0, entry.length - 1) : entry;
			if (!asciiName(name)) unfoldable.push(name);
			const fold = foldName(name);
			names.add(fold);
			entries.push(name);
			let spelled = folds.get(fold);
			if (spelled == null) {
				spelled = [];
				folds.set(fold, spelled);
			}
			spelled.push(name);
		}
	}
	_dirNames.set(dir, names);
	_dirEntries.set(dir, entries);
	_dirFolds.set(dir, folds);
	_dirUnfoldable.set(dir, unfoldable);
	return names;
}

function dirStamp(dir: string): string {
	const known = _dirStamps.get(dir);
	if (known != null) return known;
	const stamp = !exists(dir) ? "absent" : settled(dir) ? changeStamp(dir) : "";
	_dirStamps.set(dir, stamp);
	return stamp;
}

function knownDir(path: string): boolean {
	const known = _subdirs.get(path);
	if (known != null) return known;
	const found = isDir(path);
	_subdirs.set(path, found);
	return found;
}

function underAnyDir(path: string, dirs: string[]): boolean {
	for (const dir of dirs) {
		if (path.startsWith(`${dir}/`)) return true;
	}
	return false;
}

function headerRels(path: string, dirs: string[]): string[] {
	const rels: string[] = [];
	for (const dir of dirs) {
		if (path.startsWith(`${dir}/`)) rels.push(path.slice(dir.length + 1, path.length));
	}
	if (rels.length > 0) return rels;
	const framework = frameworkRel(path);
	if (framework != "") {
		rels.push(framework);
		return rels;
	}
	const at = path.lastIndexOf("/include/");
	if (at < 0) return rels;
	let tail = path.slice(at + 9, path.length);
	while (tail != "") {
		rels.push(tail);
		const slash = tail.indexOf("/");
		tail = slash < 0 ? "" : tail.slice(slash + 1, tail.length);
	}
	return rels;
}

function frameworkRel(path: string): string {
	for (const part of ["/Headers/", "/PrivateHeaders/"]) {
		const at = path.lastIndexOf(part);
		if (at < 0) continue;
		const bundle = path.slice(0, at);
		if (!bundle.endsWith(".framework")) continue;
		const name = bundle.slice(bundle.lastIndexOf("/") + 1, bundle.length - ".framework".length);
		return `${name}/${path.slice(at + part.length, path.length)}`;
	}
	return "";
}

function relTree(rels: string[]): HashMap<string, string[]> {
	const tree = new HashMap<string, string[]>();
	const placed = new HashSet<string>();
	for (const rel of rels) {
		let prefix = "";
		let rest = rel;
		while (rest != "") {
			const slash = rest.indexOf("/");
			const head = foldName(slash < 0 ? rest : rest.slice(0, slash));
			const full = prefix == "" ? head : `${prefix}/${head}`;
			if (!placed.has(full)) {
				placed.add(full);
				let children = tree.get(prefix);
				if (children == null) {
					children = [];
					tree.set(prefix, children);
				}
				children.push(head);
			}
			prefix = full;
			rest = slash < 0 ? "" : rest.slice(slash + 1, rest.length);
		}
	}
	return tree;
}

function existingCandidates(dir: string, prefix: string, spelledPrefix: string, tree: HashMap<string, string[]>, rels: HashSet<string>, found: string[], walked: string[]): void {
	const wanted = tree.get(prefix);
	if (wanted == null) return;
	walked.push(dir);
	const names = dirNames(dir);
	for (const name of _dirUnfoldable.get(dir) ?? []) found.push(spelledPrefix == "" ? name : `${spelledPrefix}/${name}`);
	const entries = _dirEntries.get(dir) ?? [];
	if (entries.length < wanted.length) {
		for (const name of entries) {
			const fold = foldName(name);
			const full = prefix == "" ? fold : `${prefix}/${fold}`;
			if (rels.has(full) || tree.get(full) != null) existingCandidate(dir, name, full, spelledPrefix, tree, rels, found, walked);
		}
	} else {
		const folds = _dirFolds.get(dir) ?? new HashMap<string, string[]>();
		for (const fold of wanted) {
			if (!names.has(fold)) continue;
			const full = prefix == "" ? fold : `${prefix}/${fold}`;
			for (const name of folds.get(fold) ?? []) existingCandidate(dir, name, full, spelledPrefix, tree, rels, found, walked);
		}
	}
}

function existingCandidate(dir: string, name: string, full: string, spelledPrefix: string, tree: HashMap<string, string[]>, rels: HashSet<string>, found: string[], walked: string[]): void {
	const spelled = spelledPrefix == "" ? name : `${spelledPrefix}/${name}`;
	if (rels.has(full)) found.push(spelled);
	if (tree.get(full) != null && knownDir(`${dir}/${name}`)) existingCandidates(`${dir}/${name}`, full, spelled, tree, rels, found, walked);
}

struct DirPresence {
	found: string;
	walked: string[];
}

struct RememberedPresence {
	presence: string;
	dirs: HashMap<string, DirPresence>;
}

const UNSETTLED_STAMP = "unsettled";

function dirPresence(dir: string, tree: HashMap<string, string[]>, folded: HashSet<string>): DirPresence {
	const found: string[] = [];
	const walked: string[] = [];
	existingCandidates(dir, "", "", tree, folded, found, walked);
	found.sort();
	return { found: found.join("|"), walked };
}

function signatureLine(dir: string, found: string): string {
	return found == "" ? "" : `s\t${dir}\t${found}\n`;
}

function foldedRels(rels: string[]): HashSet<string> {
	const folded = new HashSet<string>();
	for (const rel of rels) folded.add(foldName(rel));
	return folded;
}

function presenceSignature(searched: string[], rels: string[], walked: string[]): string {
	const tree = relTree(rels);
	const folded = foldedRels(rels);
	let signature = "";
	for (const dir of searched) {
		const part = dirPresence(dir, tree, folded);
		for (const path of part.walked) walked.push(path);
		signature = `${signature}${signatureLine(dir, part.found)}`;
	}
	return signature;
}

function searchedDirs(argDirs: string[], includers: string[], deps: string[]): string[] {
	const dirs: string[] = [];
	for (const dir of argDirs) dirs.push(absoluteSlashed(dir));
	const searched: string[] = [];
	for (const dir of dirs) {
		if (!searched.includes(dir)) searched.push(dir);
	}
	for (const dir of includers) {
		const slashed = absoluteSlashed(dir);
		if (!searched.includes(slashed)) searched.push(slashed);
	}
	for (const path of deps) {
		if (underAnyDir(path, dirs) && !searched.includes(dirname(path))) searched.push(dirname(path));
	}
	return searched;
}

export struct HeaderSearch {
	dirs: string[];
	frameworks: string[];
	complete: boolean;
}

struct ImplicitSearch {
	dirs: string[];
	frameworks: string[];
	complete: boolean;
	key: string;
}

const SEARCH_FORMAT = "search1";
const SEARCH_ENV = [
	"CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH", "OBJC_INCLUDE_PATH", "OBJCPLUS_INCLUDE_PATH",
	"SDKROOT", "DEVELOPER_DIR", "TOOLCHAINS", "COMPILER_PATH", "GCC_EXEC_PREFIX", "CCC_OVERRIDE_OPTIONS",
];
const _implicitByKey = new HashMap<string, ImplicitSearch>();

export function headerSearch(ccOption: number, ccBinary: string, isCpp: boolean, mode: number, extraFlags: string): HeaderSearch {
	const implicit = implicitSearch(ccOption, ccBinary, isCpp, mode, extraFlags);
	const dirs = objectSearchDirs(ccOption, ccBinary, isCpp, mode, extraFlags);
	for (const dir of implicit.dirs) {
		if (!dirs.includes(dir)) dirs.push(dir);
	}
	return { dirs, frameworks: implicit.frameworks, complete: implicit.complete };
}

struct SearchProbe {
	path: string;
	args: string[];
	key: string;
}

function searchProbe(ccOption: number, ccBinary: string, isCpp: boolean, mode: number, extraFlags: string): SearchProbe | null {
	const parts = objectCompileArgs(ccOption, ccBinary, isCpp, mode, extraFlags);
	if (!parts.ok) return null;
	const args = withoutSearchDirs(parts.value.lead);
	for (const arg of withoutSearchDirs(parts.value.trail)) args.push(arg);
	let inputs = `${SEARCH_FORMAT}\n${ccContentIdentity(ccOption, ccBinary)}\n${parts.value.command.path}\n${isCpp}\n${prefixMapsByToken(args).join("\n")}`;
	for (const name of SEARCH_ENV) inputs = `${inputs}\n${name}=${env.get(name)}`;
	inputs = `${inputs}${developerToolchain()}`;
	return { path: parts.value.command.path, args, key: hashContent(inputs) };
}

function implicitSearchKey(ccOption: number, ccBinary: string, isCpp: boolean, mode: number, extraFlags: string): string {
	return searchProbe(ccOption, ccBinary, isCpp, mode, extraFlags)?.key ?? "search-unresolved";
}

function implicitSearch(ccOption: number, ccBinary: string, isCpp: boolean, mode: number, extraFlags: string): ImplicitSearch {
	const probe = searchProbe(ccOption, ccBinary, isCpp, mode, extraFlags);
	if (probe == null) return { dirs: [], frameworks: [], complete: false, key: "search-unresolved" };
	const args = probe.args;
	const key = probe.key;
	const known = _implicitByKey.get(key);
	if (known != null) return known;
	const memo = `${getCacheDir()}/search.${key}`;
	let found = parseImplicitSearch(readSealed(memo).join("\n"), key);
	if (!found.complete) {
		const devNull = platform == "windows" ? "NUL" : "/dev/null";
		for (const arg of ["-E", "-v", "-x", isCpp ? "c++" : "c", devNull, "-o", devNull]) args.push(arg);
		const run = execFileResult(probe.path, args);
		found = parseImplicitSearch(run.started && run.pipeOk && run.exitCode == 0 ? run.errorOutput : "", key);
		if (found.complete) writeSealed(memo, searchLines(found));
	}
	_implicitByKey.set(key, found);
	return found;
}

function withoutSearchDirs(args: string[]): string[] {
	const kept: string[] = [];
	for (let i = 0; i < args.length; i++) {
		const kind = ["-iquote", "-isystem", "-idirafter", "-I"].find((flag) => args[i].startsWith(flag)) ?? "";
		if (kind == "") {
			kept.push(args[i]);
		} else if (args[i] == kind) {
			i = i + 1;
		}
	}
	return kept;
}

function searchLines(found: ImplicitSearch): string[] {
	const lines: string[] = ["#include <...> search starts here:"];
	for (const dir of found.dirs) lines.push(` ${dir}`);
	for (const dir of found.frameworks) lines.push(` ${dir} (framework directory)`);
	lines.push("End of search list.");
	return lines;
}

function parseImplicitSearch(text: string, key: string): ImplicitSearch {
	const dirs: string[] = [];
	const frameworks: string[] = [];
	const absent = "ignoring nonexistent directory \"";
	const marked = " (framework directory)";
	let complete = false;
	let listing = false;
	for (const raw of text.split("\n")) {
		const line = raw.endsWith("\r") ? raw.slice(0, raw.length - 1) : raw;
		if (line.startsWith(absent) && line.endsWith("\"")) {
			const dir = absoluteSlashed(line.slice(absent.length, line.length - 1));
			if (!dirs.includes(dir)) dirs.push(dir);
			if (!frameworks.includes(dir)) frameworks.push(dir);
		} else if (line.endsWith(" search starts here:")) {
			listing = true;
		} else if (line == "End of search list.") {
			complete = listing;
			listing = false;
		} else if (listing && line.startsWith(" ")) {
			const entry = line.trim();
			if (entry.endsWith(marked)) {
				const dir = absoluteSlashed(entry.slice(0, entry.length - marked.length));
				if (!frameworks.includes(dir)) frameworks.push(dir);
			} else if (entry.endsWith(")")) {
				return { dirs: [], frameworks: [], complete: false, key: `search-unreadable:${key}` };
			} else {
				const dir = absoluteSlashed(entry);
				if (!dirs.includes(dir)) dirs.push(dir);
			}
		}
	}
	if (!complete) return { dirs: [], frameworks: [], complete: false, key: `search-unread:${key}` };
	return { dirs, frameworks, complete, key: hashContent(`${dirs.join("\n")}\n|\n${frameworks.join("\n")}`) };
}

const QUERY_RECORD_FORMAT = "queries1";
const QUERY_ENTRY = "?";
const HEADER_QUERY_UNBOUNDED = "header-query-unbounded";
const HEADER_QUERY_UNRECORDED = "header-query-unrecorded";

interface QueryRecord {
	dirs: string[];
	rels: string[];
	paths: string[];
	bounded: boolean;
}

const _queriesByHash = new HashMap<string, HeaderQueries>();

function queriesIn(path: string): HeaderQueries | null {
	const hash = hashFile(path);
	const known = _queriesByHash.get(hash);
	if (known != null) return known;
	const text = readFile(path);
	if (!text.ok) return null;
	const found = headerQueries(text.value);
	_queriesByHash.set(hash, found);
	return found;
}

function asciiName(name: string): boolean {
	for (let i = 0; i < name.length; i++) {
		const code = name.charCodeAt(i);
		if (code < 32 || code > 126) return false;
	}
	return true;
}

function namedFromDir(name: string): boolean {
	return name.startsWith("/") || name == "." || name == ".."
		|| name.startsWith("./") || name.startsWith("../")
		|| name.indexOf("/./") >= 0 || name.indexOf("/../") >= 0
		|| name.endsWith("/.") || name.endsWith("/..");
}

function queryRecord(sources: string[], spelledDeps: string[], search: HeaderSearch, includers: string[]): QueryRecord {
	const deps = spelledDeps.map((path) => absoluteSlashed(path));
	const dirs = searchedDirs(search.dirs, includers, deps);
	const names: string[] = [];
	let bounded = search.complete;
	const scanned: string[] = [];
	for (const path of sources) scanned.push(path);
	for (const path of deps) scanned.push(path);
	for (const path of scanned) {
		const queries = queriesIn(path);
		if (queries == null || queries.macroForm) {
			bounded = false;
			continue;
		}
		if (queries.quoteForm) {
			const own = dirname(absoluteSlashed(path));
			if (!dirs.includes(own)) dirs.push(own);
		}
		for (const name of queries.names) names.push(name);
	}
	const rels: string[] = [];
	const paths: string[] = [];
	const seen = new HashSet<string>();
	for (const path of deps) {
		for (const rel of headerRels(path, dirs)) {
			if (seen.has(rel)) continue;
			seen.add(rel);
			rels.push(rel);
		}
	}
	for (const name of names) {
		if (seen.has(name)) continue;
		seen.add(name);
		if (!namedFromDir(name)) {
			rels.push(name);
		} else if (name.startsWith("/")) {
			paths.push(normalize(name).replaceAll("\\", "/"));
		} else {
			for (const dir of dirs) paths.push(normalize(`${dir}/${name}`).replaceAll("\\", "/"));
		}
	}
	for (const rel of rels) {
		if (!asciiName(rel)) bounded = false;
		const slash = rel.indexOf("/");
		if (slash <= 0 || namedFromDir(rel)) continue;
		for (const dir of search.frameworks) {
			for (const part of ["Headers", "PrivateHeaders"]) {
				paths.push(`${dir}/${rel.slice(0, slash)}.framework/${part}/${rel.slice(slash + 1, rel.length)}`);
			}
		}
	}
	for (const path of paths) {
		if (!asciiName(path)) bounded = false;
	}
	return { dirs, rels, paths, bounded };
}

function presenceText(record: QueryRecord, walked: string[]): string {
	let text = presenceSignature(record.dirs, record.rels, walked);
	for (const path of record.paths) {
		walked.push(dirname(path));
		text = `${text}e\t${path}\t${exists(path) ? 1 : 0}\n`;
	}
	return text;
}

function newestCandidate(record: QueryRecord): number {
	const tree = relTree(record.rels);
	const folded = new HashSet<string>();
	for (const rel of record.rels) folded.add(foldName(rel));
	let newest: number = -1;
	for (const dir of record.dirs) {
		const found: string[] = [];
		existingCandidates(dir, "", "", tree, folded, found, []);
		for (const rel of found) newest = Math.max(newest, changedTime(`${dir}/${rel}`));
	}
	for (const path of record.paths) newest = Math.max(newest, changedTime(path));
	return newest;
}

function writeQueryRecord(depFile: string, record: QueryRecord, settled: boolean): void {
	let text = `${QUERY_RECORD_FORMAT}\n`;
	if (!record.bounded) text = `${text}unbounded\n`;
	if (!settled) text = `${text}unsettled\n`;
	for (const dir of record.dirs) text = `${text}dir\t${dir}\n`;
	for (const rel of record.rels) text = `${text}rel\t${rel}\n`;
	for (const path of record.paths) text = `${text}path\t${path}\n`;
	atomicWriteFile(`${depFile}.q`, text);
}

function recordQueries(depFile: string, sources: string[], deps: string[], search: HeaderSearch, includers: string[], startedSeconds: number): boolean {
	const record = queryRecord(sources, deps, search, includers);
	const settled = record.bounded && newestCandidate(record) < Math.floor(startedSeconds);
	writeQueryRecord(depFile, record, settled);
	trackQueryRecord(depFile);
	return settled;
}

function queryPresence(depFile: string): string {
	const text = try readFile(`${depFile}.q`) catch "";
	const known = _presenceByRecord.get(text);
	if (known != null) return known;
	const key = hashContent(text);
	const remembered = rememberedPresence(depFile, key);
	let presence = remembered.presence;
	if (presence == "") presence = presenceOfRecord(depFile, text, key, remembered.dirs);
	_presenceByRecord.set(text, presence);
	return presence;
}

function presenceMemo(depFile: string): string {
	return `${dirname(depFile)}/presence/${basename(depFile)}.qs`;
}

function rememberedPresence(depFile: string, key: string): RememberedPresence {
	const dirs = new HashMap<string, DirPresence>();
	const lines = (try readFile(presenceMemo(depFile)) catch "").split("\n");
	if (lines.length < 2 || lines[0] != key) return { presence: "", dirs };
	let allCurrent = true;
	let open = false;
	let fresh = true;
	let dir = "";
	let found = "";
	let walked: string[] = [];
	for (let i = 2; i <= lines.length; i++) {
		const line = i < lines.length ? lines[i] : "p";
		if (line == "") continue;
		const tab = line.indexOf("\t", 0);
		const last = line.lastIndexOf("\t");
		const kind = tab < 0 ? line : line.slice(0, tab);
		if (kind == "w" && last > tab) {
			const path = line.slice(tab + 1, last);
			if (dirStamp(path) != line.slice(last + 1, line.length)) {
				fresh = false;
				allCurrent = false;
			}
			walked.push(path);
			continue;
		}
		if (open && fresh) dirs.set(dir, { found, walked });
		open = false;
		fresh = true;
		walked = [];
		if (kind == "s" && last > tab) {
			open = true;
			dir = line.slice(tab + 1, last);
			found = line.slice(last + 1, line.length);
		} else if (kind != "p") {
			return { presence: "", dirs: new HashMap<string, DirPresence>() };
		}
	}
	return { presence: allCurrent ? lines[1] : "", dirs };
}

function stampLines(walked: string[]): string {
	let text = "";
	const seen = new HashSet<string>();
	for (const path of walked) {
		if (seen.has(path)) continue;
		seen.add(path);
		const stamp = dirStamp(path);
		text = `${text}w\t${path}\t${stamp == "" ? UNSETTLED_STAMP : stamp}\n`;
	}
	return text;
}

function presenceOfRecord(depFile: string, text: string, key: string, remembered: HashMap<string, DirPresence>): string {
	const lines = text.split("\n");
	if (lines[0] != QUERY_RECORD_FORMAT) return HEADER_QUERY_UNRECORDED;
	const record: QueryRecord = { dirs: [], rels: [], paths: [], bounded: true };
	for (let i = 1; i < lines.length; i++) {
		const line = lines[i];
		const tab = line.indexOf("\t", 0);
		const kind = tab < 0 ? line : line.slice(0, tab);
		const value = tab < 0 ? "" : line.slice(tab + 1, line.length);
		match (kind) {
			"" => {},
			"unbounded" => { return HEADER_QUERY_UNBOUNDED; },
			"dir" => { record.dirs.push(value); },
			"rel" => { record.rels.push(value); },
			"path" => { record.paths.push(value); },
			_ => { return HEADER_QUERY_UNRECORDED; },
		}
	}
	const walks = record.dirs.some((dir) => !remembered.has(dir));
	const tree = walks ? relTree(record.rels) : new HashMap<string, string[]>();
	const folded = walks ? foldedRels(record.rels) : new HashSet<string>();
	let signature = "";
	let memo = "";
	for (const dir of record.dirs) {
		const part = remembered.get(dir) ?? dirPresence(dir, tree, folded);
		signature = `${signature}${signatureLine(dir, part.found)}`;
		memo = `${memo}s\t${dir}\t${part.found}\n${stampLines(part.walked)}`;
	}
	const parents: string[] = [];
	for (const path of record.paths) {
		parents.push(dirname(path));
		signature = `${signature}e\t${path}\t${exists(path) ? 1 : 0}\n`;
	}
	const presence = hashContent(signature);
	const memoFile = presenceMemo(depFile);
	ensureDir(dirname(memoFile));
	atomicWriteFile(memoFile, `${key}\n${presence}\n${memo}p\n${stampLines(parents)}`);
	return presence;
}

function trackQueryRecord(depFile: string): void {
	if (_queryRecordDepSet.has(depFile)) return;
	_queryRecordDepSet.add(depFile);
	_queryRecordDeps.push(depFile);
}

function trackedQueryPresence(depFile: string): string {
	trackQueryRecord(depFile);
	return queryPresence(depFile);
}

function presenceTrusted(fp: string): boolean {
	return fp.indexOf(HEADER_QUERY_UNBOUNDED, 0) < 0 && fp.indexOf(HEADER_QUERY_UNRECORDED, 0) < 0;
}

struct StoreManifest {
	deps: string[];
	queries: QueryRecord;
}

function storeManifest(dependencyFile: string, source: string, search: HeaderSearch, includers: string[]): string {
	const own = absoluteSlashed(source);
	const deps: string[] = [];
	const seen = new HashSet<string>();
	for (const dep of dependencyPathsIn(dependencyFile)) {
		const path = absoluteSlashed(dep);
		if (path == own || seen.has(path)) continue;
		seen.add(path);
		deps.push(path);
	}
	const record = queryRecord([own], deps, search, includers);
	if (!record.bounded || newestCandidate(record) >= Math.floor(_buildStartedSeconds)) return "";
	const searched = searchedDirs(search.dirs, includers, deps);
	let text = `${STORE_FORMAT}\n`;
	for (const rel of record.rels) text = `${text}r\t${rel}\n`;
	for (const dir of record.dirs) {
		if (!searched.includes(dir)) text = `${text}q\t${dir}\n`;
	}
	for (const path of record.paths) text = `${text}a\t${path}\n`;
	for (const path of deps) {
		if (changedSinceBuild(path, _buildStartedSeconds)) return "";
		text = `${text}d\t${path}\t${hashFile(path)}\n`;
	}
	return tokensOfRoots(`${text}${presenceText(record, [])}`);
}

function tokensOfRoots(text: string): string {
	let result = text;
	for (const pair of _stemRoots) result = swapFieldPrefix(result, pair[0], pair[1]);
	return result;
}

function rootsOfTokens(text: string): string {
	let result = text;
	for (const pair of _stemRoots) result = swapFieldPrefix(result, pair[1], pair[0]);
	return result;
}

function swapFieldPrefix(text: string, from: string, to: string): string {
	return text.replaceAll(`\t${from}/`, `\t${to}/`).replaceAll(`\t${from}\t`, `\t${to}\t`).replaceAll(`\t${from}\n`, `\t${to}\n`);
}

function readStoreManifest(text: string, argDirs: string[], includers: string[]): StoreManifest | null {
	const lines = text.split("\n");
	if (lines[0] != STORE_FORMAT) return null;
	const rels: string[] = [];
	const queried: string[] = [];
	const paths: string[] = [];
	const deps: string[] = [];
	let recorded = "";
	for (let i = 1; i < lines.length; i++) {
		if (lines[i] == "") continue;
		const fields = lines[i].split("\t");
		const width = match (fields[0]) {
			"r" | "q" | "a" => 2,
			"d" | "s" | "e" => 3,
			_ => 0,
		};
		if (fields.length != width) return null;
		match (fields[0]) {
			"r" => {
				rels.push(fields[1]);
			},
			"q" => {
				queried.push(fields[1]);
			},
			"a" => {
				paths.push(fields[1]);
			},
			"d" => {
				if (hashFile(fields[1]) != fields[2]) return null;
				deps.push(fields[1]);
			},
			_ => {
				recorded = `${recorded}${lines[i]}\n`;
			},
		}
	}
	const dirs = searchedDirs(argDirs, includers, deps);
	for (const dir of queried) {
		if (!dirs.includes(dir)) dirs.push(dir);
	}
	const queries: QueryRecord = { dirs, rels, paths, bounded: true };
	if (presenceText(queries, []) != recorded) return null;
	return { deps, queries };
}

function storeHit(key: string, search: HeaderSearch, includers: string[]): StoreHit | null {
	const root = storeRoot();
	if (root == "" || key == "" || !search.complete) return null;
	const dir = `${root}/${key}`;
	if (!exists(dir)) return null;
	for (const entry of readDir(dir)) {
		if (!entry.endsWith(".m")) continue;
		const object = `${dir}/${entry.slice(0, entry.length - 2)}.o`;
		if (!exists(object)) continue;
		const text = try readFile(`${dir}/${entry}`) catch "";
		const manifest = readStoreManifest(rootsOfTokens(text), search.dirs, includers);
		if (manifest != null) {
			markUsed(`${dir}/${entry}`, nowSeconds());
			return { object, deps: manifest.deps, queries: manifest.queries };
		}
	}
	return null;
}

function copyIntoLocal(object: string, oFile: string): boolean {
	const size = fileSize(object);
	if (size < 100) return false;
	ensureDir(dirname(oFile));
	const tmp = `${oFile}.tmp.${performance.now()}`;
	if (!copyFile(object, tmp).ok) return false;
	if (fileSize(tmp) != size || !renameReplace(tmp, oFile)) {
		tryRemoveFile(tmp);
		return false;
	}
	return true;
}

function writeDependencyFile(path: string, deps: string[]): void {
	let text = "native:";
	for (const dep of deps) text = `${text} ${dep.replaceAll(" ", "\\ ")}`;
	ensureDir(dirname(path));
	atomicWriteFile(path, `${text}\n`);
}

export function restoreNativeObject(srcPath: string, compileCmd: string, key: string, search: HeaderSearch): string {
	const hit = storeHit(key, search, [dirname(srcPath)]);
	if (hit == null) return "";
	const deps: string[] = [srcPath];
	for (const dep of hit.deps) deps.push(dep);
	writeDependencyFile(nativeDepFile(srcPath, compileCmd), deps);
	writeQueryRecord(nativeDepFile(srcPath, compileCmd), hit.queries, true);
	const fp = computeFingerprint(srcPath, compileCmd);
	const oFile = stableOFileFp(srcPath, fp);
	if (!copyIntoLocal(hit.object, oFile)) return "";
	atomicWriteFile(`${oFile}.fp`, fp);
	return oFile;
}

export function restoreModuleObject(modPath: string, baseFp: string, key: string, search: HeaderSearch): string {
	const hit = storeHit(key, search, []);
	if (hit == null) return "";
	writeDependencyFile(moduleDepFile(modPath, baseFp), hit.deps);
	writeQueryRecord(moduleDepFile(modPath, baseFp), hit.queries, true);
	const fp = moduleObjectFp(modPath, baseFp);
	const oFile = stableOFileFp(modPath, fp);
	if (!copyIntoLocal(hit.object, oFile)) return "";
	writeCompileFingerprintFp(modPath, fp);
	settleModuleVersion(modPath, baseFp, [oFile]);
	return oFile;
}

export function publishToStore(key: string, oFile: string, dependencyFile: string, source: string, search: HeaderSearch, includers: string[]): void {
	const root = storeRoot();
	if (root == "" || key == "") return;
	const manifest = storeManifest(dependencyFile, source, search, includers);
	if (manifest == "") return;
	const dir = `${root}/${key}`;
	const stem = hashContent(manifest);
	const object = `${dir}/${stem}.o`;
	if (exists(`${dir}/${stem}.m`) && exists(object)) return;
	ensureDir(dir);
	const tmp = `${object}.tmp.${performance.now()}`;
	if (!copyFile(oFile, tmp).ok) return;
	if (!renameReplace(tmp, object)) {
		tryRemoveFile(tmp);
		return;
	}
	atomicWriteFile(`${dir}/${stem}.m`, manifest);
}

export function collectGlobalCache(): void {
	const root = globalCacheRoot();
	if (root == "") return;
	const now = nowSeconds();
	collectStaleEntries(`${root}/store`, now, [".m", ".o"]);
	collectStaleEntries(`${root}/headers`, now, [".hi"]);
	collectStaleFlatEntries(stampMemoRoot(), now, [".sum", ".files", ".exe", ".bundle"]);
}

// Remove a file if it exists (reference-aligned: tryRemoveFile).
function tryRemoveFile(path: string): void {
	if (exists(path)) {
		remove(path);
	}
}

// Check if cached .o is up-to-date.
// Reference-aligned: addExternalFileToCompile — force bypass + tryRemoveFile on miss.
// Caller is responsible for passing the exact same fingerprint to writeCompileCache
// on the miss path — compute it once via computeFingerprint and thread it through.
// NOTE: a miss must NOT remove the local .o. Another concurrent build may be
// linking through it right now (the old remove-on-miss raced links into
// FileNotFound); a miss only means "this build recompiles", and the fresh
// object is published atomically over the stale one by the compile path.
export function isCompileCached(oFile: string, fp: string): boolean {
	const fpFile = oFile + ".fp";
	if (!_forceRebuild && presenceTrusted(fp) && exists(oFile) && exists(fpFile)) {
		const stored = try readFile(fpFile) catch "";
		if (stored == fp) return true;
	}
	return false;
}

// Write the fingerprint for a compiled .o. Takes fingerprint explicitly so it's
// safe to call from parallel workers without shared module state.
export function writeCompileCache(oFile: string, fp: string): void {
	atomicWriteFile(oFile + ".fp", fp);
}

// ===== Project-Level Cache (Layer 2) =====
//
// Reference-aligned: changeDetectedViaJsonBuildInstructions / writeJsonBuildInstructions.
// Reference BuildCache tracks: cacheVersion, outputFile, outputLastModificationTime,
// compile cmds, link files, linkcmd, configFiles, currentDir, cmdline, depfiles (hash each),
// compiler binary hash.
//

const CACHE_VERSION = "v5";

function projectCacheFile(outputFile: string, command: string): string {
	const key = objectListKey([cwd(), join(cwd(), outputFile), command]);
	return `${getCacheDir()}/project.${key}.cache`;
}

let _compilerHash = "";
let _compilerHashKey = "";

function getCompilerHash(ccOption: number, ccBinary: string): string {
	const name = getCompilerName(ccOption, ccBinary);
	if (_compilerHash != "" && _compilerHashKey == name) return _compilerHash;
	const command = compilerInvocation(ccOption, ccBinary);
	let path = command.ok ? command.value.path : name;
	const resolved = findOnPath(path);
	if (resolved != "") path = resolved;
	const version = ccContentIdentity(ccOption, ccBinary);
	_compilerHashKey = name;
	_compilerHash = compilerIdentity(name, path, fileSize(path), modifiedTime(path), version);
	return _compilerHash;
}

export function compilerIdentity(name: string, path: string, size: number, modified: number, version: string): string {
	return hashContent(`${name}:${path}:${size}:${modified}:${version}`);
}

function buildCmdFingerprint(ccOption: number, ccBinary: string, mode: number, compileFlags: string): string {
	const c = implicitSearchKey(ccOption, ccBinary, false, mode, compileFlags);
	const cpp = implicitSearchKey(ccOption, ccBinary, true, mode, compileFlags);
	return `${getCompilerHash(ccOption, ccBinary)}:${mode}:${compileFlags}:${toolchainStamp()}:${c}:${cpp}`;
}

// Prefix constants for cache line parsing — avoids magic offset numbers.
const PRE_VERSION = "version:";
const PRE_OUTPUT = "output:";
const PRE_CMDLINE = "cmdline:";
const PRE_OUTHASH = "outputHash:";

function outputIdentity(path: string): string {
	const stamp = changeStamp(path);
	if (stamp != "" && settled(path)) return `settled:${stamp}`;
	return `content:${hashFileContent(path)}`;
}

function outputMatches(stored: string, path: string): boolean {
	if (stored.startsWith("settled:")) return stored == `settled:${changeStamp(path)}`;
	return stored.startsWith("content:") && stored == `content:${hashFileContent(path)}`;
}

function settleOutputLine(cacheFile: string, lines: string[], stored: string, path: string): void {
	if (stored.startsWith("settled:")) return;
	const settledIdentity = outputIdentity(path);
	if (!settledIdentity.startsWith("settled:")) return;
	const out: string[] = [];
	for (const line of lines) {
		if (line == "") continue;
		out.push(line.startsWith(PRE_OUTHASH) ? `${PRE_OUTHASH}${settledIdentity}` : line);
	}
	atomicWriteFile(cacheFile, `${out.join("\n")}\n`);
}
const PRE_DEP = "dep:";
const PRE_CWD = "cwd:";
const PRE_INPUTS = "inputs:";

// Parse a line from the cache file. Returns value after prefix, or "" if no match.
function parseLineValue(line: string, prefix: string): string {
	if (line.length > prefix.length && line.slice(0, prefix.length) == prefix) {
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
		if (i == s.length || s.charAt(i) == "\n") {
			if (i > start) {
				lines.push(s.slice(start, i));
			}
			start = i + 1;
		}
		i = i + 1;
	}
	return lines;
}

function storedDepPath(entry: string): string {
	let i = entry.length - 1;
	while (i >= 0) {
		if (entry.charAt(i) == "=") return entry.slice(0, i);
		i = i - 1;
	}
	return "";
}

interface ProjectRecord {
	inputs: string;
	deps: string[];
}

function readProjectRecord(cacheFile: string, outputFile: string, command: string): ProjectRecord | null {
	if (!exists(cacheFile) || !exists(outputFile)) return null;
	const cacheResult = readFile(cacheFile);
	if (!cacheResult.ok) return null;
	const newline = cacheResult.value.indexOf("\n", 0);
	if (newline < 0) return null;
	const body = cacheResult.value.slice(newline + 1, cacheResult.value.length);
	if (cacheResult.value.slice(0, newline) != hashContent(body)) return null;
	const lines = splitLines(body);

	let storedVersion = "";
	let storedOutput = "";
	let storedCmd = "";
	let storedOutputHash = "";
	let storedCwd = "";
	let storedInputs = "";
	const storedDeps: string[] = [];

	for (const line of lines) {
		let val = parseLineValue(line, PRE_VERSION);
		if (val != "") { storedVersion = val; continue; }
		val = parseLineValue(line, PRE_OUTPUT);
		if (val != "") { storedOutput = val; continue; }
		val = parseLineValue(line, PRE_CMDLINE);
		if (val != "") { storedCmd = val; continue; }
		val = parseLineValue(line, PRE_OUTHASH);
		if (val != "") { storedOutputHash = val; continue; }
		val = parseLineValue(line, PRE_CWD);
		if (val != "") { storedCwd = val; continue; }
		val = parseLineValue(line, PRE_INPUTS);
		if (val != "") { storedInputs = val; continue; }
		val = parseLineValue(line, PRE_DEP);
		if (val != "") { storedDeps.push(val); }
	}

	if (storedVersion != CACHE_VERSION) return null;
	if (storedOutput != join(cwd(), outputFile)) return null;
	if (storedCmd != command) return null;
	if (storedCwd != cwd()) return null;
	if (!outputMatches(storedOutputHash, outputFile)) return null;
	return { inputs: storedInputs, deps: storedDeps };
}

function storedDepCurrent(entry: string): boolean {
	const path = storedDepPath(entry);
	if (path.startsWith(QUERY_ENTRY)) {
		const presence = queryPresence(path.slice(QUERY_ENTRY.length, path.length));
		return presenceTrusted(presence) && entry == `${path}=${presence}`;
	}
	return path != "" && entry == `${path}=${hashFile(path)}`;
}

export function projectRecordCurrent(
	outputFile: string,
	ccOption: number,
	ccBinary: string,
	mode: number,
	flags: string
): boolean {
	if (_forceRebuild) return false;
	const command = buildCmdFingerprint(ccOption, ccBinary, mode, flags);
	const record = readProjectRecord(projectCacheFile(outputFile, command), outputFile, command);
	if (record == null || record.deps.length == 0) return false;
	for (const entry of record.deps) {
		if (!storedDepCurrent(entry)) return false;
	}
	return true;
}

// Check if the project needs rebuilding.
// Reference-aligned: changeDetectedViaJsonBuildInstructions.
// Returns true if anything changed (= must rebuild). Returns false if up-to-date.
export function projectCacheChanged(
	depPaths: string[],
	outputFile: string,
	ccOption: number,
	ccBinary: string,
	mode: number,
	flags: string
): boolean {
	const currentCmd = buildCmdFingerprint(ccOption, ccBinary, mode, flags);
	const inputs = objectListKey(depPaths);
	const cacheFile = projectCacheFile(outputFile, currentCmd);
	_projectInputKey = cacheFile;
	_projectInputHashes = [];
	for (const path of depPaths) _projectInputHashes.push(hashFile(path));
	if (_forceRebuild) return true;
	const record = readProjectRecord(cacheFile, outputFile, currentCmd);
	if (record == null) return true;
	if (record.inputs != inputs) return true;

	const storedDeps = record.deps;
	if (storedDeps.length < depPaths.length) return true;
	let di = 0;
	while (di < depPaths.length) {
		const path = depPaths[di];
		if (storedDeps[di] != `${path}=${_projectInputHashes[di]}`) return true;
		di = di + 1;
	}
	while (di < storedDeps.length) {
		if (!storedDepCurrent(storedDeps[di])) return true;
		di = di + 1;
	}

	return false;
}

function dropStaleRecord(record: string): void {
	if (exists(record)) { const gone = remove(record); }
}

// Write the project cache after a successful build.
// Reference-aligned: writeJsonBuildInstructions.
export function writeProjectCache(
	depPaths: string[],
	outputFile: string,
	ccOption: number,
	ccBinary: string,
	mode: number,
	flags: string
): void {
	if (!exists(outputFile)) return;
	const command = buildCmdFingerprint(ccOption, ccBinary, mode, flags);
	const inputs = objectListKey(depPaths);
	const record = projectCacheFile(outputFile, command);
	const seen = new HashSet<string>();
	let dependencies = "";
	for (let i = 0; i < depPaths.length; i++) {
		const path = depPaths[i];
		const hash = hashFile(path);
		if (_projectInputKey == record && (i >= _projectInputHashes.length || hash != _projectInputHashes[i])) return dropStaleRecord(record);
		if (_buildStartedSeconds > 0 && (!exists(path) || changedTime(path) >= Math.floor(_buildStartedSeconds))) return dropStaleRecord(record);
		if (seen.has(path)) continue;
		seen.add(path);
		dependencies = dependencies + `${PRE_DEP}${path}=${hash}\n`;
	}
	for (const path of _nativeProjectDeps) {
		if (seen.has(path)) continue;
		if (_buildStartedSeconds > 0 && changedTime(path) >= Math.floor(_buildStartedSeconds)) return dropStaleRecord(record);
		seen.add(path);
		dependencies = dependencies + `${PRE_DEP}${path}=${hashFile(path)}\n`;
	}
	for (const depFile of _queryRecordDeps) {
		const presence = queryPresence(depFile);
		if (!presenceTrusted(presence)) return dropStaleRecord(record);
		dependencies = dependencies + `${PRE_DEP}${QUERY_ENTRY}${depFile}=${presence}\n`;
	}
	let content = `${PRE_VERSION}${CACHE_VERSION}\n`;
	content = content + `${PRE_OUTPUT}${join(cwd(), outputFile)}\n`;
	content = content + `${PRE_CMDLINE}${command}\n`;
	content = content + `${PRE_CWD}${cwd()}\n`;
	content = content + `${PRE_INPUTS}${inputs}\n`;
	content = content + `${PRE_OUTHASH}${outputIdentity(outputFile)}\n`;
	content = content + dependencies;
	atomicWriteFile(record, `${hashContent(content)}\n${content}`);
}

function withProjectRecordFixture(name: string, body: (dir: string) => void): void {
	const savedDir = _cacheDir;
	const savedForce = _forceRebuild;
	const savedDeps = _nativeProjectDeps;
	const savedDepSet = _nativeProjectDepSet;
	const savedStarted = _buildStartedSeconds;
	const savedKey = _projectInputKey;
	const savedHashes = _projectInputHashes;
	const dir = `${getCacheDir()}/project-record-${name}-${performance.now()}`;
	ensureDir(dir);
	_cacheDir = dir;
	_forceRebuild = false;
	_nativeProjectDeps = [];
	_nativeProjectDepSet = new HashSet<string>();
	_buildStartedSeconds = 0;
	_projectInputKey = "";
	_projectInputHashes = [];
	try {
		body(dir);
	} finally {
		removeAll(dir);
		_cacheDir = savedDir;
		_forceRebuild = savedForce;
		_nativeProjectDeps = savedDeps;
		_nativeProjectDepSet = savedDepSet;
		_buildStartedSeconds = savedStarted;
		_projectInputKey = savedKey;
		_projectInputHashes = savedHashes;
	}
}

test "project records reject source changes between lookup and publication" {
	withProjectRecordFixture("publication", (dir: string): void => {
		const dep = `${dir}/entry.ms`;
		const out = `${dir}/app`;
		writeFile(dep, "original source");
		writeFile(out, "output from original source");
		writeProjectCache([dep], out, 0, "", 0, "-O0");
		assert !projectCacheChanged([dep], out, 0, "", 0, "-O0");
		writeFile(dep, "changed source");
		writeProjectCache([dep], out, 0, "", 0, "-O0");
		assert projectCacheChanged([dep], out, 0, "", 0, "-O0");
	});
}

test "project records retain independent outputs and configurations on a miss" {
	withProjectRecordFixture("alternate", (dir: string): void => {
		const dep = `${dir}/entry.ms`;
		const outA = `${dir}/a`;
		const outB = `${dir}/b`;
		writeFile(dep, "entry");
		writeFile(outA, "debug-output");
		writeFile(outB, "release-output");
		writeProjectCache([dep], outA, 0, "", 0, "-O0");
		writeProjectCache([dep], outB, 0, "", 1, "-O2");
		assert !projectCacheChanged([dep], outA, 0, "", 0, "-O0");
		assert !projectCacheChanged([dep], outB, 0, "", 1, "-O2");
		assert projectCacheChanged([dep], outA, 0, "", 1, "-O2");
		assert !projectCacheChanged([dep], outA, 0, "", 0, "-O0");
		assert !projectCacheChanged([dep], outB, 0, "", 1, "-O2");
	});
}

test "project records reject changed outputs, dependencies and corrupt metadata independently" {
	withProjectRecordFixture("invalidation", (dir: string): void => {
		const depA = `${dir}/a.ms`;
		const depB = `${dir}/b.ms`;
		const outA = `${dir}/a`;
		const outB = `${dir}/b`;
		writeFile(depA, "entry-a");
		writeFile(depB, "entry-b");
		writeFile(outA, "output-a");
		writeFile(outB, "output-b");
		writeProjectCache([depA], outA, 0, "", 0, "-O0");
		writeProjectCache([depB], outB, 0, "", 0, "-O0");
		writeFile(outA, "tampered");
		assert projectCacheChanged([depA], outA, 0, "", 0, "-O0");
		assert !projectCacheChanged([depB], outB, 0, "", 0, "-O0");
		writeFile(outA, "output-a");
		writeProjectCache([depA], outA, 0, "", 0, "-O0");
		writeFile(depA, "changed-entry");
		assert projectCacheChanged([depA], outA, 0, "", 0, "-O0");
		assert !projectCacheChanged([depB], outB, 0, "", 0, "-O0");
		writeFile(depA, "entry-a");
		assert !projectCacheChanged([depA], outA, 0, "", 0, "-O0");
		const record = projectCacheFile(outA, buildCmdFingerprint(0, "", 0, "-O0"));
		writeFile(record, "corrupt");
		assert projectCacheChanged([depA], outA, 0, "", 0, "-O0");
		assert !projectCacheChanged([depB], outB, 0, "", 0, "-O0");
	});
}

test "a project record answers from its own dependency list" {
	withProjectRecordFixture("early", (dir: string): void => {
		const entry = `${dir}/entry.ms`;
		const imported = `${dir}/imported.ms`;
		const out = `${dir}/app`;
		writeFile(entry, "entry");
		writeFile(imported, "imported");
		writeFile(out, "output");
		writeProjectCache([entry, imported], out, 0, "", 0, "-O0");
		assert projectRecordCurrent(out, 0, "", 0, "-O0");
		assert !projectRecordCurrent(out, 0, "", 0, "-O0 -DOTHER");
		writeFile(imported, "imported edited");
		assert !projectRecordCurrent(out, 0, "", 0, "-O0");
		writeFile(imported, "imported");
		assert projectRecordCurrent(out, 0, "", 0, "-O0");
		remove(imported);
		assert !projectRecordCurrent(out, 0, "", 0, "-O0");
	});
}

// ===== Per-Module C Code Cache (Layer 3) =====
//
// Caches generated C code per module. Only re-invokes clang if the generated .c
// content or compile command changed. Biggest incremental build win: changing 1
// of 31 modules only recompiles that 1 module.

// Stable .c path for a module, keyed by sanitized module path.
export function stableCFile(modPath: string): string {
	return `${getCacheDir()}/${sanitizePath(modPath)}.c`;
}// Module compile fingerprint. Exported so the parallel compile path can
// precompute it at gather time instead of holding every module's C text
// alive until the post-join fingerprint write.
export function moduleCompileFp(cCode: string, compileCmd: string): string {
	return `${hashContent(cCode)}:${compileCmd}:${objectStamp()}`;
}

export function moduleDepFile(modPath: string, baseFp: string): string {
	return `${getCacheDir()}/${cacheStem(modPath)}.${fpKey(baseFp)}.d`;
}

function moduleHeaderPaths(modPath: string, baseFp: string): string[] {
	const ownStem = `${getCacheDir()}/${cacheStem(modPath)}.`;
	const result: string[] = [];
	for (const path of dependencyPathsIn(moduleDepFile(modPath, baseFp))) {
		if (!(path.startsWith(ownStem) && path.endsWith(".c"))) result.push(path);
	}
	return result;
}

export function moduleObjectFp(modPath: string, baseFp: string): string {
	if (!exists(moduleDepFile(modPath, baseFp))) return `${baseFp}:dependencies-unresolved`;
	let result = baseFp;
	for (const path of moduleHeaderPaths(modPath, baseFp)) {
		registerNativeProjectDep(path);
		result = `${result}:${path}=${hashFile(path)}`;
	}
	return `${result}:${trackedQueryPresence(moduleDepFile(modPath, baseFp))}`;
}

export function publishModuleObject(modPath: string, baseFp: string, cFile: string, oFile: string, fp: string, search: HeaderSearch): string {
	const published = publishObjectVersion(modPath, baseFp, cFile, oFile, fp, search);
	settleModuleVersion(modPath, baseFp, [oFile, published]);
	return published;
}

function publishObjectVersion(modPath: string, baseFp: string, cFile: string, oFile: string, fp: string, search: HeaderSearch): string {
	const headers = moduleHeaderPaths(modPath, baseFp);
	if (!recordQueries(moduleDepFile(modPath, baseFp), [cFile], headers, search, [], _buildStartedSeconds)) return oFile;
	for (const path of headers) {
		if (changedSinceBuild(path, _buildStartedSeconds)) return oFile;
	}
	const resolvedFp = moduleObjectFp(modPath, baseFp);
	if (resolvedFp == fp) {
		writeCompileFingerprintFp(modPath, fp);
		return oFile;
	}
	const resolved = stableOFileFp(modPath, resolvedFp);
	const tmp = `${resolved}.tmp.${performance.now()}`;
	if (!copyFile(oFile, tmp).ok || !renameReplace(tmp, resolved)) {
		tryRemoveFile(tmp);
		return oFile;
	}
	writeCompileFingerprintFp(modPath, resolvedFp);
	return resolved;
}

function moduleVersionRecord(stem: string): string {
	return `${getCacheDir()}/${stem}.versions`;
}

function moduleConfigKey(baseFp: string): string {
	const stamp = `:${objectStamp()}`;
	const end = baseFp.endsWith(stamp) ? baseFp.length - stamp.length : baseFp.length;
	return fpKey(baseFp.slice(baseFp.indexOf(":", 0) + 1, end));
}

function versionFileNames(depFile: string, objects: string[]): string[] {
	const names: string[] = [];
	const dep = basename(depFile);
	for (const name of [dep, `${dep}.q`, `presence/${dep}.qs`]) names.push(name);
	for (const object of objects) {
		const name = basename(object);
		if (names.includes(name)) continue;
		names.push(name);
		names.push(`${name}.cfp`);
	}
	return names;
}

function isFpKey(text: string): boolean {
	const underscore = text.indexOf("_", 0);
	if (underscore < 1 || underscore + 1 >= text.length) return false;
	for (let i = 0; i < text.length; i++) {
		if (i == underscore) continue;
		const b = text.byteAt(i);
		const digit = b >= "0".code && b <= "9".code;
		const hex = i < underscore && b >= "a".code && b <= "f".code;
		if (!digit && !hex) return false;
	}
	return true;
}

function isVersionFileOf(stem: string, entry: string): boolean {
	if (!entry.startsWith(`${stem}.`)) return false;
	const parts = entry.slice(stem.length + 1, entry.length).split(".");
	if (!isFpKey(parts[0])) return false;
	if (parts.length == 2) return parts[1] == "d" || parts[1] == "o";
	return parts.length == 3 && ((parts[1] == "d" && parts[2] == "q") || (parts[1] == "o" && parts[2] == "cfp"));
}

let _cacheListing: string[] | null = null;

function unrecordedVersionNames(stem: string): string[] {
	if (_cacheListing == null) _cacheListing = readDir(getCacheDir());
	const names: string[] = [];
	for (const entry of _cacheListing!) {
		if (!isVersionFileOf(stem, entry)) continue;
		names.push(entry);
		if (entry.endsWith(".d")) names.push(`presence/${entry}.qs`);
	}
	return names;
}

const LIVE_VERSION_SECONDS = 3600;
const LIVE_REFRESH_SECONDS = 600;

function lastUsedOf(name: string): float64 {
	const path = `${getCacheDir()}/${name}`;
	if (name.endsWith(".o.cfp")) return Math.max(modifiedTime(path), modifiedTime(path.slice(0, path.length - 4)));
	if (name.endsWith(".o")) return Math.max(modifiedTime(path), modifiedTime(`${path}.cfp`));
	return modifiedTime(path);
}

function versionLastUsed(names: string[]): float64 {
	let newest: float64 = -1;
	for (const name of names) newest = Math.max(newest, lastUsedOf(name));
	return newest;
}

export function settleModuleVersion(modPath: string, baseFp: string, objects: string[], now: float64 = nowSeconds()): void {
	if (modPath == "") return;
	const stem = cacheStem(modPath);
	const record = moduleVersionRecord(stem);
	const config = moduleConfigKey(baseFp);
	const depName = basename(moduleDepFile(modPath, baseFp));
	const keep = versionFileNames(moduleDepFile(modPath, baseFp), objects);
	const cutoff = now - LIVE_VERSION_SECONDS;
	const known: string[][] = [];
	const lines: string[] = [];
	if (exists(record)) {
		for (const line of (try readFile(record) catch "").split("\n")) {
			if (line == "") continue;
			const names = line.split("\t");
			if (names[0] == config) known.push(names.slice(1, names.length));
			else lines.push(line);
		}
	} else {
		known.push(unrecordedVersionNames(stem));
	}
	const current = [...keep];
	const doomed: string[] = [];
	for (const names of known) {
		if (names.includes(depName)) {
			for (const name of names) {
				if (keep.includes(name)) continue;
				if (lastUsedOf(name) < cutoff) doomed.push(name);
				else current.push(name);
			}
		} else if (versionLastUsed(names) < cutoff) {
			for (const name of names) doomed.push(name);
		} else {
			lines.push([config, ...names].join("\t"));
		}
	}
	lines.push([config, ...current].join("\t"));
	if (!atomicWriteFile(record, `${lines.join("\n")}\n`)) return;
	for (const name of doomed) {
		if (keep.includes(name) || !(name.startsWith(`${stem}.`) || name.startsWith(`presence/${stem}.`))) continue;
		tryRemoveFile(`${getCacheDir()}/${name}`);
	}
}

// Check if generated C code matches cached version. If match, .o is up to date.
// Takes the precomputed module fingerprint (moduleCompileFp) — the caller
// needs the fp-keyed oFile path anyway. A miss (or _forceRebuild) must NOT
// remove anything: the fp-keyed physical file belongs to this config alone,
// and a FAILED compile cleans up via invalidateCompileCache.
export function isCCodeCached(modPath: string, fp: string): boolean {
	const oFile = stableOFileFp(modPath, fp);
	const fpFile = oFile + ".cfp";
	if (_forceRebuild || !presenceTrusted(fp)) return false;
	if (!exists(oFile) || !exists(fpFile)) return false;
	const storedFp = try readFile(fpFile) catch "";
	if (storedFp != fp) return false;
	markUsed(fpFile, nowSeconds(), LIVE_REFRESH_SECONDS);
	return true;
}

// Write C code cache after successful compilation of a module.
// PREFER `writeCSource` + `writeCompileFingerprint` (split form) for new
// callers — split form prevents Bug 6 (writing fingerprint before compile
// confirms success).
export function writeCCodeCache(modPath: string, cCode: string, compileCmd: string): void {
	const fp = moduleCompileFp(cCode, compileCmd);
	writeCSource(modPath, fp, cCode);
	writeCompileFingerprintFp(modPath, fp);
}

// Write only the .c source (fp-keyed: emitted C is config-dependent — drc vs
// orc teardown differ — so concurrent builds of different configs must never
// swap it under a running cc). Always safe — .c is debug-friendly (lets user
// inspect generated C even when zig cc fails). Published atomically: a
// concurrent reader of the previous bytes is never torn.
export function writeCSource(modPath: string, fp: string, cCode: string): void {
	const path = stableCFileFp(modPath, fp);
	// The path embeds fpKey(hash(cCode):compileCmd:objectStamp), so a
	// correctly written file already sitting here holds these exact bytes.
	// Re-publishing it is not merely redundant: atomicWriteFile swaps the file
	// with MoveFileEx(REPLACE_EXISTING) out from under a CONCURRENT build whose
	// cc has it open, and zig then reports CacheCheckFailed.
	//
	// Compare the bytes, do not trust existence. The path only proves what was
	// MEANT to be written: a host that dies mid-flush leaves a file of the right
	// length full of NULs (136 such .c files appeared at once when a session was
	// killed mid-corpus). An exists() check made that corruption permanent --
	// every later build compiled the empty TU and the link failed on WinMain.
	// A mismatch rewrites, so the cache heals the way it did before this check.
	if (exists(path)) {
		const onDisk = try readFile(path) catch "";
		if (onDisk == cCode) {
			markUsed(path, nowSeconds(), LIVE_REFRESH_SECONDS);
			return;
		}
	}
	atomicWriteFile(path, cCode);
}

// Write the compile-success fingerprint (.cfp). Call ONLY after
// `compileCFile` returns 0. Cache lookup uses this to skip recompilation —
// writing it on failure causes future runs to false-claim cache hit and try
// to link a partial/empty .o.
export function writeCompileFingerprint(modPath: string, cCode: string, compileCmd: string): void {
	writeCompileFingerprintFp(modPath, moduleCompileFp(cCode, compileCmd));
}

// Precomputed-fp variant for the parallel compile path (fp from moduleCompileFp).
export function writeCompileFingerprintFp(modPath: string, fp: string): void {
	if (fp == "") return; // dispatcher job — .o lives next to the output, not in the cache
	atomicWriteFile(stableOFileFp(modPath, fp) + ".cfp", fp);
}

// Remove cache artifacts after a failed compile so the next run triggers a
// clean retry. Only the .cfp goes: it is the sentinel a later run reads to
// SKIP compiling, so a stale one is the only artifact that can turn a failed
// compile into a false cache hit.
//
// The .o and .c are deliberately left alone. Both are fp-keyed, so whatever
// sits at those paths came from the same C with the same command, and is
// never partial (compileCFile publishes by atomic rename, only on success).
// Under concurrent builds removing them was actively harmful: one process's
// failure deleted an object a SIBLING had just published, and the sibling's
// link then died with `failed to open object ...: FileNotFound`.
export function invalidateCompileCache(modPath: string, fp: string): void {
	if (fp == "") return;
	tryRemoveFile(stableOFileFp(modPath, fp) + ".cfp");
}

// ===== Link Cache (Layer 4) =====
//
// Tracks link command + .o file list. When all modules hit .c cache (no recompile)
// and link flags are unchanged and output binary exists, skip re-linking entirely.

const PRE_LINKCMD = "linkcmd:";
const PRE_OFILES = "ofiles:";
const PRE_LINKINPUTS = "linkInputs:";
const PRE_TOOLCHAIN = "toolchain:";

function linkToolchainKey(ccOption: number, ccBinary: string): string {
	const bundle = selectedNativeToolchain();
	return `${getCompilerHash(ccOption, ccBinary)}:${bundle == null ? "" : bundle.identity}`;
}

function linkCacheFile(image: string = ""): string {
	if (image != "") return `${getCacheDir()}/link.${hashContent(image)}.cache`;
	return `${getCacheDir()}/link.cache`;
}

function objectListKey(oFiles: string[]): string {
	let identity = "";
	for (const path of oFiles) identity = `${identity}${path.length}:${path}`;
	return hashContent(identity);
}

function imageObjectsKey(oFiles: string[]): string {
	let identity = "";
	for (const path of oFiles) identity = `${identity}${hashFile(path)}\n`;
	return hashContent(identity);
}

function linkObjectsKey(oFiles: string[], image: string): string {
	return image == "" ? objectListKey(oFiles) : imageObjectsKey(oFiles);
}

function externalInputKey(paths: string[]): string {
	let identity = "";
	for (const path of paths) identity = `${identity}${path.length}:${path}:${hashFile(path)}`;
	return hashContent(identity);
}

// Check if link step can be skipped.
export function isLinkCached(oFiles: string[], externalInputs: string[], linkFlags: string, outputFile: string, ccOption: number, ccBinary: string, image: string = ""): boolean {
	if (_forceRebuild) return false;
	const cFile = linkCacheFile(image);
	if (!exists(cFile) || !exists(outputFile)) return false;

	const linkResult = readFile(cFile);
	if (!linkResult.ok) return false;
	const lines = splitLines(linkResult.value);

	let storedCmd = "";
	let storedOFiles = "";
	let storedOutputHash = "";
	let storedInputs = "";
	let storedToolchain = "";

	for (const line of lines) {
		let val = parseLineValue(line, PRE_LINKCMD);
		if (val != "") { storedCmd = val; continue; }
		val = parseLineValue(line, PRE_TOOLCHAIN);
		if (val != "") { storedToolchain = val; continue; }
		val = parseLineValue(line, PRE_OFILES);
		if (val != "") { storedOFiles = val; continue; }
		val = parseLineValue(line, PRE_LINKINPUTS);
		if (val != "") { storedInputs = val; continue; }
		val = parseLineValue(line, PRE_OUTHASH);
		if (val != "") { storedOutputHash = val; continue; }
	}

	if (storedCmd != linkFlags) return false;
	if (storedToolchain != linkToolchainKey(ccOption, ccBinary)) return false;
	if (storedOFiles != linkObjectsKey(oFiles, image)) return false;
	if (storedInputs != externalInputKey(externalInputs)) return false;
	if (!outputMatches(storedOutputHash, outputFile)) return false;
	settleOutputLine(cFile, lines, storedOutputHash, outputFile);
	return true;
}

// Write link cache after successful link step.
export function writeLinkCache(oFiles: string[], externalInputs: string[], linkFlags: string, outputFile: string, ccOption: number, ccBinary: string, image: string = ""): void {
	let content = `${PRE_LINKCMD}${linkFlags}\n`;
	content = content + `${PRE_TOOLCHAIN}${linkToolchainKey(ccOption, ccBinary)}\n`;
	content = content + `${PRE_OFILES}${linkObjectsKey(oFiles, image)}\n`;
	content = content + `${PRE_LINKINPUTS}${externalInputKey(externalInputs)}\n`;
	content = content + `${PRE_OUTHASH}${outputIdentity(outputFile)}\n`;
	atomicWriteFile(linkCacheFile(image), content);
}

// ===== Header Module Cache (Layer 5) =====
//
// Caches the module source the loader translates from a C header, on disk,
// content-hash keyed (ccache-style).
//
// Key folds: header source, header path, target, VERSION, platform,
// compiler root (resolveRuntimeDir — the emitted @include paths and include
// search roots embed it) and toolchainStamp (msc binary + every file under
// runtime/ and vendor/). Headers OUTSIDE the stamped trees (user projects,
// std/, cparse builtin stubs) are covered by the recorded dep list: the
// transform logs every file it probed or read — "<path>\t<hash>" when read,
// "<path>\t-" when probed-absent — and a lookup re-verifies each dep against
// disk. Any divergence (content changed, file appeared, file vanished) is a
// miss; a miss recomputes exactly as without the cache. Deps under the
// stamped trees skip re-verification: the stamp already content-hashes those
// trees whole, so the key itself moved when they changed.
//
// Only error-free translations are stored: a run that surfaced diagnostics
// recomputes next time so the diagnostics re-surface (loader-side gate).
// MSC_NO_HEADER_CACHE=1 disables both lookup and store.

const HEADER_ENTRY_MAGIC = "MSHM1";

// Global when available, else the local cache dir (exotic environments).
function headersCacheDir(): string {
	const root = globalCacheRoot();
	if (root != "") return `${root}/headers/${toolchainStamp()}`;
	return `${getCacheDir()}/headers`;
}

export function headerModuleKey(source: string, headerPath: string, target: string): string {
	return hashContent(`${VERSION}:${platform}:${target}:${resolveRuntimeDir()}:${headerPath}\n${source}\n${toolchainStamp()}`);
}

function depUnderStampedTrees(path: string): boolean {
	const root = resolveRuntimeDir();
	if (root == "") return false;
	return path.startsWith(`${root}/runtime/`) || path.startsWith(`${root}/vendor/`);
}

// Verify one dep line against disk. Returns true when the recorded fact
// still holds.
function verifyHeaderDep(dep: string): boolean {
	const tab = dep.indexOf("\t", 0);
	if (tab <= 0) return false;
	const path = dep.slice(0, tab);
	const hash = dep.slice(tab + 1, dep.length);
	if (depUnderStampedTrees(path)) return true;
	const content = try readFile(path) catch "";
	if (hash == "-") return content == "";
	return content != "" && hashContent(content) == hash;
}

// Lookup a cached header module. Entry layout:
//   "MSHM1\n<dep>\n...\n--\n<output>"
// Returns "" on miss, disabled, corrupt entry, or any dep that no longer
// verifies. A miss never deletes the entry — concurrent readers first.
export function lookupHeaderModule(key: string): string {
	if (env.get("MSC_NO_HEADER_CACHE") != "") return "";
	const body = try readFile(`${headersCacheDir()}/${key}.hi`) catch "";
	if (!body.startsWith(`${HEADER_ENTRY_MAGIC}\n`)) return "";
	let pos = HEADER_ENTRY_MAGIC.length + 1;
	while (true) {
		const nl = body.indexOf("\n", pos);
		if (nl < 0) return "";
		const line = body.slice(pos, nl);
		pos = nl + 1;
		if (line == "--") break;
		if (line.length == 0) continue;
		if (!verifyHeaderDep(line)) return "";
	}
	markUsed(`${headersCacheDir()}/${key}.hi`, nowSeconds());
	return body.slice(pos, body.length);
}

// Publish a header module atomically (tmp + rename). Deps are
// the recorded read set (path+hash / path+absent lines). Deterministic
// content for a given key, so concurrent publishers write identical bytes.
export function storeHeaderModule(key: string, deps: string[], output: string): void {
	if (env.get("MSC_NO_HEADER_CACHE") != "") return;
	const dir = headersCacheDir();
	ensureDir(dir);
	const body = `${HEADER_ENTRY_MAGIC}\n${deps.join("\n")}\n--\n${output}`;
	atomicWriteFile(`${dir}/${key}.hi`, body);
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

function bug6_clearArtifacts(modPath: string, fp: string): void {
	tryRemoveFile(stableCFileFp(modPath, fp));
	tryRemoveFile(stableOFileFp(modPath, fp));
	tryRemoveFile(stableOFileFp(modPath, fp) + ".cfp");
}

test "bug6: writeCSource alone does not produce a cache hit" {
	// Split form: source written before compile, but no fingerprint until cc OK.
	// isCCodeCached must stay false so the next run still attempts to compile.
	const modPath = "test/bug6/probe_source_only.ms";
	const fp = moduleCompileFp("int main(){return 0;}", "cc -O0");
	bug6_clearArtifacts(modPath, fp);
	writeCSource(modPath, fp, "int main(){return 0;}");
	assert exists(stableCFileFp(modPath, fp));
	assert !exists(stableOFileFp(modPath, fp) + ".cfp");
	assert !isCCodeCached(modPath, fp);
	bug6_clearArtifacts(modPath, fp);
}

test "object fingerprints fold in the support trees and never the msc binary" {
	const objects = objectStamp();
	assert objects.length > 0;
	assert objects != toolchainStamp();
	assert moduleCompileFp("int main(){}", "cc -O2").indexOf(objects, 0) >= 0;
	assert moduleCompileFp("int main(){}", "cc -O2").indexOf(toolchainStamp(), 0) < 0;
	assert toolchainStamp() == toolchainStamp();
}

test "a file rewritten to the same size at once hashes to its new content" {
	const base = env.get("TEMP") != "" ? env.get("TEMP") : "/tmp";
	const path = `${base}/msc-hash-stamp-${performance.now()}.txt`;
	writeFile(path, "first content");
	const before = hashFile(path);
	assert hashFile(path) == before;
	writeFile(path, "other content");
	assert hashFile(path) != before;
	assert hashFile(path) == hashFileContent(path);
	remove(path);
	assert hashFile(path) == "absent";
}

test "a file written within the settle window is not remembered by its change stamp" {
	const base = env.get("TEMP") != "" ? env.get("TEMP") : "/tmp";
	const path = `${base}/msc-settle-${performance.now()}.d`;
	writeFile(path, "native: a.h\n");
	hashFile(path);
	dependencyPathsIn(path);
	sourceIdentity(path);
	assert _hashByStamp.get(path) == null;
	assert _dependenciesByStamp.get(path) == null;
	assert _sourceIdentityByStamp.get(path) == null;
	remove(path);
}

function backdated(path: string, content: string): boolean {
	return writeFile(path, content).ok && execFileCapture("touch", ["-t", "202001010000", path]).ok;
}

function ageChange(path: string): void {
	const deadline = nowSeconds() + 10;
	while (changedTime(path) > nowSeconds() - SETTLED_SECONDS) {
		if (nowSeconds() > deadline) throw new Error(`${path} did not settle`);
		execFileCapture("sleep", ["0.2"]);
	}
}

test "a file rewritten and backdated is not remembered while its change time is fresh" {
	if (platform == "windows") return;
	const base = env.get("TEMP") != "" ? env.get("TEMP") : "/tmp";
	const path = `${base}/msc-backdated-${performance.now()}.txt`;
	assert backdated(path, "first content");
	const writes = _hashMemoWrites;
	hashFile(path);
	assert _hashMemoWrites == writes;
	assert _hashByStamp.get(path) == null;
	ageChange(path);
	hashFile(path);
	assert _hashMemoWrites == writes + 1;
	remove(path);
}

test "a backdated file is changed since the build started" {
	if (platform == "windows") return;
	const base = env.get("TEMP") != "" ? env.get("TEMP") : "/tmp";
	const path = `${base}/msc-backdated-build-${performance.now()}.h`;
	assert backdated(path, "int a;\n");
	assert changedSinceBuild(path, nowSeconds() - 100);
	assert !changedSinceBuild(path, nowSeconds() + 100);
	assert changedSinceBuild(`${path}.absent`, nowSeconds());
	remove(path);
}

test "a backdated dependency keeps the header manifest and the project record from being written" {
	if (platform == "windows") return;
	withProjectRecordFixture("backdated", (dir: string): void => {
		const dep = `${dir}/entry.ms`;
		const header = `${dir}/dep.h`;
		const depFile = `${dir}/entry.d`;
		const out = `${dir}/app`;
		assert backdated(dep, "source");
		assert backdated(header, "int a;\n");
		assert writeFile(depFile, `native: ${header}\n`).ok;
		assert writeFile(out, "output").ok;
		_buildStartedSeconds = nowSeconds() - 100;
		assert storeManifest(depFile, `${dir}/entry.c`, { dirs: [], frameworks: [], complete: true }, []) == "";
		writeProjectCache([dep], out, 0, "", 0, "-O0");
		assert projectCacheChanged([dep], out, 0, "", 0, "-O0");
		_buildStartedSeconds = 0;
		writeProjectCache([dep], out, 0, "", 0, "-O0");
		assert !projectCacheChanged([dep], out, 0, "", 0, "-O0");
		registerNativeProjectDep(header);
		_buildStartedSeconds = nowSeconds() - 100;
		writeProjectCache([dep], out, 0, "", 0, "-O0");
		assert projectCacheChanged([dep], out, 0, "", 0, "-O0");
	});
}

test "global collection removes a stale bundle verify memo and keeps a fresh one and a foreign file" {
	if (platform == "windows") return;
	const base = env.get("TEMP") != "" ? env.get("TEMP") : "/tmp";
	const root = `${base}/msc-collect-bundle-${performance.now()}`;
	const savedGlobal = env.get("MSC_GLOBAL_CACHE_DIR");
	const savedOff = env.get("MSC_NO_GLOBAL_CACHE");
	env.set("MSC_GLOBAL_CACHE_DIR", root);
	env.set("MSC_NO_GLOBAL_CACHE", "");
	try {
		ensureDir(stampMemoRoot());
		assert backdated(`${stampMemoRoot()}/old.bundle`, "seal");
		assert writeFile(`${stampMemoRoot()}/new.bundle`, "seal").ok;
		assert backdated(`${stampMemoRoot()}/notes.txt`, "foreign");
		collectGlobalCache();
		assert !exists(`${stampMemoRoot()}/old.bundle`);
		assert exists(`${stampMemoRoot()}/new.bundle`);
		assert exists(`${stampMemoRoot()}/notes.txt`);
	} finally {
		env.set("MSC_GLOBAL_CACHE_DIR", savedGlobal);
		env.set("MSC_NO_GLOBAL_CACHE", savedOff);
		removeAll(root);
	}
}

test "a settled file is remembered by its change stamp" {
	const path = join(resolveRuntimeDir(), "runtime/core/system.h");
	assert settled(path);
	hashFile(path);
	assert _hashByStamp.get(path) != null;
}

test "a dependency file rewritten to the same size at once lists its new paths" {
	const base = env.get("TEMP") != "" ? env.get("TEMP") : "/tmp";
	const path = `${base}/msc-deps-stamp-${performance.now()}.d`;
	writeFile(path, "native: a.h b.h\n");
	assert dependencyPathsIn(path).join(",") == "a.h,b.h";
	assert dependencyPathsIn(path).join(",") == "a.h,b.h";
	writeFile(path, "native: c.h d.h\n");
	assert dependencyPathsIn(path).join(",") == "c.h,d.h";
	remove(path);
	assert dependencyPathsIn(path).length == 0;
}

test "a dependency file reads escaped spaces, line continuations and CRLF as clang writes them" {
	const base = env.get("TEMP") != "" ? env.get("TEMP") : "/tmp";
	const path = `${base}/msc-deps-escape-${performance.now()}.d`;
	writeFile(path, "native: C:/a.h \\\r\n  C:/my\\ dir/b.h \\\n  c\\\\d.h\te.h\r\n");
	assert parseDependencyFile(path).join("|") == "C:/a.h|C:/my dir/b.h|c\\d.h|e.h";
	writeFile(path, "native:\n");
	assert parseDependencyFile(path).length == 0;
	remove(path);
}

test "a dependency under the C compiler's own install is left to the compiler identity" {
	const base = env.get("TEMP") != "" ? env.get("TEMP") : "/tmp";
	const path = `${base}/msc-deps-owned-${performance.now()}.d`;
	writeFile(path, "native: C:/tools/Zig/lib/libc/include/stdio.h C:/proj/runtime/core/system.h C:/tools/zigx/lib/a.h\n");
	setToolchainHeaderRoot("C:\\tools\\zig\\lib");
	const owned = parseDependencyFile(path).join("|");
	setToolchainHeaderRoot("");
	const all = parseDependencyFile(path).join("|");
	remove(path);
	assert all == "C:/tools/Zig/lib/libc/include/stdio.h|C:/proj/runtime/core/system.h|C:/tools/zigx/lib/a.h";
	if (platform == "windows") assert owned == "C:/proj/runtime/core/system.h|C:/tools/zigx/lib/a.h";
	else assert owned == all;
}

test "a native source rewritten to the same size at once moves its fingerprint" {
	const base = env.get("TEMP") != "" ? env.get("TEMP") : "/tmp";
	const path = `${base}/msc-native-stamp-${performance.now()}.c`;
	writeFile(path, "int a;\n");
	const before = computeFingerprint(path, "cc");
	assert computeFingerprint(path, "cc") == before;
	writeFile(path, "int b;\n");
	assert computeFingerprint(path, "cc") != before;
	remove(path);
}

test "a link output rewritten to the same size at once is not taken as cached" {
	const base = env.get("TEMP") != "" ? env.get("TEMP") : "/tmp";
	const output = `${base}/msc-link-output-${performance.now()}.bin`;
	writeFile(output, "first");
	writeLinkCache([], [], "-flags", output, 0, "", output);
	assert isLinkCached([], [], "-flags", output, 0, "", output);
	writeFile(output, "other");
	assert !isLinkCached([], [], "-flags", output, 0, "", output);
	remove(output);
	remove(linkCacheFile(output));
}

test "an HCR image link is keyed by its objects' bytes, not their paths" {
	const base = env.get("TEMP") != "" ? env.get("TEMP") : "/tmp";
	const stem = `${base}/msc-image-objects-${performance.now()}`;
	const image = `${stem}.dylib`;
	writeFile(image, "image");
	writeFile(`${stem}.a.o`, "object");
	writeFile(`${stem}.b.o`, "object");
	writeLinkCache([`${stem}.a.o`], [], "-flags", image, 0, "", image);
	assert isLinkCached([`${stem}.b.o`], [], "-flags", image, 0, "", image);
	writeFile(`${stem}.b.o`, "changed");
	assert !isLinkCached([`${stem}.b.o`], [], "-flags", image, 0, "", image);
	for (const path of [image, `${stem}.a.o`, `${stem}.b.o`]) remove(path);
	remove(linkCacheFile(image));
}

test "a link record made by one C compiler misses under another, though the objects keep their bytes" {
	if (platform == "windows") return;
	const base = env.get("TEMP") != "" ? env.get("TEMP") : "/tmp";
	const stem = `${base}/msc-link-toolchain-${performance.now()}`;
	const image = `${stem}.dylib`;
	writeFile(image, "image");
	writeFile(`${stem}.o`, "object");
	writeLinkCache([`${stem}.o`], [], "-flags", image, 0, "cc", image);
	assert isLinkCached([`${stem}.o`], [], "-flags", image, 0, "cc", image);
	assert !isLinkCached([`${stem}.o`], [], "-flags", image, 0, "clang", image);
	const output = `${stem}.bin`;
	writeFile(output, "binary");
	writeLinkCache([`${stem}.o`], [], "-flags", output, 0, "cc");
	assert isLinkCached([`${stem}.o`], [], "-flags", output, 0, "cc");
	assert !isLinkCached([`${stem}.o`], [], "-flags", output, 0, "clang");
	for (const path of [image, output, `${stem}.o`, linkCacheFile(image), linkCacheFile()]) tryRemoveFile(path);
}

test "a link output recorded inside the settle window is identified by its content" {
	const base = env.get("TEMP") != "" ? env.get("TEMP") : "/tmp";
	const output = `${base}/msc-link-racy-${performance.now()}.bin`;
	writeFile(output, "first");
	assert outputIdentity(output).startsWith("content:");
	for (let i: int32 = 0; i < 50; i += 1) {
		writeFile(output, "first");
		writeLinkCache([], [], "-flags", output, 0, "", output);
		writeFile(output, "other");
		assert !isLinkCached([], [], "-flags", output, 0, "", output);
	}
	remove(output);
	remove(linkCacheFile(output));
}

test "a settled link output is trusted by its stamp and its record is upgraded once settled" {
	const base = env.get("TEMP") != "" ? env.get("TEMP") : "/tmp";
	const output = `${base}/msc-link-settled-${performance.now()}.bin`;
	writeFile(output, "first");
	writeLinkCache([], [], "-flags", output, 0, "", output);
	const contentRecord = try readFile(linkCacheFile(output)) catch "";
	assert contentRecord.includes(`${PRE_OUTHASH}content:`);
	const until = performance.now() + (SETTLED_SECONDS + 1) * 1000;
	while (performance.now() < until) {}
	assert isLinkCached([], [], "-flags", output, 0, "", output);
	const settledRecord = try readFile(linkCacheFile(output)) catch "";
	assert settledRecord.includes(`${PRE_OUTHASH}settled:`);
	assert isLinkCached([], [], "-flags", output, 0, "", output);
	writeFile(output, "other");
	assert !isLinkCached([], [], "-flags", output, 0, "", output);
	remove(output);
	remove(linkCacheFile(output));
}

test "a runtime or vendor file edit moves the support-tree stamp" {
	const base = env.get("TEMP") != "" ? env.get("TEMP") : "/tmp";
	const root = `${base}/msc-support-stamp-${performance.now()}`;
	ensureDir(`${root}/runtime`);
	ensureDir(`${root}/vendor/lib`);
	writeFile(`${root}/runtime/core.h`, "#define A 1\n");
	writeFile(`${root}/vendor/lib/x.h`, "#define B 1\n");
	const first = supportTreesStamp(root);
	assert supportTreesStamp(root) == first;
	writeFile(`${root}/vendor/lib/x.h`, "#define B 2\n");
	const vendorEdit = supportTreesStamp(root);
	assert vendorEdit != first;
	writeFile(`${root}/runtime/core.h`, "#define A 2\n");
	assert supportTreesStamp(root) != vendorEdit;
	removeAll(root);
}

let _settledTreesBase = "";

function settledSupportTree(tag: string): string {
	if (_settledTreesBase == "") {
		const base = env.get("TEMP") != "" ? env.get("TEMP") : "/tmp";
		_settledTreesBase = `${base}/msc-support-memo-${performance.now()}`;
		for (const t of ["edit", "seal", "add", "std"]) {
			ensureDir(`${_settledTreesBase}/${t}/runtime`);
			ensureDir(`${_settledTreesBase}/${t}/vendor/lib`);
			writeFile(`${_settledTreesBase}/${t}/runtime/core.h`, "#define A 1\n");
			writeFile(`${_settledTreesBase}/${t}/vendor/lib/x.h`, "#define B 1\n");
		}
		const until = performance.now() + (SETTLED_SECONDS + 1) * 1000;
		while (performance.now() < until) {}
	}
	return `${_settledTreesBase}/${tag}`;
}

function freshProcessStamp(root: string): string {
	_hashByStamp.clear();
	return supportTreesStamp(root);
}

function forgetSupportMemo(root: string): void {
	remove(hashMemoPath(root, "sum"));
	remove(hashMemoPath(root, "files"));
	removeAll(root);
}

function uncachedStamp(root: string): string {
	_hashByStamp.clear();
	const saved = env.get("MSC_NO_GLOBAL_CACHE");
	env.set("MSC_NO_GLOBAL_CACHE", "1");
	const stamp = supportTreesStamp(root);
	env.set("MSC_NO_GLOBAL_CACHE", saved);
	return stamp;
}

test "a support-tree stamp is served from disk to the next process and moves on a same-size edit" {
	if (globalCacheRoot() == "") return;
	const root = settledSupportTree("edit");
	const first = freshProcessStamp(root);
	assert readSealed(hashMemoPath(root, "sum")).length == 2;
	assert readSealed(hashMemoPath(root, "files")).length == 2;
	assert first == uncachedStamp(root);
	assert freshProcessStamp(root) == first;
	writeFile(`${root}/vendor/lib/x.h`, "#define B 2\n");
	const edited = freshProcessStamp(root);
	assert edited != first;
	assert edited == uncachedStamp(root);
	forgetSupportMemo(root);
}

test "a std-tree stamp is served from disk to the next process and moves on a same-size edit" {
	if (globalCacheRoot() == "") return;
	const dir = `${settledSupportTree("std")}/vendor`;
	const subject = `std:${dir}`;
	_hashByStamp.clear();
	const first = stdTreeStamp(dir);
	assert readSealed(hashMemoPath(subject, "sum")).length == 2;
	assert readSealed(hashMemoPath(subject, "files")).length == 1;
	_hashByStamp.clear();
	assert stdTreeStamp(dir) == first;
	writeFile(`${dir}/lib/x.h`, "#define B 2\n");
	_hashByStamp.clear();
	const edited = stdTreeStamp(dir);
	assert edited != first;
	remove(hashMemoPath(subject, "sum"));
	remove(hashMemoPath(subject, "files"));
	_hashByStamp.clear();
	assert stdTreeStamp(dir) == edited;
	remove(hashMemoPath(subject, "sum"));
	remove(hashMemoPath(subject, "files"));
	removeAll(dir);
}

test "a support-tree memo whose seal does not match its body is ignored" {
	if (globalCacheRoot() == "") return;
	const root = settledSupportTree("seal");
	const first = freshProcessStamp(root);
	const sum = readSealed(hashMemoPath(root, "sum"));
	writeFile(hashMemoPath(root, "sum"), `${HASH_MEMO_MAGIC}\n${sum[0]}\nforged-stamp\n${hashContent(`${sum[0]}\n${sum[1]}`)}`);
	const files = readSealed(hashMemoPath(root, "files"));
	const forged: string[] = [];
	for (const line of files) forged.push(`${line.substring(0, line.lastIndexOf("|") + 1)}forged`);
	writeFile(hashMemoPath(root, "files"), `${HASH_MEMO_MAGIC}\n${forged.join("\n")}\nnot-the-seal`);
	assert freshProcessStamp(root) == first;
	forgetSupportMemo(root);
}

test "a file added to a support tree moves the stamp served from disk" {
	if (globalCacheRoot() == "") return;
	const root = settledSupportTree("add");
	const first = freshProcessStamp(root);
	writeFile(`${root}/vendor/lib/y.h`, "#define C 1\n");
	const added = freshProcessStamp(root);
	assert added != first;
	assert added == uncachedStamp(root);
	forgetSupportMemo(root);
}

test "bug6: writeCompileFingerprint after writeCSource produces a cache hit" {
	// Happy path: cc returned 0, both .c and .cfp present, .o present →
	// isCCodeCached true so the next run reuses the object.
	const modPath = "test/bug6/probe_happy.ms";
	const cCode = "int main(){return 0;}";
	const cmd = "cc -O0";
	const fp = moduleCompileFp(cCode, cmd);
	bug6_clearArtifacts(modPath, fp);
	writeCSource(modPath, fp, cCode);
	// Simulate the .o that compileCFile would have produced.
	writeFile(stableOFileFp(modPath, fp), "");
	writeCompileFingerprint(modPath, cCode, cmd);
	assert exists(stableOFileFp(modPath, fp) + ".cfp");
	assert isCCodeCached(modPath, fp);
	bug6_clearArtifacts(modPath, fp);
}

test "bug6: invalidateCompileCache drops the .cfp and keeps the .o" {
	// Failure path: cc returned non-zero. Only the .cfp may be removed - it
	// is the sentinel a later run reads to SKIP compiling, so a stale one is
	// the only artifact that can turn a failed compile into a false hit.
	//
	// The .o must SURVIVE. It is fp-keyed, so any object at that path came
	// from the same C with the same command and is never partial (compileCFile
	// publishes by atomic rename, only on success). Removing it made one
	// process's failure delete an object a CONCURRENT build had just
	// published, and that build's link then died with FileNotFound.
	const modPath = "test/bug6/probe_invalidate.ms";
	const fp = moduleCompileFp("int x;", "cc -O0");
	bug6_clearArtifacts(modPath, fp);
	writeFile(stableOFileFp(modPath, fp), "");
	writeFile(stableOFileFp(modPath, fp) + ".cfp", "stale_fp:cc -O0");
	assert exists(stableOFileFp(modPath, fp));
	assert exists(stableOFileFp(modPath, fp) + ".cfp");
	invalidateCompileCache(modPath, fp);
	assert exists(stableOFileFp(modPath, fp));
	assert !exists(stableOFileFp(modPath, fp) + ".cfp");
	// The bug6 guarantee itself is unchanged: no .cfp means no cache hit.
	assert !isCCodeCached(modPath, fp);
	bug6_clearArtifacts(modPath, fp);
}

test "writeCSource writes an absent .c and heals a corrupted one" {
	const modPath = "test/bug6/probe_csource_heal.ms";
	const cCode = "int main(){return 0;}";
	const fp = moduleCompileFp(cCode, "cc -O0");
	bug6_clearArtifacts(modPath, fp);
	// Absent: written.
	writeCSource(modPath, fp, cCode);
	const fresh = try readFile(stableCFileFp(modPath, fp)) catch "";
	assert fresh == cCode;
	// Corrupted at the fp path (a host that died mid-flush leaves NULs of the
	// right length): must be REWRITTEN, not trusted because the path exists.
	writeFile(stableCFileFp(modPath, fp), "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0");
	writeCSource(modPath, fp, cCode);
	const healed = try readFile(stableCFileFp(modPath, fp)) catch "";
	assert healed == cCode;
	bug6_clearArtifacts(modPath, fp);
}

test "bug6: failed-compile sequence yields no cache hit on retry" {
	// End-to-end invariant: simulate the cmdBuildC sequence on cc failure.
	//   1. writeCSource (always)
	//   2. compileCFile fails → invalidateCompileCache, NO writeCompileFingerprint
	// Result must be: next isCCodeCached call returns false → retry compiles.
	const modPath = "test/bug6/probe_fail_seq.ms";
	const cCode = "broken c source";
	const cmd = "cc -O0";
	const fp = moduleCompileFp(cCode, cmd);
	bug6_clearArtifacts(modPath, fp);
	writeCSource(modPath, fp, cCode);
	// (compileCFile would fail here — skip writeCompileFingerprint)
	invalidateCompileCache(modPath, fp);
	assert !isCCodeCached(modPath, fp);
	bug6_clearArtifacts(modPath, fp);
}

test "distinct fingerprints get distinct physical objects" {
	// The drc/orc concurrent repro: two configs sharing one .o path let a
	// drc link pick up an orc object (undefined symbols). fp-keyed paths
	// must give each fingerprint its own file.
	const modPath = "test/bug6/probe_two_configs.ms";
	const fpA = moduleCompileFp("int main(){}", "cc -O0");
	const fpB = moduleCompileFp("int main(){}", "cc -O2");
	assert stableOFileFp(modPath, fpA) != stableOFileFp(modPath, fpB);
	assert stableCFileFp(modPath, fpA) != stableCFileFp(modPath, fpB);
	bug6_clearArtifacts(modPath, fpA);
	bug6_clearArtifacts(modPath, fpB);
}

test "long source paths keep bounded distinct cache names" {
	const sharedTail = "/src/test/corpus/programs/deeplyNested/sharedModule.ms";
	const pathA = "C:/Users/example/worktrees/one/very/long/project/root" + sharedTail;
	const pathB = "D:/Users/example/worktrees/two/very/long/project/root" + sharedTail;
	const fp = moduleCompileFp("int main(){}", "cc -O0");
	const cA = stableCFileFp(pathA, fp);
	const cB = stableCFileFp(pathB, fp);
	const dA = nativeDepFile(pathA, "cc -O0");
	const dB = nativeDepFile(pathB, "cc -O0");
	assert cA.length < 128;
	assert cA != cB;
	assert dA.length < 128;
	assert dA != dB;
}

test "cache miss keeps the stale object in place (no remove-on-miss)" {
	// A miss must force a recompile, never delete a cache object: a concurrent
	// build may be linking through it right now. The old remove-on-miss raced
	// links into FileNotFound under parallel builds sharing one cache dir.
	const modPath = "test/bug6/probe_keep.ms";
	const fp = moduleCompileFp("int main(){}", "cc -O0");
	bug6_clearArtifacts(modPath, fp);
	writeFile(stableOFileFp(modPath, fp), "old-object");
	writeFile(stableOFileFp(modPath, fp) + ".cfp", "stale-fp");
	assert !isCCodeCached(modPath, fp);
	assert exists(stableOFileFp(modPath, fp));
	assert atomicWriteFile(stableOFileFp(modPath, fp), "new-object");
	const body = try readFile(stableOFileFp(modPath, fp)) catch "";
	assert body == "new-object";
	bug6_clearArtifacts(modPath, fp);
}

test "atomicWriteFile replaces existing content and leaves no tmp siblings" {
	const p = `${getCacheDir()}/atomic_probe.txt`;
	atomicWriteFile(p, "one");
	atomicWriteFile(p, "two");
	const c = try readFile(p) catch "";
	assert c == "two";
	const entries = readDir(getCacheDir());
	let leftovers = 0;
	for (const e of entries) {
		if (e.indexOf("atomic_probe.txt.tmp.", 0) >= 0) leftovers = leftovers + 1;
	}
	assert leftovers == 0;
	remove(p);
}

// ===== Header Module Cache (Layer 5) tests =====
//
// Disk mechanics only — wrapper orchestration lives in module/loader.ms
// tests. Fixtures are real files under /tmp (same convention as bug043).

const mshcDir = "/tmp/mshc-" + String(Math.floor(Math.random() * 1000000000));

test "header cache: store → hit, dep content change → miss, restore → hit" {
	ensureDir(mshcDir);
	const hpath = mshcDir + "/hcx.h";
	const orig = "extern int hcx(void);\n";
	writeFile(hpath, orig);
	const key = headerModuleKey("extern int hcx(void);", mshcDir + "/hcx.h", "linux-x86_64");
	storeHeaderModule(key, [`${hpath}\t${hashContent(orig)}`], "OUT-1");
	assert lookupHeaderModule(key) == "OUT-1";
	writeFile(hpath, "extern int hcx2(void);\n");
	assert lookupHeaderModule(key) == "";
	writeFile(hpath, orig);
	assert lookupHeaderModule(key) == "OUT-1";
}

test "header cache: absent dep stays valid until the file appears" {
	const gone = mshcDir + "/gone.h";
	if (exists(gone)) remove(gone);
	const key = headerModuleKey("extern int m(void);", mshcDir + "/gone.h", "linux-x86_64");
	storeHeaderModule(key, [`${gone}\t-`], "OUT-2");
	assert lookupHeaderModule(key) == "OUT-2";
	writeFile(gone, "int x;\n");
	assert lookupHeaderModule(key) == "";
	if (exists(gone)) remove(gone);
}

test "header cache: deps under runtime//vendor/ skip disk re-verification" {
	const key = headerModuleKey("extern int r(void);", mshcDir + "/r.h", "linux-x86_64");
	const stampedPath = `${resolveRuntimeDir()}/runtime/definitely-not-here.h`;
	storeHeaderModule(key, [`${stampedPath}\tdeadbeef`], "OUT-3");
	assert lookupHeaderModule(key) == "OUT-3";
}

test "header cache: malformed dep line is a miss, empty dep list is a hit" {
	const keyA = headerModuleKey("extern int x1(void);", mshcDir + "/x1.h", "linux-x86_64");
	storeHeaderModule(keyA, ["nodep-newline"], "OUT-4");
	assert lookupHeaderModule(keyA) == "";
	const keyB = headerModuleKey("extern int x2(void);", mshcDir + "/x2.h", "linux-x86_64");
	storeHeaderModule(keyB, [], "OUT-5");
	assert lookupHeaderModule(keyB) == "OUT-5";
}

test "header cache: a translation for one build target is not a hit for another" {
	const src = "extern int t(void);";
	const linux = headerModuleKey(src, mshcDir + "/t.h", "linux-x86_64");
	const windows = headerModuleKey(src, mshcDir + "/t.h", "windows-x86_64");
	assert linux != windows;
	storeHeaderModule(linux, [], "OUT-LINUX");
	assert lookupHeaderModule(windows) == "";
}

test "header cache: MSC_NO_HEADER_CACHE disables both directions" {
	const key = headerModuleKey("extern int k(void);", mshcDir + "/k.h", "linux-x86_64");
	storeHeaderModule(key, [], "OUT-6");
	assert lookupHeaderModule(key) == "OUT-6";
	env.set("MSC_NO_HEADER_CACHE", "1");
	try {
		assert lookupHeaderModule(key) == "";
		storeHeaderModule(key, [], "OUT-7");
	} finally {
		env.delete("MSC_NO_HEADER_CACHE");
	}
	assert lookupHeaderModule(key) == "OUT-6";
}

test "the C compiler identity moves with its path, size, mtime and version" {
	const base = compilerIdentity("zig cc", "/opt/zig/zig", 177108480, 1700000000, "0.16.0");
	assert compilerIdentity("zig cc", "/opt/zig/zig", 177108480, 1700000000, "0.16.0") == base;
	assert compilerIdentity("zig cc", "/opt/zig2/zig", 177108480, 1700000000, "0.16.0") != base;
	assert compilerIdentity("zig cc", "/opt/zig/zig", 177108481, 1700000000, "0.16.0") != base;
	assert compilerIdentity("zig cc", "/opt/zig/zig", 177108480, 1700000001, "0.16.0") != base;
	assert compilerIdentity("zig cc", "/opt/zig/zig", 177108480, 1700000000, "0.16.1") != base;
	assert compilerIdentity("clang", "/opt/zig/zig", 177108480, 1700000000, "0.16.0") != base;
}

test "a precompiled header goes stale when a header it includes changes in place" {
	const dir = `out/test/pchManifest${performance.now()}`;
	ensureDir(dir);
	const inner = (value: string): string => `#ifndef INNER_H\n#define INNER_H\n#define INNER_VALUE ${value}\n#endif\n`;
	writeFile(`${dir}/inner.h`, inner("41"));
	writeFile(`${dir}/rt.h`, "#ifndef RT_H\n#define RT_H\n#include \"inner.h\"\nstatic inline int rtValue(void) { return INNER_VALUE; }\n#endif\n");
	writeFile(`${dir}/prefix.h`, "#include \"rt.h\"\n");
	assert buildPch(`${dir}/prefix.h`, `${dir}/prefix.pch`, `${dir}/prefix.pch.d`, `-iquote${dir}`, 0, 0, "");
	assert writePchManifest(`${dir}/prefix.pch.d`, `${dir}/prefix.pch.deps`);
	assert pchManifestCurrent(`${dir}/prefix.pch.deps`);
	writeFile(`${dir}/inner.h`, inner("42"));
	assert !pchManifestCurrent(`${dir}/prefix.pch.deps`);
	assert !pchManifestCurrent(`${dir}/absent.pch.deps`);
}

const SAMPLE_SEARCH = [
	"clang version 19.1.0",
	" \"/usr/bin/clang\" -cc1 -triple arm64 -E -v -x c /dev/null",
	"ignoring nonexistent directory \"/opt/none/include\"",
	"#include \"...\" search starts here:",
	"#include <...> search starts here:",
	" /usr/local/include",
	" /usr/include",
	" /Library/Frameworks (framework directory)",
	"End of search list.",
];

test "a search list keeps its directories, frameworks and absent directories and skips the command line" {
	const found = parseImplicitSearch(SAMPLE_SEARCH.join("\n"), "k");
	assert found.complete;
	assert found.dirs.join("|") == "/opt/none/include|/usr/local/include|/usr/include";
	assert found.frameworks.join("|") == "/opt/none/include|/Library/Frameworks";
	assert parseImplicitSearch(searchLines(found).join("\n"), "k").key == found.key;
}

test "a search list without its end or with a header map is incomplete" {
	assert !parseImplicitSearch(SAMPLE_SEARCH.slice(0, SAMPLE_SEARCH.length - 1).join("\n"), "k").complete;
	const mapped = SAMPLE_SEARCH.slice(0);
	mapped.splice(5, 0, " /work/app.hmap (headermap)");
	assert !parseImplicitSearch(mapped.join("\n"), "k").complete;
	assert !parseImplicitSearch("", "k").complete;
}

test "the selected developer directory keys the compiler identity on macOS only" {
	const saved = env.get("DEVELOPER_DIR");
	env.set("DEVELOPER_DIR", "/msc/first");
	const first = developerToolchain();
	env.set("DEVELOPER_DIR", "/msc/second");
	const second = developerToolchain();
	if (saved == "") {
		env.delete("DEVELOPER_DIR");
	} else {
		env.set("DEVELOPER_DIR", saved);
	}
	if (platform == "darwin") {
		assert first != second;
	} else {
		assert first == "" && second == "";
	}
}

test "a source or dependency that cannot be read leaves the header query record untrusted" {
	const dir = `out/test/unreadableQueries${performance.now()}`;
	ensureDir(`${dir}/dep.h`);
	writeFile(`${dir}/entry.c`, "int a;\n");
	const search: HeaderSearch = { dirs: [], frameworks: [], complete: true };
	assert queryRecord([`${dir}/entry.c`], [], search, []).bounded;
	assert !queryRecord([`${dir}/gone.c`], [], search, []).bounded;
	assert !queryRecord([`${dir}/entry.c`], [`${dir}/dep.h`], search, []).bounded;
}

function versionFixture(modPath: string, baseFp: string, objectFp: string): string[] {
	const o = stableOFileFp(modPath, objectFp);
	const d = moduleDepFile(modPath, baseFp);
	ensureDir(`${dirname(d)}/presence`);
	const files = [d, `${d}.q`, `${dirname(d)}/presence/${basename(d)}.qs`, o, `${o}.cfp`];
	for (const file of files) writeFile(file, "x");
	return files;
}

function removeFixture(files: string[]): void {
	for (const file of files) tryRemoveFile(file);
}

const PAST_LIVE_WINDOW = LIVE_VERSION_SECONDS + 60;

test "a superseded version used inside the live window stays beside the new one" {
	const modPath = `test/settle/live${performance.now()}.ms`;
	const stem = cacheStem(modPath);
	const first = moduleCompileFp("int a;", "cc -O0");
	const second = moduleCompileFp("int b;", "cc -O0");
	const v1 = versionFixture(modPath, first, `${first}:objects`);
	settleModuleVersion(modPath, first, [v1[3]]);
	const v2 = versionFixture(modPath, second, `${second}:objects`);
	settleModuleVersion(modPath, second, [v2[3]]);
	for (const file of v1) assert exists(file);
	for (const file of v2) assert exists(file);
	const third = moduleCompileFp("int d;", "cc -O0");
	const v3 = versionFixture(modPath, third, `${third}:objects`);
	settleModuleVersion(modPath, third, [v3[3]], nowSeconds() + PAST_LIVE_WINDOW);
	for (const file of v1) assert !exists(file);
	for (const file of v2) assert !exists(file);
	for (const file of v3) assert exists(file);
	removeFixture(v3);
	removeFixture([moduleVersionRecord(stem)]);
}

test "a version unused past the live window goes with nothing but its own files" {
	const modPath = `test/settle/probe${performance.now()}.ms`;
	const stem = cacheStem(modPath);
	const first = moduleCompileFp("int a;", "cc -O0");
	const second = moduleCompileFp("int b;", "cc -O0");
	const other = moduleCompileFp("int c;", "cc -O2");
	const v1 = versionFixture(modPath, first, `${first}:objects`);
	const bystander = `${getCacheDir()}/${stem}.notakey.o`;
	const sibling = `${getCacheDir()}/${stem}2.${fpKey(first)}.o`;
	writeFile(bystander, "x");
	writeFile(sibling, "x");
	settleModuleVersion(modPath, first, [v1[3]]);
	const v3 = versionFixture(modPath, other, `${other}:objects`);
	settleModuleVersion(modPath, other, [v3[3]], nowSeconds() + PAST_LIVE_WINDOW);
	for (const file of v1) assert exists(file);
	const v2 = versionFixture(modPath, second, `${second}:objects`);
	settleModuleVersion(modPath, second, [v2[3]], nowSeconds() + PAST_LIVE_WINDOW);
	for (const file of v2) assert exists(file);
	for (const file of v3) assert exists(file);
	for (const file of v1) assert !exists(file);
	assert exists(bystander);
	assert exists(sibling);
	removeFixture(v2);
	removeFixture(v3);
	removeFixture([bystander, sibling, moduleVersionRecord(stem)]);
}

test "an object of the same version keeps while it was used inside the window and goes after" {
	const modPath = `test/settle/objects${performance.now()}.ms`;
	const stem = cacheStem(modPath);
	const base = moduleCompileFp("int a;", "cc -O0");
	const v1 = versionFixture(modPath, base, `${base}:headers-one`);
	const v2 = versionFixture(modPath, base, `${base}:headers-two`);
	settleModuleVersion(modPath, base, [v1[3]]);
	settleModuleVersion(modPath, base, [v2[3]]);
	assert exists(v1[3]);
	assert exists(v1[4]);
	settleModuleVersion(modPath, base, [v2[3]], nowSeconds() + PAST_LIVE_WINDOW);
	assert !exists(v1[3]);
	assert !exists(v1[4]);
	for (const file of v2) assert exists(file);
	removeFixture(v2);
	removeFixture([moduleVersionRecord(stem)]);
}

test "a cache hit refreshes its version so the publish of another version keeps it and removes an unused one" {
	if (platform == "windows") return;
	const modPath = `test/settle/hit${performance.now()}.ms`;
	const stem = cacheStem(modPath);
	const used = moduleCompileFp("int a;", "cc -O0");
	const idle = moduleCompileFp("int b;", "cc -O0");
	const next = moduleCompileFp("int c;", "cc -O0");
	const usedObjectFp = `${used}:objects`;
	const v1 = versionFixture(modPath, used, usedObjectFp);
	const v2 = versionFixture(modPath, idle, `${idle}:objects`);
	writeFile(v1[4], usedObjectFp);
	settleModuleVersion(modPath, used, [v1[3]]);
	settleModuleVersion(modPath, idle, [v2[3]]);
	assert execFileCapture("touch", ["-t", "200001010000", ...v1, ...v2]).ok;
	assert isCCodeCached(modPath, usedObjectFp);
	const v3 = versionFixture(modPath, next, `${next}:objects`);
	settleModuleVersion(modPath, next, [v3[3]]);
	for (const file of v1) assert exists(file);
	for (const file of v2) assert !exists(file);
	for (const file of v3) assert exists(file);
	removeFixture(v1);
	removeFixture(v3);
	removeFixture([moduleVersionRecord(stem)]);
}

test "a removed version leaves the C source every config shares by its content" {
	const modPath = `test/settle/shared${performance.now()}.ms`;
	const stem = cacheStem(modPath);
	const c = stableCFileFp(modPath, moduleStoreSource("int a;"));
	writeFile(c, "int a;");
	const debug = moduleCompileFp("int a;", "cc -O0");
	const next = moduleCompileFp("int c;", "cc -O0");
	const v1 = versionFixture(modPath, debug, `${debug}:objects`);
	settleModuleVersion(modPath, debug, [v1[3]]);
	const v2 = versionFixture(modPath, next, `${next}:objects`);
	settleModuleVersion(modPath, next, [v2[3]], nowSeconds() + PAST_LIVE_WINDOW);
	for (const file of v1) assert !exists(file);
	assert exists(c);
	removeFixture([moduleVersionRecord(stem)]);
	_cacheListing = null;
	const later = moduleCompileFp("int d;", "cc -O0");
	const v3 = versionFixture(modPath, later, `${later}:objects`);
	settleModuleVersion(modPath, later, [v3[3]], nowSeconds() + PAST_LIVE_WINDOW);
	for (const file of v2) assert !exists(file);
	assert exists(c);
	removeFixture([c, ...v3, moduleVersionRecord(stem)]);
}

test "the first version recorded for a module also removes the versions an older compiler left once they are unused" {
	const modPath = `test/settle/legacy${performance.now()}.ms`;
	const stem = cacheStem(modPath);
	const old = moduleCompileFp("int a;", "cc -O0");
	const current = moduleCompileFp("int b;", "cc -O0");
	const legacy = versionFixture(modPath, old, `${old}:objects`);
	const live = versionFixture(modPath, current, `${current}:objects`);
	const bystander = `${getCacheDir()}/${stem}.link.cache`;
	writeFile(bystander, "x");
	_cacheListing = null;
	settleModuleVersion(modPath, current, [live[3]], nowSeconds() + PAST_LIVE_WINDOW);
	for (const file of legacy) assert !exists(file);
	for (const file of live) assert exists(file);
	assert exists(bystander);
	removeFixture(live);
	removeFixture([bystander, moduleVersionRecord(stem)]);
}

test "a version file name is recognised only in the shapes the compiler writes" {
	const key = fpKey("x");
	const stem = "a_d_b_x_ms";
	assert !isVersionFileOf(stem, `${stem}.${key}.c`);
	assert isVersionFileOf(stem, `${stem}.${key}.d.q`);
	assert isVersionFileOf(stem, `${stem}.${key}.o`);
	assert isVersionFileOf(stem, `${stem}.${key}.o.cfp`);
	assert !isVersionFileOf(stem, `${stem}.${key}.o.tmp.1`);
	assert !isVersionFileOf(stem, `${stem}.${key}.${key}.c`);
	assert !isVersionFileOf(stem, `${stem}.${key}.${key}.o.cfp`);
	assert !isVersionFileOf(stem, `${stem}.versions`);
	assert !isVersionFileOf(stem, `${stem}.${key}.o.fp`);
	assert !isVersionFileOf("a_d_b", `${stem}.${key}.c`);
}

test "with trim roots a module's cache name is the same under every checkout path" {
	const saved = _stemRoots;
	_stemRoots = stemRootsOf(["/work/a", "/work/a/msc", "/home/u/.metascript/cache/extracted"]);
	const first = cacheStem("/work/a/src/main.ms");
	const std = cacheStem("/work/a/msc/std/core/index.ms");
	const pkg = cacheStem("/home/u/.metascript/cache/extracted/lib/x.ms");
	_stemRoots = stemRootsOf(["/other/b", "/other/b/msc", "/home/v/.metascript/cache/extracted"]);
	assert cacheStem("/other/b/src/main.ms") == first;
	assert cacheStem("/other/b/msc/std/core/index.ms") == std;
	assert cacheStem("/home/v/.metascript/cache/extracted/lib/x.ms") == pkg;
	assert std != cacheStem("/other/b/msc_std_core_index.ms");
	assert cacheStem("/elsewhere/y.ms") == sanitizePath("/elsewhere/y.ms");
	_stemRoots = [];
	assert cacheStem("/work/a/src/main.ms") == sanitizePath("/work/a/src/main.ms");
	_stemRoots = saved;
}

test "a trimmed manifest names roots by token and reads back against the reading checkout's roots" {
	const saved = _stemRoots;
	const manifest = (root: string): string => `${STORE_FORMAT}\nq\t${root}/src\nd\t${root}/msc/runtime/core.h\tabc\ns\t${root}\tcore.h\ne\t/usr/include/x.h\t1\n`;
	_stemRoots = stemRootsOf(["/work/a", "/work/a/msc", ""]);
	const written = tokensOfRoots(manifest("/work/a"));
	assert written == `${STORE_FORMAT}\nq\t@p/src\nd\t@s/runtime/core.h\tabc\ns\t@p\tcore.h\ne\t/usr/include/x.h\t1\n`;
	_stemRoots = stemRootsOf(["/other/b", "/other/b/msc", ""]);
	assert tokensOfRoots(manifest("/other/b")) == written;
	assert rootsOfTokens(written) == manifest("/other/b");
	_stemRoots = [];
	assert tokensOfRoots(manifest("/work/a")) == manifest("/work/a");
	_stemRoots = saved;
}

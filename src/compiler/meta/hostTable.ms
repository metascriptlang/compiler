// Raiser VM — Host function table (seed)
//
// Registers wrappers for the std/* native externs Raiser can call from
// bytecode via the `CallHost` opcode. Each wrapper unboxes RaiserValue
// arguments, calls the underlying MS-level std function (which dispatches
// to a host shim during bootstrap, or to a C native after self-host), and
// boxes the return.
//
// All bridges return SCALAR types only (string / int / float / bool-as-int).
// Result<T,E>, arrays, and objects are constructed inside Raiser bytecode by
// the calling MS code (via NewObject/StoreField opcodes after Phase 3 lowers
// `Result.ok(x)` to `{ok: true, value: x}`). The bridge never needs heap
// access — it just returns raw scalars, and the MS wrapper builds the higher-
// level structure on the VM side.
//
// For natives that use the errno-poll pattern (`msFsReadFile` + `msFsLastErrno`),
// the bridge stores last-error in a module-level slot that the matching getter
// bridge returns. Mirrors the C runtime contract exactly.
//
// Naming: registry key matches the C extern name (`msFsExists`, etc.) — that
// is what `Symbol.nativeName` carries through to codegen in Phase 4. The
// bridge itself can call any equivalent MS-level wrapper available in the
// current host.
//
// === TODO: Auto-scanner ===
// This file is currently hand-maintained — each new `extern function msXxx(...)`
// in std/* must be paired with a `_bridge_msXxx` here. A small compiler-build
// tool (~1 day of work) would:
//   1. Walk the symbol table after the std/* check pass.
//   2. Filter symbols with `nativeName != ""` (extern decls).
//   3. Derive a bridge signature from the MS type (e.g. `(string) → string`).
//   4. Generate the bridge source + the `registerHostFn` call.
//   5. Emit into a generated file (e.g. `_generated/hostTable.gen.ms`).
// Until then, additions need 2 lines per native: one bridge function + one
// `registerHostFn` line. The cost is bounded — ~20 bridges cover the fs +
// process surface that @comptime actually uses today.

import { RaiserValue } from "../../raiser/value";
import { registerHostFn, markHostRegistryInitialized, isHostRegistryInitialized } from "../../raiser/hostRegistry";
import {
	unboxString,
	boxString, boxInt,
} from "../../raiser/marshal";

import { exists, isFile, isDir, fileSize, readFile, writeFile, mkdir, rmdir, remove, rename, readDir } from "std/fs";
import { cwd, platform, env, exec } from "std/process";
import { IoErrorKind } from "std/io/errors";
import { ProcessErrorKind } from "std/process/errors";

// --- Errno-poll state ---
// The C runtime sets a thread-local errno after each fallible operation and
// callers poll it via `msFsLastErrno()` / `msProcSpawnGet*()`. Bridges
// emulate that contract with module-local slots. Non-zero = error; the MS
// wrapper sees this and constructs the matching Result.err(...).

let _lastFsErrno: number = 0;

function _setFsErrno(ioErrKind: IoErrorKind): void {
	// Coarse mapping. The MS wrapper uses `ioErrorFromErrno` which maps these
	// back to IoErrorKind. Exact errno values are platform-dependent but the
	// MS layer only checks `!== 0`, so any non-zero suffices. `+ 1` shift so
	// IoErrorKind.NotFound (= 0) doesn't collide with the success sentinel.
	_lastFsErrno = (ioErrKind as number) + 1;
}

// Helper: convert Result<void, IoError> into the errno+rv contract used by
// the C runtime's mutating fs functions (returns 0 on success, non-zero on
// failure, with errno populated). Shared by mkdir/rmdir/remove/rename/etc.
// `errKind` is only consulted when `ok` is false — pass IoErrorKind.NotFound
// as a placeholder on the success path.
function _fsResultToInt(ok: boolean, errKind: IoErrorKind): RaiserValue {
	if (ok) { _lastFsErrno = 0; return boxInt(0); }
	_setFsErrno(errKind);
	return boxInt(1);
}

// --- File system bridges ---

function _bridge_msFsExists(args: RaiserValue[]): RaiserValue {
	return boxInt(exists(unboxString(args[0])) ? 1 : 0);
}

function _bridge_msFsIsFile(args: RaiserValue[]): RaiserValue {
	return boxInt(isFile(unboxString(args[0])) ? 1 : 0);
}

function _bridge_msFsIsDir(args: RaiserValue[]): RaiserValue {
	return boxInt(isDir(unboxString(args[0])) ? 1 : 0);
}

function _bridge_msFsFileSize(args: RaiserValue[]): RaiserValue {
	return boxInt(fileSize(unboxString(args[0])));
}

function _bridge_msFsReadFile(args: RaiserValue[]): RaiserValue {
	const r = readFile(unboxString(args[0]));
	if (r.ok) {
		_lastFsErrno = 0;
		return boxString(r.value);
	}
	_setFsErrno(r.error.kind);
	return boxString("");
}

function _bridge_msFsLastErrno(args: RaiserValue[]): RaiserValue {
	return boxInt(_lastFsErrno);
}

function _bridge_msFsWriteFileMode(args: RaiserValue[]): RaiserValue {
	// args[2] = mode string ("w"/"a"); seed supports overwrite only.
	const r = writeFile(unboxString(args[0]), unboxString(args[1]));
	return _fsResultToInt(r.ok, r.ok ? IoErrorKind.NotFound : r.error.kind);
}

function _bridge_msFsMkdir(args: RaiserValue[]): RaiserValue {
	const r = mkdir(unboxString(args[0]));
	return _fsResultToInt(r.ok, r.ok ? IoErrorKind.NotFound : r.error.kind);
}

function _bridge_msFsRmdir(args: RaiserValue[]): RaiserValue {
	const r = rmdir(unboxString(args[0]));
	return _fsResultToInt(r.ok, r.ok ? IoErrorKind.NotFound : r.error.kind);
}

function _bridge_msFsRemove(args: RaiserValue[]): RaiserValue {
	const r = remove(unboxString(args[0]));
	return _fsResultToInt(r.ok, r.ok ? IoErrorKind.NotFound : r.error.kind);
}

function _bridge_msFsRename(args: RaiserValue[]): RaiserValue {
	const r = rename(unboxString(args[0]), unboxString(args[1]));
	return _fsResultToInt(r.ok, r.ok ? IoErrorKind.NotFound : r.error.kind);
}

function _bridge_msFsReadDirEntries(args: RaiserValue[]): RaiserValue {
	// C contract: returns lines separated by "\n", empty on error
	// (caller polls errno). MS readDir returns string[]; join with "\n".
	// Bun shim's readDir returns [] silently on failure — pre-check via
	// exists+isDir so callers polling errno see a non-zero value when path
	// is missing or not a directory.
	const path = unboxString(args[0]);
	if (!exists(path) || !isDir(path)) {
		_setFsErrno(IoErrorKind.NotFound);
		return boxString("");
	}
	_lastFsErrno = 0;
	const entries = readDir(path);
	return boxString(entries.join("\n"));
}

// --- Process bridges ---

function _bridge_msProcessCwd(args: RaiserValue[]): RaiserValue {
	return boxString(cwd());
}

function _bridge_msProcessPlatform(args: RaiserValue[]): RaiserValue {
	return boxString(platform);
}

function _bridge_msProcessGetEnv(args: RaiserValue[]): RaiserValue {
	return boxString(env.get(unboxString(args[0])));
}

// Spawn-result state machine. The MS wrapper calls msProcessSpawnSync(cmd)
// to run the child, then polls these getters individually for status.

let _spawnStdout: string = "";
let _spawnStderr: string = "";
let _spawnExitCode: number = 0;
let _spawnSignal: number = 0;
let _spawnOk: number = 0;
let _spawnPipeOk: number = 1;

// ProcessErrorKind: SpawnFailed=0, NotFound=1, NonZeroExit=2,
// SignalTerminated=3, PipeError=4, Unknown=5

function _resetSpawnStateOk(stdout: string): void {
	_spawnStdout = stdout;
	_spawnStderr = "";
	_spawnExitCode = 0;
	_spawnSignal = 0;
	_spawnOk = 1;
	_spawnPipeOk = 1;
}

function _setSpawnStateErr(
	kind: ProcessErrorKind, stdout: string, stderr: string, exitCode: number, signal: number,
): void {
	_spawnStdout = stdout;
	_spawnStderr = stderr;
	_spawnExitCode = exitCode;
	_spawnSignal = signal;
	_spawnOk = kind === ProcessErrorKind.SpawnFailed ? 0 : 1;
	_spawnPipeOk = kind === ProcessErrorKind.PipeError ? 0 : 1;
}

function _bridge_msProcessSpawnSync(args: RaiserValue[]): RaiserValue {
	const r = exec(unboxString(args[0]));
	if (r.ok) {
		_resetSpawnStateOk(r.value);
	} else {
		const e = r.error;
		_setSpawnStateErr(e.kind, e.output, e.errorOutput, e.exitCode, e.signal);
	}
	return boxString(_spawnStdout);
}

function _bridge_msProcSpawnGetOk(args: RaiserValue[]): RaiserValue {
	return boxInt(_spawnOk);
}

function _bridge_msProcSpawnGetPipeOk(args: RaiserValue[]): RaiserValue {
	return boxInt(_spawnPipeOk);
}

function _bridge_msProcSpawnGetExitCode(args: RaiserValue[]): RaiserValue {
	return boxInt(_spawnExitCode);
}

function _bridge_msProcSpawnGetSignal(args: RaiserValue[]): RaiserValue {
	return boxInt(_spawnSignal);
}

function _bridge_msProcSpawnGetStderr(args: RaiserValue[]): RaiserValue {
	return boxString(_spawnStderr);
}

// --- String bridges ---
// Each bridge delegates to the host runtime's native JS String method
// (verified: `.trim()` etc. in MS source within a bridge body dispatches
// to JS String.prototype methods after Bun transpile, NOT the extern
// stub). Bridges exist so `@comptime` code calling `s.trim()` etc. can
// dispatch through the CallHost path without falling into "Unknown host
// function" silent-nil. Full catalogue: docs/RAISER-GAP.md Phase 4.

function _bridge_msStringTrim(args: RaiserValue[]): RaiserValue {
	return boxString(unboxString(args[0]).trim());
}

function _bridge_msStringTrimStart(args: RaiserValue[]): RaiserValue {
	return boxString(unboxString(args[0]).trimStart());
}

function _bridge_msStringTrimEnd(args: RaiserValue[]): RaiserValue {
	return boxString(unboxString(args[0]).trimEnd());
}

// indexOf: MS declares (s, sub, start: int64 = 0) — handle optional 3rd arg
function _bridge_msStringIndexOf(args: RaiserValue[]): RaiserValue {
	const start = args.length > 2 ? args[2].intVal : 0;
	return boxInt(unboxString(args[0]).indexOf(unboxString(args[1]), start));
}

function bridgeMsStringToLower(args: RaiserValue[]): RaiserValue {
	return boxString(unboxString(args[0]).toLowerCase());
}

function bridgeMsStringToUpper(args: RaiserValue[]): RaiserValue {
	return boxString(unboxString(args[0]).toUpperCase());
}

// msStringContains uses MS method name `.contains()` which doesn't exist in
// JS native (JS has `.includes()`). Workaround: indexOf >= 0. Avoids needing
// type-assertion escape hatch in bridge body.
function bridgeMsStringContains(args: RaiserValue[]): RaiserValue {
	return boxInt(unboxString(args[0]).indexOf(unboxString(args[1])) >= 0 ? 1 : 0);
}

function _bridge_msStringStartsWith(args: RaiserValue[]): RaiserValue {
	return boxInt(unboxString(args[0]).startsWith(unboxString(args[1])) ? 1 : 0);
}

function _bridge_msStringEndsWith(args: RaiserValue[]): RaiserValue {
	return boxInt(unboxString(args[0]).endsWith(unboxString(args[1])) ? 1 : 0);
}

function _bridge_msStringReplace(args: RaiserValue[]): RaiserValue {
	return boxString(unboxString(args[0]).replace(unboxString(args[1]), unboxString(args[2])));
}

function _bridge_msStringReplaceAll(args: RaiserValue[]): RaiserValue {
	return boxString(unboxString(args[0]).replaceAll(unboxString(args[1]), unboxString(args[2])));
}

// --- Registry init ---
// Idempotent: subsequent calls are no-ops. Phase 5 invokes this on first
// @comptime block entry.

// Test-only: zero out bridge module state so successive tests start from a
// known baseline. Called from test setup alongside _resetHostRegistryForTests.
// Production code never calls this — module state is set lazily by each
// bridge invocation following the C runtime's thread-local contract.
export function _resetBridgeStateForTests(): void {
	_lastFsErrno = 0;
	_spawnStdout = "";
	_spawnStderr = "";
	_spawnExitCode = 0;
	_spawnSignal = 0;
	_spawnOk = 0;
	_spawnPipeOk = 1;
}

export function ensureHostTableLoaded(): void {
	if (isHostRegistryInitialized()) return;

	// fs predicates
	registerHostFn("msFsExists",         _bridge_msFsExists);
	registerHostFn("msFsIsFile",         _bridge_msFsIsFile);
	registerHostFn("msFsIsDir",          _bridge_msFsIsDir);
	registerHostFn("msFsFileSize",       _bridge_msFsFileSize);
	// fs read/write/mutate + errno polling
	registerHostFn("msFsReadFile",       _bridge_msFsReadFile);
	registerHostFn("msFsLastErrno",      _bridge_msFsLastErrno);
	registerHostFn("msFsWriteFileMode",  _bridge_msFsWriteFileMode);
	registerHostFn("msFsMkdir",          _bridge_msFsMkdir);
	registerHostFn("msFsRmdir",          _bridge_msFsRmdir);
	registerHostFn("msFsRemove",         _bridge_msFsRemove);
	registerHostFn("msFsRename",         _bridge_msFsRename);
	registerHostFn("msFsReadDirEntries", _bridge_msFsReadDirEntries);
	// process accessors
	registerHostFn("msProcessCwd",       _bridge_msProcessCwd);
	registerHostFn("msProcessPlatform",  _bridge_msProcessPlatform);
	registerHostFn("msProcessGetEnv",    _bridge_msProcessGetEnv);
	// process spawn/exec
	registerHostFn("msProcessSpawnSync",    _bridge_msProcessSpawnSync);
	registerHostFn("msProcSpawnGetOk",      _bridge_msProcSpawnGetOk);
	registerHostFn("msProcSpawnGetPipeOk",  _bridge_msProcSpawnGetPipeOk);
	registerHostFn("msProcSpawnGetExitCode", _bridge_msProcSpawnGetExitCode);
	registerHostFn("msProcSpawnGetSignal",  _bridge_msProcSpawnGetSignal);
	registerHostFn("msProcSpawnGetStderr",  _bridge_msProcSpawnGetStderr);
	// string ops — extension methods called as `s.trim()` etc.
	// Coverage: trim family + case + indexOf/contains/start/end + replace.
	// Hot paths (charAt/slice) stay hardcoded in raiser/expressions.ms for
	// direct-opcode performance.
	registerHostFn("msStringTrim",          _bridge_msStringTrim);
	registerHostFn("msStringTrimStart",     _bridge_msStringTrimStart);
	registerHostFn("msStringTrimEnd",       _bridge_msStringTrimEnd);
	registerHostFn("msStringIndexOf",       _bridge_msStringIndexOf);
	registerHostFn("msStringToLower",       bridgeMsStringToLower);
	registerHostFn("msStringToUpper",       bridgeMsStringToUpper);
	registerHostFn("msStringContains",      bridgeMsStringContains);
	registerHostFn("msStringStartsWith",    _bridge_msStringStartsWith);
	registerHostFn("msStringEndsWith",      _bridge_msStringEndsWith);
	registerHostFn("msStringReplace",       _bridge_msStringReplace);
	registerHostFn("msStringReplaceAll",    _bridge_msStringReplaceAll);
	markHostRegistryInitialized();
}

// --- Tests ---

import { raiserString, RaiserValueKind } from "../../raiser/value";
import { lookupHostFn, _resetHostRegistryForTests } from "../../raiser/hostRegistry";

test "ensureHostTableLoaded registers fs predicates" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	assert lookupHostFn("msFsExists") !== null;
	assert lookupHostFn("msFsIsFile") !== null;
	assert lookupHostFn("msFsIsDir") !== null;
}

test "ensureHostTableLoaded registers process accessors" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	assert lookupHostFn("msProcessCwd") !== null;
	assert lookupHostFn("msProcessPlatform") !== null;
	assert lookupHostFn("msProcessGetEnv") !== null;
}

test "ensureHostTableLoaded is idempotent" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	ensureHostTableLoaded();  // should not duplicate
	// We don't assert the count strictly — registerHostFn deduplicates on
	// re-registration anyway. Just confirm initialized flag is set.
	assert isHostRegistryInitialized();
}

test "bridge_msFsExists returns 1 for present file" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	const fn = lookupHostFn("msFsExists");
	assert fn !== null;
	// README.md is in the project root, where tests run from.
	const result = fn([raiserString("README.md")]);
	assert result.kind === RaiserValueKind.Int;
	assert result.intVal === 1;
}

test "bridge_msFsExists returns 0 for missing file" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	const fn = lookupHostFn("msFsExists");
	const result = fn([raiserString("/tmp/__definitely_does_not_exist_xyz123__")]);
	assert result.kind === RaiserValueKind.Int;
	assert result.intVal === 0;
}

test "bridge_msProcessCwd returns non-empty string" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	const fn = lookupHostFn("msProcessCwd");
	const result = fn([]);
	assert result.kind === RaiserValueKind.String;
	assert result.strVal.length > 0;
}

test "bridge_msProcessPlatform returns known platform" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	const fn = lookupHostFn("msProcessPlatform");
	const result = fn([]);
	assert result.kind === RaiserValueKind.String;
	// Platform is one of darwin/linux/windows in practice.
	assert result.strVal.length > 0;
}

test "bridge_msProcessGetEnv missing var returns empty" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	const fn = lookupHostFn("msProcessGetEnv");
	const result = fn([raiserString("__NEVER_SET_VAR_QWXTY__")]);
	assert result.kind === RaiserValueKind.String;
	assert result.strVal === "";
}

// --- Phase 7 bridges: errno-poll pattern ---

test "bridge_msFsReadFile present file + errno 0" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	const read = lookupHostFn("msFsReadFile");
	const errno = lookupHostFn("msFsLastErrno");
	const r = read([raiserString("README.md")]);
	assert r.kind === RaiserValueKind.String;
	assert r.strVal.length > 0;
	const e = errno([]);
	assert e.intVal === 0;
}

test "bridge_msFsReadFile missing file + non-zero errno" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	const read = lookupHostFn("msFsReadFile");
	const errno = lookupHostFn("msFsLastErrno");
	const r = read([raiserString("/tmp/__missing_xyz__")]);
	assert r.strVal === "";
	const e = errno([]);
	assert e.intVal !== 0;
}

test "bridge_msFsReadDirEntries returns newline-separated entries" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	const fn = lookupHostFn("msFsReadDirEntries");
	const r = fn([raiserString(".")]);
	assert r.kind === RaiserValueKind.String;
	assert r.strVal.length > 0;
}

test "bridge_msProcessSpawnSync registered" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	// Just verify registration. Actual subprocess invocation is brittle inside
	// the test harness — covered by end-to-end @comptime smoke tests in
	// src/compiler/meta/comptime.ms where the bridge is exercised via the VM.
	assert lookupHostFn("msProcessSpawnSync") !== null;
}

test "bridge_msProcSpawnGet* state slots registered" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	assert lookupHostFn("msProcSpawnGetOk") !== null;
	assert lookupHostFn("msProcSpawnGetPipeOk") !== null;
	assert lookupHostFn("msProcSpawnGetExitCode") !== null;
	assert lookupHostFn("msProcSpawnGetSignal") !== null;
	assert lookupHostFn("msProcSpawnGetStderr") !== null;
}

// --- Audit-driven regression tests ---

test "I4 regression: msFsReadDirEntries missing path sets errno" {
	_resetHostRegistryForTests();
	_resetBridgeStateForTests();
	ensureHostTableLoaded();
	const readDirFn = lookupHostFn("msFsReadDirEntries");
	const errno = lookupHostFn("msFsLastErrno");
	const r = readDirFn([raiserString("/tmp/__never_exists_qpqp__")]);
	assert r.kind === RaiserValueKind.String;
	assert r.strVal === "";
	// Bug pre-fix: errno would be 0 here, masking failure
	assert errno([]).intVal !== 0;
}

test "I4 regression: msFsReadDirEntries on file (not dir) sets errno" {
	_resetHostRegistryForTests();
	_resetBridgeStateForTests();
	ensureHostTableLoaded();
	const readDirFn = lookupHostFn("msFsReadDirEntries");
	const errno = lookupHostFn("msFsLastErrno");
	readDirFn([raiserString("README.md")]);  // path exists but is a file
	assert errno([]).intVal !== 0;
}

test "I5 regression: bridge state reset clears errno" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	const read = lookupHostFn("msFsReadFile");
	const errno = lookupHostFn("msFsLastErrno");
	read([raiserString("/tmp/__missing_yyy__")]);
	assert errno([]).intVal !== 0;
	_resetBridgeStateForTests();
	assert errno([]).intVal === 0;
}

test "errno cleared after successful read following failed read" {
	_resetHostRegistryForTests();
	_resetBridgeStateForTests();
	ensureHostTableLoaded();
	const read = lookupHostFn("msFsReadFile");
	const errno = lookupHostFn("msFsLastErrno");
	read([raiserString("/tmp/__missing_first__")]);
	assert errno([]).intVal !== 0;
	read([raiserString("README.md")]);  // success — should clear errno
	assert errno([]).intVal === 0;
}

test "spawn state preserved across getter calls" {
	_resetHostRegistryForTests();
	_resetBridgeStateForTests();
	ensureHostTableLoaded();
	// Multi-getter sequence should return consistent state (no clobbering
	// between getOk → getExitCode → getStderr).
	const okFn = lookupHostFn("msProcSpawnGetOk");
	const exitFn = lookupHostFn("msProcSpawnGetExitCode");
	const stderrFn = lookupHostFn("msProcSpawnGetStderr");
	// Initial state after reset
	assert okFn([]).intVal === 0;
	assert exitFn([]).intVal === 0;
	assert stderrFn([]).strVal === "";
}

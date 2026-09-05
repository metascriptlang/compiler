// Raiser VM — Host function table (seed)
//
// Registers wrappers for the std/* native externs Raiser can call from
// bytecode via the `CallHost` opcode. Each wrapper unboxes RaiserValue
// arguments, calls the underlying MS-level std function (which dispatches
// to a host shim during bootstrap, or to a C native after self-host), and
// boxes the return.
//
// Most bridges return SCALAR types only (string / int / float / bool-as-int).
// Result<T,E>, arrays, and objects are constructed inside Raiser bytecode by
// the calling MS code (via NewObject/StoreField opcodes after Phase 3 lowers
// `Result.ok(x)` to `{ok: true, value: x}`), so those bridges never need heap
// access. The one exception is the Node child accessors (msNodeChildCount/At),
// which dereference Object/Array handles through the active-VM heaps that
// vmHandleCallHost publishes via setActiveHostHeaps.
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
// in std/* must be paired with a `_bridgeMsXxx` here. A small compiler-build
// tool (~1 day of work) would:
//   1. Walk the symbol table after the std/* check pass.
//   2. Filter symbols with `nativeName != ""` (extern decls).
//   3. Derive a bridge signature from the MS type (e.g. `(string) → string`).
//   4. Generate the bridge source + the `registerHostFn` call.
//   5. Emit into a generated file (e.g. `_generated/hostTable.gen.ms`).
// Until then, additions need 2 lines per native: one bridge function + one
// `registerHostFn` line. The cost is bounded — ~20 bridges cover the fs +
// process surface that @comptime actually uses today.

import {
	RaiserValue, RaiserValueKind, RaiserObjectHeap, RaiserArrayHeap, raiserNil,
	heapObjectFieldCount, heapObjectFieldNameAt, heapObjectFieldValueAt, heapObjectGetField,
	heapArrayLen, heapArrayGet, heapAllocArray, heapArrayPush, raiserArray,
} from "../../raiser/value";
import {
	registerHostFn, markHostRegistryInitialized, isHostRegistryInitialized,
	activeHostObjectHeap, activeHostArrayHeap,
} from "../../raiser/hostRegistry";
import {
	unboxString, unboxInt, unboxFloat, unboxBool,
	boxString, boxInt, boxFloat, boxBool,
} from "../../raiser/marshal";
import { isNodeWireMetaField } from "./wire";

import {
	exists, isFile, isDir, isExecutable, fileSize,
	readFile, writeFile, appendFile, chmod,
	mkdir, rmdir, remove, rename, readDir,
} from "std/fs";
import { cwd, platform, env, exec, argv, execFile, execFileCapture } from "std/process";
import { readLine, readBytes, writeStdout, writeStderr, stdinHasData, stdinDisableBuffering } from "std/io";
import { performance } from "std/core/performance";
import { resolveRuntimeDir } from "../../utils/path";
import { join } from "std/fs/path";
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

// Helper: convert Result<void, IoError> into the rv+errno contract used by the
// C runtime's mutating fs functions. The C ABI is **1 = ok, 0 = failure** with
// errno populated (runtime/fs/posix.c, runtime/fs/windows.c: every mutating
// entry returns 1.0 on success), and the MS wrappers test for exactly that
// (`if (msFsMkdir(path) === 1)`, std/fs/index.cms). Shared by
// mkdir/rmdir/remove/rename/chmod/writeFileMode.
// `errKind` is only consulted when `ok` is false — pass IoErrorKind.NotFound
// as a placeholder on the success path.
function _fsResultToInt(ok: boolean, errKind: IoErrorKind): RaiserValue {
	if (ok) { _lastFsErrno = 0; return boxInt(1); }
	_setFsErrno(errKind);
	return boxInt(0);
}

// --- File system bridges ---

function _bridgeMsFsExists(args: RaiserValue[]): RaiserValue {
	return boxInt(exists(unboxString(args[0])) ? 1 : 0);
}

function _bridgeMsFsIsFile(args: RaiserValue[]): RaiserValue {
	return boxInt(isFile(unboxString(args[0])) ? 1 : 0);
}

function _bridgeMsFsIsDir(args: RaiserValue[]): RaiserValue {
	return boxInt(isDir(unboxString(args[0])) ? 1 : 0);
}

function _bridgeMsFsIsExecutable(args: RaiserValue[]): RaiserValue {
	return boxInt(isExecutable(unboxString(args[0])) ? 1 : 0);
}

function _bridgeMsFsFileSize(args: RaiserValue[]): RaiserValue {
	return boxInt(fileSize(unboxString(args[0])));
}

function _bridgeMsFsChmod(args: RaiserValue[]): RaiserValue {
	const r = chmod(unboxString(args[0]), unboxInt(args[1]) as int32);
	return _fsResultToInt(r.ok, r.ok ? IoErrorKind.NotFound : r.error.kind);
}

function _bridgeMsFsReadFile(args: RaiserValue[]): RaiserValue {
	const r = readFile(unboxString(args[0]));
	if (r.ok) {
		_lastFsErrno = 0;
		return boxString(r.value);
	}
	_setFsErrno(r.error.kind);
	return boxString("");
}

function _bridgeMsFsLastErrno(args: RaiserValue[]): RaiserValue {
	return boxInt(_lastFsErrno);
}

function _bridgeMsFsWriteFileMode(args: RaiserValue[]): RaiserValue {
	// args[2] = the fopen mode the C native would use ("wb" overwrite,
	// "ab" append — std/fs writeFile/appendFile pass exactly those). Honor it:
	// ignoring the mode made appendFile silently TRUNCATE inside the VM.
	const path = unboxString(args[0]);
	const content = unboxString(args[1]);
	const mode = args.length > 2 ? unboxString(args[2]) : "wb";
	const r = mode.startsWith("a")
		? appendFile(path, content)
		: writeFile(path, content);
	return _fsResultToInt(r.ok, r.ok ? IoErrorKind.NotFound : r.error.kind);
}

function _bridgeMsFsMkdir(args: RaiserValue[]): RaiserValue {
	const r = mkdir(unboxString(args[0]));
	return _fsResultToInt(r.ok, r.ok ? IoErrorKind.NotFound : r.error.kind);
}

function _bridgeMsFsRmdir(args: RaiserValue[]): RaiserValue {
	const r = rmdir(unboxString(args[0]));
	return _fsResultToInt(r.ok, r.ok ? IoErrorKind.NotFound : r.error.kind);
}

function _bridgeMsFsRemove(args: RaiserValue[]): RaiserValue {
	const r = remove(unboxString(args[0]));
	return _fsResultToInt(r.ok, r.ok ? IoErrorKind.NotFound : r.error.kind);
}

function _bridgeMsFsRename(args: RaiserValue[]): RaiserValue {
	const r = rename(unboxString(args[0]), unboxString(args[1]));
	return _fsResultToInt(r.ok, r.ok ? IoErrorKind.NotFound : r.error.kind);
}

function _bridgeMsFsReadDirEntries(args: RaiserValue[]): RaiserValue {
	// C contract: returns lines separated by "\n", empty on error
	// (caller polls errno). MS readDir returns string[]; join with "\n".
	// readDir returns [] silently on failure — pre-check via
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

function _bridgeMsProcessCwd(args: RaiserValue[]): RaiserValue {
	return boxString(cwd());
}

function _bridgeMsProcessPlatform(args: RaiserValue[]): RaiserValue {
	return boxString(platform);
}

function _bridgeMsProcessGetEnv(args: RaiserValue[]): RaiserValue {
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

function _bridgeMsProcessSpawnSync(args: RaiserValue[]): RaiserValue {
	const r = exec(unboxString(args[0]));
	if (r.ok) {
		_resetSpawnStateOk(r.value);
	} else {
		const e = r.error;
		_setSpawnStateErr(e.kind, e.output, e.errorOutput, e.exitCode, e.signal);
	}
	return boxString(_spawnStdout);
}

function _bridgeMsProcSpawnGetOk(args: RaiserValue[]): RaiserValue {
	return boxInt(_spawnOk);
}

function _bridgeMsProcSpawnGetPipeOk(args: RaiserValue[]): RaiserValue {
	return boxInt(_spawnPipeOk);
}

function _bridgeMsProcSpawnGetExitCode(args: RaiserValue[]): RaiserValue {
	return boxInt(_spawnExitCode);
}

function _bridgeMsProcSpawnGetSignal(args: RaiserValue[]): RaiserValue {
	return boxInt(_spawnSignal);
}

function _bridgeMsProcSpawnGetStderr(args: RaiserValue[]): RaiserValue {
	return boxString(_spawnStderr);
}

// --- Process bridges (Nim vmops parity: envvars get/exists/put/del all
// registered; osproc.execCmdEx registered behind the danger flag; quit is
// deliberately NOT an op in Nim's VM — exit is handled at the codegen tier
// here, see the Halt intercept) ---

function _bridgeMsProcessArgv(args: RaiserValue[]): RaiserValue {
	const heapOrNull = activeHostArrayHeap();
	if (heapOrNull === null) return raiserNil();
	const heap: RaiserArrayHeap = heapOrNull;
	const h = heapAllocArray(heap);
	for (const a of argv) {
		heapArrayPush(heap, h, boxString(a));
	}
	return raiserArray(h);
}

function _bridgeMsProcessSetEnv(args: RaiserValue[]): RaiserValue {
	return boxInt(env.set(unboxString(args[0]), unboxString(args[1])) ? 1 : 0);
}

function _bridgeMsProcessUnsetEnv(args: RaiserValue[]): RaiserValue {
	return boxInt(env.delete(unboxString(args[0])) ? 1 : 0);
}

function _unboxStringArrayArg(v: RaiserValue): string[] {
	const out: string[] = [];
	if (v.kind !== RaiserValueKind.Array) return out;
	const heapOrNull = activeHostArrayHeap();
	if (heapOrNull === null) return out;
	const heap: RaiserArrayHeap = heapOrNull;
	const n = heapArrayLen(heap, v.intVal);
	let i = 0;
	while (i < n) {
		out.push(unboxString(heapArrayGet(heap, v.intVal, i)));
		i = i + 1;
	}
	return out;
}

function _bridgeMsProcessExecFile(args: RaiserValue[]): RaiserValue {
	const r = execFile(unboxString(args[0]), _unboxStringArrayArg(args[1]));
	return boxInt(r);
}

function _bridgeMsProcessSpawnSyncArgv(args: RaiserValue[]): RaiserValue {
	const r = execFileCapture(unboxString(args[0]), _unboxStringArrayArg(args[1]));
	if (r.ok) {
		_resetSpawnStateOk(r.value);
	} else {
		const e = r.error;
		_setSpawnStateErr(e.kind, e.output, e.errorOutput, e.exitCode, e.signal);
	}
	return boxString(_spawnStdout);
}


// --- std/io bridges (standard streams) ---
// Same static-inline shims the C tier links from runtime/io/streams.h,
// reached through msc's own std/io import — writeStdout/Stderr flush
// immediately (LSP framing), readLine strips \r\n, caps 4 KiB.

function _bridgeMsReadLine(args: RaiserValue[]): RaiserValue {
	return boxString(readLine());
}

function _bridgeMsReadBytes(args: RaiserValue[]): RaiserValue {
	return boxString(readBytes(unboxFloat(args[0])));
}

function _bridgeMsStdinHasData(args: RaiserValue[]): RaiserValue {
	return boxInt(stdinHasData() ? 1 : 0);
}

function _bridgeMsWriteStdout(args: RaiserValue[]): RaiserValue {
	writeStdout(unboxString(args[0]));
	return raiserNil();
}

function _bridgeMsWriteStderr(args: RaiserValue[]): RaiserValue {
	writeStderr(unboxString(args[0]));
	return raiserNil();
}

function _bridgeMsStdinDisableBuffering(args: RaiserValue[]): RaiserValue {
	stdinDisableBuffering();
	return raiserNil();
}

// --- std/compress/zip bridges ---
// Raw miniz kernels from runtime/compress/zip.c — the same TU set zip.cms
// @compiles into this binary via the package-manager import chain. Handles
// are int64 tokens; all Result/object construction lives in the .rms tier.
// The externs bind TUs that only the package-manager chain @compiles in —
// a test build whose closure lacks that chain (fixedbugs via test/helpers)
// would fail to link them, so the whole bridge tier is compiled out of
// test binaries (same pattern as the CLI entry's `when (!testBuild)`).

@include("runtime/compress/zip.h");

when (!testBuild) {

extern function msZipReaderOpen(data: string): int64;
extern function msZipReaderCount(handle: int64): int32;
extern function msZipReaderEntryName(handle: int64, index: int32): string;
extern function msZipReaderEntrySize(handle: int64, index: int32): int64;
extern function msZipReaderEntryIsDir(handle: int64, index: int32): int32;
extern function msZipReaderExtract(handle: int64, index: int32): string;
extern function msZipReaderClose(handle: int64): void;
extern function msZipWriterNew(): int64;
extern function msZipWriterAdd(handle: int64, name: string, data: string, level: int32): int32;
extern function msZipWriterFinalize(handle: int64): string;
extern function msZipWriterClose(handle: int64): void;

function _bridgeMsZipReaderOpen(args: RaiserValue[]): RaiserValue {
	return boxInt(msZipReaderOpen(unboxString(args[0])));
}

function _bridgeMsZipReaderCount(args: RaiserValue[]): RaiserValue {
	return boxInt(msZipReaderCount(unboxInt(args[0]) as int64));
}

function _bridgeMsZipReaderEntryName(args: RaiserValue[]): RaiserValue {
	return boxString(msZipReaderEntryName(unboxInt(args[0]) as int64, unboxInt(args[1]) as int32));
}

function _bridgeMsZipReaderEntrySize(args: RaiserValue[]): RaiserValue {
	return boxInt(msZipReaderEntrySize(unboxInt(args[0]) as int64, unboxInt(args[1]) as int32));
}

function _bridgeMsZipReaderEntryIsDir(args: RaiserValue[]): RaiserValue {
	return boxInt(msZipReaderEntryIsDir(unboxInt(args[0]) as int64, unboxInt(args[1]) as int32));
}

function _bridgeMsZipReaderExtract(args: RaiserValue[]): RaiserValue {
	return boxString(msZipReaderExtract(unboxInt(args[0]) as int64, unboxInt(args[1]) as int32));
}

function _bridgeMsZipReaderClose(args: RaiserValue[]): RaiserValue {
	msZipReaderClose(unboxInt(args[0]) as int64);
	return raiserNil();
}

function _bridgeMsZipWriterNew(args: RaiserValue[]): RaiserValue {
	return boxInt(msZipWriterNew());
}

function _bridgeMsZipWriterAdd(args: RaiserValue[]): RaiserValue {
	return boxInt(msZipWriterAdd(unboxInt(args[0]) as int64, unboxString(args[1]), unboxString(args[2]), unboxInt(args[3]) as int32));
}

function _bridgeMsZipWriterFinalize(args: RaiserValue[]): RaiserValue {
	return boxString(msZipWriterFinalize(unboxInt(args[0]) as int64));
}

function _bridgeMsZipWriterClose(args: RaiserValue[]): RaiserValue {
	msZipWriterClose(unboxInt(args[0]) as int64);
	return raiserNil();
}

}

// --- std/crypto bridges (hash family) ---
// runtime/crypto/hash.c + the mbedtls hash TUs are already compiled into
// this binary through the package-manager import chain (download.ms).
// Same test-build compile-out as the zip bridges above.

@include("runtime/crypto/hash.h");

when (!testBuild) {

extern function msCryptoInit(): boolean;
extern function msCryptoCleanup(): void;
extern function msCryptoHashString(algorithm: string, data: string, encoding: string): string;

function _bridgeMsCryptoInit(args: RaiserValue[]): RaiserValue {
	return boxBool(msCryptoInit());
}

function _bridgeMsCryptoCleanup(args: RaiserValue[]): RaiserValue {
	msCryptoCleanup();
	return raiserNil();
}

function _bridgeMsCryptoHashString(args: RaiserValue[]): RaiserValue {
	return boxString(msCryptoHashString(unboxString(args[0]), unboxString(args[1]), unboxString(args[2])));
}

}

// --- Macro Node child accessors ---
// childCount/childAt (std/meta) traverse a Node's children BY INDEX on the
// macro VM's flat wire (the Nim n[i]/n.len analog), so a top-level helper
// shared between macros can walk nodes without engine-mode flat-field reads.
// A child slot is any Object field carrying a numeric "kind" (a Node), or
// each such element of an Array field (recursively, so Node[][] fields like
// typExprFieldDecorators are reachable), in field-insertion order — the order
// addKindFields (compiler/meta/expand.ms) wrote them. Metadata fields are
// never children; resolvedSym and nodeType ARE node-shaped, so telling them
// apart rests on isNodeWireMetaField (wire.ms) — the one list the wire
// writer and this reader share. childAt returns the live heap ref, not a
// copy — mutations through it stick.

function _isNodeShaped(objHeap: RaiserObjectHeap, v: RaiserValue): boolean {
	if (v.kind !== RaiserValueKind.Object) return false;
	const kindField = heapObjectGetField(objHeap, v.intVal, "kind");
	return kindField.kind === RaiserValueKind.Int || kindField.kind === RaiserValueKind.Float;
}

function _pushNodeShapedElems(objHeap: RaiserObjectHeap, arrHeap: RaiserArrayHeap, arrHandle: number, out: RaiserValue[]): void {
	const len = heapArrayLen(arrHeap, arrHandle);
	for (let j = 0; j < len; j = j + 1) {
		const el = heapArrayGet(arrHeap, arrHandle, j);
		if (_isNodeShaped(objHeap, el)) {
			out.push(el);
		} else if (el.kind === RaiserValueKind.Array) {
			_pushNodeShapedElems(objHeap, arrHeap, el.intVal, out);
		}
	}
}

function _nodeChildSlots(h: number): RaiserValue[] {
	const out: RaiserValue[] = [];
	const objHeapOrNull = activeHostObjectHeap();
	const arrHeapOrNull = activeHostArrayHeap();
	if (objHeapOrNull === null || arrHeapOrNull === null) return out;
	const objHeap: RaiserObjectHeap = objHeapOrNull;
	const arrHeap: RaiserArrayHeap = arrHeapOrNull;
	const n = heapObjectFieldCount(objHeap, h);
	for (let i = 0; i < n; i = i + 1) {
		const name = heapObjectFieldNameAt(objHeap, h, i);
		if (isNodeWireMetaField(name)) continue;
		const v = heapObjectFieldValueAt(objHeap, h, i);
		if (_isNodeShaped(objHeap, v)) {
			out.push(v);
		} else if (v.kind === RaiserValueKind.Array) {
			_pushNodeShapedElems(objHeap, arrHeap, v.intVal, out);
		}
	}
	return out;
}

function _bridgeMsNodeChildCount(args: RaiserValue[]): RaiserValue {
	if (args.length < 1 || args[0].kind !== RaiserValueKind.Object) return boxInt(0);
	return boxInt(_nodeChildSlots(args[0].intVal).length);
}

function _bridgeMsNodeChildAt(args: RaiserValue[]): RaiserValue {
	if (args.length < 2 || args[0].kind !== RaiserValueKind.Object) return raiserNil();
	const slots = _nodeChildSlots(args[0].intVal);
	const i = unboxInt(args[1]);
	if (i < 0 || i >= slots.length) return raiserNil();
	return slots[i];
}

// --- String bridges ---
// Bridges exist so `@comptime` code calling `s.trim()` etc. can
// dispatch through the CallHost path without falling into "Unknown host
// function" silent-nil. Full catalogue: docs/RAISER-GAP.md Phase 4.

function _bridgeMsStringTrim(args: RaiserValue[]): RaiserValue {
	return boxString(unboxString(args[0]).trim());
}

function _bridgeMsStringTrimStart(args: RaiserValue[]): RaiserValue {
	return boxString(unboxString(args[0]).trimStart());
}

function _bridgeMsStringTrimEnd(args: RaiserValue[]): RaiserValue {
	return boxString(unboxString(args[0]).trimEnd());
}

// indexOf: MS declares (s, sub, start: int64 = 0) — handle optional 3rd arg
function _bridgeMsStringIndexOf(args: RaiserValue[]): RaiserValue {
	const start = args.length > 2 ? args[2].intVal : 0;
	return boxInt(unboxString(args[0]).indexOf(unboxString(args[1]), start));
}

function _bridgeMsStringCharCodeAt(args: RaiserValue[]): RaiserValue {
	return boxInt(unboxString(args[0]).charCodeAt(unboxInt(args[1])));
}

// Tier 1 — string ↔ VM-heap byte-array kernels. These cross the VM-heap
// boundary (host zero-copy view vs VM heap array), which MS cannot express
// from either side; every derived string algorithm is Tier 2
// (std/core/string/shared.ms). The only bridges that CREATE a VM heap value.
function _bridgeMsAsBytes(args: RaiserValue[]): RaiserValue {
	const bytes = unboxString(args[0]).asBytes();
	const heapOrNull = activeHostArrayHeap();
	if (heapOrNull === null) return raiserNil();
	const heap: RaiserArrayHeap = heapOrNull;
	const handle = heapAllocArray(heap);
	let i = 0;
	while (i < bytes.length) {
		heapArrayPush(heap, handle, boxInt(bytes[i]));
		i = i + 1;
	}
	return raiserArray(handle);
}

function _bridgeMsAsString(args: RaiserValue[]): RaiserValue {
	const heapOrNull = activeHostArrayHeap();
	if (heapOrNull === null) return raiserNil();
	const heap: RaiserArrayHeap = heapOrNull;
	const handle = args[0].intVal;
	const len = heapArrayLen(heap, handle);
	const bytes: uint8[] = [];
	let i = 0;
	while (i < len) {
		bytes.push(heapArrayGet(heap, handle, i).intVal as uint8);
		i = i + 1;
	}
	return boxString(bytes.asString());
}

// split: the std extension is pure MetaScript (std/core/string/shared.ms) and
// macros cannot import std, so the raiser dispatches here. The array lands in
// the active array heap; macro code reads it with .length/[i] as any array.
function _bridgeMsStringSplit(args: RaiserValue[]): RaiserValue {
	const parts = unboxString(args[0]).split(unboxString(args[1]));
	const arrHeapOrNull = activeHostArrayHeap();
	if (arrHeapOrNull === null) return raiserNil();
	const arrHeap: RaiserArrayHeap = arrHeapOrNull;
	const h = heapAllocArray(arrHeap);
	for (let i = 0; i < parts.length; i = i + 1) {
		heapArrayPush(arrHeap, h, boxString(parts[i]));
	}
	return raiserArray(h);
}

// Prelude globals. String<T> is the generic conversion on C/JS; here it
// dispatches on the dynamic value kind. Int/Float go through the number
// tier's toString — exact for integers up to 2^53 (JS parity), approximate
// beyond, which no caller in the compiler's messages relies on.
function _bridgeMsStringFromValue(args: RaiserValue[]): RaiserValue {
	const v = args[0];
	if (v.kind === RaiserValueKind.String) return v;
	if (v.kind === RaiserValueKind.Int) return boxString(unboxInt(v).toString());
	if (v.kind === RaiserValueKind.Float) return boxString(unboxFloat(v).toString());
	if (v.kind === RaiserValueKind.Bool) return boxString(unboxBool(v) ? "true" : "false");
	return boxString("");
}

function _bridgeMsPerformanceNow(args: RaiserValue[]): RaiserValue {
	return boxFloat(performance.now());
}

// Literal value accessors. Each one FIXES the representation of its result the
// way Nim's opcNIntVal/opcNFloatVal do (vm.nim:1867-1881, decodeB(rkInt/rkFloat)):
// the VM's arithmetic and compare opcodes are typed (AddI64 vs AddF64, BltI64 vs
// BltF64) and the Raiser picks them from the STATIC type of the expression, so a
// single accessor declared `: number` that returned Int for one literal and Float
// for another would have its operands read through the wrong opcode — measured as
// a value that prints "8" and then compares as 0. One static type, one register
// kind; ask isFloatLiteral first, exactly as Nim asks the node kind.
function _bridgeMsNodeIsFloatLiteral(args: RaiserValue[]): RaiserValue {
	if (args.length < 1 || args[0].kind !== RaiserValueKind.Object) return boxBool(false);
	const objHeapOrNull = activeHostObjectHeap();
	if (objHeapOrNull === null) return boxBool(false);
	const objHeap: RaiserObjectHeap = objHeapOrNull;
	const v = heapObjectGetField(objHeap, args[0].intVal, "value");
	return boxBool(v.kind === RaiserValueKind.Float);
}

function _bridgeMsNodeIntValue(args: RaiserValue[]): RaiserValue {
	if (args.length < 1 || args[0].kind !== RaiserValueKind.Object) return boxInt(0);
	const objHeapOrNull = activeHostObjectHeap();
	if (objHeapOrNull === null) return boxInt(0);
	const objHeap: RaiserObjectHeap = objHeapOrNull;
	return boxInt(unboxInt(heapObjectGetField(objHeap, args[0].intVal, "value")));
}

function _bridgeMsNodeFloatValue(args: RaiserValue[]): RaiserValue {
	if (args.length < 1 || args[0].kind !== RaiserValueKind.Object) return boxFloat(0.0);
	const objHeapOrNull = activeHostObjectHeap();
	if (objHeapOrNull === null) return boxFloat(0.0);
	const objHeap: RaiserObjectHeap = objHeapOrNull;
	return boxFloat(unboxInt(heapObjectGetField(objHeap, args[0].intVal, "value")));
}

function _bridgeMsNodeStringValue(args: RaiserValue[]): RaiserValue {
	if (args.length < 1 || args[0].kind !== RaiserValueKind.Object) return boxString("");
	const objHeapOrNull = activeHostObjectHeap();
	if (objHeapOrNull === null) return boxString("");
	const objHeap: RaiserObjectHeap = objHeapOrNull;
	return boxString(unboxString(heapObjectGetField(objHeap, args[0].intVal, "value")));
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

function _bridgeMsStringStartsWith(args: RaiserValue[]): RaiserValue {
	return boxInt(unboxString(args[0]).startsWith(unboxString(args[1])) ? 1 : 0);
}

function _bridgeMsStringEndsWith(args: RaiserValue[]): RaiserValue {
	return boxInt(unboxString(args[0]).endsWith(unboxString(args[1])) ? 1 : 0);
}

function _bridgeMsStringReplace(args: RaiserValue[]): RaiserValue {
	return boxString(unboxString(args[0]).replace(unboxString(args[1]), unboxString(args[2])));
}

function _bridgeMsStringReplaceAll(args: RaiserValue[]): RaiserValue {
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
	registerHostFn("msFsExists",         _bridgeMsFsExists);
	registerHostFn("msFsIsFile",         _bridgeMsFsIsFile);
	registerHostFn("msFsIsDir",          _bridgeMsFsIsDir);
	registerHostFn("msFsIsExecutable",   _bridgeMsFsIsExecutable);
	registerHostFn("msFsFileSize",       _bridgeMsFsFileSize);
	// fs read/write/mutate + errno polling
	registerHostFn("msFsReadFile",       _bridgeMsFsReadFile);
	registerHostFn("msFsLastErrno",      _bridgeMsFsLastErrno);
	registerHostFn("msFsWriteFileMode",  _bridgeMsFsWriteFileMode);
	registerHostFn("msFsChmod",          _bridgeMsFsChmod);
	registerHostFn("msFsMkdir",          _bridgeMsFsMkdir);
	registerHostFn("msFsRmdir",          _bridgeMsFsRmdir);
	registerHostFn("msFsRemove",         _bridgeMsFsRemove);
	registerHostFn("msFsRename",         _bridgeMsFsRename);
	registerHostFn("msFsReadDirEntries", _bridgeMsFsReadDirEntries);
	// process accessors
	registerHostFn("msProcessCwd",       _bridgeMsProcessCwd);
	registerHostFn("msProcessPlatform",  _bridgeMsProcessPlatform);
	registerHostFn("msProcessGetEnv",    _bridgeMsProcessGetEnv);
	// process spawn/exec
	registerHostFn("msProcessSpawnSync",    _bridgeMsProcessSpawnSync);
	registerHostFn("msProcSpawnGetOk",      _bridgeMsProcSpawnGetOk);
	registerHostFn("msProcSpawnGetPipeOk",  _bridgeMsProcSpawnGetPipeOk);
	registerHostFn("msProcSpawnGetExitCode", _bridgeMsProcSpawnGetExitCode);
	registerHostFn("msProcSpawnGetSignal",  _bridgeMsProcSpawnGetSignal);
	registerHostFn("msProcSpawnGetStderr",  _bridgeMsProcSpawnGetStderr);
	// macro Node child accessors (std/meta childCount/childAt)
	registerHostFn("msNodeChildCount",      _bridgeMsNodeChildCount);
	registerHostFn("msNodeChildAt",         _bridgeMsNodeChildAt);
	// string ops — extension methods called as `s.trim()` etc.
	// Coverage: trim family + case + indexOf/contains/start/end + replace.
	// Hot paths (charAt/slice) stay hardcoded in raiser/expressions.ms for
	// direct-opcode performance.
	registerHostFn("msStringTrim",          _bridgeMsStringTrim);
	registerHostFn("msStringTrimStart",     _bridgeMsStringTrimStart);
	registerHostFn("msStringTrimEnd",       _bridgeMsStringTrimEnd);
	registerHostFn("msStringIndexOf",       _bridgeMsStringIndexOf);
	registerHostFn("msStringCharCodeAt",    _bridgeMsStringCharCodeAt);
	registerHostFn("msStringFromValue",     _bridgeMsStringFromValue);
	registerHostFn("msPerformanceNow",      _bridgeMsPerformanceNow);
	registerHostFn("msProcessArgv",         _bridgeMsProcessArgv);
	registerHostFn("msProcessSetEnv",       _bridgeMsProcessSetEnv);
	registerHostFn("msProcessUnsetEnv",     _bridgeMsProcessUnsetEnv);
	registerHostFn("msProcessExecFile",     _bridgeMsProcessExecFile);
	registerHostFn("msProcessSpawnSyncArgv", _bridgeMsProcessSpawnSyncArgv);
	registerHostFn("msStdinDisableBuffering", _bridgeMsStdinDisableBuffering);
	registerHostFn("msReadLine",            _bridgeMsReadLine);
	registerHostFn("msReadBytes",           _bridgeMsReadBytes);
	registerHostFn("msStdinHasData",        _bridgeMsStdinHasData);
	registerHostFn("msWriteStdout",        _bridgeMsWriteStdout);
	registerHostFn("msWriteStderr",        _bridgeMsWriteStderr);
	when (!testBuild) {
		registerHostFn("msZipReaderOpen",       _bridgeMsZipReaderOpen);
		registerHostFn("msZipReaderCount",      _bridgeMsZipReaderCount);
		registerHostFn("msZipReaderEntryName",  _bridgeMsZipReaderEntryName);
		registerHostFn("msZipReaderEntrySize",  _bridgeMsZipReaderEntrySize);
		registerHostFn("msZipReaderEntryIsDir", _bridgeMsZipReaderEntryIsDir);
		registerHostFn("msZipReaderExtract",    _bridgeMsZipReaderExtract);
		registerHostFn("msZipReaderClose",      _bridgeMsZipReaderClose);
		registerHostFn("msZipWriterNew",        _bridgeMsZipWriterNew);
		registerHostFn("msZipWriterAdd",        _bridgeMsZipWriterAdd);
		registerHostFn("msZipWriterFinalize",   _bridgeMsZipWriterFinalize);
		registerHostFn("msZipWriterClose",      _bridgeMsZipWriterClose);
		registerHostFn("msCryptoInit",          _bridgeMsCryptoInit);
		registerHostFn("msCryptoCleanup",       _bridgeMsCryptoCleanup);
		registerHostFn("msCryptoHashString",    _bridgeMsCryptoHashString);
	}
	registerHostFn("msStringSplit",         _bridgeMsStringSplit);
	registerHostFn("msNodeIsFloatLiteral", _bridgeMsNodeIsFloatLiteral);
	registerHostFn("msNodeIntValue",        _bridgeMsNodeIntValue);
	registerHostFn("msNodeFloatValue",      _bridgeMsNodeFloatValue);
	registerHostFn("msNodeStringValue",     _bridgeMsNodeStringValue);
	registerHostFn("msStringToLower",       bridgeMsStringToLower);
	registerHostFn("msStringToUpper",       bridgeMsStringToUpper);
	registerHostFn("msStringContains",      bridgeMsStringContains);
	registerHostFn("msStringStartsWith",    _bridgeMsStringStartsWith);
	registerHostFn("msStringEndsWith",      _bridgeMsStringEndsWith);
	registerHostFn("msStringReplace",       _bridgeMsStringReplace);
	registerHostFn("msStringReplaceAll",    _bridgeMsStringReplaceAll);
	registerHostFn("msAsBytes",             _bridgeMsAsBytes);
	registerHostFn("msAsString",            _bridgeMsAsString);
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

test "bridgeMsFsExists returns 1 for present file" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	const fn = lookupHostFn("msFsExists");
	assert fn !== null;
	// README.md is in the project root, where tests run from.
	const result = fn([raiserString("README.md")]);
	assert result.kind === RaiserValueKind.Int;
	assert result.intVal === 1;
}

test "bridgeMsFsExists returns 0 for missing file" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	const fn = lookupHostFn("msFsExists");
	const result = fn([raiserString("/tmp/__definitely_does_not_exist_xyz123__")]);
	assert result.kind === RaiserValueKind.Int;
	assert result.intVal === 0;
}

test "bridgeMsProcessCwd returns non-empty string" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	const fn = lookupHostFn("msProcessCwd");
	const result = fn([]);
	assert result.kind === RaiserValueKind.String;
	assert result.strVal.length > 0;
}

test "bridgeMsProcessPlatform returns known platform" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	const fn = lookupHostFn("msProcessPlatform");
	const result = fn([]);
	assert result.kind === RaiserValueKind.String;
	// Platform is one of darwin/linux/windows in practice.
	assert result.strVal.length > 0;
}

test "bridgeMsProcessGetEnv missing var returns empty" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	const fn = lookupHostFn("msProcessGetEnv");
	const result = fn([raiserString("__NEVER_SET_VAR_QWXTY__")]);
	assert result.kind === RaiserValueKind.String;
	assert result.strVal === "";
}

// --- Phase 7 bridges: errno-poll pattern ---

test "bridgeMsFsReadFile present file + errno 0" {
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

test "bridgeMsFsReadFile missing file + non-zero errno" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	const read = lookupHostFn("msFsReadFile");
	const errno = lookupHostFn("msFsLastErrno");
	const r = read([raiserString("/tmp/__missing_xyz__")]);
	assert r.strVal === "";
	const e = errno([]);
	assert e.intVal !== 0;
}

test "bridgeMsFsReadDirEntries returns newline-separated entries" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	const fn = lookupHostFn("msFsReadDirEntries");
	const r = fn([raiserString(".")]);
	assert r.kind === RaiserValueKind.String;
	assert r.strVal.length > 0;
}

test "bridgeMsProcessSpawnSync registered" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	// Just verify registration. Actual subprocess invocation is brittle inside
	// the test harness — covered by end-to-end @comptime smoke tests in
	// src/compiler/meta/comptime.ms where the bridge is exercised via the VM.
	assert lookupHostFn("msProcessSpawnSync") !== null;
}

test "bridgeMsProcSpawnGet* state slots registered" {
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

// --- .rms closure guard ---
// Every extern declared in a std .rms prelude must be executable when a
// macro calls it: a host bridge in this table, an opcode-intercepted name
// that never reaches CallHost, or on the deliberate dead list below (with
// its blocker). Keeps a new extern from going dead silently.

function scanRmsExternNames(src: string): string[] {
	const names: string[] = [];
	const needle = `from "`;
	let i = 0;
	while (i < src.length) {
		const at = src.indexOf(needle, i);
		if (at < 0) break;
		const start = at + needle.length;
		const endQuote = src.indexOf(`"`, start);
		if (endQuote < 0) break;
		const name = src.slice(start, endQuote);
		i = endQuote + 1;
		if (name.indexOf("/") >= 0) continue;  // module specifier (re-export), not an extern
		names.push(name);
	}
	return names;
}

function nameListed(list: string[], name: string): boolean {
	for (const x of list) {
		if (x === name) return true;
	}
	return false;
}

test "rms extern closure: declared externs are bridged, intercepted, or listed dead" {
	const root = resolveRuntimeDir();
	const stdPath = root !== "" ? join(root, "std") : "std";
	const rmsFiles = [
		join(stdPath, "core/string/index.rms"),
		join(stdPath, "core/array/index.rms"),
	];
	// Names the Raiser codegen intercepts to opcodes before CallHost.
	const intercepted: string[] = [
		"msStringEquals", "msStringCompareLt",            // string == / <
		"msStringCharAt", "msStringSlice",                // StrCharAt / StrSlice
		"&msGenericArrayPush",                            // ArrayPush
		"&msGenericArraySetLen",                          // ArraySetLen
	];
	// Deliberately dead — each needs work before it can come off this list.
	const knownDead: string[] = [
		"msStringSubstring",                              // clamp semantics differ from byteSlice
		"msStringPadStart", "msStringPadEnd",             // MS-able, unwritten
		"msStringParseFloat", "msStringParseInt",         // parsing not in the shared tier
		"msStringFromCodePoint",                          // needs a codepoint-to-UTF8 encoder
	];
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	let checked = 0;
	for (const f of rmsFiles) {
		const r = readFile(f);
		assert r.ok;
		if (!r.ok) continue;
		for (const name of scanRmsExternNames(r.value)) {
			checked = checked + 1;
			const covered = lookupHostFn(name) !== null
				|| nameListed(intercepted, name)
				|| nameListed(knownDead, name);
			assert covered, `${f}: ${name}`;
		}
	}
	assert checked >= 14;
}

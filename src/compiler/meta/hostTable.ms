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
	heapArrayLen, heapArrayGet, heapStringText, heapAllocArray, heapArrayPush, heapAllocStoredString, rcIncref, raiserArray,
	raiserObject, raiserInt, createStructHeap, createArrayHeap, raiserEqual, handleIndex, stringBytesHandle, setStringBytesHandle,
	heapObjectSetField, heapAllocBytesOf, heapArrayAssignBytes, heapAllocStringOfBytes,
} from "../../raiser/value";
import { ADAPTEE_FIELD } from "../../transform/coercion/implicitConvLower";
import {
	RaiserVM, registerInPlaceHostFn, hostArg, hostArgCount, hostArgFloat, hostArgInt, hostArgString, hostArgBytes, hostArgText,
	hostReturn, hostReturnFloat, hostReturnInt, hostReturnString, hostReturnBool, hostReturnBytesToFill, hostReturnTextToFill,
} from "../../raiser/vm";
import { copyBytes } from "../../raiser/memory";
import {
	HostCapability, registerHostFn, markHostRegistryInitialized, isHostRegistryInitialized, setActiveHostHeaps,
	activeHostObjectHeap, activeHostArrayHeap, activeProgramArgv, raiseFromHost,
} from "../../raiser/hostRegistry";
import {
	unboxString, unboxInt, unboxFloat, unboxBool,
	boxString, boxInt, boxFloat, boxBool,
	RaiserHostValue, hostValue, hostString, hostObject, hostArray, copyToVm, copyToHost,
} from "../../raiser/marshal";
import { isNodeWireMetaField, allocWireObject, wireGet, wireSet, WIRE_UNION } from "./wire";
import { registerBigIntKernels } from "./bigintHost";
import { wireLiteralIsFloat, wireLiteralInteger, wireLiteralIntegerRefusal, wireLiteralFloat, boundTypeOfObject, boundSymOfObject } from "./bridge";
import { nodeKindName } from "../../ast/fieldspec";
import { NodeKind, TypeKind, SymbolKind } from "../../ast/node";
import { distinctNumericBase, enumMemberValue } from "../../checker/types";

import {
	exists, isFile, isDir, isExecutable, fileSize, modifiedTime, realpath,
	readFile, readFileBytes, writeFile, writeFileBytes, appendFile, chmod, changeStamp, changedTime,
	mkdir, mkdirExclusive, rmdir, remove, rename, symlink, readDir,
	ensureDir, removeAll, readLines, writeLines, copyFile,
} from "std/fs";
import { cwd, platform, arch, env, exec, argv, execPath, execFile, execFileResult } from "std/process";
import { readLine, readBytes, writeStdout, writeStderr, stdinHasData, stdinDisableBuffering } from "std/io";
import { utf8String, findBytesFrom, byteEqAt, asciiWords } from "std/core/string/bytes";
import { wellFormedPrefix } from "std/core/string/utf8Repair";
import { performance } from "std/core/performance";
import { fromCodePoint } from "std/core/string";
import { asciiLower, asciiUpper, isSpaceByte, repeat, reverse, equalsIgnoreCase } from "std/core/string/shared";
import { resolveRuntimeDir } from "../../utils/path";
import { join, resolve } from "std/fs/path";
import { registerCompileTimeRead } from "../cache";
import { IoError, IoErrorKind } from "std/io/errors";
import { ProcessErrorKind } from "std/process/errors";
import "std/compress/zip";
import "std/crypto";

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

// --- Std routines the VM runs through their host implementation ---

function _vmIoError(e: IoError): RaiserHostValue {
	return hostObject(["kind", "path", "message"], [hostValue(boxInt(e.kind as number)), hostString(e.path), hostString(e.message)]);
}

function _toVm(v: RaiserHostValue): RaiserValue {
	const arrays = activeHostArrayHeap();
	const objects = activeHostObjectHeap();
	if (arrays == null || objects == null) throw new Error("internal: a std routine callback ran with no active VM heaps");
	return copyToVm(arrays, objects, v);
}

function _vmFailure(e: IoError): RaiserHostValue {
	return hostObject(["ok", "error"], [hostValue(boxBool(false)), _vmIoError(e)]);
}

function _vmSuccess(value: RaiserHostValue): RaiserHostValue {
	return hostObject(["ok", "value"], [hostValue(boxBool(true)), value]);
}

function _vmStrings(items: string[]): RaiserHostValue {
	return hostArray(items.map((item: string): RaiserHostValue => hostString(item)));
}

function _vmVoidResult(r: Result<void, IoError>): RaiserValue {
	return _toVm(r.ok ? hostObject(["ok"], [hostValue(boxBool(true))]) : _vmFailure(r.error));
}

function _vmStringResult(r: Result<string, IoError>): RaiserValue {
	return _toVm(r.ok ? _vmSuccess(hostString(r.value)) : _vmFailure(r.error));
}

function _vmStringsResult(r: Result<string[], IoError>): RaiserValue {
	return _toVm(r.ok ? _vmSuccess(_vmStrings(r.value)) : _vmFailure(r.error));
}

function _hostStrings(v: RaiserValue): string[] {
	const arrays = activeHostArrayHeap();
	const objects = activeHostObjectHeap();
	if (arrays == null || objects == null) throw new Error("internal: a std routine callback ran with no active VM heaps");
	const items = copyToHost(arrays, objects, v);
	const result: string[] = [];
	for (let i: int32 = 0; i < items.length(); i += 1) result.push(items.at(i).text());
	return result;
}

function _readForBuild(path: string): string {
	registerCompileTimeRead(resolve(path, cwd()));
	return path;
}

function _stdFsReadFile(args: RaiserValue[]): RaiserValue {
	return _vmStringResult(readFile(_readForBuild(unboxString(args[0]))));
}

function _stdFsReadFileBytes(vm: RaiserVM): void {
	const r = readFileBytes(_readForBuild(hostArgString(vm, 0)));
	if (!r.ok) {
		hostReturn(vm, _toVm(_vmFailure(r.error)));
		return;
	}
	const result = _toVm(_vmSuccess(hostValue(raiserNil())));
	heapObjectSetField(vm.arrayHeap, vm.objectHeap, result.intVal, "value", raiserArray(heapAllocBytesOf(vm.arrayHeap, bufferData(r.value) as int64, r.value.length as int64)));
	hostReturn(vm, result);
}

function _stdFsReadLines(args: RaiserValue[]): RaiserValue {
	return _vmStringsResult(readLines(_readForBuild(unboxString(args[0]))));
}

function _stdFsReadDir(args: RaiserValue[]): RaiserValue {
	return _toVm(_vmStrings(readDir(unboxString(args[0]))));
}

function _stdFsWriteFile(args: RaiserValue[]): RaiserValue {
	return _vmVoidResult(writeFile(unboxString(args[0]), unboxString(args[1])));
}

function _stdFsWriteFileBytes(vm: RaiserVM): void {
	const path = hostArgString(vm, 0);
	const bytes = hostArgBytes(vm, 1);
	const content = Buffer.allocUnsafe(bytes.len as number);
	copyBytes(bufferData(content) as int64, bytes.at, bytes.len);
	hostReturn(vm, _vmVoidResult(writeFileBytes(path, content)));
}

@include("runtime/core/buffer.h");
extern function bufferData(buf: Readonly<uint8[]>): Ptr<uint8> from "msBufferData";

function _vmBytesText(bytes: Readonly<uint8[]>): RaiserValue {
	const heap = activeHostArrayHeap();
	if (heap == null) throw new Error("internal: a std routine callback ran with no active VM heaps");
	return heapAllocStringOfBytes(heap, bufferData(bytes) as int64, bytes.length as int64);
}

function _stdFsAppendFile(args: RaiserValue[]): RaiserValue {
	return _vmVoidResult(appendFile(unboxString(args[0]), unboxString(args[1])));
}

function _stdFsWriteLines(args: RaiserValue[]): RaiserValue {
	return _vmVoidResult(writeLines(unboxString(args[0]), _hostStrings(args[1])));
}

function _stdFsCopyFile(args: RaiserValue[]): RaiserValue {
	return _vmVoidResult(copyFile(_readForBuild(unboxString(args[0])), unboxString(args[1])));
}

function _stdFsChmod(args: RaiserValue[]): RaiserValue {
	return _vmVoidResult(chmod(unboxString(args[0]), unboxInt(args[1]) as int32));
}

function _stdFsMkdir(args: RaiserValue[]): RaiserValue {
	return _vmVoidResult(mkdir(unboxString(args[0])));
}

function _stdFsMkdirExclusive(args: RaiserValue[]): RaiserValue {
	return _vmVoidResult(mkdirExclusive(unboxString(args[0])));
}

function _stdFsEnsureDir(args: RaiserValue[]): RaiserValue {
	return _vmVoidResult(ensureDir(unboxString(args[0])));
}

function _stdFsRmdir(args: RaiserValue[]): RaiserValue {
	return _vmVoidResult(rmdir(unboxString(args[0])));
}

function _stdFsRemove(args: RaiserValue[]): RaiserValue {
	return _vmVoidResult(remove(unboxString(args[0])));
}

function _stdFsRemoveAll(args: RaiserValue[]): RaiserValue {
	return _vmVoidResult(removeAll(unboxString(args[0])));
}

function _stdFsRename(args: RaiserValue[]): RaiserValue {
	return _vmVoidResult(rename(unboxString(args[0]), unboxString(args[1])));
}

function _stdFsSymlink(args: RaiserValue[]): RaiserValue {
	return _vmVoidResult(symlink(unboxString(args[0]), unboxString(args[1])));
}

function _stdFsExists(args: RaiserValue[]): RaiserValue {
	return boxBool(exists(unboxString(args[0])));
}

function _stdFsIsFile(args: RaiserValue[]): RaiserValue {
	return boxBool(isFile(unboxString(args[0])));
}

function _stdFsIsDir(args: RaiserValue[]): RaiserValue {
	return boxBool(isDir(unboxString(args[0])));
}

function _stdFsIsExecutable(args: RaiserValue[]): RaiserValue {
	return boxBool(isExecutable(unboxString(args[0])));
}

function _stdFsRealpath(args: RaiserValue[]): RaiserValue {
	return boxString(realpath(unboxString(args[0])));
}

function _stdFsFileSize(args: RaiserValue[]): RaiserValue {
	return boxInt(fileSize(unboxString(args[0])));
}

function _stdFsModifiedTime(args: RaiserValue[]): RaiserValue {
	return boxInt(modifiedTime(unboxString(args[0])));
}

function _stdFsChangedTime(args: RaiserValue[]): RaiserValue {
	return boxInt(changedTime(unboxString(args[0])));
}

function _stdFsChangeStamp(args: RaiserValue[]): RaiserValue {
	return boxString(changeStamp(unboxString(args[0])));
}

// --- File system bridges ---

function _bridgeMsFsExists(args: RaiserValue[]): RaiserValue {
	return boxInt(exists(unboxString(args[0])) ? 1 : 0);
}

function _bridgeMsFsRealPath(args: RaiserValue[]): RaiserValue {
	return boxString(realpath(unboxString(args[0])));
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

function _bridgeMsFsModifiedTime(args: RaiserValue[]): RaiserValue {
	return boxInt(modifiedTime(unboxString(args[0])));
}

function _bridgeMsFsChangedTime(args: RaiserValue[]): RaiserValue {
	return boxInt(changedTime(unboxString(args[0])));
}

function _bridgeMsFsChmod(args: RaiserValue[]): RaiserValue {
	const r = chmod(unboxString(args[0]), unboxInt(args[1]) as int32);
	return _fsResultToInt(r.ok, r.ok ? IoErrorKind.NotFound : r.error.kind);
}

function _bridgeMsFsChangeStamp(args: RaiserValue[]): RaiserValue {
	return boxString(changeStamp(unboxString(args[0])));
}

function _bridgeMsFsReadFile(args: RaiserValue[]): RaiserValue {
	const path = unboxString(args[0]);
	const r = readFileBytes(path);
	registerCompileTimeRead(resolve(path, cwd()));
	if (r.ok) {
		_lastFsErrno = 0;
		return _vmBytesText(r.value);
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

function _bridgeMsFsCopyFile(args: RaiserValue[]): RaiserValue {
	const src = unboxString(args[0]);
	const r = copyFile(src, unboxString(args[1]));
	registerCompileTimeRead(resolve(src, cwd()));
	return _fsResultToInt(r.ok, r.ok ? IoErrorKind.NotFound : r.error.kind);
}

function _bridgeMsFsMkdir(args: RaiserValue[]): RaiserValue {
	const r = mkdir(unboxString(args[0]));
	return _fsResultToInt(r.ok, r.ok ? IoErrorKind.NotFound : r.error.kind);
}

function _bridgeMsFsMkdirExclusive(args: RaiserValue[]): RaiserValue {
	const r = mkdirExclusive(unboxString(args[0]));
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

function _bridgeMsFsSymlink(args: RaiserValue[]): RaiserValue {
	const r = symlink(unboxString(args[0]), unboxString(args[1]));
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

function _bridgeMsProcessArch(args: RaiserValue[]): RaiserValue {
	return boxString(arch);
}

function _bridgeMsProcessExecPath(args: RaiserValue[]): RaiserValue {
	return boxString(execPath);
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
let _spawnErrno: number = 0;

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
	_spawnOk = kind == ProcessErrorKind.SpawnFailed ? 0 : 1;
	_spawnPipeOk = kind == ProcessErrorKind.PipeError ? 0 : 1;
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

function _bridgeMsProcSpawnGetErrno(args: RaiserValue[]): RaiserValue {
	return boxInt(_spawnErrno);
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

// --- Process bridges (envvars get/exists/put/del all registered; execCmdEx
// registered behind the danger flag; quit is deliberately NOT an op — exit is
// handled at the codegen tier, see the Halt intercept) ---

function _bridgeMsProcessArgv(args: RaiserValue[]): RaiserValue {
	const heapOrNull = activeHostArrayHeap();
	if (heapOrNull == null) return raiserNil();
	const heap: RaiserArrayHeap = heapOrNull;
	const h = heapAllocArray(heap);
	const program = activeProgramArgv();
	if (program != null) {
		for (const a of program) {
			heapArrayPush(heap, h, heapAllocStoredString(heap, a));
		}
	} else {
		for (const a of argv) {
			heapArrayPush(heap, h, heapAllocStoredString(heap, a));
		}
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
	if (v.kind != RaiserValueKind.Array) return out;
	const heapOrNull = activeHostArrayHeap();
	if (heapOrNull == null) return out;
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
	const r = execFileResult(unboxString(args[0]), _unboxStringArrayArg(args[1]), unboxString(args[2]));
	_spawnStdout = r.output;
	_spawnStderr = r.errorOutput;
	_spawnExitCode = r.exitCode;
	_spawnSignal = r.signal;
	_spawnOk = r.started ? 1 : 0;
	_spawnPipeOk = r.pipeOk ? 1 : 0;
	_spawnErrno = r.startErrno;
	return boxString(_spawnStdout);
}


// --- std/process/child bridges ---
// The VM sees an index into _children, never the native pointer, so a forged or
// stale handle is refused instead of dereferenced. closeHostChildren kills and
// reaps whatever the program left open when its run ends.

@include("runtime/process.h");

extern function msProcChildSpawn(path: string, args: string[], cwd: string, mergeStderr: int32): int64;
extern function msProcChildSpawnEnv(
	path: string, args: string[], cwd: string, mergeStderr: int32,
	environment: string[],
): int64;
extern function msProcChildIsUnsupported(spawnResult: int64): int32;
extern function msProcChildPid(h: int64): int32;
extern function msProcChildErrno(h: int64): int32;
extern function msProcChildWritten(h: int64): int64;
extern function msProcChildWrite(h: int64, data: string, timeoutMs: int64): int32;
extern function msProcChildCloseStdin(h: int64): void;
extern function msProcChildRead(h: int64, stream: int32, timeoutMs: int64): int32;
extern function msProcChildTake(h: int64, stream: int32): string;
extern function msProcChildWait(h: int64, timeoutMs: int64): int32;
extern function msProcChildKill(h: int64): int32;
extern function msProcChildExitCode(h: int64): int32;
extern function msProcChildSignal(h: int64): int32;
extern function msProcChildClose(h: int64): void;
extern function msProcChildFree(h: int64): void;

const _children: int64[] = [];

function _childOf(v: RaiserValue): int64 {
	const id = unboxInt(v) as int64;
	if (id < 1 || id > _children.length || _children[id - 1] == 0) {
		raiseFromHost(`ChildProcess handle ${id} is not a live child of this run`, true);
		return 0;
	}
	return _children[id - 1];
}

export function closeHostChildren(): void {
	for (const h of _children) {
		if (h != 0) msProcChildFree(h);
	}
	_children.length = 0;
}

function _trackHostChild(handle: int64): RaiserValue {
	if (handle <= 0) { return raiserInt(handle); }
	_children.push(handle);
	return raiserInt(_children.length as int64);
}

function _bridgeMsProcChildSpawn(args: RaiserValue[]): RaiserValue {
	return _trackHostChild(msProcChildSpawn(
		unboxString(args[0]), _unboxStringArrayArg(args[1]),
		unboxString(args[2]), unboxInt(args[3]) as int32,
	));
}

function _bridgeMsProcChildSpawnEnv(args: RaiserValue[]): RaiserValue {
	return _trackHostChild(msProcChildSpawnEnv(
		unboxString(args[0]), _unboxStringArrayArg(args[1]),
		unboxString(args[2]), unboxInt(args[3]) as int32,
		_unboxStringArrayArg(args[4]),
	));
}

function _bridgeMsProcChildIsUnsupported(args: RaiserValue[]): RaiserValue {
	return boxInt(msProcChildIsUnsupported(unboxInt(args[0]) as int64));
}

function _bridgeMsProcChildPid(args: RaiserValue[]): RaiserValue {
	const h = _childOf(args[0]);
	return h == 0 ? raiserNil() : boxInt(msProcChildPid(h));
}

function _bridgeMsProcChildErrno(args: RaiserValue[]): RaiserValue {
	const h = _childOf(args[0]);
	return h == 0 ? raiserNil() : boxInt(msProcChildErrno(h));
}

function _bridgeMsProcChildWritten(args: RaiserValue[]): RaiserValue {
	const h = _childOf(args[0]);
	return h == 0 ? raiserNil() : raiserInt(msProcChildWritten(h));
}

function _bridgeMsProcChildWrite(args: RaiserValue[]): RaiserValue {
	const h = _childOf(args[0]);
	return h == 0 ? raiserNil() : boxInt(msProcChildWrite(h, unboxString(args[1]), unboxInt(args[2]) as int64));
}

function _bridgeMsProcChildCloseStdin(args: RaiserValue[]): RaiserValue {
	const h = _childOf(args[0]);
	if (h != 0) msProcChildCloseStdin(h);
	return raiserNil();
}

function _bridgeMsProcChildRead(args: RaiserValue[]): RaiserValue {
	const h = _childOf(args[0]);
	return h == 0 ? raiserNil() : boxInt(msProcChildRead(h, unboxInt(args[1]) as int32, unboxInt(args[2]) as int64));
}

function _bridgeMsProcChildTake(args: RaiserValue[]): RaiserValue {
	const h = _childOf(args[0]);
	return h == 0 ? raiserNil() : boxString(msProcChildTake(h, unboxInt(args[1]) as int32));
}

function _bridgeMsProcChildWait(args: RaiserValue[]): RaiserValue {
	const h = _childOf(args[0]);
	return h == 0 ? raiserNil() : boxInt(msProcChildWait(h, unboxInt(args[1]) as int64));
}

function _bridgeMsProcChildKill(args: RaiserValue[]): RaiserValue {
	const h = _childOf(args[0]);
	return h == 0 ? raiserNil() : boxInt(msProcChildKill(h));
}

function _bridgeMsProcChildExitCode(args: RaiserValue[]): RaiserValue {
	const h = _childOf(args[0]);
	return h == 0 ? raiserNil() : boxInt(msProcChildExitCode(h));
}

function _bridgeMsProcChildSignal(args: RaiserValue[]): RaiserValue {
	const h = _childOf(args[0]);
	return h == 0 ? raiserNil() : boxInt(msProcChildSignal(h));
}

function _bridgeMsProcChildClose(args: RaiserValue[]): RaiserValue {
	const h = _childOf(args[0]);
	if (h != 0) msProcChildClose(h);
	return raiserNil();
}

function _bridgeMsProcChildFree(args: RaiserValue[]): RaiserValue {
	const h = _childOf(args[0]);
	if (h != 0) {
		msProcChildFree(h);
		_children[(unboxInt(args[0]) as int64) - 1] = 0;
	}
	return raiserNil();
}

// --- std/io bridges (standard streams) ---
// Same static-inline shims the C tier links from runtime/io/streams.h,
// reached through msc's own std/io import — writeStdout/Stderr flush
// immediately (LSP framing), readLine strips \n or \r\n.

function _bridgeMsReadLine(args: RaiserValue[]): RaiserValue {
	return boxString(readLine());
}

function _bridgeMsReadBytes(vm: RaiserVM): void {
	const bytes = readBytes(hostArgFloat(vm, 0));
	hostReturn(vm, raiserArray(heapAllocBytesOf(vm.arrayHeap, bufferData(bytes) as int64, bytes.length as int64)));
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

function _bridgeMsEprintln(args: RaiserValue[]): RaiserValue {
	writeStderr(unboxString(args[0]) + "\n");
	return raiserNil();
}

function _bridgeMsStdinDisableBuffering(args: RaiserValue[]): RaiserValue {
	stdinDisableBuffering();
	return raiserNil();
}

// --- std/compress/zip bridges ---

@include("runtime/compress/zip.h");

extern function msZipReaderOpen(data: string): int64;
extern function msZipReaderCount(handle: int64): int32;
extern function msZipReaderEntryName(handle: int64, index: int32): string;
extern function msZipReaderEntrySize(handle: int64, index: int32): int64;
extern function msZipReaderEntryIsDir(handle: int64, index: int32): int32;
extern function msZipReaderFind(handle: int64, name: string): int32;
extern function msZipReaderExtract(handle: int64, index: int32): string;
extern function msZipReaderClose(handle: int64): void;
extern function msZipWriterNew(): int64;
extern function msZipWriterAdd(handle: int64, name: string, data: string, level: int32): int32;
extern function msZipWriterFinalize(handle: int64): string;
extern function msZipWriterClose(handle: int64): void;

function _bridgeMsZipReaderOpen(args: RaiserValue[]): RaiserValue {
	return raiserInt(msZipReaderOpen(unboxString(args[0])));
}

function _bridgeMsZipReaderCount(args: RaiserValue[]): RaiserValue {
	return boxInt(msZipReaderCount(unboxInt(args[0]) as int64));
}

function _bridgeMsZipReaderEntryName(args: RaiserValue[]): RaiserValue {
	return boxString(msZipReaderEntryName(unboxInt(args[0]) as int64, unboxInt(args[1]) as int32));
}

function _bridgeMsZipReaderEntrySize(args: RaiserValue[]): RaiserValue {
	return raiserInt(msZipReaderEntrySize(unboxInt(args[0]) as int64, unboxInt(args[1]) as int32));
}

function _bridgeMsZipReaderEntryIsDir(args: RaiserValue[]): RaiserValue {
	return boxInt(msZipReaderEntryIsDir(unboxInt(args[0]) as int64, unboxInt(args[1]) as int32));
}

function _bridgeMsZipReaderFind(args: RaiserValue[]): RaiserValue {
	return boxInt(msZipReaderFind(unboxInt(args[0]) as int64, unboxString(args[1])));
}

function _bridgeMsZipReaderExtract(args: RaiserValue[]): RaiserValue {
	return boxString(msZipReaderExtract(unboxInt(args[0]) as int64, unboxInt(args[1]) as int32));
}

function _bridgeMsZipReaderClose(args: RaiserValue[]): RaiserValue {
	msZipReaderClose(unboxInt(args[0]) as int64);
	return raiserNil();
}

function _bridgeMsZipWriterNew(args: RaiserValue[]): RaiserValue {
	return raiserInt(msZipWriterNew());
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

// --- std/crypto bridges (hash family) ---

@include("runtime/crypto/hash.h");

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

extern function msCryptoHashSize(algorithm: string): number;
extern function msCryptoHashSpanInto(algorithm: string, data: Readonly<Span<uint8>>, output: Ptr<uint8>, capacity: int64): int64;

function _bridgeMsCryptoDigest(vm: RaiserVM): void {
	const algorithm = hostArgString(vm, 0);
	const data = hostArg(vm, 1).kind == RaiserValueKind.String ? hostArgText(vm, 1) : hostArgBytes(vm, 1);
	const size = msCryptoHashSize(algorithm) as int64;
	const out = hostReturnBytesToFill(vm, size) as Ptr<uint8>;
	const view = (data.at as Readonly<Ptr<uint8>>)[0..data.len];
	if (size > 0 && msCryptoHashSpanInto(algorithm, view, out, size) != size) {
		raiseFromHost(`internal: the ${algorithm} digest failed on ${data.len} bytes`, true);
	}
}

// --- Macro Node child accessors ---
// childCount/childAt (std/meta) traverse a Node's children BY INDEX on the
// macro VM's flat wire, so a top-level helper
// shared between macros can walk nodes without engine-mode flat-field reads.
// A child slot is any Object field carrying a numeric "kind" (a Node), or
// each such element of an Array field (recursively, so Node[][] fields like
// typExprFieldDecorators are reachable), in field order. Metadata fields are
// never children; resolvedSym and nodeType ARE node-shaped, so telling them
// apart rests on isNodeWireMetaField (wire.ms). childAt returns the live heap ref, not a
// copy — mutations through it stick — and holds it for the caller, as a call result is owned.

function _isNodeShaped(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, v: RaiserValue): boolean {
	if (v.kind != RaiserValueKind.Object) return false;
	const kindField = wireGet(arrHeap, objHeap, v.intVal, "kind");
	return kindField.kind == RaiserValueKind.Int || kindField.kind == RaiserValueKind.Float;
}

function _pushNodeShapedElems(objHeap: RaiserObjectHeap, arrHeap: RaiserArrayHeap, arrHandle: int64, out: RaiserValue[]): void {
	const len = heapArrayLen(arrHeap, arrHandle);
	for (let j = 0; j < len; j = j + 1) {
		const el = heapArrayGet(arrHeap, arrHandle, j);
		if (_isNodeShaped(arrHeap, objHeap, el)) {
			out.push(el);
		} else if (el.kind == RaiserValueKind.Array) {
			_pushNodeShapedElems(objHeap, arrHeap, el.intVal, out);
		}
	}
}

function _nodeChildSlots(h: int64): RaiserValue[] {
	const out: RaiserValue[] = [];
	const objHeapOrNull = activeHostObjectHeap();
	const arrHeapOrNull = activeHostArrayHeap();
	if (objHeapOrNull == null || arrHeapOrNull == null) return out;
	const objHeap: RaiserObjectHeap = objHeapOrNull;
	const arrHeap: RaiserArrayHeap = arrHeapOrNull;
	const n = heapObjectFieldCount(objHeap, h);
	for (let i = 0; i < n; i = i + 1) {
		if (isNodeWireMetaField(heapObjectFieldNameAt(objHeap, h, i))) continue;
		const v = heapObjectFieldValueAt(arrHeap, objHeap, h, i);
		if (_isNodeShaped(arrHeap, objHeap, v)) {
			out.push(v);
		} else if (v.kind == RaiserValueKind.Array) {
			_pushNodeShapedElems(objHeap, arrHeap, v.intVal, out);
		}
	}
	return out;
}

function _bridgeMsNodeChildCount(vm: RaiserVM): void {
	const node = hostArgCount(vm) < 1 ? raiserNil() : hostArg(vm, 0);
	if (node.kind != RaiserValueKind.Object) { hostReturnInt(vm, 0); return; }
	hostReturnInt(vm, _nodeChildSlots(node.intVal).length as int64);
}

function _bridgeMsNodeChildAt(vm: RaiserVM): void {
	const node = hostArgCount(vm) < 2 ? raiserNil() : hostArg(vm, 0);
	if (node.kind != RaiserValueKind.Object) { hostReturn(vm, raiserNil()); return; }
	const slots = _nodeChildSlots(node.intVal);
	const i = unboxInt(hostArg(vm, 1));
	if (i < 0 || i >= slots.length) { hostReturn(vm, raiserNil()); return; }
	rcIncref(vm.arrayHeap, vm.objectHeap, slots[i]);
	hostReturn(vm, slots[i]);
}

// --- String bridges ---
// Bridges exist so `@comptime` code calling `s.trim()` etc. can
// dispatch through the CallHost path without falling into "Unknown host
// function" silent-nil. Full catalogue: docs/RAISER-GAP.md Phase 4.

function _bridgeMsStringTrim(vm: RaiserVM): void {
	hostReturnString(vm, hostArgString(vm, 0).trim());
}

function _bridgeMsStringTrimStart(vm: RaiserVM): void {
	hostReturnString(vm, hostArgString(vm, 0).trimStart());
}

function _bridgeMsStringTrimEnd(vm: RaiserVM): void {
	hostReturnString(vm, hostArgString(vm, 0).trimEnd());
}

function bridgeMsStringToLower(vm: RaiserVM): void {
	hostReturnString(vm, hostArgString(vm, 0).toLowerCase());
}

function bridgeMsStringToUpper(vm: RaiserVM): void {
	hostReturnString(vm, hostArgString(vm, 0).toUpperCase());
}

// indexOf: MS declares (s, sub, start: int64 = 0) — handle optional 3rd arg
function _bridgeMsStringIndexOf(vm: RaiserVM): void {
	const start = hostArgCount(vm) > 2 ? hostArg(vm, 2).intVal : 0;
	hostReturnInt(vm, hostArgString(vm, 0).indexOf(hostArgString(vm, 1), start as int32) as int64);
}

function _bridgeMsStringEquals(vm: RaiserVM): void {
	hostReturnBool(vm, hostArgString(vm, 0) == hostArgString(vm, 1));
}

function _bridgeMsStringCompare(vm: RaiserVM): void {
	const x = hostArgString(vm, 0);
	const y = hostArgString(vm, 1);
	hostReturnInt(vm, x == y ? 0 : x < y ? -1 : 1);
}

function _bridgeMsStringCharCodeAt(vm: RaiserVM): void {
	hostReturnInt(vm, hostArgString(vm, 0).charCodeAt(unboxInt(hostArg(vm, 1)) as int32) as int64);
}

function _bridgeMsStringPadStart(vm: RaiserVM): void {
	hostReturnString(vm, hostArgString(vm, 0).padStart(unboxInt(hostArg(vm, 1)) as int32, hostArgString(vm, 2)));
}

function _bridgeMsStringPadEnd(vm: RaiserVM): void {
	hostReturnString(vm, hostArgString(vm, 0).padEnd(unboxInt(hostArg(vm, 1)) as int32, hostArgString(vm, 2)));
}

function _bridgeMsStringParseInt(vm: RaiserVM): void {
	hostReturnInt(vm, (hostArgString(vm, 0).parseInt() as number) as int64);
}

function _bridgeMsStringParseFloat(vm: RaiserVM): void {
	hostReturnFloat(vm, hostArgString(vm, 0).parseFloat());
}

// --- Math bridges ---

function _bridgeFabs(vm: RaiserVM): void { hostReturnFloat(vm, Math.abs(hostArgFloat(vm, 0))); }
function _bridgeCeil(vm: RaiserVM): void { hostReturnFloat(vm, Math.ceil(hostArgFloat(vm, 0))); }
function _bridgeFloor(vm: RaiserVM): void { hostReturnFloat(vm, Math.floor(hostArgFloat(vm, 0))); }
function _bridgeTrunc(vm: RaiserVM): void { hostReturnFloat(vm, Math.trunc(hostArgFloat(vm, 0))); }
function _bridgeSqrt(vm: RaiserVM): void { hostReturnFloat(vm, Math.sqrt(hostArgFloat(vm, 0))); }
function _bridgeCbrt(vm: RaiserVM): void { hostReturnFloat(vm, Math.cbrt(hostArgFloat(vm, 0))); }
function _bridgePow(vm: RaiserVM): void { hostReturnFloat(vm, Math.pow(hostArgFloat(vm, 0), hostArgFloat(vm, 1))); }

function _powOverflow(): void {
	raiseFromHost("over- or underflow", true);
}

function _bridgePowSigned(vm: RaiserVM, exponentMax: int64): void {
	const exponent = hostArgInt(vm, 1);
	if (exponent < 0) {
		raiseFromHost(`value ${exponent} not in range 0 .. ${exponentMax}`, true);
		return;
	}
	let result: int64 = 1;
	let base = hostArgInt(vm, 0);
	let rest = exponent;
	while (true) {
		if ((rest & 1) != 0) {
			if (mulOverflowsI64(result, base)) { _powOverflow(); return; }
			result = int64Bits((result as uint64) * (base as uint64));
		}
		rest = rest >> 1;
		if (rest == 0) { hostReturnInt(vm, result); return; }
		if (mulOverflowsI64(base, base)) { _powOverflow(); return; }
		base = int64Bits((base as uint64) * (base as uint64));
	}
}

function _bridgeMsPowI64(vm: RaiserVM): void { _bridgePowSigned(vm, 9223372036854775807); }
function _bridgeMsPowI32(vm: RaiserVM): void { _bridgePowSigned(vm, 2147483647); }

function _bridgePowUnsigned(vm: RaiserVM, mask: uint64): void {
	let result: uint64 = 1;
	let base = (hostArgInt(vm, 0) as uint64) & mask;
	let rest = hostArgInt(vm, 1) as uint64;
	while (true) {
		if ((rest & 1) != 0) result = (result * base) & mask;
		rest = rest >> 1;
		if (rest == 0) { hostReturnInt(vm, int64Bits(result)); return; }
		base = (base * base) & mask;
	}
}

function _bridgeMsPowU64(vm: RaiserVM): void { _bridgePowUnsigned(vm, 18446744073709551615); }
function _bridgeMsPowU32(vm: RaiserVM): void { _bridgePowUnsigned(vm, 4294967295); }

function _bridgeExp(vm: RaiserVM): void { hostReturnFloat(vm, Math.exp(hostArgFloat(vm, 0))); }
function _bridgeExpm1(vm: RaiserVM): void { hostReturnFloat(vm, Math.expm1(hostArgFloat(vm, 0))); }
function _bridgeLog(vm: RaiserVM): void { hostReturnFloat(vm, Math.log(hostArgFloat(vm, 0))); }
function _bridgeLog1p(vm: RaiserVM): void { hostReturnFloat(vm, Math.log1p(hostArgFloat(vm, 0))); }
function _bridgeLog2(vm: RaiserVM): void { hostReturnFloat(vm, Math.log2(hostArgFloat(vm, 0))); }
function _bridgeLog10(vm: RaiserVM): void { hostReturnFloat(vm, Math.log10(hostArgFloat(vm, 0))); }
function _bridgeHypot(vm: RaiserVM): void { hostReturnFloat(vm, Math.hypot(hostArgFloat(vm, 0), hostArgFloat(vm, 1))); }
function _bridgeSin(vm: RaiserVM): void { hostReturnFloat(vm, Math.sin(hostArgFloat(vm, 0))); }
function _bridgeCos(vm: RaiserVM): void { hostReturnFloat(vm, Math.cos(hostArgFloat(vm, 0))); }
function _bridgeTan(vm: RaiserVM): void { hostReturnFloat(vm, Math.tan(hostArgFloat(vm, 0))); }
function _bridgeAsin(vm: RaiserVM): void { hostReturnFloat(vm, Math.asin(hostArgFloat(vm, 0))); }
function _bridgeAcos(vm: RaiserVM): void { hostReturnFloat(vm, Math.acos(hostArgFloat(vm, 0))); }
function _bridgeAtan(vm: RaiserVM): void { hostReturnFloat(vm, Math.atan(hostArgFloat(vm, 0))); }
function _bridgeAtan2(vm: RaiserVM): void { hostReturnFloat(vm, Math.atan2(hostArgFloat(vm, 0), hostArgFloat(vm, 1))); }
function _bridgeSinh(vm: RaiserVM): void { hostReturnFloat(vm, Math.sinh(hostArgFloat(vm, 0))); }
function _bridgeCosh(vm: RaiserVM): void { hostReturnFloat(vm, Math.cosh(hostArgFloat(vm, 0))); }
function _bridgeTanh(vm: RaiserVM): void { hostReturnFloat(vm, Math.tanh(hostArgFloat(vm, 0))); }
function _bridgeAsinh(vm: RaiserVM): void { hostReturnFloat(vm, Math.asinh(hostArgFloat(vm, 0))); }
function _bridgeAcosh(vm: RaiserVM): void { hostReturnFloat(vm, Math.acosh(hostArgFloat(vm, 0))); }
function _bridgeAtanh(vm: RaiserVM): void { hostReturnFloat(vm, Math.atanh(hostArgFloat(vm, 0))); }
function _bridgeFmod(vm: RaiserVM): void { hostReturnFloat(vm, hostArgFloat(vm, 0) % hostArgFloat(vm, 1)); }

function _bridgeMsStringFromCodePoint(vm: RaiserVM): void {
	hostReturnString(vm, fromCodePoint(unboxInt(hostArg(vm, 0))));
}

// Tier 1 — string ↔ VM-heap byte-array kernels. These cross the VM-heap
// boundary (host zero-copy view vs VM heap array), which MS cannot express
// from either side; every derived string algorithm is Tier 2
// (std/core/string/shared.ms).
function _bridgeMsAsBytes(vm: RaiserVM): void {
	const arg = hostArg(vm, 0);
	const text = hostArgText(vm, 0);
	const heap = vm.arrayHeap;
	let handle = stringBytesHandle(heap, arg);
	if (handle == 0) {
		handle = heapAllocBytesOf(heap, text.at, text.len);
		setStringBytesHandle(heap, arg, handle);
	} else {
		heapArrayAssignBytes(heap, handle, text.at, text.len);
	}
	hostReturn(vm, raiserArray(handle));
}

function _bridgeMsRawString(vm: RaiserVM): void {
	const bytes = hostArgBytes(vm, 0);
	copyBytes(hostReturnTextToFill(vm, bytes.len), bytes.at, bytes.len);
}

function _bridgeMsAsString(vm: RaiserVM): void {
	const bytes = hostArgBytes(vm, 0);
	hostReturnString(vm, utf8String((bytes.at as Readonly<Ptr<uint8>>)[0..bytes.len], true));
}

// split: the std extension is pure MetaScript (std/core/string/shared.ms) and
// macros cannot import std, so the raiser dispatches here. The array lands in
// the active array heap; macro code reads it with .length/[i] as any array.
function _bridgeMsStringSplit(vm: RaiserVM): void {
	const parts = hostArgString(vm, 0).split(hostArgString(vm, 1));
	const arrHeap = vm.arrayHeap;
	const h = heapAllocArray(arrHeap);
	for (let i = 0; i < parts.length; i = i + 1) {
		heapArrayPush(arrHeap, h, heapAllocStoredString(arrHeap, parts[i]));
	}
	hostReturn(vm, raiserArray(h));
}

function _bridgeMsPerformanceNow(vm: RaiserVM): void {
	hostReturnFloat(vm, performance.now());
}

function _bridgeMsTimeNow(vm: RaiserVM): void {
	hostReturnFloat(vm, Date.now());
}

function isWireNode(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, n: RaiserValue, kind: NodeKind): boolean {
	if (n.kind != RaiserValueKind.Object) return false;
	const k = wireGet(arrHeap, objHeap, n.intVal, "kind");
	return k.kind == RaiserValueKind.Int && k.intVal == (kind as int64);
}

function isTypedAsFloat(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, h: int64): boolean {
	const t = boundTypeOfObject(arrHeap, objHeap, h);
	const repr = distinctNumericBase(t) ?? t;
	return repr != null && (repr.kind == TypeKind.Float32 || repr.kind == TypeKind.Float64 || repr.kind == TypeKind.Number);
}

function _bridgeMsNodeIsFloatLiteral(vm: RaiserVM): void {
	const n = hostArgCount(vm) < 1 ? raiserNil() : hostArg(vm, 0);
	const objHeap = vm.objectHeap;
	const arrHeap = vm.arrayHeap;
	hostReturnBool(vm, isWireNode(arrHeap, objHeap, n, NodeKind.NumberLiteral) && (wireLiteralIsFloat(arrHeap, objHeap, n.intVal) || isTypedAsFloat(arrHeap, objHeap, n.intVal)));
}

function wireNodeKindText(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, n: RaiserValue): string {
	if (n.kind != RaiserValueKind.Object) return "null";
	const kind = wireGet(arrHeap, objHeap, n.intVal, "kind");
	return kind.kind == RaiserValueKind.Int ? nodeKindName(kind.intVal as NodeKind) : "a node without a kind";
}

function enumMemberOrdinal(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, n: RaiserValue): RaiserValue {
	const sym = n.kind == RaiserValueKind.Object ? boundSymOfObject(arrHeap, objHeap, n.intVal) : null;
	if (sym == null || sym.symbolKind != SymbolKind.EnumMember || sym.symbolType == null) return raiserNil();
	const enumType = sym.symbolType.kind == TypeKind.EnumLiteral && sym.symbolType.typeReturn != null ? sym.symbolType.typeReturn : sym.symbolType;
	const index: int32 = enumType.kind == TypeKind.Enum ? enumType.typeNames.indexOf(sym.name) as int32 : -1;
	return index < 0 ? raiserNil() : raiserInt(enumMemberValue(enumType, index) as int64);
}

function _bridgeMsNodeIntValue(vm: RaiserVM): void {
	const objHeap = vm.objectHeap;
	const arrHeap = vm.arrayHeap;
	if (hostArgCount(vm) < 1) {
		raiseFromHost("intValue needs an integer literal node", true);
		return;
	}
	const n = hostArg(vm, 0);
	const ordinal = enumMemberOrdinal(arrHeap, objHeap, n);
	if (ordinal.kind == RaiserValueKind.Int) { hostReturn(vm, ordinal); return; }
	if (!isWireNode(arrHeap, objHeap, n, NodeKind.NumberLiteral)) {
		raiseFromHost("intValue needs an integer literal or an enum member, got " + wireNodeKindText(arrHeap, objHeap, n), true);
		return;
	}
	if (wireLiteralIsFloat(arrHeap, objHeap, n.intVal)) {
		raiseFromHost("intValue needs an integer literal, got a float literal; read it with floatValue", true);
		return;
	}
	const refusal = wireLiteralIntegerRefusal(arrHeap, objHeap, n.intVal);
	if (refusal != "") {
		raiseFromHost("intValue: " + refusal, true);
		return;
	}
	hostReturnInt(vm, wireLiteralInteger(arrHeap, objHeap, n.intVal));
}

function _bridgeMsNodeFloatValue(vm: RaiserVM): void {
	const objHeap = vm.objectHeap;
	const arrHeap = vm.arrayHeap;
	if (hostArgCount(vm) < 1) {
		raiseFromHost("floatValue needs a float literal node", true);
		return;
	}
	const n = hostArg(vm, 0);
	if (!isWireNode(arrHeap, objHeap, n, NodeKind.NumberLiteral)) {
		raiseFromHost("floatValue needs a float literal, got " + wireNodeKindText(arrHeap, objHeap, n), true);
		return;
	}
	if (!wireLiteralIsFloat(arrHeap, objHeap, n.intVal) && !isTypedAsFloat(arrHeap, objHeap, n.intVal)) {
		raiseFromHost("floatValue needs a float literal, got an integer literal; read it with intValue", true);
		return;
	}
	hostReturnFloat(vm, wireLiteralFloat(arrHeap, objHeap, n.intVal));
}

function _bridgeMsNodeStringValue(vm: RaiserVM): void {
	const objHeap = vm.objectHeap;
	const arrHeap = vm.arrayHeap;
	if (hostArgCount(vm) < 1) {
		raiseFromHost("stringValue needs a string literal node", true);
		return;
	}
	const n = hostArg(vm, 0);
	if (isWireNode(arrHeap, objHeap, n, NodeKind.Identifier)) {
		const sym = boundSymOfObject(arrHeap, objHeap, n.intVal);
		if (sym != null && sym.symbolKind == SymbolKind.EnumMember) { hostReturnString(vm, sym.name); return; }
		hostReturnString(vm, unboxString(wireGet(arrHeap, objHeap, n.intVal, "name")));
		return;
	}
	if (!isWireNode(arrHeap, objHeap, n, NodeKind.StringLiteral)) {
		raiseFromHost("stringValue needs a string literal or an identifier, got " + wireNodeKindText(arrHeap, objHeap, n), true);
		return;
	}
	hostReturnString(vm, unboxString(wireGet(arrHeap, objHeap, n.intVal, "value")));
}

function _bridgeMsStringReplace(vm: RaiserVM): void {
	hostReturnString(vm, hostArgString(vm, 0).replace(hostArgString(vm, 1), hostArgString(vm, 2)));
}

function _bridgeMsStringReplaceAll(vm: RaiserVM): void {
	hostReturnString(vm, hostArgString(vm, 0).replaceAll(hostArgString(vm, 1), hostArgString(vm, 2)));
}

function _bridgeMsStringByteLength(vm: RaiserVM): void {
	hostReturnInt(vm, hostArgText(vm, 0).len);
}

function _bridgeMsStringByteAt(vm: RaiserVM): void {
	const text = hostArgText(vm, 0);
	const idx = hostArgInt(vm, 1);
	hostReturnInt(vm, idx < 0 || idx >= text.len ? -1 : (text.at as Ptr<uint8>)[idx] as int64);
}

function _bridgeStdHashFarm(vm: RaiserVM): void {
	hostReturnInt(vm, hashFarm(hostArgString(vm, 0)));
}

function _bridgeMsStringByteSlice(vm: RaiserVM): void {
	const text = hostArgText(vm, 0);
	const start = hostArgInt(vm, 1);
	const end = hostArgInt(vm, 2);
	const from = start < 0 ? 0 : start > text.len ? text.len : start;
	const to = end < from ? from : end > text.len ? text.len : end;
	if (wellFormedPrefix(((text.at + from) as Readonly<Ptr<uint8>>)[0..to - from], 0, true) == to - from) {
		copyBytes(hostReturnTextToFill(vm, to - from), text.at + from, to - from);
		return;
	}
	hostReturnString(vm, hostArgString(vm, 0).byteSlice(from as int32, to as int32));
}

function _bridgeMsStringByteIndexOf(vm: RaiserVM): void {
	const hay = hostArgText(vm, 0);
	const needle = hostArgText(vm, 1);
	const start = hostArgInt(vm, 2);
	if (needle.len == 0) { hostReturnInt(vm, start); return; }
	hostReturnInt(vm, findBytesFrom((hay.at as Readonly<Ptr<uint8>>)[0..hay.len], (needle.at as Readonly<Ptr<uint8>>)[0..needle.len], start < 0 ? 0 : start));
}

function _bridgeMsStringByteLastIndexOf(vm: RaiserVM): void {
	const hay = hostArgText(vm, 0);
	const needle = hostArgText(vm, 1);
	const startIdx = hostArgInt(vm, 2);
	if (needle.len == 0) { hostReturnInt(vm, hay.len); return; }
	let i = hay.len - needle.len;
	if (startIdx >= 0 && startIdx < i) i = startIdx;
	const hb = (hay.at as Readonly<Ptr<uint8>>)[0..hay.len];
	const nb = (needle.at as Readonly<Ptr<uint8>>)[0..needle.len];
	while (i >= 0 && !byteEqAt(hb, i, nb)) i -= 1;
	hostReturnInt(vm, i < 0 ? -1 : i);
}

function _bridgeMsUtf8Text(vm: RaiserVM): void {
	const raw = hostArg(vm, 0);
	const text = hostArgText(vm, 0);
	const surrogates = unboxBool(hostArg(vm, 1));
	const data = (text.at as Readonly<Ptr<uint8>>)[0..text.len];
	if (wellFormedPrefix(data, 0, surrogates) == text.len) {
		rcIncref(vm.arrayHeap, vm.objectHeap, raw);
		hostReturn(vm, raw);
		return;
	}
	hostReturnString(vm, utf8String(data, surrogates));
}

function _bridgeMsStringIsAscii(vm: RaiserVM): void {
	const text = hostArgText(vm, 0);
	const bytes = text.at as Readonly<Ptr<uint8>>;
	let i = asciiWords(bytes, text.len >> 3) << 3;
	while (i < text.len && bytes[i] < 0x80) i += 1;
	hostReturnBool(vm, i == text.len);
}

@include("runtime/core/string.h");
extern function msMemChr(hay: Readonly<Span<uint8>>, from: int64, end: int64, byte: uint8): int64;
extern function msEqualMem(a: Readonly<Span<uint8>>, b: Readonly<Span<uint8>>): boolean;
extern function msMemMismatch(a: Readonly<Span<uint8>>, b: Readonly<Span<uint8>>): int64;

function _bridgeMsMemChr(vm: RaiserVM): void {
	const hay = hostArgBytes(vm, 0);
	const from = hostArgInt(vm, 1);
	const end = hostArgInt(vm, 2);
	hostReturnInt(vm, msMemChr((hay.at as Readonly<Ptr<uint8>>)[0..hay.len], from, end, hostArgInt(vm, 3) as uint8));
}

function _bridgeMsMemEqAt(vm: RaiserVM): void {
	const hay = hostArgBytes(vm, 0);
	const needle = hostArgBytes(vm, 2);
	hostReturnBool(vm, byteEqAt((hay.at as Readonly<Ptr<uint8>>)[0..hay.len], hostArgInt(vm, 1), (needle.at as Readonly<Ptr<uint8>>)[0..needle.len]));
}

function _bridgeMsEqualMem(vm: RaiserVM): void {
	const a = hostArgBytes(vm, 0);
	const b = hostArgBytes(vm, 1);
	hostReturnBool(vm, msEqualMem((a.at as Readonly<Ptr<uint8>>)[0..a.len], (b.at as Readonly<Ptr<uint8>>)[0..b.len]));
}

function _bridgeMsMemMismatch(vm: RaiserVM): void {
	const a = hostArgBytes(vm, 0);
	const b = hostArgBytes(vm, 1);
	hostReturnInt(vm, msMemMismatch((a.at as Readonly<Ptr<uint8>>)[0..a.len], (b.at as Readonly<Ptr<uint8>>)[0..b.len]));
}

// --- Whole-function callbacks, keyed by the routine's qualified name ---
// The call site asks for the key before it compiles any body, so these std routines never
// become VM code; each callback serves every overload of its name (see hostRoutineKey).

function _callbackClampIndex(vm: RaiserVM): void {
	const i = unboxInt(hostArg(vm, 0));
	const len = unboxInt(hostArg(vm, 1));
	hostReturnInt(vm, (i < 0 ? 0 : i > len ? len : i) as int64);
}

function _callbackRepeat(vm: RaiserVM): void {
	hostReturnString(vm, hostArgString(vm, 0).repeat(unboxInt(hostArg(vm, 1)) as int32));
}

function _callbackReverse(vm: RaiserVM): void {
	hostReturnString(vm, hostArgString(vm, 0).reverse());
}

function _callbackEqualsIgnoreCase(vm: RaiserVM): void {
	hostReturnBool(vm, hostArgString(vm, 0).equalsIgnoreCase(hostArgString(vm, 1)));
}

function _callbackAsciiLower(vm: RaiserVM): void {
	hostReturnInt(vm, asciiLower(unboxInt(hostArg(vm, 0)) as int32) as int64);
}

function _callbackAsciiUpper(vm: RaiserVM): void {
	hostReturnInt(vm, asciiUpper(unboxInt(hostArg(vm, 0)) as int32) as int64);
}

function _callbackIsSpaceByte(vm: RaiserVM): void {
	hostReturnBool(vm, isSpaceByte(unboxInt(hostArg(vm, 0)) as int32));
}

function _callbackByteLastIndexOf(vm: RaiserVM): void {
	const startIdx = hostArgCount(vm) > 2 ? unboxInt(hostArg(vm, 2)) as int32 : -1;
	hostReturnInt(vm, hostArgString(vm, 0).byteLastIndexOf(hostArgString(vm, 1), startIdx) as int64);
}

function _hostArrayHeap(): RaiserArrayHeap {
	const heap = activeHostArrayHeap();
	if (heap == null) throw new Error("internal: an array kernel ran with no active array heap");
	return heap;
}

function _arrayArg(v: RaiserValue): int64 {
	if (v.kind != RaiserValueKind.Array) throw new Error("internal: an array kernel was handed a non-array");
	return v.intVal;
}

function _numbersOf(v: RaiserValue): number[] {
	const heap = _hostArrayHeap();
	const h = _arrayArg(v);
	const out: number[] = [];
	const n = heapArrayLen(heap, h);
	for (let i = 0; i < n; i = i + 1) out.push(unboxFloat(heapArrayGet(heap, h, i)));
	return out;
}

function _stringsOf(v: RaiserValue): string[] {
	const heap = _hostArrayHeap();
	const h = _arrayArg(v);
	const out: string[] = [];
	const n = heapArrayLen(heap, h);
	for (let i = 0; i < n; i = i + 1) out.push(heapStringText(heap, heapArrayGet(heap, h, i)));
	return out;
}

function _bridgeNumberArrayIndexOf(vm: RaiserVM): void {
	hostReturnFloat(vm, _numbersOf(hostArg(vm, 0)).indexOf(hostArgFloat(vm, 1)));
}

function _bridgeNumberArrayIncludes(vm: RaiserVM): void {
	hostReturnBool(vm, _numbersOf(hostArg(vm, 0)).includes(hostArgFloat(vm, 1)));
}

function _bridgeNumberArrayCount(vm: RaiserVM): void {
	hostReturnFloat(vm, _numbersOf(hostArg(vm, 0)).count(hostArgFloat(vm, 1)));
}

function _bridgeNumberArrayJoin(vm: RaiserVM): void {
	hostReturnString(vm, _numbersOf(hostArg(vm, 0)).join(hostArgString(vm, 1)));
}

function _bridgeNumberArrayAt(vm: RaiserVM): void {
	const xs = _numbersOf(hostArg(vm, 0));
	const idx = hostArgFloat(vm, 1);
	const i = idx < 0.0 ? xs.length + idx : idx;
	if (i < 0.0 || i >= xs.length) {
		raiseFromHost(`index ${idx} out of bounds (length ${xs.length})`, true);
		return;
	}
	hostReturnFloat(vm, xs[i as int32]);
}

function _bridgeRaiseRange(vm: RaiserVM): void {
	raiseFromHost(`value ${hostArg(vm, 0).intVal} not in range ${hostArg(vm, 1).intVal} .. ${hostArg(vm, 2).intVal}`, true);
}

function _bridgeRaiseField(vm: RaiserVM): void {
	const labels = hostArgString(vm, 1).split("|");
	const tag = unboxInt(hostArg(vm, 2));
	const label = tag >= 0 && tag < labels.length ? labels[tag as int32] : "";
	raiseFromHost(`${hostArgString(vm, 0)}${label}'`, true);
}

function _bridgeStringArrayIndexOf(vm: RaiserVM): void {
	hostReturnFloat(vm, _stringsOf(hostArg(vm, 0)).indexOf(hostArgString(vm, 1)));
}

function _bridgeStringArrayIncludes(vm: RaiserVM): void {
	hostReturnBool(vm, _stringsOf(hostArg(vm, 0)).includes(hostArgString(vm, 1)));
}

function _bridgeStringArrayLastIndexOf(vm: RaiserVM): void {
	const from = hostArgCount(vm) > 2 ? unboxInt(hostArg(vm, 2)) as int32 : -1;
	hostReturnFloat(vm, _stringsOf(hostArg(vm, 0)).lastIndexOf(hostArgString(vm, 1), from));
}

function _bridgeStringArrayCount(vm: RaiserVM): void {
	hostReturnFloat(vm, _stringsOf(hostArg(vm, 0)).count(hostArgString(vm, 1)));
}

function _bridgeStringArrayJoin(vm: RaiserVM): void {
	hostReturnString(vm, _stringsOf(hostArg(vm, 0)).join(hostArgString(vm, 1)));
}

function _bridgeGenericArrayCheckedIndex(vm: RaiserVM): void {
	const len = heapArrayLen(_hostArrayHeap(), _arrayArg(hostArg(vm, 0)));
	const idx = hostArgFloat(vm, 1);
	const i = idx < 0.0 ? len + idx : idx;
	if (i < 0.0 || i >= len) {
		raiseFromHost(`index ${idx} out of bounds (length ${len})`, true);
		return;
	}
	hostReturnInt(vm, i as int64);
}

function _bridgeStringLastIndexOf(vm: RaiserVM): void {
	const start = hostArgCount(vm) > 2 ? unboxInt(hostArg(vm, 2)) as int32 : -1;
	hostReturnInt(vm, hostArgString(vm, 0).lastIndexOf(hostArgString(vm, 1), start) as int64);
}

function registerArrayKernels(): void {
	registerInPlaceHostFn("msStringLastIndexOf", _bridgeStringLastIndexOf, HostCapability.Pure);
	registerInPlaceHostFn("&msNumberArrayIndexOf", _bridgeNumberArrayIndexOf, HostCapability.Pure);
	registerInPlaceHostFn("&msNumberArrayIncludes", _bridgeNumberArrayIncludes, HostCapability.Pure);
	registerInPlaceHostFn("&msNumberArrayCount", _bridgeNumberArrayCount, HostCapability.Pure);
	registerInPlaceHostFn("&msNumberArrayJoin", _bridgeNumberArrayJoin, HostCapability.Pure);
	registerInPlaceHostFn("&msNumberArrayAt", _bridgeNumberArrayAt, HostCapability.Pure);
	registerInPlaceHostFn("msRaiseRangeError", _bridgeRaiseRange, HostCapability.Pure);
	registerInPlaceHostFn("msRaiseFieldError", _bridgeRaiseField, HostCapability.Pure);
	registerInPlaceHostFn("&msStringArrayIndexOf", _bridgeStringArrayIndexOf, HostCapability.Pure);
	registerInPlaceHostFn("&msStringArrayIncludes", _bridgeStringArrayIncludes, HostCapability.Pure);
	registerInPlaceHostFn("&msStringArrayLastIndexOf", _bridgeStringArrayLastIndexOf, HostCapability.Pure);
	registerInPlaceHostFn("&msStringArrayCount", _bridgeStringArrayCount, HostCapability.Pure);
	registerInPlaceHostFn("&msStringArrayJoin", _bridgeStringArrayJoin, HostCapability.Pure);
	registerInPlaceHostFn("&msGenericArrayCheckedIndex", _bridgeGenericArrayCheckedIndex, HostCapability.Pure);
}

function registerStringCallbacks(): void {
	registerInPlaceHostFn("std/core/string/shared.clampIndex",   _callbackClampIndex, HostCapability.Pure);
	registerInPlaceHostFn("std/core/string.trim",                _bridgeMsStringTrim, HostCapability.Pure);
	registerInPlaceHostFn("std/core/string.trimStart",           _bridgeMsStringTrimStart, HostCapability.Pure);
	registerInPlaceHostFn("std/core/string.trimEnd",             _bridgeMsStringTrimEnd, HostCapability.Pure);
	registerInPlaceHostFn("std/core/string.toLowerCase",         bridgeMsStringToLower, HostCapability.Pure);
	registerInPlaceHostFn("std/core/string.toUpperCase",         bridgeMsStringToUpper, HostCapability.Pure);
	registerInPlaceHostFn("msStringTrim",                        _bridgeMsStringTrim, HostCapability.Pure);
	registerInPlaceHostFn("msStringTrimStart",                   _bridgeMsStringTrimStart, HostCapability.Pure);
	registerInPlaceHostFn("msStringTrimEnd",                     _bridgeMsStringTrimEnd, HostCapability.Pure);
	registerInPlaceHostFn("msStringToLowerCase",                 bridgeMsStringToLower, HostCapability.Pure);
	registerInPlaceHostFn("msStringToUpperCase",                 bridgeMsStringToUpper, HostCapability.Pure);
	registerInPlaceHostFn("std/core/string/shared.repeat",       _callbackRepeat, HostCapability.Pure);
	registerInPlaceHostFn("std/core/string/shared.reverse",      _callbackReverse, HostCapability.Pure);
	registerInPlaceHostFn("std/core/string/shared.equalsIgnoreCase", _callbackEqualsIgnoreCase, HostCapability.Pure);
	registerInPlaceHostFn("std/core/string/shared.asciiLower",   _callbackAsciiLower, HostCapability.Pure);
	registerInPlaceHostFn("std/core/string/shared.asciiUpper",   _callbackAsciiUpper, HostCapability.Pure);
	registerInPlaceHostFn("std/core/string/shared.isSpaceByte",  _callbackIsSpaceByte, HostCapability.Pure);
	registerInPlaceHostFn("std/core/string/bytes.byteLength",    _bridgeMsStringByteLength, HostCapability.Pure);
	registerInPlaceHostFn("std/core/string/bytes.byteAt",        _bridgeMsStringByteAt, HostCapability.Pure);
	registerInPlaceHostFn("std/core/string/bytes.byteSlice",     _bridgeMsStringByteSlice, HostCapability.Pure);
	registerInPlaceHostFn("std/core/string/bytes.byteLastIndexOf", _callbackByteLastIndexOf, HostCapability.Pure);
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

function _unionSlotAllowed(arrHeap: RaiserArrayHeap, slots: RaiserValue, tag: int64): boolean {
	const n = heapArrayLen(arrHeap, slots.intVal);
	if (n == 0) return true;
	for (let i = 0; i < n; i = i + 1) {
		if (heapArrayGet(arrHeap, slots.intVal, i).intVal == tag) return true;
	}
	return false;
}

function _unionRead(vm: RaiserVM, maybe: boolean): void {
	const objHeap = vm.objectHeap;
	const arrHeap = vm.arrayHeap;
	const u = hostArg(vm, 0);
	if (maybe && u.kind == RaiserValueKind.Nil) { hostReturn(vm, raiserNil()); return; }
	const tag = wireGet(arrHeap, objHeap, u.intVal, "$tag").intVal;
	if (!_unionSlotAllowed(arrHeap, hostArg(vm, 1), tag)) {
		const label = heapArrayGet(arrHeap, hostArg(vm, 3).intVal, tag);
		raiseFromHost(hostArgString(vm, 2) + unboxString(label) + "'", true);
		return;
	}
	hostReturn(vm, wireGet(arrHeap, objHeap, u.intVal, "$v"));
}

function _bridgeMsUnionRead(vm: RaiserVM): void {
	_unionRead(vm, false);
}

function _bridgeMsUnionReadMaybe(vm: RaiserVM): void {
	_unionRead(vm, true);
}

function _rangeBound(v: RaiserValue): int64 {
	return v.kind == RaiserValueKind.Float ? v.floatVal as int64 : v.intVal;
}

function _bridgeMsCheckRangeI32(vm: RaiserVM): void {
	const v = hostArg(vm, 0);
	const lo = _rangeBound(hostArg(vm, 1));
	const hi = _rangeBound(hostArg(vm, 2));
	const inRange = v.kind == RaiserValueKind.Float ? v.floatVal > (lo as float64) - 1.0 && v.floatVal < (hi as float64) + 1.0 : v.intVal >= lo && v.intVal <= hi;
	if (!inRange) {
		raiseFromHost(`value ${v.kind == RaiserValueKind.Float ? `${v.floatVal}` : `${v.intVal}`} not in range ${lo} .. ${hi}`, true);
		return;
	}
	hostReturn(vm, v.kind == RaiserValueKind.Float ? raiserInt(v.floatVal as int64) : v);
}

function _bridgeMsCheckRangeI32FromU64(vm: RaiserVM): void {
	const v = hostArg(vm, 0);
	if (v.intVal >= 0) { _bridgeMsCheckRangeI32(vm); return; }
	raiseFromHost(`value ${v.intVal as uint64} not in range ${_rangeBound(hostArg(vm, 1))} .. ${_rangeBound(hostArg(vm, 2))}`, true);
}

function closureAdaptee(arrHeap: RaiserArrayHeap, objHeap: RaiserObjectHeap, closure: RaiserValue): RaiserValue {
	let c = closure;
	while (c.kind == RaiserValueKind.Object) {
		const env = heapObjectGetField(arrHeap, objHeap, c.intVal, "env");
		if (env.kind != RaiserValueKind.Object) break;
		const adaptee = heapObjectGetField(arrHeap, objHeap, env.intVal, ADAPTEE_FIELD);
		if (adaptee.kind != RaiserValueKind.Object) break;
		c = adaptee;
	}
	return c;
}

function _bridgeMsClosureSame(vm: RaiserVM): void {
	const objHeap = vm.objectHeap;
	const arrHeap = vm.arrayHeap;
	const a = closureAdaptee(arrHeap, objHeap, hostArg(vm, 0));
	const b = closureAdaptee(arrHeap, objHeap, hostArg(vm, 1));
	if (a.kind != RaiserValueKind.Object || b.kind != RaiserValueKind.Object) { hostReturnBool(vm, raiserEqual(arrHeap, a, b)); return; }
	hostReturnBool(vm, raiserEqual(arrHeap, heapObjectGetField(arrHeap, objHeap, a.intVal, "fn"), heapObjectGetField(arrHeap, objHeap, b.intVal, "fn"))
		&& raiserEqual(arrHeap, heapObjectGetField(arrHeap, objHeap, a.intVal, "env"), heapObjectGetField(arrHeap, objHeap, b.intVal, "env")));
}

function _bridgeMsMaybeGet(vm: RaiserVM): void {
	const v = hostArg(vm, 0);
	if (v.kind == RaiserValueKind.Nil) {
		raiseFromHost(hostArgString(vm, 1) + hostArgString(vm, 2) + "'", true);
		return;
	}
	hostReturn(vm, v);
}

function _bridgeMsUnionWrapMaybe(vm: RaiserVM): void {
	const v = hostArg(vm, 0);
	if (v.kind == RaiserValueKind.Nil) { hostReturn(vm, raiserNil()); return; }
	const objHeap = vm.objectHeap;
	const arrHeap = vm.arrayHeap;
	const tag = hostArg(vm, 1);
	const handle = allocWireObject(objHeap, WIRE_UNION);
	wireSet(arrHeap, objHeap, handle, "$tag", tag);
	wireSet(arrHeap, objHeap, handle, "$v", v);
	rcIncref(arrHeap, objHeap, v);
	rcIncref(arrHeap, objHeap, tag);
	hostReturn(vm, raiserObject(handle));
}

export function ensureHostTableLoaded(): void {
	if (isHostRegistryInitialized()) return;

	registerInPlaceHostFn("msUnionRead", _bridgeMsUnionRead, HostCapability.Pure);
	registerInPlaceHostFn("msUnionReadMaybe", _bridgeMsUnionReadMaybe, HostCapability.Pure);
	registerInPlaceHostFn("msUnionWrapMaybe", _bridgeMsUnionWrapMaybe, HostCapability.Pure);
	registerInPlaceHostFn("msMaybeGet", _bridgeMsMaybeGet, HostCapability.Pure);
	registerInPlaceHostFn("msClosureSame", _bridgeMsClosureSame, HostCapability.Pure);
	registerInPlaceHostFn("msCheckRangeI32", _bridgeMsCheckRangeI32, HostCapability.Pure);
	registerInPlaceHostFn("msCheckRangeI32FromU64", _bridgeMsCheckRangeI32FromU64, HostCapability.Pure);

	// fs predicates
	registerHostFn("msFsExists",         _bridgeMsFsExists, HostCapability.FileRead);
	registerHostFn("msFsRealPath",       _bridgeMsFsRealPath, HostCapability.FileRead);
	registerHostFn("msFsIsFile",         _bridgeMsFsIsFile, HostCapability.FileRead);
	registerHostFn("msFsIsDir",          _bridgeMsFsIsDir, HostCapability.FileRead);
	registerHostFn("msFsIsExecutable",   _bridgeMsFsIsExecutable, HostCapability.FileRead);
	registerHostFn("msFsFileSize",       _bridgeMsFsFileSize, HostCapability.FileRead);
	registerHostFn("msFsModifiedTime",   _bridgeMsFsModifiedTime, HostCapability.FileRead);
	// fs read/write/mutate + errno polling
	registerHostFn("msFsReadFile",       _bridgeMsFsReadFile, HostCapability.FileRead);
	registerHostFn("msFsLastErrno",      _bridgeMsFsLastErrno, HostCapability.FileRead);
	registerHostFn("msFsWriteFileMode",  _bridgeMsFsWriteFileMode);
	registerHostFn("msFsChangedTime",    _bridgeMsFsChangedTime, HostCapability.FileRead);
	registerHostFn("msFsChangeStamp",    _bridgeMsFsChangeStamp, HostCapability.FileRead);
	registerHostFn("std/fs.readFile",    _stdFsReadFile, HostCapability.FileRead);
	registerInPlaceHostFn("std/fs.readFileBytes", _stdFsReadFileBytes, HostCapability.FileRead);
	registerHostFn("std/fs.readLines",   _stdFsReadLines, HostCapability.FileRead);
	registerHostFn("std/fs.readDir",     _stdFsReadDir, HostCapability.FileRead);
	registerHostFn("std/fs.exists",      _stdFsExists, HostCapability.FileRead);
	registerHostFn("std/fs.isFile",      _stdFsIsFile, HostCapability.FileRead);
	registerHostFn("std/fs.isDir",       _stdFsIsDir, HostCapability.FileRead);
	registerHostFn("std/fs.isExecutable", _stdFsIsExecutable, HostCapability.FileRead);
	registerHostFn("std/fs.realpath",    _stdFsRealpath, HostCapability.FileRead);
	registerHostFn("std/fs.fileSize",    _stdFsFileSize, HostCapability.FileRead);
	registerHostFn("std/fs.modifiedTime", _stdFsModifiedTime, HostCapability.FileRead);
	registerHostFn("std/fs.changedTime", _stdFsChangedTime, HostCapability.FileRead);
	registerHostFn("std/fs.changeStamp", _stdFsChangeStamp, HostCapability.FileRead);
	registerHostFn("std/fs.writeFile",   _stdFsWriteFile);
	registerInPlaceHostFn("std/fs.writeFileBytes", _stdFsWriteFileBytes);
	registerHostFn("std/fs.appendFile",  _stdFsAppendFile);
	registerHostFn("std/fs.writeLines",  _stdFsWriteLines);
	registerHostFn("std/fs.copyFile",    _stdFsCopyFile);
	registerHostFn("std/fs.chmod",       _stdFsChmod);
	registerHostFn("std/fs.mkdir",       _stdFsMkdir);
	registerHostFn("std/fs.mkdirExclusive", _stdFsMkdirExclusive);
	registerHostFn("std/fs.ensureDir",   _stdFsEnsureDir);
	registerHostFn("std/fs.rmdir",       _stdFsRmdir);
	registerHostFn("std/fs.remove",      _stdFsRemove);
	registerHostFn("std/fs.removeAll",   _stdFsRemoveAll);
	registerHostFn("std/fs.rename",      _stdFsRename);
	registerHostFn("std/fs.symlink",     _stdFsSymlink);
	registerHostFn("msFsChmod",          _bridgeMsFsChmod);
	registerHostFn("msFsCopyFile",       _bridgeMsFsCopyFile);
	registerHostFn("msFsMkdir",          _bridgeMsFsMkdir);
	registerHostFn("msFsMkdirExclusive", _bridgeMsFsMkdirExclusive);
	registerHostFn("msFsRmdir",          _bridgeMsFsRmdir);
	registerHostFn("msFsRemove",         _bridgeMsFsRemove);
	registerHostFn("msFsRename",         _bridgeMsFsRename);
	registerHostFn("msFsSymlink",        _bridgeMsFsSymlink);
	registerHostFn("msFsReadDirEntries", _bridgeMsFsReadDirEntries, HostCapability.FileRead);
	// process accessors
	registerHostFn("msProcessCwd",       _bridgeMsProcessCwd);
	registerHostFn("msProcessPlatform",  _bridgeMsProcessPlatform);
	registerHostFn("msProcessArch",      _bridgeMsProcessArch);
	registerHostFn("msProcessExecPath",  _bridgeMsProcessExecPath);
	registerHostFn("msProcessGetEnv",    _bridgeMsProcessGetEnv);
	// process spawn/exec
	registerHostFn("msProcessSpawnSync",    _bridgeMsProcessSpawnSync);
	registerHostFn("msProcSpawnGetOk",      _bridgeMsProcSpawnGetOk);
	registerHostFn("msProcSpawnGetPipeOk",  _bridgeMsProcSpawnGetPipeOk);
	registerHostFn("msProcSpawnGetErrno",   _bridgeMsProcSpawnGetErrno);
	registerHostFn("msProcSpawnGetExitCode", _bridgeMsProcSpawnGetExitCode);
	registerHostFn("msProcSpawnGetSignal",  _bridgeMsProcSpawnGetSignal);
	registerHostFn("msProcSpawnGetStderr",  _bridgeMsProcSpawnGetStderr);
	// macro Node child accessors (std/meta childCount/childAt)
	registerInPlaceHostFn("msNodeChildCount",      _bridgeMsNodeChildCount, HostCapability.Pure);
	registerInPlaceHostFn("msNodeChildAt",         _bridgeMsNodeChildAt, HostCapability.Pure);
	// string ops — extension methods called as `s.trim()` etc.
	// Coverage: trim family + case + indexOf/contains/start/end + replace.
	// Hot paths (charAt/slice) stay hardcoded in raiser/expressions.ms for
	// direct-opcode performance.
	registerInPlaceHostFn("msStringIndexOf",       _bridgeMsStringIndexOf, HostCapability.Pure);
	registerInPlaceHostFn("msStringEquals",        _bridgeMsStringEquals, HostCapability.Pure);
	registerInPlaceHostFn("msStringCompare",       _bridgeMsStringCompare, HostCapability.Pure);
	registerInPlaceHostFn("msStringCharCodeAt",    _bridgeMsStringCharCodeAt, HostCapability.Pure);
	registerInPlaceHostFn("msStringPadStart",      _bridgeMsStringPadStart, HostCapability.Pure);
	registerInPlaceHostFn("msStringPadEnd",        _bridgeMsStringPadEnd, HostCapability.Pure);
	registerInPlaceHostFn("msStringParseInt",      _bridgeMsStringParseInt, HostCapability.Pure);
	registerInPlaceHostFn("msStringParseFloat",    _bridgeMsStringParseFloat, HostCapability.Pure);
	registerInPlaceHostFn("msStringFromCodePoint", _bridgeMsStringFromCodePoint, HostCapability.Pure);
	registerInPlaceHostFn("msPerformanceNow",      _bridgeMsPerformanceNow);
	registerInPlaceHostFn("msTimeNow",             _bridgeMsTimeNow);
	registerHostFn("msProcessArgv",         _bridgeMsProcessArgv);
	registerHostFn("msProcessSetEnv",       _bridgeMsProcessSetEnv);
	registerHostFn("msProcessUnsetEnv",     _bridgeMsProcessUnsetEnv);
	registerHostFn("msProcessExecFile",     _bridgeMsProcessExecFile);
	registerHostFn("msProcessSpawnSyncArgv", _bridgeMsProcessSpawnSyncArgv);
	registerHostFn("msProcChildSpawn", _bridgeMsProcChildSpawn, HostCapability.ChildProcess);
	registerHostFn(
		"msProcChildSpawnEnv", _bridgeMsProcChildSpawnEnv,
		HostCapability.ChildProcess,
	);
	registerHostFn("msProcChildIsUnsupported", _bridgeMsProcChildIsUnsupported);
	registerHostFn("msProcChildPid", _bridgeMsProcChildPid);
	registerHostFn("msProcChildErrno", _bridgeMsProcChildErrno);
	registerHostFn("msProcChildWritten", _bridgeMsProcChildWritten);
	registerHostFn("msProcChildWrite", _bridgeMsProcChildWrite);
	registerHostFn("msProcChildCloseStdin", _bridgeMsProcChildCloseStdin);
	registerHostFn("msProcChildRead", _bridgeMsProcChildRead);
	registerHostFn("msProcChildTake", _bridgeMsProcChildTake);
	registerHostFn("msProcChildWait", _bridgeMsProcChildWait);
	registerHostFn("msProcChildKill", _bridgeMsProcChildKill);
	registerHostFn("msProcChildExitCode", _bridgeMsProcChildExitCode);
	registerHostFn("msProcChildSignal", _bridgeMsProcChildSignal);
	registerHostFn("msProcChildClose", _bridgeMsProcChildClose);
	registerHostFn("msProcChildFree", _bridgeMsProcChildFree);
	registerHostFn("msStdinDisableBuffering", _bridgeMsStdinDisableBuffering);
	registerHostFn("msReadLine",            _bridgeMsReadLine);
	registerInPlaceHostFn("msReadBytes",    _bridgeMsReadBytes);
	registerHostFn("msStdinHasData",        _bridgeMsStdinHasData);
	registerHostFn("msWriteStdout",        _bridgeMsWriteStdout);
	registerHostFn("msWriteStderr",        _bridgeMsWriteStderr);
	registerHostFn("msEprintln",           _bridgeMsEprintln);
	registerHostFn("msWarnln",             _bridgeMsEprintln);
	registerHostFn("msZipReaderOpen",       _bridgeMsZipReaderOpen);
	registerHostFn("msZipReaderCount",      _bridgeMsZipReaderCount);
	registerHostFn("msZipReaderEntryName",  _bridgeMsZipReaderEntryName);
	registerHostFn("msZipReaderEntrySize",  _bridgeMsZipReaderEntrySize);
	registerHostFn("msZipReaderEntryIsDir", _bridgeMsZipReaderEntryIsDir);
	registerHostFn("msZipReaderFind",       _bridgeMsZipReaderFind);
	registerHostFn("msZipReaderExtract",    _bridgeMsZipReaderExtract);
	registerHostFn("msZipReaderClose",      _bridgeMsZipReaderClose);
	registerHostFn("msZipWriterNew",        _bridgeMsZipWriterNew);
	registerHostFn("msZipWriterAdd",        _bridgeMsZipWriterAdd);
	registerHostFn("msZipWriterFinalize",   _bridgeMsZipWriterFinalize);
	registerHostFn("msZipWriterClose",      _bridgeMsZipWriterClose);
	registerHostFn("msCryptoInit",          _bridgeMsCryptoInit);
	registerHostFn("msCryptoCleanup",       _bridgeMsCryptoCleanup);
	registerHostFn("msCryptoHashString",    _bridgeMsCryptoHashString);
	registerInPlaceHostFn("msCryptoDigest", _bridgeMsCryptoDigest);
	registerInPlaceHostFn("msStringSplit",         _bridgeMsStringSplit, HostCapability.Pure);
	registerInPlaceHostFn("msNodeIsFloatLiteral", _bridgeMsNodeIsFloatLiteral, HostCapability.Pure);
	registerInPlaceHostFn("msNodeIntValue",        _bridgeMsNodeIntValue, HostCapability.Pure);
	registerInPlaceHostFn("msNodeFloatValue",      _bridgeMsNodeFloatValue, HostCapability.Pure);
	registerInPlaceHostFn("msNodeStringValue",     _bridgeMsNodeStringValue, HostCapability.Pure);
	registerInPlaceHostFn("msStringReplace",       _bridgeMsStringReplace, HostCapability.Pure);
	registerInPlaceHostFn("msStringReplaceAll",    _bridgeMsStringReplaceAll, HostCapability.Pure);
	registerInPlaceHostFn("msStringByteLength",    _bridgeMsStringByteLength, HostCapability.Pure);
	registerInPlaceHostFn("msStringByteAt",        _bridgeMsStringByteAt, HostCapability.Pure);
	registerInPlaceHostFn("std/core/struct.hashFarm", _bridgeStdHashFarm, HostCapability.Pure);
	registerInPlaceHostFn("msStringByteSlice",     _bridgeMsStringByteSlice, HostCapability.Pure);
	registerInPlaceHostFn("msStringByteIndexOf",   _bridgeMsStringByteIndexOf, HostCapability.Pure);
	registerInPlaceHostFn("msStringByteLastIndexOf", _bridgeMsStringByteLastIndexOf, HostCapability.Pure);
	registerInPlaceHostFn("msStringIsAscii",       _bridgeMsStringIsAscii, HostCapability.Pure);
	registerInPlaceHostFn("msUtf8Text",            _bridgeMsUtf8Text, HostCapability.Pure);
	registerInPlaceHostFn("msMemChr",              _bridgeMsMemChr, HostCapability.Pure);
	registerInPlaceHostFn("msMemEqAt",             _bridgeMsMemEqAt, HostCapability.Pure);
	registerInPlaceHostFn("msEqualMem",            _bridgeMsEqualMem, HostCapability.Pure);
	registerInPlaceHostFn("msMemMismatch",         _bridgeMsMemMismatch, HostCapability.Pure);
	registerInPlaceHostFn("msAsBytes",             _bridgeMsAsBytes, HostCapability.Pure);
	registerStringCallbacks();
	registerArrayKernels();
	registerBigIntKernels();
	registerInPlaceHostFn("msAsString",           _bridgeMsAsString, HostCapability.Pure);
	registerInPlaceHostFn("msRawString",           _bridgeMsRawString, HostCapability.Pure);
	// math (std/core/math externs + the float `%` / `**` lowerings)
	registerInPlaceHostFn("fabs",  _bridgeFabs, HostCapability.Pure);
	registerInPlaceHostFn("ceil",  _bridgeCeil, HostCapability.Pure);
	registerInPlaceHostFn("floor", _bridgeFloor, HostCapability.Pure);
	registerInPlaceHostFn("trunc", _bridgeTrunc, HostCapability.Pure);
	registerInPlaceHostFn("sqrt",  _bridgeSqrt, HostCapability.Pure);
	registerInPlaceHostFn("cbrt",  _bridgeCbrt, HostCapability.Pure);
	registerInPlaceHostFn("pow",   _bridgePow, HostCapability.Pure);
	registerInPlaceHostFn("msPowF64", _bridgePow, HostCapability.Pure);
	registerInPlaceHostFn("msPowI64", _bridgeMsPowI64, HostCapability.Pure);
	registerInPlaceHostFn("msPowI32", _bridgeMsPowI32, HostCapability.Pure);
	registerInPlaceHostFn("msPowU64", _bridgeMsPowU64, HostCapability.Pure);
	registerInPlaceHostFn("msPowU32", _bridgeMsPowU32, HostCapability.Pure);
	registerInPlaceHostFn("exp",   _bridgeExp, HostCapability.Pure);
	registerInPlaceHostFn("expm1", _bridgeExpm1, HostCapability.Pure);
	registerInPlaceHostFn("log",   _bridgeLog, HostCapability.Pure);
	registerInPlaceHostFn("log1p", _bridgeLog1p, HostCapability.Pure);
	registerInPlaceHostFn("log2",  _bridgeLog2, HostCapability.Pure);
	registerInPlaceHostFn("log10", _bridgeLog10, HostCapability.Pure);
	registerInPlaceHostFn("hypot", _bridgeHypot, HostCapability.Pure);
	registerInPlaceHostFn("sin",   _bridgeSin, HostCapability.Pure);
	registerInPlaceHostFn("cos",   _bridgeCos, HostCapability.Pure);
	registerInPlaceHostFn("tan",   _bridgeTan, HostCapability.Pure);
	registerInPlaceHostFn("asin",  _bridgeAsin, HostCapability.Pure);
	registerInPlaceHostFn("acos",  _bridgeAcos, HostCapability.Pure);
	registerInPlaceHostFn("atan",  _bridgeAtan, HostCapability.Pure);
	registerInPlaceHostFn("atan2", _bridgeAtan2, HostCapability.Pure);
	registerInPlaceHostFn("sinh",  _bridgeSinh, HostCapability.Pure);
	registerInPlaceHostFn("cosh",  _bridgeCosh, HostCapability.Pure);
	registerInPlaceHostFn("tanh",  _bridgeTanh, HostCapability.Pure);
	registerInPlaceHostFn("asinh", _bridgeAsinh, HostCapability.Pure);
	registerInPlaceHostFn("acosh", _bridgeAcosh, HostCapability.Pure);
	registerInPlaceHostFn("atanh", _bridgeAtanh, HostCapability.Pure);
	registerInPlaceHostFn("fmod",  _bridgeFmod, HostCapability.Pure);
	markHostRegistryInitialized();
}

// --- Tests ---

import { raiserInt, raiserFloat, raiserConstString, RaiserValueKind } from "../../raiser/value";
import { lookupHost, _resetHostRegistryForTests, takeHostRaise } from "../../raiser/hostRegistry";
import { int64Bits } from "../../utils/stdBackport";
import { mulOverflowsI64, execModule } from "../../raiser/vm";
import { RaiserOpcode, RaiserInstruction, raiserABC, raiserABx } from "../../raiser/bytecode";
import { makeTestModule } from "../../raiser/module";

function callHost(name: string, args: RaiserValue[]): RaiserVM {
	const code: RaiserInstruction[] = [];
	const consts: RaiserValue[] = [raiserConstString(name)];
	for (let i = 0; i < args.length; i = i + 1) {
		code.push(raiserABx(RaiserOpcode.LoadConst, i + 1, i + 1));
		consts.push(args[i]);
	}
	code.push(raiserABC(RaiserOpcode.CallHost, 0, 0, args.length));
	code.push(raiserABC(RaiserOpcode.Halt, 0, 0, 0));
	return execModule(makeTestModule(code, consts));
}

function callHostText(name: string, args: RaiserValue[]): string {
	const vm = callHost(name, args);
	if (vm.error != "") throw new Error(vm.error);
	return heapStringText(vm.arrayHeap, vm.exitValue);
}

test "ensureHostTableLoaded registers fs predicates" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	assert lookupHost("msFsExists") != null;
	assert lookupHost("msFsRealPath") != null;
	assert lookupHost("msFsIsFile") != null;
	assert lookupHost("msFsIsDir") != null;
}

test "ensureHostTableLoaded registers process accessors" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	assert lookupHost("msProcessCwd") != null;
	assert lookupHost("msProcessPlatform") != null;
	assert lookupHost("msProcessArch") != null;
	assert lookupHost("msProcessGetEnv") != null;
}

test "string padding bridges preserve native semantics" {
	ensureHostTableLoaded();
	setActiveHostHeaps(createStructHeap(), createArrayHeap());
	assert lookupHost("msStringPadStart") != null;
	assert lookupHost("msStringPadEnd") != null;
	assert callHostText("msStringPadStart", [raiserConstString("42"), raiserInt(6), raiserConstString("0")]) == "000042";
	assert callHostText("msStringPadEnd", [raiserConstString("42"), raiserInt(5), raiserConstString("ab")]) == "42aba";
	assert callHostText("msStringPadStart", [raiserConstString("é"), raiserInt(3), raiserConstString("x")]) == "xxé";
	assert callHostText("msStringPadEnd", [raiserConstString("same"), raiserInt(7), raiserConstString("")]) == "same";
}

test "the enum range bridge raises for a float outside the range without converting it" {
	ensureHostTableLoaded();
	assert callHost("msCheckRangeI32", [raiserFloat(0.0 / 0.0), raiserInt(0), raiserInt(2)]).error == "value NaN not in range 0 .. 2";
	assert callHost("msCheckRangeI32", [raiserFloat(1e300), raiserInt(0), raiserInt(2)]).error.endsWith(" not in range 0 .. 2");
	const inRange = callHost("msCheckRangeI32", [raiserFloat(2.5), raiserInt(0), raiserInt(2)]);
	assert inRange.error == "", inRange.error;
	assert inRange.exitValue.kind == RaiserValueKind.Int && inRange.exitValue.intVal == 2;
}

test "the enum range bridge for a uint64 source reports a value past int64 unsigned and refuses it" {
	ensureHostTableLoaded();
	assert callHost("msCheckRangeI32FromU64", [raiserInt(int64Bits(9223372036854775808)), raiserInt(0), raiserInt(2)]).error == "value 9223372036854775808 not in range 0 .. 2";
	assert callHost("msCheckRangeI32FromU64", [raiserInt(int64Bits(18446744073709551613)), raiserInt(-5), raiserInt(1)]).error == "value 18446744073709551613 not in range -5 .. 1";
	const inRange = callHost("msCheckRangeI32FromU64", [raiserInt(1), raiserInt(-5), raiserInt(1)]);
	assert inRange.error == "", inRange.error;
	assert inRange.exitValue.intVal == 1;
	assert callHost("msCheckRangeI32FromU64", [raiserInt(2), raiserInt(-5), raiserInt(1)]).error == "value 2 not in range -5 .. 1";
}

test "ensureHostTableLoaded is idempotent" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	ensureHostTableLoaded();  // should not duplicate
	// We don't assert the count strictly — registerHostFn deduplicates on
	// re-registration anyway. Just confirm initialized flag is set.
	assert isHostRegistryInitialized();
}

test "bridgeMsFsRealPath resolves the working directory to itself" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	const fn = lookupHost("msFsRealPath")!.fn;
	assert fn != null;
	const result = fn([raiserConstString(".")]);
	assert result.kind == RaiserValueKind.String;
	assert unboxString(result) == cwd();
}

test "bridgeMsFsRealPath returns empty for a missing path" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	const fn = lookupHost("msFsRealPath")!.fn;
	assert fn != null;
	const result = fn([raiserConstString("/tmp/__nope_xyz__")]);
	assert result.kind == RaiserValueKind.String;
	assert unboxString(result) == "";
}

test "bridgeMsFsExists returns 1 for present file" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	const fn = lookupHost("msFsExists")!.fn;
	assert fn != null;
	// README.md is in the project root, where tests run from.
	const result = fn([raiserConstString("README.md")]);
	assert result.kind == RaiserValueKind.Int;
	assert result.intVal == 1;
}

test "bridgeMsFsExists returns 0 for missing file" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	const fn = lookupHost("msFsExists")!.fn;
	const result = fn([raiserConstString("/tmp/__definitely_does_not_exist_xyz123__")]);
	assert result.kind == RaiserValueKind.Int;
	assert result.intVal == 0;
}

test "bridgeMsProcessCwd returns non-empty string" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	const fn = lookupHost("msProcessCwd")!.fn;
	const result = fn([]);
	assert result.kind == RaiserValueKind.String;
	assert unboxString(result).length > 0;
}

test "bridgeMsProcessPlatform returns known platform" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	const fn = lookupHost("msProcessPlatform")!.fn;
	const result = fn([]);
	assert result.kind == RaiserValueKind.String;
	// Platform is one of darwin/linux/windows in practice.
	assert unboxString(result).length > 0;
}

test "bridgeMsProcessGetEnv missing var returns empty" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	const fn = lookupHost("msProcessGetEnv")!.fn;
	const result = fn([raiserConstString("__NEVER_SET_VAR_QWXTY__")]);
	assert result.kind == RaiserValueKind.String;
	assert unboxString(result) == "";
}

// --- Phase 7 bridges: errno-poll pattern ---

test "bridgeMsFsReadFile present file + errno 0" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	const read = lookupHost("msFsReadFile")!.fn;
	const errno = lookupHost("msFsLastErrno")!.fn;
	const r = read([raiserConstString("README.md")]);
	assert r.kind == RaiserValueKind.String;
	assert unboxString(r).length > 0;
	const e = errno([]);
	assert e.intVal == 0;
}

test "bridgeMsFsReadFile missing file + non-zero errno" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	const read = lookupHost("msFsReadFile")!.fn;
	const errno = lookupHost("msFsLastErrno")!.fn;
	const r = read([raiserConstString("/tmp/__missing_xyz__")]);
	assert unboxString(r) == "";
	const e = errno([]);
	assert e.intVal != 0;
}

test "bridgeMsFsReadDirEntries returns newline-separated entries" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	const fn = lookupHost("msFsReadDirEntries")!.fn;
	const r = fn([raiserConstString(".")]);
	assert r.kind == RaiserValueKind.String;
	assert unboxString(r).length > 0;
}

test "bridgeMsProcessSpawnSync registered" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	// Just verify registration. Actual subprocess invocation is brittle inside
	// the test harness — covered by end-to-end @comptime smoke tests in
	// src/compiler/meta/comptime.ms where the bridge is exercised via the VM.
	assert lookupHost("msProcessSpawnSync") != null;
}

test "bridgeMsProcSpawnGet* state slots registered" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	assert lookupHost("msProcSpawnGetOk") != null;
	assert lookupHost("msProcSpawnGetPipeOk") != null;
	assert lookupHost("msProcSpawnGetExitCode") != null;
	assert lookupHost("msProcSpawnGetSignal") != null;
	assert lookupHost("msProcSpawnGetStderr") != null;
}

// --- Audit-driven regression tests ---

test "I4 regression: msFsReadDirEntries missing path sets errno" {
	_resetHostRegistryForTests();
	_resetBridgeStateForTests();
	ensureHostTableLoaded();
	const readDirFn = lookupHost("msFsReadDirEntries")!.fn;
	const errno = lookupHost("msFsLastErrno")!.fn;
	const r = readDirFn([raiserConstString("/tmp/__never_exists_qpqp__")]);
	assert r.kind == RaiserValueKind.String;
	assert unboxString(r) == "";
	// Bug pre-fix: errno would be 0 here, masking failure
	assert errno([]).intVal != 0;
}

test "I4 regression: msFsReadDirEntries on file (not dir) sets errno" {
	_resetHostRegistryForTests();
	_resetBridgeStateForTests();
	ensureHostTableLoaded();
	const readDirFn = lookupHost("msFsReadDirEntries")!.fn;
	const errno = lookupHost("msFsLastErrno")!.fn;
	readDirFn([raiserConstString("README.md")]);  // path exists but is a file
	assert errno([]).intVal != 0;
}

test "I5 regression: bridge state reset clears errno" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	const read = lookupHost("msFsReadFile")!.fn;
	const errno = lookupHost("msFsLastErrno")!.fn;
	read([raiserConstString("/tmp/__missing_yyy__")]);
	assert errno([]).intVal != 0;
	_resetBridgeStateForTests();
	assert errno([]).intVal == 0;
}

test "errno cleared after successful read following failed read" {
	_resetHostRegistryForTests();
	_resetBridgeStateForTests();
	ensureHostTableLoaded();
	const read = lookupHost("msFsReadFile")!.fn;
	const errno = lookupHost("msFsLastErrno")!.fn;
	read([raiserConstString("/tmp/__missing_first__")]);
	assert errno([]).intVal != 0;
	read([raiserConstString("README.md")]);  // success — should clear errno
	assert errno([]).intVal == 0;
}

test "spawn state preserved across getter calls" {
	_resetHostRegistryForTests();
	_resetBridgeStateForTests();
	ensureHostTableLoaded();
	// Multi-getter sequence should return consistent state (no clobbering
	// between getOk → getExitCode → getStderr).
	const okFn = lookupHost("msProcSpawnGetOk")!.fn;
	const exitFn = lookupHost("msProcSpawnGetExitCode")!.fn;
	const stderrFn = lookupHost("msProcSpawnGetStderr")!.fn;
	// Initial state after reset
	assert okFn([]).intVal == 0;
	assert exitFn([]).intVal == 0;
	assert unboxString(stderrFn([])) == "";
}

test "closeHostChildren ends every child left open and the table refuses handles it did not issue" {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	const spawnFn = lookupHost("msProcChildSpawn")!.fn;
	const pidFn = lookupHost("msProcChildPid")!.fn;
	const heap = activeHostArrayHeap()!;
	const argv = heapAllocArray(heap);
	heapArrayPush(heap, argv, heapAllocStoredString(heap, "1000"));
	const id = spawnFn([raiserConstString(platform == "windows" ? "sleep" : "/bin/sleep"), raiserArray(argv), raiserConstString(""), raiserInt(0)]);
	assert id.intVal == _children.length;
	const pid = pidFn([id]).intVal;
	assert pid > 0;
	assert takeHostRaise() == null;
	pidFn([raiserInt(id.intVal + 1)]);
	assert takeHostRaise()!.contains("is not a live child");
	closeHostChildren();
	const listing = platform == "windows"
		? execFileResult("tasklist", ["/FI", `PID eq ${pid}`, "/NH", "/FO", "CSV"]).output.contains(`","${pid}",`) ? "running" : ""
		: execFileResult("/bin/ps", ["-o", "stat=", "-p", `${pid}`]).output.trim();
	assert listing == "";
	pidFn([id]);
	assert takeHostRaise()!.contains("is not a live child");
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
		if (x == name) return true;
	}
	return false;
}

test "rms extern closure: declared externs are bridged, intercepted, or listed dead" {
	const root = resolveRuntimeDir();
	const stdPath = root != "" ? join(root, "std") : "std";
	const rmsFiles = [
		join(stdPath, "core/string/index.rms"),
		join(stdPath, "core/string/editNative.rms"),
		join(stdPath, "core/string/bytes.rms"),
		join(stdPath, "core/array/index.rms"),
		join(stdPath, "process/child.rms"),
		join(stdPath, "core/buffer/index.rms"),
		join(stdPath, "core/date/index.rms"),
	];
	// Names the Raiser codegen intercepts to opcodes before CallHost.
	const intercepted: string[] = [
		"msStringEquals", "msStringCompareLt", "msStringCompareLe", // string == / < / <=
		"msStringCharAt", "msStringSlice",                // StrCharAt / StrSlice
		"&msGenericArrayPush",                            // ArrayPush
		"&msGenericArraySetLen",                          // ArraySetLen
	];
	// Deliberately dead — each needs work before it can come off this list.
	const knownDead: string[] = [
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
			const covered = lookupHost(name) != null
				|| nameListed(intercepted, name)
				|| nameListed(knownDead, name);
			assert covered, `${f}: ${name}`;
		}
	}
	assert checked >= 14;
}

test "cms extern closure: declared externs are bridged, intercepted, or listed unserved" {
	const root = resolveRuntimeDir();
	const stdPath = root != "" ? join(root, "std") : "std";
	const cmsFiles = [
		join(stdPath, "core/string/index.cms"),
		join(stdPath, "core/string/bytes.cms"),
		join(stdPath, "core/array/index.cms"),
	];
	const intercepted: string[] = [
		"msStringEquals", "msStringCompareLt", "msStringCompareLe", "msStringCharAt", "msStringSlice", "msStringCharCodeAt",
		"&msNumberArrayPush", "&msStringArrayPush", "&msUint8ArrayPush", "&msGenericArrayPush",
		"&msNumberArraySetLen", "&msStringArraySetLen", "&msGenericArraySetLen",
	];
	const unserved: string[] = [
		"&msGenericArrayCapacity", "&msNumberArrayCapacity", "&msStringArrayCapacity", "msStringCapacity",
		"&msGenericArrayRotate", "&msGenericArraySwap", "&msGenericArraySwapWith",
		"&msGenericArrayPop", "&msNumberArrayPop", "&msStringArrayPop",
		"&msNumberArrayShift", "&msStringArrayShift",
		"&msNumberArrayConcat", "&msStringArrayConcat",
		"&msNumberArrayFill", "&msStringArrayFill",
		"&msNumberArrayReverse", "&msStringArrayReverse",
		"&msNumberArraySlice", "&msStringArraySlice", "msBytesSlice",
		"&msNumberArraySort", "&msStringArraySort",
		"&msNumberArraySplice", "&msNumberArraySplice3", "&msStringArraySplice", "&msStringArraySplice3",
		"&msRefArraySplice3", "&msUint8ArraySplice3",
		"&msStringAppend", "&msStringSetLength", "&msStringSetSlice", "msStringSetSlice", "&msStringStripInPlace",
		"msStringNewUninit", "msMemCopyTo", "memcpy",
	];
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	let checked = 0;
	for (const f of cmsFiles) {
		const r = readFile(f);
		assert r.ok;
		if (!r.ok) continue;
		for (const name of scanRmsExternNames(r.value)) {
			checked = checked + 1;
			const served = lookupHost(name) != null || nameListed(intercepted, name);
			assert served || nameListed(unserved, name), `${f}: ${name}`;
			if (nameListed(unserved, name)) assert lookupHost(name) == null, `${f}: ${name} is bridged now, drop it from the unserved list`;
		}
	}
	assert checked >= 60;
}

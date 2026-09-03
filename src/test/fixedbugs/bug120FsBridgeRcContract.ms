// bug120 — the Raiser fs host bridges inverted the C return-code contract
//
// Symptom:    std/fs mutating calls inside @comptime reported failure while
//             the operation HAD succeeded — `mkdir(d)` returned
//             Result.err(... "mkdir failed") with the directory already on
//             disk, same for writeFile. Callers either aborted or retried on
//             a side effect that already happened. appendFile additionally
//             truncated: the bridge dropped the fopen-mode argument.
// Root cause: src/compiler/meta/hostTable.ms — `_fsResultToInt` returned 0 on
//             success / 1 on failure, but the C ABI it claimed to mirror is
//             the opposite (runtime/fs/posix.c, runtime/fs/windows.c return
//             1.0 on success) and the std wrappers test for exactly that
//             (`if (msFsMkdir(path) === 1)`, std/fs/index.cms). The success
//             path also cleared errno, so the wrapper's errno fallback found
//             0 and synthesized a bogus writeFailed(...) message.
//             `_bridgeMsFsWriteFileMode` ignored args[2] (the mode), and
//             msFsChmod / msFsIsExecutable had no bridge at all.
// Fix:        `_fsResultToInt` returns 1 = ok / 0 = failure; the
//             writeFileMode bridge dispatches on the mode argument;
//             `_bridgeMsFsChmod` + `_bridgeMsFsIsExecutable` added and
//             registered, closing the fs surface (14/14 externs bridged).
//
// Tier note: this exercises the SOURCE hostTable, not @comptime in the
// compiler that builds this binary — a bridge bug must go red before any
// bootstrap step, not after one.

import { ensureHostTableLoaded, _resetBridgeStateForTests } from "../../compiler/meta/hostTable";
import { lookupHostFn, _resetHostRegistryForTests } from "../../raiser/hostRegistry";
import { raiserString, raiserInt, RaiserValueKind } from "../../raiser/value";
import { exists, isDir, readFile, writeFile, removeAll, join } from "std/fs";
import { env } from "std/process";

// OS temp dir without std/os's C header (same shape as package/walker.ms).
function bug120TmpDir(): string {
	const t = env.get("TMP");
	if (t !== "") return t;
	const t2 = env.get("TEMP");
	if (t2 !== "") return t2;
	const t3 = env.get("TMPDIR");
	if (t3 !== "") return t3;
	return "/tmp";
}

function bug120Fresh(name: string): string {
	const p = join(bug120TmpDir(), name);
	removeAll(p);
	return p;
}

function bug120Ready(): void {
	_resetHostRegistryForTests();
	_resetBridgeStateForTests();
	ensureHostTableLoaded();
}

test "bug120: mkdir bridge reports success as 1, matching the C ABI" {
	bug120Ready();
	const dir = bug120Fresh("msbug120mkdir");
	const mkdirFn = lookupHostFn("msFsMkdir");
	const errno = lookupHostFn("msFsLastErrno");
	const rv = mkdirFn([raiserString(dir)]);
	assert rv.kind === RaiserValueKind.Int;
	// Pre-fix: 0 here — while the directory below already existed.
	assert rv.intVal === 1;
	assert errno([]).intVal === 0;
	assert exists(dir) && isDir(dir);
	removeAll(dir);
}

test "bug120: mkdir bridge reports failure as 0 with errno set" {
	bug120Ready();
	const mkdirFn = lookupHostFn("msFsMkdir");
	const errno = lookupHostFn("msFsLastErrno");
	const bad = join(bug120TmpDir(), "msbug120missing/deep/child");
	const rv = mkdirFn([raiserString(bad)]);
	assert rv.intVal === 0;
	assert errno([]).intVal !== 0;
	assert !exists(bad);
}

test "bug120: writeFileMode bridge reports success as 1 and writes the bytes" {
	bug120Ready();
	const path = bug120Fresh("msbug120write.txt");
	const writeFn = lookupHostFn("msFsWriteFileMode");
	const errno = lookupHostFn("msFsLastErrno");
	const rv = writeFn([raiserString(path), raiserString("hello"), raiserString("wb")]);
	assert rv.intVal === 1;
	assert errno([]).intVal === 0;
	const back = readFile(path);
	assert back.ok;
	if (back.ok) assert back.value === "hello";
	removeAll(path);
}

test "bug120: writeFileMode bridge honors the append mode instead of truncating" {
	bug120Ready();
	const path = bug120Fresh("msbug120append.txt");
	const writeFn = lookupHostFn("msFsWriteFileMode");
	assert writeFn([raiserString(path), raiserString("aa"), raiserString("wb")]).intVal === 1;
	// Pre-fix: the mode argument was dropped, so this overwrote "aa".
	assert writeFn([raiserString(path), raiserString("bb"), raiserString("ab")]).intVal === 1;
	const back = readFile(path);
	assert back.ok;
	if (back.ok) assert back.value === "aabb";
	removeAll(path);
}

test "bug120: msFsChmod is bridged and reports success as 1" {
	bug120Ready();
	const path = bug120Fresh("msbug120chmod.txt");
	assert writeFile(path, "x").ok;
	const chmodFn = lookupHostFn("msFsChmod");
	// Pre-fix: null — the extern existed in std/fs but had no bridge, so a
	// @comptime chmod died with "Unknown host function: msFsChmod".
	assert chmodFn !== null;
	const rv = chmodFn([raiserString(path), raiserInt(420)]);  // 0644
	assert rv.kind === RaiserValueKind.Int;
	assert rv.intVal === 1;
	removeAll(path);
}

test "bug120: msFsIsExecutable is bridged and answers 0 for a missing path" {
	bug120Ready();
	const execFn = lookupHostFn("msFsIsExecutable");
	assert execFn !== null;
	const rv = execFn([raiserString(join(bug120TmpDir(), "msbug120nosuchbinary"))]);
	assert rv.kind === RaiserValueKind.Int;
	assert rv.intVal === 0;
}

// Raiser VM — Host function table (seed)
//
// Registers wrappers for the std/* native externs Raiser can call from
// bytecode via the `CallHost` opcode. Each wrapper unboxes RaiserValue
// arguments, calls the underlying MS-level std function (which dispatches
// to a Bun shim during bootstrap, or to a C native after self-host), and
// boxes the return.
//
// SCOPE (seed): only simple scalar return types (boolean, number, string).
// Natives returning Result<T,E>, arrays, or objects need heap-aware bridges
// and are deferred to a follow-up extension (see docs/RAISER-CALLHOST.md
// Phase 3 follow-up notes).
//
// Naming: registry key matches the C extern name (`msFsExists`, etc.) — that
// is what `Symbol.nativeName` carries through to codegen in Phase 4. The
// bridge itself can call any equivalent MS-level wrapper available in the
// current host (Bun shim today, C runtime after self-host).

import { RaiserValue } from "../../raiser/value";
import { registerHostFn, markHostRegistryInitialized, isHostRegistryInitialized } from "../../raiser/hostRegistry";
import { RaiserHostFn } from "../../raiser/marshal";
import {
	unboxString, unboxInt,
	boxString, boxInt,
} from "../../raiser/marshal";

// Bun shim-backed std/* surface. After self-host the same imports resolve
// to .ms-side stdlib (which itself calls into the C runtime).
import { exists, isFile, isDir, fileSize } from "std/fs";
import { cwd, platform, env } from "std/process";

// --- Bridges (simple scalar I/O) ---

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

function _bridge_msProcessCwd(args: RaiserValue[]): RaiserValue {
	return boxString(cwd());
}

function _bridge_msProcessPlatform(args: RaiserValue[]): RaiserValue {
	return boxString(platform);
}

function _bridge_msProcessGetEnv(args: RaiserValue[]): RaiserValue {
	return boxString(env.get(unboxString(args[0])));
}

// --- Registry init ---
// Idempotent: subsequent calls are no-ops. Phase 5 invokes this on first
// @comptime block entry.

export function ensureHostTableLoaded(): void {
	if (isHostRegistryInitialized()) return;

	registerHostFn("msFsExists",        _bridge_msFsExists);
	registerHostFn("msFsIsFile",        _bridge_msFsIsFile);
	registerHostFn("msFsIsDir",         _bridge_msFsIsDir);
	registerHostFn("msFsFileSize",      _bridge_msFsFileSize);
	registerHostFn("msProcessCwd",      _bridge_msProcessCwd);
	registerHostFn("msProcessPlatform", _bridge_msProcessPlatform);
	registerHostFn("msProcessGetEnv",   _bridge_msProcessGetEnv);

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

// Process Errors — Unified error type for subprocess operations.
// Used by exec(), and future spawn/execFile/kill operations.
// Follows the flat-interface pattern from std/io/errors.ms.

// ===== Error Kind =====

export enum ProcessErrorKind {
	SpawnFailed,       // fork()/CreateProcess() OS-level failure
	NotFound,          // command not on PATH (ENOENT) — distinguish from spawn-other
	NonZeroExit,       // command ran, exited with non-zero status
	SignalTerminated,  // POSIX: child killed by signal (SIGTERM, SIGSEGV, etc.)
	PipeError,         // failed reading stdout/stderr from child
	Unknown,           // catch-all for unmapped conditions
}

// ===== Error Interface =====
// Flat shape — matches std/io/errors.ms IoError pattern. Per-variant fields
// are present uniformly; irrelevant ones carry 0 or "" depending on variant.
// Caller checks `kind` then reads the relevant fields.
//
// `output` / `errorOutput` are the captured stdout/stderr text from the child
// process. NOT named `stdout`/`stderr` because those collide with Windows
// `<stdio.h>` preprocessor macros at C codegen time (`stdout` expands to
// `(*__acrt_iob_func(1))`), breaking the generated struct on Win cross-compile.

export interface ProcessError {
	kind: ProcessErrorKind;
	command: string;       // command that was attempted
	exitCode: number;      // 0 if N/A (SpawnFailed, SignalTerminated)
	signal: number;        // 0 if not signal-terminated
	output: string;        // "" if pipe failed before any data captured
	errorOutput: string;   // "" if pipe failed before any data captured
	message: string;
}

// ===== Constructors =====

export function processError(kind: ProcessErrorKind, command: string, msg: string): ProcessError {
	return {
		kind,
		command,
		exitCode: 0,
		signal: 0,
		output: "",
		errorOutput: "",
		message: msg,
	};
}

export function spawnFailed(command: string, reason: string): ProcessError {
	return {
		kind: ProcessErrorKind.SpawnFailed,
		command,
		exitCode: 0,
		signal: 0,
		output: "",
		errorOutput: "",
		message: `spawn failed: ${reason}`,
	};
}

export function notFound(command: string): ProcessError {
	return {
		kind: ProcessErrorKind.NotFound,
		command,
		exitCode: 0,
		signal: 0,
		output: "",
		errorOutput: "",
		message: `command not found: ${command}`,
	};
}

export function nonZeroExit(command: string, exitCode: number, output: string, errorOutput: string): ProcessError {
	return {
		kind: ProcessErrorKind.NonZeroExit,
		command,
		exitCode,
		signal: 0,
		output,
		errorOutput,
		message: `command exited with status ${exitCode}: ${command}`,
	};
}

export function signalTerminated(command: string, signal: number, output: string, errorOutput: string): ProcessError {
	return {
		kind: ProcessErrorKind.SignalTerminated,
		command,
		exitCode: 0,
		signal,
		output,
		errorOutput,
		message: `command terminated by signal ${signal}: ${command}`,
	};
}

export function pipeError(command: string, reason: string): ProcessError {
	return {
		kind: ProcessErrorKind.PipeError,
		command,
		exitCode: 0,
		signal: 0,
		output: "",
		errorOutput: "",
		message: `pipe error: ${reason}`,
	};
}

// ===== Classification =====

export function isNotFound(e: ProcessError): boolean {
	return e.kind == ProcessErrorKind.NotFound;
}

export function isNonZeroExit(e: ProcessError): boolean {
	return e.kind == ProcessErrorKind.NonZeroExit;
}

export function isRetryable(e: ProcessError): boolean {
	// Spawn failures may be transient (out of PIDs, etc.); non-zero exits are
	// deterministic (the command itself failed) and not worth retrying.
	return e.kind == ProcessErrorKind.SpawnFailed;
}

// ===== Tests =====

test "spawnFailed constructor" {
	const e = spawnFailed("ls", "fork() returned -1");
	assert e.kind == ProcessErrorKind.SpawnFailed;
	assert e.command == "ls";
	assert e.exitCode == 0;
	assert e.signal == 0;
}

test "notFound constructor" {
	const e = notFound("nonexistent-cmd");
	assert e.kind == ProcessErrorKind.NotFound;
	assert e.command == "nonexistent-cmd";
}

test "nonZeroExit captures output" {
	const e = nonZeroExit("ls /nope", 2, "", "ls: /nope: No such file or directory\n");
	assert e.kind == ProcessErrorKind.NonZeroExit;
	assert e.exitCode == 2;
	assert e.errorOutput.indexOf("No such file") >= 0;
	assert e.signal == 0;
}

test "signalTerminated has signal number" {
	const e = signalTerminated("sleep 5", 9, "", "");
	assert e.kind == ProcessErrorKind.SignalTerminated;
	assert e.signal == 9;
	assert e.exitCode == 0;
}

test "pipeError has empty captures" {
	const e = pipeError("ls", "read() failed");
	assert e.kind == ProcessErrorKind.PipeError;
	assert e.output == "";
	assert e.errorOutput == "";
}

test "isNotFound classification" {
	assert isNotFound(notFound("x"));
	assert !isNotFound(nonZeroExit("y", 1, "", ""));
}

test "isRetryable — only spawn failures" {
	assert isRetryable(spawnFailed("x", "transient"));
	assert !isRetryable(nonZeroExit("y", 1, "", ""));
	assert !isRetryable(notFound("z"));
}

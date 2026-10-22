// Process Errors — Unified error type for subprocess operations.
// Used by exec(), execFile*() and spawn().
// Follows the flat-interface pattern from std/io/errors.ms.

// ===== Error Kind =====

export enum ProcessErrorKind {
	SpawnFailed,       // fork()/CreateProcess() OS-level failure
	NotFound,          // command not on PATH (ENOENT) — distinguish from spawn-other
	NonZeroExit,       // command ran, exited with non-zero status
	SignalTerminated,  // POSIX: child killed by signal (SIGTERM, SIGSEGV, etc.)
	PipeError,         // failed reading stdout/stderr from child
	Unknown,           // catch-all for unmapped conditions
	Timeout,           // a deadline passed; the child keeps running
	PipeClosed,        // the pipe is closed: the child closed stdin, or the handle was closed
	OutputOverflow,    // a stream buffer filled while unread; its bytes are kept
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
	exitCode: int32;       // 127 not found, 126 found but cannot start (shell convention), 0 if N/A
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
		exitCode: 127,
		signal: 0,
		output: "",
		errorOutput: "",
		message: `command not found: ${command}`,
	};
}

export function startFailed(command: string, code: string): ProcessError {
	const missing = code == "ENOENT";
	return {
		kind: missing ? ProcessErrorKind.NotFound : ProcessErrorKind.SpawnFailed,
		command,
		exitCode: missing ? 127 : 126,
		signal: 0,
		output: "",
		errorOutput: "",
		message: `spawnSync ${command} ${code}`,
	};
}

export function errnoName(errnum: int32): string {
	return match (errnum) {
		1 => "EPERM",
		2 => "ENOENT",
		7 => "E2BIG",
		8 => "ENOEXEC",
		12 => "ENOMEM",
		13 => "EACCES",
		20 => "ENOTDIR",
		4028 => "EFTYPE",
		_ => `UNKNOWN (errno ${errnum})`,
	};
}

export function nonZeroExit(command: string, exitCode: int32, output: string, errorOutput: string): ProcessError {
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

export function timedOut(command: string, what: string): ProcessError {
	return processError(ProcessErrorKind.Timeout, command, `timed out: ${what}`);
}

export function pipeClosed(command: string, what: string): ProcessError {
	return processError(ProcessErrorKind.PipeClosed, command, `pipe closed: ${what}`);
}

export function outputOverflow(command: string, stream: string): ProcessError {
	return processError(
		ProcessErrorKind.OutputOverflow,
		command,
		`${stream} filled its buffer unread; the child is blocked until it is read`,
	);
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

test "startFailed names the program and the start error" {
	const missing = startFailed("taskset", errnoName(2));
	assert missing.kind == ProcessErrorKind.NotFound && missing.exitCode == 127;
	assert missing.message == "spawnSync taskset ENOENT";
	const denied = startFailed("/tmp", errnoName(13));
	assert denied.kind == ProcessErrorKind.SpawnFailed && denied.exitCode == 126;
	assert denied.message == "spawnSync /tmp EACCES";
	assert errnoName(4028) == "EFTYPE";
	assert errnoName(79) == "UNKNOWN (errno 79)";
	assert errnoName(99) == "UNKNOWN (errno 99)";
}

test "child-process kinds carry their kind and command" {
	assert timedOut("cat", "wait after 100 ms").kind == ProcessErrorKind.Timeout;
	assert pipeClosed("cat", "stdin").kind == ProcessErrorKind.PipeClosed;
	const full = outputOverflow("yes", "stdout");
	assert full.kind == ProcessErrorKind.OutputOverflow && full.command == "yes";
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

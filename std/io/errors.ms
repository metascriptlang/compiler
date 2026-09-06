// I/O Errors — Unified error types for fs, io, and process modules.
// Zero dependencies. Self-contained enum + interface + constructors.
// Follows the pattern from std/http/errors.ms and std/core/crypto/errors.ms.

// ===== Error Kind =====

export enum IoErrorKind {
	NotFound,          // ENOENT — file or directory does not exist
	PermissionDenied,  // EACCES — insufficient permissions
	AlreadyExists,     // EEXIST — file already exists (exclusive create)
	IsDirectory,       // EISDIR — expected file, got directory
	NotDirectory,      // ENOTDIR — expected directory, got file
	ReadFailed,        // fread error or partial read
	WriteFailed,       // fwrite error or partial write
	EndOfInput,        // stdin EOF
	Unknown,           // catch-all for unmapped errno values
}

// ===== Error Interface =====

export interface IoError {
	kind: IoErrorKind;
	path: string;       // affected file path ("" for stdin/stdout)
	message: string;
}

// ===== Constructors =====

export function ioError(kind: IoErrorKind, path: string, msg: string): IoError {
	return { kind, path, message: msg };
}

export function notFound(path: string): IoError {
	return { kind: IoErrorKind.NotFound, path, message: `no such file or directory: ${path}` };
}

export function permissionDenied(path: string): IoError {
	return { kind: IoErrorKind.PermissionDenied, path, message: `permission denied: ${path}` };
}

export function alreadyExists(path: string): IoError {
	return { kind: IoErrorKind.AlreadyExists, path, message: `already exists: ${path}` };
}

export function isDirectory(path: string): IoError {
	return { kind: IoErrorKind.IsDirectory, path, message: `is a directory: ${path}` };
}

export function notDirectory(path: string): IoError {
	return { kind: IoErrorKind.NotDirectory, path, message: `not a directory: ${path}` };
}

export function readFailed(path: string, msg: string): IoError {
	return { kind: IoErrorKind.ReadFailed, path, message: msg };
}

export function writeFailed(path: string, msg: string): IoError {
	return { kind: IoErrorKind.WriteFailed, path, message: msg };
}

export function endOfInput(): IoError {
	return { kind: IoErrorKind.EndOfInput, path: "", message: "end of input" };
}

// ===== Errno Mapping =====
// Maps POSIX errno values to IoErrorKind. Called from .cms wrappers
// after C functions set the errno via msFsLastErrno()/msProcessLastErrno().

export function ioErrorFromErrno(errnum: number, path: string): IoError {
	// POSIX errno constants (portable across macOS/Linux)
	return match (errnum) {
		2 => notFound(path),           // ENOENT
		13 => permissionDenied(path),  // EACCES
		17 => alreadyExists(path),     // EEXIST
		20 => notDirectory(path),      // ENOTDIR
		21 => isDirectory(path),       // EISDIR
		_ => ioError(IoErrorKind.Unknown, path, `I/O error (errno ${errnum}): ${path}`),
	};
}

// ===== Classification =====

export function isNotFound(e: IoError): boolean {
	return e.kind == IoErrorKind.NotFound;
}

export function isPermissionError(e: IoError): boolean {
	return e.kind == IoErrorKind.PermissionDenied;
}

export function isRetryable(e: IoError): boolean {
	return false; // I/O errors are generally not retryable
}

// ===== Tests =====

test "notFound constructor" {
	const e = notFound("/tmp/missing.txt");
	assert e.kind == IoErrorKind.NotFound;
	assert e.path == "/tmp/missing.txt";
}

test "permissionDenied constructor" {
	const e = permissionDenied("/etc/shadow");
	assert e.kind == IoErrorKind.PermissionDenied;
}

test "ioErrorFromErrno ENOENT" {
	const e = ioErrorFromErrno(2, "/tmp/x");
	assert e.kind == IoErrorKind.NotFound;
}

test "ioErrorFromErrno EACCES" {
	const e = ioErrorFromErrno(13, "/etc/shadow");
	assert e.kind == IoErrorKind.PermissionDenied;
}

test "ioErrorFromErrno EEXIST" {
	const e = ioErrorFromErrno(17, "/tmp/dir");
	assert e.kind == IoErrorKind.AlreadyExists;
}

test "ioErrorFromErrno unknown" {
	const e = ioErrorFromErrno(999, "/tmp/x");
	assert e.kind == IoErrorKind.Unknown;
}

test "isNotFound classification" {
	assert isNotFound(notFound("/x"));
	assert !isNotFound(permissionDenied("/x"));
}

test "endOfInput constructor" {
	const e = endOfInput();
	assert e.kind == IoErrorKind.EndOfInput;
	assert e.path == "";
}

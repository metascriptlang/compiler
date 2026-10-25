// The registry token store: ~/.metascript/credentials, mode 0600.

import { exists, readFile, writeFile, chmod } from "std/fs";
import { env } from "std/process";
import { join } from "std/fs/path";

function credentialsPath(): string {
	let home = env.get("HOME");
	// Windows fallback — HOME isn't set by default there.
	if (home == "") home = env.get("USERPROFILE");
	if (home == "") return "";
	return join(join(home, ".metascript"), "credentials");
}

export function loadToken(): string {
	const path = credentialsPath();
	if (path == "" || !exists(path)) return "";
	const content = try readFile(path) catch "";
	return content.trim();
}

export enum CredentialsError {
	NoHome,
	Write,
}

export function credentialsErrorMessage(e: CredentialsError): string {
	return match (e) {
		CredentialsError.NoHome => "HOME not set, cannot locate ~/.metascript/credentials",
		CredentialsError.Write => "could not write ~/.metascript/credentials",
	};
}

export function saveToken(token: string): Result<void, CredentialsError> {
	const path = credentialsPath();
	if (path == "") return Result.err(CredentialsError.NoHome);
	if (!writeFile(path, token + "\n").ok) return Result.err(CredentialsError.Write);
	// Tighten perms to 0600 (owner rw only) — 384 decimal.
	// Spec (docs/PACKAGE.md §File locations) requires mode 0600 on
	// ~/.metascript/credentials. No-op on Windows.
	chmod(path, 384 as int32);
	return Result.ok(null);
}

export function deleteToken(): Result<void, CredentialsError> {
	const path = credentialsPath();
	if (path == "" || !exists(path)) return Result.ok(null);
	if (!writeFile(path, "").ok) return Result.err(CredentialsError.Write);
	return Result.ok(null);
}

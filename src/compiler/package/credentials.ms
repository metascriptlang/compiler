// The registry token store: ~/.metascript/credentials, mode 0600.

import { exists, readFile, writeFile, chmod, ensureDir, removeAll } from "std/fs";
import { env, exec } from "std/process";
import { join } from "std/fs/path";
import { metascriptHome, tmpDir } from "../../utils/path";

function credentialsPath(): string {
	const root = metascriptHome();
	if (root == "") return "";
	return join(root, "credentials");
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
	// The empty file takes its mode before the token is written into it.
	if (!writeFile(path, "").ok) return Result.err(CredentialsError.Write);
	if (!chmod(path, 384 as int32).ok) return Result.err(CredentialsError.Write);
	if (!writeFile(path, token + "\n").ok) return Result.err(CredentialsError.Write);
	return Result.ok(null);
}

export function deleteToken(): Result<void, CredentialsError> {
	const path = credentialsPath();
	if (path == "" || !exists(path)) return Result.ok(null);
	if (!writeFile(path, "").ok) return Result.err(CredentialsError.Write);
	return Result.ok(null);
}

test "saveToken leaves the credentials file readable by its owner only" {
	if (env.get("OS") == "Windows_NT") return;
	const saved = env.get("HOME");
	const home = join(tmpDir(), "mscCredentialsTest");
	removeAll(home);
	ensureDir(join(home, ".metascript"));
	env.set("HOME", home);
	const path = join(join(home, ".metascript"), "credentials");
	writeFile(path, "old\n");
	chmod(path, 420 as int32);
	assert saveToken("tok").ok;
	const listing = exec(`ls -l "${path}"`);
	const stored = loadToken();
	env.set("HOME", saved);
	assert listing.ok;
	if (listing.ok) assert listing.value.startsWith("-rw-------");
	assert stored == "tok";
	removeAll(home);
}

import { readFileBytes } from "std/fs";
import { sha256 } from "std/crypto";

export function sha256File(path: string): Result<string, string> {
	const bytes = readFileBytes(path);
	if (!bytes.ok) {
		return Result.err("cannot read " + path + ": " + bytes.error.message);
	}
	const digest = sha256(bytes.value);
	if (!digest.ok) {
		return Result.err("cannot hash " + path + ": " + digest.error.message);
	}
	return Result.ok(digest.value);
}

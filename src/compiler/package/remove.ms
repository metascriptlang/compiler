// msc remove — remove a dependency from the project.

import { exists } from "std/fs";
import { join } from "std/fs/path";
import { removeDepFromManifest, manifestErrorMessage, ManifestError } from "./manifest";
import { readLockfile, writeLockfile, entryName, lockfileErrorMessage, LockEntry, LockfileError } from "./lockfile";

export function cmdRemove(projectRoot: string, args: string[]): boolean {
	if (args.length == 0) {
		console.log("error: msc remove requires a package name");
		console.log("usage: msc remove <name>");
		return false;
	}

	const buildPath = join(projectRoot, "build.ms");
	if (!exists(buildPath)) {
		console.log("error: no build.ms found in project root");
		return false;
	}

	const name = args[0];

	// Remove from build.ms
	const removed = removeDepFromManifest(buildPath, name);
	if (!removed.ok) {
		if (removed.error == ManifestError.NotFound) {
			console.log("error: '" + name + "' not found in build.ms");
		} else {
			console.log("error: failed to update build.ms: " + manifestErrorMessage(removed.error));
		}
		return false;
	}

	// Remove from lockfile
	const lockPath = join(projectRoot, "msc.lock");
	const lock = readLockfile(lockPath);
	if (lock.ok) {
		const kept: LockEntry[] = [];
		for (const entry of lock.value.entries) {
			if (entryName(entry.key) != name) {
				kept.push(entry);
			}
		}
		lock.value.entries = kept;
		const written = writeLockfile(lockPath, lock.value);
		if (!written.ok) console.log("warning: " + lockfileErrorMessage(written.error));
	} else if (lock.error != LockfileError.Missing) {
		console.log("warning: " + lockfileErrorMessage(lock.error) + " — left unchanged");
	}

	console.log("removed " + name);
	return true;
}

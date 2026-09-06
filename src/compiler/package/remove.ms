// msc remove — remove a dependency from the project.

import { exists } from "std/fs";
import { join } from "std/fs/path";
import { removeDepFromManifest } from "./manifest";
import { readLockfile, writeLockfile, entryName } from "./lockfile";
import { LockEntry } from "./lockfile";

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
	if (!removed) {
		console.log("error: '" + name + "' not found in build.ms");
		return false;
	}

	// Remove from lockfile
	const lockPath = join(projectRoot, "msc.lock");
	const lock = readLockfile(lockPath);
	if (lock.valid) {
		const kept: LockEntry[] = [];
		for (const entry of lock.entries) {
			if (entryName(entry.key) != name) {
				kept.push(entry);
			}
		}
		lock.entries = kept;
		writeLockfile(lockPath, lock);
	}

	console.log("removed " + name);
	return true;
}

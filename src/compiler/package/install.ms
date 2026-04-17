// msc install — ensure all dependencies are available.
// Reads build.ms + msc.lock, verifies all entries are present in cache.
// For file: deps, verifies the path exists.
// For registry/git deps, verifies cache entry exists (download is future work).

import { exists } from "std/fs";
import { join, isAbsolute } from "std/fs/path";
import { loadBuildConfig } from "../buildConfig";
import { readLockfile, entryName } from "./lockfile";
import { registrySrcPath, isCached } from "./cache";
import { fetchPackageInfo, findVersion } from "./registry";
import { downloadPackage } from "./download";

export function cmdInstall(projectRoot: string): boolean {
	const buildPath = join(projectRoot, "build.ms");
	if (!exists(buildPath)) {
		console.log("error: no build.ms found in project root");
		console.log("run `msc init` first to create a project");
		return false;
	}

	const cfg = loadBuildConfig(buildPath, false);
	if (!cfg.valid) {
		console.log("error: failed to parse build.ms");
		return false;
	}

	// Check if there are any deps at all
	if (cfg.deps.keys.length === 0 && cfg.devDeps.keys.length === 0) {
		console.log("no dependencies to install");
		return true;
	}

	let allOk = true;
	let installed = 0;
	let missing = 0;

	// Check file: deps — just verify paths exist
	let di = 0;
	while (di < cfg.deps.keys.length) {
		const name = cfg.deps.keys[di];
		const ver = cfg.deps.values[di];
		if (ver.length > 5 && ver.slice(0, 5) === "file:") {
			const relPath = ver.slice(5, ver.length);
			const absPath = isAbsolute(relPath) ? relPath : join(projectRoot, relPath);
			if (exists(absPath)) {
				installed = installed + 1;
			} else {
				console.log(`missing: ${name} → ${absPath} (directory not found)`);
				missing = missing + 1;
				allOk = false;
			}
		}
		di = di + 1;
	}

	// Check devDeps file: deps
	let ddi = 0;
	while (ddi < cfg.devDeps.keys.length) {
		const name = cfg.devDeps.keys[ddi];
		const ver = cfg.devDeps.values[ddi];
		if (ver.length > 5 && ver.slice(0, 5) === "file:") {
			const relPath = ver.slice(5, ver.length);
			const absPath = isAbsolute(relPath) ? relPath : join(projectRoot, relPath);
			if (exists(absPath)) {
				installed = installed + 1;
			} else {
				console.log(`missing: ${name} → ${absPath} (directory not found)`);
				missing = missing + 1;
				allOk = false;
			}
		}
		ddi = ddi + 1;
	}

	// Check registry/git deps via lockfile
	const lockPath = join(projectRoot, "msc.lock");
	const lock = readLockfile(lockPath);
	if (lock.valid) {
		for (const entry of lock.entries) {
			const name = entryName(entry.key);
			if (entry.source === "registry" && entry.version !== "") {
				const srcPath = registrySrcPath(name, entry.version);
				if (isCached(srcPath)) {
					installed = installed + 1;
				} else {
					// Resolve archiveUrl from lockfile or fetch from registry
					let archiveUrl = entry.url;
					let integrity = entry.integrity;
					if (archiveUrl === "") {
						const infoR = fetchPackageInfo(name);
						if (infoR.ok) {
							const ver = findVersion(infoR.value, entry.version);
							if (ver !== null) {
								archiveUrl = ver.archiveUrl;
								if (integrity === "") integrity = ver.integrity;
							}
						}
					}
					if (archiveUrl !== "" && downloadPackage(name, entry.version, archiveUrl, integrity)) {
						installed = installed + 1;
					} else {
						console.log(`missing: ${name}@${entry.version} (download failed)`);
						missing = missing + 1;
						allOk = false;
					}
				}
			}
		}
	} else if (cfg.deps.keys.length > 0 || cfg.devDeps.keys.length > 0) {
		// Has deps but no lockfile — check if all are file: deps (no lockfile needed)
		let hasNonFile = false;
		let ci = 0;
		while (ci < cfg.deps.keys.length) {
			const ver = cfg.deps.values[ci];
			if (ver.length <= 5 || ver.slice(0, 5) !== "file:") hasNonFile = true;
			ci = ci + 1;
		}
		if (hasNonFile) {
			console.log("warning: msc.lock not found — registry/git deps may not resolve");
			console.log("run `msc add <pkg>@<version>` to create the lockfile");
		}
	}

	if (allOk) {
		console.log(`all ${installed} dependencies OK`);
	} else {
		console.log(`${missing} missing, ${installed} OK`);
	}
	return allOk;
}

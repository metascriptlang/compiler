// msc install — ensure all dependencies are available.
// Reads build.ms + msc.lock, verifies all entries are present in cache.
// For file: deps, verifies the path exists.
// For registry/git deps, verifies cache entry exists (download is future work).

import { exists, ensureDir, removeAll, writeFile } from "std/fs";
import { tmpDir } from "../../utils/path";
import { join } from "std/fs/path";
import { loadBuildConfig, DepsSection } from "../buildConfig";
import { SourceKind, isFileDep, fileDepPath } from "./version";
import { readLockfile, entryName, lockfileErrorMessage, LockfileError } from "./lockfile";
import { registrySrcPath, isCached } from "./cache";
import { fetchPackageInfo, findVersion } from "./registry";
import { downloadPackage, packageErrorMessage } from "./download";

// A file: dep is present when the directory it names exists.
function checkFileDeps(section: DepsSection, projectRoot: string): { ok: int32, missing: int32 } {
	let ok = 0;
	let missing = 0;
	for (let i = 0; i < section.keys.length; i++) {
		const absPath = fileDepPath(section.values[i], projectRoot);
		if (absPath == "") continue;
		if (exists(absPath)) {
			ok = ok + 1;
		} else {
			console.log(`missing: ${section.keys[i]} → ${absPath} (directory not found)`);
			missing = missing + 1;
		}
	}
	return { ok, missing };
}

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
	if (cfg.deps.keys.length == 0 && cfg.devDeps.keys.length == 0) {
		console.log("no dependencies to install");
		return true;
	}

	let allOk = true;
	let installed = 0;
	let missing = 0;

	const fileDeps = checkFileDeps(cfg.deps, projectRoot);
	const devFileDeps = checkFileDeps(cfg.devDeps, projectRoot);
	installed = installed + fileDeps.ok + devFileDeps.ok;
	missing = missing + fileDeps.missing + devFileDeps.missing;
	if (fileDeps.missing + devFileDeps.missing > 0) allOk = false;

	// Check registry/git deps via lockfile
	const lockPath = join(projectRoot, "msc.lock");
	const lock = readLockfile(lockPath);
	if (lock.ok) {
		for (const entry of lock.value.entries) {
			const name = entryName(entry.key);
			if (entry.source == SourceKind.Registry && entry.version != "") {
				const srcPath = registrySrcPath(name, entry.version);
				if (isCached(srcPath)) {
					installed = installed + 1;
				} else {
					// Resolve archiveUrl from lockfile or fetch from registry
					let archiveUrl = entry.url;
					let integrity = entry.integrity;
					if (archiveUrl == "") {
						const infoR = fetchPackageInfo(name);
						if (infoR.ok) {
							const ver = findVersion(infoR.value, entry.version);
							if (ver != null) {
								archiveUrl = ver.archiveUrl;
								if (integrity == "") integrity = ver.integrity;
							}
						}
					}
					let downloadedOk = false;
					if (archiveUrl != "") {
						const downloaded = downloadPackage(name, entry.version, archiveUrl, integrity);
						downloadedOk = downloaded.ok;
						if (!downloaded.ok) console.log(`  error: ${name}@${entry.version}: ${packageErrorMessage(downloaded.error)}`);
					}
					if (downloadedOk) {
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
		for (const ver of cfg.deps.values) {
			if (!isFileDep(ver)) hasNonFile = true;
		}
		if (hasNonFile) {
			const reason = lockfileErrorMessage(lock.error);
			console.log("warning: " + reason + " — registry/git deps may not resolve");
			if (lock.error == LockfileError.Missing) {
				console.log("run `msc add <pkg>@<version>` to create the lockfile");
			} else {
				console.log("fix or delete msc.lock, then run `msc add <pkg>@<version>`");
			}
		}
	}

	if (allOk) {
		console.log(`all ${installed} dependencies OK`);
	} else {
		console.log(`${missing} missing, ${installed} OK`);
	}
	return allOk;
}

function installProject(label: string, depDirs: string[], devDirs: string[], present: string[]): string {
	const root = join(tmpDir(), "mscInstallTest-" + label);
	removeAll(root);
	ensureDir(join(root, "proj"));
	for (const d of present) ensureDir(join(root, d));
	const deps = depDirs.map((d: string): string => "\"" + d + "\": \"file:../" + d + "\"").join(", ");
	const dev = devDirs.map((d: string): string => "\"" + d + "\": \"file:../" + d + "\"").join(", ");
	writeFile(join(root, "proj/build.ms"), "const config = { package: { name: \"app\", version: \"1.0.0\" }, deps: { " + deps + " }, devDeps: { " + dev + " } };\nexport default config;\n");
	return join(root, "proj");
}

test "install passes when every file: dep of both sections exists" {
	assert cmdInstall(installProject("ok", ["a"], ["b"], ["a", "b"]));
}

test "install fails when a file: dep of either section is missing" {
	assert !cmdInstall(installProject("missDep", ["a"], ["b"], ["b"]));
	assert !cmdInstall(installProject("missDev", ["a"], ["b"], ["a"]));
}

test "install with no dependencies succeeds" {
	assert cmdInstall(installProject("none", [], [], []));
}

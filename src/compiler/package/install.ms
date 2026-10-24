// msc install — ensure all dependencies are available.
// Reads build.ms + msc.lock, verifies all entries are present in cache.
// For file: deps, verifies the path exists.
// A registry dep is downloaded when its cache entry is missing. A git entry, a registry entry
// that needs a package msc.lock has no entry for, and a registry/git dep without a usable
// msc.lock are refused: none of them is installed yet.

import { exists, ensureDir, removeAll, writeFile } from "std/fs";
import { tmpDir } from "../../utils/path";
import { join } from "std/fs/path";
import { loadBuildConfig, DepsSection } from "../buildConfig";
import { SourceKind, isFileDep, fileDepPath } from "./version";
import { readLockfile, entryName, lockfileErrorMessage, LockfileError, Lockfile } from "./lockfile";
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

function hasEntryNamed(lock: Lockfile, name: string): boolean {
	for (const entry of lock.entries) {
		if (entryName(entry.key) == name) return true;
	}
	return false;
}

// Prints one error per entry that cannot be installed and returns how many there are.
function refuseUninstallable(lock: Lockfile): int32 {
	let refused = 0;
	for (const entry of lock.entries) {
		if (entry.source == SourceKind.Git) {
			console.log(`error: ${entry.key}: git sources are not installed yet`);
			refused = refused + 1;
			continue;
		}
		for (let i = 0; i < entry.depKeys.length; i++) {
			if (hasEntryNamed(lock, entry.depKeys[i])) continue;
			console.log(`error: ${entry.key} needs ${entry.depKeys[i]}@${entry.depValues[i]}; transitive dependencies are not installed yet`);
			refused = refused + 1;
		}
	}
	return refused;
}

function countNonFileDeps(section: DepsSection): int32 {
	let count = 0;
	for (const ver of section.values) {
		if (!isFileDep(ver)) count = count + 1;
	}
	return count;
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
	const refused = lock.ok ? refuseUninstallable(lock.value) : 0;
	if (refused > 0) {
		missing = missing + refused;
		allOk = false;
	} else if (lock.ok) {
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
	} else if (countNonFileDeps(cfg.deps) + countNonFileDeps(cfg.devDeps) > 0) {
		console.log("error: " + lockfileErrorMessage(lock.error) + ", so registry and git deps cannot be installed");
		if (lock.error == LockfileError.Missing) {
			console.log("run `msc add <pkg>@<version>` to create the lockfile");
		} else {
			console.log("fix or delete msc.lock, then run `msc add <pkg>@<version>`");
		}
		missing = missing + countNonFileDeps(cfg.deps) + countNonFileDeps(cfg.devDeps);
		allOk = false;
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

function lockedProject(label: string, deps: string, devDeps: string, lock: string): string {
	const root = join(tmpDir(), "mscInstallTest-" + label);
	removeAll(root);
	ensureDir(root);
	writeFile(join(root, "build.ms"), "const config = { package: { name: \"app\", version: \"1.0.0\" }, deps: { " + deps + " }, devDeps: { " + devDeps + " } };\nexport default config;\n");
	if (lock != "") writeFile(join(root, "msc.lock"), lock);
	return root;
}

const gitEntryLock = '{ "version": 1, "packages": { "foo@git:github.com/acme/foo@v1.2.3": { "source": "git", "url": "github.com/acme/foo", "ref": "v1.2.3" } } }';

test "install refuses a git entry in msc.lock" {
	const lock = gitEntryLock;
	assert !cmdInstall(lockedProject("gitEntry", "\"foo\": \"git:github.com/acme/foo@v1.2.3\"", "", lock));
	assert !cmdInstall(lockedProject("gitEntryDev", "", "\"foo\": \"git:github.com/acme/foo@v1.2.3\"", lock));
}

function cachedRegistryEntry(name: string, version: string, deps: string): string {
	ensureDir(registrySrcPath(name, version));
	return '"' + name + '@' + version + '": { "source": "registry", "version": "' + version + '", "deps": { ' + deps + ' } }';
}

test "install refuses a registry entry whose dependency has no entry of its own" {
	const outer = cachedRegistryEntry("mscInstallTestOuter", "1.0.0", '"mscInstallTestInner": "0.1.0"');
	const lock = '{ "version": 1, "packages": { ' + outer + ' } }';
	const refused = cmdInstall(lockedProject("transitive", "\"mscInstallTestOuter\": \"1.0.0\"", "", lock));
	removeAll(registrySrcPath("mscInstallTestOuter", "1.0.0"));
	assert !refused;
}

test "install passes when the dependency of a registry entry has an entry of its own" {
	const outer = cachedRegistryEntry("mscInstallTestOuter", "1.0.0", '"mscInstallTestInner": "0.1.0"');
	const inner = cachedRegistryEntry("mscInstallTestInner", "0.1.0", "");
	const lock = '{ "version": 1, "packages": { ' + outer + ', ' + inner + ' } }';
	const passed = cmdInstall(lockedProject("transitiveOk", "\"mscInstallTestOuter\": \"1.0.0\"", "", lock));
	removeAll(registrySrcPath("mscInstallTestOuter", "1.0.0"));
	removeAll(registrySrcPath("mscInstallTestInner", "0.1.0"));
	assert passed;
}

test "install refuses a registry or git dep when msc.lock is missing" {
	assert !cmdInstall(lockedProject("noLockReg", "\"outer\": \"1.0.0\"", "", ""));
	assert !cmdInstall(lockedProject("noLockGit", "\"foo\": \"git:github.com/acme/foo@v1.2.3\"", "", ""));
	assert !cmdInstall(lockedProject("noLockDev", "", "\"outer\": \"1.0.0\"", ""));
}

test "install without msc.lock still passes when every dep is a file: dep" {
	const root = lockedProject("noLockFile", "\"a\": \"file:../a\"", "", "");
	ensureDir(join(root, "../a"));
	assert cmdInstall(root);
}

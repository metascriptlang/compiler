// msc add — add a dependency to the project.
//
// Usage:
//   msc add <name>@<version>         — registry dep (exact version)
//   msc add <name>@<version> -D      — dev dep
//   msc add git:<url>@<ref>          — git dep
//
// For v1: adds dep to build.ms and writes/updates msc.lock.
// Registry fetch (resolving "latest" without @version) requires the registry
// server — deferred until the server is updated to match PACKAGE.md spec.

import { exists } from "std/fs";
import { join } from "std/fs/path";
import { addDepToManifest } from "./manifest";
import { readLockfile, writeLockfile, entryName } from "./lockfile";
import { parseSourceSpec, SourceKind } from "./version";
import { parseGitSpec } from "./version";
import { LockEntry } from "./lockfile";
import { fetchPackageInfo, findVersion, latestVersion, RegistryVersion, RegistryPackage } from "./registry";
import { downloadPackage } from "./download";

// Parse "name@version" into { name, version }.
function parseNameVersion(arg: string): { name: string, version: string } {
	// Git source: entire string is the version spec
	if (arg.length >= 4 && arg.slice(0, 4) === "git:") {
		// Extract alias from the repo name (last path segment before @)
		const spec = parseGitSpec(arg);
		if (spec.isValid) {
			// Extract repo name as alias
			let lastSlash = -1;
			let i = 0;
			while (i < spec.url.length) {
				if (spec.url.charAt(i) === "/") lastSlash = i;
				i = i + 1;
			}
			const alias = lastSlash >= 0 ? spec.url.slice(lastSlash + 1, spec.url.length) : spec.url;
			return { name: alias, version: arg };
		}
		return { name: "", version: "" };
	}

	// Check for alias=git:... syntax
	let eqIdx = -1;
	let ei = 0;
	while (ei < arg.length) {
		if (arg.charAt(ei) === "=") { eqIdx = ei; ei = arg.length; }
		ei = ei + 1;
	}
	if (eqIdx > 0 && eqIdx + 4 < arg.length && arg.slice(eqIdx + 1, eqIdx + 5) === "git:") {
		const alias = arg.slice(0, eqIdx);
		const gitSpec = arg.slice(eqIdx + 1, arg.length);
		return { name: alias, version: gitSpec };
	}

	// "name@version" — split on FIRST @ (version may contain @ for git refs)
	let atIdx = -1;
	let ai = 0;
	while (ai < arg.length) {
		if (arg.charAt(ai) === "@") { atIdx = ai; ai = arg.length; }
		ai = ai + 1;
	}
	if (atIdx > 0) {
		return { name: arg.slice(0, atIdx), version: arg.slice(atIdx + 1, arg.length) };
	}

	// No version specified — name only (would need registry to resolve latest)
	return { name: arg, version: "" };
}

// Execute `msc add <args>`.
// projectRoot: directory containing build.ms
// args: remaining CLI arguments after "add"
export function cmdAdd(projectRoot: string, args: string[]): boolean {
	if (args.length === 0) {
		console.log("error: msc add requires a package specifier");
		console.log("usage: msc add <name>@<version> [-D]");
		return false;
	}

	const buildPath = join(projectRoot, "build.ms");
	if (!exists(buildPath)) {
		console.log("error: no build.ms found in project root");
		console.log("run `msc init` first to create a project");
		return false;
	}

	// Parse arguments
	let pkgArg = "";
	let isDev = false;
	let i = 0;
	while (i < args.length) {
		if (args[i] === "-D" || args[i] === "--dev") {
			isDev = true;
		} else if (pkgArg === "") {
			pkgArg = args[i];
		}
		i = i + 1;
	}

	if (pkgArg === "") {
		console.log("error: no package specifier provided");
		return false;
	}

	// Parse name@version
	const parsed = parseNameVersion(pkgArg);
	if (parsed.name === "") {
		console.log("error: invalid package specifier: " + pkgArg);
		return false;
	}
	// Fetch registry metadata (reused for latest-resolve + lockfile population)
	let registryPkg: RegistryPackage = null as unknown as RegistryPackage;

	if (parsed.version === "") {
		// Resolve latest version from registry.
		console.log("resolving latest version of " + parsed.name + " from registry...");
		const infoResult = fetchPackageInfo(parsed.name);
		if (!infoResult.ok) {
			console.log("error: " + infoResult.error.message);
			return false;
		}
		registryPkg = infoResult.value;
		const latest = latestVersion(registryPkg);
		if (latest === null) {
			console.log("error: no published versions for " + parsed.name);
			return false;
		}
		parsed.version = latest.version;
		console.log("  → " + parsed.version);
	}

	// file: source — local folder, no version validation, no lockfile entry
	const isFileSource = parsed.version.length > 5 && parsed.version.slice(0, 5) === "file:";
	if (isFileSource) {
		const scope = isDev ? "devDeps" : "deps";
		const added = addDepToManifest(buildPath, parsed.name, parsed.version, scope);
		if (!added) {
			console.log("error: failed to update build.ms");
			return false;
		}
		const devTag = isDev ? " (dev)" : "";
		console.log("added " + parsed.name + " → " + parsed.version + devTag);
		return true;
	}

	// Validate version
	const spec = parseSourceSpec(parsed.version);
	if (spec.kind === SourceKind.Registry && !spec.version.isValid) {
		console.log("error: invalid version '" + parsed.version + "'");
		console.log("expected format: <major>.<minor>.<patch> (e.g. 1.2.3)");
		return false;
	}
	if (spec.kind === SourceKind.Git && !spec.git.isValid) {
		console.log("error: invalid git source '" + parsed.version + "'");
		console.log("expected format: git:<host>/<path>@<tag-or-sha>");
		return false;
	}

	// Add to build.ms
	const scope = isDev ? "devDeps" : "deps";
	const added = addDepToManifest(buildPath, parsed.name, parsed.version, scope);
	if (!added) {
		console.log("error: failed to update build.ms");
		return false;
	}

	// Update lockfile
	const lockPath = join(projectRoot, "msc.lock");
	let lock = readLockfile(lockPath);
	if (!lock.valid) {
		const entries: LockEntry[] = [];
		lock = { version: 1, entries, valid: true };
	}

	// Build the lock entry
	let lockKey = "";
	let entry: LockEntry = null as unknown as LockEntry;

	if (spec.kind === SourceKind.Git) {
		lockKey = parsed.name + "@" + parsed.version;
		const emptyKeys: string[] = [];
		const emptyVals: string[] = [];
		entry = {
			key: lockKey,
			source: "git",
			version: "",
			integrity: "",
			url: spec.git.url,
			gitRef: spec.git.ref,
			commit: "",
			depKeys: emptyKeys,
			depValues: emptyVals,
		};
	} else {
		// Get version details from registry (archiveUrl + integrity + deps)
		let regVersion: RegistryVersion = null as unknown as RegistryVersion;
		if (registryPkg === null) {
			const infoResult = fetchPackageInfo(parsed.name);
			if (infoResult.ok) registryPkg = infoResult.value;
		}
		if (registryPkg !== null) {
			regVersion = findVersion(registryPkg, parsed.version);
		}

		lockKey = parsed.name + "@" + parsed.version;
		const depKeys: string[] = regVersion !== null ? regVersion.depKeys : [];
		const depValues: string[] = regVersion !== null ? regVersion.depValues : [];
		entry = {
			key: lockKey,
			source: "registry",
			version: parsed.version,
			integrity: regVersion !== null ? regVersion.integrity : "",
			url: regVersion !== null ? regVersion.archiveUrl : "",
			gitRef: "",
			commit: "",
			depKeys,
			depValues,
		};
	}

	// Check if already in lockfile — match by package name (not full key,
	// since the key includes the version and we're updating to a new version)
	let found = false;
	let fi = 0;
	while (fi < lock.entries.length) {
		const existingName = entryName(lock.entries[fi].key);
		if (existingName === parsed.name) {
			lock.entries[fi] = entry;
			found = true;
		}
		fi = fi + 1;
	}
	if (!found) {
		lock.entries.push(entry);
	}

	const written = writeLockfile(lockPath, lock);
	if (!written) {
		console.log("error: failed to write msc.lock");
		return false;
	}

	// Download the package archive
	if (entry.source === "registry" && entry.url !== "") {
		if (!downloadPackage(parsed.name, parsed.version, entry.url, entry.integrity)) {
			console.log("warning: added to lockfile but download failed — run `msc install` to retry");
		}
	}

	const devTag = isDev ? " (dev)" : "";
	console.log("added " + parsed.name + "@" + parsed.version + devTag);
	return true;
}

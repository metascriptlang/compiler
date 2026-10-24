// msc add — add a dependency to the project.
//
// Usage:
//   msc add <name>@<version>         — registry dep (exact version)
//   msc add <name>@<version> -D      — dev dep
//   msc add <name>@file:<path>       — local folder
//
// A git source is refused: nothing installs one yet.
//
// For v1: adds dep to build.ms and writes/updates msc.lock.
// Registry fetch (resolving "latest" without @version) requires the registry
// server — deferred until the server is updated to match PACKAGE.md spec.

import { exists, readFile, writeFile, ensureDir, removeAll } from "std/fs";
import { tmpDir } from "../../utils/path";
import { join } from "std/fs/path";
import { addDepToManifest, manifestErrorMessage } from "./manifest";
import {
	readLockfile,
	writeLockfile,
	entryName,
	lockfileErrorMessage,
	Lockfile,
	LockfileError,
} from "./lockfile";
import { parseVersion, isFileDep, SourceKind } from "./version";
import { LockEntry } from "./lockfile";
import { fetchPackageInfo, findVersion, latestVersion, RegistryVersion, RegistryPackage } from "./registry";
import { downloadPackage, packageErrorMessage } from "./download";

// Parse "name@version" into { name, version }.
// Handles scoped names:
//   "void"                → { name: "void", version: "" }
//   "void@1.0.0"          → { name: "void", version: "1.0.0" }
//   "alice/router"        → { name: "alice/router", version: "" }
//   "alice/router@1.0.0"  → { name: "alice/router", version: "1.0.0" }
//   "@acme/router"        → { name: "@acme/router", version: "" }
//   "@acme/router@1.0.0"  → { name: "@acme/router", version: "1.0.0" }
export function parseNameVersion(arg: string): { name: string, version: string } {
	// Scoped package: @org/name or @org/name@version
	// The first @ is the org prefix, find the @ after the / for the version
	if (arg.length > 0 && arg.charAt(0) == "@") {
		let slashIdx = -1;
		let si = 1;
		while (si < arg.length) {
			if (arg.charAt(si) == "/") { slashIdx = si; si = arg.length; }
			si = si + 1;
		}
		if (slashIdx > 0) {
			// Find @ after the slash — that's the version separator
			let atIdx = -1;
			let ai = slashIdx + 1;
			while (ai < arg.length) {
				if (arg.charAt(ai) == "@") { atIdx = ai; ai = arg.length; }
				ai = ai + 1;
			}
			if (atIdx > 0) {
				return { name: arg.slice(0, atIdx), version: arg.slice(atIdx + 1, arg.length) };
			}
			return { name: arg, version: "" };
		}
	}

	// User-scoped: user/name or user/name@version
	// Find the / first, then find @ after it for the version
	let slashIdx = -1;
	let sli = 0;
	while (sli < arg.length) {
		if (arg.charAt(sli) == "/") { slashIdx = sli; sli = arg.length; }
		sli = sli + 1;
	}
	let firstAt = -1;
	let fai = 0;
	while (fai < arg.length) {
		if (arg.charAt(fai) == "@") { firstAt = fai; fai = arg.length; }
		fai = fai + 1;
	}
	if (slashIdx > 0 && (firstAt < 0 || slashIdx < firstAt)) {
		// Find @ after the slash — that's the version separator
		let atIdx = -1;
		let ai = slashIdx + 1;
		while (ai < arg.length) {
			if (arg.charAt(ai) == "@") { atIdx = ai; ai = arg.length; }
			ai = ai + 1;
		}
		if (atIdx > 0) {
			return { name: arg.slice(0, atIdx), version: arg.slice(atIdx + 1, arg.length) };
		}
		return { name: arg, version: "" };
	}

	// Unscoped: "name@version" — split on FIRST @
	let atIdx = -1;
	let ai = 0;
	while (ai < arg.length) {
		if (arg.charAt(ai) == "@") { atIdx = ai; ai = arg.length; }
		ai = ai + 1;
	}
	if (atIdx > 0) {
		return { name: arg.slice(0, atIdx), version: arg.slice(atIdx + 1, arg.length) };
	}

	// No version specified — name only
	return { name: arg, version: "" };
}

function registryLockEntry(
	name: string,
	version: string,
	found: RegistryVersion | null,
): LockEntry {
	return {
		key: name + "@" + version,
		source: SourceKind.Registry,
		version,
		integrity: found != null ? found.integrity : "",
		url: found != null ? found.archiveUrl : "",
		gitRef: "",
		commit: "",
		depKeys: found != null ? found.depKeys : [],
		depValues: found != null ? found.depValues : [],
	};
}

// Version details from registry (archiveUrl + integrity + deps); fetches the package when
// not yet known.
function registryVersionOf(
	name: string,
	version: string,
	known: RegistryPackage | null,
): RegistryVersion | null {
	if (known != null) return findVersion(known, version);
	const info = fetchPackageInfo(name);
	if (!info.ok) return null;
	return findVersion(info.value, version);
}

// A git source in any spelling: `git:…`, `name@git:…` or `alias=git:…`.
function isGitSource(arg: string): boolean {
	return arg.startsWith("git:") || arg.indexOf("@git:") >= 0 || arg.indexOf("=git:") >= 0;
}

// Execute `msc add <args>`.
// projectRoot: directory containing build.ms
// args: remaining CLI arguments after "add"
export function cmdAdd(projectRoot: string, args: string[]): boolean {
	if (args.length == 0) {
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

	let pkgArg = "";
	let isDev = false;
	let i = 0;
	while (i < args.length) {
		if (args[i] == "-D" || args[i] == "--dev") {
			isDev = true;
		} else if (pkgArg == "") {
			pkgArg = args[i];
		}
		i = i + 1;
	}

	if (pkgArg == "") {
		console.log("error: no package specifier provided");
		return false;
	}

	if (isGitSource(pkgArg)) {
		console.log("error: git sources are not installed yet: " + pkgArg);
		console.log("use <name>@<version> from the registry or <name>@file:<path>");
		return false;
	}

	const parsed = parseNameVersion(pkgArg);
	if (parsed.name == "") {
		console.log("error: invalid package specifier: " + pkgArg);
		return false;
	}
	// Fetch registry metadata (reused for latest-resolve + lockfile population)
	let registryPkg: RegistryPackage | null = null;

	if (parsed.version == "") {
		// Resolve latest version from registry.
		console.log("resolving latest version of " + parsed.name + " from registry...");
		const infoResult = fetchPackageInfo(parsed.name);
		if (!infoResult.ok) {
			console.log("error: " + infoResult.error.message);
			return false;
		}
		registryPkg = infoResult.value;
		const latest = latestVersion(infoResult.value);
		if (latest == null) {
			console.log("error: no published versions for " + parsed.name);
			return false;
		}
		parsed.version = latest.version;
		console.log("  → " + parsed.version);
	}

	// file: source — local folder, no version validation, no lockfile entry
	if (isFileDep(parsed.version)) {
		const scope = isDev ? "devDeps" : "deps";
		const added = addDepToManifest(buildPath, parsed.name, parsed.version, scope);
		if (!added.ok) {
			console.log("error: failed to update build.ms: " + manifestErrorMessage(added.error));
			return false;
		}
		const devTag = isDev ? " (dev)" : "";
		console.log("added " + parsed.name + " → " + parsed.version + devTag);
		return true;
	}

	if (!parseVersion(parsed.version).ok) {
		console.log("error: invalid version '" + parsed.version + "'");
		console.log("expected format: <major>.<minor>.<patch> (e.g. 1.2.3)");
		return false;
	}

	// Read the lockfile first: a corrupt one stops the add before build.ms changes
	const lockPath = join(projectRoot, "msc.lock");
	const lockRead = readLockfile(lockPath);
	let lock: Lockfile = { version: 1, entries: [] };
	if (lockRead.ok) {
		lock = lockRead.value;
	} else if (lockRead.error != LockfileError.Missing && lockRead.error != LockfileError.Empty) {
		console.log("error: " + lockfileErrorMessage(lockRead.error));
		console.log("fix or delete msc.lock and retry");
		return false;
	}

	// Add to build.ms
	const scope = isDev ? "devDeps" : "deps";
	const added = addDepToManifest(buildPath, parsed.name, parsed.version, scope);
	if (!added.ok) {
		console.log("error: failed to update build.ms: " + manifestErrorMessage(added.error));
		return false;
	}

	const entry = registryLockEntry(
		parsed.name,
		parsed.version,
		registryVersionOf(parsed.name, parsed.version, registryPkg),
	);

	// Check if already in lockfile — match by package name (not full key,
	// since the key includes the version and we're updating to a new version)
	let found = false;
	let fi = 0;
	while (fi < lock.entries.length) {
		const existingName = entryName(lock.entries[fi].key);
		if (existingName == parsed.name) {
			lock.entries[fi] = entry;
			found = true;
		}
		fi = fi + 1;
	}
	if (!found) {
		lock.entries.push(entry);
	}

	const written = writeLockfile(lockPath, lock);
	if (!written.ok) {
		console.log("error: " + lockfileErrorMessage(written.error));
		return false;
	}

	// Download the package archive
	if (entry.source == SourceKind.Registry && entry.url != "") {
		const downloaded = downloadPackage(parsed.name, parsed.version, entry.url, entry.integrity);
		if (!downloaded.ok) {
			console.log(`  error: ${parsed.name}@${parsed.version}: ${packageErrorMessage(downloaded.error)}`);
			console.log("warning: added to lockfile but download failed — run `msc install` to retry");
		}
	}

	const devTag = isDev ? " (dev)" : "";
	console.log("added " + parsed.name + "@" + parsed.version + devTag);
	return true;
}

test "a file: version keeps its slashes out of the name" {
	const p = parseNameVersion("greeter@file:/tmp/greeter");
	assert p.name == "greeter";
	assert p.version == "file:/tmp/greeter";
	const rel = parseNameVersion("greeter@file:../greeter");
	assert rel.name == "greeter";
	assert rel.version == "file:../greeter";
}

test "a user-scoped name still splits on the slash" {
	const p = parseNameVersion("acme/cool-json@1.2.3");
	assert p.name == "acme/cool-json";
	assert p.version == "1.2.3";
	const bare = parseNameVersion("acme/cool-json");
	assert bare.name == "acme/cool-json";
	assert bare.version == "";
}

test "an org-scoped name with a file: version" {
	const p = parseNameVersion("@acme/ion@file:/tmp/ion");
	assert p.name == "@acme/ion";
	assert p.version == "file:/tmp/ion";
}

test "a plain name@version is unchanged" {
	const p = parseNameVersion("cool-json@1.2.3");
	assert p.name == "cool-json";
	assert p.version == "1.2.3";
}

test "a registry lock entry without registry details has no integrity or url" {
	const entry = registryLockEntry("cool-json", "1.2.3", null);
	assert entry.key == "cool-json@1.2.3";
	assert entry.source == SourceKind.Registry;
	assert entry.integrity == "";
	assert entry.url == "";
	assert entry.depKeys.length == 0;
}

test "a registry lock entry takes integrity, url and deps from the registry record" {
	const found: RegistryVersion = {
		version: "1.2.3",
		integrity: "sha256-abc",
		archiveUrl: "https://example.test/cool-json.zip",
		publishedAt: "",
		depKeys: ["dep"],
		depValues: ["0.1.0"],
	};
	const entry = registryLockEntry("cool-json", "1.2.3", found);
	assert entry.integrity == "sha256-abc";
	assert entry.url == "https://example.test/cool-json.zip";
	assert entry.depKeys[0] == "dep";
	assert entry.depValues[0] == "0.1.0";
}

function addProject(label: string): string {
	const root = join(tmpDir(), "mscAddTest-" + label);
	removeAll(root);
	ensureDir(root);
	writeFile(join(root, "build.ms"), addBuildMs);
	return root;
}

const addBuildMs = "const config = { package: { name: \"app\", version: \"1.0.0\" }, deps: {  }, devDeps: {  } };\nexport default config;\n";

test "add refuses a git source and leaves build.ms and msc.lock alone" {
	const specs = [
		"foo@git:github.com/acme/foo@v1.2.3",
		"git:github.com/acme/foo@v1.2.3",
		"foo=git:github.com/acme/foo@v1.2.3",
		"@acme/foo@git:github.com/acme/foo@v1.2.3",
	];
	for (const spec of specs) {
		const root = addProject("git");
		assert !cmdAdd(root, [spec]);
		assert (try readFile(join(root, "build.ms")) catch "") == addBuildMs;
		assert !exists(join(root, "msc.lock"));
	}
}

test "add refuses a git source as a dev dep too" {
	const root = addProject("gitDev");
	assert !cmdAdd(root, ["foo@git:github.com/acme/foo@v1.2.3", "-D"]);
	assert (try readFile(join(root, "build.ms")) catch "") == addBuildMs;
	assert !exists(join(root, "msc.lock"));
}

test "add still takes a file: source" {
	const root = addProject("file");
	assert cmdAdd(root, ["foo@file:../foo"]);
	assert (try readFile(join(root, "build.ms")) catch "").includes("file:../foo");
}

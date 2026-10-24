// Registry — HTTP client for the MetaScript package registry API.
// Endpoints:
//   GET /packages/:name           → package metadata + all versions
//   GET /packages/:name/:version  → specific version (integrity, archiveUrl, deps)
//   GET /packages/:name/-/:file   → archive download (redirects to R2 signed URL)
//
// API reference: ~/metascript/landing/apps/api/src/routes/packages.ts

import { HttpError, httpError, HttpErrorKind, invalidResponse } from "std/http/errors";
import { parseJson, JsonValue, JsonKind, getDynamicField, asString } from "std/core/json";
import { arrayField, depsOf } from "./json";

// Default registry URL — override via METASCRIPT_REGISTRY env var.
const DEFAULT_REGISTRY = "https://api.metascriptlang.org";

// ===== Types =====

// A single published version.
export interface RegistryVersion {
	version: string;      // "1.2.3"
	integrity: string;    // "sha256-<base64>" (W3C SRI, matches lockfile + spec)
	archiveUrl: string;   // direct URL (may be R2 signed URL)
	publishedAt: string;  // ISO timestamp
	depKeys: string[];    // dependency names
	depValues: string[];  // dependency version specs (parallel array)
}

// Full package metadata from GET /packages/:name.
export interface RegistryPackage {
	name: string;
	description: string;
	license: string;
	repository: string;
	homepage: string;
	versions: RegistryVersion[];
}

function parseVersionRecord(v: JsonValue): RegistryVersion {
	const deps = depsOf(v.getDynamicField("dependencies"));
	return {
		version: v.getDynamicField("version").asString(),
		integrity: v.getDynamicField("integrity").asString(),
		archiveUrl: v.getDynamicField("archiveUrl").asString(),
		publishedAt: v.getDynamicField("publishedAt").asString(),
		depKeys: deps.keys,
		depValues: deps.values,
	};
}

// ===== Public API =====

// Return the registry base URL (from METASCRIPT_REGISTRY env or default).
export function registryBaseUrl(): string {
	return DEFAULT_REGISTRY;
}

// Build the API path for a package name, handling scoped names.
// "void"          → "/packages/void"
// "alice/router"  → "/packages/user/alice/router"
// "@acme/router"  → "/packages/org/acme/router"
function packageApiPath(name: string): string {
	if (name.length > 0 && name.charAt(0) == "@") {
		// Org-scoped: @acme/router → /packages/org/acme/router (strip @)
		return "/packages/org/" + name.slice(1, name.length);
	}
	// Check for user scope (contains /)
	let slashIdx = -1;
	let i = 0;
	while (i < name.length) {
		if (name.charAt(i) == "/") { slashIdx = i; i = name.length; }
		i = i + 1;
	}
	if (slashIdx > 0) {
		// User-scoped: alice/router → /packages/user/alice/router
		return "/packages/user/" + name;
	}
	// Unscoped
	return "/packages/" + name;
}

// Fetch package metadata including all published versions.
// Returns null on network error or missing package.
export function fetchPackageInfo(name: string): Result<RegistryPackage, HttpError> {
	const url = registryBaseUrl() + packageApiPath(name);
	const resp = try fetch(url);
	if (resp.status == 404) {
		return Result.err(httpError(HttpErrorKind.InvalidResponse, "package not found: " + name));
	}
	if (resp.status != 200) {
		return Result.err(httpError(HttpErrorKind.InvalidResponse, "registry returned HTTP " + resp.status.toString()));
	}

	const parsed = parseJson(resp.body);
	if (!parsed.ok || parsed.value.kind != JsonKind.Object) {
		return Result.err(invalidResponse("invalid JSON from registry"));
	}
	const obj = parsed.value;

	const versionItems = arrayField(obj, "versions");
	const versions: RegistryVersion[] = [];
	for (const item of versionItems) {
		versions.push(parseVersionRecord(item));
	}

	return Result.ok({
		name: obj.getDynamicField("name").asString(),
		description: obj.getDynamicField("description").asString(),
		license: obj.getDynamicField("license").asString(),
		repository: obj.getDynamicField("repository").asString(),
		homepage: obj.getDynamicField("homepage").asString(),
		versions: versions,
	});
}

// Find a specific version in a RegistryPackage. Returns null if not found.
export function findVersion(pkg: RegistryPackage, version: string): RegistryVersion | null {
	for (const v of pkg.versions) {
		if (v.version == version) return v;
	}
	return null;
}

// Get the latest version (first in the versions array — server orders by publishedAt DESC).
export function latestVersion(pkg: RegistryPackage): RegistryVersion | null {
	if (pkg.versions.length == 0) return null;
	return pkg.versions[0];
}

function testPackage(versions: string[]): RegistryPackage {
	const records: RegistryVersion[] = [];
	for (const v of versions) {
		records.push({
			version: v,
			integrity: "",
			archiveUrl: "",
			publishedAt: "",
			depKeys: [],
			depValues: [],
		});
	}
	return {
		name: "demo",
		description: "",
		license: "",
		repository: "",
		homepage: "",
		versions: records,
	};
}

test "findVersion returns the matching record or null" {
	const pkg = testPackage(["2.0.0", "1.0.0"]);
	const hit = findVersion(pkg, "1.0.0");
	assert hit != null;
	if (hit != null) assert hit.version == "1.0.0";
	assert findVersion(pkg, "3.0.0") == null;
}

test "latestVersion is the first record, or null for a package with none" {
	const latest = latestVersion(testPackage(["2.0.0", "1.0.0"]));
	assert latest != null;
	if (latest != null) assert latest.version == "2.0.0";
	assert latestVersion(testPackage([])) == null;
}

test "a version record with mistyped fields reads as empty" {
	const parsed = parseJson('{ "version": 2, "integrity": null, "archiveUrl": "u", "publishedAt": 1.5,' +
		' "dependencies": { "a": "1.0.0", "b": 3 } }');
	assert parsed.ok;
	if (parsed.ok) {
		const rec = parseVersionRecord(parsed.value);
		assert rec.version == "" && rec.integrity == "" && rec.publishedAt == "";
		assert rec.archiveUrl == "u";
		assert rec.depKeys.length == 2 && rec.depValues[0] == "1.0.0" && rec.depValues[1] == "";
	}
	const bare = parseJson('{ "dependencies": [1] }');
	assert bare.ok;
	if (bare.ok) assert parseVersionRecord(bare.value).depKeys.length == 0;
}

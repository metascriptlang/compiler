// Registry — HTTP client for the MetaScript package registry API.
// Endpoints:
//   GET /packages/:name           → package metadata + all versions
//   GET /packages/:name/:version  → specific version (integrity, archiveUrl, deps)
//   GET /packages/:name/-/:file   → archive download (redirects to R2 signed URL)
//
// API reference: ~/metascript/landing/apps/api/src/routes/packages.ts

import { fetch } from "std/http/client";
import { HttpError, httpError, HttpErrorKind, invalidResponse } from "std/http/errors";
import { parseJson, JsonValue, JsonKind } from "std/core/json";

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

// ===== JSON Helpers =====

function getStr(obj: JsonValue, field: string): string {
	if (obj === null || obj.kind !== JsonKind.Object) return "";
	let i = 0;
	while (i < obj.keys.length) {
		if (obj.keys[i] === field && i < obj.values.length) {
			const v = obj.values[i];
			if (v !== null && v.kind === JsonKind.String) return v.strVal;
		}
		i = i + 1;
	}
	return "";
}

function getObj(obj: JsonValue, field: string): JsonValue {
	if (obj === null || obj.kind !== JsonKind.Object) return null as unknown as JsonValue;
	let i = 0;
	while (i < obj.keys.length) {
		if (obj.keys[i] === field && i < obj.values.length) return obj.values[i];
		i = i + 1;
	}
	return null as unknown as JsonValue;
}

function getArray(obj: JsonValue, field: string): JsonValue[] {
	const empty: JsonValue[] = [];
	const arr = getObj(obj, field);
	if (arr === null || arr.kind !== JsonKind.Array) return empty;
	return arr.items;
}

// Flatten a JSON object into parallel key/value arrays of strings.
function parseDeps(depsObj: JsonValue): { keys: string[], values: string[] } {
	const keys: string[] = [];
	const values: string[] = [];
	if (depsObj === null || depsObj.kind !== JsonKind.Object) return { keys: keys, values: values };
	let i = 0;
	while (i < depsObj.keys.length) {
		keys.push(depsObj.keys[i]);
		if (i < depsObj.values.length && depsObj.values[i] !== null && depsObj.values[i].kind === JsonKind.String) {
			values.push(depsObj.values[i].strVal);
		} else {
			values.push("");
		}
		i = i + 1;
	}
	return { keys: keys, values: values };
}

function parseVersionRecord(v: JsonValue): RegistryVersion {
	const deps = parseDeps(getObj(v, "dependencies"));
	return {
		version: getStr(v, "version"),
		integrity: getStr(v, "integrity"),
		archiveUrl: getStr(v, "archiveUrl"),
		publishedAt: getStr(v, "publishedAt"),
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
// "alice/router"  → "/packages/~alice/router"
// "@acme/router"  → "/packages/@acme/router"
function packageApiPath(name: string): string {
	if (name.length > 0 && name.charAt(0) === "@") {
		// Org-scoped: @acme/router → /packages/@acme/router
		return "/packages/" + name;
	}
	// Check for user scope (contains /)
	let slashIdx = -1;
	let i = 0;
	while (i < name.length) {
		if (name.charAt(i) === "/") { slashIdx = i; i = name.length; }
		i = i + 1;
	}
	if (slashIdx > 0) {
		// User-scoped: alice/router → /packages/~alice/router
		return "/packages/~" + name;
	}
	// Unscoped
	return "/packages/" + name;
}

// Fetch package metadata including all published versions.
// Returns null on network error or missing package.
export function fetchPackageInfo(name: string): Result<RegistryPackage, HttpError> {
	const url = registryBaseUrl() + packageApiPath(name);
	const resp = try fetch(url);
	if (resp.status === 404) {
		return Result.err(httpError(HttpErrorKind.InvalidResponse, "package not found: " + name));
	}
	if (resp.status !== 200) {
		return Result.err(httpError(HttpErrorKind.InvalidResponse, "registry returned HTTP " + resp.status.toString()));
	}

	const parsed = parseJson(resp.body);
	if (!parsed.ok || parsed.value.kind !== JsonKind.Object) {
		return Result.err(invalidResponse("invalid JSON from registry"));
	}
	const obj = parsed.value;

	const versionItems = getArray(obj, "versions");
	const versions: RegistryVersion[] = [];
	let i = 0;
	while (i < versionItems.length) {
		versions.push(parseVersionRecord(versionItems[i]));
		i = i + 1;
	}

	return Result.ok({
		name: getStr(obj, "name"),
		description: getStr(obj, "description"),
		license: getStr(obj, "license"),
		repository: getStr(obj, "repository"),
		homepage: getStr(obj, "homepage"),
		versions: versions,
	});
}

// Find a specific version in a RegistryPackage. Returns null if not found.
export function findVersion(pkg: RegistryPackage, version: string): RegistryVersion {
	let i = 0;
	while (i < pkg.versions.length) {
		if (pkg.versions[i].version === version) return pkg.versions[i];
		i = i + 1;
	}
	return null as unknown as RegistryVersion;
}

// Get the latest version (first in the versions array — server orders by publishedAt DESC).
export function latestVersion(pkg: RegistryPackage): RegistryVersion {
	if (pkg.versions.length === 0) return null as unknown as RegistryVersion;
	return pkg.versions[0];
}

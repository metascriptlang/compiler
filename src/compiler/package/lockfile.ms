// Lockfile — read/write msc.lock via std/json.
// Format: { "version": 1, "packages": { "name@ver": { "source": "registry", ... } } }
// See docs/PACKAGE.md for full specification.

import { exists, readFile, writeFile } from "std/fs";
import { parseJson, jsonObject, jsonString, jsonNumber, stringify, stringifyPretty } from "std/core/json";
import { JsonValue, JsonKind } from "std/core/json";

// --- Types ---

export interface LockEntry {
	key: string;          // "name@version" or "alias@git:url@sha"
	source: string;       // "registry" or "git"
	version: string;      // "1.2.3" (registry) or "" (git)
	integrity: string;    // "sha256-..." or "" (not yet downloaded)
	url: string;          // "" (registry) or "github.com/owner/repo" (git)
	gitRef: string;       // "" (registry) or tag/sha (git)
	commit: string;       // "" (registry) or full 40-char SHA (git)
	depKeys: string[];    // transitive dep names
	depValues: string[];  // transitive dep versions (parallel array)
}

export interface Lockfile {
	version: number;
	entries: LockEntry[];
	valid: boolean;
}

// --- Read ---

function getStr(obj: JsonValue, field: string): string {
	if (obj == null || obj.kind != JsonKind.Object) return "";
	let i = 0;
	while (i < obj.keys.length) {
		if (obj.keys[i] == field && i < obj.values.length) {
			const v = obj.values[i];
			if (v != null && v.kind == JsonKind.String) return v.strVal;
			if (v != null && v.kind == JsonKind.Number) return v.numVal.toString();
		}
		i = i + 1;
	}
	return "";
}

function getNum(obj: JsonValue, field: string): number {
	if (obj == null || obj.kind != JsonKind.Object) return -1;
	let i = 0;
	while (i < obj.keys.length) {
		if (obj.keys[i] == field && i < obj.values.length) {
			const v = obj.values[i];
			if (v != null && v.kind == JsonKind.Number) return v.numVal;
			if (v != null && v.kind == JsonKind.Int) return v.intVal as number;
		}
		i = i + 1;
	}
	return -1;
}

function getObj(obj: JsonValue, field: string): JsonValue {
	if (obj == null || obj.kind != JsonKind.Object) return null as unknown as JsonValue;
	let i = 0;
	while (i < obj.keys.length) {
		if (obj.keys[i] == field && i < obj.values.length) {
			return obj.values[i];
		}
		i = i + 1;
	}
	return null as unknown as JsonValue;
}

function parseDeps(depsObj: JsonValue): { keys: string[], values: string[] } {
	const keys: string[] = [];
	const values: string[] = [];
	if (depsObj == null || depsObj.kind != JsonKind.Object) return { keys, values };
	let i = 0;
	while (i < depsObj.keys.length) {
		keys.push(depsObj.keys[i]);
		if (i < depsObj.values.length) {
			const el = depsObj.values[i];
			if (el != null && el.kind == JsonKind.String) {
				values.push(el.strVal);
			} else {
				values.push("");
			}
		} else {
			values.push("");
		}
		i = i + 1;
	}
	return { keys, values };
}

export function readLockfile(path: string): Lockfile {
	const invalid: Lockfile = { version: 0, entries: [], valid: false };
	if (!exists(path)) return invalid;
	const content = try readFile(path) catch "";
	if (content == "") return invalid;
	const parsed = parseJson(content);
	if (!parsed.ok) return invalid;
	const root = parsed.value;
	if (root == null || root.kind != JsonKind.Object) return invalid;

	const ver = getNum(root, "version");
	if (ver != 1) return invalid;

	const pkgsObj = getObj(root, "packages");
	if (pkgsObj == null || pkgsObj.kind != JsonKind.Object) return invalid;

	const entries: LockEntry[] = [];
	let pi = 0;
	while (pi < pkgsObj.keys.length) {
		const key = pkgsObj.keys[pi];
		const entryObj = pi < pkgsObj.values.length ? pkgsObj.values[pi] : null as unknown as JsonValue;
		if (entryObj != null && entryObj.kind == JsonKind.Object) {
			const source = getStr(entryObj, "source");
			const deps = parseDeps(getObj(entryObj, "deps"));
			const entry: LockEntry = {
				key,
				source: source != "" ? source : "registry",
				version: getStr(entryObj, "version"),
				integrity: getStr(entryObj, "integrity"),
				url: getStr(entryObj, "url"),
				gitRef: getStr(entryObj, "ref"),
				commit: getStr(entryObj, "commit"),
				depKeys: deps.keys,
				depValues: deps.values,
			};
			entries.push(entry);
		}
		pi = pi + 1;
	}

	return { version: 1, entries, valid: true };
}

// --- Write ---

export function writeLockfile(path: string, lock: Lockfile): boolean {
	// Build JSON manually via jsonObject
	const pkgKeys: string[] = [];
	const pkgValues: JsonValue[] = [];

	for (const entry of lock.entries) {
		pkgKeys.push(entry.key);

		const eKeys: string[] = [];
		const eValues: JsonValue[] = [];

		eKeys.push("source");
		eValues.push(jsonString(entry.source));

		if (entry.source == "registry") {
			eKeys.push("version");
			eValues.push(jsonString(entry.version));
		}

		if (entry.integrity != "") {
			eKeys.push("integrity");
			eValues.push(jsonString(entry.integrity));
		}

		if (entry.source == "git") {
			eKeys.push("url");
			eValues.push(jsonString(entry.url));
			eKeys.push("ref");
			eValues.push(jsonString(entry.gitRef));
			eKeys.push("commit");
			eValues.push(jsonString(entry.commit));
		}

		// Deps sub-object
		const dKeys: string[] = [];
		const dValues: JsonValue[] = [];
		let di = 0;
		while (di < entry.depKeys.length) {
			dKeys.push(entry.depKeys[di]);
			dValues.push(jsonString(di < entry.depValues.length ? entry.depValues[di] : ""));
			di = di + 1;
		}
		eKeys.push("deps");
		eValues.push(jsonObject(dKeys, dValues));

		pkgValues.push(jsonObject(eKeys, eValues));
	}

	const rootKeys: string[] = ["version", "packages"];
	const rootValues: JsonValue[] = [jsonNumber(1), jsonObject(pkgKeys, pkgValues)];
	const rootObj = jsonObject(rootKeys, rootValues);

	const json = stringifyPretty(rootObj, 2);
	const result = writeFile(path, json);
	return result.ok;
}

// --- Helpers ---

export function findEntry(lock: Lockfile, name: string, version: string): LockEntry {
	const key = name + "@" + version;
	for (const entry of lock.entries) {
		if (entry.key == key) return entry;
	}
	return null as unknown as LockEntry;
}

// Extract the package name from a lock entry key.
// Unscoped:  "cool-json@v1.2.3"           → "cool-json"
// Git:       "my-fork@git:github.com/..."  → "my-fork"
// Personal:  "alice/router@1.0.0"          → "alice/router"
// Org:       "@acme/router@1.0.0"          → "@acme/router"
export function entryName(key: string): string {
	// Org-scoped: starts with @, find / then find @ after /
	if (key.length > 0 && key.charAt(0) == "@") {
		let slashIdx = -1;
		let si = 1;
		while (si < key.length) {
			if (key.charAt(si) == "/") { slashIdx = si; si = key.length; }
			si = si + 1;
		}
		if (slashIdx > 0) {
			let ai = slashIdx + 1;
			while (ai < key.length) {
				if (key.charAt(ai) == "@") return key.slice(0, ai);
				ai = ai + 1;
			}
			return key;
		}
	}
	// Find first @ and first /
	let firstAt = -1;
	let firstSlash = -1;
	let i = 0;
	while (i < key.length) {
		if (key.charAt(i) == "@" && firstAt == -1) firstAt = i;
		if (key.charAt(i) == "/" && firstSlash == -1) firstSlash = i;
		i = i + 1;
	}
	// If @ comes before / (or no /), it's unscoped or git — split on first @
	// e.g. "cool-json@1.0.0" or "my-fork@git:github.com/..."
	if (firstAt > 0 && (firstSlash == -1 || firstAt < firstSlash)) {
		return key.slice(0, firstAt);
	}
	// User-scoped: / comes before @ — e.g. "alice/router@1.0.0"
	if (firstSlash > 0) {
		let ai = firstSlash + 1;
		while (ai < key.length) {
			if (key.charAt(ai) == "@") return key.slice(0, ai);
			ai = ai + 1;
		}
		return key;
	}
	// No @ at all
	return key;
}

// --- Inline tests ---

test "readLockfile empty file" {
	const lock = readLockfile("/nonexistent/path/msc.lock");
	assert !lock.valid;
}

test "entryName registry" {
	assert entryName("cool-json@v1.2.3") == "cool-json";
}

test "entryName git" {
	assert entryName("my-fork@git:github.com/me/foo@abc123") == "my-fork";
}

test "entryName org-scoped" {
	assert entryName("@acme/router@1.0.0") == "@acme/router";
}

test "entryName user-scoped" {
	assert entryName("alice/router@1.0.0") == "alice/router";
}

test "entryName org-scoped no version" {
	assert entryName("@acme/router") == "@acme/router";
}

test "entryName user-scoped no version" {
	assert entryName("alice/router") == "alice/router";
}

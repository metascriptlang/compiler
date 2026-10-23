// Lockfile — read/write msc.lock via std/json.
// Format: { "version": 1, "packages": { "name@ver": { "source": "registry", ... } } }
// See docs/PACKAGE.md for full specification.

import { exists, readFile, writeFile } from "std/fs";
import { parseJson, jsonObject, jsonString, jsonNumber, stringify, stringifyPretty } from "std/core/json";
import { JsonValue, JsonKind } from "std/core/json";
import { SourceKind } from "./version";

// --- Types ---

export interface LockEntry {
	key: string;          // "name@version" or "alias@git:url@sha"
	source: SourceKind;
	version: string;      // "1.2.3" (registry) or "" (git)
	integrity: string;    // "sha256-..." or "" (not yet downloaded)
	url: string;          // "" (registry) or "github.com/owner/repo" (git)
	gitRef: string;       // "" (registry) or tag/sha (git)
	commit: string;       // "" (registry) or full 40-char SHA (git)
	depKeys: string[];    // transitive dep names
	depValues: string[];  // transitive dep versions (parallel array)
}

export interface Lockfile {
	version: int32;
	entries: LockEntry[];
}

export enum LockfileError {
	Missing,
	Unreadable,
	Empty,
	BadJson,
	BadVersion,
	BadShape,
	Write,
}

export function lockfileErrorMessage(e: LockfileError): string {
	return match (e) {
		LockfileError.Missing => "msc.lock not found",
		LockfileError.Unreadable => "msc.lock could not be read",
		LockfileError.Empty => "msc.lock is empty",
		LockfileError.BadJson => "msc.lock is not valid JSON",
		LockfileError.BadVersion => "msc.lock has no supported version (expected \"version\": 1)",
		LockfileError.BadShape => "msc.lock does not have the expected structure",
		LockfileError.Write => "failed to write msc.lock",
	};
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

function sourceKindFor(name: string): Result<SourceKind, LockfileError> {
	return match (name) {
		"" | "registry" => Result.ok(SourceKind.Registry),
		"git" => Result.ok(SourceKind.Git),
		_ => Result.err(LockfileError.BadShape),
	};
}

function sourceName(kind: SourceKind): string {
	return match (kind) {
		SourceKind.Registry => "registry",
		SourceKind.Git => "git",
	};
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

export function parseLockfile(content: string): Result<Lockfile, LockfileError> {
	if (content == "") return Result.err(LockfileError.Empty);
	const parsed = parseJson(content);
	if (!parsed.ok) return Result.err(LockfileError.BadJson);
	const root = parsed.value;
	if (root == null || root.kind != JsonKind.Object) return Result.err(LockfileError.BadShape);

	const versionVal = getObj(root, "version");
	if (versionVal == null || versionVal.asNumber(-1) != 1) return Result.err(LockfileError.BadVersion);

	const pkgsObj = getObj(root, "packages");
	if (pkgsObj == null || pkgsObj.kind != JsonKind.Object) return Result.err(LockfileError.BadShape);

	const entries: LockEntry[] = [];
	for (let pi = 0; pi < pkgsObj.keys.length; pi++) {
		if (pi >= pkgsObj.values.length) return Result.err(LockfileError.BadShape);
		const entryObj = pkgsObj.values[pi];
		if (entryObj == null || entryObj.kind != JsonKind.Object) return Result.err(LockfileError.BadShape);
		const source = try sourceKindFor(getStr(entryObj, "source"));
		const deps = parseDeps(getObj(entryObj, "deps"));
		entries.push({
			key: pkgsObj.keys[pi],
			source,
			version: getStr(entryObj, "version"),
			integrity: getStr(entryObj, "integrity"),
			url: getStr(entryObj, "url"),
			gitRef: getStr(entryObj, "ref"),
			commit: getStr(entryObj, "commit"),
			depKeys: deps.keys,
			depValues: deps.values,
		});
	}

	return Result.ok({ version: 1, entries });
}

export function readLockfile(path: string): Result<Lockfile, LockfileError> {
	if (!exists(path)) return Result.err(LockfileError.Missing);
	const content = readFile(path);
	if (!content.ok) return Result.err(LockfileError.Unreadable);
	return parseLockfile(content.value);
}

// --- Write ---

export function writeLockfile(path: string, lock: Lockfile): Result<void, LockfileError> {
	// Build JSON manually via jsonObject
	const pkgKeys: string[] = [];
	const pkgValues: JsonValue[] = [];

	for (const entry of lock.entries) {
		pkgKeys.push(entry.key);

		const eKeys: string[] = [];
		const eValues: JsonValue[] = [];

		eKeys.push("source");
		eValues.push(jsonString(sourceName(entry.source)));

		if (entry.source == SourceKind.Registry) {
			eKeys.push("version");
			eValues.push(jsonString(entry.version));
		}

		if (entry.integrity != "") {
			eKeys.push("integrity");
			eValues.push(jsonString(entry.integrity));
		}

		if (entry.source == SourceKind.Git) {
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
	if (!writeFile(path, json).ok) return Result.err(LockfileError.Write);
	return Result.ok(null);
}

// --- Helpers ---

export function findEntry(lock: Lockfile, name: string, version: string): LockEntry | null {
	const key = name + "@" + version;
	for (const entry of lock.entries) {
		if (entry.key == key) return entry;
	}
	return null;
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

test "a lockfile that does not exist is Missing" {
	const lock = readLockfile("/nonexistent/path/msc.lock");
	assert !lock.ok;
	if (!lock.ok) assert lock.error == LockfileError.Missing;
}

function parseError(content: string): LockfileError {
	const r = parseLockfile(content);
	if (r.ok) return LockfileError.Write;
	return r.error;
}

test "a corrupt lockfile is told apart from a missing one" {
	assert parseError("") == LockfileError.Empty;
	assert parseError("{ \"version\": ") == LockfileError.BadJson;
	assert parseError("[]") == LockfileError.BadShape;
	assert parseError("{ \"version\": 2, \"packages\": {} }") == LockfileError.BadVersion;
	assert parseError("{ \"packages\": {} }") == LockfileError.BadVersion;
	assert parseError("{ \"version\": 1 }") == LockfileError.BadShape;
	assert parseError("{ \"version\": 1, \"packages\": { \"a@1.0.0\": 7 } }") == LockfileError.BadShape;
	assert parseError("{ \"version\": 1, \"packages\": { \"a@1.0.0\": { \"source\": \"svn\" } } }") == LockfileError.BadShape;
}

test "a git entry reads as a Git source and a bare entry as Registry" {
	const content = "{ \"version\": 1, \"packages\": { \"fork@git:github.com/me/foo@abc\": { \"source\": \"git\", \"url\": \"github.com/me/foo\" }, \"bare@1.0.0\": {} } }";
	const r = parseLockfile(content);
	assert r.ok;
	if (r.ok) {
		assert r.value.entries[0].source == SourceKind.Git;
		assert r.value.entries[1].source == SourceKind.Registry;
	}
}

test "a valid lockfile keeps its entries, deps and source" {
	const content = "{ \"version\": 1, \"packages\": { \"cool-json@1.2.3\": { \"source\": \"registry\", \"version\": \"1.2.3\", \"integrity\": \"sha256-abc\", \"deps\": { \"dep\": \"0.1.0\" } } } }";
	const r = parseLockfile(content);
	assert r.ok;
	if (r.ok) {
		assert r.value.entries.length == 1;
		assert r.value.entries[0].key == "cool-json@1.2.3";
		assert r.value.entries[0].depKeys[0] == "dep";
		assert r.value.entries[0].depValues[0] == "0.1.0";
		assert findEntry(r.value, "cool-json", "1.2.3") != null;
		assert findEntry(r.value, "cool-json", "9.9.9") == null;
	}
}

test "writing under a missing directory is a Write error" {
	const w = writeLockfile("/nonexistent/path/msc.lock", { version: 1, entries: [] });
	assert !w.ok;
	if (!w.ok) assert w.error == LockfileError.Write;
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

// Module Resolver — translates import specifiers to candidate file paths
//
// Resolution algorithm (backend-aware, React Native pattern):
//   1. Apply alias rewriting (if configured)
//   2. Classify: relative (./foo), std (std/foo), or bare (foo)
//   3. For each base path, try extensions in priority order:
//      backend-specific (.cms/.jms/.rms/.ems/.wms) → .ms → .ts → .js
//   4. Both direct file and /index.* variants
//
// Pure function — no filesystem access. The loader tries candidates in order.

import { dirname, join, normalize } from "std/fs/path";
// (utils/string imports removed — using native .slice)

// ===== Backend Enum =====

export enum Backend {
	C, JS, Raiser, Erlang, Wasm,
}

// ===== Resolution Result =====

export type ResolveCandidates = string[];

// ===== Resolver Configuration =====
// Pure data — no FS access, no caching. Passed through from CLI/build.ms.

export interface ResolverConfig {
	backend: Backend;
	stdPath: string;           // absolute path to std library root (e.g., "/usr/lib/msc/std")
	searchPaths: string[];     // extra root dirs for bare imports
	extensions: string[];      // ordered extension list [".cms", ".ms", ".ts", ".js"]
	aliasKeys: string[];       // alias prefixes ["@app", "@lib"]
	aliasValues: string[];     // alias targets ["./src", "./lib"] (parallel with keys)
}

// ===== Backend Extension Mapping =====

export function backendExtension(backend: Backend): string {
	return match (backend) {
		Backend.C => ".cms",
		Backend.JS => ".jms",
		Backend.Raiser => ".rms",
		Backend.Erlang => ".ems",
		Backend.Wasm => ".wms",
		_ => ".ms",
	};
}

// ===== Default Config Constructor =====

export function createDefaultConfig(backend: Backend, stdPath: string): ResolverConfig {
	const ext = backendExtension(backend);
	const extensions: string[] = [];
	extensions.push(ext);
	extensions.push(".ms");
	extensions.push(".ts");
	extensions.push(".js");
	return {
		backend,
		stdPath,
		searchPaths: [],
		extensions,
		aliasKeys: [],
		aliasValues: [],
	};
}

// Minimal config for bare mode (2-arg resolveImport callers).
// Only resolves .ms, no std path, no search paths.
function bareConfig(): ResolverConfig {
	const extensions: string[] = [];
	extensions.push(".ms");
	return {
		backend: Backend.C,
		stdPath: "",
		searchPaths: [],
		extensions,
		aliasKeys: [],
		aliasValues: [],
	};
}

// ===== Import Resolution (Full) =====

export function resolveImportWithConfig(specifier: string, fromFile: string, config: ResolverConfig): ResolveCandidates {
	let result: ResolveCandidates = [];

	// Apply alias rewriting
	const spec = applyAlias(specifier, config);

	// If specifier already has a known extension, return just that path
	if (hasKnownExtension(spec)) {
		result = addDirectCandidates(result, spec, fromFile, config);
		return result;
	}

	// Classify and resolve
	if (isRelative(spec)) {
		// Relative: ./foo, ../bar — normalize to collapse ./ and ../ segments
		const baseDir = dirname(fromFile);
		const base = normalize(join(baseDir, spec));
		result = addExtensionCandidates(result, base, config.extensions);
	} else if (isStdImport(spec)) {
		// Std library: std/testing → stdPath + "/testing"
		if (config.stdPath.length > 0) {
			const subpath = spec.slice(4, spec.length);
			const base = join(config.stdPath, subpath);
			result = addExtensionCandidates(result, base, config.extensions);
		}
		// If no stdPath configured, return empty (handled externally)
	} else {
		// Bare import: try each search path
		for (const sp of config.searchPaths) {
			const base = join(sp, spec);
			result = addExtensionCandidates(result, base, config.extensions);
		}
	}

	return result;
}

// ===== Backward-Compatible Import Resolution =====
// Bare 2-arg version — std imports return empty, only .ms extension.

export function resolveImport(specifier: string, fromFile: string): ResolveCandidates {
	const result: ResolveCandidates = [];

	// Std library — handled externally in bare mode
	if (isStdImport(specifier)) return result;

	// Bare specifiers — unsupported in legacy mode
	if (!isRelative(specifier)) return result;

	const baseDir = dirname(fromFile);
	const base = join(baseDir, specifier);

	// If specifier has a known extension (.h, .ms, etc.), use it directly
	if (hasKnownExtension(specifier)) {
		result.push(base);
		return result;
	}

	// Relative imports: two candidates (.ms only)
	result.push(base + ".ms");
	result.push(join(base, "index.ms"));

	return result;
}

// ===== Candidate Generation =====

// For a base path (without extension), add direct + index candidates for each extension.
function addExtensionCandidates(result: ResolveCandidates, base: string, extensions: string[]): ResolveCandidates {
	// Direct file candidates: base + ext
	for (const ext of extensions) {
		result.push(base + ext);
	}
	// Index file candidates: base/index + ext
	for (const ext of extensions) {
		result.push(join(base, "index" + ext));
	}
	return result;
}

// For a specifier with an explicit extension, resolve it directly.
function addDirectCandidates(result: ResolveCandidates, spec: string, fromFile: string, config: ResolverConfig): ResolveCandidates {
	if (isRelative(spec)) {
		const baseDir = dirname(fromFile);
		result.push(join(baseDir, spec));
	} else if (isStdImport(spec)) {
		if (config.stdPath.length > 0) {
			const subpath = spec.slice(4, spec.length);
			result.push(join(config.stdPath, subpath));
		}
	} else {
		// Bare with extension — try search paths
		for (const sp of config.searchPaths) {
			result.push(join(sp, spec));
		}
	}
	return result;
}

// ===== Alias Rewriting =====

function applyAlias(specifier: string, config: ResolverConfig): string {
	let i = 0;
	while (i < config.aliasKeys.length) {
		const key = config.aliasKeys[i];
		if (specifier.length >= key.length && specifier.slice(0, key.length) === key) {
			// Check that alias matches at word boundary: exact match or followed by /
			if (specifier.length === key.length) {
				return config.aliasValues[i];
			}
			if (specifier.charCodeAt(key.length) === "/".code) {
				return config.aliasValues[i] + specifier.slice(key.length, specifier.length);
			}
		}
		i = i + 1;
	}
	return specifier;
}

// ===== MetaScript Module Extensions =====

// Authoritative list of MetaScript source extensions (no .ts/.js/.h).
export const msModuleExtensions: string[] = [".cms", ".ms", ".jms", ".rms", ".ems", ".wms"];

// Check if a filename has a MetaScript module extension.
export function isMsModuleExtension(name: string): boolean {
	for (const ext of msModuleExtensions) {
		if (name.length > ext.length && name.endsWith(ext)) return true;
	}
	return false;
}

// Strip a MetaScript extension from a filename, returning "" if not a MS file.
export function stripMsModuleExtension(name: string): string {
	for (const ext of msModuleExtensions) {
		if (name.length > ext.length && name.endsWith(ext)) {
			return name.slice(0, name.length - ext.length);
		}
	}
	return "";
}

// ===== Extension Detection =====

function hasKnownExtension(specifier: string): boolean {
	return specifier.endsWith(".ms")
		|| specifier.endsWith(".cms")
		|| specifier.endsWith(".jms")
		|| specifier.endsWith(".rms")
		|| specifier.endsWith(".ems")
		|| specifier.endsWith(".wms")
		|| specifier.endsWith(".ts")
		|| specifier.endsWith(".js")
		|| specifier.endsWith(".h");
}

// ===== Helpers =====

export function isStdImport(specifier: string): boolean {
	if (specifier.length < 4) return false;
	return specifier.slice(0, 4) === "std/";
}

function isRelative(specifier: string): boolean {
	if (specifier.length < 2) return false;
	const prefix = specifier.slice(0, 2);
	return prefix === "./" || prefix === "..";
}

// ===== Legacy Helpers (kept for backward compat) =====

export function buildFilePath(specifier: string, fromFile: string): string {
	const baseDir = dirname(fromFile);
	return join(baseDir, specifier + ".ms");
}

export function buildIndexPath(specifier: string, fromFile: string): string {
	const baseDir = dirname(fromFile);
	return join(baseDir, join(specifier, "index.ms"));
}

// ===== Tests =====
// -- Legacy (2-arg) backward compat --
test "std imports return empty (legacy)" {
	const r1 = resolveImport("std/testing", "/a/b.ms");
	assert r1.length === 0;
	const r2 = resolveImport("std/fs/path", "/a/b.ms");
	assert r2.length === 0;
}

test "bare imports return empty (legacy)" {
	const r = resolveImport("lodash", "/a/b.ms");
	assert r.length === 0;
}

test "relative import returns two candidates (legacy)" {
	const r = resolveImport("./foo", "/a/b.ms");
	assert r.length === 2;
	assert r[0] === "/a/foo.ms";
	assert r[1] === "/a/foo/index.ms";
}

test "parent directory import (legacy)" {
	const r = resolveImport("../bar", "/a/b/c.ms");
	assert r.length === 2;
	assert r[0] === "/a/bar.ms";
	assert r[1] === "/a/bar/index.ms";
}

test "nested relative import (legacy)" {
	const r = resolveImport("./sub/mod", "/proj/src/index.ms");
	assert r.length === 2;
	assert r[0] === "/proj/src/sub/mod.ms";
	assert r[1] === "/proj/src/sub/mod/index.ms";
}

test "isStdImport" {
	assert isStdImport("std/fs");
	assert isStdImport("std/testing");
	assert !isStdImport("./foo");
	assert !isStdImport("ab");
}

test "buildFilePath" { assert buildFilePath("./foo", "/a/b.ms") === "/a/foo.ms"; }

test "buildIndexPath" { assert buildIndexPath("./sub", "/a/b.ms") === "/a/sub/index.ms"; }
// -- Backend extension mapping --
test "backendExtension C" { assert backendExtension(Backend.C) === ".cms"; }

test "backendExtension JS" { assert backendExtension(Backend.JS) === ".jms"; }

test "backendExtension Raiser" { assert backendExtension(Backend.Raiser) === ".rms"; }

test "backendExtension Erlang" { assert backendExtension(Backend.Erlang) === ".ems"; }

test "backendExtension Wasm" { assert backendExtension(Backend.Wasm) === ".wms"; }
// -- Default config --
test "createDefaultConfig C has 4 extensions" {
	const cfg = createDefaultConfig(Backend.C, "/usr/lib/msc/std");
	assert cfg.extensions.length === 4;
	assert cfg.extensions[0] === ".cms";
	assert cfg.extensions[1] === ".ms";
	assert cfg.extensions[2] === ".ts";
	assert cfg.extensions[3] === ".js";
	assert cfg.stdPath === "/usr/lib/msc/std";
}

test "createDefaultConfig JS has .jms first" {
	const cfg = createDefaultConfig(Backend.JS, "/std");
	assert cfg.extensions[0] === ".jms";
}
// -- Full resolution with config --
test "relative with C backend generates 8 candidates" {
	const cfg = createDefaultConfig(Backend.C,"");
	const r = resolveImportWithConfig("./foo", "/a/b.ms", cfg);
	assert r.length === 8;
	assert r[0] === "/a/foo.cms";
	assert r[1] === "/a/foo.ms";
	assert r[2] === "/a/foo.ts";
	assert r[3] === "/a/foo.js";
	assert r[4] === "/a/foo/index.cms";
	assert r[5] === "/a/foo/index.ms";
	assert r[6] === "/a/foo/index.ts";
	assert r[7] === "/a/foo/index.js";
}

test "std/ with config resolves against stdPath" {
	const cfg = createDefaultConfig(Backend.C,"/lib/std");
	const r = resolveImportWithConfig("std/testing", "/a/b.ms", cfg);
	assert r.length === 8;
	assert r[0] === "/lib/std/testing.cms";
	assert r[1] === "/lib/std/testing.ms";
	assert r[4] === "/lib/std/testing/index.cms";
	assert r[5] === "/lib/std/testing/index.ms";
}

test "std/ without stdPath returns empty" {
	const cfg = createDefaultConfig(Backend.C,"");
	const r = resolveImportWithConfig("std/testing", "/a/b.ms", cfg);
	assert r.length === 0;
}

test "bare import with search paths" {
	const cfg = createDefaultConfig(Backend.C,"");
	cfg.searchPaths.push("/proj/lib");
	cfg.searchPaths.push("/proj/vendor");
	const r = resolveImportWithConfig("ui/grid", "/a/b.ms", cfg);
	// 2 search paths x 8 candidates each = 16
	assert r.length === 16;
	assert r[0] === "/proj/lib/ui/grid.cms";
	assert r[1] === "/proj/lib/ui/grid.ms";
	assert r[8] === "/proj/vendor/ui/grid.cms";
}

test "bare import without search paths returns empty" {
	const cfg = createDefaultConfig(Backend.C,"");
	const r = resolveImportWithConfig("lodash", "/a/b.ms", cfg);
	assert r.length === 0;
}

test "alias rewriting" {
	const cfg = createDefaultConfig(Backend.C,"");
	cfg.aliasKeys.push("@app");
	cfg.aliasValues.push("./src");
	const r = resolveImportWithConfig("@app/utils", "/proj/index.ms", cfg);
	// Alias rewrites to ./src/utils, then relative resolution
	assert r.length === 8;
	assert r[0] === "/proj/src/utils.cms";
	assert r[1] === "/proj/src/utils.ms";
}

test "alias exact match" {
	const cfg = createDefaultConfig(Backend.JS,"");
	cfg.aliasKeys.push("@root");
	cfg.aliasValues.push("./src/index");
	const r = resolveImportWithConfig("@root", "/proj/main.ms", cfg);
	assert r.length === 8;
	assert r[0] === "/proj/src/index.jms";
	assert r[1] === "/proj/src/index.ms";
}

test "alias does not match partial prefix" {
	const cfg = createDefaultConfig(Backend.C,"");
	cfg.aliasKeys.push("@app");
	cfg.aliasValues.push("./src");
	// "@application" should NOT match "@app" alias
	const r = resolveImportWithConfig("@application", "/proj/index.ms", cfg);
	assert r.length === 0; // bare import, no search paths
}

test "explicit extension skips probing" {
	const cfg = createDefaultConfig(Backend.C,"");
	const r = resolveImportWithConfig("./foo.ms", "/a/b.ms", cfg);
	assert r.length === 1;
	assert r[0] === "/a/foo.ms";
}

test "explicit .ts extension" {
	const cfg = createDefaultConfig(Backend.C,"");
	const r = resolveImportWithConfig("./lib.ts", "/a/b.ms", cfg);
	assert r.length === 1;
	assert r[0] === "/a/lib.ts";
}

test "explicit .cms extension" {
	const cfg = createDefaultConfig(Backend.C,"/std");
	const r = resolveImportWithConfig("std/core.cms", "/a/b.ms", cfg);
	assert r.length === 1;
	assert r[0] === "/std/core.cms";
}

test "explicit .h extension resolves directly" {
	const cfg = createDefaultConfig(Backend.C,"");
	const r = resolveImportWithConfig("./dawn.h", "/a/b.ms", cfg);
	assert r.length === 1;
	assert r[0] === "/a/dawn.h";
}

test "JS backend uses .jms first" {
	const cfg = createDefaultConfig(Backend.JS,"");
	const r = resolveImportWithConfig("./parser", "/a/b.ms", cfg);
	assert r[0] === "/a/parser.jms";
	assert r[1] === "/a/parser.ms";
}

test "Raiser backend uses .rms first" {
	const cfg = createDefaultConfig(Backend.Raiser,"");
	const r = resolveImportWithConfig("./vm", "/a/b.ms", cfg);
	assert r[0] === "/a/vm.rms";
}

test "parent dir with config" {
	const cfg = createDefaultConfig(Backend.C,"");
	const r = resolveImportWithConfig("../bar", "/a/b/c.ms", cfg);
	assert r[0] === "/a/bar.cms";
	assert r[1] === "/a/bar.ms";
}

test "std nested path" {
	const cfg = createDefaultConfig(Backend.C,"/lib/std");
	const r = resolveImportWithConfig("std/fs/path", "/a/b.ms", cfg);
	assert r[0] === "/lib/std/fs/path.cms";
	assert r[1] === "/lib/std/fs/path.ms";
}

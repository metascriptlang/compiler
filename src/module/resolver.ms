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

import { dirname, join } from "std/fs/path";
import { test, check, testGroup } from "std/testing";
import { sliceStr, endsWith } from "../utils/string";

// ===== Backend Constants =====

export const BACKEND_C = 0;
export const BACKEND_JS = 1;
export const BACKEND_RAISER = 2;
export const BACKEND_ERLANG = 3;
export const BACKEND_WASM = 4;

// ===== Resolution Result =====
// Wraps string[] in interface to avoid DRC value-type gotcha (#4).

export interface ResolveCandidates {
	paths: string[];
}

// ===== Resolver Configuration =====
// Pure data — no FS access, no caching. Passed through from CLI/build.ms.

export interface ResolverConfig {
	backend: number;           // BACKEND_C, BACKEND_JS, etc.
	stdPath: string;           // absolute path to std library root (e.g., "/usr/lib/msc/std")
	searchPaths: string[];     // extra root dirs for bare imports
	extensions: string[];      // ordered extension list [".cms", ".ms", ".ts", ".js"]
	aliasKeys: string[];       // alias prefixes ["@app", "@lib"]
	aliasValues: string[];     // alias targets ["./src", "./lib"] (parallel with keys)
}

// ===== Backend Extension Mapping =====

export function backendExtension(backend: number): string {
	if (backend === BACKEND_C) return ".cms";
	if (backend === BACKEND_JS) return ".jms";
	if (backend === BACKEND_RAISER) return ".rms";
	if (backend === BACKEND_ERLANG) return ".ems";
	if (backend === BACKEND_WASM) return ".wms";
	return ".ms";
}

// ===== Default Config Constructor =====

export function createDefaultConfig(backend: number, stdPath: string): ResolverConfig {
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
		backend: BACKEND_C,
		stdPath: "",
		searchPaths: [],
		extensions,
		aliasKeys: [],
		aliasValues: [],
	};
}

// ===== Import Resolution (Full) =====

export function resolveImportWithConfig(specifier: string, fromFile: string, config: ResolverConfig): ResolveCandidates {
	const result: ResolveCandidates = { paths: [] };

	// Apply alias rewriting
	const spec = applyAlias(specifier, config);

	// If specifier already has a known extension, return just that path
	if (hasKnownExtension(spec)) {
		addDirectCandidates(result, spec, fromFile, config);
		return result;
	}

	// Classify and resolve
	if (isRelative(spec)) {
		// Relative: ./foo, ../bar
		const baseDir = dirname(fromFile);
		const base = join(baseDir, spec);
		addExtensionCandidates(result, base, config.extensions);
	} else if (isStdImport(spec)) {
		// Std library: std/testing → stdPath + "/testing"
		if (config.stdPath.length > 0) {
			const subpath = sliceStr(spec, 4, spec.length);
			const base = join(config.stdPath, subpath);
			addExtensionCandidates(result, base, config.extensions);
		}
		// If no stdPath configured, return empty (handled externally)
	} else {
		// Bare import: try each search path
		let i = 0;
		while (i < config.searchPaths.length) {
			const base = join(config.searchPaths[i], spec);
			addExtensionCandidates(result, base, config.extensions);
			i = i + 1;
		}
	}

	return result;
}

// ===== Backward-Compatible Import Resolution =====
// Bare 2-arg version — std imports return empty, only .ms extension.
// Self-contained (does NOT call resolveImportWithConfig) to avoid DRC issues
// with temporary ResolverConfig/extensions array.

export function resolveImport(specifier: string, fromFile: string): ResolveCandidates {
	const result: ResolveCandidates = { paths: [] };

	// Std library — handled externally in bare mode
	if (isStdImport(specifier)) return result;

	// Bare specifiers — unsupported in legacy mode
	if (!isRelative(specifier)) return result;

	const baseDir = dirname(fromFile);
	const base = join(baseDir, specifier);

	// If specifier has a known extension (.h, .ms, etc.), use it directly
	if (hasKnownExtension(specifier)) {
		result.paths.push(base);
		return result;
	}

	// Relative imports: two candidates (.ms only)
	result.paths.push(base + ".ms");
	result.paths.push(join(base, "index.ms"));

	return result;
}

// ===== Candidate Generation =====

// For a base path (without extension), add direct + index candidates for each extension.
function addExtensionCandidates(result: ResolveCandidates, base: string, extensions: string[]): void {
	// Direct file candidates: base + ext
	let i = 0;
	while (i < extensions.length) {
		result.paths.push(base + extensions[i]);
		i = i + 1;
	}
	// Index file candidates: base/index + ext
	i = 0;
	while (i < extensions.length) {
		result.paths.push(join(base, "index" + extensions[i]));
		i = i + 1;
	}
}

// For a specifier with an explicit extension, resolve it directly.
function addDirectCandidates(result: ResolveCandidates, spec: string, fromFile: string, config: ResolverConfig): void {
	if (isRelative(spec)) {
		const baseDir = dirname(fromFile);
		result.paths.push(join(baseDir, spec));
	} else if (isStdImport(spec)) {
		if (config.stdPath.length > 0) {
			const subpath = sliceStr(spec, 4, spec.length);
			result.paths.push(join(config.stdPath, subpath));
		}
	} else {
		// Bare with extension — try search paths
		let i = 0;
		while (i < config.searchPaths.length) {
			result.paths.push(join(config.searchPaths[i], spec));
			i = i + 1;
		}
	}
}

// ===== Alias Rewriting =====

function applyAlias(specifier: string, config: ResolverConfig): string {
	let i = 0;
	while (i < config.aliasKeys.length) {
		const key = config.aliasKeys[i];
		if (specifier.length >= key.length && sliceStr(specifier, 0, key.length) === key) {
			// Check that alias matches at word boundary: exact match or followed by /
			if (specifier.length === key.length) {
				return config.aliasValues[i];
			}
			if (specifier.charCodeAt(key.length) === "/".code) {
				return config.aliasValues[i] + sliceStr(specifier, key.length, specifier.length);
			}
		}
		i = i + 1;
	}
	return specifier;
}

// ===== Extension Detection =====

function hasKnownExtension(specifier: string): boolean {
	return endsWith(specifier, ".ms")
		|| endsWith(specifier, ".cms")
		|| endsWith(specifier, ".jms")
		|| endsWith(specifier, ".rms")
		|| endsWith(specifier, ".ems")
		|| endsWith(specifier, ".wms")
		|| endsWith(specifier, ".ts")
		|| endsWith(specifier, ".js")
		|| endsWith(specifier, ".h");
}

// ===== Helpers =====

export function isStdImport(specifier: string): boolean {
	if (specifier.length < 4) return false;
	return sliceStr(specifier, 0, 4) === "std/";
}

function isRelative(specifier: string): boolean {
	if (specifier.length < 2) return false;
	const prefix = sliceStr(specifier, 0, 2);
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

testGroup("Resolver", () => {
	// -- Legacy (2-arg) backward compat --
	test("std imports return empty (legacy)", () => {
		const r1 = resolveImport("std/testing", "/a/b.ms");
		check(r1.paths.length === 0);
		const r2 = resolveImport("std/fs/path", "/a/b.ms");
		check(r2.paths.length === 0);
	});
	test("bare imports return empty (legacy)", () => {
		const r = resolveImport("lodash", "/a/b.ms");
		check(r.paths.length === 0);
	});
	test("relative import returns two candidates (legacy)", () => {
		const r = resolveImport("./foo", "/a/b.ms");
		check(r.paths.length === 2);
		check(r.paths[0] === "/a/foo.ms");
		check(r.paths[1] === "/a/foo/index.ms");
	});
	test("parent directory import (legacy)", () => {
		const r = resolveImport("../bar", "/a/b/c.ms");
		check(r.paths.length === 2);
		check(r.paths[0] === "/a/bar.ms");
		check(r.paths[1] === "/a/bar/index.ms");
	});
	test("nested relative import (legacy)", () => {
		const r = resolveImport("./sub/mod", "/proj/src/index.ms");
		check(r.paths.length === 2);
		check(r.paths[0] === "/proj/src/sub/mod.ms");
		check(r.paths[1] === "/proj/src/sub/mod/index.ms");
	});
	test("isStdImport", () => {
		check(isStdImport("std/fs"));
		check(isStdImport("std/testing"));
		check(!isStdImport("./foo"));
		check(!isStdImport("ab"));
	});
	test("buildFilePath", () => {
		check(buildFilePath("./foo", "/a/b.ms") === "/a/foo.ms");
	});
	test("buildIndexPath", () => {
		check(buildIndexPath("./sub", "/a/b.ms") === "/a/sub/index.ms");
	});

	// -- Backend extension mapping --
	test("backendExtension C", () => {
		check(backendExtension(0) === ".cms");
	});
	test("backendExtension JS", () => {
		check(backendExtension(1) === ".jms");
	});
	test("backendExtension Raiser", () => {
		check(backendExtension(2) === ".rms");
	});
	test("backendExtension Erlang", () => {
		check(backendExtension(3) === ".ems");
	});
	test("backendExtension Wasm", () => {
		check(backendExtension(4) === ".wms");
	});

	// -- Default config --
	test("createDefaultConfig C has 4 extensions", () => {
		const cfg = createDefaultConfig(0, "/usr/lib/msc/std");
		check(cfg.extensions.length === 4);
		check(cfg.extensions[0] === ".cms");
		check(cfg.extensions[1] === ".ms");
		check(cfg.extensions[2] === ".ts");
		check(cfg.extensions[3] === ".js");
		check(cfg.stdPath === "/usr/lib/msc/std");
	});
	test("createDefaultConfig JS has .jms first", () => {
		const cfg = createDefaultConfig(1, "/std");
		check(cfg.extensions[0] === ".jms");
	});

	// -- Full resolution with config --
	test("relative with C backend generates 8 candidates", () => {
		const cfg = createDefaultConfig(0, "");
		const r = resolveImportWithConfig("./foo", "/a/b.ms", cfg);
		check(r.paths.length === 8);
		check(r.paths[0] === "/a/foo.cms");
		check(r.paths[1] === "/a/foo.ms");
		check(r.paths[2] === "/a/foo.ts");
		check(r.paths[3] === "/a/foo.js");
		check(r.paths[4] === "/a/foo/index.cms");
		check(r.paths[5] === "/a/foo/index.ms");
		check(r.paths[6] === "/a/foo/index.ts");
		check(r.paths[7] === "/a/foo/index.js");
	});
	test("std/ with config resolves against stdPath", () => {
		const cfg = createDefaultConfig(0, "/lib/std");
		const r = resolveImportWithConfig("std/testing", "/a/b.ms", cfg);
		check(r.paths.length === 8);
		check(r.paths[0] === "/lib/std/testing.cms");
		check(r.paths[1] === "/lib/std/testing.ms");
		check(r.paths[4] === "/lib/std/testing/index.cms");
		check(r.paths[5] === "/lib/std/testing/index.ms");
	});
	test("std/ without stdPath returns empty", () => {
		const cfg = createDefaultConfig(0, "");
		const r = resolveImportWithConfig("std/testing", "/a/b.ms", cfg);
		check(r.paths.length === 0);
	});
	test("bare import with search paths", () => {
		const cfg = createDefaultConfig(0, "");
		cfg.searchPaths.push("/proj/lib");
		cfg.searchPaths.push("/proj/vendor");
		const r = resolveImportWithConfig("ui/grid", "/a/b.ms", cfg);
		// 2 search paths x 8 candidates each = 16
		check(r.paths.length === 16);
		check(r.paths[0] === "/proj/lib/ui/grid.cms");
		check(r.paths[1] === "/proj/lib/ui/grid.ms");
		check(r.paths[8] === "/proj/vendor/ui/grid.cms");
	});
	test("bare import without search paths returns empty", () => {
		const cfg = createDefaultConfig(0, "");
		const r = resolveImportWithConfig("lodash", "/a/b.ms", cfg);
		check(r.paths.length === 0);
	});
	test("alias rewriting", () => {
		const cfg = createDefaultConfig(0, "");
		cfg.aliasKeys.push("@app");
		cfg.aliasValues.push("./src");
		const r = resolveImportWithConfig("@app/utils", "/proj/index.ms", cfg);
		// Alias rewrites to ./src/utils, then relative resolution
		check(r.paths.length === 8);
		check(r.paths[0] === "/proj/src/utils.cms");
		check(r.paths[1] === "/proj/src/utils.ms");
	});
	test("alias exact match", () => {
		const cfg = createDefaultConfig(1, "");
		cfg.aliasKeys.push("@root");
		cfg.aliasValues.push("./src/index");
		const r = resolveImportWithConfig("@root", "/proj/main.ms", cfg);
		check(r.paths.length === 8);
		check(r.paths[0] === "/proj/src/index.jms");
		check(r.paths[1] === "/proj/src/index.ms");
	});
	test("alias does not match partial prefix", () => {
		const cfg = createDefaultConfig(0, "");
		cfg.aliasKeys.push("@app");
		cfg.aliasValues.push("./src");
		// "@application" should NOT match "@app" alias
		const r = resolveImportWithConfig("@application", "/proj/index.ms", cfg);
		check(r.paths.length === 0); // bare import, no search paths
	});
	test("explicit extension skips probing", () => {
		const cfg = createDefaultConfig(0, "");
		const r = resolveImportWithConfig("./foo.ms", "/a/b.ms", cfg);
		check(r.paths.length === 1);
		check(r.paths[0] === "/a/foo.ms");
	});
	test("explicit .ts extension", () => {
		const cfg = createDefaultConfig(0, "");
		const r = resolveImportWithConfig("./lib.ts", "/a/b.ms", cfg);
		check(r.paths.length === 1);
		check(r.paths[0] === "/a/lib.ts");
	});
	test("explicit .cms extension", () => {
		const cfg = createDefaultConfig(0, "/std");
		const r = resolveImportWithConfig("std/core.cms", "/a/b.ms", cfg);
		check(r.paths.length === 1);
		check(r.paths[0] === "/std/core.cms");
	});
	test("explicit .h extension resolves directly", () => {
		const cfg = createDefaultConfig(0, "");
		const r = resolveImportWithConfig("./dawn.h", "/a/b.ms", cfg);
		check(r.paths.length === 1);
		check(r.paths[0] === "/a/dawn.h");
	});
	test("JS backend uses .jms first", () => {
		const cfg = createDefaultConfig(1, "");
		const r = resolveImportWithConfig("./parser", "/a/b.ms", cfg);
		check(r.paths[0] === "/a/parser.jms");
		check(r.paths[1] === "/a/parser.ms");
	});
	test("Raiser backend uses .rms first", () => {
		const cfg = createDefaultConfig(2, "");
		const r = resolveImportWithConfig("./vm", "/a/b.ms", cfg);
		check(r.paths[0] === "/a/vm.rms");
	});
	test("parent dir with config", () => {
		const cfg = createDefaultConfig(0, "");
		const r = resolveImportWithConfig("../bar", "/a/b/c.ms", cfg);
		check(r.paths[0] === "/a/bar.cms");
		check(r.paths[1] === "/a/bar.ms");
	});
	test("std nested path", () => {
		const cfg = createDefaultConfig(0, "/lib/std");
		const r = resolveImportWithConfig("std/fs/path", "/a/b.ms", cfg);
		check(r.paths[0] === "/lib/std/fs/path.cms");
		check(r.paths[1] === "/lib/std/fs/path.ms");
	});
});

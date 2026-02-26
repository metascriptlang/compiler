// Module Resolver — translates import specifiers to candidate file paths
//
// Resolution algorithm:
//   1. Relative (./foo, ../bar): returns [dirname(fromFile)/specifier.ms, .../specifier/index.ms]
//   2. Std library ("std/..."): returns [] — handled by reference compiler
//   3. Bare specifiers: returns [] — unsupported initially
//
// Pure function — no filesystem access. The loader tries candidates in order.

import { dirname, join } from "std/fs/path";
import { test, check, testGroup } from "std/testing";
import { sliceStr } from "../utils/string";

// ===== Resolution Result =====
// Wraps string[] in interface to avoid DRC value-type gotcha (#4).

export interface ResolveCandidates {
	paths: string[];
}

// ===== Import Resolution =====

export function resolveImport(specifier: string, fromFile: string): ResolveCandidates {
	const result: ResolveCandidates = { paths: [] };

	// Std library — handled externally
	if (isStdImport(specifier)) return result;

	// Bare specifiers — unsupported
	if (!isRelative(specifier)) return result;

	// Relative imports: two candidates
	result.paths.push(buildFilePath(specifier, fromFile));
	result.paths.push(buildIndexPath(specifier, fromFile));

	return result;
}

// ===== Single-path convenience (for when caller already checked existence) =====

export function buildFilePath(specifier: string, fromFile: string): string {
	const baseDir = dirname(fromFile);
	return join(baseDir, specifier + ".ms");
}

export function buildIndexPath(specifier: string, fromFile: string): string {
	const baseDir = dirname(fromFile);
	return join(baseDir, join(specifier, "index.ms"));
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

// ===== Tests =====

testGroup("Resolver", () => {
	test("std imports return empty", () => {
		const r1 = resolveImport("std/testing", "/a/b.ms");
		check(r1.paths.length === 0);
		const r2 = resolveImport("std/fs/path", "/a/b.ms");
		check(r2.paths.length === 0);
	});
	test("bare imports return empty", () => {
		const r = resolveImport("lodash", "/a/b.ms");
		check(r.paths.length === 0);
	});
	test("relative import returns two candidates", () => {
		const r = resolveImport("./foo", "/a/b.ms");
		check(r.paths.length === 2);
		check(r.paths[0] === "/a/foo.ms");
		check(r.paths[1] === "/a/foo/index.ms");
	});
	test("parent directory import", () => {
		const r = resolveImport("../bar", "/a/b/c.ms");
		check(r.paths.length === 2);
		check(r.paths[0] === "/a/bar.ms");
		check(r.paths[1] === "/a/bar/index.ms");
	});
	test("nested relative import", () => {
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
});

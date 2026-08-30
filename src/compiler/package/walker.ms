// File walker — collect the list of files that go into a published archive.
//
// Algorithm:
//   1. DFS from rootDir using an explicit stack (no recursion — avoids
//      blowing the MetaScript call stack on deep trees).
//   2. At each directory, check its RELATIVE path against the exclude set.
//      If it matches any exclude, skip the whole subtree. This is a critical
//      optimization — skipping "out/" or ".git/" prunes thousands of entries.
//   3. At each FILE, check the relative path against:
//        a. `includes` — if non-empty, the file must match at least one.
//        b. `excludes` — the file must not match any.
//        c. `BUILTIN_EXCLUDES` — always applied.
//   4. `build.ms` at the root is force-included regardless of `includes`.
//   5. Results are sorted by relPath so the same input produces identical
//      archive bytes (and therefore identical integrity).
//
// Paths in `relPath` always use forward slashes, no leading "/".

import { readDir, isFile, isDir, fileSize, join, exists } from "std/fs";
import { env } from "std/process";

// Test scratch dir — OS temp dir without std/os's C-header (see manifest.ms).
function testTmpDir(): string {
	const t = env.get("TMP");
	if (t !== "") return t;
	const t2 = env.get("TEMP");
	if (t2 !== "") return t2;
	const t3 = env.get("TMPDIR");
	if (t3 !== "") return t3;
	return "/tmp";
}
import { compileGlobs, globMatchAny } from "std/fs/glob";

export interface FileEntry {
	relPath: string;   // forward slashes, project-root relative, no leading slash
	absPath: string;
	size: number;
}

// Always-excluded globs, applied after user-specified excludes. These are not
// user-configurable — they protect against common mistakes (publishing the
// .git directory, accidentally uploading 500 MB of node_modules, etc.).
const BUILTIN_EXCLUDE_PATTERNS: string[] = [
	".git/**",
	"out/**",
	"node_modules/**",
	"**/.DS_Store",
	".env",
	".env.*",
	"**/*.log",
	"**/.cache/**",
	"**/build_tmp/**",
	"msc.lock",
	".vscode/**",
	".idea/**",
];

export interface CollectResult {
	files: FileEntry[];
	errors: string[];   // compile errors from glob patterns, if any
}

// Walk `rootDir` and return the list of files that should be included in a
// published archive. `includes` = user `package.files` globs (empty = all).
// `excludes` = user `package.ignore` globs.
export function collectPublishFiles(rootDir: string, includes: string[], excludes: string[]): CollectResult {
	const incResult = compileGlobs(includes);
	const excResult = compileGlobs(excludes);
	const builtinGlobs = compileGlobs(BUILTIN_EXCLUDE_PATTERNS).globs;

	const errors: string[] = [];
	for (const e of incResult.errors) { errors.push("files: " + e); }
	for (const e of excResult.errors) { errors.push("ignore: " + e); }

	const files: FileEntry[] = [];
	if (!exists(rootDir) || !isDir(rootDir)) {
		errors.push("not a directory: " + rootDir);
		return { files, errors };
	}

	// Explicit DFS stack of relative paths to visit ("" = root).
	const stack: string[] = [""];
	while (stack.length > 0) {
		const relDir = stack[stack.length - 1];
		stack.pop();
		const absDir = relDir === "" ? rootDir : join(rootDir, relDir);
		const entries = readDir(absDir);

		let ei = 0;
		while (ei < entries.length) {
			const raw = entries[ei];
			ei = ei + 1;

			// readDir returns names with trailing "/" for directories.
			let name = raw;
			let isDirEntry = false;
			if (name.length > 0 && name.charAt(name.length - 1) === "/") {
				isDirEntry = true;
				name = name.slice(0, name.length - 1);
			}

			const childRel = relDir === "" ? name : relDir + "/" + name;

			if (isDirEntry) {
				// Subtree prune: if the directory's own rel path matches any exclude,
				// skip the entire subtree. Saves walking .git/, out/, etc.
				if (globMatchAny(excResult.globs, childRel) || globMatchAny(builtinGlobs, childRel)) {
					continue;
				}
				stack.push(childRel);
				continue;
			}

			// File gate.
			const absChild = join(rootDir, childRel);
			if (!isFile(absChild)) continue;

			// Force-include build.ms at the root regardless of user `files`.
			const isRootBuildMs = childRel === "build.ms";

			if (!isRootBuildMs) {
				// If user supplied `includes`, file must match at least one.
				if (incResult.globs.length > 0 && !globMatchAny(incResult.globs, childRel)) {
					continue;
				}
				// User excludes.
				if (globMatchAny(excResult.globs, childRel)) continue;
				// Builtin excludes.
				if (globMatchAny(builtinGlobs, childRel)) continue;
			}

			files.push({
				relPath: childRel,
				absPath: absChild,
				size: fileSize(absChild),
			});
		}
	}

	// Sort by relPath for deterministic output (and therefore deterministic
	// integrity hashes). Simple insertion sort — n is small (<10k) and this
	// module has no dependency on a sort utility.
	sortFilesByPath(files);

	return { files, errors };
}

function sortFilesByPath(files: FileEntry[]): void {
	// Insertion sort on relPath (string compare).
	let i = 1;
	while (i < files.length) {
		const cur = files[i];
		let j = i - 1;
		while (j >= 0 && files[j].relPath > cur.relPath) {
			files[j + 1] = files[j];
			j = j - 1;
		}
		files[j + 1] = cur;
		i = i + 1;
	}
}

// ===== Tests =====
// These tests require a writable tmp directory. They create a small fixture
// tree, walk it, and verify the returned file list.

import { mkdir, writeFile, remove, rmdir } from "std/fs";

function makeFixture(root: string): boolean {
	// Clean up any previous run.
	cleanupFixture(root);
	const r0 = mkdir(root);
	if (!r0.ok) return false;
	const r1 = mkdir(join(root, "src"));
	if (!r1.ok) return false;
	const r2 = mkdir(join(root, "src/sub"));
	if (!r2.ok) return false;
	const r3 = mkdir(join(root, "out"));
	if (!r3.ok) return false;
	const r4 = mkdir(join(root, ".git"));
	if (!r4.ok) return false;
	// Files
	const files: string[] = [
		"build.ms",
		"README.md",
		"src/main.ms",
		"src/helper.ms",
		"src/sub/deep.ms",
		"src/notes.txt",
		"out/generated.c",
		".git/HEAD",
	];
	let i = 0;
	while (i < files.length) {
		const r = writeFile(join(root, files[i]), "x");
		if (!r.ok) return false;
		i = i + 1;
	}
	return true;
}

function cleanupFixture(root: string): void {
	// Best-effort teardown — failures are ignored since the dir may not exist.
	const files: string[] = [
		"build.ms", "README.md",
		"src/main.ms", "src/helper.ms", "src/sub/deep.ms", "src/notes.txt",
		"out/generated.c", ".git/HEAD",
	];
	let i = 0;
	while (i < files.length) { remove(join(root, files[i])); i = i + 1; }
	rmdir(join(root, "src/sub"));
	rmdir(join(root, "src"));
	rmdir(join(root, "out"));
	rmdir(join(root, ".git"));
	rmdir(root);
}

test "walker: empty includes → everything non-builtin-excluded" {
	const root = join(testTmpDir(), "mspub-walk-1");
	if (makeFixture(root)) {
		const includes: string[] = [];
		const excludes: string[] = [];
		const r = collectPublishFiles(root, includes, excludes);
		assert r.errors.length === 0;
		// Expect: build.ms, README.md, src/helper.ms, src/main.ms, src/notes.txt,
		// src/sub/deep.ms (sorted). .git/HEAD and out/generated.c excluded by builtins.
		assert r.files.length === 6;
		assert r.files[0].relPath === "README.md";
		assert r.files[1].relPath === "build.ms";
		assert r.files[2].relPath === "src/helper.ms";
		assert r.files[3].relPath === "src/main.ms";
		assert r.files[4].relPath === "src/notes.txt";
		assert r.files[5].relPath === "src/sub/deep.ms";
		cleanupFixture(root);
	}
}

test "walker: includes allowlist" {
	const root = join(testTmpDir(), "mspub-walk-2");
	if (makeFixture(root)) {
		const includes: string[] = ["src/**/*.ms"];
		const excludes: string[] = [];
		const r = collectPublishFiles(root, includes, excludes);
		assert r.errors.length === 0;
		// Expect: build.ms (force-included) + all .ms files under src
		assert r.files.length === 4;
		assert r.files[0].relPath === "build.ms";
		assert r.files[1].relPath === "src/helper.ms";
		assert r.files[2].relPath === "src/main.ms";
		assert r.files[3].relPath === "src/sub/deep.ms";
		cleanupFixture(root);
	}
}

test "walker: excludes subtract from includes" {
	const root = join(testTmpDir(), "mspub-walk-3");
	if (makeFixture(root)) {
		const includes: string[] = ["src/**/*.ms"];
		const excludes: string[] = ["src/sub/**"];
		const r = collectPublishFiles(root, includes, excludes);
		assert r.errors.length === 0;
		// Expect: build.ms, src/helper.ms, src/main.ms (sub/ excluded)
		assert r.files.length === 3;
		assert r.files[0].relPath === "build.ms";
		assert r.files[1].relPath === "src/helper.ms";
		assert r.files[2].relPath === "src/main.ms";
		cleanupFixture(root);
	}
}

test "walker: builtin excludes always apply" {
	const root = join(testTmpDir(), "mspub-walk-4");
	if (makeFixture(root)) {
		// Even if user tries to include .git, builtin still excludes it
		const includes: string[] = ["**/*"];
		const excludes: string[] = [];
		const r = collectPublishFiles(root, includes, excludes);
		assert r.errors.length === 0;
		// .git/HEAD and out/generated.c still excluded
		let hasGit = false;
		let hasOut = false;
		let i = 0;
		while (i < r.files.length) {
			if (r.files[i].relPath === ".git/HEAD") hasGit = true;
			if (r.files[i].relPath === "out/generated.c") hasOut = true;
			i = i + 1;
		}
		assert !hasGit;
		assert !hasOut;
		cleanupFixture(root);
	}
}

test "walker: bad glob surfaces error" {
	const root = join(testTmpDir(), "mspub-walk-5");
	if (makeFixture(root)) {
		const includes: string[] = ["a**b"];
		const excludes: string[] = [];
		const r = collectPublishFiles(root, includes, excludes);
		assert r.errors.length === 1;
		cleanupFixture(root);
	}
}

test "walker: nonexistent root reports error" {
	const includes: string[] = [];
	const excludes: string[] = [];
	const r = collectPublishFiles(join(testTmpDir(), "does-not-exist-xyz-987"), includes, excludes);
	assert r.errors.length >= 1;
	assert r.files.length === 0;
}

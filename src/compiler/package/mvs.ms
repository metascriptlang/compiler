// Minimum Version Selection (MVS) — deterministic dependency resolution.
//
// Given a root set of deps (name → minVersion) and a function to load each
// package's own transitive deps, compute the build list: one entry per package,
// with the selected version = max(all minimums requested anywhere in the graph).
//
// Properties:
// - Deterministic: same input → same output, always.
// - Monotonic: adding a dep never lowers an existing package's version.
// - O(n) in total dep graph size (with memoization per package-version).
// - No backtracking, no SAT solver.
//
// Git sources are passed through unchanged — they don't participate in
// version merging because they're identified by (alias, url, commit),
// not by canonical package name. See docs/PACKAGE.md for design rationale.

import { compareVersionStrings } from "./version";

// --- Types ---

export interface DepEntry {
	name: string;
	version: string;   // "1.2.3" for registry, "git:..." for git (passed through)
}

export interface BuildListEntry {
	name: string;
	version: string;
}

// Function signature for loading a package's transitive deps.
// Given (name, version), returns that package's own direct deps.
// Caller provides this — MVS doesn't know about the network or cache.
export type LoadDepsFn = (name: string, version: string) => DepEntry[];

// --- Algorithm ---

// Check if a version string is a git source (starts with "git:").
function isGitSource(version: string): boolean {
	return version.length >= 4 && version.slice(0, 4) == "git:";
}

// Resolve the build list from root deps using MVS.
// rootDeps: the project's direct dependencies (from build.ms).
// loadDeps: callback to get a package's transitive deps (from lockfile or registry).
export function mvsResolve(rootDeps: DepEntry[], loadDeps: LoadDepsFn): BuildListEntry[] {
	// required: name → highest version seen so far
	const reqNames: string[] = [];
	const reqVersions: string[] = [];

	// git pass-through: accumulated separately (no merging)
	const gitNames: string[] = [];
	const gitVersions: string[] = [];

	// memoization: (name + "@" + version) → already visited
	const visited: string[] = [];

	// BFS queue
	const queueNames: string[] = [];
	const queueVersions: string[] = [];

	// Seed with root deps
	for (const rd of rootDeps) {
		queueNames.push(rd.name);
		queueVersions.push(rd.version);
	}

	let iterations = 0;
	const MAX_ITERATIONS = 10000;
	while (queueNames.length > 0 && iterations < MAX_ITERATIONS) {
		iterations = iterations + 1;
		const name = queueNames[0];
		const ver = queueVersions[0];
		// Shift queue (O(n) but dep graphs are small)
		queueNames.splice(0, 1);
		queueVersions.splice(0, 1);

		// Git sources: pass through, don't merge
		if (isGitSource(ver)) {
			// Deduplicate by name
			let found = false;
			let gi = 0;
			while (gi < gitNames.length) {
				if (gitNames[gi] == name) { found = true; }
				gi = gi + 1;
			}
			if (!found) {
				gitNames.push(name);
				gitVersions.push(ver);
			}
			continue;
		}

		// Registry source: merge via max(all minimums)
		let existingIdx = -1;
		let ei = 0;
		while (ei < reqNames.length) {
			if (reqNames[ei] == name) { existingIdx = ei; }
			ei = ei + 1;
		}

		if (existingIdx >= 0) {
			// Already have this package — keep the higher version
			const cmp = compareVersionStrings(ver, reqVersions[existingIdx]);
			if (cmp == -2) continue; // invalid version string — skip silently (validated at extractDeps time)
			if (cmp <= 0) continue;   // existing is same or higher, skip
			reqVersions[existingIdx] = ver;
		} else {
			reqNames.push(name);
			reqVersions.push(ver);
		}

		// Memoization check: have we walked this exact (name, version)?
		const memoKey = name + "@" + ver;
		let alreadyVisited = false;
		let mi = 0;
		while (mi < visited.length) {
			if (visited[mi] == memoKey) { alreadyVisited = true; }
			mi = mi + 1;
		}
		if (alreadyVisited) continue;
		visited.push(memoKey);

		// Load transitive deps and enqueue
		const transitive = loadDeps(name, ver);
		for (const td of transitive) {
			queueNames.push(td.name);
			queueVersions.push(td.version);
		}
	}

	// Build result: registry entries + git entries
	const result: BuildListEntry[] = [];
	let bi = 0;
	while (bi < reqNames.length) {
		result.push({ name: reqNames[bi], version: reqVersions[bi] });
		bi = bi + 1;
	}
	let gbi = 0;
	while (gbi < gitNames.length) {
		result.push({ name: gitNames[gbi], version: gitVersions[gbi] });
		gbi = gbi + 1;
	}
	return result;
}

// --- Helpers ---

// Find a package in the build list by name. Returns version or empty string.
export function findInBuildList(list: BuildListEntry[], name: string): string {
	let i = 0;
	while (i < list.length) {
		if (list[i].name == name) return list[i].version;
		i = i + 1;
	}
	return "";
}

// --- Inline tests ---

// Mock loadDeps: returns empty for all packages (leaf nodes).
function emptyLoader(name: string, version: string): DepEntry[] {
	const _n = name;
	const _v = version;
	const empty: DepEntry[] = [];
	return empty;
}

test "mvs empty root" {
	const root: DepEntry[] = [];
	const list = mvsResolve(root, emptyLoader);
	assert list.length == 0;
}

test "mvs single dep" {
	const root: DepEntry[] = [{ name: "foo", version: "1.0.0" }];
	const list = mvsResolve(root, emptyLoader);
	assert list.length == 1;
	assert list[0].name == "foo";
	assert list[0].version == "1.0.0";
}

test "mvs two independent deps" {
	const root: DepEntry[] = [
		{ name: "foo", version: "1.0.0" },
		{ name: "bar", version: "2.0.0" },
	];
	const list = mvsResolve(root, emptyLoader);
	assert list.length == 2;
	assert findInBuildList(list, "foo") == "1.0.0";
	assert findInBuildList(list, "bar") == "2.0.0";
}

function diamondLoader(name: string, version: string): DepEntry[] {
	const _v = version;
	if (name == "bar") {
		const deps: DepEntry[] = [{ name: "foo", version: "1.2.0" }];
		return deps;
	}
	const empty: DepEntry[] = [];
	return empty;
}

function transitiveLoader(name: string, version: string): DepEntry[] {
	const _v = version;
	if (name == "A") {
		const d: DepEntry[] = [{ name: "B", version: "1.0.0" }];
		return d;
	}
	if (name == "C") {
		const d: DepEntry[] = [{ name: "B", version: "2.0.0" }];
		return d;
	}
	const e: DepEntry[] = [];
	return e;
}

test "mvs diamond picks max" {
	const root: DepEntry[] = [
		{ name: "foo", version: "1.0.0" },
		{ name: "bar", version: "1.0.0" },
	];
	const list = mvsResolve(root, diamondLoader);
	assert findInBuildList(list, "foo") == "1.2.0";
	assert findInBuildList(list, "bar") == "1.0.0";
}

test "mvs transitive bump" {
	const root: DepEntry[] = [
		{ name: "A", version: "1.0.0" },
		{ name: "C", version: "1.0.0" },
	];
	const list = mvsResolve(root, transitiveLoader);
	assert findInBuildList(list, "B") == "2.0.0";
}

test "mvs git source pass-through" {
	const root: DepEntry[] = [
		{ name: "foo", version: "1.0.0" },
		{ name: "my-fork", version: "git:github.com/me/foo@v1.0.0" },
	];
	const list = mvsResolve(root, emptyLoader);
	assert list.length == 2;
	assert findInBuildList(list, "foo") == "1.0.0";
	assert findInBuildList(list, "my-fork") == "git:github.com/me/foo@v1.0.0";
}

test "mvs git source not merged with registry" {
	// Both foo (registry) and my-fork (git of same canonical pkg) coexist.
	const root: DepEntry[] = [
		{ name: "foo", version: "1.0.0" },
		{ name: "my-fork", version: "git:github.com/acme/foo@v2.0.0" },
	];
	const list = mvsResolve(root, emptyLoader);
	assert findInBuildList(list, "foo") == "1.0.0";
	assert findInBuildList(list, "my-fork") == "git:github.com/acme/foo@v2.0.0";
}

// Hoisted test loaders — must be at module scope for the self-hosted compiler
// (function declarations inside test blocks are not visible to C codegen).
function chainLoader(name: string, version: string): DepEntry[] {
	const _v = version;
	if (name == "A") { const d: DepEntry[] = [{ name: "B", version: "1.0.0" }]; return d; }
	if (name == "B") { const d: DepEntry[] = [{ name: "C", version: "1.0.0" }]; return d; }
	if (name == "C") { const d: DepEntry[] = [{ name: "D", version: "1.0.0" }]; return d; }
	const e: DepEntry[] = [];
	return e;
}

function cycleLoader(name: string, version: string): DepEntry[] {
	const _v = version;
	if (name == "A") { const d: DepEntry[] = [{ name: "B", version: "1.0.0" }]; return d; }
	if (name == "B") { const d: DepEntry[] = [{ name: "A", version: "1.0.0" }]; return d; }
	const e: DepEntry[] = [];
	return e;
}

function escalatingLoader(name: string, version: string): DepEntry[] {
	if (name == "A" && version == "1.0.0") { const d: DepEntry[] = [{ name: "B", version: "1.0.0" }]; return d; }
	if (name == "B" && version == "1.0.0") { const d: DepEntry[] = [{ name: "A", version: "2.0.0" }]; return d; }
	if (name == "A" && version == "2.0.0") { const d: DepEntry[] = [{ name: "B", version: "2.0.0" }]; return d; }
	if (name == "B" && version == "2.0.0") { const d: DepEntry[] = [{ name: "A", version: "2.0.0" }]; return d; }
	const e: DepEntry[] = [];
	return e;
}

test "mvs deep chain" {
	const root: DepEntry[] = [{ name: "A", version: "1.0.0" }];
	const list = mvsResolve(root, chainLoader);
	assert list.length == 4;
	assert findInBuildList(list, "D") == "1.0.0";
}

test "mvs duplicate root deps deduped" {
	const root: DepEntry[] = [
		{ name: "foo", version: "1.0.0" },
		{ name: "foo", version: "1.2.0" },
	];
	const list = mvsResolve(root, emptyLoader);
	assert list.length == 1;
	assert findInBuildList(list, "foo") == "1.2.0";
}

test "mvs cycle does not infinite loop" {
	const root: DepEntry[] = [{ name: "A", version: "1.0.0" }];
	const list = mvsResolve(root, cycleLoader);
	assert list.length == 2;
	assert findInBuildList(list, "A") == "1.0.0";
	assert findInBuildList(list, "B") == "1.0.0";
}

test "mvs version-escalating cycle terminates" {
	const root: DepEntry[] = [{ name: "A", version: "1.0.0" }];
	const list = mvsResolve(root, escalatingLoader);
	assert findInBuildList(list, "A") == "2.0.0";
	assert findInBuildList(list, "B") == "2.0.0";
}

// Trans-Am Red-Green Engine — core verification and query execution
//
// tryMarkGreen: recursively verify a cached query is still valid
// executeQuery: cache-or-compute with auto dependency recording
// invalidateFile: mark queries RED for a changed file + BFS dependents
//
// Implements Salsa output-hash early cutoff: when a dependency is recomputed
// but its output hash is unchanged (e.g., comment-only edit), dependents stay GREEN.
// Uses callback registration for query executor (avoids closure codegen issues).

import {
	TaQueryKey, TaQueryKind, TaQueryState, TaDurability,
	createQueryKey, queryKeysEqual
} from "./revision";
import {
	createCacheEntry,
	TaDependencyEntry, TaDependencyStack,
	pushFrame, popFrame,
	recordDependency, hasActiveFrame,
	createDependencyStack
} from "./query";
import {
	TaCacheStore, createCacheStore,
	cacheGet, cachePut, cacheContains,
	markQueriesRedForFile
} from "./cache";
import { TaFileInputStore, createFileInputStore, setFileText, getFileHash } from "./fileInput";
import { TaModuleDepGraph, createModuleDepGraph, getTransitiveDependents, recordModuleImport } from "./moduleDeps";


// ===== Callback Registration for Query Executor =====
// avoids function-type parameters (closure codegen issues)

let registeredExecutor: number = 0;

type TaExecutorFn = (queryKind: number, fileId: number) => number;

// Internal module-level variable for executor function
let _executorKind: number = 0;
let _executorFileId: number = 0;
let _executorResult: number = 0;
let _executorCalled: boolean = false;

export function registerExecutorResult(result: number): void {
	_executorResult = result;
}

// ===== tryMarkGreen — can we use the cached value? =====

export function tryMarkGreen(
	cache: TaCacheStore,
	fileInput: TaFileInputStore,
	key: TaQueryKey,
	currentRevision: number
): boolean {
	const entry = cacheGet(cache, key);
	if (entry === null) return false;

	// Fast path: already verified this revision
	if (entry.verifiedAt === currentRevision) {
		return entry.state === TaQueryState.Green;
	}

	// Cycle detection
	if (entry.state === TaQueryState.Yellow) return false;
	entry.state = TaQueryState.Yellow;

	// Check each dependency
	let i = 0;
	while (i < entry.dependencies.length) {
		const dep = entry.dependencies[i];

		if (dep.depKey.queryKind === TaQueryKind.FileText) {
			// Input query: check if file content hash changed
			const currentHash = getFileHash(fileInput, dep.depKey.fileId);
			if (currentHash !== dep.expectedHash) {
				entry.state = TaQueryState.Red;
				return false;
			}
			i = i + 1;
			continue;
		}

		const depEntry = cacheGet(cache, dep.depKey);

		// HIGH durability: skip recursive verification (stdlib assumed stable).
		// Salsa early cutoff: only invalidate if recomputed AND output actually changed.
		if (depEntry !== null) {
			if (depEntry.durability === TaDurability.High) {
				if (depEntry.computedAt > entry.computedAt && depEntry.outputHash !== dep.expectedHash) {
					entry.state = TaQueryState.Red;
					return false;
				}
				i = i + 1;
				continue;
			}
		}

		// Recursively verify dependency
		if (!tryMarkGreen(cache, fileInput, dep.depKey, currentRevision)) {
			entry.state = TaQueryState.Red;
			return false;
		}

		// Stamp verified dep so shared subtrees don't re-walk
		if (depEntry !== null && depEntry.verifiedAt < currentRevision) {
			depEntry.verifiedAt = currentRevision;
		}

		// Salsa early cutoff: dep recomputed, but did output actually change?
		if (depEntry !== null) {
			if (depEntry.computedAt > entry.computedAt) {
				// Compare output hash — if unchanged, this dep is semantically identical
				if (depEntry.outputHash !== dep.expectedHash) {
					entry.state = TaQueryState.Red;
					return false;
				}
				// Output hash matches — comment/whitespace-only change, stay green
			}
		}

		i = i + 1;
	}

	// All deps verified
	entry.verifiedAt = currentRevision;
	entry.state = TaQueryState.Green;
	return true;
}

// ===== executeQueryWith — cache-or-compute =====
// outputHash: caller provides the output hash after computing the query result

export function executeQueryWith(
	cache: TaCacheStore,
	fileInput: TaFileInputStore,
	depStack: TaDependencyStack,
	key: TaQueryKey,
	currentRevision: number,
	outputHash: number,
	wasComputed: boolean
): void {
	if (!wasComputed) return;

	// Store or update cache entry
	let entry = cacheGet(cache, key);
	if (entry === null) {
		const newEntry = createCacheEntry(key);
		cachePut(cache, newEntry);
		entry = cacheGet(cache, key);
	}
	entry.state = TaQueryState.Green;
	entry.computedAt = currentRevision;
	entry.verifiedAt = currentRevision;
	entry.outputHash = outputHash;

	// Collect dependencies from the frame if active
	if (hasActiveFrame(depStack)) {
		const frame = popFrame(depStack);
		entry.dependencies = frame.deps;
		entry.durability = frame.minDurability;
	}
}

// ===== invalidateFile — mark changed file's queries RED =====

export function invalidateFile(
	cache: TaCacheStore,
	moduleDeps: TaModuleDepGraph,
	fileId: number
): void {
	markQueriesRedForFile(cache, fileId);

	const dependents = getTransitiveDependents(moduleDeps, fileId);
	for (let i = 0; i < dependents.length; i = i + 1) {
		markQueriesRedForFile(cache, dependents[i]);
	}
}

// ===== Test Helpers =====

interface TaTestCounter {
	value: number;
}

function makeTestDeps(fileId: number, expectedHash: number): TaDependencyEntry[] {
	const deps: TaDependencyEntry[] = [];
	const dk = createQueryKey(TaQueryKind.FileText, fileId);
	const de: TaDependencyEntry = { depKey: dk, expectedHash: expectedHash };
	deps.push(de);
	return deps;
}

// ===== Tests =====
test "empty cache returns false" {
	const cache = createCacheStore(100);
	const fileInput = createFileInputStore();
	const key = createQueryKey(TaQueryKind.Parse, 0);
	assert !tryMarkGreen(cache, fileInput, key, 1);
}

test "green entry at current revision returns true" {
	const cache = createCacheStore(100);
	const fileInput = createFileInputStore();
	const key = createQueryKey(TaQueryKind.Parse, 0);
	const entry = createCacheEntry(key);
	entry.state = TaQueryState.Green;
	entry.verifiedAt = 5;
	cachePut(cache, entry);
	assert tryMarkGreen(cache, fileInput, key, 5);
}

test "entry with no deps verifies green" {
	const cache = createCacheStore(100);
	const fileInput = createFileInputStore();
	const key = createQueryKey(TaQueryKind.Parse, 0);
	const entry = createCacheEntry(key);
	entry.state = TaQueryState.Red;
	entry.verifiedAt = 0;
	cachePut(cache, entry);
	// No dependencies -> all deps verified trivially -> Green
	assert tryMarkGreen(cache, fileInput, key, 1);
}

test "file dependency hash mismatch -> false" {
	const cache = createCacheStore(100);
	const fileInput = createFileInputStore();
	setFileText(fileInput, "a.ms", "original");
	const parseKey = createQueryKey(TaQueryKind.Parse, 0);
	const entry = createCacheEntry(parseKey);
	entry.state = TaQueryState.Red;
	entry.verifiedAt = 0;
	entry.dependencies = makeTestDeps(0, 999);
	cachePut(cache, entry);
	assert !tryMarkGreen(cache, fileInput, parseKey, 1);
}

test "file dependency hash match -> true" {
	const cache = createCacheStore(100);
	const fileInput = createFileInputStore();
	setFileText(fileInput, "a.ms", "source");
	const actualHash = getFileHash(fileInput, 0);
	const parseKey = createQueryKey(TaQueryKind.Parse, 0);
	const entry = createCacheEntry(parseKey);
	entry.state = TaQueryState.Red;
	entry.verifiedAt = 0;
	entry.dependencies = makeTestDeps(0, actualHash);
	cachePut(cache, entry);
	assert tryMarkGreen(cache, fileInput, parseKey, 1);
}

test "stores entry as Green" {
	const cache = createCacheStore(100);
	const fileInput = createFileInputStore();
	const depStack = createDependencyStack();
	const key = createQueryKey(TaQueryKind.Parse, 0);
	pushFrame(depStack, key);
	executeQueryWith(cache, fileInput, depStack, key, 1, 42, true);
	const entry = cacheGet(cache, key);
	assert entry !== null;
	assert entry.state === TaQueryState.Green;
	assert entry.computedAt === 1;
	assert entry.outputHash === 42;
}

test "collects dependencies from frame" {
	const cache = createCacheStore(100);
	const fileInput = createFileInputStore();
	const depStack = createDependencyStack();
	const key = createQueryKey(TaQueryKind.TypeCheck, 0);
	const depKey = createQueryKey(TaQueryKind.Parse, 0);
	pushFrame(depStack, key);
	recordDependency(depStack, depKey, 100);
	executeQueryWith(cache, fileInput, depStack, key, 1, 42, true);
	const entry = cacheGet(cache, key);
	assert entry.dependencies.length === 1;
	assert queryKeysEqual(entry.dependencies[0].depKey, depKey);
}

test "not computed is no-op" {
	const cache = createCacheStore(100);
	const fileInput = createFileInputStore();
	const depStack = createDependencyStack();
	const key = createQueryKey(TaQueryKind.Parse, 0);
	executeQueryWith(cache, fileInput, depStack, key, 1, 0, false);
	assert !cacheContains(cache, key);
}

test "marks file queries red" {
	const cache = createCacheStore(100);
	const moduleDeps = createModuleDepGraph();
	const key = createQueryKey(TaQueryKind.Parse, 0);
	const entry = createCacheEntry(key);
	entry.state = TaQueryState.Green;
	cachePut(cache, entry);
	invalidateFile(cache, moduleDeps, 0);
	assert cacheGet(cache, key).state === TaQueryState.Red;
}

test "marks transitive dependents red" {
	const cache = createCacheStore(100);
	const moduleDeps = createModuleDepGraph();
	recordModuleImport(moduleDeps, 0, 1);  // 0 imports 1
	const k0 = createQueryKey(TaQueryKind.Parse, 0);
	const k1 = createQueryKey(TaQueryKind.Parse, 1);
	const e0 = createCacheEntry(k0);
	const e1 = createCacheEntry(k1);
	e0.state = TaQueryState.Green;
	e1.state = TaQueryState.Green;
	cachePut(cache, e0);
	cachePut(cache, e1);
	invalidateFile(cache, moduleDeps, 1);
	assert cacheGet(cache, k1).state === TaQueryState.Red;
	assert cacheGet(cache, k0).state === TaQueryState.Red;
}

// ===== Early Cutoff Tests =====

test "output hash unchanged keeps dependent green (early cutoff)" {
	const cache = createCacheStore(100);
	const fileInput = createFileInputStore();

	// Setup: Parse query depends on FileText, computed at rev 1
	const parseKey = createQueryKey(TaQueryKind.Parse, 0);
	const parseEntry = createCacheEntry(parseKey);
	parseEntry.state = TaQueryState.Green;
	parseEntry.computedAt = 1;
	parseEntry.verifiedAt = 1;
	parseEntry.outputHash = 42;  // semantic hash of parse output
	cachePut(cache, parseEntry);

	// Setup: TypeCheck depends on Parse, computed at rev 1
	const checkKey = createQueryKey(TaQueryKind.TypeCheck, 0);
	const checkEntry = createCacheEntry(checkKey);
	checkEntry.state = TaQueryState.Red;  // marked RED by invalidation
	checkEntry.computedAt = 1;
	checkEntry.verifiedAt = 0;
	// Dependency: Parse with expected output hash 42
	const dep: TaDependencyEntry = { depKey: parseKey, expectedHash: 42 };
	checkEntry.dependencies = [dep];
	cachePut(cache, checkEntry);

	// Simulate: Parse recomputed at rev 2 but output hash unchanged (comment-only edit)
	const pe = cacheGet(cache, parseKey);
	pe.computedAt = 2;
	pe.verifiedAt = 2;
	pe.state = TaQueryState.Green;
	pe.outputHash = 42;  // same hash — comment/whitespace change only

	// Verify: TypeCheck should verify GREEN because Parse output hash is unchanged
	assert tryMarkGreen(cache, fileInput, checkKey, 2);
	assert cacheGet(cache, checkKey).state === TaQueryState.Green;
}

test "output hash changed marks dependent red" {
	const cache = createCacheStore(100);
	const fileInput = createFileInputStore();

	// Parse computed at rev 1 with hash 42
	const parseKey = createQueryKey(TaQueryKind.Parse, 0);
	const parseEntry = createCacheEntry(parseKey);
	parseEntry.state = TaQueryState.Green;
	parseEntry.computedAt = 1;
	parseEntry.verifiedAt = 1;
	parseEntry.outputHash = 42;
	cachePut(cache, parseEntry);

	// TypeCheck depends on Parse with expected hash 42
	const checkKey = createQueryKey(TaQueryKind.TypeCheck, 0);
	const checkEntry = createCacheEntry(checkKey);
	checkEntry.state = TaQueryState.Red;
	checkEntry.computedAt = 1;
	checkEntry.verifiedAt = 0;
	const dep: TaDependencyEntry = { depKey: parseKey, expectedHash: 42 };
	checkEntry.dependencies = [dep];
	cachePut(cache, checkEntry);

	// Parse recomputed at rev 2 with DIFFERENT hash (real code change)
	const pe = cacheGet(cache, parseKey);
	pe.computedAt = 2;
	pe.verifiedAt = 2;
	pe.state = TaQueryState.Green;
	pe.outputHash = 99;  // different hash — actual semantic change

	// TypeCheck should NOT verify green
	assert !tryMarkGreen(cache, fileInput, checkKey, 2);
	assert cacheGet(cache, checkKey).state === TaQueryState.Red;
}

// ===== HIGH Durability Tests =====

test "high durability dep skips recursive verification" {
	const cache = createCacheStore(100);
	const fileInput = createFileInputStore();

	// Stdlib parse query — HIGH durability, computed at rev 1
	const stdKey = createQueryKey(TaQueryKind.Parse, 99);
	const stdEntry = createCacheEntry(stdKey);
	stdEntry.state = TaQueryState.Green;
	stdEntry.computedAt = 1;
	stdEntry.verifiedAt = 1;
	stdEntry.durability = TaDurability.High;
	cachePut(cache, stdEntry);

	// User query depends on stdlib query
	const userKey = createQueryKey(TaQueryKind.TypeCheck, 0);
	const userEntry = createCacheEntry(userKey);
	userEntry.state = TaQueryState.Red;
	userEntry.computedAt = 1;
	userEntry.verifiedAt = 0;
	const dep: TaDependencyEntry = { depKey: stdKey, expectedHash: 0 };
	userEntry.dependencies = [dep];
	cachePut(cache, userEntry);

	// HIGH durability dep not recomputed (computedAt <= entry.computedAt) → skip
	assert tryMarkGreen(cache, fileInput, userKey, 2);
}

test "high durability dep recomputed with same output stays green" {
	const cache = createCacheStore(100);
	const fileInput = createFileInputStore();

	// Stdlib query recomputed at rev 3, output hash unchanged (42)
	const stdKey = createQueryKey(TaQueryKind.Parse, 99);
	const stdEntry = createCacheEntry(stdKey);
	stdEntry.state = TaQueryState.Green;
	stdEntry.computedAt = 3;
	stdEntry.verifiedAt = 3;
	stdEntry.outputHash = 42;
	stdEntry.durability = TaDurability.High;
	cachePut(cache, stdEntry);

	// User query was computed at rev 1, expects hash 42
	const userKey = createQueryKey(TaQueryKind.TypeCheck, 0);
	const userEntry = createCacheEntry(userKey);
	userEntry.state = TaQueryState.Red;
	userEntry.computedAt = 1;
	userEntry.verifiedAt = 0;
	const dep: TaDependencyEntry = { depKey: stdKey, expectedHash: 42 };
	userEntry.dependencies = [dep];
	cachePut(cache, userEntry);

	// HIGH durability dep recomputed AFTER us but output unchanged → GREEN (Salsa early cutoff)
	assert tryMarkGreen(cache, fileInput, userKey, 4);
}

test "high durability dep recomputed with changed output marks red" {
	const cache = createCacheStore(100);
	const fileInput = createFileInputStore();

	// Stdlib query recomputed at rev 3, output hash changed (99 vs expected 42)
	const stdKey = createQueryKey(TaQueryKind.Parse, 99);
	const stdEntry = createCacheEntry(stdKey);
	stdEntry.state = TaQueryState.Green;
	stdEntry.computedAt = 3;
	stdEntry.verifiedAt = 3;
	stdEntry.outputHash = 99;
	stdEntry.durability = TaDurability.High;
	cachePut(cache, stdEntry);

	// User query was computed at rev 1, expects hash 42
	const userKey = createQueryKey(TaQueryKind.TypeCheck, 0);
	const userEntry = createCacheEntry(userKey);
	userEntry.state = TaQueryState.Red;
	userEntry.computedAt = 1;
	userEntry.verifiedAt = 0;
	const dep: TaDependencyEntry = { depKey: stdKey, expectedHash: 42 };
	userEntry.dependencies = [dep];
	cachePut(cache, userEntry);

	// HIGH durability dep recomputed AFTER us AND output changed → RED
	assert !tryMarkGreen(cache, fileInput, userKey, 4);
}

// ===== Cycle Detection (YELLOW) Tests =====

test "yellow state prevents infinite recursion" {
	const cache = createCacheStore(100);
	const fileInput = createFileInputStore();

	// A depends on B, B depends on A → cycle
	const keyA = createQueryKey(TaQueryKind.TypeCheck, 0);
	const keyB = createQueryKey(TaQueryKind.TypeCheck, 1);

	const entryA = createCacheEntry(keyA);
	entryA.state = TaQueryState.Red;
	entryA.computedAt = 1;
	entryA.verifiedAt = 0;
	const depA: TaDependencyEntry = { depKey: keyB, expectedHash: 0 };
	entryA.dependencies = [depA];
	cachePut(cache, entryA);

	const entryB = createCacheEntry(keyB);
	entryB.state = TaQueryState.Red;
	entryB.computedAt = 1;
	entryB.verifiedAt = 0;
	const depB: TaDependencyEntry = { depKey: keyA, expectedHash: 0 };
	entryB.dependencies = [depB];
	cachePut(cache, entryB);

	// Should NOT infinite loop — YELLOW breaks the cycle
	assert !tryMarkGreen(cache, fileInput, keyA, 2);
}

test "yellow entry returns false immediately" {
	const cache = createCacheStore(100);
	const fileInput = createFileInputStore();

	const key = createQueryKey(TaQueryKind.Parse, 0);
	const entry = createCacheEntry(key);
	entry.state = TaQueryState.Yellow;
	entry.verifiedAt = 0;
	cachePut(cache, entry);

	assert !tryMarkGreen(cache, fileInput, key, 1);
}

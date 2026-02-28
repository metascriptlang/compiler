// Trans-Am Red-Green Engine — core verification and query execution
//
// tryMarkGreen: recursively verify a cached query is still valid
// executeQuery: cache-or-compute with auto dependency recording
// invalidateFile: mark queries RED for a changed file + BFS dependents
//
// Phase 1: no output-hash comparison (Salsa optimization deferred).
// Uses callback registration for query executor (avoids closure codegen issues).

import {
	TaQueryKey, TaQueryKind, TaQueryState, TaDurability,
	createQueryKey, queryKeysEqual
} from "./revision";
import {
	TaCacheEntry, createCacheEntry,
	TaDependencyEntry, TaDependencyStack, TaDependencyList,
	pushFrame, popFrame,
	recordDependency, recordDurability, hasActiveFrame,
	createDependencyStack
} from "./query";
import {
	TaCacheStore, createCacheStore,
	cacheGet, cachePut, cacheContains,
	markQueriesRedForFile
} from "./cache";
import { TaFileInputStore, createFileInputStore, setFileText, getFileHash } from "./fileInput";
import { TaModuleDepGraph, createModuleDepGraph, getTransitiveDependents, recordModuleImport } from "./moduleDeps";
import { test, check, testGroup } from "std/testing";

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
	while (i < entry.dependencies.items.length) {
		const dep = entry.dependencies.items[i];

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

		// HIGH durability: skip verification (stdlib assumed stable)
		const depEntry = cacheGet(cache, dep.depKey);
		if (depEntry !== null) {
			if (depEntry.durability === TaDurability.High) {
				i = i + 1;
				continue;
			}
		}

		// Recursively verify dependency
		if (!tryMarkGreen(cache, fileInput, dep.depKey, currentRevision)) {
			entry.state = TaQueryState.Red;
			return false;
		}

		// Phase 1: if dep was recomputed since we cached, mark RED
		if (depEntry !== null) {
			if (depEntry.computedAt > entry.computedAt) {
				entry.state = TaQueryState.Red;
				return false;
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
	for (let i = 0; i < dependents.items.length; i = i + 1) {
		markQueriesRedForFile(cache, dependents.items[i]);
	}
}

// ===== Test Helpers =====

interface TaTestCounter {
	value: number;
}

function makeTestDeps(fileId: number, expectedHash: number): TaDependencyList {
	const deps: TaDependencyList = { items: [] };
	const dk = createQueryKey(TaQueryKind.FileText, fileId);
	const de: TaDependencyEntry = { depKey: dk, expectedHash: expectedHash };
	deps.items.push(de);
	return deps;
}

// ===== Tests =====

testGroup("TaRedGreen TryMarkGreen", () => {
	test("empty cache returns false", () => {
		const cache = createCacheStore(100);
		const fileInput = createFileInputStore();
		const key = createQueryKey(TaQueryKind.Parse, 0);
		check(!tryMarkGreen(cache, fileInput, key, 1));
	});
	test("green entry at current revision returns true", () => {
		const cache = createCacheStore(100);
		const fileInput = createFileInputStore();
		const key = createQueryKey(TaQueryKind.Parse, 0);
		const entry = createCacheEntry(key);
		entry.state = TaQueryState.Green;
		entry.verifiedAt = 5;
		cachePut(cache, entry);
		check(tryMarkGreen(cache, fileInput, key, 5));
	});
	test("entry with no deps verifies green", () => {
		const cache = createCacheStore(100);
		const fileInput = createFileInputStore();
		const key = createQueryKey(TaQueryKind.Parse, 0);
		const entry = createCacheEntry(key);
		entry.state = TaQueryState.Red;
		entry.verifiedAt = 0;
		cachePut(cache, entry);
		// No dependencies -> all deps verified trivially -> Green
		check(tryMarkGreen(cache, fileInput, key, 1));
	});
	test("file dependency hash mismatch -> false", () => {
		const cache = createCacheStore(100);
		const fileInput = createFileInputStore();
		setFileText(fileInput, "a.ms", "original");
		const parseKey = createQueryKey(TaQueryKind.Parse, 0);
		const entry = createCacheEntry(parseKey);
		entry.state = TaQueryState.Red;
		entry.verifiedAt = 0;
		entry.dependencies = makeTestDeps(0, 999);
		cachePut(cache, entry);
		check(!tryMarkGreen(cache, fileInput, parseKey, 1));
	});
	test("file dependency hash match -> true", () => {
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
		check(tryMarkGreen(cache, fileInput, parseKey, 1));
	});
});

testGroup("TaRedGreen ExecuteQueryWith", () => {
	test("stores entry as Green", () => {
		const cache = createCacheStore(100);
		const fileInput = createFileInputStore();
		const depStack = createDependencyStack();
		const key = createQueryKey(TaQueryKind.Parse, 0);
		pushFrame(depStack, key);
		executeQueryWith(cache, fileInput, depStack, key, 1, 42, true);
		const entry = cacheGet(cache, key);
		check(entry !== null);
		check(entry.state === TaQueryState.Green);
		check(entry.computedAt === 1);
		check(entry.outputHash === 42);
	});
	test("collects dependencies from frame", () => {
		const cache = createCacheStore(100);
		const fileInput = createFileInputStore();
		const depStack = createDependencyStack();
		const key = createQueryKey(TaQueryKind.TypeCheck, 0);
		const depKey = createQueryKey(TaQueryKind.Parse, 0);
		pushFrame(depStack, key);
		recordDependency(depStack, depKey, 100);
		executeQueryWith(cache, fileInput, depStack, key, 1, 42, true);
		const entry = cacheGet(cache, key);
		check(entry.dependencies.items.length === 1);
		check(queryKeysEqual(entry.dependencies.items[0].depKey, depKey));
	});
	test("not computed is no-op", () => {
		const cache = createCacheStore(100);
		const fileInput = createFileInputStore();
		const depStack = createDependencyStack();
		const key = createQueryKey(TaQueryKind.Parse, 0);
		executeQueryWith(cache, fileInput, depStack, key, 1, 0, false);
		check(!cacheContains(cache, key));
	});
});

testGroup("TaRedGreen InvalidateFile", () => {
	test("marks file queries red", () => {
		const cache = createCacheStore(100);
		const moduleDeps = createModuleDepGraph();
		const key = createQueryKey(TaQueryKind.Parse, 0);
		const entry = createCacheEntry(key);
		entry.state = TaQueryState.Green;
		cachePut(cache, entry);
		invalidateFile(cache, moduleDeps, 0);
		check(cacheGet(cache, key).state === TaQueryState.Red);
	});
	test("marks transitive dependents red", () => {
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
		check(cacheGet(cache, k1).state === TaQueryState.Red);
		check(cacheGet(cache, k0).state === TaQueryState.Red);
	});
});

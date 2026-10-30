// Trans-Am Red-Green Engine — core verification and query execution
//
// tryMarkGreen: recursively verify a cached query is still valid
// executeQuery: cache-or-compute with auto dependency recording
// invalidateFile: mark queries RED for a changed file + BFS dependents
//
// Uses callback registration for query executor (avoids closure codegen issues).

import {
	TaQueryKey, TaQueryKind, TaQueryState, TaDurability,
	createQueryKey, queryKeysEqual
} from "./revision";
import {
	createCacheEntry,
	TaDependencyStack,
	pushFrame, popFrame,
	recordDependency, hasActiveFrame,
	createDependencyStack
} from "./query";
import {
	TaCacheStore, createCacheStore,
	cacheGet, cachePut, cacheContains, cacheRemove,
	markQueriesRedForFile
} from "./cache";
import { TaFileInputStore, createFileInputStore, setFileText, getFileChangedAt, getLastChange, setFileDurability, getFileDurability } from "./fileInput";
import { TaModuleDepGraph, createModuleDepGraph, getTransitiveDependents, recordModuleImport } from "./moduleDeps";


function lowerDurability(a: TaDurability, b: TaDurability): TaDurability {
	return (a as int32) <= (b as int32) ? a : b;
}

// ===== tryMarkGreen — can we use the cached value? =====

export function tryMarkGreen(
	cache: TaCacheStore,
	fileInput: TaFileInputStore,
	key: TaQueryKey,
	currentRevision: int32
): boolean {
	const green = markGreen(cache, fileInput, key, currentRevision);
	if (green) {
		cache.hits += 1;
	} else {
		cache.misses += 1;
	}
	return green;
}

function markGreen(
	cache: TaCacheStore,
	fileInput: TaFileInputStore,
	key: TaQueryKey,
	currentRevision: int32
): boolean {
	const entry = cacheGet(cache, key);
	if (entry == null) return false;

	// Fast path: already verified this revision
	if (entry.verifiedAt == currentRevision) {
		return entry.state == TaQueryState.Green;
	}

	// Cycle detection
	if (entry.state == TaQueryState.Yellow) return false;
	entry.state = TaQueryState.Yellow;

	// Check each dependency
	let durability = TaDurability.High;
	for (const dep of entry.dependencies) {
		if (dep.queryKind == TaQueryKind.FileText) {
			const changedAt = getFileChangedAt(fileInput, dep.fileId);
			if (changedAt == null || changedAt > entry.verifiedAt) {
				entry.state = TaQueryState.Red;
				return false;
			}
			durability = lowerDurability(durability, getFileDurability(fileInput, dep.fileId));
			continue;
		}

		const depEntry = cacheGet(cache, dep);
		if (depEntry == null) {
			entry.state = TaQueryState.Red;
			return false;
		}

		const skipWalk = depEntry.durability == TaDurability.High && getLastChange(fileInput, TaDurability.High) <= entry.verifiedAt;
		if (!skipWalk && !markGreen(cache, fileInput, dep, currentRevision)) {
			entry.state = TaQueryState.Red;
			return false;
		}

		if (depEntry.changedAt > entry.verifiedAt) {
			entry.state = TaQueryState.Red;
			return false;
		}
		durability = lowerDurability(durability, depEntry.durability);
	}

	// All deps verified
	entry.durability = durability;
	entry.verifiedAt = currentRevision;
	entry.state = TaQueryState.Green;
	return true;
}

// ===== executeQueryWith — cache-or-compute =====

export function executeQueryWith(
	cache: TaCacheStore,
	fileInput: TaFileInputStore,
	depStack: TaDependencyStack,
	key: TaQueryKey,
	currentRevision: int32,
	changedAt: int32,
	wasComputed: boolean
): void {
	if (!wasComputed) return;

	// Store or update cache entry
	let entry = cacheGet(cache, key);
	if (entry == null) {
		entry = createCacheEntry(key);
		cachePut(cache, entry);
	}
	const kind = key.queryKind as int32;
	while (cache.recomputed.length <= kind) cache.recomputed.push(0);
	cache.recomputed[kind] += 1;
	entry.state = TaQueryState.Green;
	entry.computedAt = currentRevision;
	entry.verifiedAt = currentRevision;
	entry.changedAt = changedAt;

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
	fileId: int32
): void {
	markQueriesRedForFile(cache, fileId);

	const dependents = getTransitiveDependents(moduleDeps, fileId);
	for (let i = 0; i < dependents.length; i = i + 1) {
		markQueriesRedForFile(cache, dependents[i]);
	}
}

// ===== Test Helpers =====

function fileTextKey(fileId: int32): TaQueryKey {
	return createQueryKey(TaQueryKind.FileText, fileId);
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

test "a file changed after the entry was verified -> false" {
	const cache = createCacheStore(100);
	const fileInput = createFileInputStore();
	setFileText(fileInput, "a.ms", "original", 3);
	const parseKey = createQueryKey(TaQueryKind.Parse, 0);
	const entry = createCacheEntry(parseKey);
	entry.state = TaQueryState.Red;
	entry.verifiedAt = 2;
	entry.dependencies = [fileTextKey(0)];
	cachePut(cache, entry);
	assert !tryMarkGreen(cache, fileInput, parseKey, 3);
	assert cache.hits == 0 && cache.misses == 1;
}

test "a file changed no later than the entry was verified -> true" {
	for (const changedAt of [1, 2]) {
		const cache = createCacheStore(100);
		const fileInput = createFileInputStore();
		setFileText(fileInput, "a.ms", "source", changedAt);
		const parseKey = createQueryKey(TaQueryKind.Parse, 0);
		const entry = createCacheEntry(parseKey);
		entry.state = TaQueryState.Red;
		entry.verifiedAt = 2;
		entry.dependencies = [fileTextKey(0)];
		cachePut(cache, entry);
		assert tryMarkGreen(cache, fileInput, parseKey, 3);
		assert cache.hits == 1 && cache.misses == 0;
	}
}

test "a file the store does not know -> false" {
	const cache = createCacheStore(100);
	const fileInput = createFileInputStore();
	const parseKey = createQueryKey(TaQueryKind.Parse, 0);
	const entry = createCacheEntry(parseKey);
	entry.dependencies = [fileTextKey(99)];
	cachePut(cache, entry);
	assert !tryMarkGreen(cache, fileInput, parseKey, 1);
}

test "stores entry as Green" {
	const cache = createCacheStore(100);
	const fileInput = createFileInputStore();
	const depStack = createDependencyStack();
	const key = createQueryKey(TaQueryKind.Parse, 0);
	pushFrame(depStack, key);
	executeQueryWith(cache, fileInput, depStack, key, 3, 2, true);
	const entry = cacheGet(cache, key);
	assert entry != null;
	assert entry.state == TaQueryState.Green;
	assert entry.computedAt == 3;
	assert entry.verifiedAt == 3;
	assert entry.changedAt == 2;
	assert cache.recomputed[TaQueryKind.Parse as int32] == 1;
	assert cache.recomputed.length == (TaQueryKind.Parse as int32) + 1;
}

test "collects dependencies from frame" {
	const cache = createCacheStore(100);
	const fileInput = createFileInputStore();
	const depStack = createDependencyStack();
	const key = createQueryKey(TaQueryKind.TypeCheck, 0);
	const depKey = createQueryKey(TaQueryKind.Parse, 0);
	pushFrame(depStack, key);
	recordDependency(depStack, depKey);
	executeQueryWith(cache, fileInput, depStack, key, 1, 1, true);
	const entry = cacheGet(cache, key);
	assert entry.dependencies.length == 1;
	assert queryKeysEqual(entry.dependencies[0], depKey);
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
	assert cacheGet(cache, key).state == TaQueryState.Red;
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
	assert cacheGet(cache, k1).state == TaQueryState.Red;
	assert cacheGet(cache, k0).state == TaQueryState.Red;
}

// ===== Early Cutoff Tests =====

function parseThenCheck(cache: TaCacheStore): TaQueryKey {
	const parseKey = createQueryKey(TaQueryKind.Parse, 0);
	const parseEntry = createCacheEntry(parseKey);
	parseEntry.state = TaQueryState.Green;
	parseEntry.computedAt = 1;
	parseEntry.verifiedAt = 1;
	parseEntry.changedAt = 1;
	cachePut(cache, parseEntry);

	const checkKey = createQueryKey(TaQueryKind.TypeCheck, 0);
	const checkEntry = createCacheEntry(checkKey);
	checkEntry.state = TaQueryState.Red;
	checkEntry.computedAt = 1;
	checkEntry.verifiedAt = 1;
	checkEntry.dependencies = [parseKey];
	cachePut(cache, checkEntry);
	return checkKey;
}

test "a dependency recomputed to the same output keeps its dependent green (early cutoff)" {
	const cache = createCacheStore(100);
	const fileInput = createFileInputStore();
	const checkKey = parseThenCheck(cache);

	const pe = cacheGet(cache, createQueryKey(TaQueryKind.Parse, 0));
	pe.computedAt = 2;
	pe.verifiedAt = 2;

	assert tryMarkGreen(cache, fileInput, checkKey, 2);
	assert cacheGet(cache, checkKey).state == TaQueryState.Green;
}

test "a dependency recomputed to a different output marks its dependent red" {
	const cache = createCacheStore(100);
	const fileInput = createFileInputStore();
	const checkKey = parseThenCheck(cache);

	const pe = cacheGet(cache, createQueryKey(TaQueryKind.Parse, 0));
	pe.computedAt = 2;
	pe.verifiedAt = 2;
	pe.changedAt = 2;

	assert !tryMarkGreen(cache, fileInput, checkKey, 2);
	assert cacheGet(cache, checkKey).state == TaQueryState.Red;
}

test "a missing dependency marks its dependent red" {
	const cache = createCacheStore(100);
	const fileInput = createFileInputStore();
	const checkKey = parseThenCheck(cache);
	cacheRemove(cache, createQueryKey(TaQueryKind.Parse, 0));
	assert !tryMarkGreen(cache, fileInput, checkKey, 2);
}

// ===== HIGH Durability Tests =====

function highStdAndUser(cache: TaCacheStore, stdChangedAt: int32): TaQueryKey {
	const stdKey = createQueryKey(TaQueryKind.Parse, 99);
	const stdEntry = createCacheEntry(stdKey);
	stdEntry.state = TaQueryState.Green;
	stdEntry.computedAt = 3;
	stdEntry.verifiedAt = 3;
	stdEntry.changedAt = stdChangedAt;
	stdEntry.durability = TaDurability.High;
	cachePut(cache, stdEntry);

	const userKey = createQueryKey(TaQueryKind.TypeCheck, 0);
	const userEntry = createCacheEntry(userKey);
	userEntry.state = TaQueryState.Red;
	userEntry.computedAt = 1;
	userEntry.verifiedAt = 1;
	userEntry.dependencies = [stdKey];
	cachePut(cache, userEntry);
	return userKey;
}

test "high durability dep skips recursive verification" {
	const cache = createCacheStore(100);
	const fileInput = createFileInputStore();
	const userKey = highStdAndUser(cache, 1);
	cacheGet(cache, createQueryKey(TaQueryKind.Parse, 99)).dependencies = [fileTextKey(99)];
	assert tryMarkGreen(cache, fileInput, userKey, 4);
}

test "high durability dep recomputed with its output unchanged stays green" {
	const cache = createCacheStore(100);
	const fileInput = createFileInputStore();
	const userKey = highStdAndUser(cache, 1);
	assert tryMarkGreen(cache, fileInput, userKey, 4);
}

test "high durability dep recomputed with changed output marks red" {
	const cache = createCacheStore(100);
	const fileInput = createFileInputStore();
	const userKey = highStdAndUser(cache, 3);
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
	entryA.dependencies = [keyB];
	cachePut(cache, entryA);

	const entryB = createCacheEntry(keyB);
	entryB.state = TaQueryState.Red;
	entryB.computedAt = 1;
	entryB.verifiedAt = 0;
	entryB.dependencies = [keyA];
	cachePut(cache, entryB);

	// Should NOT infinite loop — YELLOW breaks the cycle
	assert !tryMarkGreen(cache, fileInput, keyA, 2);
}

test "recomputing a query replaces dependencies when its selected input changes" {
	for (const order of [[0, 1], [1, 0]]) {
		const cache = createCacheStore(10);
		const input = createFileInputStore();
		const stack = createDependencyStack();
		setFileText(input, "left.ms", "left", 0);
		setFileText(input, "right.ms", "right", 0);
		const key = createQueryKey(TaQueryKind.TypeCheck, 2);
		for (let i = 0; i < order.length; i += 1) {
			pushFrame(stack, key);
			recordDependency(stack, fileTextKey(order[i]));
			executeQueryWith(cache, input, stack, key, i + 1, i + 1, true);
		}
		const oldPath = order[0] == 0 ? "left.ms" : "right.ms";
		const selectedPath = order[1] == 0 ? "left.ms" : "right.ms";
		setFileText(input, oldPath, "detached input changed", 3);
		assert tryMarkGreen(cache, input, key, 3);
		setFileText(input, selectedPath, "selected input changed", 4);
		assert !tryMarkGreen(cache, input, key, 4);
		assert cache.recomputed[TaQueryKind.TypeCheck as int32] == 2;
	}
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

function durableConsumer(input: TaFileInputStore, cache: TaCacheStore, graph: TaModuleDepGraph, durability: TaDurability): TaQueryKey {
	setFileText(input, "/durability/dep.ms", "export const value = 1;", 1);
	setFileDurability(input, 0, durability, 1);
	const depKey = createQueryKey(TaQueryKind.Parse, 0);
	const dep = createCacheEntry(depKey);
	dep.computedAt = 1;
	dep.verifiedAt = 1;
	dep.changedAt = 1;
	dep.state = TaQueryState.Green;
	dep.durability = durability;
	dep.dependencies = [fileTextKey(0)];
	cachePut(cache, dep);
	const userKey = createQueryKey(TaQueryKind.TypeCheck, 1);
	const user = createCacheEntry(userKey);
	user.computedAt = 1;
	user.verifiedAt = 1;
	user.state = TaQueryState.Green;
	user.dependencies = [depKey];
	cachePut(cache, user);
	recordModuleImport(graph, 1, 0);
	return userKey;
}

test "a changed high-durability input invalidates its unchecked consumers" {
	for (const durability of [TaDurability.Low, TaDurability.High]) {
		const cache = createCacheStore(10);
		const input = createFileInputStore();
		const graph = createModuleDepGraph();
		const userKey = durableConsumer(input, cache, graph, durability);
		setFileText(input, "/durability/dep.ms", "export const value = 2;", 2);
		invalidateFile(cache, graph, 0);
		assert !tryMarkGreen(cache, input, userKey, 2);
	}
}

test "a high-durability input changed after a durability downgrade still invalidates" {
	const cache = createCacheStore(10);
	const input = createFileInputStore();
	const graph = createModuleDepGraph();
	const userKey = durableConsumer(input, cache, graph, TaDurability.High);
	setFileDurability(input, 0, TaDurability.Low, 2);
	setFileText(input, "/durability/dep.ms", "export const value = 3;", 3);
	invalidateFile(cache, graph, 0);
	assert !tryMarkGreen(cache, input, userKey, 3);
}

test "an unchanged high-durability input still skips its walk" {
	const cache = createCacheStore(10);
	const input = createFileInputStore();
	const graph = createModuleDepGraph();
	const userKey = durableConsumer(input, cache, graph, TaDurability.High);
	setFileText(input, "/durability/other.ms", "export const other = 1;", 2);
	cacheGet(cache, userKey).state = TaQueryState.Red;
	cacheGet(cache, createQueryKey(TaQueryKind.Parse, 0)).dependencies = [fileTextKey(99)];
	assert tryMarkGreen(cache, input, userKey, 2);
}

test "a consumer verified after a durability downgrade walks its input on the next write" {
	const cache = createCacheStore(10);
	const input = createFileInputStore();
	const graph = createModuleDepGraph();
	const userKey = durableConsumer(input, cache, graph, TaDurability.High);
	setFileDurability(input, 0, TaDurability.Low, 2);
	assert tryMarkGreen(cache, input, userKey, 2);
	setFileText(input, "/durability/dep.ms", "export const value = 3;", 3);
	assert !tryMarkGreen(cache, input, userKey, 3);
}

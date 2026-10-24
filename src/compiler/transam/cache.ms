// Trans-Am Cache — LRU with linear-scan eviction
//
// Lookup is O(1): fileIndex gives the entries of one file, at most one per query kind.
// Eviction and removal stay O(n): entries keep insertion order, which callers iterate.
//
// Arrays passed by pointer — bare T[] types.

import { TaQueryKey, TaQueryKind, TaQueryState, createQueryKey } from "./revision";
import { TaCacheEntry, createCacheEntry } from "./query";


// ===== Cache Store =====

export class TaCacheStore {
	entries: TaCacheEntry[];
	accessClock: int32;            // monotonic clock, incremented on each access
	capacity: int32;
	fileIndex: HashMap<int32, TaCacheEntry[]>;  // fileId → entries, for lookup and invalidation
	hits: int32;
	misses: int32;
	recomputed: int32[];
	marked: int32;
	evicted: int32;
	bound: int32;
	collected: int32;
}

export function createCacheStore(capacity: int32): TaCacheStore {
	return {
		entries: [],
		accessClock: 0,
		capacity,
		fileIndex: new HashMap<int32, TaCacheEntry[]>(),
		hits: 0,
		misses: 0,
		recomputed: [],
		marked: 0,
		evicted: 0,
		bound: 0,
		collected: 0,
	};
}

// ===== Lookup =====

function findEntry(cache: TaCacheStore, key: TaQueryKey): TaCacheEntry {
	const indexed = cache.fileIndex.get(key.fileId);
	if (indexed != null) {
		for (const entry of indexed) {
			if (entry.key.queryKind == key.queryKind) return entry;
		}
	}
	return null as unknown as TaCacheEntry;
}

export function cacheContains(cache: TaCacheStore, key: TaQueryKey): boolean {
	return findEntry(cache, key) != null;
}

function positionOf(list: TaCacheEntry[], entry: TaCacheEntry): int32 {
	for (let i = 0; i < list.length; i++) {
		if (list[i] == entry) return i;
	}
	return -1;
}

function touch(cache: TaCacheStore, entry: TaCacheEntry): void {
	cache.accessClock += 1;
	entry.accessedAt = cache.accessClock;
}

export function cacheGet(cache: TaCacheStore, key: TaQueryKey): TaCacheEntry {
	const entry = findEntry(cache, key);
	if (entry != null) touch(cache, entry);
	return entry;
}

// ===== Insert / Update =====

function findEvictIndex(cache: TaCacheStore): int32 {
	let minAccess = cache.entries[0].accessedAt;
	let minIdx = 0;
	for (let i = 1; i < cache.entries.length; i++) {
		if (cache.entries[i].accessedAt < minAccess) {
			minAccess = cache.entries[i].accessedAt;
			minIdx = i;
		}
	}
	return minIdx;
}

function removeFromFileIndex(cache: TaCacheStore, entry: TaCacheEntry): void {
	const fid = entry.key.fileId;
	const indexed = cache.fileIndex.get(fid);
	if (indexed == null) return;
	const at = positionOf(indexed, entry);
	for (let i = at; i < indexed.length - 1; i++) {
		indexed[i] = indexed[i + 1];
	}
	indexed.pop();
	if (indexed.length == 0) cache.fileIndex.delete(fid);
}

function evictAt(cache: TaCacheStore, idx: int32): void {
	removeFromFileIndex(cache, cache.entries[idx]);
	for (let i = idx; i < cache.entries.length - 1; i++) {
		cache.entries[i] = cache.entries[i + 1];
	}
	cache.entries.pop();
}

export function cachePut(cache: TaCacheStore, entry: TaCacheEntry): void {
	const old = findEntry(cache, entry.key);
	if (old != null) {
		cache.entries[positionOf(cache.entries, old)] = entry;
		const sameFile = cache.fileIndex.get(entry.key.fileId);
		if (sameFile != null) sameFile[positionOf(sameFile, old)] = entry;
		touch(cache, entry);
		return;
	}
	if (cache.entries.length >= cache.capacity) {
		evictAt(cache, findEvictIndex(cache));
		cache.evicted += 1;
	}
	touch(cache, entry);
	cache.entries.push(entry);
	const indexed = cache.fileIndex.get(entry.key.fileId);
	if (indexed != null) {
		indexed.push(entry);
	} else {
		cache.fileIndex.set(entry.key.fileId, [entry]);
	}
}

// ===== Remove =====

export function cacheRemove(cache: TaCacheStore, key: TaQueryKey): boolean {
	const entry = findEntry(cache, key);
	if (entry == null) return false;
	evictAt(cache, positionOf(cache.entries, entry));
	return true;
}

// ===== Bulk State Mutation =====

export function markQueriesRedForFile(cache: TaCacheStore, fileId: int32): void {
	const indexed = cache.fileIndex.get(fileId);
	if (indexed == null) return;
	for (const entry of indexed) {
		entry.state = TaQueryState.Red;
	}
	cache.marked += indexed.length;
}

// ===== Tests =====
test "create empty" {
	const cache = createCacheStore(10);
	assert cache.entries.length == 0;
	assert cache.capacity == 10;
}

test "put and get" {
	const cache = createCacheStore(10);
	const key = createQueryKey(TaQueryKind.Parse, 0);
	const entry = createCacheEntry(key);
	entry.state = TaQueryState.Green;
	cachePut(cache, entry);
	const got = cacheGet(cache, key);
	assert got != null;
	assert got.state == TaQueryState.Green;
}

test "get miss returns null" {
	const cache = createCacheStore(10);
	const key = createQueryKey(TaQueryKind.Parse, 99);
	const got = cacheGet(cache, key);
	assert got == null;
}

test "contains true/false" {
	const cache = createCacheStore(10);
	const key = createQueryKey(TaQueryKind.Parse, 0);
	assert !cacheContains(cache, key);
	const entry = createCacheEntry(key);
	cachePut(cache, entry);
	assert cacheContains(cache, key);
}

test "evicts at capacity" {
	const cache = createCacheStore(2);
	const k1 = createQueryKey(TaQueryKind.Parse, 1);
	const k2 = createQueryKey(TaQueryKind.Parse, 2);
	const k3 = createQueryKey(TaQueryKind.Parse, 3);
	const e1 = createCacheEntry(k1);
	const e2 = createCacheEntry(k2);
	const e3 = createCacheEntry(k3);
	cachePut(cache, e1);
	cachePut(cache, e2);
	assert cache.entries.length == 2;
	assert cache.evicted == 0;
	cachePut(cache, e3);
	assert cache.entries.length == 2;
	assert cache.evicted == 1;
	// k1 was least recently used, should be evicted
	assert !cacheContains(cache, k1);
	assert cacheContains(cache, k2);
	assert cacheContains(cache, k3);
}

test "accessed entry not evicted" {
	const cache = createCacheStore(2);
	const k1 = createQueryKey(TaQueryKind.Parse, 1);
	const k2 = createQueryKey(TaQueryKind.Parse, 2);
	const k3 = createQueryKey(TaQueryKind.Parse, 3);
	const e1 = createCacheEntry(k1);
	const e2 = createCacheEntry(k2);
	const e3 = createCacheEntry(k3);
	cachePut(cache, e1);
	cachePut(cache, e2);
	// Touch k1 so k2 becomes LRU
	cacheGet(cache, k1);
	cachePut(cache, e3);
	assert cacheContains(cache, k1);  // was touched
	assert !cacheContains(cache, k2); // evicted (LRU)
	assert cacheContains(cache, k3);
}

test "put existing key updates in place" {
	const cache = createCacheStore(10);
	const key = createQueryKey(TaQueryKind.Parse, 1);
	const e1 = createCacheEntry(key);
	e1.outputHash = 100;
	cachePut(cache, e1);
	const e2 = createCacheEntry(key);
	e2.outputHash = 200;
	cachePut(cache, e2);
	assert cache.entries.length == 1;
	const got = cacheGet(cache, key);
	assert got.outputHash == 200;
}

test "remove existing" {
	const cache = createCacheStore(10);
	const key = createQueryKey(TaQueryKind.Parse, 1);
	const entry = createCacheEntry(key);
	cachePut(cache, entry);
	assert cacheRemove(cache, key);
	assert !cacheContains(cache, key);
}

test "remove nonexistent returns false" {
	const cache = createCacheStore(10);
	const key = createQueryKey(TaQueryKind.Parse, 99);
	assert !cacheRemove(cache, key);
}

test "markQueriesRedForFile targets specific file" {
	const cache = createCacheStore(10);
	const k1 = createQueryKey(TaQueryKind.Parse, 1);
	const k2 = createQueryKey(TaQueryKind.Parse, 2);
	const e1 = createCacheEntry(k1);
	const e2 = createCacheEntry(k2);
	e1.state = TaQueryState.Green;
	e2.state = TaQueryState.Green;
	cachePut(cache, e1);
	cachePut(cache, e2);
	markQueriesRedForFile(cache, 1);
	assert cache.marked == 1;
	assert cacheGet(cache, k1).state == TaQueryState.Red;
	assert cacheGet(cache, k2).state == TaQueryState.Green;
}

test "get put remove address one entry per kind and file id" {
	const cache = createCacheStore(100);
	for (let fileId = 0; fileId < 5; fileId++) {
		cachePut(cache, createCacheEntry(createQueryKey(TaQueryKind.Parse, fileId)));
		cachePut(cache, createCacheEntry(createQueryKey(TaQueryKind.TypeCheck, fileId)));
	}
	assert cache.entries.length == 10;
	const parse3 = cacheGet(cache, createQueryKey(TaQueryKind.Parse, 3));
	assert parse3.key.queryKind == TaQueryKind.Parse && parse3.key.fileId == 3;
	assert cacheGet(cache, createQueryKey(TaQueryKind.Lower, 3)) == null;
	assert cacheGet(cache, createQueryKey(TaQueryKind.Parse, 50)) == null;
	assert cacheRemove(cache, createQueryKey(TaQueryKind.Parse, 3));
	assert cacheGet(cache, createQueryKey(TaQueryKind.Parse, 3)) == null;
	assert cacheGet(cache, createQueryKey(TaQueryKind.TypeCheck, 3)) != null;
	assert cache.entries.length == 9;
	assert !cacheRemove(cache, createQueryKey(TaQueryKind.Parse, 3));
	const replacement = createCacheEntry(createQueryKey(TaQueryKind.TypeCheck, 3));
	cachePut(cache, replacement);
	assert cacheGet(cache, createQueryKey(TaQueryKind.TypeCheck, 3)) == replacement;
	assert cache.entries.length == 9;
	markQueriesRedForFile(cache, 3);
	assert cache.marked == 1;
}

test "eviction takes the least recently used entry across kinds and keeps insertion order" {
	const cache = createCacheStore(3);
	const parse1 = createQueryKey(TaQueryKind.Parse, 1);
	const check1 = createQueryKey(TaQueryKind.TypeCheck, 1);
	const parse2 = createQueryKey(TaQueryKind.Parse, 2);
	const parse3 = createQueryKey(TaQueryKind.Parse, 3);
	cachePut(cache, createCacheEntry(parse1));
	cachePut(cache, createCacheEntry(check1));
	cachePut(cache, createCacheEntry(parse2));
	cacheGet(cache, parse1);
	cachePut(cache, createCacheEntry(parse3));
	assert cache.evicted == 1;
	assert !cacheContains(cache, check1);
	assert cacheContains(cache, parse1) && cacheContains(cache, parse2);
	assert cache.entries[0].key.fileId == 1 && cache.entries[1].key.fileId == 2;
	assert cache.entries[2].key.fileId == 3;
	assert cache.fileIndex.get(1).length == 1;
}

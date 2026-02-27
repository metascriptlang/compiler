// Trans-Am Cache — simplified LRU with linear-scan eviction
//
// Phase 1: access-counter based LRU. O(n) eviction, O(n) lookup.
// Phase 2: upgrade to O(1) doubly-linked list if profiling shows need.
//
// DRC-safe: all arrays wrapped in interfaces.

import { TaQueryKey, TaQueryKind, TaQueryState, TaDurability, createQueryKey, queryKeysEqual } from "./revision";
import { TaCacheEntry, createCacheEntry } from "./query";
import { taHashKey } from "./hash";
import { test, check, testGroup } from "std/testing";

// ===== DRC-safe wrappers =====

export interface TaCacheEntryList {
	items: TaCacheEntry[];
}

export interface TaNumberList {
	items: number[];
}

// ===== Cache Store =====

export interface TaCacheStore {
	entries: TaCacheEntryList;
	accessCounters: TaNumberList;   // parallel: last-access time per entry
	accessClock: number;            // monotonic clock, incremented on each access
	capacity: number;
}

export function createCacheStore(capacity: number): TaCacheStore {
	return {
		entries: { items: [] },
		accessCounters: { items: [] },
		accessClock: 0,
		capacity,
	};
}

// ===== Lookup =====

function findIndex(cache: TaCacheStore, key: TaQueryKey): number {
	let i = 0;
	while (i < cache.entries.items.length) {
		if (queryKeysEqual(cache.entries.items[i].key, key)) return i;
		i = i + 1;
	}
	return -1;
}

export function cacheGet(cache: TaCacheStore, key: TaQueryKey): TaCacheEntry {
	const idx = findIndex(cache, key);
	if (idx < 0) return null as unknown as TaCacheEntry;
	cache.accessClock = cache.accessClock + 1;
	cache.accessCounters.items[idx] = cache.accessClock;
	return cache.entries.items[idx];
}

export function cacheContains(cache: TaCacheStore, key: TaQueryKey): boolean {
	return findIndex(cache, key) >= 0;
}

// ===== Insert / Update =====

function findEvictIndex(cache: TaCacheStore): number {
	let minAccess = cache.accessCounters.items[0];
	let minIdx = 0;
	let i = 1;
	while (i < cache.accessCounters.items.length) {
		if (cache.accessCounters.items[i] < minAccess) {
			minAccess = cache.accessCounters.items[i];
			minIdx = i;
		}
		i = i + 1;
	}
	return minIdx;
}

function evictAt(cache: TaCacheStore, idx: number): void {
	// Manual removal: shift elements left, then pop
	let i = idx;
	while (i < cache.entries.items.length - 1) {
		cache.entries.items[i] = cache.entries.items[i + 1];
		cache.accessCounters.items[i] = cache.accessCounters.items[i + 1];
		i = i + 1;
	}
	cache.entries.items.pop();
	cache.accessCounters.items.pop();
}

export function cachePut(cache: TaCacheStore, entry: TaCacheEntry): void {
	// Update existing
	const idx = findIndex(cache, entry.key);
	if (idx >= 0) {
		cache.entries.items[idx] = entry;
		cache.accessClock = cache.accessClock + 1;
		cache.accessCounters.items[idx] = cache.accessClock;
		return;
	}
	// Evict if at capacity
	if (cache.entries.items.length >= cache.capacity) {
		const evictIdx = findEvictIndex(cache);
		evictAt(cache, evictIdx);
	}
	// Insert
	cache.accessClock = cache.accessClock + 1;
	cache.entries.items.push(entry);
	cache.accessCounters.items.push(cache.accessClock);
}

// ===== Remove =====

export function cacheRemove(cache: TaCacheStore, key: TaQueryKey): boolean {
	const idx = findIndex(cache, key);
	if (idx < 0) return false;
	evictAt(cache, idx);
	return true;
}

// ===== Bulk State Mutation =====

export function markAllRed(cache: TaCacheStore): void {
	let i = 0;
	while (i < cache.entries.items.length) {
		if (cache.entries.items[i].state === TaQueryState.Green) {
			cache.entries.items[i].state = TaQueryState.Red;
		}
		i = i + 1;
	}
}

export function markQueriesRedForFile(cache: TaCacheStore, fileId: number): void {
	let i = 0;
	while (i < cache.entries.items.length) {
		if (cache.entries.items[i].key.fileId === fileId) {
			cache.entries.items[i].state = TaQueryState.Red;
		}
		i = i + 1;
	}
}

// ===== Tests =====

testGroup("TaCacheStore Basics", () => {
	test("create empty", () => {
		const cache = createCacheStore(10);
		check(cache.entries.items.length === 0);
		check(cache.capacity === 10);
	});
	test("put and get", () => {
		const cache = createCacheStore(10);
		const key = createQueryKey(TaQueryKind.Parse, 0);
		const entry = createCacheEntry(key);
		entry.state = TaQueryState.Green;
		cachePut(cache, entry);
		const got = cacheGet(cache, key);
		check(got !== null);
		check(got.state === TaQueryState.Green);
	});
	test("get miss returns null", () => {
		const cache = createCacheStore(10);
		const key = createQueryKey(TaQueryKind.Parse, 99);
		const got = cacheGet(cache, key);
		check(got === null);
	});
	test("contains true/false", () => {
		const cache = createCacheStore(10);
		const key = createQueryKey(TaQueryKind.Parse, 0);
		check(!cacheContains(cache, key));
		const entry = createCacheEntry(key);
		cachePut(cache, entry);
		check(cacheContains(cache, key));
	});
});

testGroup("TaCacheStore Eviction", () => {
	test("evicts at capacity", () => {
		const cache = createCacheStore(2);
		const k1 = createQueryKey(TaQueryKind.Parse, 1);
		const k2 = createQueryKey(TaQueryKind.Parse, 2);
		const k3 = createQueryKey(TaQueryKind.Parse, 3);
		const e1 = createCacheEntry(k1);
		const e2 = createCacheEntry(k2);
		const e3 = createCacheEntry(k3);
		cachePut(cache, e1);
		cachePut(cache, e2);
		check(cache.entries.items.length === 2);
		cachePut(cache, e3);
		check(cache.entries.items.length === 2);
		// k1 was least recently used, should be evicted
		check(!cacheContains(cache, k1));
		check(cacheContains(cache, k2));
		check(cacheContains(cache, k3));
	});
	test("accessed entry not evicted", () => {
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
		check(cacheContains(cache, k1));  // was touched
		check(!cacheContains(cache, k2)); // evicted (LRU)
		check(cacheContains(cache, k3));
	});
});

testGroup("TaCacheStore Update", () => {
	test("put existing key updates in place", () => {
		const cache = createCacheStore(10);
		const key = createQueryKey(TaQueryKind.Parse, 1);
		const e1 = createCacheEntry(key);
		e1.outputHash = 100;
		cachePut(cache, e1);
		const e2 = createCacheEntry(key);
		e2.outputHash = 200;
		cachePut(cache, e2);
		check(cache.entries.items.length === 1);
		const got = cacheGet(cache, key);
		check(got.outputHash === 200);
	});
});

testGroup("TaCacheStore Remove", () => {
	test("remove existing", () => {
		const cache = createCacheStore(10);
		const key = createQueryKey(TaQueryKind.Parse, 1);
		const entry = createCacheEntry(key);
		cachePut(cache, entry);
		check(cacheRemove(cache, key));
		check(!cacheContains(cache, key));
	});
	test("remove nonexistent returns false", () => {
		const cache = createCacheStore(10);
		const key = createQueryKey(TaQueryKind.Parse, 99);
		check(!cacheRemove(cache, key));
	});
});

testGroup("TaCacheStore MarkRed", () => {
	test("markAllRed turns green to red", () => {
		const cache = createCacheStore(10);
		const k1 = createQueryKey(TaQueryKind.Parse, 1);
		const k2 = createQueryKey(TaQueryKind.TypeCheck, 1);
		const e1 = createCacheEntry(k1);
		const e2 = createCacheEntry(k2);
		e1.state = TaQueryState.Green;
		e2.state = TaQueryState.Green;
		cachePut(cache, e1);
		cachePut(cache, e2);
		markAllRed(cache);
		check(cacheGet(cache, k1).state === TaQueryState.Red);
		check(cacheGet(cache, k2).state === TaQueryState.Red);
	});
	test("markQueriesRedForFile targets specific file", () => {
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
		check(cacheGet(cache, k1).state === TaQueryState.Red);
		check(cacheGet(cache, k2).state === TaQueryState.Green);
	});
});

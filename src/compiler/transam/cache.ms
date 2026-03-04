// Trans-Am Cache — simplified LRU with linear-scan eviction
//
// Phase 1: access-counter based LRU. O(n) eviction, O(n) lookup.
// Phase 2: upgrade to O(1) doubly-linked list if profiling shows need.
//
// Arrays passed by pointer — bare T[] types.

import { TaQueryKey, TaQueryKind, TaQueryState, TaDurability, createQueryKey, queryKeysEqual } from "./revision";
import { TaCacheEntry, createCacheEntry } from "./query";
import { taHashKey } from "./hash";
import { check } from "std/testing";

// ===== Cache Store =====

export interface TaCacheStore {
	entries: TaCacheEntry[];
	accessCounters: number[];   // parallel: last-access time per entry
	accessClock: number;            // monotonic clock, incremented on each access
	capacity: number;
}

export function createCacheStore(capacity: number): TaCacheStore {
	return {
		entries: [],
		accessCounters: [],
		accessClock: 0,
		capacity,
	};
}

// ===== Lookup =====

function findIndex(cache: TaCacheStore, key: TaQueryKey): number {
	for (let i = 0; i < cache.entries.length; i = i + 1) {
		if (queryKeysEqual(cache.entries[i].key, key)) return i;
	}
	return -1;
}

export function cacheGet(cache: TaCacheStore, key: TaQueryKey): TaCacheEntry {
	const idx = findIndex(cache, key);
	if (idx < 0) return null as unknown as TaCacheEntry;
	cache.accessClock = cache.accessClock + 1;
	cache.accessCounters[idx] = cache.accessClock;
	return cache.entries[idx];
}

export function cacheContains(cache: TaCacheStore, key: TaQueryKey): boolean {
	return findIndex(cache, key) >= 0;
}

// ===== Insert / Update =====

function findEvictIndex(cache: TaCacheStore): number {
	let minAccess = cache.accessCounters[0];
	let minIdx = 0;
	for (let i = 1; i < cache.accessCounters.length; i = i + 1) {
		if (cache.accessCounters[i] < minAccess) {
			minAccess = cache.accessCounters[i];
			minIdx = i;
		}
	}
	return minIdx;
}

function evictAt(cache: TaCacheStore, idx: number): void {
	// Manual removal: shift elements left, then pop
	for (let i = idx; i < cache.entries.length - 1; i = i + 1) {
		cache.entries[i] = cache.entries[i + 1];
		cache.accessCounters[i] = cache.accessCounters[i + 1];
	}
	cache.entries.pop();
	cache.accessCounters.pop();
}

export function cachePut(cache: TaCacheStore, entry: TaCacheEntry): void {
	// Update existing
	const idx = findIndex(cache, entry.key);
	if (idx >= 0) {
		cache.entries[idx] = entry;
		cache.accessClock = cache.accessClock + 1;
		cache.accessCounters[idx] = cache.accessClock;
		return;
	}
	// Evict if at capacity
	if (cache.entries.length >= cache.capacity) {
		const evictIdx = findEvictIndex(cache);
		evictAt(cache, evictIdx);
	}
	// Insert
	cache.accessClock = cache.accessClock + 1;
	cache.entries.push(entry);
	cache.accessCounters.push(cache.accessClock);
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
	for (let i = 0; i < cache.entries.length; i = i + 1) {
		if (cache.entries[i].state === TaQueryState.Green) {
			cache.entries[i].state = TaQueryState.Red;
		}
	}
}

export function markQueriesRedForFile(cache: TaCacheStore, fileId: number): void {
	for (let i = 0; i < cache.entries.length; i = i + 1) {
		if (cache.entries[i].key.fileId === fileId) {
			cache.entries[i].state = TaQueryState.Red;
		}
	}
}

// ===== Tests =====
test "create empty" {
	const cache = createCacheStore(10);
	check(cache.entries.length === 0);
	check(cache.capacity === 10);
}

test "put and get" {
	const cache = createCacheStore(10);
	const key = createQueryKey(TaQueryKind.Parse, 0);
	const entry = createCacheEntry(key);
	entry.state = TaQueryState.Green;
	cachePut(cache, entry);
	const got = cacheGet(cache, key);
	check(got !== null);
	check(got.state === TaQueryState.Green);
}

test "get miss returns null" {
	const cache = createCacheStore(10);
	const key = createQueryKey(TaQueryKind.Parse, 99);
	const got = cacheGet(cache, key);
	check(got === null);
}

test "contains true/false" {
	const cache = createCacheStore(10);
	const key = createQueryKey(TaQueryKind.Parse, 0);
	check(!cacheContains(cache, key));
	const entry = createCacheEntry(key);
	cachePut(cache, entry);
	check(cacheContains(cache, key));
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
	check(cache.entries.length === 2);
	cachePut(cache, e3);
	check(cache.entries.length === 2);
	// k1 was least recently used, should be evicted
	check(!cacheContains(cache, k1));
	check(cacheContains(cache, k2));
	check(cacheContains(cache, k3));
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
	check(cacheContains(cache, k1));  // was touched
	check(!cacheContains(cache, k2)); // evicted (LRU)
	check(cacheContains(cache, k3));
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
	check(cache.entries.length === 1);
	const got = cacheGet(cache, key);
	check(got.outputHash === 200);
}

test "remove existing" {
	const cache = createCacheStore(10);
	const key = createQueryKey(TaQueryKind.Parse, 1);
	const entry = createCacheEntry(key);
	cachePut(cache, entry);
	check(cacheRemove(cache, key));
	check(!cacheContains(cache, key));
}

test "remove nonexistent returns false" {
	const cache = createCacheStore(10);
	const key = createQueryKey(TaQueryKind.Parse, 99);
	check(!cacheRemove(cache, key));
}

test "markAllRed turns green to red" {
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
	check(cacheGet(cache, k1).state === TaQueryState.Red);
	check(cacheGet(cache, k2).state === TaQueryState.Green);
}

// Identifier interning — reference IdentCache parity
// Fixed hash table (4096 buckets) + chaining. DJB2 hash.
// Intern string → unique int32 ID for O(1) symbol name comparison.

import { hashStringSigned } from "std/hash";

// ===== Types =====

export class IdentEntry {
	name: string;
	id: int32;
	next: IdentEntry;
	hash: int32;
}

export class IdentCache {
	buckets: IdentEntry[];
	counter: int32;
}

// ===== Constructor =====

const BUCKET_COUNT: int32 = 4096;
const BUCKET_MASK: int32 = 4095;

export function createIdentCache(): IdentCache {
	const buckets: IdentEntry[] = [];
	let i = 0;
	while (i < BUCKET_COUNT) {
		buckets.push(null as unknown as IdentEntry);
		i = i + 1;
	}
	return { buckets, counter: 0 };
}

// ===== Core: Intern String → ID =====

export function getIdentId(cache: IdentCache, name: string): int32 {
	const h = hashStringSigned(name);
	const idx = h & BUCKET_MASK;
	let entry = cache.buckets[idx];
	let last: IdentEntry = null as unknown as IdentEntry;
	while (entry != null) {
		if (entry.hash == h && entry.name == name) {
			// Move-to-front (LRU)
			if (last != null) {
				last.next = entry.next;
				entry.next = cache.buckets[idx];
				cache.buckets[idx] = entry;
			}
			return entry.id;
		}
		last = entry;
		entry = entry.next;
	}
	// Not found — allocate new entry
	cache.counter = cache.counter + 1;
	const newEntry: IdentEntry = {
		name,
		id: cache.counter,
		next: cache.buckets[idx],
		hash: h,
	};
	cache.buckets[idx] = newEntry;
	return newEntry.id;
}

// ===== Tests =====

test "same string returns same id" {
	const cache = createIdentCache();
	const id1 = getIdentId(cache, "hello");
	const id2 = getIdentId(cache, "hello");
	assert id1 == id2;
}

test "different strings return different ids" {
	const cache = createIdentCache();
	const id1 = getIdentId(cache, "foo");
	const id2 = getIdentId(cache, "bar");
	assert id1 != id2;
}

test "ids start at 1" {
	const cache = createIdentCache();
	const id = getIdentId(cache, "first");
	assert id == 1;
}

test "empty string interns" {
	const cache = createIdentCache();
	const id1 = getIdentId(cache, "");
	const id2 = getIdentId(cache, "");
	assert id1 == id2;
	assert id1 > 0;
}

test "many identifiers" {
	const cache = createIdentCache();
	let i = 0;
	while (i < 100) {
		const name = "var_" + i.toString();
		const id = getIdentId(cache, name);
		assert id > 0;
		// Re-intern returns same id
		const id2 = getIdentId(cache, name);
		assert id == id2;
		i = i + 1;
	}
	assert cache.counter == 100;
}

import { TaQueryKey, TaQueryKind, createQueryKey } from "./revision";
import { TaCacheStore, cacheGet, cachePut, createCacheStore } from "./cache";
import { createCacheEntry } from "./query";

export class TaOutputStore {
	outputs: HashMap<string, string>;
}

export function createOutputStore(): TaOutputStore {
	return { outputs: new HashMap<string, string>() };
}

function outputKey(key: TaQueryKey): string {
	return `${key.queryKind as int32}:${key.fileId}`;
}

export function outputChangedAt(store: TaOutputStore, cache: TaCacheStore, key: TaQueryKey, output: string | null, inputs: TaQueryKey[], revision: int32): int32 {
	const slot = outputKey(key);
	const before = store.outputs.get(slot);
	if (output == null) {
		store.outputs.delete(slot);
		return revision;
	}
	store.outputs.set(slot, output);
	const prev = cacheGet(cache, key);
	if (prev == null || before == null || before != output) return revision;
	for (const input of inputs) {
		const dep = cacheGet(cache, input);
		if (dep == null || dep.changedAt > prev.verifiedAt) return revision;
	}
	return prev.changedAt;
}

function stored(cache: TaCacheStore, key: TaQueryKey, changedAt: int32, verifiedAt: int32): void {
	const entry = createCacheEntry(key);
	entry.changedAt = changedAt;
	entry.verifiedAt = verifiedAt;
	cachePut(cache, entry);
}

test "an output equal to the previous one keeps its changedAt only while no input changed after it was verified" {
	const check = createQueryKey(TaQueryKind.TypeCheck, 1);
	const dep = createQueryKey(TaQueryKind.TypeCheck, 2);
	for (const depChangedAt of [2, 4]) {
		const store = createOutputStore();
		const cache = createCacheStore(10);
		assert outputChangedAt(store, cache, check, "iface", [dep], 3) == 3;
		stored(cache, check, 3, 3);
		stored(cache, dep, depChangedAt, 5);
		const expected = depChangedAt > 3 ? 5 : 3;
		assert outputChangedAt(store, cache, check, "iface", [dep], 5) == expected;
	}
}

test "a different output, or one that cannot be compared, is changed at the current revision" {
	const check = createQueryKey(TaQueryKind.TypeCheck, 1);
	for (const next of ["other", null]) {
		const store = createOutputStore();
		const cache = createCacheStore(10);
		outputChangedAt(store, cache, check, "iface", [], 3);
		stored(cache, check, 3, 3);
		assert outputChangedAt(store, cache, check, next, [], 5) == 5;
		assert outputChangedAt(store, cache, check, "iface", [], 6) == 6;
	}
}

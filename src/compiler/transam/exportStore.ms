import { ExportedSymInfo } from "../../checker/context";

export class TaExportStore {
	previous: HashMap<string, ExportedSymInfo[]>;
	implTexts: HashMap<int32, string>;
	implSeen: HashMap<int32, int32>;
	implChangedAt: HashMap<int32, int32>;
	collectedAt: HashMap<int32, int32>;
	closure: HashMap<int32, int32>;
	closureRevision: int32;
}

export function createExportStore(): TaExportStore {
	return {
		previous: new HashMap<string, ExportedSymInfo[]>(),
		implTexts: new HashMap<int32, string>(),
		implSeen: new HashMap<int32, int32>(),
		implChangedAt: new HashMap<int32, int32>(),
		collectedAt: new HashMap<int32, int32>(),
		closure: new HashMap<int32, int32>(),
		closureRevision: -1,
	};
}

export function keepPreviousExports(store: TaExportStore, path: string, symbols: ExportedSymInfo[]): void {
	store.previous.set(path, symbols);
}

export function previousExports(store: TaExportStore, path: string): ExportedSymInfo[] | null {
	return store.previous.get(path) ?? null;
}

export function forgetPreviousExports(store: TaExportStore, path: string): void {
	store.previous.delete(path);
}

export function forgetCollected(store: TaExportStore, fileId: int32): void {
	store.collectedAt.delete(fileId);
}

export function forgetAllCollected(store: TaExportStore): void {
	store.previous = new HashMap<string, ExportedSymInfo[]>();
	store.collectedAt = new HashMap<int32, int32>();
}

export function markCollected(store: TaExportStore, fileId: int32, revision: int32): void {
	store.collectedAt.set(fileId, revision);
}

export function collectedAtOf(store: TaExportStore, fileId: int32): int32 | null {
	return store.collectedAt.get(fileId);
}

// The revision a module's implementation (its tree without comments and positions) changed at, while the file
// still has the text it had when this was last asked.
export function knownImplChangedAt(store: TaExportStore, fileId: int32, fileChangedAt: int32): int32 | null {
	const seen = store.implSeen.get(fileId);
	return seen != null && seen == fileChangedAt ? store.implChangedAt.get(fileId) : null;
}

export function recordImpl(store: TaExportStore, fileId: int32, fileChangedAt: int32, text: string | null, revision: int32): int32 {
	const before = store.implTexts.get(fileId);
	const was = store.implChangedAt.get(fileId);
	store.implSeen.set(fileId, fileChangedAt);
	if (text == null) {
		store.implTexts.delete(fileId);
		store.implChangedAt.set(fileId, revision);
		return revision;
	}
	store.implTexts.set(fileId, text);
	const at = before != null && was != null && before == text ? was : fileChangedAt;
	store.implChangedAt.set(fileId, at);
	return at;
}

// The latest implementation change in a module's import closure, valid for one revision.
export function closureChangedAt(store: TaExportStore, fileId: int32, revision: int32): int32 | null {
	return store.closureRevision == revision ? store.closure.get(fileId) : null;
}

export function setClosureChangedAt(store: TaExportStore, fileId: int32, revision: int32, at: int32): void {
	if (store.closureRevision != revision) {
		store.closure = new HashMap<int32, int32>();
		store.closureRevision = revision;
	}
	store.closure.set(fileId, at);
}

test "an equal implementation text keeps its revision while the file is unchanged, a different one takes the revision its file was written at, none takes the current" {
	const store = createExportStore();
	assert knownImplChangedAt(store, 1, 3) == null;
	assert recordImpl(store, 1, 3, "a", 3) == 3;
	assert knownImplChangedAt(store, 1, 3) == 3;
	assert knownImplChangedAt(store, 1, 5) == null;
	assert recordImpl(store, 1, 5, "a", 5) == 3;
	assert recordImpl(store, 1, 6, "b", 6) == 6;
	assert recordImpl(store, 1, 7, null, 7) == 7;
	assert recordImpl(store, 1, 8, "b", 8) == 8;
	assert recordImpl(store, 2, 3, "a", 9) == 3;
}

test "a closure stamp is valid for the revision it was set at only" {
	const store = createExportStore();
	assert closureChangedAt(store, 1, 4) == null;
	setClosureChangedAt(store, 1, 4, 2);
	assert closureChangedAt(store, 1, 4) == 2;
	assert closureChangedAt(store, 1, 5) == null;
	setClosureChangedAt(store, 2, 5, 3);
	assert closureChangedAt(store, 1, 5) == null;
}

test "previous exports are kept by path until forgotten" {
	const store = createExportStore();
	assert previousExports(store, "/a.ms") == null;
	keepPreviousExports(store, "/a.ms", []);
	assert previousExports(store, "/a.ms") != null;
	forgetPreviousExports(store, "/a.ms");
	assert previousExports(store, "/a.ms") == null;
}

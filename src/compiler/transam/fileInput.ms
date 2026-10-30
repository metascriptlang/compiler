// Trans-Am File Input — tracks source text per file with change detection
//
// Each file gets a sequential fileId. Change detection via string equality; a real
// change records the revision of the write.
//
// Arrays passed by pointer — bare T[] types.

import { TaDurability } from "./revision";


// ===== File Entry =====

class TaFileEntry {
	filePath: string;
	source: string;
	changedAt: int32;
	fileId: int32;
	durability: TaDurability;
}

// ===== File Input Store =====

export class TaFileInputStore {
	files: TaFileEntry[];
	nextFileId: int32;
	pathIndex: HashMap<string, int32>;  // filePath → array index (O(1) lookup)
	lastChange: int32[];                // per TaDurability: revision of the last input change at or above it
}

export function createFileInputStore(): TaFileInputStore {
	return {
		files: [],
		nextFileId: 0,
		pathIndex: new HashMap<string, int32>(),
		lastChange: [0, 0, 0],
	};
}

// ===== Lookup =====

function findByPath(store: TaFileInputStore, filePath: string): int32 {
	if (store.pathIndex.has(filePath)) return store.pathIndex.get(filePath) as int32;
	return -1;
}

function findByFileId(store: TaFileInputStore, fileId: int32): int32 {
	if (fileId >= 0 && fileId < store.files.length) return fileId;
	return -1;
}

// ===== Public API =====

// Returns true if content actually changed (new file or different source)
export function setFileText(store: TaFileInputStore, filePath: string, source: string, revision: int32): boolean {
	const idx = findByPath(store, filePath);
	if (idx >= 0) {
		const file = store.files[idx];
		if (file.source == source) return false;
		file.source = source;
		file.changedAt = revision;
		moveChangeMarkers(store, file.durability, revision);
		return true;
	}
	const fileId = store.nextFileId;
	store.nextFileId = store.nextFileId + 1;
	const entry: TaFileEntry = {
		filePath,
		source,
		changedAt: revision,
		fileId,
		durability: TaDurability.Low,
	};
	store.pathIndex.set(filePath, store.files.length);
	store.files.push(entry);
	moveChangeMarkers(store, TaDurability.Low, revision);
	return true;
}

export function getFileText(store: TaFileInputStore, fileId: int32): string {
	const idx = findByFileId(store, fileId);
	if (idx < 0) return "";
	return store.files[idx].source;
}

export function getFileChangedAt(store: TaFileInputStore, fileId: int32): int32 | null {
	const idx = findByFileId(store, fileId);
	if (idx < 0) return null;
	return store.files[idx].changedAt;
}

export function getFileId(store: TaFileInputStore, filePath: string): int32 {
	const idx = findByPath(store, filePath);
	if (idx < 0) return -1;
	return store.files[idx].fileId;
}

export function hasFile(store: TaFileInputStore, filePath: string): boolean {
	return findByPath(store, filePath) >= 0;
}

// Reverse lookup: fileId → file path. Returns "" if not found.
export function getFilePath(store: TaFileInputStore, fileId: int32): string {
	const idx = findByFileId(store, fileId);
	if (idx < 0) return "";
	return store.files[idx].filePath;
}

// Count of all known files
export function getFileCount(store: TaFileInputStore): int32 {
	return store.files.length;
}

// Get file path by sequential index (0..count-1). Returns "" if out of range.
export function getFilePathByIndex(store: TaFileInputStore, index: int32): string {
	if (index < 0 || index >= store.files.length) return "";
	return store.files[index].filePath;
}

// ===== Durability =====

export function getFileDurability(store: TaFileInputStore, fileId: int32): TaDurability {
	const idx = findByFileId(store, fileId);
	if (idx < 0) return TaDurability.Low;
	return store.files[idx].durability;
}

// A write at durability D moves the marker of every durability up to D, so a High
// write also leaves Low and Medium entries unverified.
function moveChangeMarkers(store: TaFileInputStore, durability: TaDurability, revision: int32): void {
	const level = durability as int32;
	for (let d = 0; d <= level; d++) store.lastChange[d] = revision;
}

export function getLastChange(store: TaFileInputStore, dur: TaDurability): int32 {
	return store.lastChange[dur as int32];
}

// Changing a file's durability is a write at its old durability: an entry computed
// while the file was High cannot keep skipping it once the file may change as Low.
export function setFileDurability(store: TaFileInputStore, fileId: int32, dur: TaDurability, revision: int32): void {
	const idx = findByFileId(store, fileId);
	if (idx < 0 || store.files[idx].durability == dur) return;
	moveChangeMarkers(store, store.files[idx].durability, revision);
	store.files[idx].durability = dur;
}

// ===== Tests =====
test "starts empty" {
	const store = createFileInputStore();
	assert store.files.length == 0;
	assert store.nextFileId == 0;
}

test "set new file returns true" {
	const store = createFileInputStore();
	assert setFileText(store, "a.ms", "const x = 1;", 1);
}

test "set same content returns false" {
	const store = createFileInputStore();
	setFileText(store, "a.ms", "const x = 1;", 1);
	assert !setFileText(store, "a.ms", "const x = 1;", 2);
}

test "set different content returns true" {
	const store = createFileInputStore();
	setFileText(store, "a.ms", "const x = 1;", 1);
	assert setFileText(store, "a.ms", "const x = 2;", 2);
}

test "getFileId sequential" {
	const store = createFileInputStore();
	setFileText(store, "a.ms", "a", 1);
	setFileText(store, "b.ms", "b", 2);
	assert getFileId(store, "a.ms") == 0;
	assert getFileId(store, "b.ms") == 1;
}

test "getFileId unknown returns -1" {
	const store = createFileInputStore();
	assert getFileId(store, "unknown.ms") == -1;
}

test "getFileText retrieves source" {
	const store = createFileInputStore();
	setFileText(store, "a.ms", "hello world", 1);
	const id = getFileId(store, "a.ms");
	assert getFileText(store, id) == "hello world";
}

test "getFileText after update" {
	const store = createFileInputStore();
	setFileText(store, "a.ms", "v1", 1);
	const id = getFileId(store, "a.ms");
	setFileText(store, "a.ms", "v2", 2);
	assert getFileText(store, id) == "v2";
}

test "hasFile true/false" {
	const store = createFileInputStore();
	assert !hasFile(store, "a.ms");
	setFileText(store, "a.ms", "x", 1);
	assert hasFile(store, "a.ms");
}

test "getFilePath reverse lookup" {
	const store = createFileInputStore();
	setFileText(store, "/a/b.ms", "x", 1);
	const id = getFileId(store, "/a/b.ms");
	assert getFilePath(store, id) == "/a/b.ms";
	assert getFilePath(store, 999) == "";
}

test "getFileChangedAt of an unknown id is null, not the revision of an empty file" {
	const store = createFileInputStore();
	setFileText(store, "empty.ms", "", 0);
	assert getFileChangedAt(store, 0) == 0;
	assert getFileChangedAt(store, 1) == null;
	assert getFileChangedAt(store, -1) == null;
}

test "a file changes at the revision of its last real write" {
	const store = createFileInputStore();
	setFileText(store, "a.ms", "Az", 3);
	assert getFileChangedAt(store, 0) == 3;
	assert !setFileText(store, "a.ms", "Az", 4);
	assert getFileChangedAt(store, 0) == 3;
	assert setFileText(store, "a.ms", "BY", 5);
	assert getFileChangedAt(store, 0) == 5;
	assert setFileText(store, "a.ms", "Az", 6);
	assert getFileChangedAt(store, 0) == 6;
}

test "a write moves the change marker of its durability and every lower one" {
	const store = createFileInputStore();
	setFileText(store, "a.ms", "a", 2);
	assert getLastChange(store, TaDurability.Low) == 2;
	assert getLastChange(store, TaDurability.High) == 0;
	setFileDurability(store, 0, TaDurability.High, 3);
	assert getLastChange(store, TaDurability.Low) == 3;
	assert getLastChange(store, TaDurability.High) == 0;
	setFileText(store, "a.ms", "b", 4);
	assert getLastChange(store, TaDurability.Low) == 4;
	assert getLastChange(store, TaDurability.Medium) == 4;
	assert getLastChange(store, TaDurability.High) == 4;
	setFileDurability(store, 0, TaDurability.Low, 5);
	assert getLastChange(store, TaDurability.High) == 5;
}

test "a write of identical text leaves the change markers alone" {
	const store = createFileInputStore();
	setFileText(store, "a.ms", "a", 1);
	setFileDurability(store, 0, TaDurability.High, 1);
	assert !setFileText(store, "a.ms", "a", 7);
	assert getLastChange(store, TaDurability.Low) == 1;
	assert getLastChange(store, TaDurability.High) == 0;
}

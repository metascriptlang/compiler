// Trans-Am File Input — tracks source text per file with change detection
//
// Each file gets a sequential fileId. Change detection via string equality.
// Phase 2: add content hash for Salsa output-hash optimization.
//
// Arrays passed by pointer — bare T[] types.

import { taHashString } from "./hash";
import { TaDurability } from "./revision";


// ===== File Entry =====

export class TaFileEntry {
	filePath: string;
	source: string;
	sourceHash: number;
	fileId: number;
	durability: TaDurability;
}

// ===== File Input Store =====

export class TaFileInputStore {
	files: TaFileEntry[];
	nextFileId: number;
	pathIndex: Map<string, number>;  // filePath → array index (O(1) lookup)
}

export function createFileInputStore(): TaFileInputStore {
	return {
		files: [],
		nextFileId: 0,
		pathIndex: new Map<string, number>(),
	};
}

// ===== Lookup =====

function findByPath(store: TaFileInputStore, filePath: string): number {
	if (store.pathIndex.has(filePath)) return store.pathIndex.get(filePath) as number;
	return -1;
}

function findByFileId(store: TaFileInputStore, fileId: number): number {
	// fileId === array index for sequentially assigned IDs
	if (fileId >= 0 && fileId < store.files.length && store.files[fileId].fileId === fileId) return fileId;
	// Fallback linear scan for non-sequential IDs
	for (let i = 0; i < store.files.length; i = i + 1) {
		if (store.files[i].fileId === fileId) return i;
	}
	return -1;
}

// ===== Public API =====

// Returns true if content actually changed (new file or different source)
export function setFileText(store: TaFileInputStore, filePath: string, source: string): boolean {
	const idx = findByPath(store, filePath);
	if (idx >= 0) {
		// Existing file — check if content changed
		if (store.files[idx].source === source) return false;
		store.files[idx].source = source;
		store.files[idx].sourceHash = taHashString(source);
		return true;
	}
	// New file
	const fileId = store.nextFileId;
	store.nextFileId = store.nextFileId + 1;
	const entry: TaFileEntry = {
		filePath,
		source,
		sourceHash: taHashString(source),
		fileId,
		durability: TaDurability.Low,
	};
	store.pathIndex.set(filePath, store.files.length);
	store.files.push(entry);
	return true;
}

export function getFileText(store: TaFileInputStore, fileId: number): string {
	const idx = findByFileId(store, fileId);
	if (idx < 0) return "";
	return store.files[idx].source;
}

export function getFileHash(store: TaFileInputStore, fileId: number): number {
	const idx = findByFileId(store, fileId);
	if (idx < 0) return 0;
	return store.files[idx].sourceHash;
}

export function getFileId(store: TaFileInputStore, filePath: string): number {
	const idx = findByPath(store, filePath);
	if (idx < 0) return -1;
	return store.files[idx].fileId;
}

export function hasFile(store: TaFileInputStore, filePath: string): boolean {
	return findByPath(store, filePath) >= 0;
}

// Reverse lookup: fileId → file path. Returns "" if not found.
export function getFilePath(store: TaFileInputStore, fileId: number): string {
	const idx = findByFileId(store, fileId);
	if (idx < 0) return "";
	return store.files[idx].filePath;
}

// Count of all known files
export function getFileCount(store: TaFileInputStore): number {
	return store.files.length;
}

// Get file path by sequential index (0..count-1). Returns "" if out of range.
export function getFilePathByIndex(store: TaFileInputStore, index: number): string {
	if (index < 0 || index >= store.files.length) return "";
	return store.files[index].filePath;
}

// ===== Durability =====

export function getFileDurability(store: TaFileInputStore, fileId: number): TaDurability {
	const idx = findByFileId(store, fileId);
	if (idx < 0) return TaDurability.Low;
	return store.files[idx].durability;
}

export function setFileDurability(store: TaFileInputStore, fileId: number, dur: TaDurability): void {
	const idx = findByFileId(store, fileId);
	if (idx >= 0) store.files[idx].durability = dur;
}

// ===== Tests =====
test "starts empty" {
	const store = createFileInputStore();
	assert store.files.length === 0;
	assert store.nextFileId === 0;
}

test "set new file returns true" {
	const store = createFileInputStore();
	assert setFileText(store, "a.ms", "const x = 1;");
}

test "set same content returns false" {
	const store = createFileInputStore();
	setFileText(store, "a.ms", "const x = 1;");
	assert !setFileText(store, "a.ms", "const x = 1;");
}

test "set different content returns true" {
	const store = createFileInputStore();
	setFileText(store, "a.ms", "const x = 1;");
	assert setFileText(store, "a.ms", "const x = 2;");
}

test "getFileId sequential" {
	const store = createFileInputStore();
	setFileText(store, "a.ms", "a");
	setFileText(store, "b.ms", "b");
	assert getFileId(store, "a.ms") === 0;
	assert getFileId(store, "b.ms") === 1;
}

test "getFileId unknown returns -1" {
	const store = createFileInputStore();
	assert getFileId(store, "unknown.ms") === -1;
}

test "getFileText retrieves source" {
	const store = createFileInputStore();
	setFileText(store, "a.ms", "hello world");
	const id = getFileId(store, "a.ms");
	assert getFileText(store, id) === "hello world";
}

test "getFileText after update" {
	const store = createFileInputStore();
	setFileText(store, "a.ms", "v1");
	const id = getFileId(store, "a.ms");
	setFileText(store, "a.ms", "v2");
	assert getFileText(store, id) === "v2";
}

test "hasFile true/false" {
	const store = createFileInputStore();
	assert !hasFile(store, "a.ms");
	setFileText(store, "a.ms", "x");
	assert hasFile(store, "a.ms");
}

test "getFilePath reverse lookup" {
	const store = createFileInputStore();
	setFileText(store, "/a/b.ms", "x");
	const id = getFileId(store, "/a/b.ms");
	assert getFilePath(store, id) === "/a/b.ms";
	assert getFilePath(store, 999) === "";
}

test "getFileHash nonzero" {
	const store = createFileInputStore();
	setFileText(store, "a.ms", "content");
	const id = getFileId(store, "a.ms");
	assert getFileHash(store, id) !== 0;
}

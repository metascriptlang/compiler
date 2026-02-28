// Trans-Am File Input — tracks source text per file with change detection
//
// Each file gets a sequential fileId. Change detection via string equality.
// Phase 2: add content hash for Salsa output-hash optimization.
//
// DRC-safe: array wrapped in interface.

import { taHashString } from "./hash";
import { test, check, testGroup } from "std/testing";

// ===== File Entry =====

export interface TaFileEntry {
	filePath: string;
	source: string;
	sourceHash: number;
	fileId: number;
}

export interface TaFileEntryList {
	items: TaFileEntry[];
}

// ===== File Input Store =====

export interface TaFileInputStore {
	files: TaFileEntryList;
	nextFileId: number;
}

export function createFileInputStore(): TaFileInputStore {
	return {
		files: { items: [] },
		nextFileId: 0,
	};
}

// ===== Lookup =====

function findByPath(store: TaFileInputStore, filePath: string): number {
	for (let i = 0; i < store.files.items.length; i = i + 1) {
		if (store.files.items[i].filePath === filePath) return i;
	}
	return -1;
}

function findByFileId(store: TaFileInputStore, fileId: number): number {
	for (let i = 0; i < store.files.items.length; i = i + 1) {
		if (store.files.items[i].fileId === fileId) return i;
	}
	return -1;
}

// ===== Public API =====

// Returns true if content actually changed (new file or different source)
export function setFileText(store: TaFileInputStore, filePath: string, source: string): boolean {
	const idx = findByPath(store, filePath);
	if (idx >= 0) {
		// Existing file — check if content changed
		if (store.files.items[idx].source === source) return false;
		store.files.items[idx].source = source;
		store.files.items[idx].sourceHash = taHashString(source);
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
	};
	store.files.items.push(entry);
	return true;
}

export function getFileText(store: TaFileInputStore, fileId: number): string {
	const idx = findByFileId(store, fileId);
	if (idx < 0) return "";
	return store.files.items[idx].source;
}

export function getFileHash(store: TaFileInputStore, fileId: number): number {
	const idx = findByFileId(store, fileId);
	if (idx < 0) return 0;
	return store.files.items[idx].sourceHash;
}

export function getFileId(store: TaFileInputStore, filePath: string): number {
	const idx = findByPath(store, filePath);
	if (idx < 0) return -1;
	return store.files.items[idx].fileId;
}

export function hasFile(store: TaFileInputStore, filePath: string): boolean {
	return findByPath(store, filePath) >= 0;
}

// ===== Tests =====

testGroup("TaFileInputStore Basics", () => {
	test("starts empty", () => {
		const store = createFileInputStore();
		check(store.files.items.length === 0);
		check(store.nextFileId === 0);
	});
	test("set new file returns true", () => {
		const store = createFileInputStore();
		check(setFileText(store, "a.ms", "const x = 1;"));
	});
	test("set same content returns false", () => {
		const store = createFileInputStore();
		setFileText(store, "a.ms", "const x = 1;");
		check(!setFileText(store, "a.ms", "const x = 1;"));
	});
	test("set different content returns true", () => {
		const store = createFileInputStore();
		setFileText(store, "a.ms", "const x = 1;");
		check(setFileText(store, "a.ms", "const x = 2;"));
	});
});

testGroup("TaFileInputStore Lookup", () => {
	test("getFileId sequential", () => {
		const store = createFileInputStore();
		setFileText(store, "a.ms", "a");
		setFileText(store, "b.ms", "b");
		check(getFileId(store, "a.ms") === 0);
		check(getFileId(store, "b.ms") === 1);
	});
	test("getFileId unknown returns -1", () => {
		const store = createFileInputStore();
		check(getFileId(store, "unknown.ms") === -1);
	});
	test("getFileText retrieves source", () => {
		const store = createFileInputStore();
		setFileText(store, "a.ms", "hello world");
		const id = getFileId(store, "a.ms");
		check(getFileText(store, id) === "hello world");
	});
	test("getFileText after update", () => {
		const store = createFileInputStore();
		setFileText(store, "a.ms", "v1");
		const id = getFileId(store, "a.ms");
		setFileText(store, "a.ms", "v2");
		check(getFileText(store, id) === "v2");
	});
	test("hasFile true/false", () => {
		const store = createFileInputStore();
		check(!hasFile(store, "a.ms"));
		setFileText(store, "a.ms", "x");
		check(hasFile(store, "a.ms"));
	});
	test("getFileHash nonzero", () => {
		const store = createFileInputStore();
		setFileText(store, "a.ms", "content");
		const id = getFileId(store, "a.ms");
		check(getFileHash(store, id) !== 0);
	});
});

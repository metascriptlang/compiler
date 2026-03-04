// LSP Document Store — CRUD for open documents
//
// Tracks open documents by URI. Used by handlers + server.

import { check } from "std/testing";

// ===== Types =====

export interface LspDocument {
	uri: string;
	source: string;
	version: number;
}

export interface LspDocumentStore {
	documents: LspDocument[];
}

// ===== Operations =====

export function createDocumentStore(): LspDocumentStore {
	return { documents: [] };
}

export function storeDocument(store: LspDocumentStore, uri: string, source: string, version: number): void {
	for (let i = 0; i < store.documents.length; i = i + 1) {
		if (store.documents[i].uri === uri) {
			store.documents[i].source = source;
			store.documents[i].version = version;
			return;
		}
	}
	const doc: LspDocument = { uri: uri, source: source, version: version };
	store.documents.push(doc);
}

export function getDocument(store: LspDocumentStore, uri: string): LspDocument {
	for (let i = 0; i < store.documents.length; i = i + 1) {
		if (store.documents[i].uri === uri) return store.documents[i];
	}
	return null as unknown as LspDocument;
}

export function removeDocument(store: LspDocumentStore, uri: string): void {
	for (let i = 0; i < store.documents.length; i = i + 1) {
		if (store.documents[i].uri === uri) {
			for (let j = i; j + 1 < store.documents.length; j = j + 1) {
				store.documents[j] = store.documents[j + 1];
			}
			store.documents.pop();
			return;
		}
	}
}

// ===== Tests =====
test "store and get" {
	const store = createDocumentStore();
	storeDocument(store, "file:///a.ms", "const x = 1;", 1);
	const doc = getDocument(store, "file:///a.ms");
	check(doc !== null);
	check(doc.source === "const x = 1;");
	check(doc.version === 1);
}

test "update existing" {
	const store = createDocumentStore();
	storeDocument(store, "file:///a.ms", "const x = 1;", 1);
	storeDocument(store, "file:///a.ms", "const x = 2;", 2);
	check(store.documents.length === 1);
	const doc = getDocument(store, "file:///a.ms");
	check(doc.source === "const x = 2;");
	check(doc.version === 2);
}

test "remove document" {
	const store = createDocumentStore();
	storeDocument(store, "file:///a.ms", "const x = 1;", 1);
	removeDocument(store, "file:///a.ms");
	const doc = getDocument(store, "file:///a.ms");
	check(doc === null);
}

test "not found" {
	const store = createDocumentStore();
	const doc = getDocument(store, "file:///nope.ms");
	check(doc === null);
}

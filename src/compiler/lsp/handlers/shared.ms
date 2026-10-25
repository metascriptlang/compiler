// LSP Handlers — Shared state, caches, and helpers used across handler modules.
//
// Contains CompletionCache, deferred diagnostics publishing, cursor extraction,
// source text access, and import resolution.

import { TransAmDb, dbSetFileText, getFileText, getFileId } from "../../transam/index";
import { readFile } from "std/fs";
import { writeStderr } from "std/io";
import {
	lspGetField, lspGetNumberField, lspGetObjectField, lspUriToPath,
} from "../protocol";
import { lspByteColumn } from "../position";

export { lspCharacter } from "../position";


// ===== Completion Cache =====
// Caches last completion list per file for zero-lag character-by-character filtering.
// Shared with server.ms via LspServerState.

export class CompletionCache {
	uri: string;           // file URI of last completion
	line: number;          // line of last completion (1-indexed, internal)
	prefix: string;        // prefix used for last completion
	items: string[];       // cached per-item JSON strings
}

// Resolve cache: maps label to additionalTextEdits JSON for completionItem/resolve.
// nvim-cmp strips additionalTextEdits from initial response and expects them on resolve.
let _resolveCache: HashMap<string, string> = new HashMap<string, string>();

export function cacheResolveEdit(label: string, detail: string, editsJson: string): void {
	_resolveCache.set(label, editsJson);
}

export function lookupResolveEdit(label: string, detail: string): string {
	const cached = _resolveCache.get(label);
	if (cached != null) return cached;
	return "";
}

export function createCompletionCache(): CompletionCache {
	return { uri: "", line: -1, prefix: "", items: [] };
}

// Deferred diagnostics: didChange marks files as changed. Post-drain publishes diagnostics.
export struct ChangedFile {
	path: string;
	uri: string;
}

let _changedFiles: ChangedFile[] = [];
let _changedPaths: HashSet<string> = new HashSet<string>();

export function markFileChanged(path: string, uri: string): void {
	// Clear resolve cache on edit — stale textEdits from previous content
	_resolveCache = new HashMap<string, string>();
	if (_changedPaths.has(path)) return;
	_changedPaths.add(path);
	_changedFiles.push({ path, uri });
}

export function drainChangedFiles(): ChangedFile[] {
	const drained = _changedFiles;
	_changedFiles = [];
	_changedPaths = new HashSet<string>();
	return drained;
}

// ===== Shared Helpers =====

export interface LspCursorParams {
	uri: string;
	line: int32;   // 1-based (parser convention)
	col: int32;    // 0-based (for text offset scanning)
	col1: int32;   // 1-based (for AST node position matching)
}

export function lspDocumentUri(params: string): string {
	return lspGetField(lspGetObjectField(params, "textDocument"), "uri");
}

export function lspExtractPosition(params: string, db: TransAmDb | null = null): LspCursorParams {
	const uri = lspDocumentUri(params);
	const position = lspGetObjectField(params, "position");
	const line = (lspGetNumberField(position, "line") as int32) + 1;
	const character = lspGetNumberField(position, "character") as int32;
	const col1 = db != null ? lspByteColumn(dbGetSource(db, lspUriToPath(uri)), line, character) : character + 1;
	return { uri, line, col: col1 - 1, col1 };
}

// Get raw source text from Trans-Am DB for a given path.
// Used by handlers that need text scanning (completion prefix, callee detection).
export function dbGetSource(db: TransAmDb, path: string): string {
	const fileId = getFileId(db.fileInput, path);
	if (fileId < 0) return "";
	return getFileText(db.fileInput, fileId);
}

// Load a file into the TransAm DB if not already present.
export function lspReadDiskSource(filePath: string): Result<string, string> {
	const readResult = readFile(filePath);
	if (!readResult.ok) { return Result.err(filePath); }
	return Result.ok(readResult.value);
}

export function lspEnsureFileLoaded(db: TransAmDb, filePath: string): void {
	if (getFileId(db.fileInput, filePath) < 0) {
		const t0 = performance.now();
		const source = lspReadDiskSource(filePath);
		if (source.ok) {
			dbSetFileText(db, filePath, source.value);
		}
		const t1 = performance.now();
		writeStderr("[LSP] loadFile " + filePath + " " + (t1 - t0) + "ms\n");
	}
}

export function lspReloadFromDisk(db: TransAmDb, filePath: string): boolean {
	if (getFileId(db.fileInput, filePath) < 0) return false;
	const source = lspReadDiskSource(filePath);
	if (!source.ok) return dbSetFileText(db, filePath, "");
	return dbSetFileText(db, filePath, source.value);
}

// Insertion order is the order reresolveOpenDocuments publishes in; the set answers membership.
let _openDocuments: string[] = [];
let _openDocumentSet: HashSet<string> = new HashSet<string>();

export function markDocumentOpen(path: string): void {
	if (_openDocumentSet.has(path)) return;
	_openDocumentSet.add(path);
	_openDocuments.push(path);
}

export function markDocumentClosed(path: string): void {
	if (!_openDocumentSet.delete(path)) return;
	const kept: string[] = [];
	for (const open of _openDocuments) {
		if (open != path) {
			kept.push(open);
		}
	}
	_openDocuments = kept;
}

export function isDocumentOpen(path: string): boolean {
	return _openDocumentSet.has(path);
}

export function openDocuments(): string[] {
	const copy: string[] = [];
	for (const open of _openDocuments) {
		copy.push(open);
	}
	return copy;
}

let _staleDependents: string[] = [];

export function markDependentsStale(path: string): void {
	for (const stale of _staleDependents) {
		if (stale == path) return;
	}
	_staleDependents.push(path);
}

export function drainStaleDependents(): string[] {
	const drained = _staleDependents;
	_staleDependents = [];
	return drained;
}


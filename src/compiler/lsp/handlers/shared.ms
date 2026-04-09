// LSP Handlers — Shared state, caches, and helpers used across handler modules.
//
// Extracted from handlers.ms. Contains CompletionCache, deferred diagnostics
// publishing, cursor extraction, source text access, and import resolution.

import { TransAmDb, dbSetFileText, getFileText, getFileId } from "../../transam/index";
import { readFile } from "std/fs";
import { clockMs } from "std/process";
import { translateCHeader } from "../../../module/cimport/emit";
import { writeStderr } from "std/io";
import {
	lspGetField, lspGetNumberField, lspGetObjectField,
	lspResolveImportCandidates
} from "../protocol";


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
let _resolveCache: Map<string, string> = new Map<string, string>();

export function cacheResolveEdit(label: string, detail: string, editsJson: string): void {
	_resolveCache.set(label, editsJson);
}

export function lookupResolveEdit(label: string, detail: string): string {
	if (_resolveCache.has(label)) return _resolveCache.get(label);
	return "";
}

export function createCompletionCache(): CompletionCache {
	return { uri: "", line: -1, prefix: "", items: [] };
}

// Deferred diagnostics: didChange marks files as changed. Post-drain publishes diagnostics.
let _changedFiles: string[] = [];
let _changedUris: string[] = [];

export function markFileChanged(path: string, uri: string): void {
	// Clear resolve cache on edit — stale textEdits from previous content
	_resolveCache = new Map<string, string>();
	let found = false;
	for (let ci = 0; ci < _changedFiles.length; ci += 1) {
		if (_changedFiles[ci] === path) { found = true; break; }
	}
	if (!found) {
		_changedFiles.push(path);
		_changedUris.push(uri);
	}
}

export function drainChangedFiles(): string[][] {
	if (_changedFiles.length === 0) return [];
	const result: string[][] = [];
	for (let i = 0; i < _changedFiles.length; i += 1) {
		result.push([_changedFiles[i], _changedUris[i]]);
	}
	_changedFiles = [];
	_changedUris = [];
	return result;
}

// ===== Shared Helpers =====

export interface LspCursorParams {
	uri: string;
	line: number;   // 1-based (parser convention)
	col: number;    // 0-based (for text offset scanning)
	col1: number;   // 1-based (for AST node position matching)
}

export function lspExtractPosition(params: string): LspCursorParams {
	const textDoc = lspGetObjectField(params, "textDocument");
	const uri = lspGetField(textDoc, "uri");
	const position = lspGetObjectField(params, "position");
	const col0 = lspGetNumberField(position, "character");
	return { uri, line: lspGetNumberField(position, "line") + 1, col: col0, col1: col0 + 1 };
}

// Simple linear search for dedup (O(n^2) acceptable for typical reference counts).
// Get raw source text from Trans-Am DB for a given path.
// Used by handlers that need text scanning (completion prefix, callee detection).
export function dbGetSource(db: TransAmDb, path: string): string {
	const fileId = getFileId(db.fileInput, path);
	if (fileId < 0) return "";
	return getFileText(db.fileInput, fileId);
}

// Load a file into the TransAm DB if not already present.
export function lspEnsureFileLoaded(db: TransAmDb, filePath: string): void {
	if (getFileId(db.fileInput, filePath) < 0) {
		const t0 = clockMs();
		const readResult = readFile(filePath);
		if (readResult.ok) {
			let source = readResult.value;
			if (filePath.length >= 2 && filePath.slice(filePath.length - 2, filePath.length) === ".h") {
				source = translateCHeader(source, []);
			}
			dbSetFileText(db, filePath, source);
		}
		const t1 = clockMs();
		writeStderr("[LSP] loadFile " + filePath + " " + (t1 - t0) + "ms\n");
	}
}

// Resolve import specifier to absolute path. Handles relative (./foo) and std/ imports.
// For std/ imports, tries candidates in order: .ms, .cms, /index.ms, /index.cms.
// Loads from disk if not already in the db.
export function resolveImportForLsp(db: TransAmDb, basePath: string, importSpec: string): string {
	// Relative imports — try candidates (.ms, /index.ms, .cms, /index.cms)
	const relCandidates = lspResolveImportCandidates(basePath, importSpec);
	for (const c of relCandidates) {
		if (getFileId(db.fileInput, c) >= 0) return c;
	}
	for (const c of relCandidates) {
		lspEnsureFileLoaded(db, c);
		if (getFileId(db.fileInput, c) >= 0) return c;
	}

	// std/ imports — resolve against db.stdPath
	if (db.stdPath.length > 0 && importSpec.length > 4 && importSpec.slice(0, 4) === "std/") {
		const rest = importSpec.slice(4, importSpec.length);
		const base = db.stdPath + "/" + rest;
		// Try candidates: check db first (no disk I/O), then load from disk.
		const candidates: string[] = [];
		candidates.push(base + ".ms");
		candidates.push(base + ".cms");
		candidates.push(base + "/index.ms");
		candidates.push(base + "/index.cms");
		// Fast path: check if already loaded in db (no disk I/O)
		for (const c of candidates) {
			if (getFileId(db.fileInput, c) >= 0) return c;
		}
		// Slow path: try loading from disk
		for (const c of candidates) {
			lspEnsureFileLoaded(db, c);
			if (getFileId(db.fileInput, c) >= 0) return c;
		}
	}

	return "";
}

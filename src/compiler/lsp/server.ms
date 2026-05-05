// LSP Server — Main loop with request queue, state management
//
// Reads JSON-RPC from stdin, drains buffered messages, coalesces
// auto-fired requests, dispatches to handlers, writes responses.
// I/O uses writeStderr for logging. Actual stdin/stdout I/O
// requires ms_stdio.h (readLine, readBytes, writeStdout).

import {
	lspParseContentLength, lspFormatMessage, lspUriToPath,
	lspGetField, lspGetNumberField, lspGetObjectField, lspJsonNumber, lspJsonString,
	lspErrorResponse
} from "./protocol";
import { TransAmDb, createTransAmDb, dbEnsurePrelude, dbSetStdPath } from "../transam/index";
import { readLockfile, entryName } from "../package/lockfile";
import { registrySrcPath, gitSrcPath } from "../package/cache";
import { findProjectRoot } from "../../utils/path";
import { exists } from "std/fs";
import { join } from "std/fs/path";
import { resetCancel } from "../transam/cancel";
import { CompletionCache, createCompletionCache } from "./handlers/shared";
import { buildTransitiveDiagnosticsWire } from "./handlers/diagnostics";

// Set up package aliases on the db's resolverConfig from the project's lockfile.
// Uses findProjectRoot (walks up from filePath looking for build.ms).
function setupPackageAliases(db: TransAmDb, filePath: string): void {
	if (db.resolverConfig.aliasKeys.length > 0) return;
	const projectRoot = findProjectRoot(filePath);
	const lockPath = join(projectRoot, "msc.lock");
	if (!exists(lockPath)) return;
	const lock = readLockfile(lockPath);
	if (!lock.valid) return;
	for (const entry of lock.entries) {
		const name = entryName(entry.key);
		let srcPath = "";
		if (entry.source === "git" && entry.url !== "" && entry.commit !== "") {
			srcPath = gitSrcPath(entry.url, entry.commit);
		} else if (entry.version !== "") {
			srcPath = registrySrcPath(name, entry.version);
		}
		if (srcPath !== "") {
			db.resolverConfig.aliasKeys.push(name);
			db.resolverConfig.aliasValues.push(srcPath);
		}
	}
}

import { lspDispatch, publishPendingDiagnostics } from "./handlers/lifecycle";
import { readLine, readBytes, writeStdout, writeStderr, stdinHasData, stdinDisableBuffering } from "std/io";
import { resolveRuntimeDir } from "../../utils/path";


// ===== Server State =====

export class LspServerState {
	initialized: boolean;
	shutdownRequested: boolean;
	db: TransAmDb;
	completionCache: CompletionCache;
}

export function createServerState(): LspServerState {
	return {
		initialized: false,
		shutdownRequested: false,
		db: createTransAmDb(512),
		completionCache: createCompletionCache(),
	};
}

// ===== Logging =====

function lspLog(msg: string): void {
	writeStderr("[LSP] " + msg + "\n");
}

// ===== Message Queue =====

interface QueuedMessage {
	body: string;
	method: string;
	fileUri: string;
}

function extractFileUri(params: string): string {
	if (params.length === 0) return "";
	const textDoc = lspGetObjectField(params, "textDocument");
	if (textDoc.length === 0) return "";
	return lspGetField(textDoc, "uri");
}

function parseQueuedMessage(body: string): QueuedMessage {
	const method = lspGetField(body, "method");
	const params = lspGetObjectField(body, "params");
	return { body, method, fileUri: extractFileUri(params) };
}

// Auto-fired methods that can be safely deduplicated per-file.
// For each (method, fileUri) pair, keep only the last occurrence.
function isAutoFired(method: string): boolean {
	return method === "textDocument/inlayHint"
		|| method === "textDocument/semanticTokens/full"
		|| method === "textDocument/documentHighlight";
}

// Coalesce queue: dedup auto-fired requests per (method, fileUri).
// Preserves ordering. Never discards lifecycle or content-sync messages.
function coalesceQueue(queue: QueuedMessage[]): QueuedMessage[] {
	if (queue.length <= 1) return queue;
	// Mark earlier duplicates of auto-fired requests for removal.
	// Walk backwards — the last occurrence wins.
	const keep: boolean[] = [];
	let i = 0;
	while (i < queue.length) {
		keep.push(true);
		i = i + 1;
	}
	i = 0;
	while (i < queue.length) {
		const qm = queue[i];
		if (isAutoFired(qm.method) && qm.fileUri.length > 0) {
			// Check if a later entry has same method + fileUri
			let j = i + 1;
			while (j < queue.length) {
				if (queue[j].method === qm.method && queue[j].fileUri === qm.fileUri) {
					keep[i] = false;
					break;
				}
				j = j + 1;
			}
		}
		i = i + 1;
	}
	// Also dedup didChange: for same file, keep only the last
	i = 0;
	while (i < queue.length) {
		const qm = queue[i];
		if (qm.method === "textDocument/didChange" && qm.fileUri.length > 0) {
			let j = i + 1;
			while (j < queue.length) {
				if (queue[j].method === "textDocument/didChange" && queue[j].fileUri === qm.fileUri) {
					keep[i] = false;
					break;
				}
				j = j + 1;
			}
		}
		i = i + 1;
	}
	const result: QueuedMessage[] = [];
	i = 0;
	while (i < queue.length) {
		if (keep[i]) result.push(queue[i]);
		i = i + 1;
	}
	return result;
}

// Check if a request is superseded by a later didChange for the same file.
function isSuperseded(qm: QueuedMessage, queue: QueuedMessage[], fromIdx: number): boolean {
	if (qm.fileUri.length === 0) return false;
	let j = fromIdx;
	while (j < queue.length) {
		if (queue[j].method === "textDocument/didChange" && queue[j].fileUri === qm.fileUri) {
			return true;
		}
		j = j + 1;
	}
	return false;
}

// ===== Message Reading =====

function readOneMessage(): string {
	// Read headers until we find Content-Length (may not be the first header)
	let contentLength = -1;
	while (contentLength < 0) {
		const line = readLine();
		if (line.length === 0) return "";  // EOF or end-of-headers without Content-Length
		contentLength = lspParseContentLength(line);
	}
	// Skip remaining headers until empty line
	let sep = readLine();
	while (sep.length > 0) { sep = readLine(); }
	return readBytes(contentLength);
}

// ===== Main Loop =====

export function lspRunServer(): void {
	stdinDisableBuffering();  // Ensure select() sees all buffered data
	const state = createServerState();
	lspLog("MetaScript LSP server starting");

	while (!state.shutdownRequested) {
		// 1. Read first message (blocking wait)
		const first = readOneMessage();
		if (first.length === 0) break;

		// 2. Drain all buffered messages (non-blocking)
		const queue: QueuedMessage[] = [];
		queue.push(parseQueuedMessage(first));
		while (stdinHasData()) {
			const next = readOneMessage();
			if (next.length === 0) break;
			queue.push(parseQueuedMessage(next));
		}

		// 3. Coalesce: dedup auto-fired + didChange per file
		const coalesced = coalesceQueue(queue);

		if (queue.length > 1) {
			lspLog("queue: " + queue.length + " drained, " + coalesced.length + " after coalesce");
		}

		// 4. Process in order
		let qi = 0;
		while (qi < coalesced.length) {
			const qm = coalesced[qi];
			// Skip requests superseded by a later didChange for the same file
			if (isAutoFired(qm.method) && isSuperseded(qm, coalesced, qi + 1)) {
				qi = qi + 1;
				continue;
			}
			try {
				const response = processMessage(qm.body, state);
				if (response.length > 0) {
					if (response.length > 5000) {
						writeStderr(`[LSP] sending response len=${response.length} method=${qm.method}\n`);
					}
					writeStdout(response);
				}
			} catch (e) {
				lspLog("Handler error: " + e);
			}
			qi = qi + 1;
		}

		// 5. Post-drain: publish diagnostics for the last changed file.
		// Only the FINAL content state gets type-checked — intermediate keystrokes skipped.
		const pendingDiag = publishPendingDiagnostics(state.db);
		if (pendingDiag.length > 0) {
			writeStdout(pendingDiag);
		}
	}

	lspLog("MetaScript LSP server exiting");
}

// ===== Message Processing =====

// Process a single JSON-RPC message. Returns wire-formatted response(s)
// (Content-Length + JSON), or "" if no response needed.
// For didChange, appends transitive diagnostics notifications.
export function processMessage(msg: string, state: LspServerState): string {
	const method = lspGetField(msg, "method");
	const idNum = lspGetNumberField(msg, "id");
	// LSP spec allows `id` to be int OR string — VSCode/Neovim/Zed send int,
	// IntelliJ (LSP4IJ) sends string. Fall back to string lookup when no int.
	const idAsStr = idNum >= 0 ? "" : lspGetField(msg, "id");
	const idStr = idNum >= 0 ? lspJsonNumber(idNum) : (idAsStr !== "" ? lspJsonString(idAsStr) : "");
	const params = lspGetObjectField(msg, "params");

	// Track lifecycle
	if (method === "initialize") {
		state.initialized = true;
		const root = resolveRuntimeDir();
		if (root.length > 0) {
			dbSetStdPath(state.db, root + "/std");
		}
		dbEnsurePrelude(state.db);
	}
	if (method === "shutdown") {
		state.shutdownRequested = true;
	}

	// Invalidate completion cache when new content arrives
	if (method === "textDocument/didChange" || method === "textDocument/didOpen") {
		state.completionCache.uri = "";
		state.completionCache.line = -1;
	}

	// Set up package aliases BEFORE dispatch (so imports resolve during parse/check)
	if (method === "textDocument/didOpen") {
		const textDoc = lspGetObjectField(params, "textDocument");
		const openUri = lspGetField(textDoc, "uri");
		const openPath = lspUriToPath(openUri);
		setupPackageAliases(state.db, openPath);
	}

	// Log all requests for debugging
	if (method === "textDocument/completion") {
		writeStderr("[LSP] >>> " + method + " id=" + idStr + "\n");
	}
	const _isCompletion = method === "textDocument/completion";
	// Dispatch with error recovery
	let json = "";
	const t0 = performance.now();
	try {
		json = lspDispatch(method, idStr, params, state.db, state.completionCache);
	} catch (e) {
		const errMsg = e !== null ? "" + e : "unknown error";
		writeStderr("LSP handler crash: " + method + " — " + errMsg + "\n");
		if (idStr !== "") {
			json = lspErrorResponse(idStr, -32603, "internal error: " + errMsg);
		}
	}
	const t1 = performance.now();

	resetCancel(state.db.cancelCtx);

	if (json === "") {
		const notifMs = t1 - t0;
		if (notifMs > 50) {
			writeStderr("[LSP] " + method + " (notif) " + notifMs + "ms\n");
		}
		return "";
	}

	if (_isCompletion) {
		const elapsed = t1 - t0;
		writeStderr("[LSP] <<< completion id=" + idStr + " " + elapsed + "ms len=" + json.length + "\n");
	}
	let result = lspFormatMessage(json);

	// Append transitive diagnostics on didOpen (didChange handled in post-drain).
	if (method === "textDocument/didOpen") {
		const textDoc = lspGetObjectField(params, "textDocument");
		const uri = lspGetField(textDoc, "uri");
		const path = lspUriToPath(uri);
		result = result + buildTransitiveDiagnosticsWire(state.db, path);
	}

	const elapsed = t1 - t0;
	if (elapsed > 50) {
		writeStderr("[LSP] " + method + " id=" + idStr + " " + elapsed + "ms\n");
	}

	return result;
}

// ===== Tests =====
test "create state" {
	const state = createServerState();
	assert !state.initialized;
	assert !state.shutdownRequested;
}

test "initialize sets flag" {
	const state = createServerState();
	const initMsg = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}";
	const response = processMessage(initMsg, state);
	assert state.initialized;
	assert response.length > 0;
	assert lspParseContentLength(lspGetField(response, "")) >= 0 || response.length > 20;
}

test "shutdown sets flag" {
	const state = createServerState();
	const shutdownMsg = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"shutdown\",\"params\":{}}";
	processMessage(shutdownMsg, state);
	assert state.shutdownRequested;
}

test "hover on unknown uri returns wire response" {
	const state = createServerState();
	const hoverMsg = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":0}}}";
	const response = processMessage(hoverMsg, state);
	assert response.length > 0;
}

test "unknown notification returns empty" {
	const state = createServerState();
	const notif = "{\"jsonrpc\":\"2.0\",\"method\":\"$/setTrace\",\"params\":{\"value\":\"off\"}}";
	const response = processMessage(notif, state);
	assert response === "";
}

test "content length parsing" {
	assert lspParseContentLength("Content-Length: 52") === 52;
	assert lspParseContentLength("Content-Length: 0") === 0;
	assert lspParseContentLength("Content-Type: text") === -1;
}

test "coalesce empty queue" {
	const q: QueuedMessage[] = [];
	const r = coalesceQueue(q);
	assert r.length === 0;
}

test "coalesce single message" {
	const q: QueuedMessage[] = [];
	q.push({ body: "", method: "textDocument/hover", fileUri: "file:///a.ms" });
	const r = coalesceQueue(q);
	assert r.length === 1;
}

test "coalesce deduplicates auto-fired same file" {
	const q: QueuedMessage[] = [];
	q.push({ body: "1", method: "textDocument/inlayHint", fileUri: "file:///a.ms" });
	q.push({ body: "2", method: "textDocument/hover", fileUri: "file:///a.ms" });
	q.push({ body: "3", method: "textDocument/inlayHint", fileUri: "file:///a.ms" });
	const r = coalesceQueue(q);
	// First inlayHint deduped, hover kept, second inlayHint kept
	assert r.length === 2;
	assert r[0].body === "2";
	assert r[1].body === "3";
}

test "coalesce keeps different files" {
	const q: QueuedMessage[] = [];
	q.push({ body: "1", method: "textDocument/inlayHint", fileUri: "file:///a.ms" });
	q.push({ body: "2", method: "textDocument/inlayHint", fileUri: "file:///b.ms" });
	const r = coalesceQueue(q);
	assert r.length === 2;
}

test "coalesce deduplicates didChange same file" {
	const q: QueuedMessage[] = [];
	q.push({ body: "1", method: "textDocument/didChange", fileUri: "file:///a.ms" });
	q.push({ body: "2", method: "textDocument/didChange", fileUri: "file:///a.ms" });
	const r = coalesceQueue(q);
	assert r.length === 1;
	assert r[0].body === "2";
}

test "isSuperseded by later didChange" {
	const q: QueuedMessage[] = [];
	q.push({ body: "1", method: "textDocument/inlayHint", fileUri: "file:///a.ms" });
	q.push({ body: "2", method: "textDocument/didChange", fileUri: "file:///a.ms" });
	assert isSuperseded(q[0], q, 1);
	assert !isSuperseded(q[1], q, 2);
}

test "isSuperseded not by different file" {
	const q: QueuedMessage[] = [];
	q.push({ body: "1", method: "textDocument/inlayHint", fileUri: "file:///a.ms" });
	q.push({ body: "2", method: "textDocument/didChange", fileUri: "file:///b.ms" });
	assert !isSuperseded(q[0], q, 1);
}

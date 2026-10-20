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
		if (entry.source == "git" && entry.url != "" && entry.commit != "") {
			srcPath = gitSrcPath(entry.url, entry.commit);
		} else if (entry.version != "") {
			srcPath = registrySrcPath(name, entry.version);
		}
		if (srcPath != "") {
			db.resolverConfig.aliasKeys.push(name);
			db.resolverConfig.aliasValues.push(srcPath);
		}
	}
}

import {
	lspDispatch, publishPendingDiagnostics,
	clientSupportsWatchedFileRegistration, watchedFilesRegistration,
} from "./handlers/lifecycle";
import { writeStderr, stdinDisableBuffering } from "std/io";
import {
	LspTransport, MemoryWire, FrameEnd, lspReadFrame, stdioTransport, memoryTransport, createMemoryWire, lspSplitFrames,
} from "./transport";
import { parseJson } from "std/serialize/json/parser";
import { JsonKind, JsonValue } from "std/serialize/json/types";
import { getDynamicField, asString, asInt32, asBoolean } from "std/serialize/json/accessors";
import { resolveRuntimeDir } from "../../utils/path";


// ===== Server State =====

export class LspServerState {
	initialized: boolean;
	shutdownRequested: boolean;
	watchFilesThroughClient: boolean;
	db: TransAmDb;
	completionCache: CompletionCache;
}

export function createServerState(): LspServerState {
	return {
		initialized: false,
		shutdownRequested: false,
		watchFilesThroughClient: false,
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
	if (params.length == 0) return "";
	const textDoc = lspGetObjectField(params, "textDocument");
	if (textDoc.length == 0) return "";
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
	return method == "textDocument/inlayHint"
		|| method == "textDocument/semanticTokens/full"
		|| method == "textDocument/documentHighlight";
}

// Coalesce queue: dedup auto-fired requests per (method, fileUri).
// Preserves ordering. Never discards lifecycle or content-sync messages.
function coalesceKeep(queue: QueuedMessage[]): boolean[] {
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
				if (queue[j].method == qm.method && queue[j].fileUri == qm.fileUri) {
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
		if (qm.method == "textDocument/didChange" && qm.fileUri.length > 0) {
			let j = i + 1;
			while (j < queue.length) {
				if (queue[j].fileUri == qm.fileUri) {
					if (queue[j].method == "textDocument/didChange") keep[i] = false;
					if (!isAutoFired(queue[j].method)) break;
				}
				j = j + 1;
			}
		}
		i = i + 1;
	}
	return keep;
}

function coalesceQueue(queue: QueuedMessage[]): QueuedMessage[] {
	const keep = coalesceKeep(queue);
	const result: QueuedMessage[] = [];
	let i = 0;
	while (i < queue.length) {
		if (keep[i]) result.push(queue[i]);
		i = i + 1;
	}
	return result;
}

const REQUEST_CANCELLED: number = -32800;
const CONTENT_MODIFIED: number = -32801;
const INVALID_REQUEST: number = -32600;

function answerContentModified(io: LspTransport, qm: QueuedMessage): void {
	const id = lspMessageId(qm.body);
	if (id != "") io.write(lspFormatMessage(lspErrorResponse(id, CONTENT_MODIFIED, "ContentModified")));
}

function isCancelled(id: string, queue: QueuedMessage[], fromIdx: number): boolean {
	for (let j = fromIdx; j < queue.length; j += 1) {
		if (queue[j].method == "$/cancelRequest"
			&& lspMessageId(lspGetObjectField(queue[j].body, "params")) == id) {
			return true;
		}
	}
	return false;
}

// Check if a request is superseded by a later didChange for the same file.
function isSuperseded(qm: QueuedMessage, queue: QueuedMessage[], fromIdx: number): boolean {
	if (qm.fileUri.length == 0) return false;
	let j = fromIdx;
	while (j < queue.length) {
		if (queue[j].method == "textDocument/didChange" && queue[j].fileUri == qm.fileUri) {
			return true;
		}
		j = j + 1;
	}
	return false;
}

// ===== Main Loop =====

export function lspRunServer(): void {
	stdinDisableBuffering();  // Ensure select() sees all buffered data
	lspLog("MetaScript LSP server starting");
	const exitCode = lspServe(stdioTransport());
	lspLog("MetaScript LSP server exiting");
	if (exitCode != 0) process.exit(exitCode);
}

function streamExitCode(end: FrameEnd): int32 {
	return end == FrameEnd.Truncated ? 1 : 0;
}

export function lspServe(io: LspTransport): int32 {
	const state = createServerState();
	while (true) {
		// 1. Read first message (blocking wait)
		const first = lspReadFrame(io);
		if (!first.ok) return streamExitCode(first.error);

		// 2. Drain all buffered messages (non-blocking)
		const queue: QueuedMessage[] = [];
		queue.push(parseQueuedMessage(first.value));
		let streamOpen = true;
		let streamEnd = FrameEnd.Closed;
		while (streamOpen && io.hasBufferedData()) {
			const next = lspReadFrame(io);
			if (next.ok) {
				queue.push(parseQueuedMessage(next.value));
			} else {
				streamOpen = false;
				streamEnd = next.error;
			}
		}

		// 3. Coalesce: dedup auto-fired + didChange per file
		const keep = coalesceKeep(queue);
		const coalesced: QueuedMessage[] = [];
		for (let k = 0; k < queue.length; k += 1) {
			if (keep[k]) coalesced.push(queue[k]);
			else answerContentModified(io, queue[k]);
		}

		if (queue.length > 1) {
			lspLog("queue: " + queue.length + " drained, " + coalesced.length + " after coalesce");
		}

		// 4. Process in order
		for (let qi = 0; qi < coalesced.length; qi += 1) {
			const qm = coalesced[qi];
			// Skip requests superseded by a later didChange for the same file
			if (isAutoFired(qm.method) && isSuperseded(qm, coalesced, qi + 1)) {
				answerContentModified(io, qm);
				continue;
			}
			if (qm.method == "exit") return state.shutdownRequested ? 0 : 1;
			const id = qm.method == "$/cancelRequest" ? "" : lspMessageId(qm.body);
			if (id != "" && isCancelled(id, coalesced, qi + 1)) {
				io.write(lspFormatMessage(lspErrorResponse(id, REQUEST_CANCELLED, "RequestCancelled")));
				continue;
			}
			try {
				const response = processMessage(qm.body, state);
				if (response.length > 0) {
					if (response.length > 5000) {
						writeStderr(`[LSP] sending response len=${response.length} method=${qm.method}\n`);
					}
					io.write(response);
				}
			} catch (e) {
				lspLog("Handler error: " + e);
			}
		}

		// 5. Post-drain: publish diagnostics for the last changed file.
		// Only the FINAL content state gets type-checked — intermediate keystrokes skipped.
		const pendingDiag = publishPendingDiagnostics(state.db);
		if (pendingDiag.length > 0) {
			io.write(pendingDiag);
		}
		if (!streamOpen) return streamExitCode(streamEnd);
	}
	return 0;
}

// ===== Message Processing =====

function lspMessageId(msg: string): string {
	const idNum = lspGetNumberField(msg, "id");
	if (idNum >= 0) return lspJsonNumber(idNum);
	const idText = lspGetField(msg, "id");
	return idText != "" ? lspJsonString(idText) : "";
}

// Process a single JSON-RPC message. Returns wire-formatted response(s)
// (Content-Length + JSON), or "" if no response needed.
// For didChange, appends transitive diagnostics notifications.
export function processMessage(msg: string, state: LspServerState): string {
	const method = lspGetField(msg, "method");
	const idStr = lspMessageId(msg);
	const params = lspGetObjectField(msg, "params");

	if (state.shutdownRequested) {
		return idStr == "" ? "" : lspFormatMessage(lspErrorResponse(idStr, INVALID_REQUEST, "InvalidRequest: server is shutting down"));
	}

	// Track lifecycle
	if (method == "initialize") {
		state.initialized = true;
		state.watchFilesThroughClient = clientSupportsWatchedFileRegistration(params);
		const root = resolveRuntimeDir();
		if (root.length > 0) {
			dbSetStdPath(state.db, root + "/std");
		}
		dbEnsurePrelude(state.db);
	}
	if (method == "shutdown") {
		state.shutdownRequested = true;
	}
	if (method == "initialized") {
		return state.watchFilesThroughClient ? lspFormatMessage(watchedFilesRegistration()) : "";
	}

	// Invalidate completion cache when new content arrives
	if (method == "textDocument/didChange" || method == "textDocument/didOpen") {
		state.completionCache.uri = "";
		state.completionCache.line = -1;
	}

	// Set up package aliases BEFORE dispatch (so imports resolve during parse/check)
	if (method == "textDocument/didOpen") {
		const textDoc = lspGetObjectField(params, "textDocument");
		const openUri = lspGetField(textDoc, "uri");
		const openPath = lspUriToPath(openUri);
		setupPackageAliases(state.db, openPath);
	}

	// Log all requests for debugging
	if (method == "textDocument/completion") {
		writeStderr("[LSP] >>> " + method + " id=" + idStr + "\n");
	}
	const _isCompletion = method == "textDocument/completion";
	// Dispatch with error recovery
	let json = "";
	const t0 = performance.now();
	try {
		json = lspDispatch(method, idStr, params, state.db, state.completionCache);
	} catch (e) {
		const errMsg = e != null ? "" + e : "unknown error";
		writeStderr("LSP handler crash: " + method + " — " + errMsg + "\n");
		if (idStr != "") {
			json = lspErrorResponse(idStr, -32603, "internal error: " + errMsg);
		}
	}
	const t1 = performance.now();

	resetCancel(state.db.cancelCtx);

	if (json == "") {
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
	if (method == "textDocument/didOpen") {
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
	assert response == "";
}

test "content length parsing" {
	assert lspParseContentLength("Content-Length: 52") == 52;
	assert lspParseContentLength("Content-Length: 0") == 0;
	assert lspParseContentLength("Content-Type: text") == -1;
}

test "coalesce empty queue" {
	const q: QueuedMessage[] = [];
	const r = coalesceQueue(q);
	assert r.length == 0;
}

test "coalesce single message" {
	const q: QueuedMessage[] = [];
	q.push({ body: "", method: "textDocument/hover", fileUri: "file:///a.ms" });
	const r = coalesceQueue(q);
	assert r.length == 1;
}

test "coalesce deduplicates auto-fired same file" {
	const q: QueuedMessage[] = [];
	q.push({ body: "1", method: "textDocument/inlayHint", fileUri: "file:///a.ms" });
	q.push({ body: "2", method: "textDocument/hover", fileUri: "file:///a.ms" });
	q.push({ body: "3", method: "textDocument/inlayHint", fileUri: "file:///a.ms" });
	const r = coalesceQueue(q);
	// First inlayHint deduped, hover kept, second inlayHint kept
	assert r.length == 2;
	assert r[0].body == "2";
	assert r[1].body == "3";
}

test "coalesce keeps different files" {
	const q: QueuedMessage[] = [];
	q.push({ body: "1", method: "textDocument/inlayHint", fileUri: "file:///a.ms" });
	q.push({ body: "2", method: "textDocument/inlayHint", fileUri: "file:///b.ms" });
	const r = coalesceQueue(q);
	assert r.length == 2;
}

test "coalesce deduplicates didChange same file" {
	const q: QueuedMessage[] = [];
	q.push({ body: "1", method: "textDocument/didChange", fileUri: "file:///a.ms" });
	q.push({ body: "2", method: "textDocument/didChange", fileUri: "file:///a.ms" });
	const r = coalesceQueue(q);
	assert r.length == 1;
	assert r[0].body == "2";
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

// ===== Wire-level completion =====
// These drive the SAME path an editor does — processMessage over JSON-RPC —
// not just the handler. The bug074 segfault lived in dispatch-and-below and was
// invisible to handler fixtures: a completion in a file holding `let v: uin`
// (no initializer) killed the process, so the editor saw a dead server rather
// than a bad response. Pre-fix these tests take the runner down with them.

const KW_WIRE_URI = "file:///lspkw.ms";
const KW_WIRE_TEXT = "conv\\nlet v: uin\\n";

function kwWireState(): LspServerState {
	const state = createServerState();
	processMessage("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}", state);
	processMessage("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"" + KW_WIRE_URI + "\",\"languageId\":\"metascript\",\"version\":1,\"text\":\"" + KW_WIRE_TEXT + "\"}}}", state);
	return state;
}

function kwWireCompletion(state: LspServerState, id: string, line: number, col: number): string {
	const msg = "{\"jsonrpc\":\"2.0\",\"id\":" + id + ",\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"" + KW_WIRE_URI + "\"},\"position\":{\"line\":" + line.toString() + ",\"character\":" + col.toString() + "}}}";
	return processMessage(msg, state);
}

test "wire completion: statement position offers keywords" {
	const response = kwWireCompletion(kwWireState(), "2", 0, 4);
	assert response.indexOf("\"label\":\"converter\"", 0) >= 0;
}

test "wire completion: annotation position offers type keywords only" {
	const response = kwWireCompletion(kwWireState(), "2", 1, 10);
	assert response.indexOf("\"label\":\"uint32\"", 0) >= 0;
	assert response.indexOf("\"label\":\"function\"", 0) < 0;
}

test "wire completion: response is a framed message carrying its id" {
	const response = kwWireCompletion(kwWireState(), "7", 0, 4);
	assert response.indexOf("Content-Length:", 0) == 0;
	assert response.indexOf("\"id\":7", 0) > 0;
}

test "wire completion: the server survives a file with an absent child slot" {
	const state = kwWireState();
	const first = kwWireCompletion(state, "2", 0, 4);
	assert first.length > 0;
	const second = kwWireCompletion(state, "3", 1, 10);
	assert second.indexOf("\"id\":3", 0) > 0;
	const hover = processMessage("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"" + KW_WIRE_URI + "\"},\"position\":{\"line\":0,\"character\":1}}}", state);
	assert hover.length > 0;
}

// ===== Framed replay through lspServe =====

class LspReplay {
	wire: MemoryWire;
	messages: JsonValue[];
	exitCode: int32;
}

function replay(drains: string[]): LspReplay {
	const wire = createMemoryWire(drains);
	const exitCode = lspServe(memoryTransport(wire));
	const messages: JsonValue[] = [];
	for (const body of lspSplitFrames(wire.output)) {
		const parsed = parseJson(body);
		if (!parsed.ok) throw new Error("server frame is not JSON: " + body);
		messages.push(parsed.value);
	}
	return { wire, messages, exitCode };
}

function frames(bodies: string[]): string {
	let chunk = "";
	for (const body of bodies) chunk = chunk + lspFormatMessage(body);
	return chunk;
}

function request(idJson: string, method: string, params: string): string {
	return `{"jsonrpc":"2.0","id":${idJson},"method":${lspJsonString(method)},"params":${params}}`;
}

function notification(method: string, params: string): string {
	return `{"jsonrpc":"2.0","method":${lspJsonString(method)},"params":${params}}`;
}

function initializeChunk(): string {
	return frames([request("1", "initialize", "{}"), notification("initialized", "{}")]);
}

function openParams(uri: string, text: string): string {
	return `{"textDocument":{"uri":${lspJsonString(uri)},"languageId":"metascript","version":1,"text":${lspJsonString(text)}}}`;
}

function changeParams(uri: string, version: int32, text: string): string {
	return `{"textDocument":{"uri":${lspJsonString(uri)},"version":${version}},"contentChanges":[{"text":${lspJsonString(text)}}]}`;
}

function positionParams(uri: string, line: int32, character: int32): string {
	return `{"textDocument":{"uri":${lspJsonString(uri)}},"position":{"line":${line},"character":${character}}}`;
}

function idKey(id: JsonValue): string {
	return match (id.kind) {
		JsonKind.Int => "n:" + id.intVal,
		JsonKind.String => "s:" + id.strVal,
		_ => "",
	};
}

function answersTo(r: LspReplay, key: string): JsonValue[] {
	const found: JsonValue[] = [];
	for (const m of r.messages) {
		if (idKey(m.getDynamicField("id")) == key) found.push(m);
	}
	return found;
}

function onlyAnswer(r: LspReplay, key: string): JsonValue {
	const found = answersTo(r, key);
	if (found.length != 1) throw new Error("expected one answer to " + key + ", got " + found.length);
	return found[0];
}

function published(r: LspReplay, uri: string): JsonValue[][] {
	const found: JsonValue[][] = [];
	for (const m of r.messages) {
		if (m.getDynamicField("method").asString() == "textDocument/publishDiagnostics"
			&& m.getDynamicField("params").getDynamicField("uri").asString() == uri) {
			const diagnostics = m.getDynamicField("params").getDynamicField("diagnostics");
			if (diagnostics.kind != JsonKind.Array) throw new Error("diagnostics is not an array for " + uri);
			found.push(diagnostics.items);
		}
	}
	return found;
}

function hasKey(m: JsonValue, key: string): boolean {
	return m.kind == JsonKind.Object && m.keys.indexOf(key) >= 0;
}

function spanOf(diagnostic: JsonValue): string {
	const range = diagnostic.getDynamicField("range");
	const start = range.getDynamicField("start");
	const end = range.getDynamicField("end");
	return start.getDynamicField("line").asInt32(-1) + ":" + start.getDynamicField("character").asInt32(-1)
		+ "-" + end.getDynamicField("line").asInt32(-1) + ":" + end.getDynamicField("character").asInt32(-1);
}

function definitionSpan(answer: JsonValue): string {
	const result = answer.getDynamicField("result");
	if (result.kind != JsonKind.Array || result.items.length != 1) return "no location";
	return spanOf(result.items[0]);
}

const BAD_VALUE = "export const value: int32 = \"wrong\";";
const GOOD_VALUE = "export const value: int32 = 42;";
const NOT_ASSIGNABLE = "Type 'string' is not assignable to type 'int32'";

test "replay: initialize, open with an error, then a fix clears it" {
	const uri = "file:///lspwire/open.ms";
	const r = replay([
		initializeChunk(),
		frames([notification("textDocument/didOpen", openParams(uri, BAD_VALUE))]),
		frames([notification("textDocument/didChange", changeParams(uri, 2, GOOD_VALUE))]),
	]);
	assert r.messages.length == 3;
	const init = r.messages[0];
	assert idKey(init.getDynamicField("id")) == "n:1";
	const caps = init.getDynamicField("result").getDynamicField("capabilities");
	assert caps.getDynamicField("textDocumentSync").asInt32(-1) == 1;
	assert caps.getDynamicField("hoverProvider").asBoolean(false);
	const diagnostics = published(r, uri);
	assert diagnostics.length == 2;
	assert diagnostics[0].length == 1;
	assert diagnostics[0][0].getDynamicField("message").asString() == NOT_ASSIGNABLE;
	assert diagnostics[0][0].getDynamicField("severity").asInt32(-1) == 1;
	assert spanOf(diagnostics[0][0]) == "0:28-0:29";
	assert diagnostics[1].length == 0;
	assert r.exitCode == 0;
}

test "replay: Content-Length counts bytes of a multibyte request body" {
	const uri = "file:///lspwire/multibyte.ms";
	const r = replay([
		initializeChunk(),
		frames([
			notification("textDocument/didOpen", `{"textDocument":{"uri":"${uri}","languageId":"metascript","version":1,"text":"/*é😀*/ export const value: int32 = \\"wrong\\";\\nexport const w = value;"}}`),
			request("\"é😀-1\"", "textDocument/definition", positionParams(uri, 1, 17)),
		]),
	]);
	const diagnostics = published(r, uri);
	assert diagnostics.length == 1;
	assert diagnostics[0].length == 1;
	assert spanOf(diagnostics[0][0]) == "0:36-0:37";
	assert definitionSpan(onlyAnswer(r, "s:é😀-1")) == "0:21-0:26";
}

test "replay: two edits in one drain publish once, in two drains publish twice" {
	const uri = "file:///lspwire/coalesce.ms";
	const r = replay([
		initializeChunk(),
		frames([notification("textDocument/didOpen", openParams(uri, GOOD_VALUE))]),
		frames([
			notification("textDocument/didChange", changeParams(uri, 2, BAD_VALUE)),
			notification("textDocument/didChange", changeParams(uri, 3, GOOD_VALUE)),
		]),
	]);
	const once = published(r, uri);
	assert once.length == 2;
	assert once[1].length == 0;

	const split = "file:///lspwire/split.ms";
	const s = replay([
		initializeChunk(),
		frames([notification("textDocument/didOpen", openParams(split, GOOD_VALUE))]),
		frames([notification("textDocument/didChange", changeParams(split, 2, BAD_VALUE))]),
		frames([notification("textDocument/didChange", changeParams(split, 3, GOOD_VALUE))]),
	]);
	const twice = published(s, split);
	assert twice.length == 3;
	assert twice[1].length == 1;
	assert twice[1][0].getDynamicField("message").asString() == NOT_ASSIGNABLE;
	assert twice[2].length == 0;
}

test "replay: a request between two edits answers the edit before it" {
	const uri = "file:///lspwire/between.ms";
	const r = replay([
		initializeChunk(),
		frames([notification("textDocument/didOpen", openParams(uri, "const a = 1;\nconst b = a;"))]),
		frames([
			notification("textDocument/didChange", changeParams(uri, 2, "\nconst a = 1;\nconst b = a;")),
			request("3", "textDocument/definition", positionParams(uri, 2, 10)),
			notification("textDocument/didChange", changeParams(uri, 3, "\n\nconst a = 1;\nconst b = a;")),
		]),
		frames([request("4", "textDocument/definition", positionParams(uri, 3, 10))]),
	]);
	assert definitionSpan(onlyAnswer(r, "n:3")) == "1:6-1:7";
	assert definitionSpan(onlyAnswer(r, "n:4")) == "2:6-2:7";
}

test "replay: superseded and coalesced requests answer ContentModified" {
	const uri = "file:///lspwire/superseded.ms";
	const r = replay([
		initializeChunk(),
		frames([notification("textDocument/didOpen", openParams(uri, GOOD_VALUE))]),
		frames([
			request("5", "textDocument/inlayHint", `{"textDocument":{"uri":${lspJsonString(uri)}},"range":{"start":{"line":0,"character":0},"end":{"line":1,"character":0}}}`),
			notification("textDocument/didChange", changeParams(uri, 2, BAD_VALUE)),
			request("6", "textDocument/semanticTokens/full", `{"textDocument":{"uri":${lspJsonString(uri)}}}`),
			request("7", "textDocument/semanticTokens/full", `{"textDocument":{"uri":${lspJsonString(uri)}}}`),
		]),
	]);
	for (const key of ["n:5", "n:6"]) {
		assert onlyAnswer(r, key).getDynamicField("error").getDynamicField("code").asInt32(0) == -32801;
	}
	assert onlyAnswer(r, "n:7").getDynamicField("result").getDynamicField("data").kind == JsonKind.Array;
	const diagnostics = published(r, uri);
	assert diagnostics.length == 2;
	assert diagnostics[1].length == 1;
}

test "replay: request ids come back exactly, number and string" {
	const uri = "file:///lspwire/ids.ms";
	const r = replay([
		initializeChunk(),
		frames([notification("textDocument/didOpen", openParams(uri, "const a = 1;\nconst b = a;"))]),
		frames([
			request("0", "textDocument/definition", positionParams(uri, 1, 10)),
			request("42", "textDocument/definition", positionParams(uri, 1, 10)),
			request("\"42\"", "textDocument/definition", positionParams(uri, 1, 10)),
			request("\"req-α\"", "textDocument/hover", positionParams(uri, 1, 6)),
		]),
	]);
	assert definitionSpan(onlyAnswer(r, "n:0")) == "0:6-0:7";
	assert definitionSpan(onlyAnswer(r, "n:42")) == "0:6-0:7";
	assert definitionSpan(onlyAnswer(r, "s:42")) == "0:6-0:7";
	assert onlyAnswer(r, "s:req-α").getDynamicField("result").kind == JsonKind.Object;
}

test "replay: shutdown answers null and the server waits for exit" {
	const r = replay([
		initializeChunk(),
		frames([request("9", "shutdown", "null")]),
		frames([notification("exit", "null")]),
	]);
	assert r.messages.length == 2;
	const shutdown = onlyAnswer(r, "n:9");
	assert shutdown.getDynamicField("result").kind == JsonKind.Null;
	assert hasKey(shutdown, "result");
	assert r.wire.nextChunk == 3;
	assert r.exitCode == 0;
}

test "replay: after shutdown a request answers InvalidRequest and a notification is dropped" {
	const uri = "file:///lspwire/aftershutdown.ms";
	const r = replay([
		initializeChunk(),
		frames([notification("textDocument/didOpen", openParams(uri, GOOD_VALUE))]),
		frames([request("9", "shutdown", "null")]),
		frames([
			request("10", "textDocument/definition", positionParams(uri, 0, 0)),
			notification("textDocument/didChange", changeParams(uri, 2, BAD_VALUE)),
			request("11", "shutdown", "null"),
		]),
		frames([notification("exit", "null")]),
	]);
	assert onlyAnswer(r, "n:9").getDynamicField("result").kind == JsonKind.Null;
	for (const key of ["n:10", "n:11"]) {
		assert onlyAnswer(r, key).getDynamicField("error").getDynamicField("code").asInt32(0) == -32600;
	}
	assert published(r, uri).length == 1;
	assert r.exitCode == 0;
}

test "replay: exit ends the loop at once, its code says whether shutdown came first" {
	const uri = "file:///lspwire/exit.ms";
	const after = replay([
		initializeChunk(),
		frames([
			request("9", "shutdown", "null"),
			notification("exit", "null"),
			request("10", "textDocument/hover", positionParams(uri, 0, 0)),
		]),
		frames([request("11", "textDocument/hover", positionParams(uri, 0, 0))]),
	]);
	assert after.exitCode == 0;
	assert answersTo(after, "n:10").length == 0;
	assert answersTo(after, "n:11").length == 0;
	assert after.wire.nextChunk == 2;

	const without = replay([initializeChunk(), frames([notification("exit", "null")])]);
	assert without.exitCode == 1;
	assert without.messages.length == 1;

	const closed = replay([initializeChunk()]);
	assert closed.exitCode == 0;
}

test "replay: a frame cut short by EOF is not processed and ends the server" {
	const body = request("9", "shutdown", "null");
	const r = replay([
		initializeChunk(),
		"Content-Length: " + (body.byteLength + 10) + "\r\n\r\n" + body,
	]);
	assert answersTo(r, "n:9").length == 0;
	assert r.exitCode == 1;

	const header = replay([initializeChunk(), "Content-Length: 30\r\n"]);
	assert header.messages.length == 1;
	assert header.exitCode == 0;
}

test "replay: a cancelled request still in the drain answers RequestCancelled" {
	const uri = "file:///lspwire/cancel.ms";
	const text = "const a = 1;\nconst b = a;";
	const r = replay([
		initializeChunk(),
		frames([notification("textDocument/didOpen", openParams(uri, text))]),
		frames([
			request("4", "textDocument/definition", positionParams(uri, 1, 10)),
			request("\"four\"", "textDocument/definition", positionParams(uri, 1, 10)),
			request("5", "textDocument/definition", positionParams(uri, 1, 10)),
			notification("$/cancelRequest", "{\"id\":4}"),
			notification("$/cancelRequest", "{\"id\":\"four\"}"),
			notification("$/cancelRequest", "{\"id\":99}"),
		]),
		frames([request("6", "textDocument/definition", positionParams(uri, 1, 10))]),
		frames([notification("$/cancelRequest", "{\"id\":6}")]),
	]);
	for (const key of ["n:4", "s:four"]) {
		const cancelled = onlyAnswer(r, key);
		assert !hasKey(cancelled, "result");
		const error = cancelled.getDynamicField("error");
		assert error.getDynamicField("code").asInt32(0) == -32800;
		assert error.getDynamicField("message").asString() == "RequestCancelled";
	}
	assert definitionSpan(onlyAnswer(r, "n:5")) == "0:6-0:7";
	assert definitionSpan(onlyAnswer(r, "n:6")) == "0:6-0:7";
	assert answersTo(r, "n:99").length == 0;
}

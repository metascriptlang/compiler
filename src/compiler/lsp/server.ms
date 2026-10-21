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
import { TransAmDb, createTransAmDb, dbEnsurePrelude, dbSetStdPath, dbSetResolverConfig } from "../transam/index";
import { findProjectRoot } from "../../utils/path";
import { ensureDir, realpath, writeFile } from "std/fs";
import { registrySrcPath } from "../package/cache";
import { env } from "std/process";
import { newCliOptions, applyProjectConfig } from "../options";
import { buildResolverConfig } from "../compile";
import { defaultResolveSection } from "../buildConfig";
import { resetCancel } from "../transam/cancel";
import { CompletionCache, createCompletionCache } from "./handlers/shared";
import { buildTransitiveDiagnosticsWire } from "./handlers/diagnostics";

import {
	lspDispatch, publishPendingDiagnostics,
	clientSupportsWatchedFileRegistration, watchedFilesRegistration,
} from "./handlers/lifecycle";
import { writeStderr, stdinDisableBuffering } from "std/io";
import {
	LspTransport, FrameEnd, lspReadFrame, stdioTransport, memoryTransport, createMemoryWire,
} from "./transport";
import { LspReplay, lspTranscript, lspScenarioByName } from "./replayScenarios";
import { resolveRuntimeDir } from "../../utils/path";


// ===== Server State =====

export class LspServerState {
	initialized: boolean;
	shutdownRequested: boolean;
	watchFilesThroughClient: boolean;
	db: TransAmDb;
	root: string;
	dbs: Map<string, TransAmDb>;
	completionCache: CompletionCache;
}

export function createServerState(): LspServerState {
	return {
		initialized: false,
		shutdownRequested: false,
		watchFilesThroughClient: false,
		db: createTransAmDb(512),
		root: "",
		dbs: new Map<string, TransAmDb>(),
		completionCache: createCompletionCache(),
	};
}

// Applies root's build.ms as batch checking does and makes its db current. Diagnostics
// still pending for the previous db are published first, by that db.
function selectProject(state: LspServerState, root: string): string {
	if (root == state.root) return "";
	const flushed = publishPendingDiagnostics(state.db);
	const opts = newCliOptions();
	opts.command = "lsp";
	const applied = applyProjectConfig(opts, root);
	if (!applied.ok) lspLog("build.ms: " + applied.error);
	let db = state.dbs.get(root);
	if (db == null) {
		db = createTransAmDb(512);
		const resolve = applied.ok ? applied.value.resolve : defaultResolveSection();
		dbSetResolverConfig(db, buildResolverConfig(opts.target, resolve, opts.targetOs, root));
		if (state.initialized) dbEnsurePrelude(db);
		state.dbs.set(root, db);
	}
	state.db = db;
	state.root = root;
	return flushed;
}

function refreshEveryProject(state: LspServerState, params: string): string {
	let flushed = "";
	for (const root of state.dbs) {
		flushed += selectProject(state, root);
		lspDispatch("workspace/didChangeWatchedFiles", "", params, state.db, state.completionCache);
	}
	return flushed;
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

	const documentUri = extractFileUri(params);
	let flushed = documentUri != "" ? selectProject(state, findProjectRoot(lspUriToPath(documentUri))) : "";

	// Log all requests for debugging
	if (method == "textDocument/completion") {
		writeStderr("[LSP] >>> " + method + " id=" + idStr + "\n");
	}
	const _isCompletion = method == "textDocument/completion";
	// Dispatch with error recovery
	let json = "";
	const t0 = performance.now();
	try {
		if (method == "workspace/didChangeWatchedFiles") flushed += refreshEveryProject(state, params);
		else json = lspDispatch(method, idStr, params, state.db, state.completionCache);
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
		return flushed;
	}

	if (_isCompletion) {
		const elapsed = t1 - t0;
		writeStderr("[LSP] <<< completion id=" + idStr + " " + elapsed + "ms len=" + json.length + "\n");
	}
	let result = flushed + lspFormatMessage(json);

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

// ===== Project config per opened file =====

test "an opened file's msc.lock packages reach that project's resolver" {
	const tmp = env.get("TMPDIR") != "" ? env.get("TMPDIR") : "/tmp";
	const dir = `${tmp}/msc-lsplock`;
	ensureDir(dir);
	const root = realpath(dir);
	writeFile(`${root}/build.ms`, "const config = {};\nexport default config;\n");
	writeFile(`${root}/msc.lock`, "{\"version\":1,\"packages\":{\"pkg@1.2.3\":{\"version\":\"1.2.3\"}}}");
	const state = createServerState();
	const uri = lspJsonString(`file://${root}/main.ms`);
	processMessage(`{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":${uri},"languageId":"metascript","version":1,"text":"export const v: int32 = 1;"}}}`, state);
	const at = state.db.resolverConfig.aliasKeys.indexOf("pkg");
	assert at >= 0;
	assert state.db.resolverConfig.aliasValues[at] == registrySrcPath("pkg", "1.2.3");
}

// ===== Framed replay through lspServe =====
// Scenarios live in replayScenarios.ms so a process driver runs the same ones.

function replay(drains: string[][]): LspReplay {
	const chunks: string[] = [];
	for (const drain of drains) chunks.push(drain.join(""));
	const wire = createMemoryWire(chunks);
	const exitCode = lspServe(memoryTransport(wire));
	return lspTranscript(wire.output, exitCode, wire.nextChunk);
}

function runMemoryScenario(name: string): string {
	const found = lspScenarioByName(name);
	if (!found.ok) {
		writeStderr(found.error + "\n");
		return found.error;
	}
	const scenario = found.value;
	const r = replay(scenario.drains);
	let failure = scenario.check(r);
	const invariant = scenario.checkAnyBatching;
	if (failure == "" && invariant != null) failure = invariant(r);
	if (failure != "") writeStderr("replay: " + name + ": " + failure + "\n");
	return failure;
}

test "replay: initialize, open with an error, then a fix clears it" {
	assert runMemoryScenario("initialize, open with an error, then a fix clears it") == "";
}

test "replay: Content-Length counts bytes of a multibyte request body" {
	assert runMemoryScenario("Content-Length counts bytes of a multibyte request body") == "";
}

test "replay: two edits in one drain publish once, in two drains publish twice" {
	assert runMemoryScenario("two edits in one drain publish once") == "";
	assert runMemoryScenario("two edits in two drains publish twice") == "";
}

test "replay: a request between two edits answers the edit before it" {
	assert runMemoryScenario("a request between two edits answers the edit before it") == "";
}

test "replay: superseded and coalesced requests answer ContentModified" {
	assert runMemoryScenario("superseded and coalesced requests answer ContentModified") == "";
}

test "replay: request ids come back exactly, number and string" {
	assert runMemoryScenario("request ids come back exactly, number and string") == "";
}

test "replay: shutdown answers null and the server waits for exit" {
	assert runMemoryScenario("shutdown answers null and the server waits for exit") == "";
}

test "replay: after shutdown a request answers InvalidRequest and a notification is dropped" {
	assert runMemoryScenario("after shutdown a request answers InvalidRequest and a notification is dropped") == "";
}

test "replay: exit ends the loop at once, its code says whether shutdown came first" {
	assert runMemoryScenario("exit after shutdown ends the loop at once with code 0") == "";
	assert runMemoryScenario("exit without shutdown ends the loop with code 1") == "";
	assert runMemoryScenario("input closed before exit ends the loop with code 0") == "";
}

test "replay: a frame cut short by EOF is not processed and ends the server" {
	assert runMemoryScenario("a body cut short by EOF is not processed and ends the server with code 1") == "";
	assert runMemoryScenario("a header cut short by EOF ends the server with code 0") == "";
}

test "replay: a cancelled request still in the drain answers RequestCancelled" {
	assert runMemoryScenario("a cancelled request still in the drain answers RequestCancelled") == "";
}

test "replay: position edits past non-ASCII text shift the diagnostic and the definition" {
	assert runMemoryScenario("position edits past non-ASCII text shift the diagnostic and the definition, a fix clears it") == "";
}

test "replay: a dependency edit re-checks the dependent" {
	assert runMemoryScenario("a dependency edit re-checks the dependent and clears or raises its diagnostic") == "";
}

test "replay: cancelled requests do not poison the checks after them" {
	assert runMemoryScenario("cancelled requests do not poison the checks after them") == "";
}

test "replay: an unused import warns in the editor and in batch checking" {
	assert runMemoryScenario("an unused import warns in the editor and in batch checking") == "";
}

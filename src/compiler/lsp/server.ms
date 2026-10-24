// LSP Server — Main loop with request queue, state management
//
// Reads JSON-RPC from a transport, drains buffered messages, coalesces
// auto-fired requests, dispatches to handlers, writes responses.

import {
	lspParseContentLength, lspFormatMessage, lspUriToPath, lspPathToUri,
	lspGetField, lspGetObjectField, lspJsonString, lspIdOf, lspErrorResponse,
} from "./protocol";
import { parseJson } from "std/serialize/json/parser";
import { JsonKind, JsonValue } from "std/serialize/json/types";
import { TransAmDb, createTransAmDb, dbEnsurePrelude, dbSetStdPath, dbSetResolverConfig, dbSetGlobalImports, dbStats } from "../transam/index";
import { extraGlobalImports, extraGlobalImportsBuildFile } from "../../checker/prelude";
import { findProjectRoot } from "../../utils/path";
import { ModuleCtxRegistry, createModuleCtxRegistry, swapModuleCtxRegistry } from "../../checker/instantiate";
import { ensureDir, mkdir, realpath, writeFile } from "std/fs";
import { normalize } from "std/fs/path";
import { registrySrcPath } from "../package/cache";
import { env } from "std/process";
import { newCliOptions, applyProjectConfig } from "../options";
import { buildResolverConfig } from "../compile";
import { defaultResolveSection } from "../buildConfig";
import { resetCancel } from "../transam/cancel";
import { CompletionCache, createCompletionCache, markDependentsStale } from "./handlers/shared";
import { buildTransitiveDiagnosticsWire } from "./handlers/diagnostics";

import {
	lspDispatch, publishPendingDiagnostics,
	clientSupportsWatchedFileRegistration, watchedFilesRegistration, checkDependentsUnlessStopped,
} from "./handlers/lifecycle";
import { writeStderr, stdinDisableBuffering } from "std/io";
import {
	LspTransport, FrameEnd, lspReadFrame, stdioTransport, memoryTransport, createMemoryWire, createLateInputWire,
} from "./transport";
import {
	LspReplay,
	lspTranscript,
	lspScenarioByName,
	materialiseProject,
	replaceInFrames,
	projectUri,
	scenarioSlug,
	PROJECT_URI,
	frames, request, notification, initializeDrain, openParams, changeParams, positionParams,
} from "./replayScenarios";
import { getDynamicField, at, length, asString, asInt32 } from "std/serialize/json/accessors";
import { resolveRuntimeDir } from "../../utils/path";


// ===== Server State =====

export class LspServerState {
	initialized: boolean;
	shutdownRequested: boolean;
	watchFilesThroughClient: boolean;
	db: TransAmDb;
	root: string;
	dbs: Map<string, TransAmDb>;
	registries: Map<string, ModuleCtxRegistry>;
	completionCache: CompletionCache;
	inputPending: (() => boolean) | null;
	inputClosed: boolean;
	yieldToInput: boolean;
}

export function createServerState(): LspServerState {
	return {
		initialized: false,
		shutdownRequested: false,
		watchFilesThroughClient: false,
		db: createTransAmDb(512),
		root: "",
		dbs: new Map<string, TransAmDb>(),
		registries: new Map<string, ModuleCtxRegistry>(),
		completionCache: createCompletionCache(),
		inputPending: null,
		inputClosed: false,
		yieldToInput: false,
	};
}

// Applies root's build.ms as batch checking does and makes its db current. Diagnostics
// still pending for the previous db are published first, by that db.
function selectProject(state: LspServerState, root: string): string {
	if (root == state.root) return "";
	const flushed = flushWithoutYielding(state.db);
	const opts = newCliOptions();
	opts.command = "lsp";
	const applied = applyProjectConfig(opts, root);
	if (!applied.ok) lspLog("build.ms: " + applied.error);
	const next = state.registries.get(root);
	state.registries.set(state.root, swapModuleCtxRegistry(next != null ? next : createModuleCtxRegistry()));
	let db = state.dbs.get(root);
	if (db == null) {
		db = createTransAmDb(512);
		const resolve = applied.ok ? applied.value.resolve : defaultResolveSection();
		dbSetResolverConfig(db, buildResolverConfig(opts.target, resolve, opts.targetOs, root));
		if (state.initialized) dbEnsurePrelude(db);
		db.cancelCtx.inputPending = state.inputPending;
		state.dbs.set(root, db);
	}
	if (state.initialized) {
		for (const entry of dbSetGlobalImports(db, extraGlobalImports())) lspLog(`globalImports entry '${entry}' in ${extraGlobalImportsBuildFile()} resolves to no module`);
	}
	state.db = db;
	state.root = root;
	return flushed;
}

function flushWithoutYielding(db: TransAmDb): string {
	const pending = db.cancelCtx.inputPending;
	db.cancelCtx.inputPending = null;
	const flushed = publishPendingDiagnostics(db);
	db.cancelCtx.inputPending = pending;
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

struct QueuedMessage {
	body: string;
	malformed: boolean;
	method: string;
	id: string;
	cancelTarget: string;
	fileUri: string;
	receivedAt: float64;
}

const DID_CHANGE = "textDocument/didChange";
const CANCEL_REQUEST = "$/cancelRequest";

function parseQueuedMessage(body: string): QueuedMessage {
	const receivedAt = performance.now();
	const parsed = parseJson(body);
	if (!parsed.ok || parsed.value.kind != JsonKind.Object) {
		return { body, malformed: true, method: "", id: "", cancelTarget: "", fileUri: "", receivedAt };
	}
	const root = parsed.value;
	const method = root.getDynamicField("method").asString();
	const params = root.getDynamicField("params");
	return {
		body,
		malformed: false,
		method,
		id: lspIdOf(root.getDynamicField("id")),
		cancelTarget: method == CANCEL_REQUEST ? lspIdOf(params.getDynamicField("id")) : "",
		fileUri: params.getDynamicField("textDocument").getDynamicField("uri").asString(),
		receivedAt,
	};
}

// Auto-fired methods that can be safely deduplicated per-file.
// For each (method, fileUri) pair, keep only the last occurrence.
function isAutoFired(method: string): boolean {
	return method == "textDocument/inlayHint"
		|| method == "textDocument/semanticTokens/full"
		|| method == "textDocument/documentHighlight";
}

// Indices the coalesce drops: an auto-fired request with a later one for the same (method, file),
// and a didChange whose next non-auto-fired message for the file is another didChange.
// Never drops lifecycle or other content-sync messages.
function coalesceDropped(queue: QueuedMessage[]): Set<int32> {
	const dropped = new Set<int32>();
	const autoFiredAhead = new Set<string>();
	const didChangeNext = new Set<string>();
	for (let i = queue.length - 1; i >= 0; i--) {
		const qm = queue[i];
		if (qm.fileUri.length == 0) continue;
		if (isAutoFired(qm.method)) {
			const key = qm.method + " " + qm.fileUri;
			if (autoFiredAhead.has(key)) dropped.add(i);
			autoFiredAhead.add(key);
			continue;
		}
		if (qm.method == DID_CHANGE && didChangeNext.has(qm.fileUri)) dropped.add(i);
		if (qm.method == DID_CHANGE) didChangeNext.add(qm.fileUri);
		else didChangeNext.delete(qm.fileUri);
	}
	return dropped;
}

function coalesceQueue(queue: QueuedMessage[]): QueuedMessage[] {
	const dropped = coalesceDropped(queue);
	const result: QueuedMessage[] = [];
	for (let i = 0; i < queue.length; i++) {
		if (!dropped.has(i)) result.push(queue[i]);
	}
	return result;
}

const REQUEST_CANCELLED: int32 = -32800;
const CONTENT_MODIFIED: int32 = -32801;
const PARSE_ERROR: int32 = -32700;
const INVALID_REQUEST: int32 = -32600;
const INTERNAL_ERROR: int32 = -32603;

function answerError(io: LspTransport, id: string, code: int32, message: string): void {
	if (id != "") io.write(lspFormatMessage(lspErrorResponse(id, code, message)));
}

function isCancelled(id: string, queue: QueuedMessage[], fromIdx: int32): boolean {
	for (let j = fromIdx; j < queue.length; j++) {
		if (queue[j].method == CANCEL_REQUEST && queue[j].cancelTarget == id) return true;
	}
	return false;
}

// Check if a request is superseded by a later didChange for the same file.
function isSuperseded(qm: QueuedMessage, queue: QueuedMessage[], fromIdx: int32): boolean {
	if (qm.fileUri.length == 0) return false;
	for (let j = fromIdx; j < queue.length; j++) {
		if (queue[j].method == DID_CHANGE && queue[j].fileUri == qm.fileUri) return true;
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
	state.inputPending = () => !state.inputClosed && io.hasBufferedData();
	state.db.cancelCtx.inputPending = state.inputPending;
	let carried: QueuedMessage[] = [];
	while (true) {
		// 1. Read first message (blocking wait) unless a stopped check left work to redo
		const queue: QueuedMessage[] = carried;
		carried = [];
		if (queue.length == 0) {
			const first = lspReadFrame(io);
			if (!first.ok) return streamExitCode(first.error);
			queue.push(parseQueuedMessage(first.value));
		}

		// 2. Drain all buffered messages (non-blocking)
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
		state.inputClosed = !streamOpen;

		// 3. Coalesce: dedup auto-fired + didChange per file
		const dropped = coalesceDropped(queue);
		const coalesced: QueuedMessage[] = [];
		for (let k = 0; k < queue.length; k++) {
			if (!dropped.has(k)) coalesced.push(queue[k]);
			else answerError(io, queue[k].id, CONTENT_MODIFIED, "ContentModified");
		}

		if (queue.length > 1) {
			lspLog("queue: " + queue.length + " drained, " + coalesced.length + " after coalesce");
		}

		// 4. Process in order
		let yielded = false;
		for (let qi = 0; qi < coalesced.length; qi++) {
			const qm = coalesced[qi];
			if (isAutoFired(qm.method) && isSuperseded(qm, coalesced, qi + 1)) {
				answerError(io, qm.id, CONTENT_MODIFIED, "ContentModified");
				continue;
			}
			if (qm.method == "exit") return state.shutdownRequested ? 0 : 1;
			if (qm.id != "" && isCancelled(qm.id, coalesced, qi + 1)) {
				answerError(io, qm.id, REQUEST_CANCELLED, "RequestCancelled");
				continue;
			}
			if (qm.id != "") {
				const delay = performance.now() - qm.receivedAt;
				writeStderr(`[LSP-QUEUE] ${qm.method} id=${qm.id} delay=${delay}ms\n`);
			}
			try {
				const response = processQueued(qm, state);
				if (response.length > 5000) {
					writeStderr(`[LSP] sending response len=${response.length} method=${qm.method}\n`);
				}
				if (response.length > 0) io.write(response);
			} catch (e) {
				lspLog("Handler error: " + e);
				resetCancel(state.db.cancelCtx);
				state.yieldToInput = false;
			}
			if (state.yieldToInput) {
				state.yieldToInput = false;
				yielded = true;
				for (let k = qm.id != "" ? qi : qi + 1; k < coalesced.length; k++) carried.push(coalesced[k]);
				break;
			}
		}
		if (yielded) continue;

		// 5. Post-drain: publish diagnostics for the last changed file.
		// Only the FINAL content state gets type-checked — intermediate keystrokes skipped.
		const pendingDiag = publishPendingDiagnostics(state.db);
		if (pendingDiag.length > 0) io.write(pendingDiag);
		resetCancel(state.db.cancelCtx);
		writeStderr(`[LSP-STATS] ${dbStats(state.db)}\n`);
		if (!streamOpen) return streamExitCode(streamEnd);
	}
	return 0;
}

// ===== Message Processing =====

function trackLifecycle(state: LspServerState, method: string, params: string): void {
	if (method == "initialize") {
		state.initialized = true;
		state.watchFilesThroughClient = clientSupportsWatchedFileRegistration(params);
		const root = resolveRuntimeDir();
		if (root.length > 0) dbSetStdPath(state.db, root + "/std");
		dbEnsurePrelude(state.db);
	}
	if (method == "shutdown") state.shutdownRequested = true;
}

function logIfSlow(what: string, ms: float64): void {
	if (ms > 50) writeStderr("[LSP] " + what + " " + ms + "ms\n");
}

// Process a single JSON-RPC message. Returns wire-formatted response(s)
// (Content-Length + JSON), or "" if no response needed.
// For didOpen, appends transitive diagnostics notifications.
export function processMessage(msg: string, state: LspServerState): string {
	return processQueued(parseQueuedMessage(msg), state);
}

function processQueued(qm: QueuedMessage, state: LspServerState): string {
	if (qm.malformed) return lspFormatMessage(lspErrorResponse("null", PARSE_ERROR, "ParseError"));
	const method = qm.method;
	const idStr = qm.id;
	if (state.shutdownRequested) {
		const refusal = lspErrorResponse(idStr, INVALID_REQUEST, "InvalidRequest: server is shutting down");
		return idStr == "" ? "" : lspFormatMessage(refusal);
	}
	const params = lspGetObjectField(qm.body, "params");
	trackLifecycle(state, method, params);
	if (method == "initialized") {
		return state.watchFilesThroughClient ? lspFormatMessage(watchedFilesRegistration()) : "";
	}

	// Invalidate completion cache when new content arrives
	if (method == DID_CHANGE || method == "textDocument/didOpen") {
		state.completionCache.uri = "";
		state.completionCache.line = -1;
	}

	let flushed = qm.fileUri != "" ? selectProject(state, findProjectRoot(lspUriToPath(qm.fileUri))) : "";

	const isCompletion = method == "textDocument/completion";
	if (isCompletion) writeStderr("[LSP] >>> " + method + " id=" + idStr + "\n");
	let json = "";
	const t0 = performance.now();
	try {
		if (method == "workspace/didChangeWatchedFiles") flushed += refreshEveryProject(state, params);
		else json = lspDispatch(method, idStr, params, state.db, state.completionCache);
	} catch (e) {
		const errMsg = e != null ? "" + e : "unknown error";
		writeStderr("LSP handler crash: " + method + " — " + errMsg + "\n");
		if (idStr != "") json = lspErrorResponse(idStr, INTERNAL_ERROR, "internal error: " + errMsg);
	}
	const elapsed = performance.now() - t0;

	const stopped = state.db.cancelCtx.stoppedForInput;
	resetCancel(state.db.cancelCtx);
	if (stopped) {
		state.yieldToInput = true;
		state.completionCache.uri = "";
		state.completionCache.line = -1;
		if (idStr != "") return flushed;
	}

	if (json == "") {
		logIfSlow(method + " (notif)", elapsed);
		return flushed;
	}

	if (isCompletion) {
		writeStderr("[LSP] <<< completion id=" + idStr + " " + elapsed + "ms len=" + json.length + "\n");
	}
	let result = flushed + lspFormatMessage(json);

	// Append transitive diagnostics on didOpen (didChange handled in post-drain).
	if (method == "textDocument/didOpen") {
		const path = lspUriToPath(qm.fileUri);
		if (checkDependentsUnlessStopped(state.db, path)) {
			result += buildTransitiveDiagnosticsWire(state.db, path);
		} else {
			resetCancel(state.db.cancelCtx);
			markDependentsStale(path);
			state.yieldToInput = true;
		}
	}

	logIfSlow(method + " id=" + idStr, elapsed);
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

function queued(body: string, method: string, fileUri: string): QueuedMessage {
	return { body, method, id: "", cancelTarget: "", fileUri, receivedAt: 0 };
}

test "coalesce empty queue" {
	const q: QueuedMessage[] = [];
	const r = coalesceQueue(q);
	assert r.length == 0;
}

test "coalesce single message" {
	const q: QueuedMessage[] = [];
	q.push(queued("", "textDocument/hover", "file:///a.ms"));
	const r = coalesceQueue(q);
	assert r.length == 1;
}

test "coalesce deduplicates auto-fired same file" {
	const q: QueuedMessage[] = [];
	q.push(queued("1", "textDocument/inlayHint", "file:///a.ms"));
	q.push(queued("2", "textDocument/hover", "file:///a.ms"));
	q.push(queued("3", "textDocument/inlayHint", "file:///a.ms"));
	const r = coalesceQueue(q);
	// First inlayHint deduped, hover kept, second inlayHint kept
	assert r.length == 2;
	assert r[0].body == "2";
	assert r[1].body == "3";
}

test "coalesce keeps different files" {
	const q: QueuedMessage[] = [];
	q.push(queued("1", "textDocument/inlayHint", "file:///a.ms"));
	q.push(queued("2", "textDocument/inlayHint", "file:///b.ms"));
	const r = coalesceQueue(q);
	assert r.length == 2;
}

test "coalesce deduplicates didChange same file" {
	const q: QueuedMessage[] = [];
	q.push(queued("1", "textDocument/didChange", "file:///a.ms"));
	q.push(queued("2", "textDocument/didChange", "file:///a.ms"));
	const r = coalesceQueue(q);
	assert r.length == 1;
	assert r[0].body == "2";
}

test "isSuperseded by later didChange" {
	const q: QueuedMessage[] = [];
	q.push(queued("1", "textDocument/inlayHint", "file:///a.ms"));
	q.push(queued("2", "textDocument/didChange", "file:///a.ms"));
	assert isSuperseded(q[0], q, 1);
	assert !isSuperseded(q[1], q, 2);
}

test "isSuperseded not by different file" {
	const q: QueuedMessage[] = [];
	q.push(queued("1", "textDocument/inlayHint", "file:///a.ms"));
	q.push(queued("2", "textDocument/didChange", "file:///b.ms"));
	assert !isSuperseded(q[0], q, 1);
}

const HOVER_PARAMS = "\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":0}";

test "a nested id in params does not replace the request id" {
	const state = createServerState();
	const response = processMessage("{\"method\":\"textDocument/hover\",\"params\":{\"id\":7," + HOVER_PARAMS + "},\"id\":1}", state);
	assert response.indexOf("\"id\":1,", 0) > 0;
	assert response.indexOf("\"id\":7", 0) < 0;
}

test "a nested method in params does not replace the dispatched method" {
	const state = createServerState();
	const response = processMessage("{\"params\":{\"method\":\"workspace/other\",\"id\":7," + HOVER_PARAMS + "},\"method\":\"textDocument/hover\",\"id\":1}", state);
	assert response.indexOf("\"id\":1,", 0) > 0;
	assert response.indexOf("\"id\":7", 0) < 0;
}

test "a body that is not a JSON object answers ParseError with a null id" {
	const state = createServerState();
	for (const body of ["{\"id\":1,\"method\":\"textDocument/hover\"", "[1,2]"]) {
		const response = processMessage(body, state);
		assert response.indexOf("\"id\":null,\"error\":{\"code\":-32700", 0) > 0;
	}
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

function replay(drains: string[][], projectDir: string = ""): LspReplay {
	const chunks: string[] = [];
	for (const drain of drains) chunks.push(drain.join(""));
	const wire = createMemoryWire(chunks);
	const exitCode = lspServe(memoryTransport(wire));
	const output = projectDir == "" ? wire.output : replaceInFrames(wire.output, projectUri(projectDir), PROJECT_URI);
	return lspTranscript(output, exitCode, wire.nextChunk);
}

function memoryProjectDir(name: string): string {
	const tmp = env.get("TMPDIR") != "" ? env.get("TMPDIR") : "/tmp";
	const dir = `${tmp}/mscLspMemory/${scenarioSlug(name)}`;
	ensureDir(dir);
	return realpath(dir).replaceAll("\\", "/");
}

function runMemoryScenario(name: string): string {
	const found = lspScenarioByName(name);
	if (!found.ok) {
		writeStderr(found.error + "\n");
		return found.error;
	}
	const scenario = found.value;
	let drains = scenario.drains;
	let projectDir = "";
	const project = scenario.project;
	if (project != null) {
		projectDir = memoryProjectDir(name);
		const moved = materialiseProject(project, drains, projectDir);
		if (!moved.ok) {
			writeStderr("replay: " + name + ": " + moved.error + "\n");
			return moved.error;
		}
		drains = moved.value;
	}
	const r = replay(drains, projectDir);
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

test "replay: build.ms config reaches the editor as it reaches batch checking" {
	assert runMemoryScenario("build.ms config reaches the editor as it reaches batch checking") == "";
}

test "replay: two projects in one session each keep their own build.ms" {
	assert runMemoryScenario("two projects in one session each keep their own build.ms") == "";
}

test "replay: a macro from a build.ms global import expands in the editor" {
	assert runMemoryScenario("a macro from a build.ms global import expands in the editor") == "";
}

test "replay: a dependency shared by two projects resolves through each project's own deps" {
	assert runMemoryScenario("a dependency shared by two projects resolves through each project's own deps") == "";
}

test "replay: a class reached through a build.ms global import is the class its importer names" {
	assert runMemoryScenario("a class reached through a build.ms global import is the class its importer names") == "";
}

test "replay: a generic class from a macro module reached through a build.ms global import keeps its identity" {
	assert runMemoryScenario("a generic class from a macro module reached through a build.ms global import keeps its identity") == "";
}

test "replay: an edit to a build.ms global import reaches the modules that use its names" {
	assert runMemoryScenario("an edit to a build.ms global import reaches the modules that use its names") == "";
}

test "replay: a module a build.ms global import reaches does not see the global import, as in batch checking" {
	assert runMemoryScenario("a module a build.ms global import reaches does not see the global import, as in batch checking") == "";
}

test "replay: a generic instantiated from an importer reads its module's inferred const" {
	assert runMemoryScenario("a generic instantiated from an importer reads its module's inferred const") == "";
}

test "replay: a generic from a module that imports a macro reads that module's imports" {
	assert runMemoryScenario("a generic from a module that imports a macro reads that module's imports") == "";
	assert runMemoryScenario("a generic from a module that imports a macro reached through a build.ms global import reads that module's imports") == "";
}

test "replay: a module the second build.ms global import reaches sees the first one only" {
	assert runMemoryScenario("a module the second build.ms global import reaches sees the first one only") == "";
}

test "replay: a build.ms module pass still applies after the session checked another project" {
	assert runMemoryScenario("a build.ms module pass still applies after the session checked another project") == "";
}

// ===== Exports a top-level macro statement splices =====
// lib.ms gets `export interface Foo` only from the macro statement `fooBody(0);`, so an
// importer checked before lib.ms sees Foo only if the macro statement was expanded.

const SPLICE_MAC = 'import { Node, NodeKind } from "std/meta";
export macro fooBody(node: Node): Node {
	const L = node.line;
	const C = node.column;
	return {
		kind: NodeKind.SpliceMany, line: L, column: C,
		spliceNodes: [{
			kind: NodeKind.ExportDecl, line: L, column: C,
			exportedDecl: {
				kind: NodeKind.InterfaceDecl, line: L, column: C,
				interfaceName: "NAME", interfaceFields: ["x"], interfaceFieldTypes: ["number | null"], interfaceExtends: [],
				nameLocation: { line: L, column: C },
			},
		}],
	};
}
';
const SPLICE_USE = 'import { Foo } from "./lib";
const f: Foo = { x: 2 };
console.log(f.x == f.x);
';
const SPLICE_TAKE = 'import { makeFoo } from "./lib";
function take(v: string | null): void { console.log(v == v); }
take(makeFoo());
';

function spliceMac(name: string): string {
	return SPLICE_MAC.replace("NAME", name);
}

function spliceLib(statement: string): string {
	return 'import { fooBody } from "./mac";\n' + statement + '\nexport function makeFoo(): Foo {\n\treturn { x: 1 };\n}\n';
}

function spliceDir(name: string): string {
	const tmp = env.get("TMPDIR") != "" ? env.get("TMPDIR") : "/tmp";
	const dir = normalize(tmp + "/msc-lspsplice-" + name);
	mkdir(dir);
	return dir;
}

function writeSpliceTriple(dir: string, user: string): string[] {
	const files = [["mac.ms", spliceMac("Foo")], ["user.ms", user], ["lib.ms", spliceLib("fooBody(0);")]];
	const opens: string[] = [];
	for (const f of files) {
		writeFile(dir + "/" + f[0], f[1]);
		opens.push(notification("textDocument/didOpen", openParams(lspPathToUri(dir + "/" + f[0]), f[1])));
	}
	return frames(opens);
}

function publishesOf(r: LspReplay, uri: string): string {
	const publishes: string[] = [];
	for (const m of r.messages) {
		if (m.getDynamicField("method").asString() != "textDocument/publishDiagnostics") continue;
		const params = m.getDynamicField("params");
		if (params.getDynamicField("uri").asString() != uri) continue;
		const diagnostics = params.getDynamicField("diagnostics");
		const items: string[] = [];
		for (let i = 0; i < diagnostics.length(); i++) {
			const d = diagnostics.at(i);
			const start = d.getDynamicField("range").getDynamicField("start");
			items.push(start.getDynamicField("line").asInt32(-1) + ":" + start.getDynamicField("character").asInt32(-1)
				+ " " + d.getDynamicField("message").asString());
		}
		publishes.push("[" + items.join("; ") + "]");
	}
	const text = publishes.join(" ");
	writeStderr("splice: " + uri + " publishes " + text + "\n");
	return text;
}

test "a type a macro statement exports reaches an importer opened before its module" {
	const dir = spliceDir("use");
	const r = replay([initializeDrain(), writeSpliceTriple(dir, SPLICE_USE)]);
	assert publishesOf(r, lspPathToUri(dir + "/user.ms")) == "[]";
}

test "a real error through a macro-spliced type is reported once, as batch checking reports it" {
	const dir = spliceDir("take");
	const r = replay([initializeDrain(), writeSpliceTriple(dir, SPLICE_TAKE)]);
	assert publishesOf(r, lspPathToUri(dir + "/user.ms")) == "[2:4 Argument type mismatch in 'take' arg 0: got Foo, expected string | null]";
}

test "editing the macro statement or the macro re-checks the importer of the spliced type" {
	const dir = spliceDir("edit");
	const lib = lspPathToUri(dir + "/lib.ms");
	const mac = lspPathToUri(dir + "/mac.ms");
	const r = replay([
		initializeDrain(),
		writeSpliceTriple(dir, SPLICE_USE),
		frames([notification("textDocument/didChange", changeParams(lib, 2, spliceLib("")))]),
		frames([notification("textDocument/didChange", changeParams(lib, 3, spliceLib("fooBody(0);")))]),
		frames([notification("textDocument/didChange", changeParams(mac, 2, spliceMac("Bar")))]),
		frames([notification("textDocument/didChange", changeParams(mac, 3, spliceMac("Foo")))]),
	]);
	const missing = "[0:0 Module './lib' has no export 'Foo']";
	assert publishesOf(r, lspPathToUri(dir + "/user.ms")) == ["[]", missing, "[]", missing, "[]"].join(" ");
}

const HOME_LIB = 'import { fooBody } from "./mac";
fooBody(0);
export class Home {
  n: int32 = 1;
}
export function built(h: Home, f: Foo): int32 {
  return f.x == null ? h.n : 0;
}
';
const HOME_GEN = 'import { Home, Foo, built } from "./lib";
export function each<T>(x: T, h: Home, f: Foo): int32 {
  return built(h, f);
}
';
const HOME_USER = 'import { each } from "./gen";
import { Home, Foo } from "./lib";
const f: Foo = { x: null };
console.log(each<int32>(1, new Home(), f));
';

test "a class from a macro-importing module keeps one identity for a generic checked before its importer" {
	const dir = spliceDir("home");
	const files = [["mac.ms", spliceMac("Foo")], ["lib.ms", HOME_LIB], ["gen.ms", HOME_GEN], ["user.ms", HOME_USER]];
	for (const f of files) writeFile(dir + "/" + f[0], f[1]);
	const gen = lspPathToUri(dir + "/gen.ms");
	const user = lspPathToUri(dir + "/user.ms");
	const r = replay([
		initializeDrain(),
		frames([notification("textDocument/didOpen", openParams(gen, HOME_GEN))]),
		frames([notification("textDocument/didOpen", openParams(user, HOME_USER))]),
	]);
	assert publishesOf(r, gen) == "[]";
	assert publishesOf(r, user) == "[]";
}

const BUILT_LIB = 'export class Home {
  n: int32 = 1;
}
export function built(h: Home, f: string | null): int32 {
  return f == null ? h.n : 0;
}
';
const BUILT_GEN = 'import { Home, built } from "./lib";
export function each<T>(x: T, h: Home): int32 {
  return built(h, null);
}
';
const BUILT_USER = 'import { each } from "./gen";
import { Home } from "./lib";
console.log(each<int32>(1, new Home()));
';

test "a generic from a module not checked yet resolves its own module's imports" {
	const dir = spliceDir("built");
	const files = [["lib.ms", BUILT_LIB], ["gen.ms", BUILT_GEN], ["user.ms", BUILT_USER]];
	for (const f of files) writeFile(dir + "/" + f[0], f[1]);
	const user = lspPathToUri(dir + "/user.ms");
	const r = replay([initializeDrain(), frames([notification("textDocument/didOpen", openParams(user, BUILT_USER))])]);
	assert publishesOf(r, user) == "[]";
}

const DRIFT_LIB = 'import { k } from "./d";
export class Home {
  n: int32 = k;
}
export function mk(): Home {
  return new Home();
}
';
const DRIFT_MID = 'import { Home } from "./lib";
export function take(h: Home): int32 {
  return h.n;
}
';
const DRIFT_USER = 'import { mk } from "./lib";
import { take } from "./mid";
console.log(take(mk()));
';

test "an upstream edit re-registers an unchanged module against its dependency's current class" {
	const dir = spliceDir("drift");
	const files = [["d.ms", "export const k: int32 = 1;\n"], ["lib.ms", DRIFT_LIB], ["mid.ms", DRIFT_MID], ["user.ms", DRIFT_USER]];
	for (const f of files) writeFile(dir + "/" + f[0], f[1]);
	const lib = lspPathToUri(dir + "/lib.ms");
	const user = lspPathToUri(dir + "/user.ms");
	const r = replay([
		initializeDrain(),
		frames([notification("textDocument/didOpen", openParams(lib, DRIFT_LIB))]),
		frames([notification("textDocument/didOpen", openParams(user, DRIFT_USER))]),
		frames([notification("textDocument/didChange", changeParams(lspPathToUri(dir + "/d.ms"), 2, "export const k: int32 = 2;\n"))]),
	]);
	assert publishesOf(r, user) == "[]";
}

// ===== Input that arrives while a check runs =====
// Three chunks are read before the late one is armed (initialize, open, edit+requests); the
// first empty probe after that ends the drain and each later one precedes a top-level statement.

const LATE_URI = "file:///lsp-late/a.ms";
const LATE_V1 = "const a = 1;\nconst b = a;\nexport const value: int32 = 42;\n";
const LATE_V2 = "const a = 1;\nconst b = a;\nexport const value: string = \"x\";\n";
const LATE_WRONG = "const a = 1;\nconst b = a;\nexport const value: int32 = \"x\";\n";
const LATE_V3 = "const a = 1;\nconst b = a;\nexport const value: boolean = true;\n";

function lateReplay(drains: string[][], late: string[], atEmptyProbe: int32): LspReplay {
	const chunks: string[] = [];
	for (const drain of drains) chunks.push(drain.join(""));
	const wire = createLateInputWire(chunks, late.join(""), drains.length, atEmptyProbe);
	const exitCode = lspServe(memoryTransport(wire));
	return lspTranscript(wire.output, exitCode, wire.nextChunk);
}

function answerTo(r: LspReplay, id: int32): JsonValue {
	for (const m of r.messages) {
		if (m.getDynamicField("id").asInt32(-1) == id) return m;
	}
	throw new Error("no answer to " + id);
}

function errorCodeOf(r: LspReplay, id: int32): int32 {
	return answerTo(r, id).getDynamicField("error").getDynamicField("code").asInt32(0);
}

function hoverOf(r: LspReplay, id: int32): string {
	return answerTo(r, id).getDynamicField("result").getDynamicField("contents").getDynamicField("value").asString();
}

function lateHover(id: string): string {
	return frames([request(id, "textDocument/hover", positionParams(LATE_URI, 2, 14))])[0];
}

function lateEditedDrains(): string[][] {
	return [
		initializeDrain(),
		frames([notification("textDocument/didOpen", openParams(LATE_URI, LATE_V1))]),
		frames([notification("textDocument/didChange", changeParams(LATE_URI, 2, LATE_V2))]).concat([lateHover("7")]),
	];
}

test "a request cancelled while its check runs stops there and answers RequestCancelled" {
	for (const probe of [2, 4]) {
		const r = lateReplay(lateEditedDrains(), frames([notification("$/cancelRequest", "{\"id\":7}")]).concat([lateHover("8")]), probe);
		assert r.exitCode == 0;
		assert errorCodeOf(r, 7) == -32800;
		assert hoverOf(r, 8).indexOf("string", 0) >= 0;
	}
}

test "an auto-fired request stopped by a later edit answers ContentModified and the next request reads the new text" {
	const hint = frames([request("7", "textDocument/inlayHint", "{\"textDocument\":{\"uri\":\"" + LATE_URI + "\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":3,\"character\":0}}}")]);
	const drains = lateEditedDrains();
	drains[2] = frames([notification("textDocument/didChange", changeParams(LATE_URI, 2, LATE_V2))]).concat(hint);
	const late = frames([notification("textDocument/didChange", changeParams(LATE_URI, 3, LATE_V3))]).concat([lateHover("8")]);
	const r = lateReplay(drains, late, 2);
	assert r.exitCode == 0;
	assert errorCodeOf(r, 7) == -32801;
	assert hoverOf(r, 8).indexOf("boolean", 0) >= 0;
}

test "a hover stopped by a later edit is retried in order and the edit is checked once" {
	const late = frames([notification("textDocument/didChange", changeParams(LATE_URI, 3, LATE_V3))]).concat([lateHover("8")]);
	const r = lateReplay(lateEditedDrains(), late, 2);
	assert r.exitCode == 0;
	assert hoverOf(r, 7).indexOf("string", 0) >= 0;
	assert hoverOf(r, 8).indexOf("boolean", 0) >= 0;
	assert publishesOf(r, LATE_URI) == "[] []";
}

test "pending diagnostics stopped by a later edit are published once, for the last text" {
	const drains = [
		initializeDrain(),
		frames([notification("textDocument/didOpen", openParams(LATE_URI, LATE_V1))]),
		frames([notification("textDocument/didChange", changeParams(LATE_URI, 2, LATE_V2))]),
	];
	const late = frames([notification("textDocument/didChange", changeParams(LATE_URI, 3, LATE_WRONG))]);
	const r = lateReplay(drains, late, 2);
	assert r.exitCode == 0;
	assert publishesOf(r, LATE_URI) == "[] [2:28 Type 'string' is not assignable to type 'int32']";
}

test "dependents stopped while checked are published after the next batch, unchanged ones not at all" {
	const depUri = "file:///lsp-late/b.ms";
	const userUri = "file:///lsp-late/user.ms";
	const good = "export function foo(): int32 { return 1; }\n";
	const bad = "export function foo(): string { return \"x\"; }\n";
	const user = "import { foo } from \"./b\";\nexport const x: int32 = foo();\n";
	const drains = [
		initializeDrain(),
		frames([notification("textDocument/didOpen", openParams(depUri, good))]),
		frames([notification("textDocument/didOpen", openParams(userUri, user))]),
		frames([notification("textDocument/didChange", changeParams(depUri, 2, bad))]),
	];
	const late = frames([notification("textDocument/didChange", changeParams(depUri, 3, good))]);
	const r = lateReplay(drains, late, 3);
	assert r.exitCode == 0;
	assert publishesOf(r, userUri) == "[]";
	assert publishesOf(r, depUri) == "[] [] []";
}

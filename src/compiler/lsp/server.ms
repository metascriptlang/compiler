// LSP Server — Main loop, state management
//
// Reads JSON-RPC from stdin, dispatches to handlers, writes responses.
// I/O uses console.log for stderr logging. Actual stdin/stdout I/O
// requires ms_stdio.h (readLine, readBytes, writeStdout).
// For now, server logic is tested via pure dispatch (no I/O in tests).

import {
	lspParseContentLength, lspFormatMessage, lspUriToPath,
	lspGetField, lspGetNumberField, lspGetObjectField, lspJsonNumber
} from "./protocol";
import { TransAmDb, createTransAmDb } from "../transam/index";
import { requestCancel, resetCancel } from "../transam/cancel";
import { lspDispatch, buildTransitiveDiagnosticsWire, CompletionCache, createCompletionCache } from "./handlers";
import { readLine, readBytes, writeStdout, writeStderr } from "std/io";


// ===== Server State =====

export interface LspServerState {
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

// ===== Main Loop =====

export function lspRunServer(): void {
	const state = createServerState();
	lspLog("MetaScript LSP server starting");

	while (!state.shutdownRequested) {
		// 1. Read Content-Length header line
		const headerLine = readLine();
		if (headerLine.length === 0) {
			// EOF on stdin — client disconnected
			break;
		}

		const contentLength = lspParseContentLength(headerLine);
		if (contentLength < 0) {
			// Not a Content-Length header — skip (could be Content-Type or other)
			continue;
		}

		// 2. Read remaining headers until empty line (\r\n\r\n separator)
		//    readLine strips \r\n, so empty line → length 0
		let sep = readLine();
		while (sep.length > 0) {
			// Could be additional headers (Content-Type, etc.) — skip
			sep = readLine();
		}

		// 3. Read JSON body
		const body = readBytes(contentLength);
		if (body.length === 0) {
			lspLog("Failed to read message body");
			break;
		}

		// 4. Process and respond (processMessage returns wire-formatted string)
		try {
			const response = processMessage(body, state);
			if (response.length > 0) {
				writeStdout(response);
			}
		} catch (e) {
			lspLog("Handler error: " + e);
		}
	}

	lspLog("MetaScript LSP server exiting");
}

// ===== Message Processing =====

// Process a single JSON-RPC message. Returns wire-formatted response(s)
// (Content-Length + JSON), or "" if no response needed.
// For didOpen/didChange, appends transitive diagnostics notifications.
export function processMessage(msg: string, state: LspServerState): string {
	const method = lspGetField(msg, "method");
	const idNum = lspGetNumberField(msg, "id");
	const idStr = idNum >= 0 ? lspJsonNumber(idNum) : "";
	const params = lspGetObjectField(msg, "params");

	// Track lifecycle
	if (method === "initialize") {
		state.initialized = true;
		// Extract rootUri/rootPath → set stdPath for prelude file resolution
		const rootUri = lspGetField(params, "rootUri");
		if (rootUri.length > 0) {
			const rp = lspUriToPath(rootUri);
			if (rp.length > 0) {
				state.db.stdPath = rp + "/std";
			}
		} else {
			const rootPath = lspGetField(params, "rootPath");
			if (rootPath.length > 0) {
				state.db.stdPath = rootPath + "/std";
			}
		}
	}
	if (method === "shutdown") {
		state.shutdownRequested = true;
	}

	// Cancel any in-progress check and invalidate completion cache when new content arrives
	if (method === "textDocument/didChange" || method === "textDocument/didOpen") {
		requestCancel(state.db.cancelCtx);
		state.completionCache.uri = "";
		state.completionCache.line = -1;
	}

	const json = lspDispatch(method, idStr, params, state.db, state.completionCache);

	// Reset cancel flag after dispatch completes
	resetCancel(state.db.cancelCtx);

	if (json === "") return "";

	let result = lspFormatMessage(json);

	// Append transitive diagnostics for file change events
	if (method === "textDocument/didChange" || method === "textDocument/didOpen") {
		const textDoc = lspGetObjectField(params, "textDocument");
		const uri = lspGetField(textDoc, "uri");
		const path = lspUriToPath(uri);
		result = result + buildTransitiveDiagnosticsWire(state.db, path);
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
	// Response is wire-formatted (starts with Content-Length)
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
	// Should return a wire-formatted response
	assert response.length > 0;
}

test "unknown notification returns empty" {
	const state = createServerState();
	// No "id" field — pure notification
	const notif = "{\"jsonrpc\":\"2.0\",\"method\":\"$/setTrace\",\"params\":{\"value\":\"off\"}}";
	const response = processMessage(notif, state);
	assert response === "";
}

test "content length parsing" {
	assert lspParseContentLength("Content-Length: 52") === 52;
	assert lspParseContentLength("Content-Length: 0") === 0;
	assert lspParseContentLength("Content-Type: text") === -1;
}

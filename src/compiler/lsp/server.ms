// LSP Server — Main loop, I/O, URI conversion
//
// Reads JSON-RPC from stdin, dispatches to handlers, writes responses.
// I/O uses console.log for stderr logging. Actual stdin/stdout I/O
// requires ms_stdio.h (readLine, readBytes, writeStdout).
// For now, server logic is tested via pure dispatch (no I/O in tests).

import { sliceStr, charAt } from "../../utils/string";
import {
	lspParseContentLength, lspFormatMessage,
	lspGetField, lspGetNumberField, lspGetObjectField, lspJsonNumber
} from "./protocol";
import { LspDocumentStore, createDocumentStore } from "./store";
import { lspDispatch } from "./handlers";
import { readLine, readBytes, writeStdout, writeStderr } from "std/io";
import { check } from "std/testing";

// ===== Server State =====

export interface LspServerState {
	initialized: boolean;
	shutdownRequested: boolean;
	documents: LspDocumentStore;
}

export function createServerState(): LspServerState {
	return {
		initialized: false,
		shutdownRequested: false,
		documents: createDocumentStore(),
	};
}

// ===== URI Conversion =====

export function lspUriToPath(uri: string): string {
	// "file:///Users/foo/bar.ms" → "/Users/foo/bar.ms"
	const prefix = "file://";
	if (uri.length > prefix.length) {
		const uriPrefix = sliceStr(uri, 0, prefix.length);
		if (uriPrefix === prefix) {
			return sliceStr(uri, prefix.length, uri.length);
		}
	}
	return uri;
}

export function lspPathToUri(path: string): string {
	return "file://" + path;
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

		// 4. Process and respond
		const response = processMessage(body, state);
		if (response.length > 0) {
			const formatted = lspFormatMessage(response);
			writeStdout(formatted);
		}
	}

	lspLog("MetaScript LSP server exiting");
}

// ===== Message Processing =====

// Process a single JSON-RPC message. Returns the response JSON to send,
// or "" if no response needed (notifications without response).
export function processMessage(msg: string, state: LspServerState): string {
	const method = lspGetField(msg, "method");
	const idNum = lspGetNumberField(msg, "id");
	const idStr = idNum >= 0 ? lspJsonNumber(idNum) : "";
	const params = lspGetObjectField(msg, "params");

	// Track lifecycle
	if (method === "initialize") {
		state.initialized = true;
	}
	if (method === "shutdown") {
		state.shutdownRequested = true;
	}

	return lspDispatch(method, idStr, params, state.documents);
}

// ===== Tests =====
test "uri to path" { check(lspUriToPath("file:///Users/foo/bar.ms") === "/Users/foo/bar.ms"); }

test "path to uri" { check(lspPathToUri("/a/b.ms") === "file:///a/b.ms"); }

test "non-file uri unchanged" { check(lspUriToPath("http://example.com") === "http://example.com"); }

test "create state" {
	const state = createServerState();
	check(!state.initialized);
	check(!state.shutdownRequested);
}

test "initialize sets flag" {
	const state = createServerState();
	const initMsg = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}";
	const response = processMessage(initMsg, state);
	check(state.initialized);
	check(response.length > 0);
}

test "shutdown sets flag" {
	const state = createServerState();
	const shutdownMsg = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"shutdown\",\"params\":{}}";
	processMessage(shutdownMsg, state);
	check(state.shutdownRequested);
}

test "hover on unknown uri returns null result" {
	const state = createServerState();
	const hoverMsg = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":0}}}";
	const response = processMessage(hoverMsg, state);
	// Should return a valid response (null hover since doc not open)
	check(response.length > 0);
	check(lspGetNumberField(response, "id") === 3);
}

test "unknown notification returns empty" {
	const state = createServerState();
	// No "id" field — pure notification
	const notif = "{\"jsonrpc\":\"2.0\",\"method\":\"$/setTrace\",\"params\":{\"value\":\"off\"}}";
	const response = processMessage(notif, state);
	check(response === "");
}

test "content length parsing" {
	check(lspParseContentLength("Content-Length: 52") === 52);
	check(lspParseContentLength("Content-Length: 0") === 0);
	check(lspParseContentLength("Content-Type: text") === -1);
}

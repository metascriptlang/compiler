// JSON-RPC over LSP: Content-Length framing and the request, response, notification and error
// envelopes. Pure computation; the bytes move through transport.ms.

import { parseIntPrefix } from "std/core/number/parse";
import { parseJson } from "std/serialize/json/parser";
import { getDynamicField } from "std/serialize/json/accessors";
import { JsonKind, JsonValue, asInt64, asNumber, asString } from "std/serialize/json/types";
import { lspJsonString, lspJsonNumber } from "./jsonEncode";

// Parse Content-Length from a header line. Returns -1 if not a Content-Length header.
export function lspParseContentLength(headerLine: string): int32 {
	const prefix = "Content-Length: ";
	if (headerLine.byteLength <= prefix.byteLength) return -1;
	if (headerLine.slice(0, prefix.byteLength) != prefix) return -1;
	return parseIntPrefix(headerLine.slice(prefix.byteLength, headerLine.byteLength)) as int32;
}

// Format a JSON-RPC message with Content-Length header for writing.
export function lspFormatMessage(json: string): string {
	return "Content-Length: " + lspJsonNumber(json.byteLength) + "\r\n\r\n" + json;
}

export function lspIdOf(id: JsonValue): string {
	return match (id.kind) {
		JsonKind.Int => id.asInt64().toString(),
		JsonKind.Number => lspJsonNumber(id.asNumber()),
		JsonKind.String => lspJsonString(id.asString()),
		_ => "",
	};
}

// Build a JSON-RPC response: {"jsonrpc":"2.0","id":N,"result":{...}}
export function lspResponse(id: string, resultJson: string): string {
	return "{\"jsonrpc\":\"2.0\",\"id\":" + id + ",\"result\":" + resultJson + "}";
}

export function lspRequest(id: string, method: string, paramsJson: string): string {
	return "{\"jsonrpc\":\"2.0\",\"id\":" + id + ",\"method\":" + lspJsonString(method) + ",\"params\":" + paramsJson + "}";
}

// Build a JSON-RPC notification: {"jsonrpc":"2.0","method":"...","params":{...}}
export function lspNotification(method: string, paramsJson: string): string {
	return "{\"jsonrpc\":\"2.0\",\"method\":" + lspJsonString(method) + ",\"params\":" + paramsJson + "}";
}

// Build a JSON-RPC error response
export function lspErrorResponse(id: string, code: int32, message: string): string {
	return "{\"jsonrpc\":\"2.0\",\"id\":" + id + ",\"error\":{\"code\":" + lspJsonNumber(code) + ",\"message\":" + lspJsonString(message) + "}}";
}

test "parse content length" {
	assert lspParseContentLength("Content-Length: 123") == 123;
	assert lspParseContentLength("Content-Length: 0") == 0;
}

test "not content length" {
	assert lspParseContentLength("Content-Type: json") == -1;
	assert lspParseContentLength("") == -1;
}

test "format message" {
	const msg = lspFormatMessage("{\"id\":1}");
	// Should start with Content-Length header
	assert msg.slice(0, 16) == "Content-Length: ";
}

test "an id goes back as the client wrote it: number, string, or none" {
	const r = parseJson("{\"a\":7,\"b\":\"x\",\"c\":null,\"d\":1.5}");
	assert r.ok;
	if (r.ok) {
		assert lspIdOf(r.value.getDynamicField("a")) == "7";
		assert lspIdOf(r.value.getDynamicField("b")) == "\"x\"";
		assert lspIdOf(r.value.getDynamicField("c")) == "";
		assert lspIdOf(r.value.getDynamicField("d")) == "1.5";
		assert lspIdOf(r.value.getDynamicField("missing")) == "";
	}
}

test "content length ignores text after the digits" {
	assert lspParseContentLength("Content-Length: 12abc") == 12;
}

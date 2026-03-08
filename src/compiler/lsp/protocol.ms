// LSP Protocol — JSON-RPC framing + minimal JSON building/parsing
//
// Pure computation: JSON building, field extraction, message framing format.
// No I/O — actual stdin/stdout handled by server.ms.
//
// TODO: Replace hand-rolled JSON helpers with JSON.parse()/JSON.stringify()
// when the self-hosted compiler supports class codegen and object field access.
// Currently std/core/json's JsonNode has opaque object/array access (MVP limitation).

import { sliceStr, charAt } from "../../utils/string";


// ===== JSON Building =====

export function lspJsonString(val: string): string {
	// Escape special characters for JSON
	let result = "\"";
	for (let i = 0; i < val.length; i = i + 1) {
		const ch = sliceStr(val, i, i + 1);
		if (ch === "\\") { result = result + "\\\\"; }
		else if (ch === "\"") { result = result + "\\\""; }
		else if (ch === "\n") { result = result + "\\n"; }
		else if (ch === "\r") { result = result + "\\r"; }
		else if (ch === "\t") { result = result + "\\t"; }
		else { result = result + ch; }
	}
	result = result + "\"";
	return result;
}

export function lspJsonNumber(val: number): string {
	return "" + val;
}

export function lspJsonBool(val: boolean): string {
	if (val) return "true";
	return "false";
}

export function lspJsonNull(): string {
	return "null";
}

// ===== JSON Field Extraction =====

// Find a simple string value for a key in a JSON object.
// Scans for "key":"value" pattern. Returns the unescaped value string.
// Returns "" if not found.
//
// Uses segment-based extraction: bulk-copies non-escaped segments via sliceStr,
// only splitting at escape sequences. O(n) for strings without escapes,
// O(n * k/n) = O(k) concat ops where k = number of escape sequences.
export function lspGetField(json: string, field: string): string {
	// Build the search pattern: "field":
	const pattern = "\"" + field + "\":";
	const patLen = pattern.length;

	for (let i = 0; i + patLen <= json.length; i = i + 1) {
		const candidate = sliceStr(json, i, i + patLen);
		if (candidate === pattern) {
			// Skip whitespace after colon
			let j = i + patLen;
			while (j < json.length && (charAt(json, j) === " " || charAt(json, j) === "\t")) { j = j + 1; }
			// Expect opening quote for string value
			if (j >= json.length || charAt(json, j) !== "\"") continue;
			j = j + 1;  // skip opening quote

			// Fast path: scan for end quote, check if any escapes exist
			let hasEscapes = false;
			let endPos = j;
			while (endPos < json.length) {
				const c = charAt(json, endPos);
				if (c === "\\") {
					hasEscapes = true;
					endPos = endPos + 2;  // skip escape pair
				} else if (c === "\"") {
					break;
				} else {
					endPos = endPos + 1;
				}
			}

			// No escapes: single sliceStr — O(1) concat
			if (!hasEscapes) {
				return sliceStr(json, j, endPos);
			}

			// Has escapes: segment-based extraction
			// Concat non-escaped segments via sliceStr, only split at \ positions
			let result = "";
			let segStart = j;
			let k = j;
			while (k < endPos) {
				const c = charAt(json, k);
				if (c === "\\") {
					// Flush segment before this escape
					if (k > segStart) {
						result = result + sliceStr(json, segStart, k);
					}
					// Decode escape
					if (k + 1 < json.length) {
						const next = charAt(json, k + 1);
						if (next === "\"") { result = result + "\""; }
						else if (next === "\\") { result = result + "\\"; }
						else if (next === "n") { result = result + "\n"; }
						else if (next === "r") { result = result + "\r"; }
						else if (next === "t") { result = result + "\t"; }
						else { result = result + next; }
						k = k + 2;
					} else {
						k = k + 1;
					}
					segStart = k;
				} else {
					k = k + 1;
				}
			}
			// Flush final segment
			if (k > segStart) {
				result = result + sliceStr(json, segStart, k);
			}
			return result;
		}
	}
	return "";
}

// Find a number value for a key in a JSON object.
// Scans for "key":number pattern. Returns -1 if not found.
export function lspGetNumberField(json: string, field: string): number {
	// Build search pattern: "field":
	const pattern = "\"" + field + "\":";
	const patLen = pattern.length;

	for (let i = 0; i + patLen <= json.length; i = i + 1) {
		const candidate = sliceStr(json, i, i + patLen);
		if (candidate === pattern) {
			// Found key. Parse digits.
			let j = i + patLen;
			// Skip whitespace
			while (j < json.length && charAt(json, j) === " ") { j = j + 1; }
			let neg = false;
			if (j < json.length && charAt(json, j) === "-") {
				neg = true;
				j = j + 1;
			}
			let result = 0;
			let found = false;
			while (j < json.length) {
				const c = charAt(json, j);
				const d = digitValue(c);
				if (d < 0) break;
				result = result * 10 + d;
				found = true;
				j = j + 1;
			}
			if (!found) return -1;
			if (neg) result = 0 - result;
			return result;
		}
	}
	return -1;
}

// Extract a nested JSON object value for a key.
// Scans for "key":{...} and returns the {...} substring.
export function lspGetObjectField(json: string, field: string): string {
	const pattern = "\"" + field + "\":";
	const patLen = pattern.length;

	for (let i = 0; i + patLen <= json.length; i = i + 1) {
		const candidate = sliceStr(json, i, i + patLen);
		if (candidate === pattern) {
			let j = i + patLen;
			// Skip whitespace
			while (j < json.length && charAt(json, j) === " ") { j = j + 1; }
			if (j < json.length && charAt(json, j) === "{") {
				// Find matching closing brace
				let depth = 0;
				let start = j;
				while (j < json.length) {
					const c = charAt(json, j);
					if (c === "{") { depth = depth + 1; }
					else if (c === "}") {
						depth = depth - 1;
						if (depth === 0) {
							return sliceStr(json, start, j + 1);
						}
					} else if (c === "\"") {
						// Skip quoted string
						j = j + 1;
						while (j < json.length && charAt(json, j) !== "\"") {
							if (charAt(json, j) === "\\") { j = j + 1; }
							j = j + 1;
						}
					}
					j = j + 1;
				}
			}
		}
	}
	return "";
}

// ===== Content-Length Framing =====

// Parse Content-Length from a header line. Returns -1 if not a Content-Length header.
export function lspParseContentLength(headerLine: string): number {
	const prefix = "Content-Length: ";
	if (headerLine.length <= prefix.length) return -1;
	const linePrefix = sliceStr(headerLine, 0, prefix.length);
	if (linePrefix !== prefix) return -1;
	const numPart = sliceStr(headerLine, prefix.length, headerLine.length);
	return parseSimpleInt(numPart);
}

// Format a JSON-RPC message with Content-Length header for writing.
export function lspFormatMessage(json: string): string {
	return "Content-Length: " + lspJsonNumber(json.length) + "\r\n\r\n" + json;
}

// ===== Helpers =====

function digitValue(c: string): number {
	return match (c) {
		"0" => 0, "1" => 1, "2" => 2, "3" => 3, "4" => 4,
		"5" => 5, "6" => 6, "7" => 7, "8" => 8, "9" => 9,
		_ => -1,
	};
}

function parseSimpleInt(s: string): number {
	let result = 0;
	for (let i = 0; i < s.length; i = i + 1) {
		const c = charAt(s, i);
		const d = digitValue(c);
		if (d < 0) break;
		result = result * 10 + d;
	}
	return result;
}

// ===== JSON Response Builders =====

// Build a JSON-RPC response: {"jsonrpc":"2.0","id":N,"result":{...}}
export function lspResponse(id: string, resultJson: string): string {
	return "{\"jsonrpc\":\"2.0\",\"id\":" + id + ",\"result\":" + resultJson + "}";
}

// Build a JSON-RPC notification: {"jsonrpc":"2.0","method":"...","params":{...}}
export function lspNotification(method: string, paramsJson: string): string {
	return "{\"jsonrpc\":\"2.0\",\"method\":" + lspJsonString(method) + ",\"params\":" + paramsJson + "}";
}

// Build a JSON-RPC error response
export function lspErrorResponse(id: string, code: number, message: string): string {
	return "{\"jsonrpc\":\"2.0\",\"id\":" + id + ",\"error\":{\"code\":" + lspJsonNumber(code) + ",\"message\":" + lspJsonString(message) + "}}";
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

// ===== Path Helpers =====

// Extract directory from a path: "/a/b/c.ms" → "/a/b"
export function lspDirname(path: string): string {
	let lastSlash = -1;
	for (let i = 0; i < path.length; i = i + 1) {
		if (charAt(path, i) === "/") lastSlash = i;
	}
	if (lastSlash <= 0) return "/";
	return sliceStr(path, 0, lastSlash);
}

// Resolve a relative import specifier against a base file path.
// Handles "./foo", "../bar", "../../baz". Auto-appends ".ms" if missing.
// Returns "" for non-relative imports (std/*, bare module names).
export function lspResolveImport(basePath: string, importSpec: string): string {
	if (importSpec.length === 0) return "";
	// Must start with "./" or "../" to be relative
	if (charAt(importSpec, 0) !== ".") return "";
	if (importSpec.length < 2) return "";
	const second = charAt(importSpec, 1);
	if (second !== "/" && second !== ".") return "";

	let dir = lspDirname(basePath);
	let spec = importSpec;

	// Process "../" prefixes
	while (spec.length >= 3 && sliceStr(spec, 0, 3) === "../") {
		dir = lspDirname(dir);
		spec = sliceStr(spec, 3, spec.length);
	}
	// Process "./" prefix
	if (spec.length >= 2 && sliceStr(spec, 0, 2) === "./") {
		spec = sliceStr(spec, 2, spec.length);
	}

	let result = dir + "/" + spec;
	// Auto-append .ms if not already present
	if (result.length < 3 || sliceStr(result, result.length - 3, result.length) !== ".ms") {
		result = result + ".ms";
	}
	return result;
}

// ===== Tests =====
test "uri to path" { assert lspUriToPath("file:///Users/foo/bar.ms") === "/Users/foo/bar.ms"; }

test "path to uri" { assert lspPathToUri("/a/b.ms") === "file:///a/b.ms"; }

test "non-file uri unchanged" { assert lspUriToPath("http://example.com") === "http://example.com"; }

test "simple string" { assert lspJsonString("hello") === "\"hello\""; }

test "escapes backslash" { assert lspJsonString("a\\b") === "\"a\\\\b\""; }

test "escapes quote" { assert lspJsonString("a\"b") === "\"a\\\"b\""; }

test "escapes newline" { assert lspJsonString("a\nb") === "\"a\\nb\""; }

test "empty string" { assert lspJsonString("") === "\"\""; }

test "number" {
	assert lspJsonNumber(42) === "42";
	assert lspJsonNumber(0) === "0";
}

test "bool true" { assert lspJsonBool(true) === "true"; }

test "bool false" { assert lspJsonBool(false) === "false"; }

test "null" { assert lspJsonNull() === "null"; }

test "extract method" {
	const json = "{\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"id\":1}";
	assert lspGetField(json, "method") === "initialize";
}

test "extract nested value" {
	const json = "{\"uri\":\"file:///a.ms\",\"text\":\"const x = 1;\"}";
	assert lspGetField(json, "uri") === "file:///a.ms";
	assert lspGetField(json, "text") === "const x = 1;";
}

test "missing field" {
	const json = "{\"a\":\"1\"}";
	assert lspGetField(json, "b") === "";
}

test "escaped value" {
	const json = "{\"msg\":\"hello\\nworld\"}";
	assert lspGetField(json, "msg") === "hello\nworld";
}

test "extract id" {
	const json = "{\"jsonrpc\":\"2.0\",\"id\":42}";
	assert lspGetNumberField(json, "id") === 42;
}

test "extract zero" {
	const json = "{\"line\":0,\"character\":5}";
	assert lspGetNumberField(json, "line") === 0;
	assert lspGetNumberField(json, "character") === 5;
}

test "missing field" {
	const json = "{\"a\":1}";
	assert lspGetNumberField(json, "b") === -1;
}

test "extract params" {
	const json = "{\"method\":\"hover\",\"params\":{\"line\":1,\"col\":5}}";
	const params = lspGetObjectField(json, "params");
	assert params === "{\"line\":1,\"col\":5}";
}

test "nested object" {
	const json = "{\"params\":{\"position\":{\"line\":0}}}";
	const params = lspGetObjectField(json, "params");
	assert params === "{\"position\":{\"line\":0}}";
}

test "missing object" {
	const json = "{\"a\":1}";
	assert lspGetObjectField(json, "b") === "";
}

test "response format" {
	const r = lspResponse("1", "{\"capabilities\":{}}");
	assert lspGetField(r, "jsonrpc") === "2.0";
	assert lspGetNumberField(r, "id") === 1;
}

test "notification format" {
	const n = lspNotification("textDocument/publishDiagnostics", "{\"uri\":\"file:///a.ms\"}");
	assert lspGetField(n, "method") === "textDocument/publishDiagnostics";
}

test "error response format" {
	const e = lspErrorResponse("1", -32601, "Method not found");
	assert lspGetNumberField(e, "id") === 1;
}

test "parse content length" {
	assert lspParseContentLength("Content-Length: 123") === 123;
	assert lspParseContentLength("Content-Length: 0") === 0;
}

test "not content length" {
	assert lspParseContentLength("Content-Type: json") === -1;
	assert lspParseContentLength("") === -1;
}

test "format message" {
	const msg = lspFormatMessage("{\"id\":1}");
	// Should start with Content-Length header
	const prefix = sliceStr(msg, 0, 16);
	assert prefix === "Content-Length: ";
}

test "dirname basic" {
	assert lspDirname("/a/b/c.ms") === "/a/b";
	assert lspDirname("/a/b.ms") === "/a";
	assert lspDirname("/a.ms") === "/";
}

test "resolve import same dir" {
	assert lspResolveImport("/a/b/c.ms", "./utils") === "/a/b/utils.ms";
	assert lspResolveImport("/a/b/c.ms", "./utils.ms") === "/a/b/utils.ms";
}

test "resolve import parent dir" {
	assert lspResolveImport("/a/b/c.ms", "../utils") === "/a/utils.ms";
	assert lspResolveImport("/a/b/c/d.ms", "../../utils") === "/a/utils.ms";
}

test "resolve import non-relative returns empty" {
	assert lspResolveImport("/a/b.ms", "std/testing") === "";
	assert lspResolveImport("/a/b.ms", "lodash") === "";
}

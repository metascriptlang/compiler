// LSP Protocol — field probes over JSON text, relative import resolution, and the facade the
// handlers import the rest of the wire vocabulary through (jsonEncode, jsonRpc, fileUri).
//
// Pure computation. No I/O — actual stdin/stdout handled by server.ms.

import { parseJson } from "std/serialize/json/parser";
import { JsonKind } from "std/serialize/json/types";
import { isDigit } from "../../lexer/chars";

export { lspJsonString, lspJsonNumber, lspJsonBool } from "./jsonEncode";
export {
	lspParseContentLength, lspFormatMessage, lspIdOf, lspResponse, lspRequest, lspNotification, lspErrorResponse,
} from "./jsonRpc";
export { lspUriToPath, lspPathToUri } from "./fileUri";

// ===== JSON Field Extraction =====

// Find a string value for a key in a JSON object. The string token goes through the shared
// JSON parser so every RFC 8259 escape decodes, which matters because LSP4IJ (IntelliJ)
// sends `=` as `\u003d` where VSCode and Neovim send it raw.
export function lspGetField(json: string, field: string): string {
	const pattern = "\"" + field + "\":";
	let pos = 0;
	while (pos < json.byteLength) {
		const i = json.indexOf(pattern, pos);
		if (i < 0) return "";
		// Skip whitespace after colon
		let j = i + pattern.byteLength;
		while (j < json.byteLength && (json.charAt(j) == " " || json.charAt(j) == "\t")) { j++; }
		// Expect opening quote for string value (skip past non-string matches like nested keys)
		if (j >= json.byteLength || json.charAt(j) != "\"") {
			pos = i + 1;
			continue;
		}
		// Scan to closing quote, handling escapes (\uXXXX is 6 chars; others 2)
		let k = j + 1;
		while (k < json.byteLength) {
			const c = json.charAt(k);
			if (c == "\\") {
				if (k + 1 < json.byteLength && json.charAt(k + 1) == "u") {
					k = k + 6;
				} else {
					k = k + 2;
				}
			} else if (c == "\"") {
				k++;
				break;
			} else {
				k++;
			}
		}
		// Hand the string token (with quotes) to the JSON parser for decoding
		const token = json.slice(j, k);
		const parsed = parseJson(token);
		if (!parsed.ok) return "";
		if (parsed.value.kind != JsonKind.String) return "";
		return parsed.value.strVal;
	}
	return "";
}

// Find a number value for a key in a JSON object.
// Uses native indexOf for O(n) pattern search. Returns -1 if not found.
export function lspGetNumberField(json: string, field: string): number {
	const pattern = "\"" + field + "\":";
	const i = json.indexOf(pattern);
	if (i < 0) return -1;
	// Found key. Parse digits.
	let j = i + pattern.byteLength;
	while (j < json.byteLength && json.charAt(j) == " ") { j++; }
	let neg = false;
	if (j < json.byteLength && json.charAt(j) == "-") {
		neg = true;
		j++;
	}
	let result = 0;
	let found = false;
	while (j < json.byteLength && isDigit(json.charCodeAt(j))) {
		result = result * 10 + (json.charCodeAt(j) - "0".code);
		found = true;
		j++;
	}
	if (!found) return -1;
	if (neg) result = 0 - result;
	return result;
}

// Extract a nested JSON object or array value for a key.
// Uses native indexOf for O(n) pattern search.
export function lspGetObjectField(json: string, field: string): string {
	const pattern = "\"" + field + "\":";
	let pos = 0;
	while (pos < json.byteLength) {
		const i = json.indexOf(pattern, pos);
		if (i < 0) return "";
		let j = i + pattern.byteLength;
		while (j < json.byteLength && json.charAt(j) == " ") { j++; }
		const opener = j < json.byteLength ? json.charAt(j) : "";
		if (opener == "{" || opener == "[") {
			const closer = opener == "{" ? "}" : "]";
			// Find matching closing delimiter
			let depth = 0;
			let start = j;
			while (j < json.byteLength) {
				const c = json.charAt(j);
				if (c == opener) { depth++; }
				else if (c == closer) {
					depth--;
					if (depth == 0) {
						return json.slice(start, j + 1);
					}
				} else if (c == "\"") {
					// Skip quoted string
					j++;
					while (j < json.byteLength && json.charAt(j) != "\"") {
						if (json.charAt(j) == "\\") { j++; }
						j++;
					}
				}
				j++;
			}
		}
		pos = i + 1;
	}
	return "";
}

export function lspGetBoolField(json: string, field: string): boolean {
	const pattern = "\"" + field + "\":";
	const i = json.indexOf(pattern);
	if (i < 0) return false;
	let j = i + pattern.byteLength;
	while (j < json.byteLength && json.charAt(j) == " ") { j++; }
	return json.slice(j, j + 4) == "true";
}

export function lspGetArrayItems(arrayJson: string): string[] {
	const items: string[] = [];
	let depth = 0;
	let start = -1;
	let j = 0;
	while (j < arrayJson.byteLength) {
		const c = arrayJson.charAt(j);
		if (c == "\"") {
			j++;
			while (j < arrayJson.byteLength && arrayJson.charAt(j) != "\"") {
				if (arrayJson.charAt(j) == "\\") { j++; }
				j++;
			}
		} else if (c == "{" || c == "[") {
			depth++;
			if (depth == 2 && c == "{") { start = j; }
		} else if (c == "}" || c == "]") {
			if (depth == 2 && c == "}" && start >= 0) {
				items.push(arrayJson.slice(start, j + 1));
				start = -1;
			}
			depth--;
		}
		j++;
	}
	return items;
}

// ===== Path Helpers =====

export { dirname } from "std/fs/path";
import { dirname } from "std/fs/path";

test "extract method" {
	const json = "{\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"id\":1}";
	assert lspGetField(json, "method") == "initialize";
}

test "extract nested value" {
	const json = "{\"uri\":\"file:///a.ms\",\"text\":\"const x = 1;\"}";
	assert lspGetField(json, "uri") == "file:///a.ms";
	assert lspGetField(json, "text") == "const x = 1;";
}

test "missing field" {
	const json = "{\"a\":\"1\"}";
	assert lspGetField(json, "b") == "";
}

test "escaped value" {
	const json = "{\"msg\":\"hello\\nworld\"}";
	assert lspGetField(json, "msg") == "hello\nworld";
}

test "decodes \\uXXXX escape (LSP4IJ encodes = as \\u003d)" {
	// LSP4IJ over-conservative: emits `=` as `=`. Server must decode.
	const json = "{\"text\":\"const a \\u003d 1\"}";
	assert lspGetField(json, "text") == "const a = 1";
}

test "decodes \\u with multiple escapes including arrows" {
	// (req, res) => { ... }  →  (req, res) => { ... }
	const json = "{\"text\":\"(req, res) \\u003d\\u003e {\"}";
	assert lspGetField(json, "text") == "(req, res) => {";
}

test "decodes \\b \\f \\/ escapes (full JSON spec)" {
	const json = "{\"x\":\"\\b\\f\\/\"}";
	assert lspGetField(json, "x") == "\b\f/";
}

test "decodes UTF-16 surrogate pair (emoji 😀 = U+1F600)" {
	// 😀 is the surrogate pair encoding of U+1F600
	const json = "{\"x\":\"\\uD83D\\uDE00\"}";
	const decoded = lspGetField(json, "x");
	assert decoded == fromCodePoint(128512);
}

test "extract id" {
	const json = "{\"jsonrpc\":\"2.0\",\"id\":42}";
	assert lspGetNumberField(json, "id") == 42;
}

test "extract zero" {
	const json = "{\"line\":0,\"character\":5}";
	assert lspGetNumberField(json, "line") == 0;
	assert lspGetNumberField(json, "character") == 5;
}

test "missing field" {
	const json = "{\"a\":1}";
	assert lspGetNumberField(json, "b") == -1;
}

test "extract params" {
	const json = "{\"method\":\"hover\",\"params\":{\"line\":1,\"col\":5}}";
	const params = lspGetObjectField(json, "params");
	assert params == "{\"line\":1,\"col\":5}";
}

test "nested object" {
	const json = "{\"params\":{\"position\":{\"line\":0}}}";
	const params = lspGetObjectField(json, "params");
	assert params == "{\"position\":{\"line\":0}}";
}

test "missing object" {
	const json = "{\"a\":1}";
	assert lspGetObjectField(json, "b") == "";
}

test "response format" {
	const r = lspResponse("1", "{\"capabilities\":{}}");
	assert lspGetField(r, "jsonrpc") == "2.0";
	assert lspGetNumberField(r, "id") == 1;
}

test "notification format" {
	const n = lspNotification("textDocument/publishDiagnostics", "{\"uri\":\"file:///a.ms\"}");
	assert lspGetField(n, "method") == "textDocument/publishDiagnostics";
}

test "error response format" {
	const e = lspErrorResponse("1", -32601, "Method not found");
	assert lspGetNumberField(e, "id") == 1;
}

test "dirname basic" {
	assert dirname("/a/b/c.ms") == "/a/b";
	assert dirname("/a/b.ms") == "/a";
	assert dirname("/a.ms") == "/";
}

test "bool field reads true only" {
	assert lspGetBoolField("{\"dynamicRegistration\": true}", "dynamicRegistration");
	assert !lspGetBoolField("{\"dynamicRegistration\":false}", "dynamicRegistration");
	assert !lspGetBoolField("{}", "dynamicRegistration");
}

test "array items split top-level objects" {
	const items = lspGetArrayItems("[{\"uri\":\"file:///a}.ms\",\"type\":2},{\"uri\":\"file:///b.ms\",\"extra\":{\"x\":1}}]");
	assert items.length == 2;
	assert lspGetField(items[0], "uri") == "file:///a}.ms";
	assert lspGetField(items[1], "uri") == "file:///b.ms";
	assert lspGetArrayItems("[]").length == 0;
}

test "request carries id, method and params" {
	const r = lspRequest("\"r1\"", "client/registerCapability", "{}");
	assert lspGetField(r, "id") == "r1";
	assert lspGetField(r, "method") == "client/registerCapability";
}

test "protocol still serves the wire vocabulary the handlers import from it" {
	assert lspJsonString("a") == "\"a\"";
	assert lspFormatMessage("{}") == "Content-Length: 2\r\n\r\n{}";
	assert lspUriToPath(lspPathToUri("/a/b.ms")) == "/a/b.ms";
}

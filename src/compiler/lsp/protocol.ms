// LSP Protocol — JSON-RPC framing + minimal JSON building/parsing
//
// Pure computation: JSON building, field extraction, message framing format.
// No I/O — actual stdin/stdout handled by server.ms.

import { parseJson } from "std/serialize/json/parser";
import { JsonKind, JsonValue, asInt64, asNumber, asString } from "std/serialize/json/types";
import { getDynamicField } from "std/serialize/json/accessors";
import { digitValue, parseIntPrefix } from "std/core/number/parse";
import { isDigit } from "../../lexer/chars";


// ===== JSON Building =====

function unicodeEscape(code: int32): string {
	const hex = code.toString(16);
	return "\\u" + "0000".slice(0, 4 - hex.length) + hex;
}

export function lspJsonString(val: string): string {
	const parts: string[] = ["\""];
	let start = 0;
	for (let i = 0; i < val.length; i++) {
		const code = val.charCodeAt(i);
		const escape = match (code) {
			"\\".code => "\\\\",
			"\"".code => "\\\"",
			"\n".code => "\\n",
			"\r".code => "\\r",
			"\t".code => "\\t",
			_ => code > 127 ? unicodeEscape(code) : "",
		};
		if (escape == "") continue;
		if (start < i) parts.push(val.slice(start, i));
		parts.push(escape);
		start = i + 1;
	}
	if (start < val.length) parts.push(val.slice(start, val.length));
	parts.push("\"");
	return parts.join("");
}

export function lspJsonNumber(val: number): string {
	return "" + val;
}

export function lspJsonBool(val: boolean): string {
	if (val) return "true";
	return "false";
}

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

// ===== Content-Length Framing =====

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

// ===== JSON Response Builders =====

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

// ===== URI Conversion =====

function escapedByte(s: string, at: int32): int32 {
	if (at + 2 >= s.length || s.charAt(at) != "%") return -1;
	const hi = digitValue(s.charCodeAt(at + 1));
	const lo = digitValue(s.charCodeAt(at + 2));
	return hi < 16 && lo < 16 ? hi * 16 + lo : -1;
}

// Percent-decoding. Real clients hand us escaped URIs: the VS Code plugin sends
// `document.uri.toString()`, which escapes the Windows drive colon as `%3A` and
// every space as `%20`. Left undecoded, the drive-letter check below never fires
// and every path-keyed feature (project root, build.ms lookup) silently resolves
// against a path that exists nowhere.
//
// Escapes are UTF-8 BYTES, so a non-ASCII character arrives as a run of them
// (é = %C3%A9); decoding each byte through fromCodePoint would emit mojibake.
// Continuation bytes are folded into one code point here.
function lspPercentDecode(s: string): string {
	let out = "";
	let i = 0;
	while (i < s.length) {
		const b0 = escapedByte(s, i);
		if (b0 < 0) {
			out += s.charAt(i);
			i++;
			continue;
		}
		i += 3;
		if (b0 < 0x80) {
			out += fromCodePoint(b0);
			continue;
		}
		const need = b0 >= 0xF0 ? 3 : b0 >= 0xE0 ? 2 : b0 >= 0xC0 ? 1 : 0;
		if (need == 0) continue;
		let cp = b0 - (need == 3 ? 0xF0 : need == 2 ? 0xE0 : 0xC0);
		let ok = true;
		for (let taken = 0; taken < need; taken++) {
			const cb = escapedByte(s, i);
			if (cb < 0x80 || cb >= 0xC0) { ok = false; break; }
			cp = cp * 64 + (cb - 0x80);
			i += 3;
		}
		if (ok) out += fromCodePoint(cp);
	}
	return out;
}

export function lspUriToPath(uri: string): string {
	// "file:///Users/foo/bar.ms" → "/Users/foo/bar.ms"
	// "file:///C:/Users/foo.ms" → "C:/Users/foo.ms" (drop leading slash before drive)
	const prefix = "file://";
	if (uri.byteLength > prefix.byteLength) {
		if (uri.slice(0, prefix.byteLength) == prefix) {
			const stripped = lspPercentDecode(uri.slice(prefix.byteLength, uri.byteLength));
			// Windows: "/C:/..." → "C:/..." (RFC 8089 file URIs)
			if (stripped.length >= 3 && stripped.charAt(0) == "/" && stripped.charAt(2) == ":") {
				return stripped.slice(1, stripped.length);
			}
			return stripped;
		}
	}
	return uri;
}

export function lspPathToUri(path: string): string {
	const drive = path.length >= 2 && path.charAt(1) == ":" ? path.charAt(0).toLowerCase() : "";
	if (drive != "" && "abcdefghijklmnopqrstuvwxyz".includes(drive)) return `file:///${drive}%3A${lspPathEscape(path.slice(2, path.length))}`;
	return "file://" + lspPathEscape(path);
}

function lspPathEscape(path: string): string {
	const hex = "0123456789ABCDEF";
	let out = "";
	for (let i = 0; i < path.byteLength; i++) {
		const b = path.byteAt(i);
		const kept = (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
			|| b == "-".code || b == ".".code || b == "_".code || b == "~".code || b == "/".code;
		out = kept ? out + fromCodePoint(b) : `${out}%${hex.charAt(b >> 4)}${hex.charAt(b & 15)}`;
	}
	return out;
}

// ===== Path Helpers =====

export { dirname } from "std/fs/path";
import { dirname } from "std/fs/path";

// Resolve a relative import specifier against a base file path.
// Handles "./foo", "../bar", "../../baz". Auto-appends ".ms" if missing.
// Returns "" for non-relative imports (std/*, bare module names).
export function lspResolveImport(basePath: string, importSpec: string): string {
	if (importSpec.byteLength == 0) return "";
	// Must start with "./" or "../" to be relative
	if (importSpec.charAt(0) != ".") return "";
	if (importSpec.byteLength < 2) return "";
	const second = importSpec.charAt(1);
	if (second != "/" && second != ".") return "";

	let dir = dirname(basePath);
	let spec = importSpec;

	// Process "../" prefixes
	while (spec.byteLength >= 3 && spec.slice(0, 3) == "../") {
		dir = dirname(dir);
		spec = spec.slice(3, spec.byteLength);
	}
	// Process "./" prefix
	if (spec.byteLength >= 2 && spec.slice(0, 2) == "./") {
		spec = spec.slice(2, spec.byteLength);
	}

	const result = dir + "/" + spec;
	// Already has extension — single candidate
	if (result.endsWith(".ms") || result.endsWith(".h") || result.endsWith(".cms")) {
		return result;
	}
	// Default: append .ms
	return result + ".ms";
}

// ===== Tests =====
test "uri to path" { assert lspUriToPath("file:///Users/foo/bar.ms") == "/Users/foo/bar.ms"; }

test "path to uri" { assert lspPathToUri("/a/b.ms") == "file:///a/b.ms"; }

test "path to uri gives a windows drive as the escaped lower-case volume a client sends" {
	assert lspPathToUri("C:/Users/foo/bar.ms") == "file:///c%3A/Users/foo/bar.ms";
	assert lspPathToUri("d:/x.ms") == "file:///d%3A/x.ms";
	assert lspUriToPath(lspPathToUri("C:/x/y.ms")) == "c:/x/y.ms";
}

test "path to uri escapes every byte of a segment outside the unreserved set" {
	assert lspPathToUri("/My Docs/a#1?b.ms") == "file:///My%20Docs/a%231%3Fb.ms";
	assert lspPathToUri("C:/a b/[x]@y.ms") == "file:///c%3A/a%20b/%5Bx%5D%40y.ms";
	assert lspPathToUri("/Users/caf" + fromCodePoint(233) + "/a-b_c.~ms") == "file:///Users/caf%C3%A9/a-b_c.~ms";
	const odd = "/q/a b#c%d/e.ms";
	assert lspUriToPath(lspPathToUri(odd)) == odd;
}

test "non-file uri unchanged" { assert lspUriToPath("http://example.com") == "http://example.com"; }

test "simple string" { assert lspJsonString("hello") == "\"hello\""; }

test "escapes backslash" { assert lspJsonString("a\\b") == "\"a\\\\b\""; }

test "escapes quote" { assert lspJsonString("a\"b") == "\"a\\\"b\""; }

test "escapes newline" { assert lspJsonString("a\nb") == "\"a\\nb\""; }

test "empty string" { assert lspJsonString("") == "\"\""; }

test "number" {
	assert lspJsonNumber(42) == "42";
	assert lspJsonNumber(0) == "0";
}

test "bool true" { assert lspJsonBool(true) == "true"; }

test "bool false" { assert lspJsonBool(false) == "false"; }

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

test "dirname basic" {
	assert dirname("/a/b/c.ms") == "/a/b";
	assert dirname("/a/b.ms") == "/a";
	assert dirname("/a.ms") == "/";
}

test "resolve import same dir" {
	assert lspResolveImport("/a/b/c.ms", "./utils") == "/a/b/utils.ms";
	assert lspResolveImport("/a/b/c.ms", "./utils.ms") == "/a/b/utils.ms";
}

test "resolve import parent dir" {
	assert lspResolveImport("/a/b/c.ms", "../utils") == "/a/utils.ms";
	assert lspResolveImport("/a/b/c/d.ms", "../../utils") == "/a/utils.ms";
}

test "resolve import non-relative returns empty" {
	assert lspResolveImport("/a/b.ms", "std/testing") == "";
	assert lspResolveImport("/a/b.ms", "lodash") == "";
}

test "uri to path decodes the escaped windows drive colon" {
	// What the VS Code plugin actually sends on Windows (vscode-uri toString).
	assert lspUriToPath("file:///c%3A/Users/foo/bar.ms") == "c:/Users/foo/bar.ms";
	assert lspUriToPath("file:///C%3A/Users/foo/bar.ms") == "C:/Users/foo/bar.ms";
}

test "uri to path decodes escaped spaces" {
	assert lspUriToPath("file:///Users/My%20Docs/a.ms") == "/Users/My Docs/a.ms";
}

test "uri to path leaves an unescaped uri unchanged" {
	assert lspUriToPath("file:///C:/x/y.ms") == "C:/x/y.ms";
	assert lspUriToPath("file:///Users/foo/bar.ms") == "/Users/foo/bar.ms";
}

test "uri to path folds multi-byte utf-8 escapes into one code point" {
	// caf%C3%A9 is two escapes for ONE character; byte-wise decoding would
	// yield mojibake and a path that opens nothing.
	const p = lspUriToPath("file:///Users/caf%C3%A9/a.ms");
	assert p == "/Users/caf" + fromCodePoint(233) + "/a.ms";
}

test "uri to path keeps a literal percent that is not an escape" {
	assert lspUriToPath("file:///Users/100%pure/a.ms") == "/Users/100%pure/a.ms";
	assert lspUriToPath("file:///Users/a%zz/b.ms") == "/Users/a%zz/b.ms";
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

test "json string escapes non-ASCII as lower-case \\u units" {
	assert lspJsonString("é") == "\"\\u00e9\"";
	assert lspJsonString("a\tb") == "\"a\\tb\"";
}

test "content length ignores text after the digits" {
	assert lspParseContentLength("Content-Length: 12abc") == 12;
}

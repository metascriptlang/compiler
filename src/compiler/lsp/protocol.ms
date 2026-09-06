// LSP Protocol — JSON-RPC framing + minimal JSON building/parsing
//
// Pure computation: JSON building, field extraction, message framing format.
// No I/O — actual stdin/stdout handled by server.ms.
//
// All string methods (indexOf, charAt, slice) come from std/core/string prelude.

// String value decoding delegates to the shared JSON parser so we honour
// the full RFC 8259 escape spec (including `\uXXXX` + surrogate pairs).
// Hand-rolled escape handling here would re-implement (and inevitably
// drift from) std/core/json/parser.ms.
import { parseJson } from "std/serialize/json/parser";
import { JsonKind } from "std/serialize/json/types";


// ===== JSON Building =====

export function lspJsonString(val: string): string {
	const parts: string[] = [];
	parts.push("\"");
	let start = 0;
	let i = 0;
	while (i < val.length) {
		const code = val.charCodeAt(i);
		if (code > 127) {
			if (start < i) parts.push(val.slice(start, i));
			const hex = code.toString(16);
			parts.push("\\u");
			parts.push("0000".slice(0, 4 - hex.length));
			parts.push(hex);
			i = i + 1;
			start = i;
			continue;
		}
		const ch = val.charAt(i);
		if (ch === "\\" || ch === "\"" || ch === "\n" || ch === "\r" || ch === "\t") {
			if (start < i) parts.push(val.slice(start, i));
			parts.push(match (ch) {
				"\\" => "\\\\",
				"\"" => "\\\"",
				"\n" => "\\n",
				"\r" => "\\r",
				"\t" => "\\t",
				_ => ch,
			});
			i = i + 1;
			start = i;
			continue;
		}
		i = i + 1;
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

export function lspJsonNull(): string {
	return "null";
}

// ===== JSON Field Extraction =====

// Find a string value for a key in a JSON object.
// Uses native indexOf for O(n) pattern search to locate the field, then
// delegates to the shared `parseJson` (std/core/json) to decode the string
// token. This guarantees we honour the full RFC 8259 §7 escape spec —
// `\"  \\  \/  \b  \f  \n  \r  \t  \uXXXX` (with UTF-16 surrogate pairs) —
// without re-implementing it. LSP4IJ (IntelliJ) emits `=` as `=`, `>`
// as `>`, etc.; the bug was invisible until then because VSCode/Neovim
// send those characters raw.
export function lspGetField(json: string, field: string): string {
	const pattern = "\"" + field + "\":";
	let pos = 0;
	while (pos < json.byteLength) {
		const i = json.indexOf(pattern, pos);
		if (i < 0) return "";
		// Skip whitespace after colon
		let j = i + pattern.byteLength;
		while (j < json.byteLength && (json.charAt(j) === " " || json.charAt(j) === "\t")) { j = j + 1; }
		// Expect opening quote for string value (skip past non-string matches like nested keys)
		if (j >= json.byteLength || json.charAt(j) !== "\"") {
			pos = i + 1;
			continue;
		}
		// Scan to closing quote, handling escapes (\uXXXX is 6 chars; others 2)
		let k = j + 1;
		while (k < json.byteLength) {
			const c = json.charAt(k);
			if (c === "\\") {
				if (k + 1 < json.byteLength && json.charAt(k + 1) === "u") {
					k = k + 6;
				} else {
					k = k + 2;
				}
			} else if (c === "\"") {
				k = k + 1;
				break;
			} else {
				k = k + 1;
			}
		}
		// Hand the string token (with quotes) to the JSON parser for decoding
		const token = json.slice(j, k);
		const parsed = parseJson(token);
		if (!parsed.ok) return "";
		if (parsed.value.kind !== JsonKind.String) return "";
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
	while (j < json.byteLength && json.charAt(j) === " ") { j = j + 1; }
	let neg = false;
	if (j < json.byteLength && json.charAt(j) === "-") {
		neg = true;
		j = j + 1;
	}
	let result = 0;
	let found = false;
	while (j < json.byteLength) {
		const c = json.charAt(j);
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

// Extract a nested JSON object or array value for a key.
// Uses native indexOf for O(n) pattern search.
export function lspGetObjectField(json: string, field: string): string {
	const pattern = "\"" + field + "\":";
	let pos = 0;
	while (pos < json.byteLength) {
		const i = json.indexOf(pattern, pos);
		if (i < 0) return "";
		let j = i + pattern.byteLength;
		while (j < json.byteLength && json.charAt(j) === " ") { j = j + 1; }
		const opener = j < json.byteLength ? json.charAt(j) : "";
		if (opener === "{" || opener === "[") {
			const closer = opener === "{" ? "}" : "]";
			// Find matching closing delimiter
			let depth = 0;
			let start = j;
			while (j < json.byteLength) {
				const c = json.charAt(j);
				if (c === opener) { depth = depth + 1; }
				else if (c === closer) {
					depth = depth - 1;
					if (depth === 0) {
						return json.slice(start, j + 1);
					}
				} else if (c === "\"") {
					// Skip quoted string
					j = j + 1;
					while (j < json.byteLength && json.charAt(j) !== "\"") {
						if (json.charAt(j) === "\\") { j = j + 1; }
						j = j + 1;
					}
				}
				j = j + 1;
			}
		}
		pos = i + 1;
	}
	return "";
}

// ===== Content-Length Framing =====

// Parse Content-Length from a header line. Returns -1 if not a Content-Length header.
export function lspParseContentLength(headerLine: string): int32 {
	const prefix = "Content-Length: ";
	if (headerLine.byteLength <= prefix.byteLength) return -1;
	if (headerLine.slice(0, prefix.byteLength) !== prefix) return -1;
	const numPart = headerLine.slice(prefix.byteLength, headerLine.byteLength);
	return parseSimpleInt(numPart);
}

// Format a JSON-RPC message with Content-Length header for writing.
export function lspFormatMessage(json: string): string {
	return "Content-Length: " + lspJsonNumber(Buffer.byteLength(json)) + "\r\n\r\n" + json;
}

// ===== Helpers =====

function digitValue(c: string): int32 {
	return match (c) {
		"0" => 0, "1" => 1, "2" => 2, "3" => 3, "4" => 4,
		"5" => 5, "6" => 6, "7" => 7, "8" => 8, "9" => 9,
		_ => -1,
	};
}

function parseSimpleInt(s: string): int32 {
	let result = 0;
	for (let i = 0; i < s.byteLength; i = i + 1) {
		const d = digitValue(s.charAt(i));
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

function lspHexDigit(code: int32): int32 {
	if (code >= "0".code && code <= "9".code) return code - "0".code;
	if (code >= "a".code && code <= "f".code) return code - "a".code + 10;
	if (code >= "A".code && code <= "F".code) return code - "A".code + 10;
	return -1;
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
		const ch = s.charAt(i);
		if (ch !== "%" || i + 2 >= s.length) {
			out = out + ch;
			i = i + 1;
			continue;
		}
		const hi = lspHexDigit(s.charCodeAt(i + 1));
		const lo = lspHexDigit(s.charCodeAt(i + 2));
		if (hi < 0 || lo < 0) {
			// Not a valid escape — a literal "%" in the path.
			out = out + ch;
			i = i + 1;
			continue;
		}
		const b0 = hi * 16 + lo;
		i = i + 3;
		if (b0 < 0x80) {
			out = out + fromCodePoint(b0);
			continue;
		}
		let need = 0;
		let cp = 0;
		if (b0 >= 0xF0) { need = 3; cp = b0 - 0xF0; }
		else if (b0 >= 0xE0) { need = 2; cp = b0 - 0xE0; }
		else if (b0 >= 0xC0) { need = 1; cp = b0 - 0xC0; }
		else { continue; }
		let taken = 0;
		let ok = true;
		while (taken < need) {
			if (i + 2 >= s.length || s.charAt(i) !== "%") { ok = false; break; }
			const chi = lspHexDigit(s.charCodeAt(i + 1));
			const clo = lspHexDigit(s.charCodeAt(i + 2));
			if (chi < 0 || clo < 0) { ok = false; break; }
			const cb = chi * 16 + clo;
			if (cb < 0x80 || cb >= 0xC0) { ok = false; break; }
			cp = cp * 64 + (cb - 0x80);
			i = i + 3;
			taken = taken + 1;
		}
		if (ok) out = out + fromCodePoint(cp);
	}
	return out;
}

export function lspUriToPath(uri: string): string {
	// "file:///Users/foo/bar.ms" → "/Users/foo/bar.ms"
	// "file:///C:/Users/foo.ms" → "C:/Users/foo.ms" (drop leading slash before drive)
	const prefix = "file://";
	if (uri.byteLength > prefix.byteLength) {
		if (uri.slice(0, prefix.byteLength) === prefix) {
			const stripped = lspPercentDecode(uri.slice(prefix.byteLength, uri.byteLength));
			// Windows: "/C:/..." → "C:/..." (RFC 8089 file URIs)
			if (stripped.length >= 3 && stripped.charAt(0) === "/" && stripped.charAt(2) === ":") {
				return stripped.slice(1, stripped.length);
			}
			return stripped;
		}
	}
	return uri;
}

export function lspPathToUri(path: string): string {
	return "file://" + path;
}

// ===== Path Helpers =====

// Re-export from std/fs/path so LSP handlers have one canonical path API.
// (Historical `lspDirname` only split on "/"; replaced with the cross-platform
// variant that accepts both "/" and "\\".) LSP handlers import `dirname` from
// here; resolveImport below also uses it directly.
import { dirname as _dirname } from "std/fs/path";
export function dirname(p: string): string { return _dirname(p); }

// Resolve a relative import specifier against a base file path.
// Handles "./foo", "../bar", "../../baz". Auto-appends ".ms" if missing.
// Returns "" for non-relative imports (std/*, bare module names).
export function lspResolveImport(basePath: string, importSpec: string): string {
	if (importSpec.byteLength === 0) return "";
	// Must start with "./" or "../" to be relative
	if (importSpec.charAt(0) !== ".") return "";
	if (importSpec.byteLength < 2) return "";
	const second = importSpec.charAt(1);
	if (second !== "/" && second !== ".") return "";

	let dir = dirname(basePath);
	let spec = importSpec;

	// Process "../" prefixes
	while (spec.byteLength >= 3 && spec.slice(0, 3) === "../") {
		dir = dirname(dir);
		spec = spec.slice(3, spec.byteLength);
	}
	// Process "./" prefix
	if (spec.byteLength >= 2 && spec.slice(0, 2) === "./") {
		spec = spec.slice(2, spec.byteLength);
	}

	const result = dir + "/" + spec;
	// Already has extension — single candidate
	if (result.endsWith(".ms") || result.endsWith(".h") || result.endsWith(".cms")) {
		return result;
	}
	// Default: append .ms (callers use lspResolveImportCandidates for full fallback)
	return result + ".ms";
}

// Resolve relative import to candidate paths: spec.ms, spec/index.ms, spec.cms, spec/index.cms.
// Used by LSP and TransAm for directory-style imports (e.g., "./platform/sdl" → "sdl/index.ms").
export function lspResolveImportCandidates(basePath: string, importSpec: string): string[] {
	const first = lspResolveImport(basePath, importSpec);
	if (first === "") return [];
	// Already has extension — single candidate
	if (importSpec.endsWith(".ms") || importSpec.endsWith(".h") || importSpec.endsWith(".cms")) {
		return [first];
	}
	// Bare specifier: try .ms, /index.ms, .cms, /index.cms
	const base = first.endsWith(".ms") ? first.slice(0, first.length - 3) : first;
	return [base + ".ms", base + "/index.ms", base + ".cms", base + "/index.cms"];
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

test "decodes \\uXXXX escape (LSP4IJ encodes = as \\u003d)" {
	// LSP4IJ over-conservative: emits `=` as `=`. Server must decode.
	const json = "{\"text\":\"const a \\u003d 1\"}";
	assert lspGetField(json, "text") === "const a = 1";
}

test "decodes \\u with multiple escapes including arrows" {
	// (req, res) => { ... }  →  (req, res) => { ... }
	const json = "{\"text\":\"(req, res) \\u003d\\u003e {\"}";
	assert lspGetField(json, "text") === "(req, res) => {";
}

test "decodes \\b \\f \\/ escapes (full JSON spec)" {
	const json = "{\"x\":\"\\b\\f\\/\"}";
	assert lspGetField(json, "x") === "\b\f/";
}

test "decodes UTF-16 surrogate pair (emoji 😀 = U+1F600)" {
	// 😀 is the surrogate pair encoding of U+1F600
	const json = "{\"x\":\"\\uD83D\\uDE00\"}";
	const decoded = lspGetField(json, "x");
	assert decoded === fromCodePoint(128512);
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
	assert msg.slice(0, 16) === "Content-Length: ";
}

test "dirname basic" {
	assert dirname("/a/b/c.ms") === "/a/b";
	assert dirname("/a/b.ms") === "/a";
	assert dirname("/a.ms") === "/";
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

test "uri to path decodes the escaped windows drive colon" {
	// What the VS Code plugin actually sends on Windows (vscode-uri toString).
	assert lspUriToPath("file:///c%3A/Users/foo/bar.ms") === "c:/Users/foo/bar.ms";
	assert lspUriToPath("file:///C%3A/Users/foo/bar.ms") === "C:/Users/foo/bar.ms";
}

test "uri to path decodes escaped spaces" {
	assert lspUriToPath("file:///Users/My%20Docs/a.ms") === "/Users/My Docs/a.ms";
}

test "uri to path leaves an unescaped uri unchanged" {
	assert lspUriToPath("file:///C:/x/y.ms") === "C:/x/y.ms";
	assert lspUriToPath("file:///Users/foo/bar.ms") === "/Users/foo/bar.ms";
}

test "uri to path folds multi-byte utf-8 escapes into one code point" {
	// caf%C3%A9 is two escapes for ONE character; byte-wise decoding would
	// yield mojibake and a path that opens nothing.
	const p = lspUriToPath("file:///Users/caf%C3%A9/a.ms");
	assert p === "/Users/caf" + fromCodePoint(233) + "/a.ms";
}

test "uri to path keeps a literal percent that is not an escape" {
	assert lspUriToPath("file:///Users/100%pure/a.ms") === "/Users/100%pure/a.ms";
	assert lspUriToPath("file:///Users/a%zz/b.ms") === "/Users/a%zz/b.ms";
}

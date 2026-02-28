// LSP Protocol — JSON-RPC framing + minimal JSON building/parsing
//
// Pure computation: JSON building, field extraction, message framing format.
// No I/O — actual stdin/stdout handled by server.ms.
//
// TODO: Replace hand-rolled JSON helpers with JSON.parse()/JSON.stringify()
// when the self-hosted compiler supports class codegen and object field access.
// Currently std/json's JsonNode has opaque object/array access (MVP limitation).

import { sliceStr, charAt } from "../../utils/string";
import { test, check, testGroup } from "std/testing";

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
export function lspGetField(json: string, field: string): string {
	// Build the search pattern: "field":"
	const pattern = "\"" + field + "\":\"";
	const patLen = pattern.length;

	for (let i = 0; i + patLen <= json.length; i = i + 1) {
		const candidate = sliceStr(json, i, i + patLen);
		if (candidate === pattern) {
			// Found key. Extract value until closing unescaped quote.
			let j = i + patLen;
			let value = "";
			while (j < json.length) {
				const c = charAt(json, j);
				if (c === "\\") {
					// Escaped character
					if (j + 1 < json.length) {
						const next = charAt(json, j + 1);
						if (next === "\"") { value = value + "\""; }
						else if (next === "\\") { value = value + "\\"; }
						else if (next === "n") { value = value + "\n"; }
						else if (next === "r") { value = value + "\r"; }
						else if (next === "t") { value = value + "\t"; }
						else { value = value + next; }
						j = j + 2;
					} else {
						j = j + 1;
					}
				} else if (c === "\"") {
					return value;
				} else {
					value = value + c;
					j = j + 1;
				}
			}
			return value;
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

// ===== Tests =====

testGroup("lspJsonString", () => {
	test("simple string", () => {
		check(lspJsonString("hello") === "\"hello\"");
	});
	test("escapes backslash", () => {
		check(lspJsonString("a\\b") === "\"a\\\\b\"");
	});
	test("escapes quote", () => {
		check(lspJsonString("a\"b") === "\"a\\\"b\"");
	});
	test("escapes newline", () => {
		check(lspJsonString("a\nb") === "\"a\\nb\"");
	});
	test("empty string", () => {
		check(lspJsonString("") === "\"\"");
	});
});

testGroup("lspJsonPrimitives", () => {
	test("number", () => {
		check(lspJsonNumber(42) === "42");
		check(lspJsonNumber(0) === "0");
	});
	test("bool true", () => {
		check(lspJsonBool(true) === "true");
	});
	test("bool false", () => {
		check(lspJsonBool(false) === "false");
	});
	test("null", () => {
		check(lspJsonNull() === "null");
	});
});

testGroup("lspGetField", () => {
	test("extract method", () => {
		const json = "{\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"id\":1}";
		check(lspGetField(json, "method") === "initialize");
	});
	test("extract nested value", () => {
		const json = "{\"uri\":\"file:///a.ms\",\"text\":\"const x = 1;\"}";
		check(lspGetField(json, "uri") === "file:///a.ms");
		check(lspGetField(json, "text") === "const x = 1;");
	});
	test("missing field", () => {
		const json = "{\"a\":\"1\"}";
		check(lspGetField(json, "b") === "");
	});
	test("escaped value", () => {
		const json = "{\"msg\":\"hello\\nworld\"}";
		check(lspGetField(json, "msg") === "hello\nworld");
	});
});

testGroup("lspGetNumberField", () => {
	test("extract id", () => {
		const json = "{\"jsonrpc\":\"2.0\",\"id\":42}";
		check(lspGetNumberField(json, "id") === 42);
	});
	test("extract zero", () => {
		const json = "{\"line\":0,\"character\":5}";
		check(lspGetNumberField(json, "line") === 0);
		check(lspGetNumberField(json, "character") === 5);
	});
	test("missing field", () => {
		const json = "{\"a\":1}";
		check(lspGetNumberField(json, "b") === -1);
	});
});

testGroup("lspGetObjectField", () => {
	test("extract params", () => {
		const json = "{\"method\":\"hover\",\"params\":{\"line\":1,\"col\":5}}";
		const params = lspGetObjectField(json, "params");
		check(params === "{\"line\":1,\"col\":5}");
	});
	test("nested object", () => {
		const json = "{\"params\":{\"position\":{\"line\":0}}}";
		const params = lspGetObjectField(json, "params");
		check(params === "{\"position\":{\"line\":0}}");
	});
	test("missing object", () => {
		const json = "{\"a\":1}";
		check(lspGetObjectField(json, "b") === "");
	});
});

testGroup("lspResponseBuilders", () => {
	test("response format", () => {
		const r = lspResponse("1", "{\"capabilities\":{}}");
		check(lspGetField(r, "jsonrpc") === "2.0");
		check(lspGetNumberField(r, "id") === 1);
	});
	test("notification format", () => {
		const n = lspNotification("textDocument/publishDiagnostics", "{\"uri\":\"file:///a.ms\"}");
		check(lspGetField(n, "method") === "textDocument/publishDiagnostics");
	});
	test("error response format", () => {
		const e = lspErrorResponse("1", -32601, "Method not found");
		check(lspGetNumberField(e, "id") === 1);
	});
});

testGroup("lspFraming", () => {
	test("parse content length", () => {
		check(lspParseContentLength("Content-Length: 123") === 123);
		check(lspParseContentLength("Content-Length: 0") === 0);
	});
	test("not content length", () => {
		check(lspParseContentLength("Content-Type: json") === -1);
		check(lspParseContentLength("") === -1);
	});
	test("format message", () => {
		const msg = lspFormatMessage("{\"id\":1}");
		// Should start with Content-Length header
		const prefix = sliceStr(msg, 0, 16);
		check(prefix === "Content-Length: ");
	});
});

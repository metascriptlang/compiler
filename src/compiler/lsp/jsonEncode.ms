// LSP JSON text: strings, numbers and booleans as they go on the wire.

import { stringify, jsonString } from "std/core/json";

export function lspJsonString(val: string): string {
	return stringify(jsonString(val));
}

export function lspJsonNumber(val: number): string {
	return "" + val;
}

export function lspJsonBool(val: boolean): string {
	if (val) return "true";
	return "false";
}

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

test "json string writes non-ASCII text as raw UTF-8" {
	assert lspJsonString("\u00e9") == "\"\u00e9\"";
	assert lspJsonString("\u{1F600}").byteLength == 6;
	assert lspJsonString("a\tb") == "\"a\\tb\"";
}

test "json string escapes every control character" {
	assert lspJsonString("a\u0008b") == "\"a\\bb\"";
	assert lspJsonString("a\u000cb") == "\"a\\fb\"";
	assert lspJsonString("a\u0000b") == "\"a\\u0000b\"";
	assert lspJsonString("a\u001fb") == "\"a\\u001fb\"";
}

test "json string escapes a lone surrogate so the frame stays valid UTF-8" {
	assert lspJsonString("a\ud800b") == "\"a\\ud800b\"";
}

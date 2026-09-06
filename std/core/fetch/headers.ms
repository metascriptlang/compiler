// HTTP Headers — Operations on HttpHeaders (parallel array storage).
// All header names stored lowercase (RFC 7230: case-insensitive).

import { HttpHeaders } from "./types";

// ===== Construction =====

export function createHeaders(): HttpHeaders {
	const names: string[] = [];
	const values: string[] = [];
	return { _names: names, _values: values };
}

// ===== Mutating =====

// Replace existing header or add new one. Name lowercased on insert.
export function setHeader(h: HttpHeaders, name: string, value: string): void {
	const key = name.toLowerCase();
	let i = 0;
	while (i < h._names.length) {
		if (h._names[i] == key) {
			h._values[i] = value;
			return;
		}
		i = i + 1;
	}
	h._names.push(key);
	h._values.push(value);
}

// Always append (for multi-value headers like Set-Cookie).
export function addHeader(h: HttpHeaders, name: string, value: string): void {
	h._names.push(name.toLowerCase());
	h._values.push(value);
}

// Remove ALL entries matching name.
export function removeHeader(h: HttpHeaders, name: string): void {
	const key = name.toLowerCase();
	const newNames: string[] = [];
	const newValues: string[] = [];
	let i = 0;
	while (i < h._names.length) {
		if (h._names[i] != key) {
			newNames.push(h._names[i]);
			newValues.push(h._values[i]);
		}
		i = i + 1;
	}
	h._names.length = 0;
	h._values.length = 0;
	let j = 0;
	while (j < newNames.length) {
		h._names.push(newNames[j]);
		h._values.push(newValues[j]);
		j = j + 1;
	}
}

// ===== Query =====

// First matching value, "" if missing.
export function getHeader(h: HttpHeaders, name: string): string {
	const key = name.toLowerCase();
	let i = 0;
	while (i < h._names.length) {
		if (h._names[i] == key) return h._values[i];
		i = i + 1;
	}
	return "";
}

export function hasHeader(h: HttpHeaders, name: string): boolean {
	const key = name.toLowerCase();
	let i = 0;
	while (i < h._names.length) {
		if (h._names[i] == key) return true;
		i = i + 1;
	}
	return false;
}

// All values for a name (multi-value support).
export function getHeaderValues(h: HttpHeaders, name: string): string[] {
	const key = name.toLowerCase();
	const result: string[] = [];
	let i = 0;
	while (i < h._names.length) {
		if (h._names[i] == key) result.push(h._values[i]);
		i = i + 1;
	}
	return result;
}

// ===== Serialization =====

// "name: value\r\n" for each entry.
export function serializeHeaders(h: HttpHeaders): string {
	let result = "";
	let i = 0;
	while (i < h._names.length) {
		result = result + h._names[i] + ": " + h._values[i] + "\r\n";
		i = i + 1;
	}
	return result;
}

// ===== HTTP-Specific Helpers =====

// Parse Content-Length header, -1 if missing.
export function getContentLength(h: HttpHeaders): int32 {
	const val = getHeader(h, "content-length");
	if (val == "") return -1;
	const n = val.parseInt();
	return n as int32;
}

// Transfer-Encoding contains "chunked"?
export function isChunked(h: HttpHeaders): boolean {
	return getHeader(h, "transfer-encoding").contains("chunked");
}

// Connection header + HTTP version default.
// HTTP/1.1 default: keep-alive. HTTP/1.0 default: close.
export function isKeepAlive(h: HttpHeaders, version: string): boolean {
	const conn = getHeader(h, "connection").toLowerCase();
	if (conn == "close") return false;
	if (conn == "keep-alive") return true;
	return version == "1.1";
}

// ===== Tests =====

test "createHeaders empty" {
	const h = createHeaders();
	assert h._names.length == 0;
	assert h._values.length == 0;
}

test "setHeader add new" {
	const h = createHeaders();
	setHeader(h, "Content-Type", "text/html");
	assert h._names.length == 1;
	assert getHeader(h, "content-type") == "text/html";
}

test "setHeader replaces existing" {
	const h = createHeaders();
	setHeader(h, "Content-Type", "text/html");
	setHeader(h, "Content-Type", "application/json");
	assert h._names.length == 1;
	assert getHeader(h, "content-type") == "application/json";
}

test "setHeader case insensitive" {
	const h = createHeaders();
	setHeader(h, "Content-Type", "text/html");
	assert getHeader(h, "CONTENT-TYPE") == "text/html";
	assert hasHeader(h, "content-type");
}

test "addHeader multi-value" {
	const h = createHeaders();
	addHeader(h, "Set-Cookie", "a=1");
	addHeader(h, "Set-Cookie", "b=2");
	assert h._names.length == 2;
	const vals = getHeaderValues(h, "Set-Cookie");
	assert vals.length == 2;
	assert vals[0] == "a=1";
	assert vals[1] == "b=2";
}

test "getHeader missing returns empty" {
	const h = createHeaders();
	assert getHeader(h, "X-Missing") == "";
}

test "hasHeader true and false" {
	const h = createHeaders();
	setHeader(h, "Host", "example.com");
	assert hasHeader(h, "Host");
	assert !hasHeader(h, "X-Missing");
}

test "removeHeader" {
	const h = createHeaders();
	setHeader(h, "Host", "example.com");
	setHeader(h, "Content-Type", "text/html");
	removeHeader(h, "Host");
	assert h._names.length == 1;
	assert !hasHeader(h, "Host");
	assert hasHeader(h, "Content-Type");
}

test "removeHeader multi-value removes all" {
	const h = createHeaders();
	addHeader(h, "Set-Cookie", "a=1");
	addHeader(h, "Set-Cookie", "b=2");
	setHeader(h, "Host", "x");
	removeHeader(h, "Set-Cookie");
	assert h._names.length == 1;
	assert hasHeader(h, "Host");
}

test "serializeHeaders" {
	const h = createHeaders();
	setHeader(h, "Host", "example.com");
	setHeader(h, "Accept", "*/*");
	const s = serializeHeaders(h);
	assert s == "host: example.com\r\naccept: */*\r\n";
}

test "getContentLength" {
	const h = createHeaders();
	assert getContentLength(h) == -1;
	setHeader(h, "Content-Length", "42");
	assert getContentLength(h) == 42;
}

test "isChunked" {
	const h = createHeaders();
	assert !isChunked(h);
	setHeader(h, "Transfer-Encoding", "chunked");
	assert isChunked(h);
}

test "isKeepAlive defaults" {
	const h = createHeaders();
	assert isKeepAlive(h, "1.1");
	assert !isKeepAlive(h, "1.0");
}

test "isKeepAlive explicit close" {
	const h = createHeaders();
	setHeader(h, "Connection", "close");
	assert !isKeepAlive(h, "1.1");
}

test "isKeepAlive explicit keep-alive" {
	const h = createHeaders();
	setHeader(h, "Connection", "keep-alive");
	assert isKeepAlive(h, "1.0");
}

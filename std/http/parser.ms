// HTTP Parser — RFC 7230 request/response line + header parsing.
// Pure MetaScript. Imports from types.ms, errors.ms, headers.ms.

import { HttpMethod, HttpHeaders, ParsedUrl, parseMethod } from "./types";
import { HttpError, invalidRequest, invalidResponse, invalidHeader } from "./errors";
import { createHeaders, addHeader } from "./headers";

// ===== Parsed Results =====

export interface ParsedRequest {
	method: HttpMethod;
	path: string;
	version: string;
	headers: HttpHeaders;
	bodyStart: int32;
}

export interface ParsedResponse {
	version: string;
	status: int32;
	statusText: string;
	headers: HttpHeaders;
	bodyStart: int32;
}

// ===== Internal Helpers =====

// Find index of "\r\n" starting from pos. Returns -1 if not found.
function findCRLF(data: string, pos: int32): int32 {
	let i = pos;
	const len = data.length - 1;
	while (i < len) {
		if (data.charCodeAt(i) === "\r".code && data.charCodeAt(i + 1) === "\n".code) {
			return i;
		}
		i = i + 1;
	}
	return -1;
}

// Find index of a single char starting from pos. Returns -1 if not found.
function findChar(data: string, ch: int32, pos: int32): int32 {
	let i = pos;
	while (i < data.length) {
		if (data.charCodeAt(i) === ch) return i;
		i = i + 1;
	}
	return -1;
}

// ===== Header Parsing =====

interface HeaderParseResult {
	endPos: int32;
}

// Parse headers from data starting at pos. Returns offset after final \r\n\r\n.
function parseHeaderBlock(data: string, pos: int32, h: HttpHeaders): Result<HeaderParseResult, HttpError> {
	let cur = pos;
	while (cur < data.length) {
		// Empty line = end of headers
		if (cur + 1 < data.length && data.charCodeAt(cur) === "\r".code && data.charCodeAt(cur + 1) === "\n".code) {
			return Result.ok({ endPos: cur + 2 });
		}
		// Find end of this header line
		const lineEnd = findCRLF(data, cur);
		if (lineEnd < 0) return Result.err(invalidHeader("unterminated header line"));

		// Find colon separator
		const colon = findChar(data, ":".code, cur);
		if (colon < 0 || colon >= lineEnd) return Result.err(invalidHeader("missing colon in header"));

		const name = data.slice(cur, colon);
		// Skip colon + optional whitespace
		let valStart = colon + 1;
		while (valStart < lineEnd && (data.charCodeAt(valStart) === " ".code || data.charCodeAt(valStart) === "\t".code)) {
			valStart = valStart + 1;
		}
		const value = data.slice(valStart, lineEnd);
		addHeader(h, name, value);

		cur = lineEnd + 2;
	}
	return Result.err(invalidHeader("headers not terminated by empty line"));
}

// ===== Version Parsing =====

interface VersionResult {
	version: string;
}

function parseHttpVersion(versionStr: string, errFn: (msg: string) => HttpError): Result<VersionResult, HttpError> {
	if (versionStr === "HTTP/1.1") return Result.ok({ version: "1.1" });
	if (versionStr === "HTTP/1.0") return Result.ok({ version: "1.0" });
	return Result.err(errFn("unsupported HTTP version: " + versionStr));
}

// ===== Request Parsing =====

export function parseRequest(data: string): Result<ParsedRequest, HttpError> {
	// Request line: METHOD SP PATH SP HTTP/x.y CRLF
	const lineEnd = findCRLF(data, 0);
	if (lineEnd < 0) return Result.err(invalidRequest("no request line terminator"));

	// First space: end of method
	const sp1 = findChar(data, " ".code, 0);
	if (sp1 < 0 || sp1 >= lineEnd) return Result.err(invalidRequest("missing method"));

	// Second space: end of path
	const sp2 = findChar(data, " ".code, sp1 + 1);
	if (sp2 < 0 || sp2 >= lineEnd) return Result.err(invalidRequest("missing path"));

	const methodStr = data.slice(0, sp1);
	const path = data.slice(sp1 + 1, sp2);
	const versionStr = data.slice(sp2 + 1, lineEnd);

	const versionResult = try parseHttpVersion(versionStr, invalidRequest);

	// Parse headers
	const headers = createHeaders();
	const headerResult = try parseHeaderBlock(data, lineEnd + 2, headers);

	return Result.ok({
		method: parseMethod(methodStr),
		path: path,
		version: versionResult.version,
		headers: headers,
		bodyStart: headerResult.endPos,
	});
}

// ===== Response Parsing =====

export function parseResponse(data: string): Result<ParsedResponse, HttpError> {
	// Status line: HTTP/x.y SP STATUS SP REASON CRLF
	const lineEnd = findCRLF(data, 0);
	if (lineEnd < 0) return Result.err(invalidResponse("no status line terminator"));

	// First space: end of version
	const sp1 = findChar(data, " ".code, 0);
	if (sp1 < 0 || sp1 >= lineEnd) return Result.err(invalidResponse("missing version"));

	// Second space: end of status code
	const sp2 = findChar(data, " ".code, sp1 + 1);
	if (sp2 < 0 || sp2 >= lineEnd) return Result.err(invalidResponse("missing status code"));

	const versionStr = data.slice(0, sp1);
	const statusStr = data.slice(sp1 + 1, sp2);
	const reasonPhrase = data.slice(sp2 + 1, lineEnd);

	const versionResult = try parseHttpVersion(versionStr, invalidResponse);

	const status = statusStr.parseInt();

	const headers = createHeaders();
	const headerResult = try parseHeaderBlock(data, lineEnd + 2, headers);

	return Result.ok({
		version: versionResult.version,
		status: status,
		statusText: reasonPhrase,
		headers: headers,
		bodyStart: headerResult.endPos,
	});
}

// ===== URL Parsing =====

export function splitPathQuery(url: string): { path: string; query: string } {
	const qmark = url.indexOf("?");
	if (qmark < 0) return { path: url, query: "" };
	return { path: url.slice(0, qmark), query: url.slice(qmark + 1, url.length) };
}

export function parseUrl(url: string): Result<ParsedUrl, HttpError> {
	let pos = 0;
	let protocol = "http";
	let defaultPort: int32 = 80;

	// Check for protocol
	if (url.startsWith("https://")) {
		protocol = "https";
		defaultPort = 443;
		pos = 8;
	} else if (url.startsWith("http://")) {
		pos = 7;
	} else {
		return Result.err(invalidRequest("unsupported protocol in URL: " + url));
	}

	// Find end of host (first / or end of string)
	let hostEnd = url.indexOf("/", pos);
	if (hostEnd < 0) hostEnd = url.length;

	const hostPart = url.slice(pos, hostEnd);

	// Check for port
	let hostname = hostPart;
	let port = defaultPort;
	const colonIdx = hostPart.indexOf(":");
	if (colonIdx >= 0) {
		hostname = hostPart.slice(0, colonIdx);
		const portStr = hostPart.slice(colonIdx + 1, hostPart.length);
		port = portStr.parseInt();
	}

	// Path + query
	let pathAndQuery = "/";
	if (hostEnd < url.length) {
		pathAndQuery = url.slice(hostEnd, url.length);
	}

	const pq = splitPathQuery(pathAndQuery);

	return Result.ok({
		protocol: protocol,
		hostname: hostname,
		port: port,
		path: pq.path,
		query: pq.query,
	});
}

// ===== Chunked Encoding =====

// Decode chunked transfer-encoding body.
// Format: hex-size\r\ndata\r\n... 0\r\n\r\n
export function decodeChunked(data: string): Result<string, HttpError> {
	let result = "";
	let pos = 0;
	while (pos < data.length) {
		// Read chunk size (hex)
		const sizeEnd = findCRLF(data, pos);
		if (sizeEnd < 0) return Result.err(invalidResponse("unterminated chunk size"));

		const sizeStr = data.slice(pos, sizeEnd);
		const chunkSize = parseHex(sizeStr);
		if (chunkSize < 0) return Result.err(invalidResponse("invalid chunk size: " + sizeStr));
		if (chunkSize === 0) return Result.ok(result);

		// Read chunk data
		const dataStart = sizeEnd + 2;
		const dataEnd = dataStart + chunkSize;
		if (dataEnd + 2 > data.length) return Result.err(invalidResponse("truncated chunk data"));

		result = result + data.slice(dataStart, dataEnd);
		pos = dataEnd + 2; // skip trailing \r\n
	}
	return Result.err(invalidResponse("chunked body not terminated"));
}

// Encode a single chunk for chunked transfer-encoding.
export function encodeChunk(data: string): string {
	return toHex(data.length) + "\r\n" + data + "\r\n";
}

// Final chunk marker.
export function encodeLastChunk(): string {
	return "0\r\n\r\n";
}

// ===== Hex Helpers =====

function parseHex(s: string): int32 {
	if (s.length === 0) return -1;
	let result: int32 = 0;
	let i = 0;
	while (i < s.length) {
		const ch = s.charCodeAt(i);
		let digit: int32 = -1;
		if (ch >= "0".code && ch <= "9".code) {
			digit = ch - "0".code;
		} else if (ch >= "a".code && ch <= "f".code) {
			digit = 10 + ch - "a".code;
		} else if (ch >= "A".code && ch <= "F".code) {
			digit = 10 + ch - "A".code;
		} else {
			return -1;
		}
		result = result * 16 + digit;
		i = i + 1;
	}
	return result;
}

function toHex(n: number): string {
	if (n === 0) return "0";
	let result = "";
	let val = n;
	while (val > 0) {
		const digit = val % 16;
		let ch = "";
		if (digit < 10) {
			ch = String(digit);
		} else {
			// a=97
			ch = fromCodePoint(97 + digit - 10);
		}
		result = ch + result;
		val = (val - digit) / 16;
	}
	return result;
}

// ===== Tests =====

// --- Request Parsing ---

test "parseRequest simple GET" {
	const data = "GET /index.html HTTP/1.1\r\nHost: example.com\r\n\r\n";
	const r = parseRequest(data);
	assert r.ok;
	assert r.value.method === HttpMethod.GET;
	assert r.value.path === "/index.html";
	assert r.value.version === "1.1";
}

test "parseRequest POST with headers" {
	const data = "POST /api/data HTTP/1.1\r\nHost: example.com\r\nContent-Length: 13\r\n\r\n{\"key\":\"val\"}";
	const r = parseRequest(data);
	assert r.ok;
	assert r.value.method === HttpMethod.POST;
	assert r.value.path === "/api/data";
	assert r.value.bodyStart === 66;
}

test "parseRequest HTTP/1.0" {
	const data = "GET / HTTP/1.0\r\nHost: old.com\r\n\r\n";
	const r = parseRequest(data);
	assert r.ok;
	assert r.value.version === "1.0";
}

test "parseRequest bad version" {
	const data = "GET / HTTP/2.0\r\n\r\n";
	const r = parseRequest(data);
	assert !r.ok;
	assert r.error.message.contains("unsupported HTTP version");
}

test "parseRequest no CRLF" {
	const r = parseRequest("GET / HTTP/1.1");
	assert !r.ok;
}

test "parseRequest multiple headers" {
	const data = "GET / HTTP/1.1\r\nHost: a.com\r\nAccept: text/html\r\nX-Custom: foo\r\n\r\n";
	const r = parseRequest(data);
	assert r.ok;
	assert r.value.headers._names.length === 3;
}

// --- Response Parsing ---

test "parseResponse 200 OK" {
	const data = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html>";
	const r = parseResponse(data);
	assert r.ok;
	assert r.value.status === 200;
	assert r.value.statusText === "OK";
	assert r.value.version === "1.1";
}

test "parseResponse 404" {
	const data = "HTTP/1.1 404 Not Found\r\n\r\n";
	const r = parseResponse(data);
	assert r.ok;
	assert r.value.status === 404;
	assert r.value.statusText === "Not Found";
}

test "parseResponse HTTP/1.0" {
	const data = "HTTP/1.0 200 OK\r\n\r\n";
	const r = parseResponse(data);
	assert r.ok;
	assert r.value.version === "1.0";
}

test "parseResponse bad version" {
	const data = "HTTP/3.0 200 OK\r\n\r\n";
	const r = parseResponse(data);
	assert !r.ok;
}

// --- URL Parsing ---

test "splitPathQuery no query" {
	const r = splitPathQuery("/api/users");
	assert r.path === "/api/users";
	assert r.query === "";
}

test "splitPathQuery with query" {
	const r = splitPathQuery("/search?q=hello&page=2");
	assert r.path === "/search";
	assert r.query === "q=hello&page=2";
}

test "parseUrl http" {
	const r = parseUrl("http://example.com/path?q=1");
	assert r.ok;
	assert r.value.protocol === "http";
	assert r.value.hostname === "example.com";
	assert r.value.port === 80;
	assert r.value.path === "/path";
	assert r.value.query === "q=1";
}

test "parseUrl https with port" {
	const r = parseUrl("https://api.example.com:8443/v1/data");
	assert r.ok;
	assert r.value.protocol === "https";
	assert r.value.hostname === "api.example.com";
	assert r.value.port === 8443;
	assert r.value.path === "/v1/data";
}

test "parseUrl no path" {
	const r = parseUrl("http://example.com");
	assert r.ok;
	assert r.value.path === "/";
	assert r.value.query === "";
}

test "parseUrl bad protocol" {
	const r = parseUrl("ftp://example.com");
	assert !r.ok;
}

// --- Chunked Encoding ---

test "decodeChunked simple" {
	const data = "5\r\nHello\r\n6\r\n World\r\n0\r\n\r\n";
	const r = decodeChunked(data);
	assert r.ok;
	assert r.value === "Hello World";
}

test "decodeChunked single chunk" {
	const data = "3\r\nabc\r\n0\r\n\r\n";
	const r = decodeChunked(data);
	assert r.ok;
	assert r.value === "abc";
}

test "decodeChunked empty" {
	const data = "0\r\n\r\n";
	const r = decodeChunked(data);
	assert r.ok;
	assert r.value === "";
}

test "encodeChunk" {
	const r = encodeChunk("Hello");
	assert r === "5\r\nHello\r\n";
}

test "encodeLastChunk" {
	assert encodeLastChunk() === "0\r\n\r\n";
}

test "toHex values" {
	assert toHex(0) === "0";
	assert toHex(10) === "a";
	assert toHex(255) === "ff";
	assert toHex(16) === "10";
}

test "parseHex values" {
	assert parseHex("0") === 0;
	assert parseHex("a") === 10;
	assert parseHex("ff") === 255;
	assert parseHex("10") === 16;
	assert parseHex("FF") === 255;
	assert parseHex("xyz") === -1;
	assert parseHex("") === -1;
}

test "header value with tab whitespace" {
	const data = "GET / HTTP/1.1\r\nX-Tab:\tvalue\r\n\r\n";
	const r = parseRequest(data);
	assert r.ok;
	assert r.value.headers._values[0] === "value";
}

test "header value with mixed whitespace" {
	const data = "GET / HTTP/1.1\r\nX-Mix:\t  spaced\r\n\r\n";
	const r = parseRequest(data);
	assert r.ok;
	assert r.value.headers._values[0] === "spaced";
}

test "parseRequest empty path" {
	const data = "GET / HTTP/1.1\r\n\r\n";
	const r = parseRequest(data);
	assert r.ok;
	assert r.value.path === "/";
	assert r.value.headers._names.length === 0;
}

test "parseResponse body offset correct" {
	const data = "HTTP/1.1 200 OK\r\n\r\nbody";
	const r = parseResponse(data);
	assert r.ok;
	assert data.slice(r.value.bodyStart, data.length) === "body";
}

test "parseUrl with query only" {
	const r = parseUrl("http://example.com/?key=val");
	assert r.ok;
	assert r.value.path === "/";
	assert r.value.query === "key=val";
}

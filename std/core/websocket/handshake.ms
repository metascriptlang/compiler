// WebSocket Handshake — RFC 6455 §4.
//
// Pure string work: build the HTTP/1.1 upgrade request, parse the 101 response,
// derive the expected Sec-WebSocket-Accept key. The actual SHA-1 + Base64
// primitives come from std/crypto via local extern bindings — the C linker
// resolves the symbols at compile time through the .cms wrapper that pulls
// in std/crypto separately.
//
// Inline tests cover the pure-string paths (request building, response parsing,
// header validation, base64 key generation). The cryptographic accept-key
// derivation is exercised in src/test/std/http/websocket.ms via the C compile
// path — the inline harness cannot run sha1 (the extern stub throws).

@include("runtime/crypto/hash.h");

import { WsError, wsHandshakeFailed, wsInvalidUrl } from "./errors";

// Local externs into std/crypto's runtime — the C link resolves these via
// the .cms wrapper that imports std/crypto.
extern function msCryptoHashString(algorithm: string, data: string, encoding: string): string;
extern function msCryptoToBase64(data: string): string;
extern function msCryptoRandomBytes(size: number): string;

// ===== Constants =====

// RFC 6455 §1.3 magic GUID — concatenated to the client key before SHA-1ing
// it to derive the Sec-WebSocket-Accept value.
export const WS_MAGIC_GUID: string = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

// RFC 6455 §4.1 mandates protocol version 13.
export const WS_VERSION: string = "13";

// ===== URL parsing — minimal ws:// only =====

export interface WsUrl {
	host: string;
	port: int32;          // defaults: 80 for ws://
	path: string;         // includes query if any; defaults to "/"
	secure: boolean;      // wss:// flag; v0 only supports ws:// (secure=false)
}

// Parse a `ws://host[:port][/path][?query]` URL. Pure string scanning — no
// regex, no allocations beyond slices. Out of scope: `wss://` (returns an
// error so callers don't accidentally send plain-text upgrades to TLS hosts).
export function parseWsUrl(url: string): Result<WsUrl, WsError> {
	const lower = url.toLowerCase();
	let scheme = "";
	let rest = "";
	if (lower.startsWith("ws://")) {
		scheme = "ws";
		rest = url.slice(5, url.length);
	} else if (lower.startsWith("wss://")) {
		// Reject for v0 — TLS not in scope, and we don't want to silently
		// downgrade to plain text.
		return Result.err(wsInvalidUrl("wss:// not supported in v0 — use ws://"));
	} else {
		return Result.err(wsInvalidUrl("URL must start with ws:// — got: " + url));
	}

	// Split host[:port] from /path. IPv6 hosts arrive as `[::1]:8080/path`
	// per RFC 3986 §3.2.2 — the brackets fence off the colons inside the
	// address. We must NOT split the path at the FIRST '/' if a closing ']'
	// hasn't appeared yet (defensive — IPv6 addresses don't contain '/' but
	// we keep the rule simple and split on the first '/' AFTER any ']').
	let hostPart = rest;
	let path = "/";
	const slashStart: int32 = rest.startsWith("[") ? findClosingBracket(rest) + 1 : 0;
	if (slashStart >= 0) {
		const slash = indexOfFrom(rest, "/", slashStart);
		if (slash >= 0) {
			hostPart = rest.slice(0, slash);
			path = rest.slice(slash, rest.length);
		}
	}
	if (hostPart.length === 0) {
		return Result.err(wsInvalidUrl("missing host: " + url));
	}

	// Split host from port. Bracket notation (`[::1]:8080`) hides the colons
	// inside the address; only the colon AFTER the closing ']' separates
	// host from port. The bracket-stripped form is what TCP connect()
	// expects (e.g. "::1" not "[::1]").
	let host = hostPart;
	let port: int32 = 80;
	if (hostPart.startsWith("[")) {
		const close = hostPart.indexOf("]");
		if (close < 0) {
			return Result.err(wsInvalidUrl("missing ']' in IPv6 host: " + url));
		}
		host = hostPart.slice(1, close);
		if (host.length === 0) {
			return Result.err(wsInvalidUrl("empty IPv6 host: " + url));
		}
		if (close + 1 < hostPart.length) {
			if (hostPart.charCodeAt(close + 1) !== ":".code) {
				return Result.err(wsInvalidUrl("expected ':' after ']' in IPv6 host: " + url));
			}
			const portStr = hostPart.slice(close + 2, hostPart.length);
			const p = parseIntStrict(portStr);
			if (p < 0) return Result.err(wsInvalidUrl("bad port: " + portStr));
			port = p;
		}
	} else {
		const colon = hostPart.indexOf(":");
		if (colon >= 0) {
			host = hostPart.slice(0, colon);
			const portStr = hostPart.slice(colon + 1, hostPart.length);
			const p = parseIntStrict(portStr);
			if (p < 0) return Result.err(wsInvalidUrl("bad port: " + portStr));
			port = p;
		}
	}

	return Result.ok({ host: host, port: port, path: path, secure: scheme === "wss" });
}

// indexOf(needle, fromIndex) — std/core/string only exposes a no-args indexOf
// extension; we need to start searching past the IPv6 closing bracket so the
// host's internal colons aren't mistaken for the host:port separator.
function indexOfFrom(s: string, needle: string, fromIdx: int32): int32 {
	if (fromIdx <= 0) return s.indexOf(needle);
	if (fromIdx >= s.length) return -1;
	const tail = s.slice(fromIdx, s.length);
	const localIdx = tail.indexOf(needle);
	if (localIdx < 0) return -1;
	return fromIdx + localIdx;
}

// Position of ']' in a bracketed-IPv6 host prefix; -1 if missing.
function findClosingBracket(s: string): int32 {
	for (let i: int32 = 0; i < s.length; i = i + 1) {
		if (s.charCodeAt(i) === "]".code) return i;
	}
	return -1;
}

// Trim leading + trailing ASCII whitespace (space, tab). RFC 7230 §3.2 says
// HTTP header values may be wrapped with optional whitespace; servers
// occasionally emit a trailing space (e.g. `Sec-WebSocket-Accept: ABC `)
// which would defeat the strict equality check against our derived hash.
function trimAsciiWs(s: string): string {
	let start: int32 = 0;
	while (start < s.length) {
		const c = s.charCodeAt(start);
		if (c !== " ".code && c !== "\t".code) break;
		start = start + 1;
	}
	let end: int32 = s.length;
	while (end > start) {
		const c = s.charCodeAt(end - 1);
		if (c !== " ".code && c !== "\t".code) break;
		end = end - 1;
	}
	if (start === 0 && end === s.length) return s;
	return s.slice(start, end);
}

// RFC 7230 §3.2.6 — many HTTP headers (Connection, Upgrade, Cache-Control, ...)
// carry comma-separated lists of tokens. Per RFC 6455 §4.1 we need to know
// whether the Connection header CONTAINS the token "upgrade" — not whether
// the entire field equals "upgrade" exactly. nginx and Cloudflare commonly
// send `Connection: Upgrade, keep-alive` to upstream, which the strict
// equality check would reject.
//
// `token` should already be lowercase. Comparison is case-insensitive on the
// list side via toLowerCase(). Whitespace around each token is trimmed.
export function commaListContainsToken(value: string, token: string): boolean {
	const lower = value.toLowerCase();
	let i: int32 = 0;
	while (i < lower.length) {
		// Skip leading whitespace + commas.
		while (i < lower.length) {
			const c = lower.charCodeAt(i);
			if (c !== " ".code && c !== "\t".code && c !== ",".code) break;
			i = i + 1;
		}
		// Read one token.
		let tokStart = i;
		while (i < lower.length) {
			const c = lower.charCodeAt(i);
			if (c === ",".code) break;
			i = i + 1;
		}
		// Strip trailing whitespace from this token.
		let tokEnd = i;
		while (tokEnd > tokStart) {
			const c = lower.charCodeAt(tokEnd - 1);
			if (c !== " ".code && c !== "\t".code) break;
			tokEnd = tokEnd - 1;
		}
		if (tokEnd > tokStart) {
			if (lower.slice(tokStart, tokEnd) === token) return true;
		}
		// Skip the comma (i already at comma or end).
		if (i < lower.length) i = i + 1;
	}
	return false;
}

// Parse a non-negative decimal integer. Returns -1 on any error.
function parseIntStrict(s: string): int32 {
	if (s.length === 0) return -1;
	let v: int32 = 0;
	let i = 0;
	while (i < s.length) {
		const c = s.charCodeAt(i);
		if (c < "0".code || c > "9".code) return -1;
		v = v * 10 + (c - "0".code);
		if (v > 65535) return -1;  // sane port cap
		i = i + 1;
	}
	return v;
}

// ===== Sec-WebSocket-Key generation =====

// Build the 24-character base64-encoded random key the client sends in
// Sec-WebSocket-Key. RFC 6455 §4.1 says it must be a fresh 16-byte random
// value, base64-encoded — server echoes it transformed in Sec-WebSocket-Accept.
//
// Native-only — runs sha1/randomBytes externs.
export function makeClientKey(): string {
	const raw = msCryptoRandomBytes(16);
	return msCryptoToBase64(raw);
}

// ===== Sec-WebSocket-Accept derivation =====

// Compute the expected Sec-WebSocket-Accept value for a given client key.
// Server should send back exactly base64(sha1(clientKey + WS_MAGIC_GUID)).
//
// Native-only — runs sha1 + toBase64 externs.
export function deriveAcceptKey(clientKey: string): string {
	return msCryptoHashString("sha1", clientKey + WS_MAGIC_GUID, "base64");
}

// ===== Upgrade request builder =====

// Build the HTTP/1.1 upgrade request as a single string ready to send().
//   url           — already parsed WsUrl
//   clientKey     — pre-generated base64 Sec-WebSocket-Key
//   subprotocols  — optional list, e.g. ["cbor"]; "" header omitted if empty
//   extraHeaders  — additional caller-supplied headers, formatted as full lines
//                   without trailing CRLF (e.g. "Authorization: Bearer xyz")
export function buildUpgradeRequest(
	url: WsUrl,
	clientKey: string,
	subprotocols: string[],
	extraHeaders: string[],
): string {
	let hostHeader = url.host;
	if (url.port !== 80) {
		hostHeader = url.host + ":" + url.port.toString();
	}

	let req = "GET " + url.path + " HTTP/1.1\r\n";
	req = req + "Host: " + hostHeader + "\r\n";
	req = req + "Upgrade: websocket\r\n";
	req = req + "Connection: Upgrade\r\n";
	req = req + "Sec-WebSocket-Key: " + clientKey + "\r\n";
	req = req + "Sec-WebSocket-Version: " + WS_VERSION + "\r\n";

	if (subprotocols.length > 0) {
		let proto = subprotocols[0];
		let i = 1;
		while (i < subprotocols.length) {
			proto = proto + ", " + subprotocols[i];
			i = i + 1;
		}
		req = req + "Sec-WebSocket-Protocol: " + proto + "\r\n";
	}

	let h = 0;
	while (h < extraHeaders.length) {
		req = req + extraHeaders[h] + "\r\n";
		h = h + 1;
	}

	req = req + "\r\n";
	return req;
}

// ===== 101 response parsing =====

export interface UpgradeResponse {
	subprotocol: string;       // negotiated; "" if server didn't pick one
	acceptKey: string;         // value of Sec-WebSocket-Accept (server-supplied)
	bodyStart: int32;          // byte offset where response body begins (any leftover after \r\n\r\n)
}

// Parse a server's HTTP/1.1 101 Switching Protocols response. Validates:
//   - status line is "HTTP/1.1 101 ..."
//   - Upgrade: websocket (case-insensitive)
//   - Connection: upgrade  (case-insensitive)
//   - Sec-WebSocket-Accept matches expectedAccept (string-equal — server must
//     compute it the same way we do)
// Returns the negotiated subprotocol (or "") and the offset of any post-headers
// payload bytes that the caller should treat as the start of the WS frame stream.
export function parse101Response(raw: string, expectedAccept: string): Result<UpgradeResponse, WsError> {
	// Find end of headers
	const headerEnd = raw.indexOf("\r\n\r\n");
	if (headerEnd < 0) {
		return Result.err(wsHandshakeFailed("response missing CRLF CRLF terminator"));
	}

	// Status line ends at first \r\n
	const firstCrlf = raw.indexOf("\r\n");
	if (firstCrlf < 0 || firstCrlf >= headerEnd) {
		return Result.err(wsHandshakeFailed("malformed status line"));
	}
	const statusLine = raw.slice(0, firstCrlf);
	if (!statusLine.startsWith("HTTP/1.1 101")) {
		return Result.err(wsHandshakeFailed("expected HTTP/1.1 101, got: " + statusLine));
	}

	// Walk header lines
	let upgradeOk = false;
	let connectionOk = false;
	let acceptKey = "";
	let subprotocol = "";

	let cursor = firstCrlf + 2;
	while (cursor < headerEnd) {
		const lineEnd = raw.indexOf("\r\n", cursor);
		if (lineEnd < 0 || lineEnd > headerEnd) break;
		const line = raw.slice(cursor, lineEnd);
		const colon = line.indexOf(":");
		if (colon > 0) {
			const name = line.slice(0, colon).toLowerCase();
			// Trim leading + trailing ASCII whitespace from the value (B4).
			// RFC 7230 §3.2 allows optional whitespace; servers occasionally
			// emit a trailing space which would defeat the strict equality
			// check against our derived Sec-WebSocket-Accept hash.
			const value = trimAsciiWs(line.slice(colon + 1, line.length));
			if (name === "upgrade") {
				// Upgrade is also a comma-list per RFC 7230, but RFC 6455 §4.1
				// requires "websocket" be present. Use the same containment
				// check for consistency with Connection.
				if (commaListContainsToken(value, "websocket")) upgradeOk = true;
			} else if (name === "connection") {
				// Multi-token: nginx/Cloudflare proxies send
				// `Connection: Upgrade, keep-alive` (B3). Token containment
				// rather than strict equality.
				if (commaListContainsToken(value, "upgrade")) connectionOk = true;
			} else if (name === "sec-websocket-accept") {
				acceptKey = value;
			} else if (name === "sec-websocket-protocol") {
				subprotocol = value;
			}
		}
		cursor = lineEnd + 2;
	}

	if (!upgradeOk) return Result.err(wsHandshakeFailed("missing or wrong Upgrade header"));
	if (!connectionOk) return Result.err(wsHandshakeFailed("missing or wrong Connection header"));
	if (acceptKey.length === 0) return Result.err(wsHandshakeFailed("missing Sec-WebSocket-Accept"));
	if (acceptKey !== expectedAccept) {
		return Result.err(wsHandshakeFailed("Sec-WebSocket-Accept mismatch — expected " + expectedAccept + ", got " + acceptKey));
	}

	return Result.ok({
		subprotocol: subprotocol,
		acceptKey: acceptKey,
		bodyStart: headerEnd + 4,
	});
}

// ===== Server-side handshake =====
//
// Inverse of buildUpgradeRequest / parse101Response. Server consumes the
// client's HTTP/1.1 upgrade request (raw HTTP bytes, headers terminated by
// CRLFCRLF) and emits the 101 Switching Protocols response. Pure string
// work — the actual accept-key derivation reuses deriveAcceptKey
// (SHA-1 + base64) above. Caller is responsible for combining the parsed
// clientKey with deriveAcceptKey and feeding the result into
// buildUpgradeResponse.

export interface UpgradeRequest {
	path: string;                // request-target from the GET line (e.g. "/socket?token=abc")
	clientKey: string;           // Sec-WebSocket-Key value, base64-encoded
	subprotocols: string[];      // client-offered subprotocols, lowercased; empty if none
	bodyStart: int32;            // byte offset where any post-headers bytes begin
}

// Parse a client's HTTP/1.1 WebSocket upgrade request. Symmetric inverse of
// parse101Response. Validates per RFC 6455 §4.1:
//   - Request-line is "GET <path> HTTP/1.1"
//   - Upgrade header contains "websocket" (RFC 7230 comma-list, case-insensitive)
//   - Connection header contains "upgrade" (RFC 7230 comma-list, case-insensitive
//     — proxies may send "Upgrade, keep-alive")
//   - Sec-WebSocket-Key is present and non-empty
//   - Sec-WebSocket-Version is "13"
//
// On success returns the parsed key + offered subprotocols + path. Caller
// passes clientKey to deriveAcceptKey, then buildUpgradeResponse, then writes
// the response back to the socket.
export function parseUpgradeRequest(raw: string): Result<UpgradeRequest, WsError> {
	const headerEnd = raw.indexOf("\r\n\r\n");
	if (headerEnd < 0) {
		return Result.err(wsHandshakeFailed("request missing CRLF CRLF terminator"));
	}
	const firstCrlf = raw.indexOf("\r\n");
	if (firstCrlf < 0 || firstCrlf >= headerEnd) {
		return Result.err(wsHandshakeFailed("malformed request line"));
	}

	// Parse request line: "GET <path> HTTP/1.1"
	const reqLine = raw.slice(0, firstCrlf);
	const sp1 = reqLine.indexOf(" ");
	if (sp1 < 0) {
		return Result.err(wsHandshakeFailed("request line missing method/path separator"));
	}
	const method = reqLine.slice(0, sp1);
	if (method !== "GET") {
		return Result.err(wsHandshakeFailed("upgrade requires GET method, got " + method));
	}
	const rest = reqLine.slice(sp1 + 1, reqLine.length);
	const sp2 = rest.indexOf(" ");
	if (sp2 < 0) {
		return Result.err(wsHandshakeFailed("request line missing path/version separator"));
	}
	const path = rest.slice(0, sp2);
	const version = rest.slice(sp2 + 1, rest.length);
	if (version !== "HTTP/1.1") {
		return Result.err(wsHandshakeFailed("upgrade requires HTTP/1.1, got " + version));
	}

	// Walk header lines.
	let upgradeOk = false;
	let connectionOk = false;
	let clientKey = "";
	let versionHeader = "";
	let subprotocols: string[] = [];

	let cursor = firstCrlf + 2;
	while (cursor < headerEnd) {
		const lineEnd = raw.indexOf("\r\n", cursor);
		if (lineEnd < 0 || lineEnd > headerEnd) break;
		const line = raw.slice(cursor, lineEnd);
		const colon = line.indexOf(":");
		if (colon > 0) {
			const name = line.slice(0, colon).toLowerCase();
			const value = trimAsciiWs(line.slice(colon + 1, line.length));
			match (name) {
				"upgrade" => { if (commaListContainsToken(value, "websocket")) upgradeOk = true; },
				"connection" => { if (commaListContainsToken(value, "upgrade")) connectionOk = true; },
				"sec-websocket-key" => { clientKey = value; },
				"sec-websocket-version" => { versionHeader = value; },
				"sec-websocket-protocol" => { subprotocols = splitCommaList(value); },
				_ => {},
			};
		}
		cursor = lineEnd + 2;
	}

	if (!upgradeOk) return Result.err(wsHandshakeFailed("missing or wrong Upgrade header"));
	if (!connectionOk) return Result.err(wsHandshakeFailed("missing or wrong Connection header"));
	if (clientKey.length === 0) return Result.err(wsHandshakeFailed("missing Sec-WebSocket-Key"));
	// RFC 6455 §4.1 — the key MUST be the base64 encoding of a 16-byte random
	// nonce. base64(16 bytes) = 22 chars + 2 padding = exactly 24 chars. Lax
	// parsing here is safe (the protocol's accept-key roundtrip catches garbage
	// end-to-end) but rejecting wrong-length keys earlier gives the caller a
	// clear handshake error instead of an opaque "accept mismatch" on the client.
	if (clientKey.length !== 24) {
		return Result.err(wsHandshakeFailed("invalid Sec-WebSocket-Key length: expected 24, got " + clientKey.length.toString()));
	}
	if (versionHeader !== WS_VERSION) {
		return Result.err(wsHandshakeFailed("unsupported Sec-WebSocket-Version: " + versionHeader));
	}

	return Result.ok({
		path: path,
		clientKey: clientKey,
		subprotocols: subprotocols,
		bodyStart: (headerEnd + 4) as int32,
	});
}

// Split an RFC 7230 comma-separated header value into trimmed lowercased tokens.
// "cbor, JSON, bincode" → ["cbor", "json", "bincode"]. Used for the offered
// subprotocols list — the same splitter pattern as commaListContainsToken,
// but materializing the list rather than membership-testing.
function splitCommaList(value: string): string[] {
	let out: string[] = [];
	const lower = value.toLowerCase();
	let i: int32 = 0;
	while (i < lower.length) {
		while (i < lower.length) {
			const c = lower.charCodeAt(i);
			if (c !== " ".code && c !== "\t".code && c !== ",".code) break;
			i = i + 1;
		}
		let start = i;
		while (i < lower.length) {
			const c = lower.charCodeAt(i);
			if (c === ",".code) break;
			i = i + 1;
		}
		let end = i;
		while (end > start) {
			const c = lower.charCodeAt(end - 1);
			if (c !== " ".code && c !== "\t".code) break;
			end = end - 1;
		}
		if (end > start) {
			out.push(lower.slice(start, end));
		}
		if (i < lower.length) i = i + 1;
	}
	return out;
}

// Build the HTTP/1.1 101 Switching Protocols response. Symmetric inverse of
// parse101Response. Caller has already derived `acceptKey` via deriveAcceptKey.
//   subprotocol   — negotiated subprotocol; "" omits the header
//   extraHeaders  — additional headers as full lines without trailing CRLF
//                   (e.g. "X-Server: photon/0.1")
export function buildUpgradeResponse(
	acceptKey: string,
	subprotocol: string,
	extraHeaders: string[],
): string {
	let resp = "HTTP/1.1 101 Switching Protocols\r\n";
	resp = resp + "Upgrade: websocket\r\n";
	resp = resp + "Connection: Upgrade\r\n";
	resp = resp + "Sec-WebSocket-Accept: " + acceptKey + "\r\n";

	if (subprotocol.length > 0) {
		resp = resp + "Sec-WebSocket-Protocol: " + subprotocol + "\r\n";
	}

	for (const header of extraHeaders) {
		resp = resp + header + "\r\n";
	}

	resp = resp + "\r\n";
	return resp;
}

// ===== Tests (pure-string only — sha1/randomBytes paths covered in src/test/std/http/websocket.ms) =====

test "parseWsUrl plain host" {
	const r = parseWsUrl("ws://example.com");
	assert r.ok;
	assert r.value.host === "example.com";
	assert r.value.port === 80;
	assert r.value.path === "/";
	assert !r.value.secure;
}

test "parseWsUrl with port" {
	const r = parseWsUrl("ws://127.0.0.1:8000");
	assert r.ok;
	assert r.value.host === "127.0.0.1";
	assert r.value.port === 8000;
	assert r.value.path === "/";
}

test "parseWsUrl with port and path" {
	const r = parseWsUrl("ws://localhost:8080/rpc");
	assert r.ok;
	assert r.value.host === "localhost";
	assert r.value.port === 8080;
	assert r.value.path === "/rpc";
}

test "parseWsUrl with path and query" {
	const r = parseWsUrl("ws://api.local/sub?room=42");
	assert r.ok;
	assert r.value.host === "api.local";
	assert r.value.port === 80;
	assert r.value.path === "/sub?room=42";
}

test "parseWsUrl rejects wss://" {
	const r = parseWsUrl("wss://example.com");
	assert !r.ok;
}

test "parseWsUrl rejects http://" {
	const r = parseWsUrl("http://example.com");
	assert !r.ok;
}

test "parseWsUrl rejects bad port" {
	const r = parseWsUrl("ws://x:abc/");
	assert !r.ok;
}

// ----- B5: IPv6 host (RFC 3986 §3.2.2 bracket notation) -----

test "parseWsUrl IPv6 loopback with port" {
	const r = parseWsUrl("ws://[::1]:8080/");
	assert r.ok;
	assert r.value.host === "::1";   // brackets stripped — TCP connect wants raw form
	assert r.value.port === 8080;
	assert r.value.path === "/";
}

test "parseWsUrl IPv6 loopback default port" {
	const r = parseWsUrl("ws://[::1]/");
	assert r.ok;
	assert r.value.host === "::1";
	assert r.value.port === 80;
}

test "parseWsUrl IPv6 with full address" {
	const r = parseWsUrl("ws://[2001:db8::1]:9000/rpc");
	assert r.ok;
	assert r.value.host === "2001:db8::1";
	assert r.value.port === 9000;
	assert r.value.path === "/rpc";
}

test "parseWsUrl IPv6 no path" {
	const r = parseWsUrl("ws://[::1]:8000");
	assert r.ok;
	assert r.value.host === "::1";
	assert r.value.port === 8000;
	assert r.value.path === "/";
}

test "parseWsUrl IPv6 rejects missing close bracket" {
	const r = parseWsUrl("ws://[::1:8080/");
	assert !r.ok;
}

test "parseWsUrl IPv6 rejects empty bracket content" {
	const r = parseWsUrl("ws://[]:8080/");
	assert !r.ok;
}

test "parseWsUrl IPv6 rejects bad char after ']'" {
	const r = parseWsUrl("ws://[::1]x8080/");
	assert !r.ok;
}

test "parseWsUrl IPv6 rejects bad port after ']'" {
	const r = parseWsUrl("ws://[::1]:bogus/");
	assert !r.ok;
}

test "buildUpgradeRequest minimal — no subprotocols, no extras" {
	const url: WsUrl = { host: "127.0.0.1", port: 8000 as int32, path: "/rpc", secure: false };
	const subs: string[] = [];
	const extras: string[] = [];
	const req = buildUpgradeRequest(url, "dGhlIHNhbXBsZSBub25jZQ==", subs, extras);
	assert req.startsWith("GET /rpc HTTP/1.1\r\n");
	assert req.indexOf("Host: 127.0.0.1:8000\r\n") >= 0;
	assert req.indexOf("Upgrade: websocket\r\n") >= 0;
	assert req.indexOf("Connection: Upgrade\r\n") >= 0;
	assert req.indexOf("Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n") >= 0;
	assert req.indexOf("Sec-WebSocket-Version: 13\r\n") >= 0;
	assert req.indexOf("Sec-WebSocket-Protocol:") < 0;  // omitted
	assert req.endsWith("\r\n\r\n");
}

test "buildUpgradeRequest omits :80 in Host header" {
	const url: WsUrl = { host: "example.com", port: 80 as int32, path: "/", secure: false };
	const subs: string[] = [];
	const extras: string[] = [];
	const req = buildUpgradeRequest(url, "K", subs, extras);
	assert req.indexOf("Host: example.com\r\n") >= 0;
	assert req.indexOf("Host: example.com:80") < 0;
}

test "buildUpgradeRequest single subprotocol" {
	const url: WsUrl = { host: "h", port: 80 as int32, path: "/", secure: false };
	const subs: string[] = ["cbor"];
	const extras: string[] = [];
	const req = buildUpgradeRequest(url, "K", subs, extras);
	assert req.indexOf("Sec-WebSocket-Protocol: cbor\r\n") >= 0;
}

test "buildUpgradeRequest multiple subprotocols comma-joined" {
	const url: WsUrl = { host: "h", port: 80 as int32, path: "/", secure: false };
	const subs: string[] = ["cbor", "json", "bincode"];
	const extras: string[] = [];
	const req = buildUpgradeRequest(url, "K", subs, extras);
	assert req.indexOf("Sec-WebSocket-Protocol: cbor, json, bincode\r\n") >= 0;
}

test "buildUpgradeRequest extra headers" {
	const url: WsUrl = { host: "h", port: 80 as int32, path: "/", secure: false };
	const subs: string[] = [];
	const extras: string[] = ["Authorization: Bearer xyz", "X-Trace-Id: abc"];
	const req = buildUpgradeRequest(url, "K", subs, extras);
	assert req.indexOf("Authorization: Bearer xyz\r\n") >= 0;
	assert req.indexOf("X-Trace-Id: abc\r\n") >= 0;
}

test "parse101Response success — RFC 6455 §1.3 sample" {
	const raw =
		"HTTP/1.1 101 Switching Protocols\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" +
		"\r\n";
	const r = parse101Response(raw, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");
	assert r.ok;
	assert r.value.subprotocol === "";
	assert r.value.acceptKey === "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=";
	assert r.value.bodyStart === raw.length;
}

test "parse101Response with subprotocol" {
	const raw =
		"HTTP/1.1 101 Switching Protocols\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Accept: ABC\r\n" +
		"Sec-WebSocket-Protocol: cbor\r\n" +
		"\r\n";
	const r = parse101Response(raw, "ABC");
	assert r.ok;
	assert r.value.subprotocol === "cbor";
}

test "parse101Response case-insensitive header names + values" {
	const raw =
		"HTTP/1.1 101 Switching Protocols\r\n" +
		"upgrade: WebSocket\r\n" +
		"CONNECTION: upgrade\r\n" +
		"Sec-WebSocket-Accept: K\r\n" +
		"\r\n";
	const r = parse101Response(raw, "K");
	assert r.ok;
}

test "parse101Response rejects non-101 status" {
	const raw =
		"HTTP/1.1 200 OK\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Accept: K\r\n" +
		"\r\n";
	const r = parse101Response(raw, "K");
	assert !r.ok;
}

test "parse101Response rejects missing Upgrade header" {
	const raw =
		"HTTP/1.1 101 Switching Protocols\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Accept: K\r\n" +
		"\r\n";
	const r = parse101Response(raw, "K");
	assert !r.ok;
}

test "parse101Response rejects accept-key mismatch" {
	const raw =
		"HTTP/1.1 101 Switching Protocols\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Accept: WRONG\r\n" +
		"\r\n";
	const r = parse101Response(raw, "EXPECTED");
	assert !r.ok;
}

test "parse101Response surfaces post-headers byte offset" {
	const headers =
		"HTTP/1.1 101 Switching Protocols\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Accept: K\r\n" +
		"\r\n";
	const trailing = "extrabytes";  // server might send the first frame piggybacked
	const raw = headers + trailing;
	const r = parse101Response(raw, "K");
	assert r.ok;
	assert r.value.bodyStart === headers.length;
	assert raw.slice(r.value.bodyStart, raw.length) === trailing;
}

// ----- B3: multi-token Connection header (proxies) -----

test "parse101Response accepts Connection: Upgrade, keep-alive (nginx/Cloudflare)" {
	const raw =
		"HTTP/1.1 101 Switching Protocols\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade, keep-alive\r\n" +
		"Sec-WebSocket-Accept: K\r\n" +
		"\r\n";
	const r = parse101Response(raw, "K");
	assert r.ok;
}

test "parse101Response accepts Connection: keep-alive, Upgrade (token order swapped)" {
	const raw =
		"HTTP/1.1 101 Switching Protocols\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: keep-alive, Upgrade\r\n" +
		"Sec-WebSocket-Accept: K\r\n" +
		"\r\n";
	const r = parse101Response(raw, "K");
	assert r.ok;
}

test "parse101Response rejects Connection without 'upgrade' token" {
	const raw =
		"HTTP/1.1 101 Switching Protocols\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: keep-alive, close\r\n" +
		"Sec-WebSocket-Accept: K\r\n" +
		"\r\n";
	const r = parse101Response(raw, "K");
	assert !r.ok;
}

test "parse101Response rejects Connection: upgrades (substring of upgrade)" {
	const raw =
		"HTTP/1.1 101 Switching Protocols\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: upgrades\r\n" +
		"Sec-WebSocket-Accept: K\r\n" +
		"\r\n";
	const r = parse101Response(raw, "K");
	assert !r.ok;
}

// ----- B4: trailing whitespace on header values -----

test "parse101Response strips trailing whitespace on Sec-WebSocket-Accept" {
	const raw =
		"HTTP/1.1 101 Switching Protocols\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Accept: ABC \r\n" +  // trailing space
		"\r\n";
	const r = parse101Response(raw, "ABC");
	assert r.ok;
	assert r.value.acceptKey === "ABC";
}

test "parse101Response strips trailing tab on header value" {
	const raw =
		"HTTP/1.1 101 Switching Protocols\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Accept: K\t\r\n" +  // trailing tab
		"\r\n";
	const r = parse101Response(raw, "K");
	assert r.ok;
}

// ----- commaListContainsToken helper -----

test "commaListContainsToken: single token exact match" {
	assert commaListContainsToken("upgrade", "upgrade");
}

test "commaListContainsToken: case-insensitive" {
	assert commaListContainsToken("Upgrade", "upgrade");
	assert commaListContainsToken("UPGRADE", "upgrade");
}

test "commaListContainsToken: comma-separated" {
	assert commaListContainsToken("Upgrade, keep-alive", "upgrade");
	assert commaListContainsToken("keep-alive, Upgrade", "upgrade");
	assert commaListContainsToken("a, b, upgrade, c", "upgrade");
}

test "commaListContainsToken: whitespace around tokens" {
	assert commaListContainsToken("  upgrade  ", "upgrade");
	assert commaListContainsToken("\tupgrade\t", "upgrade");
}

test "commaListContainsToken: rejects substring matches" {
	assert !commaListContainsToken("upgrades", "upgrade");
	assert !commaListContainsToken("notupgrade", "upgrade");
}

test "commaListContainsToken: empty value returns false" {
	assert !commaListContainsToken("", "upgrade");
}

test "commaListContainsToken: only commas returns false" {
	assert !commaListContainsToken(",,,", "upgrade");
}

test "trimAsciiWs strips both ends" {
	assert trimAsciiWs("  hi  ") === "hi";
	assert trimAsciiWs("\t\thi\t\t") === "hi";
	assert trimAsciiWs("hi") === "hi";
	assert trimAsciiWs("") === "";
	assert trimAsciiWs("   ") === "";
}

// ----- parseUpgradeRequest / buildUpgradeResponse (server-side handshake) -----

test "parseUpgradeRequest minimal valid" {
	const raw =
		"GET /socket HTTP/1.1\r\n" +
		"Host: localhost:8080\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
		"Sec-WebSocket-Version: 13\r\n" +
		"\r\n";
	const r = parseUpgradeRequest(raw);
	assert r.ok;
	assert r.value.path === "/socket";
	assert r.value.clientKey === "dGhlIHNhbXBsZSBub25jZQ==";
	assert r.value.subprotocols.length === 0;
	assert r.value.bodyStart === raw.length;
}

test "parseUpgradeRequest preserves query string in path" {
	const raw =
		"GET /socket?token=abc HTTP/1.1\r\n" +
		"Host: h\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
		"Sec-WebSocket-Version: 13\r\n" +
		"\r\n";
	const r = parseUpgradeRequest(raw);
	assert r.ok;
	assert r.value.path === "/socket?token=abc";
}

test "parseUpgradeRequest case-insensitive header names + values" {
	const raw =
		"GET / HTTP/1.1\r\n" +
		"Host: h\r\n" +
		"upgrade: WebSocket\r\n" +
		"CONNECTION: upgrade\r\n" +
		"sec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
		"Sec-WebSocket-Version: 13\r\n" +
		"\r\n";
	const r = parseUpgradeRequest(raw);
	assert r.ok;
}

test "parseUpgradeRequest accepts Connection: Upgrade, keep-alive (proxies)" {
	const raw =
		"GET / HTTP/1.1\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade, keep-alive\r\n" +
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
		"Sec-WebSocket-Version: 13\r\n" +
		"\r\n";
	const r = parseUpgradeRequest(raw);
	assert r.ok;
}

test "parseUpgradeRequest accepts Upgrade: websocket, h2c (multi-token Upgrade)" {
	const raw =
		"GET / HTTP/1.1\r\n" +
		"Upgrade: websocket, h2c\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
		"Sec-WebSocket-Version: 13\r\n" +
		"\r\n";
	const r = parseUpgradeRequest(raw);
	assert r.ok;
}

test "parseUpgradeRequest extracts subprotocols list" {
	const raw =
		"GET / HTTP/1.1\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
		"Sec-WebSocket-Version: 13\r\n" +
		"Sec-WebSocket-Protocol: cbor, JSON\r\n" +
		"\r\n";
	const r = parseUpgradeRequest(raw);
	assert r.ok;
	assert r.value.subprotocols.length === 2;
	assert r.value.subprotocols[0] === "cbor";
	assert r.value.subprotocols[1] === "json";  // lowercased
}

test "parseUpgradeRequest empty subprotocols list" {
	const raw =
		"GET / HTTP/1.1\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
		"Sec-WebSocket-Version: 13\r\n" +
		"\r\n";
	const r = parseUpgradeRequest(raw);
	assert r.ok;
	assert r.value.subprotocols.length === 0;
}

test "parseUpgradeRequest rejects non-GET method" {
	const raw =
		"POST / HTTP/1.1\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
		"Sec-WebSocket-Version: 13\r\n" +
		"\r\n";
	const r = parseUpgradeRequest(raw);
	assert !r.ok;
}

test "parseUpgradeRequest rejects HTTP/1.0" {
	const raw =
		"GET / HTTP/1.0\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
		"Sec-WebSocket-Version: 13\r\n" +
		"\r\n";
	const r = parseUpgradeRequest(raw);
	assert !r.ok;
}

test "parseUpgradeRequest rejects missing Sec-WebSocket-Key" {
	const raw =
		"GET / HTTP/1.1\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Version: 13\r\n" +
		"\r\n";
	const r = parseUpgradeRequest(raw);
	assert !r.ok;
}

test "parseUpgradeRequest rejects too-short Sec-WebSocket-Key (RFC 6455 §4.1)" {
	const raw =
		"GET / HTTP/1.1\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Key: short\r\n" +
		"Sec-WebSocket-Version: 13\r\n" +
		"\r\n";
	const r = parseUpgradeRequest(raw);
	assert !r.ok;
}

test "parseUpgradeRequest rejects too-long Sec-WebSocket-Key" {
	const raw =
		"GET / HTTP/1.1\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==EXTRA\r\n" +
		"Sec-WebSocket-Version: 13\r\n" +
		"\r\n";
	const r = parseUpgradeRequest(raw);
	assert !r.ok;
}

test "parseUpgradeRequest rejects unsupported Sec-WebSocket-Version" {
	const raw =
		"GET / HTTP/1.1\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
		"Sec-WebSocket-Version: 8\r\n" +
		"\r\n";
	const r = parseUpgradeRequest(raw);
	assert !r.ok;
}

test "parseUpgradeRequest rejects missing CRLFCRLF" {
	const raw = "GET / HTTP/1.1\r\nUpgrade: websocket\r\n";
	const r = parseUpgradeRequest(raw);
	assert !r.ok;
}

test "parseUpgradeRequest rejects missing Upgrade header" {
	const raw =
		"GET / HTTP/1.1\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
		"Sec-WebSocket-Version: 13\r\n" +
		"\r\n";
	const r = parseUpgradeRequest(raw);
	assert !r.ok;
}

test "parseUpgradeRequest rejects missing Connection header" {
	const raw =
		"GET / HTTP/1.1\r\n" +
		"Upgrade: websocket\r\n" +
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
		"Sec-WebSocket-Version: 13\r\n" +
		"\r\n";
	const r = parseUpgradeRequest(raw);
	assert !r.ok;
}

test "parseUpgradeRequest rejects Connection without 'upgrade' token" {
	const raw =
		"GET / HTTP/1.1\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: keep-alive\r\n" +
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
		"Sec-WebSocket-Version: 13\r\n" +
		"\r\n";
	const r = parseUpgradeRequest(raw);
	assert !r.ok;
}

test "parseUpgradeRequest surfaces post-headers byte offset (piggybacked frame)" {
	const headers =
		"GET / HTTP/1.1\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
		"Sec-WebSocket-Version: 13\r\n" +
		"\r\n";
	const trailing = "leftover-bytes";
	const raw = headers + trailing;
	const r = parseUpgradeRequest(raw);
	assert r.ok;
	assert r.value.bodyStart === headers.length;
	assert raw.slice(r.value.bodyStart, raw.length) === trailing;
}

test "buildUpgradeResponse minimal — no subprotocol, no extras" {
	const resp = buildUpgradeResponse("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "", []);
	assert resp.startsWith("HTTP/1.1 101 Switching Protocols\r\n");
	assert resp.indexOf("Upgrade: websocket\r\n") >= 0;
	assert resp.indexOf("Connection: Upgrade\r\n") >= 0;
	assert resp.indexOf("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n") >= 0;
	assert resp.indexOf("Sec-WebSocket-Protocol:") < 0;
	assert resp.endsWith("\r\n\r\n");
}

test "buildUpgradeResponse with negotiated subprotocol" {
	const resp = buildUpgradeResponse("K", "cbor", []);
	assert resp.indexOf("Sec-WebSocket-Protocol: cbor\r\n") >= 0;
}

test "buildUpgradeResponse with extra headers" {
	const resp = buildUpgradeResponse("K", "", ["X-Server: photon", "X-Trace-Id: abc"]);
	assert resp.indexOf("X-Server: photon\r\n") >= 0;
	assert resp.indexOf("X-Trace-Id: abc\r\n") >= 0;
}

test "buildUpgradeResponse roundtrips through parse101Response" {
	// What the server emits must be what the client successfully parses.
	const resp = buildUpgradeResponse("ABC", "", []);
	const r = parse101Response(resp, "ABC");
	assert r.ok;
	assert r.value.acceptKey === "ABC";
	assert r.value.subprotocol === "";
}

test "buildUpgradeResponse with subprotocol roundtrips through parse101Response" {
	const resp = buildUpgradeResponse("K", "cbor", []);
	const r = parse101Response(resp, "K");
	assert r.ok;
	assert r.value.subprotocol === "cbor";
}

test "splitCommaList: single token" {
	const out = splitCommaList("cbor");
	assert out.length === 1;
	assert out[0] === "cbor";
}

test "splitCommaList: multiple tokens trimmed + lowercased" {
	const out = splitCommaList("CBOR,  JSON , bincode");
	assert out.length === 3;
	assert out[0] === "cbor";
	assert out[1] === "json";
	assert out[2] === "bincode";
}

test "splitCommaList: empty" {
	const out = splitCommaList("");
	assert out.length === 0;
}

test "splitCommaList: only commas + whitespace" {
	const out = splitCommaList(" , , ,");
	assert out.length === 0;
}

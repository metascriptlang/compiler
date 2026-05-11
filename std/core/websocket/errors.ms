// WebSocket Errors — Error types for the WebSocket module.
// Zero dependencies. Self-contained enum + interface + constructors.
// Separate from HttpError because WS has its own protocol-level failure modes
// (RFC 6455 close codes, fragmentation violations, masking violations, etc.).

// ===== Error Kind =====

export enum WsErrorKind {
	ConnectionFailed,    // TCP connect / DNS / socket creation failed
	Timeout,             // recv/send timed out
	HandshakeFailed,     // server returned non-101 or invalid Sec-WebSocket-Accept
	ProtocolError,       // RFC 6455 violation (reserved opcode, server-masked frame, fragmentation rule, ...)
	PayloadTooLarge,     // frame payload exceeds the configured cap (default 16 MB)
	InvalidUrl,          // URL not parseable as ws://host[:port][/path]
	Closed,              // operation attempted on closed/closing connection
	SocketError,         // unexpected I/O error from the underlying socket
	InternalError,       // mask key generation failed, etc. — should not happen but caller must know
}

// ===== Error Interface =====

export interface WsError {
	kind: WsErrorKind;
	message: string;
}

// ===== Constructors =====

// All WS error constructors are prefixed with `ws` so they don't collide
// with the HttpError constructors of the same shape (`connectionFailed`,
// `timeout`, `socketError`, `isProtocolError`) that the std/core/fetch
// prelude already exports.

export function wsError(kind: WsErrorKind, msg: string): WsError {
	return { kind: kind, message: msg };
}

export function wsConnectionFailed(msg: string): WsError {
	return { kind: WsErrorKind.ConnectionFailed, message: msg };
}

export function wsTimeout(msg: string): WsError {
	return { kind: WsErrorKind.Timeout, message: msg };
}

export function wsHandshakeFailed(msg: string): WsError {
	return { kind: WsErrorKind.HandshakeFailed, message: msg };
}

export function wsProtocolError(msg: string): WsError {
	return { kind: WsErrorKind.ProtocolError, message: msg };
}

export function wsPayloadTooLarge(size: int32, limit: int32): WsError {
	return { kind: WsErrorKind.PayloadTooLarge, message: "payload " + size.toString() + " exceeds limit " + limit.toString() };
}

export function wsInvalidUrl(msg: string): WsError {
	return { kind: WsErrorKind.InvalidUrl, message: msg };
}

export function wsClosed(msg: string): WsError {
	return { kind: WsErrorKind.Closed, message: msg };
}

export function wsSocketError(msg: string): WsError {
	return { kind: WsErrorKind.SocketError, message: msg };
}

export function wsInternalError(msg: string): WsError {
	return { kind: WsErrorKind.InternalError, message: msg };
}

// ===== Classification =====

export function isWsProtocolError(e: WsError): boolean {
	return match (e.kind) {
		WsErrorKind.ProtocolError | WsErrorKind.HandshakeFailed | WsErrorKind.PayloadTooLarge => true,
		_ => false,
	};
}

export function isWsTransportError(e: WsError): boolean {
	return match (e.kind) {
		WsErrorKind.ConnectionFailed | WsErrorKind.Timeout | WsErrorKind.SocketError => true,
		_ => false,
	};
}

// ===== Tests =====

test "wsError constructor" {
	const e = wsError(WsErrorKind.Timeout, "timed out");
	assert e.kind === WsErrorKind.Timeout;
	assert e.message === "timed out";
}

test "wsHandshakeFailed constructor" {
	const e = wsHandshakeFailed("bad accept-key");
	assert e.kind === WsErrorKind.HandshakeFailed;
	assert e.message === "bad accept-key";
}

test "wsProtocolError constructor" {
	const e = wsProtocolError("masked server frame");
	assert e.kind === WsErrorKind.ProtocolError;
}

test "wsPayloadTooLarge message" {
	const e = wsPayloadTooLarge(20000000, 16777216);
	assert e.kind === WsErrorKind.PayloadTooLarge;
	assert e.message === "payload 20000000 exceeds limit 16777216";
}

test "wsClosed constructor" {
	const e = wsClosed("send on closed socket");
	assert e.kind === WsErrorKind.Closed;
}

test "isWsProtocolError true for protocol/handshake/payload" {
	assert isWsProtocolError(wsProtocolError("p"));
	assert isWsProtocolError(wsHandshakeFailed("h"));
	assert isWsProtocolError(wsPayloadTooLarge(10, 5));
	assert !isWsProtocolError(wsTimeout("t"));
}

test "isWsTransportError true for connection/timeout/socket" {
	assert isWsTransportError(wsConnectionFailed("c"));
	assert isWsTransportError(wsTimeout("t"));
	assert isWsTransportError(wsSocketError("s"));
	assert !isWsTransportError(wsProtocolError("p"));
}

test "wsInternalError constructor" {
	const e = wsInternalError("RNG failure");
	assert e.kind === WsErrorKind.InternalError;
	assert e.message === "RNG failure";
}

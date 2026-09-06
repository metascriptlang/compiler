// HTTP Errors — Error types for the HTTP module.
// Zero dependencies. Self-contained enum + interface + constructors.

// ===== Error Kind =====

export enum HttpErrorKind {
	ConnectionFailed,
	ConnectionReset,
	Timeout,
	DnsLookupFailed,
	InvalidRequest,
	InvalidResponse,
	InvalidHeader,
	TooManyRedirects,
	BodyTooLarge,
	SocketError,
}

// ===== Error Interface =====

export interface HttpError {
	kind: HttpErrorKind;
	message: string;
}

// ===== Constructors =====

export function httpError(kind: HttpErrorKind, msg: string): HttpError {
	return { kind: kind, message: msg };
}

export function connectionFailed(msg: string): HttpError {
	return { kind: HttpErrorKind.ConnectionFailed, message: msg };
}

export function connectionReset(msg: string): HttpError {
	return { kind: HttpErrorKind.ConnectionReset, message: msg };
}

export function timeout(msg: string): HttpError {
	return { kind: HttpErrorKind.Timeout, message: msg };
}

export function invalidRequest(msg: string): HttpError {
	return { kind: HttpErrorKind.InvalidRequest, message: msg };
}

export function invalidResponse(msg: string): HttpError {
	return { kind: HttpErrorKind.InvalidResponse, message: msg };
}

export function invalidHeader(msg: string): HttpError {
	return { kind: HttpErrorKind.InvalidHeader, message: msg };
}

export function socketError(msg: string): HttpError {
	return { kind: HttpErrorKind.SocketError, message: msg };
}

export function bodyTooLarge(size: int32, limit: int32): HttpError {
	return { kind: HttpErrorKind.BodyTooLarge, message: "body " + size.toString() + " exceeds limit " + limit.toString() };
}

export function tooManyRedirects(count: int32): HttpError {
	return { kind: HttpErrorKind.TooManyRedirects, message: "exceeded " + count.toString() + " redirects" };
}

// ===== Classification =====

export function isRetryable(e: HttpError): boolean {
	return match (e.kind) {
		HttpErrorKind.Timeout | HttpErrorKind.ConnectionReset | HttpErrorKind.ConnectionFailed => true,
		_ => false,
	};
}

export function isConnectionError(e: HttpError): boolean {
	return match (e.kind) {
		HttpErrorKind.ConnectionFailed | HttpErrorKind.ConnectionReset | HttpErrorKind.Timeout | HttpErrorKind.DnsLookupFailed | HttpErrorKind.SocketError => true,
		_ => false,
	};
}

export function isProtocolError(e: HttpError): boolean {
	return match (e.kind) {
		HttpErrorKind.InvalidRequest | HttpErrorKind.InvalidResponse | HttpErrorKind.InvalidHeader => true,
		_ => false,
	};
}

// ===== Tests =====

test "httpError constructor" {
	const e = httpError(HttpErrorKind.Timeout, "timed out");
	assert e.kind == HttpErrorKind.Timeout;
	assert e.message == "timed out";
}

test "connectionFailed constructor" {
	const e = connectionFailed("refused");
	assert e.kind == HttpErrorKind.ConnectionFailed;
}

test "bodyTooLarge message" {
	const e = bodyTooLarge(2000, 1000);
	assert e.kind == HttpErrorKind.BodyTooLarge;
	assert e.message == "body 2000 exceeds limit 1000";
}

test "tooManyRedirects message" {
	const e = tooManyRedirects(5);
	assert e.message == "exceeded 5 redirects";
}

test "isRetryable true for timeout" {
	assert isRetryable(timeout("t"));
}

test "isRetryable true for connectionReset" {
	assert isRetryable(connectionReset("r"));
}

test "isRetryable false for invalidRequest" {
	assert !isRetryable(invalidRequest("bad"));
}

test "isConnectionError" {
	assert isConnectionError(connectionFailed("f"));
	assert isConnectionError(socketError("s"));
	assert !isConnectionError(invalidRequest("bad"));
}

test "isProtocolError" {
	assert isProtocolError(invalidRequest("r"));
	assert isProtocolError(invalidResponse("r"));
	assert !isProtocolError(timeout("t"));
}

// HTTP Types — Pure type definitions for the HTTP module.
// Zero dependencies. All interfaces, enums, and helpers are self-contained.

// ===== Enums =====

export enum HttpMethod {
	GET,
	POST,
	PUT,
	DELETE,
	PATCH,
	HEAD,
	OPTIONS,
}

// ===== Core Interfaces =====

// Header storage. Operations (get/set/has/serialize) live in headers.ms.
// Parallel arrays: _names[i] corresponds to _values[i].
// All names stored lowercase (RFC 7230: headers are case-insensitive).
export interface HttpHeaders {
	_names: string[];
	_values: string[];
}

// Incoming request (server-side).
export interface HttpRequest {
	method: HttpMethod;
	path: string;
	version: string;
	headers: HttpHeaders;
	body: string;
	clientFd: int32;
}

// Response from server (client-side, immutable result).
export interface HttpResponse {
	status: int32;
	statusText: string;
	headers: HttpHeaders;
	body: string;
}

// Mutable response builder (server-side, handler fills via writeHead/write/end).
// `_upgraded` signals that the handler has taken ownership of the fd (e.g. for
// a WebSocket upgrade). When true, the HTTP event loop removes the fd from
// its selector after the current response is written and does NOT close it —
// the handler is responsible for the fd's lifecycle from that point on.
export interface ServerResponse {
	fd: int32;
	status: int32;
	headers: HttpHeaders;
	_chunks: string[];
	headersSent: boolean;
	_finished: boolean;
	_chunked: boolean;
	_responseData: string;
	_upgraded: boolean;
}

export type RequestHandler = (req: HttpRequest, res: ServerResponse) => void;
export type AsyncRequestHandler = (req: HttpRequest, res: ServerResponse) => Promise<void>;

// Client request options (http.request() equivalent).
export interface RequestOptions {
	method: HttpMethod;
	hostname: string;
	port: int32;
	path: string;
	headers: HttpHeaders;
	body: string;
	timeout: int32;
	tls: boolean;
}

// Fetch-style request options (URL-based API).
// Defaults: method="GET", timeout=30000, maxRedirects=5.
// Use timeout <= 0 for default 30s, maxRedirects < 0 for default 5.
export interface FetchOptions {
	method: string;
	body: string;
	headers: HttpHeaders;
	timeout: int32;
	maxRedirects: int32;
}

// Parsed URL components.
export interface ParsedUrl {
	protocol: string;
	hostname: string;
	port: int32;
	path: string;
	query: string;
}

// ===== Status Codes =====

export function statusText(code: int32): string {
	return match (code) {
		100 => "Continue",
		101 => "Switching Protocols",
		200 => "OK",
		201 => "Created",
		202 => "Accepted",
		204 => "No Content",
		206 => "Partial Content",
		301 => "Moved Permanently",
		302 => "Found",
		303 => "See Other",
		304 => "Not Modified",
		307 => "Temporary Redirect",
		308 => "Permanent Redirect",
		400 => "Bad Request",
		401 => "Unauthorized",
		403 => "Forbidden",
		404 => "Not Found",
		405 => "Method Not Allowed",
		408 => "Request Timeout",
		409 => "Conflict",
		411 => "Length Required",
		413 => "Payload Too Large",
		415 => "Unsupported Media Type",
		422 => "Unprocessable Entity",
		429 => "Too Many Requests",
		500 => "Internal Server Error",
		501 => "Not Implemented",
		502 => "Bad Gateway",
		503 => "Service Unavailable",
		504 => "Gateway Timeout",
		_ => "Unknown",
	};
}

// ===== Status Classification =====

export function isSuccess(status: int32): boolean {
	return status >= 200 && status < 300;
}

export function isRedirect(status: int32): boolean {
	return status >= 300 && status < 400;
}

export function isClientError(status: int32): boolean {
	return status >= 400 && status < 500;
}

export function isServerError(status: int32): boolean {
	return status >= 500 && status < 600;
}

// ===== Method Conversion =====

export function methodToString(m: HttpMethod): string {
	return match (m) {
		HttpMethod.GET => "GET",
		HttpMethod.POST => "POST",
		HttpMethod.PUT => "PUT",
		HttpMethod.DELETE => "DELETE",
		HttpMethod.PATCH => "PATCH",
		HttpMethod.HEAD => "HEAD",
		HttpMethod.OPTIONS => "OPTIONS",
		_ => "GET",
	};
}

export function parseMethod(s: string): HttpMethod {
	return match (s) {
		"GET" => HttpMethod.GET,
		"POST" => HttpMethod.POST,
		"PUT" => HttpMethod.PUT,
		"DELETE" => HttpMethod.DELETE,
		"PATCH" => HttpMethod.PATCH,
		"HEAD" => HttpMethod.HEAD,
		"OPTIONS" => HttpMethod.OPTIONS,
		_ => HttpMethod.GET,
	};
}

// ===== Tests =====

test "statusText 200" { assert statusText(200) == "OK"; }
test "statusText 404" { assert statusText(404) == "Not Found"; }
test "statusText 500" { assert statusText(500) == "Internal Server Error"; }
test "statusText unknown" { assert statusText(999) == "Unknown"; }

test "methodToString GET" { assert methodToString(HttpMethod.GET) == "GET"; }
test "methodToString POST" { assert methodToString(HttpMethod.POST) == "POST"; }
test "methodToString DELETE" { assert methodToString(HttpMethod.DELETE) == "DELETE"; }
test "methodToString OPTIONS" { assert methodToString(HttpMethod.OPTIONS) == "OPTIONS"; }

test "parseMethod GET" { assert parseMethod("GET") == HttpMethod.GET; }
test "parseMethod POST" { assert parseMethod("POST") == HttpMethod.POST; }
test "parseMethod PATCH" { assert parseMethod("PATCH") == HttpMethod.PATCH; }
test "parseMethod unknown defaults to GET" { assert parseMethod("INVALID") == HttpMethod.GET; }

test "isSuccess 200" { assert isSuccess(200); }
test "isSuccess 204" { assert isSuccess(204); }
test "isSuccess 301 false" { assert !isSuccess(301); }
test "isRedirect 301" { assert isRedirect(301); }
test "isRedirect 200 false" { assert !isRedirect(200); }
test "isClientError 404" { assert isClientError(404); }
test "isClientError 500 false" { assert !isClientError(500); }
test "isServerError 500" { assert isServerError(500); }
test "isServerError 404 false" { assert !isServerError(404); }

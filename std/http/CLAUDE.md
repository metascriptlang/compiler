# std/http — HTTP Module Implementation Plan

## Goal

Feature-comparable HTTP/1.1 module to Node.js `http`. Not API-identical — we use `Result<T,E>`, enums, `match`, `defer` — but a thin compatibility wrapper should be buildable on top. Target: ~1200 LOC across all files.

## Node.js Feature Comparison

| Node.js `http` Feature | Our `std/http` | Status |
|------------------------|----------------|--------|
| `http.createServer(handler)` | `createServer(handler)` | Phase 4 |
| `server.listen(port, host, cb)` | `server.listen(addr, port): Result` | Phase 4 |
| `server.close()` | `server.stop()` | Phase 4 |
| `req.method` | `req.method: HttpMethod` (enum) | Phase 1 |
| `req.url` | `req.path: string` | Phase 1 |
| `req.headers` | `req.headers: HttpHeaders` | Phase 1 |
| `req.httpVersion` | `req.version: string` | Phase 1 |
| `req.on('data', cb)` / req body | `req.body` (buffered) + `readBody(fd)` | Phase 4 |
| `res.writeHead(status, headers)` | `res.writeHead(status, headers)` | Phase 4 |
| `res.setHeader(name, value)` | `setHeader(res.headers, name, value)` | Phase 2 |
| `res.getHeader(name)` | `getHeader(res.headers, name)` | Phase 2 |
| `res.write(chunk)` | `res.write(chunk)` (streaming) | Phase 4 |
| `res.end(data?)` | `res.end()` / `res.end(data)` | Phase 4 |
| `res.statusCode = N` | `res.status = N` | Phase 1 |
| `http.request(options, cb)` | `request(options): Result<HttpResponse, HttpError>` | Phase 5 |
| `http.get(url, cb)` | `httpGet(host, port, path): Result` | Phase 5 |
| Keep-alive (default) | Keep-alive with configurable timeout | Phase 4 |
| `Transfer-Encoding: chunked` | Chunked response encoding | Phase 4 |
| `Content-Length` auto | Auto Content-Length for buffered responses | Phase 4 |
| Status codes + reason phrases | `statusText(code)` function | Phase 1 |
| URL parsing | `parseUrl(url)` + `splitPathQuery` | Phase 3 |
| **NOT planned (v1)** | | |
| `http.Agent` / connection pooling | Future (F6) | — |
| TLS/HTTPS | Future (F4) | — |
| WebSocket upgrade | Future (F5) | — |
| Multipart form data | Future (F7) | — |
| HTTP/2 | Not planned | — |
| Trailers | Not planned | — |

## Architecture

```
User Code
    |
    v
std/http/server.cms  <->  std/http/client.cms     (HTTP protocol)
    |                        |
    v                        v
std/http/parser.ms   std/http/headers.ms          (pure MS parsing)
    |
    v
std/http/types.ms + std/http/errors.ms            (pure MS types)
    |
    v
std/net/index.cms                                  (TCP sockets)
    |
    v
std/net/native.h                                   (POSIX sockets C runtime)
```

## File Plan

```
std/net/
  native.h              ~100 LOC  POSIX socket wrappers (C runtime)
  index.cms              ~40 LOC  extern declarations + MS exports

std/http/
  CLAUDE.md             this file
  types.ms              ~100 LOC  enums, interfaces, constants (pure MS)
  errors.ms              ~60 LOC  HttpErrorKind enum + constructors (pure MS)
  headers.ms             ~80 LOC  HttpHeaders operations (pure MS)
  parser.ms             ~250 LOC  HTTP/1.1 request/response parser (pure MS)
  server.cms            ~300 LOC  HTTP server with streaming + keep-alive
  client.cms            ~200 LOC  HTTP client with full body reading
  index.ms               ~30 LOC  re-exports for `import from "std/http"`
```

Total: ~1160 LOC

## Module Boundaries

| Module | Scope | Does NOT contain |
|--------|-------|------------------|
| `std/net` | TCP socket primitives only | HTTP parsing, protocol logic |
| `std/http/types.ms` | Enums + interfaces + constants | Imports from other http files |
| `std/http/errors.ms` | Error enum + constructors | Imports from types.ms (self-contained) |
| `std/http/headers.ms` | Header get/set/has/serialize | Parsing, socket I/O |
| `std/http/parser.ms` | Request/response line + header parsing | Socket I/O, server logic |
| `std/http/server.cms` | Bind/listen/accept/dispatch/streaming | Client logic |
| `std/http/client.cms` | Connect/send/recv/body reading | Server logic |

---

## Phase 0: `std/net` — TCP Socket Primitives

### `std/net/native.h` (~100 LOC)

C runtime for POSIX sockets. Header-only, static inline functions.

**Functions** (all use proper int32 params, not double):

```c
// Core operations
int32_t msNetSocket(void);                                     // socket(AF_INET, SOCK_STREAM, 0)
int32_t msNetBind(int32_t fd, msString addr, int32_t port);    // bind + SO_REUSEADDR
int32_t msNetListen(int32_t fd, int32_t backlog);              // listen
int32_t msNetAccept(int32_t fd);                               // accept + TCP_NODELAY
int32_t msNetConnect(int32_t fd, msString host, int32_t port); // connect (getaddrinfo)
int32_t msNetSend(int32_t fd, msString data);                  // send (full write loop)
msString msNetRecv(int32_t fd, int32_t maxBytes);              // recv -> msString
void    msNetClose(int32_t fd);                                // close
int32_t msNetSetTimeout(int32_t fd, int32_t ms);               // SO_RCVTIMEO + SO_SNDTIMEO
int32_t msNetSetNonBlocking(int32_t fd);                       // O_NONBLOCK (for future event loop)
```

**Design decisions**:
- `int32_t` params — NOT double. We have sized integers now (`int32` in MS).
- `msNetBind` sets `SO_REUSEADDR` automatically (every server needs it).
- `msNetAccept` sets `TCP_NODELAY` automatically (low-latency responses).
- `msNetRecv` returns `msString` — empty string on error/close (same pattern as `std/fs`).
- `msNetConnect` uses `getaddrinfo` for DNS resolution (supports hostnames, not just IPs).
- `msNetSend` does full write loop (retries on short writes and EINTR).

### `std/net/index.cms` (~40 LOC)

```ms
@include("net/native.h");

extern function msNetSocket(): int32;
extern function msNetBind(fd: int32, addr: string, port: int32): int32;
extern function msNetListen(fd: int32, backlog: int32): int32;
extern function msNetAccept(fd: int32): int32;
extern function msNetConnect(fd: int32, host: string, port: int32): int32;
extern function msNetSend(fd: int32, data: string): int32;
extern function msNetRecv(fd: int32, maxBytes: int32): string;
extern function msNetClose(fd: int32): void;
extern function msNetSetTimeout(fd: int32, ms: int32): int32;

// Re-export with clean names
export function createSocket(): int32 { return msNetSocket(); }
export function bind(fd: int32, addr: string, port: int32): int32 { return msNetBind(fd, addr, port); }
export function listen(fd: int32, backlog: int32): int32 { return msNetListen(fd, backlog); }
export function accept(fd: int32): int32 { return msNetAccept(fd); }
export function connect(fd: int32, host: string, port: int32): int32 { return msNetConnect(fd, host, port); }
export function send(fd: int32, data: string): int32 { return msNetSend(fd, data); }
export function recv(fd: int32, maxBytes: int32): string { return msNetRecv(fd, maxBytes); }
export function close(fd: int32): void { msNetClose(fd); }
export function setTimeout(fd: int32, ms: int32): int32 { return msNetSetTimeout(fd, ms); }
```

---

## Phase 1: `std/http/types.ms` — Pure Types (~100 LOC)

No imports from other http files. Zero dependencies (except headers.ms for HttpHeaders).

```ms
export enum HttpMethod { GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS }

export interface HttpRequest {
    method: HttpMethod;
    path: string;              // URL path (e.g. "/api/users?page=2")
    version: string;           // "1.0" or "1.1"
    headers: HttpHeaders;
    body: string;              // buffered body (read after headers parsed)
    clientFd: int32;           // socket fd for advanced use
}

// Client response (immutable result from httpGet/httpPost)
export interface HttpResponse {
    status: int32;
    statusText: string;
    headers: HttpHeaders;
    body: string;
}

// Server response (mutable, handler fills via writeHead/write/end)
export interface ServerResponse {
    fd: int32;
    status: int32;
    headers: HttpHeaders;
    _chunks: string[];         // buffered chunks from write() calls
    headersSent: boolean;      // true after writeHead() or first write
    _finished: boolean;        // true after end() called
    _chunked: boolean;         // using Transfer-Encoding: chunked
}

export type RequestHandler = (req: HttpRequest, res: ServerResponse) => void;

// Client request options (Node.js http.request() equivalent)
export interface RequestOptions {
    method: HttpMethod;
    hostname: string;
    port: int32;
    path: string;
    headers: HttpHeaders;
    body: string;
    timeout: int32;            // ms, 0 = no timeout
}
```

### Status codes — function, not 60 constants

```ms
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
```

### HttpMethod to/from string

```ms
export function methodToString(m: HttpMethod): string {
    return match (m) {
        HttpMethod.GET => "GET",
        HttpMethod.POST => "POST",
        HttpMethod.PUT => "PUT",
        HttpMethod.DELETE => "DELETE",
        HttpMethod.PATCH => "PATCH",
        HttpMethod.HEAD => "HEAD",
        HttpMethod.OPTIONS => "OPTIONS",
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
```

---

## Phase 1b: `std/http/errors.ms` — Error Types (~60 LOC)

No imports. Self-contained.

```ms
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

export interface HttpError {
    kind: HttpErrorKind;
    message: string;
}

export function httpError(kind: HttpErrorKind, msg: string): HttpError {
    return { kind: kind, message: msg };
}

// Convenience constructors (most common ones)
export function connectionFailed(msg: string): HttpError {
    return { kind: HttpErrorKind.ConnectionFailed, message: msg };
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
export function socketError(msg: string): HttpError {
    return { kind: HttpErrorKind.SocketError, message: msg };
}
export function bodyTooLarge(size: int32, limit: int32): HttpError {
    return { kind: HttpErrorKind.BodyTooLarge, message: "body " + size.toString() + " exceeds limit " + limit.toString() };
}

// Classification helpers
export function isRetryable(e: HttpError): boolean {
    return match (e.kind) {
        HttpErrorKind.Timeout => true,
        HttpErrorKind.ConnectionReset => true,
        HttpErrorKind.ConnectionFailed => true,
        _ => false,
    };
}
```

---

## Phase 2: `std/http/headers.ms` — Header Operations (~80 LOC)

Pure MetaScript. Imports nothing from other http files.

```ms
export interface HttpHeaders {
    table: Map<string, string[]>;
    keys: string[];
}

export function createHeaders(): HttpHeaders { ... }
export function setHeader(h: HttpHeaders, name: string, value: string): void { ... }
export function addHeader(h: HttpHeaders, name: string, value: string): void { ... }
export function getHeader(h: HttpHeaders, name: string): string { ... }       // "" if missing
export function hasHeader(h: HttpHeaders, name: string): boolean { ... }
export function removeHeader(h: HttpHeaders, name: string): void { ... }
export function getHeaderValues(h: HttpHeaders, name: string): string[] { ... } // all values
export function serializeHeaders(h: HttpHeaders): string { ... }               // "key: val\r\n..."
export function getContentLength(h: HttpHeaders): int32 { ... }               // -1 if missing
export function isChunked(h: HttpHeaders): boolean { ... }                     // Transfer-Encoding: chunked?
export function isKeepAlive(h: HttpHeaders, version: string): boolean { ... }  // Connection header + version default
```

**Design notes**:
- `getHeader` returns `""` not `null` — simpler for C backend (no Maybe wrapper).
- All keys lowercased on insert (RFC 7230: headers are case-insensitive).
- `isKeepAlive` checks `Connection` header; defaults to true for HTTP/1.1, false for 1.0.
- `isChunked` and `getContentLength` are frequently needed — dedicated helpers avoid repeated parsing.

---

## Phase 3: `std/http/parser.ms` — HTTP Parser (~250 LOC)

Pure MetaScript. Imports from `types.ms`, `errors.ms`, `headers.ms`.

### Request parsing

```ms
export interface ParsedRequest {
    method: HttpMethod;
    path: string;
    version: string;
    headers: HttpHeaders;
    bodyStart: int32;  // byte offset where body begins in raw data
}

export function parseRequest(data: string): Result<ParsedRequest, HttpError> { ... }
```

### Response parsing (for client)

```ms
export interface ParsedResponse {
    version: string;
    status: int32;
    statusText: string;
    headers: HttpHeaders;
    bodyStart: int32;
}

export function parseResponse(data: string): Result<ParsedResponse, HttpError> { ... }
```

### URL parsing (Node.js `new URL()` equivalent)

```ms
export interface ParsedUrl {
    protocol: string;    // "http" or "https"
    hostname: string;    // "example.com"
    port: int32;         // 80, 443, or explicit
    path: string;        // "/api/users"
    query: string;       // "page=2&limit=10"
}

export function parseUrl(url: string): Result<ParsedUrl, HttpError> { ... }
export function splitPathQuery(url: string): { path: string; query: string } { ... }
export function parseQueryString(query: string): Map<string, string> { ... }
```

### Chunked encoding

```ms
export function decodeChunked(data: string): Result<string, HttpError> { ... }
export function encodeChunk(data: string): string { ... }     // "A\r\nHelloWorld\r\n"
export function encodeLastChunk(): string { ... }             // "0\r\n\r\n"
```

### Implementation approach
- `charCodeAt(i)` + while loops for scanning (no regex)
- `"\r".code` / `"\n".code` / " ".code for delimiters
- `slice(start, end)` for substring extraction
- All pure MetaScript — compiles to both C and JS backends

---

## Phase 4: `std/http/server.cms` — HTTP Server (~300 LOC)

Imports: `std/net`, `./types`, `./errors`, `./headers`, `./parser`.

### Core Server API

```ms
export interface HttpServer {
    fd: int32;
    handler: RequestHandler;
    running: boolean;
    address: string;
    port: int32;
    keepAlive: boolean;                // default: true (Node.js default)
    keepAliveTimeout: int32;           // ms, default: 5000 (Node.js default)
    maxRequestsPerConnection: int32;   // default: 0 (unlimited)
    maxHeaderSize: int32;              // default: 8192
    maxBodySize: int32;                // default: 1048576 (1MB)
}

export function createServer(handler: RequestHandler): HttpServer { ... }
export function listen(this server: HttpServer, addr: string, port: int32): Result<void, HttpError> { ... }
export function serve(this server: HttpServer): void { ... }
export function serveN(this server: HttpServer, count: int32): void { ... }
export function stop(this server: HttpServer): void { ... }
```

### Streaming Response API (Node.js parity)

```ms
// writeHead: send status line + headers immediately (enables streaming)
export function writeHead(this res: ServerResponse, status: int32, headers: HttpHeaders): void {
    res.status = status;
    // Merge headers
    // ... copy provided headers into res.headers ...
    // If no Content-Length set, use chunked encoding
    if (!hasHeader(res.headers, "content-length")) {
        setHeader(res.headers, "Transfer-Encoding", "chunked");
        res._chunked = true;
    }
    // Send status line + headers now
    let head = "HTTP/1.1 " + status.toString() + " " + statusText(status) + "\r\n";
    head = head + serializeHeaders(res.headers) + "\r\n";
    send(res.fd, head);
    res.headersSent = true;
}

// write: send a chunk of body data (streaming)
export function write(this res: ServerResponse, chunk: string): void {
    if (!res.headersSent) {
        // Auto-send headers on first write (chunked mode)
        res.writeHead(res.status, res.headers);
    }
    if (res._chunked) {
        send(res.fd, encodeChunk(chunk));
    } else {
        send(res.fd, chunk);
    }
}

// end: finalize response
export function end(this res: ServerResponse): void {
    if (!res.headersSent) {
        // Buffered mode: collect all chunks, set Content-Length, send at once
        const body = joinChunks(res._chunks);
        setHeader(res.headers, "Content-Length", body.length.toString());
        let response = "HTTP/1.1 " + res.status.toString() + " " + statusText(res.status) + "\r\n";
        response = response + serializeHeaders(res.headers) + "\r\n" + body;
        send(res.fd, response);
    } else if (res._chunked) {
        send(res.fd, encodeLastChunk());
    }
    res._finished = true;
}

// end with final data
export function endWithBody(this res: ServerResponse, data: string): void {
    res.write(data);
    res.end();
}
```

### Convenience helpers (sugar on top of write/end)

```ms
export function sendText(this res: ServerResponse, text: string): void {
    setHeader(res.headers, "Content-Type", "text/plain; charset=utf-8");
    setHeader(res.headers, "Content-Length", text.length.toString());
    res.writeHead(res.status, res.headers);
    send(res.fd, text);
    res._finished = true;
}

export function sendJson(this res: ServerResponse, json: string): void {
    setHeader(res.headers, "Content-Type", "application/json");
    setHeader(res.headers, "Content-Length", json.length.toString());
    res.writeHead(res.status, res.headers);
    send(res.fd, json);
    res._finished = true;
}

export function sendHtml(this res: ServerResponse, html: string): void {
    setHeader(res.headers, "Content-Type", "text/html; charset=utf-8");
    setHeader(res.headers, "Content-Length", html.length.toString());
    res.writeHead(res.status, res.headers);
    send(res.fd, html);
    res._finished = true;
}

export function sendError(this res: ServerResponse, status: int32, msg: string): void {
    res.status = status;
    res.sendText(msg);
}
```

### Request body reading

```ms
// Read full request body based on Content-Length header.
// Called internally after headers are parsed. Handles bodies > initial recv buffer.
function readRequestBody(fd: int32, initialData: string, bodyStart: int32, contentLength: int32, maxSize: int32): Result<string, HttpError> {
    if (contentLength > maxSize) {
        return Result.err(bodyTooLarge(contentLength, maxSize));
    }
    // Body bytes already in initial buffer
    const available = initialData.length - bodyStart;
    if (available >= contentLength) {
        return Result.ok(initialData.slice(bodyStart, bodyStart + contentLength));
    }
    // Need more data from socket
    let body = initialData.slice(bodyStart, initialData.length);
    let remaining = contentLength - available;
    while (remaining > 0) {
        const chunk = recv(fd, remaining);
        if (chunk.length === 0) {
            return Result.err(socketError("connection closed while reading body"));
        }
        body = body + chunk;
        remaining = remaining - chunk.length;
    }
    return Result.ok(body);
}
```

### Accept loop with keep-alive

```ms
export function serve(this server: HttpServer): void {
    server.running = true;
    while (server.running) {
        const clientFd = accept(server.fd);
        if (clientFd < 0) continue;

        handleConnection(server, clientFd);
        close(clientFd);
    }
}

function handleConnection(server: HttpServer, fd: int32): void {
    let requestCount = 0;
    let keepGoing = true;

    while (keepGoing) {
        // Read headers (up to maxHeaderSize)
        const data = recv(fd, server.maxHeaderSize);
        if (data.length === 0) return;  // client closed

        // Parse request headers
        const parsed = try parseRequest(data) catch { return; };

        // Read body if Content-Length present
        const contentLength = getContentLength(parsed.headers);
        let body = "";
        if (contentLength > 0) {
            const bodyResult = readRequestBody(fd, data, parsed.bodyStart, contentLength, server.maxBodySize);
            if (!bodyResult.ok) return;
            body = bodyResult.value;
        }

        // Build request
        const req: HttpRequest = {
            method: parsed.method,
            path: parsed.path,
            version: parsed.version,
            headers: parsed.headers,
            body: body,
            clientFd: fd,
        };

        // Build response
        const res = createServerResponse(fd);

        // Call handler
        server.handler(req, res);

        // Ensure response was sent
        if (!res._finished) {
            res.end();
        }

        requestCount = requestCount + 1;

        // Keep-alive decision
        if (!server.keepAlive) { keepGoing = false; }
        else if (server.maxRequestsPerConnection > 0 && requestCount >= server.maxRequestsPerConnection) { keepGoing = false; }
        else if (!isKeepAlive(parsed.headers, parsed.version)) { keepGoing = false; }
        // TODO: keepAliveTimeout via SO_RCVTIMEO
    }
}
```

---

## Phase 5: `std/http/client.cms` — HTTP Client (~200 LOC)

Imports: `std/net`, `./types`, `./errors`, `./headers`, `./parser`.

### Core API

```ms
// Simple one-shot functions
export function httpGet(host: string, port: int32, path: string): Result<HttpResponse, HttpError> { ... }
export function httpPost(host: string, port: int32, path: string, body: string, contentType: string): Result<HttpResponse, HttpError> { ... }

// Full options (Node.js http.request() equivalent)
export function request(options: RequestOptions): Result<HttpResponse, HttpError> { ... }

// Stateful client with defaults
export interface HttpClient {
    timeout: int32;
    maxRedirects: int32;
    userAgent: string;
}

export function createClient(): HttpClient { ... }
export function get(this c: HttpClient, host: string, port: int32, path: string): Result<HttpResponse, HttpError> { ... }
export function post(this c: HttpClient, host: string, port: int32, path: string, body: string, contentType: string): Result<HttpResponse, HttpError> { ... }
```

### Full response body reading

```ms
function doRequest(options: RequestOptions): Result<HttpResponse, HttpError> {
    const fd = createSocket();
    if (fd < 0) return Result.err(socketError("socket() failed"));
    defer close(fd);

    if (options.timeout > 0) {
        setTimeout(fd, options.timeout);
    }

    if (connect(fd, options.hostname, options.port) < 0) {
        return Result.err(connectionFailed("connect to " + options.hostname + " failed"));
    }

    // Build + send request
    const headers = options.headers;
    setHeader(headers, "Host", options.hostname);
    if (options.body.length > 0) {
        setHeader(headers, "Content-Length", options.body.length.toString());
    }
    setHeader(headers, "Connection", "close");

    const reqStr = methodToString(options.method) + " " + options.path + " HTTP/1.1\r\n"
                 + serializeHeaders(headers) + "\r\n" + options.body;

    if (send(fd, reqStr) < 0) {
        return Result.err(socketError("send failed"));
    }

    // Read response headers
    let data = recv(fd, 8192);
    if (data.length === 0) {
        return Result.err(invalidResponse("empty response"));
    }

    // Parse status + headers
    const parsed = try parseResponse(data);

    // Read full body
    const contentLength = getContentLength(parsed.headers);
    let body = "";

    if (isChunked(parsed.headers)) {
        // Read chunked response
        body = try readChunkedBody(fd, data, parsed.bodyStart);
    } else if (contentLength > 0) {
        // Read Content-Length body
        const bodyResult = readFullBody(fd, data, parsed.bodyStart, contentLength);
        if (!bodyResult.ok) return Result.err(bodyResult.error);
        body = bodyResult.value;
    } else if (contentLength < 0) {
        // No Content-Length, no chunked: read until connection close
        body = readUntilClose(fd, data, parsed.bodyStart);
    }

    return Result.ok({
        status: parsed.status,
        statusText: parsed.statusText,
        headers: parsed.headers,
        body: body,
    });
}
```

### Redirect following

```ms
export function requestWithRedirects(options: RequestOptions, maxRedirects: int32): Result<HttpResponse, HttpError> {
    let remaining = maxRedirects;
    let currentOptions = options;
    while (remaining > 0) {
        const resp = try doRequest(currentOptions);
        if (resp.status < 300 || resp.status >= 400) {
            return Result.ok(resp);
        }
        // Follow redirect
        const location = getHeader(resp.headers, "location");
        if (location.length === 0) return Result.ok(resp);  // no Location header
        const parsed = try parseUrl(location);
        currentOptions = { ...currentOptions, hostname: parsed.hostname, port: parsed.port, path: parsed.path };
        remaining = remaining - 1;
    }
    return Result.err(httpError(HttpErrorKind.TooManyRedirects, "exceeded " + maxRedirects.toString() + " redirects"));
}
```

---

## Phase 6: `std/http/index.ms` — Re-exports (~30 LOC)

```ms
// Types
export { HttpMethod, HttpRequest, HttpResponse, ServerResponse, RequestHandler, RequestOptions,
         statusText, methodToString, parseMethod } from "./types";

// Errors
export { HttpErrorKind, HttpError, httpError, connectionFailed, timeout,
         invalidRequest, invalidResponse, socketError, bodyTooLarge, isRetryable } from "./errors";

// Headers
export { HttpHeaders, createHeaders, setHeader, addHeader, getHeader, hasHeader,
         removeHeader, getHeaderValues, serializeHeaders, getContentLength,
         isChunked, isKeepAlive } from "./headers";

// Parser
export { parseRequest, parseResponse, parseUrl, splitPathQuery, parseQueryString,
         decodeChunked, encodeChunk, encodeLastChunk } from "./parser";

// Server
export { HttpServer, createServer, listen, serve, serveN, stop,
         writeHead, write, end, endWithBody,
         sendText, sendJson, sendHtml, sendError } from "./server";

// Client
export { httpGet, httpPost, request, HttpClient, createClient,
         requestWithRedirects } from "./client";
```

---

## Implementation Order

| Step | File | Deps | Test Strategy |
|------|------|------|---------------|
| 1 | `std/net/native.h` | system headers only | manual C test |
| 2 | `std/net/index.cms` | native.h | MS echo server test |
| 3 | `std/http/types.ms` | none | inline tests (enum, statusText) |
| 4 | `std/http/errors.ms` | none | inline tests (constructors, isRetryable) |
| 5 | `std/http/headers.ms` | none | inline tests (set/get/has/serialize/isKeepAlive) |
| 6 | `std/http/parser.ms` | types, errors, headers | inline tests (parse request/response/url strings) |
| 7 | `std/http/server.cms` | std/net, types, errors, headers, parser | integration test (start server, curl it) |
| 8 | `std/http/client.cms` | std/net, types, errors, headers, parser | integration test (client -> server roundtrip) |
| 9 | `std/http/index.ms` | all above | import test |

**Pure MS files first** (types, errors, headers, parser) — testable without networking.
**Then C layer** (std/net) — socket primitives.
**Then glue** (server, client) — tie it together.

---

## Future Phases (NOT in scope now)

| Phase | Feature | Node.js Equivalent |
|-------|---------|-------------------|
| F1 | Event-driven server (kqueue/epoll via existing `runtime/core/selector.h`) | Concurrency / multi-client |
| F2 | Connection pooling (client) | `http.Agent` |
| F3 | TLS/HTTPS (mbedTLS lazy link) | `https` module |
| F4 | WebSocket upgrade | `ws` package |
| F5 | Multipart form data | `multer` / `formidable` |
| F6 | Cookie jar (client) | `tough-cookie` |
| F7 | Compression (gzip/deflate) | `zlib` |

## Key Design Principles

1. **Pure MS where possible** — types, errors, headers, parser are all `.ms` (work on all backends)
2. **C only for syscalls** — only `std/net/native.h` touches POSIX APIs
3. **Result<T, HttpError> everywhere** — no exceptions, no panics
4. **`int32` for fd/port/status** — proper sized integers, not f64
5. **`enum` for HttpMethod/HttpErrorKind** — native C switch, exhaustive match
6. **`defer` for socket cleanup** — no resource leaks
7. **`match` for dispatch** — idiomatic MetaScript throughout
8. **Streaming first** — `writeHead`/`write`/`end` is the core API; `sendText` etc. are sugar
9. **Keep-alive by default** — matches Node.js HTTP/1.1 behavior
10. **Node.js wrappable** — every Node.js `http` feature has a MetaScript equivalent or is explicitly in future phases

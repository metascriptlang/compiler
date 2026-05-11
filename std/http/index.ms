// std/http — Re-exports for `import from "std/http"`

// Types
export {
	HttpMethod, HttpRequest, HttpResponse, ServerResponse, RequestHandler, AsyncRequestHandler,
	RequestOptions, FetchOptions, ParsedUrl,
	HttpHeaders, statusText, methodToString, parseMethod,
	isSuccess, isRedirect, isClientError, isServerError,
} from "./types";

// Errors
export {
	HttpErrorKind, HttpError, httpError,
	connectionFailed, connectionReset, timeout,
	invalidRequest, invalidResponse, invalidHeader, socketError,
	bodyTooLarge, tooManyRedirects,
	isRetryable, isConnectionError, isProtocolError,
} from "./errors";

// Headers — low-level HttpHeaders ops. The matching ServerResponse
// extension methods (res.setHeader(...) etc.) come from "./server" below;
// at call sites, MS dispatches by first-arg type so both can coexist.
export {
	createHeaders, addHeader, getHeaderValues, serializeHeaders,
	getContentLength, isChunked, isKeepAlive,
} from "./headers";

// Parser
export {
	ParsedRequest, ParsedResponse,
	parseRequest, parseResponse, parseUrl, splitPathQuery,
	decodeChunked, encodeChunk, encodeLastChunk,
} from "./parser";

// Server
export {
	HttpServer, createServer, createServerAsync, listen, serve, serveConcurrent, serveConcurrentAsync, serveN, stop,
	sendText, sendJson, sendHtml, sendError, sendRaw, getClientFd,
	// Phase 4 — Node-style extension methods on ServerResponse
	setHeader, getHeader, removeHeader, hasHeader, writeHead, end, json,
} from "./server";

// Plain HTTP client (matches Node's `http` module). Importing these does
// NOT pull `std/crypto/tls` / mbedtls into the link.
//
// For HTTPS, import from `std/https` — same function names (`request`,
// `requestWithRedirects`), TLS wiring underneath.
//
// For URL-based dispatch (`fetch(url)` auto-detecting http vs https), use
// the global `fetch` from the prelude (see `std/core/fetch`).
export {
	HttpClient, createClient,
	request, requestWithRedirects,
} from "./client";

// WebSocket client (RFC 6455). Real types/functions live in `std/core/websocket`
// (a prelude); these re-exports expose them through the explicit-import path.
// `sendText`/`recv`/`close` aren't re-exported by name to avoid colliding with
// the HTTP server names — call them as extension methods on a `WsClient`
// instance instead (e.g. `client.sendText("hi")`).
export {
	WsClient, WsMessage, WsState, WsMessageKind, WsCloseCode,
	connect,
} from "std/core/websocket";

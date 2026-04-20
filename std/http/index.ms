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

// Headers
export {
	createHeaders, setHeader, addHeader, getHeader, hasHeader,
	removeHeader, getHeaderValues, serializeHeaders,
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
	HttpServer, createServer, createServerAsync, serverListen, serve, serveConcurrent, serveConcurrentAsync, serveN, stop,
	sendText, sendJson, sendHtml, sendError, sendRaw, getClientFd,
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

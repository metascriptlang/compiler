// Re-export shim — actual definitions live in std/core/fetch/headers.
export {
	createHeaders, addHeader, setHeader, removeHeader, getHeader, hasHeader,
	getHeaderValues, serializeHeaders,
	getContentLength, isChunked, isKeepAlive,
} from "std/core/fetch/headers";

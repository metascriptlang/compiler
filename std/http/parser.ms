// Re-export shim — actual definitions live in std/core/fetch/parser.
export {
	ParsedRequest, ParsedResponse,
	parseRequest, parseResponse, parseUrl, splitPathQuery,
	decodeChunked, encodeChunk, encodeLastChunk,
} from "std/core/fetch/parser";

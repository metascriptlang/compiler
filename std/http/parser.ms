// Re-export shim — actual definitions live in std/core/fetch/parser.
export {
	ParsedRequest, ParsedResponse,
	parseRequest, parseResponse, parseUrl, splitPathQuery,
	decodeChunked, encodeChunk, encodeLastChunk,
	FrameResult, ChunkedDecodeResult,
	frameRequest, tryDecodeChunked,
} from "std/core/fetch/parser";

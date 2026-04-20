// Re-export shim — actual definitions live in std/core/fetch/types.
// Kept so existing `import { ... } from "std/http/types"` paths continue to work.
export {
	HttpMethod, HttpHeaders, HttpRequest, HttpResponse, ServerResponse,
	RequestOptions, FetchOptions, ParsedUrl,
	RequestHandler, AsyncRequestHandler,
	statusText, isSuccess, isRedirect, isClientError, isServerError,
	methodToString, parseMethod,
} from "std/core/fetch/types";

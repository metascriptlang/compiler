// Re-export shim — actual implementation lives in std/core/fetch/client.cms.
// Importing from std/http/client (or std/http) keeps the module dependency
// graph clean: only the plain-TCP transport becomes alive, mbedtls is NOT
// pulled in unless std/https or fetch() are also referenced.
export {
	HttpClient, createClient, ResolvedOptions,
	request, requestWithRedirects,
	doRequestOver, requestWithRedirectsOver,
	resolveFetchOptions, urlPath,
	RECV_CHUNK_SIZE, MAX_HEADER_BYTES,
} from "std/core/fetch/client";

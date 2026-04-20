// Re-export shim — actual definitions live in std/core/fetch/errors.
export {
	HttpErrorKind, HttpError,
	httpError, connectionFailed, connectionReset, timeout,
	invalidRequest, invalidResponse, invalidHeader, socketError,
	bodyTooLarge, tooManyRedirects,
	isRetryable, isConnectionError, isProtocolError,
} from "std/core/fetch/errors";

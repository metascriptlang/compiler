// SurrealDB client errors.
//
// Layered:
//   - Connection — TCP/WebSocket transport failure
//   - Decode     — CBOR malformed or response shape unexpected
//   - Rpc        — server returned `{ error: { code, message } }`
//   - Auth       — signin/authenticate failed (specialised RpcError)
//   - Closed     — operation attempted on closed client

export enum SurrealErrorKind {
	ConnectionFailed,
	Decode,
	Rpc,
	AuthFailed,
	Closed,
	Internal,
}

export interface SurrealError {
	kind: SurrealErrorKind;
	message: string;
	rpcCode: int32;          // populated only when kind === Rpc
}

export function surrealError(kind: SurrealErrorKind, msg: string): SurrealError {
	return { kind: kind, message: msg, rpcCode: 0 };
}

export function connectionFailed(msg: string): SurrealError {
	return { kind: SurrealErrorKind.ConnectionFailed, message: msg, rpcCode: 0 };
}

export function decodeError(msg: string): SurrealError {
	return { kind: SurrealErrorKind.Decode, message: msg, rpcCode: 0 };
}

export function rpcError(code: int32, msg: string): SurrealError {
	return { kind: SurrealErrorKind.Rpc, message: msg, rpcCode: code };
}

export function authFailed(msg: string): SurrealError {
	return { kind: SurrealErrorKind.AuthFailed, message: msg, rpcCode: 0 };
}

export function closed(msg: string): SurrealError {
	return { kind: SurrealErrorKind.Closed, message: msg, rpcCode: 0 };
}

export function internal(msg: string): SurrealError {
	return { kind: SurrealErrorKind.Internal, message: msg, rpcCode: 0 };
}

// ===== Tests =====

test "rpcError carries code + message" {
	const e = rpcError(-32602, "invalid params");
	assert e.kind == SurrealErrorKind.Rpc;
	assert e.rpcCode == -32602;
	assert e.message == "invalid params";
}

test "connectionFailed" {
	const e = connectionFailed("refused");
	assert e.kind == SurrealErrorKind.ConnectionFailed;
}

test "authFailed distinct from generic rpc error" {
	const e = authFailed("bad credentials");
	assert e.kind == SurrealErrorKind.AuthFailed;
	assert e.kind != SurrealErrorKind.Rpc;
}

test "decodeError surfaces parser failures" {
	const e = decodeError("cbor truncated");
	assert e.kind == SurrealErrorKind.Decode;
}

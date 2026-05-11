// std/surreal — SurrealDB client over WebSocket + CBOR.
//
// V0 ships a sync client. Async + live queries are deferred to V1.
//
// Pre-req server: `surreal start --user root --pass root memory` (or any
// SurrealDB v2/v3 instance reachable on the configured ws:// URL).
//
// Usage:
//
//   import { connectSurreal, SurrealError, SurrealErrorKind } from "std/surreal";
//
//   const r = connectSurreal("ws://127.0.0.1:8000/rpc");
//   if (!r.ok) { /* handle */ return; }
//   const c = r.value;
//   try c.signin("root", "root");
//   try c.use("test", "test");
//   try c.queryStr("CREATE foo SET name = 'hello'");
//   const records = try c.select("foo");
//   c.close();

export {
	SurrealError, SurrealErrorKind,
	surrealError, connectionFailed, decodeError, rpcError, authFailed, closed, internal,
} from "./errors";

export {
	RpcResponse,
	buildRequest, parseResponse,
} from "./rpc";

export {
	SurrealClient, LiveSubscription,
	connectSurreal,
	signin, signup, authenticate, invalidate,
	use, letVar, unsetVar,
	queryStr, query,
	select, create, update, merge, deleteRecord,
	live, kill, dispatchOnce, dispatchLoop,
	ping, close,
} from "./client";

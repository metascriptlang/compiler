// std/surreal — SurrealDB client over WebSocket + CBOR.
//
// V0 ships a sync client. Async + live queries are supported on the same
// socket via the LIVE-SELECT subscriptions in ./live.
//
// Pre-req server: `surreal start --user root --pass root memory` (or any
// SurrealDB v2/v3 instance reachable on the configured ws:// URL).
//
// Module layout:
//   - ./errors  — typed SurrealError + constructors
//   - ./rpc     — pure CBOR envelope codec (no socket)
//   - ./client  — connection state, internal RPC dispatch, close/ping
//   - ./auth    — signin/signup/authenticate/invalidate, session vars, admin
//   - ./crud    — raw CRUD + recordId + queries + patch + run + exists + graph
//   - ./typed   — Surreal class (macro-driven typed decode)
//   - ./live    — LIVE SELECT subscriptions + dispatch loop
//
// Usage:
//
//   import { connectSurreal, Surreal } from "std/surreal";
//
//   const c = try connectSurreal("ws://127.0.0.1:8000/rpc");
//   try c.signin("root", "root");
//   try c.use("test", "test");
//   const posts = try Surreal.select<Post>(c, "posts");

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
	ping, close,
} from "./client";

export {
	signin, signup, authenticate, invalidate,
	use, letVar, unsetVar,
	version, info, reset,
} from "./auth";

export {
	queryStr, query,
	// Raw CRUD (CborValue result) — use when you want untyped inspection.
	selectRaw, createRaw, updateRaw, mergeRaw, deleteRecordRaw,
	insertRaw, upsertRaw,
	// Graph raw forms.
	relateRaw, insertRelationRaw,
	// Standalone RPC methods + helpers.
	patch, run, exists, recordId,
} from "./crud";

export {
	// Typed CRUD via the `Surreal` class — Surreal.select<Post>(c, "posts").
	Surreal,
} from "./typed";

export {
	live, kill, dispatchOnce, dispatchLoop,
} from "./live";

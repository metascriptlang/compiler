// SurrealDB sync client.
//
// Wires WS + CBOR + RPC envelope into a small request/response API. V0 is
// sync-only — one in-flight request per connection at a time. Async + live
// queries deferred to V1 (would use the actor pattern proven by
// examples/probeActorMux.ms).
//
// Usage:
//
//   import { connectSurreal, SurrealClient } from "std/surreal";
//
//   const c = try connectSurreal("ws://127.0.0.1:8000/rpc");
//   try c.signin("root", "root");
//   try c.use("test", "test");
//   try c.queryStr("CREATE foo SET name = 'hello'");
//   const got = try c.select("foo");
//
// `select`/`query` return raw `CborValue` — caller inspects via the cbor
// untyped tree (`getDynamicField`, `asString`, `at`, `length`, ...). Typed
// decode of result records is a Layer-B/macro concern that builds on top.

import { connectSync, sendBinarySync, recvSync, closeSync, WsClient, WsCloseCode, WsMessageKind, ConnectOptions } from "std/core/websocket";
import { CborKind, CborValue } from "std/serialize/cbor/types";
import { cborText, cborTextMap, cborArray } from "std/serialize/cbor/builder";
import { getDynamicField, asString, length, at } from "std/serialize/cbor/accessors";
import { newCborWriter, encodeValue } from "std/serialize/cbor/encoder";
import { decodeAll } from "std/serialize/cbor/decoder";
import { buildRequest, parseResponse, RpcResponse } from "./rpc";
import {
	SurrealError, SurrealErrorKind,
	connectionFailed, decodeError, rpcError, authFailed, closed, internal,
} from "./errors";

// ===== Live-subscription support =====

// One registered LIVE callback. SurrealDB v3 keys live notifications by a
// UUID Tag (CBOR tag wrapping 16 raw bytes), not by the request id of the
// LIVE-SELECT call that registered the subscription. We keep the Tag as a
// raw CborValue and match notifications by deep equality on (tagNum, bytes).
export interface LiveSubscription {
	uuid: CborValue;                                // the UUID Tag from LIVE response
	callback: (notification: CborValue) => void;    // called per push frame
}

// ===== Client state =====

export interface SurrealClient {
	ws: WsClient;
	nextId: int32;
	open: boolean;
	_liveSubs: LiveSubscription[];   // active subscriptions; linear scan on dispatch (~N usually 1-2)
}

// ===== Public connect =====

export function connectSurreal(url: string): Result<SurrealClient, SurrealError> {
	const subs: string[] = ["cbor"];
	const extras: string[] = [];
	const wsOpts: ConnectOptions = {
		subprotocols: subs,
		extraHeaders: extras,
		recvSendTimeoutMs: 30000,
	};
	const wsResult = connectSync(url, wsOpts);
	if (!wsResult.ok) {
		return Result.err(connectionFailed("ws connect: " + wsResult.error.message));
	}
	const ws = wsResult.value;
	if (ws.subprotocol !== "cbor") {
		// Server didn't negotiate cbor — we can't speak any other format.
		ws.closeSync(WsCloseCode.UnsupportedData as int32, "");
		return Result.err(connectionFailed("server did not negotiate 'cbor' subprotocol (got '" + ws.subprotocol + "')"));
	}
	const liveSubs: LiveSubscription[] = [];
	return Result.ok({ ws: ws, nextId: 1 as int32, open: true, _liveSubs: liveSubs });
}

// Deep-equal a CBOR Tag (used for matching live UUID notifications against
// registered subscriptions). Surreal sends UUIDs as a Tag wrapping either
// raw 16-byte Bytes or a Text representation; we handle both.
function cborTagEquals(a: CborValue, b: CborValue): boolean {
	if (a.kind !== CborKind.Tag || b.kind !== CborKind.Tag) return false;
	if (a.tagNum !== b.tagNum) return false;
	const ai = a.tagged;
	const bi = b.tagged;
	if (ai.kind !== bi.kind) return false;
	if (ai.kind === CborKind.Text && bi.kind === CborKind.Text) {
		return ai.textVal === bi.textVal;
	}
	if (ai.kind === CborKind.Bytes && bi.kind === CborKind.Bytes) {
		if (ai.bytesVal.byteLength !== bi.bytesVal.byteLength) return false;
		const n = ai.bytesVal.byteLength;
		for (let i: int64 = 0; i < n; i = i + 1) {
			if (ai.bytesVal.byteAt(i) !== bi.bytesVal.byteAt(i)) return false;
		}
		return true;
	}
	return false;
}

// Try to dispatch an already-decoded frame as a live notification. Returns
// true if the frame was a notification (regardless of whether any callback
// was registered for it — unmatched notifications are silently dropped).
// False means "this is a regular response, parse it normally".
//
// Notification shape (verified against Surreal v3 with LIVE SELECT):
//   { result: Map { id: Tag(UUID), action: Text, record: Tag, result: Map, session: Tag } }
// — no top-level `id` field, so a missing-id parse failure on the regular
// path is the discriminator.
//
// Caveat: the matched callback runs SYNCHRONOUSLY on the caller's stack
// (the rpc() loop or dispatchOnce()). A slow callback delays delivery of
// the original RPC's response by the same amount. Keep callbacks short or
// hand off to a queue/spawn inside the callback if heavy work is needed.
function tryDispatchNotification(c: SurrealClient, root: CborValue): boolean {
	if (root.kind !== CborKind.Map) return false;
	// A real RPC response always carries top-level `id: Text`. If we see one,
	// not a notification — let the caller parse it as a response.
	const idField = getDynamicField(root, "id");
	if (idField.kind === CborKind.Text) return false;
	// Otherwise inspect result.id for a Tag.
	const result = getDynamicField(root, "result");
	if (result.kind !== CborKind.Map) return false;
	const liveId = getDynamicField(result, "id");
	if (liveId.kind !== CborKind.Tag) return false;
	for (let i: int32 = 0; i < c._liveSubs.length; i = i + 1) {
		if (cborTagEquals(c._liveSubs[i].uuid, liveId)) {
			c._liveSubs[i].callback(result);
			return true;
		}
	}
	// Notification for an unknown subscription — drop silently.
	return true;
}

// Parse an already-decoded CborValue into an RpcResponse. Returns
// Result.err on shape violations.
function decodedToResponse(root: CborValue): Result<RpcResponse, SurrealError> {
	if (root.kind !== CborKind.Map) {
		return Result.err(decodeError("response is not a CBOR Map (kind=" + root.kind.toString() + ")"));
	}
	const idField = getDynamicField(root, "id");
	if (idField.kind !== CborKind.Text) {
		return Result.err(decodeError("response missing or non-text id field"));
	}
	const id = asString(idField);
	const errorField = getDynamicField(root, "error");
	if (errorField.kind !== CborKind.Null) {
		if (errorField.kind !== CborKind.Map) {
			return Result.err(decodeError("response.error is not a Map"));
		}
		const code = getDynamicField(errorField, "code");
		const message = getDynamicField(errorField, "message");
		const codeI = code.kind === CborKind.Int ? code.intVal as int32 : 0 as int32;
		const messageS = message.kind === CborKind.Text ? asString(message) : "(no message)";
		const empty: CborValue = { kind: CborKind.Null };
		return Result.ok({ id: id, ok: false, result: empty, error: rpcError(codeI, messageS) });
	}
	const resultField = getDynamicField(root, "result");
	const placeholder: SurrealError = { kind: SurrealErrorKind.Internal, message: "", rpcCode: 0 };
	return Result.ok({ id: id, ok: true, result: resultField, error: placeholder });
}

// ===== Internal RPC dispatch =====

function nextRequestId(c: SurrealClient): string {
	const id = c.nextId.toString();
	c.nextId = c.nextId + 1;
	return id;
}

// Tear the connection down on transport failure: mark closed AND force the
// underlying ws fd shut so we don't leak it through `close()`'s open-check.
function abortConnection(c: SurrealClient): void {
	if (!c.open) return;
	c.open = false;
	c.ws.closeSync(WsCloseCode.InternalError as int32, "");
}

// Convenience wrapper for RPCs whose result we don't surface to the caller
// (use, letVar, unsetVar, invalidate, ping, kill). Maps `Result.ok(_) → ()`
// and propagates errors as-is.
function rpcVoid(c: SurrealClient, method: string, params: CborValue[]): Result<void, SurrealError> {
	const r = rpc(c, method, params);
	if (!r.ok) return Result.err(r.error);
	return Result.ok(null as unknown as void);
}

// One in-flight request → wait for matching response.
function rpc(c: SurrealClient, method: string, params: CborValue[]): Result<CborValue, SurrealError> {
	if (!c.open) return Result.err(closed("client closed"));
	const id = nextRequestId(c);
	const reqBytes = buildRequest(id, method, params);
	const sendResult = c.ws.sendBinarySync(reqBytes);
	if (!sendResult.ok) {
		abortConnection(c);
		return Result.err(connectionFailed("send: " + sendResult.error.message));
	}

	// Drain until we see a response with the matching id. Live-subscription
	// notifications interleave with responses on the same connection; we
	// dispatch them to registered callbacks inline so callers running mixed
	// RPC + live workloads don't have to spawn a separate dispatch loop.
	while (true) {
		const recvResult = c.ws.recvSync();
		if (!recvResult.ok) {
			abortConnection(c);
			return Result.err(connectionFailed("recv: " + recvResult.error.message));
		}
		const msg = recvResult.value;
		if (msg.kind === WsMessageKind.Close) {
			abortConnection(c);
			return Result.err(closed("server closed connection"));
		}
		if (msg.kind !== WsMessageKind.Binary) {
			// Server sent text? Not a Surreal RPC response — keep draining.
			continue;
		}
		// Decode once; both the notification check and the response parse
		// look at the same Map root.
		const dr = decodeAll(msg.data);
		if (!dr.ok) {
			return Result.err(decodeError("cbor parse: " + dr.error));
		}
		// Notification first — Surreal notifications have no top-level `id`
		// field so they'd fail the regular response parse.
		if (tryDispatchNotification(c, dr.value)) continue;
		const parsed = decodedToResponse(dr.value);
		if (!parsed.ok) {
			return Result.err(parsed.error);
		}
		const resp = parsed.value;
		if (resp.id !== id) {
			// Stray response with mismatched id — extremely rare (would imply
			// pipelining we don't support). Drop and keep draining.
			continue;
		}
		if (!resp.ok) return Result.err(resp.error);
		return Result.ok(resp.result);
	}
	// unreachable — while(true) only exits via return
	return Result.err(internal("rpc loop exited unexpectedly"));
}

// ===== Public API =====

// Authenticate as a root or namespace/database user.
//   surrealdb.signin({ user, pass })  →  JWT token (string)
export function signin(this c: SurrealClient, user: string, pass: string): Result<string, SurrealError> {
	const credMap = cborTextMap(
		["user", "pass"],
		[cborText(user), cborText(pass)],
	);
	const params: CborValue[] = [credMap];
	const r = rpc(c, "signin", params);
	if (!r.ok) {
		// Map server-side auth failure to a more specific kind.
		if (r.error.kind === SurrealErrorKind.Rpc) {
			return Result.err(authFailed(r.error.message));
		}
		return Result.err(r.error);
	}
	if (r.value.kind !== CborKind.Text) {
		return Result.err(decodeError("signin returned non-text result (kind=" + r.value.kind.toString() + ")"));
	}
	return Result.ok(asString(r.value));
}

// Sign up a new user. `creds` is a pre-built CborValue map containing the
// scope/access-method-specific fields the server expects (typically NS, DB,
// AC + record-scope auth fields). Returns the JWT.
//
// Caller builds the map manually for now — different scopes/access methods
// take different fields, so we don't pin a fixed signature.
export function signup(this c: SurrealClient, creds: CborValue): Result<string, SurrealError> {
	const params: CborValue[] = [creds];
	const r = rpc(c, "signup", params);
	if (!r.ok) {
		if (r.error.kind === SurrealErrorKind.Rpc) {
			return Result.err(authFailed(r.error.message));
		}
		return Result.err(r.error);
	}
	if (r.value.kind !== CborKind.Text) {
		return Result.err(decodeError("signup returned non-text result (kind=" + r.value.kind.toString() + ")"));
	}
	return Result.ok(asString(r.value));
}

// Re-authenticate using a previously-issued JWT. Useful for restoring a
// session after reconnect.
export function authenticate(this c: SurrealClient, token: string): Result<void, SurrealError> {
	const params: CborValue[] = [cborText(token)];
	const r = rpc(c, "authenticate", params);
	if (!r.ok) {
		if (r.error.kind === SurrealErrorKind.Rpc) {
			return Result.err(authFailed(r.error.message));
		}
		return Result.err(r.error);
	}
	return Result.ok(null as unknown as void);
}

// Drop the current session's auth state (logout). The connection itself
// stays open; subsequent calls fall back to whatever permission level the
// server's anonymous user has.
export function invalidate(this c: SurrealClient): Result<void, SurrealError> {
	const params: CborValue[] = [];
	return rpcVoid(c, "invalidate", params);
}

// Set a session variable. The server makes `$key` available inside subsequent
// SurrealQL queries on this connection. Method is named `letVar` (not `let`)
// because `let` is a reserved keyword.
export function letVar(this c: SurrealClient, key: string, value: CborValue): Result<void, SurrealError> {
	return rpcVoid(c, "let", [cborText(key), value]);
}

// Clear a session variable. Mirror of `letVar` for symmetry; `unset` itself
// isn't a keyword but we follow the same suffix convention.
export function unsetVar(this c: SurrealClient, key: string): Result<void, SurrealError> {
	return rpcVoid(c, "unset", [cborText(key)]);
}

// Select active namespace + database for this connection.
export function use(this c: SurrealClient, ns: string, db: string): Result<void, SurrealError> {
	return rpcVoid(c, "use", [cborText(ns), cborText(db)]);
}

// Run an arbitrary SurrealQL string. Returns the raw result tree (typically
// an Array of statement results). Caller inspects via cbor accessors.
//
// V0 doesn't take parameter bindings — pass them inlined for now or call
// `query()` (below) with a pre-built variables map.
export function queryStr(this c: SurrealClient, sql: string): Result<CborValue, SurrealError> {
	const params: CborValue[] = [cborText(sql)];
	return rpc(c, "query", params);
}

// Run a SurrealQL string with a variables map. Caller pre-builds the vars
// CborValue (most often via `cborTextMap(keys, values)`).
export function query(this c: SurrealClient, sql: string, vars: CborValue): Result<CborValue, SurrealError> {
	const params: CborValue[] = [cborText(sql), vars];
	return rpc(c, "query", params);
}

// Fetch records by table name or RecordId-as-string ("table:id").
export function select(this c: SurrealClient, thing: string): Result<CborValue, SurrealError> {
	const params: CborValue[] = [cborText(thing)];
	return rpc(c, "select", params);
}

// Create a record. `thing` is either a table name (server generates id) or
// "table:id" for explicit id. `data` is the record body as a CborValue
// (usually `cborTextMap`).
export function create(this c: SurrealClient, thing: string, data: CborValue): Result<CborValue, SurrealError> {
	const params: CborValue[] = [cborText(thing), data];
	return rpc(c, "create", params);
}

// Replace the entire content of records matching `thing` with `data`.
export function update(this c: SurrealClient, thing: string, data: CborValue): Result<CborValue, SurrealError> {
	const params: CborValue[] = [cborText(thing), data];
	return rpc(c, "update", params);
}

// Merge `data` into existing records matching `thing` (partial update).
export function merge(this c: SurrealClient, thing: string, data: CborValue): Result<CborValue, SurrealError> {
	const params: CborValue[] = [cborText(thing), data];
	return rpc(c, "merge", params);
}

// Delete records matching `thing`. Returns the deleted records.
export function deleteRecord(this c: SurrealClient, thing: string): Result<CborValue, SurrealError> {
	const params: CborValue[] = [cborText(thing)];
	return rpc(c, "delete", params);
}

// ===== Live subscriptions =====

// Register a LIVE SELECT subscription. The callback fires for every
// CREATE/UPDATE/DELETE on records matching the query, with the `result` Map
// from the notification — i.e. the Map containing { action, id, record,
// result, session }. Caller inspects via cbor accessors.
//
// Returns the UUID Tag the server assigned. Pass it to `kill(uuid)` to
// unsubscribe.
//
// Mixed-mode (live + regular RPC on same connection): callers can keep
// calling `query`/`select`/etc.; the rpc() loop dispatches incoming
// notifications inline as it drains. No extra setup needed.
//
// Subscribe-only mode (live-only, no other RPC traffic): caller must drive
// the receive loop itself. Spawn a background task that calls
// `dispatchLoop()` so notifications keep flowing while the main task
// blocks elsewhere:
//
//   spawn(() => c.dispatchLoop());
//
// Caveats:
//   - Callbacks run synchronously on the rpc-driving thread. A slow callback
//     stalls the original RPC's response delivery by the same amount —
//     keep them short, or hand heavy work off via an internal queue/spawn.
//   - `query` is concatenated as `"LIVE " + query` and sent to the server
//     verbatim. The caller is trusted to pass safe SurrealQL (this is the
//     wire protocol's design — there is no parameterised LIVE form).
export function live(this c: SurrealClient, query: string, callback: (notification: CborValue) => void): Result<CborValue, SurrealError> {
	if (!c.open) return Result.err(closed("client closed"));
	const r = rpc(c, "query", [cborText("LIVE " + query)]);
	if (!r.ok) return Result.err(r.error);
	// Surreal wraps query results: [{ status, time, result: <UUID-Tag> }].
	// On error the same shape carries `status: "ERR"`, `result: <message Text>`,
	// and an optional `kind` discriminator.
	if (r.value.kind !== CborKind.Array || length(r.value) === 0) {
		return Result.err(decodeError("LIVE response not an Array of statement results"));
	}
	const stmt0 = at(r.value, 0);
	if (stmt0.kind !== CborKind.Map) {
		return Result.err(decodeError("LIVE statement result not a Map"));
	}
	const status = getDynamicField(stmt0, "status");
	if (status.kind === CborKind.Text && asString(status) !== "OK") {
		const msg = getDynamicField(stmt0, "result");
		const msgText = msg.kind === CborKind.Text ? asString(msg) : "(non-text error message)";
		return Result.err(rpcError(0 as int32, "LIVE failed: " + msgText));
	}
	const innerResult = getDynamicField(stmt0, "result");
	if (innerResult.kind !== CborKind.Tag) {
		return Result.err(decodeError("LIVE result not a UUID Tag (kind=" + innerResult.kind.toString() + ")"));
	}
	const sub: LiveSubscription = { uuid: innerResult, callback: callback };
	c._liveSubs.push(sub);
	return Result.ok(innerResult);
}

// Cancel a previously-registered live subscription. Idempotent — calling
// kill twice with the same uuid removes the local registration on first
// call and no-ops on the second (the server will simply have no record of
// the second KILL, which it tolerates).
export function kill(this c: SurrealClient, uuid: CborValue): Result<void, SurrealError> {
	// Remove local registration first so any lingering notifications get
	// dropped silently rather than calling a stale callback.
	let removed = false;
	let kept: LiveSubscription[] = [];
	for (let i: int32 = 0; i < c._liveSubs.length; i = i + 1) {
		if (!removed && cborTagEquals(c._liveSubs[i].uuid, uuid)) {
			removed = true;
			continue;
		}
		kept.push(c._liveSubs[i]);
	}
	c._liveSubs = kept;

	return rpcVoid(c, "kill", [uuid]);
}

// Drain one inbound frame and dispatch it. Returns:
//   Result.ok(true)  — frame dispatched as a live notification
//   Result.ok(false) — frame was a stray response (unlikely; drained)
//   Result.err       — connection-level failure
//
// Useful when the caller is in subscribe-only mode and needs to keep the
// socket warm.
export function dispatchOnce(this c: SurrealClient): Result<boolean, SurrealError> {
	if (!c.open) return Result.err(closed("client closed"));
	const recvResult = c.ws.recvSync();
	if (!recvResult.ok) {
		abortConnection(c);
		return Result.err(connectionFailed("recv: " + recvResult.error.message));
	}
	const msg = recvResult.value;
	if (msg.kind === WsMessageKind.Close) {
		abortConnection(c);
		return Result.err(closed("server closed connection"));
	}
	if (msg.kind !== WsMessageKind.Binary) {
		return Result.ok(false);
	}
	const dr = decodeAll(msg.data);
	if (!dr.ok) return Result.err(decodeError("cbor parse: " + dr.error));
	if (tryDispatchNotification(c, dr.value)) return Result.ok(true);
	// Stray response — most likely a delayed reply we already moved past.
	// Drop quietly.
	return Result.ok(false);
}

// Forever-loop that drives `dispatchOnce` until the client closes or the
// connection drops. Intended to run in a `spawn(() => c.dispatchLoop())`
// background task so the main caller can do other work.
export function dispatchLoop(this c: SurrealClient): Result<void, SurrealError> {
	while (c.open) {
		const r = c.dispatchOnce();
		if (!r.ok) return Result.err(r.error);
	}
	return Result.ok(null as unknown as void);
}

// ===== Misc =====

// Keepalive ping — useful behind idle proxies.
export function ping(this c: SurrealClient): Result<void, SurrealError> {
	const params: CborValue[] = [];
	return rpcVoid(c, "ping", params);
}

// Close the connection cleanly. Idempotent.
export function close(this c: SurrealClient): Result<void, SurrealError> {
	if (!c.open) return Result.ok(null as unknown as void);
	c.open = false;
	const cr = c.ws.closeSync(WsCloseCode.Normal as int32, "bye");
	if (!cr.ok) return Result.err(connectionFailed("ws close: " + cr.error.message));
	return Result.ok(null as unknown as void);
}

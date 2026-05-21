// LIVE SELECT subscriptions + dispatch loops.
//
// Two operating modes:
//   - Mixed mode (live + regular RPC on same connection): callers keep
//     calling `query`/`select`/etc.; the internal rpc() loop drains
//     notifications inline.
//   - Subscribe-only mode: caller spawns a background task that drives
//     `dispatchLoop()` so notifications keep flowing while the main
//     task blocks elsewhere.
//
//   spawn(() => c.dispatchLoop());

import { WsMessageKind } from "std/core/websocket";
import { CborKind, CborValue } from "std/serialize/cbor/types";
import { cborText } from "std/serialize/cbor/builder";
import { getDynamicField, asString, length, at } from "std/serialize/cbor/accessors";
import { decodeAll } from "std/serialize/cbor/decoder";
import { SurrealError, decodeError, rpcError, connectionFailed, closed } from "./errors";
import {
	SurrealClient, LiveSubscription,
	rpc, rpcVoid, cborTagEquals, tryDispatchNotification, abortConn,
} from "./client";

// Register a LIVE SELECT subscription. The callback fires for every
// CREATE/UPDATE/DELETE on records matching the query, with the `result` Map
// from the notification — i.e. the Map containing { action, id, record,
// result, session }.
//
// Returns the UUID Tag the server assigned. Pass it to `kill(uuid)` to
// unsubscribe.
//
// Caveats:
//   - Callbacks run synchronously on the rpc-driving thread. A slow callback
//     stalls the original RPC's response delivery by the same amount —
//     keep them short, or hand heavy work off via an internal queue/spawn.
//   - `query` is concatenated as `"LIVE " + query` and sent verbatim. The
//     caller is trusted to pass safe SurrealQL — the wire protocol has no
//     parameterised LIVE form.
export function live(this c: SurrealClient, query: string, callback: (notification: CborValue) => void): Result<CborValue, SurrealError> {
	if (!c.open) return Result.err(closed("client closed"));
	const r = rpc(c, "query", [cborText("LIVE " + query)]);
	if (!r.ok) return Result.err(r.error);
	// Surreal wraps query results: [{ status, time, result: <UUID-Tag> }].
	// On error the same shape carries `status: "ERR"`, `result: <message Text>`.
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
// call and no-ops on the second (the server tolerates an unknown KILL).
export function kill(this c: SurrealClient, uuid: CborValue): Result<void, SurrealError> {
	// Remove local registration first so any lingering notifications get
	// dropped silently rather than calling a stale callback.
	let removed = false;
	const kept: LiveSubscription[] = [];
	for (const sub of c._liveSubs) {
		if (!removed && cborTagEquals(sub.uuid, uuid)) {
			removed = true;
			continue;
		}
		kept.push(sub);
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
		abortConn(c);
		return Result.err(connectionFailed("recv: " + recvResult.error.message));
	}
	const msg = recvResult.value;
	if (msg.kind === WsMessageKind.Close) {
		abortConn(c);
		return Result.err(closed("server closed connection"));
	}
	if (msg.kind !== WsMessageKind.Binary) return Result.ok(false);
	const dr = decodeAll(msg.data);
	if (!dr.ok) return Result.err(decodeError("cbor parse: " + dr.error));
	if (tryDispatchNotification(c, dr.value)) return Result.ok(true);
	// Stray response — most likely a delayed reply we already moved past.
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
	return Result.ok(null);
}

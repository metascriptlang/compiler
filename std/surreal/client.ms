// SurrealDB client — base layer.
//
// Owns: connection state (`SurrealClient`), socket open/close, internal
// CBOR-RPC dispatch (`rpc`/`rpcVoid`/`rpcText`), and the live-notification
// drain that runs on every read.
//
// User-facing wrappers live in sibling files:
//   - auth.ms   : signin/signup/authenticate/invalidate + use/letVar/unsetVar/reset/info/version
//   - crud.ms   : selectRaw/createRaw/... + recordId + exists + relate/insertRelation + patch + run + queryStr/query
//   - typed.ms  : Surreal class + macro-driven typed decode
//   - live.ms   : LIVE SELECT subscriptions + dispatch loop

import { connectSync, sendBinarySync, recvSync, closeSync, WsClient, WsCloseCode, WsMessageKind, ConnectOptions } from "std/core/websocket";
import { CborKind, CborValue } from "std/serialize/cbor/types";
import { cborText, cborTextMap, cborArray } from "std/serialize/cbor/builder";
import { getDynamicField, asString, length } from "std/serialize/cbor/accessors";
import { decodeAll } from "std/serialize/cbor/decoder";
import { buildRequest, RpcResponse } from "./rpc";
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
	const wsOpts: ConnectOptions = {
		subprotocols: ["cbor"],
		extraHeaders: [],
		recvSendTimeoutMs: 30000,
	};
	const wsResult = connectSync(url, wsOpts);
	if (!wsResult.ok) return Result.err(connectionFailed("ws connect: " + wsResult.error.message));
	const ws = wsResult.value;
	if (ws.subprotocol !== "cbor") {
		// Server didn't negotiate cbor — we can't speak any other format.
		ws.closeSync(WsCloseCode.UnsupportedData as int32, "");
		return Result.err(connectionFailed("server did not negotiate 'cbor' subprotocol (got '" + ws.subprotocol + "')"));
	}
	const liveSubs: LiveSubscription[] = [];
	return Result.ok({ ws: ws, nextId: 1 as int32, open: true, _liveSubs: liveSubs });
}

// ===== Internal helpers (exported for sibling modules in std/surreal/) =====

// Deep-equal a CBOR Tag (used for matching live UUID notifications against
// registered subscriptions). Surreal sends UUIDs as a Tag wrapping either
// raw 16-byte Bytes or a Text representation; we handle both.
export function cborTagEquals(a: CborValue, b: CborValue): boolean {
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
// the original RPC's response by the same amount.
export function tryDispatchNotification(c: SurrealClient, root: CborValue): boolean {
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
	for (const sub of c._liveSubs) {
		if (cborTagEquals(sub.uuid, liveId)) {
			sub.callback(result);
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
export function rpcVoid(c: SurrealClient, method: string, params: CborValue[]): Result<void, SurrealError> {
	const r = rpc(c, method, params);
	if (!r.ok) return Result.err(r.error);
	return Result.ok(null as unknown as void);
}

// RPC that expects a Text result. Wraps `rpc` + kind check + asString.
// `label` is folded into the error message on shape mismatch.
export function rpcText(c: SurrealClient, method: string, params: CborValue[], label: string): Result<string, SurrealError> {
	const r = rpc(c, method, params);
	if (!r.ok) return Result.err(r.error);
	if (r.value.kind !== CborKind.Text) {
		return Result.err(decodeError(label + ": expected Text, got kind=" + r.value.kind.toString()));
	}
	return Result.ok(asString(r.value));
}

// Map a server-side Rpc error to AuthFailed; pass through transport errors.
// Used by signin / signup / authenticate to surface bad-credentials as a
// dedicated kind callers can branch on.
export function mapAuthErr(err: SurrealError): SurrealError {
	if (err.kind === SurrealErrorKind.Rpc) return authFailed(err.message);
	return err;
}

// One in-flight request → wait for matching response. Drains live
// notifications inline so callers running mixed RPC + LIVE workloads
// don't need a separate dispatch task.
export function rpc(c: SurrealClient, method: string, params: CborValue[]): Result<CborValue, SurrealError> {
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
	// dispatch them to registered callbacks inline.
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
		if (msg.kind !== WsMessageKind.Binary) continue;   // text frames aren't Surreal RPC
		const dr = decodeAll(msg.data);
		if (!dr.ok) return Result.err(decodeError("cbor parse: " + dr.error));
		// Notification first — Surreal notifications have no top-level `id`
		// field so they'd fail the regular response parse.
		if (tryDispatchNotification(c, dr.value)) continue;
		const parsed = decodedToResponse(dr.value);
		if (!parsed.ok) return Result.err(parsed.error);
		const resp = parsed.value;
		if (resp.id !== id) continue;   // stray mismatched response — drop & keep draining
		if (!resp.ok) return Result.err(resp.error);
		return Result.ok(resp.result);
	}
	// unreachable — while(true) only exits via return
	return Result.err(internal("rpc loop exited unexpectedly"));
}

// ===== Connection lifecycle =====

// Keepalive ping — useful behind idle proxies.
export function ping(this c: SurrealClient): Result<void, SurrealError> {
	return rpcVoid(c, "ping", []);
}

// Close the connection cleanly. Idempotent.
export function close(this c: SurrealClient): Result<void, SurrealError> {
	if (!c.open) return Result.ok(null as unknown as void);
	c.open = false;
	const cr = c.ws.closeSync(WsCloseCode.Normal as int32, "bye");
	if (!cr.ok) return Result.err(connectionFailed("ws close: " + cr.error.message));
	return Result.ok(null as unknown as void);
}

// Mark the connection torn down without sending a close frame. Exported for
// the dispatch loop in live.ms (transport errors there must abort the same
// way as inside rpc()).
export function abortConn(c: SurrealClient): void { abortConnection(c); }

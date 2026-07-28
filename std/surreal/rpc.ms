// SurrealDB RPC envelope codec.
//
// Wire shape (CBOR-encoded over a WebSocket binary frame):
//   Request:   { id: <text>, method: <text>, params: <array> }
//   Response:  { id: <same>, result: <any> }                 — success
//              { id: <same>, error: { code: <int>, message: <text> } } — failure
//
// This module is pure CBOR-tree manipulation — no socket access. The actual
// wire I/O happens in `./client`. Keeping it pure lets us drive the codec
// from inline tests without spinning up a server.

// Import from submodules directly.
import { CborKind, CborValue } from "std/serialize/cbor/types";
import { cborText, cborTextMap, cborArray } from "std/serialize/cbor/builder";
import { newCborWriter, encodeValue } from "std/serialize/cbor/encoder";
import { decodeAll } from "std/serialize/cbor/decoder";
import { getDynamicField, asString, asInt32 } from "std/serialize/cbor/accessors";
import { SurrealError, SurrealErrorKind, decodeError, rpcError } from "./errors";

// ===== Request =====

// Build a CBOR-encoded request frame as `number[]` bytes (each element 0..255).
// `params` is the list of method arguments — the caller constructs each as a
// CborValue (e.g. `cborText("users:abc")` for a record id, or `cborTextMap`
// for a credential record).
//
// Returns `number[]` rather than Buffer/string so the caller can hand the
// frame straight to `ws.sendBinarySync(...)` (which takes `number[]`)
// without an extra encoding hop.
export function buildRequest(id: string, method: string, params: CborValue[]): number[] {
	const envelope = cborTextMap(
		["id", "method", "params"],
		[cborText(id), cborText(method), cborArray(params)],
	);
	const w = newCborWriter();
	encodeValue(w, envelope);
	return w.bytes;
}

// ===== Response =====

// Parsed response. Exactly one of `ok` / `err` is meaningful.
export interface RpcResponse {
	id: string;
	ok: boolean;
	result: CborValue;       // valid when ok
	error: SurrealError;     // valid when !ok
}

// Parse a CBOR-encoded response frame (raw bytes). Returns Result.err on:
//   - CBOR parse failure
//   - response not a map
//   - id field missing or not text
//   - neither result nor error present
//
// Otherwise returns Result.ok with `RpcResponse.ok` indicating server-side
// success vs failure. Server errors come back as `Result.ok({ ok: false,
// error: rpcError(...) })` so the caller can correlate by `id` first.
export function parseResponse(bytes: number[]): Result<RpcResponse, SurrealError> {
	const dr = decodeAll(bytes);
	if (!dr.ok) {
		return Result.err(decodeError("cbor parse: " + dr.error));
	}
	const root = dr.value;
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
		// Server reported an error.
		if (errorField.kind !== CborKind.Map) {
			return Result.err(decodeError("response.error is not a Map"));
		}
		const code = asInt32(getDynamicField(errorField, "code"));
		const message = asString(getDynamicField(errorField, "message"));
		const empty: CborValue = { kind: CborKind.Null };
		return Result.ok({
			id: id,
			ok: false,
			result: empty,
			error: rpcError(code, message),
		});
	}

	const resultField = getDynamicField(root, "result");
	// Even Null is a legitimate result (e.g. `use` returns NONE → tag(6)/null).
	// Placeholder error — the `ok: true` flag tells callers to ignore it.
	const placeholder: SurrealError = { kind: SurrealErrorKind.Internal, message: "", rpcCode: 0 };
	return Result.ok({
		id: id,
		ok: true,
		result: resultField,
		error: placeholder,
	});
}

// ===== Tests =====

// Helper: encode a CborValue to bytes via the same writer the public API uses.
function encodeToBytes(v: CborValue): number[] {
	const w = newCborWriter();
	encodeValue(w, v);
	return w.bytes;
}

test "buildRequest emits Map with id/method/params and decodes back" {
	const empty: CborValue[] = [];
	const bytes = buildRequest("p1", "ping", empty);
	const r = decodeAll(bytes);
	assert r.ok;
	const v = r.value;
	assert v.kind === CborKind.Map;
	assert asString(getDynamicField(v, "id")) === "p1";
	assert asString(getDynamicField(v, "method")) === "ping";
}

test "buildRequest preserves params array" {
	const params: CborValue[] = [cborText("foo"), cborText("bar")];
	const bytes = buildRequest("q1", "query", params);
	const r = decodeAll(bytes);
	assert r.ok;
	const paramsField = getDynamicField(r.value, "params");
	assert paramsField.kind === CborKind.Array;
}

test "parseResponse success — id + result map" {
	const respValue = cborTextMap(
		["id", "result"],
		[cborText("p1"), cborText("ok")],
	);
	const bytes = encodeToBytes(respValue);
	const r = parseResponse(bytes);
	assert r.ok;
	const resp = r.value;
	assert resp.ok;
	assert resp.id === "p1";
	assert resp.result.kind === CborKind.Text;
	assert asString(resp.result) === "ok";
}

test "parseResponse failure — server error map" {
	const errMap = cborTextMap(
		["code", "message"],
		[cborText("-32600"), cborText("Invalid Request")],
	);
	const respValue = cborTextMap(
		["id", "error"],
		[cborText("q1"), errMap],
	);
	const bytes = encodeToBytes(respValue);
	const r = parseResponse(bytes);
	assert r.ok;
	const resp = r.value;
	assert !resp.ok;
	assert resp.id === "q1";
	assert resp.error.message === "Invalid Request";
}

test "parseResponse rejects non-map root" {
	const bytes = encodeToBytes(cborText("not a map"));
	const r = parseResponse(bytes);
	assert !r.ok;
}

test "parseResponse rejects missing id" {
	const respValue = cborTextMap(["result"], [cborText("ok")]);
	const bytes = encodeToBytes(respValue);
	const r = parseResponse(bytes);
	assert !r.ok;
}

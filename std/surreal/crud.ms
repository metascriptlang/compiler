// Raw CRUD + adjacent data operations.
//
// Every public function here returns `Result<CborValue, SurrealError>` —
// callers inspect via the CBOR untyped tree (`getDynamicField`, `asString`,
// `at`, `length`, ...). For typed decode use the `Surreal` class from
// `./typed`.
//
// Groups:
//   - Queries        : queryStr / query
//   - Single-record  : selectRaw / createRaw / updateRaw / mergeRaw / deleteRecordRaw / upsertRaw
//   - Bulk           : insertRaw
//   - Graph          : relateRaw / insertRelationRaw + recordId helper
//   - JSON Patch     : patch (auto-builds RecordId Tag for "table:id" form)
//   - Server fn      : run
//   - Existence      : exists (boolean wrapper over selectRaw)

import { CborKind, CborValue } from "std/serialize/cbor/types";
import { cborText, cborTextMap, cborArray, cborTag } from "std/serialize/cbor/builder";
import { length } from "std/serialize/cbor/accessors";
import { SurrealError, SurrealErrorKind } from "./errors";
import { SurrealClient, rpc } from "./client";

// ===== Constants =====

// SurrealDB CBOR Tag number for RecordId values (`Tag(8, [table, id])`).
// Documented in the v3 wire-format spec.
const SURREAL_TAG_RECORD_ID: int64 = 8 as int64;

// ===== Queries =====

// Run an arbitrary SurrealQL string. Returns the raw result tree (typically
// an Array of statement results).
//
// Doesn't take parameter bindings — pass them inlined or call `query()` with
// a pre-built variables map.
export function queryStr(this c: SurrealClient, sql: string): Result<CborValue, SurrealError> {
	return rpc(c, "query", [cborText(sql)]);
}

// Run a SurrealQL string with a variables map. Caller pre-builds the vars
// CborValue (most often via `cborTextMap(keys, values)`).
export function query(this c: SurrealClient, sql: string, vars: CborValue): Result<CborValue, SurrealError> {
	return rpc(c, "query", [cborText(sql), vars]);
}

// ===== Raw CRUD — return untyped CborValue =====

// Fetch records by table name or RecordId-as-string ("table:id"). Raw form.
export function selectRaw(this c: SurrealClient, thing: string): Result<CborValue, SurrealError> {
	return rpc(c, "select", [cborText(thing)]);
}

// Create a record. `thing` is either a table name (server generates id) or
// "table:id" for explicit id. Raw form.
export function createRaw(this c: SurrealClient, thing: string, data: CborValue): Result<CborValue, SurrealError> {
	return rpc(c, "create", [cborText(thing), data]);
}

// Replace the entire content of records matching `thing` with `data`. Raw form.
export function updateRaw(this c: SurrealClient, thing: string, data: CborValue): Result<CborValue, SurrealError> {
	return rpc(c, "update", [cborText(thing), data]);
}

// Merge `data` into existing records matching `thing` (partial update). Raw form.
export function mergeRaw(this c: SurrealClient, thing: string, data: CborValue): Result<CborValue, SurrealError> {
	return rpc(c, "merge", [cborText(thing), data]);
}

// Delete records matching `thing`. Returns the deleted records. Raw form.
export function deleteRecordRaw(this c: SurrealClient, thing: string): Result<CborValue, SurrealError> {
	return rpc(c, "delete", [cborText(thing)]);
}

// Bulk insert. `data` is either a single record map or an Array of record
// maps. Raw form — returns the Array of created records.
export function insertRaw(this c: SurrealClient, thing: string, data: CborValue): Result<CborValue, SurrealError> {
	return rpc(c, "insert", [cborText(thing), data]);
}

// Create-or-replace a record. With "table:id" replaces the record body
// wholesale, inserts if absent. Returns an Array(1) wrapping the record.
export function upsertRaw(this c: SurrealClient, thing: string, data: CborValue): Result<CborValue, SurrealError> {
	return rpc(c, "upsert", [cborText(thing), data]);
}

// ===== Graph relations =====

// Build a Surreal RecordId CBOR value — Tag 8 wrapping `[table, id]`.
// Required for `relate` / `insertRelation` whose RPC params expect typed
// record refs, not bare strings like "table:id". Also yields a slightly
// tighter return shape from `select` (single Map instead of 1-element Array).
export function recordId(table: string, id: string): CborValue {
	return cborTag(SURREAL_TAG_RECORD_ID, cborArray([cborText(table), cborText(id)]));
}

// Create a graph edge from `from` to `to` via the `edge` table.
//
// `from` and `to` MUST be RecordId values (Tag 8 wrapping `[table, id]`).
// Use the `recordId(table, id)` helper to build them. `data` carries extra
// fields on the edge record (pass an empty map if none).
//
// Wire return is a single Map (the created edge record). Raw form.
export function relateRaw(this c: SurrealClient, from: CborValue, edge: string, to: CborValue, data: CborValue): Result<CborValue, SurrealError> {
	return rpc(c, "relate", [from, cborText(edge), to, data]);
}

// Bulk graph-edge creation. `data` is a Map (or Array of Maps) carrying
// `in`, `out`, and any extra edge fields. Each `in`/`out` MUST be a
// RecordId (Tag 8). Returns an Array of created edge records. Raw form.
export function insertRelationRaw(this c: SurrealClient, table: string, data: CborValue): Result<CborValue, SurrealError> {
	return rpc(c, "insert_relation", [cborText(table), data]);
}

// ===== JSON Patch =====

// Apply JSON Patch (RFC 6902) operations to records. `patches` is an Array of
// patch operation maps: `[{op: "replace", path: "/name", value: "..."}, ...]`.
// Returns an Array of per-record patch result arrays. The shape is too
// freeform for typed decode — inspect via CBOR accessors.
//
// Wire quirk: the `patch` RPC method treats a bare Text param as a TABLE name
// (unlike `select`/`update`/`merge` which auto-parse "table:id"). For UX
// parity, we split on the FIRST ':' and build a RecordId Tag so
// `patch("table:id", ...)` targets a single record. `colon > 0` (not `>= 0`)
// rejects `":abc"` malformed input — let the server emit the meaningful error.
export function patch(this c: SurrealClient, thing: string, patches: CborValue): Result<CborValue, SurrealError> {
	let thingCbor: CborValue = cborText(thing);
	const colon = thing.indexOf(":");
	if (colon > 0 as int64 && (colon + 1 as int64) < thing.length as int64) {
		const table = thing.slice(0 as int64, colon);
		const id = thing.slice(colon + 1 as int64, thing.length as int64);
		thingCbor = recordId(table, id);
	}
	return rpc(c, "patch", [thingCbor, patches]);
}

// ===== Server-side functions =====

// Call a server-side function previously defined with `DEFINE FUNCTION` or
// the `fn::` / `ml::` namespaces. `args` is an Array of CBOR values to pass.
// `version` is the ML model version string (e.g. "v1.2.3") — leave empty for
// regular `fn::` functions. Caller inspects the raw result; shape depends on
// fn body.
export function run(this c: SurrealClient, fn: string, args: CborValue, version: string = ""): Result<CborValue, SurrealError> {
	return rpc(c, "run", [cborText(fn), cborText(version), args]);
}

// ===== Existence check =====

// True when at least one record matches `thing`. Wraps `select` and inspects
// the result length without decoding bodies.
//
// Surreal v3 returns a "table 'X' does not exist" Rpc error when the table
// was never created. We downgrade that specific case to `false` so callers
// can write `if (try exists(c, t)) { ... }` without special-casing missing
// tables. Other transport / auth errors still propagate.
//
// CAVEAT: the "does not exist" detection is a string-match on the server's
// error message — fragile to wording changes. Verified against SurrealDB
// v3.0.5; if a future server release rewords the error, this branch silently
// stops firing and `exists` would surface the Rpc error instead.
export function exists(this c: SurrealClient, thing: string): Result<boolean, SurrealError> {
	const r = selectRaw(c, thing);
	if (!r.ok) {
		if (r.error.kind == SurrealErrorKind.Rpc && r.error.message.contains("does not exist")) {
			return Result.ok(false);
		}
		return Result.err(r.error);
	}
	if (r.value.kind == CborKind.Map) return Result.ok(true);   // direct single-record return (RecordId Tag form)
	if (r.value.kind != CborKind.Array) return Result.ok(false);
	return Result.ok(length(r.value) > 0);
}

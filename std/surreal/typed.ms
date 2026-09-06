// Typed CRUD — decode result into user-supplied struct/interface T.
//
// Usage:
//   interface Post { title: string; n: int32; }
//   const r = Surreal.select<Post>(c, "posts");       // Result<Post[], SurrealError>
//   const c1 = Surreal.create<Post>(c, "posts", body); // Result<Post, SurrealError>
//
// T must be a struct or interface. The `cborValueToStruct` macro emits inline
// field-by-field construction at each monomorphization; atomic types (number,
// string, etc.) and union types are rejected at compile time.
//
// Why a static class instead of `c.select<T>(...)` extension methods: extension
// method dispatch with explicit type args (`obj.method<T>(args)`) doesn't
// propagate T through return-type substitution at codegen mangling, producing
// `Result<unknown, _>` instead of `Result<T, _>`. Static class methods route
// through the regular generic dispatch path (same as JSON.parse<T>) and work
// correctly.

import { CborKind, CborValue } from "std/serialize/cbor/types";
import { length, at } from "std/serialize/cbor/accessors";
import { cborValueToStruct } from "std/serialize/cbor/decode";
import { SurrealError, decodeError } from "./errors";
import { SurrealClient } from "./client";
import {
	selectRaw, createRaw, updateRaw, mergeRaw, deleteRecordRaw,
	insertRaw, upsertRaw, relateRaw, insertRelationRaw,
} from "./crud";

// ===== Decode helpers =====

// Decode a CborValue Array into T[] using `cborValueToStruct<T>` per item.
function decodeArray<T>(cv: CborValue, witness: T | null): Result<T[], SurrealError> {
	if (cv.kind != CborKind.Array) {
		return Result.err(decodeError("expected Array result, got kind=" + cv.kind.toString()));
	}
	const out: T[] = [];
	const n = length(cv);
	let i: int64 = 0;
	while (i < n) {
		const item = at(cv, i);
		if (item.kind != CborKind.Map) {
			return Result.err(decodeError("expected Map element at index " + i.toString() + ", got kind=" + item.kind.toString()));
		}
		out.push(cborValueToStruct(item, witness));
		i = i + 1;
	}
	return Result.ok(out);
}

// Decode a single-record result. Surreal sometimes wraps a single record in a
// 1-element Array; peel that case. Empty array → error.
function decodeOne<T>(cv: CborValue, witness: T | null): Result<T, SurrealError> {
	let item = cv;
	if (cv.kind == CborKind.Array) {
		const n = length(cv);
		if (n == 0) return Result.err(decodeError("expected record, got empty array"));
		item = at(cv, 0);
	}
	if (item.kind != CborKind.Map) {
		return Result.err(decodeError("expected record (Map), got kind=" + item.kind.toString()));
	}
	return Result.ok(cborValueToStruct(item, witness));
}

// Bridge: take a raw RPC `Result<CborValue, _>` and a witness, return a typed
// `Result<T[], _>` via decodeArray. Centralizes the unwrap+decode pattern
// shared by select/update/merge/deleteRecord/insert.
function typedMany<T>(raw: Result<CborValue, SurrealError>, witness: T | null): Result<T[], SurrealError> {
	if (!raw.ok) return Result.err(raw.error);
	return decodeArray<T>(raw.value, witness);
}

// Bridge: take a raw RPC `Result<CborValue, _>` and a witness, return a typed
// `Result<T, _>` via decodeOne. Centralizes the unwrap+decode pattern shared
// by create/findById/upsert/relate/insertRelation.
function typedOne<T>(raw: Result<CborValue, SurrealError>, witness: T | null): Result<T, SurrealError> {
	if (!raw.ok) return Result.err(raw.error);
	return decodeOne<T>(raw.value, witness);
}

// ===== Typed surface =====

export class Surreal {
	static select<T>(c: SurrealClient, thing: string): Result<T[], SurrealError> {
		return typedMany<T>(selectRaw(c, thing), null);
	}

	static create<T>(c: SurrealClient, thing: string, data: CborValue): Result<T, SurrealError> {
		return typedOne<T>(createRaw(c, thing, data), null);
	}

	static update<T>(c: SurrealClient, thing: string, data: CborValue): Result<T[], SurrealError> {
		return typedMany<T>(updateRaw(c, thing, data), null);
	}

	static merge<T>(c: SurrealClient, thing: string, data: CborValue): Result<T[], SurrealError> {
		return typedMany<T>(mergeRaw(c, thing, data), null);
	}

	static deleteRecord<T>(c: SurrealClient, thing: string): Result<T[], SurrealError> {
		return typedMany<T>(deleteRecordRaw(c, thing), null);
	}

	// Fetch a single record by RecordId-as-string ("table:id"). Errors if no
	// record matches. Use `select<T>` when you want T[] (zero-or-more).
	static findById<T>(c: SurrealClient, thing: string): Result<T, SurrealError> {
		return typedOne<T>(selectRaw(c, thing), null);
	}

	// Bulk insert. `data` is either a single record map (`cborTextMap(...)`)
	// or an Array of record maps (`cborArray([map1, map2, ...])`).
	static insert<T>(c: SurrealClient, thing: string, data: CborValue): Result<T[], SurrealError> {
		return typedMany<T>(insertRaw(c, thing, data), null);
	}

	// Create-or-replace one record by id. Returns the resulting record.
	static upsert<T>(c: SurrealClient, thing: string, data: CborValue): Result<T, SurrealError> {
		return typedOne<T>(upsertRaw(c, thing, data), null);
	}

	// Create a graph edge `from -> edge -> to`, optionally with extra fields
	// on the edge record. `from` and `to` MUST be RecordId values built via
	// `recordId(table, id)`. Pass `cborTextMap([], [])` for empty data.
	static relate<T>(c: SurrealClient, from: CborValue, edge: string, to: CborValue, data: CborValue): Result<T, SurrealError> {
		return typedOne<T>(relateRaw(c, from, edge, to, data), null);
	}

	// Bulk graph-edge creation. `data` is a Map with at least `in` and `out`
	// RecordId fields (build via `recordId(...)`) plus any edge-record fields.
	static insertRelation<T>(c: SurrealClient, table: string, data: CborValue): Result<T, SurrealError> {
		return typedOne<T>(insertRelationRaw(c, table, data), null);
	}
}

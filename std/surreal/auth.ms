// Authentication + session control + read-only admin RPCs.
//
// Groups by lifecycle:
//   - Auth        : signin / signup / authenticate / invalidate
//   - Session var : use / letVar / unsetVar
//   - Admin       : reset / info / version

import { CborKind, CborValue } from "std/serialize/cbor/types";
import { cborText, cborTextMap } from "std/serialize/cbor/builder";
import { SurrealError, decodeError } from "./errors";
import { SurrealClient, rpc, rpcVoid, rpcText, mapAuthErr } from "./client";

// ===== Authentication =====

// Authenticate as a root or namespace/database user.
//   surrealdb.signin({ user, pass })  →  JWT token (string)
export function signin(this c: SurrealClient, user: string, pass: string): Result<string, SurrealError> {
	const creds = cborTextMap(["user", "pass"], [cborText(user), cborText(pass)]);
	const r = rpcText(c, "signin", [creds], "signin");
	if (!r.ok) return Result.err(mapAuthErr(r.error));
	return Result.ok(r.value);
}

// Sign up a new user. `creds` is a pre-built CborValue map containing the
// scope/access-method-specific fields the server expects (typically NS, DB,
// AC + record-scope auth fields). Returns the JWT.
//
// Caller builds the map manually for now — different scopes/access methods
// take different fields, so we don't pin a fixed signature.
export function signup(this c: SurrealClient, creds: CborValue): Result<string, SurrealError> {
	const r = rpcText(c, "signup", [creds], "signup");
	if (!r.ok) return Result.err(mapAuthErr(r.error));
	return Result.ok(r.value);
}

// Re-authenticate using a previously-issued JWT. Useful for restoring a
// session after reconnect.
export function authenticate(this c: SurrealClient, token: string): Result<void, SurrealError> {
	const r = rpc(c, "authenticate", [cborText(token)]);
	if (!r.ok) return Result.err(mapAuthErr(r.error));
	return Result.ok(null);
}

// Drop the current session's auth state (logout). The connection itself
// stays open; subsequent calls fall back to whatever permission level the
// server's anonymous user has.
export function invalidate(this c: SurrealClient): Result<void, SurrealError> {
	return rpcVoid(c, "invalidate", []);
}

// ===== Session variables =====

// Select active namespace + database for this connection.
export function use(this c: SurrealClient, ns: string, db: string): Result<void, SurrealError> {
	return rpcVoid(c, "use", [cborText(ns), cborText(db)]);
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

// ===== Read-only admin =====

// Server version string (e.g. "surrealdb-3.0.5").
export function version(this c: SurrealClient): Result<string, SurrealError> {
	return rpcText(c, "version", [], "version");
}

// Current session info. Server returns the authenticated record's body for
// record-auth sessions, or a Tag-wrapped null for root/NS/DB auth. Returned
// raw because the shape varies with the auth mode.
export function info(this c: SurrealClient): Result<CborValue, SurrealError> {
	return rpc(c, "info", []);
}

// Clear the current session — drops auth, NS/DB selection, and `let`/`unset`
// variables. The socket stays open. Subsequent calls fall back to anonymous
// permissions until re-authenticated.
export function reset(this c: SurrealClient): Result<void, SurrealError> {
	return rpcVoid(c, "reset", []);
}

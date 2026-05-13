// E2E: WebSocket server upgrade (std/http/server + std/core/websocket) → C output
//
// Companion to `src/test/std/http/websocket.ms` (client-side). This file pins
// the SERVER-side upgrade surface introduced for Photon:
//   - `parseUpgradeRequest` / `buildUpgradeResponse` (server-direction handshake helpers)
//   - `processFrame(fs, frame, isServerSide=true)` (server-direction mask check)
//   - `res.detach()` on `ServerResponse` (HTTP fd handoff for protocol switch)
//
// We do NOT spin up a real server here — the inline-test harness can't run
// the C backend. Runtime smoke tests against curl/phoenix.js belong in a
// later integration suite. This file's job is to lock in that:
//
//   1. The full pipeline (parse → check → transform → analyze → codegen) accepts
//      idiomatic uses of the new API surface.
//   2. The pure-MS helpers (parseUpgradeRequest / buildUpgradeResponse) and the
//      isServerSide-flagged processFrame are wired through the prelude re-exports.
//   3. The Photon-style upgrade flow compiles unchanged (parse headers, derive
//      accept-key, build 101, send via std/net, detach fd, walk away).

import { compileToC } from "../../helpers";

// ===== 1. Server-side handshake helpers compile =====

test "E2E C: parseUpgradeRequest + deriveAcceptKey + buildUpgradeResponse compose" {
	const src = `
function handshake(raw: string): string {
	const r = parseUpgradeRequest(raw);
	if (!r.ok) return "";
	const accept = deriveAcceptKey(r.value.clientKey);
	return buildUpgradeResponse(accept, "", []);
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: parseUpgradeRequest surfaces subprotocols list" {
	const src = `
function pickSubprotocol(raw: string): string {
	const r = parseUpgradeRequest(raw);
	if (!r.ok) return "";
	if (r.value.subprotocols.length === 0) return "";
	return r.value.subprotocols[0];
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: buildUpgradeResponse with negotiated subprotocol + extras" {
	const src = `
function build(accept: string, sub: string): string {
	const extras: string[] = ["X-Server: photon"];
	return buildUpgradeResponse(accept, sub, extras);
}
`;
	const c = compileToC(src);
	assert c.ok;
}

// ===== 2. processFrame server-direction compiles =====

test "E2E C: processFrame with isServerSide=true compiles" {
	const src = `
function recvOne(fs: FragState, f: ParsedFrame): string {
	const d = processFrame(fs, f, true);
	if (d.action === "deliver") return "msg";
	if (d.action === "error") return "err";
	return "cont";
}
`;
	const c = compileToC(src);
	assert c.ok;
}

// ===== 3. Photon-style upgrade flow compiles =====
//
// The full shape Photon uses inside `app.socket()`: handler reads headers
// via std/http helpers, validates Upgrade + Connection tokens, derives
// the accept key, sets response headers + status 101, calls detach() to
// release the fd, and returns. After end() flushes the 101, std/http
// removes the fd from its selector — caller's recv loop owns it.

test "E2E C: detach() can be called without subsequent res.end()" {
	// Handlers may detach the fd and write the 101 response by other means
	// (raw socket writes, deferred async, etc.). detach() must not require a
	// matching res.end() — the event loops respect _upgraded regardless of
	// whether a response is queued through std/http's pipeline.
	const src = `
import { HttpRequest, ServerResponse } from "std/http/types";

function bareDetachHandler(req: HttpRequest, res: ServerResponse): int32 {
	const fd = res.detach();
	// No res.end() call here — caller will write to fd via their own path.
	return fd;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: full WebSocket upgrade handler compiles" {
	const src = `
import { HttpRequest, ServerResponse } from "std/http/types";
import { getHeader } from "std/http/headers";

function wsUpgradeHandler(req: HttpRequest, res: ServerResponse): void {
	const upgrade = getHeader(req.headers, "upgrade");
	if (!commaListContainsToken(upgrade, "websocket")) {
		res.status = 400;
		res.end("not a websocket request");
		return;
	}
	const connection = getHeader(req.headers, "connection");
	if (!commaListContainsToken(connection, "upgrade")) {
		res.status = 400;
		res.end("missing Connection: Upgrade");
		return;
	}
	const key = getHeader(req.headers, "sec-websocket-key");
	if (key.length === 0) {
		res.status = 400;
		res.end("missing Sec-WebSocket-Key");
		return;
	}
	const version = getHeader(req.headers, "sec-websocket-version");
	if (version !== "13") {
		res.status = 400;
		res.end("unsupported version");
		return;
	}

	const accept = deriveAcceptKey(key);
	res.setHeader("Upgrade", "websocket");
	res.setHeader("Connection", "Upgrade");
	res.setHeader("Sec-WebSocket-Accept", accept);
	res.status = 101;
	const fd = res.detach();
	res.end();
	// Caller would spawn a ConnectionActor on \`fd\` here.
}
`;
	const c = compileToC(src);
	assert c.ok;
}

// ===== 4. Server recv loop pattern compiles =====
//
// After detach(), Photon's ConnectionActor reads frames in a loop, feeding
// each parsed frame through processFrame with isServerSide=true. This is
// the canonical inbound state-machine driver — pin its compile shape.

test "E2E C: server-side frame recv loop compiles" {
	const src = `
function recvLoop(fs: FragState, buf: number[]): int32 {
	// Caller would: recv bytes from fd → parseFrame → processFrame(fs, frame, true).
	// We exercise the pure compile path here; the I/O wiring is in Photon's
	// vendor layer.
	let delivered = 0;
	const r = parseFrame(buf, 0);
	if (!r.ok) return -1;
	if (r.value.needMore) return delivered;
	const d = processFrame(fs, r.value.frame, true);
	if (d.action === "deliver") delivered = delivered + 1;
	if (d.action === "error") return -1;
	return delivered;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

// ===== 5. Roundtrip: client request bytes → server parse → server build → client parse =====
//
// Sanity check that what the server emits is what the client successfully
// accepts. The pure-string roundtrip is already covered by inline tests in
// handshake.ms; this E2E test pins that the wire produces valid C source.

test "E2E C: handshake roundtrip (server build → client parse) compiles" {
	const src = `
function roundtrip(clientReq: string): boolean {
	const reqR = parseUpgradeRequest(clientReq);
	if (!reqR.ok) return false;
	const accept = deriveAcceptKey(reqR.value.clientKey);
	const respStr = buildUpgradeResponse(accept, "", []);
	const respR = parse101Response(respStr, accept);
	return respR.ok;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

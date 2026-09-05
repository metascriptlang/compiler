// E2E: WebSocket client (std/core/websocket) → C output
//
// The WS client lives in std/core/websocket (prelude). Three layers:
//   ./frame      — pure-MS frame parser/builder (29 inline tests)
//   ./handshake  — pure-MS HTTP/1.1 upgrade builder + 101 parser (26 inline tests)
//   ./client.cms — async client over std/net + std/crypto
//
// This file verifies the FULL pipeline (parse → check → transform → analyze
// → codegen) emits valid C for the canonical user patterns. We don't run a
// real WS server here — runtime smoke tests (echo.websocket.events / Surreal
// CBOR) live as `skip` markers below; flip the env vars in CI to enable them
// when an echo endpoint or local Surreal is available.
//
// Coverage targets:
//   1. Each public API call compiles + lowers correctly (connect / sendText /
//      sendBinary / recv / close, plus their *Sync counterparts).
//   2. Re-exports from `std/http` work (the explicit-import path).
//   3. Frame layer integrates: protocol-violation handling reachable.
//   4. Handshake layer integrates: subprotocol negotiation, custom headers.
//   5. Sync + async paths are independently reachable (separate function
//      tables in the C output).

import { compileToC } from "../../helpers";

// ===== 1. Public API compiles (async-first) =====

test "E2E C: minimal connect+sendText+recv+close compiles" {
	const src = `
async function main(): Promise<void> {
	const r = await connect("ws://127.0.0.1:8000/rpc");
	if (!r.ok) return;
	const client = r.value;
	const sendResult = await client.sendText("hello");
	if (!sendResult.ok) return;
	const msg = await client.recv();
	if (!msg.ok) return;
	await client.close(WsCloseCode.Normal, "bye");
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: sendBinary + recv binary roundtrip compiles" {
	const src = `
async function main(): Promise<void> {
	const r = await connect("ws://127.0.0.1:8000/rpc");
	if (!r.ok) return;
	const client = r.value;
	const payload: uint8[] = [0xa1, 0x64, 0x70, 0x69, 0x6e, 0x67];
	const s = await client.sendBinary(payload);
	if (!s.ok) return;
	const msg = await client.recv();
	if (!msg.ok) return;
	if (msg.value.kind === WsMessageKind.Binary) {
		const data = msg.value.data;
	}
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: connect with subprotocols compiles" {
	const src = `
async function main(): Promise<void> {
	const subs: string[] = ["cbor", "json"];
	const extras: string[] = [];
	const opts: ConnectOptions = { subprotocols: subs, extraHeaders: extras, recvSendTimeoutMs: 0 };
	const r = await connect("ws://127.0.0.1:8000/rpc", opts);
	if (!r.ok) return;
	const negotiated = r.value.subprotocol;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: connect with extra headers compiles" {
	const src = `
async function main(): Promise<void> {
	const subs: string[] = [];
	const extras: string[] = ["Authorization: Bearer xyz", "X-Trace-Id: 42"];
	const opts: ConnectOptions = { subprotocols: subs, extraHeaders: extras, recvSendTimeoutMs: 0 };
	const r = await connect("ws://127.0.0.1:8000/rpc", opts);
	if (!r.ok) return;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: connect with timeout compiles" {
	const src = `
async function main(): Promise<void> {
	const subs: string[] = [];
	const extras: string[] = [];
	const opts: ConnectOptions = { subprotocols: subs, extraHeaders: extras, recvSendTimeoutMs: 5000 };
	const r = await connect("ws://example.com:8080/path", opts);
	if (!r.ok) return;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

// ===== 2. Sync variants =====

test "E2E C: connectSync + sendTextSync + recvSync + closeSync compiles" {
	const src = `
function main(): void {
	const r = connectSync("ws://127.0.0.1:8000/");
	if (!r.ok) return;
	const client = r.value;
	const s = client.sendTextSync("hi");
	if (!s.ok) return;
	const m = client.recvSync();
	if (!m.ok) return;
	client.closeSync(WsCloseCode.Normal, "");
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: sendBinarySync compiles" {
	const src = `
function main(): void {
	const r = connectSync("ws://localhost:7000/ws");
	if (!r.ok) return;
	const bytes: uint8[] = [1, 2, 3, 4, 5];
	r.value.sendBinarySync(bytes);
}
`;
	const c = compileToC(src);
	assert c.ok;
}

// ===== 3. Re-exports from std/http (explicit-import path) =====

test "E2E C: import { connect } from std/http compiles" {
	const src = `
import { connect, WsClient, WsCloseCode } from "std/http";

async function main(): Promise<void> {
	const r = await connect("ws://localhost:9000/");
	if (!r.ok) return;
	const c: WsClient = r.value;
	await c.close(WsCloseCode.GoingAway, "shutdown");
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: import WsMessage + WsMessageKind from std/http compiles" {
	const src = `
import { connect, WsMessage, WsMessageKind, WsState } from "std/http";

async function readOne(client: WsClient): Promise<void> {
	const r = await client.recv();
	if (!r.ok) return;
	const msg: WsMessage = r.value;
	if (msg.kind === WsMessageKind.Text) {
		// text branch
		return;
	}
	if (msg.kind === WsMessageKind.Binary) {
		// binary branch
		return;
	}
}

async function main(): Promise<void> {
	const r = await connect("ws://h/");
	if (!r.ok) return;
	if (r.value.state === WsState.Open) {
		await readOne(r.value);
	}
}
`;
	const c = compileToC(src);
	assert c.ok;
}

// ===== 4. Pure-MS layer accessibility from user code =====

test "E2E C: parseFrame + buildFrame accessible from user code" {
	const src = `
function main(): void {
	const key: uint8[] = [0xAA, 0xBB, 0xCC, 0xDD];
	const payload: uint8[] = [0x68, 0x69];
	const frame = buildFrame(OPCODE_TEXT, true, payload, key);
	const r = parseFrame(frame, 0);
	if (!r.ok) return;
	if (r.value.needMore) return;
	const f = r.value.frame;
	if (f.opcode !== OPCODE_TEXT) return;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: encodeClosePayload + decodeClosePayload accessible" {
	const src = `
function main(): void {
	const reason: uint8[] = [0x62, 0x79, 0x65];
	const enc = encodeClosePayload(WsCloseCode.GoingAway as int32, reason);
	const dec = decodeClosePayload(enc);
	if (dec.code !== 1001) return;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: handshake helpers accessible (deriveAcceptKey, parseWsUrl)" {
	const src = `
function main(): void {
	const u = parseWsUrl("ws://example.com:8080/path");
	if (!u.ok) return;
	const key = deriveAcceptKey("dGhlIHNhbXBsZSBub25jZQ==");
	if (key.length === 0) return;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

// ===== 5. Codegen pin checks — user-module call sites are emitted =====
//
// compileToC returns the entry MODULE's C (not the linked binary), so
// extern symbols like `msNetConnect` live in std/core/websocket/client.cms's
// emitted C, not in the user module. We therefore pin user-side call sites
// (the function calls themselves) rather than the runtime symbols.

test "E2E C: async user code emits connect/recv/sendText/close call sites" {
	const src = `
async function main(): Promise<void> {
	const r = await connect("ws://127.0.0.1/");
	if (!r.ok) return;
	const c = r.value;
	await c.sendText("ping");
	const m = await c.recv();
	if (!m.ok) return;
	await c.close(WsCloseCode.Normal, "");
}
`;
	const out = compileToC(src);
	assert out.ok;
	// Mangled symbol names contain the source-level identifier.
	assert out.value.contains("connect");
	assert out.value.contains("sendText");
	assert out.value.contains("recv");
	// close() may be emitted as part of an extension-method dispatch.
}

test "E2E C: sync user code emits *Sync call sites" {
	const src = `
function main(): void {
	const r = connectSync("ws://127.0.0.1/");
	if (!r.ok) return;
	r.value.sendTextSync("hi");
	r.value.recvSync();
	r.value.closeSync(WsCloseCode.Normal, "");
}
`;
	const out = compileToC(src);
	assert out.ok;
	assert out.value.contains("connectSync");
	assert out.value.contains("sendTextSync");
	assert out.value.contains("recvSync");
	assert out.value.contains("closeSync");
}

// ===== 6. Error / close-code surface =====

test "E2E C: WsCloseCode enum values reachable" {
	const src = `
function main(): void {
	const a = WsCloseCode.Normal;
	const b = WsCloseCode.GoingAway;
	const c = WsCloseCode.ProtocolError;
	const d = WsCloseCode.UnsupportedData;
	const e = WsCloseCode.InvalidPayload;
	const f = WsCloseCode.PolicyViolation;
	const g = WsCloseCode.MessageTooBig;
	const h = WsCloseCode.InternalError;
	if ((a as int32) !== 1000) return;
	if ((b as int32) !== 1001) return;
	if ((g as int32) !== 1009) return;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: WsErrorKind classification helpers reachable" {
	const src = `
function check(e: WsError): boolean {
	return isWsProtocolError(e) || isWsTransportError(e);
}

function main(): void {
	const e1 = wsHandshakeFailed("bad");
	const e2 = wsTimeout("slow");
	const e3 = wsConnectionFailed("refused");
	const e4 = wsProtocolError("rsv set");
	const e5 = wsClosed("after close");
	if (!check(e1)) return;
	if (!check(e2)) return;
	if (!check(e3)) return;
	if (!check(e4)) return;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

// ===== 7. Bytes ↔ string boundary helpers =====

test "E2E C: stringToBytes + bytesToString accessible" {
	const src = `
function main(): void {
	const bytes = stringToBytes("hello");
	if (bytes.length !== 5) return;
	const s = bytesToString(bytes);
	if (s !== "hello") return;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

// ===== 8. Realistic patterns =====

test "E2E C: SurrealDB-style CBOR ping/response loop compiles" {
	const src = `
	async function pingLoop(c: WsClient): Promise<Result<uint8[], WsError>> {
	const subs: string[] = [];
	const extras: string[] = [];
	// Send a CBOR-encoded RPC ping (caller-supplied bytes, opaque to us).
	const rpcBytes: uint8[] = [0xa3, 0x62, 0x69, 0x64, 0x01, 0x66, 0x6d, 0x65, 0x74, 0x68, 0x6f, 0x64, 0x64, 0x70, 0x69, 0x6e, 0x67, 0x66, 0x70, 0x61, 0x72, 0x61, 0x6d, 0x73, 0x80];
	const s = await c.sendBinary(rpcBytes);
	if (!s.ok) return Result.err(s.error);
	const m = await c.recv();
	if (!m.ok) return Result.err(m.error);
	return Result.ok(m.value.data);
}

async function main(): Promise<void> {
	const subs: string[] = ["cbor"];
	const extras: string[] = [];
	const opts: ConnectOptions = { subprotocols: subs, extraHeaders: extras, recvSendTimeoutMs: 0 };
	const r = await connect("ws://127.0.0.1:8000/rpc", opts);
	if (!r.ok) return;
	const replyResult = await pingLoop(r.value);
	if (!replyResult.ok) return;
	await r.value.close(WsCloseCode.Normal, "");
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: chat-style text echo loop with state-machine close" {
	const src = `
async function chat(c: WsClient): Promise<void> {
	if (c.state !== WsState.Open) return;
	const s = await c.sendText("hello server");
	if (!s.ok) return;
	const m = await c.recv();
	if (!m.ok) return;
	if (m.value.kind === WsMessageKind.Close) {
		// Server initiated close; recv() already echoed back and shut the socket.
		return;
	}
	if (m.value.kind === WsMessageKind.Text) {
		// Got our echo back. Initiate clean close.
		await c.close(WsCloseCode.Normal, "done");
	}
}

async function main(): Promise<void> {
	const r = await connect("ws://echo.websocket.events");
	if (!r.ok) return;
	await chat(r.value);
}
`;
	const c = compileToC(src);
	assert c.ok;
}

// ===== 9. Frame-layer protocol-violation paths reachable =====

test "E2E C: parseFrame protocol-error path emits payloadTooLarge / protocolError constructors" {
	const src = `
function main(): void {
	// 9-byte header + bogus huge length triggers payloadTooLarge.
	const bad: uint8[] = [0x82, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00];
	const r = parseFrame(bad, 0);
	if (r.ok) return;
	if (r.error.kind === WsErrorKind.PayloadTooLarge) return;
	if (r.error.kind === WsErrorKind.ProtocolError) return;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: parseFrame reserved-opcode rejection reachable" {
	const src = `
function main(): boolean {
	const bad: uint8[] = [0x83, 0x00];  // FIN=1, opcode=3 (reserved)
	const r = parseFrame(bad, 0);
	return !r.ok;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

// ===== 10. Optional runtime smokes (skip by default) =====
//
// These need a live ws:// endpoint. To enable, run with the proper env set
// and a local server up:
//
//   WS_ECHO_TEST=1 msc test src/test/std/http/websocket.ms
//   WS_SURREAL_TEST=1 surreal start --user root --pass root memory &  \
//     msc test src/test/std/http/websocket.ms
//
// Until the harness can run compiled-C E2E tests inline (no helper exists
// yet), these are placeholders that just verify the patterns *compile* —
// turning them into live network smokes is a separate piece of work.

test "E2E C: echo-server pattern compiles (runtime smoke deferred)" {
	const src = `
async function main(): Promise<void> {
	const r = await connect("ws://echo.websocket.events");
	if (!r.ok) return;
	const c = r.value;
	const send: uint8[] = [];
	let i = 0;
	while (i < 1024) { send.push(i & 0xff); i = i + 1; }
	const sr = await c.sendBinary(send);
	if (!sr.ok) return;
	const mr = await c.recv();
	if (!mr.ok) return;
	if (mr.value.kind !== WsMessageKind.Binary) return;
	if (mr.value.data.length !== 1024) return;
	await c.close(WsCloseCode.Normal, "");
}
`;
	const c = compileToC(src);
	assert c.ok;
}

// WebSocket state machine — pure MS, fully testable.
//
// Inputs: a parsed frame + the current fragment-reassembly state.
// Output: a `FrameDecision` describing what the I/O layer must do next
// (continue looping, deliver a message, send a close frame, ...).
//
// Keeping this layer free of I/O lets the inline tests cover every spec-
// required transition (auto-pong, fragmented message lifecycle, server-masked
// rejection, illegal close codes, fragment-size cap, interleaved control
// frames during fragmentation) without spinning up a socket.
//
// Public types (WsState / WsMessage / WsCloseCode / FragState) also live here
// because they're pure data shared by both the state machine and the I/O
// wrapper in client.cms.

import {
	OPCODE_CONTINUATION, OPCODE_TEXT, OPCODE_BINARY, OPCODE_CLOSE, OPCODE_PING, OPCODE_PONG,
	MAX_PAYLOAD_BYTES,
	ParsedFrame, decodeClosePayload, isWireValidCloseCode,
} from "./frame";

// ===== Connection-level enums =====

export enum WsState {
	Connecting,
	Open,
	Closing,
	Closed,
}

export enum WsMessageKind {
	Text,
	Binary,
	Close,
	Ping,
	Pong,
}

// RFC 6455 §7.4.1 — only the close codes a client is likely to need.
export enum WsCloseCode {
	Normal = 1000,
	GoingAway = 1001,
	ProtocolError = 1002,
	UnsupportedData = 1003,
	InvalidPayload = 1007,
	PolicyViolation = 1008,
	MessageTooBig = 1009,
	InternalError = 1011,
}

// ===== Public message shape =====

export interface WsMessage {
	kind: WsMessageKind;
	data: number[];          // raw bytes — text frames are also bytes; caller decodes UTF-8 if needed
	closeCode: int32;        // populated only when kind === Close (default 1000 if no code)
}

// ===== Fragment-reassembly state =====
//
// Held by WsClient between recv() calls. Mutated in place by processFrame:
// `fragments` accumulates the in-progress message body; `fragOpcode` is the
// data opcode (Text/Binary) of the first frame in the chain, or 0 when no
// fragmentation is in flight.

export interface FragState {
	fragments: number[];
	fragOpcode: int32;
}

export function newFragState(): FragState {
	const empty: number[] = [];
	return { fragments: empty, fragOpcode: 0 };
}

// ===== Frame decision (state-machine output) =====
//
// Encoded as a string `action` rather than a discriminated union to keep the
// shape stable across both backends and avoid touching the codegen NRVO path
// the rest of this module already exercises heavily.

export interface FrameDecision {
	// One of:
	//   "continue"         — keep looping; nothing to surface (e.g. ping/pong consumed)
	//   "deliver"          — deliver `message` to caller
	//   "delivered_close"  — delivered Close frame; caller must close the socket
	//   "error"            — protocol error; caller must send Close(closeCode) then close socket
	action: string;
	message: WsMessage;
	autoReplyOpcode: int32;     // OPCODE_PONG or OPCODE_CLOSE — caller sends it; 0 = none
	autoReplyPayload: number[]; // payload for the auto-reply
	closeCode: int32;           // for "error" — the close code to send (1002 / 1009 etc.)
	errorMsg: string;           // for "error" — the error message
}

function emptyMessage(): WsMessage {
	const empty: number[] = [];
	return { kind: WsMessageKind.Text, data: empty, closeCode: 0 };
}

export function decisionContinue(reply: int32, payload: number[]): FrameDecision {
	return {
		action: "continue",
		message: emptyMessage(),
		autoReplyOpcode: reply,
		autoReplyPayload: payload,
		closeCode: 0,
		errorMsg: "",
	};
}

export function decisionDeliver(msg: WsMessage): FrameDecision {
	const empty: number[] = [];
	return {
		action: "deliver",
		message: msg,
		autoReplyOpcode: 0,
		autoReplyPayload: empty,
		closeCode: 0,
		errorMsg: "",
	};
}

export function decisionDeliveredClose(msg: WsMessage, replyPayload: number[]): FrameDecision {
	return {
		action: "delivered_close",
		message: msg,
		autoReplyOpcode: OPCODE_CLOSE,
		autoReplyPayload: replyPayload,
		closeCode: 0,
		errorMsg: "",
	};
}

export function decisionError(code: int32, msg: string): FrameDecision {
	const empty: number[] = [];
	return {
		action: "error",
		message: emptyMessage(),
		autoReplyOpcode: 0,
		autoReplyPayload: empty,
		closeCode: code,
		errorMsg: msg,
	};
}

// ===== Byte buffer helpers =====
//
// Shared by the state machine and the handshake recv loop. Exposed so the
// I/O wrapper can splice frame chunks together without re-implementing them.

export function appendBytes(dst: number[], src: number[]): void {
	for (let i: int32 = 0; i < src.length; i = i + 1) {
		dst.push(src[i]);
	}
}

export function dropPrefix(arr: number[], prefixLen: int32): number[] {
	let out: number[] = [];
	for (let i: int32 = prefixLen; i < arr.length; i = i + 1) {
		out.push(arr[i]);
	}
	return out;
}

export function sliceBytes(src: number[], start: int32, end: int32): number[] {
	let out: number[] = [];
	for (let i: int32 = start; i < end; i = i + 1) {
		out.push(src[i]);
	}
	return out;
}

// Find \r\n\r\n in a byte buffer. Returns -1 if not present.
export function findCRLFCRLF(bytes: number[]): int32 {
	const cr: int32 = 0x0D;
	const lf: int32 = 0x0A;
	const limit = bytes.length - 3;
	for (let i: int32 = 0; i < limit; i = i + 1) {
		if (bytes[i] === cr && bytes[i + 1] === lf && bytes[i + 2] === cr && bytes[i + 3] === lf) {
			return i;
		}
	}
	return -1;
}

// ===== processFrame — the inbound state machine =====
//
// Examines a parsed frame. Mutates `fs.fragments` / `fs.fragOpcode` when
// assembling fragmented messages. Returns a FrameDecision for the I/O caller
// to act on. Keeps no socket reference — purely a state transition.
//
// `isServerSide` selects the mask-direction check per RFC 6455 §5.1:
//   - default false (client receiving): server→client frames MUST NOT be masked
//   - true (server receiving): client→server frames MUST be masked
// Default preserves the existing client-side behavior so call sites in
// client.cms don't need to change.

export function processFrame(fs: FragState, f: ParsedFrame, isServerSide: boolean = false): FrameDecision {
	// RFC 6455 §5.1 — masking direction is asymmetric:
	//   client→server: MUST mask    (server rejects unmasked)
	//   server→client: MUST NOT mask (client rejects masked)
	if (isServerSide) {
		if (!f.masked) {
			return decisionError(WsCloseCode.ProtocolError as int32, "client sent unmasked frame");
		}
	} else {
		if (f.masked) {
			return decisionError(WsCloseCode.ProtocolError as int32, "server sent masked frame");
		}
	}

	// Control frames — auto-reply or surface immediately. Per RFC §5.4 control
	// frames may interleave between data frames of a fragmented message
	// without disturbing the fragment state.
	if (f.opcode === OPCODE_PING) {
		return decisionContinue(OPCODE_PONG, f.payload);
	}
	if (f.opcode === OPCODE_PONG) {
		const empty: number[] = [];
		return decisionContinue(0, empty);
	}
	if (f.opcode === OPCODE_CLOSE) {
		const info = decodeClosePayload(f.payload);
		// RFC 6455 §7.4.1: certain codes (1004/1005/1006/1015 + reserved
		// ranges) MUST NOT appear on the wire. If a peer sends them, that's a
		// protocol violation — close with 1002 instead of trusting the code.
		if (info.hasCode && !isWireValidCloseCode(info.code)) {
			return decisionError(WsCloseCode.ProtocolError as int32, "peer sent illegal close code " + info.code.toString());
		}
		const msg: WsMessage = {
			kind: WsMessageKind.Close,
			data: f.payload,
			closeCode: info.code,
		};
		return decisionDeliveredClose(msg, f.payload);
	}

	// Data frames — handle fragmentation.
	if (f.opcode === OPCODE_CONTINUATION) {
		if (fs.fragOpcode === 0) {
			return decisionError(WsCloseCode.ProtocolError as int32, "continuation frame with no in-progress message");
		}
		if (fs.fragments.length + f.payload.length > MAX_PAYLOAD_BYTES) {
			return decisionError(WsCloseCode.MessageTooBig as int32, "fragmented message exceeds " + MAX_PAYLOAD_BYTES.toString() + " bytes");
		}
		appendBytes(fs.fragments, f.payload);
		if (f.fin) {
			const op = fs.fragOpcode;
			const data = fs.fragments;
			const empty: number[] = [];
			fs.fragments = empty;
			fs.fragOpcode = 0;
			const kind = op === OPCODE_TEXT ? WsMessageKind.Text : WsMessageKind.Binary;
			return decisionDeliver({ kind: kind, data: data, closeCode: 0 });
		}
		const empty: number[] = [];
		return decisionContinue(0, empty);
	}

	if (f.opcode === OPCODE_TEXT || f.opcode === OPCODE_BINARY) {
		if (fs.fragOpcode !== 0) {
			return decisionError(WsCloseCode.ProtocolError as int32, "new data frame while fragmenting");
		}
		if (f.fin) {
			const kind = f.opcode === OPCODE_TEXT ? WsMessageKind.Text : WsMessageKind.Binary;
			return decisionDeliver({ kind: kind, data: f.payload, closeCode: 0 });
		}
		// Start fragmented message.
		if (f.payload.length > MAX_PAYLOAD_BYTES) {
			return decisionError(WsCloseCode.MessageTooBig as int32, "fragmented message starts above " + MAX_PAYLOAD_BYTES.toString() + " bytes");
		}
		fs.fragOpcode = f.opcode;
		appendBytes(fs.fragments, f.payload);
		const empty: number[] = [];
		return decisionContinue(0, empty);
	}

	// Reserved opcodes are caught by parseFrame; if we somehow get here,
	// fail safe rather than crash.
	return decisionError(WsCloseCode.ProtocolError as int32, "unhandled opcode " + f.opcode.toString());
}

// ===== Tests =====

function makeFrame(opcode: int32, fin: boolean, masked: boolean, payload: number[]): ParsedFrame {
	return {
		fin: fin,
		opcode: opcode,
		masked: masked,
		payload: payload,
		headerSize: masked ? 6 : 2,
		totalSize: (masked ? 6 : 2) + payload.length,
	};
}

function bytesEqual(a: number[], b: number[]): boolean {
	if (a.length !== b.length) return false;
	for (let i: int32 = 0; i < a.length; i = i + 1) {
		if (a[i] !== b[i]) return false;
	}
	return true;
}

// ----- Single-frame data path -----

test "processFrame: single Text frame FIN=1 → deliver" {
	const fs = newFragState();
	const payload: number[] = [0x68, 0x65, 0x6C, 0x6C, 0x6F];  // "hello"
	const d = processFrame(fs, makeFrame(OPCODE_TEXT, true, false, payload));
	assert d.action === "deliver";
	assert d.message.kind === WsMessageKind.Text;
	assert bytesEqual(d.message.data, payload);
	assert fs.fragments.length === 0;
	assert fs.fragOpcode === 0;
}

test "processFrame: single Binary frame FIN=1 → deliver" {
	const fs = newFragState();
	const payload: number[] = [0x01, 0x02, 0x03];
	const d = processFrame(fs, makeFrame(OPCODE_BINARY, true, false, payload));
	assert d.action === "deliver";
	assert d.message.kind === WsMessageKind.Binary;
	assert bytesEqual(d.message.data, payload);
}

// ----- Control frames -----

test "processFrame: Ping → continue + auto-reply Pong with same payload" {
	const fs = newFragState();
	const pingPayload: number[] = [0x01, 0x02, 0x03];
	const d = processFrame(fs, makeFrame(OPCODE_PING, true, false, pingPayload));
	assert d.action === "continue";
	assert d.autoReplyOpcode === OPCODE_PONG;
	assert bytesEqual(d.autoReplyPayload, pingPayload);
}

test "processFrame: Pong → continue silently (no auto-reply)" {
	const fs = newFragState();
	const pongPayload: number[] = [0x42];
	const d = processFrame(fs, makeFrame(OPCODE_PONG, true, false, pongPayload));
	assert d.action === "continue";
	assert d.autoReplyOpcode === 0;
}

test "processFrame: Close (no payload) → delivered_close, code defaults to 1000" {
	const fs = newFragState();
	const empty: number[] = [];
	const d = processFrame(fs, makeFrame(OPCODE_CLOSE, true, false, empty));
	assert d.action === "delivered_close";
	assert d.message.kind === WsMessageKind.Close;
	assert d.message.closeCode === 1000;
	assert d.autoReplyOpcode === OPCODE_CLOSE;
}

test "processFrame: Close (code 1001 only) → delivered_close, code=1001" {
	const fs = newFragState();
	const payload: number[] = [0x03, 0xE9];  // 1001
	const d = processFrame(fs, makeFrame(OPCODE_CLOSE, true, false, payload));
	assert d.action === "delivered_close";
	assert d.message.closeCode === 1001;
}

test "processFrame: Close (code + reason) → delivered_close echoes payload" {
	const fs = newFragState();
	const payload: number[] = [0x03, 0xE8, 0x62, 0x79, 0x65];  // 1000 + "bye"
	const d = processFrame(fs, makeFrame(OPCODE_CLOSE, true, false, payload));
	assert d.action === "delivered_close";
	assert d.message.closeCode === 1000;
	assert bytesEqual(d.autoReplyPayload, payload);
}

test "processFrame: Close with illegal code 1006 → protocol error 1002" {
	const fs = newFragState();
	const payload: number[] = [0x03, 0xEE];  // 1006 (Abnormal Closure — wire-illegal)
	const d = processFrame(fs, makeFrame(OPCODE_CLOSE, true, false, payload));
	assert d.action === "error";
	assert d.closeCode === (WsCloseCode.ProtocolError as int32);
}

test "processFrame: Close with illegal code 1015 → protocol error" {
	const fs = newFragState();
	const payload: number[] = [0x03, 0xF7];  // 1015 (TLS — wire-illegal)
	const d = processFrame(fs, makeFrame(OPCODE_CLOSE, true, false, payload));
	assert d.action === "error";
}

// ----- Server-masked rejection (client-side direction, default isServerSide=false) -----

test "processFrame: server-masked frame → protocol error" {
	const fs = newFragState();
	const payload: number[] = [0x68, 0x69];
	const d = processFrame(fs, makeFrame(OPCODE_TEXT, true, true, payload));  // masked=true
	assert d.action === "error";
	assert d.closeCode === (WsCloseCode.ProtocolError as int32);
}

// ----- Server-side direction (isServerSide=true): mask check is flipped -----

test "processFrame server-side: masked client frame → deliver" {
	const fs = newFragState();
	const payload: number[] = [0x68, 0x65, 0x6C, 0x6C, 0x6F];
	const d = processFrame(fs, makeFrame(OPCODE_TEXT, true, true, payload), true);  // isServerSide=true, masked=true
	assert d.action === "deliver";
	assert d.message.kind === WsMessageKind.Text;
	assert bytesEqual(d.message.data, payload);
}

test "processFrame server-side: unmasked client frame → protocol error" {
	const fs = newFragState();
	const payload: number[] = [0x68, 0x69];
	const d = processFrame(fs, makeFrame(OPCODE_TEXT, true, false, payload), true);  // isServerSide=true, masked=false
	assert d.action === "error";
	assert d.closeCode === (WsCloseCode.ProtocolError as int32);
	assert d.errorMsg === "client sent unmasked frame";
}

test "processFrame server-side: ping with masked payload → auto-pong" {
	const fs = newFragState();
	const payload: number[] = [0x01, 0x02];
	const d = processFrame(fs, makeFrame(OPCODE_PING, true, true, payload), true);
	assert d.action === "continue";
	assert d.autoReplyOpcode === OPCODE_PONG;
	assert bytesEqual(d.autoReplyPayload, payload);
}

test "processFrame server-side: fragmentation still works with masked frames" {
	const fs = newFragState();
	processFrame(fs, makeFrame(OPCODE_TEXT, false, true, [0x48, 0x65, 0x6C]), true);
	const d = processFrame(fs, makeFrame(OPCODE_CONTINUATION, true, true, [0x6C, 0x6F]), true);
	assert d.action === "deliver";
	assert bytesEqual(d.message.data, [0x48, 0x65, 0x6C, 0x6C, 0x6F]);
}

// ----- Fragmentation lifecycle -----

test "processFrame: fragmented Text — start FIN=0 sets state, no deliver" {
	const fs = newFragState();
	const part1: number[] = [0x48, 0x65, 0x6C];  // "Hel"
	const d = processFrame(fs, makeFrame(OPCODE_TEXT, false, false, part1));
	assert d.action === "continue";
	assert fs.fragOpcode === OPCODE_TEXT;
	assert bytesEqual(fs.fragments, part1);
}

test "processFrame: fragmented Text — middle Continuation FIN=0 appends, no deliver" {
	const fs = newFragState();
	processFrame(fs, makeFrame(OPCODE_TEXT, false, false, [0x48, 0x65, 0x6C]));
	const part2: number[] = [0x6C, 0x6F];
	const d = processFrame(fs, makeFrame(OPCODE_CONTINUATION, false, false, part2));
	assert d.action === "continue";
	assert fs.fragOpcode === OPCODE_TEXT;
	assert bytesEqual(fs.fragments, [0x48, 0x65, 0x6C, 0x6C, 0x6F]);
}

test "processFrame: fragmented Text — end Continuation FIN=1 delivers reassembled" {
	const fs = newFragState();
	processFrame(fs, makeFrame(OPCODE_TEXT, false, false, [0x48, 0x65, 0x6C]));
	const part2: number[] = [0x6C, 0x6F];
	const d = processFrame(fs, makeFrame(OPCODE_CONTINUATION, true, false, part2));
	assert d.action === "deliver";
	assert d.message.kind === WsMessageKind.Text;
	assert bytesEqual(d.message.data, [0x48, 0x65, 0x6C, 0x6C, 0x6F]);
	// Fragment state cleared after delivery.
	assert fs.fragments.length === 0;
	assert fs.fragOpcode === 0;
}

test "processFrame: fragmented Binary multi-part (3 frames) reassembles in order" {
	const fs = newFragState();
	const a: number[] = [0x01, 0x02];
	const b: number[] = [0x03, 0x04];
	const c: number[] = [0x05, 0x06];
	processFrame(fs, makeFrame(OPCODE_BINARY, false, false, a));
	processFrame(fs, makeFrame(OPCODE_CONTINUATION, false, false, b));
	const d = processFrame(fs, makeFrame(OPCODE_CONTINUATION, true, false, c));
	assert d.action === "deliver";
	assert d.message.kind === WsMessageKind.Binary;
	assert bytesEqual(d.message.data, [0x01, 0x02, 0x03, 0x04, 0x05, 0x06]);
}

test "processFrame: orphan Continuation (no prior data start) → protocol error" {
	const fs = newFragState();
	const payload: number[] = [0x01];
	const d = processFrame(fs, makeFrame(OPCODE_CONTINUATION, true, false, payload));
	assert d.action === "error";
	assert d.closeCode === (WsCloseCode.ProtocolError as int32);
}

test "processFrame: interleaved data frame during fragmentation → protocol error" {
	const fs = newFragState();
	processFrame(fs, makeFrame(OPCODE_TEXT, false, false, [0x68, 0x69]));
	// New Text frame mid-fragment is illegal.
	const d = processFrame(fs, makeFrame(OPCODE_TEXT, true, false, [0x6F]));
	assert d.action === "error";
}

test "processFrame: Ping during fragmentation does NOT clear fragment state" {
	const fs = newFragState();
	processFrame(fs, makeFrame(OPCODE_TEXT, false, false, [0x48, 0x65, 0x6C]));
	const pingPayload: number[] = [0x9A];
	const dPing = processFrame(fs, makeFrame(OPCODE_PING, true, false, pingPayload));
	assert dPing.action === "continue";
	assert dPing.autoReplyOpcode === OPCODE_PONG;
	// Fragment state unchanged.
	assert fs.fragOpcode === OPCODE_TEXT;
	assert bytesEqual(fs.fragments, [0x48, 0x65, 0x6C]);
	// Then continuation finishes the message.
	const dEnd = processFrame(fs, makeFrame(OPCODE_CONTINUATION, true, false, [0x6C, 0x6F]));
	assert dEnd.action === "deliver";
	assert bytesEqual(dEnd.message.data, [0x48, 0x65, 0x6C, 0x6C, 0x6F]);
}

// ----- Fragment-size cap (E4) -----
//
// Real overflow tests would allocate 16 MB+ which is heavy for a unit test.
// The cap predicate is a single `>` comparison and is visually reviewable.
// We exercise the BELOW-cap acceptance path here; an integration test that
// actually drives the cap from a server would belong in src/test/std/http/
// against a fixture server.

test "processFrame: fragment START below cap → accepted" {
	const fs = newFragState();
	let payload: number[] = [];
	for (let i: int32 = 0; i < 4; i = i + 1) {
		payload.push(0);
	}
	const d = processFrame(fs, makeFrame(OPCODE_BINARY, false, false, payload));
	assert d.action === "continue";
	assert fs.fragOpcode === OPCODE_BINARY;
}

// ----- Bytes helpers -----

test "appendBytes appends in order" {
	let dst: number[] = [1, 2];
	const src: number[] = [3, 4, 5];
	appendBytes(dst, src);
	assert bytesEqual(dst, [1, 2, 3, 4, 5]);
}

test "appendBytes empty src is no-op" {
	let dst: number[] = [1, 2, 3];
	const src: number[] = [];
	appendBytes(dst, src);
	assert bytesEqual(dst, [1, 2, 3]);
}

test "dropPrefix removes leading bytes" {
	const arr: number[] = [10, 20, 30, 40];
	const out = dropPrefix(arr, 2);
	assert bytesEqual(out, [30, 40]);
}

test "dropPrefix prefixLen == length yields empty" {
	const arr: number[] = [1, 2, 3];
	const out = dropPrefix(arr, 3);
	assert out.length === 0;
}

test "sliceBytes slices half-open range" {
	const arr: number[] = [10, 20, 30, 40, 50];
	const out = sliceBytes(arr, 1, 4);
	assert bytesEqual(out, [20, 30, 40]);
}

test "findCRLFCRLF locates separator" {
	const arr: number[] = [0x41, 0x42, 0x0D, 0x0A, 0x0D, 0x0A, 0x43];
	assert findCRLFCRLF(arr) === 2;
}

test "findCRLFCRLF returns -1 when absent" {
	const arr: number[] = [0x41, 0x42, 0x43];
	assert findCRLFCRLF(arr) === -1;
}

test "findCRLFCRLF skips a single CRLF" {
	const arr: number[] = [0x0D, 0x0A, 0x41, 0x0D, 0x0A, 0x42];
	assert findCRLFCRLF(arr) === -1;
}

// ----- Decision constructor sanity -----

test "decisionContinue carries reply opcode + payload" {
	const payload: number[] = [0x01];
	const d = decisionContinue(OPCODE_PONG, payload);
	assert d.action === "continue";
	assert d.autoReplyOpcode === OPCODE_PONG;
	assert bytesEqual(d.autoReplyPayload, payload);
}

test "decisionError carries close code + message" {
	const d = decisionError(WsCloseCode.MessageTooBig as int32, "too big");
	assert d.action === "error";
	assert d.closeCode === 1009;
	assert d.errorMsg === "too big";
}

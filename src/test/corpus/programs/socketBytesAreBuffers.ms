// @xfail(raiser): std/core/websocket and std/net are .cms modules, C backend only
// @skip-js: std/core/websocket and std/net are .cms modules, C backend only
// @serial
// @stdout: recv: length 256 exact=true
// @stdout: recvNonBlock: length 256 exact=true
// @stdout: text: 6162c3a9
// @stdout: ws binary reply: length 256 exact=true
// @stdout: ws binary request: length 256 exact=true
// note: socket and websocket byte reads return a Buffer holding every byte value 0..255 unchanged,
//   and send accepts a Buffer or a string.

import { Buffer } from "std/core/buffer";
import { createSocket, bind, listen, accept, connect, send, recv, close, recvNonBlock, setNonBlocking } from "std/net";
import {
	connectSync, recvSync, sendBinarySync, OPCODE_BINARY, buildFrameUnmasked, parseFrame, appendBytes,
	parseUpgradeRequest, buildUpgradeResponse, deriveAcceptKey,
} from "std/core/websocket";

function listenOnFreePort(): int32[] {
	let port = (20000 + Date.now() % 20000) as int32;
	while (true) {
		const fd = createSocket();
		if (bind(fd, "127.0.0.1", port) >= 0 && listen(fd, 4) >= 0) return [fd, port];
		close(fd);
		port = port + 1;
	}
}

function allByteValues(): Buffer {
	const all = Buffer.alloc(256);
	for (let i = 0; i < 256; i++) all.set(i, i);
	return all;
}

function exact(bytes: Buffer): boolean {
	if (bytes.length != 256) return false;
	for (let i = 0; i < 256; i++) if (bytes.byteAt(i) != i) return false;
	return true;
}

function describe(name: string, bytes: Buffer): void {
	console.log(`${name}: length ${bytes.length} exact=${exact(bytes)}`);
}

function readAll(fd: int32, want: int32, nonBlocking: boolean): Buffer {
	const got: uint8[] = [];
	const t0 = Date.now();
	while (got.length < want && Date.now() - t0 < 5000) {
		const part = nonBlocking ? recvNonBlock(fd, 8192) : recv(fd, 8192);
		if (part.length == 0 && !nonBlocking) break;
		appendBytes(got, part);
	}
	return got;
}

function loopback(data: Buffer | string, want: int32, nonBlocking: boolean): Buffer {
	const lp = listenOnFreePort();
	const client = createSocket();
	connect(client, "127.0.0.1", lp[1]);
	const peer = accept(lp[0]);
	send(client, data);
	if (nonBlocking) setNonBlocking(peer);
	const got = readAll(peer, want, nonBlocking);
	close(client);
	close(peer);
	close(lp[0]);
	return got;
}

function wsServer(listenFd: int32): int32 {
	const fd = accept(listenFd);
	let raw = "";
	while (!raw.includes("\r\n\r\n")) {
		const chunk = recv(fd, 4096);
		if (chunk.length == 0) return -1;
		raw += chunk.asString();
	}
	const req = parseUpgradeRequest(raw);
	if (!req.ok) return -2;
	send(fd, buildUpgradeResponse(deriveAcceptKey(req.value.clientKey), "", []));
	send(fd, buildFrameUnmasked(OPCODE_BINARY, true, allByteValues()));
	const seen: uint8[] = [];
	const t0 = Date.now();
	while (Date.now() - t0 < 5000) {
		const chunk = recv(fd, 4096);
		if (chunk.length == 0) break;
		appendBytes(seen, chunk);
		const frame = parseFrame(seen, 0);
		if (frame.ok && !frame.value.needMore) {
			describe("ws binary request", frame.value.frame.payload);
			break;
		}
	}
	close(fd);
	return 0;
}

function websocket(): void {
	const lp = listenOnFreePort();
	const server = spawn(() => wsServer(lp[0]));
	const client = connectSync(`ws://127.0.0.1:${lp[1]}/`, { subprotocols: [], extraHeaders: [], recvSendTimeoutMs: 5000 });
	if (!client.ok) {
		console.log("connect failed: " + client.error.message);
		return;
	}
	const msg = recvSync(client.value);
	if (msg.ok) describe("ws binary reply", msg.value.data);
	else console.log("recv failed: " + msg.error.message);
	sendBinarySync(client.value, allByteValues());
	await server;
	close(lp[0]);
}

describe("recv", loopback(allByteValues(), 256, false));
describe("recvNonBlock", loopback(allByteValues(), 256, true));
console.log(`text: ${loopback("abé", 4, false).toHex()}`);
websocket();

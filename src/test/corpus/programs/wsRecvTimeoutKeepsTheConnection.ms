// @xfail(raiser): std/core/websocket and std/net are .cms modules, C backend only
// @skip-js: std/core/websocket and std/net are .cms modules, C backend only
// @serial
// @stdout: silent: timed out=true state=Open
// @stdout: late frame: late
// @stdout: net: timed out=true then closed=true
// note: a receive that outlasts recvSendTimeoutMs is a Timeout error with the connection still open, and the
//   next recvSync reads the frame sent after it. An empty recv is told apart from end of stream by recvTimedOut.

import { createSocket, bind, listen, accept, connect, send, recv, close, setTimeout, recvTimedOut } from "std/net";
import {
	connectSync, recvSync, WsErrorKind, WsState, OPCODE_TEXT, buildFrameUnmasked,
	parseUpgradeRequest, buildUpgradeResponse, deriveAcceptKey, stringToBytes, bytesToString,
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

function quietThenSend(listenFd: int32): int32 {
	const fd = accept(listenFd);
	let raw = "";
	while (!raw.includes("\r\n\r\n")) {
		const chunk = recv(fd, 4096);
		if (chunk.length == 0) return -1;
		raw += chunk;
	}
	const req = parseUpgradeRequest(raw);
	if (!req.ok) return -2;
	send(fd, buildUpgradeResponse(deriveAcceptKey(req.value.clientKey), "", []));
	const t0 = Date.now();
	while (Date.now() - t0 < 600) {}
	send(fd, bytesToString(buildFrameUnmasked(OPCODE_TEXT, true, stringToBytes("late"))));
	const t1 = Date.now();
	while (Date.now() - t1 < 600) {}
	close(fd);
	return 0;
}

function wsTimeout(): void {
	const lp = listenOnFreePort();
	const server = spawn(() => quietThenSend(lp[0]));
	const ws = connectSync(`ws://127.0.0.1:${lp[1]}/`, { subprotocols: [], extraHeaders: [], recvSendTimeoutMs: 150 });
	if (!ws.ok) {
		console.log("connect failed: " + ws.error.message);
		return;
	}
	const first = recvSync(ws.value);
	console.log(`silent: timed out=${!first.ok && first.error.kind == WsErrorKind.Timeout} state=${ws.value.state == WsState.Open ? "Open" : "Closed"}`);
	let late = recvSync(ws.value);
	while (!late.ok && late.error.kind == WsErrorKind.Timeout) late = recvSync(ws.value);
	console.log(late.ok ? `late frame: ${bytesToString(late.value.data)}` : `late frame failed: ${late.error.message}`);
	await server;
	close(lp[0]);
}

function netTimeout(): void {
	const lp = listenOnFreePort();
	const client = createSocket();
	connect(client, "127.0.0.1", lp[1]);
	setTimeout(client, 100);
	const silent = recv(client, 64);
	const timedOut = silent.length == 0 && recvTimedOut();
	const peer = accept(lp[0]);
	close(peer);
	const eof = recv(client, 64);
	console.log(`net: timed out=${timedOut} then closed=${eof.length == 0 && !recvTimedOut()}`);
	close(client);
	close(lp[0]);
}

wsTimeout();
netTimeout();

// @xfail(raiser): std/net is a .cms module, C backend only
// @skip-js: std/net is a .cms module, C backend only
// @serial
// @stdout: blocking fd: recv one, send 8388608, prompt: true
// @stdout: nonblocking fd: recv one, send 8388608, prompt: true
// @stdout: small send: recv ping, send 2
// @stdout: two fds: recv two, send 2097152
// note: a recv and a send pending on one fd wait side by side: the peer's bytes complete the recv while the send,
//   whose peer does not read, stays pending, and neither waits for an event of the other side. The blocking fd is
//   never made non-blocking, so a send larger than the socket buffer does not wait for the peer to read.

import { accept, bind, close, connect, createSocket, listen, recvAsync, send, sendAsync, setNonBlocking } from "std/net";
import { sleepAsync } from "std/core/promise";

const BIG = 8 * 1024 * 1024;

function listenOnFreePort(): int32[] {
	let port = (20000 + Date.now() % 20000) as int32;
	while (true) {
		const fd = createSocket();
		if (bind(fd, "127.0.0.1", port) >= 0 && listen(fd, 4) >= 0) return [fd, port];
		close(fd);
		port = port + 1;
	}
}

async function pair(): Promise<int32[]> {
	const lp = listenOnFreePort();
	const client = createSocket();
	connect(client, "127.0.0.1", lp[1]);
	const peer = accept(lp[0]);
	close(lp[0]);
	return [peer, client];
}

async function drain(fd: int32, want: int32): Promise<void> {
	let total = 0;
	while (total < want) {
		const chunk = await recvAsync(fd, 65536);
		if (chunk.length == 0) return;
		total += chunk.length;
	}
}

async function bigSendAndRecv(label: string, nonBlocking: boolean): Promise<void> {
	const p = await pair();
	if (nonBlocking) setNonBlocking(p[0]);
	const pendingSend = sendAsync(p[0], "x".repeat(BIG));
	const pendingRecv = recvAsync(p[0], 16);
	await sleepAsync(50);
	send(p[1], "one");
	const got = await pendingRecv;
	const start = Date.now();
	await sleepAsync(20);
	const prompt = Date.now() - start < 1000;
	await drain(p[1], BIG);
	const sent = await pendingSend;
	console.log(`${label}: recv ${got.asString()}, send ${sent}, prompt: ${prompt}`);
	close(p[0]);
	close(p[1]);
}

async function smallSendAndRecv(): Promise<void> {
	const p = await pair();
	const pendingRecv = recvAsync(p[0], 16);
	const sent = await sendAsync(p[0], "hi");
	send(p[1], "ping");
	const got = await pendingRecv;
	console.log(`small send: recv ${got.asString()}, send ${sent}`);
	close(p[0]);
	close(p[1]);
}

async function sendAndRecvOnTwoFds(): Promise<void> {
	const a = await pair();
	const b = await pair();
	const pendingSend = sendAsync(a[0], "y".repeat(2 * 1024 * 1024));
	const pendingRecv = recvAsync(b[0], 16);
	await sleepAsync(50);
	send(b[1], "two");
	const got = await pendingRecv;
	await drain(a[1], 2 * 1024 * 1024);
	const sent = await pendingSend;
	console.log(`two fds: recv ${got.asString()}, send ${sent}`);
	close(a[0]); close(a[1]); close(b[0]); close(b[1]);
}

await bigSendAndRecv("blocking fd", false);
await bigSendAndRecv("nonblocking fd", true);
await smallSendAndRecv();
await sendAndRecvOnTwoFds();

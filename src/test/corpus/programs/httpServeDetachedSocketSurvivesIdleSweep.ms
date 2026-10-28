// @xfail(raiser): error: Cannot resolve module 'std/http/server'
// @stdout: detached: pong after 2500 ms idle
// @stdout: plain: closed by the idle sweep
// @exit: 0
// @serial
// @skip-js: std/http/server is a .cms module, C backend only
// note: a connection the handler took over with res.detach() belongs to the handler, so the idle sweep never closes it; a plain keep-alive connection idle for the same time is still closed (old: both were closed once keepAliveTimeout passed)

import { HttpRequest, ServerResponse } from "std/http";
import { createServerAsync, sendText, serveConcurrentAsync, setHeader, detach, end, stop } from "std/http/server";
import { createSocket, bind, connect, send, recv, close } from "std/net";
import { lockedRead, lockedUpdate } from "std/core/promise";

function freePort(): int32 {
	let port = (20000 + Date.now() % 20000) as int32;
	while (true) {
		const fd = createSocket();
		const ok = bind(fd, "127.0.0.1", port) >= 0;
		close(fd);
		if (ok) return port;
		port = port + 1;
	}
}

struct Handed { fd: int32; plain: int32; }

const handed: Locked<Handed> = new Locked({ fd: -1, plain: 0 });

async function handle(req: HttpRequest, res: ServerResponse): Promise<void> {
	if (req.path == "/ws") {
		res.setHeader("Upgrade", "websocket");
		res.setHeader("Connection", "Upgrade");
		res.status = 101;
		const fd = res.detach();
		res.end();
		lockedUpdate(handed, (h: Handed): Handed => { return { fd: fd, plain: h.plain }; });
		return;
	}
	sendText(res, "plain");
	lockedUpdate(handed, (h: Handed): Handed => { return { fd: h.fd, plain: h.plain + 1 }; });
}

function connectTo(port: int32): int32 {
	const t0 = Date.now();
	while (Date.now() - t0 < 5000) {
		const fd = createSocket();
		if (connect(fd, "127.0.0.1", port) == 0) return fd;
		close(fd);
	}
	return -1;
}

function readUntil(fd: int32, mark: string): string {
	let got = "";
	while (!got.includes(mark)) {
		const chunk = recv(fd, 4096);
		if (chunk.length == 0) break;
		got += chunk;
	}
	return got;
}

function clients(port: int32): string {
	const ws = connectTo(port);
	send(ws, "GET /ws HTTP/1.1\r\nHost: localhost\r\n\r\n");
	readUntil(ws, "\r\n\r\n");
	const plain = connectTo(port);
	send(plain, "GET /a HTTP/1.1\r\nHost: localhost\r\n\r\n");
	readUntil(plain, "plain");
	const idleStart = Date.now();
	const tail = recv(plain, 4096);
	const plainOut = tail.length == 0 ? "plain: closed by the idle sweep" : "plain: still open";
	const pong = readUntil(ws, "pong");
	const wsOut = pong.includes("pong") ? `detached: pong after ${Date.now() - idleStart >= 2500 ? 2500 : 0} ms idle` : "detached: closed";
	close(ws);
	close(plain);
	return wsOut + " | " + plainOut;
}

function handedFd(): int32 {
	return lockedRead(handed, (h: Handed): int32 => { return h.fd; });
}

const server = createServerAsync(handle);
server.keepAliveTimeout = 300;
const port = freePort();
server.listen("127.0.0.1", port);
const c = spawn(() => clients(port));
let sentAt: number = 0;
const timer = setInterval(() => {
	const fd = handedFd();
	if (fd < 0) return;
	if (sentAt == 0) sentAt = Date.now();
	if (Date.now() - sentAt < 2500) return;
	send(fd, "pong");
	stop(server);
}, 5);
serveConcurrentAsync(server, handle, 2);
clearInterval(timer);
const out = await c;
for (const line of out.split(" | ")) console.log(line);

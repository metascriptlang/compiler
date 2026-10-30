// @xfail(raiser): error: Cannot resolve module 'std/http/server'
// @stdout: sync: /bin c3a9ff80c378 | /after
// @stdout: async: /bin c3a9ff80c378 | /after
// @exit: 0
// @serial
// @skip-js: std/http/server is a .cms module, C backend only
// note: behind a header with non-ASCII text, a request body of non-UTF-8 bytes, sent in two writes cut inside a character, reaches the handler byte for byte, and the pipelined request after it is framed at the right byte

import { HttpRequest, ServerResponse } from "std/http";
import { HttpServer, createServer, createServerAsync, sendText, serveConcurrent, serveConcurrentAsync, stop } from "std/http/server";
import { createSocket, connect, send, recv, close } from "std/net";
import { Buffer } from "std/core/buffer";
import { lockedRead, lockedUpdate } from "std/core/promise";

function listenFree(s: HttpServer): int32 {
	let port = (20000 + Date.now() % 20000) as int32;
	while (!s.listen("127.0.0.1", port).ok) port = port + 1;
	return port;
}

function settle(ms: int32): void {
	const t0 = Date.now();
	while (Date.now() - t0 < ms) {}
}

function bodies(got: string): string {
	const parts: string[] = [];
	for (const piece of got.split("HTTP/1.1 200 OK")) {
		const at = piece.indexOf("\r\n\r\n");
		if (at >= 0) parts.push(piece.slice(at + 4, piece.length));
	}
	return parts.join(" | ");
}

function exchange(port: int32): string {
	const t0 = Date.now();
	while (Date.now() - t0 < 5000) {
		const fd = createSocket();
		if (connect(fd, "127.0.0.1", port) == 0) {
			send(fd, "POST /bin HTTP/1.1\r\nHost: localhost\r\nX-Name: café\r\nContent-Length: 6\r\n\r\n");
			send(fd, Buffer.fromArray([0xC3, 0xA9, 0xFF, 0x80, 0xC3]));
			settle(50);
			send(fd, Buffer.fromArray([0x78]));
			send(fd, "GET /after HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
			let got = "";
			while (true) {
				const chunk = recv(fd, 4096);
				if (chunk.length == 0) break;
				got += chunk.asString();
				if (got.endsWith("/after")) break;
			}
			close(fd);
			return bodies(got);
		}
		close(fd);
	}
	return "no connection";
}

struct Served { n: int32; }

const served: Locked<Served> = new Locked({ n: 0 });

function servedCount(): int32 {
	return lockedRead(served, (s: Served): int32 => { return s.n; });
}

function reply(req: HttpRequest, res: ServerResponse): void {
	sendText(res, req.bytes.length == 0 ? req.path : `${req.path} ${req.bytes.toHex()}`);
	lockedUpdate(served, (s: Served): Served => { return { n: s.n + 1 }; });
}

async function replyAsync(req: HttpRequest, res: ServerResponse): Promise<void> {
	reply(req, res);
}

const server = createServer(reply);
const serverAsync = createServerAsync(replyAsync);

function syncServer(): void {
	lockedUpdate(served, (s: Served): Served => { return { n: 0 }; });
	const port = listenFree(server);
	const c = spawn(() => exchange(port));
	const timer = setInterval(() => { if (servedCount() >= 2) stop(server); }, 5);
	serveConcurrent(server, 2);
	clearInterval(timer);
	console.log(`sync: ${await c}`);
}

function asyncServer(): void {
	lockedUpdate(served, (s: Served): Served => { return { n: 0 }; });
	const port = listenFree(serverAsync);
	const c = spawn(() => exchange(port));
	const timer = setInterval(() => { if (servedCount() >= 2) stop(serverAsync); }, 5);
	serveConcurrentAsync(serverAsync, replyAsync, 2);
	clearInterval(timer);
	console.log(`async: ${await c}`);
}

syncServer();
asyncServer();

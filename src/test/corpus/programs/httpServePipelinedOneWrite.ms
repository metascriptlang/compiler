// @xfail(raiser): error: Cannot resolve module 'std/http/server'
// @stdout: sync: /a | /b | /c
// @stdout: async: /a | /b | /c
// @exit: 0
// @serial
// @skip-js: std/http/server is a .cms module, C backend only
// note: three requests that reach the server in one write are each answered, in order, on the sync and the async server

import { HttpRequest, ServerResponse } from "std/http";
import { HttpServer, createServer, createServerAsync, sendText, serveConcurrent, serveConcurrentAsync, stop } from "std/http/server";
import { createSocket, connect, send, recv, recvTimedOut, setTimeout, close } from "std/net";
import { lockedRead, lockedUpdate } from "std/core/promise";

function listenFree(s: HttpServer): int32 {
	let port = (20000 + Date.now() % 20000) as int32;
	while (!s.listen("127.0.0.1", port).ok) port = port + 1;
	return port;
}

function bodies(got: string): string {
	const parts: string[] = [];
	for (const piece of got.split("HTTP/1.1 200 OK")) {
		const at = piece.indexOf("\r\n\r\n");
		if (at >= 0) parts.push(piece.slice(at + 4, piece.length));
	}
	return parts.join(" | ");
}

struct Progress { served: int32; clientDone: boolean; }

const progress: Locked<Progress> = new Locked({ served: 0, clientDone: false });

function finished(): boolean {
	return lockedRead(progress, (p: Progress): boolean => { return p.served >= 3 || p.clientDone; });
}

function exchange(port: int32): string {
	const fd = createSocket();
	let got = "";
	if (connect(fd, "127.0.0.1", port) == 0) {
		setTimeout(fd, 5000);
		send(fd, "GET /a HTTP/1.1\r\nHost: l\r\n\r\nGET /b HTTP/1.1\r\nHost: l\r\n\r\nGET /c HTTP/1.1\r\nHost: l\r\nConnection: close\r\n\r\n");
		while (true) {
			const chunk = recv(fd, 4096);
			if (chunk.length == 0 || recvTimedOut()) break;
			got += chunk.asString();
			if (got.endsWith("/c")) break;
		}
	}
	close(fd);
	lockedUpdate(progress, (p: Progress): Progress => { return { served: p.served, clientDone: true }; });
	return bodies(got);
}

function reply(req: HttpRequest, res: ServerResponse): void {
	sendText(res, req.path);
	lockedUpdate(progress, (p: Progress): Progress => { return { served: p.served + 1, clientDone: p.clientDone }; });
}

async function replyAsync(req: HttpRequest, res: ServerResponse): Promise<void> {
	reply(req, res);
}

const server = createServer(reply);
const serverAsync = createServerAsync(replyAsync);

function reset(): void {
	lockedUpdate(progress, (p: Progress): Progress => { return { served: 0, clientDone: false }; });
}

function syncServer(): void {
	reset();
	const port = listenFree(server);
	const c = spawn(() => exchange(port));
	const timer = setInterval(() => { if (finished()) stop(server); }, 5);
	serveConcurrent(server, 2);
	clearInterval(timer);
	console.log(`sync: ${await c}`);
}

function asyncServer(): void {
	reset();
	const port = listenFree(serverAsync);
	const c = spawn(() => exchange(port));
	const timer = setInterval(() => { if (finished()) stop(serverAsync); }, 5);
	serveConcurrentAsync(serverAsync, replyAsync, 2);
	clearInterval(timer);
	console.log(`async: ${await c}`);
}

syncServer();
asyncServer();

// @xfail(raiser): error: Cannot resolve module 'std/http/server'
// @stdout: sync one client: 8000000 bytes intact=true | /after
// @stdout: sync one client: served=2 running=false
// @stdout: sync two clients: 6000000 bytes intact=true | 6000000 bytes intact=true
// @stdout: sync two clients: served=2 running=false
// @stdout: async one client: 8000000 bytes intact=true | /after
// @stdout: async one client: served=2 running=false
// @exit: 0
// @serial
// @skip-js: std/http/server is a .cms module, C backend only
// note: a response body of megabytes read by a slow client in small steps reaches it byte for byte and the server keeps serving (old: a send that wrote part of the body completed early, or aborted on the full socket buffer)

import { HttpRequest, ServerResponse } from "std/http";
import { createServer, createServerAsync, sendText, serveConcurrent, serveConcurrentAsync, stop } from "std/http/server";
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

function settle(ms: int32): void {
	const t0 = Date.now();
	while (Date.now() - t0 < ms) {}
}

function bigBody(size: int32): string {
	return "0123456789abcdef".repeat(size / 16);
}

function slowGet(port: int32, path: string, size: int32): string {
	const t0 = Date.now();
	while (Date.now() - t0 < 5000) {
		const fd = createSocket();
		if (connect(fd, "127.0.0.1", port) == 0) {
			send(fd, `GET ${path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n`);
			let got = "";
			settle(200);
			while (true) {
				settle(5);
				const chunk = recv(fd, 262144);
				if (chunk.length == 0) break;
				got += chunk.asString();
				const at = got.indexOf("\r\n\r\n");
				if (at >= 0 && got.length - at - 4 >= size) break;
			}
			close(fd);
			const body = got.slice(got.indexOf("\r\n\r\n") + 4, got.length);
			return `${body.length} bytes intact=${body == bigBody(size)}`;
		}
		close(fd);
	}
	return "no connection";
}

function slowThenAfter(port: int32, size: int32): string {
	const big = slowGet(port, "/big", size);
	const t0 = Date.now();
	while (Date.now() - t0 < 5000) {
		const fd = createSocket();
		if (connect(fd, "127.0.0.1", port) == 0) {
			send(fd, "GET /after HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
			let got = "";
			while (true) {
				const chunk = recv(fd, 4096);
				if (chunk.length == 0) break;
				got += chunk.asString();
				if (got.endsWith("/after")) break;
			}
			close(fd);
			return `${big} | ${got.slice(got.indexOf("\r\n\r\n") + 4, got.length)}`;
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

function handle(req: HttpRequest, res: ServerResponse): void {
	sendText(res, req.path == "/big" ? bigBody(8000000) : req.path == "/mid" ? bigBody(6000000) : req.path);
	lockedUpdate(served, (s: Served): Served => { return { n: s.n + 1 }; });
}

async function handleAsync(req: HttpRequest, res: ServerResponse): Promise<void> {
	handle(req, res);
}

const server = createServer(handle);
const serverAsync = createServerAsync(handleAsync);

function syncOne(): void {
	lockedUpdate(served, (s: Served): Served => { return { n: 0 }; });
	const port = freePort();
	server.listen("127.0.0.1", port);
	const c = spawn(() => slowThenAfter(port, 8000000));
	const timer = setInterval(() => { if (servedCount() >= 2) stop(server); }, 5);
	serveConcurrent(server, 2);
	clearInterval(timer);
	console.log(`sync one client: ${await c}`);
	console.log(`sync one client: served=${servedCount()} running=${server.running}`);
}

function syncTwo(): void {
	lockedUpdate(served, (s: Served): Served => { return { n: 0 }; });
	const port = freePort();
	server.listen("127.0.0.1", port);
	const a = spawn(() => slowGet(port, "/mid", 6000000));
	const b = spawn(() => slowGet(port, "/mid", 6000000));
	const timer = setInterval(() => { if (servedCount() >= 2) stop(server); }, 5);
	serveConcurrent(server, 2);
	clearInterval(timer);
	console.log(`sync two clients: ${await a} | ${await b}`);
	console.log(`sync two clients: served=${servedCount()} running=${server.running}`);
}

function asyncOne(): void {
	lockedUpdate(served, (s: Served): Served => { return { n: 0 }; });
	const port = freePort();
	serverAsync.listen("127.0.0.1", port);
	const c = spawn(() => slowThenAfter(port, 8000000));
	const timer = setInterval(() => { if (servedCount() >= 2) stop(serverAsync); }, 5);
	serveConcurrentAsync(serverAsync, handleAsync, 2);
	clearInterval(timer);
	console.log(`async one client: ${await c}`);
	console.log(`async one client: served=${servedCount()} running=${serverAsync.running}`);
}

syncOne();
syncTwo();
asyncOne();

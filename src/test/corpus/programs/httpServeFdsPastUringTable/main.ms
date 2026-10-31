// Two clients reading large bodies from one server, with every fd the server holds at or above 1100:
// each connection keeps its own io_uring send and receive state, so both bodies arrive byte for byte
// (old runtime: every fd at or above 1024 shared slot 0 of the per-fd tables, so one connection's
// resent tail and receive buffer were the other's).
// Axes: the sync serveConcurrent path (the io_uring loop on Linux) and the async path.
//
// @stdout: raised=true fds past 1100=true
// @stdout: sync two clients: 6000000 bytes intact=true | 6000000 bytes intact=true
// @stdout: sync two clients: served=2 running=false
// @stdout: async two clients: 6000000 bytes intact=true | 6000000 bytes intact=true
// @stdout: async two clients: served=2 running=false
// @exit: 0
// @serial
// @skip-js: std/http/server is a .cms module, C backend only
// @skip-raiser

import { HttpRequest, ServerResponse } from "std/http";
import { createServer, createServerAsync, sendText, serveConcurrent, serveConcurrentAsync, stop } from "std/http/server";
import { createSocket, bind, connect, send, recv, close } from "std/net";
import { lockedRead, lockedUpdate } from "std/core/promise";

@include("./noFile.h");
extern function corpusRaiseNoFile(n: int32): int32;

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

function slowGet(port: int32, size: int32): string {
	const t0 = Date.now();
	while (Date.now() - t0 < 5000) {
		const fd = createSocket();
		if (connect(fd, "127.0.0.1", port) == 0) {
			send(fd, "GET /big HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
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

struct Served { n: int32; }

const served: Locked<Served> = new Locked({ n: 0 });

function servedCount(): int32 {
	return lockedRead(served, (s: Served): int32 => { return s.n; });
}

function handle(req: HttpRequest, res: ServerResponse): void {
	sendText(res, bigBody(6000000));
	lockedUpdate(served, (s: Served): Served => { return { n: s.n + 1 }; });
}

async function handleAsync(req: HttpRequest, res: ServerResponse): Promise<void> {
	handle(req, res);
}

const server = createServer(handle);
const serverAsync = createServerAsync(handleAsync);

function syncTwo(): void {
	lockedUpdate(served, (s: Served): Served => { return { n: 0 }; });
	const port = freePort();
	server.listen("127.0.0.1", port);
	const a = spawn(() => slowGet(port, 6000000));
	const b = spawn(() => slowGet(port, 6000000));
	const timer = setInterval(() => { if (servedCount() >= 2) stop(server); }, 5);
	serveConcurrent(server, 2);
	clearInterval(timer);
	console.log(`sync two clients: ${await a} | ${await b}`);
	console.log(`sync two clients: served=${servedCount()} running=${server.running}`);
}

function asyncTwo(): void {
	lockedUpdate(served, (s: Served): Served => { return { n: 0 }; });
	const port = freePort();
	serverAsync.listen("127.0.0.1", port);
	const a = spawn(() => slowGet(port, 6000000));
	const b = spawn(() => slowGet(port, 6000000));
	const timer = setInterval(() => { if (servedCount() >= 2) stop(serverAsync); }, 5);
	serveConcurrentAsync(serverAsync, handleAsync, 2);
	clearInterval(timer);
	console.log(`async two clients: ${await a} | ${await b}`);
	console.log(`async two clients: served=${servedCount()} running=${serverAsync.running}`);
}

const raised = corpusRaiseNoFile(1500) == 0;
const held: int32[] = [];
let past = raised;
while (past && held.length < 1100) {
	const fd = createSocket();
	if (fd < 0) past = false;
	else held.push(fd);
}
console.log(`raised=${raised} fds past 1100=${past && held[held.length - 1] >= 1100}`);

syncTwo();
asyncTwo();
for (const fd of held) close(fd);

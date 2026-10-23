// @xfail(raiser): error: Cannot resolve module 'std/http/server'
// @stdout: queued 2 threads: HTTP/1.1 200 OK /a | HTTP/1.1 200 OK /b
// @stdout: queued 2 threads: served=2 running=false
// @stdout: queued 4 threads: HTTP/1.1 200 OK /q0 | HTTP/1.1 200 OK /q1 | HTTP/1.1 200 OK /q2 | HTTP/1.1 200 OK /q3
// @stdout: queued 4 threads: served=4 running=false
// @stdout: queued async 4 threads: HTTP/1.1 200 OK /q0 | HTTP/1.1 200 OK /q1 | HTTP/1.1 200 OK /q2 | HTTP/1.1 200 OK /q3
// @stdout: queued async 4 threads: served=4 running=false
// @exit: 0
// @serial
// @skip-js: std/http/server is a .cms module, C backend only
// note: connections a client opens after listen() and before serveConcurrent / serveConcurrentAsync starts wait in the listening socket's backlog and each gets its reply (old: serveConcurrent closed listen()'s socket and reset them, the client read an empty reply and the server never counted them)

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

function request(port: int32, path: string): string {
	const t0 = Date.now();
	while (Date.now() - t0 < 5000) {
		const fd = createSocket();
		if (connect(fd, "127.0.0.1", port) == 0) {
			send(fd, `GET ${path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n`);
			let got = "";
			while (true) {
				const chunk = recv(fd, 4096);
				if (chunk.length == 0) break;
				got += chunk;
				if (got.includes("\r\n\r\n") && got.endsWith(path)) break;
			}
			close(fd);
			const status = got.split("\r\n")[0];
			const body = got.slice(got.indexOf("\r\n\r\n") + 4, got.length);
			return `${status} ${body}`;
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
	sendText(res, req.path);
	lockedUpdate(served, (s: Served): Served => { return { n: s.n + 1 }; });
}

async function handleAsync(req: HttpRequest, res: ServerResponse): Promise<void> {
	sendText(res, req.path);
	lockedUpdate(served, (s: Served): Served => { return { n: s.n + 1 }; });
}

const server = createServer(handle);
const serverAsync = createServerAsync(handleAsync);

function settle(): void {
	const t0 = Date.now();
	while (Date.now() - t0 < 300) {}
}

function sequential(port: int32): string {
	return request(port, "/a") + " | " + request(port, "/b");
}

function queuedTwo(): void {
	lockedUpdate(served, (s: Served): Served => { return { n: 0 }; });
	const port = freePort();
	server.listen("127.0.0.1", port);
	const c = spawn(() => sequential(port));
	const timer = setInterval(() => { if (servedCount() >= 2) stop(server); }, 5);
	settle();
	serveConcurrent(server, 2);
	clearInterval(timer);
	console.log(`queued 2 threads: ${await c}`);
	console.log(`queued 2 threads: served=${servedCount()} running=${server.running}`);
}

function burst(label: string, port: int32, serve: () => void): void {
	const q0 = spawn(() => request(port, "/q0"));
	const q1 = spawn(() => request(port, "/q1"));
	const q2 = spawn(() => request(port, "/q2"));
	const q3 = spawn(() => request(port, "/q3"));
	settle();
	serve();
	console.log(`${label}: ${await q0} | ${await q1} | ${await q2} | ${await q3}`);
}

function queuedFour(): void {
	lockedUpdate(served, (s: Served): Served => { return { n: 0 }; });
	const port = freePort();
	server.listen("127.0.0.1", port);
	const timer = setInterval(() => { if (servedCount() >= 4) stop(server); }, 5);
	burst("queued 4 threads", port, (): void => { serveConcurrent(server, 4); });
	clearInterval(timer);
	console.log(`queued 4 threads: served=${servedCount()} running=${server.running}`);
}

function queuedFourAsync(): void {
	lockedUpdate(served, (s: Served): Served => { return { n: 0 }; });
	const port = freePort();
	serverAsync.listen("127.0.0.1", port);
	const timer = setInterval(() => { if (servedCount() >= 4) stop(serverAsync); }, 5);
	burst("queued async 4 threads", port, (): void => { serveConcurrentAsync(serverAsync, handleAsync, 4); });
	clearInterval(timer);
	console.log(`queued async 4 threads: served=${servedCount()} running=${serverAsync.running}`);
}

queuedTwo();
queuedFour();
queuedFourAsync();

// @xfail(raiser): error: Cannot resolve module 'std/http/server'
// @stdout: HTTP/1.1 200 OK /a
// @stdout: HTTP/1.1 200 OK keep-alive=timeout=7
// @stdout: HTTP/1.1 200 OK /b
// @stdout: idle closed by server: true
// @stdout: threads=2 served=3 stopped running=false
// @exit: 0
// @serial
// @skip-js: std/http/server is a .cms module, C backend only
// note: serveConcurrent with 2 thread(s): a timer on the serving thread calls stop() once the handlers have counted 3 requests; every event loop sees it, the idle keep-alive connection is closed (its response carries the server's own Keep-Alive timeout), and the worker tasks are joined before serveConcurrent returns (old compiler: refused at check, the one HttpServer lent to every worker while the parent loop used it)

import { HttpRequest, ServerResponse } from "std/http";
import { createServer, sendText, serveConcurrent, stop } from "std/http/server";
import { createSocket, bind, connect, send, recv, close } from "std/net";
import { lockedRead, lockedUpdate, sleepAsync } from "std/core/promise";

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

function headerValue(raw: string, name: string): string {
	for (const line of raw.split("\r\n")) {
		if (line.toLowerCase().startsWith(`${name}:`)) return line.slice(name.length + 1, line.length).trim();
	}
	return "missing";
}

// A keep-alive connection that has had its response and stays open.
function idleConnection(port: int32): int32 {
	const fd = createSocket();
	if (connect(fd, "127.0.0.1", port) != 0) return -1;
	send(fd, "GET /idle HTTP/1.1\r\nHost: localhost\r\n\r\n");
	let got = "";
	while (!got.endsWith("/idle")) {
		const chunk = recv(fd, 4096);
		if (chunk.length == 0) break;
		got += chunk;
	}
	console.log(`${got.split("\r\n")[0]} keep-alive=${headerValue(got, "keep-alive")}`);
	return fd;
}

function client(port: int32): int32 {
	console.log(request(port, "/a"));
	const idle = idleConnection(port);
	console.log(request(port, "/b"));
	console.log(`idle closed by server: ${recv(idle, 4096).length == 0}`);
	close(idle);
	return 0;
}

struct Served { n: int32; }

const served: Locked<Served> = new Locked({ n: 0 });

struct Done { done: boolean; }

const finished: Locked<Done> = new Locked({ done: false });

function isFinished(): boolean {
	return lockedRead(finished, (d: Done): boolean => { return d.done; });
}

function watchdog(what: string): int32 {
	const t0 = Date.now();
	while (!isFinished()) {
		if (Date.now() - t0 > 30000) {
			console.log(`WATCHDOG: ${what} did not return within 30 s`);
			process.exit(2);
		}
		await sleepAsync(20);
	}
	return 0;
}

function servedCount(): int32 {
	return lockedRead(served, (s: Served): int32 => { return s.n; });
}

function handle(req: HttpRequest, res: ServerResponse): void {
	sendText(res, req.path);
	lockedUpdate(served, (s: Served): Served => { return { n: s.n + 1 }; });
}

const server = createServer(handle);

function round(threads: int32): void {
	const port = freePort();
	server.address = "127.0.0.1";
	server.port = port;
	server.keepAliveTimeout = 7000;
	lockedUpdate(served, (s: Served): Served => { return { n: 0 }; });
	lockedUpdate(finished, (d: Done): Done => { return { done: false }; });
	const w = spawn(() => watchdog(`serveConcurrent(threads=${threads})`));
	const c = spawn(() => client(port));
	const timer = setInterval(() => { if (servedCount() >= 3) stop(server); }, 5);
	serveConcurrent(server, threads);
	clearInterval(timer);
	await c;
	lockedUpdate(finished, (d: Done): Done => { return { done: true }; });
	await w;
	console.log(`threads=${threads} served=${servedCount()} stopped running=${server.running}`);
}

round(2);

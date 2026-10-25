// @xfail(raiser): error: Cannot resolve module 'std/http/server'
// @stdout: stop twice 4 threads: HTTP/1.1 200 OK /q0 | HTTP/1.1 200 OK /q1 | HTTP/1.1 200 OK /q2 | HTTP/1.1 200 OK /q3
// @stdout: stop twice 4 threads: served=4 running=false
// @stdout: stop twice async 4 threads: HTTP/1.1 200 OK /q0 | HTTP/1.1 200 OK /q1 | HTTP/1.1 200 OK /q2 | HTTP/1.1 200 OK /q3
// @stdout: stop twice async 4 threads: served=4 running=false
// @exit: 0
// @serial
// @skip-js: std/http/server is a .cms module, C backend only
// note: stop() called twice while the serving loops of serveConcurrent / serveConcurrentAsync drain returns once every loop has ended (shared listening socket: the second stop() closed it before the slower loops cancelled their accept, and those loops never ended)

import { HttpRequest, ServerResponse } from "std/http";
import { createServer, createServerAsync, sendText, serveConcurrent, serveConcurrentAsync, stop } from "std/http/server";
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

struct Served { n: int32; }

const served: Locked<Served> = new Locked({ n: 0 });

struct Done { done: boolean; }

const finished: Locked<Done> = new Locked({ done: false });

function servedCount(): int32 {
	return lockedRead(served, (s: Served): int32 => { return s.n; });
}

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

function round(label: string, port: int32, serve: () => void): void {
	lockedUpdate(finished, (d: Done): Done => { return { done: false }; });
	const w = spawn(() => watchdog(label));
	const q0 = spawn(() => request(port, "/q0"));
	const q1 = spawn(() => request(port, "/q1"));
	const q2 = spawn(() => request(port, "/q2"));
	const q3 = spawn(() => request(port, "/q3"));
	serve();
	lockedUpdate(finished, (d: Done): Done => { return { done: true }; });
	await w;
	console.log(`${label}: ${await q0} | ${await q1} | ${await q2} | ${await q3}`);
}

function stopTwice(): void {
	lockedUpdate(served, (s: Served): Served => { return { n: 0 }; });
	const port = freePort();
	server.listen("127.0.0.1", port);
	const timer = setInterval(() => { if (servedCount() >= 4) { stop(server); stop(server); } }, 5);
	round("stop twice 4 threads", port, (): void => { serveConcurrent(server, 4); });
	clearInterval(timer);
	console.log(`stop twice 4 threads: served=${servedCount()} running=${server.running}`);
}

function stopTwiceAsync(): void {
	lockedUpdate(served, (s: Served): Served => { return { n: 0 }; });
	const port = freePort();
	serverAsync.listen("127.0.0.1", port);
	const timer = setInterval(() => { if (servedCount() >= 4) { stop(serverAsync); stop(serverAsync); } }, 5);
	round("stop twice async 4 threads", port, (): void => { serveConcurrentAsync(serverAsync, handleAsync, 4); });
	clearInterval(timer);
	console.log(`stop twice async 4 threads: served=${servedCount()} running=${serverAsync.running}`);
}

stopTwice();
stopTwiceAsync();

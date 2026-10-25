// @xfail(raiser): error: Cannot resolve module 'std/http/server'
// @stdout: HTTP/1.1 200 OK /a
// @stdout: HTTP/1.1 200 OK /b
// @stdout: serveConcurrent aborted: served=2 running=false reason=enough
// @stdout: HTTP/1.1 200 OK /a
// @stdout: HTTP/1.1 200 OK /b
// @stdout: serveConcurrentAsync aborted: served=2 running=false reason=enough
// @stdout: aborted before serve: served=0 running=false
// @exit: 0
// @serial
// @skip-js: std/http/server is a .cms module, C backend only
// note: server.listen(addr, port, { signal }) as Node's listen({ signal }): aborting the controller on the serving thread stops a concurrent server (sync and async handlers, 2 threads); a signal aborted before serving makes the serve return at once

import { HttpRequest, ServerResponse } from "std/http";
import { createServer, createServerAsync, sendText, serveConcurrent, serveConcurrentAsync } from "std/http/server";
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

function client(port: int32): int32 {
	console.log(request(port, "/a"));
	console.log(request(port, "/b"));
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

function resetRound(): void {
	lockedUpdate(served, (s: Served): Served => { return { n: 0 }; });
	lockedUpdate(finished, (d: Done): Done => { return { done: false }; });
}

function endRound(): void {
	lockedUpdate(finished, (d: Done): Done => { return { done: true }; });
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

function abortedRound(): void {
	resetRound();
	const port = freePort();
	const controller = new AbortController();
	server.listen("127.0.0.1", port, { signal: controller.signal });
	const w = spawn(() => watchdog("serveConcurrent"));
	const c = spawn(() => client(port));
	const timer = setInterval(() => { if (servedCount() >= 2) controller.abort("enough"); }, 5);
	serveConcurrent(server, 2);
	clearInterval(timer);
	await c;
	endRound();
	await w;
	console.log(`serveConcurrent aborted: served=${servedCount()} running=${server.running} reason=${controller.signal.reason}`);
}

function abortedRoundAsync(): void {
	resetRound();
	const port = freePort();
	const controller = new AbortController();
	serverAsync.listen("127.0.0.1", port, { signal: controller.signal });
	const w = spawn(() => watchdog("serveConcurrentAsync"));
	const c = spawn(() => client(port));
	const timer = setInterval(() => { if (servedCount() >= 2) controller.abort("enough"); }, 5);
	serveConcurrentAsync(serverAsync, handleAsync, 2);
	clearInterval(timer);
	await c;
	endRound();
	await w;
	console.log(`serveConcurrentAsync aborted: served=${servedCount()} running=${serverAsync.running} reason=${controller.signal.reason}`);
}

function abortedBeforeServe(): void {
	resetRound();
	const controller = new AbortController();
	controller.abort("early");
	server.listen("127.0.0.1", freePort(), { signal: controller.signal });
	serveConcurrent(server, 2);
	console.log(`aborted before serve: served=${servedCount()} running=${server.running}`);
}

abortedRound();
abortedRoundAsync();
abortedBeforeServe();

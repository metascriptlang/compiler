// @xfail(raiser): error: Cannot resolve module 'std/http/server'
// @stdout: threads=1 answered all 40, sum=1600
// @stdout: threads=4 answered all 40, sum=1600
// @exit: 0
// @serial
// @skip-js: std/http/server is a .cms module, C backend only
// note: serveConcurrentAsync with 1 and then 4 thread(s), each handler awaiting a spawn: the spawn's completion returns to the serving thread that awaits it while the main loop runs beside it (old runtime: every loop drained one process-wide completion queue, so the main loop and a serving thread destroyed the same completion twice under ASan)

import { HttpRequest, ServerResponse } from "std/http";
import { createServerAsync, sendText, serveConcurrentAsync, stop } from "std/http/server";
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

function request(port: int32, n: int32): int32 {
	const t0 = Date.now();
	while (Date.now() - t0 < 5000) {
		const fd = createSocket();
		if (connect(fd, "127.0.0.1", port) == 0) {
			send(fd, `GET /${n} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n`);
			let got = "";
			while (true) {
				const chunk = recv(fd, 4096);
				if (chunk.length == 0) break;
				got += chunk;
				if (got.includes("\r\n\r\n") && got.endsWith(";")) break;
			}
			close(fd);
			const body = got.slice(got.indexOf("\r\n\r\n") + 4, got.length - 1);
			return parseInt(body) as int32;
		}
		close(fd);
	}
	return -1;
}

function client(port: int32): int32 {
	let ok: int32 = 0;
	let sum: int32 = 0;
	for (let i: int32 = 0; i < 40; i += 1) {
		const v = request(port, i);
		if (v >= 0) { ok += 1; sum += v; }
	}
	return ok == 40 ? sum : -ok;
}

struct Served { n: int32; }

const served: Locked<Served> = new Locked({ n: 0 });

function servedCount(): int32 {
	return lockedRead(served, (s: Served): int32 => { return s.n; });
}

function twicePlusOne(n: int32): int32 { return n * 2 + 1; }

async function handle(req: HttpRequest, res: ServerResponse): Promise<void> {
	const n = parseInt(req.path.slice(1, req.path.length)) as int32;
	const v = await spawn(() => twicePlusOne(n));
	sendText(res, `${v};`);
	lockedUpdate(served, (s: Served): Served => { return { n: s.n + 1 }; });
}

const server = createServerAsync(handle);

function round(threads: int32): void {
	const port = freePort();
	server.address = "127.0.0.1";
	server.port = port;
	lockedUpdate(served, (s: Served): Served => { return { n: 0 }; });
	const c = spawn(() => client(port));
	const timer = setInterval(() => { if (servedCount() >= 40) stop(server); }, 5);
	serveConcurrentAsync(server, handle, threads);
	clearInterval(timer);
	const r = await c;
	console.log(r >= 0 ? `threads=${threads} answered all 40, sum=${r}` : `threads=${threads} answered ${-r} of 40`);
}

round(1);
round(4);

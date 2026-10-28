// @xfail(raiser): error: Cannot resolve module 'std/http/server'
// @stdout: threads=2 answered all 300, last=300
// @stdout: threads=4 answered all 300, last=600
// @exit: 0
// @serial
// @skip-js: std/http/server is a .cms module, C backend only
// note: a handler on any serving thread awaits a call to one actor and gets the actor's result back on its own thread, in order and with no crash (the card saw a segfault after 187-312 sequential requests with 2 threads, from the job queue the actor call resumed through; the counter is the actor's, so a lost or doubled resume shows in `last`)

import { HttpRequest, ServerResponse, AsyncRequestHandler } from "std/http/types";
import { createServerAsync, sendText, serveConcurrentAsync, stop } from "std/http/server";
import { createSocket, bind, connect, send, recv, close } from "std/net";
import { lockedRead, lockedUpdate } from "std/core/promise";

actor Counter {
	private count: int32 = 0;
	next(): int32 {
		this.count += 1;
		return this.count;
	}
}

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

function request(port: int32): int32 {
	const t0 = Date.now();
	while (Date.now() - t0 < 5000) {
		const fd = createSocket();
		if (connect(fd, "127.0.0.1", port) == 0) {
			send(fd, "GET /n HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
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

const REQUESTS: int32 = 300;

function client(port: int32): int32 {
	let last: int32 = 0;
	for (let i: int32 = 0; i < REQUESTS; i += 1) {
		const v = request(port);
		if (v <= last) return -i;
		last = v;
	}
	return last;
}

struct Served { n: int32; }

const served: Locked<Served> = new Locked({ n: 0 });

function servedCount(): int32 {
	return lockedRead(served, (s: Served): int32 => { return s.n; });
}

function makeHandler(counter: Counter): AsyncRequestHandler {
	return async (req: HttpRequest, res: ServerResponse): Promise<void> => {
		const n = await counter.next();
		sendText(res, `${n};`);
		lockedUpdate(served, (s: Served): Served => { return { n: s.n + 1 }; });
	};
}

const counter = new Counter();
const handle = makeHandler(counter);
const server = createServerAsync(handle);

function round(threads: int32, expectedLast: int32): void {
	const port = freePort();
	server.address = "127.0.0.1";
	server.port = port;
	lockedUpdate(served, (s: Served): Served => { return { n: 0 }; });
	const c = spawn(() => client(port));
	const timer = setInterval(() => { if (servedCount() >= REQUESTS) stop(server); }, 5);
	serveConcurrentAsync(server, handle, threads);
	clearInterval(timer);
	const r = await c;
	console.log(r == expectedLast ? `threads=${threads} answered all ${REQUESTS}, last=${r}` : `threads=${threads} failed, client saw ${r}`);
}

round(2, 300);
round(4, 600);

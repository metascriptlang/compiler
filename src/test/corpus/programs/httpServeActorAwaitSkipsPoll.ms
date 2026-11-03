// @xfail(raiser): error: 'createServerAsync', 'sendText', 'serveConcurrentAsync', 'stop' from 'std/http/server' cannot run on the Raiser: the module has no Raiser tier; it runs on C
// @stdout: one await: 50 awaits under 200 ms
// @stdout: two nested awaits: 50 awaits under 200 ms
// @exit: 0
// @serial
// @skip-js: std/http/server is a .cms module, C backend only

import { HttpRequest, ServerResponse } from "std/http";
import { createServerAsync, sendText, serveConcurrentAsync, stop } from "std/http/server";
import { createSocket, bind, connect, send, recv, close } from "std/net";
import { lockedRead, lockedUpdate } from "std/core/promise";

const AWAITS: int32 = 50;

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

function fetchBody(port: int32): string {
	const t0 = Date.now();
	while (Date.now() - t0 < 5000) {
		const fd = createSocket();
		if (connect(fd, "127.0.0.1", port) == 0) {
			send(fd, "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
			let got = "";
			while (true) {
				const chunk = recv(fd, 4096);
				if (chunk.length == 0) break;
				got += chunk.asString();
				if (got.includes("\r\n\r\n") && got.endsWith(";")) break;
			}
			close(fd);
			return got.slice(got.indexOf("\r\n\r\n") + 4, got.length - 1);
		}
		close(fd);
	}
	return "no answer";
}

async function inner(): Promise<boolean> {
	return true;
}

async function outer(): Promise<boolean> {
	return await inner();
}

actor Awaiter {
	run(nested: boolean): string {
		const started = Date.now();
		let count: int32 = 0;
		for (let i: int32 = 0; i < AWAITS; i += 1) {
			const ok = nested ? await outer() : await inner();
			if (ok) count += 1;
		}
		const ms = Date.now() - started;
		return ms < 200 ? `${count} awaits under 200 ms` : `${count} awaits took ${ms} ms`;
	}
}

struct Served { n: int32; }

const served: Locked<Served> = new Locked({ n: 0 });

async function handle(req: HttpRequest, res: ServerResponse): Promise<void> {
	const one = await new Awaiter().run(false);
	const two = await new Awaiter().run(true);
	sendText(res, `one await: ${one}\ntwo nested awaits: ${two};`);
	lockedUpdate(served, (s: Served): Served => { return { n: s.n + 1 }; });
}

const server = createServerAsync(handle);
const port = freePort();
server.address = "127.0.0.1";
server.port = port;
const c = spawn(() => fetchBody(port));
const timer = setInterval(() => { if (lockedRead(served, (s: Served): int32 => { return s.n; }) > 0) stop(server); }, 5);
serveConcurrentAsync(server, handle, 1);
clearInterval(timer);
console.log(await c);

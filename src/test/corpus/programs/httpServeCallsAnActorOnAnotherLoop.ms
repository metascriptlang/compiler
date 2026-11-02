// @xfail(raiser): error: Cannot resolve module 'std/http/server'
// @stdout: an actor made on each of four serving loops: 8 requests answered, every call under 5 ms on average
// @stdout: spawn completions on four serving loops: 8 requests answered, every await under 5 ms on average
// @stdout: spawn completions on the main serving loop: 8 requests answered, every await under 5 ms on average
// @exit: 0
// @serial
// @skip-js: std/http/server is a .cms module, C backend only
// note: four serving loops, then the main thread's alone, whose handlers wait on actors and spawns: an actor a handler makes belongs to that serving loop (old runtime: to another scheduler, which the loop's CALLs waited on), and every completion another thread posts reaches the serving loop parked in its I/O engine (old runtime on io_uring: about 10 ms per wait, one driver poll); a line for an actor the main thread owns waits on inbox card 2026-11-02-serve-concurrent-async-closure-handler-env-destroyed-after-free

import { HttpRequest, ServerResponse } from "std/http";
import { AsyncRequestHandler } from "std/http/types";
import { createServerAsync, sendText, serveConcurrentAsync, stop } from "std/http/server";
import { createSocket, bind, connect, send, recv, close } from "std/net";
import { lockedRead, lockedUpdate } from "std/core/promise";

const CLIENTS: int32 = 8;
const CALLS: int32 = 50;
const REQUESTS: int32 = 8;
const SPAWNS: int32 = 20;

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

actor Counter {
	count: int32 = 0;
	bump(): int32 {
		this.count += 1;
		return this.count;
	}
}

struct Served { n: int32; worstMeanMs: float64; }

const served: Locked<Served> = new Locked({ n: 0, worstMeanMs: 0.0 });

function record(mean: float64): void {
	lockedUpdate(served, (s: Served): Served => ({ n: s.n + 1, worstMeanMs: mean > s.worstMeanMs ? mean : s.worstMeanMs }));
}

function report(what: string, answered: int32, unit: string): void {
	const s = lockedRead(served, (s: Served): Served => s);
	console.log(s.worstMeanMs < 5 ? `${what}: ${answered} requests answered, every ${unit} under 5 ms on average` : `${what}: ${answered} requests answered, worst mean ${s.worstMeanMs} ms per ${unit}`);
	lockedUpdate(served, (s: Served): Served => ({ n: 0, worstMeanMs: 0.0 }));
}

function serveUntil(handle: AsyncRequestHandler, requests: int32, threads: int32, parallel: boolean): int32 {
	const server = createServerAsync(handle);
	const port = freePort();
	server.address = "127.0.0.1";
	server.port = port;
	const c = spawn(() => parallel ? parallelClients(port) : sequentialClient(port));
	const timer = setInterval(() => { if (lockedRead(served, (s: Served): int32 => s.n) >= requests) stop(server); }, 5);
	serveConcurrentAsync(server, handle, threads);
	clearInterval(timer);
	return await c;
}

async function calls(req: HttpRequest, res: ServerResponse): Promise<void> {
	const counter = new Counter();
	const started = Date.now();
	for (let i: int32 = 0; i < CALLS; i += 1) await counter.bump();
	sendText(res, "ok;");
	record((Date.now() - started) / CALLS);
}

function parallelClients(port: int32): int32 {
	const hs: Promise<string>[] = [];
	for (let c: int32 = 0; c < CLIENTS; c += 1) hs.push(spawn(() => fetchBody(port)));
	let ok: int32 = 0;
	for (const h of hs) if ((await h) == "ok") ok += 1;
	return ok;
}

function twicePlusOne(n: int32): int32 { return n * 2 + 1; }

function twicePlusOneElsewhere(n: int32): Promise<int32> { return spawn(() => twicePlusOne(n)); }

async function spawns(req: HttpRequest, res: ServerResponse): Promise<void> {
	const started = Date.now();
	let sum: int32 = 0;
	for (let i: int32 = 0; i < SPAWNS; i += 1) sum += await twicePlusOneElsewhere(i);
	sendText(res, sum == SPAWNS * SPAWNS ? "ok;" : `sum ${sum};`);
	record((Date.now() - started) / SPAWNS);
}

function sequentialClient(port: int32): int32 {
	let ok: int32 = 0;
	for (let r: int32 = 0; r < REQUESTS; r += 1) if (fetchBody(port) == "ok") ok += 1;
	return ok;
}

report("an actor made on each of four serving loops", serveUntil(calls, CLIENTS, 4, true), "call");
report("spawn completions on four serving loops", serveUntil(spawns, REQUESTS, 4, false), "await");
report("spawn completions on the main serving loop", serveUntil(spawns, REQUESTS, 1, false), "await");

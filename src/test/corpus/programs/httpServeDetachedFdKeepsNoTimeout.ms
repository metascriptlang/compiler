// @xfail(raiser): std/http/server is a .cms module, C backend only
// @xfail(san): blocking serve() has no stop its Sendable handler may call, so the handler ends the program with exit(0), and the module state and serve()'s connection frame stay live in the exit-time ledger
// @skip-js: std/http/server is a .cms module, C backend only
// @serial
// @stdout: serve: HTTP/1.1 101 Switching Protocols then echo: hello
// @exit: 0
// note: under a 200 ms keepAliveTimeout, a connection a blocking serve() handler took with res.detach() carries no
//   receive timeout, so the handler's own blocking recv waits 2.5 s for the peer (old std: serve()'s socket timeout
//   stayed on the detached fd and the recv returned empty after 200 ms).

import { HttpRequest, ServerResponse } from "std/http/types";
import { createServer, serve } from "std/http/server";
import { createSocket, bind, connect, send, recv, setTimeout, close } from "std/net";
import { exit } from "std/process";
import { lockedRead, lockedUpdate, sleepAsync } from "std/core/promise";

const PAST_SWEEP_MS = 2500;

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

function upgrade(port: int32): int32 {
	const t0 = Date.now();
	while (Date.now() - t0 < 5000) {
		const fd = createSocket();
		if (connect(fd, "127.0.0.1", port) == 0) {
			setTimeout(fd, 5000);
			send(fd, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
			return fd;
		}
		close(fd);
	}
	return -1;
}

function statusLine(fd: int32): string {
	let head = "";
	while (!head.includes("\r\n\r\n")) {
		const chunk = recv(fd, 256);
		if (chunk.length == 0) break;
		head += chunk;
	}
	return head.split("\r\n")[0];
}

const clientDone: Locked<boolean> = new Locked(false);

function plainClient(port: int32): int32 {
	const fd = upgrade(port);
	const status = statusLine(fd);
	await sleepAsync(PAST_SWEEP_MS);
	send(fd, "hello");
	console.log(`serve: ${status} then ${recv(fd, 64)}`);
	close(fd);
	lockedUpdate(clientDone, (d: boolean): boolean => true);
	return 0;
}

const plain = createServer((req: HttpRequest, res: ServerResponse): void => {
	const fd = res.detach();
	send(fd, "HTTP/1.1 101 Switching Protocols\r\n\r\n");
	send(fd, `echo: ${recv(fd, 64)}`);
	close(fd);
	const t0 = Date.now();
	while (!lockedRead(clientDone, (d: boolean): boolean => d) && Date.now() - t0 < 10000) {}
	exit(0);
});
plain.keepAliveTimeout = 200;
const plainPort = freePort();
const l = plain.listen("127.0.0.1", plainPort);
if (!l.ok) throw new Error(l.error.message);
const p = spawn(() => plainClient(plainPort));
serve(plain);
await p;

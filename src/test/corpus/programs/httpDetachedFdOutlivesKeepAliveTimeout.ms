// @xfail(raiser): std/http/server is a .cms module, C backend only
// @skip-js: std/http/server is a .cms module, C backend only
// @serial
// @stdout: serveConcurrent: HTTP/1.1 101 Switching Protocols then still open
// @exit: 0
// note: under a 200 ms keepAliveTimeout, a connection a sync serveConcurrent handler took with res.detach() is still
//   open 2.5 s later, past several idle sweeps (old std: the readiness loop's idle sweep closed it).

import { HttpRequest, ServerResponse } from "std/http/types";
import { createServer, serveConcurrent, stop } from "std/http/server";
import { createSocket, bind, connect, send, recv, setBlocking, setTimeout, close } from "std/net";
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
		head += chunk.asString();
	}
	return head.split("\r\n")[0];
}

const held: Locked<int32> = new Locked(-1);
const waited: Locked<boolean> = new Locked(false);

function concurrentClient(port: int32): int32 {
	const fd = upgrade(port);
	const status = statusLine(fd);
	await sleepAsync(PAST_SWEEP_MS);
	lockedUpdate(waited, (w: boolean): boolean => true);
	console.log(`serveConcurrent: ${status} then ${recv(fd, 64).asString()}`);
	close(fd);
	return 0;
}

const concurrent = createServer((req: HttpRequest, res: ServerResponse): void => {
	const fd = res.detach();
	send(fd, "HTTP/1.1 101 Switching Protocols\r\n\r\n");
	lockedUpdate(held, (h: int32): int32 => fd);
});
concurrent.keepAliveTimeout = 200;
concurrent.address = "127.0.0.1";
const concurrentPort = freePort();
concurrent.port = concurrentPort;
const c = spawn(() => concurrentClient(concurrentPort));
const timer = setInterval(() => { if (lockedRead(waited, (w: boolean): boolean => w)) stop(concurrent); }, 5);
serveConcurrent(concurrent, 1);
clearInterval(timer);
const heldFd = lockedRead(held, (h: int32): int32 => h);
setBlocking(heldFd);
send(heldFd, "still open");
await c;
close(heldFd);

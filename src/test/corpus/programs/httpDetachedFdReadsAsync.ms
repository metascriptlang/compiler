// @xfail(raiser): std/http/server is a .cms module, C backend only
// @skip-js: std/http/server is a .cms module, C backend only
// @serial
// @stdout: detached read: hello
// @stdout: client saw 101: true
// note: a handler detaches its fd and reads it with recvAsync; the read completes when the peer sends, on the readiness
//   loop and on the io_uring loop alike (the io_uring loop used to pump only the dispatcher, so the read never completed).

import { recvAsync, send, createSocket, bind, connect, recv, close } from "std/net";
import { HttpRequest, ServerResponse } from "std/http/types";
import { createServer, serveConcurrent, stop } from "std/http/server";
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

const done: Locked<int32> = new Locked(0);

async function readOnce(fd: int32): Promise<void> {
	const chunk = await recvAsync(fd, 64);
	console.log(`detached read: ${chunk}`);
	close(fd);
	lockedUpdate(done, (v: int32): int32 => v + 1);
}

function client(port: int32): boolean {
	const t0 = Date.now();
	while (Date.now() - t0 < 5000) {
		const fd = createSocket();
		if (connect(fd, "127.0.0.1", port) == 0) {
			send(fd, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
			let got = "";
			while (!got.includes("\r\n\r\n")) {
				const c = recv(fd, 256);
				if (c.length == 0) break;
				got += c;
			}
			send(fd, "hello");
			const t1 = Date.now();
			while (lockedRead(done, (v: int32): int32 => v) == 0 && Date.now() - t1 < 5000) {}
			close(fd);
			return got.startsWith("HTTP/1.1 101");
		}
		close(fd);
	}
	return false;
}

const server = createServer((req: HttpRequest, res: ServerResponse): void => {
	const fd = res.detach();
	send(fd, "HTTP/1.1 101 Switching Protocols\r\n\r\n");
	readOnce(fd);
});
server.keepAliveTimeout = 0;
const port = freePort();
const l = server.listen("127.0.0.1", port);
if (!l.ok) throw new Error(l.error.message);
const c = spawn(() => client(port));
const timer = setInterval(() => { if (lockedRead(done, (v: int32): int32 => v) > 0) stop(server); }, 5);
serveConcurrent(server, 1);
clearInterval(timer);
console.log(`client saw 101: ${await c}`);

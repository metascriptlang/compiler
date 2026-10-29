// @xfail(raiser): std/http/server is a .cms module, C backend only
// @skip-js: std/http/server is a .cms module, C backend only
// @serial
// @stdout: /return: HTTP/1.1 101 Switching Protocols then echo: hello
// @stdout: /await: HTTP/1.1 101 Switching Protocols then echo: hello
// @stdout: idle keep-alive closed by server: true
// @exit: 0
// note: serveConcurrentAsync with a 200 ms keepAliveTimeout: a connection the handler took with res.detach() still
//   echoes 2.5 s later, whether the handler returned at once or awaits the session itself, while an idle keep-alive
//   connection is closed by the sweep (old std: the idle sweep closed the detached fd too).

import { HttpRequest, ServerResponse } from "std/http/types";
import { createServerAsync, sendText, serveConcurrentAsync, stop } from "std/http/server";
import { createSocket, bind, connect, send, recv, recvAsync, recvTimedOut, setTimeout, close } from "std/net";
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

async function echoOnce(fd: int32): Promise<void> {
	const chunk = await recvAsync(fd, 64);
	if (chunk.length == 0) return;
	send(fd, `echo: ${chunk}`);
	close(fd);
}

async function handle(req: HttpRequest, res: ServerResponse): Promise<void> {
	if (req.path == "/idle") {
		sendText(res, "idle");
		return;
	}
	const fd = res.detach();
	send(fd, "HTTP/1.1 101 Switching Protocols\r\n\r\n");
	if (req.path == "/await") {
		await echoOnce(fd);
	} else {
		echoOnce(fd);
	}
}

function connectTo(port: int32, path: string): int32 {
	const t0 = Date.now();
	while (Date.now() - t0 < 5000) {
		const fd = createSocket();
		if (connect(fd, "127.0.0.1", port) == 0) {
			setTimeout(fd, 5000);
			send(fd, `GET ${path} HTTP/1.1\r\nHost: x\r\n\r\n`);
			return fd;
		}
		close(fd);
	}
	return -1;
}

function readHead(fd: int32): string {
	let got = "";
	while (!got.includes("\r\n\r\n")) {
		const chunk = recv(fd, 256);
		if (chunk.length == 0) break;
		got += chunk;
	}
	return got;
}

function detached(port: int32, path: string): string {
	const fd = connectTo(port, path);
	if (fd < 0) return `${path}: no connection`;
	const status = readHead(fd).split("\r\n")[0];
	await sleepAsync(PAST_SWEEP_MS);
	send(fd, "hello");
	const reply = recv(fd, 64);
	close(fd);
	return `${path}: ${status} then ${reply}`;
}

function idleClosed(port: int32): boolean {
	const fd = connectTo(port, "/idle");
	if (fd < 0) return false;
	const head = readHead(fd);
	let got = head;
	while (!got.endsWith("idle")) {
		const chunk = recv(fd, 256);
		if (chunk.length == 0) break;
		got += chunk;
	}
	const rest = recv(fd, 64);
	const closed = rest.length == 0 && !recvTimedOut();
	close(fd);
	return closed;
}

const done: Locked<boolean> = new Locked(false);

function client(port: int32): int32 {
	console.log(detached(port, "/return"));
	console.log(detached(port, "/await"));
	console.log(`idle keep-alive closed by server: ${idleClosed(port)}`);
	lockedUpdate(done, (d: boolean): boolean => true);
	return 0;
}

const port = freePort();
const server = createServerAsync(handle);
server.address = "127.0.0.1";
server.port = port;
server.keepAliveTimeout = 200;
const c = spawn(() => client(port));
const timer = setInterval(() => { if (lockedRead(done, (d: boolean): boolean => d)) stop(server); }, 5);
serveConcurrentAsync(server, handle, 1);
clearInterval(timer);
await c;

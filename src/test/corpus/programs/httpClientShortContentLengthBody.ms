// @xfail(raiser): error: Cannot resolve module 'std/net' (std/net and std/http/client are .cms modules, C backend only)
// @stdout: slow chunks | ok 200 30 bytes
// @stdout: stalled past timeout | error body shorter than Content-Length: 10 of 30 bytes
// @stdout: closed early | error body shorter than Content-Length: 10 of 30 bytes
// @exit: 0
// @serial
// @skip-js: std/http/client is a .cms module, C backend only
// note: std/http/client `request` returns an error naming the shortfall when the body ends before Content-Length bytes (a read timeout or an early close), and the full body when the chunks arrive slowly within the timeout

import { HttpMethod } from "std/http";
import { request } from "std/http/client";
import { createSocket, bind, listen, accept, send, recv, close } from "std/net";
import { sleepAsync } from "std/core/promise";

const HEAD = "HTTP/1.1 200 OK\r\nContent-Length: 30\r\nConnection: close\r\n\r\n";
const TEN = "0123456789";

function listenOnFreePort(fd: int32): int32 {
	let port = (20000 + Date.now() % 20000) as int32;
	while (bind(fd, "127.0.0.1", port) < 0) port = port + 1;
	listen(fd, 8);
	return port;
}

function call(port: int32): string {
	const res = request({
		method: HttpMethod.GET, hostname: "127.0.0.1", port: port, path: "/",
		headers: { _names: [], _values: [] }, body: "", timeout: 1000, tls: false,
	});
	if (!res.ok) return `error ${res.error.message}`;
	return `ok ${res.value.status} ${res.value.bytes.length} bytes`;
}

function client(port: int32): string[] {
	return [call(port), call(port), call(port)];
}

function readHead(fd: int32): void {
	let head = "";
	while (!head.includes("\r\n\r\n")) {
		const chunk = recv(fd, 4096);
		if (chunk.length == 0) break;
		head += chunk.asString();
	}
}

const listenFd = createSocket();
const port = listenOnFreePort(listenFd);
const c = spawn(() => client(port));

let fd = accept(listenFd);
readHead(fd);
send(fd, HEAD + TEN);
await sleepAsync(300);
send(fd, TEN);
await sleepAsync(300);
send(fd, TEN);
close(fd);

fd = accept(listenFd);
readHead(fd);
send(fd, HEAD + TEN);
await sleepAsync(1600);
send(fd, TEN + TEN);
close(fd);

fd = accept(listenFd);
readHead(fd);
send(fd, HEAD + TEN);
close(fd);

const results = await c;
close(listenFd);
console.log(`slow chunks | ${results[0]}`);
console.log(`stalled past timeout | ${results[1]}`);
console.log(`closed early | ${results[2]}`);

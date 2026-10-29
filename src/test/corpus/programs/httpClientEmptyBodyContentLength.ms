// @xfail(raiser): error: Cannot resolve module 'std/net' (std/net and std/http/client are .cms modules, C backend only)
// @stdout: POST content-length: 0 | 200
// @stdout: PUT content-length: 0 | 200
// @stdout: PATCH content-length: 0 | 200
// @stdout: GET no content-length | 200
// @stdout: HEAD no content-length | 200
// @exit: 0
// @serial
// @skip-js: std/http/client is a .cms module, C backend only
// note: std/http/client `request` sends Content-Length: 0 for a POST, PUT or PATCH with an empty body (RFC 9110 §8.6, as Node's http client does) and none for a bodyless GET or HEAD

import { HttpMethod } from "std/http";
import { request } from "std/http/client";
import { createSocket, bind, listen, accept, send, recv, close } from "std/net";

function listenOnFreePort(fd: int32): int32 {
	let port = (20000 + Date.now() % 20000) as int32;
	while (bind(fd, "127.0.0.1", port) < 0) port = port + 1;
	listen(fd, 8);
	return port;
}

function call(port: int32, method: HttpMethod): string {
	const res = request({
		method: method, hostname: "127.0.0.1", port: port, path: "/",
		headers: { _names: [], _values: [] }, body: "", timeout: 5000, tls: false,
	});
	if (!res.ok) return "error";
	return res.value.status.toString();
}

function client(port: int32): string[] {
	return [
		call(port, HttpMethod.POST),
		call(port, HttpMethod.PUT),
		call(port, HttpMethod.PATCH),
		call(port, HttpMethod.GET),
		call(port, HttpMethod.HEAD),
	];
}

function serveOne(listenFd: int32): string {
	const fd = accept(listenFd);
	let head = "";
	while (!head.includes("\r\n\r\n")) {
		const chunk = recv(fd, 4096);
		if (chunk.length == 0) break;
		head += chunk;
	}
	send(fd, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
	close(fd);
	const method = head.slice(0, head.indexOf(" "));
	const length = head.toLowerCase().split("\r\n").filter((line: string): boolean => line.startsWith("content-length:"));
	return `${method} ${length.length == 0 ? "no content-length" : length.join(",")}`;
}

const listenFd = createSocket();
const port = listenOnFreePort(listenFd);
const c = spawn(() => client(port));
const seen: string[] = [];
for (let i = 0; i < 5; i++) seen.push(serveOne(listenFd));
const statuses = await c;
close(listenFd);
for (let i = 0; i < 5; i++) console.log(`${seen[i]} | ${statuses[i]}`);

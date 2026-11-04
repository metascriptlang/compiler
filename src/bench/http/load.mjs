// The one load generator both arms run against their own server: node load.mjs <port>. It holds `width` requests in
// flight and each timed call completes the oldest and issues the next, so a row's time per call is the server's time
// per request at that concurrency. A raw HTTP/1.1 client over node:net keeps the client's own cost small and equal.

import net from "node:net";
import { benchAsync } from "../harness.mjs";

const port = Number(process.argv[2]);
const echoBody = Buffer.alloc(65536, "x");

function head(method, path, length, keepAlive) {
	const lengthLine = length > 0 ? `Content-Length: ${length}\r\n` : "";
	return Buffer.from(`${method} ${path} HTTP/1.1\r\nHost: 127.0.0.1\r\n${lengthLine}Connection: ${keepAlive ? "keep-alive" : "close"}\r\n\r\n`);
}

function responseLength(data) {
	const end = data.indexOf("\r\n\r\n");
	if (end < 0) return -1;
	const headText = data.subarray(0, end).toString("latin1");
	if (!headText.startsWith("HTTP/1.1 200")) throw new Error(`status: ${headText.split("\r\n")[0]}`);
	const match = /\r\ncontent-length:\s*(\d+)/i.exec(headText);
	if (match == null) throw new Error(`no content-length: ${headText}`);
	return end + 4 + Number(match[1]);
}

class Connection {
	constructor() {
		this.socket = null;
		this.chunks = [];
		this.size = 0;
		this.waiter = null;
	}

	open() {
		return new Promise((resolve, reject) => {
			const socket = net.connect({ host: "127.0.0.1", port, noDelay: true }, () => resolve());
			socket.on("data", (chunk) => this.received(chunk));
			socket.on("error", (error) => { if (this.waiter != null) this.waiter.reject(error); else reject(error); });
			this.socket = socket;
		});
	}

	received(chunk) {
		this.chunks.push(chunk);
		this.size += chunk.length;
		if (this.waiter == null) return;
		const data = this.chunks.length == 1 ? this.chunks[0] : Buffer.concat(this.chunks);
		this.chunks = [data];
		const total = responseLength(data);
		if (total < 0 || this.size < total) return;
		if (this.size > total) throw new Error("bytes past the response");
		const { resolve, expect } = this.waiter;
		this.waiter = null;
		this.chunks = [];
		this.size = 0;
		const bodyLength = total - data.indexOf("\r\n\r\n") - 4;
		if (bodyLength != expect) throw new Error(`body ${bodyLength} bytes, expected ${expect}`);
		resolve();
	}

	request(requestHead, body, expect) {
		return new Promise((resolve, reject) => {
			this.waiter = { resolve, reject, expect };
			if (body == null) this.socket.write(requestHead);
			else { this.socket.cork(); this.socket.write(requestHead); this.socket.write(body); this.socket.uncork(); }
		});
	}

	close() {
		this.socket.destroy();
	}
}

async function keepAliveSend(conn, requestHead, body, expect) {
	await conn.request(requestHead, body, expect);
}

async function freshSend(requestHead, body, expect) {
	const conn = new Connection();
	await conn.open();
	await conn.request(requestHead, body, expect);
	conn.socket.resetAndDestroy();
}

async function row(name, perCallBytes, width, keepAlive, method, path, body, expect) {
	const requestHead = head(method, path, body == null ? 0 : body.length, keepAlive);
	const conns = [];
	if (keepAlive) for (let i = 0; i < width; i++) { conns.push(new Connection()); await conns[i].open(); }
	const issue = (i) => keepAlive ? keepAliveSend(conns[i], requestHead, body, expect) : freshSend(requestHead, body, expect);
	const inFlight = [];
	for (let i = 0; i < width; i++) inFlight.push(issue(i));
	let next = 0;
	await benchAsync(name, perCallBytes, async () => {
		const slot = next;
		next = (next + 1) % width;
		await inFlight[slot];
		inFlight[slot] = issue(slot);
	});
	await Promise.all(inFlight);
	for (const conn of conns) conn.close();
}

const helloLength = "Hello, World!".length;
const jsonLength = 1024;

await row("hello keep-alive c1", 0, 1, true, "GET", "/hello", null, helloLength);
await row("hello keep-alive c16", 0, 16, true, "GET", "/hello", null, helloLength);
await row("hello new-conn c1", 0, 1, false, "GET", "/hello", null, helloLength);
await row("hello new-conn c16", 0, 16, false, "GET", "/hello", null, helloLength);
await row("json 1 KB keep-alive c1", 0, 1, true, "GET", "/json", null, jsonLength);
await row("json 1 KB keep-alive c16", 0, 16, true, "GET", "/json", null, jsonLength);
await row("post echo 64 KB c1", 65536, 1, true, "POST", "/echo", echoBody, echoBody.length);
await row("post echo 64 KB c16", 65536, 16, true, "POST", "/echo", echoBody, echoBody.length);

const stop = new Connection();
await stop.open();
await stop.request(head("GET", "/stop", 0, false), null, 3);
stop.close();

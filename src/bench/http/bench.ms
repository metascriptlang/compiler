// One serving thread, as node has: load.mjs drives it, and its rows are this arm's output.

import { HttpRequest, ServerResponse } from "std/http";
import {
	createServer,
	sendJson,
	sendText,
	serveConcurrent,
	stop,
} from "std/http/server";
import { createSocket, bind, close } from "std/net";
import { env, spawn, ChildStream } from "std/process";
import { lockedRead, lockedUpdate } from "std/core/promise";

const HELLO = "Hello, World!";

function jsonBody(): string {
	const items: string[] = [];
	for (let i = 0; i < 20; i++) {
		items.push(`{"id":${i},"name":"item ${i}","ok":true}`);
	}
	const head = `{"items":[${items.join(",")}],"pad":"`;
	return head + "x".repeat(1024 - head.length - 2) + `"}`;
}

const JSON_BODY = jsonBody();

struct Stopping { asked: boolean; }

const stopping: Locked<Stopping> = new Locked({ asked: false });

function stopAsked(): boolean {
	return lockedRead(stopping, (s: Stopping): boolean => s.asked);
}

function handle(req: HttpRequest, res: ServerResponse): void {
	match (req.path) {
		"/hello" => sendText(res, HELLO),
		"/json" => sendJson(res, JSON_BODY),
		"/echo" => sendText(res, req.bodyText()),
		"/stop" => {
			lockedUpdate(stopping, (s: Stopping): Stopping => {
				return { asked: true };
			});
			sendText(res, "bye");
		},
		_ => sendText(res, "unknown path " + req.path),
	};
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

const server = createServer(handle);
const port = freePort();
const listening = server.listen("127.0.0.1", port);
if (!listening.ok) throw new Error(listening.error.message);

const node = env.get("NODE") != "" ? env.get("NODE") : "node";
const started = spawn(node, ["src/bench/http/load.mjs", port.toString()]);
if (!started.ok) throw new Error(started.error.message);
const client = started.value;
client.closeStdin();

const timer = setInterval(() => {
	if (stopAsked() || client.wait(0).ok) stop(server);
}, 5);
serveConcurrent(server, 1);
clearInterval(timer);

let rows = "";
while (true) {
	const got = client.read(ChildStream.Stdout, 10000);
	if (!got.ok) throw new Error(got.error.message);
	rows += got.value.data;
	if (got.value.ended) break;
}
console.log(rows.trimEnd());
const status = client.wait(10000);
const errors = client.takeStderr();
client.close();
if (!status.ok || status.value.code != 0 || errors != "") {
	throw new Error("load.mjs failed: " + errors);
}

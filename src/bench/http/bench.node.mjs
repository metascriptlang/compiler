// The echo row decodes the body to a string and encodes it back, as std/http's string-only response does.

import http from "node:http";
import { spawn } from "node:child_process";

const HELLO = "Hello, World!";

function jsonBody() {
	const items = [];
	for (let i = 0; i < 20; i++) items.push(`{"id":${i},"name":"item ${i}","ok":true}`);
	const head = `{"items":[${items.join(",")}],"pad":"`;
	return head + "x".repeat(1024 - head.length - 2) + `"}`;
}

const JSON_BODY = jsonBody();

function send(res, contentType, body) {
	res.setHeader("content-type", contentType);
	res.end(body);
}

const server = http.createServer((req, res) => {
	if (req.url == "/echo") {
		const chunks = [];
		req.on("data", (chunk) => chunks.push(chunk));
		req.on("end", () => send(res, "text/plain; charset=utf-8", Buffer.concat(chunks).toString("utf8")));
		return;
	}
	if (req.url == "/hello") send(res, "text/plain; charset=utf-8", HELLO);
	else if (req.url == "/json") send(res, "application/json", JSON_BODY);
	else if (req.url == "/stop") send(res, "text/plain; charset=utf-8", "bye");
	else send(res, "text/plain; charset=utf-8", "unknown path " + req.url);
});

server.listen(0, "127.0.0.1", () => {
	const client = spawn(process.execPath, ["src/bench/http/load.mjs", String(server.address().port)], { stdio: ["ignore", "inherit", "inherit"] });
	client.on("exit", (code) => {
		server.close();
		server.closeAllConnections();
		if (code != 0) process.exitCode = 1;
	});
});

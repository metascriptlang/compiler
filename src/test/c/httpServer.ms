// E2E: HTTP server compilation
// Migrated from examples/httpConcurrent.ms — server entry point runs
// forever (event loop), so runtime testing isn't tractable in this suite.
// Instead, we verify the full pipeline parses + checks + lowers + codegens
// through to C for the canonical concurrent-server pattern. Catches:
//   - std/http + std/http/server + std/os imports stay resolvable
//   - createServer + listen + serveConcurrent typecheck against current API
//   - Request/Response handler closure lifts correctly
//   - sendText / sendJson / JSON.stringify code paths reachable

import { compileToC } from "../helpers";

test "E2E C: minimal HTTP server compiles" {
	const src = `
import { HttpRequest, ServerResponse } from "std/http";
import { createServer, sendText } from "std/http/server";

function main(): void {
	const server = createServer((req: HttpRequest, res: ServerResponse): void => {
		sendText(res, "ok");
	});
	const lr = server.listen("127.0.0.1", 9999);
	if (!lr.ok) { return; }
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: HTTP server with route + JSON response compiles" {
	const src = `
import { HttpRequest, ServerResponse } from "std/http";
import { createServer, sendText, sendJson } from "std/http/server";

function main(): void {
	const server = createServer((req: HttpRequest, res: ServerResponse): void => {
		if (req.path === "/ping") { sendText(res, "pong"); return; }
		sendJson(res, JSON.stringify({ path: req.path }));
	});
	const lr = server.listen("127.0.0.1", 9999);
	if (!lr.ok) { return; }
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: concurrent HTTP server compiles" {
	const src = `
import { HttpRequest, ServerResponse } from "std/http";
import { createServer, sendText, serveConcurrent } from "std/http/server";
import { cpuCount } from "std/os";

function main(): void {
	const server = createServer((req: HttpRequest, res: ServerResponse): void => {
		sendText(res, "ok");
	});
	const lr = server.listen("127.0.0.1", 9999);
	if (!lr.ok) { return; }
	serveConcurrent(server, cpuCount());
}
`;
	const c = compileToC(src);
	assert c.ok;
}

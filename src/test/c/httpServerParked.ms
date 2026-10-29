// Red on card ~/metascript/.inbox/compiler/2026-10-29-compile-to-c-with-std-reads-a-std-routine-call-as-a-function-value.md:
// through compileToCWithStd, a Sendable handler calling req.bodyText() is refused because a call inside
// utf8String reads as a function value, while `msc check` and `msc build` of the same source pass.

import { compileToCWithStd } from "../helpers";

test "E2E C: a blocking server handler that decodes the body as text compiles" {
	const src = `
import { HttpRequest, ServerResponse } from "std/http";
import { createServer, sendJson, serve } from "std/http/server";

function main(): void {
	const server = createServer((req: HttpRequest, res: ServerResponse): void => {
		sendJson(res, req.bodyText());
	});
	const lr = server.listen("127.0.0.1", 9999);
	if (!lr.ok) { return; }
	serve(server);
}
`;
	const c = compileToCWithStd(src);
	assert c.ok;
}

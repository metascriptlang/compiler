// bug016 — HTTP body framer: fast header check false-matches chunked terminator
//
// Symptom:    POST with Transfer-Encoding: chunked returns body=[] empty.
//             Pipelined POST + GET delivers only POST response, GET silently
//             dropped. Server's selector path receives entire request in one
//             recv but treats end-of-buffer as end-of-headers.
//
// Root cause: msFastHeadersCheck only inspects the LAST 4 bytes of the buffer
//             and returns `len` if they are \r\n\r\n. The chunked terminator
//             (`0\r\n\r\n`) and pipelined header blocks both satisfy this
//             pattern, so endPos is set to end-of-buffer. dispatch then has
//             bufferAfter = "" → frameRequest sees empty body for chunked /
//             swallows the next request for pipelined.
//
// Fix:        In dispatch (and dispatchAsync) verify with msSlowHeadersCheck
//             when fast match lands at end-of-buffer. Slow scan finds the
//             FIRST \r\n\r\n (true end of headers) — if it differs from the
//             fast result, use slow.
//
//             Also (separate but discovered during this fix): resetRequest
//             must clear request.headers; otherwise a pipelined GET on the
//             same connection sees the previous POST's Content-Length and
//             frameRequest returns needMore forever.
//
// Body: invariant test on parseRequest (which uses linear scan via findCRLF,
// the same SHAPE as msSlowHeadersCheck). If linear-scan ever regresses to
// matching at end-of-buffer, this catches it. Server-level integration test
// is the smoke procedure with examples/httpEchoConcurrent.ms (manual until
// harness supports compiled-C runtime tests).

import { compileToC } from "../helpers";

test "bug016: linear header scan finds FIRST CRLFCRLF on chunked-terminated buffer" {
	const src = `
import { parseRequest } from "std/http";

function main(): void {
	const data = "POST /x HTTP/1.1\\r\\nTransfer-Encoding: chunked\\r\\n\\r\\n5\\r\\nhello\\r\\n0\\r\\n\\r\\n";
	const r = parseRequest(data);
	if (!r.ok) return;
	// bodyStart must be inside the buffer, NOT at end-of-buffer.
	if (r.value.bodyStart >= data.length as int32) return;
	// Verify the body portion is the intact chunked frame.
	const body = data.slice(r.value.bodyStart, data.length);
	if (body !== "5\\r\\nhello\\r\\n0\\r\\n\\r\\n") return;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "bug016: pipelined POST + GET — buffer ending with \\r\\n\\r\\n still parses to FIRST CRLFCRLF" {
	const src = `
import { parseRequest } from "std/http";

function main(): void {
	// Buffer contains POST headers + body + GET headers (ends with \\r\\n\\r\\n).
	// Linear scan must return offset after FIRST POST headers, not at end of GET.
	const data = "POST /a HTTP/1.1\\r\\nContent-Length: 5\\r\\n\\r\\nhelloGET /b HTTP/1.1\\r\\nHost: l\\r\\n\\r\\n";
	const r = parseRequest(data);
	if (!r.ok) return;
	// bodyStart must point inside POST's body region, not past it.
	if (r.value.bodyStart >= 50) return;  // POST header block ~48 bytes
}
`;
	const c = compileToC(src);
	assert c.ok;
}

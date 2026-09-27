// @stdout: headers chunked=true pipelined=true

import { parseRequest } from "std/http/parser";

function bodyMatches(headers: string, body: string): boolean {
	const data = headers + body;
	const result = parseRequest(data);
	if (!result.ok) return false;
	return result.value.bodyStart == headers.length && data.slice(result.value.bodyStart, data.length) == body;
}

const chunked = bodyMatches("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n", "5\r\nhello\r\n0\r\n\r\n");
const pipelined = bodyMatches("POST /a HTTP/1.1\r\nContent-Length: 5\r\n\r\n", "helloGET /b HTTP/1.1\r\nHost: l\r\n\r\n");
console.log(`headers chunked=${chunked} pipelined=${pipelined}`);

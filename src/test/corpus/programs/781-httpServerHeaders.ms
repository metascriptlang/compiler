// @xfail(raiser): error: Cannot resolve module 'std/http/server'
// Parity program — `std/http/server` type-checks and its response header
// methods reach the header table: `setHeader` / `hasHeader` / `getHeader` /
// `removeHeader` are `this` functions that call the `std/http/headers`
// functions of the same name through a namespace import, so a namespace call
// that resolves to the local `this` function stops every importer of the server.
//
// @stdout: server 0.0.0.0 0 true|set true text/plain|removed false 0
// @exit: 0
// @skip-js: std/http/server is a .cms module, C backend only ("Cannot resolve module 'std/http/server'" on js)

import { createServer, setHeader, hasHeader, getHeader, removeHeader } from "std/http/server";
import { HttpRequest, ServerResponse } from "std/http/types";

function handle(req: HttpRequest, res: ServerResponse): void {
	res.setHeader("x-handled", "1");
}

const server = createServer(handle);
const res: ServerResponse = {
	fd: -1, status: 200, headers: { _names: [], _values: [] }, _chunks: [],
	headersSent: false, _finished: false, _chunked: false, _responseData: "", _upgraded: false,
};
res.setHeader("content-type", "text/plain");
const line1 = `server ${server.address} ${server.port} ${server.keepAlive}`;
const line2 = `set ${res.hasHeader("content-type")} ${res.getHeader("content-type")}`;
res.removeHeader("content-type");
const line3 = `removed ${res.hasHeader("content-type")} ${res.headers._names.length}`;
console.log(`${line1}|${line2}|${line3}`);
